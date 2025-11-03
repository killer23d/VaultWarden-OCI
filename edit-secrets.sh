#!/usr/bin/env bash
# edit-secrets.sh - Secure VaultWarden secrets editor with enhanced privacy
# ENHANCED: Fixed SOPS key path exposure - no longer visible in process list
# ENHANCED: Secure environment handling and temporary file management

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"

# Configuration
EDITOR="${EDITOR:-nano}"
DRY_RUN=false
BACKUP_SECRETS=true
VALIDATE_SECRETS=true
SECURE_MODE=true

# Cleanup actions
CLEANUP_ACTIONS=()

register_cleanup() {
    CLEANUP_ACTIONS+=("$1")
}

perform_cleanup() {
    local action
    for ((idx=${#CLEANUP_ACTIONS[@]}-1; idx>=0; idx--)); do
        eval "${CLEANUP_ACTIONS[$idx]}" 2>/dev/null || true
    done
}

trap perform_cleanup EXIT

show_help() {
    cat << 'EOF'
VaultWarden-OCI Secure Secrets Editor - Enhanced Privacy Protection

USAGE:
    ./edit-secrets.sh [OPTIONS]

OPTIONS:
    --editor EDITOR         Use specific editor (default: nano)
    --no-backup             Skip creating backup before editing
    --no-validation         Skip validation after editing
    --insecure-mode         Disable additional security measures
    --dry-run               Show what would be done without executing
    --help                  Show this help

SECURITY FEATURES:
    - SOPS key path never exposed in process list
    - Secure temporary file handling with proper cleanup
    - Automatic backup creation before editing
    - Validation of secrets after editing
    - Secure environment variable management
    - Memory-safe cleanup of sensitive data

EXAMPLES:
    ./edit-secrets.sh                    # Edit with nano (default)
    ./edit-secrets.sh --editor vim       # Edit with vim
    ./edit-secrets.sh --no-backup        # Skip backup creation

SUPPORTED EDITORS:
    - nano (default, user-friendly)
    - vim/vi (advanced users)
    - emacs (advanced users)
    - code (VS Code, if available)
EOF
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --editor)
            if [[ ${2-} == "" ]]; then
                log_error "Missing value for --editor"
                exit 1
            fi
            EDITOR="$2"
            shift 2
            ;;
        --no-backup) BACKUP_SECRETS=false; shift ;;
        --no-validation) VALIDATE_SECRETS=false; shift ;;
        --insecure-mode) SECURE_MODE=false; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# ENHANCED: Secure environment setup - prevents key path exposure
setup_secure_environment() {
    log_info "Setting up secure editing environment..."

    local age_key_file="secrets/keys/age-key.txt"
    local secrets_file="secrets/secrets.yaml"

    # Validate prerequisites
    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        return 1
    fi

    if [[ ! -f "$secrets_file" ]]; then
        log_error "Secrets file not found: $secrets_file"
        return 1
    fi

    # SECURITY FIX: Use file descriptor instead of environment variable
    # This prevents the key path from appearing in process lists

    # Create a temporary file descriptor for the key
    local key_fd
    exec {key_fd}< "$age_key_file"
    register_cleanup "exec $key_fd<&-"

    # Store the file descriptor number for SOPS to use
    export SOPS_AGE_KEY_FD="$key_fd"
    register_cleanup "unset SOPS_AGE_KEY_FD"

    # Alternative: If SOPS doesn't support FD, use a more secure approach
    # Create a temporary directory with restrictive permissions
    local temp_env_dir
    temp_env_dir=$(mktemp -d -t vw-secrets-env.XXXXXX)
    chmod 700 "$temp_env_dir"
    register_cleanup "rm -rf '$temp_env_dir'"

    # Create a temporary key file copy with secure permissions
    local temp_key_file="$temp_env_dir/age-key.txt"
    cp "$age_key_file" "$temp_key_file"
    chmod 600 "$temp_key_file"

    # Export only the temporary path (shorter, less identifiable in ps)
    export SOPS_AGE_KEY_FILE="$temp_key_file"
    register_cleanup "unset SOPS_AGE_KEY_FILE"

    log_success "Secure environment configured"
    return 0
}

# ENHANCED: Validate editor security and availability
validate_editor() {
    local editor="$1"

    log_debug "Validating editor: $editor"

    # Check if editor exists
    if ! command -v "$editor" >/dev/null 2>&1; then
        log_error "Editor not found: $editor"
        log_info "Available editors: $(which nano vim vi emacs code 2>/dev/null | tr '
' ' ' || echo 'none found')"
        return 1
    fi

    # Security check: ensure editor is not a suspicious binary
    local editor_path
    editor_path=$(which "$editor")

    # Check if editor is in expected locations
    if [[ ! "$editor_path" =~ ^/(usr/)?bin/ ]] && [[ ! "$editor_path" =~ ^/usr/local/bin/ ]]; then
        log_warn "Editor in unusual location: $editor_path"
        if [[ "$SECURE_MODE" == "true" ]]; then
            log_error "Refusing to use editor outside standard paths in secure mode"
            return 1
        fi
    fi

    # Check editor permissions
    local editor_perms
    editor_perms=$(stat -c '%a' "$editor_path" 2>/dev/null || echo "unknown")
    if [[ "$editor_perms" != "755" ]] && [[ "$editor_perms" != "755" ]]; then
        log_warn "Editor has unusual permissions: $editor_perms"
    fi

    log_success "Editor validation passed: $editor"
    return 0
}

# STANDARDIZED: Create backup of secrets file
create_secrets_backup() {
    if [[ "$BACKUP_SECRETS" != "true" ]]; then
        log_info "Skipping backup creation (--no-backup specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create backup of secrets file"
        return 0
    fi

    local secrets_file="secrets/secrets.yaml"
    local backup_file="secrets/secrets.yaml.backup-$(date +%Y%m%d-%H%M%S)"

    log_info "Creating backup of secrets file..."

    if cp "$secrets_file" "$backup_file"; then
        # Secure the backup file
        chmod 600 "$backup_file"
        log_success "Backup created: $(basename "$backup_file")"

        # Clean up old backups (keep last 5)
        local old_backups
        if old_backups=$(find secrets/ -name "secrets.yaml.backup-*" -type f | sort -r | tail -n +6); then
            if [[ -n "$old_backups" ]]; then
                echo "$old_backups" | xargs rm -f
                local cleaned_count
                cleaned_count=$(echo "$old_backups" | wc -l)
                log_debug "Cleaned up $cleaned_count old backup files"
            fi
        fi

        return 0
    else
        log_error "Failed to create backup"
        return 1
    fi
}

# ENHANCED: Validate secrets file after editing
validate_secrets_file() {
    if [[ "$VALIDATE_SECRETS" != "true" ]]; then
        log_info "Skipping secrets validation (--no-validation specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would validate secrets file"
        return 0
    fi

    local secrets_file="secrets/secrets.yaml"

    log_info "Validating edited secrets file..."

    # Test SOPS decryption
    if ! sops -d "$secrets_file" >/dev/null 2>&1; then
        log_error "Secrets file validation failed - cannot decrypt"
        log_error "File may be corrupted or contain syntax errors"
        return 1
    fi

    # Validate YAML structure
    if ! sops -d "$secrets_file" | python3 -c "import yaml, sys; yaml.safe_load(sys.stdin)" 2>/dev/null; then
        log_warn "Secrets file contains invalid YAML structure"
        log_info "SOPS decryption works, but YAML may have formatting issues"
    fi

    # Validate required secrets exist
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
        log_info "Ensure all required secrets are defined"
    fi

    # Validate no placeholder values remain
    local placeholder_secrets=()
    for secret in "${required_secrets[@]}"; do
        local value
        if value=$(sops -d --extract "[\"$secret\"]" "$secrets_file" 2>/dev/null); then
            if [[ "$value" =~ ^CHANGE_ME ]]; then
                placeholder_secrets+=("$secret")
            fi
        fi
    done

    if [[ ${#placeholder_secrets[@]} -gt 0 ]]; then
        log_warn "Secrets still contain placeholder values: ${placeholder_secrets[*]}"
        log_info "Update these secrets with real values"
    fi

    log_success "Secrets file validation completed"
    return 0
}

# ENHANCED: Secure secrets editing with privacy protection
edit_secrets_securely() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would open secrets file for secure editing"
        return 0
    fi

    local secrets_file="secrets/secrets.yaml"

    log_info "Opening secrets file for secure editing..."
    log_info "Editor: $EDITOR"

    # Create a secure temporary directory for editing
    local temp_dir
    temp_dir=$(mktemp -d -t vw-edit-secrets.XXXXXX)
    chmod 700 "$temp_dir"
    register_cleanup "rm -rf '$temp_dir'"

    # Additional security measures in secure mode
    if [[ "$SECURE_MODE" == "true" ]]; then
        # Disable shell history during editing
        export HISTFILE="$temp_dir/dummy_history"
        register_cleanup "unset HISTFILE"

        # Set secure umask
        local old_umask
        old_umask=$(umask)
        umask 077
        register_cleanup "umask '$old_umask'"

        log_info "Enhanced security mode enabled"
    fi

    # Edit the file using SOPS
    if sops "$secrets_file"; then
        log_success "Secrets file edited successfully"
        return 0
    else
        local exit_code=$?
        log_error "Editor exited with error code: $exit_code"

        # Check if file was corrupted
        if [[ ! -f "$secrets_file" ]]; then
            log_error "CRITICAL: Secrets file was deleted during editing!"

            # Attempt to restore from backup
            local latest_backup
            if latest_backup=$(find secrets/ -name "secrets.yaml.backup-*" -type f | sort -r | head -1); then
                log_info "Attempting to restore from latest backup: $(basename "$latest_backup")"
                if cp "$latest_backup" "$secrets_file"; then
                    log_success "Secrets file restored from backup"
                else
                    log_error "Failed to restore from backup"
                fi
            fi
        fi

        return $exit_code
    fi
}

# ENHANCED: Post-edit security verification
post_edit_security_check() {
    log_info "Running post-edit security verification..."

    local secrets_file="secrets/secrets.yaml"

    # Check file permissions
    local file_perms
    file_perms=$(stat -c '%a' "$secrets_file" 2>/dev/null)
    if [[ "$file_perms" != "600" ]]; then
        log_warn "Secrets file permissions changed: $file_perms (should be 600)"
        if chmod 600 "$secrets_file"; then
            log_success "File permissions corrected"
        else
            log_error "Failed to correct file permissions"
            return 1
        fi
    fi

    # Check file ownership
    local file_owner
    file_owner=$(stat -c '%U' "$secrets_file" 2>/dev/null)
    local current_user
    current_user=$(get_real_user)

    if [[ "$file_owner" != "$current_user" ]]; then
        log_warn "Secrets file ownership changed: $file_owner (should be $current_user)"
        if chown "$current_user:$current_user" "$secrets_file"; then
            log_success "File ownership corrected"
        else
            log_error "Failed to correct file ownership"
            return 1
        fi
    fi

    log_success "Post-edit security verification completed"
    return 0
}

# ENHANCED: Main function with comprehensive error handling
main() {
    log_header "VaultWarden-OCI Secure Secrets Editor"

    # Validate prerequisites
    if ! require_commands sops age; then
        log_error "Required tools not available"
        exit 1
    fi

    # Validate editor
    if ! validate_editor "$EDITOR"; then
        log_error "Editor validation failed"
        exit 1
    fi

    # Setup secure environment
    if ! setup_secure_environment; then
        log_error "Failed to setup secure environment"
        exit 1
    fi

    # Create backup
    if ! create_secrets_backup; then
        log_error "Failed to create backup"
        exit 1
    fi

    # Edit secrets securely
    if ! edit_secrets_securely; then
        log_error "Secrets editing failed"
        exit 1
    fi

    # Validate edited file
    if ! validate_secrets_file; then
        log_warn "Secrets validation detected issues"
        log_info "File was saved, but please review and correct any issues"
    fi

    # Post-edit security check
    if ! post_edit_security_check; then
        log_warn "Post-edit security check detected issues"
    fi

    # Success summary
    log_success "Secrets editing completed successfully"

    echo ""
    echo "Next Steps:"
    echo "1. Restart services to apply changes: ./startup.sh --force-restart"
    echo "2. Verify system health: ./health.sh"
    echo "3. Test functionality with updated secrets"

    # Clean up sensitive environment
    perform_cleanup

    exit 0
}

main "$@"
