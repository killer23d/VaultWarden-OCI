#!/usr/bin/env bash
# utilities/maintenance-run.sh — Runs routine VaultWarden maintenance tasks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "$PROJECT_ROOT/lib/log.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/common.sh"
init_common_lib "$0"
source "$PROJECT_ROOT/lib/operations.sh"
source "$PROJECT_ROOT/lib/email.sh"
DOCKER_PROJECT_LABEL="${DOCKER_PROJECT_LABEL:-label=com.docker.compose.project=vaultwarden-oci}"
source "$PROJECT_ROOT/lib/docker.sh"
source "$PROJECT_ROOT/lib/backup-utils.sh"
source "$PROJECT_ROOT/lib/crypto.sh"
source "$PROJECT_ROOT/lib/secrets.sh"
source "$PROJECT_ROOT/lib/storage.sh"
source "$PROJECT_ROOT/lib/maintenance-utils.sh"

CLEAN_LOGS=true
CLEAN_BACKUPS=true
CLEAN_DOCKER=true
OPTIMIZE_DATABASE=true
UPDATE_FIREWALL=false
UPDATE_DNS=false
DRY_RUN=false
EMAIL_NOTIFY=false
COMPREHENSIVE=false
TARGETED_MODE=false
LOG_RETENTION_DAYS=30
DB_BACKUP_RETENTION_DAYS=14
FULL_BACKUP_RETENTION_DAYS=30
EMERGENCY_BACKUP_RETENTION_DAYS=90
: "${LOG_RETENTION_DAYS}" "${DB_BACKUP_RETENTION_DAYS}" "${FULL_BACKUP_RETENTION_DAYS}" "${EMERGENCY_BACKUP_RETENTION_DAYS}"

show_help() {
    cat <<'EOF_HELP'
VaultWarden-OCI Routine Maintenance Runner

USAGE:
    sudo utilities/maintenance-run.sh [OPTIONS]
    sudo ./maintenance.sh run [OPTIONS]

DESCRIPTION:
    Performs routine maintenance: log cleanup, old backup pruning, Docker
    system cleanup, expired plaintext recovery-kit fallback cleanup, online
    SQLite optimization, and quick post-maintenance health validation.

OPTIONS:
    --comprehensive         Run everything: routine + firewall + DNS
    --no-logs               Skip log rotation and cleanup
    --no-backups            Skip backup cleanup
    --no-docker             Skip Docker cleanup
    --no-database           Skip routine online database optimization
    --update-dns            Include DNS update in this run
    --update-firewall       Include firewall update in this run
    --dry-run               Show what would be done without executing
    --email                 Send email notification on completion
    --help, -h              Show this help
    --version, -V           Print the VaultWarden-OCI version and exit

EXIT CODES:
    0 — completed without real failures; may include warnings or expected skips
    1 — completed with one real failure
    2 — completed with multiple real failures

EXAMPLES:
    sudo ./maintenance.sh run
    sudo ./maintenance.sh run --comprehensive
    sudo ./maintenance.sh run --dry-run
    sudo ./maintenance.sh run --email
EOF_HELP
}

# Routine maintenance keeps Vaultwarden online. Deep offline work remains owned
# by utilities/maintenance-db-maint.sh.
optimize_database() {
    if [[ "${OPTIMIZE_DATABASE:-true}" != "true" ]]; then
        log_info "Skipping database optimization"
        return 0
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would run PRAGMA optimize and PRAGMA wal_checkpoint(PASSIVE)"
        return 0
    fi

    local state_dir db_file page_count freelist_count page_size
    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    db_file="$state_dir/data/db.sqlite3"
    if [[ ! -f "$db_file" ]]; then
        log_error "Database file not found: $db_file"
        return 1
    fi
    if ! command -v sqlite3 >/dev/null 2>&1; then
        log_error "sqlite3 is required for routine database optimization"
        return 1
    fi

    log_info "Running online SQLite routine maintenance..."
    page_count="$(sqlite3 "$db_file" 'PRAGMA page_count;' 2>/dev/null || true)"
    freelist_count="$(sqlite3 "$db_file" 'PRAGMA freelist_count;' 2>/dev/null || true)"
    page_size="$(sqlite3 "$db_file" 'PRAGMA page_size;' 2>/dev/null || true)"
    if [[ -n "$page_count" && -n "$freelist_count" && -n "$page_size" ]]; then
        log_info "SQLite pages: total=${page_count}, free=${freelist_count}, page_size=${page_size} bytes"
    fi

    if ! sqlite3 "$db_file" 'PRAGMA optimize;' >/dev/null 2>&1; then
        log_error "PRAGMA optimize failed"
        return 1
    fi
    if ! sqlite3 "$db_file" 'PRAGMA wal_checkpoint(PASSIVE);' >/dev/null 2>&1; then
        log_error "PRAGMA wal_checkpoint(PASSIVE) failed"
        return 1
    fi
    log_success "Online SQLite routine maintenance completed"
}

validate_system_health() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would run quick post-maintenance health validation"
        return 0
    fi

    local rc=0
    log_info "Validating system health after maintenance..."
    log_info "Invoking: VAULTWARDEN_INTERNAL_HEALTH_CHECK=true ${PROJECT_ROOT}/utilities/maintenance-health.sh --quick --quiet"
    VAULTWARDEN_INTERNAL_HEALTH_CHECK=true \
        "${PROJECT_ROOT}/utilities/maintenance-health.sh" --quick --quiet || rc=$?

    case "$rc" in
        0)  log_success "System health validation passed" ;;
        1)  log_warn "System health validation passed with advisory warnings" ;;
        75) log_warn "System health validation skipped because another health check is active" ;;
        2|3|4) log_error "System health validation failed with status ${rc}" ;;
        *)  log_error "System health validation returned unexpected status ${rc}" ;;
    esac
    return "$rc"
}

_health_summary_line() {
    case "$1" in
        0)  printf '  ✅ Health validation: Passed\n' ;;
        1)  printf '  ⚠️  Health validation: Passed with advisory warnings\n' ;;
        75) printf '  ⏭️  Health validation: Skipped (another health execution was active)\n' ;;
        2|3|4) printf '  ❌ Health validation: Failed (status %s)\n' "$1" ;;
        *)  printf '  ❌ Health validation: Failed (unexpected status %s)\n' "$1" ;;
    esac
}

generate_maintenance_summary() {
    local log_cleanup="$1" backup_cleanup="$2" docker_cleanup="$3"
    local db_optimization="$4" firewall_update="$5" dns_update="$6" health_validation="$7"
    local duration_seconds="${8:-}"
    local summary critical_failures=0 operation_skips=0

    summary="VaultWarden Maintenance Summary - $(date)\n\nMaintenance Results:\n"
    if [[ "$CLEAN_LOGS" == "true" ]]; then
        [[ "$log_cleanup" == 0 ]] && summary+="  ✅ Log cleanup: OK\n" || summary+="  ❌ Log cleanup: Failed\n"
    else
        summary+="  ⏭️  Log cleanup: Skipped\n"
    fi
    if [[ "$CLEAN_BACKUPS" == "true" ]]; then
        [[ "$backup_cleanup" == 0 ]] && summary+="  ✅ Backup cleanup: OK\n" || summary+="  ❌ Backup cleanup: Failed\n"
    else
        summary+="  ⏭️  Backup cleanup: Skipped\n"
    fi
    if [[ "$CLEAN_DOCKER" == "true" ]]; then
        case "$docker_cleanup" in
            0) summary+="  ✅ Docker cleanup: OK\n" ;;
            1) summary+="  ⚠️  Docker cleanup: Issues\n" ;;
            *) summary+="  ❌ Docker cleanup: Failed\n" ;;
        esac
    else
        summary+="  ⏭️  Docker cleanup: Skipped\n"
    fi
    if [[ "$OPTIMIZE_DATABASE" == "true" ]]; then
        [[ "$db_optimization" == 0 ]] && summary+="  ✅ DB optimization: OK\n" || summary+="  ❌ DB optimization: Failed\n"
    else
        summary+="  ⏭️  DB optimization: Skipped\n"
    fi
    if [[ "$UPDATE_FIREWALL" == "true" ]]; then
        case "$firewall_update" in
            0) summary+="  ✅ Firewall update: OK\n" ;;
            75) summary+="  ⏭️  Firewall update: Skipped (active operation)\n" ;;
            *) summary+="  ❌ Firewall update: Failed\n" ;;
        esac
    else
        summary+="  ⏭️  Firewall update: Skipped\n"
    fi
    if [[ "$UPDATE_DNS" == "true" ]]; then
        case "$dns_update" in
            0) summary+="  ✅ DNS update: OK\n" ;;
            75) summary+="  ⏭️  DNS update: Skipped (active operation)\n" ;;
            *) summary+="  ❌ DNS update: Failed\n" ;;
        esac
    else
        summary+="  ⏭️  DNS update: Skipped\n"
    fi
    summary+="$(_health_summary_line "$health_validation")"

    [[ "$CLEAN_LOGS" == "true" && "$log_cleanup" != 0 ]] && ((++critical_failures))
    [[ "$CLEAN_BACKUPS" == "true" && "$backup_cleanup" != 0 ]] && ((++critical_failures))
    [[ "$CLEAN_DOCKER" == "true" && "$docker_cleanup" == 2 ]] && ((++critical_failures))
    [[ "$OPTIMIZE_DATABASE" == "true" && "$db_optimization" != 0 ]] && ((++critical_failures))
    [[ "$UPDATE_FIREWALL" == "true" && "$firewall_update" != 0 && "$firewall_update" != 75 ]] && ((++critical_failures))
    [[ "$UPDATE_DNS" == "true" && "$dns_update" != 0 && "$dns_update" != 75 ]] && ((++critical_failures))
    case "$health_validation" in 0|1|75) ;; *) ((++critical_failures)) ;; esac

    [[ "$UPDATE_FIREWALL" == "true" && "$firewall_update" == 75 ]] && ((++operation_skips))
    [[ "$UPDATE_DNS" == "true" && "$dns_update" == 75 ]] && ((++operation_skips))
    [[ "$health_validation" == 75 ]] && ((++operation_skips))

    if [[ -n "$duration_seconds" && "$duration_seconds" =~ ^[0-9]+$ ]]; then
        summary+="\nDuration: $(_format_duration "$duration_seconds")\n"
    fi
    if (( critical_failures == 0 && operation_skips == 0 )); then
        summary+="🎉 Overall Status: SUCCESS\n"
    elif (( critical_failures == 0 )); then
        summary+="⏭️  Overall Status: COMPLETED WITH SKIPS\n"
    else
        summary+="⚠️  Overall Status: COMPLETED WITH ISSUES\n"
    fi

    printf '%b' "$summary"
    if [[ "$EMAIL_NOTIFY" == "true" ]]; then
        local subject email_body
        if (( critical_failures == 0 && operation_skips == 0 )); then
            subject="VaultWarden Maintenance: SUCCESS"
        elif (( critical_failures == 0 )); then
            subject="VaultWarden Maintenance: COMPLETED WITH SKIPS"
        else
            subject="VaultWarden Maintenance: ISSUES DETECTED"
        fi
        email_body="$(printf '%b' "$summary")"
        send_notification_email "$subject" "$email_body" \
            && log_info "Summary emailed" \
            || log_warn "Failed to send summary email"
    fi
}

[[ "${1:-}" == "run" ]] && shift
while [[ $# -gt 0 ]]; do
    case $1 in
        --comprehensive) COMPREHENSIVE=true; UPDATE_FIREWALL=true; UPDATE_DNS=true; shift ;;
        --no-logs) CLEAN_LOGS=false; shift ;;
        --no-backups) CLEAN_BACKUPS=false; shift ;;
        --no-docker) CLEAN_DOCKER=false; shift ;;
        --no-database) OPTIMIZE_DATABASE=false; shift ;;
        --update-dns) UPDATE_DNS=true; shift ;;
        --update-firewall) UPDATE_FIREWALL=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --email) EMAIL_NOTIFY=true; shift ;;
        --help|-h|help) show_help; exit 0 ;;
        --version|-V) print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0 ;;
        *) log_error "Unknown option for 'run': $1"; show_help; exit 1 ;;
    esac
done

main() {
    require_root
    operation_acquire --id maintenance --label "Maintenance" \
        --specific-lock /run/lock/vaultwarden-maintenance.lock --non-interactive skip || exit $?
    _cleanup_locks() {
        local rc=$?
        operation_release "$rc"
        perform_cleanup
        return "$rc"
    }
    trap _cleanup_locks EXIT
    trap 'operation_release 130; perform_cleanup; exit 130' INT
    trap 'operation_release 143; perform_cleanup; exit 143' HUP TERM

    log_header "VaultWarden-OCI Maintenance Manager"
    [[ "$DRY_RUN" == "true" ]] && log_warn "DRY RUN MODE - No changes will be made"
    [[ "$COMPREHENSIVE" == "true" ]] && log_info "Running comprehensive maintenance..."

    local start_epoch
    start_epoch="$(date +%s)"
    load_project_environment || exit 1
    auto_fix_critical_permissions "$PROJECT_ROOT"
    require_project_state_ready || exit 1

    local log_cleanup_result=0 backup_cleanup_result=0 docker_cleanup_result=0
    local recovery_cleanup_result=0 db_optimization_result=0
    local firewall_update_result=1 dns_update_result=1 health_validation_result=0

    operation_set_phase "1" "System cleanup"
    log_header "Phase 1/4 — System cleanup"
    cleanup_logs || log_cleanup_result=$?
    cleanup_backups || backup_cleanup_result=$?
    cleanup_expired_recovery_kits "$DRY_RUN" || recovery_cleanup_result=$?
    cleanup_docker_system || docker_cleanup_result=$?

    operation_set_phase "2" "Database optimization"
    log_header "Phase 2/4 — Database optimization"
    optimize_database || db_optimization_result=$?

    if [[ "$UPDATE_FIREWALL" == "true" || "$UPDATE_DNS" == "true" ]]; then
        operation_set_phase "3" "Security and network maintenance"
        log_header "Phase 3/4 — Security and network maintenance"
        if [[ "$UPDATE_FIREWALL" == "true" ]]; then
            local fw_args=("${PROJECT_ROOT}/utilities/maintenance-update-firewall.sh" update-firewall)
            [[ "$DRY_RUN" == "true" ]] && fw_args+=(--dry-run)
            if "${fw_args[@]}"; then
                firewall_update_result=0
            else
                firewall_update_result=$?
            fi
        fi
        if [[ "$UPDATE_DNS" == "true" ]]; then
            local dns_args=("${PROJECT_ROOT}/utilities/maintenance-update-dns.sh" update-dns)
            [[ "$EMAIL_NOTIFY" == "true" ]] && dns_args+=(--email)
            [[ "$DRY_RUN" == "true" ]] && dns_args+=(--dry-run)
            if "${dns_args[@]}"; then
                dns_update_result=0
            else
                dns_update_result=$?
            fi
        fi
    fi

    operation_set_phase "4" "Health validation"
    log_header "Phase 4/4 — Health validation"
    validate_system_health || health_validation_result=$?

    local duration_seconds=$(( $(date +%s) - start_epoch ))
    log_header "Maintenance Summary"
    if [[ "$recovery_cleanup_result" == 0 ]]; then
        log_success "Recovery-kit fallback cleanup: completed"
    else
        log_error "Recovery-kit fallback cleanup: issues require operator review"
    fi
    generate_maintenance_summary \
        "$log_cleanup_result" "$backup_cleanup_result" "$docker_cleanup_result" \
        "$db_optimization_result" "$firewall_update_result" "$dns_update_result" \
        "$health_validation_result" "$duration_seconds"

    local critical_failures=0 operation_skips=0
    [[ "$recovery_cleanup_result" != 0 ]] && ((++critical_failures))
    [[ "$CLEAN_LOGS" == "true" && "$log_cleanup_result" != 0 ]] && ((++critical_failures))
    [[ "$CLEAN_BACKUPS" == "true" && "$backup_cleanup_result" != 0 ]] && ((++critical_failures))
    [[ "$CLEAN_DOCKER" == "true" && "$docker_cleanup_result" == 2 ]] && ((++critical_failures))
    [[ "$OPTIMIZE_DATABASE" == "true" && "$db_optimization_result" != 0 ]] && ((++critical_failures))
    [[ "$UPDATE_FIREWALL" == "true" && "$firewall_update_result" != 0 && "$firewall_update_result" != 75 ]] && ((++critical_failures))
    [[ "$UPDATE_DNS" == "true" && "$dns_update_result" != 0 && "$dns_update_result" != 75 ]] && ((++critical_failures))
    case "$health_validation_result" in 0|1|75) ;; *) ((++critical_failures)) ;; esac

    [[ "$UPDATE_FIREWALL" == "true" && "$firewall_update_result" == 75 ]] && ((++operation_skips))
    [[ "$UPDATE_DNS" == "true" && "$dns_update_result" == 75 ]] && ((++operation_skips))
    [[ "$health_validation_result" == 75 ]] && ((++operation_skips))

    if (( critical_failures == 0 && operation_skips == 0 )); then
        log_success "Maintenance completed successfully"
        exit 0
    elif (( critical_failures == 0 )); then
        log_warn "Maintenance completed with skipped work"
        exit 0
    elif (( critical_failures == 1 )); then
        log_warn "Maintenance completed with minor issues"
        exit 1
    else
        log_error "Maintenance completed with critical failures"
        exit 2
    fi
}

main "$@"
