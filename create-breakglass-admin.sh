#!/usr/bin/env bash
# create-breakglass-admin.sh - Emergency admin account for OCI serial console access
# SECURITY DESIGN: Creates a targeted-privilege account with least-privilege sudoers.
# Grants only the specific commands needed for emergency VaultWarden recovery.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/security.sh"

# FIX [L-05]: Source SSH_PORT from .env so instructions show the correct port.
# $SSH_PORT defaults to 22 if not set or not found in .env.
SSH_PORT="${SSH_PORT:-}"
if [[ -z "$SSH_PORT" ]] && [[ -f "${PROJECT_ROOT}/.env" ]]; then
    # Use grep -m1 to take the first match; strip surrounding quotes/spaces robustly.
    SSH_PORT=$(grep -m1 -E '^[[:space:]]*SSH_PORT[[:space:]]*=' "${PROJECT_ROOT}/.env" 2>/dev/null \
        | sed 's/^[^=]*=[[:space:]]*//' | tr -d '"'"'" | tr -d '[:space:]') || true
fi
SSH_PORT="${SSH_PORT:-22}"

# Configuration
BREAKGLASS_USER="vw-emergency"
CREATE_USER=false
REMOVE_USER=false
RESET_PASSWORD=false
SHOW_STATUS=false
VALIDATE_ONLY=false
DRY_RUN=false
FORCE=false

# BG-L1: Configurable threshold (hours) after which --status warns the account is still active.
BREAKGLASS_MAX_AGE_HOURS="${BREAKGLASS_MAX_AGE_HOURS:-72}"

# Auto-expiry: hours after creation before the account is automatically removed.
# Set to 0 to disable auto-expiry (not recommended for production use).
BREAKGLASS_AUTO_EXPIRY_HOURS="${BREAKGLASS_AUTO_EXPIRY_HOURS:-2}"

show_help() {
    cat << 'EOF'
VaultWarden-OCI Break-Glass Admin Manager - Emergency Access

USAGE:
    sudo ./create-breakglass-admin.sh [OPTIONS]

OPTIONS:
    --create                Create break-glass admin account (targeted sudo)
    --remove                Remove break-glass admin account
    --reset-password        Reset break-glass admin password
    --status                Show break-glass admin status
    --validate              Validate script security only (no operations)
    --user USERNAME         Specify username (default: vw-emergency)
    --force                 Force operations without confirmation
    --dry-run               Show what would be done without executing
    --help                  Show this help

ENVIRONMENT:
    BREAKGLASS_MAX_AGE_HOURS     Hours before --status warns account is too old (default: 72)
    BREAKGLASS_AUTO_EXPIRY_HOURS Hours after creation before the account is auto-removed
                                 (default: 2). Scheduler priority:
                                   1. `at` + atd running
                                   2. `at` present (tries on-demand activation)
                                   3. systemd-run transient timer (survives reboots)
                                   4. background sleep subshell (lost on reboot)
                                 Set to 0 to disable auto-expiry entirely.

EXAMPLES:
    sudo ./create-breakglass-admin.sh --create        # Create emergency admin
    sudo ./create-breakglass-admin.sh --status        # Check status
    sudo ./create-breakglass-admin.sh --validate      # Validate script security
    sudo ./create-breakglass-admin.sh --reset-password # Reset password
    sudo ./create-breakglass-admin.sh --remove        # Remove account

BREAK-GLASS ADMIN PURPOSE:
    Emergency access when SSH is broken or firewall blocks access.
    This account has targeted sudo access (docker, systemctl, journalctl, reboot).
    Access via OCI Console Connection (serial console).

SECURITY NOTES:
    • Uses strong random password (32+ characters)
    • Account is granted targeted sudo via /etc/sudoers.d/vw-emergency
    • Allowed commands: docker, systemctl, journalctl, reboot
    • Password displayed only once during creation
    • Account is automatically removed after BREAKGLASS_AUTO_EXPIRY_HOURS (default: 2h)
    • Account can be disabled/removed manually with --remove
    • Script validates its own security before operations
EOF
}

# ---------------------------------------------------------------------------
# BG-M1 FIX: validate_script_security()
#
# Two-tier enforcement:
#   strict=true  → hard-fail on ANY permission/ownership deviation (--validate mode)
#   strict=false → hard-fail ONLY when the script is world-writable (o+w set),
#                  because that is an active privilege-escalation vector regardless
#                  of operational mode. Non-critical deviations (e.g. not yet
#                  chowned to root during a fresh install) remain warnings.
# ---------------------------------------------------------------------------
validate_script_security() {
    local strict="${1:-false}"
    local script_path="$0"

    log_info "Validating script security..."

    # Get absolute path
    if ! script_path=$(readlink -f "$script_path"); then
        log_error "Failed to resolve script path"
        return 1
    fi

    # ------------------------------------------------------------------
    # BG-M1: Always hard-fail if the script file is world-writable (o+w).
    # This check runs in every mode so an attacker cannot inject code by
    # making the file group- or world-writable between invocations.
    # ------------------------------------------------------------------
    local perms
    if perms=$(stat -c '%a' "$script_path" 2>/dev/null); then
        # Convert octal string to integer for bitwise test
        local perm_int
        perm_int=$(( 8#$perms ))
        # Bit 1 of the "other" triad = world-write (octal 002 = decimal 2)
        if (( perm_int & 8#002 )); then
            log_error "SECURITY: Script is world-writable — hard-failing to prevent code injection"
            log_error "Script: $script_path  (current mode: $perms)"
            log_error "Fix with: sudo chmod o-w '$script_path'"
            return 1
        fi
        # Group-writable is also dangerous; always hard-fail on that too.
        if (( perm_int & 8#020 )); then
            log_error "SECURITY: Script is group-writable — hard-failing to prevent code injection"
            log_error "Script: $script_path  (current mode: $perms)"
            log_error "Fix with: sudo chmod g-w '$script_path'"
            return 1
        fi
    else
        log_error "Failed to stat script for permission check: $script_path"
        return 1
    fi

    # ------------------------------------------------------------------
    # Full ownership + permission check (root:root 700).
    # In strict mode (--validate) this is a hard error.
    # In non-strict mode it is a warning so fresh installs aren't blocked.
    # ------------------------------------------------------------------
    if ! validate_file_permissions "$script_path" "700" "root" "root"; then
        if [[ "$strict" == "true" ]]; then
            log_error "SECURITY: Script failed validation - privilege escalation risk"
            log_error "Expected: root:root ownership with 700 permissions"
            log_error "Current script: $script_path"

            # Show current permissions for debugging
            if ls -la "$script_path"; then
                log_info "^ Current permissions shown above"
            fi

            log_error "Fix with: sudo chown root:root '$script_path' && sudo chmod 700 '$script_path'"
            return 1
        else
            log_warn "Script not owned by root:root — consider: sudo chown root:root $(realpath "$script_path") && sudo chmod 700 $(realpath "$script_path")"
        fi
    fi

    # Validate script is in expected location
    local expected_dir="/opt/vaultwarden-scripts"
    if [[ "$script_path" == "$expected_dir"/* ]]; then
        log_success "Script location validated (secure cron location)"
    elif [[ "$script_path" == */VaultWarden-OCI/* ]]; then
        log_info "Script location: Development/project directory"
    else
        log_warn "Script in unexpected location: $script_path"
    fi

    # Validate lib/security.sh is available and secure
    local security_lib="$PROJECT_ROOT/lib/security.sh"
    if [[ ! -f "$security_lib" ]]; then
        log_error "SECURITY: Required security library not found: $security_lib"
        return 1
    fi

    if ! validate_file_permissions "$security_lib" "644" "root" "root"; then
        log_warn "Security library permissions could be improved"
        log_info "Consider: sudo chown root:root '$security_lib' && sudo chmod 644 '$security_lib'"
    fi

    log_success "Script security validation passed"
    return 0
}

# Argument Parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --create) CREATE_USER=true; shift ;;
        --remove) REMOVE_USER=true; shift ;;
        --reset-password) RESET_PASSWORD=true; shift ;;
        --status) SHOW_STATUS=true; shift ;;
        --validate) VALIDATE_ONLY=true; shift ;;
        --user) BREAKGLASS_USER="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Validation
if [[ "$CREATE_USER" == "true" && "$REMOVE_USER" == "true" ]]; then
    log_error "Cannot create and remove at the same time"
    exit 1
fi

if [[ "$VALIDATE_ONLY" == "false" ]] && [[ "$CREATE_USER" == "false" && "$REMOVE_USER" == "false" && "$RESET_PASSWORD" == "false" && "$SHOW_STATUS" == "false" ]]; then
    log_error "Must specify --create, --remove, --reset-password, --status, or --validate"
    show_help
    exit 1
fi

# STANDARDIZED: Check if user exists - returns exit code
check_user_exists() {
    id "$BREAKGLASS_USER" >/dev/null 2>&1
}

# STANDARDIZED: Generate secure password - returns exit code
generate_breakglass_password() {
    local password
    if password=$(generate_secure_password 32); then
        echo "$password"
        return 0
    else
        log_error "Failed to generate secure password"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# create_sudoers_config()
#
# Grants least-privilege sudo access scoped to the exact commands needed for
# emergency VaultWarden recovery. Full 'sudo' group membership is intentionally
# avoided: if the account password is compromised it should not hand an attacker
# unrestricted root access.
#
# The sudoers entry is written atomically via visudo -c validation and installed
# to /etc/sudoers.d/ with mode 0440 (required by sudo). Cleanup on removal is
# handled by remove_breakglass_user().
# ---------------------------------------------------------------------------
create_sudoers_config() {
    local sudoers_file="/etc/sudoers.d/vw-emergency"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would write targeted sudoers: $sudoers_file"
        return 0
    fi

    local tmp_sudoers
    tmp_sudoers=$(mktemp -t vw_sudoers.XXXXXXXXXX)
    trap 'rm -f "$tmp_sudoers" 2>/dev/null; trap - RETURN' RETURN

    cat >"$tmp_sudoers" <<EOF
# VaultWarden emergency break-glass account — least-privilege sudo
# Generated by create-breakglass-admin.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Remove this file when the break-glass account is decommissioned.
${BREAKGLASS_USER} ALL=(root) NOPASSWD: /usr/bin/docker, /bin/systemctl, /usr/bin/journalctl, /sbin/reboot
EOF

    if ! visudo -c -f "$tmp_sudoers" >/dev/null 2>&1; then
        log_error "Generated sudoers content failed visudo validation — not installed"
        return 1
    fi

    if ! install -m 0440 -o root -g root "$tmp_sudoers" "$sudoers_file"; then
        log_error "Failed to install sudoers file: $sudoers_file"
        return 1
    fi

    log_success "Targeted sudoers installed: $sudoers_file"
    return 0
}

# ---------------------------------------------------------------------------
# LOW FIX: _notify_breakglass_event()
#
# Emits a notification via the same send_notification_email() / send_email()
# path used by health.sh and maintenance.sh so breakglass activity is
# visible in the operator's alert channel, not just a local log file.
# Non-fatal: a delivery failure is logged as a warning only.
# ---------------------------------------------------------------------------
_notify_breakglass_event() {
    local event="$1"      # e.g. "CREATED", "REMOVED", "PASSWORD_RESET", "DISABLE_FAILED"
    local detail="${2:-}"
    local severity="${3:-INFO}"  # INFO | CRITICAL

    local subject="Breakglass Admin ${event}: ${BREAKGLASS_USER}"
    [[ "$severity" == "CRITICAL" ]] && subject="CRITICAL ${subject}"

    local body
    body=$(printf 'Breakglass admin event\n\nEvent:   %s\nUser:    %s\nHost:    %s\nTime:    %s\n' \
        "$event" "$BREAKGLASS_USER" "$(hostname -f 2>/dev/null || hostname)" "$(date -uIs)")
    [[ -n "$detail" ]] && body+=$(printf '\nDetail:  %s' "$detail")

    if ! send_notification_email "$subject" "$body" 2>/dev/null; then
        log_warn "Breakglass event notification delivery failed (non-fatal)"
    fi
}

# ---------------------------------------------------------------------------
# schedule_auto_cleanup()
#
# Schedules an automatic --remove for BREAKGLASS_AUTO_EXPIRY_HOURS from now.
# Scheduler priority (first available method wins):
#
#   1. `at` + atd running       Most reliable; persists across reboots within
#                               the expiry window. Uses stdin submission.
#   2. `at` present, atd absent Tries submission anyway (some distros activate
#                               atd on first use).
#   3. systemd-run --on-active  Transient one-shot timer. Survives reboots
#                               because systemd re-arms the timer from the
#                               monotonic offset on resume. No persistent unit
#                               file; cleaned up automatically after the job
#                               runs. Preferred over the sleep subshell.
#   4. setsid+sleep subshell    Last resort. Runs detached from the terminal
#                               but is LOST on reboot. Operator is warned.
#
# Set BREAKGLASS_AUTO_EXPIRY_HOURS=0 to disable entirely.
# ---------------------------------------------------------------------------
schedule_auto_cleanup() {
    local expiry_hours="$BREAKGLASS_AUTO_EXPIRY_HOURS"
    local bg_user="$BREAKGLASS_USER"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would schedule auto-cleanup in ${expiry_hours}h"
        return 0
    fi

    if (( expiry_hours == 0 )); then
        log_warn "Auto-expiry disabled (BREAKGLASS_AUTO_EXPIRY_HOURS=0) — remember to run --remove manually"
        return 0
    fi

    local script_abs
    script_abs=$(readlink -f "$0")
    local cleanup_cmd="${script_abs} --remove --user ${bg_user} --force"
    local expiry_epoch=$(( $(date +%s) + expiry_hours * 3600 ))
    local expiry_human
    expiry_human=$(date -d "@${expiry_epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
        || date -r "${expiry_epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
        || date -u -d "${expiry_hours} hours" '+%Y-%m-%d %H:%M UTC' 2>/dev/null \
        || echo "in ${expiry_hours} hour(s)")

    # ------------------------------------------------------------------
    # Tier 1 & 2: `at` scheduler
    # ------------------------------------------------------------------
    if command -v at >/dev/null 2>&1 && systemctl is-active --quiet atd 2>/dev/null; then
        # `at` is available and atd is running — schedule via the job queue.
        if echo "${cleanup_cmd}" | at now + "${expiry_hours}" hours 2>/dev/null; then
            log_success "Auto-cleanup scheduled via 'at' at ${expiry_human}"
            return 0
        else
            log_warn "'at' scheduling failed — trying next tier"
        fi
    elif command -v at >/dev/null 2>&1; then
        # `at` present but atd not confirmed running — try anyway (some
        # distros start atd on demand via socket activation).
        if echo "${cleanup_cmd}" | at now + "${expiry_hours}" hours 2>/dev/null; then
            log_success "Auto-cleanup scheduled via 'at' at ${expiry_human}"
            return 0
        else
            log_warn "'at' available but scheduling failed — trying next tier"
        fi
    fi

    # ------------------------------------------------------------------
    # Tier 3: systemd-run transient timer.
    #
    # --on-active schedules the unit to run N time after activation.
    # Transient timers are re-armed by systemd from their monotonic offset
    # on resume, so a reboot within the expiry window does NOT lose the
    # cleanup job. The unit is automatically removed after it fires.
    # UNIT NAME is fixed (vw-breakglass-cleanup) so a duplicate run
    # (e.g. --force recreate) replaces any existing timer rather than
    # stacking multiple timers for the same account.
    # ------------------------------------------------------------------
    if command -v systemd-run >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
        if systemd-run \
                --on-active="${expiry_hours}h" \
                --unit="vw-breakglass-cleanup" \
                --description="VaultWarden breakglass auto-cleanup for ${bg_user}" \
                -- bash -c "${cleanup_cmd}" 2>/dev/null; then
            log_success "Auto-cleanup scheduled via systemd transient timer at ${expiry_human} (reboot-safe)"
            return 0
        else
            log_warn "systemd-run scheduling failed — falling back to background sleep"
        fi
    fi

    # ------------------------------------------------------------------
    # Tier 4: background subshell using sleep.
    # Runs detached (setsid + redirects) so it survives the invoking shell
    # session, but it is LOST ON REBOOT. The operator must run --remove
    # manually if the host is rebooted before expiry elapses.
    # ------------------------------------------------------------------
    local sleep_seconds=$(( expiry_hours * 3600 ))
    log_warn "'at' and systemd-run not available or failed — scheduling auto-cleanup via background sleep"
    log_warn "WARNING: This cleanup job is NOT reboot-safe. Run --remove manually if you reboot this host."
    setsid bash -c "sleep ${sleep_seconds} && ${cleanup_cmd}" \
        </dev/null >/dev/null 2>&1 &
    disown
    log_success "Auto-cleanup background job started (PID $!) — will run at ${expiry_human} (NOT reboot-safe)"
    return 0
}

# STANDARDIZED: Create break-glass user - returns exit code
create_breakglass_user() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create break-glass admin user: $BREAKGLASS_USER"
        return 0
    fi

    log_info "Creating break-glass admin user: $BREAKGLASS_USER"

    # Check if user already exists
    if check_user_exists; then
        if [[ "$FORCE" != "true" ]]; then
            log_error "User already exists: $BREAKGLASS_USER"
            log_info "Use --force to recreate or --reset-password to change password"
            return 1
        else
            log_warn "User exists, recreating with --force"
            if ! remove_breakglass_user; then
                log_error "Failed to remove existing user for recreation"
                return 1
            fi
        fi
    fi

    # Generate secure password using centralized function
    local password
    if ! password=$(generate_secure_random 32); then
        log_error "Failed to generate secure password"
        return 1
    fi

    # Create user with home directory
    if ! useradd -m -s /bin/bash -c "VaultWarden Emergency Admin" "$BREAKGLASS_USER"; then
        log_error "Failed to create user: $BREAKGLASS_USER"
        return 1
    fi

    # FIX [M-09]: Use heredoc to set password — avoids "echo USER:PASS | chpasswd" which
    # exposes the password in /proc/<pid>/cmdline via the echo subprocess.
    if ! chpasswd <<< "${BREAKGLASS_USER}:${password}"; then
        log_error "Failed to set user password"
        userdel -r "$BREAKGLASS_USER" 2>/dev/null || true
        return 1
    fi

    if ! create_sudoers_config; then
        log_error "Failed to install sudoers configuration"
        userdel -r "$BREAKGLASS_USER" 2>/dev/null || true
        return 1
    fi

    log_success "Break-glass admin created with targeted sudo access"

    # Create emergency access instructions with secure permissions
    local instructions_file="/home/$BREAKGLASS_USER/EMERGENCY_ACCESS_INSTRUCTIONS.txt"
    local instructions_content
    instructions_content=$(cat << EOF
VaultWarden Emergency Access Instructions
========================================
This account has targeted emergency access for VaultWarden recovery.

ACCESS VIA OCI CONSOLE:
1. Log into Oracle Cloud Infrastructure (OCI)
2. Navigate to: Compute → Instances → Your Instance
3. Click "Console Connection"
4. Login with these credentials:
   Username: $BREAKGLASS_USER
   Password: [stored securely in your password manager]

ALLOWED OPERATIONS:
- sudo /usr/bin/docker
- sudo /bin/systemctl
- sudo /usr/bin/journalctl
- sudo /sbin/reboot

COMMON EMERGENCY COMMANDS:
# Fix SSH lockout
sudo /bin/systemctl restart sshd

# Check system status
sudo /usr/bin/docker compose ps
sudo /usr/bin/journalctl -u docker --since "1 hour ago"

# Restart services
sudo /usr/bin/docker compose restart

SECURITY NOTES:
- This account does NOT have unrestricted root access
- Use only for genuine emergencies
- Account auto-expires after ${BREAKGLASS_AUTO_EXPIRY_HOURS} hour(s)
- Remove manually if needed: sudo ./create-breakglass-admin.sh --remove
- Password is 32+ characters for maximum security

Created: $(date)
Project: $PROJECT_ROOT
EOF
)

    if ! create_secure_file "$instructions_file" "$instructions_content" "600" "$BREAKGLASS_USER" "$BREAKGLASS_USER"; then
        log_warn "Failed to create instructions file securely"
    fi

    log_success "Break-glass admin created successfully"

    _notify_breakglass_event "CREATED" "User $BREAKGLASS_USER created with targeted sudoers (/etc/sudoers.d/vw-emergency)" "INFO"

    # Compute and display the auto-expiry time before clearing the screen.
    local expiry_epoch=$(( $(date +%s) + BREAKGLASS_AUTO_EXPIRY_HOURS * 3600 ))
    local expiry_human
    expiry_human=$(date -d "@${expiry_epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
        || date -r "${expiry_epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
        || echo "in ${BREAKGLASS_AUTO_EXPIRY_HOURS} hour(s)")

    clear
    printf '%b\n' "${COLOR_RED}"
    cat << "EOF"
  _    _  ___  ____  _   _  _  _  ____  _ 
 ( \/\/ )/ __)(_  _)( )_( )( \/ )(__  )(_)
  )    (( (__  _)(_  ) _ (  )  (  _)(_  _ 
 (__/\__)\___)(____)((_) (_)(_/\_)(____)((_)
EOF
    printf '%b\n' "${COLOR_RESET}"

    printf '%b\n' "${COLOR_YELLOW}EMERGENCY ACCESS CREDENTIALS CREATED${COLOR_RESET}"
    printf 'These credentials allow access via the OCI Serial Console if SSH fails.\n'
    printf 'Write these down physically and store them securely.\n\n'

    printf '%b\n' "Username:  ${COLOR_GREEN}${BREAKGLASS_USER}${COLOR_RESET}"
    printf '%b\n' "Password:  ${COLOR_GREEN}${password}${COLOR_RESET}"
    if (( BREAKGLASS_AUTO_EXPIRY_HOURS > 0 )); then
        printf '%b\n' "Expiry:    ${COLOR_YELLOW}${expiry_human} (auto-cleanup in ${BREAKGLASS_AUTO_EXPIRY_HOURS}h)${COLOR_RESET}"
    else
        printf '%b\n' "Expiry:    ${COLOR_CYAN}None — auto-expiry disabled. Remove manually with --remove${COLOR_RESET}"
    fi

    printf '\nTo test this:\n'
    printf '1. Go to Oracle Cloud Console > Compute > Instance > Console Connection\n'
    printf '2. Launch Cloud Shell connection\n'
    printf '3. Press ENTER to see login prompt\n'
    printf '4. Login with the credentials above\n'

    printf '%b\n' "\n${COLOR_RED}Press ENTER to clear screen and finish...${COLOR_RESET}"
    read -r
    clear

    # Schedule auto-cleanup after credentials have been displayed and acknowledged.
    schedule_auto_cleanup

    return 0
}

# ---------------------------------------------------------------------------
# BG-M2 FIX: remove_breakglass_user()
# ---------------------------------------------------------------------------
remove_breakglass_user() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would remove break-glass user: $BREAKGLASS_USER"
        return 0
    fi

    log_info "Removing break-glass admin user: $BREAKGLASS_USER"

    if ! check_user_exists; then
        log_info "User does not exist: $BREAKGLASS_USER"
        return 0
    fi

    if [[ "$FORCE" != "true" ]]; then
        echo ""
        log_warn "This will permanently remove the break-glass admin account."
        log_warn "You will lose emergency console access capability."
        echo ""
        read -r -p "Continue with removal? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            log_info "Removal cancelled by user"
            return 0
        fi
    fi

    local sudoers_file="/etc/sudoers.d/vw-emergency"
    if [[ -f "$sudoers_file" ]]; then
        if rm -f "$sudoers_file"; then
            log_info "Removed targeted sudoers: $sudoers_file"
        else
            log_warn "Failed to remove sudoers file: $sudoers_file — manual removal required"
        fi
    fi

    # Cancel the transient systemd cleanup timer if it is still pending,
    # so it does not fire and attempt --remove on an already-removed account.
    if systemctl is-active --quiet vw-breakglass-cleanup.timer 2>/dev/null; then
        systemctl stop vw-breakglass-cleanup.timer 2>/dev/null || true
        log_info "Stopped pending systemd transient cleanup timer (vw-breakglass-cleanup)"
    fi

    # Legacy cleanup for older installs that added the user to the sudo group.
    if groups "$BREAKGLASS_USER" 2>/dev/null | grep -qw "sudo"; then
        if command -v gpasswd >/dev/null 2>&1; then
            if gpasswd -d "$BREAKGLASS_USER" sudo 2>/dev/null; then
                log_info "Removed $BREAKGLASS_USER from sudo group via gpasswd (legacy cleanup)"
            else
                log_warn "gpasswd -d reported an error removing $BREAKGLASS_USER from sudo group"
            fi
        elif command -v deluser >/dev/null 2>&1; then
            if deluser "$BREAKGLASS_USER" sudo 2>/dev/null; then
                log_info "Removed $BREAKGLASS_USER from sudo group via deluser (legacy cleanup)"
            else
                log_warn "deluser reported an error removing $BREAKGLASS_USER from sudo group"
            fi
        else
            log_warn "Could not remove $BREAKGLASS_USER from sudo group automatically."
            log_warn "Manual remediation: edit /etc/group and remove '$BREAKGLASS_USER' from the sudo line."
        fi
    fi

    if userdel -r "$BREAKGLASS_USER" 2>/dev/null; then
        log_success "User removed: $BREAKGLASS_USER"
    else
        log_warn "User removal may have had issues (user might not have had home directory)"
    fi

    log_success "Break-glass admin removal completed"
    _notify_breakglass_event "REMOVED" "User $BREAKGLASS_USER and sudoers file /etc/sudoers.d/vw-emergency removed" "INFO"
    return 0
}

# STANDARDIZED: Reset break-glass password - returns exit code
reset_breakglass_password() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would reset password for: $BREAKGLASS_USER"
        return 0
    fi

    log_info "Resetting break-glass admin password: $BREAKGLASS_USER"

    if ! check_user_exists; then
        log_error "User does not exist: $BREAKGLASS_USER"
        log_info "Use --create to create the break-glass admin first"
        return 1
    fi

    local password
    if ! password=$(generate_secure_random 32); then
        log_error "Failed to generate secure password"
        return 1
    fi

    if ! chpasswd <<< "${BREAKGLASS_USER}:${password}"; then
        log_error "Failed to reset user password"
        return 1
    fi

    log_success "Break-glass admin password reset successfully"
    echo ""
    echo "🔑 NEW EMERGENCY ACCESS CREDENTIALS"
    echo "=================================="
    echo "Username: $BREAKGLASS_USER"
    echo "Password: $password"
    echo ""
    echo "⚠️  SECURITY WARNING:"
    echo "• These credentials are displayed ONLY ONCE"
    echo "• Store them securely (password manager, encrypted note)"
    echo "• Old credentials are now invalid"

    _notify_breakglass_event "PASSWORD_RESET" "Password for $BREAKGLASS_USER was reset" "INFO"
    return 0
}

# ---------------------------------------------------------------------------
# BG-L1 FIX: _check_breakglass_account_age()
# ---------------------------------------------------------------------------
_check_breakglass_account_age() {
    local home_dir="$1"
    local instructions_file="$home_dir/EMERGENCY_ACCESS_INSTRUCTIONS.txt"
    local creation_epoch=""

    if [[ -f "$instructions_file" ]]; then
        creation_epoch=$(stat -c '%Y' "$instructions_file" 2>/dev/null) || true
    fi

    if [[ -z "$creation_epoch" ]] && [[ -d "$home_dir" ]]; then
        creation_epoch=$(stat -c '%Y' "$home_dir" 2>/dev/null) || true
    fi

    if [[ -z "$creation_epoch" ]]; then
        log_warn "Cannot determine account creation time — skipping age check"
        return 0
    fi

    local now_epoch
    now_epoch=$(date +%s)
    local age_seconds=$(( now_epoch - creation_epoch ))
    local age_hours=$(( age_seconds / 3600 ))
    local threshold_seconds=$(( BREAKGLASS_MAX_AGE_HOURS * 3600 ))

    if (( age_seconds > threshold_seconds )); then
        echo "  Account age: ⚠️  ${age_hours}h (threshold: ${BREAKGLASS_MAX_AGE_HOURS}h) — consider removing with --remove"
        log_warn "Break-glass account has been active for ${age_hours} hours (limit: ${BREAKGLASS_MAX_AGE_HOURS}h)."
        log_warn "Remove it when no longer needed: sudo $0 --remove"
    else
        echo "  Account age: ✅ ${age_hours}h (threshold: ${BREAKGLASS_MAX_AGE_HOURS}h)"
    fi
}

# ENHANCED: Show break-glass status with security validation
show_breakglass_status() {
    log_info "Break-glass admin status:"
    echo ""

    if check_user_exists; then
        echo "  Status: ✅ Active"
        echo "  Username: $BREAKGLASS_USER"

        local user_info
        if user_info=$(getent passwd "$BREAKGLASS_USER"); then
            local home_dir
            home_dir=$(echo "$user_info" | cut -d: -f6)
            echo "  Home directory: $home_dir"

            local instructions_file="$home_dir/EMERGENCY_ACCESS_INSTRUCTIONS.txt"
            if [[ -f "$instructions_file" ]]; then
                if validate_file_permissions "$instructions_file" "600" "$BREAKGLASS_USER" "$BREAKGLASS_USER"; then
                    echo "  Instructions: ✅ Available and secure"
                else
                    echo "  Instructions: ⚠️  Available but permissions need fixing"
                fi
            else
                echo "  Instructions: ❌ Missing"
            fi

            _check_breakglass_account_age "$home_dir"
        fi

        local sudoers_file="/etc/sudoers.d/vw-emergency"
        if [[ -f "$sudoers_file" ]] && grep -q "^${BREAKGLASS_USER} " "$sudoers_file" 2>/dev/null; then
            echo "  Sudo access: ✅ Configured (targeted /etc/sudoers.d/vw-emergency)"
        elif groups "$BREAKGLASS_USER" 2>/dev/null | grep -q -w "sudo"; then
            echo "  Sudo access: ⚠️  Member of 'sudo' group (legacy full-root configuration)"
        else
            echo "  Sudo access: ❌ NOT configured"
        fi

        if passwd -S "$BREAKGLASS_USER" 2>/dev/null | grep -q " P "; then
            echo "  Account: ✅ Password set"
        else
            echo "  Account: ⚠️  No password or locked"
        fi

        # Show cleanup timer status if it is still pending.
        if systemctl is-active --quiet vw-breakglass-cleanup.timer 2>/dev/null; then
            local timer_left
            timer_left=$(systemctl show vw-breakglass-cleanup.timer -p NextElapseUSecRealtime 2>/dev/null | cut -d= -f2 || echo "unknown")
            echo "  Auto-cleanup timer: ✅ Pending via systemd (vw-breakglass-cleanup)"
        else
            echo "  Auto-cleanup timer: ℹ️  Not active via systemd (may be scheduled via 'at')"
        fi

    else
        echo "  Status: ❌ Not created"
        echo "  Username: $BREAKGLASS_USER (would be created)"
    fi

    echo ""
    log_info "OCI Console Access:"
    echo "  • Log into Oracle Cloud Infrastructure (OCI)"
    echo "  • Navigate to: Compute → Instances → Your Instance"
    echo "  • Click 'Console Connection'"
    echo "  • Use credentials above to access via serial console"

    echo ""
    log_info "Security Status:"
    if validate_script_security "false"; then
        echo "  • Script security: ✅ Validated"
    else
        echo "  • Script security: ❌ Validation failed"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# MEDIUM FIX: _restart_after_disable()
# ---------------------------------------------------------------------------
_restart_after_disable() {
    local service="${1:-vaultwarden}"

    log_info "Restarting $service to re-apply original token..."
    if docker compose restart "$service"; then
        log_success "$service restarted successfully — breakglass token deactivated"
        return 0
    fi

    local _rc=$?
    log_error "CRITICAL: 'docker compose restart $service' failed (exit ${_rc})."
    log_error "CRITICAL: The breakglass admin token is still ACTIVE."
    log_error "Manual remediation required:"
    log_error "  1. Investigate: docker compose logs $service"
    log_error "  2. Fix the underlying issue (port conflict, OOM, config error)"
    log_error "  3. Re-run: docker compose restart $service"
    log_error "  4. Confirm: ./create-breakglass-admin.sh --status"

    _notify_breakglass_event \
        "DISABLE_FAILED" \
        "docker compose restart ${service} exited with code ${_rc}. Breakglass token is still ACTIVE." \
        "CRITICAL"

    return $_rc
}

# ENHANCED: Main function with proper error handling, exit strategy, and security validation
main() {
    log_header "VaultWarden-OCI Break-Glass Admin Manager (Simple Mode)"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    if ! is_root; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi

    local _security_strict="false"
    [[ "$VALIDATE_ONLY" == "true" ]] && _security_strict="true"

    if ! validate_script_security "$_security_strict"; then
        log_error "Script security validation failed - refusing to proceed"
        log_info "This is a security requirement to prevent privilege escalation"
        exit 1
    fi

    if [[ "$VALIDATE_ONLY" == "true" ]]; then
        log_success "Script security validation completed successfully"
        exit 0
    fi

    if [[ ! "$BREAKGLASS_USER" =~ ^[a-z][-a-z0-9]*$ ]]; then
        log_error "Invalid username format: $BREAKGLASS_USER"
        log_info "Username must start with lowercase letter and contain only lowercase letters, numbers, and hyphens"
        exit 1
    fi

    if [[ "$SHOW_STATUS" == "true" ]]; then
        if show_breakglass_status; then
            exit 0
        else
            exit 1
        fi
    fi

    local _BG_LOCK_FILE="/run/lock/vaultwarden-breakglass.lock"
    local _BG_LOCK_FD
    exec {_BG_LOCK_FD}>"$_BG_LOCK_FILE"
    trap 'rm -f "${_BG_LOCK_FILE:-}"' EXIT
    if ! flock -n "$_BG_LOCK_FD"; then
        log_error "Another breakglass operation is already running."
        log_error "If the lock is stale, remove: ${_BG_LOCK_FILE}"
        exit 1
    fi

    if [[ "$REMOVE_USER" == "true" ]]; then
        if remove_breakglass_user; then
            log_success "Break-glass admin removal completed successfully"
            exit 0
        else
            log_error "Break-glass admin removal failed"
            exit 1
        fi
    fi

    if [[ "$RESET_PASSWORD" == "true" ]]; then
        if reset_breakglass_password; then
            log_success "Break-glass admin password reset completed successfully"
            exit 0
        else
            log_error "Break-glass admin password reset failed"
            exit 1
        fi
    fi

    if [[ "$CREATE_USER" == "true" ]]; then
        if create_breakglass_user; then
            log_success "Break-glass admin creation completed successfully"

            echo ""
            log_info "🎯 Next Steps:"
            echo "  1. Store the credentials securely"
            echo "  2. Test OCI Console Connection access"
            echo "  3. Validate script security: sudo ./create-breakglass-admin.sh --validate"
            echo "  4. Account will auto-expire in ${BREAKGLASS_AUTO_EXPIRY_HOURS}h; remove sooner if done: sudo ./create-breakglass-admin.sh --remove"

            exit 0
        else
            log_error "Break-glass admin creation failed"
            exit 1
        fi
    fi

    log_error "No valid operation specified"
    show_help
    exit 1
}

main "$@"
