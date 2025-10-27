#!/bin/bash
# create-breakglass-admin.sh - Interactive break-glass admin creation for serial console access

set -euo pipefail

# Source common functions (following your project pattern)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

init_common_lib "$0"

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Interactive prompts with validation
prompt_admin_username() {
    local default_user="admin2"
    local username

    echo
    log_info "Setting up break-glass admin for OCI serial console access"
    echo

    while true; do
        read -p "Enter break-glass admin username (default: $default_user): " username
        username="${username:-$default_user}"

        # Validate username
        if [[ "$username" =~ ^[a-z_]([a-z0-9_-]{0,31}|[a-z0-9_-]{0,30}\$)\$ ]]; then
            if [[ "$username" != "root" && "$username" != "ubuntu" ]]; then
                ADMIN_USER="$username"
                break
            else
                log_error "Cannot use system usernames (root, ubuntu). Choose a different name."
            fi
        else
            log_error "Invalid username. Use lowercase letters, numbers, underscore, and dash only."
        fi
    done

    log_success "Break-glass admin username: $ADMIN_USER"
}

prompt_primary_user() {
    local default_primary="ubuntu"
    local primary_user
    local detected_users

    # Detect existing users with home directories (excluding system users)
    detected_users=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 { print $1 }' | grep -v nobody | head -5)

    echo
    log_info "Detected user accounts: $detected_users"

    while true; do
        read -p "Enter primary user to copy SSH keys from (default: $default_primary): " primary_user
        primary_user="${primary_user:-$default_primary}"

        if id "$primary_user" &>/dev/null; then
            PRIMARY_USER="$primary_user"
            break
        else
            log_error "User '$primary_user' does not exist. Choose from: $detected_users"
        fi
    done

    log_success "Primary user for SSH key copy: $PRIMARY_USER"
}

prompt_additional_ssh_key() {
    local add_key_choice
    local ssh_key

    echo
    log_info "SSH Key Configuration"
    log_info "The script will copy SSH keys from '$PRIMARY_USER' by default."

    while true; do
        read -p "Add an additional SSH public key? (y/n, default: n): " add_key_choice
        add_key_choice="${add_key_choice:-n}"

        case "$add_key_choice" in
            [Yy]|[Yy][Ee][Ss])
                echo "Paste your SSH public key (starts with ssh-rsa, ssh-ed25519, etc.):"
                read -r ssh_key

                # Basic validation of SSH key format
                if [[ "$ssh_key" =~ ^(ssh-rsa|ssh-ed25519|ssh-ecdsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\s+[A-Za-z0-9+/]+ ]]; then
                    ADDITIONAL_SSH_KEY="$ssh_key"
                    log_success "Additional SSH key will be added"
                    break
                else
                    log_error "Invalid SSH key format. Please paste a valid public key."
                fi
                ;;
            [Nn]|[Nn][Oo])
                ADDITIONAL_SSH_KEY=""
                log_info "No additional SSH key will be added"
                break
                ;;
            *)
                log_error "Please answer y or n"
                ;;
        esac
    done
}

prompt_password_setup() {
    local password_choice

    echo
    log_info "Password Configuration"
    log_info "A password is REQUIRED for OCI serial console login."

    while true; do
        read -p "Set password now? (y/n, default: y): " password_choice
        password_choice="${password_choice:-y}"

        case "$password_choice" in
            [Yy]|[Yy][Ee][Ss])
                SET_PASSWORD_NOW="true"
                break
                ;;
            [Nn]|[Nn][Oo])
                SET_PASSWORD_NOW="false"
                log_warn "You will need to set the password manually later with: sudo passwd $ADMIN_USER"
                break
                ;;
            *)
                log_error "Please answer y or n"
                ;;
        esac
    done
}

# Idempotent SSH key management
setup_ssh_keys_idempotent() {
    local auth_keys_file="/home/$ADMIN_USER/.ssh/authorized_keys"
    local temp_file=$(mktemp)
    local primary_keys_file="/home/$PRIMARY_USER/.ssh/authorized_keys"

    log_info "Setting up SSH keys (idempotent)..."

    # Collect all keys that should be present
    {
        # Add primary user's keys if they exist
        if [[ -f "$primary_keys_file" ]]; then
            cat "$primary_keys_file"
        fi

        # Add additional key if provided
        if [[ -n "$ADDITIONAL_SSH_KEY" ]]; then
            echo "$ADDITIONAL_SSH_KEY"
        fi
    } > "$temp_file"

    # Remove empty lines and duplicates
    grep -v '^[[:space:]]*$' "$temp_file" | sort -u > "${temp_file}.clean"

    # Check if current keys match desired keys
    if [[ -f "$auth_keys_file" ]] && cmp -s "${temp_file}.clean" <(sort -u "$auth_keys_file" | grep -v '^[[:space:]]*$'); then
        log_success "SSH keys already up to date"
    else
        # Install the deduplicated keys
        mv "${temp_file}.clean" "$auth_keys_file"
        chmod 600 "$auth_keys_file"
        chown "$ADMIN_USER:$ADMIN_USER" "$auth_keys_file"

        local key_count=$(wc -l < "$auth_keys_file")
        log_success "SSH keys updated ($key_count keys configured)"
    fi

    # Cleanup
    rm -f "$temp_file" "${temp_file}.clean"
}

# Idempotent user creation and configuration
create_or_update_breakglass_admin() {
    local user_existed=false
    local needs_update=false

    # Check if user already exists
    if id "$ADMIN_USER" &>/dev/null; then
        user_existed=true
        log_info "User '$ADMIN_USER' already exists"

        # In non-force mode, ask for confirmation
        if [[ "${FORCE_MODE:-false}" != "true" ]]; then
            local overwrite_choice
            read -p "Update existing user configuration? (y/n): " overwrite_choice
            case "$overwrite_choice" in
                [Yy]|[Yy][Ee][Ss])
                    log_info "Updating existing user '$ADMIN_USER'..."
                    ;;
                *)
                    log_info "Skipping user configuration update"
                    return 0
                    ;;
            esac
        else
            log_info "Force mode: updating existing user '$ADMIN_USER'..."
        fi
    else
        # Create user with sudo privileges
        log_info "Creating user '$ADMIN_USER' with sudo access..."
        useradd -m -s /bin/bash "$ADMIN_USER"
        log_success "User '$ADMIN_USER' created"
        needs_update=true
    fi

    # Ensure user has sudo privileges (idempotent)
    if ! groups "$ADMIN_USER" | grep -q sudo; then
        usermod -aG sudo "$ADMIN_USER"
        log_success "Sudo privileges granted to '$ADMIN_USER'"
        needs_update=true
    else
        log_success "User '$ADMIN_USER' already has sudo privileges"
    fi

    # Setup SSH directory (idempotent)
    local ssh_dir="/home/$ADMIN_USER/.ssh"
    if [[ ! -d "$ssh_dir" ]]; then
        mkdir -p "$ssh_dir"
        chmod 700 "$ssh_dir"
        chown "$ADMIN_USER:$ADMIN_USER" "$ssh_dir"
        log_success "SSH directory created"
        needs_update=true
    fi

    # Setup SSH keys (always check and update if needed)
    setup_ssh_keys_idempotent

    if [[ "$user_existed" == "true" && "$needs_update" == "false" ]]; then
        log_success "Break-glass admin '$ADMIN_USER' already properly configured"
    else
        log_success "Break-glass admin '$ADMIN_USER' configured successfully"
    fi

    return 0
}

set_admin_password() {
    if ! id "$ADMIN_USER" &>/dev/null; then
        log_error "User '$ADMIN_USER' does not exist. Run create function first."
        return 1
    fi

    log_info "Setting password for '$ADMIN_USER'..."
    log_info "Choose a strong password for OCI serial console access."
    echo

    if passwd "$ADMIN_USER"; then
        log_success "Password set for '$ADMIN_USER'"
        echo
        log_info "Serial console login credentials:"
        log_info "Username: $ADMIN_USER"
        log_info "Password: [the password you just set]"
        echo
        log_info "To access via OCI Console:"
        log_info "1. Go to OCI Console → Compute → Instances → [Your Instance]"
        log_info "2. Click 'Console Connection'"
        log_info "3. Connect and login with the above credentials"
    else
        log_error "Failed to set password for '$ADMIN_USER'"
        return 1
    fi
}

show_usage() {
    echo "Usage: sudo $0 [create|password|status|interactive] [--force]"
    echo ""
    echo "Commands:"
    echo "  create       - Create break-glass admin user (interactive prompts)"
    echo "  interactive  - Same as create (default mode)"
    echo "  password     - Set password for existing break-glass admin"
    echo "  status       - Show current break-glass admin status"
    echo ""
    echo "Options:"
    echo "  --force      - Skip interactive confirmations for existing users"
    echo ""
    echo "Interactive mode will prompt you for:"
    echo "  - Break-glass admin username"
    echo "  - Primary user to copy SSH keys from"
    echo "  - Optional additional SSH public key"
    echo "  - Whether to set password immediately"
    echo ""
    echo "Examples:"
    echo "  sudo $0 create"
    echo "  sudo $0 create --force    # Non-interactive updates"
    echo "  sudo $0 password"
    echo ""
    echo "Idempotent behavior:"
    echo "  - Safe to run multiple times"
    echo "  - Only makes necessary changes"
    echo "  - Deduplicates SSH keys automatically"
}

show_status() {
    echo
    log_info "=== Break-glass Admin Status ==="

    # Check for common break-glass admin usernames
    local potential_admins=("admin2" "breakglass" "emergency" "console")
    local found_admins=()

    for user in "${potential_admins[@]}"; do
        if id "$user" &>/dev/null 2>&1; then
            found_admins+=("$user")
        fi
    done

    if [[ ${#found_admins[@]} -eq 0 ]]; then
        log_warn "No break-glass admin accounts found"
        log_info "Common usernames checked: ${potential_admins[*]}"
        echo
        log_info "To create a break-glass admin, run: sudo $0 create"
        return 1
    fi

    echo
    for admin_user in "${found_admins[@]}"; do
        log_info "--- Break-glass admin: $admin_user ---"

        if groups "$admin_user" | grep -q sudo; then
            log_success "✓ User has sudo privileges"
        else
            log_error "✗ User lacks sudo privileges"
        fi

        if [[ -f "/home/$admin_user/.ssh/authorized_keys" ]]; then
            local key_count=$(grep -v '^[[:space:]]*$' "/home/$admin_user/.ssh/authorized_keys" 2>/dev/null | wc -l || echo "0")
            if [[ $key_count -gt 0 ]]; then
                log_success "✓ SSH keys configured ($key_count keys)"
            else
                log_warn "⚠ SSH authorized_keys file exists but empty"
            fi
        else
            log_warn "⚠ No SSH keys configured"
        fi

        # Check if password is set (indirect check)
        if passwd -S "$admin_user" 2>/dev/null | grep -q " P "; then
            log_success "✓ Password is set (serial console ready)"
        else
            log_warn "⚠ No password set (run: sudo $0 password)"
        fi
        echo
    done

    log_info "=== OCI Serial Console Access ==="
    log_info "1. OCI Console → Compute → Instances → [Your Instance]"
    log_info "2. Console Connection → Connect with Cloud Shell"
    log_info "3. Login with break-glass admin credentials"
    log_info "4. Fix firewall: sudo ufw allow 22/tcp"
    log_info "5. Regain SSH access normally"
}

interactive_create() {
    log_header "Interactive Break-glass Admin Creation (Idempotent)"

    # Collect all information interactively
    prompt_admin_username
    prompt_primary_user
    prompt_additional_ssh_key
    prompt_password_setup

    echo
    log_info "=== Configuration Summary ==="
    log_info "Break-glass admin username: $ADMIN_USER"
    log_info "Copy SSH keys from: $PRIMARY_USER"
    if [[ -n "$ADDITIONAL_SSH_KEY" ]]; then
        log_info "Additional SSH key: Yes"
    else
        log_info "Additional SSH key: No"
    fi
    log_info "Set password now: $SET_PASSWORD_NOW"

    echo
    local confirm
    if [[ "${FORCE_MODE:-false}" != "true" ]]; then
        read -p "Proceed with creation/update? (y/n): " confirm
        case "$confirm" in
            [Yy]|[Yy][Ee][Ss])
                ;;
            *)
                log_info "Operation cancelled"
                exit 0
                ;;
        esac
    fi

    # Create or update the admin account (idempotent)
    create_or_update_breakglass_admin

    # Set password if requested
    if [[ "$SET_PASSWORD_NOW" == "true" ]]; then
        echo
        set_admin_password
    fi

    echo
    log_success "Break-glass admin setup completed!"

    if [[ "$SET_PASSWORD_NOW" == "false" ]]; then
        echo
        log_warn "REMINDER: Set password for serial console access:"
        log_warn "sudo passwd $ADMIN_USER"
    fi

    echo
    log_info "Test the setup:"
    log_info "1. Try SSH: ssh $ADMIN_USER@$(hostname -I | awk '{print $1}')"
    log_info "2. Test serial console access via OCI Console"

    log_info "Idempotent: Safe to run this command again anytime"
}

set_password_for_existing() {
    local admin_user

    # Try to detect existing break-glass admin
    local potential_admins=("admin2" "breakglass" "emergency" "console")
    local found_admins=()

    for user in "${potential_admins[@]}"; do
        if id "$user" &>/dev/null 2>&1; then
            found_admins+=("$user")
        fi
    done

    if [[ ${#found_admins[@]} -eq 0 ]]; then
        log_error "No break-glass admin accounts found"
        log_info "Create one first with: sudo $0 create"
        exit 1
    elif [[ ${#found_admins[@]} -eq 1 ]]; then
        admin_user="${found_admins[0]}"
        log_info "Found break-glass admin: $admin_user"
    else
        echo "Multiple break-glass admin accounts found:"
        select admin_user in "${found_admins[@]}"; do
            if [[ -n "$admin_user" ]]; then
                break
            else
                log_error "Invalid selection"
            fi
        done
    fi

    ADMIN_USER="$admin_user"
    set_admin_password
}

main() {
    # Parse command line arguments
    local command="${1:-interactive}"
    local force_mode=false

    # Check for --force flag
    for arg in "$@"; do
        if [[ "$arg" == "--force" ]]; then
            force_mode=true
            FORCE_MODE="true"
            break
        fi
    done

    case "$command" in
        "create"|"interactive")
            interactive_create
            ;;
        "password")
            set_password_for_existing
            ;;
        "status")
            show_status
            ;;
        "help"|"--help"|"-h")
            show_usage
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Global variables (will be set by prompts)
ADMIN_USER=""
PRIMARY_USER=""
ADDITIONAL_SSH_KEY=""
SET_PASSWORD_NOW=""

main "$@"
