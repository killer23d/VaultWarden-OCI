#!/usr/bin/env bash
# maintenance.sh - System maintenance and cleanup with library integration
# UPDATED: Removed redundant log rotation functions - Docker json-file driver handles rotation now
# ENHANCED: Added Cloudflare IP range updates for UFW security synchronization
# SIMPLIFIED: Focus on Docker cleanup, backup retention, system maintenance, and security

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh" # Needed for checking age key if encrypting backups

# --- Configuration ---
DRY_RUN=false
FORCE=false
CLEANUP_TYPE="standard"  # standard, deep, docker, cf-ranges

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden System Maintenance - Enhanced with Security Automation

USAGE:
    sudo ./maintenance.sh [OPTIONS]

OPTIONS:
    --type TYPE    Cleanup type: standard, deep, docker, cf-ranges (default: standard)
    --force        Skip confirmation prompts
    --dry-run      Show what would be done without executing
    --help         Show this help

CLEANUP TYPES:
    standard     Docker cleanup, old local & remote backups, system basics
    deep         Standard + system cache, temp files, package cache
    docker       Docker-specific cleanup (images, volumes, networks)
    cf-ranges    Update UFW Cloudflare IP ranges (security sync)

NOTE: Log rotation is now handled automatically by Docker json-file driver.
      VaultWarden and Fail2ban log to stdout, Caddy rotates its own access.log.

EXAMPLES:
    sudo ./maintenance.sh                   # Standard maintenance
    sudo ./maintenance.sh --type deep       # Deep system cleanup
    sudo ./maintenance.sh --type docker     # Docker cleanup only
    sudo ./maintenance.sh --type cf-ranges  # Update Cloudflare IP ranges
    sudo ./maintenance.sh --dry-run         # Preview actions
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --type) CLEANUP_TYPE="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Validation ---
validate_environment() {
    # Check if running as root for system operations
    if [[ "$CLEANUP_TYPE" != "docker" ]] && ! is_root; then
        log_error "System maintenance requires root privileges"
        log_info "Run with: sudo ./maintenance.sh"
        return 1
    fi
    # Need rclone for remote cleanup
    if [[ "$CLEANUP_TYPE" == "standard" || "$CLEANUP_TYPE" == "deep" ]]; then
        require_commands rclone || return 1
    fi
    # Need ufw for CF range updates
    if [[ "$CLEANUP_TYPE" == "cf-ranges" ]]; then
        require_commands ufw curl || return 1
    fi

    return 0
}

# --- NEW: Cloudflare IP Range Updates ---
update_ufw_cloudflare_ranges() {
    log_info "Updating UFW Cloudflare IP ranges..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would update UFW Cloudflare IP ranges"
        log_info "[DRY RUN] Would remove old CF-IPv4 and CF-IPv6 rules"
        log_info "[DRY RUN] Would fetch fresh ranges from Cloudflare API"
        log_info "[DRY RUN] Would apply new UFW rules for HTTP/HTTPS traffic"
        return 0
    fi

    # Remove old CF rules (cleanup)
    log_info "Removing old Cloudflare UFW rules..."
    local old_rules
    old_rules=$(ufw status numbered 2>/dev/null | grep -E "(CF-IPv4|CF-IPv6|CF-Setup|CF-Auto|CF-Only|CF-HTTP)" | awk '{print $1}' | tac)
    if [[ -n "$old_rules" ]]; then
        echo "$old_rules" | while read -r rule_num; do
            echo "y" | ufw delete "$rule_num" >/dev/null 2>&1 || true
        done
        log_info "Removed old Cloudflare rules"
    fi

    # Fetch and apply new ranges
    local cf_ipv4_file="/tmp/cf_ipv4_update.txt"
    local cf_ipv6_file="/tmp/cf_ipv6_update.txt"
    local ranges_updated=false

    # Fetch IPv4 ranges
    if curl -sf --max-time 10 "https://www.cloudflare.com/ips-v4" -o "$cf_ipv4_file"; then
        log_info "Applying IPv4 Cloudflare ranges..."
        local ipv4_count=0
        while IFS= read -r range; do
            if [[ -n "$range" ]]; then
                ufw allow from "$range" to any port 80,443 comment "CF-IPv4" >/dev/null
                ((ipv4_count++))
            fi
        done < "$cf_ipv4_file"
        log_success "Applied $ipv4_count IPv4 Cloudflare ranges"
        ranges_updated=true
        rm -f "$cf_ipv4_file"
    else
        log_error "Failed to fetch Cloudflare IPv4 ranges"
    fi

    # Fetch IPv6 ranges  
    if curl -sf --max-time 10 "https://www.cloudflare.com/ips-v6" -o "$cf_ipv6_file"; then
        log_info "Applying IPv6 Cloudflare ranges..."
        local ipv6_count=0
        while IFS= read -r range; do
            if [[ -n "$range" ]]; then
                ufw allow from "$range" to any port 80,443 comment "CF-IPv6" >/dev/null
                ((ipv6_count++))
            fi
        done < "$cf_ipv6_file"
        log_success "Applied $ipv6_count IPv6 Cloudflare ranges"
        ranges_updated=true
        rm -f "$cf_ipv6_file"
    else
        log_error "Failed to fetch Cloudflare IPv6 ranges"
    fi

    if [[ "$ranges_updated" == "true" ]]; then
        log_success "UFW Cloudflare IP ranges updated successfully"
        log_info "UFW now blocks direct IP access, forcing traffic through Cloudflare"
        return 0
    else
        log_error "Failed to update any Cloudflare IP ranges"
        return 1
    fi
}

# --- Docker Cleanup ---
cleanup_docker() {
    log_info "Docker cleanup..."

    # Check Docker availability using library function
    if ! check_docker_available; then
        log_warn "Docker not available, skipping Docker cleanup"
        return 0
    fi

    local freed_space=0

    # Clean up stopped containers using library function
    log_info "Removing stopped containers..."
    if [[ "$DRY_RUN" == "true" ]]; then
        local stopped_containers
        stopped_containers=$(docker ps -aq --filter "status=exited" | wc -l)
        log_info "[DRY RUN] Would remove $stopped_containers stopped containers"
    else
        cleanup_containers
        log_success "Stopped containers cleaned up"
    fi

    # Clean up unused images using library function
    log_info "Removing unused Docker images..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: docker image prune -f"
    else
        cleanup_images
        log_success "Unused images cleaned up"
    fi

    # Clean up unused volumes using library function (be careful!)
    log_info "Checking for unused Docker volumes..."
    if [[ "$DRY_RUN" == "true" ]]; then
        local unused_volumes
        unused_volumes=$(docker volume ls -qf dangling=true | wc -l)
        log_info "[DRY RUN] Found $unused_volumes unused volumes"
    else
        cleanup_volumes
        log_success "Unused volumes cleaned up"
    fi

    # Clean up unused networks using library function
    log_info "Cleaning up unused Docker networks..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: docker network prune -f"
    else
        cleanup_networks
        log_success "Unused networks cleaned up"
    fi

    # Show Docker system disk usage
    log_info "Docker system disk usage:"
    if check_docker_available; then
        docker system df 2>/dev/null || log_warn "Could not get Docker disk usage"
    fi

    return 0
}

# --- Local Backup Cleanup ---
cleanup_local_backups() {
    log_info "Local backup cleanup..."

    local backup_dir="$PROJECT_ROOT/backups"
    if [[ ! -d "$backup_dir" ]]; then
        log_info "No backup directory found, skipping local backup cleanup"
        return 0
    fi

    # Define retention periods from environment or use defaults
    local db_retention_days full_retention_days emergency_retention_days
    db_retention_days=$(get_config_value "DB_BACKUP_RETENTION_DAYS" "14")
    full_retention_days=$(get_config_value "FULL_BACKUP_RETENTION_DAYS" "30")
    emergency_retention_days=$(get_config_value "EMERGENCY_BACKUP_RETENTION_DAYS" "90")

    # Clean up old database backups
    log_info "Cleaning local database backups (retention: ${db_retention_days} days)..."
    if [[ "$DRY_RUN" == "true" ]]; then
        local old_db_backups
        old_db_backups=$(find "$backup_dir/db" -name "*.age" -mtime +${db_retention_days} 2>/dev/null | wc -l)
        log_info "[DRY RUN] Would remove $old_db_backups old local database backups"
    else
        local removed_db=0
        while IFS= read -r -d '' backup_file; do
            rm -f "$backup_file" "$backup_file.sha256" "$backup_file.meta"
            ((removed_db++))
        done < <(find "$backup_dir/db" -name "*.age" -mtime +${db_retention_days} -print0 2>/dev/null)

        if [[ $removed_db -gt 0 ]]; then
            log_success "Removed $removed_db old local database backups"
        fi
    fi

    # Clean up old full backups
    log_info "Cleaning local full backups (retention: ${full_retention_days} days)..."
    if [[ "$DRY_RUN" == "true" ]]; then
        local old_full_backups
        old_full_backups=$(find "$backup_dir/full" -name "*.age" -mtime +${full_retention_days} 2>/dev/null | wc -l)
        log_info "[DRY RUN] Would remove $old_full_backups old local full backups"
    else
        local removed_full=0
        while IFS= read -r -d '' backup_file; do
            rm -f "$backup_file" "$backup_file.sha256" "$backup_file.meta"
            ((removed_full++))
        done < <(find "$backup_dir/full" -name "*.age" -mtime +${full_retention_days} -print0 2>/dev/null)

        if [[ $removed_full -gt 0 ]]; then
            log_success "Removed $removed_full old local full backups"
        fi
    fi

    # Clean up old emergency kits (keep longer)
    log_info "Cleaning local emergency kits (retention: ${emergency_retention_days} days)..."
    if [[ "$DRY_RUN" == "true" ]]; then
        local old_emergency
        old_emergency=$(find "$backup_dir/emergency" -name "*.age" -mtime +${emergency_retention_days} 2>/dev/null | wc -l)
        log_info "[DRY RUN] Would remove $old_emergency old local emergency kits"
    else
        local removed_emergency=0
        while IFS= read -r -d '' backup_file; do
            rm -f "$backup_file" "$backup_file.sha256" "$backup_file.meta"
            ((removed_emergency++))
        done < <(find "$backup_dir/emergency" -name "*.age" -mtime +${emergency_retention_days} -print0 2>/dev/null)

        if [[ $removed_emergency -gt 0 ]]; then
            log_success "Removed $removed_emergency old local emergency kits"
        fi
    fi

    return 0
}

# --- Remote Backup Cleanup ---
cleanup_remote_backups() {
    log_info "Remote backup cleanup (via rclone)..."

    local remote_name
    remote_name=$(get_config_value "RCLONE_REMOTE_NAME" "")

    if [[ -z "$remote_name" ]] || [[ "$remote_name" == "CHANGE_ME" ]]; then
        log_warn "RCLONE_REMOTE_NAME not configured in .env. Skipping remote backup cleanup."
        return 0 # Return success, it's just not configured
    fi

    local remote_base_path="$remote_name:vaultwarden_backups" # Standardized remote path

    # Check if remote base path exists
    if ! rclone lsd "$remote_base_path" >/dev/null 2>&1; then
        log_warn "Remote backup path '$remote_base_path' not found or inaccessible. Skipping remote cleanup."
        return 0
    fi

    # Define retention periods from environment or use defaults
    local db_retention_days full_retention_days emergency_retention_days
    db_retention_days=$(get_config_value "DB_BACKUP_RETENTION_DAYS" "14")
    full_retention_days=$(get_config_value "FULL_BACKUP_RETENTION_DAYS" "30")
    emergency_retention_days=$(get_config_value "EMERGENCY_BACKUP_RETENTION_DAYS" "90")

    local rclone_opts=("--log-level" "INFO") # Log rclone actions
    [[ "$DRY_RUN" == "true" ]] && rclone_opts+=("--dry-run")

    local cleanup_failed=false

    # Cleanup DB backups
    log_info "Cleaning remote database backups (older than ${db_retention_days} days)..."
    if ! rclone delete "${rclone_opts[@]}" --min-age "${db_retention_days}d" "${remote_base_path}/db/"; then
        log_error "Failed to clean remote database backups"
        cleanup_failed=true
    else
        log_success "Remote database backup cleanup command executed successfully"
    fi

    # Cleanup Full backups
    log_info "Cleaning remote full backups (older than ${full_retention_days} days)..."
    if ! rclone delete "${rclone_opts[@]}" --min-age "${full_retention_days}d" "${remote_base_path}/full/"; then
        log_error "Failed to clean remote full backups"
        cleanup_failed=true
    else
        log_success "Remote full backup cleanup command executed successfully"
    fi

    # Cleanup Emergency backups
    log_info "Cleaning remote emergency kits (older than ${emergency_retention_days} days)..."
    if ! rclone delete "${rclone_opts[@]}" --min-age "${emergency_retention_days}d" "${remote_base_path}/emergency/"; then
        log_error "Failed to clean remote emergency kits"
        cleanup_failed=true
    else
        log_success "Remote emergency kit cleanup command executed successfully"
    fi

    if [[ "$cleanup_failed" == "true" ]]; then
        return 1 # Indicate failure
    fi
    return 0 # Indicate success
}

# --- System Cleanup ---
cleanup_system() {
    log_info "System cleanup..."

    if ! is_root; then
        log_warn "Skipping system cleanup (requires root)"
        return 0
    fi

    # Clean package cache
    log_info "Cleaning package cache..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: apt autoclean && apt autoremove"
    else
        apt autoclean -y >/dev/null 2>&1 || true
        apt autoremove -y >/dev/null 2>&1 || true
        log_success "Package cache cleaned"
    fi

    # Clean temporary files
    local temp_dirs=("/tmp" "/var/tmp")
    for temp_dir in "${temp_dirs[@]}"; do
        if [[ ! -d "$temp_dir" ]]; then
            continue
        fi

        log_info "Cleaning old temporary files in: $temp_dir"
        if [[ "$DRY_RUN" == "true" ]]; then
            local temp_files
            temp_files=$(find "$temp_dir" -type f -mtime +7 2>/dev/null | wc -l)
            log_info "[DRY RUN] Would remove $temp_files temporary files older than 7 days"
        else
            local removed_temp=0
            while IFS= read -r -d '' temp_file; do
                # Add extra safety check: ensure we are not deleting /tmp or /var/tmp itself
                if [[ "$temp_file" != "$temp_dir" ]]; then
                    rm -f "$temp_file" 2>/dev/null && ((removed_temp++))
                fi
            done < <(find "$temp_dir" -type f -mtime +7 -print0 2>/dev/null)

            if [[ $removed_temp -gt 0 ]]; then
                log_success "Removed $removed_temp temporary files from $temp_dir"
            fi
        fi
    done

    # Clean systemd journal logs (keep last 30 days)
    if has_command journalctl; then
        log_info "Cleaning systemd journal logs..."
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would run: journalctl --vacuum-time=30d"
        else
            journalctl --vacuum-time=30d >/dev/null 2>&1 || true
            log_success "Systemd journal logs cleaned"
        fi
    fi

    return 0
}

# --- Disk Usage Report ---
show_disk_usage() {
    log_info "Current disk usage report:"
    echo ""

    # System disk usage
    echo "System Disk Usage:"
    df -h / 2>/dev/null || echo "  Cannot determine root filesystem usage"

    # Project directory usage
    if [[ -d "$PROJECT_ROOT" ]]; then
        echo ""
        echo "Project Directory Usage:"
        du -sh "$PROJECT_ROOT" 2>/dev/null || echo "  Cannot determine project directory usage"
    fi

    # State directory usage
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    if [[ -d "$state_dir" ]]; then
        echo ""
        echo "VaultWarden State Directory Usage:"
        du -sh "$state_dir" 2>/dev/null || echo "  Cannot determine state directory usage"

        # Break down by subdirectory
        local subdirs=("data" "caddy" "fail2ban") # Updated: removed logs since Docker handles them
        for subdir in "${subdirs[@]}"; do
            if [[ -d "$state_dir/$subdir" ]]; then
                local size
                size=$(du -sh "$state_dir/$subdir" 2>/dev/null | cut -f1)
                echo "  $subdir: $size"
            fi
        done

        # Show Docker log usage (now managed by Docker)
        echo "  docker-logs: managed by json-file driver (max 30MB per service)"
    fi

    # Docker usage if available
    if check_docker_available; then
        echo ""
        echo "Docker System Usage:"
        docker system df 2>/dev/null || echo "  Cannot determine Docker usage"
    fi

    echo ""
}

# --- Main Execution ---
main() {
    log_info "VaultWarden System Maintenance - Enhanced with Security Automation"

    validate_environment || exit 1

    # Load configuration using library function
    load_env_file 2>/dev/null || log_warn "No .env file found"

    # Show current disk usage (except for cf-ranges which is focused)
    if [[ "$CLEANUP_TYPE" != "cf-ranges" ]]; then
        show_disk_usage
    fi

    # Confirm maintenance operation
    if [[ "$FORCE" == "false" && "$DRY_RUN" == "false" ]]; then
        echo ""
        read -p "Proceed with $CLEANUP_TYPE maintenance? (Y/n): " confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            log_info "Maintenance cancelled"
            exit 0
        fi
    fi

    echo ""
    log_info "Starting $CLEANUP_TYPE maintenance..."

    local exit_code=0

    # Execute maintenance based on type
    case "$CLEANUP_TYPE" in
        "standard")
            cleanup_local_backups || exit_code=1
            cleanup_remote_backups || exit_code=1
            cleanup_docker || exit_code=1
            ;;
        "deep")
            cleanup_local_backups || exit_code=1
            cleanup_remote_backups || exit_code=1
            cleanup_docker || exit_code=1
            cleanup_system || exit_code=1
            ;;
        "docker")
            cleanup_docker || exit_code=1
            ;;
        "cf-ranges")
            update_ufw_cloudflare_ranges || exit_code=1
            ;;
        *)
            log_error "Unknown cleanup type: $CLEANUP_TYPE"
            log_info "Valid types: standard, deep, docker, cf-ranges"
            exit 1
            ;;
    esac

    echo ""
    if [[ $exit_code -eq 0 ]]; then
      log_success "Maintenance completed successfully!"
    else
      log_error "Maintenance completed with errors."
    fi

    # Show updated disk usage (except for cf-ranges)
    if [[ "$CLEANUP_TYPE" != "cf-ranges" ]]; then
        echo ""
        show_disk_usage
    fi

    echo ""
    log_info "Maintenance summary:"
    echo "  Type: $CLEANUP_TYPE"
    echo "  Completed: $(date)"
    if [[ "$CLEANUP_TYPE" == "cf-ranges" ]]; then
        echo "  Security: UFW Cloudflare IP ranges synchronized"
    else
        echo "  Log rotation: Handled by Docker json-file driver"
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  Mode: Dry run (no changes made)"
    fi

    exit $exit_code
}

main "$@"
