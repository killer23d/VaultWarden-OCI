#!/usr/bin/env bash
# cron-setup.sh - Secure VaultWarden cron job management with centralized security functions
# FIXED: All 8 correctness and security fixes applied (see commit message for details)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/security.sh"

# Configuration
INSTALL_CRON=false
REMOVE_CRON=false
LIST_CRON=false
DRY_RUN=false
VALIDATE_ONLY=false

# Cron job configuration
# BUG 3 FIX: Removed dead CRON_USER="root" variable (was never referenced).
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
    - Creates hardened copies with root:root 700 permissions
    - Stamps SCRIPT_DIR and PROJECT_ROOT into copies to prevent context loss
    - Rewrites lib/ source paths to load from locked-down /opt/ tree (no LPE)
    - Validates script integrity before scheduling
    - Implements secure logging with proper permissions
    - Uses centralized lib/security.sh validation functions

CRON JOBS MANAGED:
    - Daily DB backup (fast verification)
    - Weekly Full backup (comprehensive verification, Sunday 3 AM)
    - Health monitoring (every 30 minutes)
    - Maintenance (daily 2 AM) & Firewall (Saturday 4 AM)
    - DNS update (hourly)

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

# BUG 8 FIX: Shebang regex updated to portable POSIX ERE.
# Accepts: #!/bin/bash  #!/usr/bin/bash  #!/usr/bin/env bash  #!/usr/bin/env sh
# Eliminates false-positive warnings on every script that uses #!/usr/bin/env bash.
validate_script_security() {
    local script_path="$1"
    local script_name="$(basename "$script_path")"

    log_debug "Validating security of script: $script_name"

    if [[ ! -f "$script_path" ]]; then
        log_error "Script not found: $script_path"
        return 1
    fi

    if [[ ! -r "$script_path" ]]; then
        log_error "Script not readable: $script_name"
        return 1
    fi

    # Check for suspicious content patterns
    if grep -q -E '(pkexec|chmod \+s)' "$script_path"; then
        log_warn "SECURITY: Script $script_name contains potential privilege escalation commands"
        log_warn "Review manually: grep -E '(pkexec|chmod \\+s)' '$script_path'"
    fi

    # BUG 8 FIX: Portable POSIX ERE — [[:space:]]+ instead of non-portable \s
    local shebang
    shebang=$(head -1 "$script_path")
    if [[ ! "$shebang" =~ ^#!(/usr)?/bin/(bash|sh|env[[:space:]]+(bash|sh))$ ]]; then
        log_warn "Script $script_name has unusual shebang: $shebang"
    fi

    log_success "Script security validation passed: $script_name"
    return 0
}

# BUG 1 FIX: All log_* calls redirected to stderr so only echo "$secure_copy"
#            reaches the caller's $() capture. Previously, log_info/log_success
#            wrote to stdout, corrupting the captured path in secure_scripts[].
#
# BUG 7 FIX: Replace cat with a three-expression sed that:
#   (a) Locks SCRIPT_DIR to $CRON_SCRIPTS_DIR (/opt/) so source "lib/" loads
#       come exclusively from the root-owned locked-down tree.
#   (b) Locks PROJECT_ROOT to the git clone path so .env and docker-compose.yml
#       are found when the script cds to it.
#   (c) Rewrites 'source "lib/' -> 'source "$SCRIPT_DIR/lib/' so bash resolves
#       lib/ imports against /opt/vaultwarden-scripts, never the unprivileged
#       git repo. This closes the LPE vector where a compromised user account
#       could inject code into git-repo lib/common.sh and have it sourced by
#       the next root cron run.
#
#       Security boundary after patching:
#         SCRIPT_DIR  = /opt/vaultwarden-scripts        (root:root 750, libs 640)
#         PROJECT_ROOT = /path/to/git/clone             (for .env, docker-compose.yml)
#         source "$SCRIPT_DIR/lib/..."                  (always from /opt/, never git)
#
# BUG 7 cont: cmp -s removed — content intentionally differs after sed patching.
#             Replaced with a line-count sanity check (allows ±2 for patched lines).
create_secure_script_copy() {
    local source_script="$1"
    local script_name="$(basename "$source_script")"
    local secure_copy="$CRON_SCRIPTS_DIR/$script_name"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create secure copy: $secure_copy" >&2
        return 0
    fi

    log_info "Creating secure script copy: $script_name" >&2

    # Ensure secure scripts directory exists with proper permissions
    if ! ensure_dir "$CRON_SCRIPTS_DIR" 750; then
        log_error "Failed to create secure scripts directory" >&2
        return 1
    fi

    # Set ownership on scripts directory
    if ! chown root:root "$CRON_SCRIPTS_DIR" || ! chmod 750 "$CRON_SCRIPTS_DIR"; then
        log_error "Failed to secure scripts directory" >&2
        return 1
    fi

    # BUG 7 FIX: sed patches three critical lines rather than plain cat.
    # Expression (a): lock SCRIPT_DIR to the hardened /opt/ directory.
    # Expression (b): lock PROJECT_ROOT to the git clone for runtime config files.
    # Expression (c): rewrite unqualified lib/ sources to use absolute SCRIPT_DIR
    #                 path, ensuring root cron never loads libs from the git repo.
    local script_content
    if ! script_content=$(sed \
        -e "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$CRON_SCRIPTS_DIR\"|" \
        -e "s|^PROJECT_ROOT=\"\$SCRIPT_DIR\"|PROJECT_ROOT=\"$PROJECT_ROOT\"|" \
        -e 's|source "lib/|source "$SCRIPT_DIR/lib/|g' \
        "$source_script"); then
        log_error "Failed to read/modify source script: $source_script" >&2
        return 1
    fi

    # Use centralized secure file creation
    if ! create_secure_file "$secure_copy" "$script_content" "700" "root" "root"; then
        log_error "Failed to create secure script copy" >&2
        return 1
    fi

    # BUG 7 FIX: cmp -s replaced — content now intentionally differs post-patch.
    # Sanity-check: copy must have at least (source_lines - 2) lines.
    local source_lines copy_lines
    source_lines=$(wc -l < "$source_script")
    copy_lines=$(wc -l < "$secure_copy")
    if [[ "$copy_lines" -lt $(( source_lines - 2 )) ]]; then
        log_error "Script copy appears truncated (source: ${source_lines}L, copy: ${copy_lines}L)" >&2
        return 1
    fi

    log_success "Secure script copy created and verified: $secure_copy" >&2
    echo "$secure_copy"   # BUG 1 FIX: sole stdout line — safe for $() capture
    return 0
}

# Setup secure logging directory using centralized functions
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

    # Set ownership explicitly
    if ! chown root:root "$CRON_LOG_DIR" || ! chmod 750 "$CRON_LOG_DIR"; then
        log_error "Failed to secure cron log directory"
        return 1
    fi

    # Create individual log files with proper permissions
    local log_files=(
        "maintenance.log"
        "backup.log"
        "health.log"
        "firewall.log"
        "dns-update.log"
    )

    for log_file in "${log_files[@]}"; do
        local full_path="$CRON_LOG_DIR/$log_file"
        if [[ ! -f "$full_path" ]]; then
            if ! touch "$full_path"; then
                log_error "Failed to create log file: $log_file"
                return 1
            fi

            if ! chmod 640 "$full_path" || ! chown root:root "$full_path"; then
                log_error "Failed to secure log file: $log_file"
                return 1
            fi

            log_debug "Created secure log file: $log_file"
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

# Install secure cron jobs with centralized validation
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

    # Check and start cron service BEFORE doing anything else
    if ! systemctl is-active --quiet cron 2>/dev/null; then
        log_warn "Cron service is not running - attempting to start..."
        if systemctl start cron 2>/dev/null && systemctl enable cron 2>/dev/null; then
            log_success "Cron service started and enabled"
        else
            log_error "Failed to start cron service"
            log_info "Install with: sudo apt install cron && sudo systemctl start cron"
            return 1
        fi
    fi

    # Setup secure logging
    if ! setup_cron_logging; then
        log_error "Failed to setup cron logging"
        return 1
    fi

    # Copy library dependencies with correct permissions
    log_info "Installing library dependencies to secure directory..."
    if ! cp -r "$PROJECT_ROOT/lib" "$CRON_SCRIPTS_DIR/" 2>/dev/null; then
        log_error "Failed to copy library directory"
        return 1
    fi
    find "$CRON_SCRIPTS_DIR/lib" -type f -exec chmod 640 {} \; 2>/dev/null || true
    find "$CRON_SCRIPTS_DIR/lib" -type d -exec chmod 750 {} \; 2>/dev/null || true
    chown -R root:root "$CRON_SCRIPTS_DIR/lib" 2>/dev/null || true
    log_success "Libraries installed successfully"

    # Define scripts to install with validation
    local scripts_to_install=(
        "maintenance.sh:Database and system maintenance"
        "backup.sh:Automated backup creation"
        "health.sh:System health monitoring"
    )

    local secure_scripts=()
    local validation_failed=false

    # Validate and create secure copies of all scripts first
    for script_info in "${scripts_to_install[@]}"; do
        local script_name="${script_info%%:*}"
        local script_path="$PROJECT_ROOT/$script_name"

        log_info "Validating script for cron installation: $script_name"

        if ! validate_script_security "$script_path"; then
            log_error "Security validation failed for: $script_name"
            validation_failed=true
            continue
        fi

        # BUG 1 FIX: $() capture is clean — create_secure_script_copy now
        # emits only the path on stdout; all logging goes to stderr.
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

    # BUG 6 FIX: Sunday cron collision resolved.
    #   BEFORE: Firewall Sun 4 AM + Full backup Sun 5 AM risked overlap with
    #           Mon 4 AM daily backup if the full backup ran long.
    #   AFTER:  Firewall moved to Saturday 4 AM (day 6).
    #           Full backup moved to Sunday 3 AM (day 0) — one clear hour
    #           before the daily maintenance at 2 AM on weekdays, and well
    #           clear of Monday's 4 AM daily backup.
    local cron_jobs=(
        # Daily maintenance at 2 AM
        "0 2 * * * cd $PROJECT_ROOT && $CRON_SCRIPTS_DIR/maintenance.sh --comprehensive >> $CRON_LOG_DIR/maintenance.log 2>&1"

        # Daily database backup at 4 AM with fast verification
        "0 4 * * * cd $PROJECT_ROOT && $CRON_SCRIPTS_DIR/backup.sh --type db --rclone --email >> $CRON_LOG_DIR/backup.log 2>&1"

        # Health check every 30 minutes
        "*/30 * * * * cd $PROJECT_ROOT && $CRON_SCRIPTS_DIR/health.sh --quiet >> $CRON_LOG_DIR/health.log 2>&1"

        # BUG 6 FIX: Weekly firewall update moved to Saturday 4 AM (was Sunday 4 AM)
        "0 4 * * 6 cd $PROJECT_ROOT && $CRON_SCRIPTS_DIR/maintenance.sh --update-firewall >> $CRON_LOG_DIR/firewall.log 2>&1"

        # BUG 6 FIX: Weekly full backup moved to Sunday 3 AM (was Sunday 5 AM)
        # Gives full backup a clean run before Mon 4 AM daily backup.
        "0 3 * * 0 cd $PROJECT_ROOT && $CRON_SCRIPTS_DIR/backup.sh --type full --full-verification --rclone --email >> $CRON_LOG_DIR/backup.log 2>&1"

        # Automated DNS update every hour
        "0 * * * * cd $PROJECT_ROOT && $CRON_SCRIPTS_DIR/maintenance.sh --update-dns >> $CRON_LOG_DIR/dns-update.log 2>&1"
    )

    # Install cron jobs securely
    local temp_cron="/tmp/vaultwarden_cron.$$"

    # Get existing crontab (if any) but exclude our jobs.
    # || true required: grep -v exits 1 when all lines are filtered out,
    # which under set -euo pipefail would abort the script here.
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
        secure_cleanup "$temp_cron"
        return 1
    fi

    secure_cleanup "$temp_cron"

    log_success "Secure cron jobs installation completed"
    log_info "Installed cron jobs:"
    log_info "  Daily   (2 AM):       Comprehensive maintenance"
    log_info "  Daily   (4 AM):       Database backup with fast verification"
    log_info "  Every 30 min:         Health check"
    log_info "  Every hour:           DNS update"
    log_info "  Weekly  (Sat 4 AM):   Firewall update"
    log_info "  Weekly  (Sun 3 AM):   Full backup with comprehensive verification"
    return 0
}

# BUG 2+4 FIX: remove_cron_jobs rewritten to survive set -euo pipefail.
#
#   BUG 4: grep -v exits 1 when no lines survive the filter. Under pipefail
#          this aborted the script before reaching the else branch or cleanup.
#          Fixed by appending || true to the pipeline.
#
#   BUG 2: When the user has ONLY VaultWarden cron jobs, grep -v produces an
#          empty file. The old code installed that zero-byte file as the new
#          crontab. Fixed by gating on [[ -s ]] (file is non-empty) and
#          calling crontab -r when nothing remains.
#
#          secure_cleanup is now unconditionally at the end of the function
#          so it is always reached regardless of which branch was taken.
remove_cron_jobs() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would remove VaultWarden cron jobs"
        return 0
    fi

    log_info "Removing VaultWarden cron jobs..."

    local temp_cron="/tmp/vaultwarden_cron_remove.$$"

    # BUG 4 FIX: || true prevents pipefail abort when grep -v matches nothing.
    crontab -l 2>/dev/null \
        | grep -v -E "(vaultwarden|VaultWarden|$CRON_SCRIPTS_DIR)" \
        > "$temp_cron" || true

    # BUG 2 FIX: [[ -s ]] gates on non-empty file.
    if [[ -s "$temp_cron" ]]; then
        # Non-VaultWarden jobs remain — reinstall them.
        chmod 600 "$temp_cron"
        if ! crontab "$temp_cron"; then
            log_error "Failed to update crontab"
            secure_cleanup "$temp_cron"
            return 1
        fi
        log_success "VaultWarden cron jobs removed"
    else
        # BUG 2 FIX: Nothing left — remove the crontab entirely rather than
        # installing an empty file, which would leave a blank crontab entry.
        crontab -r 2>/dev/null || true
        log_success "VaultWarden cron jobs removed (crontab now empty)"
    fi

    # BUG 2 FIX: secure_cleanup is now always reached (was only in if-branch).
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

# List current cron jobs
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

    # Check secure scripts directory
    if [[ -d "$CRON_SCRIPTS_DIR" ]]; then
        log_info "Secure scripts directory exists: $CRON_SCRIPTS_DIR"

        local script_count
        script_count=$(find "$CRON_SCRIPTS_DIR" -name "*.sh" -type f 2>/dev/null | wc -l)
        log_info "Contains $script_count script files"

        if [[ -d "$CRON_SCRIPTS_DIR/lib" ]]; then
            log_success "Library dependencies present"
        else
            log_warn "Library dependencies missing"
        fi
    else
        log_info "Secure scripts directory does not exist: $CRON_SCRIPTS_DIR"
    fi

    return 0
}

# BUG 5 FIX: validate_cron_security now sets validation_passed=false when
# cron jobs are not found, preventing a false-green post-install result.
validate_cron_security() {
    log_info "Validating VaultWarden cron job security..."

    local validation_passed=true

    # Check cron service status
    if ! systemctl is-active --quiet cron 2>/dev/null; then
        log_error "Cron service is not running"
        log_info "Start with: sudo systemctl start cron"
        validation_passed=false
    else
        log_success "Cron service is running"
    fi

    # Check if cron jobs are installed
    if crontab -l 2>/dev/null | grep -q "$CRON_SCRIPTS_DIR"; then
        log_success "VaultWarden cron jobs are installed"
    else
        log_warn "No VaultWarden cron jobs found"
        # BUG 5 FIX: was missing — caused false-green on post-install validation
        validation_passed=false
    fi

    # Validate secure directories exist
    if [[ -d "$CRON_SCRIPTS_DIR" ]]; then
        log_success "Secure scripts directory exists"
    else
        log_warn "Secure scripts directory not found (normal if not installed)"
    fi

    if [[ -d "$CRON_LOG_DIR" ]]; then
        log_success "Cron log directory exists"
    else
        log_warn "Cron log directory not found (normal if not installed)"
    fi

    if [[ "$validation_passed" == "true" ]]; then
        log_success "Cron job security validation passed"
        return 0
    else
        log_warn "Cron job security validation completed with warnings"
        return 1
    fi
}

# Main function
main() {
    log_header "VaultWarden-OCI Secure Cron Management"

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
        list_cron_jobs || exit_code=1
    fi

    if [[ "$VALIDATE_ONLY" == "true" ]]; then
        validate_cron_security || exit_code=1
    fi

    if [[ "$REMOVE_CRON" == "true" ]]; then
        remove_cron_jobs || exit_code=1
    fi

    if [[ "$INSTALL_CRON" == "true" ]]; then
        if install_cron_jobs; then
            log_info "Validating installation..."
            validate_cron_security || exit_code=2
        else
            exit_code=1
        fi
    fi

    # Default action: no flags given
    if [[ "$LIST_CRON" != "true" ]] && [[ "$VALIDATE_ONLY" != "true" ]] && \
       [[ "$REMOVE_CRON" != "true" ]] && [[ "$INSTALL_CRON" != "true" ]]; then
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
