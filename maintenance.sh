#!/usr/bin/env bash
# maintenance.sh - System cleanup, optimization, DNS update, and on-demand DB/Email maintenance
# Merged: db-maint.sh (on-demand deep DB maintenance) + update-dns.sh (Cloudflare DDNS) + simple-email-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/backup_utils.sh"
source "lib/crypto.sh"

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
# Help
# ---------------------------------------------------------------------------
show_help() {
    cat << 'EOF'
VaultWarden-OCI Maintenance Script

USAGE:
    ./maintenance.sh [OPTIONS]

TARGETED (single-task) OPTIONS:
    --update-dns            Check and update Cloudflare DNS A record ONLY
    --update-firewall       Update Cloudflare IP ranges in firewall ONLY

    When called with ONLY one of the above, the routine cleanup/optimization
    phases are skipped entirely. Combine with --comprehensive or routine
    flags to include them alongside.

ON-DEMAND DIAGNOSTICS & DEEP MAINTENANCE:
    --db-maint              Run deep database maintenance (VACUUM + WAL checkpoint + backup)
                            Stops the VaultWarden container; prompts for confirmation
    --db-maint --force      Skip the confirmation prompt
    --test-email            Run email diagnostics and send a test notification.
                            Supports: --dry-run, --recipient EMAIL, --verbose
                            May start the postfix container if it is stopped.
    --recipient EMAIL       Override the default admin email recipient.
                            Only meaningful with --test-email.
    --verbose               Show detailed diagnostic output.
                            Only meaningful with --test-email; ignored in all other modes.

ROUTINE MAINTENANCE OPTIONS:
    --comprehensive         Run everything: routine + firewall + DNS
    --no-logs               Skip log rotation and cleanup
    --no-backups            Skip backup cleanup
    --no-docker             Skip Docker cleanup
    --no-database           Skip scheduled database optimization
    --dry-run               Show what would be done without executing.
                            Supported by all modes including --test-email.
    --email                 Send email notification on completion
    --help                  Show this help

BEHAVIOUR OVERVIEW:
    --test-email            Run email diagnostics ONLY (no cleanup, no DB opt)
    --db-maint              Run deep DB maintenance ONLY (no cleanup, no DB opt)
    --update-dns alone      Run DNS update ONLY (no cleanup, no DB opt)
    --update-firewall alone Run firewall update ONLY (no cleanup, no DB opt)
    --comprehensive         Full routine + firewall + DNS + health check
    No flags                Show this help
    --dry-run               Preview any mode without making changes

EXAMPLES:
    ./maintenance.sh --comprehensive              # Full maintenance
    ./maintenance.sh --update-dns                 # DNS update ONLY
    ./maintenance.sh --update-dns --email         # DNS update + notify on change
    ./maintenance.sh --test-email                 # Email diagnostics
    ./maintenance.sh --test-email --verbose       # Email diagnostics (detailed)
    ./maintenance.sh --test-email --dry-run       # Preview email test without sending
    ./maintenance.sh --test-email --recipient admin@example.com
    sudo ./maintenance.sh --db-maint              # Deep DB maintenance (interactive)
    sudo ./maintenance.sh --db-maint --force      # Deep DB maintenance (non-interactive)
EOF
}

# ---------------------------------------------------------------------------
# Argument Parsing
# ---------------------------------------------------------------------------
[[ $# -eq 0 ]] && { show_help; exit 0; }

# Track which flags were explicitly set so we can detect targeted mode
_ROUTINE_OVERRIDE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --comprehensive)
            COMPREHENSIVE=true; UPDATE_FIREWALL=true; UPDATE_DNS=true
            _ROUTINE_OVERRIDE=true; shift ;;
        --no-logs)      CLEAN_LOGS=false;        _ROUTINE_OVERRIDE=true; shift ;;
        --no-backups)   CLEAN_BACKUPS=false;     _ROUTINE_OVERRIDE=true; shift ;;
        --no-docker)    CLEAN_DOCKER=false;      _ROUTINE_OVERRIDE=true; shift ;;
        --no-database)  OPTIMIZE_DATABASE=false; _ROUTINE_OVERRIDE=true; shift ;;
        --update-firewall) UPDATE_FIREWALL=true; shift ;;
        --update-dns)      UPDATE_DNS=true;      shift ;;
        --dry-run)         DRY_RUN=true;         shift ;;
        --email)           EMAIL_NOTIFY=true;    shift ;;
        --db-maint)        DB_DEEP_MAINT=true;   shift ;;
        --force)           DB_DEEP_FORCE=true;   shift ;;
        --test-email)      TEST_EMAIL=true;      shift ;;
        --recipient)       TEST_RECIPIENT="$2";  shift 2 ;;
        --verbose)         VERBOSE=true;         shift ;;
        --help)            show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if [[ "$_ROUTINE_OVERRIDE" == "false" && "$DB_DEEP_MAINT" == "false" && "$TEST_EMAIL" == "false" ]]; then
    if [[ "$UPDATE_DNS" == "true" || "$UPDATE_FIREWALL" == "true" ]]; then
        TARGETED_MODE=true
        CLEAN_LOGS=false
        CLEAN_BACKUPS=false
        CLEAN_DOCKER=false
        OPTIMIZE_DATABASE=false
    fi
fi

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
        "$PROJECT_ROOT/logs"
    )
    for log_dir in "${log_dirs[@]}"; do
        if [[ -d "$log_dir" ]]; then
            local old_logs
            if old_logs=$(find "$log_dir" -name "*.log*" -type f -mtime +"$LOG_RETENTION_DAYS" 2>/dev/null); then
                while IFS= read -r log_file; do
                    if [[ -n "$log_file" ]]; then
                        rm -f "$log_file" && ((logs_cleaned++)) && log_debug "Removed old log: $(basename "$log_file")"
                    fi
                done <<< "$old_logs"
            fi
        fi
    done
    local large_logs
    if large_logs=$(find "${log_dirs[@]}" -name "*.log" -type f -size +100M 2>/dev/null); then
        while IFS= read -r log_file; do
            if [[ -n "$log_file" ]]; then
                if [[ "$log_file" == *"/logs/caddy/access.log" ]]; then
                    log_debug "Skipping rotation for Caddy log (handled internally): $log_file"
                    continue
                fi
                local rotated_name="${log_file}.$(date +%Y%m%d)"
                if mv "$log_file" "$rotated_name" && gzip "$rotated_name"; then
                    log_debug "Rotated large log: $(basename "$log_file")"
                    ((logs_cleaned++))
                fi
            fi
        done <<< "$large_logs"
    fi
    [[ $logs_cleaned -gt 0 ]] && log_success "Cleaned up $logs_cleaned log files" || log_info "No old logs found to clean up"
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
    backup_base_dir="$(get_config_value "BACKUP_DIR" "$PROJECT_ROOT/backups")"
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
    if ! require_docker; then log_error "Docker not available for cleanup"; return 1; fi
    local cleanup_success=true
    cleanup_containers || { log_warn "Container cleanup had issues"; cleanup_success=false; }
    cleanup_images     || { log_warn "Image cleanup had issues";     cleanup_success=false; }
    log_info "Cleaning up unnamed Docker volumes..."
    docker volume prune -f >/dev/null 2>&1 || { log_warn "Volume cleanup had issues"; cleanup_success=false; }
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
    is_service_running "vaultwarden" && was_running=true || log_warn "VaultWarden not running, will optimize offline database"

    local size_bytes_before
    size_bytes_before=$(stat -c%s "$host_db_path" 2>/dev/null || echo "0")
    local size_kb_before=$(( size_bytes_before / 1024 ))
    log_info "Database size before optimization: ${size_kb_before} KB"

    if [[ "$was_running" == "true" ]]; then
        log_info "Stopping VaultWarden service..."
        docker compose stop vaultwarden || { log_error "Failed to stop VaultWarden"; return 1; }
        log_success "VaultWarden stopped"; sleep 3
    fi
    # FIX BUG-S: was data/bwdata/ — corrected to data/
    local backup_file="$state_dir/data/db.sqlite3.pre-optimization-$(date +%Y%m%d-%H%M%S)"
    cp "$host_db_path" "$backup_file" || {
        log_error "Failed to create safety backup"
        [[ "$was_running" == "true" ]] && docker compose start vaultwarden
        return 1
    }
    log_success "Safety backup created: $(basename "$backup_file")"

    log_info "Verifying integrity before optimization..."
    if ! sqlite3 "$host_db_path" "PRAGMA integrity_check;" | grep -qx "ok"; then
        log_error "Integrity check failed - aborting"
        [[ "$was_running" == "true" ]] && docker compose start vaultwarden
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
        log_error "CRITICAL: Post-optimization integrity check failed! Restoring..."
        cp "$backup_file" "$host_db_path" && log_success "Restored from backup" || log_error "CRITICAL: Restore failed!"
        optimization_success=false
    else
        log_success "Post-optimization integrity check passed"
    fi

    if [[ "$was_running" == "true" ]]; then
        docker compose start vaultwarden && log_success "VaultWarden restarted" || { log_error "Failed to restart VaultWarden"; optimization_success=false; }
        sleep 5
        is_service_running "vaultwarden" && log_success "VaultWarden healthy" || { log_error "VaultWarden not healthy after optimization"; optimization_success=false; }
    fi

    local size_bytes_after
    size_bytes_after=$(stat -c%s "$host_db_path" 2>/dev/null || echo "0")
    local size_kb_after=$(( size_bytes_after / 1024 ))

    if [[ "$optimization_success" == "true" ]]; then
        log_success "Database optimization completed. ${size_kb_before} KB → ${size_kb_after} KB"
        rm -f "$backup_file"
    else
        log_warn "Optimization completed with issues. Safety backup retained: $(basename "$backup_file")"
    fi
    return $([[ "$optimization_success" == "true" ]] && echo 0 || echo 1)
}

# ---------------------------------------------------------------------------
# ON-DEMAND: Deep database maintenance  (merged from db-maint.sh)
# ---------------------------------------------------------------------------
run_deep_db_maintenance() {
    log_info "VaultWarden Deep Database Maintenance"
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    # FIX BUG-S: was data/bwdata/db.sqlite3 — corrected to data/db.sqlite3
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

    log_info "Step 0/5: Creating pre-maintenance safety backup..."
    # FIX [M-02]: backup.sh writes log lines to stdout — do not capture stdout as a file path.
    # Capture a timestamp BEFORE running backup.sh, then find the newest db backup created after it.
    local backup_ts_marker
    backup_ts_marker=$(mktemp) && touch "$backup_ts_marker"
    if ! ./backup.sh --type db; then
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
        # Find the db backup created after our timestamp marker (most reliable approach)
        local backup_base; backup_base=$(get_config_value "BACKUP_DIR" "${PROJECT_ROOT}/backups")
        safety_backup_file=$(find "${backup_base}/db" -name "vaultwarden-db-*.age" -newer "$backup_ts_marker" 2>/dev/null | sort | tail -1) || true
        rm -f "$backup_ts_marker"
    fi

    log_info "Stopping VaultWarden container..."
    docker compose stop vaultwarden && log_success "VaultWarden container stopped" || log_warn "Failed to stop vaultwarden container"
    log_info "Waiting 5 seconds for file lock release..."; sleep 5

    log_info "Step 1/5: Checking database integrity..."
    if ! sqlite3 "$db_file" "PRAGMA integrity_check;" | grep -q "ok"; then
        log_error "Integrity check FAILED. Aborting. Restarting services..."
        docker compose start vaultwarden; return 1
    fi
    log_success "Database integrity check passed"

    log_info "Step 2/5: Committing WAL file (PRAGMA wal_checkpoint(TRUNCATE))..."
    sqlite3 "$db_file" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 && log_success "WAL checkpointed" || log_warn "Could not checkpoint WAL. Proceeding."

    log_info "Step 3/5: Optimizing database stats (PRAGMA optimize)..."
    sqlite3 "$db_file" "PRAGMA optimize;" >/dev/null 2>&1 && log_success "Optimization complete" || log_warn "Could not optimize. Proceeding."

    log_info "Step 4/5: Reclaiming free space (VACUUM)... This may take a moment."
    if ! sqlite3 "$db_file" "VACUUM;" >/dev/null 2>&1; then
        log_error "VACUUM FAILED. Aborting. Restarting services..."
        docker compose start vaultwarden; return 1
    fi
    log_success "Database VACUUM completed"

    log_info "Step 5/5: Gathering statistics..."
    local new_size new_bytes
    new_size=$(du -h "$db_file" | cut -f1)
    new_bytes=$(stat -c%s "$db_file" 2>/dev/null || echo "0")

    log_info "Restarting VaultWarden container..."
    docker compose start vaultwarden || { log_error "Failed to restart VaultWarden!"; return 1; }

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
        rm -f "$safety_backup_file" "$safety_backup_file.sha256" "$safety_backup_file.meta" 2>/dev/null \
            && log_success "Removed safety backup: $(basename "$safety_backup_file")" \
            || log_warn "Could not remove safety backup: $safety_backup_file"
    elif [[ -n "$safety_backup_file" && -f "$safety_backup_file" ]]; then
        log_warn "Maintenance did not complete successfully. Retaining safety backup: $safety_backup_file"
    fi

    return $([[ "$maintenance_successful" == "true" ]] && echo 0 || echo 1)
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

    if docker compose ps postfix >/dev/null 2>&1; then
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

    # Use docker inspect to check actual running state.
    # `docker compose ps fail2ban` always exits 0 (it lists config, not state),
    # so it cannot be used as a running-state guard.
    local f2b_running
    f2b_running=$(docker inspect vaultwarden_fail2ban --format '{{.State.Running}}' 2>/dev/null || echo "false")
    if [[ "$f2b_running" != "true" ]]; then
        log_error "❌ fail2ban container is not running"
        log_info "💡 Start it with: docker compose up -d fail2ban"
        return 1
    fi
    log_success "✅ fail2ban container is running"

    # crazymax/fail2ban uses a non-standard PATH; invoke fail2ban-client via
    # `sh -c` to ensure the shell resolves it correctly. Use `docker exec`
    # directly (by container name) — more reliable for host-network containers
    # than `docker compose exec` which requires a compose project context.
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

    local test_subject="VaultWarden Email Test - postfix - $(date)"
    local test_body="VaultWarden notification test
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
update_firewall_ranges() {
    if [[ "$UPDATE_FIREWALL" != "true" ]]; then log_info "Skipping firewall update"; return 0; fi
    if [[ "$DRY_RUN"         == "true" ]]; then log_info "[DRY RUN] Would safely update Cloudflare IP ranges in firewall"; return 0; fi
    
    require_root "$@"
    
    log_info "Safely updating Cloudflare IP ranges in firewall..."
    local cf_ipv4_file cf_ipv6_file
    cf_ipv4_file=$(mktemp -t cf_ipv4.XXXXXXXXXX)
    cf_ipv6_file=$(mktemp -t cf_ipv6.XXXXXXXXXX)
    CLEANUP_ACTIONS+=("rm -f '$cf_ipv4_file' '$cf_ipv6_file' 2>/dev/null || true")
    if retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v4" -o "$cf_ipv4_file" && \
       retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v6" -o "$cf_ipv6_file"; then
        log_success "Successfully fetched current Cloudflare IP ranges"
    else
        log_error "Failed to fetch Cloudflare IP ranges - aborting firewall update"; return 1
    fi

    _ufw_allow_range() {
        local range="$1" label="$2"
        local added=false
        if ! ufw status | grep -q "$range"; then
            ufw allow proto tcp from "$range" to any port 80  comment "${label}" >/dev/null 2>&1 && \
            ufw allow proto tcp from "$range" to any port 443 comment "${label}" >/dev/null 2>&1 && \
            added=true
        fi
        echo "$added"
    }

    local ranges_added=false

    if grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' "$cf_ipv4_file" >/dev/null; then
        log_info "Adding new Cloudflare IPv4 ranges..."
        while IFS= read -r range; do
            if [[ -n "$range" && "$range" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
                result=$(_ufw_allow_range "$range" "CF-IPv4-NEW")
                [[ "$result" == "true" ]] && ranges_added=true && log_debug "Added IPv4 range: $range"
            fi
        done < "$cf_ipv4_file"
    fi

    if grep -E '^[0-9a-fA-F:]+/[0-9]{1,3}$' "$cf_ipv6_file" >/dev/null; then
        log_info "Adding new Cloudflare IPv6 ranges..."
        while IFS= read -r range; do
            if [[ -n "$range" && "$range" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]]; then
                result=$(_ufw_allow_range "$range" "CF-IPv6-NEW")
                [[ "$result" == "true" ]] && ranges_added=true && log_debug "Added IPv6 range: $range"
            fi
        done < "$cf_ipv6_file"
    fi

    if [[ "$ranges_added" == "true" ]]; then
        log_success "New Cloudflare IP ranges added successfully"
        log_info "Removing outdated Cloudflare IP ranges..."
        local old_rules removed_count=0
        if old_rules=$(ufw status numbered | grep -E "CF-IPv[46]" | grep -v "CF-IPv[46]-NEW" | awk '{print $1}' | sed 's/\[//g' | sed 's/\]//g' | sort -rn); then
            while IFS= read -r rule_num; do
                [[ -n "$rule_num" ]] && echo "y" | ufw delete "$rule_num" >/dev/null 2>&1 && ((removed_count++))
            done <<< "$old_rules"
            [[ $removed_count -gt 0 ]] && log_success "Removed $removed_count outdated firewall rules"
        fi
        log_success "Firewall IP ranges updated safely"
    else
        log_info "No new IP ranges needed to be added"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# TARGETED: DNS update
# ---------------------------------------------------------------------------
update_dns_record() {
    if [[ "$UPDATE_DNS" != "true" ]]; then log_info "Skipping DNS update"; return 0; fi
    if [[ "$DRY_RUN"    == "true" ]]; then log_info "[DRY RUN] Would check and update Cloudflare DNS A record"; return 0; fi

    local domain="${DOMAIN:-}"
    domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')
    local zone_id="${CLOUDFLARE_ZONE_ID:-}"
    [[ -z "$domain"  ]] && { log_error "DOMAIN not set in .env"; return 1; }
    [[ -z "$zone_id" ]] && { log_error "CLOUDFLARE_ZONE_ID not set in .env"; return 1; }

    local lock_dir="${PROJECT_ROOT}/.locks"
    local DNS_LOCK="${lock_dir}/dns-update.lock"
    ensure_dir "$lock_dir" 700 "$(get_real_user)" || {
        log_error "Failed to initialize lock directory: $lock_dir"
        return 1
    }

    exec 242>"$DNS_LOCK"
    if ! flock -n 242; then
        log_info "DNS update already in progress (lock: $DNS_LOCK). Skipping."
        return 0
    fi

    log_info "Checking if DNS update needed for $domain..."
    local current_ip
    current_ip=$(curl -s --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '\n\r ') || true
    [[ -z "$current_ip" ]] && { log_error "Cannot determine current external IP"; return 1; }
    [[ ! "$current_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && { log_error "Invalid IP format: $current_ip"; return 1; }

    local dns_ip
    dns_ip=$(dig +short "$domain" @1.1.1.1 2>/dev/null | head -1) || { log_error "Cannot resolve DNS for $domain"; return 1; }
    [[ -z "$dns_ip" ]] && { log_warn "No DNS record found for $domain, proceeding with update"; dns_ip="(none)"; }

    if [[ "$current_ip" == "$dns_ip" ]]; then
        log_success "DNS record up to date: $domain -> $current_ip"; return 0
    fi
    log_info "DNS update needed: $dns_ip -> $current_ip"

    # FIX [H-01]: Read token from host secret file first; fall back to running container.
    # Reading from the container fails when Caddy is stopped (e.g., during maintenance).
    local token_file="${PROJECT_ROOT}/secrets/.docker_secrets/caddy_cloudflare_dns_token"
    local cf_token
    if [[ -f "$token_file" ]]; then
        cf_token=$(cat "$token_file") || { log_error "Cannot read Cloudflare API token from host secret file"; return 1; }
    else
        cf_token=$(docker compose exec -T caddy cat /run/secrets/caddy_cloudflare_dns_token 2>/dev/null) \
            || { log_error "Cannot read Cloudflare API token (host file: $token_file not found, Caddy container may be stopped)"; return 1; }
    fi
    [[ -z "$cf_token" ]] && { log_error "Cloudflare API token is empty"; return 1; }

    local record_id
    record_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$domain" \
                -H "Authorization: Bearer $cf_token" -H "Content-Type: application/json" | \
                jq -r '.result[0].id // empty' 2>/dev/null)
    [[ -z "$record_id" ]] && { log_error "Cannot find DNS record ID for $domain"; return 1; }

    local response
    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
               -H "Authorization: Bearer $cf_token" -H "Content-Type: application/json" \
               --data "{\"type\":\"A\",\"name\":\"$domain\",\"content\":\"$current_ip\",\"ttl\":300}")

    if echo "$response" | jq -e '.success' >/dev/null 2>&1; then
        log_success "DNS updated successfully: $domain -> $current_ip"
        if [[ "$EMAIL_NOTIFY" == "true" ]]; then
            local admin_email; admin_email=$(get_config_value "ADMIN_EMAIL" "")
            if [[ -n "$admin_email" ]]; then
                send_notification_email "VaultWarden IP Address Changed" \
"Old IP: $dns_ip
New IP: $current_ip
Domain: $domain
DNS record updated automatically." \
                    && log_info "DNS change notification sent" \
                    || log_warn "Failed to send DNS change notification email"
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
    ./health.sh --quiet && { log_success "System health validation passed"; return 0; } || { log_warn "System health validation detected issues"; return 1; }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
generate_maintenance_summary() {
    local log_cleanup="$1" backup_cleanup="$2" docker_cleanup="$3"
    local db_optimization="$4" firewall_update="$5" dns_update="$6" health_validation="$7"

    local summary="VaultWarden Maintenance Summary - $(date)\n\nMaintenance Results:\n"

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
    [[ "$CLEAN_LOGS"    == "true" && "$log_cleanup"    != "0" ]] && ((critical_failures++))
    [[ "$CLEAN_BACKUPS" == "true" && "$backup_cleanup" != "0" ]] && ((critical_failures++))
    [[ "$CLEAN_DOCKER"  == "true" && "$docker_cleanup" == "2" ]] && ((critical_failures++))
    [[ $critical_failures -eq 0 ]] && summary+="\n🎉 Overall Status: SUCCESS\n" || summary+="\n⚠️  Overall Status: COMPLETED WITH ISSUES\n"

    echo -e "$summary"

    if [[ "$EMAIL_NOTIFY" == "true" ]]; then
        local subj; [[ $critical_failures -eq 0 ]] && subj="VaultWarden Maintenance: SUCCESS" || subj="VaultWarden Maintenance: ISSUES DETECTED"
        send_notification_email "$subj" "$summary" && log_info "Summary emailed" || log_warn "Failed to send summary email"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
perform_cleanup() {
    for ((idx=${#CLEANUP_ACTIONS[@]}-1; idx>=0; idx--)); do
        eval "${CLEANUP_ACTIONS[$idx]}" 2>/dev/null || true
    done
}

main() {
    log_header "VaultWarden-OCI Maintenance Manager"

    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    mkdir -p "$state_dir/.locks" 2>/dev/null || true

    CLEANUP_ACTIONS=()
    trap perform_cleanup EXIT

    # ---- Deep DB maintenance: self-contained sub-command ----
    if [[ "$DB_DEEP_MAINT" == "true" ]]; then
        # Needs root (enforced inside run_deep_db_maintenance via is_root),
        # but keep lock creation etc. consistent here.
        require_root "$@"
        local DEEP_LOCKDIR="$state_dir/.locks/db-maint.lock"
        if ! mkdir "$DEEP_LOCKDIR" 2>/dev/null; then
            log_error "Another DB maintenance task is already running (lock: $DEEP_LOCKDIR)"
            log_info  "If this is an error, manually remove: $DEEP_LOCKDIR"
            exit 1
        fi
        CLEANUP_ACTIONS+=("rmdir '$DEEP_LOCKDIR' 2>/dev/null || true")
        local GLOBAL_MAINT_LOCK="$state_dir/.locks/global-maintenance.lock"
        touch "$GLOBAL_MAINT_LOCK"
        CLEANUP_ACTIONS+=("rm -f '$GLOBAL_MAINT_LOCK' 2>/dev/null || true")
        if ! load_env_file; then log_error "Failed to load configuration"; exit 1; fi
        run_deep_db_maintenance
        exit $?
    fi

    # ---- Email diagnostic: self-contained sub-command ----
    if [[ "$TEST_EMAIL" == "true" ]]; then
        # Email diagnostics do not inherently require root; they require Docker access.
        # If user lacks docker permissions, docker commands will fail with a clear error.
        if ! load_env_file; then log_error "Failed to load configuration"; exit 1; fi
        run_email_diagnostics
        exit $?
    fi

    # ---- Routine or targeted maintenance ----
    # Routine maintenance and firewall updates require root.
    require_root "$@"
    # FIX [M-01]: Use shared flock on operations.lock (same as update.sh/restore.sh fd 9)
    # so concurrent runs of maintenance/update/restore are mutually exclusive.
    local ops_lock_dir="${PROJECT_ROOT}/.locks"
    ensure_dir "$ops_lock_dir" 700 "$(get_real_user)" || true
    exec 9>"${ops_lock_dir}/operations.lock"
    if ! flock -n 9; then
        log_error "Another operation (update/restore/maintenance) is already running. Aborting."
        exit 1
    fi
    # FIX [M-01]: Signal health.sh to skip auto-recovery while maintenance is active
    touch /tmp/.vw_maintenance.lock
    CLEANUP_ACTIONS+=("rm -f /tmp/.vw_maintenance.lock 2>/dev/null || true")

    [[ "$DRY_RUN"        == "true" ]] && log_warn "DRY RUN MODE - No changes will be made"
    [[ "$TARGETED_MODE"  == "true" ]] && log_info "Targeted mode — running requested task(s) only"
    [[ "$COMPREHENSIVE"  == "true" ]] && log_info "Running comprehensive maintenance..."

    if ! load_env_file; then log_error "Failed to load configuration"; exit 1; fi

    local log_cleanup_result=0 backup_cleanup_result=0 docker_cleanup_result=0
    local db_optimization_result=0 firewall_update_result=1 dns_update_result=1
    local health_validation_result=0

    # ---- Phase 1 & 2: skipped entirely in targeted mode ----
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

    # ---- Phase 3: Targeted tasks (always run when flagged) ----
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

    # ---- Phase 4: Health check (skipped in targeted mode) ----
    if [[ "$TARGETED_MODE" == "false" ]]; then
        log_info "=== Phase 4: Health Validation ==="
        validate_system_health || health_validation_result=$?
    fi

    # ---- Phase 5: Summary ----
    log_info "=== Summary ==="
    generate_maintenance_summary \
        "$log_cleanup_result" "$backup_cleanup_result" "$docker_cleanup_result" \
        "$db_optimization_result" "$firewall_update_result" "$dns_update_result" \
        "$health_validation_result"

    local critical_failures=0
    [[ "$CLEAN_LOGS"    == "true" && "$log_cleanup_result"    != "0" ]] && ((critical_failures++))
    [[ "$CLEAN_BACKUPS" == "true" && "$backup_cleanup_result" != "0" ]] && ((critical_failures++))
    [[ "$CLEAN_DOCKER"  == "true" && "$docker_cleanup_result" == "2" ]] && ((critical_failures++))

    if [[ $critical_failures -eq 0 ]]; then
        log_success "Maintenance completed successfully"; exit 0
    elif [[ $critical_failures -le 1 ]]; then
        log_warn "Maintenance completed with minor issues"; exit 2
    else
        log_error "Maintenance completed with critical failures"; exit 1
    fi
}

main "$@"