#!/usr/bin/env bash
# cron-setup.sh - Simplified cron job management with library integration
# Uses centralized library functions

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0"
# P14 FIX: Need docker library for container checks
source "lib/docker.sh"

# --- Configuration ---
REMOVE_CRONS=false
DRY_RUN=false

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden Cron Job Setup

USAGE:
    sudo ./cron-setup.sh [OPTIONS]

OPTIONS:
    --remove     Remove existing VaultWarden cron jobs
    --dry-run    Show what would be done without executing
    --help       Show this help

DESCRIPTION:
    Sets up automated cron jobs for VaultWarden maintenance:
    - Weekly maintenance (Sunday 00:00) - Prunes old backups/logs
    - Daily database backups (2:00 AM) with rclone sync and email
    - Weekly full backups (Sunday 1:00 AM) with rclone sync and email
    - Quarterly DB VACUUM (1st Sunday Jan/Apr/Jul/Oct 1:00 AM)
    - Daily health checks (every 6 hours) with email on failure
    - Weekly container updates (Sunday 3:00 AM) with email notification
    - Monthly system updates (First Sunday 4:00 AM) with email and auto-reboot
    - Weekly Cloudflare IP updates (Monday 5:00 AM) with email on failure

EXAMPLES:
    sudo ./cron-setup.sh           # Install cron jobs
    sudo ./cron-setup.sh --remove  # Remove cron jobs
    sudo ./cron-setup.sh --dry-run # Preview changes
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --remove) REMOVE_CRONS=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Validation ---
validate_environment() {
    # Check if running as root using library function
    if ! is_root; then
        log_error "Cron setup requires root privileges"
        log_info "Run with: sudo ./cron-setup.sh"
        return 1
    fi

    # Check required commands using library function
    require_commands crontab rclone mail docker || return 1

    # Ensure project scripts are executable
    # --- FIX: Added maintenance.sh and db-maint.sh ---
    local scripts=("backup.sh" "health.sh" "update.sh" "update-cloudflare-ips.sh" "maintenance.sh" "db-maint.sh")
    for script in "${scripts[@]}"; do
        if [[ ! -f "$PROJECT_ROOT/$script" ]]; then
           log_error "Required script not found: $script"
           return 1
        elif [[ ! -x "$PROJECT_ROOT/$script" ]]; then
            log_warn "Making script executable: $script"
            chmod +x "$PROJECT_ROOT/$script"
        fi
    done

    return 0
}

# --- Cron Management ---
get_current_crontab() {
    # Get current crontab, handle case where no crontab exists
    crontab -l 2>/dev/null || echo ""
}

remove_vaultwarden_crons() {
    log_info "Removing VaultWarden cron jobs..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would remove VaultWarden cron jobs"
        return 0
    fi

    local current_crons temp_crons
    current_crons=$(get_current_crontab)

    if [[ -z "$current_crons" ]]; then
        log_info "No existing crontab found"
        return 0
    fi

    # Filter out VaultWarden-related cron jobs
    temp_crons=$(mktemp)
    setup_cleanup_trap "rm -f '$temp_crons'"

    echo "$current_crons" | grep -v "# VaultWarden-OCI-NG" | grep -v "$PROJECT_ROOT" > "$temp_crons" || true

    # Install filtered crontab
    if crontab "$temp_crons"; then
        log_success "VaultWarden cron jobs removed"
    else
        log_error "Failed to update crontab"
        return 1
    fi

    return 0
}

install_vaultwarden_crons() {
    log_info "Installing VaultWarden cron jobs..."

    # Get real user using library function
    local real_user
    real_user=$(get_real_user)

    # Define cron jobs
    local cron_jobs
    # --- P11 FIX: Explicitly source .env in each job ---
    # Redirect all cron output to logs/cron.log
    read -r -d '' cron_jobs << EOF || true
# VaultWarden-OCI-NG Automated Tasks
# Generated on $(date)

# --- FIX: Added Weekly Maintenance Job (Prevents Disk Full) ---
# Weekly maintenance (prune old backups/logs/docker) on Sunday 00:00
0 0 * * 0 root cd $PROJECT_ROOT && source .env && ./maintenance.sh --type standard --force >> $PROJECT_ROOT/logs/cron.log 2>&1

# Daily database backup at 2:00 AM, with rclone sync and email
0 2 * * * $real_user cd $PROJECT_ROOT && source .env && ./backup.sh --type db --rclone --email >> $PROJECT_ROOT/logs/cron.log 2>&1

# Weekly full backup on Sunday at 1:00 AM, with rclone sync and email
0 1 * * 0 $real_user cd $PROJECT_ROOT && source .env && ./backup.sh --type full --rclone --email >> $PROJECT_ROOT/logs/cron.log 2>&1

# --- FIX: Added Quarterly Database Maintenance ---
# Quarterly database maintenance (VACUUM, etc) on the 1st Sunday of Jan/Apr/Jul/Oct at 1:00 AM
0 1 1-7 1,4,7,10 0 root cd $PROJECT_ROOT && source .env && ./db-maint.sh --force >> $PROJECT_ROOT/logs/cron.log 2>&1

# Health check every 6 hours with auto-heal and email on failure
0 */6 * * * $real_user cd $PROJECT_ROOT && source .env && ./health.sh --auto-heal --quiet --email-alert >> $PROJECT_ROOT/logs/cron.log 2>&1

# Weekly container updates on Sunday at 3:00 AM (sends email)
0 3 * * 0 $real_user cd $PROJECT_ROOT && source .env && ./update.sh --type containers --force >> $PROJECT_ROOT/logs/cron.log 2>&1

# Monthly system updates on first Sunday at 4:00 AM (sends email, auto-reboots)
0 4 1-7 * 0 root cd $PROJECT_ROOT && source .env && ./update.sh --type system --force >> $PROJECT_ROOT/logs/cron.log 2>&1

# Weekly Cloudflare IP update on Monday at 5:00 AM (runs as root, sends email on failure)
0 5 * * 1 root cd $PROJECT_ROOT && source .env && ./update-cloudflare-ips.sh >> $PROJECT_ROOT/logs/cron.log 2>&1
# --- END P11 FIX ---

EOF

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install the following cron jobs:"
        echo "$cron_jobs"
        return 0
    fi

    # Get current crontab and append new jobs
    local current_crons temp_file
    current_crons=$(get_current_crontab)
    temp_file=$(mktemp)
    setup_cleanup_trap "rm -f '$temp_file'"

    # Ensure log directory exists for cron output
    local real_group=$(id -g -n "$real_user") || real_group="$real_user"
    ensure_dir "$PROJECT_ROOT/logs" 755 "$real_user:$real_group"

    # Remove any existing VaultWarden crons first
    if [[ -n "$current_crons" ]]; then
        echo "$current_crons" | grep -v "# VaultWarden-OCI-NG" | grep -v "$PROJECT_ROOT" > "$temp_file" || true
    fi

    # Add new cron jobs
    echo "" >> "$temp_file"
    echo "$cron_jobs" >> "$temp_file"

    # Install updated crontab
    if crontab "$temp_file"; then
        log_success "VaultWarden cron jobs installed"
    else
        log_error "Failed to install crontab"
        return 1
    fi

    # Verify cron service is running
    if systemctl is-active cron >/dev/null 2>&1 || systemctl is-active crond >/dev/null 2>&1; then
        log_success "Cron service is running"
    else
        log_warn "Cron service may not be running"
        log_info "Start with: sudo systemctl start cron"
    fi

    return 0
}

show_current_crons() {
    log_info "Current VaultWarden-related cron jobs:"
    echo ""

    local current_crons
    current_crons=$(get_current_crontab)

    if [[ -z "$current_crons" ]]; then
        log_info "No crontab found"
        return 0
    fi

    # Show only VaultWarden-related crons
    local vw_crons
    vw_crons=$(echo "$current_crons" | grep -A 20 "# VaultWarden-OCI-NG" || echo "")

    if [[ -z "$vw_crons" ]]; then
        log_info "No VaultWarden cron jobs found"
    else
        echo "$vw_crons"
    fi

    echo ""
}

# --- Log Rotation Configuration ---
setup_log_rotation() {
    log_info "Setting up log rotation for VaultWarden..."

    local logrotate_conf="/etc/logrotate.d/vaultwarden"
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local real_user
    real_user=$(get_real_user)
    local real_group=$(id -g -n "$real_user") || real_group="$real_user"
    # P14 FIX: Get predictable container names from .env or defaults
    local compose_project_name=$(get_config_value "COMPOSE_PROJECT_NAME" "vaultwarden")
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create logrotate configuration: $logrotate_conf"
        return 0
    fi

    # Create logrotate configuration
    cat > "$logrotate_conf" << EOF
# VaultWarden-OCI-NG Log Rotation
# --- FIX: Removed Caddy logs (self-rotates) ---
$state_dir/logs/vaultwarden/*.log $state_dir/logs/fail2ban/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 $real_user $real_group
    sharedscripts
    postrotate
        # --- FIX: Robust postrotate script ---
        if command -v docker >/dev/null 2>&1 && [[ -f "$PROJECT_ROOT/.env" ]]; then
            # Get the COMPOSE_PROJECT_NAME from the .env file
            PROJECT_NAME=\$(grep -E '^COMPOSE_PROJECT_NAME=' "$PROJECT_ROOT/.env" | cut -d= -f2)
            PROJECT_NAME=\${PROJECT_NAME:-vaultwarden}
            
            # Use docker compose exec to find the container and flush logs
            (cd "$PROJECT_ROOT" && \
             docker compose -p "\$PROJECT_NAME" exec -T fail2ban fail2ban-client flushlogs >/dev/null 2>&1) || \
             echo "Failed to flush fail2ban logs" >> /var/log/syslog
        else
            echo "Could not find docker or .env file, skipping fail2ban log flush" >> /var/log/syslog
        fi
        # --- END FIX ---
    endscript
}

# Rotate cron job output log
$PROJECT_ROOT/logs/cron.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 644 $real_user $real_group
}

# Rotate project backup script logs (if any are created)
$PROJECT_ROOT/backups/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF

    log_success "Log rotation configured: $logrotate_conf"
    # Ensure logrotate runs daily if needed
    if [[ ! -f /etc/cron.daily/logrotate ]]; then
        log_warn "Logrotate daily cron job may not be configured on this system."
    fi
    return 0
}

# --- Cron Service Management ---
ensure_cron_service() {
    log_info "Ensuring cron service is enabled and running..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would check and start cron service"
        return 0
    fi

    # Try both cron and crond service names
    local cron_service=""
    if systemctl list-unit-files | grep -q "^cron.service"; then
        cron_service="cron"
    elif systemctl list-unit-files | grep -q "^crond.service"; then
        cron_service="crond"
    else
        log_warn "Could not find cron service"
        return 1
    fi

    # Enable and start cron service
    if ! systemctl is-enabled "$cron_service" >/dev/null 2>&1; then
        log_info "Enabling cron service..."
        systemctl enable "$cron_service" || log_warn "Failed to enable cron service"
    fi

    if ! systemctl is-active "$cron_service" >/dev/null 2>&1; then
        log_info "Starting cron service..."
        systemctl start "$cron_service" || {
            log_error "Failed to start cron service"
            return 1
        }
    fi

    log_success "Cron service is running and enabled"
    return 0
}

# --- Configuration Validation ---
validate_scripts() {
    log_info "Validating automation scripts..."

    # --- FIX: Added maintenance.sh and db-maint.sh ---
    local scripts=("backup.sh" "health.sh" "update.sh" "update-cloudflare-ips.sh" "maintenance.sh" "db-maint.sh")
    local missing_scripts=()
    local non_executable=()

    for script in "${scripts[@]}"; do
        if [[ ! -f "$PROJECT_ROOT/$script" ]]; then
            missing_scripts+=("$script")
        elif [[ ! -x "$PROJECT_ROOT/$script" ]]; then
            non_executable+=("$script")
        fi
    done

    if [[ ${#missing_scripts[@]} -gt 0 ]]; then
        log_error "Missing required scripts: ${missing_scripts[*]}"
        return 1
    fi

    if [[ ${#non_executable[@]} -gt 0 ]]; then
        log_warn "Making scripts executable: ${non_executable[*]}"
        if [[ "$DRY_RUN" != "true" ]]; then
            for script in "${non_executable[@]}"; do
                chmod +x "$PROJECT_ROOT/$script"
            done
        fi
    fi

    log_success "All automation scripts are available and executable"
    return 0
}

# --- Main Execution ---
main() {
    log_info "VaultWarden Cron Setup"

    validate_environment || exit 1

    # Load configuration if available using library function
    load_env_file 2>/dev/null || log_warn "No .env file found, using defaults"

    if [[ "$REMOVE_CRONS" == "true" ]]; then
        remove_vaultwarden_crons || exit 1
    else
        show_current_crons

        # Validate scripts before installing crons
        validate_scripts || exit 1

        # Ask for confirmation unless dry run
        if [[ "$DRY_RUN" == "false" ]]; then
            echo ""
            read -p "Install/update VaultWarden cron jobs? (Y/n): " confirm
            if [[ "$confirm" =~ ^[Nn]$ ]]; then
                log_info "Cancelled"
                exit 0
            fi
        fi

        # Ensure cron service is running
        ensure_cron_service || log_warn "Cron service issues detected"

        # Install cron jobs
        install_vaultwarden_crons || exit 1

        # Setup log rotation
        setup_log_rotation || log_warn "Failed to setup log rotation (non-critical)"

        echo ""
        log_success "Cron setup completed!"
        echo ""
        echo "Scheduled Tasks:"
        echo "  • Weekly maintenance: Sunday 00:00 (Prunes old backups/logs)"
        echo "  • Daily DB backup: 2:00 AM (with Rclone sync & email)"
        echo "  • Weekly full backup: Sunday 1:00 AM (with Rclone sync & email)"
        echo "  • Quarterly DB maintenance: 1st Sun of Jan/Apr/Jul/Oct at 1:00 AM"
        echo "  • Health check: Every 6 hours (with email on failure)"
        echo "  • Container updates: Sunday 3:00 AM (with email notification)"
        echo "  • System updates: First Sunday 4:00 AM (with email & auto-reboot)"
        echo "  • Cloudflare IP updates: Monday 5:00 AM (with email on failure)"
        echo ""
        echo "Management Commands:"
        echo "  • View cron jobs: sudo crontab -l"
        echo "  • Check cron logs: sudo less /var/log/syslog | grep CRON or journalctl -u cron"
        echo "  • Check project cron logs: less $PROJECT_ROOT/logs/cron.log"
        echo "  • Manual health check: ./health.sh --comprehensive"
    fi
}

main "$@"

