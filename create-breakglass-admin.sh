#!/usr/bin/env bash
# create-breakglass-admin.sh - Emergency admin account for OCI serial console access
# SIMPLIFIED DESIGN: Creates a full admin user and adds to 'sudo' group.
# This is simpler and more maintainable than a custom sudoers file.

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
    --create                Create break-glass admin account (full sudo)
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
    This account is a FULL ADMINISTRATOR with root privileges.
    Access via OCI Console Connection (serial console).

SECURITY NOTES:
    • Uses strong random password (32+ characters)
    • Account is added to the 'sudo' group (full root access)
    • Password displayed only once during creation
    • Account can be disabled/removed when not needed
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

# SIMPLIFIED: create_sudoers_config() function removed.
# We now add the user to the standard 'sudo' group.

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

    # Set password
    if ! echo "$BREAKGLASS_USER:$password" | chpasswd; then
        log_error "Failed to set user password"
        userdel -r "$BREAKGLASS_USER" 2>/dev/null || true
        return 1
    fi
    
    # SIMPLIFIED: Just add to sudo group (full admin access)
    if ! usermod -aG sudo "$BREAKGLASS_USER"; then
        log_error "Failed to add user to sudo group"
        userdel -r "$BREAKGLASS_USER" 2>/dev/null || true
        return 1
    fi

    log_success "Break-glass admin created with full sudo access"

    # Create emergency access instructions with secure permissions
    local instructions_file="/home/$BREAKGLASS_USER/EMERGENCY_ACCESS_INSTRUCTIONS.txt"
    local instructions_content
    instructions_content=$(cat << EOF
VaultWarden Emergency Access Instructions
========================================
This account is a FULL ADMINISTRATOR with complete system access.

ACCESS VIA OCI CONSOLE:
1. Log into Oracle Cloud Infrastructure (OCI)
2. Navigate to: Compute → Instances → Your Instance
3. Click "Console Connection"
4. Login with these credentials:
   Username: $BREAKGLASS_USER
   Password: [stored securely in your password manager]

AVAILABLE OPERATIONS:
- All sudo commands (full root access)
- All Docker operations
- All VaultWarden scripts (restore, backup, maintenance)
- All file operations
- System reboot/shutdown

COMMON EMERGENCY COMMANDS:
# Fix SSH lockout
sudo ufw allow ${SSH_PORT:-22}/tcp
sudo systemctl restart sshd

# Check system status
sudo docker compose ps
sudo journalctl -u docker --since "1 hour ago"
sudo df -h

# Restart services
sudo docker compose restart
cd $PROJECT_ROOT && sudo ./startup.sh

# Full disaster recovery
cd $PROJECT_ROOT && sudo ./restore.sh

SECURITY NOTES:
- This account has the SAME privileges as your main admin user
- Use only for genuine emergencies
- Disable when not needed: sudo deluser $BREAKGLASS_USER sudo
- Remove when no longer needed: sudo deluser --remove-home $BREAKGLASS_USER
- Password is 32+ characters for maximum security

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
    echo "• This is a FULL ADMINISTRATOR account"
    echo "• 32-character password provides strong protection"
    echo "• Store in secure password manager immediately"
    echo "• Access via OCI Console Connection when needed"
    echo "• Disable when not needed: sudo deluser $BREAKGLASS_USER sudo"
    echo "• Remove when done: sudo deluser --remove-home $BREAKGLASS_USER"
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

    # SIMPLIFIED: Just delete user (no custom sudoers file to remove)
    if userdel -r "$BREAKGLASS_USER" 2>/dev/null; then
        log_success "User removed: $BREAKGLASS_USER"
    else
        log_warn "User removal may have had issues (user might not have had home directory)"
    fi

    # Remove user from sudo group (best effort)
    deluser "$BREAKGLASS_USER" sudo 2>/dev/null || true


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
        if groups "$BREAKGLASS_USER" | grep -q -w "sudo"; then
            echo "  Sudo access: ✅ Configured (member of 'sudo' group)"
        else
            echo "  Sudo access: ❌ NOT in 'sudo' group"
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
    log_header "VaultWarden-OCI Break-Glass Admin Manager (Simple Mode)"

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
            echo "  3. Validate script security: sudo ./create-breakglass-admin.sh --validate"
            echo "  4. Disable when not needed: sudo deluser $BREAKGLASS_USER sudo"

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
