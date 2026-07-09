#!/usr/bin/env bash
# utilities/maintenance-run.sh — Runs routine VaultWarden maintenance tasks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_SAVE_SCRIPT_DIR="$PROJECT_ROOT"
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
_MAINT_SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/secrets.sh"
SCRIPT_DIR="$_MAINT_SCRIPT_DIR"
unset _MAINT_SCRIPT_DIR
source "$PROJECT_ROOT/lib/storage.sh"
source "$PROJECT_ROOT/lib/maintenance-utils.sh"

# Configuration defaults mirror maintenance.sh.
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
    system cleanup, and scheduled database optimization. Run automatically
    by the vaultwarden-maintenance systemd timer, or manually on demand.

OPTIONS:
    --comprehensive         Run everything: routine + firewall + DNS
    --no-logs               Skip log rotation and cleanup
    --no-backups            Skip backup cleanup
    --no-docker             Skip Docker cleanup
    --no-database           Skip scheduled database optimization
    --update-dns            Include DNS update in this run
    --update-firewall       Include firewall update in this run
    --dry-run               Show what would be done without executing
    --email                 Send email notification on completion
    --help, -h              Show this help
    --version, -V           Print the VaultWarden-OCI version and exit

EXIT CODES:
    0 — completed successfully
    1 — completed with minor issues
    2 — completed with critical failures

EXAMPLES:
    sudo ./maintenance.sh run
    sudo ./maintenance.sh run --comprehensive
    sudo ./maintenance.sh run --dry-run
    sudo ./maintenance.sh run --email
EOF
}


_load_env() {
    if load_env_file 2>/dev/null; then return 0; fi
    log_warn "No .env file found — relying on environment already set (e.g. systemd EnvironmentFile)"
    return 0
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
    [[ "$DRY_RUN"      == "true" ]] && log_warn "DRY RUN MODE - No changes will be made"
    [[ "$COMPREHENSIVE" == "true" ]] && log_info "Running comprehensive maintenance..."

    # Record start time so the summary can report elapsed duration (issue #37).
    local _MAINT_START_EPOCH
    _MAINT_START_EPOCH=$(date +%s)

    _load_env
    auto_fix_critical_permissions "$PROJECT_ROOT"
    require_project_state_ready || exit 1

    local log_cleanup_result=0 backup_cleanup_result=0 docker_cleanup_result=0
    local db_optimization_result=0 firewall_update_result=1 dns_update_result=1
    local health_validation_result=0

    operation_set_phase "1" "System cleanup"
    log_header "Phase 1/4 — System cleanup"
    cleanup_logs    || log_cleanup_result=$?
    cleanup_backups || backup_cleanup_result=$?
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
            local _fw_args=("${SCRIPT_DIR}/utilities/maintenance-update-firewall.sh" update-firewall)
            [[ "$DRY_RUN" == "true" ]] && _fw_args+=("--dry-run")
            "${_fw_args[@]}" && firewall_update_result=0 || firewall_update_result=$?
        fi
        if [[ "$UPDATE_DNS" == "true" ]]; then
            local _dns_args=("${SCRIPT_DIR}/utilities/maintenance-update-dns.sh" update-dns)
            [[ "$EMAIL_NOTIFY" == "true" ]] && _dns_args+=("--email")
            [[ "$DRY_RUN" == "true" ]]     && _dns_args+=("--dry-run")
            "${_dns_args[@]}" && dns_update_result=0 || dns_update_result=$?
        fi
    fi

    operation_set_phase "4" "Health validation"
    log_header "Phase 4/4 — Health validation"
    validate_system_health || health_validation_result=$?

    # Compute elapsed wall-clock time for the summary footer.
    local _maint_duration_seconds=$(( $(date +%s) - _MAINT_START_EPOCH ))

    log_header "Maintenance Summary"
    generate_maintenance_summary \
        "$log_cleanup_result" "$backup_cleanup_result" "$docker_cleanup_result" \
        "$db_optimization_result" "$firewall_update_result" "$dns_update_result" \
        "$health_validation_result" "$_maint_duration_seconds"

    local critical_failures=0
    [[ "$CLEAN_LOGS"        == "true"  && "$log_cleanup_result"       != "0" ]] && ((critical_failures++))
    [[ "$CLEAN_BACKUPS"     == "true"  && "$backup_cleanup_result"    != "0" ]] && ((critical_failures++))
    [[ "$CLEAN_DOCKER"      == "true"  && "$docker_cleanup_result"    == "2" ]] && ((critical_failures++))
    [[ "$OPTIMIZE_DATABASE" == "true"  && "$db_optimization_result"   != "0" ]] && ((critical_failures++))
    [[ "$UPDATE_FIREWALL"   == "true"  && "$firewall_update_result"   != "0" && "$firewall_update_result" != "75" ]] && ((critical_failures++))
    [[ "$UPDATE_DNS"        == "true"  && "$dns_update_result"        != "0" && "$dns_update_result"      != "75" ]] && ((critical_failures++))
    [[ "$TARGETED_MODE"     == "false" && "$health_validation_result" != "0" ]] && ((critical_failures++))

    local operation_skips=0
    [[ "$UPDATE_FIREWALL" == "true" && "$firewall_update_result" == "75" ]] && ((operation_skips++))
    [[ "$UPDATE_DNS"      == "true" && "$dns_update_result"      == "75" ]] && ((operation_skips++))

    if [[ $critical_failures -eq 0 && $operation_skips -eq 0 ]]; then
        log_success "Maintenance completed successfully"; exit 0
    elif [[ $critical_failures -eq 0 ]]; then
        log_warn "Maintenance completed with skipped work"; exit 0
    elif [[ $critical_failures -eq 1 ]]; then
        log_warn "Maintenance completed with minor issues"; exit 1
    else
        log_error "Maintenance completed with critical failures"; exit 2
    fi
}

main "$@"
