#!/usr/bin/env bash
# create-breakglass-admin.sh - Emergency admin account for OCI serial console access
# ENHANCED: Standardized error handling - functions return, main() decides exit strategy
# All functions return exit codes, main() collects status and determines final exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/security.sh"

# Configuration
BREAKGLASS_USER="vw-emergency"
CREATE_USER=false
REMOVE_USER=false
RESET_PASSWORD=false
SHOW_STATUS=false
VALIDATE_ONLY=false
DRY_RUN=false
FORCE=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Break-Glass Admin Manager - Emergency Access

USAGE:
    sudo ./create-breakglass-admin.sh [OPTIONS]

OPTIONS:
    --create                Create break-glass admin account
    --remove                Remove break-glass admin account
    --reset-password        Reset break-glass admin password
    --status                Show break-glass admin status
    --validate              Validate script security only (no operations)
    --user USERNAME         Specify username (default: vw-emergency)
    --force                 Force operations without confirmation
    --dry-run               Show what would be done without executing
    --help                  Show this help

EXAMPLES:
    sudo ./create-breakglass-admin.sh --create        # Create emergency admin
    sudo ./create-breakglass-admin.sh --status        # Check status
    sudo ./create-breakglass-admin.sh --validate      # Validate script security
    sudo ./create-breakglass-admin.sh --reset-password # Reset password
    sudo ./create-breakglass-admin.sh --remove        # Remove account

BREAK-GLASS ADMIN PURPOSE:
    Emergency access when SSH is broken or firewall blocks access.
    Access via OCI Console Connection (serial console).

SECURITY NOTES:
    • Uses strong random password (32 characters)
    • Limited sudo access (systemctl, ufw, docker commands only)
    • Separate from primary admin account
    • Password displayed only once during creation
    • Account can be disabled when not needed
    • Script validates its own security before operations
EOF
}

# ENHANCED: Script self-validation using lib/security.sh
validate_script_security() {
    local script_path="$0"

    log_info "Validating script security..."

    # Get absolute path
    if ! script_path=$(readlink -f "$script_path"); then
        log_error "Failed to resolve script path"
        return 1
    fi

    # Use centralized security validation
    if ! validate_file_permissions "$script_path" "700" "root" "root"; then
        log_error "SECURITY: Script failed validation - privilege escalation risk"
        log_error "Expected: root:root ownership with 700 permissions"
        log_error "Current script: $script_path"

        # Show current permissions for debugging
        if ls -la "$script_path"; then
            log_info "^ Current permissions shown above"
        fi

        log_error "Fix with: sudo chown root:root '$script_path' && sudo chmod 700 '$script_path'"
        return 1
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

# STANDARDIZED: Create sudoers configuration - returns exit code
create_sudoers_config() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create sudoers configuration for $BREAKGLASS_USER"
        return 0
    fi

    log_info "Creating limited sudoers configuration..."

    local sudoers_file="/etc/sudoers.d/vaultwarden-breakglass"

    # Use centralized secure file creation
    local temp_content
    temp_content=$(cat << EOF
# VaultWarden Break-Glass Admin - Limited Emergency Access
# Created: $(date)
# User: $BREAKGLASS_USER

# Allow limited system control commands for emergency access
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /bin/systemctl start ssh
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /bin/systemctl stop ssh
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart ssh
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /bin/systemctl status ssh
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /usr/sbin/ufw allow *
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /usr/sbin/ufw delete *
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /usr/sbin/ufw status
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /usr/bin/docker ps
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /usr/bin/docker compose ps
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /usr/bin/docker compose logs *
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /usr/bin/docker compose restart
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /usr/bin/docker compose down
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /usr/bin/docker compose up -d

# Allow viewing logs
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /usr/bin/journalctl *
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /bin/dmesg

# Allow changing to project directory
$BREAKGLASS_USER ALL=(ALL) NOPASSWD: /bin/su - $(get_real_user)
EOF
)

    # Create with secure permissions using centralized function
    if ! create_secure_file "$sudoers_file" "$temp_content" "440" "root" "root"; then
        log_error "Failed to create sudoers configuration securely"
        return 1
    fi

    # Validate sudoers syntax
    if ! visudo -c -f "$sudoers_file"; then
        log_error "Sudoers configuration syntax validation failed"
        secure_cleanup "$sudoers_file"
        return 1
    fi

    log_success "Sudoers configuration created and validated"
    return 0
}

# STANDARDIZED: Create break-glass user - returns exit code
create_breakglass_user() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create break-glass user: $BREAKGLASS_USER"
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

    # Set password
    if ! echo "$BREAKGLASS_USER:$password" | chpasswd; then
        log_error "Failed to set user password"
        userdel -r "$BREAKGLASS_USER" 2>/dev/null || true
        return 1
    fi

    # Create sudoers configuration
    if ! create_sudoers_config; then
        log_error "Failed to create sudoers configuration"
        userdel -r "$BREAKGLASS_USER" 2>/dev/null || true
        return 1
    fi

    # Create emergency access instructions with secure permissions
    local instructions_file="/home/$BREAKGLASS_USER/EMERGENCY_ACCESS_INSTRUCTIONS.txt"
    local instructions_content
    instructions_content=$(cat << EOF
VaultWarden Emergency Access Instructions
========================================

This account provides emergency access to your VaultWarden instance when:
- SSH access is broken
- Firewall blocks normal access
- Primary admin account is locked

ACCESS VIA OCI CONSOLE:
1. Log into Oracle Cloud Infrastructure (OCI)
2. Navigate to: Compute → Instances → Your Instance
3. Click "Console Connection"
4. Create new connection or use existing
5. Connect via browser or SSH

EMERGENCY COMMANDS AVAILABLE:
- sudo systemctl restart ssh    # Fix SSH service
- sudo ufw allow 22/tcp        # Open SSH in firewall
- sudo docker compose ps       # Check container status
- sudo docker compose restart  # Restart services
- sudo journalctl -u ssh       # Check SSH logs

IMPORTANT:
- This account has LIMITED sudo access for security
- Use only for genuine emergencies
- Disable/remove when not needed
- Change password regularly

Created: $(date)
Project: $PROJECT_ROOT
EOF
)

    if ! create_secure_file "$instructions_file" "$instructions_content" "600" "$BREAKGLASS_USER" "$BREAKGLASS_USER"; then
        log_warn "Failed to create instructions file securely"
    fi

    log_success "Break-glass admin created successfully"
    echo ""
    echo "🚨 EMERGENCY ACCESS CREDENTIALS 🚨"
    echo "=================================="
    echo "Username: $BREAKGLASS_USER"
    echo "Password: $password"
    echo ""
    echo "⚠️  SECURITY WARNING:"
    echo "• These credentials are displayed ONLY ONCE"
    echo "• Store them securely (password manager, encrypted note)"
    echo "• Access via OCI Console Connection when needed"
    echo "• Delete this account when no longer needed"
    echo ""
    echo "Instructions saved to: $instructions_file"

    return 0
}

# STANDARDIZED: Remove break-glass user - returns exit code
remove_breakglass_user() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would remove break-glass user: $BREAKGLASS_USER"
        return 0
    fi

    log_info "Removing break-glass admin user: $BREAKGLASS_USER"

    # Check if user exists
    if ! check_user_exists; then
        log_info "User does not exist: $BREAKGLASS_USER"
        return 0
    fi

    # Confirmation unless forced
    if [[ "$FORCE" != "true" ]]; then
        echo ""
        log_warn "This will permanently remove the break-glass admin account."
        log_warn "You will lose emergency console access capability."
        echo ""
        read -p "Continue with removal? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            log_info "Removal cancelled by user"
            return 0
        fi
    fi

    # Remove user and home directory
    if userdel -r "$BREAKGLASS_USER" 2>/dev/null; then
        log_success "User removed: $BREAKGLASS_USER"
    else
        log_warn "User removal may have had issues (user might not have had home directory)"
    fi

    # Remove sudoers configuration with secure cleanup
    local sudoers_file="/etc/sudoers.d/vaultwarden-breakglass"
    if [[ -f "$sudoers_file" ]]; then
        if secure_cleanup "$sudoers_file"; then
            log_success "Sudoers configuration removed securely"
        else
            log_warn "Failed to remove sudoers configuration securely"
        fi
    fi

    log_success "Break-glass admin removal completed"
    return 0
}

# STANDARDIZED: Reset break-glass password - returns exit code
reset_breakglass_password() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would reset password for: $BREAKGLASS_USER"
        return 0
    fi

    log_info "Resetting break-glass admin password: $BREAKGLASS_USER"

    # Check if user exists
    if ! check_user_exists; then
        log_error "User does not exist: $BREAKGLASS_USER"
        log_info "Use --create to create the break-glass admin first"
        return 1
    fi

    # Generate new password using centralized function
    local password
    if ! password=$(generate_secure_random 32); then
        log_error "Failed to generate secure password"
        return 1
    fi

    # Set new password
    if ! echo "$BREAKGLASS_USER:$password" | chpasswd; then
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

    return 0
}

# ENHANCED: Show break-glass status with security validation
show_breakglass_status() {
    log_info "Break-glass admin status:"
    echo ""

    # Check if user exists
    if check_user_exists; then
        echo "  Status: ✅ Active"
        echo "  Username: $BREAKGLASS_USER"

        # Get user info
        local user_info
        if user_info=$(getent passwd "$BREAKGLASS_USER"); then
            local home_dir
            home_dir=$(echo "$user_info" | cut -d: -f6)
            echo "  Home directory: $home_dir"

            # Check if instructions file exists and is secure
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
        fi

        # Check sudoers configuration
        local sudoers_file="/etc/sudoers.d/vaultwarden-breakglass"
        if [[ -f "$sudoers_file" ]]; then
            if validate_file_permissions "$sudoers_file" "440" "root" "root"; then
                echo "  Sudo access: ✅ Configured and secure"
            else
                echo "  Sudo access: ⚠️  Configured but permissions need fixing"
            fi

            # Validate sudoers syntax
            if visudo -c -f "$sudoers_file" >/dev/null 2>&1; then
                echo "  Sudo config: ✅ Valid syntax"
            else
                echo "  Sudo config: ❌ Invalid syntax"
            fi
        else
            echo "  Sudo access: ❌ Not configured"
        fi

        # Check account status
        if passwd -S "$BREAKGLASS_USER" 2>/dev/null | grep -q " P "; then
            echo "  Account: ✅ Password set"
        else
            echo "  Account: ⚠️  No password or locked"
        fi

    else
        echo "  Status: ❌ Not created"
        echo "  Username: $BREAKGLASS_USER (would be created)"
    fi

    # Check OCI console connection capability
    echo ""
    log_info "OCI Console Access:"
    echo "  • Log into Oracle Cloud Infrastructure (OCI)"
    echo "  • Navigate to: Compute → Instances → Your Instance"
    echo "  • Click 'Console Connection'"
    echo "  • Use credentials above to access via serial console"

    echo ""
    log_info "Security Status:"
    if validate_script_security; then
        echo "  • Script security: ✅ Validated"
    else
        echo "  • Script security: ❌ Validation failed"
        return 1
    fi

    return 0
}

# ENHANCED: Main function with proper error handling, exit strategy, and security validation
main() {
    log_header "VaultWarden-OCI Break-Glass Admin Manager"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    # Must run as root
    if ! is_root; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi

    # ENHANCED: Always validate script security first (as documented in SECURITY.md)
    if ! validate_script_security; then
        log_error "Script security validation failed - refusing to proceed"
        log_info "This is a security requirement to prevent privilege escalation"
        exit 1
    fi

    # Handle validation-only mode
    if [[ "$VALIDATE_ONLY" == "true" ]]; then
        log_success "Script security validation completed successfully"
        exit 0
    fi

    # Validate username
    if [[ ! "$BREAKGLASS_USER" =~ ^[a-z][-a-z0-9]*$ ]]; then
        log_error "Invalid username format: $BREAKGLASS_USER"
        log_info "Username must start with lowercase letter and contain only lowercase letters, numbers, and hyphens"
        exit 1
    fi

    # Handle status check
    if [[ "$SHOW_STATUS" == "true" ]]; then
        if show_breakglass_status; then
            exit 0
        else
            exit 1
        fi
    fi

    # Handle user removal
    if [[ "$REMOVE_USER" == "true" ]]; then
        if remove_breakglass_user; then
            log_success "Break-glass admin removal completed successfully"
            exit 0
        else
            log_error "Break-glass admin removal failed"
            exit 1
        fi
    fi

    # Handle password reset
    if [[ "$RESET_PASSWORD" == "true" ]]; then
        if reset_breakglass_password; then
            log_success "Break-glass admin password reset completed successfully"
            exit 0
        else
            log_error "Break-glass admin password reset failed"
            exit 1
        fi
    fi

    # Handle user creation
    if [[ "$CREATE_USER" == "true" ]]; then
        if create_breakglass_user; then
            log_success "Break-glass admin creation completed successfully"

            echo ""
            log_info "🎯 Next Steps:"
            echo "  1. Store the credentials securely"
            echo "  2. Test OCI Console Connection access"
            echo "  3. Verify emergency commands work"
            echo "  4. Validate script security: sudo ./create-breakglass-admin.sh --validate"
            echo "  5. Disable when not needed: sudo ./create-breakglass-admin.sh --remove"

            exit 0
        else
            log_error "Break-glass admin creation failed"
            exit 1
        fi
    fi

    # Should not reach here
    log_error "No valid operation specified"
    show_help
    exit 1
}

main "$@"
