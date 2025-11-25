#!/usr/bin/env bash
# edit-secrets.sh - Idempotent VaultWarden secrets editor
# Safe to re-run multiple times
# Uses your $EDITOR or falls back to nano

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/secrets.sh"

# Configuration
EDITOR_CMD="${EDITOR:-nano}"
SKIP_BACKUP=false
VIEW_ONLY=false

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
VaultWarden Secrets Editor (Idempotent)

USAGE:
    ./edit-secrets.sh [OPTIONS]

OPTIONS:
    --editor EDITOR     Use specific editor (default: $EDITOR or nano)
    --no-backup         Skip creating backup before edit
    --view              View-only mode (read-only)
    --help              Show help

FEATURES:
    ✅ Idempotent - Safe to re-run
    ✅ Automatic backup before editing
    ✅ Validates decryption before opening
    ✅ Detects if no changes made
    ✅ Validates YAML after editing
    ✅ Rollback on invalid changes

EXAMPLES:
    ./edit-secrets.sh                    # Edit with default editor
    ./edit-secrets.sh --editor vim       # Edit with vim
    ./edit-secrets.sh --view             # View only (no changes)
    ./edit-secrets.sh --no-backup        # Skip backup
HELP
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --editor) EDITOR_CMD="$2"; shift 2 ;;
        --no-backup) SKIP_BACKUP=true; shift ;;
        --view) VIEW_ONLY=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Check prerequisites (idempotent)
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing=()
    
    # Check Age key
    if [[ ! -f "$AGE_KEY_FILE" ]]; then
        missing+=("Age encryption key: $AGE_KEY_FILE")
    elif ! check_age_key "$AGE_KEY_FILE" 2>/dev/null; then
        missing+=("Valid Age encryption key")
    fi
    
    # Check SOPS configuration
    if [[ ! -f ".sops.yaml" ]]; then
        missing+=("SOPS configuration: .sops.yaml")
    fi
    
    # Check secrets file
    if [[ ! -f "$SECRETS_FILE" ]]; then
        missing+=("Secrets file: $SECRETS_FILE")
    fi
    
    # Report missing
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing prerequisites:"
        for item in "${missing[@]}"; do
            log_error "  - $item"
        done
        echo ""
        log_info "To create secrets, run: ./setup-secrets.sh"
        return 1
    fi
    
    log_success "All prerequisites present"
    return 0
}

# Validate secrets can be decrypted (idempotent check)
validate_secrets() {
    log_info "Validating secrets file..."
    
    if ! setup_secrets_environment; then
        log_error "Failed to setup SOPS environment"
        return 1
    fi
    
    if ! validate_secrets_decryption; then
        log_error "Cannot decrypt secrets file"
        log_info "The Age key may be incorrect or the file corrupted"
        cleanup_secrets_environment
        return 1
    fi
    
    if ! validate_secrets_yaml; then
        log_warn "Secrets file has invalid YAML structure"
        # Continue anyway - user might be fixing it
    fi
    
    cleanup_secrets_environment
    log_success "Secrets validation passed"
    return 0
}

# Create backup (idempotent - uses timestamp)
create_backup() {
    if [[ "$SKIP_BACKUP" == "true" ]]; then
        log_info "Skipping backup (--no-backup specified)"
        return 0
    fi
    
    local backup_file="$SECRETS_BACKUP_DIR/secrets.yaml.backup-$(date +%Y%m%d-%H%M%S)"
    
    log_info "Creating backup: $(basename "$backup_file")"
    
    if ! cp "$SECRETS_FILE" "$backup_file"; then
        log_error "Failed to create backup"
        return 1
    fi
    
    chmod 600 "$backup_file"
    log_success "Backup created"
    
    # Cleanup old backups (keep last 5)
    cleanup_old_backups "$SECRETS_BACKUP_DIR" 5
    
    return 0
}

# View secrets (read-only)
view_secrets() {
    log_info "Opening secrets in view-only mode..."
    
    if ! setup_secrets_environment; then
        return 1
    fi
    
    local temp_file
    temp_file=$(mktemp)
    chmod 600 "$temp_file"
    register_cleanup "rm -f '$temp_file'"
    
    if ! sops -d "$SECRETS_FILE" > "$temp_file"; then
        log_error "Failed to decrypt secrets"
        return 1
    fi
    
    # View with less or editor in read-only mode
    if command -v less >/dev/null 2>&1; then
        less "$temp_file"
    else
        "$EDITOR_CMD" -R "$temp_file" 2>/dev/null || cat "$temp_file"
    fi
    
    cleanup_secrets_environment
    return 0
}

# Edit secrets interactively
edit_secrets() {
    log_info "Opening secrets with: $EDITOR_CMD"
    
    if ! setup_secrets_environment; then
        return 1
    fi
    
    # Decrypt to temp file
    local temp_file
    temp_file=$(mktemp)
    chmod 600 "$temp_file"
    register_cleanup "rm -f '$temp_file'"
    
    if ! sops -d "$SECRETS_FILE" > "$temp_file"; then
        log_error "Failed to decrypt secrets"
        return 1
    fi
    
    # Get checksum before editing
    local before_checksum
    before_checksum=$(calculate_sha256 "$temp_file")
    
    # Open editor
    if ! "$EDITOR_CMD" "$temp_file"; then
        log_error "Editor exited with error"
        return 1
    fi
    
    # Check if file changed
    local after_checksum
    after_checksum=$(calculate_sha256 "$temp_file")
    
    if [[ "$before_checksum" == "$after_checksum" ]]; then
        log_info "File has not changed, exiting"
        cleanup_secrets_environment
        return 0
    fi
    
    log_info "Changes detected, validating..."
    
    # Validate YAML structure
    if ! python3 -c "import yaml, sys; yaml.safe_load(open('$temp_file'))" 2>/dev/null; then
        log_error "Invalid YAML structure after editing"
        read -p "Discard changes? (yes/no): " discard
        if [[ "$discard" == "yes" ]]; then
            log_info "Changes discarded"
            return 1
        else
            log_info "Re-opening editor to fix..."
            edit_secrets
            return $?
        fi
    fi
    
    # Encrypt and save (atomic)
    log_info "Encrypting changes..."
    local encrypted_temp="${temp_file}.enc"
    
    if ! sops --encrypt "$temp_file" > "$encrypted_temp"; then
        log_error "Failed to encrypt secrets"
        rm -f "$encrypted_temp"
        return 1
    fi
    
    # Atomic move
    mv "$encrypted_temp" "$SECRETS_FILE"
    secure_secrets_file
    
    cleanup_secrets_environment
    
    log_success "Secrets updated successfully"
    return 0
}

# Main execution
main() {
    log_header "VaultWarden Secrets Editor"
    
    # Check prerequisites (idempotent)
    if ! check_prerequisites; then
        exit 1
    fi
    
    # Validate secrets (idempotent)
    if ! validate_secrets; then
        exit 1
    fi
    
    # Create backup (idempotent - timestamped)
    if [[ "$VIEW_ONLY" != "true" ]]; then
        if ! create_backup; then
            log_warn "Failed to create backup, continuing anyway..."
        fi
    fi
    
    # View or edit
    if [[ "$VIEW_ONLY" == "true" ]]; then
        if ! view_secrets; then
            exit 1
        fi
    else
        if ! edit_secrets; then
            exit 1
        fi
    fi
    
    exit 0
}

main "$@"
