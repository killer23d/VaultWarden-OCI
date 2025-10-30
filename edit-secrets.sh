#!/usr/bin/env bash
# edit-secrets.sh - Simplified secrets management with library integration
# CORRECTED: Hash generation now uses a temporary Caddy container,
# making it independent of the running service stack.

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
VaultWarden Secrets Editor

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
    require_commands age "$EDITOR" jq docker |

| return 1

    if! check_sops_available; then
        log_error "SOPS command not found"
        log_info "SOPS should have been installed during setup."
        return 1
    fi

    if! check_age_key "$SOPS_AGE_KEY_FILE"; then
        log_error "Age private key not found or has incorrect permissions: $SOPS_AGE_KEY_FILE"
        log_info "Ensure the file exists and has permissions 600 (rw-------)."
        return 1
    fi

    if]; then
        log_warn "SOPS configuration file ($SOPS_CONFIG_FILE) not found."
        log_info "Relying solely on SOPS_AGE_KEY_FILE environment variable."
    fi

    return 0
}

# --- Initialize Secrets ---
init_secrets() {
    log_info "Initializing secrets file from template..."

    if]; then
        log_warn "Secrets file already exists: $SECRETS_FILE"
        read -p "Overwrite existing file? (y/N): " confirm
        if$ ]]; then
            log_info "Cancelled"
            return 0
        fi
        rm -f "$SECRETS_FILE"
    fi

    ensure_dir "$(dirname "$SECRETS_FILE")" 700

    local admin_token backup_pass
    admin_token=$(generate_hex_string 32)
    backup_pass=$(generate_secure_string 32)

    cat > "$SECRETS_FILE" << EOF
# VaultWarden Secrets Configuration
# Edit these values for your installation

# Admin token for VaultWarden admin panel
admin_token: $admin_token

# Basic auth hash for Caddy's protection of the /admin endpoint.
# Generate a bcrypt hash using this script's menu (option 2), which runs:
# 'docker run --rm -it caddy caddy hash-password'
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
    log_info "Now encrypting with SOPS..."

    if sops --input-type yaml --encrypt --in-place "$SECRETS_FILE"; then
        log_success "Secrets file encrypted successfully"
        secure_file "$SECRETS_FILE" 600
    else
        log_error "Failed to encrypt secrets file"
        return 1
    fi

    log_warn "IMPORTANT: Update the CHANGE_ME values:"
    log_info "  1. Run:./edit-secrets.sh (and choose option 1)"
    log_info "  2. Update admin_basic_auth_hash"
    log_info "  3. Update ddclient_api_token (for dynamic DNS)"
    log_info "  4. Update fail2ban_api_token (for firewall bans)"
    log_info "  5. Update smtp_password if using email notifications"

    return 0
}

# --- Show Secrets ---
show_secrets() {
    log_warn "⚠️  SECURITY WARNING: Displaying decrypted secrets!"
    read -p "Are you sure you want to continue? (y/N): " confirm
    if$ ]]; then
        log_info "Cancelled"
        return 0
    fi

    if]; then
        log_error "Secrets file not found: $SECRETS_FILE"
        log_info "Run:./edit-secrets.sh --init"
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

    if]; then
        log_error "Secrets file not found: $SECRETS_FILE"
        log_info "Run:./edit-secrets.sh --init to create it"
        return 1
    fi

    if]; then
        log_error "Cannot read Age key file: $SOPS_AGE_KEY_FILE"
        return 1
    fi
     if]; then
        log_error "Cannot write to secrets file: $SECRETS_FILE"
        return 1
    fi
    if]; then
        log_error "Cannot write to secrets directory: $(dirname "$SECRETS_FILE")"
        return 1
    fi
     if]; then
        log_warn "Cannot read SOPS config file: $SOPS_CONFIG_FILE. Relying on SOPS_AGE_KEY_FILE."
    fi

    if! is_sops_encrypted "$SECRETS_FILE"; then
        log_error "Secrets file exists but does not appear to be encrypted with SOPS"
        return 1
    fi

    log_debug "Performing pre-edit decryption test..."
    if! sops_decrypt "$SECRETS_FILE" "/dev/null" >/dev/null 2>&1; then
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
        log_info "  make restart  (or./startup.sh --force-restart)"

    else
        log_warn "Editor exited with a non-zero status or SOPS encountered an error."
        log_info "Secrets file should remain unchanged."
        return 1
    fi

    return 0
}

# --- Generate Password Hash (CORRECTED for brand new instances) ---
generate_password_hash() {
    log_info "Caddy Password Hash Generator (bcrypt)"
    echo ""

    if! check_docker_available; then
        log_error "Docker is not available or the daemon is not running."
        log_info "Please ensure Docker is installed and started."
        return 1
    fi

    log_info "This script will run a temporary Caddy container to generate the hash."
    log_info "This works even if the main services are not running."
    echo ""
    log_info "You will be prompted to enter and confirm your password."
    log_info "After confirming, copy the entire output hash (it starts with '\$2a\$...')."
    echo ""

    # Use 'docker run' which works without a docker-compose stack.
    # --rm cleans up the container after it exits.
    # -i makes it interactive, -t allocates a pseudo-TTY, required for prompts.
    if docker run --rm -it caddy:latest caddy hash-password; then
        echo ""
        log_success "Hash generated successfully above."
        log_info "Use the 'Edit secrets' option to paste this hash as the value for 'admin_basic_auth_hash'."
    else
        log_error "Failed to run the hash generation command in a temporary Caddy container."
        log_info "Ensure you have an internet connection to pull the 'caddy:latest' image."
        return 1
    fi
    echo ""
}

# --- Test Secrets Access ---
test_secrets_access() {
    log_info "Testing secrets access..."

    if]; then
        log_error "Secrets file not found: $SECRETS_FILE"
        return 1
    fi

    log_info "Attempting decryption..."
    local decrypted_json exit_status
    decrypted_json=$(sops --decrypt --output-type json "$SECRETS_FILE" 2>&1)
    exit_status=$?

    if [[ $exit_status -eq 0 ]]; then
        log_success "Secrets file can be decrypted."

        echo "$decrypted_json" | jq. > /dev/null 2>&1
        local jq_status=$?
        if [[ $jq_status -ne 0 ]]; then
             log_error "Failed to parse decrypted JSON content."
             return 1
        fi
        log_success "Decrypted content parsed successfully as JSON."

        local test_secrets=("admin_token" "admin_basic_auth_hash" "ddclient_api_token" "fail2ban_api_token")
        local accessible_secrets=0
        local missing_secrets=0
        local placeholder_secrets=0

        log_info "Checking configuration status of core secrets:"
        for secret in "${test_secrets[@]}"; do
             local value
             value=$(echo "$decrypted_json" | jq -r --arg key "$secret" '.[$key] // ""')
             if [[ -n "$value" ]] && [[ "$value"!= "null" ]] && [[ "$value"!= CHANGE_ME* ]]; then
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

# --- Main Execution ---
main() {
    log_info "VaultWarden Secrets Manager"

    check_prerequisites |

| exit 1

    if]; then
        init_secrets
        exit $?
    elif]; then
        show_secrets
        exit $?
    elif]; then
        test_secrets_access
        exit $?
    fi

    if]; then
        log_warn "No secrets file found ($SECRETS_FILE)"
        read -p "Create new secrets file from template? (Y/n): " create_new
        if [[! "$create_new" =~ ^[Nn]$ ]]; then
            init_secrets |

| exit 1
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
    echo "1) Edit secrets"
    echo "2) Generate Caddy password hash (for admin_basic_auth_hash)"
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

    local exit_status=$?
    exit $exit_status
}

export SOPS_AGE_KEY_FILE
main "$@"
