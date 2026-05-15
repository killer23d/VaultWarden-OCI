#!/usr/bin/env bash
# edit-secrets.sh - VaultWarden secrets editor
# Modes: edit | view | list | rotate FIELD | export-recovery-kit
# Safe to re-run multiple times.  Uses your $EDITOR or falls back to nano.
#
# Canonical standalone recovery-kit export:
#   ./edit-secrets.sh export-recovery-kit
#
# See also: ./setup.sh secrets  (first-time creation and full reconfiguration)
#
# ---------------------------------------------------------------------------
# SCOPE AND STORAGE GUARD — READ BEFORE MODIFYING
# ---------------------------------------------------------------------------
# This script manages repo-managed encrypted configuration:
#   secrets/secrets.yaml       — SOPS/Age-encrypted runtime secrets
#   secrets/.docker_secrets/   — bind-mounted plaintext Docker secret files
#   secrets/keys/              — Age key (local dev path)
#   .env                       — project environment variables
#   .sops.yaml                 — SOPS key-binding configuration
#
# It does NOT read from or write to PROJECT_STATE_DIR (the VaultWarden
# runtime data directory, which in separate-volume mode lives on a dedicated
# block device, e.g. /mnt/vw-data).
#
# Therefore this script intentionally does NOT call require_project_state_ready()
# from lib/storage.sh.  Enforcing a storage guard here would prevent operators
# from rotating credentials or exporting a recovery kit during the very
# storage incidents where those actions are most needed.
#
# Post-rotation actions (Docker secret file sync, docker compose restart
# guidance) may fail or be deferred when the stack is down — those failures
# are already handled gracefully by _deploy_docker_secrets() and do_rotate().
# A non-blocking preflight (_warn_if_stack_unavailable) informs the operator
# if the data volume appears unavailable without halting execution.
# ---------------------------------------------------------------------------

HISTFILE=/dev/null
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/secrets.sh"

# ---------------------------------------------------------------------------
# _warn_if_stack_unavailable
#
# Non-blocking preflight: warns the operator when separate-volume mode is
# configured (DATA_VOLUME_DEVICE set in .env) but the data volume is not
# currently mounted.  Secret editing and rotation continue normally — this
# script does not require the data volume.  However, Docker-dependent
# post-rotation steps (secret file sync, service restart) may fail until
# the volume is mounted and the stack is back up.
#
# Uses DATA_VOLUME_DEVICE (written by setup.sh) rather than STORAGE_MODE
# (not written by setup.sh and absent from .env.example) as the gate.
# ---------------------------------------------------------------------------
_warn_if_stack_unavailable() {
    [[ ! -f "${PROJECT_ROOT}/.env" ]] && return 0

    local data_volume_device data_volume_mount
    data_volume_device=$(_read_dotenv_value "DATA_VOLUME_DEVICE" "${PROJECT_ROOT}/.env")
    data_volume_mount=$(_read_dotenv_value  "DATA_VOLUME_MOUNT"  "${PROJECT_ROOT}/.env")

    # Only relevant in separate-volume mode (DATA_VOLUME_DEVICE non-empty).
    [[ -z "${data_volume_device}" ]] && return 0
    [[ -z "${data_volume_mount}"  ]] && return 0

    if ! mountpoint -q "${data_volume_mount}" 2>/dev/null; then
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_warn "⚠  DATA VOLUME NOT MOUNTED: ${data_volume_mount}"
        log_warn "   DATA_VOLUME_DEVICE=${data_volume_device} is configured but"
        log_warn "   the mount point is absent or unmounted.  Secret editing"
        log_warn "   and rotation will continue normally — this script does not"
        log_warn "   require the data volume.  However, Docker-dependent"
        log_warn "   post-rotation steps (secret file sync, service restart)"
        log_warn "   may fail until the volume is mounted and the stack is up."
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Parse EDITOR into an array to support flags (e.g. EDITOR='code --wait').
# read -ra splits on IFS whitespace without glob expansion, which is safer
# than unquoted array assignment.  Use --editor 'code --wait' at runtime to
# override with the same effect.
read -ra EDITOR_CMD <<< "${EDITOR:-nano}"
SKIP_BACKUP=false
VIEW_ONLY=false
LIST_KEYS=false
ROTATE_FIELD=""   # non-empty triggers rotate subcommand
EXPORT_RECOVERY_KIT=false
DRY_RUN=false
# Maximum recursive edit attempts before aborting
readonly MAX_EDIT_ATTEMPTS=5

# Known forking editors that return before the user has saved.
# Users of these editors MUST pass the appropriate "wait" flag themselves.
_FORKING_EDITORS=("gvim" "mvim" "code" "atom" "subl" "sublime_text" "gedit" "kate" "mousepad")

# ---------------------------------------------------------------------------
# Secure shred helper
# ---------------------------------------------------------------------------
# Use _secure_shred() instead of plain rm -f for all plaintext
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
# Cleanup — safe array-based dispatch; no eval.
# register_cleanup FUNCTION ARG  — register a single-argument cleanup call.
# perform_cleanup                — execute in reverse registration order.
# ---------------------------------------------------------------------------
CLEANUP_FUNCS=()
CLEANUP_ARGS=()
register_cleanup() { CLEANUP_FUNCS+=("$1"); CLEANUP_ARGS+=("$2"); }
perform_cleanup() {
    # Execute cleanup actions without eval to eliminate shell
    # injection risk.  Each action is stored as a (function, arg) pair in
    # parallel arrays and dispatched via direct function call.
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
#
# Require at least one whitespace character before #
# to distinguish inline comments from embedded # in values (e.g. p@ss#1).
# Synced to the safe pattern already present in setup.sh secrets.
# ---------------------------------------------------------------------------
_read_dotenv_value() {
    local key="$1"
    local file="${2:-.env}"
    [[ -f "$file" ]] || { echo ""; return 0; }
    # If the file is not readable (e.g. root:root 600 but we're non-root),
    # warn to stderr (keeping stdout clean for callers that capture the return
    # value) and return an empty string.
    if [[ ! -r "$file" ]]; then
        log_warn "_read_dotenv_value: '${file}' is not readable by $(id -un) — returning empty for key '${key}'" >&2
        echo ""; return 0
    fi
    local val
    # Strip inline comments (one-or-more whitespace then #) and trailing
    # whitespace.  Requiring [[:space:]]\+ before # deliberately preserves
    # passwords containing '#' (e.g. "p@ss#1") while correctly stripping
    # "VALUE  # comment".
    val=$(grep -E "^${key}=" "$file" | head -1 | sed "s/^${key}=//;s/[[:space:]]\+#.*$//;s/[[:space:]]*$//")
    echo "$val"
}

# ---------------------------------------------------------------------------
# _validate_yaml_no_duplicates FILE
#
# Python's yaml.safe_load() silently drops duplicate keys (last
# value wins), so the old validator passed files that SOPS (Go yaml.v3)
# would reject with "mapping key X already defined at line N".
#
# This function uses a custom Loader that raises ValueError on the first
# duplicate mapping key found, matching SOPS's strict behaviour.  Returns
# 0 on valid YAML with no duplicates, 1 otherwise (error printed to stderr).
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
    ./edit-secrets.sh <subcommand> [options]

SUBCOMMANDS (mutually exclusive):
    edit                    Interactively edit decrypted secrets, then re-encrypt
    view                    View decrypted secrets read-only (no changes saved)
    list                    List secret key names only (no values shown)
    rotate FIELD            Re-collect and re-hash a single named field, then
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
        EMAIL_MODE=auto   — email driver tries API → SMTP → Postfix in order
        EMAIL_MODE=api    — HTTP API only   (rotate: email_api_token)
        EMAIL_MODE=smtp   — SMTP relay only (rotate: smtp_password)
        EMAIL_MODE=host   — Postfix sidecar (no token or password needed)
        EMAIL_PROVIDER=mailersend|sendgrid|mailgun|postmark|resend
            → selects which HTTP driver is used at runtime;
              the token is always stored as "email_api_token" in secrets.yaml.

    export-recovery-kit     Generate a recovery document with unencrypted
                            secrets. This is the canonical standalone entry
                            point for recovery kit export. setup.sh secrets
                            delegates its post-setup prompt here.

OPTIONS:
    --editor EDITOR         Use specific editor (default: $EDITOR or nano)
    --no-backup             Skip creating backup before edit
    --dry-run               Preview what 'rotate' would change without writing

GLOBAL SUBCOMMAND:
    help                    Show this help

FEATURES:
    ✅ Automatic backup before every edit
    ✅ Change detection (no-op if nothing changed)
    ✅ YAML validation after editing with rollback offer
    ✅ 'rotate' calls collect_secret_field() from lib/secrets.sh (single
       source of truth for hashing — no duplicate Argon2id/bcrypt logic)
    ✅ 'rotate' uses atomic write (temp file → mv) to prevent partial writes
    ✅ 'list' shows key names without decrypting values
    ✅ Prompts to export recovery kit upon any modification
    ✅ Recovery kit export validates no PLACEHOLDER values remain
    ✅ 'rotate --dry-run' previews which values would change

EXAMPLES:
    ./edit-secrets.sh edit                         # Interactive edit
    ./edit-secrets.sh edit --editor vim            # Edit with vim
    ./edit-secrets.sh view                         # View only
    ./edit-secrets.sh list                         # Show key names
    ./edit-secrets.sh rotate admin_token           # Re-hash VW admin password
    ./edit-secrets.sh rotate admin_token --dry-run # Preview rotation
    ./edit-secrets.sh rotate email_api_token       # Replace email provider API key
    ./edit-secrets.sh rotate smtp_password         # Replace SMTP relay password
    ./edit-secrets.sh rotate caddy_cloudflare_dns_token  # Replace CF token
    ./edit-secrets.sh export-recovery-kit          # Export a recovery document

SEE ALSO:
    ./setup.sh secrets  - First-time creation or full reconfiguration
HELP
}

# ---------------------------------------------------------------------------
# Argument parsing — subcommand-first, then options.
# ---------------------------------------------------------------------------
# Pre-scan for recognized subcommands: edit | view | list | rotate | export-recovery-kit
if [[ $# -eq 0 ]]; then
    log_error "Missing subcommand. Use './edit-secrets.sh edit' for interactive editing."
    log_error "Run './edit-secrets.sh help' for usage."
    show_help
    exit 1
fi

case "$1" in
    edit)
        shift
        ;;
    view)
        VIEW_ONLY=true; shift
        ;;
    list)
        LIST_KEYS=true; shift
        ;;
    rotate)
        shift
        if [[ $# -eq 0 || "$1" == --* ]]; then
            log_error "'rotate' requires a FIELD argument."
            log_error "Example: ./edit-secrets.sh rotate admin_token"
            exit 1
        fi
        ROTATE_FIELD="$1"; shift
        ;;
    export-recovery-kit)
        EXPORT_RECOVERY_KIT=true; shift
        ;;
    help)
        show_help; exit 0
        ;;
    *)
        log_error "Unknown subcommand: '$1'"
        log_error "Valid subcommands: edit | view | list | rotate FIELD | export-recovery-kit | help"
        log_error "Run './edit-secrets.sh help' for usage."
        show_help; exit 1
        ;;
esac

# Parse remaining options
while [[ $# -gt 0 ]]; do
    case $1 in
        --editor)
            if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
                log_error "--editor requires an argument (e.g. --editor vim or --editor 'code --wait')"
                exit 1
            fi
            read -ra EDITOR_CMD <<< "$2"
            shift 2
            ;;
        --no-backup) SKIP_BACKUP=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        *)         log_error "Unknown option: '$1'"; show_help; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Mutual-exclusion guard
# ---------------------------------------------------------------------------
_mode_count=0
[[ "$VIEW_ONLY" == "true"           ]] && _mode_count=$(( _mode_count + 1 ))
[[ "$LIST_KEYS" == "true"           ]] && _mode_count=$(( _mode_count + 1 ))
[[ -n "$ROTATE_FIELD"               ]] && _mode_count=$(( _mode_count + 1 ))
# export-recovery-kit is a standalone mode when it is the only subcommand;
# it can also trail rotate / do_edit (offer after modification).
# Standalone evaluation is handled in main().

if [[ $_mode_count -gt 1 ]]; then
    log_error "'view', 'list', and 'rotate' are mutually exclusive subcommands"
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
        # If the configured key is missing but the canonical or repo-local key exists,
        # give the operator a targeted hint.
        local canonical_key="/etc/vaultwarden/age-key.txt"
        local repo_local_key="${PROJECT_ROOT}/secrets/keys/age-key.txt"
        if [[ ! -f "$AGE_KEY_FILE" ]]; then
            if [[ -f "$canonical_key" && "$AGE_KEY_FILE" != "$canonical_key" ]]; then
                log_warn "A key exists at the canonical production path: ${canonical_key}"
                log_warn "Update SOPS_AGE_KEY_FILE in .env to: ${canonical_key}"
                log_warn "Then run: make key-health"
            elif [[ -f "$repo_local_key" && "$AGE_KEY_FILE" != "$repo_local_key" ]]; then
                log_warn "A repo-local key was detected at: ${repo_local_key}"
                log_warn "For production: install it to ${canonical_key} and update .env."
                log_warn "For local/dev: set SOPS_AGE_KEY_FILE=${repo_local_key} in .env."
            fi
        fi
        log_info "To create secrets, run: ./setup.sh secrets"
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

    # ensure_sops_env is called here only for validation. The
    # cleanup_secrets_environment() calls inside validate_secrets_decryption()
    # and validate_secrets_yaml() will unset SOPS_AGE_KEY_FILE when they return.
    # Each action function (do_edit, do_view, do_rotate, etc.) must call
    # ensure_sops_env() independently before invoking sops.
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

    local backup_file
    backup_file="$SECRETS_BACKUP_DIR/secrets.yaml.backup-$(date +%Y%m%d-%H%M%S)"
    log_info "Creating backup: $(basename "$backup_file")"

    # Create backup file with secure permissions before writing content,
    # eliminating the window where the file exists with world-readable permissions.
    # -p preserves the source file's timestamps for accurate backup dating.
    if ! install -m 600 -p "$SECRETS_FILE" "$backup_file" 2>/dev/null; then
        log_error "Failed to create backup"
        return 1
    fi
    log_success "Backup created"

    # Keep last 5 secrets backups (count-based, NOT day-based)
    cleanup_old_secret_backups "$SECRETS_BACKUP_DIR" 5

    return 0
}

# ---------------------------------------------------------------------------
# list subcommand: show key names only, no values
#
# EMAIL_PROVIDER fallback covers both the error case and the empty-value case.
# The `|| echo smtp` pattern only fires on non-zero exit code from
# _read_dotenv_value, not when the key exists with a blank value.
# Shell default expansion handles the empty-value case correctly.
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
            local _provider
            _provider=$(_read_dotenv_value EMAIL_PROVIDER .env)
            _provider="${_provider:-mailersend}"
            printf '  %s  (email provider API token — used by EMAIL_PROVIDER=%s)\n' \
                "$key" "$_provider"
        else
            printf '  %s\n' "$key"
        fi
    done <<< "$raw_keys"

    echo ""
    log_warn "⚠  Hashed fields: admin_token and admin_basic_auth_hash are one-way Argon2id/bcrypt hashes."
    log_warn "   Decrypting the secrets file will show the hash, not the original password."
    log_warn "   To change them: ./edit-secrets.sh rotate admin_token"
    echo ""
    log_info "Canonical production key path: /etc/vaultwarden/age-key.txt (installed by setup.sh)"
    log_info "Run './edit-secrets.sh rotate email_api_token' to set or rotate the provider API key."
    log_info "Run './edit-secrets.sh rotate <field>' to update any other specific key."
    return 0
}

# ---------------------------------------------------------------------------
# view subcommand
# ---------------------------------------------------------------------------
do_view() {
    log_info "Opening secrets in view-only mode..."
    log_warn "⚠  Hashed fields (admin_token, admin_basic_auth_hash) are stored as one-way hashes."
    log_warn "   The displayed hash is NOT the password. Use 'rotate <field>' to change them."

    # Re-establish SOPS env — cleanup_secrets_environment() called
    # inside validate_secrets_decryption/yaml has already unset SOPS_AGE_KEY_FILE.
    if ! ensure_sops_env; then
        log_error "Failed to setup SOPS environment"
        return 1
    fi

    local temp_file
    temp_file=$(mktemp -p /dev/shm 2>/dev/null || mktemp)
    if [[ -n "$temp_file" && "$temp_file" != /dev/shm/* ]]; then
        log_warn "view: /dev/shm unavailable — plaintext temp file is disk-backed: $temp_file"
        log_warn "      Ensure full-disk encryption is active on this host."
    fi
    # Make chmod failure a hard abort — if we can't secure the
    # temp file, we must not proceed as secrets could be exposed to other users.
    if ! install -m 600 /dev/null "$temp_file" 2>/dev/null; then
        rm -f "$temp_file"
        log_error "Failed to secure temp file: $temp_file"
        return 1
    fi
    # use _secure_shred() instead of rm -f for plaintext temp file
    register_cleanup "_secure_shred" "$temp_file"

    local sops_rc=0
    sops -d "$SECRETS_FILE" > "$temp_file" || sops_rc=$?
    cleanup_secrets_environment
    if [[ $sops_rc -ne 0 ]]; then
        log_error "Failed to decrypt secrets"
        return 1
    fi

    if command -v less >/dev/null 2>&1; then
        less "$temp_file"
    else
        "${EDITOR_CMD[@]}" -R "$temp_file" 2>/dev/null || cat "$temp_file"
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
    # If the user already added a wait/nofork flag, skip the warning entirely.
    local _editor_str="${EDITOR_CMD[*]}"
    case "$_editor_str" in
        *--wait*|*--nofork*|-f|*\ -f\ *|*\ -f) return 0 ;;
    esac

    local editor_bin
    editor_bin="$(basename "${EDITOR_CMD[0]}")"

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
#
# Replace yaml.safe_load() with the _NoDupLoader
# already defined in _validate_yaml_no_duplicates so that a file with a
# duplicate key cannot silently pass the placeholder check (safe_load hides
# duplicates; _NoDupLoader raises ValueError on the first one found).
# ---------------------------------------------------------------------------
_validate_no_placeholders() {
    local plain_yaml="$1"

    local offending
    local _py_rc=0
    offending=$(python3 - "$plain_yaml" <<'PYEOF' 2>/dev/null
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

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = yaml.load(f, Loader=_NoDupLoader) or {}

bad = []
for k, v in data.items():
    sv = str(v) if v is not None else ""
    if sv.startswith("PLACEHOLDER") or sv == "PLACEHOLDER_NOT_CONFIGURED":
        bad.append(k)

if bad:
    print("\n".join(bad))
    sys.exit(1)
PYEOF
    ) || _py_rc=$?

    if [[ $_py_rc -ne 0 ]]; then
        log_error "Recovery kit contains unconfigured placeholder values for:"
        while IFS= read -r key; do
            log_error "  - $key"
        done <<< "$offending"
        log_error "Run './setup.sh secrets' or './edit-secrets.sh rotate <field>' to configure these fields first."
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# rotate FIELD subcommand
#
# email_api_token is a fixed canonical key. do_rotate() stores
# the token directly under "email_api_token" in secrets.yaml — no provider-
# specific derivation. This matches what decrypt_secret reads in lib/common.sh.
# ---------------------------------------------------------------------------

_ROTATE_FIELDS=("admin_token" "admin_basic_auth_hash"
                "caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token"
                "email_api_token"
                "smtp_password" "push_installation_id" "push_installation_key"
                "backup_passphrase")

# Map each rotatable field to the Docker service(s) that consume
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

# Deploy all Docker secret files from the encrypted YAML.
# Mirrors the logic in startup.sh prepare_docker_secrets() so the bind-mounted
# files in secrets/.docker_secrets/ stay in sync after a rotation.
# Always use "email_api_token" as the key name — no provider derivation.
# Warns for each field skipped due to a CHANGE_ME/NOT_USED/null placeholder
# so the admin can see which Docker secret files were not written.
_deploy_docker_secrets() {
    local docker_dir="$PROJECT_ROOT/secrets/.docker_secrets"
    local temp_plain
    temp_plain=$(mktemp -p /dev/shm --suffix=.yaml 2>/dev/null || mktemp --suffix=.yaml)
    if [[ -n "$temp_plain" && "$temp_plain" != /dev/shm/* ]]; then
        log_warn "deploy-secrets: /dev/shm unavailable — plaintext temp file is disk-backed: $temp_plain"
        log_warn "                Ensure full-disk encryption is active on this host."
    fi
    # Make chmod failure a hard abort — if we can't secure the
    # temp file, we must not proceed as secrets could be exposed to other users.
    if ! install -m 600 /dev/null "$temp_plain" 2>/dev/null; then
        rm -f "$temp_plain"
        log_error "Failed to secure temp file: $temp_plain"
        return 1
    fi
    # use _secure_shred() for this plaintext temp file
    register_cleanup "_secure_shred" "$temp_plain"

    # Re-establish SOPS env before calling sops directly.
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

    # canonical fixed key — no provider derivation
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
        else
            # Warn so the admin knows which files were not written.
            log_warn "Docker secret '$field_name' skipped (still placeholder — rotate with: ./edit-secrets.sh rotate $field_name)"
        fi
    done
    umask "$old_umask"

    log_debug "Docker secrets deployed: $deployed"
    return 0
}

do_rotate() {
    local field="$1"

    if ! _validate_rotate_field "$field"; then exit 1; fi

    # email_api_token is a fixed canonical key — no provider derivation.
    # actual_field == field for all cases including email_api_token.
    local actual_field="$field"

    # --dry-run support for rotate subcommand
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
    # Make chmod failure a hard abort — if we can't secure the
    # temp file, we must not proceed as secrets could be exposed to other users.
    if ! install -m 600 /dev/null "$temp_plain" 2>/dev/null; then
        rm -f "$temp_plain"
        log_error "Failed to secure temp file: $temp_plain"
        return 1
    fi
    if [[ -n "$temp_plain" && "$temp_plain" != /dev/shm/* ]]; then
        log_warn "rotate: /dev/shm unavailable — plaintext temp file is disk-backed: $temp_plain"
        log_warn "        Ensure full-disk encryption is active on this host."
    fi
    # use _secure_shred() for this plaintext temp file
    register_cleanup "_secure_shred" "$temp_plain"

    # Re-establish SOPS env before calling sops directly.
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

    # For email_api_token, prompt directly (plain token, no hashing).
    # For all other fields, delegate to the canonical collect_secret_field().
    local new_value
    if [[ "$field" == "email_api_token" ]]; then
        # Read EMAIL_PROVIDER from .env rather than relying
        # on the calling shell's environment.  An admin running the script in a
        # clean shell would otherwise see the generic "email" fallback in the
        # prompt instead of the actual configured provider name.
        local _ep
        _ep=$(_read_dotenv_value EMAIL_PROVIDER .env)
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
    # Make chmod failure a hard abort — if we can't secure the
    # temp file, we must not proceed as secrets could be exposed to other users.
    if ! install -m 600 /dev/null "$temp_patched" 2>/dev/null; then
        rm -f "$temp_patched"
        log_error "Failed to secure temp file: $temp_patched"
        return 1
    fi
    if [[ -n "$temp_patched" && "$temp_patched" != /dev/shm/* ]]; then
        log_warn "rotate: /dev/shm unavailable — patched temp file is disk-backed: $temp_patched"
        log_warn "        Ensure full-disk encryption is active on this host."
    fi
    # use _secure_shred() for this plaintext patched temp file
    register_cleanup "_secure_shred" "$temp_patched"

    # Replace yaml.safe_load + yaml.dump round-trip
    # with a line-by-line regex substitution so YAML comments (inline field
    # documentation added by setup.sh secrets write_secrets()) are preserved
    # on every rotation.  yaml.dump() strips all comments on first write.
    local _patch_rc=0
    python3 - "$temp_plain" "$actual_field" "$new_value" "$temp_patched" << 'PYEOF' || _patch_rc=$?
import sys, re

def yaml_scalar(value):
    # Produce a YAML double-quoted scalar with proper escape sequences.
    # Double-quoted scalars are always single-line, version-independent, and
    # handle all YAML-special characters (: # [ ] { } & * leading/trailing
    # spaces, newlines, etc.) without relying on PyYAML's output format.
    # Using manual escaping avoids PyYAML's block-style emission for multi-line
    # strings, which would break the regex-based line substitution below.
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

# Produce a YAML-safe scalar for the replacement value.  yaml_scalar() adds
# quoting (single or double quotes) when the value contains YAML-special
# characters such as ':', '#', leading/trailing spaces, or newlines,
# preventing broken YAML when new_value contains those characters.
yaml_value = yaml_scalar(new_value)

# Replace the value for the given key while preserving all comments and
# surrounding whitespace.  The pattern matches the key at the start of a
# line followed by optional spaces/colon-space and the rest of the line.
# Both bare values and YAML single-quoted scalars are replaced.
pattern = r'^(' + re.escape(field) + r':\s*).*$'
replacement = lambda m: m.group(1) + yaml_value
new_content, n = re.subn(pattern, replacement, content, flags=re.MULTILINE)

if n == 0:
    # Key not yet present (e.g. first-time email_api_token insert) — append it.
    new_content = content.rstrip('\n') + '\n' + field + ': ' + yaml_value + '\n'

with open(dst_file, 'w', encoding='utf-8') as f:
    f.write(new_content)
PYEOF

    if [[ $_patch_rc -ne 0 ]]; then
        log_error "Failed to patch YAML for field: $actual_field"
        return 1
    fi

    # Use strict duplicate-key validator instead of bare yaml.safe_load
    if ! _validate_yaml_no_duplicates "$temp_patched" 2>&1; then
        log_error "Patched YAML is invalid - aborting"
        return 1
    fi

    log_info "Re-encrypting secrets (atomic write)..."
    # Pass a plain .yaml staging file to encrypt_sops_file().
    # Using .yaml (not .yaml.enc) avoids extension-strip confusion inside
    # encrypt_sops_file()'s own mktemp call. encrypt_sops_file() handles the
    # cp → sops --encrypt --in-place → mv cycle; we then mv the result to
    # SECRETS_FILE for a fully atomic two-step replace.
    local temp_enc
    temp_enc=$(mktemp --suffix=.yaml --tmpdir="$(dirname "$SECRETS_FILE")")
    # Make chmod failure a hard abort — if we can't secure the
    # temp file, we must not proceed as secrets could be exposed to other users.
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

    # Atomic replacement: mv on the same filesystem is a single syscall.
    if ! mv "$temp_enc" "$SECRETS_FILE"; then
        log_error "Atomic mv failed — encrypted output in: $temp_enc"
        return 1
    fi

    secure_secrets_file

    log_success "Secret '${actual_field}' rotated successfully"

    # Tell the operator exactly which Docker service to restart.
    local _affected_service="${_FIELD_SERVICES[$field]:-}"
    if [[ -n "$_affected_service" ]]; then
        log_warn "Restart the following Docker service for the new secret to take effect:"
        log_warn "  docker compose restart $_affected_service"
    else
        log_warn "Run 'docker compose restart <service>' for the new secret to take effect"
    fi

    # After successful rotation, redeploy Docker secret files so
    # the live bind-mounted secrets stay in sync with the encrypted YAML.
    log_info "Redeploying Docker secret files..."
    if _deploy_docker_secrets 2>/dev/null; then
        log_success "Docker secret files updated"
    else
        log_warn "Could not auto-redeploy Docker secret files. Run: ./startup.sh or ./setup.sh secrets"
    fi

    offer_recovery_kit_export "$EXPORT_RECOVERY_KIT"

    return 0
}

# ---------------------------------------------------------------------------
# Default: interactive edit
# ---------------------------------------------------------------------------
# _depth parameter prevents unbounded recursion when the
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
    log_info "Opening secrets with: ${EDITOR_CMD[*]}"

    # MEDIUM FIX: Warn user if their editor is known to fork (return before save).
    _check_editor_forks

    local temp_file
    temp_file=$(mktemp -p /dev/shm --suffix=.yaml 2>/dev/null || mktemp --suffix=.yaml)
    if [[ -n "$temp_file" && "$temp_file" != /dev/shm/* ]]; then
        log_warn "edit: /dev/shm unavailable — plaintext temp file is disk-backed: $temp_file"
        log_warn "      Ensure full-disk encryption is active on this host."
    fi
    # Make chmod failure a hard abort — if we can't secure the
    # temp file, we must not proceed as secrets could be exposed to other users.
    if ! install -m 600 /dev/null "$temp_file" 2>/dev/null; then
        rm -f "$temp_file"
        log_error "Failed to secure temp file: $temp_file"
        return 1
    fi
    # use _secure_shred() for this plaintext temp file
    register_cleanup "_secure_shred" "$temp_file"

    # Re-establish SOPS env — validate_secrets() called ensure_sops_env()
    # but cleanup_secrets_environment() inside validate_secrets_decryption/yaml
    # has already unset SOPS_AGE_KEY_FILE by the time do_edit() runs.
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

    # Inject inline YAML hints for hashed fields so the operator knows not to
    # type plaintext values directly. SOPS preserves YAML comments on re-encrypt,
    # so the hints will survive a save-and-re-encrypt cycle. Guard each substitution
    # with a negative-lookahead grep so we never insert duplicate comment lines on
    # subsequent edits (idempotent across re-opens).
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

    # Compute checksum AFTER comment injection so that a no-op editor session
    # (open + close without changes) is correctly detected as "no changes".
    local before_checksum
    before_checksum=$(calculate_sha256 "$temp_file")

    # W4-M9 FIX: Suppress vim/nvim swap files so plaintext secrets are not
    # written to a .swp file alongside the temp file. vim/nvim accept -i NONE
    # to disable viminfo, and --noswapfile to disable swap. We detect these
    # editors by binary name and prepend the flags if not already present.
    local _editor_bin
    _editor_bin="$(basename "${EDITOR_CMD[0]}")"
    local -a _effective_editor_cmd=("${EDITOR_CMD[@]}")
    case "$_editor_bin" in
        vim|vi|nvim|view|gvim|rvim|rview)
            # Only prepend flags if not already supplied by the user.
            if [[ "${EDITOR_CMD[*]}" != *"--noswapfile"* ]]; then
                _effective_editor_cmd=("${EDITOR_CMD[0]}" "-i" "NONE" "--noswapfile" "${EDITOR_CMD[@]:1}")
            fi
            ;;
    esac

    if ! "${_effective_editor_cmd[@]}" "$temp_file"; then
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

    # Use strict duplicate-key YAML validator.
    # yaml.safe_load() silently deduplicates keys; SOPS (Go yaml.v3) rejects
    # them. Catch the error here with a human-readable message so the operator
    # is offered the chance to fix it in the editor rather than hitting the
    # opaque SOPS unmarshal error.
    local yaml_err
    if ! yaml_err=$(_validate_yaml_no_duplicates "$temp_file" 2>&1); then
        log_error "Invalid YAML structure after editing:"
        log_error "  $yaml_err"
        # Add -t 30 timeout to avoid hanging indefinitely
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
    # Use a plain .yaml staging file (not .yaml.enc) placed
    # in the same directory as SECRETS_FILE so the final mv is atomic.
    # encrypt_sops_file() handles cp → sops --encrypt --in-place → internal mv;
    # we then mv its output over SECRETS_FILE.
    local encrypted_temp
    encrypted_temp=$(mktemp --suffix=.yaml --tmpdir="$(dirname "$SECRETS_FILE")")
    # Make chmod failure a hard abort — if we can't secure the
    # temp file, we must not proceed as secrets could be exposed to other users.
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
    temp_plain=$(mktemp -p /dev/shm --suffix=.yaml 2>/dev/null || mktemp --suffix=.yaml)
    if [[ -n "$temp_plain" && "$temp_plain" != /dev/shm/* ]]; then
        log_warn "export-recovery-kit: /dev/shm unavailable — plaintext temp file is disk-backed: $temp_plain"
        log_warn "                     Ensure full-disk encryption is active on this host."
    fi
    # Make chmod failure a hard abort — if we can't secure the
    # temp file, we must not proceed as secrets could be exposed to other users.
    if ! install -m 600 /dev/null "$temp_plain" 2>/dev/null; then
        rm -f "$temp_plain"
        log_error "Failed to secure temp file: $temp_plain"
        return 1
    fi
    register_cleanup "_secure_shred" "$temp_plain"

    # Re-establish SOPS env before calling sops directly.
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

    # MEDIUM FIX: Block export if any placeholder values remain.
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

    # Soft preflight: warn if the data volume appears unavailable in
    # separate-volume mode.  Non-blocking — this script operates on
    # repo-managed encrypted files, not PROJECT_STATE_DIR.  See the SCOPE AND
    # STORAGE GUARD section at the top of this file for the full rationale.
    _warn_if_stack_unavailable

    # Standalone export: export-recovery-kit subcommand with no other mode.
    # This is the canonical single entry point for recovery kit export (Fix #1).
    if [[ "$EXPORT_RECOVERY_KIT" == "true" && "$_mode_count" -eq 0 ]]; then
        log_info "Running standalone recovery kit export..."
        _export_recovery_kit_safe
        exit $?
    fi

    if ! validate_secrets; then exit 1; fi

    # Backup before any write operation
    if [[ "$VIEW_ONLY" != "true" && "$LIST_KEYS" != "true" ]]; then
        if ! create_backup; then
            log_error "Backup failed — aborting to protect against data loss."
            log_error "Use --no-backup to skip backup creation (not recommended)."
            exit 1
        fi
    fi

    if   [[ "$LIST_KEYS" == "true" ]]; then do_list_keys             || exit 1
    elif [[ "$VIEW_ONLY" == "true" ]]; then do_view                  || exit 1
    elif [[ -n "$ROTATE_FIELD"     ]]; then do_rotate "$ROTATE_FIELD" || exit 1
    else                                    do_edit                  || exit 1
    fi

    exit 0
}

main "$@"
