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
AGE_KEY_FILE="secrets/keys/age-key.txt"
SOPS_CONFIG_FILE=".sops.yaml" # Added SOPS config file variable


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
    --test          Test if secrets can be decrypted
    --help          Show this help

DESCRIPTION:
    Safely edit encrypted secrets using SOPS and Age encryption.
    Secrets are automatically re-encrypted after editing.

EXAMPLES:
    ./edit-secrets.sh           # Edit secrets with default editor (via menu)
    make edit-secrets          # Edit secrets with default editor (via menu)
    ./edit-secrets.sh --editor vim   # Use vim as editor
    ./edit-secrets.sh --init    # Create new secrets file from template
    ./edit-secrets.sh --show    # Display current secrets (be careful!)
    ./edit-secrets.sh --test    # Check if secrets are accessible
EOF
}

# --- Argument Parsing ---
SHOW_MODE=false
INIT_MODE=false
TEST_MODE=false # Added test mode flag

while [[ $# -gt 0 ]]; do
    case $1 in
        --editor) EDITOR="$2"; shift 2 ;;
        --init) INIT_MODE=true; shift ;;
        --show) SHOW_MODE=true; shift ;;
        --test) TEST_MODE=true; shift ;; # Added test mode parsing
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Validation ---
check_prerequisites() {
    # Check required commands using library function
    # Check if EDITOR command exists
    if ! has_command "$EDITOR"; then
         log_error "Configured editor '$EDITOR' not found."
         log_info "Install it or use '--editor <installed_editor>'."
         log_info "Default editor 'nano' can be installed with: sudo apt install nano"
         return 1
    fi
    require_commands age "$EDITOR" || return 1


    # Check SOPS availability using library function
    if ! check_sops_available; then
        log_error "SOPS command not found"
        log_info "SOPS should have been installed during setup."
        log_info "Try running setup again or install manually."
        return 1
    fi

    # Check Age key using library function (checks existence and permissions 600)
    if ! check_age_key "$AGE_KEY_FILE"; then
        log_error "Age private key not found or has incorrect permissions: $AGE_KEY_FILE"
        log_info "Ensure the file exists and has permissions 600 (rw-------)."
        log_info "If the key is missing, setup may need to be rerun (this might reset secrets)."
        return 1
    fi

    # --- START FIX: Check SOPS config file existence ---
    if [[ ! -f "$SOPS_CONFIG_FILE" ]]; then
        log_error "SOPS configuration file not found: $SOPS_CONFIG_FILE"
        log_info "This file tells SOPS which key to use."
        log_info "Please re-run 'sudo ./setup.sh --force' to generate it."
        return 1
    fi
    # --- END FIX ---


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
        # Remove existing file if overwriting
        rm -f "$SECRETS_FILE"
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
push_installation_id: CHANGE_ME_OR_LEAVE_EMPTY
push_installation_key: CHANGE_ME_OR_LEAVE_EMPTY

# Cloudflare API token for DDNS (Permissions: Zone:DNS:Edit)
ddclient_api_token: CHANGE_ME_DDCLIENT_API_TOKEN

# Cloudflare API token for Fail2Ban/Caddy (Permissions: Zone:Firewall Services:Edit)
fail2ban_api_token: CHANGE_ME_FAIL2BAN_API_TOKEN
EOF

    log_success "Template secrets file created"
    log_info "Now encrypting with SOPS..."

    # Encrypt the file using SOPS. It should pick up the key from .sops.yaml
    if sops --encrypt --in-place "$SECRETS_FILE"; then
        log_success "Secrets file encrypted successfully using config in $SOPS_CONFIG_FILE"
        secure_file "$SECRETS_FILE" 600
    else
        log_error "Failed to encrypt secrets file using $SOPS_CONFIG_FILE"
        log_info "Check $SOPS_CONFIG_FILE and ensure the public key matches secrets/keys/age-public-key.txt"
        return 1
    fi

    log_warn "IMPORTANT: Update the CHANGE_ME values:"
    log_info "  1. Run: ./edit-secrets.sh (and choose option 1)"
    log_info "  2. Update admin_basic_auth_hash"
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
    echo "=== DECRYPTED SECRETS (using key $AGE_KEY_FILE) ==="
    # Use library function to decrypt, explicitly providing key
    # (Showing secrets should always use the explicit key for clarity)
    if sops_decrypt "$SECRETS_FILE" "" "$AGE_KEY_FILE"; then # Pass key file explicitly
        echo "======================================================"
        echo ""
        log_warn "Remember to keep these values secure!"
    else
        log_error "Failed to decrypt secrets file using key $AGE_KEY_FILE"
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

    # Permission checks
    if [[ ! -r "$AGE_KEY_FILE" ]]; then
        log_error "Cannot read Age key file: $AGE_KEY_FILE"
        log_info "Check permissions. It should be readable by user $(whoami)."
        return 1
    fi
     if [[ ! -w "$SECRETS_FILE" ]]; then
        log_error "Cannot write to secrets file: $SECRETS_FILE"
        log_info "Check permissions. It should be writable by user $(whoami)."
        return 1
    fi
    if [[ ! -w "$(dirname "$SECRETS_FILE")" ]]; then
        log_error "Cannot write to secrets directory: $(dirname "$SECRETS_FILE")"
        log_info "Check permissions. Directory should be writable by user $(whoami)."
        return 1
    fi
     if [[ ! -r "$SOPS_CONFIG_FILE" ]]; then
        log_error "Cannot read SOPS config file: $SOPS_CONFIG_FILE"
        log_info "Check permissions or re-run setup."
        return 1
    fi


    # Check if file is encrypted using library function
    if ! is_sops_encrypted "$SECRETS_FILE"; then
        log_error "Secrets file exists but does not appear to be encrypted with SOPS"
        log_info "Cannot safely edit. If this is unexpected, check the file content."
        return 1
    fi

    # Test decryption using the explicit key (as a sanity check before editing)
    log_debug "Performing pre-edit decryption test using key $AGE_KEY_FILE..."
    if ! sops_decrypt "$SECRETS_FILE" "/dev/null" "$AGE_KEY_FILE" >/dev/null 2>&1; then
        log_error "Pre-edit decryption test failed using key: $AGE_KEY_FILE"
        log_info "This indicates a key mismatch or corrupted file. Cannot proceed with edit."
        return 1
    fi
    log_success "Pre-edit decryption test passed."


    log_info "Using editor: $EDITOR"
    log_info "Relying on $SOPS_CONFIG_FILE to find the correct Age key."
    log_info "The file will be automatically re-encrypted when you save and exit."
    echo ""

    # --- START FIX: Rely on .sops.yaml for the edit command ---
    # Use SOPS to edit the file directly. SOPS will use .sops.yaml to find the key.
    local sops_command="sops \"$SECRETS_FILE\""
    log_debug "Executing SOPS edit command: EDITOR=\"$EDITOR\" $sops_command"
    if EDITOR="$EDITOR" sops "$SECRETS_FILE"; then
    # --- END FIX ---
        log_success "Secrets updated successfully"

        # Verify the file is still properly encrypted using library function
        if is_sops_encrypted "$SECRETS_FILE"; then
            log_success "Secrets file encryption verified"
        else
            log_error "CRITICAL WARNING: Secrets file may NOT be properly encrypted after editing!"
            log_info "Check the file content immediately: $SECRETS_FILE"
            return 1
        fi

        # Set proper permissions using library function
        secure_file "$SECRETS_FILE" 600

        # Remind about restarting services
        echo ""
        log_info "To apply changes to running services:"
        log_info "  make restart  (or ./startup.sh --force-restart)"

    else
        log_warn "Editor exited with a non-zero status or SOPS encountered an error during edit."
        log_info "Secrets file *should* remain unchanged if the editor cancelled."
        log_info "If SOPS reported an error, check its output for details."
        log_info "You can run './edit-secrets.sh --test' to check decryption again."
        return 1 # Return error code
    fi

    return 0
}

# --- Generate Password Hash ---
generate_password_hash() {
    log_info "Password Hash Generator"
    echo ""

    if ! has_command argon2; then
        log_warn "argon2 command not found, using openssl alternative (less secure)"
        log_info "Install argon2: sudo apt install argon2"
        echo ""

        read -s -p "Enter password: " password
        echo ""
        local salt hash
        salt=$(generate_secure_string 16) # Use crypto lib function
        hash=$(echo -n "$password" | openssl dgst -sha256 -binary | openssl base64) # Simple hash, NOT bcrypt
        echo ""
        log_info "Basic SHA256 hash (NOT RECOMMENDED for production):"
        echo "$hash"
        echo ""
        log_warn "Use a proper bcrypt generator online for production:"
        log_info "https://bcrypt-generator.com/"
        log_info "(Or install 'argon2' package for local generation)"
    else
        read -s -p "Enter password: " password
        echo ""
        read -s -p "Confirm password: " password_confirm
        echo ""
        if [[ "$password" != "$password_confirm" ]]; then
            log_error "Passwords do not match."
            return 1
        fi

        local salt hash
        # Use crypto lib function for salt
        salt=$(generate_secure_string 32)
        # Standard parameters for Argon2id
        hash=$(echo -n "$password" | argon2 "$salt" -e -id -k 65536 -t 3 -p 4)
        echo ""
        log_success "Argon2id hash generated (suitable for Caddy basicauth):"
        echo "$hash"
        echo ""
        log_info "Copy this hash to your secrets file as admin_basic_auth_hash"
    fi

    echo ""
}

# --- Test Secrets Access ---
test_secrets_access() {
    log_info "Testing secrets access..."

    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_error "Secrets file not found: $SECRETS_FILE"
        return 1
    fi

    # Test decryption using library function, explicitly pass key for test clarity
    log_info "Attempting decryption using key: $AGE_KEY_FILE..."
    if sops_decrypt "$SECRETS_FILE" "/dev/null" "$AGE_KEY_FILE" >/dev/null 2>&1; then
        log_success "Secrets file can be decrypted using the current key."

        # Test individual secret access using direct decryption and jq
        local decrypted_json
        decrypted_json=$(sops_decrypt "$SECRETS_FILE" "" "$AGE_KEY_FILE" | jq .) || {
             log_error "Failed to parse decrypted JSON content."
             return 1
        }


        local test_secrets=("admin_token" "backup_passphrase" "ddclient_api_token" "fail2ban_api_token")
        local accessible_secrets=0
        local missing_secrets=0
        local placeholder_secrets=0

        log_info "Checking configuration status of core secrets:"
        for secret in "${test_secrets[@]}"; do
             local value
             value=$(echo "$decrypted_json" | jq -r --arg key "$secret" '.[$key] // ""')
             if [[ -n "$value" ]] && [[ "$value" != "null" ]] && [[ "$value" != CHANGE_ME* ]]; then
                ((accessible_secrets++))
                log_success "  ✓ '$secret' is accessible and configured."
             elif [[ -n "$value" ]] && [[ "$value" == CHANGE_ME* ]]; then
                 log_warn "  ✗ '$secret' has a placeholder value (e.g., CHANGE_ME...)."
                 ((placeholder_secrets++))
             else
                 log_warn "  ✗ '$secret' not found in the secrets file."
                 ((missing_secrets++))
             fi
        done

        echo ""
        if [[ $missing_secrets -eq 0 && $placeholder_secrets -eq 0 ]]; then
            log_success "All core secrets are accessible and appear configured correctly."
            return 0
        else
            log_warn "Found $placeholder_secrets placeholder value(s) and $missing_secrets missing secret(s)."
            log_info "Use option '1) Edit secrets' to configure them."
            return 1 # Return error if not fully configured
        fi

    else
        log_error "Cannot decrypt secrets file using key: $AGE_KEY_FILE"
        log_info "This indicates a key mismatch or corrupted file."
        return 1
    fi
}

# --- Main Execution ---
main() {
    log_info "VaultWarden Secrets Manager"

    # Check prerequisites first
    check_prerequisites || exit 1

    # Handle direct flags first
    if [[ "$INIT_MODE" == "true" ]]; then
        init_secrets
        exit $?
    elif [[ "$SHOW_MODE" == "true" ]]; then
        show_secrets
        exit $?
    elif [[ "$TEST_MODE" == "true" ]]; then
        test_secrets_access
        exit $?
    fi


    # If no direct flag, show menu

    # Check if secrets file exists, offer to create it if not
    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_warn "No secrets file found ($SECRETS_FILE)"
        read -p "Create new secrets file from template? (Y/n): " create_new
        if [[ ! "$create_new" =~ ^[Nn]$ ]]; then
            init_secrets || exit 1
            echo ""
            log_info "Now opening for editing..."
            sleep 1 # Brief pause before edit
            edit_secrets
            exit $?
        else
            log_info "Cancelled. Run './edit-secrets.sh --init' to create the file manually."
            exit 0
        fi
    fi

    # Show menu for existing file
    echo ""
    echo "What would you like to do?"
    echo "1) Edit secrets"
    echo "2) Generate password hash (for admin_basic_auth_hash)"
    echo "3) Show current secrets (use caution!)"
    echo "4) Test secrets access & configuration"
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

    # Capture exit status from chosen function
    local exit_status=$?
    # Ensure Makefile sees the error if a function fails
    exit $exit_status
}

main "$@"

