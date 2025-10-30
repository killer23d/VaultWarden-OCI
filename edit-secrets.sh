#!/usr/bin/env bash
# edit-secrets.sh - Enhanced secrets management with caddy-cloudflare support
# UPDATED: Added separate DNS/Firewall tokens, bcrypt vs Argon2 handling

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/docker.sh"

# --- Configuration ---
EDITOR="${EDITOR:-nano}"
SECRETS_FILE="secrets/secrets.yaml"
AGE_KEY_FILE="secrets/keys/age-key.txt"
SOPS_CONFIG_FILE=".sops.yaml"
export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/$AGE_KEY_FILE"

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden Secrets Editor - Enhanced for Caddy-Cloudflare

USAGE:
    ./edit-secrets.sh

OPTIONS:
    --editor EDITOR  Editor to use (default: nano, or $EDITOR)
    --init          Initialize secrets file with templates
    --show          Show decrypted secrets (careful!)
    --test          Test if secrets can be decrypted
    --help          Show this help

DESCRIPTION:
    Safely edit encrypted secrets using SOPS and Age encryption.
    Enhanced for caddy-cloudflare with separate DNS/Firewall tokens.
    
    PASSWORD HASH TYPES:
    - VaultWarden admin_token: Plain text (VaultWarden hashes to Argon2)
    - Caddy admin_basic_auth_hash: bcrypt format (use menu option 2)

EXAMPLES:
    ./edit-secrets.sh           # Edit secrets with menu
    ./edit-secrets.sh --editor vim   # Use vim as editor
    ./edit-secrets.sh --init    # Create new secrets file
    ./edit-secrets.sh --show    # Display current secrets (careful!)
    ./edit-secrets.sh --test    # Check secrets accessibility
EOF
}

# --- Argument Parsing ---
SHOW_MODE=false
INIT_MODE=false
TEST_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --editor) EDITOR="$2"; shift 2 ;;
        --init) INIT_MODE=true; shift ;;
        --show) SHOW_MODE=true; shift ;;
        --test) TEST_MODE=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Validation ---
check_prerequisites() {
    require_commands age "$EDITOR" jq docker || return 1

    if ! check_sops_available; then
        log_error "SOPS command not found"
        log_info "SOPS should have been installed during setup."
        return 1
    fi

    if ! check_age_key "$SOPS_AGE_KEY_FILE"; then
        log_error "Age private key not found or has incorrect permissions: $SOPS_AGE_KEY_FILE"
        log_info "Ensure the file exists and has permissions 600 (rw-------)."
        return 1
    fi

    if [[ ! -f "$SOPS_CONFIG_FILE" ]]; then
        log_warn "SOPS configuration file ($SOPS_CONFIG_FILE) not found."
        log_info "Relying solely on SOPS_AGE_KEY_FILE environment variable."
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
        rm -f "$SECRETS_FILE"
    fi

    ensure_dir "$(dirname "$SECRETS_FILE")" 700

    local admin_token backup_pass
    admin_token=$(generate_secure_string 32)
    backup_pass=$(generate_secure_string 32)

    cat > "$SECRETS_FILE" << EOF
# VaultWarden Secrets Configuration - Enhanced for Caddy-Cloudflare
# IMPORTANT: Different hash types for different services

# VaultWarden admin token (plain text - VaultWarden auto-hashes to Argon2)
admin_token: $admin_token

# Caddy basic_auth hash for /admin endpoint (bcrypt format)
# Generate with: docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password
admin_basic_auth_hash: CHANGE_ME_BCRYPT_HASH

# SMTP password for email notifications
smtp_password: CHANGE_ME_SMTP_PASSWORD

# Backup encryption passphrase
backup_passphrase: $backup_pass

# Push notifications (optional - get ID and Key from bitwarden.com/host)
push_installation_id: CHANGE_ME_OR_LEAVE_EMPTY  
push_installation_key: CHANGE_ME_OR_LEAVE_EMPTY

# Cloudflare DNS API token for caddy-cloudflare (DNS-01 ACME challenges)
# Permissions: Zone:DNS:Edit + Zone:Zone:Read
caddy_cloudflare_dns_token: CHANGE_ME_DNS_TOKEN

# Cloudflare Firewall API token for fail2ban IP blocking
# Permissions: Zone:Firewall Services:Edit
fail2ban_cloudflare_firewall_token: CHANGE_ME_FIREWALL_TOKEN
EOF

    log_success "Template secrets file created"
    log_info "Now encrypting with SOPS..."

    if sops --input-type yaml --encrypt --in-place "$SECRETS_FILE"; then
        log_success "Secrets file encrypted successfully"
        secure_file "$SECRETS_FILE" 600
    else
        log_error "Failed to encrypt secrets file"
        return 1
    fi

    log_warn "IMPORTANT: Update the CHANGE_ME values:"
    log_info "  1. Run: ./edit-secrets.sh (choose option 1)"
    log_info "  2. Generate bcrypt hash with option 2"
    log_info "  3. Update caddy_cloudflare_dns_token"
    log_info "  4. Update fail2ban_cloudflare_firewall_token"
    log_info "  5. Update smtp_password if using email"

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
    if sops_decrypt "$SECRETS_FILE" "" "yaml"; then
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

    # Comprehensive permission checks
    if [[ ! -r "$SOPS_AGE_KEY_FILE" ]]; then
        log_error "Cannot read Age key file: $SOPS_AGE_KEY_FILE"
        return 1
    fi
    if [[ ! -w "$SECRETS_FILE" ]]; then
        log_error "Cannot write to secrets file: $SECRETS_FILE"
        return 1
    fi
    if [[ ! -w "$(dirname "$SECRETS_FILE")" ]]; then
        log_error "Cannot write to secrets directory: $(dirname "$SECRETS_FILE")"
        return 1
    fi
    if [[ -f "$SOPS_CONFIG_FILE" ]] && [[ ! -r "$SOPS_CONFIG_FILE" ]]; then
        log_warn "Cannot read SOPS config file: $SOPS_CONFIG_FILE. Relying on SOPS_AGE_KEY_FILE."
    fi

    if ! is_sops_encrypted "$SECRETS_FILE"; then
        log_error "Secrets file exists but does not appear to be encrypted with SOPS"
        return 1
    fi

    log_debug "Performing pre-edit decryption test..."
    if ! sops_decrypt "$SECRETS_FILE" "/dev/null" >/dev/null 2>&1; then
        log_error "Pre-edit decryption test failed. Cannot proceed with edit."
        return 1
    fi
    log_success "Pre-edit decryption test passed."

    log_info "Using editor: $EDITOR"
    log_info "The file will be automatically re-encrypted when you save and exit."
    echo ""

    if EDITOR="$EDITOR" sops "$SECRETS_FILE"; then
        log_success "Secrets updated successfully"

        if is_sops_encrypted "$SECRETS_FILE"; then
            log_success "Secrets file encryption verified"
        else
            log_error "CRITICAL WARNING: Secrets file may NOT be properly encrypted after editing!"
            return 1
        fi

        secure_file "$SECRETS_FILE" 600

        echo ""
        log_info "To apply changes to running services:"
        log_info "  make restart  (or ./startup.sh --force-restart)"

    else
        log_warn "Editor exited with a non-zero status or SOPS encountered an error."
        log_info "Secrets file should remain unchanged."
        return 1
    fi

    return 0
}

# --- Generate Caddy bcrypt Password Hash ---
generate_caddy_password_hash() {
    log_info "Caddy Password Hash Generator (bcrypt for basic_auth)"
    echo ""
    log_info "This generates a bcrypt hash for Caddy's basic_auth directive."
    log_info "This is DIFFERENT from VaultWarden's admin token (which uses Argon2)."
    echo ""

    if ! check_docker_available; then
        log_error "Docker is not available or the daemon is not running."
        log_info "Please ensure Docker is installed and started."
        return 1
    fi

    log_info "This will run a temporary caddy-cloudflare container to generate the hash."
    log_info "This works even if your main services are not running."
    echo ""
    log_info "You will be prompted to enter and confirm your password."
    log_info "After confirming, copy the entire hash output (starts with '\$2a\$...')."
    echo ""

    # Use caddy-cloudflare image which has the hash-password command
    if docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password; then
        echo ""
        log_success "Bcrypt hash generated successfully above."
        log_info "Use the 'Edit secrets' option to paste this hash as 'admin_basic_auth_hash'."
        echo ""
        log_warn "IMPORTANT: This bcrypt hash is for Caddy basic_auth only."
        log_info "VaultWarden admin_token should remain as plain text (auto-hashed to Argon2)."
    else
        log_error "Failed to run hash generation command."
        log_info "Ensure you have internet connection to pull the caddy-cloudflare image."
        return 1
    fi
    echo ""
}

# --- Generate VaultWarden Admin Token ---
generate_vaultwarden_admin_token() {
    log_info "VaultWarden Admin Token Generator"
    echo ""
    log_info "VaultWarden admin tokens should be stored as PLAIN TEXT in secrets."
    log_info "VaultWarden automatically hashes them to Argon2 format internally."
    echo ""
    
    local new_token
    new_token=$(generate_secure_string 32)
    
    echo "Generated admin token (plain text):"
    echo "======================================"
    echo "$new_token"
    echo "======================================"
    echo ""
    log_info "Use the 'Edit secrets' option to set this as 'admin_token' value."
    log_warn "Store this as plain text - VaultWarden will hash it automatically."
    echo ""
}

# --- Test Secrets Access ---
test_secrets_access() {
    log_info "Testing secrets access..."

    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_error "Secrets file not found: $SECRETS_FILE"
        return 1
    fi

    log_info "Attempting decryption..."
    local decrypted_json exit_status
    decrypted_json=$(sops --decrypt --output-type json "$SECRETS_FILE" 2>&1)
    exit_status=$?

    if [[ $exit_status -eq 0 ]]; then
        log_success "Secrets file can be decrypted."

        echo "$decrypted_json" | jq . > /dev/null 2>&1
        local jq_status=$?
        if [[ $jq_status -ne 0 ]]; then
            log_error "Failed to parse decrypted JSON content."
            return 1
        fi
        log_success "Decrypted content parsed successfully as JSON."

        # Updated test secrets for caddy-cloudflare
        local test_secrets=("admin_token" "admin_basic_auth_hash" "caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token")
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
            return 1
        fi

    else
        log_error "Cannot decrypt secrets file."
        log_error "SOPS Output: $decrypted_json"
        return 1
    fi
}

# --- Generate Docker Secrets Files ---
generate_docker_secrets() {
    log_info "Generating Docker Compose secret files..."
    
    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_error "Secrets file not found: $SECRETS_FILE"
        return 1
    fi

    local secrets_dir="secrets/.docker_secrets"
    ensure_dir "$secrets_dir" 700

    # Decrypt secrets to JSON
    local decrypted_json
    decrypted_json=$(sops --decrypt --output-type json "$SECRETS_FILE" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        log_error "Failed to decrypt secrets file"
        return 1
    fi

    # Extract and write individual secret files
    local secrets_map=(
        "admin_token:admin_token"
        "admin_basic_auth_hash:admin_basic_auth_hash"
        "smtp_password:smtp_password"
        "push_installation_id:push_installation_id"
        "push_installation_key:push_installation_key"
        "caddy_cloudflare_dns_token:caddy_cloudflare_dns_token"
        "fail2ban_cloudflare_firewall_token:fail2ban_cloudflare_firewall_token"
    )

    for mapping in "${secrets_map[@]}"; do
        local yaml_key="${mapping%:*}"
        local file_name="${mapping#*:}"
        local value
        
        value=$(echo "$decrypted_json" | jq -r --arg key "$yaml_key" '.[$key] // ""')
        
        if [[ -n "$value" ]] && [[ "$value" != "null" ]] && [[ "$value" != CHANGE_ME* ]]; then
            echo -n "$value" > "$secrets_dir/$file_name"
            chmod 600 "$secrets_dir/$file_name"
            log_success "Generated: $file_name"
        elif [[ "$value" == CHANGE_ME* ]]; then
            log_warn "Skipped: $file_name (placeholder value)"
        else
            log_warn "Skipped: $file_name (empty/missing value)"
        fi
    done

    log_success "Docker secret files generated in $secrets_dir"
    return 0
}

# --- Main Execution ---
main() {
    log_info "VaultWarden Secrets Manager - Enhanced for Caddy-Cloudflare"

    check_prerequisites || exit 1

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

    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_warn "No secrets file found ($SECRETS_FILE)"
        read -p "Create new secrets file from template? (Y/n): " create_new
        if [[ ! "$create_new" =~ ^[Nn]$ ]]; then
            init_secrets || exit 1
            echo ""
            log_info "Now opening for editing..."
            sleep 1
            edit_secrets
            exit $?
        else
            log_info "Cancelled."
            exit 0
        fi
    fi

    echo ""
    echo "What would you like to do?"
    echo "1) Edit secrets file"
    echo "2) Generate Caddy bcrypt password hash (for admin_basic_auth_hash)"
    echo "3) Generate VaultWarden admin token (plain text)"
    echo "4) Show current secrets (use caution!)"
    echo "5) Test secrets access & configuration"
    echo "6) Generate Docker Compose secret files"
    echo "7) Exit"
    echo ""
    read -p "Choice (1-7): " choice

    case "$choice" in
        1) edit_secrets ;;
        2) generate_caddy_password_hash ;;
        3) generate_vaultwarden_admin_token ;;
        4) show_secrets ;;
        5) test_secrets_access ;;
        6) generate_docker_secrets ;;
        7) log_info "Goodbye"; exit 0 ;;
        *) log_error "Invalid choice"; exit 1 ;;
    esac

    local exit_status=$?
    exit $exit_status
}

export SOPS_AGE_KEY_FILE
main "$@"
