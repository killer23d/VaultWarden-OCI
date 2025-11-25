#!/usr/bin/env bash
# lib/secrets.sh - Shared secrets management functions
# Used by edit-secrets.sh and setup-secrets.sh

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This library should be sourced, not executed directly"
    exit 1
fi

# Configuration
SECRETS_FILE="${SECRETS_FILE:-secrets/secrets.yaml}"
AGE_KEY_FILE="${AGE_KEY_FILE:-secrets/keys/age-key.txt}"
SECRETS_BACKUP_DIR="${SECRETS_BACKUP_DIR:-secrets}"

# Check if secrets file exists
secrets_file_exists() {
    [[ -f "$SECRETS_FILE" ]]
}

# Validate secrets file can be decrypted
validate_secrets_decryption() {
    local secrets_file="${1:-$SECRETS_FILE}"
    local age_key="${2:-$AGE_KEY_FILE}"
    
    if [[ ! -f "$secrets_file" ]]; then
        log_error "Secrets file not found: $secrets_file"
        return 1
    fi
    
    if [[ ! -f "$age_key" ]]; then
        log_error "Age key file not found: $age_key"
        return 1
    fi
    
    export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/$age_key"
    
    if ! sops -d "$secrets_file" >/dev/null 2>&1; then
        log_error "Cannot decrypt secrets file"
        return 1
    fi
    
    return 0
}

# Validate YAML structure
validate_secrets_yaml() {
    local secrets_file="${1:-$SECRETS_FILE}"
    
    if ! sops -d "$secrets_file" | python3 -c "import yaml, sys; yaml.safe_load(sys.stdin)" 2>/dev/null; then
        log_warn "Secrets file contains invalid YAML"
        return 1
    fi
    
    return 0
}

# Check required secrets exist
validate_required_secrets() {
    local secrets_file="${1:-$SECRETS_FILE}"
    
    local required_secrets=(
        "admin_token"
        "admin_basic_auth_hash"
        "caddy_cloudflare_dns_token"
        "fail2ban_cloudflare_firewall_token"
    )
    
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

# Check for placeholder values
check_placeholder_values() {
    local secrets_file="${1:-$SECRETS_FILE}"
    
    local secrets_to_check=(
        "admin_token"
        "admin_basic_auth_hash"
        "caddy_cloudflare_dns_token"
        "fail2ban_cloudflare_firewall_token"
    )
    
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

# Create backup of secrets file
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

# Cleanup old backups (keep last N)
cleanup_old_backups() {
    local backup_dir="${1:-$SECRETS_BACKUP_DIR}"
    local keep_count="${2:-5}"
    
    local old_backups
    old_backups=$(find "$backup_dir" -name "secrets.yaml.backup-*" -type f 2>/dev/null | sort -r | tail -n +$((keep_count + 1)))
    
    if [[ -n "$old_backups" ]]; then
        echo "$old_backups" | xargs rm -f
        log_debug "Cleaned up old backups"
    fi
    
    return 0
}

# Setup secure environment for SOPS
setup_secrets_environment() {
    local age_key="${1:-$AGE_KEY_FILE}"
    
    if [[ ! -f "$age_key" ]]; then
        log_error "Age key not found: $age_key"
        return 1
    fi
    
    export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/$age_key"
    log_debug "Secure environment configured"
    return 0
}

# Cleanup secrets environment
cleanup_secrets_environment() {
    if [[ -n "${SOPS_AGE_KEY_FILE:-}" ]]; then
        unset SOPS_AGE_KEY_FILE
    fi
    log_debug "Environment cleaned up"
    return 0
}

# Check Argon2 support
check_argon2_support() {
    if python3 -c "import argon2" 2>/dev/null; then
        echo "python"
        return 0
    elif command -v argon2 >/dev/null 2>&1; then
        echo "cli"
        return 0
    else
        return 1
    fi
}

# Generate Argon2 hash
generate_argon2_hash() {
    local password="$1"
    local hash
    local method
    
    if ! method=$(check_argon2_support); then
        log_error "Argon2 not available"
        log_info "Install: pip3 install argon2-cffi OR apt-get install argon2"
        return 1
    fi
    
    case "$method" in
        python)
            hash=$(printf '%s' "$password" | python3 -c "
import sys
from argon2 import PasswordHasher
from argon2 import Type
ph = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4, hash_len=32, salt_len=16, type=Type.ID)
password = sys.stdin.read()
print(ph.hash(password))
")
            ;;
        cli)
            local salt
            salt=$(openssl rand -base64 16)
            hash=$(echo -n "$password" | argon2 "$salt" -id -t 3 -m 16 -p 4 -l 32 -e 2>/dev/null)
            ;;
    esac
    
    if [[ -z "$hash" ]]; then
        log_error "Failed to generate Argon2 hash"
        return 1
    fi
    
    echo "$hash"
    return 0
}

# Generate bcrypt hash using htpasswd
generate_bcrypt_hash() {
    local password="$1"
    local rounds="${2:-12}"
    
    if [[ -z "$password" ]]; then
        log_error "Password cannot be empty"
        return 1
    fi
    
    local hash
    if ! hash=$(printf '%s\n' "$password" | htpasswd -niBC "$rounds" user 2>/dev/null | cut -d: -f2); then
        log_error "Failed to generate bcrypt hash"
        return 1
    fi
    
    if [[ -z "$hash" ]]; then
        log_error "Failed to generate bcrypt hash"
        return 1
    fi
    
    echo "$hash"
    return 0
}

# Validate Cloudflare token
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
        dns)
            endpoint="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?per_page=1"
            ;;
        firewall)
            endpoint="https://api.cloudflare.com/client/v4/zones/$zone_id/firewall/access_rules/rules?per_page=1"
            ;;
        *)
            log_error "Invalid token type: $token_type"
            return 1
            ;;
    esac
    
    if curl -sf --max-time 10 -H "Authorization: Bearer $token" "$endpoint" | jq -e '.success == true' >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Prompt for password with confirmation
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

# Secure secrets file permissions
secure_secrets_file() {
    local secrets_file="${1:-$SECRETS_FILE}"
    
    if [[ ! -f "$secrets_file" ]]; then
        return 0
    fi
    
    chmod 600 "$secrets_file"
    
    local real_user
    real_user=$(get_real_user)
    chown "$real_user:$real_user" "$secrets_file"
    
    return 0
}
