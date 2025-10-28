#!/usr/bin/env bash
# edit-secrets.sh - Simplified secrets management with library integration
# Uses centralized library functions
# Added permission checks and explicit key path for SOPS edit
# Changed edit command to rely on .sops.yaml
# Added SOPS_AGE_KEY_FILE export
# Explicitly request JSON output for jq parsing in test

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
# --- START FIX: Export full key path ---
export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/$AGE_KEY_FILE"
# --- END FIX ---


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
    Uses the key defined in secrets/keys/age-key.txt via SOPS_AGE_KEY_FILE env var.

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
    # Ensure jq is installed for testing
    require_commands age "$EDITOR" jq || return 1


    # Check SOPS availability using library function
    if ! check_sops_available; then
        log_error "SOPS command not found"
        log_info "SOPS should have been installed during setup."
        log_info "Try running setup again or install manually."
        return 1
    fi

    # Check Age key using library function (checks existence and permissions 600)
    # Use the exported full path
    if ! check_age_key "$SOPS_AGE_KEY_FILE"; then
        log_error "Age private key not found or has incorrect permissions: $SOPS_AGE_KEY_FILE"
        log_info "Ensure the file exists and has permissions 600 (rw-------)."
        log_info "If the key is missing, setup may need to be rerun (this might reset secrets)."
        return 1
    fi

    # Check SOPS config file existence (still useful for encryption rules)
    if [[ ! -f "$SOPS_CONFIG_FILE" ]]; then
        log_warn "SOPS configuration file ($SOPS_CONFIG_FILE) not found."
        log_info "Relying solely on SOPS_AGE_KEY_FILE environment variable."
        # Don't fail here, as SOPS_AGE_KEY_FILE should override
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
ddclient_api_token: CHANGE_ME_DNS_TOKEN

# Cloudflare API token for Fail2Ban/Caddy (Permissions: Zone:Firewall Services:Edit)
fail2ban_api_token: CHANGE_ME_FIREWALL_TOKEN
EOF

    log_success "Template secrets file created"
    log_info "Now encrypting with SOPS (using SOPS_AGE_KEY_FILE)..."

    # Encrypt the file using SOPS. SOPS_AGE_KEY_FILE should ensure the correct key is used.
    # Specify input type explicitly during encryption
    if sops --input-type yaml --encrypt --in-place "$SECRETS_FILE"; then
        log_success "Secrets file encrypted successfully using key $SOPS_AGE_KEY_FILE"
        secure_file "$SECRETS_FILE" 600
    else
        log_error "Failed to encrypt secrets file using key $SOPS_AGE_KEY_FILE"
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
    echo "=== DECRYPTED SECRETS (using key $SOPS_AGE_KEY_FILE) ==="
    # Use library function to decrypt, relies on SOPS_AGE_KEY_FILE now
    # Request YAML output for better readability
    if sops_decrypt "$SECRETS_FILE" "" "yaml"; then # Request YAML output type
        echo "======================================================"
        echo ""
        log_warn "Remember to keep these values secure!"
    else
        log_error "Failed to decrypt secrets file using key $SOPS_AGE_KEY_FILE"
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
    if [[ ! -r "$SOPS_AGE_KEY_FILE" ]]; then # Check the exported full path
        log_error "Cannot read Age key file: $SOPS_AGE_KEY_FILE"
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
     # Config file check is now less critical but still good practice
     if [[ ! -r "$SOPS_CONFIG_FILE" ]]; then
        log_warn "Cannot read SOPS config file: $SOPS_CONFIG_FILE. Relying on SOPS_AGE_KEY_FILE."
    fi


    # Check if file is encrypted using library function
    if ! is_sops_encrypted "$SECRETS_FILE"; then
        log_error "Secrets file exists but does not appear to be encrypted with SOPS"
        log_info "Cannot safely edit. If this is unexpected, check the file content."
        return 1
    fi

    # Test decryption using SOPS_AGE_KEY_FILE (as a sanity check before editing)
    log_debug "Performing pre-edit decryption test using key $SOPS_AGE_KEY_FILE..."
    # The sops_decrypt function should now implicitly use SOPS_AGE_KEY_FILE
    if ! sops_decrypt "$SECRETS_FILE" "/dev/null" >/dev/null 2>&1; then
        log_error "Pre-edit decryption test failed using key specified by SOPS_AGE_KEY_FILE ($SOPS_AGE_KEY_FILE)"
        log_info "This indicates a key mismatch or corrupted file. Cannot proceed with edit."
        return 1
    fi
    log_success "Pre-edit decryption test passed."


    log_info "Using editor: $EDITOR"
    log_info "Using Age key file: $SOPS_AGE_KEY_FILE (via environment variable)"
    log_info "The file will be automatically re-encrypted when you save and exit."
    echo ""

    # Use SOPS to edit the file directly. SOPS_AGE_KEY_FILE should ensure the correct key is used.
    local sops_command="sops \"$SECRETS_FILE\""
    log_debug "Executing SOPS edit command: EDITOR=\"$EDITOR\" $sops_command"
    # SOPS_AGE_KEY_FILE is already exported for the sops command
    if EDITOR="$EDITOR" sops "$SECRETS_FILE"; then
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
        log_info "If SOPS reported an error, check its output for details (e.g., key issues)."
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

    # Test decryption using library function, relies on SOPS_AGE_KEY_FILE
    log_info "Attempting decryption using key specified by SOPS_AGE_KEY_FILE ($SOPS_AGE_KEY_FILE)..."
    # The sops_decrypt function in lib/crypto.sh needs modification to accept output type
    # For now, call sops directly for the test to ensure JSON output for jq
    local decrypted_json exit_status
    log_debug "Running: sops --decrypt --output-type json \"$SECRETS_FILE\""
    decrypted_json=$(sops --decrypt --output-type json "$SECRETS_FILE" 2>&1)
    exit_status=$?

    if [[ $exit_status -eq 0 ]]; then
        log_success "Secrets file can be decrypted using the current key."

        # Test parsing with jq
        log_debug "Testing JSON parsing with jq..."
        echo "$decrypted_json" | jq . > /dev/null 2>&1
        local jq_status=$?
        if [[ $jq_status -ne 0 ]]; then
             log_error "Failed to parse decrypted JSON content with jq."
             log_debug "Decrypted content was: $decrypted_json"
             return 1
        fi
        log_success "Decrypted content parsed successfully as JSON."

        # Test individual secret access using direct decryption and jq
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
        log_error "Cannot decrypt secrets file using key specified by SOPS_AGE_KEY_FILE ($SOPS_AGE_KEY_FILE)"
        log_error "SOPS Output: $decrypted_json"
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

# Make sure SOPS_AGE_KEY_FILE is exported before main runs
export SOPS_AGE_KEY_FILE
main "$@"

