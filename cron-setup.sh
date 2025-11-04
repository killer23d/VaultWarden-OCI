#!/usr/bin/env bash
# cron-setup.sh - Secure VaultWarden cron job management with centralized security functions
# ENHANCED: Uses lib/security.sh for centralized security validation
# ENHANCED: Eliminates code duplication and improves maintainability
# UPDATED: Differentiated daily (fast) and weekly (full) backup verification

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/security.sh"  # ENHANCED: Use centralized security functions

# Configuration
INSTALL_CRON=false
REMOVE_CRON=false
LIST_CRON=false
DRY_RUN=false
VALIDATE_ONLY=false

# Cron job configuration
CRON_USER="root"
CRON_SCRIPTS_DIR="/opt/vaultwarden-scripts"
CRON_LOG_DIR="/var/log/vaultwarden-cron"

show_help() {
    cat << 'EOF'
VaultWarden-OCI Secure Cron Setup - Centralized Security Functions

USAGE:
    sudo ./cron-setup.sh [OPTIONS]

OPTIONS:
    --install               Install VaultWarden cron jobs securely
    --remove                Remove VaultWarden cron jobs
    --list                  List current VaultWarden cron jobs
    --validate              Validate existing cron job security
    --dry-run               Show what would be done without executing
    --help                  Show this help

SECURITY FEATURES:
    - Uses centralized lib/security.sh validation functions
    - Validates script ownership (must be root:root)
    - Ensures proper script permissions (700)
    - Creates hardened copies in secure directory
    - Validates script integrity before scheduling
    - Implements secure logging with proper permissions

CRON JOBS MANAGED:
    - Daily DB backup (fast verification)
    - Weekly Full backup (comprehensive verification)
    - Health monitoring (every 30 minutes)
    - Maintenance & Firewall (weekly)

EXAMPLES:
    sudo ./cron-setup.sh --install     # Install secure cron jobs
    sudo ./cron-setup.sh --validate    # Validate current setup
    sudo ./cron-setup.sh --remove      # Remove all cron jobs
EOF
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --install) INSTALL_CRON=true; shift ;;
        --remove) REMOVE_CRON=true; shift ;;
        --list) LIST_CRON=true; shift ;;
        --validate) VALIDATE_ONLY=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# ENHANCED: Script security validation using centralized lib/security.sh functions
validate_script_security() {
    local script_path="$1"
    local script_name="$(basename "$script_path")"

    log_debug "Validating security of script: $script_name"

    # Use centralized validation function from lib/security.sh
    if ! validate_file_permissions "$script_path" "700" "root" "root"; then
        log_error "SECURITY: Script $script_name failed security validation"
        log_error "This creates a privilege escalation risk when run by root cron"
        return 1
    fi

    # Additional script-specific security checks
    if [[ ! -x "$script_path" ]]; then
        log_error "Script $script_name is not executable"
        return 1
    fi

    # Check for suspicious content patterns
    if grep -q -E '(sudo|su |pkexec|chmod \+s)' "$script_path"; then
        log_warn "SECURITY: Script $script_name contains privilege escalation commands"
        log_warn "Review manually: grep -E '(sudo|su |pkexec|chmod \\+s)' '$script_path'"
    fi

    # Validate script has proper shebang
    local shebang
    shebang=$(head -1 "$script_path")
    if [[ ! "$shebang" =~ ^#!/(usr/)?bin/(bash|sh)$ ]]; then
        log_warn "Script $script_name has unusual shebang: $shebang"
    fi

    log_success "Script security validation passed: $script_name"
    return 0
}

# ENHANCED: Create hardened script copies using centralized secure file functions
create_secure_script_copy() {
    local source_script="$1"
    local script_name="$(basename "$source_script")"
    local secure_copy="$CRON_SCRIPTS_DIR/$script_name"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create secure copy: $secure_copy"
        return 0
    fi

    log_info "Creating secure script copy: $script_name"

    # Ensure secure scripts directory exists with proper permissions
    if ! ensure_dir "$CRON_SCRIPTS_DIR" 750; then
        log_error "Failed to create secure scripts directory"
        return 1
    fi

    # Use centralized directory validation
    if ! validate_directory_permissions "$CRON_SCRIPTS_DIR" "750" "root" "root"; then
        # Fix permissions if validation failed
        if ! chown root:root "$CRON_SCRIPTS_DIR" || ! chmod 750 "$CRON_SCRIPTS_DIR"; then
            log_error "Failed to secure scripts directory"
            return 1
        fi
    fi

    # Read source script content
    local script_content
    if ! script_content=$(cat "$source_script"); then
        log_error "Failed to read source script: $source_script"
        return 1
    fi

    # Use centralized secure file creation
    if ! create_secure_file "$secure_copy" "$script_content" "700" "root" "root"; then
        log_error "Failed to create secure script copy"
        return 1
    fi

    # Verify the copy is identical
    if ! cmp -s "$source_script" "$secure_copy"; then
        log_error "Script copy verification failed - files differ"
        return 1
    fi

    log_success "Secure script copy created: $secure_copy"
    echo "$secure_copy"
    return 0
}

# STANDARDIZED: Setup secure logging directory using centralized functions
setup_cron_logging() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would setup secure cron logging"
        return 0
    fi

    log_info "Setting up secure cron job logging..."

    # Create log directory with proper permissions
    if ! ensure_dir "$CRON_LOG_DIR" 750; then
        log_error "Failed to create cron log directory"
        return 1
    fi

    # Use centralized validation and fix if needed
    if ! validate_directory_permissions "$CRON_LOG_DIR" "750" "root" "root"; then
        if ! chown root:root "$CRON_LOG_DIR" || ! chmod 750 "$CRON_LOG_DIR"; then
            log_error "Failed to secure cron log directory"
            return 1
        fi
    fi

    # Create individual log files with proper permissions using centralized function
    local log_files=(
        "maintenance.log"
        "backup.log"
        "health.log"
        "firewall.log"
    )

    for log_file in "${log_files[@]}"; do
        local full_path="$CRON_LOG_DIR/$log_file"
        if [[ ! -f "$full_path" ]]; then
            # Use centralized secure file creation
            if ! create_secure_file "$full_path" "" "640" "root" "root"; then
                log_error "Failed to create secure log file: $log_file"
                return 1
            fi
        else
            # Validate existing log file permissions
            if ! validate_file_permissions "$full_path" "640" "root" "root"; then
                log_warn "Correcting permissions for existing log file: $log_file"
                if ! chown root:root "$full_path" || ! chmod 640 "$full_path"; then
                    log_error "Failed to secure existing log file: $log_file"
                    return 1
                fi
            fi
        fi
    done

    log_success "Cron logging setup completed"
    return 0
}

# ENHANCED: Install secure cron jobs with centralized validation
install_cron_jobs() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install secure VaultWarden cron jobs"
        return 0
    fi

    log_info "Installing secure VaultWarden cron jobs..."

    # Validate we're running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "Cron installation must be run as root"
        return 1
    fi

    # Setup secure logging
    if ! setup_cron_logging; then
        log_error "Failed to setup cron logging"
        return 1
    fi

    # Define scripts to install with validation
    local scripts_to_install=(
        "maintenance.sh:Database and system maintenance"
        "backup.sh:Automated backup creation"
        "health.sh:System health monitoring"
        "update-dns.sh:Cloudflare DNS updates"
    )

    local secure_scripts=()
    local validation_failed=false

    # Validate and create secure copies of all scripts first
    for script_info in "${scripts_to_install[@]}"; do
        local script_name="${script_info%%:*}"
        local script_path="$PROJECT_ROOT/$script_name"

        log_info "Validating script for cron installation: $script_name"

        # Validate script security using centralized function
        if ! validate_script_security "$script_path"; then
            log_error "Security validation failed for: $script_name"
            validation_failed=true
            continue
        fi

        # Create secure copy
        local secure_copy
        if secure_copy=$(create_secure_script_copy "$script_path"); then
            secure_scripts+=("$secure_copy")
        else
            log_error "Failed to create secure copy of: $script_name"
            validation_failed=true
        fi
    done

    if [[ "$validation_failed" == "true" ]]; then
        log_error "Script validation failures prevent cron installation"
        return 1
    fi

    # Create cron jobs with secure script paths
    log_info "Creating cron job entries..."

    local cron_jobs=(
        # Daily maintenance at 2 AM
        "0 2 * * * cd $PROJECT_ROOT && $CRON_SCRIPTS_DIR/maintenance.sh --comprehensive >> $CRON_LOG_DIR/maintenance.log 2>&1"

        # Daily database backup with fast verification
        "0 3 * * * cd $PROJECT_ROOT && $CRON_SCRIPTS_DIR/backup.sh --type db --rclone --email >> $CRON_LOG_DIR/backup.log 2>&1"

        # Health check every 30 minutes
        "*/30 * * * * cd $PROJECT_ROOT && $CRON_SCRIPTS_DIR/health.sh --quiet >> $CRON_LOG_DIR/health.log 2>&1"

        # Weekly firewall update (Sunday at 4 AM)
        "0 4 * * 0 cd $PROJECT_ROOT && $CRON_SCRIPTS_DIR/maintenance.sh --update-firewall >> $CRON_LOG_DIR/firewall.log 2>&1"

        # Weekly full backup with comprehensive verification (Sundays at 5 AM)
        "0 5 * * 0 cd $PROJECT_ROOT && $CRON_SCRIPTS_DIR/backup.sh --type full --full-verification --rclone --email >> $CRON_LOG_DIR/backup.log 2>&1"
    )

    # Install cron jobs securely
    local temp_cron="/tmp/vaultwarden_cron.$$"

    # Get existing crontab (if any) but exclude our jobs
    crontab -l 2>/dev/null | grep -v "vaultwarden\|VaultWarden" > "$temp_cron" || true

    # Add our jobs with identifying comments
    echo "# VaultWarden-OCI Automated Jobs - Managed by cron-setup.sh" >> "$temp_cron"
    for job in "${cron_jobs[@]}"; do
        echo "$job" >> "$temp_cron"
    done
    echo "# End VaultWarden-OCI Jobs" >> "$temp_cron"

    # Secure the temporary cron file before installation
    if ! chmod 600 "$temp_cron"; then
        log_error "Failed to secure temporary cron file"
        rm -f "$temp_cron"
        return 1
    fi

    # Install the crontab
    if crontab "$temp_cron"; then
        log_success "Cron jobs installed successfully"
    else
        log_error "Failed to install cron jobs"
        # Secure cleanup of temp file
        secure_cleanup "$temp_cron"
        return 1
    fi

    # Secure cleanup of temp file
    secure_cleanup "$temp_cron"

    # Verify cron service is running
    if ! systemctl is-active --quiet cron 2>/dev/null; then
        log_warn "Cron service is not running - attempting to start..."
        if systemctl start cron 2>/dev/null; then
            log_success "Cron service started"
        else
            log_error "Failed to start cron service"
            return 1
        fi
    fi

    log_success "Secure cron jobs installation completed"
    log_info "Installed cron jobs:"
    log_info "  Daily (2 AM): Comprehensive maintenance"
    log_info "  Daily (3 AM): Database backup with fast verification"
    log_info "  Weekly (Sun 4 AM): Firewall update"
    log_info "  Weekly (Sun 5 AM): Full backup with comprehensive verification"
    log_info "  Every 30 min: Health check"
    return 0
}

# STANDARDIZED: Remove cron jobs with secure cleanup
remove_cron_jobs() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would remove VaultWarden cron jobs"
        return 0
    fi

    log_info "Removing VaultWarden cron jobs..."

    # Get current crontab and remove our jobs
    local temp_cron="/tmp/vaultwarden_cron_remove.$$"

    if crontab -l 2>/dev/null | grep -v -E "(vaultwarden|VaultWarden|$CRON_SCRIPTS_DIR)" > "$temp_cron"; then
        # Secure the temporary file
        chmod 600 "$temp_cron"

        if crontab "$temp_cron"; then
            log_success "VaultWarden cron jobs removed"
        else
            log_error "Failed to update crontab"
            secure_cleanup "$temp_cron"
            return 1
        fi
    else
        # No crontab or no jobs to remove
        log_info "No VaultWarden cron jobs found to remove"
    fi

    # Secure cleanup of temp file
    secure_cleanup "$temp_cron"

    # Clean up secure scripts directory
    if [[ -d "$CRON_SCRIPTS_DIR" ]]; then
        log_info "Removing secure scripts directory..."
        if secure_cleanup "$CRON_SCRIPTS_DIR"; then
            log_success "Secure scripts directory removed"
        else
            log_warn "Failed to securely remove scripts directory"
        fi
    fi

    return 0
}

# STANDARDIZED: List current cron jobs
list_cron_jobs() {
    log_info "Current VaultWarden cron jobs:"

    local cron_output
    if cron_output=$(crontab -l 2>/dev/null); then
        local vw_jobs
        if vw_jobs=$(echo "$cron_output" | grep -E "(vaultwarden|VaultWarden|$CRON_SCRIPTS_DIR)"); then
            echo "$vw_jobs"
            echo ""
            log_info "Found $(echo "$vw_jobs" | wc -l) VaultWarden cron jobs"
        else
            log_info "No VaultWarden cron jobs found"
        fi
    else
        log_info "No crontab found for current user"
    fi

    # Check secure scripts directory using centralized validation
    if [[ -d "$CRON_SCRIPTS_DIR" ]]; then
        log_info "Secure scripts directory exists: $CRON_SCRIPTS_DIR"

        # Validate directory permissions
        if validate_directory_permissions "$CRON_SCRIPTS_DIR" "750" "root" "root"; then
            log_success "Scripts directory permissions are secure"
        else
            log_warn "Scripts directory has incorrect permissions"
        fi

        local script_count
        script_count=$(find "$CRON_SCRIPTS_DIR" -name "*.sh" -type f | wc -l)
        log_info "Contains $script_count script files"

        # Validate each script's permissions
        while IFS= read -r -d '' script_file; do
            if validate_file_permissions "$script_file" "700" "root" "root"; then
                log_debug "Script permissions OK: $(basename "$script_file")"
            else
                log_warn "Script permissions incorrect: $(basename "$script_file")"
            fi
        done < <(find "$CRON_SCRIPTS_DIR" -name "*.sh" -type f -print0)

    else
        log_info "Secure scripts directory does not exist: $CRON_SCRIPTS_DIR"
    fi

    return 0
}

# ENHANCED: Validate existing cron setup security using centralized functions
validate_cron_security() {
    log_info "Validating VaultWarden cron job security using centralized functions..."

    local validation_passed=true

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "Cron validation should be run as root for complete security check"
        validation_passed=false
    fi

    # Check cron service status
    if ! systemctl is-active --quiet cron 2>/dev/null; then
        log_error "Cron service is not running"
        validation_passed=false
    fi

    # Validate secure scripts directory using centralized functions
    if [[ -d "$CRON_SCRIPTS_DIR" ]]; then
        log_info "Validating secure scripts directory..."

        if validate_directory_permissions "$CRON_SCRIPTS_DIR" "750" "root" "root"; then
            log_success "Scripts directory permissions validated"
        else
            log_error "Scripts directory has incorrect permissions"
            validation_passed=false
        fi

        # Validate each script in the directory using centralized validation
        while IFS= read -r -d '' script_file; do
            if ! validate_file_permissions "$script_file" "700" "root" "root"; then
                validation_passed=false
            fi
        done < <(find "$CRON_SCRIPTS_DIR" -name "*.sh" -type f -print0)

    else
        log_warn "Secure scripts directory not found: $CRON_SCRIPTS_DIR"
    fi

    # Check cron log directory using centralized validation
    if [[ -d "$CRON_LOG_DIR" ]]; then
        if validate_directory_permissions "$CRON_LOG_DIR" "750" "root" "root"; then
            log_success "Cron log directory permissions validated"
        else
            log_warn "Cron log directory has incorrect permissions"
        fi
    fi

    if [[ "$validation_passed" == "true" ]]; then
        log_success "Cron job security validation passed"
        return 0
    else
        log_error "Cron job security validation failed"
        return 1
    fi
}

# ENHANCED: Main function with proper error handling
main() {
    log_header "VaultWarden-OCI Secure Cron Management (Centralized Security)"

    # Validate running as root for installation/removal
    if [[ "$INSTALL_CRON" == "true" ]] || [[ "$REMOVE_CRON" == "true" ]]; then
        if [[ $EUID -ne 0 ]]; then
            log_error "Cron installation/removal must be run as root"
            log_info "Use: sudo $0 $*"
            exit 1
        fi
    fi

    # Handle different operations
    local exit_code=0

    if [[ "$LIST_CRON" == "true" ]]; then
        if ! list_cron_jobs; then
            exit_code=1
        fi
    fi

    if [[ "$VALIDATE_ONLY" == "true" ]]; then
        if ! validate_cron_security; then
            exit_code=1
        fi
    fi

    if [[ "$REMOVE_CRON" == "true" ]]; then
        if ! remove_cron_jobs; then
            exit_code=1
        fi
    fi

    if [[ "$INSTALL_CRON" == "true" ]]; then
        if ! install_cron_jobs; then
            exit_code=1
        fi

        # Automatically validate after installation
        log_info "Validating installation security..."
        if ! validate_cron_security; then
            log_warn "Installation completed but security validation failed"
            exit_code=2
        fi
    fi

    # Default action if no specific operation requested
    if [[ "$LIST_CRON" != "true" ]] && [[ "$VALIDATE_ONLY" != "true" ]] &&        [[ "$REMOVE_CRON" != "true" ]] && [[ "$INSTALL_CRON" != "true" ]]; then
        log_info "No operation specified. Use --help for options."
        show_help
        exit 1
    fi

    if [[ $exit_code -eq 0 ]]; then
        log_success "Cron management operation completed successfully"
    elif [[ $exit_code -eq 2 ]]; then
        log_warn "Operation completed with warnings"
    else
        log_error "Cron management operation failed"
    fi

    exit $exit_code
}

main "$@"
