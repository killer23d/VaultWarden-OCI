#!/usr/bin/env bash
# edit-secrets.sh - Simplified secrets management with library integration
# Uses centralized library functions

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"

# --- Configuration ---
EDITOR="${EDITOR:-nano}"
SECRETS_FILE="secrets/secrets.yaml"

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden Secrets Editor

USAGE:
    ./edit-secrets.sh [OPTIONS]

OPTIONS:
    --editor EDITOR  Editor to use (default: nano, or $EDITOR)
    --init          Initialize secrets file with templates
    --show          Show decrypted secrets (careful!)
    --help          Show this help

DESCRIPTION:
    Safely edit encrypted secrets using SOPS and Age encryption.
    Secrets are automatically re-encrypted after editing.

EXAMPLES:
    ./edit-secrets.sh           # Edit secrets with default editor
    ./edit-secrets.sh --editor vim   # Use vim as editor
    ./edit-secrets.sh --init    # Create new secrets file from template
    ./edit-secrets.sh --show    # Display current secrets (be careful!)
EOF
}

# --- Argument Parsing ---
SHOW_MODE=false
INIT_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --editor) EDITOR="$2"; shift 2 ;;
        --init) INIT_MODE=true; shift ;;
        --show) SHOW_MODE=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Validation ---
check_prerequisites() {
    # Check required commands using library function
    require_commands age "$EDITOR" || return 1

    # Check SOPS availability using library function
    if ! check_sops_available; then
        log_error "SOPS not available"
        log_info "Install with: sudo apt install sops"
        return 1
    fi

    # Check Age key using library function
    if ! check_age_key; then
        log_error "Age private key not available"
        log_info "Run ./setup.sh to generate keys"
        return 1
    fi

    return 0
}

# --- Initialize Secrets ---
init_secrets() {
    log_info "Initializing secrets file from template..."

    if [[ -f "$SECRETS_FILE" ]]; then
        log_warn "Secrets file already exists: $SECRETS_FILE"
        read -p "Overwrite existing file? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Cancelled"
            return 0
        fi
    fi

    # Ensure secrets directory exists using library function
    ensure_dir "$(dirname "$SECRETS_FILE")" 700

    # Generate secure random values using library function
    local admin_token backup_pass
    admin_token=$(generate_hex_string 32)
    backup_pass=$(generate_secure_string 32)

    # Create template secrets file
    cat > "$SECRETS_FILE" << EOF
# VaultWarden Secrets Configuration
# Edit these values for your installation

# Admin token for VaultWarden admin panel
# Generate with: openssl rand -hex 32
admin_token: $admin_token

# Basic auth hash for admin panel protection
# Generate with: echo -n 'password' | argon2 \$(openssl rand -base64 32) -e -id -k 65536 -t 3 -p 4
# Or use online bcrypt generator: https://bcrypt-generator.com/
admin_basic_auth_hash: CHANGE_ME_BCRYPT_HASH

# SMTP password for email notifications
smtp_password: CHANGE_ME_SMTP_PASSWORD

# Backup encryption passphrase
backup_passphrase: $backup_pass

# Optional: Push notifications (get ID and Key from bitwarden.com/host)
# --- FIX: Added push_installation_id ---
push_installation_id: CHANGE_ME_OR_LEAVE_EMPTY
push_installation_key: CHANGE_ME_OR_LEAVE_EMPTY

# --- P1 CHANGE: Split Cloudflare token ---
# Cloudflare API token for DDNS (Permissions: Zone:DNS:Edit)
ddclient_api_token: CHANGE_ME_DDCLIENT_API_TOKEN

# Cloudflare API token for Fail2Ban/Caddy (Permissions: Zone:Firewall Services:Edit)
fail2ban_api_token: CHANGE_ME_FAIL2BAN_API_TOKEN
EOF

    log_success "Template secrets file created"
    log_info "Now encrypting with SOPS..."

    # Encrypt the file using library function
    if sops_encrypt "$SECRETS_FILE"; then
        log_success "Secrets file encrypted successfully"
        secure_file "$SECRETS_FILE" 600
    else
        log_error "Failed to encrypt secrets file"
        return 1
    fi

    log_warn "IMPORTANT: Update the CHANGE_ME values:"
    log_info "  1. Run: ./edit-secrets.sh"
    log_info "  2. Update admin_basic_auth_hash"
    # --- P1 CHANGE: Updated help text ---
    log_info "  3. Update ddclient_api_token (for dynamic DNS)"
    log_info "  4. Update fail2ban_api_token (for firewall bans)"
    log_info "  5. Update smtp_password if using email notifications"
    log_info "  6. Update push_installation_id and push_installation_key if using push"

    return 0
}

# --- Show Secrets ---
show_secrets() {
    log_warn "⚠️  SECURITY WARNING: Displaying decrypted secrets!"
    read -p "Are you sure you want to continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Cancelled"
        return 0
    fi

    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_error "Secrets file not found: $SECRETS_FILE"
        log_info "Run: ./edit-secrets.sh --init"
        return 1
    fi

    echo ""
    echo "=== DECRYPTED SECRETS ==="
    # Use library function to decrypt
    if sops_decrypt "$SECRETS_FILE"; then
        echo "========================="
        echo ""
        log_warn "Remember to keep these values secure!"
    else
        log_error "Failed to decrypt secrets file"
        return 1
    fi

    return 0
}

# --- Edit Secrets ---
edit_secrets() {
    log_info "Opening encrypted secrets for editing..."

    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_error "Secrets file not found: $SECRETS_FILE"
        log_info "Run: ./edit-secrets.sh --init to create it"
        return 1
    fi

    # Check if file is encrypted using library function
    if ! is_sops_encrypted "$SECRETS_FILE"; then
        log_error "Secrets file is not encrypted with SOPS"
        return 1
    fi

    # Test decryption using library function
    if ! sops_decrypt "$SECRETS_FILE" >/dev/null 2>&1; then
        log_error "Cannot decrypt secrets file with current Age key"
        log_info "Check that Age key is correct and SOPS config is valid"
        return 1
    fi

    log_info "Using editor: $EDITOR"
    log_info "The file will be automatically re-encrypted when you save and exit"
    echo ""

    # Use SOPS to edit the file directly using library function
    if sops_edit "$SECRETS_FILE"; then
        log_success "Secrets updated successfully"

        # Verify the file is still properly encrypted using library function
        if is_sops_encrypted "$SECRETS_FILE"; then
            log_success "Secrets file encryption verified"
        else
            log_error "Warning: Secrets file may not be properly encrypted"
            return 1
        fi

        # Set proper permissions using library function
        secure_file "$SECRETS_FILE" 600

        # Remind about restarting services
        echo ""
        log_info "To apply changes to running services:"
        log_info "  ./startup.sh --force-restart"

    else
        log_error "Editor exited with error or was cancelled"
        return 1
    fi

    return 0
}

# --- Generate Password Hash ---
generate_password_hash() {
    log_info "Password Hash Generator"
    echo ""

    if ! has_command argon2; then
        log_warn "argon2 command not found, using openssl alternative"
        log_info "Install argon2: sudo apt install argon2"
        echo ""

        read -s -p "Enter password: " password
        echo ""
        local salt hash
        salt=$(generate_secure_string 16)
        hash=$(echo -n "$password" | openssl dgst -sha256 -binary | openssl base64)
        echo ""
        log_info "Basic SHA256 hash (less secure than bcrypt/argon2):"
        echo "$hash"
        echo ""
        log_warn "Use a proper bcrypt generator online for production:"
        log_info "https://bcrypt-generator.com/"
    else
        read -s -p "Enter password: " password
        echo ""
        local salt hash
        salt=$(generate_secure_string 32)
        hash=$(echo -n "$password" | argon2 "$salt" -e -id -k 65536 -t 3 -p 4)
        echo ""
        log_success "Argon2 hash generated:"
        echo "$hash"
    fi

    echo ""
    log_info "Copy this hash to your secrets file as admin_basic_auth_hash"
}

# --- Test Secrets Access ---
test_secrets_access() {
    log_info "Testing secrets access..."

    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_error "Secrets file not found: $SECRETS_FILE"
        return 1
    fi

    # Test decryption using library function
    if sops_decrypt "$SECRETS_FILE" >/dev/null 2>&1; then
        log_success "Secrets file can be decrypted"

        # Test individual secret access using library function
        local test_secrets=("admin_token" "backup_passphrase")
        local accessible_secrets=0

        for secret in "${test_secrets[@]}"; do
            if get_secret "$secret" >/dev/null 2>&1; then
                ((accessible_secrets++))
                log_success "Secret '$secret' accessible"
            else
                log_warn "Secret '$secret' not found or inaccessible"
            fi
        done

        if [[ $accessible_secrets -eq ${#test_secrets[@]} ]]; then
            log_success "All core secrets are accessible"
        else
            log_warn "Some secrets may be missing or misconfigured"
        fi

    else
        log_error "Cannot decrypt secrets file"
        return 1
    fi

    return 0
}

# --- Main Execution ---
main() {
    log_info "VaultWarden Secrets Manager"

    # Check prerequisites first
    check_prerequisites || exit 1

    # Handle different modes
    if [[ "$INIT_MODE" == "true" ]]; then
        init_secrets
    elif [[ "$SHOW_MODE" == "true" ]]; then
        show_secrets
    else
        # Check if secrets file exists, offer to create it
        if [[ ! -f "$SECRETS_FILE" ]]; then
            log_warn "No secrets file found"
            read -p "Create new secrets file from template? (Y/n): " create_new
            if [[ ! "$create_new" =~ ^[Nn]$ ]]; then
                init_secrets || exit 1
                echo ""
                log_info "Now opening for editing..."
                sleep 2
            else
                log_info "Cancelled"
                exit 0
            fi
        fi

        # Show menu for existing file
        echo ""
        echo "What would you like to do?"
        echo "1) Edit secrets"
        echo "2) Generate password hash"
        echo "3) Show current secrets"
        echo "4) Test secrets access"
        echo "5) Exit"
        echo ""
        read -p "Choice (1-5): " choice

        case "$choice" in
            1) edit_secrets ;;
            2) generate_password_hash ;;
            3) show_secrets ;;
            4) test_secrets_access ;;
            5) log_info "Goodbye"; exit 0 ;;
            *) log_error "Invalid choice"; exit 1 ;;
        esac
    fi
}

main "$@"
