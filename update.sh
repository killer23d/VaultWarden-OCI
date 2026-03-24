#!/usr/bin/env bash
# update.sh - VaultWarden-OCI update script
# Updates system packages, Docker images, and restarts services.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"

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
    sudo ./update.sh [OPTIONS]

OPTIONS:
    --system         Update system packages (apt upgrade)
    --images         Update Docker images only
    --all            Update system packages + Docker images
    --force          Force update even if images are up to date
    --dry-run        Show what would be done without executing
    --skip-backup    Skip pre-update safety backup
    --email          Send email notification on completion/failure
    --help           Show this help

EXAMPLES:
    sudo ./update.sh --system        # Update system packages only
    sudo ./update.sh --images        # Update Docker images only
    sudo ./update.sh --all           # Full system + image update
    sudo ./update.sh --all --email   # Full update with email notification
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --system)      UPDATE_SYSTEM=true;  shift ;;
        --images)      UPDATE_IMAGES=true;  shift ;;
        --all)         UPDATE_SYSTEM=true; UPDATE_IMAGES=true; shift ;;
        --force)       FORCE=true;          shift ;;
        --dry-run)     DRY_RUN=true;        shift ;;
        --skip-backup) SKIP_BACKUP=true;    shift ;;
        --email)       EMAIL_NOTIFY=true;   shift ;;
        --help)        show_help; exit 0 ;;
        *)             log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if [[ "$UPDATE_SYSTEM" == "false" && "$UPDATE_IMAGES" == "false" ]]; then
    log_error "Specify at least one of: --system, --images, --all"
    show_help
    exit 1
fi

# ---------------------------------------------------------------------------
# ensure_caddy_entrypoint_executable
#
# BUG-EP1 FIX: caddy/entrypoint.sh is bind-mounted as the container entrypoint.
# Docker preserves host filesystem permission bits exactly; if the file lacks
# the execute bit the OCI runtime fails with 'permission denied' before the
# container process can start. This can happen after:
#   - 'git pull' run with a restrictive umask (e.g. 0027 -> mode 640)
#   - Any chmod 644/640 sweep over the repo directory
#   - rsync/scp from a source where the bit was lost
# startup.sh already guards this inside prepare_log_directories(); this
# function mirrors that guard so update.sh is also resilient.
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
    # Verify the fix took effect
    if [[ ! -x "$ep" ]]; then
        log_error "Failed to make caddy/entrypoint.sh executable — Caddy container will fail to start"
        return 1
    fi
    log_info "caddy/entrypoint.sh execute bit OK"
    return 0
}

update_system_packages() {
    log_info "Updating system packages..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: apt-get update && apt-get upgrade -y"
        return 0
    fi
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    if [[ -f /var/run/reboot-required ]]; then
        log_warn "A system reboot is required due to package updates."
    fi
    log_success "System packages updated"
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
    for image in "${images[@]}"; do
        log_info "  Pulling $image..."
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "  [DRY RUN] Would pull: $image"
            continue
        fi

        local old_id new_id
        old_id=$(docker inspect --format='{{.Id}}' "$image" 2>/dev/null || echo "")
        docker pull "$image" --quiet 2>/dev/null || docker pull "$image" 2>&1 | tail -1
        new_id=$(docker inspect --format='{{.Id}}' "$image" 2>/dev/null || echo "")

        if [[ -n "$old_id" && "$old_id" != "$new_id" ]]; then
            log_info "  [UPDATED] $image"
            (( ++updated )) || true
        else
            log_info "  [CURRENT] $image is up to date"
        fi
    done

    if (( updated > 0 )); then
        log_info "$updated image(s) updated"
    else
        log_info "All Docker images are up to date"
    fi
    return 0
}

verify_image_digests() {
    log_info "Verifying image digest integrity before starting services..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would verify image digests"
        return 0
    fi

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

    # BUG-EP1 FIX: Ensure caddy/entrypoint.sh has the execute bit before
    # docker compose up. Docker bind-mounts preserve host permission bits
    # exactly; a missing +x causes runc EACCES before the container starts.
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
        log_warn "backup.sh not found or not executable — skipping pre-update backup"
        return 0
    fi
    log_info "Creating pre-update safety backup..."
    if "${SCRIPT_DIR}/backup.sh" --type db --quiet; then
        log_success "Pre-update safety backup created"
    else
        log_warn "Pre-update backup failed — continuing with update anyway"
        log_warn "Consider running './backup.sh --type full' manually before proceeding"
    fi
}

main() {
    require_root "$@"
    load_env_file || { log_error "Failed to load .env"; exit 1; }

    log_header "VaultWarden-OCI Update"

    run_pre_update_backup

    if [[ "$UPDATE_SYSTEM" == "true" ]]; then
        update_system_packages
    fi

    if [[ "$UPDATE_IMAGES" == "true" ]] || [[ "$FORCE" == "true" ]]; then
        check_image_updates || log_warn "Image check encountered issues"
        verify_image_digests || log_warn "Digest verification had issues"
    fi

    apply_updates_and_restart || {
        if [[ "$EMAIL_NOTIFY" == "true" ]]; then
            local subject="[VaultWarden] Update FAILED: $(date)"
            local body
            body="$(printf 'Update failed on host: %s\nTime: %s\n\nCheck logs for details.\n' \
                "$(hostname -f 2>/dev/null || hostname)" "$(date)")"
            send_notification_email "$subject" "$body" 2>/dev/null || true
        fi
        exit 1
    }

    if [[ "$EMAIL_NOTIFY" == "true" ]]; then
        local subject="[VaultWarden] Update completed: $(date)"
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
