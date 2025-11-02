#!/usr/bin/env bash
# edit-secrets.sh - SOPS encrypted secrets management with enhanced safety
# ENHANCED: Standardized error handling - functions return, main() decides exit strategy
# All functions return exit codes, main() collects status and determines final exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"

# Configuration
SECRETS_FILE="secrets/secrets.yaml"
AGE_KEY_FILE="secrets/keys/age-key.txt"
INIT_SECRETS=false
TEST_ONLY=false
BACKUP_BEFORE_EDIT=true
DRY_RUN=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Secrets Management - SOPS + Age Encryption

USAGE:
    ./edit-secrets.sh [OPTIONS]

OPTIONS:
    --init                  Initialize new secrets file with template
    --test                  Test decryption without editing
    --no-backup             Skip backup before editing
    --dry-run               Show what would be done without executing
    --help                  Show this help

EXAMPLES:
    ./edit-secrets.sh                    # Edit existing secrets
    ./edit-secrets.sh --init             # Create new secrets file
    ./edit-secrets.sh --test             # Test decryption
    ./edit-secrets.sh --no-backup        # Edit without backup

SECRETS INCLUDED:
    admin_token                         # VaultWarden admin token (plain text)
    admin_basic_auth_hash              # Caddy basic auth (bcrypt hash)
    smtp_password                      # Email notifications
    backup_passphrase                  # Backup encryption
    push_installation_id/key           # Push notifications (optional)
    caddy_cloudflare_dns_token         # DNS-01 ACME challenges
    fail2ban_cloudflare_firewall_token # IP blocking via Cloudflare

IMPORTANT:
    • admin_token: Plain text (VaultWarden hashes with Argon2)
    • admin_basic_auth_hash: Must be bcrypt (generate with Caddy)
    • After editing, run: ./startup.sh --force-restart
EOF
}

# Argument Parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --init) INIT_SECRETS=true; shift ;;
        --test) TEST_ONLY=true; shift ;;
        --no-backup) BACKUP_BEFORE_EDIT=false; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Set Age key file environment variable
export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/$AGE_KEY_FILE"

# STANDARDIZED: Validate environment - returns exit code
validate_secrets_environment() {
    log_info "Validating secrets environment..."

    # Check required commands
    if ! require_commands sops age jq; then
        return 1
    fi

    # Check Age key file
    if [[ ! -f "$SOPS_AGE_KEY_FILE" ]]; then
        log_error "Age key file not found: $SOPS_AGE_KEY_FILE"
        log_info "Run setup.sh first to generate encryption keys"
        return 1
    fi

    # Check Age key permissions
    local key_perms
    key_perms=$(stat -c "%a" "$SOPS_AGE_KEY_FILE" 2>/dev/null || echo "000")
    if [[ "$key_perms" != "600" ]]; then
        log_error "Age key has incorrect permissions: $key_perms (should be 600)"
        log_info "Fix with: chmod 600 $SOPS_AGE_KEY_FILE"
        return 1
    fi

    # Check SOPS configuration
    if [[ ! -f ".sops.yaml" ]]; then
        log_error "SOPS configuration not found: .sops.yaml"
        log_info "Run setup.sh to create SOPS configuration"
        return 1
    fi

    log_success "Secrets environment validation passed"
    return 0
}

# STANDARDIZED: Create secrets backup - returns exit code
backup_secrets_file() {
    if [[ "$BACKUP_BEFORE_EDIT" != "true" ]]; then
        log_info "Skipping secrets backup (--no-backup specified)"
        return 0
    fi

    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_info "No existing secrets file to backup"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would backup secrets file"
        return 0
    fi

    log_info "Creating backup of secrets file..."

    local backup_file="$SECRETS_FILE.backup.$(date +%Y%m%d-%H%M%S)"
    
    if cp "$SECRETS_FILE" "$backup_file"; then
        log_success "Secrets backup created: $(basename "$backup_file")"
        return 0
    else
        log_error "Failed to create secrets backup"
        return 1
    fi
}

# STANDARDIZED: Test secrets decryption - returns exit code
test_secrets_decryption() {
    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_error "Secrets file not found: $SECRETS_FILE"
        return 1
    fi

    log_info "Testing secrets decryption..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would test secrets decryption"
        return 0
    fi

    # Test SOPS decryption
    local decrypted_content
    if decrypted_content=$(sops --decrypt "$SECRETS_FILE" 2>&1); then
        log_success "Secrets file decryption: OK"
        
        # Validate YAML structure
        if echo "$decrypted_content" | yq eval '.' >/dev/null 2>&1; then
            log_success "YAML structure validation: OK"
        elif echo "$decrypted_content" | jq . >/dev/null 2>&1; then
            log_success "JSON structure validation: OK"
        else
            log_warn "Content structure validation: Could not validate format"
        fi
        
        # Count secrets
        local secret_count
        if secret_count=$(echo "$decrypted_content" | yq eval 'keys | length' 2>/dev/null); then
            log_info "Found $secret_count secrets in file"
        fi
        
        return 0
    else
        log_error "Secrets file decryption failed:"
        log_error "$decrypted_content"
        return 1
    fi
}

# STANDARDIZED: Initialize new secrets file - returns exit code
initialize_secrets_file() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would initialize new secrets file"
        return 0
    fi

    log_info "Initializing new secrets file..."

    # Check if secrets file already exists
    if [[ -f "$SECRETS_FILE" ]]; then
        log_error "Secrets file already exists: $SECRETS_FILE"
        log_info "Use regular edit mode or remove existing file first"
        return 1
    fi

    # Ensure secrets directory exists
    if ! ensure_dir "secrets" 700; then
        log_error "Failed to create secrets directory"
        return 1
    fi

    # Generate secure defaults
    local admin_token backup_pass
    if ! admin_token=$(generate_secure_string 32) || ! backup_pass=$(generate_secure_string 32); then
        log_error "Failed to generate secure default values"
        return 1
    fi

    # Create initial secrets file (unencrypted)
    if ! cat > "$SECRETS_FILE" << EOF; then
# VaultWarden Secrets Configuration - Enhanced for Caddy-Cloudflare
# IMPORTANT: VaultWarden admin uses Argon2, Caddy basic_auth uses bcrypt

# VaultWarden admin token (plain text - will be hashed to Argon2 by VaultWarden)
admin_token: $admin_token

# Caddy basic_auth hash for /admin endpoint (bcrypt format)
# Generate with: docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password
admin_basic_auth_hash: CHANGE_ME_BCRYPT_HASH

# SMTP password for email notifications
smtp_password: CHANGE_ME_SMTP_PASSWORD

# Backup encryption passphrase
backup_passphrase: $backup_pass

# Push notifications (optional - get from bitwarden.com/host)
push_installation_id: CHANGE_ME_OR_LEAVE_EMPTY
push_installation_key: CHANGE_ME_OR_LEAVE_EMPTY

# Cloudflare DNS API token for caddy-cloudflare (DNS-01 ACME challenges)
# Permissions: Zone:DNS:Edit + Zone:Zone:Read for your domain
caddy_cloudflare_dns_token: CHANGE_ME_DNS_TOKEN

# Cloudflare Firewall API token for fail2ban IP blocking
# Permissions: Zone:Firewall Services:Edit for your domain
fail2ban_cloudflare_firewall_token: CHANGE_ME_FIREWALL_TOKEN
EOF
        log_error "Failed to create initial secrets file"
        return 1
    fi

    # Encrypt with SOPS
    if encrypt_sops_file "$SECRETS_FILE" "$AGE_KEY_FILE"; then
        log_success "Secrets file initialized and encrypted"
        
        # Set secure permissions
        if ! secure_file "$SECRETS_FILE" 600; then
            log_warn "Failed to set secure permissions on secrets file"
        fi
        
        log_warn "IMPORTANT: Update the placeholder values:"
        log_info "  1. Generate bcrypt hash for admin_basic_auth_hash"
        log_info "  2. Add Cloudflare DNS API token"
        log_info "  3. Add Cloudflare Firewall API token"
        log_info "  4. Configure SMTP password if using email"
        log_info "  5. Run: ./edit-secrets.sh (to edit)"
        
        return 0
    else
        log_error "Failed to encrypt secrets file"
        return 1
    fi
}

# STANDARDIZED: Edit secrets file - returns exit code
edit_secrets_file() {
    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_error "Secrets file not found: $SECRETS_FILE"
        log_info "Run with --init to create a new secrets file"
        return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would open secrets file for editing"
        return 0
    fi

    log_info "Opening secrets file for editing..."

    # Create backup before editing
    if ! backup_secrets_file; then
        log_error "Failed to create backup before editing"
        return 1
    fi

    # Determine editor
    local editor="${EDITOR:-nano}"
    
    if ! has_command "$editor"; then
        log_warn "Editor '$editor' not found, falling back to nano"
        editor="nano"
    fi

    if ! has_command "$editor"; then
        log_error "No suitable editor found"
        log_info "Install nano: sudo apt install nano"
        log_info "Or set EDITOR environment variable"
        return 1
    fi

    log_info "Using editor: $editor"
    log_info "Edit the secrets and save the file when done"
    
    # Use SOPS to edit the encrypted file
    if sops --editor "$editor" "$SECRETS_FILE"; then
        log_success "Secrets file edited successfully"
        
        # Validate the edited file
        if test_secrets_decryption; then
            log_success "Edited secrets file validated successfully"
            
            log_warn "IMPORTANT NEXT STEPS:"
            log_info "  1. Restart containers: ./startup.sh --force-restart"
            log_info "  2. Test login with new credentials"
            log_info "  3. Verify email notifications if configured"
            
            return 0
        else
            log_error "Edited secrets file validation failed"
            log_info "The file may have syntax errors or encryption issues"
            return 1
        fi
    else
        log_error "Failed to edit secrets file"
        log_info "Check that SOPS and your editor are working correctly"
        return 1
    fi
}

# STANDARDIZED: Show secrets status - returns exit code
show_secrets_status() {
    log_info "Secrets file status:"
    echo ""

    # Check if secrets file exists
    if [[ -f "$SECRETS_FILE" ]]; then
        local file_size file_perms file_age
        file_size=$(stat -c%s "$SECRETS_FILE" 2>/dev/null || echo "unknown")
        file_perms=$(stat -c "%a" "$SECRETS_FILE" 2>/dev/null || echo "unknown")
        file_age=$(stat -c %Y "$SECRETS_FILE" 2>/dev/null || echo "0")
        file_age=$(date -d "@$file_age" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown")

        echo "  File: $SECRETS_FILE"
        echo "  Size: $file_size bytes"
        echo "  Permissions: $file_perms"
        echo "  Last modified: $file_age"
        echo ""

        # Test encryption
        if test_secrets_decryption; then
            echo "  Encryption: ✅ Working"
        else
            echo "  Encryption: ❌ Issues detected"
        fi
    else
        echo "  Status: ❌ Not found"
        echo "  Location: $SECRETS_FILE"
        echo ""
        log_info "Initialize with: ./edit-secrets.sh --init"
    fi

    # Check Age key
    echo ""
    log_info "Age key status:"
    if [[ -f "$SOPS_AGE_KEY_FILE" ]]; then
        local key_perms
        key_perms=$(stat -c "%a" "$SOPS_AGE_KEY_FILE" 2>/dev/null || echo "unknown")
        echo "  File: $SOPS_AGE_KEY_FILE"
        echo "  Permissions: $key_perms"
        
        if [[ "$key_perms" == "600" ]]; then
            echo "  Security: ✅ Properly secured"
        else
            echo "  Security: ⚠️  Incorrect permissions"
        fi
    else
        echo "  Status: ❌ Not found"
        log_info "Run setup.sh to generate Age keys"
    fi

    return 0
}

# ENHANCED: Main function with proper error handling and exit strategy
main() {
    log_header "VaultWarden-OCI Secrets Management"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    # Validate environment
    if ! validate_secrets_environment; then
        exit 1
    fi

    # Handle test-only mode
    if [[ "$TEST_ONLY" == "true" ]]; then
        log_info "=== Testing Secrets Decryption ==="
        if test_secrets_decryption; then
            show_secrets_status
            log_success "Secrets test completed successfully"
            exit 0
        else
            log_error "Secrets test failed"
            exit 1
        fi
    fi

    # Handle initialization mode
    if [[ "$INIT_SECRETS" == "true" ]]; then
        log_info "=== Initializing Secrets File ==="
        if initialize_secrets_file; then
            log_success "Secrets file initialized successfully"
            show_secrets_status
            exit 0
        else
            log_error "Failed to initialize secrets file"
            exit 1
        fi
    fi

    # Handle regular edit mode
    log_info "=== Editing Secrets File ==="
    
    # Show current status first
    show_secrets_status
    echo ""

    # Pre-edit validation
    if [[ -f "$SECRETS_FILE" ]]; then
        if ! test_secrets_decryption; then
            log_error "Cannot edit secrets file - decryption failed"
            log_info "File may be corrupted or keys may be wrong"
            exit 1
        fi
    fi

    # Edit the file
    if edit_secrets_file; then
        log_success "Secrets editing completed successfully"
        exit 0
    else
        log_error "Secrets editing failed"
        exit 1
    fi
}

main "$@"
