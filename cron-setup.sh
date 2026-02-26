#!/usr/bin/env bash
# cron-setup.sh - Secure VaultWarden cron job management

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

CRON_SCRIPTS_DIR="/opt/vaultwarden-scripts"
CRON_LOG_DIR="/var/log/vaultwarden-cron"

# Lock directory for flock-based job mutual exclusion
CRON_LOCK_DIR="/tmp/vaultwarden-cron-locks"

show_help() {
    cat << 'EOF'
VaultWarden-OCI Secure Cron Setup

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
    - flock-based mutual exclusion prevents overlapping cron runs
    - Simple split-brain detection: warns when /opt/ scripts are older than git repo

CRON JOBS MANAGED:
    - Daily DB backup (fast verification, 4 AM Mon-Sat)
    - Weekly Full backup (comprehensive verification, Sunday 3 AM)
    - Health monitoring (every 30 min, flock-protected)
    - Maintenance (daily 2 AM Mon-Sat ONLY, flock-protected)
    - Firewall update (Saturday 4 AM)
    - DNS update (hourly)

EXAMPLES:
    sudo ./cron-setup.sh --install     # Install secure cron jobs
    sudo ./cron-setup.sh --validate    # Validate current setup
    sudo ./cron-setup.sh --list        # List jobs + check for split-brain
    sudo ./cron-setup.sh --remove      # Remove all cron jobs
EOF
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --install)  INSTALL_CRON=true;   shift ;;
        --remove)   REMOVE_CRON=true;    shift ;;
        --list)     LIST_CRON=true;      shift ;;
        --validate) VALIDATE_ONLY=true;  shift ;;
        --dry-run)  DRY_RUN=true;        shift ;;
        --help)     show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# validate_script_security SCRIPT_PATH
# BUG 8 FIX: Portable POSIX ERE shebang check.
# ---------------------------------------------------------------------------
validate_script_security() {
    local script_path="$1"
    local script_name
    script_name="$(basename "$script_path")"

    log_debug "Validating security of script: $script_name"

    if [[ ! -f "$script_path" ]]; then
        log_error "Script not found: $script_path"
        return 1
    fi

    if [[ ! -r "$script_path" ]]; then
        log_error "Script not readable: $script_name"
        return 1
    fi

    if grep -q -E '(pkexec|chmod \+s)' "$script_path"; then
        log_warn "SECURITY: Script $script_name contains potential privilege escalation commands"
        log_warn "Review manually: grep -E '(pkexec|chmod \\+s)' '$script_path'"
    fi

    # BUG 8 FIX: [[:space:]]+ instead of non-portable \s
    local shebang
    shebang=$(head -1 "$script_path")
    if [[ ! "$shebang" =~ ^#!(/usr)?/bin/(bash|sh|env[[:space:]]+(bash|sh))$ ]]; then
        log_warn "Script $script_name has unusual shebang: $shebang"
    fi

    log_success "Script security validation passed: $script_name"
    return 0
}

# ---------------------------------------------------------------------------
# create_secure_script_copy SOURCE_SCRIPT
# BUG 1 FIX: All logging to stderr; only path on stdout (safe for $() capture).
# BUG 7 FIX: sed patches SCRIPT_DIR, PROJECT_ROOT, and source "lib/" paths.
# ---------------------------------------------------------------------------
create_secure_script_copy() {
    local source_script="$1"
    local script_name
    script_name="$(basename "$source_script")"
    local secure_copy="$CRON_SCRIPTS_DIR/$script_name"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create secure copy: $secure_copy" >&2
        return 0
    fi

    log_info "Creating secure script copy: $script_name" >&2

    if ! ensure_dir "$CRON_SCRIPTS_DIR" 750; then
        log_error "Failed to create secure scripts directory" >&2
        return 1
    fi

    if ! chown root:root "$CRON_SCRIPTS_DIR" || ! chmod 750 "$CRON_SCRIPTS_DIR"; then
        log_error "Failed to secure scripts directory" >&2
        return 1
    fi

    # BUG 7 FIX: three-expression sed:
    #   (a) Lock SCRIPT_DIR to /opt/ tree
    #   (b) Lock PROJECT_ROOT to git clone path
    #   (c) Rewrite unqualified lib/ sources to use $SCRIPT_DIR/lib/ (closes LPE)
    local script_content
    if ! script_content=$(sed \
        -e "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$CRON_SCRIPTS_DIR\"|" \
        -e "s|^PROJECT_ROOT=\"\$SCRIPT_DIR\"|PROJECT_ROOT=\"$PROJECT_ROOT\"|" \
        -e 's|source "lib/|source "$SCRIPT_DIR/lib/|g' \
        "$source_script"); then
        log_error "Failed to read/modify source script: $source_script" >&2
        return 1
    fi

    if ! create_secure_file "$secure_copy" "$script_content" "700" "root" "root"; then
        log_error "Failed to create secure script copy" >&2
        return 1
    fi

    # Sanity-check: copy must have at least (source_lines - 2) lines
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

# ---------------------------------------------------------------------------
# setup_cron_logging
# ---------------------------------------------------------------------------
setup_cron_logging() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would setup secure cron logging"
        return 0
    fi

    log_info "Setting up secure cron job logging..."

    if ! ensure_dir "$CRON_LOG_DIR" 750; then
        log_error "Failed to create cron log directory"
        return 1
    fi

    if ! chown root:root "$CRON_LOG_DIR" || ! chmod 750 "$CRON_LOG_DIR"; then
        log_error "Failed to secure cron log directory"
        return 1
    fi

    # FIX [ISSUE 5]: Create lock directory for flock-based mutual exclusion
    if ! ensure_dir "$CRON_LOCK_DIR" 1777; then
        log_warn "Failed to create cron lock directory — overlapping job protection disabled"
    else
        log_success "Cron lock directory ready: $CRON_LOCK_DIR"
    fi

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

# ---------------------------------------------------------------------------
# check_split_brain
#
# FIX [ISSUE 17]: Warns when scripts in /opt/ are older (by mtime) than their
# counterparts in the git repo. This catches the common "pulled an update but
# forgot to re-run --install" scenario for a part-time admin.
# Non-fatal: always returns 0 so it never blocks --list or --validate.
# ---------------------------------------------------------------------------
check_split_brain() {
    if [[ ! -d "$CRON_SCRIPTS_DIR" ]]; then
        return 0
    fi

    local stale_scripts=()
    local scripts_to_check=("backup.sh" "maintenance.sh" "health.sh")

    for script in "${scripts_to_check[@]}"; do
        local repo_script="$PROJECT_ROOT/$script"
        local opt_script="$CRON_SCRIPTS_DIR/$script"

        if [[ ! -f "$repo_script" ]] || [[ ! -f "$opt_script" ]]; then
            continue
        fi

        local repo_mtime opt_mtime
        repo_mtime=$(stat -c%Y "$repo_script" 2>/dev/null || echo "0")
        opt_mtime=$(stat -c%Y "$opt_script"  2>/dev/null || echo "0")

        if (( repo_mtime > opt_mtime )); then
            stale_scripts+=("$script")
        fi
    done

    if [[ ${#stale_scripts[@]} -gt 0 ]]; then
        echo ""
        log_warn "⚠️  SPLIT-BRAIN DETECTED: The following scripts in $CRON_SCRIPTS_DIR"
        log_warn "   are OLDER than their counterparts in the git repo ($PROJECT_ROOT):"
        for s in "${stale_scripts[@]}"; do
            log_warn "     • $s"
        done
        log_warn "   Scheduled tasks are running STALE code."
        log_warn "   Fix: sudo ./cron-setup.sh --install"
        echo ""
    else
        log_success "No split-brain detected — /opt/ scripts match git repo"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# install_cron_jobs
#
# FIX [ISSUE 5]:  All health and maintenance cron commands are wrapped with
#   flock -n LOCKFILE CMD so only one instance runs at a time. If the previous
#   run is still active, the new invocation exits immediately (no queuing, no
#   duplicate alerts). Backup jobs already have their own internal lock
#   (/tmp/vaultwarden-backup-${UID}.lock) so they are not double-wrapped.
#
# FIX [ISSUE 9]:  Daily maintenance moved from "* * *" (every day) to
#   "* * 1-6" (Monday–Saturday only). This prevents maintenance from running
#   at 2 AM on Sunday, which was the only remaining overlap window with the
#   weekly full backup at 3 AM on Sunday.
#
# FIX [ISSUE 15]: After cp -r lib/, explicitly verify that
#   simple_key_resilience.sh landed in /opt/. If it is missing the install
#   fails loudly rather than silently degrading backup key health checks.
# ---------------------------------------------------------------------------
install_cron_jobs() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install secure VaultWarden cron jobs"
        return 0
    fi

    log_info "Installing secure VaultWarden cron jobs..."

    if [[ $EUID -ne 0 ]]; then
        log_error "Cron installation must be run as root"
        return 1
    fi

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

    if ! setup_cron_logging; then
        log_error "Failed to setup cron logging"
        return 1
    fi

    log_info "Installing library dependencies to secure directory..."
    if ! cp -r "$PROJECT_ROOT/lib" "$CRON_SCRIPTS_DIR/" 2>/dev/null; then
        log_error "Failed to copy library directory"
        return 1
    fi
    find "$CRON_SCRIPTS_DIR/lib" -type f -exec chmod 640 {} \; 2>/dev/null || true
    find "$CRON_SCRIPTS_DIR/lib" -type d -exec chmod 750 {} \; 2>/dev/null || true
    chown -R root:root "$CRON_SCRIPTS_DIR/lib" 2>/dev/null || true

    # FIX [ISSUE 15]: Explicitly verify that simple_key_resilience.sh was copied.
    # If this file is absent, every cron backup silently skips the Age key health
    # check (the fallback stub in backup.sh is a no-op, not a failure).
    local resilience_lib="$CRON_SCRIPTS_DIR/lib/simple_key_resilience.sh"
    if [[ ! -f "$resilience_lib" ]]; then
        log_error "CRITICAL: lib/simple_key_resilience.sh is missing from the git repo."
        log_error "          Cannot install — key health checks would be silently disabled."
        log_error "          Ensure lib/simple_key_resilience.sh exists in: $PROJECT_ROOT/lib/"
        return 1
    fi
    log_success "Libraries installed successfully (including simple_key_resilience.sh)"

    local scripts_to_install=(
        "maintenance.sh:Database and system maintenance"
        "backup.sh:Automated backup creation"
        "health.sh:System health monitoring"
    )

    local secure_scripts=()
    local validation_failed=false

    for script_info in "${scripts_to_install[@]}"; do
        local script_name="${script_info%%:*}"
        local script_path="$PROJECT_ROOT/$script_name"

        log_info "Validating script for cron installation: $script_name"

        if ! validate_script_security "$script_path"; then
            log_error "Security validation failed for: $script_name"
            validation_failed=true
            continue
        fi

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

    log_info "Creating cron job entries..."

    # flock wrapper helper used by maintenance and health jobs.
    # flock -n: non-blocking — if lock is held, exit immediately (no queue).
    # Lock files live in CRON_LOCK_DIR (/tmp/vaultwarden-cron-locks/).
    local fl="flock -n"
    local ml="$CRON_LOCK_DIR/maintenance.lock"
    local hl="$CRON_LOCK_DIR/health.lock"

    # FIX [ISSUE 9]:  maintenance now runs Mon-Sat ONLY (days 1-6).
    #                 Sunday is reserved for the weekly full backup at 3 AM.
    # FIX [ISSUE 5]:  maintenance and health wrapped with flock -n to prevent
    #                 overlapping instances. Backup has its own internal lock.
    # BUG 6 FIX:      Firewall on Saturday 4 AM, full backup Sunday 3 AM.
    local cron_jobs=(
        # Daily maintenance at 2 AM — MON-SAT ONLY (FIX [ISSUE 9]: skip Sunday)
        "0 2 * * 1-6 cd $PROJECT_ROOT && $fl $ml $CRON_SCRIPTS_DIR/maintenance.sh --comprehensive >> $CRON_LOG_DIR/maintenance.log 2>&1"

        # Daily database backup at 4 AM with fast verification
        "0 4 * * * cd $PROJECT_ROOT && $CRON_SCRIPTS_DIR/backup.sh --type db --rclone --email >> $CRON_LOG_DIR/backup.log 2>&1"

        # Health check every 30 min (FIX [ISSUE 5]: flock prevents overlapping runs)
        "*/30 * * * * cd $PROJECT_ROOT && $fl $hl $CRON_SCRIPTS_DIR/health.sh --quiet >> $CRON_LOG_DIR/health.log 2>&1"

        # BUG 6 FIX: Weekly firewall update — Saturday 4 AM
        "0 4 * * 6 cd $PROJECT_ROOT && $CRON_SCRIPTS_DIR/maintenance.sh --update-firewall >> $CRON_LOG_DIR/firewall.log 2>&1"

        # BUG 6 FIX + FIX [ISSUE 9]: Weekly full backup — Sunday 3 AM
        # Maintenance does NOT run on Sunday (see Mon-Sat schedule above),
        # so full backup has the full hour window with no competing jobs.
        "0 3 * * 0 cd $PROJECT_ROOT && $CRON_SCRIPTS_DIR/backup.sh --type full --full-verification --rclone --email >> $CRON_LOG_DIR/backup.log 2>&1"

        # Automated DNS update every hour
        "0 * * * * cd $PROJECT_ROOT && $CRON_SCRIPTS_DIR/maintenance.sh --update-dns >> $CRON_LOG_DIR/dns-update.log 2>&1"
    )

    local temp_cron="/tmp/vaultwarden_cron.$$"

    # || true: grep -v exits 1 when all lines are filtered (set -e safety)
    crontab -l 2>/dev/null | grep -v "vaultwarden\|VaultWarden" > "$temp_cron" || true

    echo "# VaultWarden-OCI Automated Jobs - Managed by cron-setup.sh" >> "$temp_cron"
    for job in "${cron_jobs[@]}"; do
        echo "$job" >> "$temp_cron"
    done
    echo "# End VaultWarden-OCI Jobs" >> "$temp_cron"

    if ! chmod 600 "$temp_cron"; then
        log_error "Failed to secure temporary cron file"
        rm -f "$temp_cron"
        return 1
    fi

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
    log_info "  Daily   (2 AM Mon-Sat):  Comprehensive maintenance (flock-protected)"
    log_info "  Daily   (4 AM):          Database backup with fast verification"
    log_info "  Every 30 min:            Health check (flock-protected)"
    log_info "  Every hour:              DNS update"
    log_info "  Weekly  (Sat 4 AM):      Firewall update"
    log_info "  Weekly  (Sun 3 AM):      Full backup with comprehensive verification"
    log_info "  NOTE: Sunday maintenance is intentionally skipped to avoid"
    log_info "        overlap with the Sunday 3 AM full backup."
    return 0
}

# ---------------------------------------------------------------------------
# remove_cron_jobs
# BUG 2 + BUG 4 FIX: handles empty result and pipefail abort.
# ---------------------------------------------------------------------------
remove_cron_jobs() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would remove VaultWarden cron jobs"
        return 0
    fi

    log_info "Removing VaultWarden cron jobs..."

    local temp_cron="/tmp/vaultwarden_cron_remove.$$"

    # BUG 4 FIX: || true prevents pipefail abort when grep -v matches nothing
    crontab -l 2>/dev/null \
        | grep -v -E "(vaultwarden|VaultWarden|$CRON_SCRIPTS_DIR)" \
        > "$temp_cron" || true

    # BUG 2 FIX: gate on non-empty file
    if [[ -s "$temp_cron" ]]; then
        chmod 600 "$temp_cron"
        if ! crontab "$temp_cron"; then
            log_error "Failed to update crontab"
            secure_cleanup "$temp_cron"
            return 1
        fi
        log_success "VaultWarden cron jobs removed"
    else
        # BUG 2 FIX: nothing left — remove entirely rather than install empty file
        crontab -r 2>/dev/null || true
        log_success "VaultWarden cron jobs removed (crontab now empty)"
    fi

    # BUG 2 FIX: always reached
    secure_cleanup "$temp_cron"

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

# ---------------------------------------------------------------------------
# list_cron_jobs
# FIX [ISSUE 17]: Calls check_split_brain at the end.
# ---------------------------------------------------------------------------
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

    if [[ -d "$CRON_SCRIPTS_DIR" ]]; then
        log_info "Secure scripts directory exists: $CRON_SCRIPTS_DIR"
        local script_count
        script_count=$(find "$CRON_SCRIPTS_DIR" -name "*.sh" -type f 2>/dev/null | wc -l)
        log_info "Contains $script_count script files"

        if [[ -d "$CRON_SCRIPTS_DIR/lib" ]]; then
            log_success "Library dependencies present"
            # FIX [ISSUE 15]: Show explicit status for simple_key_resilience.sh
            if [[ -f "$CRON_SCRIPTS_DIR/lib/simple_key_resilience.sh" ]]; then
                log_success "  ✅ simple_key_resilience.sh present"
            else
                log_warn "  ❌ simple_key_resilience.sh MISSING — key health checks disabled"
            fi
        else
            log_warn "Library dependencies missing"
        fi
    else
        log_info "Secure scripts directory does not exist: $CRON_SCRIPTS_DIR"
    fi

    # FIX [ISSUE 17]: Check for split-brain condition
    check_split_brain

    return 0
}

# ---------------------------------------------------------------------------
# validate_cron_security
# BUG 5 FIX: Sets validation_passed=false when jobs not found.
# FIX [ISSUE 17]: Calls check_split_brain at the end.
# FIX [ISSUE 15]: Checks for simple_key_resilience.sh in /opt/.
# ---------------------------------------------------------------------------
validate_cron_security() {
    log_info "Validating VaultWarden cron job security..."

    local validation_passed=true

    if ! systemctl is-active --quiet cron 2>/dev/null; then
        log_error "Cron service is not running"
        log_info "Start with: sudo systemctl start cron"
        validation_passed=false
    else
        log_success "Cron service is running"
    fi

    if crontab -l 2>/dev/null | grep -q "$CRON_SCRIPTS_DIR"; then
        log_success "VaultWarden cron jobs are installed"
    else
        log_warn "No VaultWarden cron jobs found"
        # BUG 5 FIX: was missing
        validation_passed=false
    fi

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

    # FIX [ISSUE 15]: Validate simple_key_resilience.sh presence
    if [[ -f "$CRON_SCRIPTS_DIR/lib/simple_key_resilience.sh" ]]; then
        log_success "simple_key_resilience.sh present in /opt/ lib"
    else
        log_warn "simple_key_resilience.sh MISSING from /opt/ lib — key health checks silently disabled"
        log_info "Fix: sudo ./cron-setup.sh --install"
        validation_passed=false
    fi

    # FIX [ISSUE 5]: Check flock is available (required for job mutual exclusion)
    if command -v flock >/dev/null 2>&1; then
        log_success "flock available — overlapping job protection active"
    else
        log_warn "flock not found — overlapping cron job protection DISABLED"
        log_info "Install with: sudo apt install util-linux"
        validation_passed=false
    fi

    # FIX [ISSUE 17]: Check for split-brain
    check_split_brain

    if [[ "$validation_passed" == "true" ]]; then
        log_success "Cron job security validation passed"
        return 0
    else
        log_warn "Cron job security validation completed with warnings"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    log_header "VaultWarden-OCI Secure Cron Management"

    if [[ "$INSTALL_CRON" == "true" ]] || [[ "$REMOVE_CRON" == "true" ]]; then
        if [[ $EUID -ne 0 ]]; then
            log_error "Cron installation/removal must be run as root"
            log_info "Use: sudo $0 $*"
            exit 1
        fi
    fi

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
