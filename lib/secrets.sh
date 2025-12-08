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
    
    # Resolve to absolute path if relative
    if [[ ! "$age_key" = /* ]]; then
        age_key="${PROJECT_ROOT:-$(pwd)}/$age_key"
    fi
    
    if [[ ! -f "$age_key" ]]; then
        log_error "Age key not found: $age_key"
        return 1
    fi
    
    export SOPS_AGE_KEY_FILE="$age_key"
    # FIXED: Also export SOPS_CONFIG to ensure .sops.yaml is found
    export SOPS_CONFIG="${PROJECT_ROOT}/.sops.yaml"
    log_debug "Secure environment configured"
    return 0
}

# Cleanup secrets environment
# FIXED: Commented out to prevent breaking edit-secrets.sh
# The environment variables need to persist for the entire script execution
cleanup_secrets_environment() {
    # NOTE: This function is intentionally disabled to prevent unsetting
    # SOPS environment variables that are needed throughout script execution.
    # If you need to cleanup, call 'unset SOPS_AGE_KEY_FILE SOPS_CONFIG' explicitly.
    
    # if [[ -n "${SOPS_AGE_KEY_FILE:-}" ]]; then
    #     unset SOPS_AGE_KEY_FILE
    # fi
    # if [[ -n "${SOPS_CONFIG:-}" ]]; then
    #     unset SOPS_CONFIG
    # fi
    
    log_debug "Environment cleanup skipped (variables persist for script duration)"
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
