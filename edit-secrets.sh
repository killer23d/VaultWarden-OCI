#!/usr/bin/env bash
# edit-secrets.sh - Secure secrets editor
# REFACTORED: Uses lib/secrets.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/secrets.sh"

# Configuration
EDITOR="${EDITOR:-nano}"
DRY_RUN=false
NO_BACKUP=false
NO_VALIDATION=false

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
VaultWarden Secrets Editor

USAGE:
    ./edit-secrets.sh [OPTIONS]

OPTIONS:
    --editor EDITOR     Editor (default: nano)
    --no-backup         Skip backup
    --no-validation     Skip validation
    --dry-run           Preview
    --help              Help

EXAMPLES:
    ./edit-secrets.sh
    ./edit-secrets.sh --editor vim
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --editor) EDITOR="${2:-nano}"; shift 2 ;;
        --no-backup) NO_BACKUP=true; shift ;;
        --no-validation) NO_VALIDATION=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown: $1"; show_help; exit 1 ;;
    esac
done

# Validate editor
validate_editor() {
    if ! command -v "$EDITOR" >/dev/null 2>&1; then
        log_error "Editor not found: $EDITOR"
        return 1
    fi
    return 0
}

# Edit secrets
edit_secrets() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would open with $EDITOR"
        return 0
    fi
    
    log_info "Opening with $EDITOR..."
    
    if ! setup_secrets_environment; then
        return 1
    fi
    
    if sops "$SECRETS_FILE"; then
        log_success "Edited successfully"
        return 0
    else
        log_error "Editor failed"
        return 1
    fi
}

# Main
main() {
    log_header "VaultWarden Secrets Editor"
    
    if ! require_commands sops age; then
        exit 1
    fi
    
    if ! validate_editor; then
        exit 1
    fi
    
    if ! secrets_file_exists; then
        log_error "File not found: $SECRETS_FILE"
        log_info "Run ./setup-secrets.sh first"
        exit 1
    fi
    
    if [[ "$NO_BACKUP" != "true" ]]; then
        create_secrets_backup || exit 1
        cleanup_old_backups
    fi
    
    if ! edit_secrets; then
        exit 1
    fi
    
    if [[ "$NO_VALIDATION" != "true" ]]; then
        log_info "Validating..."
        validate_secrets_decryption || log_warn "Decryption failed"
        validate_secrets_yaml || log_warn "YAML invalid"
        validate_required_secrets || log_warn "Missing secrets"
        check_placeholder_values || log_warn "Placeholders remain"
    fi
    
    secure_secrets_file
    
    log_success "Complete"
    echo ""
    echo "Next: ./startup.sh --force-restart"
    
    exit 0
}

main "$@"
