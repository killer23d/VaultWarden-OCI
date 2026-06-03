#!/usr/bin/env bash
# utilities/secrets-list.sh — Lists VaultWarden secret key names without showing secret values.

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

show_help() {
    cat << 'EOF'
VaultWarden Secrets — list subcommand

USAGE:
    ./utilities/secrets-list.sh list [OPTIONS]
    ./edit-secrets.sh list

DESCRIPTION:
    Lists secret key names only — no values are decrypted or displayed.

FLAGS:
    --help, -h    Show this help

EXAMPLES:
    ./utilities/secrets-list.sh list
    ./edit-secrets.sh list
EOF
}


do_list_keys() {
    log_info "Secret key names in: $SECRETS_FILE"
    echo ""

    local raw_keys
    if ! raw_keys=$(list_secret_keys "$SECRETS_FILE" 2>&1); then
        log_error "Failed to list secret keys"
        return 1
    fi

    while IFS= read -r key; do
        if [[ "$key" == "email_api_token" ]]; then
            local _provider
            _provider=$(_read_dotenv_value EMAIL_PROVIDER "${PROJECT_ROOT}/.env")
            _provider="${_provider:-mailersend}"
            printf '  %s  (email provider API token — used by EMAIL_PROVIDER=%s)\n' \
                "$key" "$_provider"
        else
            printf '  %s\n' "$key"
        fi
    done <<< "$raw_keys"

    echo ""

    # Derive the list of hashed fields from the schema so the warning stays in
    # sync with secrets-schema.yaml without manual updates here.
    local -a _hashed_keys=()
    while IFS= read -r _lkey; do
        [[ -z "$_lkey" ]] && continue
        local _lhash
        _lhash=$(schema_field_safe "$_lkey" hash 2>/dev/null)
        if [[ "$_lhash" == "argon2id" || "$_lhash" == "bcrypt" ]]; then
            _hashed_keys+=("$_lkey")
        fi
    done < <(schema_keys 2>/dev/null)

    if [[ ${#_hashed_keys[@]} -gt 0 ]]; then
        log_warn "⚠  Hashed fields: ${_hashed_keys[*]} are one-way hashes."
        log_warn "   Decrypting the secrets file will show the hash, not the original password."
        log_warn "   To change them: ./edit-secrets.sh rotate ${_hashed_keys[0]}"
    fi

    echo ""
    log_info "Canonical production key path: /etc/vaultwarden/age-key.txt (installed by setup.sh)"
    log_info "Run './edit-secrets.sh rotate email_api_token' to set or rotate the provider API key."
    log_info "Run './edit-secrets.sh rotate <field>' to update any other specific key."
    return 0
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

main() {
    if [[ "${1:-}" == "list" ]]; then shift; fi

    case "${1:-}" in
        --help|-h) show_help; exit 0 ;;
        "")        ;;
        *) log_error "Unknown option: '$1'"; show_help; exit 1 ;;
    esac

    if ! check_prerequisites; then exit 1; fi

    do_list_keys || exit 1
}

main "$@"
