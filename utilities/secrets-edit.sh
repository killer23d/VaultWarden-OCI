#!/usr/bin/env bash
# utilities/secrets-edit.sh — Interactively edit VaultWarden encrypted secrets
#
# Standalone admin tool. Also invocable via: ./edit-secrets.sh edit
#
# USAGE:
#   ./utilities/secrets-edit.sh edit [OPTIONS]
#   ./edit-secrets.sh edit [OPTIONS]
#
# FLAGS:
#   --editor EDITOR    Use specific editor (default: $EDITOR or nano)
#   --no-backup        Skip creating backup before edit
#   --help, -h         Show this help

HISTFILE=/dev/null
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
source "${PROJECT_ROOT}/lib/crypto.sh"
source "${PROJECT_ROOT}/lib/secrets.sh"

trap perform_cleanup EXIT

show_help() {
    cat << 'EOF'
VaultWarden Secrets — edit subcommand

USAGE:
    ./utilities/secrets-edit.sh edit [OPTIONS]
    ./edit-secrets.sh edit [OPTIONS]

DESCRIPTION:
    Interactively decrypts, opens in $EDITOR, validates, re-encrypts, and
    backs up the secrets file. Offers recovery kit export on every save.

FLAGS:
    --editor EDITOR    Use specific editor (default: $EDITOR or nano).
                       Pass flags in quotes: --editor 'code --wait'
    --no-backup        Skip creating a timestamped backup before editing
    --help, -h         Show this help

FEATURES:
    ✅ Automatic backup before every edit
    ✅ Change detection (no-op if nothing changed)
    ✅ YAML duplicate-key validation with rollback offer
    ✅ vim/nvim swap-file suppression (--noswapfile -i NONE)
    ✅ Forking-editor detection (code, gvim, atom, ...)
    ✅ Prompts to export recovery kit after any modification

EXAMPLES:
    ./utilities/secrets-edit.sh edit
    ./utilities/secrets-edit.sh edit --editor vim
    ./edit-secrets.sh edit --editor 'code --wait'
    ./edit-secrets.sh edit --no-backup
EOF
}

# Parse EDITOR into an array to support flags (e.g. EDITOR='code --wait').
read -ra EDITOR_CMD <<< "${EDITOR:-nano}"
SKIP_BACKUP=false
readonly MAX_EDIT_ATTEMPTS=5

# Known forking editors that return before the user has saved.
_FORKING_EDITORS=("gvim" "mvim" "code" "atom" "subl" "sublime_text" "gedit" "kate" "mousepad")

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

# ---------------------------------------------------------------------------
# _check_editor_forks — warn when the selected editor is known to fork
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# _validate_editor_saved TEMP_FILE BEFORE_CHECKSUM
#
# Prints the post-edit checksum to stdout on success, exits non-zero on error.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# do_edit — interactive edit with YAML validation and atomic re-encrypt
# ---------------------------------------------------------------------------
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

    # Inject inline YAML hints for hashed fields (idempotent — only once).
    if ! grep -q "^# HASHED (Argon2id)" "$temp_file"; then
        sed -i \
            -e 's|^admin_token:|# HASHED (Argon2id) — do NOT type plaintext here. Use: ./edit-secrets.sh rotate admin_token\nadmin_token:|' \
            "$temp_file"
    fi
    if ! grep -q "^# HASHED (bcrypt)" "$temp_file"; then
        sed -i \
            -e 's|^admin_basic_auth_hash:|# HASHED (bcrypt) — do NOT type plaintext here. Use: ./edit-secrets.sh rotate admin_basic_auth_hash\nadmin_basic_auth_hash:|' \
            "$temp_file"
    fi

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

    if ! mv "$encrypted_temp" "$SECRETS_FILE"; then
        log_error "Atomic mv failed — encrypted output left at: $encrypted_temp"
        return 1
    fi

    secure_secrets_file
    log_success "Secrets updated successfully"

    offer_recovery_kit_export "false"

    return 0
}

main() {
    # Strip the leading "edit" token if called as: secrets-edit.sh edit
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
