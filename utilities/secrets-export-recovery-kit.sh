#!/usr/bin/env bash
# secrets-export-recovery-kit.sh — Exports the VaultWarden recovery kit.

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
VaultWarden Secrets — export-recovery-kit subcommand

USAGE:
    ./utilities/secrets-export-recovery-kit.sh export-recovery-kit [OPTIONS]
    ./edit-secrets.sh export-recovery-kit [OPTIONS]

DESCRIPTION:
    Decrypts secrets.yaml, validates that no PLACEHOLDER values remain, then
    exports a plaintext recovery document containing the Age private key and
    all credentials. The output file is written to a tmpfs-backed directory
    (e.g. /dev/shm) with mode 0600 and an auto-delete scheduled after 30
    minutes via at(1).

    This is the canonical standalone entry point for recovery kit export.
    setup-secrets.sh delegates its post-setup export prompt here.

FLAGS:
    --help, -h    Show this help

EXAMPLES:
    ./utilities/secrets-export-recovery-kit.sh export-recovery-kit
    ./edit-secrets.sh export-recovery-kit
EOF
}

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

# Decrypt first and block export when placeholder values remain.
# Recovery kit export enforces mode 0600.
_export_recovery_kit_safe() {
    log_info "Validating secrets before recovery kit export..."

    local temp_plain
    temp_plain=$(mktemp -p /dev/shm --suffix=.yaml 2>/dev/null || mktemp --suffix=.yaml)
    if [[ -n "$temp_plain" && "$temp_plain" != /dev/shm/* ]]; then
        log_warn "export-recovery-kit: /dev/shm unavailable — plaintext temp file is disk-backed: $temp_plain"
        log_warn "                     Ensure full-disk encryption is active on this host."
    fi
    if ! install -m 600 /dev/null "$temp_plain" 2>/dev/null; then
        rm -f "$temp_plain"
        log_error "Failed to secure temp file: $temp_plain"
        return 1
    fi
    register_cleanup "_secure_shred" "$temp_plain"

    if ! ensure_sops_env; then
        log_error "Failed to setup SOPS environment"
        return 1
    fi
    local sops_rc=0
    sops -d "$SECRETS_FILE" > "$temp_plain" || sops_rc=$?
    cleanup_secrets_environment
    if [[ $sops_rc -ne 0 ]]; then
        log_error "Cannot decrypt secrets — aborting recovery kit export"
        return 1
    fi

    if ! _validate_no_placeholders "$temp_plain"; then
        log_error "Aborting recovery kit export due to unconfigured secrets."
        return 1
    fi

    log_success "No placeholder values detected — proceeding with export"

    local old_umask; old_umask=$(umask)
    umask 0177
    offer_recovery_kit_export "true"
    local _rc=$?
    umask "$old_umask"
    return $_rc
}

main() {
    if [[ "${1:-}" == "export-recovery-kit" ]]; then shift; fi

    case "${1:-}" in
        --help|-h) show_help; exit 0 ;;
        "")        ;;
        *) log_error "Unknown option: '$1'"; show_help; exit 1 ;;
    esac

    if ! check_prerequisites; then exit 1; fi
    _warn_if_stack_unavailable

    log_info "Running standalone recovery kit export..."
    _export_recovery_kit_safe
    exit $?
}

main "$@"
