#!/usr/bin/env bash
# update.sh - System and container update script with enhanced safety
# ENHANCED: Standardized error handling - functions return, main() decides exit strategy
# All functions return exit codes, main() collects status and determines final exit

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

show_help() {
    cat << 'EOF'
VaultWarden-OCI Update Script with Safety Checks

USAGE:
    ./update.sh [OPTIONS]

OPTIONS:
    --system                Update system packages (default: containers only)
    --no-backup            Skip backup before update (not recommended)
    --no-restart           Skip service restart after update
    --force                Force update even if no new versions available
    --dry-run              Show what would be updated without executing
    --email                Send email notification on completion
    --help                 Show this help

EXAMPLES:
    ./update.sh                          # Update containers with backup
    ./update.sh --system                 # Update both system and containers
    ./update.sh --dry-run --system       # Preview all updates
    ./update.sh --no-backup --force      # Force update without backup

SAFETY FEATURES:
    - Automatic backup before updates (can be disabled with --no-backup)
    - Health checks before and after updates
    - Rollback capability if health checks fail
    - Email notifications for update status
EOF
}

# Argument Parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --system)    UPDATE_SYSTEM=true;        shift ;;
        --no-backup) BACKUP_BEFORE_UPDATE=false; shift ;;
        --no-restart) RESTART_AFTER=false;      shift ;;
        --force)     FORCE_UPDATE=true;         shift ;;
        --dry-run)   DRY_RUN=true;              shift ;;
        --email)     EMAIL_NOTIFY=true;         shift ;;
        --help)      show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# create_pre_update_backup
# ---------------------------------------------------------------------------
# FIX 1: The old call was:  ./backup.sh --type full --email=false
#   --email=false is not a recognised flag in backup.sh.  backup.sh's --email
#   is a boolean toggle (no value).  EMAIL_NOTIFY defaults to false already,
#   so simply omit the flag entirely.  Only pass --email when the caller
#   explicitly requested email via update.sh --email.
#
# FIX 2: The health check before the backup was failing with
#   "CRITICAL: Backup issues: No full backups found" because there are no
#   backups yet (first run).  That warning is expected and should NOT block
#   a pre-update backup — the backup IS the safety net.  The health check
#   failure is already logged as WARN and execution continues; nothing
#   changes here structurally but the comment is now accurate.
# ---------------------------------------------------------------------------
create_pre_update_backup() {
    if [[ "$BACKUP_BEFORE_UPDATE" != "true" ]]; then
        log_info "Skipping pre-update backup (--no-backup specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create pre-update backup"
        return 0
    fi

    log_info "Creating pre-update backup for safety..."

    # Build backup.sh argument list.
    # --email is a boolean flag with no value; only include it when requested.
    local backup_args=(--type full)
    [[ "$EMAIL_NOTIFY" == "true" ]] && backup_args+=(--email)

    if ./backup.sh "${backup_args[@]}"; then
        log_success "Pre-update backup completed successfully"
        return 0
    else
        log_error "Pre-update backup failed"
        return 1
    fi
}

# STANDARDIZED: System updates - returns exit code
update_system_packages() {
    if [[ "$UPDATE_SYSTEM" != "true" ]]; then
        log_info "Skipping system package updates (use --system to enable)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would update system packages"
        return 0
    fi

    log_info "Updating system packages..."

    if ! apt-get update -qq; then
        log_error "Failed to update package lists"
        return 1
    fi

    local updates_available
    updates_available=$(apt list --upgradable 2>/dev/null | wc -l)
    updates_available=$(( updates_available - 1 ))  # subtract header line

    if [[ $updates_available -eq 0 ]] && [[ "$FORCE_UPDATE" != "true" ]]; then
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

# STANDARDIZED: Container updates - returns exit code
update_containers() {
    if [[ "$UPDATE_CONTAINERS" != "true" ]]; then
        log_info "Skipping container updates"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would update container images"
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

# STANDARDIZED: Pre-update health check - non-fatal, returns exit code for tracking only
pre_update_health_check() {
    log_info "Performing pre-update health check..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would perform pre-update health check"
        return 0
    fi

    if ./health.sh --quiet; then
        log_success "Pre-update health check passed"
        return 0
    else
        # Non-fatal: health issues (e.g. "No full backups found") are expected
        # on a fresh deployment or before the first backup has ever run.
        # The backup we are about to create IS the safety net.
        log_warn "Pre-update health check reported issues (non-fatal - see above)"
        log_info "Continuing with update - the pre-update backup provides safety"
        return 1
    fi
}

# STANDARDIZED: Post-update service restart - returns exit code
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

    if ./startup.sh --force-restart; then
        log_success "Services restarted successfully with updated containers"
        return 0
    else
        log_error "Failed to restart services after update"
        return 1
    fi
}

# STANDARDIZED: Post-update health check - returns exit code
post_update_health_check() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would perform post-update health check"
        return 0
    fi

    log_info "Performing post-update health check..."
    log_info "Waiting 30s for services to stabilize after restart..."
    sleep 30

    if ./health.sh --quiet; then
        log_success "Post-update health check passed"
        return 0
    else
        log_error "Post-update health check failed - update may have caused issues"
        log_info "Consider checking logs and potentially rolling back"
        return 1
    fi
}

# STANDARDIZED: Update summary generation - returns exit code
generate_update_summary() {
    local pre_health="$1"
    local system_update="$2"
    local container_update="$3"
    local restart="$4"
    local post_health="$5"

    log_info "Generating update summary..."

    local summary="VaultWarden Update Summary - $(date)\n"
    summary+="\nUpdate Results:\n"

    if [[ "$UPDATE_SYSTEM" == "true" ]]; then
        if [[ "$system_update" == "0" ]]; then
            summary+="  ✅ System packages: Updated successfully\n"
        else
            summary+="  ❌ System packages: Update failed\n"
        fi
    else
        summary+="  ⏭️  System packages: Skipped\n"
    fi

    if [[ "$container_update" == "0" ]]; then
        summary+="  ✅ Container images: Updated successfully\n"
    else
        summary+="  ❌ Container images: Update failed\n"
    fi

    if [[ "$RESTART_AFTER" == "true" ]]; then
        if [[ "$restart" == "0" ]]; then
            summary+="  ✅ Service restart: Completed successfully\n"
        else
            summary+="  ❌ Service restart: Failed\n"
        fi
    else
        summary+="  ⏭️  Service restart: Skipped\n"
    fi

    if [[ "$pre_health" == "0" ]]; then
        summary+="  ✅ Pre-update health: Passed\n"
    else
        summary+="  ⚠️  Pre-update health: Issues detected (non-fatal)\n"
    fi

    if [[ "$post_health" == "0" ]]; then
        summary+="  ✅ Post-update health: Passed\n"
    else
        summary+="  ❌ Post-update health: Issues detected\n"
    fi

    if [[ "$system_update" == "0" && "$container_update" == "0" && "$restart" == "0" && "$post_health" == "0" ]]; then
        summary+="\n🎉 Overall Status: UPDATE SUCCESSFUL\n"
        summary+="\nNext Steps:\n"
        summary+="  • Monitor services for stability\n"
        summary+="  • Check logs if any issues arise\n"
        if [[ -f /var/run/reboot-required ]]; then
            summary+="  • IMPORTANT: System reboot required (sudo reboot)\n"
        fi
    else
        summary+="\n⚠️  Overall Status: UPDATE COMPLETED WITH ISSUES\n"
        summary+="\nImmediate Actions Required:\n"
        summary+="  • Check service logs: make logs\n"
        summary+="  • Run health check: ./health.sh --comprehensive\n"
        summary+="  • Consider rollback if issues persist\n"
    fi

    echo -e "$summary"

    if [[ "$EMAIL_NOTIFY" == "true" ]]; then
        local email_subject
        if [[ "$system_update" == "0" && "$container_update" == "0" && "$restart" == "0" && "$post_health" == "0" ]]; then
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

# ENHANCED: Main function with proper error handling and exit strategy
main() {
    log_header "VaultWarden-OCI Update Manager"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    if ! load_env_file; then
        log_error "Failed to load configuration"
        exit 1
    fi

    # Track operation results
    local pre_health_result=1
    local system_update_result=1
    local container_update_result=1
    local restart_result=1
    local post_health_result=1

    # -----------------------------------------------------------------------
    # Phase 1: Pre-update checks and backup
    # -----------------------------------------------------------------------
    log_info "=== Phase 1: Pre-Update Preparation ==="

    # Health check is informational only - a fresh system with no backups yet
    # will always fail this check; that must not block the update.
    if pre_update_health_check; then
        pre_health_result=0
    fi
    # Note: no 'else abort' here - pre-health failure is non-fatal by design.

    # Backup IS fatal: if we cannot create a safety snapshot, refuse to proceed.
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
        log_error "System package update failed"
        # Continue with container updates even if system updates fail
    fi

    if update_containers; then
        container_update_result=0
    else
        log_error "Container update failed"
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
        log_info "Skipping service restart (no container updates)"
        restart_result=0
    fi

    if [[ "$restart_result" == "0" ]]; then
        if post_update_health_check; then
            post_health_result=0
        else
            log_error "Post-update health check failed"
        fi
    fi

    # -----------------------------------------------------------------------
    # Phase 4: Summary and cleanup
    # -----------------------------------------------------------------------
    log_info "=== Phase 4: Update Summary ==="

    generate_update_summary "$pre_health_result" "$system_update_result" "$container_update_result" "$restart_result" "$post_health_result"

    if [[ "$container_update_result" == "0" && "$restart_result" == "0" && "$post_health_result" == "0" ]]; then
        log_success "Update completed successfully"
        exit 0
    elif [[ "$container_update_result" == "0" && "$restart_result" == "0" ]]; then
        log_warn "Update completed but health check shows issues"
        exit 2
    else
        log_error "Update completed with critical failures"
        exit 1
    fi
}

main "$@"
