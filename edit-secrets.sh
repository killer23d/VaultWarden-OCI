#!/usr/bin/env bash
# edit-secrets.sh - VaultWarden secrets editor
# Modes: edit (default) | view (--view) | list keys (--list) | rotate field (--rotate FIELD) | export kit (--export-recovery-kit)
# Safe to re-run multiple times.  Uses your $EDITOR or falls back to nano.
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
    --export-recovery-kit   Generate a recovery document with unencrypted secrets

EDIT OPTIONS:
    --editor EDITOR         Use specific editor (default: $EDITOR or nano)
    --no-backup             Skip creating backup before edit
    --help                  Show this help

FEATURES:
    ✅ Automatic backup before every edit
    ✅ Change detection (no-op if nothing changed)
    ✅ YAML validation after editing with rollback offer
    ✅ --rotate re-invokes hashing logic from setup for password fields
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
# Note: --export-recovery-kit is treated as a mode if it's the ONLY thing passed,
# but it can also be a flag applied to the default edit mode.
# We will evaluate standalone export in the main() function.

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
    register_cleanup "rm -f '$temp_file'"

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
# ---------------------------------------------------------------------------

_HASHED_FIELDS=("admin_token" "admin_basic_auth_hash")
_PLAIN_TOKEN_FIELDS=("caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token" "smtp_password" "push_installation_id" "push_installation_key")
_AUTO_FIELDS=("backup_passphrase")
_ALL_ROTATE_FIELDS=("${_HASHED_FIELDS[@]}" "${_PLAIN_TOKEN_FIELDS[@]}" "${_AUTO_FIELDS[@]}")

_validate_rotate_field() {
    local field="$1"
    for f in "${_ALL_ROTATE_FIELDS[@]}"; do
        [[ "$f" == "$field" ]] && return 0
    done
    log_error "Unknown field: $field"
    log_info  "Supported fields: ${_ALL_ROTATE_FIELDS[*]}"
    return 1
}

_collect_new_value() {
    local field="$1"
    local new_value=""

    case "$field" in

        admin_token)
            log_info "Re-collecting VaultWarden admin password (will be Argon2id hashed)"
            local raw_pass
            raw_pass=$(prompt_password_with_confirmation "New VaultWarden admin password" 12)
            log_info "Generating Argon2id hash..."
            new_value=$(generate_argon2_hash "$raw_pass")
            [[ -z "$new_value" ]] && { log_error "Argon2id hash generation failed"; return 1; }
            log_success "Argon2id hash generated"
            ;;

        admin_basic_auth_hash)
            log_info "Re-collecting Caddy admin password (will be bcrypt hashed, htpasswd format)"
            local raw_pass
            raw_pass=$(prompt_password_with_confirmation "New Caddy admin password" 12)
            log_info "Generating bcrypt hash..."
            local bcrypt_hash
            bcrypt_hash=$(generate_bcrypt_hash "$raw_pass")
            [[ -z "$bcrypt_hash" ]] && { log_error "bcrypt hash generation failed"; return 1; }
            if [[ ! "$bcrypt_hash" =~ ^\$2[aby]\$[0-9]{2}\$ ]]; then
                log_error "Generated bcrypt hash has invalid format: $bcrypt_hash"
                return 1
            fi
            new_value="admin $bcrypt_hash"
            log_success "bcrypt hash generated (htpasswd format: admin:\$2a\$...)"
            ;;

        caddy_cloudflare_dns_token)
            log_info "Required Permissions: Zone:DNS:Edit + Zone:Zone:Read"
            log_info "Create at: https://dash.cloudflare.com/profile/api-tokens"
            read -p "New Cloudflare DNS API token: " new_value
            if [[ -n "$new_value" && "$new_value" != "CHANGE_ME"* ]]; then
                if validate_cloudflare_token "$new_value" "dns" 2>/dev/null; then
                    log_success "DNS token validated successfully"
                else
                    log_warn "Token validation failed - continuing anyway"
                fi
            fi
            ;;

        fail2ban_cloudflare_firewall_token)
            log_info "Required Permissions: Zone:Firewall Services:Edit"
            log_info "Create at: https://dash.cloudflare.com/profile/api-tokens"
            read -p "New Cloudflare Firewall API token: " new_value
            if [[ -n "$new_value" && "$new_value" != "CHANGE_ME"* ]]; then
                if validate_cloudflare_token "$new_value" "firewall" 2>/dev/null; then
                    log_success "Firewall token validated successfully"
                else
                    log_warn "Token validation failed - continuing anyway"
                fi
            fi
            ;;

        smtp_password)
            read -s -p "New SMTP password: " new_value
            echo ""
            ;;

        push_installation_id)
            log_info "Get credentials from: https://bitwarden.com/host"
            read -p "New push installation ID: " new_value
            ;;

        push_installation_key)
            read -p "New push installation key: " new_value
            ;;

        backup_passphrase)
            new_value=$(generate_secure_string 32)
            log_warn "Auto-generated new backup passphrase (32 chars) - save it if needed:"
            log_warn "  $new_value"
            ;;
    esac

    [[ -z "$new_value" ]] && { log_error "No value entered for $field"; return 1; }
    printf '%s' "$new_value"
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
    register_cleanup "rm -f '$temp_plain'"

    if ! sops -d "$SECRETS_FILE" > "$temp_plain"; then
        log_error "Failed to decrypt secrets for rotation"
        return 1
    fi

    local new_value
    if ! new_value=$(_collect_new_value "$field"); then
        return 1
    fi

    local temp_patched
    temp_patched=$(mktemp --suffix=.yaml)
    chmod 600 "$temp_patched"
    register_cleanup "rm -f '$temp_patched'"

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

    if ! python3 -c "import yaml, sys; yaml.safe_load(open('$temp_patched'))" 2>/dev/null; then
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

    offer_recovery_kit_export "$EXPORT_RECOVERY_KIT"

    return 0
}

# ---------------------------------------------------------------------------
# Default: interactive edit
# ---------------------------------------------------------------------------
do_edit() {
    log_info "Opening secrets with: $EDITOR_CMD"

    local temp_file
    temp_file=$(mktemp --suffix=.yaml)
    chmod 600 "$temp_file"
    register_cleanup "rm -f '$temp_file'"

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

    if ! python3 -c "import yaml, sys; yaml.safe_load(open('$temp_file'))" 2>/dev/null; then
        log_error "Invalid YAML structure after editing"
        read -p "Discard changes? (yes/no): " discard
        if [[ "$discard" == "yes" ]]; then
            log_info "Changes discarded"
            return 1
        else
            log_info "Re-opening editor to fix..."
            do_edit
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

    # Standalone export logic
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
