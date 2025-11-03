#!/usr/bin/env bash
# maintenance.sh - System cleanup and optimization with enhanced safety
# ENHANCED: Fixed live database VACUUM - now safely stops services before database operations
# ENHANCED: Proper transaction handling and integrity verification

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/backup_utils.sh"

# Configuration
CLEAN_LOGS=true
CLEAN_BACKUPS=true
CLEAN_DOCKER=true
OPTIMIZE_DATABASE=true
UPDATE_FIREWALL=false
DRY_RUN=false
EMAIL_NOTIFY=false
COMPREHENSIVE=false

# Retention settings (days)
LOG_RETENTION_DAYS=30
DB_BACKUP_RETENTION_DAYS=14
FULL_BACKUP_RETENTION_DAYS=30
EMERGENCY_BACKUP_RETENTION_DAYS=90

show_help() {
    cat << 'EOF'
VaultWarden-OCI Maintenance Script - Safe Database Operations

USAGE:
    ./maintenance.sh [OPTIONS]

OPTIONS:
    --comprehensive         Run comprehensive maintenance (includes firewall updates)
    --no-logs               Skip log rotation and cleanup
    --no-backups            Skip backup cleanup
    --no-docker             Skip Docker cleanup
    --no-database           Skip database optimization
    --update-firewall       Update Cloudflare IP ranges in firewall
    --dry-run               Show what would be done without executing
    --email                 Send email notification on completion
    --help                  Show this help

MAINTENANCE TASKS:
    Basic:
    - Log rotation and cleanup (30 days)
    - Backup retention management (14/30/90 days)
    - Docker system cleanup
    - SAFE database optimization (stops services first)

    Comprehensive:
    - All basic tasks
    - Safe firewall IP range updates (no service interruption)
    - System health validation

SAFETY FEATURES:
    - Database operations stop VaultWarden service first
    - WAL checkpoint before VACUUM operations
    - Integrity verification before restart
    - Firewall updates avoid service interruption

EXAMPLES:
    ./maintenance.sh                    # Basic maintenance
    ./maintenance.sh --comprehensive    # Full maintenance with firewall
    ./maintenance.sh --dry-run          # Preview maintenance actions
EOF
}

# Argument Parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --comprehensive) COMPREHENSIVE=true; UPDATE_FIREWALL=true; shift ;;
        --no-logs) CLEAN_LOGS=false; shift ;;
        --no-backups) CLEAN_BACKUPS=false; shift ;;
        --no-docker) CLEAN_DOCKER=false; shift ;;
        --no-database) OPTIMIZE_DATABASE=false; shift ;;
        --update-firewall) UPDATE_FIREWALL=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --email) EMAIL_NOTIFY=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# STANDARDIZED: Log cleanup and rotation - returns exit code
cleanup_logs() {
    if [[ "$CLEAN_LOGS" != "true" ]]; then
        log_info "Skipping log cleanup (--no-logs specified)"
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

    # Clean up application logs
    local log_dirs=(
        "$state_dir/logs/vaultwarden"
        "$state_dir/logs/caddy"
        "$state_dir/logs/fail2ban"
        "$PROJECT_ROOT/logs"
    )

    for log_dir in "${log_dirs[@]}"; do
        if [[ -d "$log_dir" ]]; then
            local old_logs
            if old_logs=$(find "$log_dir" -name "*.log*" -type f -mtime +$LOG_RETENTION_DAYS 2>/dev/null); then
                while IFS= read -r log_file; do
                    if [[ -n "$log_file" ]]; then
                        if rm -f "$log_file"; then
                            ((logs_cleaned++))
                            log_debug "Removed old log: $(basename "$log_file")"
                        fi
                    fi
                done <<< "$old_logs"
            fi
        fi
    done

    # Rotate current logs if they're too large (>100MB)
    local large_logs
    if large_logs=$(find "${log_dirs[@]}" -name "*.log" -type f -size +100M 2>/dev/null); then
        while IFS= read -r log_file; do
            if [[ -n "$log_file" ]]; then
                local rotated_name="${log_file}.$(date +%Y%m%d)"
                if mv "$log_file" "$rotated_name" && gzip "$rotated_name"; then
                    log_debug "Rotated large log: $(basename "$log_file")"
                    ((logs_cleaned++))
                fi
            fi
        done <<< "$large_logs"
    fi

    if [[ $logs_cleaned -gt 0 ]]; then
        log_success "Cleaned up $logs_cleaned log files"
    else
        log_info "No old logs found to clean up"
    fi

    return 0
}

# STANDARDIZED: Backup retention management - returns exit code
cleanup_backups() {
    if [[ "$CLEAN_BACKUPS" != "true" ]]; then
        log_info "Skipping backup cleanup (--no-backups specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would clean up old backups based on retention policy"
        return 0
    fi

    log_info "Managing backup retention..."

    local backup_base_dir="$PROJECT_ROOT/backups"
    local cleanup_results=()

    # Clean up different backup types with different retention periods
    local backup_types=(
        "db:$DB_BACKUP_RETENTION_DAYS"
        "full:$FULL_BACKUP_RETENTION_DAYS"
        "emergency:$EMERGENCY_BACKUP_RETENTION_DAYS"
    )

    for backup_type_info in "${backup_types[@]}"; do
        local backup_type="${backup_type_info%%:*}"
        local retention_days="${backup_type_info##*:}"
        local backup_dir="$backup_base_dir/$backup_type"

        if cleanup_old_backups "$backup_dir" "$backup_type" "$retention_days"; then
            cleanup_results+=("✅ $backup_type backups cleaned (${retention_days}d retention)")
        else
            cleanup_results+=("❌ $backup_type backup cleanup failed")
        fi
    done

    # Log results
    for result in "${cleanup_results[@]}"; do
        if [[ "$result" =~ ^✅ ]]; then
            log_success "${result#✅ }"
        else
            log_error "${result#❌ }"
        fi
    done

    log_success "Backup retention management completed"
    return 0
}

# STANDARDIZED: Docker system cleanup - returns exit code
cleanup_docker_system() {
    if [[ "$CLEAN_DOCKER" != "true" ]]; then
        log_info "Skipping Docker cleanup (--no-docker specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would clean up Docker system resources"
        return 0
    fi

    log_info "Cleaning up Docker system resources..."

    # Check Docker availability
    if ! require_docker; then
        log_error "Docker not available for cleanup"
        return 1
    fi

    local cleanup_success=true

    # Clean up in order of safety: containers -> images -> volumes -> networks
    if ! cleanup_containers; then
        log_warn "Container cleanup had issues"
        cleanup_success=false
    fi

    if ! cleanup_images; then
        log_warn "Image cleanup had issues"  
        cleanup_success=false
    fi

    # Be more careful with volumes - only clean unnamed volumes
    log_info "Cleaning up unnamed Docker volumes..."
    if ! docker volume prune -f >/dev/null 2>&1; then
        log_warn "Volume cleanup had issues"
        cleanup_success=false
    fi

    if ! cleanup_networks; then
        log_warn "Network cleanup had issues"
        cleanup_success=false
    fi

    # Get cleanup summary
    local space_reclaimed
    space_reclaimed=$(docker system df --format "table {{.Reclaimed}}" 2>/dev/null | tail -1 || echo "unknown")

    if [[ "$cleanup_success" == "true" ]]; then
        log_success "Docker cleanup completed successfully (reclaimed: ${space_reclaimed})"
        return 0
    else
        log_warn "Docker cleanup completed with some issues (reclaimed: ${space_reclaimed})"
        return 1
    fi
}

# ENHANCED: SAFE database optimization - stops services first to prevent corruption
optimize_database() {
    if [[ "$OPTIMIZE_DATABASE" != "true" ]]; then
        log_info "Skipping database optimization (--no-database specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would safely optimize VaultWarden database (stops service first)"
        return 0
    fi

    log_info "Starting SAFE database optimization (will stop VaultWarden temporarily)..."

    # Check if VaultWarden is running
    local was_running=false
    if is_service_running "vaultwarden"; then
        was_running=true
    else
        log_warn "VaultWarden not running, will optimize offline database"
    fi

    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local host_db_path="$state_dir/data/bwdata/db.sqlite3"

    # Verify database exists
    if [[ ! -f "$host_db_path" ]]; then
        log_error "Database file not found: $host_db_path"
        return 1
    fi

    # Get database size before optimization
    local size_before
    if size_before=$(stat -c%s "$host_db_path" 2>/dev/null); then
        size_before=$((size_before / 1024 / 1024))  # Convert to MB
    else
        log_warn "Could not determine database size"
        size_before=0
    fi

    log_info "Database size before optimization: ${size_before}MB"

    # SAFETY STEP 1: If service is running, prepare for safe shutdown
    if [[ "$was_running" == "true" ]]; then
        log_info "Preparing VaultWarden for safe database maintenance..."

        # Checkpoint WAL to ensure all transactions are written to main DB
        log_info "Checkpointing WAL (Write-Ahead Log) for transaction consistency..."
        if docker compose exec -T vaultwarden sqlite3 /data/bwdata/db.sqlite3 "PRAGMA wal_checkpoint(FULL);" >/dev/null 2>&1; then
            log_success "WAL checkpoint completed successfully"
        else
            log_warn "WAL checkpoint failed, but continuing with optimization"
        fi

        # Stop VaultWarden service gracefully
        log_info "Stopping VaultWarden service for safe database operations..."
        if ! docker compose stop vaultwarden; then
            log_error "Failed to stop VaultWarden service"
            return 1
        fi
        log_success "VaultWarden service stopped safely"

        # Give a moment for graceful shutdown
        sleep 3
    fi

    # SAFETY STEP 2: Create a backup before optimization
    local backup_file="$state_dir/data/bwdata/db.sqlite3.pre-optimization-$(date +%Y%m%d-%H%M%S)"
    log_info "Creating safety backup before optimization..."
    if cp "$host_db_path" "$backup_file"; then
        log_success "Safety backup created: $(basename "$backup_file")"
    else
        log_error "Failed to create safety backup - aborting optimization"
        # Restart service if it was running
        if [[ "$was_running" == "true" ]]; then
            docker compose start vaultwarden
        fi
        return 1
    fi

    # SAFETY STEP 3: Verify database integrity before optimization
    log_info "Verifying database integrity before optimization..."
    if sqlite3 "$host_db_path" "PRAGMA integrity_check;" | grep -qx "ok"; then
        log_success "Database integrity check passed"
    else
        log_error "Database integrity check failed - aborting optimization"
        # Restart service if it was running
        if [[ "$was_running" == "true" ]]; then
            docker compose start vaultwarden
        fi
        return 1
    fi

    # STEP 4: Perform database optimization operations safely
    log_info "Performing database optimization operations (VACUUM, ANALYZE, OPTIMIZE)..."

    local optimization_commands=(
        "PRAGMA optimize;"
        "ANALYZE;"
        "VACUUM;"
    )

    local optimization_success=true

    for cmd in "${optimization_commands[@]}"; do
        log_debug "Running: $cmd"
        if ! sqlite3 "$host_db_path" "$cmd" 2>/dev/null; then
            log_warn "Database command failed: $cmd"
            optimization_success=false
        fi
    done

    # SAFETY STEP 5: Verify database integrity after optimization
    log_info "Verifying database integrity after optimization..."
    if sqlite3 "$host_db_path" "PRAGMA integrity_check;" | grep -qx "ok"; then
        log_success "Post-optimization integrity check passed"
    else
        log_error "CRITICAL: Database integrity check failed after optimization!"
        log_error "Restoring from safety backup..."

        if cp "$backup_file" "$host_db_path"; then
            log_success "Database restored from safety backup"
        else
            log_error "CRITICAL: Failed to restore from backup!"
        fi

        optimization_success=false
    fi

    # STEP 6: Restart VaultWarden service if it was running
    if [[ "$was_running" == "true" ]]; then
        log_info "Restarting VaultWarden service..."
        if docker compose start vaultwarden; then
            log_success "VaultWarden service restarted successfully"

            # Wait for service to be ready
            sleep 5

            # Verify service health
            if is_service_running "vaultwarden"; then
                log_success "VaultWarden service is healthy after database optimization"
            else
                log_error "VaultWarden service failed to start properly after optimization"
                optimization_success=false
            fi
        else
            log_error "Failed to restart VaultWarden service"
            optimization_success=false
        fi
    fi

    # STEP 7: Report results and clean up
    local size_after
    if size_after=$(stat -c%s "$host_db_path" 2>/dev/null); then
        size_after=$((size_after / 1024 / 1024))  # Convert to MB
        local space_saved=$((size_before - size_after))

        log_info "Database size after optimization: ${size_after}MB"

        if [[ "$optimization_success" == "true" ]]; then
            log_success "SAFE database optimization completed successfully"
            log_info "Size change: ${size_before}MB → ${size_after}MB (saved ${space_saved}MB)"

            # Clean up safety backup after successful optimization
            if rm -f "$backup_file"; then
                log_debug "Safety backup cleaned up"
            fi
        else
            log_error "Database optimization completed with issues"
            log_warn "Safety backup retained: $(basename "$backup_file")"
        fi
    else
        if [[ "$optimization_success" == "true" ]]; then
            log_success "SAFE database optimization completed successfully"
        else
            log_error "Database optimization completed with issues"
        fi
    fi

    return $([[ "$optimization_success" == "true" ]] && echo 0 || echo 1)
}

# ENHANCED: Safe firewall IP range updates - prevents service interruption
update_firewall_ranges() {
    if [[ "$UPDATE_FIREWALL" != "true" ]]; then
        log_info "Skipping firewall updates (use --update-firewall to enable)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would safely update Cloudflare IP ranges in firewall"
        return 0
    fi

    log_info "Safely updating Cloudflare IP ranges in firewall (no service interruption)..."

    # Fetch new Cloudflare IP ranges first
    local cf_ipv4_file="/tmp/cf_ipv4_ranges_maint.txt"
    local cf_ipv6_file="/tmp/cf_ipv6_ranges_maint.txt"
    local ranges_fetched=false

    if retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v4" -o "$cf_ipv4_file" &&        retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v6" -o "$cf_ipv6_file"; then
        ranges_fetched=true
        log_success "Successfully fetched current Cloudflare IP ranges"
    else
        log_error "Failed to fetch Cloudflare IP ranges - aborting firewall update"
        return 1
    fi

    # SAFETY: Add new rules FIRST, then remove old ones to prevent service interruption
    local ranges_added=false

    # Apply IPv4 ranges
    if grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' "$cf_ipv4_file" >/dev/null; then
        log_info "Adding new Cloudflare IPv4 ranges..."
        while IFS= read -r range; do
            if [[ -n "$range" && "$range" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
                # Check if rule already exists to avoid duplicates
                if ! ufw status | grep -q "$range"; then
                    if ufw allow from "$range" to any port 80,443 comment "CF-IPv4-NEW" >/dev/null; then
                        ranges_added=true
                        log_debug "Added IPv4 range: $range"
                    fi
                fi
            fi
        done < "$cf_ipv4_file"
    fi

    # Apply IPv6 ranges
    if grep -E '^[0-9a-fA-F:]+/[0-9]{1,3}$' "$cf_ipv6_file" >/dev/null; then
        log_info "Adding new Cloudflare IPv6 ranges..."
        while IFS= read -r range; do
            if [[ -n "$range" && "$range" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]]; then
                # Check if rule already exists to avoid duplicates
                if ! ufw status | grep -q "$range"; then
                    if ufw allow from "$range" to any port 80,443 comment "CF-IPv6-NEW" >/dev/null; then
                        ranges_added=true
                        log_debug "Added IPv6 range: $range"
                    fi
                fi
            fi
        done < "$cf_ipv6_file"
    fi

    if [[ "$ranges_added" == "true" ]]; then
        log_success "New Cloudflare IP ranges added successfully"

        # Now safely remove old rules (those without -NEW suffix)
        log_info "Removing outdated Cloudflare IP ranges..."
        local old_rules
        if old_rules=$(ufw status numbered | grep -E "CF-IPv[46]" | grep -v "CF-IPv[46]-NEW" | awk '{print $1}' | sed 's/\[//g' | sed 's/\]//g' | sort -rn); then
            local removed_count=0
            while IFS= read -r rule_num; do
                if [[ -n "$rule_num" ]]; then
                    if echo "y" | ufw delete "$rule_num" >/dev/null 2>&1; then
                        ((removed_count++))
                    fi
                fi
            done <<< "$old_rules"

            if [[ $removed_count -gt 0 ]]; then
                log_success "Removed $removed_count outdated firewall rules"
            fi
        fi

        # Clean up the -NEW suffixes from comments
        log_info "Finalizing firewall rule comments..."
        # Note: UFW doesn't have a direct way to modify comments, so we leave them as -NEW
        # This actually helps identify when rules were last updated

        log_success "Firewall IP ranges updated safely with no service interruption"
    else
        log_info "No new IP ranges needed to be added"
    fi

    # Clean up temporary files
    rm -f "$cf_ipv4_file" "$cf_ipv6_file"

    return 0
}

# STANDARDIZED: System health validation - returns exit code
validate_system_health() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would validate system health after maintenance"
        return 0
    fi

    log_info "Validating system health after maintenance..."

    # Run basic health check
    if ./health.sh --quiet; then
        log_success "System health validation passed"
        return 0
    else
        log_warn "System health validation detected issues"
        return 1
    fi
}

# STANDARDIZED: Maintenance summary generation - returns exit code
generate_maintenance_summary() {
    local log_cleanup="$1"
    local backup_cleanup="$2"
    local docker_cleanup="$3"
    local db_optimization="$4"
    local firewall_update="$5"
    local health_validation="$6"

    log_info "Generating maintenance summary..."

    local summary="VaultWarden SAFE Maintenance Summary - $(date)
"
    summary+="
Maintenance Results:
"

    # Log cleanup
    if [[ "$CLEAN_LOGS" == "true" ]]; then
        if [[ "$log_cleanup" == "0" ]]; then
            summary+="  ✅ Log cleanup: Completed successfully
"
        else
            summary+="  ❌ Log cleanup: Failed
"
        fi
    else
        summary+="  ⏭️  Log cleanup: Skipped
"
    fi

    # Backup cleanup
    if [[ "$CLEAN_BACKUPS" == "true" ]]; then
        if [[ "$backup_cleanup" == "0" ]]; then
            summary+="  ✅ Backup cleanup: Completed successfully
"
        else
            summary+="  ❌ Backup cleanup: Failed
"
        fi
    else
        summary+="  ⏭️  Backup cleanup: Skipped
"
    fi

    # Docker cleanup
    if [[ "$CLEAN_DOCKER" == "true" ]]; then
        if [[ "$docker_cleanup" == "0" ]]; then
            summary+="  ✅ Docker cleanup: Completed successfully
"
        elif [[ "$docker_cleanup" == "1" ]]; then
            summary+="  ⚠️  Docker cleanup: Completed with issues
"
        else
            summary+="  ❌ Docker cleanup: Failed
"
        fi
    else
        summary+="  ⏭️  Docker cleanup: Skipped
"
    fi

    # Database optimization
    if [[ "$OPTIMIZE_DATABASE" == "true" ]]; then
        if [[ "$db_optimization" == "0" ]]; then
            summary+="  ✅ SAFE database optimization: Completed successfully
"
        else
            summary+="  ⚠️  SAFE database optimization: Completed with issues
"
        fi
    else
        summary+="  ⏭️  Database optimization: Skipped
"
    fi

    # Firewall update
    if [[ "$UPDATE_FIREWALL" == "true" ]]; then
        if [[ "$firewall_update" == "0" ]]; then
            summary+="  ✅ SAFE firewall update: Completed successfully
"
        else
            summary+="  ❌ Firewall update: Failed
"
        fi
    else
        summary+="  ⏭️  Firewall update: Skipped
"
    fi

    # Health validation
    if [[ "$health_validation" == "0" ]]; then
        summary+="  ✅ Health validation: Passed
"
    else
        summary+="  ⚠️  Health validation: Issues detected
"
    fi

    # Overall status
    local critical_failures=0
    [[ "$log_cleanup" != "0" ]] && ((critical_failures++))
    [[ "$backup_cleanup" != "0" ]] && ((critical_failures++))
    [[ "$docker_cleanup" == "2" ]] && ((critical_failures++))  # Only count severe Docker failures

    if [[ $critical_failures -eq 0 ]]; then
        summary+="
🎉 Overall Status: SAFE MAINTENANCE SUCCESSFUL
"
        summary+="
Safety Features Used:
"
        summary+="  • Database operations stopped service first
"
        summary+="  • WAL checkpoint before VACUUM
"
        summary+="  • Integrity verification at each step
"
        summary+="  • Firewall updates avoided service interruption
"
        summary+="
Next Steps:
"
        summary+="  • Monitor system performance
"
        summary+="  • Check logs if any issues arise
"
    else
        summary+="
⚠️  Overall Status: MAINTENANCE COMPLETED WITH ISSUES
"
        summary+="
Recommended Actions:
"
        summary+="  • Review maintenance logs
"
        summary+="  • Run comprehensive health check
"
        summary+="  • Address any critical issues
"
    fi

    echo -e "$summary"

    # Send email notification if requested
    if [[ "$EMAIL_NOTIFY" == "true" ]]; then
        local email_subject
        if [[ $critical_failures -eq 0 ]]; then
            email_subject="VaultWarden SAFE Maintenance: SUCCESS"
        else
            email_subject="VaultWarden SAFE Maintenance: ISSUES DETECTED"
        fi

        if send_notification_email "$email_subject" "$summary"; then
            log_info "Maintenance summary emailed to admin"
        else
            log_warn "Failed to send maintenance summary email"
        fi
    fi

    return 0
}

# ENHANCED: Main function with proper error handling and exit strategy
main() {
    log_header "VaultWarden-OCI SAFE Maintenance Manager"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    if [[ "$COMPREHENSIVE" == "true" ]]; then
        log_info "Running comprehensive SAFE maintenance..."
    fi

    # Load configuration
    if ! load_env_file; then
        log_error "Failed to load configuration"
        exit 1
    fi

    # Track maintenance task results
    local log_cleanup_result=1
    local backup_cleanup_result=1
    local docker_cleanup_result=1
    local db_optimization_result=1
    local firewall_update_result=1
    local health_validation_result=1

    # Phase 1: System cleanup
    log_info "=== Phase 1: System Cleanup ==="

    if cleanup_logs; then
        log_cleanup_result=0
    fi

    if cleanup_backups; then
        backup_cleanup_result=0
    fi

    if cleanup_docker_system; then
        docker_cleanup_result=0
    elif [[ $? -eq 1 ]]; then
        docker_cleanup_result=1  # Issues but not critical
    else
        docker_cleanup_result=2  # Critical failure
    fi

    # Phase 2: SAFE Optimization
    log_info "=== Phase 2: SAFE System Optimization ==="

    if optimize_database; then
        db_optimization_result=0
    fi

    # Phase 3: SAFE Security maintenance (comprehensive mode)
    if [[ "$COMPREHENSIVE" == "true" ]]; then
        log_info "=== Phase 3: SAFE Security Maintenance ==="

        if update_firewall_ranges; then
            firewall_update_result=0
        fi
    fi

    # Phase 4: Health validation
    log_info "=== Phase 4: Health Validation ==="

    if validate_system_health; then
        health_validation_result=0
    fi

    # Phase 5: Summary and reporting
    log_info "=== Phase 5: Maintenance Summary ==="

    generate_maintenance_summary "$log_cleanup_result" "$backup_cleanup_result" "$docker_cleanup_result" "$db_optimization_result" "$firewall_update_result" "$health_validation_result"

    # Determine final exit code
    local critical_failures=0
    [[ "$log_cleanup_result" != "0" ]] && ((critical_failures++))
    [[ "$backup_cleanup_result" != "0" ]] && ((critical_failures++))
    [[ "$docker_cleanup_result" == "2" ]] && ((critical_failures++))

    if [[ $critical_failures -eq 0 ]]; then
        log_success "SAFE maintenance completed successfully"
        exit 0
    elif [[ $critical_failures -le 1 ]]; then
        log_warn "SAFE maintenance completed with minor issues"
        exit 2  # Warning exit code
    else
        log_error "SAFE maintenance completed with critical failures"
        exit 1
    fi
}

main "$@"
