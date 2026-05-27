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
    cf_worker_bouncer_token  (CrowdSec Cloudflare Workers bouncer API token)
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
    ./utilities/secrets-rotate.sh cf_worker_bouncer_token
    ./utilities/secrets-rotate.sh email_api_token --dry-run
    ./edit-secrets.sh rotate smtp_password
    ./edit-secrets.sh rotate backup_passphrase --no-backup
EOF
}

DRY_RUN=false
SKIP_BACKUP=false

_ROTATE_FIELDS=("admin_token" "admin_basic_auth_hash"
                "caddy_cloudflare_dns_token"
                "cf_worker_bouncer_token"
                "email_api_token"
                "smtp_password" "push_installation_id" "push_installation_key"
                "backup_passphrase")

# Map each rotatable field to the Docker service or services that consume it.
declare -A _FIELD_SERVICES
_FIELD_SERVICES=(
    [admin_token]="vaultwarden"
    [admin_basic_auth_hash]="vaultwarden"
    [caddy_cloudflare_dns_token]="caddy"
    [cf_worker_bouncer_token]="crowdsec-cloudflare-worker-bouncer"
    [email_api_token]="vaultwarden"
    [smtp_password]="vaultwarden"
    [push_installation_id]="vaultwarden"
    [push_installation_key]="vaultwarden"
    [backup_passphrase]="vaultwarden"
)

check_prerequisites() {
    local missing=()
    # FIX: resolve_age_key_path() instead of bare $AGE_KEY_FILE which is never
    # exported to the environment, causing 'unbound variable' at set -u.
    local _resolved_key
    if ! _resolved_key=$(resolve_age_key_path 2>/dev/null); then
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
    backup_f