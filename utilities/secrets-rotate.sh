#!/usr/bin/env bash
# utilities/secrets-rotate.sh — Rotates a VaultWarden credential and resyncs dependent secret files.

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
VaultWarden Secrets — rotate subcommand

USAGE:
    ./utilities/secrets-rotate.sh FIELD [OPTIONS]
    ./utilities/secrets-rotate.sh rotate FIELD [OPTIONS]  # 'rotate' accepted as alias
    ./edit-secrets.sh rotate FIELD [OPTIONS]

DESCRIPTION:
    Re-collects and re-hashes a single named credential, then atomically
    re-encrypts secrets.yaml and resyncs Docker secret bind-mount files.

SUPPORTED FIELDS:
    admin_token              (Argon2id re-hash)
    admin_basic_auth_hash    (bcrypt re-hash)
    caddy_cloudflare_dns_token
    email_api_token          (HTTP API token for email provider)
    smtp_password            (SMTP relay password)
    push_installation_id
    push_installation_key
    backup_passphrase        (auto-generated)

EMAIL_MODE / EMAIL_PROVIDER quick reference (.env):
    EMAIL_MODE=auto   — tries API → SMTP → Postfix in order
    EMAIL_MODE=api    — HTTP API only   (rotate: email_api_token)
    EMAIL_MODE=smtp   — SMTP relay only (rotate: smtp_password)
    EMAIL_MODE=host   — Postfix sidecar (no token or password needed)
    EMAIL_PROVIDER=mailersend|sendgrid|mailgun|postmark|resend
        → selects which HTTP driver is used at runtime;
          the token is always stored as "email_api_token" in secrets.yaml.

FLAGS:
    --dry-run    Preview what would change without writing
    --no-backup  Skip creating backup before rotation
    --help, -h   Show this help

EXAMPLES:
    ./utilities/secrets-rotate.sh admin_token
    ./utilities/secrets-rotate.sh email_api_token --dry-run
    ./edit-secrets.sh rotate smtp_password
    ./edit-secrets.sh rotate backup_passphrase --no-backup
EOF
}

DRY_RUN=false
SKIP_BACKUP=false

_ROTATE_FIELDS=("admin_token" "admin_basic_auth_hash"
                "caddy_cloudflare_dns_token"
                "email_api_token"
                "smtp_password" "push_installation_id" "push_installation_key"
                "backup_passphrase")

# Map each rotatable field to the Docker service or services that consume it.
declare -A _FIELD_SERVICES
_FIELD_SERVICES=(
    [admin_token]="vaultwarden"
    [admin_basic_auth_hash]="vaultwarden"
    [caddy_cloudflare_dns_token]="caddy"
    [email_api_token]="vaultwarden"
    [smtp_password]="vaultwarden"
    [push_installation_id]="vaultwarden"
    [push_installation_key]="vaultwarden"
    [backup_passphrase]="vaultwarden"
)

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

_validate_rotate_field() {
    local field="$1"
    local f
    for f in "${_ROTATE_FIELDS[@]}"; do
        [[ "$f" == "$field" ]] && return 0
    done
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

    # Prompt for email_api_token directly because it is stored as a plain token.
    # Delegate all other fields to the canonical collect_secret_field() helper.
    local new_value
    if [[ "$field" == "email_api_token" ]]; then
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

    # Patch the YAML value with regex substitution to preserve existing YAML comments.
    # Using yaml.dump() would strip comments on the first write.
    #
    # NOTE: yaml_scalar() below produces double-quoted YAML scalars, handling \, ",
    # newline, carriage return, and tab escapes. This intentionally differs from
    # yaml_escape() in utilities/setup-secrets.sh, which produces single-quoted scalars
    # and only escapes embedded single quotes. yaml_scalar() is required here because
    # rotated values such as Argon2id hashes and random tokens may contain backslashes,
    # double quotes, or non-printable characters that single-quote style cannot encode.
    # yaml_escape() in setup-secrets.sh writes a fresh YAML file where values are known
    # ASCII with no special characters, so the simpler style is adequate there.
    local _patch_rc=0
    python3 - "$temp_plain" "$actual_field" "$new_value" "$temp_patched" << 'PYEOF' || _patch_rc=$?
import sys, re

def yaml_scalar(value):
    # Produce a YAML double-quoted scalar with proper escape sequences.
    # Double-quoted scalars handle all YAML-special characters without
    # relying on PyYAML's output format.
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

    log_info "Re-encrypting secrets (atomic write)..."
    local temp_enc
    temp_enc=$(mktemp --suffix=.yaml --tmpdir="$(dirname "$SECRETS_FILE")")
    if ! install -m 600 /dev/null "$temp_enc" 2>/dev/null; then
        rm -f "$temp_enc"
        log_error "Failed to secure temp file: $temp_enc"
        return 1
    fi
    cp "$temp_patched" "$temp_enc"

    if ! encrypt_sops_file "$temp_enc" "$AGE_KEY_FILE"; then
        log_error "Failed to re-encrypt secrets"
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
    if [[ -n "$_affected_service" ]]; then
        log_warn "Restart the following Docker service for the new secret to take effect:"
        log_warn "  docker compose restart $_affected_service"
    else
        log_warn "Run 'docker compose restart <service>' for the new secret to take effect"
    fi

    log_info "Redeploying Docker secret files..."
    local docker_dir="${PROJECT_ROOT}/secrets/.docker_secrets"
    if export_docker_secrets "$docker_dir" "$SECRETS_FILE" 2>/dev/null; then
        log_success "Docker secret files updated"
    else
        log_warn "Could not auto-redeploy Docker secret files. Run: ./startup.sh or ./setup.sh secrets"
    fi

    # Pass "false" because rotate does not auto-export a recovery kit.
    # Run utilities/secrets-export-recovery-kit.sh explicitly after rotation if needed.
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
            --dry-run)   DRY_RUN=true;    shift ;;
            --no-backup) SKIP_BACKUP=true; shift ;;
            --help|-h)   show_help; exit 0 ;;
            *) log_error "Unknown option: '$1'"; show_help; exit 1 ;;
        esac
    done

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
