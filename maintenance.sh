#!/usr/bin/env bash
# maintenance.sh - System cleanup and optimization with enhanced safety
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
VaultWarden-OCI Maintenance Script - Automated System Care

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
    - Database optimization

    Comprehensive:
    - All basic tasks
    - Firewall IP range updates
    - System health validation

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

# STANDARDIZED: Database optimization - returns exit code
optimize_database() {
    if [[ "$OPTIMIZE_DATABASE" != "true" ]]; then
        log_info "Skipping database optimization (--no-database specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would optimize VaultWarden database"
        return 0
    fi

    log_info "Optimizing VaultWarden database..."

    # Check if VaultWarden is running
    if ! is_service_running "vaultwarden"; then
        log_warn "VaultWarden not running, skipping database optimization"
        return 0
    fi

    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local db_path="/data/bwdata/db.sqlite3"  # Path inside container

    # Get database size before optimization
    local size_before
    if size_before=$(docker compose exec -T vaultwarden stat -c%s "$db_path" 2>/dev/null); then
        size_before=$((size_before / 1024 / 1024))  # Convert to MB
    else
        log_warn "Could not determine database size"
        size_before=0
    fi

    # Run database optimization commands
    local optimization_commands=(
        "PRAGMA optimize;"
        "VACUUM;"
        "PRAGMA integrity_check;"
    )

    local optimization_success=true

    for cmd in "${optimization_commands[@]}"; do
        log_debug "Running: $cmd"
        if ! docker compose exec -T vaultwarden sqlite3 "$db_path" "$cmd" >/dev/null 2>&1; then
            log_warn "Database command failed: $cmd"
            optimization_success=false
        fi
    done

    # Get database size after optimization
    local size_after
    if size_after=$(docker compose exec -T vaultwarden stat -c%s "$db_path" 2>/dev/null); then
        size_after=$((size_after / 1024 / 1024))  # Convert to MB
        local space_saved=$((size_before - size_after))

        if [[ "$optimization_success" == "true" ]]; then
            log_success "Database optimization completed (${size_before}MB → ${size_after}MB, saved ${space_saved}MB)"
        else
            log_warn "Database optimization completed with issues (${size_before}MB → ${size_after}MB)"
        fi
    else
        if [[ "$optimization_success" == "true" ]]; then
            log_success "Database optimization completed"
        else
            log_warn "Database optimization completed with issues"
        fi
    fi

    return $([[ "$optimization_success" == "true" ]] && echo 0 || echo 1)
}

# STANDARDIZED: Firewall IP range updates - returns exit code
update_firewall_ranges() {
    if [[ "$UPDATE_FIREWALL" != "true" ]]; then
        log_info "Skipping firewall updates (use --update-firewall to enable)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would update Cloudflare IP ranges in firewall"
        return 0
    fi

    log_info "Updating Cloudflare IP ranges in firewall..."

    # Remove old Cloudflare rules
    local old_rules
    if old_rules=$(ufw status numbered | grep -E "CF-IPv[46]" | awk '{print $1}' | sed 's/\[//g' | sed 's/\]//g' | sort -rn); then
        while IFS= read -r rule_num; do
            if [[ -n "$rule_num" ]]; then
                echo "y" | ufw delete "$rule_num" >/dev/null 2>&1 || log_warn "Failed to remove rule $rule_num"
            fi
        done <<< "$old_rules"
    fi

    # Fetch new Cloudflare IP ranges
    local cf_ipv4_file="/tmp/cf_ipv4_ranges_maint.txt"
    local cf_ipv6_file="/tmp/cf_ipv6_ranges_maint.txt"
    local ranges_updated=false

    if retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v4" -o "$cf_ipv4_file" && \
       retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v6" -o "$cf_ipv6_file"; then

        # Apply IPv4 ranges
        if grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' "$cf_ipv4_file" >/dev/null; then
            while IFS= read -r range; do
                if [[ -n "$range" && "$range" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
                    if ufw allow from "$range" to any port 80,443 comment "CF-IPv4" >/dev/null; then
                        ranges_updated=true
                    fi
                fi
            done < "$cf_ipv4_file"
        fi

        # Apply IPv6 ranges
        if grep -E '^[0-9a-fA-F:]+/[0-9]{1,3}$' "$cf_ipv6_file" >/dev/null; then
            while IFS= read -r range; do
                if [[ -n "$range" && "$range" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]]; then
                    if ufw allow from "$range" to any port 80,443 comment "CF-IPv6" >/dev/null; then
                        ranges_updated=true
                    fi
                fi
            done < "$cf_ipv6_file"
        fi

        rm -f "$cf_ipv4_file" "$cf_ipv6_file"

        if [[ "$ranges_updated" == "true" ]]; then
            log_success "Firewall IP ranges updated successfully"
            return 0
        else
            log_warn "No new IP ranges were applied"
            return 1
        fi
    else
        log_error "Failed to fetch Cloudflare IP ranges for firewall update"
        return 1
    fi
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

    local summary="VaultWarden Maintenance Summary - $(date)\n"
    summary+="\nMaintenance Results:\n"

    # Log cleanup
    if [[ "$CLEAN_LOGS" == "true" ]]; then
        if [[ "$log_cleanup" == "0" ]]; then
            summary+="  ✅ Log cleanup: Completed successfully\n"
        else
            summary+="  ❌ Log cleanup: Failed\n"
        fi
    else
        summary+="  ⏭️  Log cleanup: Skipped\n"
    fi

    # Backup cleanup
    if [[ "$CLEAN_BACKUPS" == "true" ]]; then
        if [[ "$backup_cleanup" == "0" ]]; then
            summary+="  ✅ Backup cleanup: Completed successfully\n"
        else
            summary+="  ❌ Backup cleanup: Failed\n"
        fi
    else
        summary+="  ⏭️  Backup cleanup: Skipped\n"
    fi

    # Docker cleanup
    if [[ "$CLEAN_DOCKER" == "true" ]]; then
        if [[ "$docker_cleanup" == "0" ]]; then
            summary+="  ✅ Docker cleanup: Completed successfully\n"
        elif [[ "$docker_cleanup" == "1" ]]; then
            summary+="  ⚠️  Docker cleanup: Completed with issues\n"
        else
            summary+="  ❌ Docker cleanup: Failed\n"
        fi
    else
        summary+="  ⏭️  Docker cleanup: Skipped\n"
    fi

    # Database optimization
    if [[ "$OPTIMIZE_DATABASE" == "true" ]]; then
        if [[ "$db_optimization" == "0" ]]; then
            summary+="  ✅ Database optimization: Completed successfully\n"
        else
            summary+="  ⚠️  Database optimization: Completed with issues\n"
        fi
    else
        summary+="  ⏭️  Database optimization: Skipped\n"
    fi

    # Firewall update
    if [[ "$UPDATE_FIREWALL" == "true" ]]; then
        if [[ "$firewall_update" == "0" ]]; then
            summary+="  ✅ Firewall update: Completed successfully\n"
        else
            summary+="  ❌ Firewall update: Failed\n"
        fi
    else
        summary+="  ⏭️  Firewall update: Skipped\n"
    fi

    # Health validation
    if [[ "$health_validation" == "0" ]]; then
        summary+="  ✅ Health validation: Passed\n"
    else
        summary+="  ⚠️  Health validation: Issues detected\n"
    fi

    # Overall status
    local critical_failures=0
    [[ "$log_cleanup" != "0" ]] && ((critical_failures++))
    [[ "$backup_cleanup" != "0" ]] && ((critical_failures++))
    [[ "$docker_cleanup" == "2" ]] && ((critical_failures++))  # Only count severe Docker failures

    if [[ $critical_failures -eq 0 ]]; then
        summary+="\n🎉 Overall Status: MAINTENANCE SUCCESSFUL\n"
        summary+="\nNext Steps:\n"
        summary+="  • Monitor system performance\n"
        summary+="  • Check logs if any issues arise\n"
    else
        summary+="\n⚠️  Overall Status: MAINTENANCE COMPLETED WITH ISSUES\n"
        summary+="\nRecommended Actions:\n"
        summary+="  • Review maintenance logs\n"
        summary+="  • Run comprehensive health check\n"
        summary+="  • Address any critical issues\n"
    fi

    echo -e "$summary"

    # Send email notification if requested
    if [[ "$EMAIL_NOTIFY" == "true" ]]; then
        local email_subject
        if [[ $critical_failures -eq 0 ]]; then
            email_subject="VaultWarden Maintenance: SUCCESS"
        else
            email_subject="VaultWarden Maintenance: ISSUES DETECTED"
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
    log_header "VaultWarden-OCI Maintenance Manager"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    if [[ "$COMPREHENSIVE" == "true" ]]; then
        log_info "Running comprehensive maintenance..."
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

    # Phase 2: Optimization
    log_info "=== Phase 2: System Optimization ==="

    if optimize_database; then
        db_optimization_result=0
    fi

    # Phase 3: Security maintenance (comprehensive mode)
    if [[ "$COMPREHENSIVE" == "true" ]]; then
        log_info "=== Phase 3: Security Maintenance ==="

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
        log_success "Maintenance completed successfully"
        exit 0
    elif [[ $critical_failures -le 1 ]]; then
        log_warn "Maintenance completed with minor issues"
        exit 2  # Warning exit code
    else
        log_error "Maintenance completed with critical failures"
        exit 1
    fi
}

main "$@"
