#!/usr/bin/env bash
# utilities/maintenance-db-maint.sh — VaultWarden deep database maintenance
#
# Standalone entry point for the 'db-maint' subcommand.
# Invoked directly by:
#   - maintenance.sh db-maint [OPTIONS]  (thin dispatcher)
#
# EXIT CODES:
#   0 — deep DB maintenance completed successfully
#   1 — maintenance failed or was cancelled

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
source "$PROJECT_ROOT/lib/maintenance-utils.sh"

# ---------------------------------------------------------------------------
# Configuration defaults
# ---------------------------------------------------------------------------
DB_DEEP_FORCE=false
DRY_RUN=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Deep Database Maintenance

USAGE:
    sudo utilities/maintenance-db-maint.sh [OPTIONS]
    sudo ./maintenance.sh db-maint [OPTIONS]

DESCRIPTION:
    Performs a full offline SQLite VACUUM + WAL checkpoint + integrity check.
    VaultWarden is stopped briefly; a pre-maintenance encrypted backup is
    created automatically via backup.sh.

OPTIONS:
    --force     Skip confirmation prompt
    --dry-run   Preview what would be done without executing
    --help, -h  Show this help

EXIT CODES:
    0 — maintenance completed successfully
    1 — maintenance failed or was cancelled
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
# run_deep_db_maintenance — verbatim from maintenance.sh
# ---------------------------------------------------------------------------
run_deep_db_maintenance() {
    log_info "VaultWarden Deep Database Maintenance"
    local state_dir; state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local db_file="$state_dir/data/db.sqlite3"
    if [[ ! -f "$db_file" ]]; then log_error "Database file not found at: $db_file"; return 1; fi
    local original_size original_bytes
    original_size=$(du -h "$db_file" | cut -f1)
    original_bytes=$(stat -c%s "$db_file" 2>/dev/null || echo "0")
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would perform deep DB maintenance on: $db_file ($original_size)"; return 0
    fi
    is_root          || { log_error "Deep DB maintenance requires sudo."; return 1; }
    require_commands stat numfmt || return 1
    require_docker               || return 1
    if [[ "$DB_DEEP_FORCE" == "false" ]]; then
        echo ""
        log_warn "This will stop the VaultWarden container temporarily. (Caddy stays up)"
        log_info "Database: $db_file  |  Current Size: $original_size"
        echo ""
        read -r -t 30 -p "Continue with deep database maintenance? (Y/n): " confirm || confirm="Y"
        [[ "$confirm" =~ ^[Nn]$ ]] && { log_info "Deep maintenance cancelled"; return 0; }
    fi
    local safety_backup_file=""
    local maintenance_successful=false
    local was_running=false
    if is_service_running "vaultwarden"; then was_running=true; fi
    _deep_db_cleanup() {
        if [[ "$was_running" == "true" ]]; then
            if ! is_service_running "vaultwarden" 2>/dev/null; then
                log_warn "run_deep_db_maintenance: safety net restarting VaultWarden..."
                docker compose up -d vaultwarden 2>&1 || log_error "Safety net restart failed — manual intervention required"
            fi
        fi
    }
    trap '_deep_db_cleanup' RETURN
    log_info "Step 1/6: Creating pre-maintenance safety backup..."
    local backup_ts_marker
    backup_ts_marker=$(mktemp) && touch "$backup_ts_marker"
    log_info "Invoking: $SCRIPT_DIR/backup.sh run db"
    if ! "$SCRIPT_DIR/backup.sh" run db; then
        rm -f "$backup_ts_marker"
        log_error "Pre-maintenance safety backup failed — aborting deep maintenance"
        if [[ "$DB_DEEP_FORCE" == "false" ]]; then
            read -r -t 30 -p "Proceed without a safety backup? (y/N): " confirm_no_backup || confirm_no_backup="n"
            [[ ! "$confirm_no_backup" =~ ^[Yy]$ ]] && { log_info "Maintenance cancelled"; return 1; }
        else
            log_warn "Proceeding without safety backup (--force specified)"
        fi
    else
        log_success "Pre-maintenance safety backup created"
        local backup_base; backup_base=$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")
        safety_backup_file=$(find "${backup_base}/db" -name "vaultwarden-db-*.age" -newer "$backup_ts_marker" 2>/dev/null | sort | tail -1) || true
        rm -f "$backup_ts_marker"
    fi
    log_info "Stopping VaultWarden container..."
    if docker compose stop vaultwarden; then
        log_success "VaultWarden container stopped"
    else
        log_warn "Failed to stop vaultwarden container"
    fi
    log_info "Waiting for WAL to quiesce before maintenance..."
    _wait_wal_quiesce "$db_file" 30
    log_info "Step 2/6: Checking database integrity..."
    if ! sqlite3 "$db_file" "PRAGMA integrity_check;" | grep -q "ok"; then
        log_error "Integrity check FAILED. Aborting. Restarting services..."
        docker compose up -d vaultwarden; return 1
    fi
    log_success "Database integrity check passed"
    log_info "Step 3/6: Committing WAL file (PRAGMA wal_checkpoint(TRUNCATE))..."
    if sqlite3 "$db_file" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1; then
        log_success "WAL checkpointed"
    else
        log_warn "Could not checkpoint WAL. Proceeding."
    fi
    log_info "Step 4/6: Optimizing database stats (PRAGMA optimize)..."
    if sqlite3 "$db_file" "PRAGMA optimize;" >/dev/null 2>&1; then
        log_success "Optimization complete"
    else
        log_warn "Could not optimize. Proceeding."
    fi
    log_info "Step 5/6: Reclaiming free space (VACUUM)... This may take a moment."
    if ! sqlite3 "$db_file" "VACUUM;" >/dev/null 2>&1; then
        log_error "VACUUM FAILED. Aborting. Restarting services..."
        docker compose up -d vaultwarden; return 1
    fi
    log_success "Database VACUUM completed"
    log_info "Step 6/6: Gathering statistics..."
    local new_size new_bytes
    new_size=$(du -h "$db_file" | cut -f1)
    new_bytes=$(stat -c%s "$db_file" 2>/dev/null || echo "0")
    log_info "Restarting VaultWarden container..."
    docker compose up -d vaultwarden || { log_error "Failed to restart VaultWarden!"; return 1; }
    log_info "Waiting for services to become healthy (timeout: 45s)..."
    if wait_for_service_ready "vaultwarden" 45; then
        log_success "All critical services are healthy"
        maintenance_successful=true
    else
        log_error "vaultwarden did not become healthy in time"
        log_info "Check logs: docker compose logs vaultwarden"
    fi
    log_success "VaultWarden is back online"
    echo ""
    log_success "Deep database maintenance complete!"
    if [[ "$original_bytes" -gt 0 && "$new_bytes" -gt 0 && "$original_bytes" -ge "$new_bytes" ]]; then
        local saved_bytes=$((original_bytes - new_bytes))
        local saved_percent=$(( (saved_bytes * 100) / original_bytes ))
        log_info "Size: $original_size → $new_size  (saved $(numfmt --to=iec $saved_bytes), ${saved_percent}%)"
    else
        log_info "Size changed from $original_size to $new_size"
    fi
    echo ""
    if [[ "$maintenance_successful" == "true" && -n "$safety_backup_file" && -f "$safety_backup_file" ]]; then
        log_info "Cleaning up temporary safety backup..."
        local removed_sidecars=0
        for sidecar in "${safety_backup_file}".*; do
            if [[ -f "$sidecar" ]]; then rm -f "$sidecar"; (( removed_sidecars++ )) || true; fi
        done
        if rm -f "$safety_backup_file"; then
            log_success "Removed safety backup: $(basename "$safety_backup_file") (+${removed_sidecars} sidecar(s))"
        else
            log_warn "Could not remove safety backup: $safety_backup_file"
        fi
    elif [[ -n "$safety_backup_file" && -f "$safety_backup_file" ]]; then
        log_warn "Maintenance did not complete successfully. Retaining safety backup: $safety_backup_file"
    fi
    [[ "$maintenance_successful" == "true" ]]
}

# ---------------------------------------------------------------------------
# Argument parsing & main
# ---------------------------------------------------------------------------
[[ "${1:-}" == "db-maint" ]] && shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)       DB_DEEP_FORCE=true; shift ;;
        --dry-run)     DRY_RUN=true;       shift ;;
        --help|-h|help) show_help; exit 0 ;;
        *) log_error "Unknown option for 'db-maint': $1"; show_help; exit 1 ;;
    esac
done

main() {
    require_root
    local OPS_LOCK="/run/lock/vaultwarden-operations.lock"
    local _OPS_LOCK_FD
    exec {_OPS_LOCK_FD}>"$OPS_LOCK"
    if ! flock -n "$_OPS_LOCK_FD"; then
        log_error "Another operation (update/restore/maintenance) is already running. Aborting."
        exit 1
    fi
    touch /tmp/.vw_maintenance.lock
    register_cleanup rm -f /tmp/.vw_maintenance.lock
    _load_env
    run_deep_db_maintenance
    exit $?
}

main "$@"
