#!/usr/bin/env bash
# cron-setup.sh - Automated cron job configuration for VaultWarden-OCI
# ENHANCED: Standardized error handling - functions return, main() decides exit strategy
# All functions return exit codes, main() collects status and determines final exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"

# Configuration
INSTALL_CRON=false
REMOVE_CRON=false
LIST_CRON=false
DRY_RUN=false
CRON_USER=""
ENABLE_BACKUPS=true
ENABLE_MAINTENANCE=true
ENABLE_UPDATES=false
ENABLE_HEALTH_MONITORING=true

show_help() {
    cat << 'EOF'
VaultWarden-OCI Cron Setup - Automated Task Scheduling

USAGE:
    sudo ./cron-setup.sh [OPTIONS]

OPTIONS:
    --install               Install cron jobs for automation
    --remove                Remove all VaultWarden cron jobs
    --list                  List current VaultWarden cron jobs
    --user USER             Run cron jobs as specific user (default: detected)
    --no-backups            Disable automated backups
    --no-maintenance        Disable automated maintenance
    --enable-updates        Enable automated updates (disabled by default)
    --no-health             Disable health monitoring
    --dry-run               Show what would be configured without executing
    --help                  Show this help

AUTOMATED TASKS:
    Backups:
    - Database backup: Daily at 2:00 AM
    - Full backup: Weekly on Sunday at 3:00 AM
    - Emergency kit: Monthly on 1st at 4:00 AM

    Maintenance:
    - Basic maintenance: Weekly on Monday at 1:00 AM
    - Comprehensive maintenance: Monthly on 15th at 2:00 AM

    Health Monitoring:
    - Health check: Every 4 hours
    - Alert on failures

    Updates (Optional):
    - Container updates: Weekly on Saturday at 5:00 AM

EXAMPLES:
    sudo ./cron-setup.sh --install                    # Install with defaults
    sudo ./cron-setup.sh --install --enable-updates   # Include auto-updates
    sudo ./cron-setup.sh --list                       # Show current jobs
    sudo ./cron-setup.sh --remove                     # Remove all jobs
EOF
}

# Argument Parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --install) INSTALL_CRON=true; shift ;;
        --remove) REMOVE_CRON=true; shift ;;
        --list) LIST_CRON=true; shift ;;
        --user) CRON_USER="$2"; shift 2 ;;
        --no-backups) ENABLE_BACKUPS=false; shift ;;
        --no-maintenance) ENABLE_MAINTENANCE=false; shift ;;
        --enable-updates) ENABLE_UPDATES=true; shift ;;
        --no-health) ENABLE_HEALTH_MONITORING=false; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Validation
if [[ "$INSTALL_CRON" == "true" && "$REMOVE_CRON" == "true" ]]; then
    log_error "Cannot install and remove at the same time"
    exit 1
fi

if [[ "$INSTALL_CRON" == "false" && "$REMOVE_CRON" == "false" && "$LIST_CRON" == "false" ]]; then
    log_error "Must specify --install, --remove, or --list"
    show_help
    exit 1
fi

# STANDARDIZED: Detect appropriate user - returns exit code
detect_cron_user() {
    if [[ -n "$CRON_USER" ]]; then
        # Validate specified user exists
        if ! id "$CRON_USER" >/dev/null 2>&1; then
            log_error "Specified user does not exist: $CRON_USER"
            return 1
        fi
        log_info "Using specified cron user: $CRON_USER"
        return 0
    fi

    # Auto-detect appropriate user
    local real_user
    real_user=$(get_real_user)

    # Ensure user exists and is in docker group
    if ! id "$real_user" >/dev/null 2>&1; then
        log_error "Real user does not exist: $real_user"
        return 1
    fi

    if ! groups "$real_user" | grep -q docker; then
        log_error "User $real_user is not in docker group"
        log_info "Add with: sudo usermod -aG docker $real_user"
        return 1
    fi

    CRON_USER="$real_user"
    log_info "Detected cron user: $CRON_USER"
    return 0
}

# STANDARDIZED: Generate cron job content - returns exit code
generate_cron_jobs() {
    log_info "Generating cron job configuration..."

    local cron_content=""
    
    # Header
    cron_content+="# VaultWarden-OCI Automated Tasks - Generated $(date)\n"
    cron_content+="# Project: $PROJECT_ROOT\n"
    cron_content+="# User: $CRON_USER\n"
    cron_content+="\n"

    # Environment variables for cron
    cron_content+="# Environment\n"
    cron_content+="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n"
    cron_content+="MAILTO=\"\"\n"
    cron_content+="\n"

    # Backup jobs
    if [[ "$ENABLE_BACKUPS" == "true" ]]; then
        cron_content+="# Database Backups - Daily at 2:00 AM\n"
        cron_content+="0 2 * * * cd $PROJECT_ROOT && ./backup.sh --type db --email >/dev/null 2>&1\n"
        cron_content+="\n"
        
        cron_content+="# Full System Backup - Weekly on Sunday at 3:00 AM\n"
        cron_content+="0 3 * * 0 cd $PROJECT_ROOT && ./backup.sh --type full --email >/dev/null 2>&1\n"
        cron_content+="\n"
        
        cron_content+="# Emergency Recovery Kit - Monthly on 1st at 4:00 AM\n"
        cron_content+="0 4 1 * * cd $PROJECT_ROOT && ./backup.sh --type emergency --email >/dev/null 2>&1\n"
        cron_content+="\n"
    fi

    # Maintenance jobs
    if [[ "$ENABLE_MAINTENANCE" == "true" ]]; then
        cron_content+="# Basic Maintenance - Weekly on Monday at 1:00 AM\n"
        cron_content+="0 1 * * 1 cd $PROJECT_ROOT && ./maintenance.sh --email >/dev/null 2>&1\n"
        cron_content+="\n"
        
        cron_content+="# Comprehensive Maintenance - Monthly on 15th at 2:00 AM\n"
        cron_content+="0 2 15 * * cd $PROJECT_ROOT && ./maintenance.sh --comprehensive --email >/dev/null 2>&1\n"
        cron_content+="\n"
    fi

    # Update jobs (optional)
    if [[ "$ENABLE_UPDATES" == "true" ]]; then
        cron_content+="# Container Updates - Weekly on Saturday at 5:00 AM\n"
        cron_content+="0 5 * * 6 cd $PROJECT_ROOT && ./update.sh --email >/dev/null 2>&1\n"
        cron_content+="\n"
    fi

    # Health monitoring
    if [[ "$ENABLE_HEALTH_MONITORING" == "true" ]]; then
        cron_content+="# Health Monitoring - Every 4 hours\n"
        cron_content+="0 */4 * * * cd $PROJECT_ROOT && ./health.sh --quiet || ./health.sh --email >/dev/null 2>&1\n"
        cron_content+="\n"
    fi

    echo -e "$cron_content"
    return 0
}

# STANDARDIZED: Install cron jobs - returns exit code
install_cron_jobs() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install cron jobs for user: $CRON_USER"
        local cron_jobs
        cron_jobs=$(generate_cron_jobs)
        echo "Cron jobs that would be installed:"
        echo "=================================="
        echo -e "$cron_jobs"
        return 0
    fi

    log_info "Installing cron jobs for user: $CRON_USER..."

    # Get current crontab
    local current_crontab="/tmp/vw_current_crontab_$$"
    local new_crontab="/tmp/vw_new_crontab_$$"

    # Cleanup temp files on exit
    trap "rm -f '$current_crontab' '$new_crontab'" EXIT

    # Get existing crontab (might not exist)
    if ! crontab -u "$CRON_USER" -l > "$current_crontab" 2>/dev/null; then
        # No existing crontab, create empty one
        touch "$current_crontab"
    fi

    # Remove any existing VaultWarden jobs
    if ! grep -v "VaultWarden-OCI" "$current_crontab" > "$new_crontab"; then
        # If grep fails (no non-matching lines), create empty file
        touch "$new_crontab"
    fi

    # Add new VaultWarden jobs
    local vw_cron_jobs
    if ! vw_cron_jobs=$(generate_cron_jobs); then
        log_error "Failed to generate cron jobs"
        return 1
    fi

    echo -e "$vw_cron_jobs" >> "$new_crontab"

    # Install new crontab
    if crontab -u "$CRON_USER" "$new_crontab"; then
        log_success "Cron jobs installed successfully for user: $CRON_USER"
        
        # Show what was installed
        local job_count
        job_count=$(echo -e "$vw_cron_jobs" | grep -c "cd $PROJECT_ROOT" || echo "0")
        log_info "Installed $job_count automated tasks"
        
        return 0
    else
        log_error "Failed to install cron jobs"
        return 1
    fi
}

# STANDARDIZED: Remove cron jobs - returns exit code
remove_cron_jobs() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would remove VaultWarden cron jobs for user: $CRON_USER"
        return 0
    fi

    log_info "Removing VaultWarden cron jobs for user: $CRON_USER..."

    # Get current crontab
    local current_crontab="/tmp/vw_current_crontab_$$"
    local new_crontab="/tmp/vw_new_crontab_$$"

    # Cleanup temp files on exit
    trap "rm -f '$current_crontab' '$new_crontab'" EXIT

    # Get existing crontab
    if ! crontab -u "$CRON_USER" -l > "$current_crontab" 2>/dev/null; then
        log_info "No existing crontab found for user: $CRON_USER"
        return 0
    fi

    # Count existing VaultWarden jobs
    local existing_jobs
    existing_jobs=$(grep -c "VaultWarden-OCI\|cd $PROJECT_ROOT" "$current_crontab" || echo "0")

    if [[ "$existing_jobs" -eq "0" ]]; then
        log_info "No VaultWarden cron jobs found to remove"
        return 0
    fi

    # Remove VaultWarden jobs
    if grep -v "VaultWarden-OCI\|cd $PROJECT_ROOT" "$current_crontab" > "$new_crontab"; then
        # Install cleaned crontab
        if crontab -u "$CRON_USER" "$new_crontab"; then
            log_success "Removed $existing_jobs VaultWarden cron jobs"
            return 0
        else
            log_error "Failed to update crontab after removing jobs"
            return 1
        fi
    else
        # All lines were VaultWarden jobs, remove entire crontab
        if crontab -u "$CRON_USER" -r; then
            log_success "Removed all cron jobs (crontab was entirely VaultWarden jobs)"
            return 0
        else
            log_error "Failed to remove crontab"
            return 1
        fi
    fi
}

# STANDARDIZED: List current cron jobs - returns exit code
list_cron_jobs() {
    log_info "Current VaultWarden cron jobs for user: $CRON_USER"
    echo ""

    # Get current crontab
    local current_crontab
    if current_crontab=$(crontab -u "$CRON_USER" -l 2>/dev/null); then
        # Filter for VaultWarden jobs
        local vw_jobs
        vw_jobs=$(echo "$current_crontab" | grep -E "VaultWarden-OCI|cd $PROJECT_ROOT" || echo "")

        if [[ -n "$vw_jobs" ]]; then
            echo "Found VaultWarden cron jobs:"
            echo "============================="
            echo "$vw_jobs"
            echo ""
            
            local job_count
            job_count=$(echo "$vw_jobs" | grep -c "cd $PROJECT_ROOT" || echo "0")
            log_info "Total VaultWarden automated tasks: $job_count"
        else
            log_info "No VaultWarden cron jobs found"
        fi
    else
        log_info "No crontab found for user: $CRON_USER"
    fi

    # Show cron service status
    echo ""
    log_info "Cron service status:"
    if systemctl is-active --quiet cron; then
        log_success "Cron service is running"
    else
        log_warn "Cron service is not running"
        log_info "Start with: sudo systemctl start cron"
    fi

    return 0
}

# STANDARDIZED: Validate cron environment - returns exit code
validate_cron_environment() {
    log_info "Validating cron environment..."

    # Check if cron service is installed and running
    if ! has_command crontab; then
        log_error "crontab command not found"
        log_info "Install with: sudo apt install cron"
        return 1
    fi

    if ! systemctl is-enabled --quiet cron; then
        log_warn "Cron service is not enabled"
        log_info "Enable with: sudo systemctl enable cron"
    fi

    if ! systemctl is-active --quiet cron; then
        log_error "Cron service is not running"
        log_info "Start with: sudo systemctl start cron"
        return 1
    fi

    # Check if project scripts are executable
    local required_scripts=("health.sh" "backup.sh" "maintenance.sh")
    if [[ "$ENABLE_UPDATES" == "true" ]]; then
        required_scripts+=("update.sh")
    fi

    local missing_scripts=()
    for script in "${required_scripts[@]}"; do
        if [[ ! -x "$PROJECT_ROOT/$script" ]]; then
            missing_scripts+=("$script")
        fi
    done

    if [[ ${#missing_scripts[@]} -gt 0 ]]; then
        log_error "Required scripts are not executable: ${missing_scripts[*]}"
        log_info "Fix with: chmod +x ${missing_scripts[*]}"
        return 1
    fi

    # Check if .env file exists (needed for cron environment)
    if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
        log_error "Configuration file not found: .env"
        log_info "Run setup.sh first to create configuration"
        return 1
    fi

    log_success "Cron environment validation passed"
    return 0
}

# ENHANCED: Main function with proper error handling and exit strategy
main() {
    log_header "VaultWarden-OCI Cron Setup Manager"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    # Detect appropriate user for cron jobs
    if ! detect_cron_user; then
        exit 1
    fi

    # Handle list operation
    if [[ "$LIST_CRON" == "true" ]]; then
        if list_cron_jobs; then
            exit 0
        else
            exit 1
        fi
    fi

    # Handle remove operation
    if [[ "$REMOVE_CRON" == "true" ]]; then
        log_info "=== Removing VaultWarden Cron Jobs ==="
        if remove_cron_jobs; then
            log_success "VaultWarden cron jobs removed successfully"
            exit 0
        else
            log_error "Failed to remove VaultWarden cron jobs"
            exit 1
        fi
    fi

    # Handle install operation
    if [[ "$INSTALL_CRON" == "true" ]]; then
        log_info "=== Installing VaultWarden Cron Jobs ==="

        # Validate environment
        if ! validate_cron_environment; then
            log_error "Cron environment validation failed"
            exit 1
        fi

        # Show configuration summary
        log_info "Cron job configuration:"
        echo "  User: $CRON_USER"
        echo "  Project: $PROJECT_ROOT"
        echo "  Backups: $ENABLE_BACKUPS"
        echo "  Maintenance: $ENABLE_MAINTENANCE"
        echo "  Updates: $ENABLE_UPDATES"
        echo "  Health Monitoring: $ENABLE_HEALTH_MONITORING"
        echo ""

        # Install jobs
        if install_cron_jobs; then
            log_success "VaultWarden cron jobs installed successfully"
            
            echo ""
            log_info "🎯 Automation enabled! Your VaultWarden instance will now:"
            if [[ "$ENABLE_BACKUPS" == "true" ]]; then
                echo "  • Create daily database backups (2 AM)"
                echo "  • Create weekly full backups (Sunday 3 AM)"
                echo "  • Create monthly emergency kits (1st 4 AM)"
            fi
            if [[ "$ENABLE_MAINTENANCE" == "true" ]]; then
                echo "  • Run weekly maintenance (Monday 1 AM)"
                echo "  • Run comprehensive maintenance (15th 2 AM)"
            fi
            if [[ "$ENABLE_UPDATES" == "true" ]]; then
                echo "  • Update containers weekly (Saturday 5 AM)"
            fi
            if [[ "$ENABLE_HEALTH_MONITORING" == "true" ]]; then
                echo "  • Monitor health every 4 hours"
            fi
            
            echo ""
            log_info "Useful commands:"
            echo "  • List cron jobs: sudo ./cron-setup.sh --list"
            echo "  • Remove cron jobs: sudo ./cron-setup.sh --remove"
            echo "  • Check cron logs: sudo journalctl -u cron"
            echo "  • Test backup: ./backup.sh --type db"
            echo "  • Test health check: ./health.sh"
            
            exit 0
        else
            log_error "Failed to install VaultWarden cron jobs"
            exit 1
        fi
    fi

    # Should not reach here
    log_error "No valid operation specified"
    show_help
    exit 1
}

main "$@"
