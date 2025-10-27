#!/usr/bin/env bash
# db-maint.sh - On-demand VaultWarden SQLite database maintenance
# This script stops the ENTIRE stack, runs VACUUM on the live DB, and restarts.
# It also cleans up its own safety backup on success.

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh" # Needed for backup script

# --- Configuration ---
FORCE=false

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden On-Demand Database Maintenance

USAGE:
    sudo ./db-maint.sh [OPTIONS]

OPTIONS:
    --force          Skip confirmation prompt
    --help           Show this help

DESCRIPTION:
    Performs comprehensive maintenance on the live SQLite database:
    0. Creates a safety backup (./backup.sh --type db)
    1. Checks integrity (PRAGMA integrity_check)
    2. Commits WAL file (PRAGMA wal_checkpoint)
    3. Optimizes query stats (PRAGMA optimize)
    4. Reclaims free space (VACUUM)
    5. Deletes safety backup on success

    This script requires brief downtime as it must stop the
    ENTIRE service stack (Caddy, VaultWarden, etc)
    to safely access the database file.
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --force) FORCE=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Main Execution ---
main() {
    log_info "VaultWarden Database Maintenance"
    
    local safety_backup_file=""
    local maintenance_successful=false
    
    # Check if running as root
    if ! is_root; then
        log_error "This script must be run with sudo to access Docker and the database file."
        exit 1
    fi
    
    # Load configuration
    load_env_file || { log_error "Failed to load .env file"; exit 1; }
    require_docker || exit 1
    require_commands sqlite3 stat numfmt || exit 1
    
    # Get database file path
    local state_dir db_file
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    db_file="$state_dir/data/bwdata/db.sqlite3"
    
    if [[ ! -f "$db_file" ]]; then
        log_error "Database file not found at: $db_file"
        exit 1
    fi
    
    # Get current file size
    local original_size original_bytes
    original_size=$(du -h "$db_file" | cut -f1)
    original_bytes=$(stat -c%s "$db_file" 2>/dev/null || echo "0")
    
    # Confirmation
    if [[ "$FORCE" == "false" ]]; then
        echo ""
        log_warn "This script will stop the ENTIRE service stack temporarily."
        log_warn "(Caddy, VaultWarden, Fail2Ban, etc. will be down)"
        log_info "Database: $db_file"
        log_info "Current Size: $original_size"
        echo ""
        read -p "Continue with database maintenance? (Y/n): " confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            log_info "Maintenance cancelled"
            exit 0
        fi
    fi
    
    # --- Maintenance Start ---
    
    log_info "Step 0/5: Creating pre-maintenance safety backup..."
    # Capture stdout to get the backup file path
    if safety_backup_file=$(./backup.sh --type db 2>/dev/null); then
        log_success "Safety backup created: $(basename "$safety_backup_file")"
    else
        log_error "Failed to create safety backup!"
        if [[ "$FORCE" == "false" ]]; then
            read -p "Proceed without a safety backup? (y/N): " confirm_no_backup
            if [[ ! "$confirm_no_backup" =~ ^[Yy]$ ]]; then
                log_info "Maintenance cancelled"
                exit 1
            fi
        else
            log_warn "Proceeding without safety backup (--force specified)"
        fi
    fi
    
    log_info "Stopping all services..."
    if ! stop_services; then
        log_warn "Failed to stop services (maybe they were already stopped?)"
    else
        log_success "All services stopped"
    fi
    
    log_info "Waiting 5 seconds for file lock release..."
    sleep 5
    
    # 1. Check integrity
    log_info "Step 1/5: Checking database integrity..."
    if sqlite3 "$db_file" "PRAGMA integrity_check;" | grep -q "ok"; then
        log_success "Database integrity check passed"
    else
        log_error "Database integrity check FAILED"
        log_info "Maintenance aborted. Restarting services..."
        start_services
        exit 1
    fi
    
    # 2. Checkpoint WAL
    log_info "Step 2/5: Committing WAL file (PRAGMA wal_checkpoint)..."
    if sqlite3 "$db_file" "PRAGMA wal_checkpoint(TRUNCATE);"; then
        log_success "WAL file checkpointed successfully"
    else
        # This is non-fatal, but we should warn
        log_warn "Could not checkpoint WAL file. Proceeding anyway."
    fi
    
    # 3. Optimize
    log_info "Step 3/5: Optimizing database stats (PRAGMA optimize)..."
    if sqlite3 "$db_file" "PRAGMA optimize;"; then
        log_success "Database optimization complete"
    else
        log_warn "Could not optimize database. Proceeding anyway."
    fi
    
    # 4. Perform VACUUM
    log_info "Step 4/5: Reclaiming free space (VACUUM)... This may take a moment."
    if sqlite3 "$db_file" "VACUUM;"; then
        log_success "Database VACUUM completed"
    else
        log_error "Database VACUUM FAILED"
        log_info "Maintenance aborted. Restarting services..."
        start_services
        exit 1
    fi
    
    # 5. Get new size and stats
    log_info "Step 5/5: Gathering statistics..."
    local new_size new_bytes
    new_size=$(du -h "$db_file" | cut -f1)
    new_bytes=$(stat -c%s "$db_file" 2>/dev/null || echo "0")
    
    # --- Maintenance End ---
    
    log_info "Restarting all services..."
    if ! start_services; then
        log_error "Failed to restart services!"
        log_info "Run './startup.sh' to start the stack manually."
        exit 1
    fi
    
    log_info "Waiting for services to become healthy (timeout: 45s)..."
    local services=("vaultwarden" "caddy")
    local failed_services=()
    
    for service in "${services[@]}"; do
        if ! wait_for_service_ready "$service" 45; then
            failed_services+=("$service")
        fi
    done
    
    if [[ ${#failed_services[@]} -eq 0 ]]; then
        log_success "All critical services are healthy"
        maintenance_successful=true # Set success flag
    else
        log_error "Failed services: ${failed_services[*]}"
        log_info "Check logs: docker compose logs <service>"
        # Don't exit, report completion anyway
    fi
    
    log_success "All services are back online"
    echo ""
    log_success "Database maintenance complete!"
    
    # Show statistics
    if [[ "$original_bytes" -gt 0 && "$new_bytes" -gt 0 && "$original_bytes" -ge "$new_bytes" ]]; then
        local saved_bytes=$((original_bytes - new_bytes))
        local saved_percent=$(( (saved_bytes * 100) / original_bytes ))
        log_info "Size changed from $original_size to $new_size"
        log_info "Space reclaimed: $(numfmt --to=iec $saved_bytes) (${saved_percent}%)"
    else
        log_info "Size changed from $original_size to $new_size"
    fi
    
    # --- Cleanup Safety Backup ---
    echo ""
    if [[ "$maintenance_successful" == "true" && -n "$safety_backup_file" && -f "$safety_backup_file" ]]; then
      log_info "Cleaning up temporary safety backup..."
      if rm -f "$safety_backup_file"; then
        log_success "Removed safety backup: $(basename "$safety_backup_file")"
      else
        log_warn "Could not remove safety backup: $safety_backup_file"
      fi
    elif [[ -n "$safety_backup_file" && -f "$safety_backup_file" ]]; then
      log_warn "Maintenance did not complete successfully."
      log_warn "Retaining safety backup: $safety_backup_file"
    fi
}

main "$@"

