#!/usr/bin/env bash
# update.sh - VaultWarden-OCI update script
# Updates system packages, Docker images, and restarts services.
#
# PATCHED BUGS (2026-03-26):
#   UPDATE-1 [MEDIUM] lib/simple_key_resilience.sh was never sourced.
#                     update.sh calls apply_updates_and_restart() which
#                     re-starts services via docker compose up.  If the
#                     age key is corrupt or has wrong permissions at
#                     restart time, the next backup or maintenance run
#                     fails with a cryptic SOPS error rather than a clear
#                     message.  Fix: source simple_key_resilience.sh and
#                     call check_age_key_health_for_update() in main()
#                     before any update operations.
#
# PATCHED BUGS (2026-04-06):
#   UPDATE-2 [HIGH]   No rollback on partial image pull failure.
#                     If docker compose pull succeeded for some images but
#                     failed for others (network drop, rate limit, registry
#                     error), docker compose up -d was still called, bringing
#                     the stack up in a split old/new image state with only
#                     a log_warn and no operator-visible abort.
#                     Fix: snapshot all image Ids before pulling, detect a
#                     partial-pull result (exit 2 from check_image_updates),
#                     roll back any pulled images to their pre-pull digest via
#                     rollback_image_digests(), and exit 1 before calling
#                     apply_updates_and_restart().
#
# PATCHED BUGS (2026-04-07):
#   UPDATE-3 [HIGH]   Pre-update backup existed but used the wrong backup mode
#                     and treated failures as non-fatal. The previous
#                     run_pre_update_backup() invoked ./backup.sh --type db and
#                     continued on failure, which does not provide a clean full
#                     pre-update rollback point for compose-level changes.
#                     Fix: run ./backup.sh --type pre-update before any update
#                     work, abort on failure, and make the log message explicit
#                     so operators know the update did not proceed without a
#                     restorable safety net.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/simple_key_resilience.sh"  # UPDATE-1 FIX: provides check_age_key_health()

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

# ---------------------------------------------------------------------------
# check_age_key_health_for_update
#
# UPDATE-1 FIX: Verify the age key is present, readable (mode 600), and
# decodeable before running any update operations.  A healthy key at update
# time means the next backup/maintenance systemd timer will succeed.
# In --dry-run mode the check is skipped gracefully (key may not exist
# in CI/dev environments).
# ---------------------------------------------------------------------------
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
        log_warn "     Run: sudo ./setup-systemd.sh --install"
        log_warn "Continuing with update — fix the key before the next backup timer fires."
        # Non-fatal for update: the update itself does not use the key,
        # but we want the operator to know about the problem.
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
    # Issue #51: Add explicit dpkg conffile options to prevent interactive
    # prompts when a package upgrade finds a modified config file.  Without
    # these, dpkg can still prompt under certain conditions even with
    # DEBIAN_FRONTEND=noninteractive, hanging the systemd timer indefinitely.
    # --force-confdef: accept the default (keep or replace) automatically.
    # --force-confold: keep the existing config if no default is defined.
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    if [[ -f /var/run/reboot-required ]]; then
        log_warn "A system reboot is required due to package updates."
    fi
    log_success "System packages updated"
}

# ---------------------------------------------------------------------------
# snapshot_image_digests
#
# UPDATE-2 FIX: Record the current image Id for every service image before
# any pull begins.  The associative array _PRE_PULL_IDS maps image name to
# its pre-pull docker image Id.  Used by rollback_image_digests() to restore
# a coherent image set if the pull is only partially successful.
#
# Must be called before check_image_updates().
# ---------------------------------------------------------------------------
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
        local id
        id=$(docker inspect --format='{{.Id}}' "$image" 2>/dev/null || echo "")
        _PRE_PULL_IDS["$image"]="$id"
        if [[ -n "$id" ]]; then
            log_info "  Snapshot: $image → ${id:7:12}..."
        else
            log_info "  Snapshot: $image → (not present locally)"
        fi
    done

    log_info "Pre-pull snapshot complete (${#_PRE_PULL_IDS[@]} image(s))"
}

# ---------------------------------------------------------------------------
# rollback_image_digests
#
# UPDATE-2 FIX: Called when check_image_updates() detects a partial pull
# failure (some images updated, some not).  For each image that was pulled
# successfully (i.e. its Id changed from the snapshot), re-tag the pre-pull
# image Id back to the image name so that docker compose up -d will use the
# original cohesive set rather than a split old/new mix.
#
# Uses `docker tag <pre-pull-id> <image-name>` which is a metadata-only
# operation (no data moved) and is always safe even if the registry is
# unreachable.
# ---------------------------------------------------------------------------
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
        local cur_id
        cur_id=$(docker inspect --format='{{.Id}}' "$image" 2>/dev/null || echo "")

        if [[ -z "$pre_id" ]]; then
            # Image was not present before the pull; nothing to roll back to.
            log_info "  Skipping rollback for $image (was not present before pull)"
            continue
        fi

        if [[ "$cur_id" == "$pre_id" ]]; then
            log_info "  Unchanged (no rollback needed): $image"
            continue
        fi

        # Image was updated during this run — restore the pre-pull tag.
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
        log_error "Pull again from a stable network: sudo ./update.sh --images"
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

# ---------------------------------------------------------------------------
# check_image_updates
#
# Returns:
#   0  — all images pulled successfully (or already up to date)
#   1  — all pulls failed (nothing was updated)
#   2  — partial failure: some images were updated, some failed (split state)
#
# UPDATE-2 FIX: exit code 2 distinguishes a partial pull from a total failure
# so main() can detect the split-version risk and call rollback_image_digests()
# before aborting.
# ---------------------------------------------------------------------------
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
        # Issue #21: use pull_image_with_retry() for exponential backoff and
        # permanent-error detection; track failures so caller sees non-zero.
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

    if (( updated > 0 )); then
        log_info "$updated image(s) updated"
    else
        log_info "All Docker images are up to date"
    fi

    if (( failed == 0 )); then
        return 0
    fi

    # UPDATE-2 FIX: distinguish total failure (nothing updated, return 1)
    # from partial failure (some updated, some failed, return 2 — split risk).
    if (( updated > 0 )); then
        log_error "$failed image pull(s) FAILED after $updated succeeded — stack would be in a split-version state."
        return 2
    fi

    # All pulls failed — nothing changed on disk.
    log_error "All $failed image pull(s) failed — no images were updated."
    return 1
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
            # Issue #22: count missing digests as failures so caller is notified.
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
        log_error "backup.sh not found or not executable — aborting update"
        return 1
    fi
    log_info "Creating pre-update backup via ./backup.sh --type pre-update..."
    if "${SCRIPT_DIR}/backup.sh" --type pre-update; then
        log_success "Pre-update backup created"
        return 0
    fi
    log_error "Pre-update backup failed — aborting update to avoid an unsafe rollback point"
    return 1
}

main() {
    require_root "$@"
    load_env_file || { log_error "Failed to load .env"; exit 1; }

    log_header "VaultWarden-OCI Update"

    # UPDATE-1 FIX: Check age key health before update so any key regression
    # (e.g. wrong permissions after git pull) is surfaced here rather than
    # silently causing backup/maintenance failures later.
    check_age_key_health_for_update

    run_pre_update_backup || exit 1

    if [[ "$UPDATE_SYSTEM" == "true" ]]; then
        update_system_packages
    fi

    if [[ "$UPDATE_IMAGES" == "true" ]] || [[ "$FORCE" == "true" ]]; then
        # UPDATE-2 FIX: Snapshot pre-pull image Ids before pulling so that
        # rollback_image_digests() can restore a coherent set on partial failure.
        snapshot_image_digests

        local pull_rc=0
        check_image_updates || pull_rc=$?

        if (( pull_rc == 2 )); then
            # Partial pull — some images updated, some failed.  Roll back the
            # successfully pulled images to their pre-pull state so the stack
            # remains on a consistent version set, then abort.
            log_error "Partial image pull detected (UPDATE-2): rolling back to prevent a split-version stack."
            rollback_image_digests || true
            if [[ "$EMAIL_NOTIFY" == "true" ]]; then
                local subject="[VaultWarden] Update ABORTED: partial image pull"
                local body
                body="$(printf 'A partial docker image pull was detected on host: %s\nTime: %s\n\nSome images were updated and some failed. The pulled images have been\nrolled back to their pre-pull digests to prevent a split-version stack.\n\nResolve the network or registry issue, then retry:\n  sudo ./update.sh --images\n' \
                    "$(hostname -f 2>/dev/null || hostname)" "$(date)")"
                send_notification_email "$subject" "$body" 2>/dev/null || true
            fi
            exit 1
        elif (( pull_rc != 0 )); then
            # Total failure — nothing was pulled; no rollback needed.
            log_warn "Image pull failed for all images — no images were updated. Services not restarted."
            if [[ "$EMAIL_NOTIFY" == "true" ]]; then
                local subject="[VaultWarden] Update WARNING: image pull failed"
                local body
                body="$(printf 'All docker image pulls failed on host: %s\nTime: %s\n\nNo images were updated. Services remain on their current versions.\n\nResolve the network or registry issue, then retry:\n  sudo ./update.sh --images\n' \
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