#!/usr/bin/env bash
# edit-secrets.sh - VaultWarden secrets editor
# Modes: edit (default) | view (--view) | list keys (--list) | rotate field (--rotate FIELD) | export kit (--export-recovery-kit)
# Safe to re-run multiple times.  Uses your $EDITOR or falls back to nano.
#
# Canonical standalone recovery-kit export:
#   ./edit-secrets.sh --export-recovery-kit
#
# See also: ./setup-secrets.sh  (first-time creation and full reconfiguration)
#
# BUG FIX (2026-03-19):
#   FIX-ES1 [HIGH] do_edit(), do_view(), do_rotate(), and _deploy_docker_secrets()
#   called sops directly without first calling ensure_sops_env(). The
#   validate_secrets() call in main() sets SOPS_AGE_KEY_FILE via ensure_sops_env(),
#   but lib/secrets.sh cleanup_secrets_environment() (LS-2/LS-8 fixes) correctly
#   unsets it after validation completes — before any of the action functions run.
#   Fix: call ensure_sops_env() at the start of each function that invokes sops
#   directly, and call cleanup_secrets_environment() when done, mirroring the
#   pattern used throughout lib/secrets.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/secrets.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
EDITOR_CMD="${EDITOR:-nano}"
SKIP_BACKUP=false
VIEW_ONLY=false
LIST_KEYS=false
ROTATE_FIELD=""   # non-empty triggers --rotate mode
EXPORT_RECOVERY_KIT=false
DRY_RUN=false
# FIX [L-07]: Maximum recursive edit attempts before aborting
readonly MAX_EDIT_ATTEMPTS=5

# Known forking editors that return before the user has saved.
# Users of these editors MUST pass the appropriate "wait" flag themselves.
_FORKING_EDITORS=("gvim" "mvim" "code" "atom" "subl" "sublime_text" "gedit" "kate" "mousepad")

# ---------------------------------------------------------------------------
# Secure shred helper
# ---------------------------------------------------------------------------
# FIX [P3-H3]: Use _secure_shred() instead of plain rm -f for all plaintext
# YAML temp files so decrypted data cannot be recovered from CoW filesystems
# (btrfs, APFS, ZFS) where overwrite-in-place is a no-op.
# Tries shred(1), then srm(1), then falls back to a best-effort
# overwrite-via-dd before unlinking.
_secure_shred() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if command -v shred >/dev/null 2>&1; then
        shred -uzf "$file" 2>/dev/null || rm -f "$file"
    elif command -v srm >/dev/null 2>&1; then
        srm -fz "$file" 2>/dev/null || rm -f "$file"
    else
        # Best-effort: overwrite with zeros then remove
        local sz; sz=$(wc -c < "$file" 2>/dev/null || echo 0)
        if [[ "$sz" -gt 0 ]]; then
            dd if=/dev/zero of="$file" bs=1 count="$sz" conv=notrunc 2>/dev/null || true
        fi
        rm -f "$file"
    fi
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
CLEANUP_ACTIONS=()
register_cleanup() { CLEANUP_ACTIONS+=("$1"); }
perform_cleanup() {
    for ((idx=${#CLEANUP_ACTIONS[@]}-1; idx>=0; idx--)); do
        eval "${CLEANUP_ACTIONS[$idx]}" 2>/dev/null || true
    done
}
trap perform_cleanup EXIT

# ---------------------------------------------------------------------------
# _read_dotenv_value KEY [FILE]
#
# Read a single KEY from .env (or FILE) without sourcing the whole file.
# Returns the value, or an empty string if the key is not found.
# ---------------------------------------------------------------------------
_read_dotenv_value() {
    local key="$1"
    local file="${2:-.env}"
    [[ -f "$file" ]] || { echo ""; return 0; }
    local val
    val=$(grep -E "^${key}=" "$file" | head -1 | sed "s/^${key}=//;s/#.*$//;s/[[:space:]]*$//")
    echo "$val"
}

# ---------------------------------------------------------------------------
# _email_api_token_key PROVIDER
#
# Return the canonical secrets key for the given provider's HTTP API token,
# e.g. mailersend → MAILERSEND_API_TOKEN
# ---------------------------------------------------------------------------
_email_api_token_key() {
    local provider="${1,,}"   # lower-case
    echo "${provider^^}_API_TOKEN"  # upper-case + _API_TOKEN
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
show_help() {
    cat << 'HELP'
VaultWarden Secrets Editor

USAGE:
    ./edit-secrets.sh [OPTIONS]

MODES (mutually exclusive; default is interactive edit):
    --view                  View decrypted secrets read-only (no changes saved)
    --list                  List secret key names only (no values shown)
    --rotate FIELD          Re-collect and re-hash a single named field, then
                            re-encrypt.  Supported fields:
                                admin_token              (Argon2id re-hash)
                                admin_basic_auth_hash    (bcrypt re-hash)
                                caddy_cloudflare_dns_token
                                fail2ban_cloudflare_firewall_token
                                email_api_token          (HTTP API token for email
                                                          provider; key name derived
                                                          from EMAIL_PROVIDER in .env,
                                                          e.g. MAILERSEND_API_TOKEN)
                                smtp_password            (SMTP relay password;
                                                          used when EMAIL_MODE=smtp
                                                          or EMAIL_MODE=auto)
                                push_installation_id
                                push_installation_key
                                backup_passphrase        (auto-generated)

    EMAIL_MODE / EMAIL_PROVIDER quick reference (.env):
        EMAIL_MODE=auto   — lib/email.sh tries API → SMTP → Postfix in order
        EMAIL_MODE=api    — HTTP API only   (rotate: email_api_token)
        EMAIL_MODE=smtp   — SMTP relay only (rotate: smtp_password)
        EMAIL_MODE=host   — Postfix sidecar (no token or password needed)
        EMAIL_PROVIDER=mailersend|sendgrid|mailgun|postmark|resend
            → determines which key is stored, e.g.:
               mailersend → MAILERSEND_API_TOKEN
               sendgrid   → SENDGRID_API_TOKEN

    --export-recovery-kit   Generate a recovery document with unencrypted
                            secrets. This is the canonical standalone entry
                            point for recovery kit export. setup-secrets.sh
                            delegates its post-setup prompt here.

EDIT OPTIONS:
    --editor EDITOR         Use specific editor (default: $EDITOR or nano)
    --no-backup             Skip creating backup before edit
    --dry-run               Preview what --rotate would change without writing
    --help                  Show this help

FEATURES:
    ✅ Automatic backup before every edit
    ✅ Change detection (no-op if nothing changed)
    ✅ YAML validation after editing with rollback offer
    ✅ --rotate calls collect_secret_field() from lib/secrets.sh (single
       source of truth for hashing — no duplicate Argon2id/bcrypt logic)
    ✅ --rotate uses atomic write (temp file → mv) to prevent partial writes
    ✅ --list shows key names without decrypting values
    ✅ Prompts to export recovery kit upon any modification
    ✅ Recovery kit export validates no PLACEHOLDER values remain
    ✅ --rotate --dry-run previews which values would change

EXAMPLES:
    ./edit-secrets.sh                              # Interactive edit
    ./edit-secrets.sh --editor vim                 # Edit with vim
    ./edit-secrets.sh --view                       # View only
    ./edit-secrets.sh --list                       # Show key names
    ./edit-secrets.sh --rotate admin_token         # Re-hash VW admin password
    ./edit-secrets.sh --rotate admin_token --dry-run  # Preview rotation
    ./edit-secrets.sh --rotate email_api_token     # Replace email provider API key
    ./edit-secrets.sh --rotate smtp_password       # Replace SMTP relay password
    ./edit-secrets.sh --rotate caddy_cloudflare_dns_token  # Replace CF token
    ./edit-secrets.sh --export-recovery-kit        # Export a recovery document

SEE ALSO:
    ./setup-secrets.sh  - First-time creation or full reconfiguration
HELP
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --editor)              EDITOR_CMD="$2"; shift 2 ;;
        --no-backup)           SKIP_BACKUP=true; shift ;;
        --view)                VIEW_ONLY=true; shift ;;
        --list)                LIST_KEYS=true; shift ;;
        --rotate)              ROTATE_FIELD="$2"; shift 2 ;;
        --export-recovery-kit) EXPORT_RECOVERY_KIT=true; shift ;;
        --dry-run)             DRY_RUN=true; shift ;;
        --help)                show_help; exit 0 ;;
        *)                     log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Mutual-exclusion guard
# ---------------------------------------------------------------------------
_mode_count=0
[[ "$VIEW_ONLY" == "true"           ]] && _mode_count=$(( _mode_count + 1 ))
[[ "$LIST_KEYS" == "true"           ]] && _mode_count=$(( _mode_count + 1 ))
[[ -n "$ROTATE_FIELD"               ]] && _mode_count=$(( _mode_count + 1 ))
# --export-recovery-kit is a standalone mode when it is the only flag;
# it can also trail --rotate / do_edit (offer after modification).
# Standalone evaluation is handled in main().

if [[ $_mode_count -gt 1 ]]; then
    log_error "--view, --list, and --rotate are mutually exclusive"
    exit 1
fi

# ---------------------------------------------------------------------------
# Prerequisites check
# ---------------------------------------------------------------------------
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()

    if [[ ! -f "$AGE_KEY_FILE" ]]; then
        missing+=("Age encryption key: $AGE_KEY_FILE")
    elif ! check_age_key "$AGE_KEY_FILE" 2>/dev/null; then
        missing+=("Valid Age encryption key")
    fi

    [[ ! -f ".sops.yaml" ]]    && missing+=("SOPS configuration: .sops.yaml")
    [[ ! -f "$SECRETS_FILE" ]] && missing+=("Secrets file: $SECRETS_FILE")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing prerequisites:"
        for item in "${missing[@]}"; do log_error "  - $item"; done
        echo ""
        log_info "To create secrets, run: ./setup-secrets.sh"
        return 1
    fi

    log_success "All prerequisites present"
    return 0
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
validate_secrets() {
    log_info "Validating secrets file..."

    # FIX-ES1: ensure_sops_env is called here only for validation. The
    # cleanup_secrets_environment() calls inside validate_secrets_decryption()
    # and validate_secrets_yaml() (lib/secrets.sh LS-8/LS-9 fixes) will unset
    # SOPS_AGE_KEY_FILE when they return. Each action function (do_edit,
    # do_view, do_rotate, etc.) must call ensure_sops_env() independently
    # before invoking sops.
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

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
create_backup() {
    if [[ "$SKIP_BACKUP" == "true" ]]; then
        log_info "Skipping backup (--no-backup specified)"
        return 0
    fi

    local backup_file="$SECRETS_BACKUP_DIR/secrets.yaml.backup-$(date +%Y%m%d-%H%M%S)"
    log_info "Creating backup: $(basename "$backup_file")"

    if ! cp "$SECRETS_FILE" "$backup_file"; then
        log_error "Failed to create backup"
        return 1
    fi

    chmod 600 "$backup_file"
    log_success "Backup created"

    # Keep last 5 secrets backups (count-based, NOT day-based)
    cleanup_old_secret_backups "$SECRETS_BACKUP_DIR" 5

    return 0
}

# ---------------------------------------------------------------------------
# --list mode: show key names only, no values
#
# FIX [email_api_token-list]: After setup.sh but before setup-secrets.sh,
# secrets.yaml holds the generic key name "email_api_token". The operator
# needs to know what the *resolved* key name will be (e.g. MAILERSEND_API_TOKEN)
# so they can confirm what --rotate email_api_token will write.
# Resolve EMAIL_PROVIDER from .env and annotate the email_api_token line
# with its runtime key name, without exposing any values.
# ---------------------------------------------------------------------------
do_list_keys() {
    log_info "Secret key names in: $SECRETS_FILE"
    echo ""

    # Resolve the active provider token key name for annotation
    local _email_provider _api_key_name
    _email_provider=$(_read_dotenv_value "EMAIL_PROVIDER" .env)
    _email_provider="${_email_provider:-mailersend}"
    _api_key_name=$(_email_api_token_key "$_email_provider")

    # list_secret_keys() prints one key per line; post-process to annotate
    # the email_api_token entry and any already-promoted provider key.
    local raw_keys
    if ! raw_keys=$(list_secret_keys "$SECRETS_FILE" 2>&1); then
        log_error "Failed to list secret keys"
        return 1
    fi

    while IFS= read -r key; do
        if [[ "$key" == "email_api_token" ]]; then
            # Generic placeholder key — show what --rotate will resolve it to
            printf '  %s  (→ will be stored as: %s when rotated via --rotate email_api_token)\n' \
                "$key" "$_api_key_name"
        elif [[ "$key" == "$_api_key_name" ]]; then
            # Key has already been promoted by setup-secrets.sh
            printf '  %s  (active provider token for EMAIL_PROVIDER=%s)\n' \
                "$key" "$_email_provider"
        else
            printf '  %s\n' "$key"
        fi
    done <<< "$raw_keys"

    echo ""
    log_info "Active EMAIL_PROVIDER: ${_email_provider}  →  token key: ${_api_key_name}"
    log_info "Run './edit-secrets.sh --rotate email_api_token' to set or rotate the provider API key."
    log_info "Run './edit-secrets.sh --rotate <field>' to update any other specific key."
    return 0
}

# ---------------------------------------------------------------------------
# --view mode
# ---------------------------------------------------------------------------
do_view() {
    log_info "Opening secrets in view-only mode..."

    # FIX-ES1: Re-establish SOPS env — cleanup_secrets_environment() called
    # inside validate_secrets_decryption/yaml has already unset SOPS_AGE_KEY_FILE.
    if ! ensure_sops_env; then
        log_error "Failed to setup SOPS environment"
        return 1
    fi

    local temp_file
    temp_file=$(mktemp)
    chmod 600 "$temp_file"
    # FIX [P3-H3]: use _secure_shred() instead of rm -f for plaintext temp file
    register_cleanup "_secure_shred '$temp_file'"

    local sops_rc=0
    sops -d "$SECRETS_FILE" > "$temp_file" 2>&1 || sops_rc=$?
    cleanup_secrets_environment
    if [[ $sops_rc -ne 0 ]]; then
        log_error "Failed to decrypt secrets"
        return 1
    fi

    if command -v less >/dev/null 2>&1; then
        less "$temp_file"
    else
        "$EDITOR_CMD" -R "$temp_file" 2>/dev/null || cat "$temp_file"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# MEDIUM FIX: _check_editor_forks()
#
# Detects known GUI/forking editors and warns the operator they must pass
# a "wait" flag (e.g. --wait for VS Code) so the script does not re-encrypt
# an empty or unchanged temp file before the user has saved.
# ---------------------------------------------------------------------------
_check_editor_forks() {
    local editor_bin
    editor_bin=$(basename "$EDITOR_CMD")
    # Strip leading path components and any wrapper flags (take first word)
    editor_bin="${editor_bin%% *}"

    for forking in "${_FORKING_EDITORS[@]}"; do
        if [[ "$editor_bin" == "$forking" ]]; then
            log_warn "EDITOR '$editor_bin' is known to fork and return immediately."
            log_warn "The script may re-encrypt before you save your changes."
            case "$editor_bin" in
                code)   log_warn "Use:  EDITOR='code --wait' ./edit-secrets.sh" ;;
                gvim|mvim) log_warn "Use:  EDITOR='gvim --nofork' ./edit-secrets.sh" ;;
                atom)   log_warn "Use:  EDITOR='atom --wait' ./edit-secrets.sh" ;;
                *)      log_warn "Pass a '--wait' or '--nofork' flag to your editor." ;;
            esac
            log_warn "Proceeding anyway — verify your changes are saved before this script exits."
            return 0
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# MEDIUM FIX: _validate_editor_saved()
#
# After the editor process exits, verifies the temp file is non-empty and
# was actually modified (mtime changed). This catches the case where a
# forking editor returns immediately and the file is still at its original
# decrypted content (or empty).
# ---------------------------------------------------------------------------
_validate_editor_saved() {
    local temp_file="$1"
    local before_checksum="$2"

    # Hard fail if file is now empty — forking editor almost certainly returned
    # before the user had a chance to save anything.
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
# MEDIUM FIX: _validate_no_placeholders()
#
# Scans a decrypted YAML file for any values that start with PLACEHOLDER_
# or equal PLACEHOLDER_NOT_CONFIGURED. Returns 1 (with a list of offending
# keys) if any are found, so recovery kit export can be aborted.
# ---------------------------------------------------------------------------
_validate_no_placeholders() {
    local plain_yaml="$1"

    local offending
    offending=$(python3 - "$plain_yaml" <<'PYEOF' 2>/dev/null
import sys, yaml

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}

bad = []
for k, v in data.items():
    sv = str(v) if v is not None else ""
    if sv.startswith("PLACEHOLDER") or sv == "PLACEHOLDER_NOT_CONFIGURED":
        bad.append(k)

if bad:
    print("\n".join(bad))
    sys.exit(1)
PYEOF
)

    if [[ $? -ne 0 ]]; then
        log_error "Recovery kit contains unconfigured placeholder values for:"
        while IFS= read -r key; do
            log_error "  - $key"
        done <<< "$offending"
        log_error "Run './setup-secrets.sh' or './edit-secrets.sh --rotate <field>' to configure these fields first."
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# --rotate FIELD mode
#
# FIX #2: _collect_new_value() has been removed. All per-field collection,
# hashing (Argon2id / bcrypt), and validation is now handled by the single
# canonical collect_secret_field() function in lib/secrets.sh.
#
# HIGH FIX: Atomic write — sops --encrypt writes to a temp file, then
# mv atomically replaces SECRETS_FILE. An interrupted write leaves the
# original file intact.
#
# email_api_token is a dynamic field: the YAML key name is resolved from
# EMAIL_PROVIDER in .env (e.g. mailersend → MAILERSEND_API_TOKEN) so the
# stored key always matches what lib/email.sh resolves at runtime.
# ---------------------------------------------------------------------------

_ROTATE_FIELDS=("admin_token" "admin_basic_auth_hash"
                "caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token"
                "email_api_token"
                "smtp_password" "push_installation_id" "push_installation_key"
                "backup_passphrase")

# FIX [P4-UX2]: Map each rotatable field to the Docker service(s) that consume
# it so the post-rotation message tells the operator exactly what to restart.
declare -A _FIELD_SERVICES
_FIELD_SERVICES=(
    [admin_token]="vaultwarden"
    [admin_basic_auth_hash]="vaultwarden"
    [caddy_cloudflare_dns_token]="caddy"
    [fail2ban_cloudflare_firewall_token]="fail2ban"
    [email_api_token]="vaultwarden"
    [smtp_password]="vaultwarden"
    [push_installation_id]="vaultwarden"
    [push_installation_key]="vaultwarden"
    [backup_passphrase]="vaultwarden"
)

_validate_rotate_field() {
    local field="$1"
    for f in "${_ROTATE_FIELDS[@]}"; do
        [[ "$f" == "$field" ]] && return 0
    done
    log_error "Unknown field: $field"
    log_info  "Supported fields: ${_ROTATE_FIELDS[*]}"
    return 1
}

# FIX [M-10]: Deploy all Docker secret files from the encrypted YAML.
# Mirrors the logic in startup.sh prepare_docker_secrets() so the bind-mounted
# files in secrets/.docker_secrets/ stay in sync after a rotation.
_deploy_docker_secrets() {
    local docker_dir="$PROJECT_ROOT/secrets/.docker_secrets"
    local temp_plain
    temp_plain=$(mktemp --suffix=.yaml)
    chmod 600 "$temp_plain"
    # FIX [P3-H3]: use _secure_shred() for this plaintext temp file
    register_cleanup "_secure_shred '$temp_plain'"

    # FIX-ES1: Re-establish SOPS env before calling sops directly.
    if ! ensure_sops_env; then
        log_error "Failed to setup SOPS environment for Docker secret deployment"
        return 1
    fi

    local sops_rc=0
    sops -d "$SECRETS_FILE" > "$temp_plain" 2>/dev/null || sops_rc=$?
    cleanup_secrets_environment
    if [[ $sops_rc -ne 0 ]]; then
        log_error "Cannot decrypt secrets for Docker secret deployment"
        return 1
    fi

    mkdir -p "$docker_dir"
    chmod 700 "$docker_dir"

    local old_umask; old_umask=$(umask); umask 077
    local deployed=0

    # Determine the dynamic email API token key from .env
    local _email_provider _api_key_name
    _email_provider=$(_read_dotenv_value "EMAIL_PROVIDER" .env)
    _email_provider="${_email_provider:-mailersend}"
    _api_key_name=$(_email_api_token_key "$_email_provider")

    local secret_fields=(
        "admin_token" "admin_basic_auth_hash" "smtp_password"
        "backup_passphrase" "push_installation_id" "push_installation_key"
        "caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token"
        "$_api_key_name"
    )
    for field_name in "${secret_fields[@]}"; do
        local value
        value=$(python3 - "$temp_plain" "$field_name" <<'PY'
import sys, yaml
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}
v = data.get(sys.argv[2], "")
print(v if v is not None else "", end="")
PY
)
        if [[ -n "$value" ]] && [[ "$value" != "CHANGE_ME"* ]] && [[ "$value" != "NOT_USED"* ]] && [[ "$value" != "null" ]]; then
            printf '%s' "$value" > "$docker_dir/$field_name"
            (( deployed++ ))
        fi
    done
    umask "$old_umask"

    log_debug "Docker secrets deployed: $deployed"
    return 0
}

do_rotate() {
    local field="$1"

    if ! _validate_rotate_field "$field"; then exit 1; fi

    # Resolve the actual YAML key name for the email_api_token virtual field.
    # This ensures the key written to the secrets file always matches what
    # lib/email.sh will look up (e.g. MAILERSEND_API_TOKEN, SENDGRID_API_TOKEN).
    local actual_field="$field"
    local _api_key_name=""
    if [[ "$field" == "email_api_token" ]]; then
        local _email_provider
        _email_provider=$(_read_dotenv_value "EMAIL_PROVIDER" .env)
        _email_provider="${_email_provider:-mailersend}"
        _api_key_name=$(_email_api_token_key "$_email_provider")
        actual_field="$_api_key_name"
        log_info "EMAIL_PROVIDER=${_email_provider} → rotating secret key: ${actual_field}"
        log_info "(To change provider, update EMAIL_PROVIDER in .env and re-run rotate)"
        echo ""
    fi

    # LOW FIX: --dry-run support for --rotate
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
    temp_plain=$(mktemp --suffix=.yaml)
    chmod 600 "$temp_plain"
    # FIX [P3-H3]: use _secure_shred() for this plaintext temp file
    register_cleanup "_secure_shred '$temp_plain'"

    # FIX-ES1: Re-establish SOPS env before calling sops directly.
    if ! ensure_sops_env; then
        log_error "Failed to setup SOPS environment"
        return 1
    fi
    local sops_rc=0
    sops -d "$SECRETS_FILE" > "$temp_plain" 2>&1 || sops_rc=$?
    cleanup_secrets_environment
    if [[ $sops_rc -ne 0 ]]; then
        log_error "Failed to decrypt secrets for rotation"
        return 1
    fi

    # For email_api_token, prompt directly (plain token, no hashing).
    # For all other fields, delegate to the canonical collect_secret_field().
    local new_value
    if [[ "$field" == "email_api_token" ]]; then
        local _raw_token
        if ! read -r -s -t 120 -p "${actual_field}: " _raw_token; then
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
    temp_patched=$(mktemp --suffix=.yaml)
    chmod 600 "$temp_patched"
    # FIX [P3-H3]: use _secure_shred() for this plaintext patched temp file
    register_cleanup "_secure_shred '$temp_patched'"

    python3 - "$temp_plain" "$actual_field" "$new_value" "$temp_patched" << 'PYEOF'
import sys, yaml
src_file, field, new_value, dst_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(src_file) as f:
    data = yaml.safe_load(f)
# For email_api_token the key may not exist yet (first time) — insert it.
data[field] = new_value
with open(dst_file, 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)
PYEOF

    if [[ $? -ne 0 ]]; then
        log_error "Failed to patch YAML for field: $actual_field"
        return 1
    fi

    if ! python3 - "$temp_patched" <<'PYEOF' 2>/dev/null
import sys, yaml
with open(sys.argv[1]) as f:
    yaml.safe_load(f)
PYEOF
    then
        log_error "Patched YAML is invalid - aborting"
        return 1
    fi

    log_info "Re-encrypting secrets (atomic write)..."
    # HIGH FIX: Write encrypted output to a temp file on the same filesystem
    # as SECRETS_FILE so that mv(1) is atomic. If sops --encrypt is interrupted,
    # the original SECRETS_FILE is untouched.
    local temp_enc
    temp_enc=$(mktemp --suffix=.yaml.enc --tmpdir="$(dirname "$SECRETS_FILE")")
    chmod 600 "$temp_enc"

    # FIX-ES1: Re-establish SOPS env for the encrypt step.
    if ! ensure_sops_env; then
        log_error "Failed to setup SOPS environment for re-encryption"
        rm -f "$temp_enc"
        return 1
    fi
    local enc_rc=0
    sops --encrypt "$temp_patched" > "$temp_enc" 2>&1 || enc_rc=$?
    cleanup_secrets_environment
    if [[ $enc_rc -ne 0 ]]; then
        log_error "Failed to re-encrypt secrets"
        rm -f "$temp_enc"
        return 1
    fi

    # Atomic replacement: mv on the same filesystem is a single syscall.
    if ! mv "$temp_enc" "$SECRETS_FILE"; then
        log_error "Atomic mv failed — encrypted output in: $temp_enc"
        return 1
    fi

    secure_secrets_file

    log_success "Secret '${actual_field}' rotated successfully"

    # FIX [P4-UX2]: Tell the operator exactly which Docker service to restart.
    local _affected_service="${_FIELD_SERVICES[$field]:-}"
    if [[ -n "$_affected_service" ]]; then
        log_warn "Restart the following Docker service for the new secret to take effect:"
        log_warn "  docker compose restart $_affected_service"
    else
        log_warn "Run 'docker compose restart <service>' for the new secret to take effect"
    fi

    # FIX [M-10]: After successful rotation, redeploy Docker secret files so
    # the live bind-mounted secrets stay in sync with the encrypted YAML.
    log_info "Redeploying Docker secret files..."
    if _deploy_docker_secrets 2>/dev/null; then
        log_success "Docker secret files updated"
    else
        log_warn "Could not auto-redeploy Docker secret files. Run: ./startup.sh or ./setup-secrets.sh"
    fi

    offer_recovery_kit_export "$EXPORT_RECOVERY_KIT"

    return 0
}

# ---------------------------------------------------------------------------
# Default: interactive edit
# ---------------------------------------------------------------------------
# FIX [L-07]: Added _depth parameter to prevent unbounded recursion when the
# user repeatedly saves invalid YAML and chooses not to discard changes.
#
# MEDIUM FIX: Editor fork detection + post-edit file-size check added.
# HIGH FIX: Encrypted output written atomically via temp file + mv.
do_edit() {
    local _depth="${1:-0}"
    if (( _depth > MAX_EDIT_ATTEMPTS )); then
        log_error "Too many failed edit attempts (max ${MAX_EDIT_ATTEMPTS}). Aborting."
        return 1
    fi
    log_info "Opening secrets with: $EDITOR_CMD"

    # MEDIUM FIX: Warn user if their editor is known to fork (return before save).
    _check_editor_forks

    local temp_file
    temp_file=$(mktemp --suffix=.yaml)
    chmod 600 "$temp_file"
    # FIX [P3-H3]: use _secure_shred() for this plaintext temp file
    register_cleanup "_secure_shred '$temp_file'"

    # FIX-ES1: Re-establish SOPS env — validate_secrets() called ensure_sops_env()
    # but cleanup_secrets_environment() inside validate_secrets_decryption/yaml
    # has already unset SOPS_AGE_KEY_FILE by the time do_edit() runs.
    if ! ensure_sops_env; then
        log_error "Failed to setup SOPS environment"
        return 1
    fi
    local sops_rc=0
    sops -d "$SECRETS_FILE" > "$temp_file" 2>&1 || sops_rc=$?
    cleanup_secrets_environment
    if [[ $sops_rc -ne 0 ]]; then
        log_error "Failed to decrypt secrets"
        return 1
    fi

    local before_checksum
    before_checksum=$(calculate_sha256 "$temp_file")

    if ! "$EDITOR_CMD" "$temp_file"; then
        log_error "Editor exited with error"
        return 1
    fi

    # MEDIUM FIX: Verify the file is non-empty and get the after-checksum.
    local after_checksum
    if ! after_checksum=$(_validate_editor_saved "$temp_file" "$before_checksum"); then
        return 1
    fi

    if [[ "$before_checksum" == "$after_checksum" ]]; then
        log_info "No changes detected - nothing to save"
        return 0
    fi

    log_info "Changes detected, validating..."

    if ! python3 - "$temp_file" <<'PYEOF' 2>/dev/null
import sys, yaml
with open(sys.argv[1]) as f:
    yaml.safe_load(f)
PYEOF
    then
        log_error "Invalid YAML structure after editing"
        # FIX [L-04]: Add -t 30 timeout
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
    # HIGH FIX: Write encrypted output to a temp file on the same filesystem
    # as SECRETS_FILE so that mv(1) is atomic. An interrupted sops call leaves
    # the original SECRETS_FILE intact.
    local encrypted_temp
    encrypted_temp=$(mktemp --suffix=.yaml.enc --tmpdir="$(dirname "$SECRETS_FILE")")
    chmod 600 "$encrypted_temp"

    # FIX-ES1: Re-establish SOPS env for the encrypt step.
    if ! ensure_sops_env; then
        log_error "Failed to setup SOPS environment for encryption"
        rm -f "$encrypted_temp"
        return 1
    fi
    local enc_rc=0
    sops --encrypt "$temp_file" > "$encrypted_temp" 2>&1 || enc_rc=$?
    cleanup_secrets_environment
    if [[ $enc_rc -ne 0 ]]; then
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

    offer_recovery_kit_export "$EXPORT_RECOVERY_KIT"

    return 0
}

# ---------------------------------------------------------------------------
# Recovery kit export wrapper with placeholder validation
#
# MEDIUM FIX: Decrypt the file first; abort if any value is still a
# PLACEHOLDER_* string — the kit would otherwise capture unconfigured values.
#
# HIGH FIX: tar archive created with --mode=0600 so the archive file is
# always 0600 regardless of the calling process's umask.
# ---------------------------------------------------------------------------
_export_recovery_kit_safe() {
    log_info "Validating secrets before recovery kit export..."

    local temp_plain
    temp_plain=$(mktemp --suffix=.yaml)
    chmod 600 "$temp_plain"
    register_cleanup "_secure_shred '$temp_plain'"

    # FIX-ES1: Re-establish SOPS env before calling sops directly.
    if ! ensure_sops_env; then
        log_error "Failed to setup SOPS environment"
        return 1
    fi
    local sops_rc=0
    sops -d "$SECRETS_FILE" > "$temp_plain" 2>&1 || sops_rc=$?
    cleanup_secrets_environment
    if [[ $sops_rc -ne 0 ]]; then
        log_error "Cannot decrypt secrets — aborting recovery kit export"
        return 1
    fi

    # MEDIUM FIX: Block export if any placeholder values remain.
    if ! _validate_no_placeholders "$temp_plain"; then
        log_error "Aborting recovery kit export due to unconfigured secrets."
        return 1
    fi

    log_success "No placeholder values detected — proceeding with export"

    # Delegate to the upstream offer_recovery_kit_export() from lib/secrets.sh.
    # That function handles the Age key inclusion, tar creation, and GPG
    # signing. We only intercept it to add the placeholder guard above and
    # enforce a secure tar mode below.
    #
    # HIGH FIX: The upstream function uses `tar cf` which inherits the calling
    # umask. We override umask to 0177 (result: 0600) for the duration of
    # the export and restore it immediately after. This is belt-and-suspenders:
    # the underlying tar call in lib/secrets.sh is also patched to pass
    # --mode=0600 when creating the archive entry.
    local old_umask; old_umask=$(umask)
    umask 0177
    offer_recovery_kit_export "true"
    local _rc=$?
    umask "$old_umask"
    return $_rc
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log_header "VaultWarden Secrets Editor"

    if ! check_prerequisites; then exit 1; fi

    # Standalone export: --export-recovery-kit with no other mode flag.
    # This is the canonical single entry point for recovery kit export (Fix #1).
    if [[ "$EXPORT_RECOVERY_KIT" == "true" && "$_mode_count" -eq 0 ]]; then
        log_info "Running standalone recovery kit export..."
        # FIX-ES1: ensure_sops_env is called inside _export_recovery_kit_safe()
        # directly before the sops call, so no need to set it here.
        _export_recovery_kit_safe
        exit $?
    fi

    if ! validate_secrets; then exit 1; fi

    # Backup before any write operation
    if [[ "$VIEW_ONLY" != "true" && "$LIST_KEYS" != "true" ]]; then
        create_backup || log_warn "Backup failed - continuing anyway"
    fi

    if   [[ "$LIST_KEYS" == "true" ]]; then do_list_keys             || exit 1
    elif [[ "$VIEW_ONLY" == "true" ]]; then do_view                  || exit 1
    elif [[ -n "$ROTATE_FIELD"     ]]; then do_rotate "$ROTATE_FIELD" || exit 1
    else                                    do_edit                  || exit 1
    fi

    exit 0
}

main "$@"
