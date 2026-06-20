#!/usr/bin/env bash
# utilities/secrets-edit.sh — Interactively edits VaultWarden encrypted secrets.

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
load_project_environment || exit 1
SOPS_CONFIG_FILE="${PROJECT_ROOT}/.sops.yaml"
export SOPS_CONFIG_FILE

trap perform_cleanup EXIT

show_help() {
    cat << 'EOF'
VaultWarden Secrets — rotate subcommand

USAGE:
    ./utilities/secrets-rotate.sh FIELD [OPTIONS]
    ./utilities/secrets-rotate.sh rotate FIELD [OPTIONS]  # 'rotate' accepted as alias
    ./edit-secrets.sh rotate FIELD [OPTIONS]

DESCRIPTION:
    Re-collects and re-hashes a single named credential, then atomically
    re-encrypts secrets.yaml and resyncs Docker secret bind-mount files.

SUPPORTED FIELDS:
    (yq not installed — install with: sudo apt install yq  or  snap install yq)
    admin_token                         (auto-generated admin token)
    caddy_admin_password                (bcrypt hash for Caddy)
    backup_passphrase                   (backup encryption passphrase)
    caddy_cloudflare_dns_token          (Cloudflare DNS API token)
    smtp_password                       (SMTP relay password)
    email_api_token                     (email API key)
    ... run after setup.sh install for the full schema list

EMAIL_MODE / EMAIL_PROVIDER quick reference (.env):
    EMAIL_MODE=auto   — tries API → Postfix sidecar → direct upstream SMTP in order
    EMAIL_MODE=api    — HTTP API only   (rotate: email_api_token)
    EMAIL_MODE=smtp   — Postfix sidecar → direct SMTP (rotate: smtp_password)
    EMAIL_MODE=direct — direct SMTP only (rotate: smtp_password)
    EMAIL_MODE=host   — deprecated alias for direct (rotate: smtp_password)
    EMAIL_PROVIDER=mailersend|sendgrid|mailgun|postmark|resend
        → selects which HTTP driver is used at runtime;
          the token is always stored as "email_api_token" in secrets.yaml.

FLAGS:
    --dry-run    Preview what would change without writing
    --no-backup  Skip creating backup before rotation
    --help, -h   Show this help
    --version, -V Print the VaultWarden-OCI version and exit

EXAMPLES:
    ./utilities/secrets-rotate.sh admin_token
    ./utilities/secrets-rotate.sh cf_worker_bouncer_token
    ./utilities/secrets-rotate.sh email_api_token --dry-run
    ./edit-secrets.sh rotate smtp_password
    ./edit-secrets.sh rotate backup_passphrase --no-backup

EOF
}
# Parse EDITOR into an array so flag-bearing values such as EDITOR='code --wait' work.
read -ra EDITOR_CMD <<< "${EDITOR:-nano}"
SKIP_BACKUP=false
readonly MAX_EDIT_ATTEMPTS=5

# Known forking editors that return before the user has saved.
_FORKING_EDITORS=("gvim" "mvim" "code" "atom" "subl" "sublime_text" "gedit" "kate" "mousepad")

check_prerequisites() {
    local missing=()
    if ! resolve_age_key_path 2>/dev/null; then
        missing+=("Age encryption key (not found at \$AGE_KEY_FILE, /etc/vaultwarden/age-key.txt, or secrets/keys/age-key.txt)")
    fi

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

create_backup() {
    if [[ "$SKIP_BACKUP" == "true" ]]; then
        log_info "Skipping backup (--no-backup specified)"
        return 0
    fi
    local backup_file
    backup_file="$SECRETS_BACKUP_DIR/secrets.yaml.backup-$(date +%Y%m%d-%H%M%S)"
    log_info "Creating backup: $(basename "$backup_file")"
    if ! install -m 600 -p "$SECRETS_FILE" "$backup_file" 2>/dev/null; then
        log_error "Failed to create backup"
        return 1
    fi
    log_success "Backup created"
    cleanup_old_secret_backups "$SECRETS_BACKUP_DIR" 5
    return 0
}

# Warn when the selected editor is known to fork.
_check_editor_forks() {
    local _editor_str="${EDITOR_CMD[*]}"
    case "$_editor_str" in
        *--wait*|*--nofork*|-f|*\ -f\ *|*\ -f) return 0 ;;
    esac

    local editor_bin
    editor_bin="$(basename "${EDITOR_CMD[0]}")"

    local forking
    for forking in "${_FORKING_EDITORS[@]}"; do
        if [[ "$editor_bin" == "$forking" ]]; then
            log_warn "EDITOR '$editor_bin' is known to fork and return immediately."
            log_warn "The script may re-encrypt before you save your changes."
            case "$editor_bin" in
                code)      log_warn "Use:  EDITOR='code --wait' ./edit-secrets.sh" ;;
                gvim|mvim) log_warn "Use:  EDITOR='gvim --nofork' ./edit-secrets.sh" ;;
                atom)      log_warn "Use:  EDITOR='atom --wait' ./edit-secrets.sh" ;;
                *)         log_warn "Pass a '--wait' or '--nofork' flag to your editor." ;;
            esac
            log_warn "Proceeding anyway — verify your changes are saved before this script exits."
            return 0
        fi
    done
    return 0
}

# Prints the post-edit checksum to stdout on success, exits non-zero on error.
_validate_editor_saved() {
    local temp_file="$1"
    local before_checksum="$2"

    local file_size
    file_size=$(wc -c < "$temp_file" 2>/dev/null || echo 0)
    if [[ "$file_size" -eq 0 ]]; then
        log_error "Temp file is empty after editor exit — forking editor likely returned before save."
        log_error "No changes written. Re-run with a 'wait'-capable editor invocation."
        return 1
    fi

    local after_checksum
    after_checksum=$(calculate_sha256 "$temp_file")
    printf '%s\n' "$after_checksum"
    return 0
}

# Interactively edit secrets with YAML validation and atomic re-encryption.
do_edit() {
    local _depth="${1:-0}"
    if (( _depth > MAX_EDIT_ATTEMPTS )); then
        log_error "Too many failed edit attempts (max ${MAX_EDIT_ATTEMPTS}). Aborting."
        return 1
    fi
    log_info "Opening secrets with: ${EDITOR_CMD[*]}"

    _check_editor_forks

    local temp_file
    temp_file=$(mktemp -p /dev/shm --suffix=.yaml 2>/dev/null || mktemp --suffix=.yaml)
    if [[ -n "$temp_file" && "$temp_file" != /dev/shm/* ]]; then
        log_warn "edit: /dev/shm unavailable — plaintext temp file is disk-backed: $temp_file"
        log_warn "      Ensure full-disk encryption is active on this host."
    fi
    if ! install -m 600 /dev/null "$temp_file" 2>/dev/null; then
        rm -f "$temp_file"
        log_error "Failed to secure temp file: $temp_file"
        return 1
    fi
    register_cleanup "_secure_shred" "$temp_file"

    if ! ensure_sops_env; then
        log_error "Failed to setup SOPS environment"
        return 1
    fi
    local sops_rc=0
    sops -d "$SECRETS_FILE" > "$temp_file" || sops_rc=$?
    cleanup_secrets_environment
    if [[ $sops_rc -ne 0 ]]; then
        log_error "Failed to decrypt secrets"
        return 1
    fi

    # Inject inline YAML hint comments for any key that defines a non-empty
    # 'hint' field in secrets-schema.yaml.  This loop replaces the previous
    # hardcoded sed expressions for admin_token and admin_basic_auth_hash.
    while IFS= read -r _hint_key; do
        [[ -z "$_hint_key" ]] && continue
        local _hint_text
        _hint_text=$(schema_field_safe "$_hint_key" hint 2>/dev/null)
        [[ -z "$_hint_text" ]] && continue
        # Only inject if the hint comment is not already present.
        if ! grep -qF "# ${_hint_text%%—*}" "$temp_file" 2>/dev/null; then
            local _escaped_hint
            _escaped_hint="${_hint_text//\\/\\\\}"
            _escaped_hint="${_escaped_hint//|/\\|}"
            sed -i \
                -e "s|^${_hint_key}:|# ${_escaped_hint}\\n${_hint_key}:|" \
                "$temp_file"
        fi
    done < <(schema_hinted_keys 2>/dev/null)

    local before_checksum
    before_checksum=$(calculate_sha256 "$temp_file")

    # Suppress vim/nvim swap files so plaintext secrets are not written to .swp.
    local _editor_bin
    _editor_bin="$(basename "${EDITOR_CMD[0]}")"
    local -a _effective_editor_cmd=("${EDITOR_CMD[@]}")
    case "$_editor_bin" in
        vim|vi|nvim|view|gvim|rvim|rview)
            if [[ "${EDITOR_CMD[*]}" != *"--noswapfile"* ]]; then
                _effective_editor_cmd=("${EDITOR_CMD[0]}" "-i" "NONE" "--noswapfile" "${EDITOR_CMD[@]:1}")
            fi
            ;;
    esac

    if ! "${_effective_editor_cmd[@]}" "$temp_file"; then
        log_error "Editor exited with error"
        return 1
    fi

    local after_checksum
    if ! after_checksum=$(_validate_editor_saved "$temp_file" "$before_checksum"); then
        return 1
    fi

    if [[ "$before_checksum" == "$after_checksum" ]]; then
        log_info "No changes detected - nothing to save"
        return 0
    fi

    log_info "Changes detected, validating..."

    local yaml_err
    if ! yaml_err=$(_validate_yaml_no_duplicates "$temp_file" 2>&1); then
        log_error "Invalid YAML structure after editing:"
        log_error "  $yaml_err"
        local discard
        if ! read -r -t 30 -p "Discard changes? (yes/no): " discard; then
            log_warn "No input received (30s timeout). Discarding changes."
            discard="yes"
        fi
        if [[ "$discard" == "yes" ]]; then
            log_info "Changes discarded"
            return 1
        else
            log_info "Re-opening editor to fix..."
            do_edit $(( _depth + 1 ))
            return $?
        fi
    fi

    log_info "Encrypting changes (atomic write)..."
    local encrypted_temp
    encrypted_temp=$(mktemp --suffix=.yaml --tmpdir="$(dirname "$SECRETS_FILE")")
    if ! install -m 600 /dev/null "$encrypted_temp" 2>/dev/null; then
        rm -f "$encrypted_temp"
        log_error "Failed to secure temp file: $encrypted_temp"
        return 1
    fi
    cp "$temp_file" "$encrypted_temp"

    if ! encrypt_sops_file "$encrypted_temp" "$AGE_KEY_FILE"; then
        log_error "Failed to encrypt secrets"
        rm -f "$encrypted_temp"
        return 1
    fi

    if ! sops --config "$SOPS_CONFIG_FILE" updatekeys --yes "$encrypted_temp"; then
        log_error "Failed to synchronize SOPS recipients"
        rm -f "$encrypted_temp"
        return 1
    fi
    if ! ensure_sops_env; then
        log_error "Failed to re-setup SOPS environment for validation"
        rm -f "$encrypted_temp"
        return 1
    fi
    if ! sops -d "$encrypted_temp" >/dev/null; then
        log_error "Staged encrypted secrets failed validation"
        cleanup_secrets_environment
        rm -f "$encrypted_temp"
        return 1
    fi
    cleanup_secrets_environment
    if ! mv "$encrypted_temp" "$SECRETS_FILE"; then
        log_error "Atomic mv failed — encrypted output left at: $encrypted_temp"
        return 1
    fi

    secure_secrets_file
    log_success "Secrets updated successfully"

    offer_recovery_kit_export "true"

    return 0
}

main() {
    if [[ "${1:-}" == "edit" ]]; then shift; fi

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
            --no-backup) SKIP_BACKUP=true; shift ;;
            --help|-h)   show_help; exit 0 ;;
            *) log_error "Unknown option: '$1'"; show_help; exit 1 ;;
        esac
    done

    log_header "VaultWarden Secrets Editor"

    if ! check_prerequisites; then exit 1; fi
    _warn_if_stack_unavailable
    if ! validate_secrets; then exit 1; fi
    if ! create_backup; then
        log_error "Backup failed — aborting to protect against data loss."
        log_error "Use --no-backup to skip backup creation (not recommended)."
        exit 1
    fi

    do_edit || exit 1
}

main "$@"
