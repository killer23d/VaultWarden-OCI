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
    cat <<'EOF'
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
EOF
}

[[ "${1:-}" == "run" ]] && shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --comprehensive)   COMPREHENSIVE=true; UPDATE_FIREWALL=true; UPDATE_DNS=true; shift ;;
        --no-logs)         CLEAN_LOGS=false;        shift ;;
        --no-backups)      CLEAN_BACKUPS=false;     shift ;;
        --no-docker)       CLEAN_DOCKER=false;      shift ;;
        --no-database)     OPTIMIZE_DATABASE=false; shift ;;
        --update-dns)      UPDATE_DNS=true;         shift ;;
        --update-firewall) UPDATE_FIREWALL=true;    shift ;;
        --dry-run)         DRY_RUN=true;            shift ;;
        --email)           EMAIL_NOTIFY=true;       shift ;;
        --help|-h|help)    show_help; exit 0 ;;
        --version|-V)      print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0 ;;
        *) log_error "Unknown option for 'run': $1"; show_help; exit 1 ;;
    esac
done

main() {
    require_root

    operation_acquire \
        --id maintenance \
        --label "Maintenance" \
        --specific-lock /run/lock/vaultwarden-maintenance.lock \
        --non-interactive skip || exit $?
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
    start_epoch=$(date +%s)

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
    if cleanup_docker_system; then
        docker_cleanup_result=0
    else
        docker_cleanup_result=$?
    fi

    operation_set_phase "2" "Database optimization"
    log_header "Phase 2/4 — Database optimization"
    optimize_database || db_optimization_result=$?

    if [[ "$UPDATE_FIREWALL" == "true" || "$UPDATE_DNS" == "true" ]]; then
        operation_set_phase "3" "Security and network maintenance"
        log_header "Phase 3/4 — Security and network maintenance"
        if [[ "$UPDATE_FIREWALL" == "true" ]]; then
            local firewall_args=("${PROJECT_ROOT}/utilities/maintenance-update-firewall.sh" update-firewall)
            [[ "$DRY_RUN" == "true" ]] && firewall_args+=(--dry-run)
            "${firewall_args[@]}" && firewall_update_result=0 || firewall_update_result=$?
        fi
        if [[ "$UPDATE_DNS" == "true" ]]; then
            local dns_args=("${PROJECT_ROOT}/utilities/maintenance-update-dns.sh" update-dns)
            [[ "$EMAIL_NOTIFY" == "true" ]] && dns_args+=(--email)
            [[ "$DRY_RUN" == "true" ]] && dns_args+=(--dry-run)
            "${dns_args[@]}" && dns_update_result=0 || dns_update_result=$?
        fi
    fi

    operation_set_phase "4" "Health validation"
    log_header "Phase 4/4 — Health validation"
    validate_system_health || health_validation_result=$?

    local duration_seconds=$(( $(date +%s) - start_epoch ))
    local maintenance_result=0
    log_header "Maintenance Summary"
    generate_maintenance_summary \
        "$log_cleanup_result" "$backup_cleanup_result" "$docker_cleanup_result" \
        "$db_optimization_result" "$firewall_update_result" "$dns_update_result" \
        "$health_validation_result" "$recovery_cleanup_result" "$duration_seconds" \
        || maintenance_result=$?

    case "$maintenance_result" in
        0) log_success "Maintenance completed without real failures" ;;
        1) log_warn "Maintenance completed with one real failure" ;;
        *) log_error "Maintenance completed with multiple real failures" ;;
    esac
    exit "$maintenance_result"
}

main "$@"
