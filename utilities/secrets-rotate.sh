#!/usr/bin/env bash
# utilities/secrets-rotate.sh — Rotates a VaultWarden credential and resyncs dependent secret files.

HISTFILE=/dev/null
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

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
    Derived at runtime from secrets-schema.yaml.
    Run after setup.sh install for the full schema list, or inspect:
      secrets/secrets-schema.yaml

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
    --dry-run     Preview what would change without writing
    --no-backup   Skip creating backup before rotation
    --help, -h    Show this help
    --version, -V Print the VaultWarden-OCI version and exit

EXAMPLES:
    ./utilities/secrets-rotate.sh admin_token
    ./utilities/secrets-rotate.sh cf_worker_bouncer_token
    ./utilities/secrets-rotate.sh email_api_token --dry-run
    ./edit-secrets.sh rotate smtp_password
    ./edit-secrets.sh rotate backup_passphrase --no-backup

EOF
}

show_version() {
    local version
    version=$(tr -d '[:space:]' < "${PROJECT_ROOT}/VERSION" 2>/dev/null || echo "unknown")
    printf 'VaultWarden-OCI %s\n' "${version:-unknown}"
}

dispatch_information_request() {
    local -a args=("$@")
    local index=0

    if [[ "${args[0]:-}" == "rotate" ]]; then
        index=1
    fi

    if [[ $index -lt ${#args[@]} && "${args[$index]}" != --* &&
          "${args[$index]}" != "-h" && "${args[$index]}" != "-V" ]]; then
        index=$((index + 1))
    fi

    while [[ $index -lt ${#args[@]} ]]; do
        case "${args[$index]}" in
            --dry-run|--no-backup)
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
                return
                ;;
        esac
    done
}

dispatch_information_request "$@"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
refuse_root_for_user_command "Do not run with sudo. Run: ./utilities/secrets-rotate.sh <field>"
source "${PROJECT_ROOT}/lib/crypto.sh"
source "${PROJECT_ROOT}/lib/secrets.sh"
load_project_environment || exit 1
SOPS_CONFIG_FILE="${PROJECT_ROOT}/.sops.yaml"
export SOPS_CONFIG_FILE

log_debug "secrets-rotate: SECRETS_FILE resolved to: ${SECRETS_FILE}"

trap perform_cleanup EXIT

DRY_RUN=false
SKIP_BACKUP=false

declare -A _FIELD_SERVICES=()
_ROTATE_FIELDS=()

_populate_field_services() {
    local _pk
    while IFS= read -r _pk; do
        [[ -z "$_pk" ]] && continue
        local _svcs
        _svcs=$(schema_services_for_key "$_pk" 2>/dev/null) || _svcs=""
        _FIELD_SERVICES["$_pk"]="$_svcs"
    done < <(schema_keys 2>/dev/null)
}

check_prerequisites() {
    local missing=()
    local _resolved_key
    if ! _resolved_key=$(resolve_age_key_path 2>/dev/null); then
        missing+=("Age encryption key (not found at /etc/vaultwarden/age-key.txt or secrets/keys/age-key.txt)")
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

_print_rotation_receipt() {
    local field="$1"
    local old_fp="$2"
    local new_fp="$3"
    local docker_synced="$4"
    local services_list="$5"
    local rotated_at
    rotated_at=$(date '+%Y-%m-%d %H:%M:%S %Z')

    printf '\n'
    log_header "Rotation Receipt"

    printf '  %-22s %s\n'  "Field:"      "$field"
    printf '  %-22s %s\n'  "Rotated at:" "$rotated_at"
    printf '\n'
    printf '  %-22s %s\n'  "Old fingerprint:"  "${old_fp:-unset} (SHA-256 prefix, first 12 chars)"
    printf '  %-22s %s\n'  "New fingerprint:"  "${new_fp}        (SHA-256 prefix, first 12 chars)"
    printf '\n'

    # Docker secrets sync status
    if [[ "$docker_synced" == "true" ]]; then
        printf '  %-22s %s\n' "Docker secrets:" \
            "$(printf '%s✔ Resynced%s' "${COLOR_GREEN}" "${COLOR_RESET}")"
    else
        printf '  %-22s %s\n' "Docker secrets:" \
            "$(printf '%s✖ Not synced — run: ./startup.sh or ./setup.sh secrets%s' \
                "${COLOR_YELLOW}" "${COLOR_RESET}")"
    fi

    # Services restart reminder
    printf '\n'
    if [[ -n "$services_list" ]]; then
        printf '  %sServices requiring restart:%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
        local svc
        for svc in $services_list; do
            printf '    %s→%s docker compose restart %s\n' \
                "${COLOR_CYAN}" "${COLOR_RESET}" "$svc"
        done
    else
        printf '  %sServices requiring restart:%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
        printf '    %s→%s docker compose restart <service>\n' \
            "${COLOR_CYAN}" "${COLOR_RESET}"
    fi

    printf '\n'
    log_hint "Fingerprints are non-reversible — use them only to confirm the value changed."
    printf '\n'
}

_validate_rotate_field() {
    local field="$1"
    # Use schema_key_exists for an O(1) lookup rather than iterating the array.
    if schema_key_exists "$field" 2>/dev/null; then
        return 0
    fi
    log_error "Unknown field: $field"
    log_info  "Supported fields: ${_ROTATE_FIELDS[*]}"
    return 1
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

do_rotate() {
    local field="$1"

    if ! _validate_rotate_field "$field"; then return 1; fi

    local actual_field="$field"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would rotate secret: $actual_field"
        local _svc="${_FIELD_SERVICES[$field]:-<service>}"
        log_info "[DRY RUN] After rotation, you would need to restart: $_svc"
        log_info "[DRY RUN] No changes written."
        return 0
    fi

    log_info "Rotating secret: $actual_field"
    echo ""

    local temp_plain
    temp_plain=$(mktemp -p /dev/shm --suffix=.yaml 2>/dev/null || mktemp --suffix=.yaml)
    if ! install -m 600 /dev/null "$temp_plain" 2>/dev/null; then
        rm -f "$temp_plain"
        log_error "Failed to secure temp file: $temp_plain"
        return 1
    fi
    if [[ -n "$temp_plain" && "$temp_plain" != /dev/shm/* ]]; then
        log_warn "rotate: /dev/shm unavailable — plaintext temp file is disk-backed: $temp_plain"
        log_warn "        Ensure full-disk encryption is active on this host."
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
        log_error "Failed to decrypt secrets for rotation"
        return 1
    fi

    local old_fingerprint
    old_fingerprint=$(python3 - "$temp_plain" "$actual_field" <<'PYEOF' 2>/dev/null || true
import sys, hashlib, re
path, field = sys.argv[1], sys.argv[2]
val = ""
pat = re.compile("^" + re.escape(field) + r":\s*(.*)$")
for line in open(path, encoding="utf-8"):
    m = pat.match(line.rstrip("\n"))
    if m:
        val = m.group(1).strip().strip(chr(34) + chr(39))
        break
print(hashlib.sha256(val.encode()).hexdigest()[:12] if val else "unset")
PYEOF
)

    local new_value
    local auto_fn
    auto_fn=$(schema_field_safe "$field" "auto_fn" 2>/dev/null) || auto_fn=""
    if [[ -n "$auto_fn" ]]; then
        if ! declare -F "$auto_fn" >/dev/null 2>&1; then
            log_error "rotate: schema auto_fn '$auto_fn' is not defined for '$field'"
            return 1
        fi
        new_value=$("$auto_fn" "$field") || return 1
    elif [[ "$field" == "email_api_token" ]]; then
        local _ep
        _ep=$(_read_dotenv_value EMAIL_PROVIDER "${PROJECT_ROOT}/.env")
        _ep="${_ep:-email}"
        local _raw_token
        if ! read -r -s -t 120 -p "email_api_token (${_ep} API key): " _raw_token; then
            log_error "No input received (120s timeout). Aborting."
            return 1
        fi
        echo ""
        if [[ -z "$_raw_token" ]]; then
            log_error "No token entered. Aborting."
            return 1
        fi
        new_value="$_raw_token"
    else
        if ! new_value=$(collect_secret_field "$field"); then
            return 1
        fi
    fi

    local temp_patched
    temp_patched=$(mktemp -p /dev/shm --suffix=.yaml 2>/dev/null || mktemp --suffix=.yaml)
    if ! install -m 600 /dev/null "$temp_patched" 2>/dev/null; then
        rm -f "$temp_patched"
        log_error "Failed to secure temp file: $temp_patched"
        return 1
    fi
    if [[ -n "$temp_patched" && "$temp_patched" != /dev/shm/* ]]; then
        log_warn "rotate: /dev/shm unavailable — patched temp file is disk-backed: $temp_patched"
        log_warn "        Ensure full-disk encryption is active on this host."
    fi
    register_cleanup "_secure_shred" "$temp_patched"

    local _patch_rc=0
    python3 - "$temp_plain" "$actual_field" "$new_value" "$temp_patched" << 'PYEOF' || _patch_rc=$?
import sys, re

def yaml_scalar(value):
    escaped = (value
        .replace('\\', '\\\\')
        .replace('"',  '\\"')
        .replace('\n', '\\n')
        .replace('\r', '\\r')
        .replace('\t', '\\t'))
    return '"' + escaped + '"'

src_file, field, new_value, dst_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(src_file, 'r', encoding='utf-8') as f:
    content = f.read()

yaml_value = yaml_scalar(new_value)

pattern = r'^(' + re.escape(field) + r':\s*).*$'
replacement = lambda m: m.group(1) + yaml_value
new_content, n = re.subn(pattern, replacement, content, flags=re.MULTILINE)

if n == 0:
    new_content = content.rstrip('\n') + '\n' + field + ': ' + yaml_value + '\n'

with open(dst_file, 'w', encoding='utf-8') as f:
    f.write(new_content)
PYEOF

    if [[ $_patch_rc -ne 0 ]]; then
        log_error "Failed to patch YAML for field: $actual_field"
        return 1
    fi

    if ! _validate_yaml_no_duplicates "$temp_patched" 2>&1; then
        log_error "Patched YAML is invalid - aborting"
        return 1
    fi

    local new_fingerprint
    new_fingerprint=$(printf '%s' "$new_value" | sha256sum | awk '{print substr($1,1,12)}')
    log_info "Rotation preview for '${actual_field}':"
    printf '  %-10s %s\n' "before:" "$old_fingerprint"
    printf '  %-10s %s\n' "after:"  "$new_fingerprint"
    if [[ -t 0 ]]; then
        local confirm_rotate
        read -r -p "Apply this rotation? [y/N] " confirm_rotate
        if [[ ! "${confirm_rotate,,}" =~ ^y(es)?$ ]]; then
            log_info "Rotation cancelled by operator."
            return 0
        fi
    fi

    log_info "Re-encrypting secrets (atomic write)..."
    local temp_enc
    temp_enc=$(mktemp --suffix=.yaml --tmpdir="$(dirname "$SECRETS_FILE")")
    if ! install -m 600 /dev/null "$temp_enc" 2>/dev/null; then
        rm -f "$temp_enc"
        log_error "Failed to secure temp file: $temp_enc"
        return 1
    fi
    cp "$temp_patched" "$temp_enc"

    local _age_key_path
    if ! _age_key_path=$(resolve_age_key_path 2>/dev/null); then
        log_error "Cannot resolve Age key path for re-encryption"
        rm -f "$temp_enc"
        return 1
    fi
    if ! encrypt_sops_file "$temp_enc" "$_age_key_path"; then
        log_error "Failed to re-encrypt secrets"
        rm -f "$temp_enc"
        return 1
    fi

    if ! sops --config "$SOPS_CONFIG_FILE" updatekeys --yes "$temp_enc"; then
        log_error "Failed to synchronize SOPS recipients"
        rm -f "$temp_enc"
        return 1
    fi
    if ! SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" sops -d "$temp_enc" >/dev/null; then
        log_error "Staged encrypted secrets failed validation"
        rm -f "$temp_enc"
        return 1
    fi

    if ! mv "$temp_enc" "$SECRETS_FILE"; then
        log_error "Atomic mv failed — encrypted output in: $temp_enc"
        return 1
    fi

    secure_secrets_file
    log_success "Secret '${actual_field}' rotated successfully"

    local _affected_service="${_FIELD_SERVICES[$field]:-}"

    log_info "Redeploying Docker secret files..."
    local docker_dir="/run/vaultwarden-oci/secrets"
    local _docker_synced="false"
    if export_docker_secrets "$docker_dir" "$SECRETS_FILE" 2>/dev/null; then
        log_success "Docker secret files updated"
        _docker_synced="true"
    else
        log_warn "Could not auto-redeploy Docker secret files. Run: ./startup.sh or ./setup.sh secrets"
    fi

    _print_rotation_receipt \
        "$actual_field"           \
        "$old_fingerprint"        \
        "$new_fingerprint"        \
        "$_docker_synced"         \
        "${_affected_service}"

    offer_recovery_kit_export "false"

    return 0
}

main() {
    if [[ "${1:-}" == "rotate" ]]; then shift; fi

    local rotate_field=""

    if [[ $# -gt 0 && "${1}" != --* ]]; then
        rotate_field="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)   DRY_RUN=true;     shift ;;
            --no-backup) SKIP_BACKUP=true; shift ;;
            --help|-h)   show_help; exit 0 ;;
            --version|-V) print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0 ;;
            *) log_error "Unknown option: '$1'"; show_help; exit 1 ;;
        esac
    done

    mapfile -t _ROTATE_FIELDS < <(schema_keys 2>/dev/null)
    _populate_field_services
    unset -f _populate_field_services

    if [[ -z "$rotate_field" ]]; then
        log_error "'rotate' requires a FIELD argument."
        log_error "Example: ./edit-secrets.sh rotate admin_token"
        log_error "Supported fields: ${_ROTATE_FIELDS[*]}"
        exit 1
    fi

    if ! check_prerequisites; then exit 1; fi
    _warn_if_stack_unavailable

    if ! create_backup; then
        log_error "Backup failed — aborting to protect against data loss."
        log_error "Use --no-backup to skip backup creation (not recommended)."
        exit 1
    fi

    do_rotate "$rotate_field" || exit 1
}

main "$@"
