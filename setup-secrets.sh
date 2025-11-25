#!/usr/bin/env bash
# setup-secrets.sh - Idempotent VaultWarden secrets configuration
# Can be run standalone or as part of setup.sh
# Safe to re-run multiple times

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
AUTO_FIX=true

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
    cat << 'HELP'
VaultWarden Interactive Secrets Setup (Idempotent)

USAGE:
    ./setup-secrets.sh [OPTIONS]

OPTIONS:
    --auto              Auto-generate passwords
    --skip-validation   Skip token/SMTP validation
    --skip-optional     Skip optional secrets
    --force             Overwrite existing secrets without prompting
    --dry-run           Preview without executing
    --no-auto-fix       Don't auto-create missing prerequisites
    --help              Show help

FEATURES:
    ✅ Idempotent - Safe to re-run multiple times
    ✅ Auto-fixes missing prerequisites (Age keys, SOPS config)
    ✅ Validates existing secrets before reconfiguration
    ✅ Automatic Argon2 hashing (VaultWarden)
    ✅ Automatic bcrypt hashing (Caddy)
    ✅ Cloudflare token validation
    ✅ Interactive prompts with confirmation

EXAMPLES:
    ./setup-secrets.sh                  # Interactive setup
    ./setup-secrets.sh --auto           # Automated with generated passwords
    ./setup-secrets.sh --force          # Reconfigure without prompting
    ./setup-secrets.sh --skip-optional  # Skip push notifications
HELP
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --auto) AUTO_MODE=true; shift ;;
        --skip-validation) SKIP_VALIDATION=true; shift ;;
        --skip-optional) SKIP_OPTIONAL=true; shift ;;
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --no-auto-fix) AUTO_FIX=false; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Ensure prerequisites exist (idempotent)
ensure_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing=()
    local can_fix=()
    
    # Check Age key
    if [[ ! -f "$AGE_KEY_FILE" ]]; then
        missing+=("Age encryption key")
        can_fix+=("age_key")
    elif ! check_age_key "$AGE_KEY_FILE" 2>/dev/null; then
        log_warn "Age key exists but appears invalid"
        missing+=("Valid Age encryption key")
        can_fix+=("age_key")
    fi
    
    # Check SOPS configuration
    if [[ ! -f ".sops.yaml" ]]; then
        missing+=("SOPS configuration")
        can_fix+=("sops_config")
    fi
    
    # Check directories
    if [[ ! -d "secrets" ]]; then
        missing+=("Secrets directory")
        can_fix+=("directories")
    fi
    
    # Report missing items
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing prerequisites:"
        for item in "${missing[@]}"; do
            log_warn "  - $item"
        done
        
        # Auto-fix or prompt
        if [[ "$AUTO_FIX" == "true" ]]; then
            log_info "Auto-fixing missing prerequisites..."
            fix_prerequisites "${can_fix[@]}"
        else
            log_error "Prerequisites missing. Run './setup.sh' first or use --auto-fix"
            return 1
        fi
    else
        log_success "All prerequisites present"
    fi
    
    return 0
}

# Fix missing prerequisites (idempotent)
fix_prerequisites() {
    local items=("$@")
    
    for item in "${items[@]}"; do
        case "$item" in
            age_key)
                log_info "Creating Age encryption key..."
                mkdir -p "$(dirname "$AGE_KEY_FILE")"
                if generate_age_key "$AGE_KEY_FILE" true; then
                    log_success "Age key created: $AGE_KEY_FILE"
                else
                    log_error "Failed to create Age key"
                    return 1
                fi
                ;;
            sops_config)
                log_info "Creating SOPS configuration..."
                local age_public_key
                if ! age_public_key=$(get_age_public_key "$AGE_KEY_FILE"); then
                    log_error "Failed to extract Age public key"
                    return 1
                fi
                
                cat > .sops.yaml << SOPS_EOF
creation_rules:
  - path_regex: secrets/secrets\.yaml$
    age: $age_public_key
SOPS_EOF
                log_success "SOPS configuration created: .sops.yaml"
                ;;
            directories)
                log_info "Creating directory structure..."
                mkdir -p secrets/keys secrets
                chmod 700 secrets/keys
                log_success "Directories created"
                ;;
        esac
    done
    
    return 0
}

# Check if secrets are already configured (idempotent check)
secrets_are_configured() {
    if ! secrets_file_exists; then
        return 1
    fi
    
    # Setup environment to decrypt
    if ! setup_secrets_environment; then
        return 1
    fi
    
    # Check for placeholder values
    if ! check_placeholder_values 2>/dev/null; then
        cleanup_secrets_environment
        return 1
    fi
    
    cleanup_secrets_environment
    return 0
}

# Validate existing secrets
validate_existing_secrets() {
    log_info "Validating existing secrets..."
    
    if ! setup_secrets_environment; then
        return 1
    fi
    
    local issues=()
    
    # Check decryption
    if ! validate_secrets_decryption; then
        issues+=("Cannot decrypt secrets file")
    fi
    
    # Check YAML structure
    if ! validate_secrets_yaml; then
        issues+=("Invalid YAML structure")
    fi
    
    # Check required secrets
    if ! validate_required_secrets; then
        issues+=("Missing required secrets")
    fi
    
    # Check for placeholders
    if ! check_placeholder_values; then
        issues+=("Contains placeholder values")
    fi
    
    cleanup_secrets_environment
    
    if [[ ${#issues[@]} -gt 0 ]]; then
        log_warn "Validation issues found:"
        for issue in "${issues[@]}"; do
            log_warn "  - $issue"
        done
        return 1
    fi
    
    log_success "Existing secrets are valid"
    return 0
}

# Ensure Argon2 available (idempotent)
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

# Check if reconfiguration needed
check_reconfiguration() {
    if ! secrets_are_configured; then
        log_info "No valid secrets found - configuration needed"
        return 0
    fi
    
    if [[ "$FORCE" == "true" ]]; then
        log_info "Force mode - reconfiguring secrets"
        create_secrets_backup
        return 0
    fi
    
    log_info "Secrets already configured and valid"
    
    if [[ "$AUTO_MODE" == "true" ]]; then
        log_info "Auto mode - keeping existing secrets"
        return 1
    fi
    
    read -p "Reconfigure secrets? (yes/no): " confirm
    
    if [[ "$confirm" == "yes" ]]; then
        create_secrets_backup
        return 0
    fi
    
    return 1
}

# Collect secrets interactively
collect_secrets() {
    declare -A SECRETS
    
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
    vw_hash=$(generate_argon2_hash "$vw_pass")
    if [[ -z "$vw_hash" ]]; then
        log_error "Failed to generate Argon2 hash"
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
    caddy_hash=$(generate_bcrypt_hash "$caddy_pass")
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

# Write secrets (atomic operation)
write_secrets() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would write secrets"
        return 0
    fi
    
    local temp_file
    temp_file=$(mktemp)
    chmod 600 "$temp_file"
    register_cleanup "rm -f '$temp_file'"
    
    cat > "$temp_file" << SECRETS_EOF
# VaultWarden Secrets - Generated $(date -Iseconds)
admin_token: $SECRET_admin_token
admin_basic_auth_hash: $SECRET_admin_basic_auth_hash
smtp_password: $SECRET_smtp_password
backup_passphrase: $SECRET_backup_passphrase
push_installation_id: $SECRET_push_installation_id
push_installation_key: $SECRET_push_installation_key
caddy_cloudflare_dns_token: $SECRET_caddy_cloudflare_dns_token
fail2ban_cloudflare_firewall_token: $SECRET_fail2ban_cloudflare_firewall_token
SECRETS_EOF
    
    if ! setup_secrets_environment; then
        return 1
    fi
    
    # Atomic write: encrypt to temp, then move
    local encrypted_temp="${temp_file}.enc"
    if ! sops --encrypt "$temp_file" > "$encrypted_temp"; then
        log_error "Failed to encrypt secrets"
        rm -f "$encrypted_temp"
        return 1
    fi
    
    # Atomic move
    mv "$encrypted_temp" "$SECRETS_FILE"
    secure_secrets_file
    
    log_success "Secrets written successfully"
    return 0
}

# Main execution
main() {
    log_header "VaultWarden Interactive Secrets Setup"
    
    # Check required commands
    if ! require_commands sops age python3 jq; then
        exit 1
    fi
    
    # Ensure prerequisites (idempotent)
    if ! ensure_prerequisites; then
        exit 1
    fi
    
    # Ensure Argon2 available
    if ! ensure_argon2_available; then
        exit 1
    fi
    
    # Check if reconfiguration needed (idempotent check)
    if ! check_reconfiguration; then
        log_info "Keeping existing secrets - no changes made"
        exit 0
    fi
    
    # Collect secrets
    if ! collect_secrets; then
        log_error "Failed to collect secrets"
        exit 1
    fi
    
    # Write secrets (atomic)
    if ! write_secrets; then
        log_error "Failed to write secrets"
        exit 1
    fi
    
    log_success "Secrets setup complete!"
    echo ""
    echo "Next Steps:"
    echo "1. Start services: make up"
    echo "2. Verify: ./health.sh"
    
    exit 0
}

main "$@"
