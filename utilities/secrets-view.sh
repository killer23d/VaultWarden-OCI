#!/usr/bin/env bash
# secrets-view.sh — Views decrypted VaultWarden secrets in read-only mode.

HISTFILE=/dev/null
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
source "${PROJECT_ROOT}/lib/crypto.sh"
source "${PROJECT_ROOT}/lib/secrets.sh"

trap perform_cleanup EXIT

show_help() {
    cat << 'EOF'
VaultWarden Secrets — view subcommand

USAGE:
    ./utilities/secrets-view.sh [OPTIONS]
    ./utilities/secrets-view.sh view [OPTIONS]  # 'view' accepted as alias
    ./edit-secrets.sh view [OPTIONS]

DESCRIPTION:
    Decrypts and displays secrets in read-only mode. No changes are saved.

FLAGS:
    --editor EDITOR    Override pager/viewer (default: less, then $EDITOR -R)
    --help, -h         Show this help

EXAMPLES:
    ./utilities/secrets-view.sh
    ./utilities/secrets-view.sh --editor vim
    ./edit-secrets.sh view
EOF
}

# Parse EDITOR into an array so values like 'code --wait' keep their flags.
read -ra EDITOR_CMD <<< "${EDITOR:-nano}"

check_prerequisites() {
    local missing=()
    [[ ! -f "$AGE_KEY_FILE" ]] && missing+=("Age encryption key: $AGE_KEY_FILE")
    [[ ! -f ".sops.yaml" ]]    && missing+=("SOPS configuration: .sops.yaml")
    [[ ! -f "$SECRETS_FILE" ]] && missing+=("Secrets file: $SECRETS_FILE")
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing prerequisites:"
        for item in "${missing[@]}"; do log_error "  - $item"; done
        log_info "To create secrets, run: ./setup.sh secrets"
        return 1
    fi
    return 0
}

validate_secrets() {
    log_info "Validating secrets file..."
    if ! ensure_sops_env; then return 1; fi
    if ! validate_secrets_decryption; then
        log_error "Cannot decrypt secrets file - Age key may be incorrect or file corrupted"
        return 1
    fi
    if ! validate_secrets_yaml; then
        log_warn "Secrets file has invalid YAML structure (continuing - you may be fixing it)"
    fi
    log_success "Secrets validation passed"
    return 0
}

do_view() {
    log_info "Opening secrets in view-only mode..."
    log_warn "⚠  Hashed fields (admin_token, admin_basic_auth_hash) are stored as one-way hashes."
    log_warn "   The displayed hash is NOT the password. Use 'rotate <field>' to change them."

    if ! ensure_sops_env; then
        log_error "Failed to setup SOPS environment"
        return 1
    fi

    local temp_file
    temp_file=$(mktemp -p /dev/shm 2>/dev/null || mktemp)
    if [[ -n "$temp_file" && "$temp_file" != /dev/shm/* ]]; then
        log_warn "view: /dev/shm unavailable — plaintext temp file is disk-backed: $temp_file"
        log_warn "      Ensure full-disk encryption is active on this host."
    fi
    if ! install -m 600 /dev/null "$temp_file" 2>/dev/null; then
        rm -f "$temp_file"
        log_error "Failed to secure temp file: $temp_file"
        return 1
    fi
    register_cleanup "_secure_shred" "$temp_file"

    local sops_rc=0
    sops -d "$SECRETS_FILE" > "$temp_file" || sops_rc=$?
    cleanup_secrets_environment
    if [[ $sops_rc -ne 0 ]]; then
        log_error "Failed to decrypt secrets"
        return 1
    fi

    if command -v less >/dev/null 2>&1; then
        less "$temp_file"
    else
        "${EDITOR_CMD[@]}" -R "$temp_file" 2>/dev/null || cat "$temp_file"
    fi

    return 0
}

main() {
    if [[ "${1:-}" == "view" ]]; then shift; fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --editor)
                if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
                    log_error "--editor requires an argument (e.g. --editor vim)"
                    exit 1
                fi
                read -ra EDITOR_CMD <<< "$2"
                shift 2
                ;;
            --help|-h) show_help; exit 0 ;;
            *) log_error "Unknown option: '$1'"; show_help; exit 1 ;;
        esac
    done

    if ! check_prerequisites; then exit 1; fi
    _warn_if_stack_unavailable
    if ! validate_secrets; then exit 1; fi

    do_view || exit 1
}

main "$@"
