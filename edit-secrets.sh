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
RESTART_AFTER=false  # --restart-after: auto docker compose restart after rotation
EXPORT_RECOVERY_KIT=false
DRY_RUN=false

readonly MAX_EDIT_ATTEMPTS=5

_FORKING_EDITORS=("gvim" "mvim" "code" "atom" "subl" "sublime_text" "gedit" "kate" "mousepad")

# ---------------------------------------------------------------------------
# Secure shred helper
# ---------------------------------------------------------------------------
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
# _secure_shred_dir DIR
# Shred every file inside DIR then remove the directory itself.
# Registered as a cleanup handler for tmpfs-backed temp directories so the
# EXIT trap wipes the whole tree even after a crash or Ctrl-C.
# ---------------------------------------------------------------------------
_secure_shred_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    while IFS= read -r -d "" f; do
        _secure_shred "$f" 2>/dev/null || true
    done < <(find "$dir" -type f -print0 2>/dev/null)
    rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# _secure_tmpdir
#
# Create and return a fresh temp directory.  Prefers /dev/shm (tmpfs — data
# never touches a persistent block-volume) with a fallback to /tmp when
# /dev/shm is absent or not writable (e.g. some container runtimes).
# ---------------------------------------------------------------------------
_secure_tmpdir() {
    if [[ -d /dev/shm && -w /dev/shm ]]; then
        mktemp -d -p /dev/shm
    else
        mktemp -d
    fi
}

# ---------------------------------------------------------------------------
# Cleanup — safe array-based dispatch; no eval.
# register_cleanup FUNCTION ARG  — register a single-argument cleanup call.
# perform_cleanup                — execute in reverse registration order.
# ---------------------------------------------------------------------------
CLEANUP_FUNCS=()
CLEANUP_ARGS=()
register_cleanup() { CLEANUP_FUNCS+=("$1"); CLEANUP_ARGS+=("$2"); }
perform_cleanup() {
    local idx
    for ((idx=${#CLEANUP_FUNCS[@]}-1; idx>=0; idx--)); do
        "${CLEANUP_FUNCS[$idx]}" "${CLEANUP_ARGS[$idx]}" 2>/dev/null || true
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
# _validate_yaml_no_duplicates FILE
# ---------------------------------------------------------------------------
_validate_yaml_no_duplicates() {
    local yaml_file="$1"
    python3 - "$yaml_file" <<'PYEOF'
import sys, yaml

class _NoDupLoader(yaml.SafeLoader):
    pass

def _check_no_dup_mapping(loader, node):
    keys_seen = {}
    for key_node, _ in node.value:
        key = loader.construct_object(key_node)
        if key in keys_seen:
            raise ValueError(
                f"Duplicate mapping key '{key}' "
                f"(first at line {keys_seen[key]}, "
                f"again at line {key_node.start_mark.line + 1})"
            )
        keys_seen[key] = key_node.start_mark.line + 1
    return loader.construct_mapping(node, deep=True)

_NoDupLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _check_no_dup_mapping,
)

try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        yaml.load(f, Loader=_NoDupLoader)
except (yaml.YAMLError, ValueError) as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(1)
PYEOF
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
                                                          provider; always stored
                                                          under the fixed key
                                                          "email_api_token" in
                                                          secrets.yaml regardless
                                                          of EMAIL_PROVIDER)
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
            → selects which HTTP driver lib/email.sh uses at runtime;
              the token is always stored as "email_api_token" in secrets.yaml.

    --export-recovery-kit   Generate a recovery document with unencrypted
                            secrets. This is the canonical standalone entry
                            point for recovery kit export. setup-secrets.sh
                            delegates its post-setup prompt here.

EDIT OPTIONS:
    --editor EDITOR         Use specific editor (default: $EDITOR or nano)
    --no-backup             Skip creating backup before edit
    --dry-run               Preview what --rotate would change without writing
    --restart-after         After a successful --rotate, automatically run
                            'docker compose restart <affected_service>' so the
                            new secret takes effect immediately.  Without this
                            flag the script prints a manual restart reminder
                            instead (safer for unattended or scripted runs).
    --help                  Show this help

FEATURES:
    ✅ Automatic backup before every edit
    ✅ Change detection (no-op if nothing changed)
    ✅ YAML validation after editing with rollback offer
    ✅ --rotate calls collect_secret_field() from lib/secrets.sh (single
       source of truth for hashing — no duplicate Argon2id/bcrypt logic)
    ✅ --rotate uses atomic write (temp file → mv) to prevent partial writes
    ✅ --restart-after auto-restarts the affected Docker service post-rotation
    ✅ --list shows key names without decrypting values
    ✅ Prompts to export recovery kit upon any modification
    ✅ Recovery kit export validates no PLACEHOLDER values remain
    ✅ --rotate --dry-run previews which values would change

EXAMPLES:
    ./edit-secrets.sh                                          # Interactive edit
    ./edit-secrets.sh --editor vim                             # Edit with vim
    ./edit-secrets.sh --view                                   # View only
    ./edit-secrets.sh --list                                   # Show key names
    ./edit-secrets.sh --rotate admin_token                     # Re-hash VW admin password
    ./edit-secrets.sh --rotate admin_token --dry-run           # Preview rotation
    ./edit-secrets.sh --rotate admin_token --restart-after     # Rotate + auto-restart vaultwarden
    ./edit-secrets.sh --rotate caddy_cloudflare_dns_token --restart-after  # Rotate + restart caddy
    ./edit-secrets.sh --rotate email_api_token                 # Replace email provider API key
    ./edit-secrets.sh --rotate smtp_password                   # Replace SMTP relay password
    ./edit-secrets.sh --export-recovery-kit                    # Export a recovery document

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
        --restart-after)       RESTART_AFTER=true; shift ;;
        --export-recovery-kit) EXPORT_RECOVERY_KIT=true; shift ;;
        --dry-run)             DRY_RUN=true; shift ;;
        --help)                show_help; exit 0 ;;
        *)                     log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --restart-after is only valid with --rotate
if [[ "$RESTART_AFTER" == "true" && -z "$ROTATE_FIELD" ]]; then
    log_error "--restart-after requires --rotate FIELD"
    exit 1
fi

# ---------------------------------------------------------------------------
# Mutual-exclusion guard
# ---------------------------------------------------------------------------
_mode_count=0
[[ "$VIEW_ONLY" == "true"           ]] && _mode_count=$(( _mode_count + 1 ))
[[ "$LIST_KEYS" == "true"           ]] && _mode_count=$(( _mode_count + 1 ))
[[ -n "$ROTATE_FIELD"               ]] && _mode_count=$(( _mode_count + 1 ))

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

    cleanup_old_secret_backups "$SECRETS_BACKUP_DIR" 5

    return 0
}

# ---------------------------------------------------------------------------
# --list mode: show key names only, no values
# ---------------------------------------------------------------------------
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
            printf '  %s  (email provider API token — used by EMAIL_PROVIDER=%s)\n' \
                "$key" "$(_read_dotenv_value EMAIL_PROVIDER .env || echo smtp)"
        else
            printf '  %s\n' "$key"
        fi
    done <<< "$raw_keys"

    echo ""
    log_info "Run './edit-secrets.sh --rotate email_api_token' to set or rotate the provider API key."
    log_info "Run './edit-secrets.sh --rotate <field>' to update any other specific key."
    return 0
}

# ---------------------------------------------------------------------------
# --view mode
# ---------------------------------------------------------------------------
do_view() {
    log_info "Opening secrets in view-only mode..."

    if ! ensure_sops_env; then
        log_error "Failed to setup SOPS environment"
        return 1
    fi

    local _view_tmpdir
    _view_tmpdir=$(_secure_tmpdir)
    register_cleanup "_secure_shred_dir" "$_view_tmpdir"
    local temp_file="$_view_tmpdir/secrets-view.yaml"
    if ! install -m 600 /dev/null "$temp_file" 2>/dev/null; then
        log_error "Failed to secure temp file: $temp_file"
        return 1
    fi

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

_ROTATE_FIELDS=("admin_token" "admin_basic_auth_hash"
                "caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token"
                "email_api_token"
                "smtp_password" "push_installation_id" "push_installation_key"
                "backup_passphrase")

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

_deploy_docker_secrets() {
    local docker_dir="$PROJECT_ROOT/secrets/.docker_secrets"

    local _deploy_tmpdir
    _deploy_tmpdir=$(_secure_tmpdir)
    register_cleanup "_secure_shred_dir" "$_deploy_tmpdir"
    local temp_plain="$_deploy_tmpdir/secrets-deploy.yaml"
    if ! install -m 600 /dev/null "$temp_plain" 2>/dev/null; then
        log_error "Failed to secure temp file: $temp_plain"
        return 1
    fi

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

    local secret_fields=(
        "admin_token" "admin_basic_auth_hash" "smtp_password"
        "backup_passphrase" "push_installation_id" "push_installation_key"
        "caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token"
        "email_api_token"
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

    local actual_field="$field"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would rotate secret: $actual_field"
        local _svc="${_FIELD_SERVICES[$field]:-<service>}"
        log_info "[DRY RUN] Affected Docker service: $_svc"
        if [[ "$RESTART_AFTER" == "true" ]]; then
            log_info "[DRY RUN] --restart-after is set: would run 'docker compose restart $_svc'"
        else
            log_info "[DRY RUN] Manual restart required: make restart  (or: docker compose restart $_svc)"
        fi
        log_info "[DRY RUN] No changes written."
        return 0
    fi

    log_info "Rotating secret: $actual_field"
    echo ""

    local _rotate_tmpdir
    _rotate_tmpdir=$(_secure_tmpdir)
    register_cleanup "_secure_shred_dir" "$_rotate_tmpdir"
    local temp_plain="$_rotate_tmpdir/secrets-rotate.yaml"
    if ! install -m 600 /dev/null "$temp_plain" 2>/dev/null; then
        log_error "Failed to secure temp file: $temp_plain"
        return 1
    fi

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

    local new_value
    if [[ "$field" == "email_api_token" ]]; then
        local _raw_token
        if ! read -r -s -t 120 -p "email_api_token (your ${EMAIL_PROVIDER:-email} API key): " _raw_token; then
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

    local temp_patched="$_rotate_tmpdir/secrets-patched.yaml"
    if ! install -m 600 /dev/null "$temp_patched" 2>/dev/null; then
        log_error "Failed to secure temp file: $temp_patched"
        return 1
    fi

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

    log_info "Redeploying Docker secret files..."
    if _deploy_docker_secrets 2>/dev/null; then
        log_success "Docker secret files updated"
    else
        log_warn "Could not auto-redeploy Docker secret files. Run: ./startup.sh or ./setup-secrets.sh"
    fi

    local _affected_service="${_FIELD_SERVICES[$field]:-}"
    if [[ "$RESTART_AFTER" == "true" ]]; then
        if [[ -n "$_affected_service" ]]; then
            log_info "Restarting Docker service: $_affected_service ..."
            local restart_rc=0
            docker compose restart "$_affected_service" 2>&1 || restart_rc=$?
            if [[ $restart_rc -eq 0 ]]; then
                log_success "Service '$_affected_service' restarted — new secret is active."
            else
                log_warn "'docker compose restart $_affected_service' failed (exit $restart_rc)."
                log_warn "Restart manually: make restart  (or: docker compose restart $_affected_service)"
            fi
        else
            log_warn "No service mapping found for '$field'. Restart manually: make restart"
        fi
    else
        log_warn "Secret rotated. Restart required: make restart"
        if [[ -n "$_affected_service" ]]; then
            log_warn "  Affected service: $_affected_service"
            log_warn "  Quick restart:    docker compose restart $_affected_service"
        fi
        log_warn "  Or add --restart-after to rotate and restart in one step."
    fi

    offer_recovery_kit_export "$EXPORT_RECOVERY_KIT"

    return 0
}

# ---------------------------------------------------------------------------
# Default: interactive edit
# ---------------------------------------------------------------------------
do_edit() {
    local _depth="${1:-0}"
    if (( _depth > MAX_EDIT_ATTEMPTS )); then
        log_error "Too many failed edit attempts (max ${MAX_EDIT_ATTEMPTS}). Aborting."
        return 1
    fi
    log_info "Opening secrets with: $EDITOR_CMD"

    _check_editor_forks

    local _edit_tmpdir
    _edit_tmpdir=$(_secure_tmpdir)
    register_cleanup "_secure_shred_dir" "$_edit_tmpdir"
    local temp_file="$_edit_tmpdir/secrets-edit.yaml"
    if ! install -m 600 /dev/null "$temp_file" 2>/dev/null; then
        log_error "Failed to secure temp file: $temp_file"
        return 1
    fi

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

    offer_recovery_kit_export "$EXPORT_RECOVERY_KIT"

    return 0
}

_export_recovery_kit_safe() {
    log_info "Validating secrets before recovery kit export..."

    local _export_tmpdir
    _export_tmpdir=$(_secure_tmpdir)
    register_cleanup "_secure_shred_dir" "$_export_tmpdir"
    local temp_plain="$_export_tmpdir/secrets-export.yaml"
    if ! install -m 600 /dev/null "$temp_plain" 2>/dev/null; then
        log_error "Failed to secure temp file: $temp_plain"
        return 1
    fi

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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log_header "VaultWarden Secrets Editor"

    if ! check_prerequisites; then exit 1; fi

    if [[ "$EXPORT_RECOVERY_KIT" == "true" && "$_mode_count" -eq 0 ]]; then
        log_info "Running standalone recovery kit export..."
        _export_recovery_kit_safe
        exit $?
    fi

    if ! validate_secrets; then exit 1; fi

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
