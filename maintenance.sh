#!/usr/bin/env bash
# maintenance.sh - System cleanup, health monitoring, DNS update, and on-demand DB/Email operations

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
init_common_lib "$0"
source "$SCRIPT_DIR/lib/docker.sh"
source "$SCRIPT_DIR/lib/backup-utils.sh"
source "$SCRIPT_DIR/lib/crypto.sh"
# lib/secrets.sh recomputes SCRIPT_DIR (→ lib/) at load time so it can find
# crypto.sh as a sibling; save and restore the project-root SCRIPT_DIR.
_MAINT_SCRIPT_DIR="$SCRIPT_DIR"
source "$SCRIPT_DIR/lib/secrets.sh"
SCRIPT_DIR="$_MAINT_SCRIPT_DIR"
unset _MAINT_SCRIPT_DIR
source "$SCRIPT_DIR/lib/storage.sh"  # provides require_project_state_ready()

# ---------------------------------------------------------------------------
# Configuration defaults
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

# Deep (on-demand) DB maintenance mode
DB_DEEP_MAINT=false
DB_DEEP_FORCE=false

# Email diagnostic mode
TEST_EMAIL=false
TEST_RECIPIENT=""
VERBOSE=false   # Only meaningful with --test-email; ignored by all other modes

# Targeted-mode flag: set to true when ONLY targeted flags are given
# (i.e. --update-dns or --update-firewall alone)
TARGETED_MODE=false

# Retention settings (days)
LOG_RETENTION_DAYS=30
DB_BACKUP_RETENTION_DAYS=14
FULL_BACKUP_RETENTION_DAYS=30
EMERGENCY_BACKUP_RETENTION_DAYS=90

# ---------------------------------------------------------------------------
# _default_backup_dir
# ---------------------------------------------------------------------------
# Thin wrapper that delegates to vw_default_backup_dir() in lib/storage.sh.
# Kept for backward compatibility with callers in this script.
# ---------------------------------------------------------------------------
_default_backup_dir() { vw_default_backup_dir; }

# ---------------------------------------------------------------------------
# _default_alert_state_dir
# ---------------------------------------------------------------------------
# Returns the default directory for alert cooldown state files, derived from
# PROJECT_STATE_DIR.  Mirrors the _default_backup_dir() pattern so that
# alert cooldowns always survive reboots when using separate-volume storage.
#
# Callers use this value only when ALERT_STATE_DIR is absent from the
# environment; an explicit ALERT_STATE_DIR always takes precedence.
# ---------------------------------------------------------------------------
_default_alert_state_dir() {
    local state_dir
    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    printf '%s/.vw-health-alert' "$state_dir"
}

# _default_report_dir
#
# Returns the default directory for health reports, derived from
# PROJECT_STATE_DIR for consistency across storage modes.
_default_report_dir() {
    local state_dir
    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    printf '%s/reports' "$state_dir"
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
show_help() {
    cat << 'EOF'
VaultWarden-OCI Maintenance Script

USAGE:
    ./maintenance.sh <subcommand> [options]

SUBCOMMANDS:
    run               Full routine maintenance (cleanup + optimize + health)
    run --comprehensive   Full routine + firewall + DNS updates
    health            Run system health checks
    update            Update system packages and/or Docker images
    db-maint          Deep database maintenance (VACUUM + WAL + backup)
    test-email        Email diagnostics and test notification
    update-dns        Update Cloudflare DNS A record only
    update-firewall   Update Cloudflare IP ranges in firewall only

RUN OPTIONS (used after 'run'):
    --comprehensive         Run everything: routine + firewall + DNS
    --no-logs               Skip log rotation and cleanup
    --no-backups            Skip backup cleanup
    --no-docker             Skip Docker cleanup
    --no-database           Skip scheduled database optimization
    --update-dns            Include DNS update in this run
    --update-firewall       Include firewall update in this run
    --dry-run               Show what would be done without executing
    --email                 Send email notification on completion

HEALTH OPTIONS (used after 'health'):
    --comprehensive         Include extended checks
    --fix                   Auto-restart unhealthy containers
    --report                Write a report file

UPDATE OPTIONS (used after 'update'):
    --system                Update OS packages only
    --images                Update Docker images only
    --all                   Update OS packages + Docker images
    --force                 Skip confirmation prompts
    --dry-run               Preview without changes
    --skip-backup           Skip pre-update backup
    --email                 Notify on completion

DB-MAINT OPTIONS (used after 'db-maint'):
    --force                 Skip confirmation prompt
    --dry-run               Preview without changes

TEST-EMAIL OPTIONS (used after 'test-email'):
    --recipient EMAIL       Override default admin email recipient
    --verbose               Show detailed diagnostic output
    --dry-run               Preview without sending

GLOBAL SUBCOMMAND:
    help                    Show this help

EXAMPLES:
    ./maintenance.sh run                          # Full routine maintenance
    ./maintenance.sh run --comprehensive          # Full + firewall + DNS
    ./maintenance.sh run --comprehensive --email  # Full + notify on completion
    ./maintenance.sh run --dry-run                # Preview what run would do
    ./maintenance.sh health                       # Health checks
    ./maintenance.sh health --comprehensive --fix # Full health + auto-fix
    sudo ./maintenance.sh update --all            # Update packages + images
    sudo ./maintenance.sh db-maint                # Deep DB maintenance (interactive)
    sudo ./maintenance.sh db-maint --force        # Deep DB maintenance (skip confirm)
    ./maintenance.sh test-email                   # Email diagnostics
    ./maintenance.sh test-email --verbose         # Email diagnostics (detailed)
    ./maintenance.sh test-email --recipient admin@example.com
    ./maintenance.sh update-dns                   # DNS update only
    ./maintenance.sh update-firewall              # Firewall update only
EOF
}

# ---------------------------------------------------------------------------
# ROUTINE: Log cleanup and rotation
# ---------------------------------------------------------------------------
cleanup_logs() {
    if [[ "$CLEAN_LOGS" != "true" ]]; then
        log_info "Skipping log cleanup"
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would clean up logs older than $LOG_RETENTION_DAYS days"
        return 0
    fi
    log_info "Cleaning up logs older than $LOG_RETENTION_DAYS days..."
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local logs_cleaned=0
    local log_dirs=(
        "$state_dir/logs/vaultwarden"
        "$state_dir/logs/caddy"
        "$state_dir/logs/fail2ban"
        "$SCRIPT_DIR/logs"
    )
    for log_dir in "${log_dirs[@]}"; do
        if [[ -d "$log_dir" ]]; then
            local -a old_log_files=()
            mapfile -d '' old_log_files < <(
                find "$log_dir" -name "*.log*" -type f -mtime +"$LOG_RETENTION_DAYS" -print0 2>/dev/null
            )
            for log_file in "${old_log_files[@]}"; do
                rm -f "$log_file" && ((logs_cleaned++)) && log_debug "Removed old log: $(basename "$log_file")"
            done
        fi
    done
    local existing_log_dirs=()
    for log_dir in "${log_dirs[@]}"; do
        [[ -d "$log_dir" ]] && existing_log_dirs+=("$log_dir")
    done
    if [[ ${#existing_log_dirs[@]} -gt 0 ]]; then
        local -a large_log_files=()
        mapfile -d '' large_log_files < <(
            find "${existing_log_dirs[@]}" -name "*.log" -type f -size +100M -print0 2>/dev/null
        )
        for log_file in "${large_log_files[@]}"; do
            if [[ "$log_file" == *"/logs/caddy/access.log" ]]; then
                log_debug "Skipping rotation for Caddy log (handled internally): $log_file"
                continue
            fi
            local rotated_name
            rotated_name="${log_file}.$(date +%Y%m%d)"
            if mv "$log_file" "$rotated_name"; then
                if gzip "$rotated_name"; then
                    log_debug "Rotated large log: $(basename "$log_file")"
                    ((logs_cleaned++)) || true
                else
                    # Restore original file on compression failure rather than destroying log data.
                    # This is especially important when gzip fails due to a full disk — the log
                    # contains the evidence of what caused the disk to fill up.
                    log_warn "gzip failed for $(basename "$rotated_name") — restoring original log file"
                    mv "$rotated_name" "$log_file" || \
                        log_error "CRITICAL: cannot restore log after gzip failure: $rotated_name"
                fi
            fi
        done
    fi
    if (( logs_cleaned > 0 )); then
        log_success "Cleaned up $logs_cleaned log files"
    else
        log_info "No old logs found to clean up"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# ROUTINE: Backup retention management
# ---------------------------------------------------------------------------
cleanup_backups() {
    if [[ "$CLEAN_BACKUPS" != "true" ]]; then log_info "Skipping backup cleanup"; return 0; fi
    if [[ "$DRY_RUN"       == "true" ]]; then log_info "[DRY RUN] Would clean up old backups based on retention policy"; return 0; fi
    log_info "Managing backup retention..."
    local backup_base_dir
    backup_base_dir="$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")"
    local had_real_error=false
    local backup_types=("db:$DB_BACKUP_RETENTION_DAYS" "full:$FULL_BACKUP_RETENTION_DAYS" "emergency:$EMERGENCY_BACKUP_RETENTION_DAYS")
    for backup_type_info in "${backup_types[@]}"; do
        local backup_type="${backup_type_info%%:*}"
        local retention_days="${backup_type_info##*:}"
        local backup_dir="$backup_base_dir/$backup_type"
        if [[ ! -d "$backup_dir" ]]; then
            log_info "No $backup_type backup directory yet (skipping cleanup)"
            continue
        fi
        if cleanup_old_backups "$backup_dir" "$backup_type" "$retention_days"; then
            log_success "$backup_type backups cleaned (${retention_days}d retention)"
        else
            log_error "$backup_type backup cleanup failed"
            had_real_error=true
        fi
    done
    log_success "Backup retention management completed"
    [[ "$had_real_error" == "true" ]] && return 1 || return 0
}

# ---------------------------------------------------------------------------
# ROUTINE: Docker system cleanup
# ---------------------------------------------------------------------------
cleanup_docker_system() {
    if [[ "$CLEAN_DOCKER" != "true" ]]; then log_info "Skipping Docker cleanup"; return 0; fi
    if [[ "$DRY_RUN"      == "true" ]]; then log_info "[DRY RUN] Would clean up Docker system resources"; return 0; fi
    log_info "Cleaning up Docker system resources..."
    # Return 2 (hard failure) when Docker itself is unavailable; return 1 for
    # partial cleanup issues so the summary can distinguish warnings from failures.
    if ! require_docker; then log_error "Docker not available for cleanup"; return 2; fi
    local cleanup_success=true
    cleanup_containers || { log_warn "Container cleanup had issues"; cleanup_success=false; }
    cleanup_images     || { log_warn "Image cleanup had issues";     cleanup_success=false; }
    log_info "Cleaning up Docker images and build cache..."
    # Skip 'docker volume prune': it removes ALL anonymous volumes not attached
    # to a currently running container. If any service is temporarily stopped
    # (e.g. crashed and not yet restarted by the health --fix path), its anonymous
    # volumes would be permanently deleted. Named volumes (where all persistent
    # VaultWarden data lives) are safe, but this is a latent footgun if the
    # compose file is ever extended with anonymous volume mounts.
    docker image prune -f >/dev/null 2>&1 || { log_warn "Image prune had issues"; cleanup_success=false; }
    docker builder prune -f --filter until=24h >/dev/null 2>&1 || { log_warn "Builder cache prune had issues"; cleanup_success=false; }
    cleanup_networks   || { log_warn "Network cleanup had issues";   cleanup_success=false; }
    local space_reclaimed
    space_reclaimed=$(docker system df --format "table {{.Reclaimed}}" 2>/dev/null | tail -1 || echo "unknown")
    if [[ "$cleanup_success" == "true" ]]; then
        log_success "Docker cleanup completed successfully (reclaimed: ${space_reclaimed})"; return 0
    else
        log_warn "Docker cleanup completed with some issues (reclaimed: ${space_reclaimed})"; return 1
    fi
}

# ---------------------------------------------------------------------------
# _wait_wal_quiesce DB_FILE [MAX_SECONDS]
#
# Poll until SQLite's WAL busy_count reaches 0, indicating no writer holds
# a WAL frame lock and it is safe to run wal_checkpoint(TRUNCATE)/VACUUM.
# Falls back to a plain sleep if sqlite3 is unavailable.
# ---------------------------------------------------------------------------
_wait_wal_quiesce() {
    local db_file="$1"
    local max_seconds="${2:-30}"
    local waited=0
    local interval=1
    log_debug "Waiting for WAL to quiesce on $db_file (max ${max_seconds}s)..."
    while (( waited < max_seconds )); do
        local busy_count
        busy_count=$(sqlite3 "$db_file" "PRAGMA wal_checkpoint(PASSIVE);" 2>/dev/null | awk -F'|' 'NR==1{print $2}' || echo "0")
        # busy_count == 0 means no writer is blocking the checkpoint
        if [[ "$busy_count" == "0" ]]; then
            log_debug "WAL quiesced after ${waited}s (busy_count=0)"
            return 0
        fi
        log_debug "WAL busy (busy_count=${busy_count}), waited ${waited}s…"
        sleep "$interval"
        (( waited += interval ))
    done
    log_warn "WAL did not fully quiesce within ${max_seconds}s (busy_count=${busy_count:-?}) — proceeding anyway"
    return 0
}

# ---------------------------------------------------------------------------
# ROUTINE: Scheduled database optimization
# ---------------------------------------------------------------------------
optimize_database() {
    if [[ "$OPTIMIZE_DATABASE" != "true" ]]; then log_info "Skipping database optimization"; return 0; fi
    if [[ "$DRY_RUN"           == "true" ]]; then log_info "[DRY RUN] Would safely optimize VaultWarden database"; return 0; fi
    log_info "Starting SAFE database optimization (will stop VaultWarden temporarily)..."
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local host_db_path="$state_dir/data/db.sqlite3"
    if [[ ! -f "$host_db_path" ]]; then log_error "Database file not found: $host_db_path"; return 1; fi
    local was_running=false
    if is_service_running "vaultwarden"; then
        was_running=true
    else
        log_warn "VaultWarden not running, will optimize offline database"
    fi

    # Safety net: if anything causes an early exit after VaultWarden is stopped,
    # ensure it is restarted. RETURN trap fires on both normal return and set -e exits.
    _db_opt_cleanup() {
        if [[ "$was_running" == "true" ]]; then
            if ! is_service_running "vaultwarden" 2>/dev/null; then
                log_warn "optimize_database: safety net restarting VaultWarden..."
                docker compose up -d vaultwarden 2>&1 || log_error "Safety net restart failed — manual intervention required"
            fi
        fi
    }
    trap '_db_opt_cleanup' RETURN

    local size_bytes_before
    size_bytes_before=$(stat -c%s "$host_db_path" 2>/dev/null || echo "0")
    local size_kb_before=$(( size_bytes_before / 1024 ))
    log_info "Database size before optimization: ${size_kb_before} KB"

    if [[ "$was_running" == "true" ]]; then
        log_info "Stopping VaultWarden service..."
        docker compose stop vaultwarden || { log_error "Failed to stop VaultWarden"; return 1; }
        log_success "VaultWarden stopped"
        _wait_wal_quiesce "$host_db_path" 30
    fi

    # Create an encrypted pre-optimization backup via backup.sh rather than a
    # plaintext cp to /tmp. /tmp is world-readable and is wiped on reboot —
    # making the safety net unreachable if VaultWarden fails to restart and the
    # host reboots (e.g. a kernel panic immediately after package updates).
    log_info "Creating encrypted pre-optimization backup via backup.sh..."
    if ! "${SCRIPT_DIR}/backup.sh" run db; then
        log_error "Pre-optimization backup FAILED — aborting to avoid an unsafe rollback point"
        [[ "$was_running" == "true" ]] && docker compose up -d vaultwarden
        return 1
    fi
    log_success "Encrypted pre-optimization backup created in backup directory"

    log_info "Verifying integrity before optimization..."
    if ! sqlite3 "$host_db_path" "PRAGMA integrity_check;" | grep -qx "ok"; then
        log_error "Integrity check failed - aborting"
        [[ "$was_running" == "true" ]] && docker compose up -d vaultwarden
        return 1
    fi
    log_success "Integrity check passed"

    local optimization_success=true
    for cmd in "PRAGMA wal_checkpoint(TRUNCATE);" "PRAGMA optimize;" "ANALYZE;" "VACUUM;"; do
        log_debug "Running: $cmd"
        sqlite3 "$host_db_path" "$cmd" >/dev/null 2>&1 || { log_warn "Command failed: $cmd"; optimization_success=false; }
    done

    log_info "Verifying integrity after optimization..."
    if ! sqlite3 "$host_db_path" "PRAGMA integrity_check;" | grep -qx "ok"; then
        log_error "CRITICAL: Post-optimization integrity check failed! Manual restore from backup directory required."
        optimization_success=false
    else
        log_success "Post-optimization integrity check passed"
    fi

    if [[ "$was_running" == "true" ]]; then
        if docker compose up -d vaultwarden; then
            log_success "VaultWarden restarted"
        else
            log_error "Failed to restart VaultWarden"
            optimization_success=false
        fi
        sleep 5
        if is_service_running "vaultwarden"; then
            log_success "VaultWarden healthy"
        else
            log_error "VaultWarden not healthy after optimization"
            optimization_success=false
        fi
    fi

    local size_bytes_after
    size_bytes_after=$(stat -c%s "$host_db_path" 2>/dev/null || echo "0")
    local size_kb_after=$(( size_bytes_after / 1024 ))

    if [[ "$optimization_success" == "true" ]]; then
        log_success "Database optimization completed. ${size_kb_before} KB → ${size_kb_after} KB"
    else
        log_warn "Optimization completed with issues. Safety backup retained in backup directory."
    fi
    [[ "$optimization_success" == "true" ]]
}

# ---------------------------------------------------------------------------
# ON-DEMAND: Deep database maintenance  (merged from db-maint.sh)
# ---------------------------------------------------------------------------
run_deep_db_maintenance() {
    log_info "VaultWarden Deep Database Maintenance"
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
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

    # Safety net: if anything causes an early exit after VaultWarden is stopped,
    # ensure it is restarted. RETURN trap fires on both normal return and set -e exits.
    _deep_db_cleanup() {
        if [[ "$was_running" == "true" ]]; then
            if ! is_service_running "vaultwarden" 2>/dev/null; then
                log_warn "run_deep_db_maintenance: safety net restarting VaultWarden..."
                docker compose up -d vaultwarden 2>&1 || log_error "Safety net restart failed — manual intervention required"
            fi
        fi
    }
    trap '_deep_db_cleanup' RETURN

    log_info "Step 0/5: Creating pre-maintenance safety backup..."
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

    log_info "Step 1/5: Checking database integrity..."
    if ! sqlite3 "$db_file" "PRAGMA integrity_check;" | grep -q "ok"; then
        log_error "Integrity check FAILED. Aborting. Restarting services..."
        docker compose up -d vaultwarden; return 1
    fi
    log_success "Database integrity check passed"

    log_info "Step 2/5: Committing WAL file (PRAGMA wal_checkpoint(TRUNCATE))..."
    if sqlite3 "$db_file" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1; then
        log_success "WAL checkpointed"
    else
        log_warn "Could not checkpoint WAL. Proceeding."
    fi

    log_info "Step 3/5: Optimizing database stats (PRAGMA optimize)..."
    if sqlite3 "$db_file" "PRAGMA optimize;" >/dev/null 2>&1; then
        log_success "Optimization complete"
    else
        log_warn "Could not optimize. Proceeding."
    fi

    log_info "Step 4/5: Reclaiming free space (VACUUM)... This may take a moment."
    if ! sqlite3 "$db_file" "VACUUM;" >/dev/null 2>&1; then
        log_error "VACUUM FAILED. Aborting. Restarting services..."
        docker compose up -d vaultwarden; return 1
    fi
    log_success "Database VACUUM completed"

    log_info "Step 5/5: Gathering statistics..."
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
            if [[ -f "$sidecar" ]]; then
                rm -f "$sidecar"
                (( removed_sidecars++ )) || true
            fi
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
# ON-DEMAND: Email Diagnostics (merged from simple-email-test.sh)
# ---------------------------------------------------------------------------

# verbose_log: emits only when --verbose is set. Only called within the
# --test-email sub-command; VERBOSE has no effect in any other mode.
verbose_log() {
    [[ "$VERBOSE" == "true" ]] && log_info "$1"
}

test_postfix_container() {
    log_info "Testing postfix container status..."

    local postfix_running
    postfix_running=$(docker inspect vaultwarden_postfix --format '{{.State.Running}}' 2>/dev/null || echo "false")

    if [[ "$postfix_running" == "true" ]]; then
        log_success "✅ postfix container is running"
        verbose_log "Container status: $(docker compose ps postfix --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}')"
    else
        log_error "❌ postfix container is not running"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "🔍 [DRY RUN] Would start postfix container"
            return 1
        fi
        log_info "Starting postfix container..."
        if docker compose up -d postfix; then
            sleep 15
            log_success "✅ postfix container started successfully"
        else
            log_error "❌ Failed to start postfix container"
            return 1
        fi
    fi

    local health_status
    health_status=$(docker compose exec -T postfix nc -z localhost 587 >/dev/null 2>&1 && echo "healthy" || echo "unhealthy")

    if [[ "$health_status" == "healthy" ]]; then
        log_success "✅ postfix health check passed (port 587 responding)"
    else
        log_error "❌ postfix health check failed (port 587 not responding)"
        log_info "🔍 Check logs: docker compose logs postfix"
        return 1
    fi

    if docker compose exec -T postfix postfix status >/dev/null 2>&1; then
        log_success "✅ postfix service is active"
        verbose_log "$(docker compose exec -T postfix postfix status)"
    else
        log_warn "⚠️  Could not verify postfix service status"
    fi

    local recent_logs
    recent_logs=$(docker compose logs --tail 20 postfix 2>/dev/null | grep -i "error\|fatal" | grep -v "warning" || true)
    if [[ -n "$recent_logs" ]]; then
        log_warn "⚠️  Found recent errors in postfix logs:"
        echo "$recent_logs" | while read -r line; do
            log_warn "    $line"
        done
    else
        verbose_log "No critical errors found in postfix logs"
    fi
    return 0
}

test_fail2ban_integration() {
    log_info "Testing fail2ban integration..."

    local f2b_running
    f2b_running=$(docker inspect vaultwarden_fail2ban --format '{{.State.Running}}' 2>/dev/null || echo "false")
    if [[ "$f2b_running" != "true" ]]; then
        log_error "❌ fail2ban container is not running"
        log_info "💡 Start it with: docker compose up -d fail2ban"
        return 1
    fi
    log_success "✅ fail2ban container is running"

    local f2b_status_output
    if f2b_status_output=$(docker exec vaultwarden_fail2ban sh -c 'fail2ban-client status' 2>&1); then
        log_success "✅ fail2ban is responding"
        verbose_log "fail2ban status: $f2b_status_output"
    else
        log_error "❌ fail2ban is not responding (fail2ban-client status failed)"
        log_info "🔍 Debug: docker exec vaultwarden_fail2ban sh -c 'fail2ban-client status'"
        log_info "🔍 Logs:  docker compose logs fail2ban"
        return 1
    fi

    local f2b_netmode smtp_host smtp_port
    f2b_netmode=$(docker inspect vaultwarden_fail2ban --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || echo "")
    smtp_port="587"

    if [[ "$f2b_netmode" == "host" ]]; then
        smtp_host="127.0.0.1"
        verbose_log "fail2ban network mode: host -> testing SMTP via ${smtp_host}:${smtp_port}"
    else
        smtp_host="postfix"
        verbose_log "fail2ban network mode: ${f2b_netmode:-unknown} -> testing SMTP via ${smtp_host}:${smtp_port}"
    fi

    if docker exec vaultwarden_fail2ban sh -c "nc -zv $smtp_host $smtp_port" >/dev/null 2>&1; then
        log_success "✅ fail2ban can reach postfix SMTP (${smtp_host}:${smtp_port})"
    else
        log_error "❌ fail2ban cannot reach postfix SMTP (${smtp_host}:${smtp_port})"
        log_info "🔍 Debug: docker exec vaultwarden_fail2ban sh -c 'nc -zv ${smtp_host} ${smtp_port}'"
        return 1
    fi

    if docker exec vaultwarden_fail2ban sh -c 'test -f /data/fail2ban/action.d/smtp.conf'; then
        log_success "✅ SMTP action configuration found"
        if docker exec vaultwarden_fail2ban sh -c \
            'grep -Eq "smtplib\.SMTP\(.(postfix|127\.0\.0\.1)., 587\)" /data/fail2ban/action.d/smtp.conf'; then
            log_success "✅ SMTP action correctly configured (postfix or localhost)"
        else
            log_warn "⚠️  SMTP action may still reference old msmtpd configuration"
        fi
    else
        log_error "❌ SMTP action configuration missing: /data/fail2ban/action.d/smtp.conf"
        return 1
    fi
    return 0
}

test_host_script_email() {
    log_info "Testing host script email functionality..."

    if [[ -z "$TEST_RECIPIENT" ]]; then
        TEST_RECIPIENT=$(get_config_value "ADMIN_EMAIL" "")
        if [[ -z "$TEST_RECIPIENT" ]]; then
            log_error "❌ No email recipient configured (ADMIN_EMAIL not set)"
            return 1
        fi
    fi

    log_success "✅ Email recipient configured: $TEST_RECIPIENT"

    local sender_domains
    sender_domains=$(get_config_value "ALLOWED_SENDER_DOMAINS" "")
    if [[ -n "$sender_domains" ]]; then
        log_success "✅ Allowed sender domains configured: $sender_domains"
    else
        log_warn "⚠️  ALLOWED_SENDER_DOMAINS not set (postfix may reject emails)"
    fi

    if declare -f send_notification_email >/dev/null 2>&1; then
        log_success "✅ send_notification_email function available"
    else
        log_error "❌ send_notification_email function not available"
        return 1
    fi
    return 0
}

test_end_to_end_email() {
    log_info "Testing end-to-end email functionality..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "🔍 [DRY RUN] Would send test email to: $TEST_RECIPIENT"
        log_info "🔍 [DRY RUN] Email would be sent via postfix container (port 587)"
        return 0
    fi

    if [[ -z "$TEST_RECIPIENT" ]]; then
        log_error "❌ No test recipient specified"
        return 1
    fi

    local test_subject
    test_subject="VaultWarden Email Test - postfix - $(date)"
    local test_body
    test_body="VaultWarden notification test
Sent: $(date -Iseconds)
Host: $(hostname -f 2>/dev/null || hostname)

If you received this message, email delivery is working correctly."

    log_info "📧 Sending test email to: $TEST_RECIPIENT"

    if send_notification_email "$test_subject" "$test_body"; then
        log_success "✅ Test email sent successfully!"
        log_info "📬 Please check $TEST_RECIPIENT for the test message"
        log_info "🔍 Check postfix logs: docker compose logs postfix"
    else
        log_error "❌ Failed to send test email"
        log_info "🔍 Debug steps:"
        log_info "   1. Check postfix logs: docker compose logs postfix"
        log_info "   2. Check fail2ban logs: docker compose logs fail2ban"
        log_info "   3. Verify SMTP credentials in secrets"
        log_info "   4. Verify ALLOWED_SENDER_DOMAINS in .env"
        log_info "   5. Check postfix relay configuration"
        log_info "   6. Check postfix container permissions: docker compose logs postfix | grep -i permission"
        return 1
    fi
    return 0
}

run_email_diagnostics() {
    log_header "VaultWarden Email Diagnostic"

    local test_results=()
    local test_names=("postfix Container" "fail2ban Integration" "Host Script Email" "End-to-End Email")

    test_postfix_container    && test_results+=(0) || test_results+=(1)
    test_fail2ban_integration && test_results+=(0) || test_results+=(1)
    test_host_script_email    && test_results+=(0) || test_results+=(1)
    test_end_to_end_email     && test_results+=(0) || test_results+=(1)

    local total_tests=${#test_results[@]}
    local passed_tests=0
    local failed_tests=()

    for i in "${!test_results[@]}"; do
        if [[ ${test_results[i]} -eq 0 ]]; then
            ((passed_tests++))
        else
            failed_tests+=("${test_names[i]}")
        fi
    done

    echo ""
    log_info "============================================"
    log_info "TEST RESULTS: $passed_tests/$total_tests tests passed"
    log_info "============================================"

    if [[ $passed_tests -eq $total_tests ]]; then
        log_success "🎉 ALL EMAIL TESTS PASSED!"
        log_success "✅ Your VaultWarden-OCI email deployment is functioning correctly"
        return 0
    else
        log_error "❌ Some email tests failed: ${failed_tests[*]}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# TARGETED: Firewall IP range update
# ---------------------------------------------------------------------------
# shellcheck disable=SC2120  # $@ is forwarded to require_root; callers pass no args intentionally
update_firewall_ranges() {
    if [[ "$UPDATE_FIREWALL" != "true" ]]; then log_info "Skipping firewall update"; return 0; fi
    if [[ "$DRY_RUN"         == "true" ]]; then log_info "[DRY RUN] Would safely update Cloudflare IP ranges in firewall"; return 0; fi

    require_root "$@"

    log_info "Safely updating Cloudflare IP ranges in firewall..."
    local cf_ipv4_file cf_ipv6_file
    cf_ipv4_file=$(mktemp -t cf_ipv4.XXXXXXXXXX)
    cf_ipv6_file=$(mktemp -t cf_ipv6.XXXXXXXXXX)
    register_cleanup rm -f "$cf_ipv4_file" "$cf_ipv6_file"
    if retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v4" -o "$cf_ipv4_file" && \
       retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v6" -o "$cf_ipv6_file"; then
        log_success "Successfully fetched current Cloudflare IP ranges"
    else
        log_error "Failed to fetch Cloudflare IP ranges - aborting firewall update"; return 1
    fi

    _ufw_allow_range() {
        local range="$1" label="$2"
        _ufw_result=false
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null)
        # Check that BOTH port 80 and port 443 rules exist for this range.
        # UFW status format: "80/tcp  ALLOW IN  <range>  # comment"
        # Match port in the To-column followed by ALLOW and the range to avoid
        # false positives from comment text that contains the range and a number.
        local has_80=false has_443=false
        echo "$ufw_status" | grep -qE "^80(/tcp)?[[:space:]]+(ALLOW|ALLOW IN)[[:space:]].*${range}" && has_80=true
        echo "$ufw_status" | grep -qE "^443(/tcp)?[[:space:]]+(ALLOW|ALLOW IN)[[:space:]].*${range}" && has_443=true
        if [[ "$has_80" == "true" && "$has_443" == "true" ]]; then
            return 0  # both rules already present
        fi
        if ufw allow proto tcp from "$range" to any port 80  comment "${label}" >/dev/null 2>&1 && \
           ufw allow proto tcp from "$range" to any port 443 comment "${label}" >/dev/null 2>&1; then
            _ufw_result=true
        else
            log_warn "ufw allow failed for range: $range"
        fi
    }

    local ranges_added=false
    local _ufw_result=false

    if grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' "$cf_ipv4_file" >/dev/null; then
        log_info "Adding new Cloudflare IPv4 ranges..."
        while IFS= read -r range; do
            if [[ -n "$range" && "$range" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
                _ufw_allow_range "$range" "CF-IPv4-NEW"
                if [[ "$_ufw_result" == "true" ]]; then
                    ranges_added=true
                    log_debug "Added IPv4 range: $range"
                fi
            fi
        done < "$cf_ipv4_file"
    fi

    if grep -E '^[0-9a-fA-F:]+/[0-9]{1,3}$' "$cf_ipv6_file" >/dev/null; then
        log_info "Adding new Cloudflare IPv6 ranges..."
        while IFS= read -r range; do
            if [[ -n "$range" && "$range" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]]; then
                _ufw_allow_range "$range" "CF-IPv6-NEW"
                if [[ "$_ufw_result" == "true" ]]; then
                    ranges_added=true
                    log_debug "Added IPv6 range: $range"
                fi
            fi
        done < "$cf_ipv6_file"
    fi

    if [[ "$ranges_added" == "true" ]]; then
        log_success "New Cloudflare IP ranges added successfully"
    else
        log_info "No new IP ranges needed to be added"
    fi

    # Remove stale rules regardless of whether new ranges were added — rules
    # may have been added in a previous run whose corresponding IP ranges were
    # subsequently retired by Cloudflare.
    log_info "Removing outdated Cloudflare IP ranges..."
    local removed_count=0
    local -a old_rule_nums=()
    mapfile -t old_rule_nums < <(
        ufw status numbered \
        | grep -E "CF-IPv[46]" \
        | grep -v "CF-IPv[46]-NEW" \
        | sed -n 's/^\[\s*\([0-9]\+\)\].*/\1/p' \
        | sort -rn
    )
    for rule_num in "${old_rule_nums[@]}"; do
        [[ -n "$rule_num" ]] && echo "y" | ufw delete "$rule_num" >/dev/null 2>&1 && ((removed_count++))
    done
    [[ $removed_count -gt 0 ]] && log_success "Removed $removed_count outdated firewall rules"
    log_success "Firewall IP ranges updated safely"
    return 0
}

# ---------------------------------------------------------------------------
# TARGETED: DNS update  (Cloudflare-proxy-safe)
# ---------------------------------------------------------------------------
update_dns_record() {
    if [[ "$UPDATE_DNS" != "true" ]]; then log_info "Skipping DNS update"; return 0; fi
    if [[ "$DRY_RUN"    == "true" ]]; then log_info "[DRY RUN] Would check and update Cloudflare DNS A record"; return 0; fi

    local domain="${DOMAIN:-}"
    domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')
    local zone_id="${CLOUDFLARE_ZONE_ID:-}"
    [[ -z "$domain"  ]] && { log_error "DOMAIN not set in .env"; return 1; }
    [[ -z "$zone_id" ]] && { log_error "CLOUDFLARE_ZONE_ID not set in .env"; return 1; }

    local DNS_LOCK="/run/lock/vaultwarden-dns-update.lock"
    local _DNS_LOCK_FD
    exec {_DNS_LOCK_FD}>"$DNS_LOCK"
    if ! flock -n "$_DNS_LOCK_FD"; then
        log_info "DNS update already in progress (lock: $DNS_LOCK). Skipping."
        return 0
    fi

    log_info "Checking if DNS update needed for $domain..."

    # ── Step 1: get origin server's real public IP ────────────────────────
    local current_ip
    current_ip=$(curl -s --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '\n\r ') || true
    [[ -z "$current_ip" ]] && { log_error "Cannot determine current external IP"; return 1; }
    [[ ! "$current_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && {
        log_error "Invalid IP format: $current_ip"; return 1
    }

    # ── Step 2: read Cloudflare API token (unchanged from original) ───────
    local token_file="${SCRIPT_DIR}/secrets/.docker_secrets/caddy_cloudflare_dns_token"
    local cf_token
    if [[ -f "$token_file" ]]; then
        local token_perms
        token_perms=$(stat -c%a "$token_file" 2>/dev/null \
                   || stat -f%Lp "$token_file" 2>/dev/null \
                   || echo "")
        case "$token_perms" in
            444|400|600|640)
                log_debug "Cloudflare token file permissions OK ($token_perms)"
                ;;
            "")
                log_warn "Cannot determine permissions on $token_file — proceeding with caution"
                ;;
            *)
                log_error "Cloudflare token file has insecure permissions ($token_perms): $token_file"
                log_error "Expected 444 (docker secret) or 400/600. Fix with: chmod 444 '$token_file'"
                return 1
                ;;
        esac
        cf_token=$(cat "$token_file") \
            || { log_error "Cannot read Cloudflare API token from host secret file"; return 1; }
    else
        cf_token=$(docker compose exec -T caddy \
            cat /run/secrets/caddy_cloudflare_dns_token 2>/dev/null) \
            || { log_error "Cannot read Cloudflare API token (host file: $token_file not found, Caddy container may be stopped)"; return 1; }
    fi
    [[ -z "$cf_token" ]] && { log_error "Cloudflare API token is empty"; return 1; }

    # ── Step 3: query Cloudflare API for BOTH record_id AND stored origin IP
    #    This is the key fix: .content is the real origin IP, never the proxy IP,
    #    regardless of whether the orange-cloud proxy is enabled.
    local cf_response record_id stored_ip
    cf_response=$(curl -s --max-time 15 \
        -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$domain" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json") \
        || { log_error "Cloudflare API request failed (network error)"; return 1; }

    record_id=$(echo "$cf_response" | jq -r '.result[0].id   // empty' 2>/dev/null)
    stored_ip=$(echo "$cf_response" | jq -r '.result[0].content // empty' 2>/dev/null)

    [[ -z "$record_id" ]] && { log_error "Cannot find DNS record ID for $domain"; return 1; }

    # ── Step 4: compare origin IP with stored origin IP (proxy-safe) ──────
    if [[ "$current_ip" == "$stored_ip" ]]; then
        log_success "DNS record up to date: $domain -> $current_ip (CF record content matches, proxy state irrelevant)"
        return 0
    fi

    log_info "DNS update needed: stored_ip=$stored_ip -> current_ip=$current_ip"

    # ── Step 5: update the record ─────────────────────────────────────────
    local response
    response=$(curl -s --max-time 15 \
        -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$domain\",\"content\":\"$current_ip\",\"ttl\":300}")

    if echo "$response" | jq -e '.success' >/dev/null 2>&1; then
        log_success "DNS updated successfully: $domain -> $current_ip"
        if [[ "$EMAIL_NOTIFY" == "true" ]]; then
            local admin_email; admin_email=$(get_config_value "ADMIN_EMAIL" "")
            if [[ -n "$admin_email" ]]; then
                if send_notification_email "VaultWarden IP Address Changed" \
"Old IP: $stored_ip
New IP: $current_ip
Domain: $domain
DNS record updated automatically."; then
                    log_info "DNS change notification sent"
                else
                    log_warn "Failed to send DNS change notification email"
                fi
            fi
        fi
    else
        log_error "DNS update failed: $response"; return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# ROUTINE: System health validation
# ---------------------------------------------------------------------------
validate_system_health() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would validate system health"; return 0; fi
    log_info "Validating system health after maintenance..."
    log_info "Invoking: $SCRIPT_DIR/maintenance.sh health --quiet"
    if "$SCRIPT_DIR/maintenance.sh" health --quiet; then
        log_success "System health validation passed"
        return 0
    else
        log_warn "System health validation detected issues"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
generate_maintenance_summary() {
    local log_cleanup="$1" backup_cleanup="$2" docker_cleanup="$3"
    local db_optimization="$4" firewall_update="$5" dns_update="$6" health_validation="$7"

    local summary
    summary="VaultWarden Maintenance Summary - $(date)\n\nMaintenance Results:\n"

    if [[ "$CLEAN_LOGS" == "true" ]]; then
        [[ "$log_cleanup" == "0" ]] && summary+="  ✅ Log cleanup: OK\n" || summary+="  ❌ Log cleanup: Failed\n"
    else
        summary+="  ⏭️  Log cleanup: Skipped\n"
    fi

    if [[ "$CLEAN_BACKUPS" == "true" ]]; then
        [[ "$backup_cleanup" == "0" ]] && summary+="  ✅ Backup cleanup: OK\n" || summary+="  ❌ Backup cleanup: Failed\n"
    else
        summary+="  ⏭️  Backup cleanup: Skipped\n"
    fi

    if [[ "$CLEAN_DOCKER" == "true" ]]; then
        if [[ "$docker_cleanup" == "0" ]]; then
            summary+="  ✅ Docker cleanup: OK\n"
        elif [[ "$docker_cleanup" == "1" ]]; then
            summary+="  ⚠️  Docker cleanup: Issues\n"
        else
            summary+="  ❌ Docker cleanup: Failed\n"
        fi
    else
        summary+="  ⏭️  Docker cleanup: Skipped\n"
    fi

    if [[ "$OPTIMIZE_DATABASE" == "true" ]]; then
        [[ "$db_optimization" == "0" ]] && summary+="  ✅ DB optimization: OK\n" || summary+="  ⚠️  DB optimization: Issues\n"
    else
        summary+="  ⏭️  DB optimization: Skipped\n"
    fi

    if [[ "$UPDATE_FIREWALL" == "true" ]]; then
        [[ "$firewall_update" == "0" ]] && summary+="  ✅ Firewall update: OK\n" || summary+="  ❌ Firewall update: Failed\n"
    else
        summary+="  ⏭️  Firewall update: Skipped\n"
    fi

    if [[ "$UPDATE_DNS" == "true" ]]; then
        [[ "$dns_update" == "0" ]] && summary+="  ✅ DNS update: OK\n" || summary+="  ❌ DNS update: Failed\n"
    else
        summary+="  ⏭️  DNS update: Skipped\n"
    fi

    if [[ "$TARGETED_MODE" == "false" ]]; then
        [[ "$health_validation" == "0" ]] && summary+="  ✅ Health validation: Passed\n" || summary+="  ⚠️  Health validation: Issues\n"
    fi

    local critical_failures=0
    [[ "$CLEAN_LOGS"        == "true"  && "$log_cleanup"      != "0" ]] && ((critical_failures++))
    [[ "$CLEAN_BACKUPS"     == "true"  && "$backup_cleanup"   != "0" ]] && ((critical_failures++))
    # Docker cleanup exit 1 = partial issues (warning); only exit 2 (hard failure) is critical.
    [[ "$CLEAN_DOCKER"      == "true"  && "$docker_cleanup"   == "2" ]] && ((critical_failures++))
    [[ "$OPTIMIZE_DATABASE" == "true"  && "$db_optimization"  != "0" ]] && ((critical_failures++))
    [[ "$UPDATE_FIREWALL"   == "true"  && "$firewall_update"  != "0" ]] && ((critical_failures++))
    [[ "$UPDATE_DNS"        == "true"  && "$dns_update"       != "0" ]] && ((critical_failures++))
    [[ "$TARGETED_MODE"     == "false" && "$health_validation" != "0" ]] && ((critical_failures++))
    if [[ $critical_failures -eq 0 ]]; then
        summary+="\n🎉 Overall Status: SUCCESS\n"
    else
        summary+="\n⚠️  Overall Status: COMPLETED WITH ISSUES\n"
    fi

    printf '%b' "$summary"

    if [[ "$EMAIL_NOTIFY" == "true" ]]; then
        local subj
        if [[ $critical_failures -eq 0 ]]; then
            subj="VaultWarden Maintenance: SUCCESS"
        else
            subj="VaultWarden Maintenance: ISSUES DETECTED"
        fi
        local email_body
        email_body=$(printf '%b' "$summary")
        if send_notification_email "$subj" "$email_body"; then
            log_info "Summary emailed"
        else
            log_warn "Failed to send summary email"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _load_env — gracefully load .env; non-fatal when running under systemd
# (environment already injected via EnvironmentFile= in the unit file).
# Returns 0 always; individual functions will still fail on missing vars.
# ---------------------------------------------------------------------------
_load_env() {
    if load_env_file 2>/dev/null; then
        return 0
    fi
    log_warn "No .env file found — relying on environment already set (e.g. systemd EnvironmentFile)"
    return 0
}

# ---------------------------------------------------------------------------
# run_health_check
# ---------------------------------------------------------------------------
run_health_check() {
# Load environment.
#
_resolve_env_file() {
    local candidates=(
        "${SCRIPT_DIR}/.env"
        "/etc/vaultwarden/vaultwarden.env"
    )
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    echo ""
    return 1
}

local ENV_FILE
ENV_FILE="$(_resolve_env_file || true)"

if [[ -n "${ENV_FILE}" ]]; then
    if [[ ! -r "${ENV_FILE}" ]]; then
        log_error "maintenance.sh health: '${ENV_FILE}' is not readable by $(id -un) — config variables will be unset."
        log_error "Fix ownership: sudo chown $(id -un):$(id -gn) '${ENV_FILE}'"
    else
        load_env_file "${ENV_FILE}" || true
    fi
else
    # Neither candidate path exists; the script may still work if the
    # caller (e.g., systemd EnvironmentFile=) has already exported the
    # required variables into the process environment.
    log_warn "maintenance.sh health: no .env file found at '${SCRIPT_DIR}/.env' or '/etc/vaultwarden/vaultwarden.env' — relying on inherited environment"
    ENV_FILE="/etc/vaultwarden/vaultwarden.env"  # canonical path for error messages
fi

# Health check configuration
local HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-10}
local HEALTH_CONNECT_TIMEOUT=${HEALTH_CONNECT_TIMEOUT:-3}
local HEALTH_RETRIES=${HEALTH_RETRIES:-3}
local HEALTH_RETRY_DELAY=${HEALTH_RETRY_DELAY:-2}

# When true, a non-200 response from /api/config is recorded as a hard
# failure (exit 2) rather than a warning (exit 1). Set in .env or the
# calling environment to opt in to stricter alerting.
local HEALTH_API_STRICT=${HEALTH_API_STRICT:-false}

# Auto-fix configuration
local AUTO_FIX=${AUTO_FIX:-false}
local FIX_MAX_RESTARTS=${FIX_MAX_RESTARTS:-3}
local FIX_RESTART_WINDOW=${FIX_RESTART_WINDOW:-300}  # 5 minutes

# Report configuration
local REPORT_DIR; REPORT_DIR="$(_default_report_dir)"
local REPORT_RETENTION_DAYS=${REPORT_RETENTION_DAYS:-30}

# Notification thresholds
local DISK_WARN_THRESHOLD=${DISK_WARN_THRESHOLD:-80}
local DISK_CRIT_THRESHOLD=${DISK_CRIT_THRESHOLD:-90}
local MEM_WARN_THRESHOLD=${MEM_WARN_THRESHOLD:-80}
local MEM_CRIT_THRESHOLD=${MEM_CRIT_THRESHOLD:-90}
local CERT_WARN_DAYS=${CERT_WARN_DAYS:-30}
local CERT_CRIT_DAYS=${CERT_CRIT_DAYS:-7}

# Fail2Ban daemon ping retry configuration.
# The fail2ban daemon socket may not be ready immediately after container
# start. Retry up to FAIL2BAN_PING_RETRIES times with FAIL2BAN_PING_DELAY
# seconds between attempts before recording a result.
local FAIL2BAN_PING_RETRIES=${FAIL2BAN_PING_RETRIES:-5}
local FAIL2BAN_PING_DELAY=${FAIL2BAN_PING_DELAY:-6}

# =============================================================================
# SINGLETON LOCK — prevents overlapping health-check runs
# =============================================================================

local _HEALTH_RUN_LOCK_FILE="/run/lock/vaultwarden-health.lock"
local _HEALTH_LOCK_FD=""

_acquire_run_lock() {
    exec {_HEALTH_LOCK_FD}>"$_HEALTH_RUN_LOCK_FILE" 2>/dev/null || {
        log_warn "Cannot open run-lock ${_HEALTH_RUN_LOCK_FILE} — proceeding without singleton guard"
        _HEALTH_LOCK_FD=""
        return 0
    }
    if ! flock -n "$_HEALTH_LOCK_FD" 2>/dev/null; then
        log_info "Another health check is already running — exiting"
        exit 0
    fi
}

_release_run_lock() {
    [[ -n "${_HEALTH_LOCK_FD:-}" ]] || return 0
    flock -u "$_HEALTH_LOCK_FD" 2>/dev/null || true
    eval "exec ${_HEALTH_LOCK_FD}>&-" 2>/dev/null || true
}

# =============================================================================
# ALERT COOLDOWN
# =============================================================================
#
# Cooldown state lives on persistent disk, not /run (which is wiped on
# container/host restart). Files are named <safe_key>.cooldown and contain
# a Unix epoch timestamp written at send time. TTL is checked on read.
# This survives reboots, container restarts, and systemd RuntimeDirectory
# teardown without losing cooldown state.
# =============================================================================

local ALERT_LOCK_DIR="${ALERT_STATE_DIR:-$(_default_alert_state_dir)}"
local ALERT_COOLDOWN_SECONDS=${ALERT_COOLDOWN_SECONDS:-3600}
local ALERT_RECOVERY_TTL=${ALERT_RECOVERY_TTL:-86400}

# _acquire_alert_lock KEY
#
# Returns 0 if an alert should fire for KEY (cooldown expired or first alert).
# Returns 1 if still within the cooldown window.
# On return 0, writes the current epoch to the cooldown file — the caller
# MUST send the alert (or explicitly call _release_alert_lock KEY on failure).
#
# Uses a per-key timestamp file on persistent storage instead of flock on
# /run so that cooldown state survives container/host restarts.
_acquire_alert_lock() {
    local key="$1"
    local safe_key
    safe_key=$(printf '%s' "$key" | tr -cs '[:alnum:]-' '_')

    mkdir -p "${ALERT_LOCK_DIR}" 2>/dev/null || true

    local state_file="${ALERT_LOCK_DIR}/${safe_key}.cooldown"
    local ttl="${2:-${ALERT_COOLDOWN_SECONDS}}"
    local now
    now=$(date +%s)

    if [[ -f "$state_file" ]]; then
        local last_sent
        last_sent=$(cat "$state_file" 2>/dev/null || printf '0')
        if (( now - last_sent < ttl )); then
            return 1   # still within cooldown
        fi
    fi

    # Atomically claim the slot: write timestamp before returning 0.
    # Use a temp file + mv for atomic replacement (avoids partial reads).
    local tmp_file
    tmp_file=$(mktemp "${ALERT_LOCK_DIR}/.tmp.XXXXXXXXXX")
    printf '%s\n' "$now" > "$tmp_file"
    mv -f "$tmp_file" "$state_file"

    return 0
}

# _release_alert_lock KEY
#
# Removes the cooldown stamp for KEY so the next run can re-send immediately.
# Call this when a delivery failure occurs so the alert retries next cycle.
_release_alert_lock() {
    local key="$1"
    local safe_key
    safe_key=$(printf '%s' "$key" | tr -cs '[:alnum:]-' '_')
    rm -f "${ALERT_LOCK_DIR}/${safe_key}.cooldown" 2>/dev/null || true
}

# _release_recovery_lock
#
# Removes the recovery-state lock file so the next failure cycle can send
# a fresh clear-state email when it resolves.  Called only when failures are
# detected (i.e., we are NOT in a clean state).
_release_recovery_lock() {
    rm -f "${ALERT_LOCK_DIR}/recovery.cooldown" 2>/dev/null || true
}

# =============================================================================
# GLOBAL STATE
# =============================================================================

# Health check results
local -A check_results=()    # check_name -> pass|warn|fail
local -A check_messages=()   # check_name -> message
local -a check_order=()      # ordered list of check names

# Counters
local passed=0
local warnings=0
local failed=0
local total=0

# Flags
local COMPREHENSIVE=false
local FIX_MODE=false
local REPORT_MODE=false
local QUIET=false

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

_health_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --comprehensive)     COMPREHENSIVE=true;  shift ;;
            --fix|-f)            FIX_MODE=true;       shift ;;
            --report|-r)         REPORT_MODE=true;    shift ;;
            --quiet|-q)          QUIET=true;          shift ;;
            *)                   log_error "Unknown option for 'health': $1"; _show_help; exit 1 ;;
        esac
    done
}

_show_help() {
    cat <<'EOF'
Usage: ./maintenance.sh health [OPTIONS]

Options:
  --comprehensive     Run all checks including extended diagnostics
  --fix, -f            Attempt automatic recovery for failed checks
  --report, -r         Save health report to file
  --quiet, -q          Suppress non-critical output

Checks performed:
  - Docker container status and health
  - SSL certificate validity and expiry
  - VaultWarden /alive liveness probe (internal + external HTTPS)
  - VaultWarden /api/config readiness probe (requires live DB connection)
  - Fail2Ban status and jail activity
  - Disk space utilization
  - Memory utilization
  - Network connectivity
  - Backup status and age
  - DNS resolution
  - Configuration validation

Comprehensive mode adds:
  - Detailed container resource usage
  - SSL certificate chain validation
  - Extended /api/config endpoint testing (explicit comprehensive result)
  - Backup integrity verification
  - Fail2Ban rule validation
  - Fail2Ban filter regex drift detection (vaultwarden-auth against live log)

Environment variables:
  HEALTH_API_STRICT=true          Promote /api/config non-200 from warning to failure
  FAIL2BAN_PING_RETRIES=5         Ping attempts before recording fail2ban result (default: 5)
  FAIL2BAN_PING_DELAY=6           Seconds between fail2ban ping retries (default: 6)
  ALERT_COOLDOWN_SECONDS=3600     Minimum seconds between repeat alerts for the same
                                  failure key (default: 3600 = 1 hour)
  ALERT_RECOVERY_TTL=86400        Minimum seconds between clear-state recovery emails
                                  (default: 86400 = 24 hours)

Alert cooldown:
  Alerts are rate-limited per failure key using timestamp files under
  $PROJECT_STATE_DIR/.vw-health-alert/. At most one alert fires per failure 
  key per ALERT_COOLDOWN_SECONDS window. A single clear-state recovery email 
  fires once when all checks pass, then is suppressed for ALERT_RECOVERY_TTL
  seconds. State survives reboots and container restarts.

Exit codes:
  0 - All checks passed
  1 - One or more warnings
  2 - One or more failures
  3 - Critical failure (cannot run checks)
EOF
}

# =============================================================================
# RESULT RECORDING
# =============================================================================

_record() {
    local name="$1" status="$2" message="$3"
    check_results["$name"]="$status"
    check_messages["$name"]="$message"
    check_order+=("$name")
    (( total++ )) || true
    case "$status" in
        pass)  (( passed++ ))   || true ;;
        warn)  (( warnings++ )) || true ;;
        fail)  (( failed++ ))   || true ;;
    esac
}

_pass() { _record "$1" pass "$2"; }
_warn() { _record "$1" warn "$2"; }
_fail() { _record "$1" fail "$2"; }

# =============================================================================
# DOMAIN RESOLUTION
# =============================================================================

_get_domain() {
    if [[ -n "${DOMAIN_NAME:-}" ]]; then
        echo "${DOMAIN_NAME}"
    elif [[ -n "${DOMAIN:-}" ]]; then
        local _d="${DOMAIN#https://}"
        echo "${_d#http://}"
    else
        echo ""
    fi
}

# =============================================================================
# CONTAINER HEALTH CHECKS
# =============================================================================

_check_containers() {
    log_info "Checking container status..."

    local containers=("vaultwarden_app" "vaultwarden_caddy" "vaultwarden_fail2ban" "vaultwarden_postfix")
    local all_healthy=true

    for container in "${containers[@]}"; do
        if ! docker inspect "$container" &>/dev/null; then
            _fail "container:${container}" "Container not found: $container"
            all_healthy=false
            continue
        fi

        local status running health
        status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
        running=$(docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null || echo "false")

        if [[ "$running" != "true" ]]; then
            _fail "container:${container}" "Container not running: $container (status: $status)"
            all_healthy=false
            continue
        fi

        health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$container" 2>/dev/null || echo "unknown")

        case "$health" in
            healthy|no-healthcheck)
                _pass "container:${container}" "$container is running (health: $health)"
                ;;
            starting)
                _warn "container:${container}" "$container is starting up (health: starting)"
                ;;
            unhealthy)
                _fail "container:${container}" "$container is unhealthy"
                all_healthy=false
                ;;
            *)
                _warn "container:${container}" "$container health status unknown: $health"
                ;;
        esac
    done

    if $all_healthy; then log_info "All containers healthy"; fi
}

_fix_unhealthy_containers() {
    local fix_lock_dir="${ALERT_LOCK_DIR}"
    local max_restarts="${MAX_AUTO_RESTARTS:-3}"
    local window_hours="${RESTART_COUNT_WINDOW_HOURS:-6}"

    log_info "Fix mode: attempting recovery for failed containers..."

    for name in "${check_order[@]}"; do
        [[ "${check_results[$name]:-}" == "fail" ]] || continue
        [[ "$name" == container:* ]] || continue

        local container="${name#container:}"
        local safe_name
        safe_name=$(printf '%s' "$container" | tr -cs '[:alnum:]-' '_')
        local count_file="${fix_lock_dir}/restart_count_${safe_name}"
        local window_file="${fix_lock_dir}/restart_window_${safe_name}"

        mkdir -p "$fix_lock_dir" 2>/dev/null || true

        # Reset counter when outside the rolling window
        local now; now=$(date +%s)
        local window_start=$(( now - window_hours * 3600 ))
        local window_ts; window_ts=$(cat "$window_file" 2>/dev/null || echo 0)
        if (( window_ts < window_start )); then
            printf '0\n'  > "$count_file"
            printf '%s\n' "$now" > "$window_file"
        fi

        local count; count=$(cat "$count_file" 2>/dev/null || echo 0)

        if (( count >= max_restarts )); then
            log_warn "Fix mode: ${container} suppressed — already auto-restarted ${count}x in the last ${window_hours}h. Investigate manually."
            _warn "fix:restart-limit:${container}" \
                "${container} auto-restart suppressed after ${count} attempts in ${window_hours}h — manual intervention required"
            continue
        fi

        log_warn "Fix mode: restarting ${container} (attempt $(( count + 1 ))/${max_restarts} in ${window_hours}h window)..."
        if docker restart "$container" 2>/dev/null; then
            printf '%s\n' $(( count + 1 )) > "$count_file"
            log_info "Fix mode: ${container} restarted successfully"
            sleep 8
        else
            log_error "Fix mode: failed to restart ${container}"
        fi
    done
}

# =============================================================================
# SSL CERTIFICATE CHECKS
# =============================================================================

_check_ssl() {
    local domain
    domain="$(_get_domain)"

    if [[ -z "$domain" ]]; then
        _warn "ssl:cert" "Cannot check SSL — domain not configured"
        return
    fi

    log_info "Checking SSL certificate for $domain..."

    local expiry_output
    expiry_output=$(echo | timeout "$HEALTH_TIMEOUT" openssl s_client \
        -connect "${domain}:443" \
        -servername "$domain" 2>/dev/null | \
        openssl x509 -noout -enddate 2>/dev/null) || {
        _fail "ssl:cert" "Cannot connect to ${domain}:443 for SSL check"
        return
    }

    local expiry_date expiry_epoch now_epoch days_remaining
    expiry_date="${expiry_output#notAfter=}"
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -jf "%b %e %T %Y %Z" "$expiry_date" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    days_remaining=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [[ $days_remaining -le 0 ]]; then
        _fail "ssl:cert" "SSL certificate EXPIRED for $domain (expired $expiry_date)"
    elif [[ $days_remaining -le $CERT_CRIT_DAYS ]]; then
        _fail "ssl:cert" "SSL certificate expires in ${days_remaining} days for $domain (critical threshold: ${CERT_CRIT_DAYS} days)"
    elif [[ $days_remaining -le $CERT_WARN_DAYS ]]; then
        _warn "ssl:cert" "SSL certificate expires in ${days_remaining} days for $domain (warning threshold: ${CERT_WARN_DAYS} days)"
    else
        _pass "ssl:cert" "SSL certificate valid for $domain (${days_remaining} days remaining)"
    fi

    if $COMPREHENSIVE; then
        if echo | timeout "$HEALTH_TIMEOUT" openssl s_client \
            -connect "${domain}:443" \
            -servername "$domain" \
            -verify_return_error >/dev/null 2>&1; then
            _pass "ssl:chain" "SSL certificate chain valid for $domain"
        else
            _warn "ssl:chain" "SSL chain validation warning for $domain"
        fi
    fi
}

# =============================================================================
# VAULTWARDEN API CHECKS
# =============================================================================

_check_vaultwarden_alive() {
    local domain
    domain="$(_get_domain)"

    log_info "Checking VaultWarden liveness (/alive)..."

    local alive_response
    if alive_response=$(timeout "$HEALTH_TIMEOUT" curl -sf \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        "http://127.0.0.1:80/alive" 2>/dev/null); then
        _pass "vaultwarden:alive" "VaultWarden /alive endpoint responding (response: ${alive_response:-<empty>})"
    else
        if docker exec vaultwarden_app curl -sf \
            --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
            --max-time "$HEALTH_TIMEOUT" \
            "http://127.0.0.1/alive" &>/dev/null; then
            _pass "vaultwarden:alive" "VaultWarden /alive endpoint responding (via container)"
        else
            _fail "vaultwarden:alive" "VaultWarden /alive endpoint not responding"
        fi
    fi

    if [[ -n "$domain" ]]; then
        local external_code
        external_code=$(timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
            --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
            --max-time "$HEALTH_TIMEOUT" \
            -w "%{http_code}" \
            "https://${domain}/alive" 2>/dev/null || echo "000")

        case "$external_code" in
            200) _pass "vaultwarden:external" "VaultWarden HTTPS responding (HTTP $external_code)" ;;
            301|302) _warn "vaultwarden:external" "VaultWarden HTTPS redirect (HTTP $external_code)" ;;
            000) _fail "vaultwarden:external" "VaultWarden HTTPS not reachable (connection failed)" ;;
            *) _warn "vaultwarden:external" "VaultWarden HTTPS returned HTTP $external_code" ;;
        esac
    fi
}

_check_vaultwarden_server_info() {
    local domain
    domain="$(_get_domain)"

    log_info "Checking VaultWarden readiness (/api/config)..."

    local internal_code
    internal_code=$(docker exec vaultwarden_app curl -so /dev/null \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        -w "%{http_code}" \
        "http://127.0.0.1/api/config" 2>/dev/null || echo "000")

    case "$internal_code" in
        200)
            _pass "vaultwarden:server-info" "VaultWarden /api/config responding (HTTP $internal_code)"
            ;;
        000)
            _fail "vaultwarden:server-info" "VaultWarden /api/config not reachable internally (connection failed)"
            ;;
        *)
            if [[ "${HEALTH_API_STRICT:-false}" == "true" ]]; then
                _fail "vaultwarden:server-info" "VaultWarden /api/config returned HTTP ${internal_code} (HEALTH_API_STRICT=true)"
            else
                _warn "vaultwarden:server-info" "VaultWarden /api/config returned HTTP ${internal_code} (set HEALTH_API_STRICT=true to treat as failure)"
            fi
            ;;
    esac

    if [[ -n "$domain" ]]; then
        local external_code
        external_code=$(timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
            --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
            --max-time "$HEALTH_TIMEOUT" \
            -w "%{http_code}" \
            "https://${domain}/api/config" 2>/dev/null || echo "000")

        case "$external_code" in
            200)
                _pass "vaultwarden:server-info:external" "VaultWarden /api/config HTTPS responding (HTTP $external_code)"
                ;;
            000)
                _fail "vaultwarden:server-info:external" "VaultWarden /api/config HTTPS not reachable (connection failed)"
                ;;
            *)
                if [[ "${HEALTH_API_STRICT:-false}" == "true" ]]; then
                    _fail "vaultwarden:server-info:external" "VaultWarden /api/config HTTPS returned HTTP ${external_code} (HEALTH_API_STRICT=true)"
                else
                    _warn "vaultwarden:server-info:external" "VaultWarden /api/config HTTPS returned HTTP ${external_code}"
                fi
                ;;
        esac
    fi

    if $COMPREHENSIVE && [[ -n "$domain" ]]; then
        local comp_code
        comp_code=$(timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
            --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
            --max-time "$HEALTH_TIMEOUT" \
            -w "%{http_code}" \
            "https://${domain}/api/config" 2>/dev/null || echo "000")
        case "$comp_code" in
            200) _pass "vaultwarden:api" "VaultWarden API endpoint responding (HTTP $comp_code)" ;;
            *) _warn "vaultwarden:api" "VaultWarden API returned HTTP $comp_code" ;;
        esac
    fi
}

# =============================================================================
# FAIL2BAN CHECKS
# =============================================================================

_check_fail2ban() {
    log_info "Checking Fail2Ban..."

    local initial_container_health
    initial_container_health=$(docker inspect \
        --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
        vaultwarden_fail2ban 2>/dev/null || echo "unknown")

    local attempt ping_result
    for (( attempt=1; attempt<=FAIL2BAN_PING_RETRIES; attempt++ )); do
        if ping_result=$(docker exec vaultwarden_fail2ban fail2ban-client ping 2>/dev/null); then
            if echo "$ping_result" | grep -q pong; then
                _pass "fail2ban:daemon" "Fail2Ban daemon responding to ping"
                break
            else
                _warn "fail2ban:daemon" "Fail2Ban ping response unexpected: $ping_result"
                return
            fi
        fi

        if [[ $attempt -lt $FAIL2BAN_PING_RETRIES ]]; then
            log_info "Fail2Ban ping attempt ${attempt}/${FAIL2BAN_PING_RETRIES} failed — retrying in ${FAIL2BAN_PING_DELAY}s..."
            sleep "$FAIL2BAN_PING_DELAY"
        fi
    done

    if [[ -z "${check_results[fail2ban:daemon]:-}" ]]; then
        local current_container_health
        current_container_health=$(docker inspect \
            --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
            vaultwarden_fail2ban 2>/dev/null || echo "unknown")

        if [[ "$initial_container_health" == "starting" || "$current_container_health" == "starting" ]]; then
            _warn "fail2ban:daemon" \
                "Fail2Ban daemon not yet responding (container was starting when check began — retried ${FAIL2BAN_PING_RETRIES}x${FAIL2BAN_PING_DELAY}s; will resolve automatically)"
        else
            _fail "fail2ban:daemon" \
                "Fail2Ban daemon not responding to ping after ${FAIL2BAN_PING_RETRIES} attempts (container health: ${current_container_health})"
        fi
        return
    fi

    if $COMPREHENSIVE; then
        local jails_output
        jails_output=$(docker exec vaultwarden_fail2ban fail2ban-client status 2>/dev/null || echo "")
        if [[ -n "$jails_output" ]]; then
            _pass "fail2ban:jails" "Fail2Ban jails status retrieved"
        else
            _warn "fail2ban:jails" "Cannot retrieve Fail2Ban jail status"
        fi

        _check_fail2ban_filter_drift
    fi
}

_check_fail2ban_filter_drift() {
    local log_file="/var/log/vaultwarden/vaultwarden.log"
    local filter_conf="/etc/fail2ban/filter.d/vaultwarden-auth.conf"

    log_info "Checking Fail2Ban filter regex drift (vaultwarden-auth)..."

    if ! docker exec vaultwarden_fail2ban test -f "$log_file" 2>/dev/null; then
        _warn "fail2ban:filter-drift" \
            "Cannot run filter drift check — log file not found inside container: ${log_file}"
        return
    fi
    if ! docker exec vaultwarden_fail2ban test -f "$filter_conf" 2>/dev/null; then
        _warn "fail2ban:filter-drift" \
            "Cannot run filter drift check — filter conf not found inside container: ${filter_conf}"
        return
    fi

    local log_lines
    log_lines=$(docker exec vaultwarden_fail2ban wc -l < "$log_file" 2>/dev/null || echo 0)
    if [[ "$log_lines" -lt 10 ]]; then
        _warn "fail2ban:filter-drift" \
            "Skipping filter drift check — log file has fewer than 10 lines (${log_lines}); may be freshly rotated"
        return
    fi

    local regex_output match_count
    regex_output=$(docker exec vaultwarden_fail2ban \
        fail2ban-regex "$log_file" "$filter_conf" 2>&1 || true)

    match_count=$(echo "$regex_output" \
        | grep -oP '(?<=,\s)\d+(?=\s+matched)' \
        | head -1 || echo 0)

    if [[ "$match_count" -eq 0 ]]; then
        _warn "fail2ban:filter-drift" \
            "vaultwarden-auth filter matched 0 lines in a ${log_lines}-line log — datepattern or failregex may have drifted. Run: docker exec vaultwarden_fail2ban fail2ban-regex ${log_file} ${filter_conf}"
    else
        _pass "fail2ban:filter-drift" \
            "vaultwarden-auth filter matched ${match_count} lines — filter is aligned with log format"
    fi
}

# =============================================================================
# DISK SPACE CHECKS
# =============================================================================

_check_disk() {
    log_info "Checking disk space..."

    local state_dir; state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"

    # Resolve mount points to detect shared filesystems
    local state_mount root_mount
    state_mount=$(df --output=target "$state_dir" 2>/dev/null | tail -1 || echo "")
    root_mount=$(df --output=target / 2>/dev/null | tail -1 || echo "/")

    local usage_pct
    usage_pct=$(df "$state_dir" 2>/dev/null \
        | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0")

    if (( usage_pct >= DISK_CRIT_THRESHOLD )); then
        _fail "disk:state" \
            "Disk usage critical: ${usage_pct}% on ${state_dir} (mount: ${state_mount}) — threshold: ${DISK_CRIT_THRESHOLD}%"
    elif (( usage_pct >= DISK_WARN_THRESHOLD )); then
        _warn "disk:state" \
            "Disk usage warning: ${usage_pct}% on ${state_dir} (mount: ${state_mount}) — threshold: ${DISK_WARN_THRESHOLD}%"
    else
        _pass "disk:state" \
            "Disk OK: ${usage_pct}% on ${state_dir} (mount: ${state_mount})"
    fi

    # Only check root separately if it is on a different filesystem
    if [[ -n "$state_mount" && "$state_mount" != "$root_mount" ]]; then
        local root_usage
        root_usage=$(df / 2>/dev/null \
            | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0")
        if (( root_usage >= DISK_CRIT_THRESHOLD )); then
            _fail "disk:root" \
                "Root partition critical: ${root_usage}% on / — threshold: ${DISK_CRIT_THRESHOLD}%"
        elif (( root_usage >= DISK_WARN_THRESHOLD )); then
            _warn "disk:root" \
                "Root partition warning: ${root_usage}% on / — threshold: ${DISK_WARN_THRESHOLD}%"
        else
            _pass "disk:root" "Root partition OK: ${root_usage}% on /"
        fi
    fi
}

# =============================================================================
# MEMORY CHECKS
# =============================================================================

_check_memory() {
    log_info "Checking memory..."

    local mem_total mem_available mem_used_pct
    mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    mem_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)

    if [[ $mem_total -gt 0 ]]; then
        mem_used_pct=$(( (mem_total - mem_available) * 100 / mem_total ))

        if [[ $mem_used_pct -ge $MEM_CRIT_THRESHOLD ]]; then
            _fail "memory:usage" "Memory critical: ${mem_used_pct}% used (threshold: ${MEM_CRIT_THRESHOLD}%)"
        elif [[ $mem_used_pct -ge $MEM_WARN_THRESHOLD ]]; then
            _warn "memory:usage" "Memory warning: ${mem_used_pct}% used (threshold: ${MEM_WARN_THRESHOLD}%)"
        else
            _pass "memory:usage" "Memory OK: ${mem_used_pct}% used"
        fi
    else
        _warn "memory:usage" "Cannot read memory information from /proc/meminfo"
    fi
}

# =============================================================================
# NETWORK CONNECTIVITY CHECKS
# =============================================================================

_check_network() {
    log_info "Checking network connectivity..."

    if timeout "$HEALTH_TIMEOUT" curl -sf \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        "https://1.1.1.1" &>/dev/null || \
       timeout "$HEALTH_TIMEOUT" curl -sf \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        "https://cloudflare.com" &>/dev/null; then
        _pass "network:outbound" "Outbound internet connectivity OK"
    else
        _warn "network:outbound" "Outbound internet connectivity check failed (Cloudflare unreachable)"
    fi

    local cf_code
    cf_code=$(timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        -w "%{http_code}" \
        "https://api.cloudflare.com/" 2>/dev/null || echo "000")
    case "$cf_code" in
        200|301|302|400|401|403) _pass "network:cloudflare" "Cloudflare API reachable (HTTP $cf_code)" ;;
        *) _warn "network:cloudflare" "Cloudflare API not reachable (HTTP $cf_code)" ;;
    esac
}

# =============================================================================
# SMTP SIDECAR HEALTH CHECK
# =============================================================================

_check_smtp() {
    log_info "Checking Postfix SMTP sidecar on port 587..."

    # Skip only when using a direct external relay with no local sidecar:
    # SMTP_PASSWORD set (credentials for external relay) AND
    # VW_SMTP_HOST_PORT not set (no local sidecar address configured).
    if [[ -n "${SMTP_PASSWORD:-}" && -z "${VW_SMTP_HOST_PORT:-}" ]]; then
        _pass "smtp:sidecar" "Direct external SMTP relay configured — sidecar check skipped"
        return
    fi

    local sidecar_addr="${VW_SMTP_HOST_PORT:-127.0.0.1:587}"
    local sidecar_host="${sidecar_addr%:*}"
    local sidecar_port="${sidecar_addr##*:}"

    # Port probe
    local port_open=false
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 3 "$sidecar_host" "$sidecar_port" >/dev/null 2>&1 && port_open=true
    elif (echo >/dev/tcp/"$sidecar_host"/"$sidecar_port") >/dev/null 2>&1; then
        port_open=true
    else
        _warn "smtp:sidecar" "Cannot probe port ${sidecar_addr} — nc not available and /dev/tcp failed"
        return
    fi

    if ! $port_open; then
        _fail "smtp:sidecar" \
            "Postfix sidecar not listening on ${sidecar_addr} — email delivery will fail silently"
        return
    fi

    # Banner probe: confirm it's actually an SMTP server, not a stray process
    local banner=""
    if command -v nc >/dev/null 2>&1; then
        banner=$(printf 'QUIT\r\n' | nc -w 3 "$sidecar_host" "$sidecar_port" 2>/dev/null \
            | head -1 | tr -d '\r' || true)
    fi

    if [[ "$banner" == "220"* ]]; then
        _pass "smtp:sidecar" \
            "Postfix sidecar healthy on ${sidecar_addr} (banner: ${banner:0:60})"
    elif [[ -n "$banner" ]]; then
        _warn "smtp:sidecar" \
            "Postfix sidecar port open but unexpected banner: '${banner:0:60}'"
    else
        _pass "smtp:sidecar" \
            "Postfix sidecar port ${sidecar_addr} open (banner unavailable)"
    fi
}

# =============================================================================
# DNS RESOLUTION CHECKS
# =============================================================================

_check_dns() {
    local domain
    domain="$(_get_domain)"

    if [[ -z "$domain" ]]; then
        _warn "dns:resolution" "Cannot check DNS — domain not configured"
        return
    fi

    log_info "Checking DNS resolution for $domain..."

    local resolved_ip
    if resolved_ip=$(timeout "$HEALTH_TIMEOUT" dig +short "$domain" 2>/dev/null | grep -v '^;' | head -1) && [[ -n "$resolved_ip" ]]; then
        _pass "dns:resolution" "DNS resolves $domain → $resolved_ip"
    elif resolved_ip=$(timeout "$HEALTH_TIMEOUT" nslookup "$domain" 2>/dev/null | awk '/^Address/ && NR>1 {print $2}' | head -1) && [[ -n "$resolved_ip" ]]; then
        _pass "dns:resolution" "DNS resolves $domain → $resolved_ip (via nslookup)"
    else
        _fail "dns:resolution" "DNS resolution failed for $domain"
    fi
}

# =============================================================================
# BACKUP STATUS CHECKS
# =============================================================================

_check_backups() {
    log_info "Checking backup status..."

    local backup_dir; backup_dir="$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")"
    local now_epoch
    now_epoch=$(date +%s)

    if [[ ! -d "$backup_dir" ]]; then
        _warn "backup:dir" "Backup directory not found: $backup_dir"
        return
    fi

    # Check each backup type independently so that stale full backups are not
    # masked by a recent db backup.  A daily db backup passing the 26 h check
    # would previously hide a full backup that hadn't run in 45+ days.
    local -A max_age_hours=([db]=26 [full]=168)  # db: 26 h; full: 7 days

    local any_found=false
    for btype in db full; do
        local type_dir="$backup_dir/$btype"
        if [[ ! -d "$type_dir" ]]; then
            _warn "backup:${btype}" "No $btype backup directory found: $type_dir"
            continue
        fi

        local latest_file
        latest_file=$(find "$type_dir" -maxdepth 1 -name '*.age' -type f \
            -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

        if [[ -z "$latest_file" ]]; then
            _warn "backup:${btype}" "No $btype backups found in $type_dir"
            continue
        fi

        any_found=true
        local mtime age_h
        mtime=$(stat -c %Y "$latest_file" 2>/dev/null || stat -f %m "$latest_file" 2>/dev/null || echo 0)
        age_h=$(( (now_epoch - mtime) / 3600 ))

        if (( age_h > max_age_hours[$btype] )); then
            _warn "backup:${btype}" \
                "$btype backup is ${age_h}h old (threshold: ${max_age_hours[$btype]}h): $(basename "$latest_file")"
        else
            _pass "backup:${btype}" \
                "$btype backup is ${age_h}h old: $(basename "$latest_file")"
        fi
    done

    [[ "$any_found" == "false" ]] && _warn "backup:age" "No backup archives found in $backup_dir"
}

# =============================================================================
# CONFIGURATION VALIDATION
# =============================================================================

_check_config() {
    log_info "Checking configuration..."

    local config_issues=()

    if [[ ! -f "$ENV_FILE" ]]; then
        config_issues+=("Missing env file: $ENV_FILE")
    elif [[ ! -r "$ENV_FILE" ]]; then
        config_issues+=("$ENV_FILE is not readable by $(id -un) — run: sudo chown $(id -un):$(id -gn) $ENV_FILE")
    else
        local required_vars=("DOMAIN" "ADMIN_EMAIL" "CLOUDFLARE_ZONE_ID")
        for var in "${required_vars[@]}"; do
            [[ -n "${!var:-}" ]] || config_issues+=("${var} is not set — verify '${var}=' is present in ${ENV_FILE}")
        done
    fi

    local secrets_dir="${SCRIPT_DIR}/secrets/.docker_secrets"
    if [[ -d "$secrets_dir" ]]; then
        local required_secrets=("admin_token" "caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token")
        for secret in "${required_secrets[@]}"; do
            [[ -f "${secrets_dir}/${secret}" ]] || config_issues+=("Missing secret: $secret")
        done
    fi

    # --- Age encryption key validation ---
    local age_key_file="${SOPS_AGE_KEY_FILE:-${SCRIPT_DIR}/secrets/keys/age-key.txt}"
    if [[ ! -f "$age_key_file" ]]; then
        config_issues+=("Age key not found: ${age_key_file} — backups cannot encrypt. Run: ./edit-secrets.sh --init-key")
    elif [[ ! -r "$age_key_file" ]]; then
        config_issues+=("Age key not readable: ${age_key_file} — check file permissions")
    else
        if ! grep -q '^AGE-SECRET-KEY-' "$age_key_file" 2>/dev/null; then
            config_issues+=("Age key malformed or empty: ${age_key_file} — missing AGE-SECRET-KEY line")
        else
            local age_key_perms
            age_key_perms=$(stat -c '%a' "$age_key_file" 2>/dev/null || echo "unknown")
            if [[ "$age_key_perms" != "600" && "$age_key_perms" != "400" ]]; then
                _warn "config:age-key" \
                    "Age key has insecure permissions (${age_key_perms}): ${age_key_file} — run: chmod 600 '${age_key_file}'"
            else
                _pass "config:age-key" \
                    "Age key present and valid (${age_key_file}, perms: ${age_key_perms})"
            fi
        fi
    fi

    local root_owned_issues=()
    for f in ".env" "Makefile" "startup.sh" "backup.sh" "edit-secrets.sh"; do
        local fpath="${SCRIPT_DIR}/${f}"
        if [[ -e "$fpath" ]]; then
            local owner
            owner=$(stat -c '%U' "$fpath" 2>/dev/null || echo "unknown")
            if [[ "$owner" == "root" ]]; then
                root_owned_issues+=("${f} is owned by root — run: sudo make fix-permissions")
            fi
        fi
    done
    if [[ ${#root_owned_issues[@]} -gt 0 ]]; then
        local _pi=0
        for issue in "${root_owned_issues[@]}"; do
            _warn "permissions:project-files:${_pi}" "$issue"
            (( _pi++ )) || true
        done
    elif [[ -f "${SCRIPT_DIR}/.env" || -f "${SCRIPT_DIR}/Makefile" ]]; then
        _pass "permissions:project-files" "Project file ownership is correct"
    fi

    if [[ ${#config_issues[@]} -eq 0 ]]; then
        _pass "config:validation" "Configuration validation passed"
    else
        local _ci=0
        for issue in "${config_issues[@]}"; do
            _fail "config:validation:${_ci}" "$issue"
            (( _ci++ )) || true
        done
    fi
}

# =============================================================================
# NOTIFY-FAILURE DEAD-LETTER CHECKS
# =============================================================================

_check_notify_failures() {
    local state_dir; state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    local -a markers=()
    mapfile -t markers < <(find "$state_dir" -maxdepth 1 -name 'NOTIFY_FAILED_*' 2>/dev/null | sort)

    if [[ ${#markers[@]} -eq 0 ]]; then
        _pass "notify:dead-letter" "No lost failure notifications"
        return
    fi

    for marker in "${markers[@]}"; do
        local unit="${marker##*/NOTIFY_FAILED_}"
        _fail "notify:dead-letter:${unit}" \
            "SMTP was down when ${unit} failed — notification lost. Investigate and remove: ${marker}"
    done
}

# =============================================================================
# COMPREHENSIVE CHECKS
# =============================================================================

_check_container_resources() {
    log_info "Checking container resource usage..."

    local stats
    stats=$(docker stats --no-stream --format \
        'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' \
        2>/dev/null) || {
        _warn "resources:stats" "Cannot retrieve container resource stats"
        return
    }

    log_debug "Container resource stats:
${stats}"
    _pass "resources:stats" "Container resource stats retrieved"
}

# =============================================================================
# NOTIFICATION (with per-key alert cooldown)
# =============================================================================

_send_notification() {
    local subject="$1" body="$2"

    if [[ "${_email_available:-true}" == "false" ]]; then
        log_warn "Email notifications not available"
        return
    fi

    if [[ -z "${ADMIN_EMAIL:-}" ]]; then
        log_warn "ADMIN_EMAIL not set — cannot send health notification"
        return 1
    fi

    if ! send_email "$ADMIN_EMAIL" "$subject" "$body" 2>/dev/null; then
        log_warn "Failed to send health notification email"
        return 1
    fi

    return 0
}

# _notify_failures — fixed version
_notify_failures() {
    local alerted_any=false

    for name in "${check_order[@]}"; do
        local status="${check_results[$name]:-}"
        [[ "$status" == "fail" || "$status" == "warn" ]] || continue

        if ! _acquire_alert_lock "$name"; then
            log_info "Alert cooldown active for '${name}' — suppressing repeat notification"
            continue
        fi

        local message="${check_messages[$name]:-}"
        local alert_date subject body
        alert_date="$(date)"

        subject="VaultWarden Health [${status^^}]: ${name} on $(hostname)"
        printf -v body \
            'Health check alert at %s\n\nCheck : %s\nStatus: %s\nDetail: %s\n\nThis alert will not repeat for %ss (%s min).\nRun '\''./maintenance.sh health --report'\'' for full status.' \
            "$alert_date" "$name" "${status^^}" "$message" \
            "$ALERT_COOLDOWN_SECONDS" "$(( ALERT_COOLDOWN_SECONDS / 60 ))"

        # NOTE: clear_email_rate_limit removed from here.
        # The flock/timestamp cooldown (above) is the deduplication layer.
        # Clearing the rate-limit stamp before sending defeated both guards
        # simultaneously on delivery failure, causing alert storms.

        if ! _send_notification "$subject" "$body"; then
            log_warn "_notify_failures: delivery failed for '${name}' — releasing cooldown for retry next cycle"
            _release_alert_lock "$name"
            continue
        fi

        alerted_any=true
        log_info "Alert sent for '${name}' (${status})"
    done

    if [[ "$alerted_any" == "true" ]]; then
        log_debug "_notify_failures: at least one alert was sent this cycle"
    fi

    if [[ $failed -gt 0 || $warnings -gt 0 ]]; then
        _release_recovery_lock
    fi
}

# _notify_recovery — updated to use ALERT_RECOVERY_TTL via _acquire_alert_lock
_notify_recovery() {
    [[ $failed -eq 0 && $warnings -eq 0 ]] || return 0

    if ! _acquire_alert_lock "recovery" "${ALERT_RECOVERY_TTL}"; then
        log_info "Recovery notification already sent within TTL — suppressing"
        return 0
    fi

    local recovery_date subject body
    recovery_date="$(date)"
    subject="VaultWarden Health RECOVERED on $(hostname)"
    printf -v body \
        'All health checks passed at %s\n\nPassed : %s\nWarnings: 0\nFailed : 0\n\nNo further alerts will fire until the next failure.' \
        "$recovery_date" "$passed"

    _send_notification "$subject" "$body" || true
    log_info "Recovery notification sent"
}

# =============================================================================
# REPORT GENERATION
# =============================================================================

_generate_report() {
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local report_file="${REPORT_DIR}/health_${timestamp}.txt"

    mkdir -p "$REPORT_DIR" 2>/dev/null || true

    {
        echo "VaultWarden Health Report"
        echo "Generated: $(date)"
        echo "Host: $(hostname)"
        echo "Mode: $( $COMPREHENSIVE && echo comprehensive || echo standard )"
        echo "================================================================="
        echo ""
        echo "SUMMARY: $passed passed, $warnings warnings, $failed failed (total: $total)"
        echo ""

        for name in "${check_order[@]}"; do
            local status="${check_results[$name]:-unknown}"
            local message="${check_messages[$name]:-no message}"
            printf '%-10s %-40s %s\n' "[$status]" "$name" "$message"
        done

        if $COMPREHENSIVE; then
            echo ""
            echo "CONTAINER RESOURCES:"
            docker stats --no-stream 2>/dev/null || echo "  (unavailable)"
        fi
    } > "$report_file" 2>/dev/null

    log_info "Report saved to: $report_file"

    find "$REPORT_DIR" -name 'health_*.txt' \
        -mtime +"$REPORT_RETENTION_DAYS" -delete 2>/dev/null || true
}

# =============================================================================
# OUTPUT
# =============================================================================

_print_results() {
    if $QUIET && [[ $failed -eq 0 && $warnings -eq 0 ]]; then
        return
    fi

    echo ""
    echo "================================================================="
    echo " VaultWarden Health Check Results"
    echo "================================================================="

    local status_color
    for name in "${check_order[@]}"; do
        local status="${check_results[$name]:-unknown}"
        local message="${check_messages[$name]:-}"

        case "$status" in
            pass) status_color="${COLOR_GREEN:-}" ;;
            warn) status_color="${COLOR_YELLOW:-}" ;;
            fail) status_color="${COLOR_RED:-}" ;;
            *)    status_color="" ;;
        esac

        printf '%s[%-4s]%s %-40s %s\n' \
            "$status_color" "$status" "${COLOR_RESET:-}" "$name" "$message"
    done

    echo "-----------------------------------------------------------------"
    printf 'Total: %d | Passed: %s%d%s | Warnings: %s%d%s | Failed: %s%d%s\n' \
        "$total" \
        "${COLOR_GREEN:-}" "$passed"   "${COLOR_RESET:-}" \
        "${COLOR_YELLOW:-}" "$warnings" "${COLOR_RESET:-}" \
        "${COLOR_RED:-}"   "$failed"   "${COLOR_RESET:-}"
    echo "================================================================="
}

# =============================================================================
# MAIN
# =============================================================================

_health_main() {
    _acquire_run_lock
    trap '_release_run_lock' EXIT HUP INT TERM
    _health_parse_args "$@"

    log_info "Starting VaultWarden health check..."
    if $COMPREHENSIVE; then
        log_info "Mode: comprehensive"
    else
        log_info "Mode: standard"
    fi

    _check_containers
    _check_ssl
    _check_vaultwarden_alive
    _check_vaultwarden_server_info
    _check_fail2ban
    _check_disk
    _check_memory
    _check_network
    _check_smtp
    _check_dns
    _check_backups
    _check_config
    _check_notify_failures

    if $COMPREHENSIVE; then
        _check_container_resources
    fi

    if $FIX_MODE && [[ $failed -gt 0 ]]; then
        log_info "Fix mode enabled — attempting recovery..."
        _fix_unhealthy_containers
    fi

    _print_results

    if $REPORT_MODE; then
        _generate_report
    fi

    _notify_failures
    _notify_recovery

    if [[ $failed -gt 0 ]]; then
        exit 2
    elif [[ $warnings -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

    _health_main "$@"
}

# ---------------------------------------------------------------------------
# run_update
# ---------------------------------------------------------------------------
run_update() {
local UPDATE_SYSTEM=false
local UPDATE_IMAGES=false
local FORCE=false
local DRY_RUN=false
local SKIP_BACKUP=false
local EMAIL_NOTIFY=false

_update_show_help() {
    cat << 'EOF'
VaultWarden-OCI Update Script

USAGE:
    sudo ./maintenance.sh update [OPTIONS]

OPTIONS:
    --system         Update system packages (apt upgrade)
    --images         Update Docker images only
    --all            Update system packages + Docker images
    --force          Force update even if images are up to date
    --dry-run        Show what would be done without executing
    --skip-backup    Skip pre-update safety backup
    --email          Send email notification on completion/failure

EXAMPLES:
    sudo ./maintenance.sh update --system        # Update system packages only
    sudo ./maintenance.sh update --images        # Update Docker images only
    sudo ./maintenance.sh update --all           # Full system + image update
    sudo ./maintenance.sh update --all --email   # Full update with email notification
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
        *)             log_error "Unknown option: $1"; _update_show_help; exit 1 ;;
    esac
done

if [[ "$UPDATE_SYSTEM" == "false" && "$UPDATE_IMAGES" == "false" ]]; then
    log_error "Specify at least one of: --system, --images, --all"
    _update_show_help
    exit 1
fi

# ---------------------------------------------------------------------------
# ensure_caddy_entrypoint_executable
#
# Docker preserves host filesystem permission bits exactly; if the file lacks
# the execute bit the OCI runtime fails with 'permission denied' before the
# container process can start. This can happen after:
#   - 'git pull' run with a restrictive umask (e.g. 0027 -> mode 640)
#   - Any chmod 644/640 sweep over the repo directory
#   - rsync/scp from a source where the bit was lost
# startup.sh already guards this inside prepare_log_directories(); this
# function mirrors that guard so the update subcommand is also resilient.
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
        log_warn "     Run: sudo ./setup.sh systemd install"
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
    # Add explicit dpkg conffile options to prevent interactive
    # prompts when a package upgrade finds a modified config file.
    # --force-confdef: accept the default (keep or replace) automatically.
    # --force-confold: keep the existing config if no default is defined.
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    # If Docker itself was upgraded by apt, the daemon may need a restart.
    # Attempting 'docker version' against the (now-stopped) old daemon returns
    # an empty Server.Version, indicating the daemon needs to be restarted
    # before 'docker compose pull' is safe to run.
    if systemctl is-active docker >/dev/null 2>&1; then
        if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
            log_warn "Docker daemon unreachable after package update — restarting daemon..."
            if systemctl restart docker; then
                sleep 5
                if docker version >/dev/null 2>&1; then
                    log_success "Docker daemon restarted successfully after package upgrade"
                else
                    log_error "CRITICAL: Docker daemon unhealthy after restart — manual intervention required"
                    return 1
                fi
            else
                log_error "CRITICAL: Docker daemon failed to restart after package upgrade"
                return 1
            fi
        fi
    fi

    if [[ -f /var/run/reboot-required ]]; then
        log_warn "A system reboot is required due to package updates."
        log_warn "Schedule a maintenance window: sudo systemctl reboot"
        if [[ "${EMAIL_NOTIFY:-false}" == "true" ]]; then
            send_notification_email \
                "VaultWarden Host: Reboot Required on $(hostname)" \
                "$(printf 'A reboot is required on %s after package updates.\nSchedule a maintenance window to apply the kernel/library update.\n' "$(hostname -f 2>/dev/null || hostname)")" \
                2>/dev/null || true
        fi
    fi
    log_success "System packages updated"
}

# ---------------------------------------------------------------------------
# snapshot_image_digests
#
# any pull begins.  The associative array _PRE_PULL_IDS maps image name to
# its pre-pull docker image Id.  Used by rollback_image_digests() to restore
# a coherent image set if the pull is only partially successful.
#
# Must be called before check_image_updates().
# ---------------------------------------------------------------------------
local -A _PRE_PULL_IDS=()

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
        log_error "Pull again from a stable network: sudo ./maintenance.sh update --images"
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
        # Use pull_image_with_retry() for exponential backoff and
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
            # Count missing digests as failures so caller is notified.
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
    log_info "Creating pre-update safety backup via ./backup.sh run db..."
    if "${SCRIPT_DIR}/backup.sh" run db; then
        log_success "Pre-update backup created"
        return 0
    fi
    log_error "Pre-update backup failed — aborting update to avoid an unsafe rollback point"
    return 1
}

_update_main() {
    require_root "$@"
    load_env_file || { log_error "Failed to load .env"; exit 1; }

    log_header "VaultWarden-OCI Update"

    # (e.g. wrong permissions after git pull) is surfaced here rather than
    # silently causing backup/maintenance failures later.
    check_age_key_health_for_update

    run_pre_update_backup || exit 1

    if [[ "$UPDATE_SYSTEM" == "true" ]]; then
        update_system_packages
    fi

    if [[ "$UPDATE_IMAGES" == "true" ]] || [[ "$FORCE" == "true" ]]; then
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
                body="$(printf 'A partial docker image pull was detected on host: %s\nTime: %s\n\nSome images were updated and some failed. The pulled images have been\nrolled back to their pre-pull digests to prevent a split-version stack.\n\nResolve the network or registry issue, then retry:\n  sudo ./maintenance.sh update --images\n' \
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
                body="$(printf 'All docker image pulls failed on host: %s\nTime: %s\n\nNo images were updated. Services remain on their current versions.\n\nResolve the network or registry issue, then retry:\n  sudo ./maintenance.sh update --images\n' \
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
    _update_main "$@"
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log_header "VaultWarden-OCI Maintenance Manager"

    trap 'perform_cleanup' EXIT HUP INT TERM

    local OPS_LOCK="/run/lock/vaultwarden-operations.lock"

    # ---- Deep DB maintenance: self-contained sub-command ----
    if [[ "$DB_DEEP_MAINT" == "true" ]]; then
        require_root
        # Use automatic FD allocation instead of hardcoded FD.
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
    fi

    # ---- Email diagnostic: self-contained sub-command ----
    if [[ "$TEST_EMAIL" == "true" ]]; then
        _load_env
        run_email_diagnostics
        exit $?
    fi

    # ---- Routine or targeted maintenance ----
    require_root
    # Use automatic FD allocation instead of hardcoded FD.
    local _OPS_LOCK_FD
    exec {_OPS_LOCK_FD}>"$OPS_LOCK"
    if ! flock -n "$_OPS_LOCK_FD"; then
        log_error "Another operation (update/restore/maintenance) is already running. Aborting."
        exit 1
    fi
    touch /tmp/.vw_maintenance.lock
    register_cleanup rm -f /tmp/.vw_maintenance.lock

    [[ "$DRY_RUN"       == "true" ]] && log_warn "DRY RUN MODE - No changes will be made"
    [[ "$TARGETED_MODE" == "true" ]] && log_info "Targeted mode — running requested task(s) only"
    [[ "$COMPREHENSIVE" == "true" ]] && log_info "Running comprehensive maintenance..."

    _load_env

    # Fail closed if the expected data volume is not mounted.
    require_project_state_ready || exit 1

    local log_cleanup_result=0 backup_cleanup_result=0 docker_cleanup_result=0
    local db_optimization_result=0 firewall_update_result=1 dns_update_result=1
    local health_validation_result=0

    if [[ "$TARGETED_MODE" == "false" ]]; then
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
    fi

    if [[ "$UPDATE_FIREWALL" == "true" || "$UPDATE_DNS" == "true" ]]; then
        if [[ "$TARGETED_MODE" == "true" ]]; then
            log_info "=== Targeted Task(s) ==="
        else
            log_info "=== Phase 3: SAFE Security & Network Maintenance ==="
        fi
        if [[ "$UPDATE_FIREWALL" == "true" ]]; then
            update_firewall_ranges && firewall_update_result=0 || firewall_update_result=$?
        fi
        if [[ "$UPDATE_DNS" == "true" ]]; then
            update_dns_record && dns_update_result=0 || dns_update_result=$?
        fi
    fi

    if [[ "$TARGETED_MODE" == "false" ]]; then
        log_info "=== Phase 4: Health Validation ==="
        validate_system_health || health_validation_result=$?
    fi

    log_info "=== Summary ==="
    generate_maintenance_summary \
        "$log_cleanup_result" "$backup_cleanup_result" "$docker_cleanup_result" \
        "$db_optimization_result" "$firewall_update_result" "$dns_update_result" \
        "$health_validation_result"

    local critical_failures=0
    [[ "$CLEAN_LOGS"        == "true"  && "$log_cleanup_result"       != "0" ]] && ((critical_failures++))
    [[ "$CLEAN_BACKUPS"     == "true"  && "$backup_cleanup_result"    != "0" ]] && ((critical_failures++))
    # Docker cleanup exit 1 = partial issues (warning); only exit 2 (hard failure) is critical.
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

# ---------------------------------------------------------------------------
# Argument Parsing & Execution
# Subcommand-only dispatch — no --flag aliases.
# ---------------------------------------------------------------------------

[[ $# -eq 0 ]] && { show_help; exit 0; }

_TASK="${1:-}"

case "$_TASK" in
    # ── Named subcommands ──────────────────────────────────────────────────
    health)
        shift
        run_health_check "$@"
        exit $?
        ;;
    update)
        shift
        run_update "$@"
        exit $?
        ;;
    db-maint)
        DB_DEEP_MAINT=true
        shift
        while [[ $# -gt 0 ]]; do
            case $1 in
                --force)   DB_DEEP_FORCE=true; shift ;;
                --dry-run) DRY_RUN=true;       shift ;;
                *) log_error "Unknown option for 'db-maint': $1"; show_help; exit 1 ;;
            esac
        done
        main
        exit $?
        ;;
    test-email)
        TEST_EMAIL=true
        shift
        while [[ $# -gt 0 ]]; do
            case $1 in
                --recipient) TEST_RECIPIENT="$2"; shift 2 ;;
                --verbose)   VERBOSE=true;        shift   ;;
                --dry-run)   DRY_RUN=true;        shift   ;;
                *) log_error "Unknown option for 'test-email': $1"; show_help; exit 1 ;;
            esac
        done
        main
        exit $?
        ;;
    # ── Routine maintenance entry point ────────────────────────────────────
    run)
        shift
        while [[ $# -gt 0 ]]; do
            case $1 in
                --comprehensive) COMPREHENSIVE=true; UPDATE_FIREWALL=true; UPDATE_DNS=true; shift ;;
                --no-logs)       CLEAN_LOGS=false;        shift ;;
                --no-backups)    CLEAN_BACKUPS=false;     shift ;;
                --no-docker)     CLEAN_DOCKER=false;      shift ;;
                --no-database)   OPTIMIZE_DATABASE=false; shift ;;
                --update-dns)    UPDATE_DNS=true;         shift ;;
                --update-firewall) UPDATE_FIREWALL=true;  shift ;;
                --dry-run)       DRY_RUN=true;            shift ;;
                --email)         EMAIL_NOTIFY=true;       shift ;;
                *) log_error "Unknown option for 'run': $1"; show_help; exit 1 ;;
            esac
        done
        main
        exit $?
        ;;
    # ── Targeted single-task subcommands ───────────────────────────────────
    update-dns)
        UPDATE_DNS=true
        TARGETED_MODE=true
        CLEAN_LOGS=false; CLEAN_BACKUPS=false; CLEAN_DOCKER=false; OPTIMIZE_DATABASE=false
        shift
        while [[ $# -gt 0 ]]; do
            case $1 in
                --email)   EMAIL_NOTIFY=true; shift ;;
                --dry-run) DRY_RUN=true;      shift ;;
                *) log_error "Unknown option for 'update-dns': $1"; show_help; exit 1 ;;
            esac
        done
        main
        exit $?
        ;;
    update-firewall)
        UPDATE_FIREWALL=true
        TARGETED_MODE=true
        CLEAN_LOGS=false; CLEAN_BACKUPS=false; CLEAN_DOCKER=false; OPTIMIZE_DATABASE=false
        shift
        while [[ $# -gt 0 ]]; do
            case $1 in
                --dry-run) DRY_RUN=true; shift ;;
                *) log_error "Unknown option for 'update-firewall': $1"; show_help; exit 1 ;;
            esac
        done
        main
        exit $?
        ;;
    help)
        show_help; exit 0
        ;;
    *)
        log_error "Unknown subcommand: '$_TASK'"
        log_error "Run './maintenance.sh help' for usage."
        exit 1
        ;;
esac
