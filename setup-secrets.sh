#!/usr/bin/env bash
# setup-secrets.sh - Interactive VaultWarden secrets configuration
# Automates password hashing and token validation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/secrets.sh"

# Configuration
AUTO_MODE=false
SKIP_VALIDATION=false
SKIP_OPTIONAL=false
FORCE=false
DRY_RUN=false

# Cleanup
CLEANUP_ACTIONS=()
register_cleanup() { CLEANUP_ACTIONS+=("$1"); }
perform_cleanup() { 
    for ((idx=${#CLEANUP_ACTIONS[@]}-1; idx>=0; idx--)); do 
        eval "${CLEANUP_ACTIONS[$idx]}" 2>/dev/null || true
    done
    cleanup_secrets_environment
}
trap perform_cleanup EXIT

show_help() {
    cat << 'EOF'
VaultWarden Interactive Secrets Setup

USAGE:
    ./setup-secrets.sh [OPTIONS]

OPTIONS:
    --auto              Auto-generate passwords
    --skip-validation   Skip token/SMTP validation
    --skip-optional     Skip optional secrets
    --force             Overwrite existing secrets
    --dry-run           Preview without executing
    --help              Show help

FEATURES:
    ✅ Automatic Argon2 hashing (VaultWarden)
    ✅ Automatic bcrypt hashing (Caddy)
    ✅ Cloudflare token validation
    ✅ Interactive prompts with confirmation
    ✅ Secure random generation

EXAMPLES:
    ./setup-secrets.sh                  # Interactive
    ./setup-secrets.sh --auto           # Automated
    ./setup-secrets.sh --skip-optional  # Skip push notifications
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --auto) AUTO_MODE=true; shift ;;
        --skip-validation) SKIP_VALIDATION=true; shift ;;
        --skip-optional) SKIP_OPTIONAL=true; shift ;;
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown: $1"; show_help; exit 1 ;;
    esac
done

# Ensure Argon2 available
ensure_argon2_available() {
    if check_argon2_support >/dev/null; then
        return 0
    fi
    
    log_warn "Argon2 not detected"
    
    if [[ "$AUTO_MODE" != "true" ]]; then
        read -p "Install Python argon2-cffi? (yes/no): " install_it
        if [[ "$install_it" == "yes" ]]; then
            pip3 install argon2-cffi && return 0
        fi
    fi
    
    log_error "Argon2 required but not available"
    return 1
}

# Check overwrite
check_overwrite() {
    if ! secrets_file_exists; then
        return 0
    fi
    
    # Check if placeholder structure
    if setup_secrets_environment && sops -d "$SECRETS_FILE" 2>/dev/null | grep -q "PLACEHOLDER_NOT_CONFIGURED"; then
        cleanup_secrets_environment
        log_info "Found empty structure - ready to populate"
        return 0
    fi
    cleanup_secrets_environment
    
    if [[ "$FORCE" == "true" ]]; then
        create_secrets_backup
        return 0
    fi
    
    log_warn "Secrets already configured"
    read -p "Overwrite? (yes/no): " confirm
    
    if [[ "$confirm" == "yes" ]]; then
        create_secrets_backup
        return 0
    fi
    
    return 1
}

# Collect secrets
collect_secrets() {
    declare -A SECRETS
    
    # VaultWarden Admin
    log_info "=== VaultWarden Admin Password ==="
    log_info "Will be hashed with Argon2id"
    local vw_pass
    if [[ "$AUTO_MODE" == "true" ]]; then
        vw_pass=$(generate_secure_string 24)
        echo ""
        log_warn "🔐 SAVE THIS PASSWORD: $vw_pass"
        echo ""
    else
        vw_pass=$(prompt_password_with_confirmation "VaultWarden admin password" 12)
    fi
    
    local vw_hash
    if ! vw_hash=$(generate_argon2_hash "$vw_pass"); then
        return 1
    fi
    SECRETS["admin_token"]="$vw_hash"
    
    # Caddy Admin
    echo ""
    log_info "=== Caddy Admin Password ==="
    log_info "Will be hashed with bcrypt"
    local caddy_pass
    if [[ "$AUTO_MODE" == "true" ]]; then
        caddy_pass=$(generate_secure_string 24)
        echo ""
        log_warn "🔐 SAVE THIS PASSWORD: $caddy_pass"
        echo ""
    else
        caddy_pass=$(prompt_password_with_confirmation "Caddy admin password" 12)
    fi
    
    local caddy_hash
    caddy_hash=$(generate_bcrypt_hash "$caddy_pass" 2>/dev/null)
    if [[ -z "$caddy_hash" ]]; then
        log_error "Failed to generate bcrypt hash"
        return 1
    fi
    SECRETS["admin_basic_auth_hash"]="$caddy_hash"
    
    # Cloudflare DNS
    echo ""
    log_info "=== Cloudflare DNS Token ==="
    log_info "Permissions: Zone:DNS:Edit + Zone:Zone:Read"
    local cf_dns
    if [[ "$AUTO_MODE" == "true" ]]; then
        cf_dns="CHANGE_ME_DNS_TOKEN"
    else
        read -p "Cloudflare DNS token: " cf_dns
        if [[ "$SKIP_VALIDATION" != "true" && "$cf_dns" != "CHANGE_ME_DNS_TOKEN" ]]; then
            if validate_cloudflare_token "$cf_dns" "dns"; then
                log_success "DNS token validated"
            else
                log_warn "Validation failed but continuing"
            fi
        fi
    fi
    SECRETS["caddy_cloudflare_dns_token"]="$cf_dns"
    
    # Cloudflare Firewall
    echo ""
    log_info "=== Cloudflare Firewall Token ==="
    log_info "Permissions: Zone:Firewall Services:Edit"
    local cf_fw
    if [[ "$AUTO_MODE" == "true" ]]; then
        cf_fw="CHANGE_ME_FIREWALL_TOKEN"
    else
        read -p "Cloudflare Firewall token: " cf_fw
        if [[ "$SKIP_VALIDATION" != "true" && "$cf_fw" != "CHANGE_ME_FIREWALL_TOKEN" ]]; then
            if validate_cloudflare_token "$cf_fw" "firewall"; then
                log_success "Firewall token validated"
            else
                log_warn "Validation failed but continuing"
            fi
        fi
    fi
    SECRETS["fail2ban_cloudflare_firewall_token"]="$cf_fw"
    
    # SMTP
    echo ""
    log_info "=== SMTP Password ==="
    local smtp_pass
    if [[ "$AUTO_MODE" == "true" ]]; then
        smtp_pass="CHANGE_ME_SMTP_PASSWORD"
    else
        read -p "Enable email? (yes/no): " enable_email
        if [[ "$enable_email" == "yes" ]]; then
            read -s -p "SMTP password: " smtp_pass
            echo ""
        else
            smtp_pass="CHANGE_ME_SMTP_PASSWORD"
        fi
    fi
    SECRETS["smtp_password"]="$smtp_pass"
    
    # Backup Passphrase
    log_info "Generating backup passphrase..."
    SECRETS["backup_passphrase"]=$(generate_secure_string 32)
    
    # Optional: Push
    if [[ "$SKIP_OPTIONAL" != "true" ]]; then
        echo ""
        read -p "Configure push notifications? (yes/no): " do_push
        if [[ "$do_push" == "yes" ]]; then
            read -p "Push installation ID: " push_id
            read -p "Push installation key: " push_key
            SECRETS["push_installation_id"]="$push_id"
            SECRETS["push_installation_key"]="$push_key"
        else
            SECRETS["push_installation_id"]="CHANGE_ME_OR_LEAVE_EMPTY"
            SECRETS["push_installation_key"]="CHANGE_ME_OR_LEAVE_EMPTY"
        fi
    else
        SECRETS["push_installation_id"]="CHANGE_ME_OR_LEAVE_EMPTY"
        SECRETS["push_installation_key"]="CHANGE_ME_OR_LEAVE_EMPTY"
    fi
    
    # Export for write
    for key in "${!SECRETS[@]}"; do
        export "SECRET_$key=${SECRETS[$key]}"
    done
    
    return 0
}

# Write secrets
write_secrets() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would write secrets"
        return 0
    fi
    
    local temp_file
    temp_file=$(mktemp)
    chmod 600 "$temp_file"
    register_cleanup "rm -f '$temp_file'"
    
    cat > "$temp_file" << EOF
# VaultWarden Secrets - Generated by setup-secrets.sh
admin_token: $SECRET_admin_token
admin_basic_auth_hash: $SECRET_admin_basic_auth_hash
smtp_password: $SECRET_smtp_password
backup_passphrase: $SECRET_backup_passphrase
push_installation_id: $SECRET_push_installation_id
push_installation_key: $SECRET_push_installation_key
caddy_cloudflare_dns_token: $SECRET_caddy_cloudflare_dns_token
fail2ban_cloudflare_firewall_token: $SECRET_fail2ban_cloudflare_firewall_token
EOF
    
    if ! setup_secrets_environment; then
        return 1
    fi
    
    if ! sops --encrypt "$temp_file" > "$SECRETS_FILE"; then
        log_error "Failed to encrypt secrets"
        return 1
    fi
    
    secure_secrets_file
    log_success "Secrets written"
    return 0
}

# Main
main() {
    log_header "VaultWarden Interactive Secrets Setup"
    
    if ! require_commands sops age docker python3 jq; then
        exit 1
    fi
    
    if ! ensure_argon2_available; then
        exit 1
    fi
    
    if ! check_overwrite; then
        log_info "Keeping existing secrets"
        exit 0
    fi
    
    if ! collect_secrets; then
        log_error "Failed to collect secrets"
        exit 1
    fi
    
    if ! write_secrets; then
        log_error "Failed to write secrets"
        exit 1
    fi
    
    log_success "Secrets setup complete!"
    echo ""
    echo "Next Steps:"
    echo "1. Start services: ./startup.sh"
    echo "2. Verify: ./health.sh"
    
    exit 0
}

main "$@"
