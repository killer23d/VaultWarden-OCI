#!/usr/bin/env bash
# simplified-recovery-kit.sh - Comprehensive Server Recovery Kit
# Generates a single file with ALL credentials, keys, and migration instructions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"

show_help() {
    cat << 'EOF'
VaultWarden Comprehensive Recovery Kit Generator

USAGE:
  ./simplified-recovery-kit.sh [OPTIONS]

OPTIONS:
  --create          Create a full recovery document (Keys + Secrets + Config)
  --help            Show this help

DESCRIPTION:
  This script generates a SINGLE "Break Glass" document containing:
  1. The Age Encryption Key (Critical)
  2. All Decrypted Secrets (SMTP, Cloudflare, Backup Passphrase)
  3. Configuration Variables (Domain, Email)
  4. Server Migration/Rebuild Checklist

SECURITY WARNING:
  The output file contains UNENCRYPTED secrets. 
  Store it IMMEDIATELY in a secure location (Password Manager/Safe) 
  and DELETE the local copy.

EOF
}

# Parse Arguments
ACTION=""
for arg in "$@"; do
    case "$arg" in
        --create) ACTION="create" ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $arg"; show_help; exit 1 ;;
    esac
done

[[ -z "$ACTION" ]] && { show_help; exit 1; }

# Prerequisites
check_deps() {
    local missing=()
    for cmd in sops age age-keygen jq grep; do
        if ! command -v $cmd >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        exit 1
    fi
}

generate_recovery_kit() {
    local output_file="$1"
    local age_key="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"
    local secrets_file="secrets/secrets.yaml"
    local env_file=".env"

    if [[ ! -f "$age_key" ]]; then
        log_error "Age key not found: $age_key"
        return 1
    fi

    log_info "Collecting recovery data..."

    # 1. Metadata
    local hostname_val=$(hostname)
    local date_val=$(date)

    # 2. Key Data
    local pub_key=$(age-keygen -y "$age_key")
    local priv_key=$(cat "$age_key")

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
        # Export key for sops
        export SOPS_AGE_KEY_FILE="$age_key"
        
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
    cat > "$output_file" << EOF
══════════════════════════════════════════════════════════════════════════════
VAULTWARDEN SERVER RECOVERY KIT
══════════════════════════════════════════════════════════════════════════════
Created: $date_val
Server:  $hostname_val
Domain:  $domain

🚨 CRITICAL SECURITY DOCUMENT 🚨
This file contains sensitive unencrypted secrets.
1. Save this to your Password Manager (Secure Note).
2. Print a copy for your physical safe (optional).
3. DELETE this file from the server immediately after saving.

══════════════════════════════════════════════════════════════════════════════
SECTION 1: ENCRYPTION KEYS (THE MOST IMPORTANT PART)
══════════════════════════════════════════════════════════════════════════════
If you lose this key, your backups are USELESS.

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
   [ ] Verify email delivery:
       ./test-email-simple.sh

══════════════════════════════════════════════════════════════════════════════
END OF RECOVERY KIT
══════════════════════════════════════════════════════════════════════════════
EOF

    chmod 600 "$output_file"
}

# Main Execution
check_deps

if [[ "$ACTION" == "create" ]]; then
    output_file="$HOME/vaultwarden-recovery-kit-$(date +%Y%m%d).txt"
    
    if generate_recovery_kit "$output_file"; then
        log_success "Recovery Kit created: $output_file"
        echo ""
        log_warn "⚠️  ACTION REQUIRED:"
        echo "1. Copy content to password manager."
        echo "2. Delete local file: rm $output_file"
        echo ""
    else
        log_error "Failed to generate recovery kit"
        exit 1
    fi
fi
