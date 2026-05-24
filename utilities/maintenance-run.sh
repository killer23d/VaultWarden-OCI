#!/usr/bin/env bash
# utilities/maintenance-run.sh — VaultWarden routine maintenance runner
#
# Standalone entry point for the 'run' subcommand.
# Invoked directly by:
#   - maintenance.sh run [OPTIONS]  (thin dispatcher)
#   - systemd/vaultwarden-maintenance.service
#
# EXIT CODES:
#   0 — maintenance completed successfully
#   1 — maintenance completed with minor issues
#   2 — maintenance completed with critical failures

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_SAVE_SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/email.sh"
init_common_lib "$0"
source "$PROJECT_ROOT/lib/docker.sh"
source "$PROJECT_ROOT/lib/backup-utils.sh"
source "$PROJECT_ROOT/lib/crypto.sh"
_MAINT_SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/secrets.sh"
SCRIPT_DIR="$_MAINT_SCRIPT_DIR"
unset _MAINT_SCRIPT_DIR
source "$PROJECT_ROOT/lib/storage.sh"
source "$PROJECT_ROOT/lib/maintenance-utils.sh"

# ---------------------------------------------------------------------------
# Configuration defaults (mirrors maintenance.sh)
# ---------------------------------------------------------------------------
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

show_help() {
    cat << 'EOF'
VaultWarden-OCI Routine Maintenance Runner

USAGE:
    sudo utilities/maintenance-run.sh [OPTIONS]
    sudo ./maintenance.sh run [OPTIONS]

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

EXIT CODES:
    0 — completed successfully
    1 — completed with minor issues
    2 — completed with critical failures
EOF
}

# ---------------------------------------------------------------------------
# _load_env
# ---------------------------------------------------------------------------
_load_env() {
    if load_env_file 2>/dev/null; then return 0; fi
    log_warn "No .env file found — relying on environment already set (e.g. systemd EnvironmentFile)"
    return 0
}

# ---------------------------------------------------------------------------
# Argument parsing & main
# ---------------------------------------------------------------------------
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
        *) log_error "Unknown option for 'run': $1"; show_help; exit 1 ;;
    esac
done

main() {
    require_root
    auto_fix_critical_permissions "$PROJECT_ROOT"
    local OPS_LOCK="/run/lock/vaultwarden-operations.lock"
    local _OPS_LOCK_FD
    local lock_user lock_group
    lock_user="${SERVICE_USER:-${BACKUP_USER:-ubuntu}}"
    lock_group=$(id -gn "$lock_user" 2>/dev/null || echo "$lock_user")
    if [[ -e "$OPS_LOCK" ]]; then
        chown "${lock_user}:${lock_group}" "$OPS_LOCK" 2>/dev/null || true
        chmod 0660 "$OPS_LOCK" 2>/dev/null || true
    else
        install -m 0660 -o "$lock_user" -g "$lock_group" /dev/null "$OPS_LOCK" 2>/dev/null || true
    fi
    exec {_OPS_LOCK_FD}>"$OPS_LOCK"
    if ! flock -n "$_OPS_LOCK_FD"; then
        log_error "Another operation (update/restore/maintenance) is already running. Aborting."
        exit 1
    fi
    touch /tmp/.vw_maintenance.lock
    register_cleanup rm -f /tmp/.vw_maintenance.lock
    trap 'perform_cleanup' EXIT HUP INT TERM

    log_header "VaultWarden-OCI Maintenance Manager"
    [[ "$DRY_RUN"      == "true" ]] && log_warn "DRY RUN MODE - No changes will be made"
    [[ "$COMPREHENSIVE" == "true" ]] && log_info "Running comprehensive maintenance..."

    _load_env
    auto_fix_critical_permissions "$PROJECT_ROOT"
    require_project_state_ready || exit 1

    local log_cleanup_result=0 backup_cleanup_result=0 docker_cleanup_result=0
    local db_optimization_result=0 firewall_update_result=1 dns_update_result=1
    local health_validation_result=0

    log_info "=== Phase 1: System Cleanup ==="
    cleanup_logs    || log_cleanup_result=$?
    cleanup_backups || backup_cleanup_result=$?
    if cleanup_docker_system; then
        docker_cleanup_result=0
    else
        docker_cleanup_result=$?
    fi

    log_info "=== Phase 2: SAFE System Optimization ==="
    optimize_database || db_optimization_result=$?

    if [[ "$UPDATE_FIREWALL" == "true" || "$UPDATE_DNS" == "true" ]]; then
        log_info "=== Phase 3: SAFE Security & Network Maintenance ==="
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

    log_info "=== Phase 4: Health Validation ==="
    validate_system_health || health_validation_result=$?

    log_info "=== Summary ==="
    generate_maintenance_summary \
        "$log_cleanup_result" "$backup_cleanup_result" "$docker_cleanup_result" \
        "$db_optimization_result" "$firewall_update_result" "$dns_update_result" \
        "$health_validation_result"

    local critical_failures=0
    [[ "$CLEAN_LOGS"        == "true"  && "$log_cleanup_result"       != "0" ]] && ((critical_failures++))
    [[ "$CLEAN_BACKUPS"     == "true"  && "$backup_cleanup_result"    != "0" ]] && ((critical_failures++))
    [[ "$CLEAN_DOCKER"      == "true"  && "$docker_cleanup_result"    == "2" ]] && ((critical_failures++))
    [[ "$OPTIMIZE_DATABASE" == "true"  && "$db_optimization_result"   != "0" ]] && ((critical_failures++))
    [[ "$UPDATE_FIREWALL"   == "true"  && "$firewall_update_result"   != "0" ]] && ((critical_failures++))
    [[ "$UPDATE_DNS"        == "true"  && "$dns_update_result"        != "0" ]] && ((critical_failures++))
    [[ "$TARGETED_MODE"     == "false" && "$health_validation_result" != "0" ]] && ((critical_failures++))

    if [[ $critical_failures -eq 0 ]]; then
        log_success "Maintenance completed successfully"; exit 0
    elif [[ $critical_failures -eq 1 ]]; then
        log_warn "Maintenance completed with minor issues"; exit 1
    else
        log_error "Maintenance completed with critical failures"; exit 2
    fi
}

main "$@"
