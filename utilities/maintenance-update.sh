#!/usr/bin/env bash
# utilities/maintenance-update.sh — VaultWarden system + Docker image updater
#
# Standalone entry point for the 'update' subcommand.
# Invoked directly by:
#   - maintenance.sh update [OPTIONS]  (thin dispatcher)
#
# EXIT CODES:
#   0 — update completed successfully
#   1 — update failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_SAVE_SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/common.sh"
init_common_lib "$0"
source "$PROJECT_ROOT/lib/docker.sh"
source "$PROJECT_ROOT/lib/backup-utils.sh"
source "$PROJECT_ROOT/lib/crypto.sh"
_MAINT_SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/secrets.sh"
SCRIPT_DIR="$_MAINT_SCRIPT_DIR"
unset _MAINT_SCRIPT_DIR
source "$PROJECT_ROOT/lib/storage.sh"

# ---------------------------------------------------------------------------
# Configuration defaults
# ---------------------------------------------------------------------------
UPDATE_SYSTEM=false
UPDATE_IMAGES=false
FORCE=false
DRY_RUN=false
SKIP_BACKUP=false
EMAIL_NOTIFY=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Update Script

USAGE:
    sudo utilities/maintenance-update.sh [OPTIONS]
    sudo ./maintenance.sh update [OPTIONS]

OPTIONS:
    --system         Update system packages (apt upgrade)
    --images         Update Docker images only
    --all            Update system packages + Docker images
    --force          Force update even if images are up to date
    --dry-run        Show what would be done without executing
    --skip-backup    Skip pre-update safety backup
    --email          Send email notification on completion/failure
    --help, -h       Show this help

EXAMPLES:
    sudo ./maintenance.sh update --system        # Update system packages only
    sudo ./maintenance.sh update --images        # Update Docker images only
    sudo ./maintenance.sh update --all           # Full system + image update
    sudo ./maintenance.sh update --all --email   # Full update with email notification
EOF
}

# ---------------------------------------------------------------------------
# Update functions — verbatim from maintenance.sh run_update() body
# ---------------------------------------------------------------------------
ensure_caddy_entrypoint_executable() {
    local ep="${SCRIPT_DIR}/caddy/entrypoint.sh"
    if [[ ! -f "$ep" ]]; then
        log_warn "caddy/entrypoint.sh not found at expected path: $ep"
        return 0
    fi
    if [[ ! -x "$ep" ]]; then
        log_warn "caddy/entrypoint.sh is not executable — fixing (BUG-EP1)"
        chmod +x "$ep"
    fi
    if [[ ! -x "$ep" ]]; then
        log_error "Failed to make caddy/entrypoint.sh executable — Caddy container will fail to start"
        return 1
    fi
    log_info "caddy/entrypoint.sh execute bit OK"
    return 0
}

check_age_key_health_for_update() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Skipping age key health check"
        return 0
    fi
    log_info "Pre-flight: checking age key integrity..."
    if ! check_age_key_health 2>/dev/null; then
        log_warn "Age key health check FAILED."
        log_warn "Backup and maintenance operations will fail until the key is repaired."
        log_warn "Common causes:"
        log_warn "  1. Key file missing or wrong path (check SOPS_AGE_KEY_FILE in .env)"
        log_warn "  2. Wrong permissions (must be 600): chmod 600 \"\$SOPS_AGE_KEY_FILE\""
        log_warn "  3. Key file corrupt — restore from recovery kit"
        log_warn "  4. After systemd install, key must be at /etc/vaultwarden/age-key.txt"
        log_warn "     Run: sudo ./setup.sh systemd install"
        log_warn "Continuing with update — fix the key before the next backup timer fires."
        return 0
    fi
    log_success "Age key integrity OK"
    return 0
}

update_system_packages() {
    log_info "Updating system packages..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: apt-get update && apt-get upgrade -y"
        return 0
    fi
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    if systemctl is-active docker >/dev/null 2>&1; then
        if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
            log_warn "Docker daemon unreachable after package update — restarting daemon..."
            if systemctl restart docker; then
                sleep 5
                if docker version >/dev/null 2>&1; then
                    log_success "Docker daemon restarted successfully after package upgrade"
                else
                    log_error "CRITICAL: Docker daemon unhealthy after restart — manual intervention required"
                    return 1
                fi
            else
                log_error "CRITICAL: Docker daemon failed to restart after package upgrade"
                return 1
            fi
        fi
    fi
    if [[ -f /var/run/reboot-required ]]; then
        log_warn "A system reboot is required due to package updates."
        log_warn "Schedule a maintenance window: sudo systemctl reboot"
        if [[ "${EMAIL_NOTIFY:-false}" == "true" ]]; then
            send_notification_email \
                "VaultWarden Host: Reboot Required on $(hostname)" \
                "$(printf 'A reboot is required on %s after package updates.\nSchedule a maintenance window to apply the kernel/library update.\n' "$(hostname -f 2>/dev/null || hostname)")" \
                2>/dev/null || true
        fi
    fi
    log_success "System packages updated"
}

declare -A _PRE_PULL_IDS=()

snapshot_image_digests() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would snapshot pre-pull image digests"
        return 0
    fi
    log_info "Snapshotting pre-pull image digests..."
    local images=()
    while IFS= read -r img; do
        [[ -n "$img" ]] && images+=("$img")
    done < <(docker compose config --images 2>/dev/null || true)
    for image in "${images[@]}"; do
        local id; id=$(docker inspect --format='{{.Id}}' "$image" 2>/dev/null || echo "")
        _PRE_PULL_IDS["$image"]="$id"
        if [[ -n "$id" ]]; then
            log_info "  Snapshot: $image → ${id:7:12}..."
        else
            log_info "  Snapshot: $image → (not present locally)"
        fi
    done
    log_info "Pre-pull snapshot complete (${#_PRE_PULL_IDS[@]} image(s))"
}

rollback_image_digests() {
    if [[ ${#_PRE_PULL_IDS[@]} -eq 0 ]]; then
        log_warn "No pre-pull snapshot available — cannot roll back image digests."
        log_warn "Inspect running containers manually before restarting services."
        return 1
    fi
    log_warn "Rolling back pulled images to pre-pull digests..."
    local rolled_back=0
    local rollback_failed=0
    for image in "${!_PRE_PULL_IDS[@]}"; do
        local pre_id="${_PRE_PULL_IDS[$image]}"
        local cur_id; cur_id=$(docker inspect --format='{{.Id}}' "$image" 2>/dev/null || echo "")
        if [[ -z "$pre_id" ]]; then
            log_info "  Skipping rollback for $image (was not present before pull)"
            continue
        fi
        if [[ "$cur_id" == "$pre_id" ]]; then
            log_info "  Unchanged (no rollback needed): $image"
            continue
        fi
        log_warn "  Restoring: $image → ${pre_id:7:12}..."
        if docker tag "$pre_id" "$image" 2>/dev/null; then
            log_warn "  Restored:  $image"
            (( ++rolled_back )) || true
        else
            log_error "  Rollback FAILED for $image (pre-pull Id: ${pre_id:7:12})"
            log_error "  The pre-pull image layer may have been pruned."
            log_error "  Run 'docker compose pull' again once the network issue is resolved."
            (( ++rollback_failed )) || true
        fi
    done
    if (( rollback_failed > 0 )); then
        log_error "Rollback incomplete: $rollback_failed image(s) could not be restored."
        log_error "Do NOT run 'docker compose up -d' until all images are at consistent versions."
        log_error "Pull again from a stable network: sudo ./maintenance.sh update --images"
        return 1
    fi
    if (( rolled_back > 0 )); then
        log_warn "Rollback complete: $rolled_back image(s) restored to pre-pull state."
        log_warn "The stack will restart on the previous cohesive image set."
    else
        log_info "Rollback: no images required restoration."
    fi
    return 0
}

check_image_updates() {
    log_info "Checking for image updates..."
    local images=()
    while IFS= read -r img; do
        [[ -n "$img" ]] && images+=("$img")
    done < <(docker compose config --images 2>/dev/null || true)
    if [[ ${#images[@]} -eq 0 ]]; then
        log_warn "No images found in docker-compose.yml"
        return 1
    fi
    local updated=0
    local failed=0
    for image in "${images[@]}"; do
        log_info "  Pulling $image..."
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "  [DRY RUN] Would pull: $image"
            continue
        fi
        local old_id new_id
        old_id=$(docker inspect --format='{{.Id}}' "$image" 2>/dev/null || echo "")
        if ! pull_image_with_retry "$image"; then
            log_error "  [FAILED] Could not pull: $image"
            (( failed++ )) || true
            continue
        fi
        new_id=$(docker inspect --format='{{.Id}}' "$image" 2>/dev/null || echo "")
        if [[ -n "$old_id" && "$old_id" != "$new_id" ]]; then
            log_info "  [UPDATED] $image"
            (( ++updated )) || true
        else
            log_info "  [CURRENT] $image is up to date"
        fi
    done
    if (( updated > 0 )); then log_info "$updated image(s) updated"
    else log_info "All Docker images are up to date"; fi
    if (( failed == 0 )); then return 0; fi
    if (( updated > 0 )); then
        log_error "$failed image pull(s) FAILED after $updated succeeded — stack would be in a split-version state."
        return 2
    fi
    log_error "All $failed image pull(s) failed — no images were updated."
    return 1
}

verify_image_digests() {
    log_info "Verifying image digest integrity before starting services..."
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would verify image digests"; return 0; fi
    local images=()
    while IFS= read -r img; do
        [[ -n "$img" ]] && images+=("$img")
    done < <(docker compose config --images 2>/dev/null || true)
    local failed=0
    for image in "${images[@]}"; do
        local digest
        digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$image" 2>/dev/null | awk -F'@' '{print $2}' || echo "")
        if [[ -z "$digest" ]]; then
            log_warn "  No digest available for $image (local-only image?)"
            (( failed++ )) || true
        else
            log_info "  Digest integrity OK for $image (${digest:0:18}...)"
        fi
    done
    return $failed
}

apply_updates_and_restart() {
    log_info "Applying updates and restarting services..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: docker compose up -d --remove-orphans"
        return 0
    fi
    ensure_caddy_entrypoint_executable || return 1
    if ! docker compose up -d --remove-orphans; then
        log_error "Failed to restart services"
        return 1
    fi
    log_success "Services restarted successfully"
    return 0
}

run_pre_update_backup() {
    if [[ "$SKIP_BACKUP" == "true" ]]; then
        log_info "Skipping pre-update backup (--skip-backup)"
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create pre-update safety backup"
        return 0
    fi
    if [[ ! -x "${SCRIPT_DIR}/backup.sh" ]]; then
        log_error "backup.sh not found or not executable — aborting update"
        return 1
    fi
    log_info "Creating pre-update safety backup via ./backup.sh run db..."
    if "${SCRIPT_DIR}/backup.sh" run db; then
        log_success "Pre-update backup created"
        return 0
    fi
    log_error "Pre-update backup failed — aborting update to avoid an unsafe rollback point"
    return 1
}

# ---------------------------------------------------------------------------
# Argument parsing & main
# ---------------------------------------------------------------------------
[[ "${1:-}" == "update" ]] && shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --system)      UPDATE_SYSTEM=true;               shift ;;
        --images)      UPDATE_IMAGES=true;               shift ;;
        --all)         UPDATE_SYSTEM=true; UPDATE_IMAGES=true; shift ;;
        --force)       FORCE=true;                       shift ;;
        --dry-run)     DRY_RUN=true;                     shift ;;
        --skip-backup) SKIP_BACKUP=true;                 shift ;;
        --email)       EMAIL_NOTIFY=true;                shift ;;
        --help|-h|help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

main() {
    require_root
    load_env_file || { log_error "Failed to load .env"; exit 1; }
    if [[ "$UPDATE_SYSTEM" == "false" && "$UPDATE_IMAGES" == "false" ]]; then
        log_error "Specify at least one of: --system, --images, --all"
        show_help; exit 1
    fi
    log_header "VaultWarden-OCI Update"
    check_age_key_health_for_update
    run_pre_update_backup || exit 1
    if [[ "$UPDATE_SYSTEM" == "true" ]]; then
        update_system_packages
    fi
    if [[ "$UPDATE_IMAGES" == "true" ]] || [[ "$FORCE" == "true" ]]; then
        snapshot_image_digests
        local pull_rc=0
        check_image_updates || pull_rc=$?
        if (( pull_rc == 2 )); then
            log_error "Partial image pull detected (UPDATE-2): rolling back to prevent a split-version stack."
            rollback_image_digests || true
            if [[ "$EMAIL_NOTIFY" == "true" ]]; then
                local subject="[VaultWarden] Update ABORTED: partial image pull"
                local body
                body="$(printf 'A partial docker image pull was detected on host: %s\nTime: %s\n\nSome images were updated and some failed. The pulled images have been\nrolled back to their pre-pull digests to prevent a split-version stack.\n\nResolve the network or registry issue, then retry:\n  sudo ./maintenance.sh update --images\n' \
                    "$(hostname -f 2>/dev/null || hostname)" "$(date)")"
                send_notification_email "$subject" "$body" 2>/dev/null || true
            fi
            exit 1
        elif (( pull_rc != 0 )); then
            log_warn "Image pull failed for all images — no images were updated. Services not restarted."
            if [[ "$EMAIL_NOTIFY" == "true" ]]; then
                local subject="[VaultWarden] Update WARNING: image pull failed"
                local body
                body="$(printf 'All docker image pulls failed on host: %s\nTime: %s\n\nNo images were updated. Services remain on their current versions.\n\nResolve the network or registry issue, then retry:\n  sudo ./maintenance.sh update --images\n' \
                    "$(hostname -f 2>/dev/null || hostname)" "$(date)")"
                send_notification_email "$subject" "$body" 2>/dev/null || true
            fi
            exit 1
        fi
        verify_image_digests || log_warn "Digest verification had issues"
    fi
    apply_updates_and_restart || {
        if [[ "$EMAIL_NOTIFY" == "true" ]]; then
            local subject="[VaultWarden] Update FAILED"
            local body
            body="$(printf 'Update failed on host: %s\nTime: %s\n\nCheck logs for details.\n' \
                "$(hostname -f 2>/dev/null || hostname)" "$(date)")"
            send_notification_email "$subject" "$body" 2>/dev/null || true
        fi
        exit 1
    }
    if [[ "$EMAIL_NOTIFY" == "true" ]]; then
        local subject="[VaultWarden] Update completed"
        local body
        body="$(printf 'System packages: %s\nDocker images:   %s\nHost:            %s\nTime:            %s\n' \
            "$( [[ $UPDATE_SYSTEM == true ]] && echo updated || echo skipped )" \
            "$( [[ $UPDATE_IMAGES == true ]] && echo checked || echo skipped )" \
            "$(hostname -f 2>/dev/null || hostname)" \
            "$(date)")"
        send_notification_email "$subject" "$body" 2>/dev/null || \
            log_warn "Email notification failed (update still succeeded)"
    fi
    log_success "Update completed successfully"
    exit 0
}

main "$@"
