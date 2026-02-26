#!/usr/bin/env bash
# update.sh - System and container update script with enhanced safety

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/backup_utils.sh"

# Configuration
BACKUP_BEFORE_UPDATE=true
UPDATE_CONTAINERS=true
UPDATE_SYSTEM=false
FORCE_UPDATE=false
DRY_RUN=false
EMAIL_NOTIFY=false
RESTART_AFTER=true

# How long to wait for services to stabilize before post-update health check.
# Override from environment: POST_UPDATE_WAIT_SECONDS=60 ./update.sh
POST_UPDATE_WAIT_SECONDS="${POST_UPDATE_WAIT_SECONDS:-30}"

show_help() {
    cat << 'EOF'
VaultWarden-OCI Update Script with Safety Checks

USAGE:
    ./update.sh [OPTIONS]

OPTIONS:
    --system                Update system packages (default: containers only)
    --no-backup             Skip backup before update (not recommended)
    --no-restart            Skip service restart after update
    --force                 Force update even if no new versions available
    --dry-run               Show what would be updated without executing
    --email                 Send email notification on completion
    --help                  Show this help

EXAMPLES:
    ./update.sh                          # Update containers with backup
    ./update.sh --system                 # Update both system and containers
    ./update.sh --dry-run --system       # Preview all updates
    ./update.sh --no-backup --force      # Force update without backup

SAFETY FEATURES:
    - Automatic backup before updates (can be disabled with --no-backup)
    - Health checks before and after updates
    - Automatic rollback attempt via restore.sh --latest if post-update
      health check fails (always selects the freshest pre-update snapshot)
    - Email notifications for update status (single summary email per run;
      the pre-update backup does NOT send its own email even with --email)

EXIT CODES:
    0  - Update completed successfully, all health checks passed
    1  - Update failed or critical phase error
    2  - Update completed but post-update health check reported issues
EOF
}

# Argument Parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --system)     UPDATE_SYSTEM=true;         shift ;;
        --no-backup)  BACKUP_BEFORE_UPDATE=false; shift ;;
        --no-restart) RESTART_AFTER=false;        shift ;;
        --force)      FORCE_UPDATE=true;          shift ;;
        --dry-run)    DRY_RUN=true;               shift ;;
        --email)      EMAIL_NOTIFY=true;          shift ;;
        --help)       show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# create_pre_update_backup
#
# FIX #3: --email is intentionally NOT forwarded to backup.sh here.
# When update.sh --email is used the user expects exactly one summary
# email for the whole run. If backup.sh also emailed, two emails would
# fire for a single update. The update summary from generate_update_summary()
# already covers the backup outcome.
# ---------------------------------------------------------------------------
create_pre_update_backup() {
    if [[ "$BACKUP_BEFORE_UPDATE" != "true" ]]; then
        log_info "Skipping pre-update backup (--no-backup specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create pre-update backup (type: full)"
        return 0
    fi

    log_info "Creating pre-update backup for safety..."

    # NOTE: --email is deliberately omitted. The update summary email covers
    # the full run; we do not want backup.sh to send a separate email here.
    if ./backup.sh --type full; then
        log_success "Pre-update backup completed successfully"
        return 0
    else
        log_error "Pre-update backup failed"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# update_system_packages
# ---------------------------------------------------------------------------
update_system_packages() {
    if [[ "$UPDATE_SYSTEM" != "true" ]]; then
        log_info "Skipping system package updates (use --system to enable)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would update system packages"
        apt-get update -qq 2>/dev/null || true
        local count
        count=$(apt list --upgradable 2>/dev/null | grep -c '/' || echo "0")
        log_info "[DRY RUN] System packages available to upgrade: ${count}"
        return 0
    fi

    log_info "Updating system packages..."

    if ! apt-get update -qq; then
        log_error "Failed to update package lists"
        return 1
    fi

    local updates_available
    updates_available=$(apt list --upgradable 2>/dev/null | grep -c '/' || echo "0")

    if [[ "$updates_available" -eq 0 ]] && [[ "$FORCE_UPDATE" != "true" ]]; then
        log_info "No system package updates available"
        return 0
    fi

    log_info "Found $updates_available system package updates available"

    export DEBIAN_FRONTEND=noninteractive
    if apt-get upgrade -y; then
        log_success "System packages updated successfully"
        if [[ -f /var/run/reboot-required ]]; then
            log_warn "System reboot required after updates"
            log_info "Reboot after completing container updates with: sudo reboot"
        fi
        return 0
    else
        log_error "System package updates failed"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# update_containers
# ---------------------------------------------------------------------------
update_containers() {
    if [[ "$UPDATE_CONTAINERS" != "true" ]]; then
        log_info "Skipping container updates"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would pull updated container images. Current configured tags:"
        docker compose config --images 2>/dev/null | sort | uniq | sed 's/^/    /' || \
            log_info "    (could not list images - docker compose config unavailable)"
        return 0
    fi

    log_info "Updating container images..."

    if ! pull_images; then
        log_error "Failed to pull latest container images"
        return 1
    fi

    log_success "Container images updated successfully"
    return 0
}

# ---------------------------------------------------------------------------
# restart_services_after_update
# Uses --force (the correct, documented flag per startup.sh after FIX [ISSUE 2]).
# ---------------------------------------------------------------------------
restart_services_after_update() {
    if [[ "$RESTART_AFTER" != "true" ]]; then
        log_info "Skipping service restart (--no-restart specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would restart services after update"
        return 0
    fi

    log_info "Restarting services with updated containers..."

    if ./startup.sh --force; then
        log_success "Services restarted successfully with updated containers"
        return 0
    else
        log_error "Failed to restart services after update"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# attempt_rollback
#
# FIX [ISSUE 14]: Now uses --latest --type full so restore.sh always selects
# the most recent full backup by mtime. This guarantees the rollback grabs
# the snapshot just created by create_pre_update_backup regardless of whether
# lexicographic sort or clock skew would have chosen a different file.
#
# --no-backup skips the pre-restore snapshot (we already have ours).
# --force    skips the interactive confirmation prompt.
# ---------------------------------------------------------------------------
attempt_rollback() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would attempt rollback: ./restore.sh --latest --type full --force --no-backup"
        return 0
    fi

    log_warn "Attempting automatic rollback to pre-update backup..."

    if [[ ! -x "./restore.sh" ]]; then
        log_error "restore.sh not found or not executable - manual rollback required"
        log_error "Run: ./restore.sh --latest --type full --force --no-backup"
        return 1
    fi

    if ./restore.sh --latest --type full --force --no-backup; then
        log_success "Rollback completed - services restored to pre-update state"
        log_warn "Please investigate why the update caused health check failures"
        return 0
    else
        log_error "Automatic rollback failed - MANUAL INTERVENTION REQUIRED"
        log_error "Steps: 1) docker compose down  2) ./restore.sh  3) ./startup.sh"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# generate_update_summary
# ---------------------------------------------------------------------------
generate_update_summary() {
    local pre_health="$1"
    local system_update="$2"
    local container_update="$3"
    local restart="$4"
    local post_health="$5"
    local rollback_attempted="${6:-false}"
    local rollback_result="${7:-1}"

    log_info "Generating update summary..."

    local summary
    summary=$(printf "VaultWarden Update Summary - %s\n" "$(date)")
    summary+=$(printf "\nUpdate Results:\n")

    if [[ "$UPDATE_SYSTEM" == "true" ]]; then
        if [[ "$system_update" == "0" ]]; then
            summary+=$(printf "  ✅ System packages: Updated successfully\n")
        else
            summary+=$(printf "  ❌ System packages: Update failed\n")
        fi
    else
        summary+=$(printf "  ⏭️  System packages: Skipped\n")
    fi

    if [[ "$container_update" == "0" ]]; then
        summary+=$(printf "  ✅ Container images: Updated successfully\n")
    else
        summary+=$(printf "  ❌ Container images: Update failed\n")
    fi

    if [[ "$RESTART_AFTER" == "true" ]]; then
        if [[ "$restart" == "0" ]]; then
            summary+=$(printf "  ✅ Service restart: Completed successfully\n")
        else
            summary+=$(printf "  ❌ Service restart: Failed\n")
        fi
    else
        summary+=$(printf "  ⏭️  Service restart: Skipped\n")
    fi

    if [[ "$pre_health" == "0" ]]; then
        summary+=$(printf "  ✅ Pre-update health: Passed\n")
    else
        summary+=$(printf "  ⚠️  Pre-update health: Issues detected (non-fatal)\n")
    fi

    if [[ "$post_health" == "0" ]]; then
        summary+=$(printf "  ✅ Post-update health: Passed\n")
    else
        summary+=$(printf "  ❌ Post-update health: Issues detected\n")
    fi

    if [[ "$rollback_attempted" == "true" ]]; then
        if [[ "$rollback_result" == "0" ]]; then
            summary+=$(printf "  ✅ Automatic rollback: Succeeded\n")
        else
            summary+=$(printf "  ❌ Automatic rollback: FAILED - manual intervention required\n")
        fi
    fi

    if [[ "$system_update" == "0" && "$container_update" == "0" && \
          "$restart" == "0" && "$post_health" == "0" ]]; then
        summary+=$(printf "\n🎉 Overall Status: UPDATE SUCCESSFUL\n")
        summary+=$(printf "\nNext Steps:\n")
        summary+=$(printf "  • Monitor services for stability\n")
        summary+=$(printf "  • Check logs if any issues arise\n")
        if [[ -f /var/run/reboot-required ]]; then
            summary+=$(printf "  • IMPORTANT: System reboot required (sudo reboot)\n")
        fi
    else
        summary+=$(printf "\n⚠️  Overall Status: UPDATE COMPLETED WITH ISSUES\n")
        summary+=$(printf "\nImmediate Actions Required:\n")
        summary+=$(printf "  • Check service logs: make logs\n")
        summary+=$(printf "  • Run health check: ./health.sh --comprehensive\n")
        if [[ "$rollback_attempted" != "true" ]]; then
            summary+=$(printf "  • Consider rollback: ./restore.sh --latest --type full --force --no-backup\n")
        fi
    fi

    printf "%s\n" "$summary"

    if [[ "$EMAIL_NOTIFY" == "true" ]]; then
        local email_subject
        if [[ "$system_update" == "0" && "$container_update" == "0" && \
              "$restart" == "0" && "$post_health" == "0" ]]; then
            email_subject="VaultWarden Update: SUCCESS"
        else
            email_subject="VaultWarden Update: ISSUES DETECTED"
        fi

        if send_notification_email "$email_subject" "$summary"; then
            log_info "Update summary emailed to admin"
        else
            log_warn "Failed to send update summary email"
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# main
#
# FIX #4: pre_update_health_check() and post_update_health_check() wrapper
# functions have been removed and their logic inlined here.
#
# Pre-check  — informational only, never blocks the update. The non-fatal
#              semantics and context message are preserved inline.
# Post-check — the POST_UPDATE_WAIT_SECONDS stabilisation sleep is preserved
#              inline before calling ./health.sh --quiet. This was the
#              non-trivial behaviour that the wrapper added beyond the bare
#              health.sh call, and it must not be lost.
# ---------------------------------------------------------------------------
main() {
    log_header "VaultWarden-OCI Update Manager"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    if ! load_env_file; then
        log_error "Failed to load configuration"
        exit 1
    fi

    # Track operation results (1 = not yet run / failed, 0 = success)
    local pre_health_result=1
    local system_update_result=1
    local container_update_result=1
    local restart_result=1
    local post_health_result=1
    local rollback_attempted=false
    local rollback_result=1

    # -----------------------------------------------------------------------
    # Phase 1: Pre-update checks and backup
    # -----------------------------------------------------------------------
    log_info "=== Phase 1: Pre-Update Preparation ==="

    # Pre-update health check — informational only, never blocks the update.
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would perform pre-update health check"
        pre_health_result=0
    elif ./health.sh --quiet; then
        log_success "Pre-update health check passed"
        pre_health_result=0
    else
        log_warn "Pre-update health check reported issues (non-fatal - see above)"
        log_info "Continuing with update - the pre-update backup provides the safety net"
        # pre_health_result stays 1 (issues detected) but we do not exit
    fi

    # Backup IS fatal: refuse to proceed without a safety snapshot
    if ! create_pre_update_backup; then
        log_error "Pre-update backup failed - aborting update for safety"
        exit 1
    fi

    # -----------------------------------------------------------------------
    # Phase 2: Perform updates
    # -----------------------------------------------------------------------
    log_info "=== Phase 2: Performing Updates ==="

    if update_system_packages; then
        system_update_result=0
    else
        log_error "System package update failed - continuing with container updates"
    fi

    if update_containers; then
        container_update_result=0
    else
        log_error "Container image pull failed"
    fi

    # -----------------------------------------------------------------------
    # Phase 3: Post-update restart and verification
    # -----------------------------------------------------------------------
    log_info "=== Phase 3: Post-Update Restart and Verification ==="

    if [[ "$container_update_result" == "0" ]] || [[ "$FORCE_UPDATE" == "true" ]]; then
        if restart_services_after_update; then
            restart_result=0
        else
            log_error "Service restart failed"
        fi
    else
        # Pull failed — nothing was changed, services still running on old images.
        log_info "Skipping service restart — container pull failed, old images still active"
        restart_result=0
    fi

    if [[ "$restart_result" == "0" ]]; then
        # Post-update health check — wait for stabilisation, then check.
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would perform post-update health check (wait: ${POST_UPDATE_WAIT_SECONDS}s)"
            post_health_result=0
        else
            log_info "Performing post-update health check..."
            log_info "Waiting ${POST_UPDATE_WAIT_SECONDS}s for services to stabilize after restart..."
            sleep "$POST_UPDATE_WAIT_SECONDS"
            if ./health.sh --quiet; then
                log_success "Post-update health check passed"
                post_health_result=0
            else
                log_error "Post-update health check failed — attempting automatic rollback"
                rollback_attempted=true
                if attempt_rollback; then
                    rollback_result=0
                fi
            fi
        fi
    fi

    # -----------------------------------------------------------------------
    # Phase 4: Summary and cleanup
    # -----------------------------------------------------------------------
    log_info "=== Phase 4: Update Summary ==="

    generate_update_summary \
        "$pre_health_result" \
        "$system_update_result" \
        "$container_update_result" \
        "$restart_result" \
        "$post_health_result" \
        "$rollback_attempted" \
        "$rollback_result"

    if [[ "$container_update_result" == "0" && "$restart_result" == "0" && \
          "$post_health_result" == "0" ]]; then
        log_success "Update completed successfully"
        exit 0
    elif [[ "$container_update_result" == "0" && "$restart_result" == "0" ]]; then
        log_warn "Update completed but health check shows issues (exit 2)"
        exit 2
    else
        log_error "Update completed with critical failures"
        exit 1
    fi
}

main "$@"
