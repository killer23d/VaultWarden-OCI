#!/usr/bin/env bash
# edit-secrets.sh - VaultWarden secrets editor
# Modes: edit (default) | view (--view) | list keys (--list) | rotate field (--rotate FIELD) | export kit (--export-recovery-kit)
# Safe to re-run multiple times.  Uses your $EDITOR or falls back to nano.
#
# Canonical standalone recovery-kit export:
#   ./edit-secrets.sh --export-recovery-kit
#
# See also: ./setup-secrets.sh  (first-time creation and full reconfiguration)

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
# FIX [L-07]: Maximum recursive edit attempts before aborting
readonly MAX_EDIT_ATTEMPTS=5

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
                                smtp_password
                                push_installation_id
                                push_installation_key
                                backup_passphrase        (auto-generated)
    --export-recovery-kit   Generate a recovery document with unencrypted
                            secrets. This is the canonical standalone entry
                            point for recovery kit export. setup-secrets.sh
                            delegates its post-setup prompt here.

EDIT OPTIONS:
    --editor EDITOR         Use specific editor (default: $EDITOR or nano)
    --no-backup             Skip creating backup before edit
    --help                  Show this help

FEATURES:
    ✅ Automatic backup before every edit
    ✅ Change detection (no-op if nothing changed)
    ✅ YAML validation after editing with rollback offer
    ✅ --rotate calls collect_secret_field() from lib/secrets.sh (single
       source of truth for hashing — no duplicate Argon2id/bcrypt logic)
    ✅ --list shows key names without decrypting values
    ✅ Prompts to export recovery kit upon any modification

EXAMPLES:
    ./edit-secrets.sh                              # Interactive edit
    ./edit-secrets.sh --editor vim                 # Edit with vim
    ./edit-secrets.sh --view                       # View only
    ./edit-secrets.sh --list                       # Show key names
    ./edit-secrets.sh --rotate admin_token         # Re-hash VW admin password
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
# ---------------------------------------------------------------------------
do_list_keys() {
    log_info "Secret key names in: $SECRETS_FILE"
    echo ""
    if ! list_secret_keys "$SECRETS_FILE"; then
        return 1
    fi
    echo ""
    log_info "Run './edit-secrets.sh --rotate <field>' to update a specific key."
    return 0
}

# ---------------------------------------------------------------------------
# --view mode
# ---------------------------------------------------------------------------
do_view() {
    log_info "Opening secrets in view-only mode..."

    local temp_file
    temp_file=$(mktemp)
    chmod 600 "$temp_file"
    # FIX [P3-H3]: use _secure_shred() instead of rm -f for plaintext temp file
    register_cleanup "_secure_shred '$temp_file'"

    if ! sops -d "$SECRETS_FILE" > "$temp_file"; then
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
# --rotate FIELD mode
#
# FIX #2: _collect_new_value() has been removed. All per-field collection,
# hashing (Argon2id / bcrypt), and validation is now handled by the single
# canonical collect_secret_field() function in lib/secrets.sh.
# ---------------------------------------------------------------------------

_ROTATE_FIELDS=("admin_token" "admin_basic_auth_hash"
                "caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token"
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

    if ! sops -d "$SECRETS_FILE" > "$temp_plain" 2>/dev/null; then
        log_error "Cannot decrypt secrets for Docker secret deployment"
        return 1
    fi

    mkdir -p "$docker_dir"
    chmod 700 "$docker_dir"

    local old_umask; old_umask=$(umask); umask 077
    local deployed=0 failed=0
    local secret_fields=(
        "admin_token" "admin_basic_auth_hash" "smtp_password"
        "backup_passphrase" "push_installation_id" "push_installation_key"
        "caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token"
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
        if [[ -n "$value" ]] && [[ "$value" != "CHANGE_ME"* ]] && [[ "$value" != "null" ]]; then
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

    log_info "Rotating secret: $field"
    echo ""

    local temp_plain
    temp_plain=$(mktemp --suffix=.yaml)
    chmod 600 "$temp_plain"
    # FIX [P3-H3]: use _secure_shred() for this plaintext temp file
    register_cleanup "_secure_shred '$temp_plain'"

    if ! sops -d "$SECRETS_FILE" > "$temp_plain"; then
        log_error "Failed to decrypt secrets for rotation"
        return 1
    fi

    # Delegate to the single canonical field-collection function in lib/secrets.sh
    local new_value
    if ! new_value=$(collect_secret_field "$field"); then
        return 1
    fi

    local temp_patched
    temp_patched=$(mktemp --suffix=.yaml)
    chmod 600 "$temp_patched"
    # FIX [P3-H3]: use _secure_shred() for this plaintext patched temp file
    register_cleanup "_secure_shred '$temp_patched'"

    python3 - "$temp_plain" "$field" "$new_value" "$temp_patched" << 'PYEOF'
import sys, yaml
src_file, field, new_value, dst_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(src_file) as f:
    data = yaml.safe_load(f)
if field not in data:
    sys.exit(f"Field '{field}' not found in secrets file")
data[field] = new_value
with open(dst_file, 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)
PYEOF

    if [[ $? -ne 0 ]]; then
        log_error "Failed to patch YAML for field: $field"
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

    log_info "Re-encrypting secrets..."
    local temp_enc
    temp_enc=$(mktemp --suffix=.yaml.enc)
    chmod 600 "$temp_enc"
    register_cleanup "rm -f '$temp_enc'"

    if ! sops --encrypt "$temp_patched" > "$temp_enc"; then
        log_error "Failed to re-encrypt secrets"
        return 1
    fi

    mv "$temp_enc" "$SECRETS_FILE"
    secure_secrets_file

    log_success "Secret '$field' rotated successfully"

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
do_edit() {
    local _depth="${1:-0}"
    if (( _depth > MAX_EDIT_ATTEMPTS )); then
        log_error "Too many failed edit attempts (max ${MAX_EDIT_ATTEMPTS}). Aborting."
        return 1
    fi
    log_info "Opening secrets with: $EDITOR_CMD"

    local temp_file
    temp_file=$(mktemp --suffix=.yaml)
    chmod 600 "$temp_file"
    # FIX [P3-H3]: use _secure_shred() for this plaintext temp file
    register_cleanup "_secure_shred '$temp_file'"

    if ! sops -d "$SECRETS_FILE" > "$temp_file"; then
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
    after_checksum=$(calculate_sha256 "$temp_file")

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

    log_info "Encrypting changes..."
    local encrypted_temp
    encrypted_temp=$(mktemp --suffix=.yaml.enc)
    chmod 600 "$encrypted_temp"
    register_cleanup "rm -f '$encrypted_temp'"

    if ! sops --encrypt "$temp_file" > "$encrypted_temp"; then
        log_error "Failed to encrypt secrets"
        rm -f "$encrypted_temp"
        return 1
    fi

    mv "$encrypted_temp" "$SECRETS_FILE"
    secure_secrets_file

    log_success "Secrets updated successfully"

    offer_recovery_kit_export "$EXPORT_RECOVERY_KIT"

    return 0
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
        if ! ensure_sops_env; then exit 1; fi
        offer_recovery_kit_export "true"
        exit 0
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
