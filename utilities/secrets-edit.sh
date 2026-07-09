#!/usr/bin/env bash
# utilities/secrets-edit.sh — Interactively edits VaultWarden encrypted secrets.

HISTFILE=/dev/null
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

show_help() {
    cat << 'EOF'
VaultWarden Secrets — edit subcommand

USAGE:
    sudo ./utilities/secrets-edit.sh [OPTIONS]
    sudo ./utilities/secrets-edit.sh edit [OPTIONS]  # 'edit' accepted as alias
    sudo ./edit-secrets.sh edit [OPTIONS]

DESCRIPTION:
    Decrypts secrets.yaml to a protected temporary file, opens it in your
    editor, validates YAML after save, then atomically re-encrypts it.

FLAGS:
    --editor EDITOR Override editor for this run
    --no-backup     Skip creating backup before edit
    --help, -h      Show this help
    --version, -V   Print the VaultWarden-OCI version and exit

EXAMPLES:
    sudo ./utilities/secrets-edit.sh
    sudo ./utilities/secrets-edit.sh --editor vim
    EDITOR='code --wait' sudo ./edit-secrets.sh edit
EOF
}

show_version() {
    printf 'VaultWarden-OCI %s\n' "$(tr -d '[:space:]' < "${PROJECT_ROOT}/VERSION" 2>/dev/null || echo unknown)"
}

dispatch_information_request() {
    local -a args=("$@")
    local index=0

    if [[ "${args[0]:-}" == "edit" ]]; then
        index=1
    fi

    while [[ $index -lt ${#args[@]} ]]; do
        case "${args[$index]}" in
            --editor)
                if [[ $((index + 1)) -ge ${#args[@]} || -z "${args[$((index + 1))]}" ||
                      "${args[$((index + 1))]}" == --* ]]; then
                    echo "ERROR: --editor requires an argument (e.g. --editor vim)" >&2
                    show_help >&2
                    exit 1
                fi
                index=$((index + 2))
                ;;
            --no-backup)
                index=$((index + 1))
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --version|-V)
                show_version
                exit 0
                ;;
            *)
                echo "ERROR: Unknown option: '${args[$index]}'" >&2
                show_help >&2
                exit 1
                ;;
        esac
    done
}

dispatch_information_request "$@"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
require_root "$@"
source "${PROJECT_ROOT}/lib/operations.sh"
source "${PROJECT_ROOT}/lib/crypto.sh"
source "${PROJECT_ROOT}/lib/secrets.sh"

_secrets_edit_policy="fail"
if [[ ! -t 0 || ! -t 1 ]]; then
    _secrets_edit_policy="skip"
fi
operation_acquire \
    --id secrets \
    --label "Secrets edit" \
    --specific-lock /run/lock/vaultwarden-secrets.lock \
    --non-interactive "$_secrets_edit_policy" || exit $?
_secrets_edit_cleanup() {
    local rc=$?
    operation_release "$rc"
    perform_cleanup
    exit "$rc"
}
trap _secrets_edit_cleanup EXIT
trap 'operation_release 130; perform_cleanup; exit 130' INT
trap 'operation_release 143; perform_cleanup; exit 143' HUP TERM
operation_set_phase "edit" "Editing encrypted secrets"

load_project_environment || exit 1
SOPS_CONFIG_FILE="${PROJECT_ROOT}/.sops.yaml"
export SOPS_CONFIG_FILE

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
        log_info "To create secrets, run: sudo ./setup.sh secrets"
        return 1
    fi
    return 0
}

validate_secrets() {
    log_info "Validating secrets file..."
    if ! ensure_sops_env; then return 1; fi
    if ! validate_secrets_decryption "$SECRETS_FILE"; then
        log_error "Cannot decrypt secrets file - Age key may be incorrect or file corrupted"
        return 1
    fi
    if ! validate_secrets_yaml "$SECRETS_FILE"; then
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

_secret_fingerprints_from_plain_file() {
    local yaml_file="$1"
    python3 - "$yaml_file" <<'PYEOF'
import hashlib
import sys
import yaml

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = yaml.safe_load(handle) or {}
if not isinstance(data, dict):
    sys.exit(0)
for key in sorted(data):
    if key == "sops":
        continue
    value = data[key]
    text = "" if value is None else str(value)
    print(f"{key}\t{hashlib.sha256(text.encode()).hexdigest()[:12]}")
PYEOF
}

_changed_keys_from_fingerprints() {
    local before="$1"
    local after="$2"
    declare -A _before=()
    declare -A _after=()
    declare -A _all=()
    local key fp

    while IFS=$'\t' read -r key fp; do
        [[ -z "$key" ]] && continue
        _before["$key"]="$fp"
        _all["$key"]=1
    done <<< "$before"

    while IFS=$'\t' read -r key fp; do
        [[ -z "$key" ]] && continue
        _after["$key"]="$fp"
        _all["$key"]=1
    done <<< "$after"

    for key in "${!_all[@]}"; do
        if [[ "${_before[$key]:-}" != "${_after[$key]:-}" ]]; then
            printf '%s\n' "$key"
        fi
    done | sort
}

_print_post_edit_apply_guidance() {
    local changed_keys=("$@")
    [[ ${#changed_keys[@]} -gt 0 ]] || return 0

    log_info "Changed secret keys: ${changed_keys[*]}"
    log_info "No plaintext values were printed; changes were detected by fingerprints."
    log_info "Post-edit apply guidance:"

    local key apply_type targets target
    for key in "${changed_keys[@]}"; do
        if ! schema_key_exists "$key" 2>/dev/null; then
            if [[ "$key" == "backup_passphrase" ]]; then
                log_info "  ${key}: legacy key retained for compatibility; no active apply action."
            else
                log_warn "  ${key}: unknown key; no apply action available."
            fi
            continue
        fi

        apply_type=$(schema_apply_type_for_key "$key" 2>/dev/null || printf 'none')
        targets=$(schema_apply_targets_for_key "$key" 2>/dev/null || printf '')
        case "$apply_type" in
            compose_restart)
                for target in $targets; do
                    log_info "  ${key}: docker compose restart ${target}"
                done
                ;;
            systemd_restart)
                for target in $targets; do
                    log_info "  ${key}: sudo systemctl restart ${target}"
                done
                ;;
            crowdsec_worker_config)
                log_warn "  ${key}: CrowdSec Workers config is stale until re-rendered."
                log_warn "  Retry/apply exactly: sudo ./utilities/crowdsec-worker-apply.sh"
                ;;
            none)
                log_info "  ${key}: no restart required."
                ;;
            *)
                log_warn "  ${key}: unknown apply type '${apply_type}'."
                ;;
        esac
    done
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

    local before_key_fingerprints
    before_key_fingerprints="$(_secret_fingerprints_from_plain_file "$temp_file")"

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
        if ! read -r -t 30 -p "Discard changes? [yes/no]: " discard; then
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

    local schema_err
    if ! schema_err=$(validate_plaintext_secrets_schema_contract "$temp_file" 2>&1); then
        log_error "Secrets schema validation failed after editing:"
        while IFS= read -r _schema_line; do
            [[ -n "$_schema_line" ]] && log_error "  $_schema_line"
        done <<< "$schema_err"
        local discard_schema
        if ! read -r -t 30 -p "Discard changes? [yes/no]: " discard_schema; then
            log_warn "No input received (30s timeout). Discarding changes."
            discard_schema="yes"
        fi
        if [[ "$discard_schema" == "yes" ]]; then
            log_info "Changes discarded"
            return 1
        else
            log_info "Re-opening editor to fix..."
            do_edit $(( _depth + 1 ))
            return $?
        fi
    fi

    local after_key_fingerprints changed_keys
    after_key_fingerprints="$(_secret_fingerprints_from_plain_file "$temp_file")"
    changed_keys="$(_changed_keys_from_fingerprints "$before_key_fingerprints" "$after_key_fingerprints")"

    log_info "Encrypting changes (atomic write)..."
    local encrypted_temp
    encrypted_temp=$(mktemp --suffix=.yaml --tmpdir="$(dirname "$SECRETS_FILE")")
    if ! install -m 600 /dev/null "$encrypted_temp" 2>/dev/null; then
        rm -f "$encrypted_temp"
        log_error "Failed to secure temp file: $encrypted_temp"
        return 1
    fi
    cp "$temp_file" "$encrypted_temp"

    local _age_key_path
    if ! _age_key_path=$(resolve_age_key_path 2>/dev/null); then
        log_error "Cannot resolve Age key path for re-encryption"
        rm -f "$encrypted_temp"
        return 1
    fi
    if ! encrypt_sops_file "$encrypted_temp" "$_age_key_path"; then
        log_error "Failed to encrypt secrets"
        rm -f "$encrypted_temp"
        return 1
    fi

    if ! SOPS_AGE_KEY_FILE="$_age_key_path" sops --config "$SOPS_CONFIG_FILE" updatekeys --yes "$encrypted_temp"; then
        log_error "Failed to synchronize SOPS recipients"
        rm -f "$encrypted_temp"
        return 1
    fi
    if ! SOPS_AGE_KEY_FILE="$_age_key_path" sops -d "$encrypted_temp" >/dev/null; then
        log_error "Staged encrypted secrets failed validation"
        rm -f "$encrypted_temp"
        return 1
    fi
    if ! mv "$encrypted_temp" "$SECRETS_FILE"; then
        log_error "Atomic mv failed — encrypted output left at: $encrypted_temp"
        return 1
    fi

    secure_secrets_file "$SECRETS_FILE"
    log_success "Secrets updated successfully"

    local docker_dir="/run/vaultwarden-oci/secrets"
    log_info "Synchronizing runtime secret files..."
    if ! export_docker_secrets "$docker_dir" "$SECRETS_FILE"; then
        log_error "Secrets were encrypted, but runtime secret reconciliation failed."
        log_error "Retry after fixing the reported issue: sudo make up"
        return 1
    fi
    if ! prepare_push_secret_placeholders "$docker_dir"; then
        log_error "Secrets were encrypted, but push placeholder preparation failed."
        log_error "Retry after fixing the reported issue: sudo make up"
        return 1
    fi
    log_success "Runtime secret files synchronized"

    if [[ -n "$changed_keys" ]]; then
        local -a _changed_key_array
        mapfile -t _changed_key_array <<< "$changed_keys"
        _print_post_edit_apply_guidance "${_changed_key_array[@]}"
    fi

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
            --version|-V) show_version; exit 0 ;;
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
