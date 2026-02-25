#!/usr/bin/env bash
# lib/secrets.sh - Shared secrets management functions
# Used by edit-secrets.sh and setup-secrets.sh

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This library should be sourced, not executed directly"
    exit 1
fi

# Source crypto library for hash functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/crypto.sh"

# Configuration
SECRETS_FILE="${SECRETS_FILE:-secrets/secrets.yaml}"
AGE_KEY_FILE="${AGE_KEY_FILE:-secrets/keys/age-key.txt}"
SECRETS_BACKUP_DIR="${SECRETS_BACKUP_DIR:-secrets}"

# ---------------------------------------------------------------------------
# ensure_sops_env
# ---------------------------------------------------------------------------
ensure_sops_env() {
    local age_key="${1:-$AGE_KEY_FILE}"

    # Resolve to absolute path when relative
    if [[ ! "$age_key" = /* ]]; then
        age_key="${PROJECT_ROOT:-$(pwd)}/$age_key"
    fi

    if [[ ! -f "$age_key" ]]; then
        log_error "Age key not found: $age_key"
        return 1
    fi

    export SOPS_AGE_KEY_FILE="$age_key"
    export SOPS_CONFIG="${PROJECT_ROOT:-$(pwd)}/.sops.yaml"
    log_debug "SOPS env set: key=$SOPS_AGE_KEY_FILE  config=$SOPS_CONFIG"
    return 0
}

setup_secrets_environment() { ensure_sops_env "${1:-}"; }

cleanup_secrets_environment() {
    log_debug "cleanup_secrets_environment: no-op (SOPS vars persist for script lifetime)"
    return 0
}

# ---------------------------------------------------------------------------
# Existence / structure checks
# ---------------------------------------------------------------------------
secrets_file_exists() {
    [[ -f "$SECRETS_FILE" ]]
}

validate_secrets_decryption() {
    local secrets_file="${1:-$SECRETS_FILE}"
    if [[ ! -f "$secrets_file" ]]; then
        log_error "Secrets file not found: $secrets_file"
        return 1
    fi
    if ! ensure_sops_env; then return 1; fi
    if ! sops -d "$secrets_file" >/dev/null 2>&1; then
        log_error "Cannot decrypt secrets file"
        return 1
    fi
    return 0
}

validate_secrets_yaml() {
    local secrets_file="${1:-$SECRETS_FILE}"
    if ! ensure_sops_env; then return 1; fi
    if ! sops -d "$secrets_file" | python3 -c "import yaml, sys; yaml.safe_load(sys.stdin)" 2>/dev/null; then
        log_warn "Secrets file contains invalid YAML"
        return 1
    fi
    return 0
}

validate_required_secrets() {
    local secrets_file="${1:-$SECRETS_FILE}"
    local required_secrets=("admin_token" "admin_basic_auth_hash" "caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token")
    if ! ensure_sops_env; then return 1; fi
    local missing_secrets=()
    for secret in "${required_secrets[@]}"; do
        if ! sops -d --extract "[\"$secret\"]" "$secrets_file" >/dev/null 2>&1; then
            missing_secrets+=("$secret")
        fi
    done
    if [[ ${#missing_secrets[@]} -gt 0 ]]; then
        log_warn "Missing required secrets: ${missing_secrets[*]}"
        return 1
    fi
    return 0
}

check_placeholder_values() {
    local secrets_file="${1:-$SECRETS_FILE}"
    local secrets_to_check=("admin_token" "admin_basic_auth_hash" "caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token")
    if ! ensure_sops_env; then return 1; fi
    local placeholder_secrets=()
    for secret in "${secrets_to_check[@]}"; do
        local value
        if value=$(sops -d --extract "[\"$secret\"]" "$secrets_file" 2>/dev/null); then
            if [[ "$value" =~ ^(CHANGE_ME|PLACEHOLDER_NOT_CONFIGURED) ]] || [[ -z "$value" ]]; then
                placeholder_secrets+=("$secret")
            fi
        fi
    done
    if [[ ${#placeholder_secrets[@]} -gt 0 ]]; then
        log_warn "Secrets with placeholders: ${placeholder_secrets[*]}"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# list_secret_keys
# ---------------------------------------------------------------------------
list_secret_keys() {
    local secrets_file="${1:-$SECRETS_FILE}"
    if [[ ! -f "$secrets_file" ]]; then
        log_error "Secrets file not found: $secrets_file"
        return 1
    fi
    if ! ensure_sops_env; then return 1; fi
    local keys
    keys=$(sops -d "$secrets_file" 2>/dev/null \
        | python3 -c "import yaml, sys; [print(k) for k in yaml.safe_load(sys.stdin).keys()]" 2>/dev/null)
    if [[ -z "$keys" ]]; then
        log_error "Could not list keys - decryption or parse failure"
        return 1
    fi
    echo "$keys"
    return 0
}

# ---------------------------------------------------------------------------
# Backup helpers
# ---------------------------------------------------------------------------
create_secrets_backup() {
    local secrets_file="${1:-$SECRETS_FILE}"
    local backup_dir="${2:-$SECRETS_BACKUP_DIR}"
    if [[ ! -f "$secrets_file" ]]; then
        log_debug "No secrets file to backup"
        return 0
    fi
    local backup_file="$backup_dir/secrets.yaml.backup-$(date +%Y%m%d-%H%M%S)"
    log_info "Creating backup: $(basename "$backup_file")"
    if ! cp "$secrets_file" "$backup_file"; then
        log_error "Failed to create backup"
        return 1
    fi
    chmod 600 "$backup_file"
    log_success "Backup created"
    return 0
}

cleanup_old_secret_backups() {
    local backup_dir="${1:-$SECRETS_BACKUP_DIR}"
    local keep_count="${2:-5}"
    local old_backups
    old_backups=$(find "$backup_dir" -name "secrets.yaml.backup-*" -type f 2>/dev/null \
        | sort -r | tail -n +$((keep_count + 1)))
    if [[ -n "$old_backups" ]]; then
        echo "$old_backups" | xargs rm -f
        log_debug "Cleaned up old secrets backups (keeping last $keep_count)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Cloudflare token validation
# ---------------------------------------------------------------------------
validate_cloudflare_token() {
    local token="$1"
    local token_type="$2"
    local zone_id="${3:-}"
    if [[ -z "$zone_id" ]]; then
        zone_id=$(get_config_value "CLOUDFLARE_ZONE_ID" "")
    fi
    if [[ -z "$zone_id" ]] || [[ "$zone_id" == "your_cloudflare_zone_id_here" ]]; then
        log_debug "Zone ID not configured - skipping validation"
        return 0
    fi
    local endpoint
    case "$token_type" in
        dns)      endpoint="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?per_page=1" ;;
        firewall) endpoint="https://api.cloudflare.com/client/v4/zones/$zone_id/firewall/access_rules/rules?per_page=1" ;;
        *)        log_error "Invalid token type: $token_type"; return 1 ;;
    esac
    if curl -sf --max-time 10 -H "Authorization: Bearer $token" "$endpoint" \
        | jq -e '.success == true' >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Interactive helpers
# ---------------------------------------------------------------------------
prompt_password_with_confirmation() {
    local prompt_text="$1"
    local min_length="${2:-12}"
    local password password_confirm
    while true; do
        read -s -p "$prompt_text: " password
        echo ""
        if [[ -z "$password" ]]; then
            log_error "Password cannot be empty"
            continue
        fi
        if [[ ${#password} -lt $min_length ]]; then
            log_error "Password must be at least $min_length characters"
            continue
        fi
        read -s -p "Confirm password: " password_confirm
        echo ""
        if [[ "$password" != "$password_confirm" ]]; then
            log_error "Passwords don't match"
            continue
        fi
        break
    done
    echo "$password"
    return 0
}

# ---------------------------------------------------------------------------
# File permission helper
# ---------------------------------------------------------------------------
secure_secrets_file() {
    local secrets_file="${1:-$SECRETS_FILE}"
    if [[ ! -f "$secrets_file" ]]; then return 0; fi
    chmod 600 "$secrets_file"
    local real_user
    real_user=$(get_real_user)
    chown "$real_user:$real_user" "$secrets_file"
    return 0
}

# ---------------------------------------------------------------------------
# Recovery Kit Generation
# ---------------------------------------------------------------------------
generate_recovery_kit() {
    local output_file="$1"
    local age_key="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"
    local secrets_file="${SECRETS_FILE:-secrets/secrets.yaml}"
    local env_file="${PROJECT_ROOT:-.}/.env"

    if [[ ! -f "$age_key" ]]; then
        log_error "Age key not found: $age_key"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq is required to generate the recovery kit. Please install it."
        return 1
    fi

    log_info "Collecting recovery data..."

    # 1. Metadata
    local hostname_val
    hostname_val=$(hostname)
    local date_val
    date_val=$(date)

    # 2. Key Data
    local pub_key
    if ! pub_key=$(age-keygen -y "$age_key" 2>/dev/null); then
        log_error "Failed to derive Age public key"
        return 1
    fi
    local priv_key
    priv_key=$(cat "$age_key")

    # 3. Config Data
    local domain="Not Configured"
    local admin_email="Not Configured"
    if [[ -f "$env_file" ]]; then
        domain=$(grep "^DOMAIN=" "$env_file" | cut -d= -f2 || echo "Not Configured")
        admin_email=$(grep "^ADMIN_EMAIL=" "$env_file" | cut -d= -f2 || echo "Not Configured")
    fi

    # 4. Decrypt Secrets
    log_info "Decrypting secrets for export..."
    local vw_admin_hash="Not Set"
    local caddy_hash="Not Set"
    local smtp_pass="Not Set"
    local backup_pass="Not Set"
    local cf_dns="Not Set"
    local cf_fw="Not Set"
    local push_id="Not Set"
    local push_key="Not Set"

    if [[ -f "$secrets_file" ]]; then
        if ! ensure_sops_env; then return 1; fi

        local secrets_json
        if secrets_json=$(sops -d --output-type json "$secrets_file" 2>/dev/null); then
            vw_admin_hash=$(echo "$secrets_json" | jq -r '.admin_token // "Not Set"')
            caddy_hash=$(echo "$secrets_json" | jq -r '.admin_basic_auth_hash // "Not Set"')
            smtp_pass=$(echo "$secrets_json" | jq -r '.smtp_password // "Not Set"')
            backup_pass=$(echo "$secrets_json" | jq -r '.backup_passphrase // "Not Set"')
            cf_dns=$(echo "$secrets_json" | jq -r '.caddy_cloudflare_dns_token // "Not Set"')
            cf_fw=$(echo "$secrets_json" | jq -r '.fail2ban_cloudflare_firewall_token // "Not Set"')
            push_id=$(echo "$secrets_json" | jq -r '.push_installation_id // "Not Set"')
            push_key=$(echo "$secrets_json" | jq -r '.push_installation_key // "Not Set"')
        else
            log_error "Failed to decrypt secrets.yaml. Ensure sops is working."
            return 1
        fi
    else
        log_warn "secrets.yaml not found"
    fi

    # 5. Generate Content
    # FIX: Pre-create the output file with 600 permissions BEFORE any plaintext
    # is written. Without this, the shell creates the file at the current umask
    # (typically 022 → 644) and it remains world-readable until the chmod 600
    # at the end of this function — a window that exposes the Age private key
    # and all decrypted secrets to any other process on the system.
    if ! install -m 600 /dev/null "$output_file"; then
        log_error "Failed to create output file with secure permissions: $output_file"
        return 1
    fi

    cat > "$output_file" << EOF
██████╗ ███████╗ ██████╗ ██████╗ ██╗   ██╗███████╗██████╗ ██╗   ██╗
██╔══██╗██╔════╝██╔════╝██╔═══██╗██║   ██║██╔════╝██╔══██╗╚██╗ ██╔╝
██████╔╝█████╗  ██║     ██║   ██║██║   ██║█████╗  ██████╔╝ ╚████╔╝ 
██╔══██╗██╔══╝  ██║     ██║   ██║╚██╗ ██╔╝██╔══╝  ██╔══██╗  ╚██╔╝  
██║  ██║███████╗╚██████╗╚██████╔╝ ╚████╔╝ ███████╗██║  ██║   ██║   
╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝   ╚═══╝  ╚══════╝╚═╝  ╚═╝   ╚═╝   
                                                                   
██╗  ██╗██╗████████╗
██║ ██╔╝██║╚══██╔══╝
█████╔╝ ██║   ██║   
██╔═██╗ ██║   ██║   
██║  ██╗██║   ██║   
╚═╝  ╚═╝╚═╝   ╚═╝   

══════════════════════════════════════════════════════════════════════════════
                            🚨 CRITICAL SECURITY DOCUMENT 🚨
══════════════════════════════════════════════════════════════════════════════
Created: $date_val
Server:  $hostname_val
Domain:  $domain

WARNING: This file contains highly sensitive UNENCRYPTED secrets.
1. Save this to your Password Manager (Secure Note) IMMEDIATELY.
2. Print a physical copy for your fireproof safe (optional).
3. DELETE THIS FILE from the server immediately after saving.

══════════════════════════════════════════════════════════════════════════════
SECTION 1: ENCRYPTION KEYS (THE MOST IMPORTANT PART)
══════════════════════════════════════════════════════════════════════════════
If you lose this key, your backups are FOREVER USELESS.

[AGE PRIVATE KEY]
$priv_key

[AGE PUBLIC KEY]
$pub_key

══════════════════════════════════════════════════════════════════════════════
SECTION 2: SERVER SECRETS (DECRYPTED)
══════════════════════════════════════════════════════════════════════════════

[SYSTEM CREDENTIALS]
Backup Encryption Passphrase:
$backup_pass

SMTP Password (Email):
$smtp_pass

Cloudflare DNS Token:
$cf_dns

Cloudflare Firewall Token:
$cf_fw

[PUSH NOTIFICATIONS]
Installation ID:  $push_id
Installation Key: $push_key

[ADMIN ACCESS]
Admin Email: $admin_email

VaultWarden Admin Password Hash (Argon2id):
$vw_admin_hash
(Note: Original password cannot be recovered from hash. Reset if lost.)

Caddy Basic Auth Hash (Bcrypt):
$caddy_hash
(Note: Original password cannot be recovered from hash. Reset if lost.)

══════════════════════════════════════════════════════════════════════════════
SECTION 3: DISASTER RECOVERY & MIGRATION CHECKLIST
══════════════════════════════════════════════════════════════════════════════

TO RESTORE THIS SERVER ON NEW HARDWARE:

1. PREPARATION
   [ ] Install Git, Docker, and SOPS on new server.
   [ ] Clone the repository:
       git clone https://github.com/killer23d/VaultWarden-OCI.git
   [ ] Run setup:
       cd VaultWarden-OCI
       ./setup.sh --domain $domain --email $admin_email

2. RESTORE KEYS
   [ ] Create key directory:
       mkdir -p secrets/keys
   [ ] Restore Age Key:
       Paste the [AGE PRIVATE KEY] above into: secrets/keys/age-key.txt
   [ ] Set permissions:
       chmod 600 secrets/keys/age-key.txt

3. RESTORE DATA (Choose Option A or B)

   OPTION A: From Remote Backup (Rclone/S3)
   [ ] Configure Rclone:
       rclone config
   [ ] Download latest backup:
       rclone copy remote:bucket/backup.tar.gz.age ./backups/
   [ ] Run Restore:
       ./restore.sh --type emergency

   OPTION B: From Secrets Above (Manual Rebuild)
   [ ] Run secrets setup:
       ./setup-secrets.sh
   [ ] Manually enter the values from [SECTION 2] when prompted.

4. FINALIZATION
   [ ] Start services:
       make up
   [ ] Check health:
       ./health.sh

══════════════════════════════════════════════════════════════════════════════
END OF RECOVERY KIT
══════════════════════════════════════════════════════════════════════════════
EOF

    chmod 600 "$output_file"
}

offer_recovery_kit_export() {
    local auto_export="${1:-false}"
    local output_file="$HOME/vaultwarden-recovery-kit-$(date +%Y%m%d%H%M%S).txt"

    if [[ "$auto_export" == "true" ]]; then
        log_info "Exporting recovery kit (--export-recovery-kit specified)..."
        if generate_recovery_kit "$output_file"; then
            log_success "Recovery Kit created: $output_file"
            echo ""
            log_warn "⚠️  ACTION REQUIRED:"
            echo "1. Copy content to password manager."
            echo "2. Delete local file: rm $output_file"
            echo ""
        else
            log_error "Failed to generate recovery kit"
            return 1
        fi
        return 0
    fi

    # Interactive prompt
    echo ""
    read -p "Export a plaintext Recovery Kit? (yes/no): " export_kit
    if [[ "$export_kit" == "yes" ]]; then
        if generate_recovery_kit "$output_file"; then
            log_success "Recovery Kit created: $output_file"
            echo ""
            log_warn "⚠️  ACTION REQUIRED:"
            echo "1. Copy content to password manager."
            echo "2. Delete local file: rm $output_file"
            echo ""
        else
            log_error "Failed to generate recovery kit"
            return 1
        fi
    fi
}
