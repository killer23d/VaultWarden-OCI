#!/usr/bin/env bash
# lib/secrets.sh — Secret management and recovery helpers for VaultWarden-OCI.
#
# Provides:
#   SOPS       : ensure_sops_env, cleanup_secrets_environment, decrypt_secret,
#                list_secrets, list_secret_keys, validate_secrets_decryption,
#                validate_secrets_yaml, validate_required_secrets
#   Secrets    : write_secret_file, generate_admin_token, collect_secret_field,
#                auto_generate_secret_field, export_docker_secrets
#   Backups    : create_secrets_backup, cleanup_old_secret_backups,
#                generate_recovery_kit, offer_recovery_kit_export
#   Validation : check_placeholder_values, validate_cloudflare_token,
#                secure_secrets_file
#
# Depends on / Load order:
#   lib/log.sh is auto-loaded if it has not already been sourced.
#   lib/crypto.sh is sourced by this file and should remain available.
#
# Canonical caller source block:
#   source "${LIB_DIR}/log.sh"
#   source "${LIB_DIR}/common.sh"
#   source "${LIB_DIR}/crypto.sh"
#   source "${LIB_DIR}/secrets.sh"


if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This library should be sourced, not executed directly"
    exit 1
fi

_SECRETS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Self-load log.sh if not already loaded — allows this lib to be sourced
# directly without going through common.sh or a caller that pre-loads log.sh.
# NOTE: _SECRETS_LIB_DIR is intentionally NOT unset here; it is reused two
# lines below to source crypto.sh, then unset after that call.
[[ -n "${VW_LOG_LIB_LOADED:-}" ]] || source "${_SECRETS_LIB_DIR}/log.sh"
[[ -n "${VAULTWARDEN_DEFAULTS_LOADED:-}" ]] || source "${_SECRETS_LIB_DIR}/defaults.sh"

source "${_SECRETS_LIB_DIR}/crypto.sh"
source "${_SECRETS_LIB_DIR}/schema.sh"
unset _SECRETS_LIB_DIR

# Do NOT set -euo pipefail here — callers own their shell options.
# Entry-point scripts apply these options via init_common_lib(); this library
# is always sourced after that call.

# SECRETS_FILE is exported by lib/config.sh (canonical source of truth).
# lib/secrets.sh intentionally does NOT define a fallback here so that the
# two libraries always agree on the path. If you are sourcing this file
# standalone (without config.sh loaded first), export SECRETS_FILE before
# sourcing.
SECRETS_BACKUP_DIR="${SECRETS_BACKUP_DIR:-secrets}"

ensure_sops_env() {
    local age_key
    if ! age_key=$(resolve_age_key_path); then
        return 1
    fi
    export SOPS_AGE_KEY_FILE="$age_key"
    export SOPS_CONFIG="${PROJECT_ROOT:-$(pwd)}/.sops.yaml"
    log_debug "SOPS env set: key=$SOPS_AGE_KEY_FILE  config=$SOPS_CONFIG"
    return 0
}

cleanup_secrets_environment() {
    unset SOPS_AGE_KEY_FILE
    unset SOPS_CONFIG
    log_debug "cleanup_secrets_environment: SOPS_AGE_KEY_FILE and SOPS_CONFIG unset"
    return 0
}

write_secret_file() {
    local dest="$1"
    local value="$2"

    local old_umask
    old_umask=$(umask)
    umask 077
    printf '%s\n' "$value" > "$dest"
    local write_rc=$?
    umask "$old_umask"

    if [[ $write_rc -ne 0 ]]; then
        log_error "write_secret_file: failed to write $dest"
        return 1
    fi

    # Verify the written file is non-empty when the source value
    # was non-empty. A zero-byte file after a successful printf return indicates
    # a disk-full or I/O error that printf did not propagate as a non-zero exit.
    if [[ -n "$value" && ! -s "$dest" ]]; then
        log_error "write_secret_file: file is empty after write — possible disk-full: $dest"
        rm -f "$dest"
        return 1
    fi

    chmod 444 "$dest"
    return 0
}

generate_admin_token() {
    local length="${1:-48}"
    local token

    # Run in a subshell with pipefail so openssl failure propagates.
    if ! token=$(
        set -o pipefail
        openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "$length"
    ); then
        log_error "generate_admin_token: openssl rand failed or pipeline error"
        return 1
    fi

    if [[ -z "$token" || ${#token} -lt 32 ]]; then
        log_error "generate_admin_token: generated token is too short (${#token} chars); aborting"
        return 1
    fi

    printf '%s' "$token"
    return 0
}

# SECURITY: Decrypted value is returned via printf to stdout (command substitution).
# Callers MUST capture via local variable assignment only:
#   local value; value=$(decrypt_secret "key") || return 1
# NEVER pass the result directly as a positional argument to an external command:
#   some_cmd "$(decrypt_secret "key")"  # WRONG: appears in /proc/$$/cmdline
decrypt_secret() {
    local key="$1"
    local secrets_file="${2:-$SECRETS_FILE}"

    if ! ensure_sops_env; then return 1; fi

    local _tmp_err
    _tmp_err=$(mktemp) || { log_error "decrypt_secret: mktemp failed"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -f '$_tmp_err'" RETURN

    local value rc=0
    # Suppress xtrace around secret decryption to prevent value
    # appearing in debug logs or core dumps via set -x output.
    { set +x; } 2>/dev/null
    value=$(sops -d --extract "[\"$key\"]" "$secrets_file" 2>"$_tmp_err") || rc=$?

    # Capture the key path before unsetting so it is available for error logging below.
    local _age_key_path="$SOPS_AGE_KEY_FILE"
    # Unset key file path from environment so child processes do not inherit it.
    unset SOPS_AGE_KEY_FILE

    if [[ $rc -ne 0 ]]; then
        local sops_stderr
        sops_stderr=$(cat "$_tmp_err")
        log_error "decrypt_secret: failed to decrypt key '$key' from $secrets_file (sops exit $rc)"
        log_error "  Expected AGE key: ${_age_key_path:-<not set by ensure_sops_env>}"
        if [[ -n "${sops_stderr:-}" ]]; then
            log_error "  sops error: $sops_stderr"
        fi
        return 1
    fi

    printf '%s' "$value"
    unset value
    return 0
}

list_secrets() {
    local secrets_file="${1:-$SECRETS_FILE}"

    if [[ ! -f "$secrets_file" ]]; then
        log_error "Secrets file not found: $secrets_file"
        return 1
    fi

    if ! ensure_sops_env; then return 1; fi

    local keys
    local sops_stderr
    local rc=0
    # Suppress xtrace before sops to prevent the key file path
    # from appearing in trace output (bash -x / set -x logs).
    { set +x; } 2>/dev/null
    # Decrypt once into a variable; parse from that in-memory copy
    # rather than calling sops -d a second time (avoids double I/O and TOCTOU).
    local yaml_content _sops_err_file
    _sops_err_file=$(mktemp)
    yaml_content=$(sops -d "$secrets_file" 2>"$_sops_err_file") || rc=$?
    if [[ $rc -ne 0 ]]; then
        sops_stderr=$(cat "$_sops_err_file" 2>/dev/null || true)
    else
        keys=$(printf '%s\n' "$yaml_content" \
            | python3 -c "
import yaml, sys
data = yaml.safe_load(sys.stdin)
if isinstance(data, dict):
    for k in data.keys():
        print(k)
" 2>/dev/null) || rc=$?
    fi
    rm -f "$_sops_err_file"

    cleanup_secrets_environment

    if [[ $rc -ne 0 || -z "$keys" ]]; then
        log_error "list_secrets: decryption or parse failure for $secrets_file (sops exit $rc)"
        if [[ -n "${sops_stderr:-}" ]]; then
            log_error "  sops error: $sops_stderr"
        fi
        return 1
    fi

    echo "$keys"
    return 0
}

secrets_file_exists() {
    [[ -f "$SECRETS_FILE" ]]
}

validate_secrets_decryption() {
    local secrets_file="${1:-$SECRETS_FILE}"
    if [[ ! -f "$secrets_file" ]]; then
        log_error "Secrets file not found: $secrets_file"
        return 1
    fi
    if ! ensure_sops_env; then return 1; fi
    local rc=0
    local sops_stderr
    # Capture sops stderr so the operator knows whether failure is a
    # wrong key, missing key file, corrupt MAC, or other sops-level error.
    sops_stderr=$(sops -d "$secrets_file" 2>&1 >/dev/null) || rc=$?
    # Capture key path before cleanup_secrets_environment() unsets SOPS_AGE_KEY_FILE.
    local _age_key_path="$SOPS_AGE_KEY_FILE"
    cleanup_secrets_environment
    if [[ $rc -ne 0 ]]; then
        log_error "Cannot decrypt secrets file: $secrets_file (sops exit $rc)"
        log_error "  Check AGE key at: ${_age_key_path:-<not set by ensure_sops_env>}"
        if [[ -n "${sops_stderr:-}" ]]; then
            log_error "  sops error: $sops_stderr"
        fi
        return 1
    fi
    return 0
}

validate_secrets_yaml() {
    local secrets_file="${1:-$SECRETS_FILE}"
    if [[ ! -f "$secrets_file" ]]; then
        log_error "Secrets file not found: $secrets_file"
        return 1
    fi
    if ! ensure_sops_env; then return 1; fi
    local rc=0
    local sops_stderr
    sops_stderr=$(sops -d --output-type json "$secrets_file" 2>&1 >/dev/null) || rc=$?
    cleanup_secrets_environment
    if [[ $rc -ne 0 ]]; then
        log_warn "Secrets file cannot be decrypted or contains invalid YAML: $secrets_file (sops exit $rc)"
        if [[ -n "${sops_stderr:-}" ]]; then
            log_warn "  sops error: $sops_stderr"
        fi
        return 1
    fi
    return 0
}

validate_required_secrets() {
    local secrets_file="${1:-$SECRETS_FILE}"
    local required_secrets=(
        "admin_token"
        "admin_basic_auth_hash"
        "caddy_cloudflare_dns_token"
        "email_api_token"
        "backup_passphrase"
    )
    # CrowdSec Cloudflare keys are conditionally required when CF proxy is enabled.
    if [[ "${CLOUDFLARE_PROXY_ENABLED:-false}" == "true" ]]; then
        required_secrets+=("cloudflare_zone_id" "cf_account_id" "cf_worker_bouncer_token")
    fi
    if ! ensure_sops_env; then return 1; fi
    local missing_secrets=()
    for secret in "${required_secrets[@]}"; do
        local sops_stderr rc=0
        # Capture sops stderr per-key so missing vs. undecryptable
        # secrets produce distinct diagnostic messages.
        sops_stderr=$(sops -d --extract "[\"$secret\"]" "$secrets_file" 2>&1 >/dev/null) || rc=$?
        if [[ $rc -ne 0 ]]; then
            log_error "validate_required_secrets: required secret '$secret' is missing or unreadable"
            missing_secrets+=("$secret")
            if [[ -n "${sops_stderr:-}" ]]; then
                log_debug "validate_required_secrets: sops error for '$secret': $sops_stderr"
            fi
        fi
    done
    cleanup_secrets_environment
    if [[ ${#missing_secrets[@]} -gt 0 ]]; then
        log_warn "Missing required secrets (${#missing_secrets[@]}): ${missing_secrets[*]}"
        return 1
    fi
    return 0
}

check_placeholder_values() {
    local secrets_file="${1:-$SECRETS_FILE}"

    # Derive the required-key list from secrets-schema.yaml so no key names are
    # hardcoded here.  Adding or removing a key only requires updating the schema.
    local _required_keys
    if ! _required_keys=$(schema_required_keys 2>/dev/null); then
        log_error "check_placeholder_values: failed to read required keys from secrets-schema.yaml"
        return 1
    fi

    if ! ensure_sops_env; then return 1; fi
    local placeholder_secrets=()
    local unreadable_secrets=()

    while IFS= read -r secret; do
        [[ -z "$secret" ]] && continue
        local value rc=0
        # Decrypt once and reuse the value for both checks.
        # Suppress xtrace to prevent plaintext secret appearing in debug logs.
        { set +x; } 2>/dev/null
        local _tmp_sops_err
        _tmp_sops_err=$(mktemp)
        value=$(sops -d --extract "[\"$secret\"]" "$secrets_file" 2>"$_tmp_sops_err") || rc=$?
        if [[ $rc -ne 0 ]]; then
            local sops_stderr
            sops_stderr=$(cat "$_tmp_sops_err" 2>/dev/null || true)
            rm -f "$_tmp_sops_err"
            log_error "check_placeholder_values: failed to read secret '$secret' from $secrets_file (sops exit $rc)"
            if [[ -n "${sops_stderr:-}" ]]; then
                log_error "  sops error: $sops_stderr"
            fi
            unreadable_secrets+=("$secret")
            continue
        fi
        rm -f "$_tmp_sops_err"
        if [[ "$value" =~ ^(CHANGE_ME|PLACEHOLDER_NOT_CONFIGURED) ]] || [[ -z "$value" ]]; then
            log_warn "check_placeholder_values: secret '$secret' is set to a placeholder or is empty"
            placeholder_secrets+=("$secret")
        fi
        unset value
    done <<< "$_required_keys"

    cleanup_secrets_environment
    if [[ ${#unreadable_secrets[@]} -gt 0 ]]; then
        log_error "Unreadable secrets during placeholder check (${#unreadable_secrets[@]}): ${unreadable_secrets[*]}"
        return 1
    fi
    if [[ ${#placeholder_secrets[@]} -gt 0 ]]; then
        log_warn "Secrets with placeholders (${#placeholder_secrets[@]}): ${placeholder_secrets[*]}"
        return 1
    fi
    return 0
}

list_secret_keys() {
    local secrets_file="${1:-$SECRETS_FILE}"
    if [[ ! -f "$secrets_file" ]]; then
        log_error "Secrets file not found: $secrets_file"
        return 1
    fi
    if ! ensure_sops_env; then return 1; fi
    local keys
    local sops_stderr
    local rc=0
    # Decrypt once into a variable; parse from that in-memory copy
    # rather than calling sops -d a second time (avoids double I/O and TOCTOU).
    local yaml_content _sops_err_file
    _sops_err_file=$(mktemp)
    yaml_content=$(sops -d "$secrets_file" 2>"$_sops_err_file") || rc=$?
    if [[ $rc -ne 0 ]]; then
        sops_stderr=$(cat "$_sops_err_file" 2>/dev/null || true)
    else
        keys=$(printf '%s\n' "$yaml_content" \
            | python3 -c "import yaml, sys; [print(k) for k in yaml.safe_load(sys.stdin).keys()]" 2>/dev/null) || rc=$?
    fi
    rm -f "$_sops_err_file"
    cleanup_secrets_environment
    if [[ $rc -ne 0 || -z "$keys" ]]; then
        log_error "list_secret_keys: decryption or parse failure for $secrets_file (sops exit $rc)"
        if [[ -n "${sops_stderr:-}" ]]; then
            log_error "  sops error: $sops_stderr"
        fi
        return 1
    fi
    echo "$keys"
    return 0
}

create_secrets_backup() {
    local secrets_file="${1:-$SECRETS_FILE}"
    local backup_dir="${2:-$SECRETS_BACKUP_DIR}"
    if [[ ! -f "$secrets_file" ]]; then
        log_debug "No secrets file to backup"
        return 0
    fi
    local backup_file
    backup_file="$backup_dir/secrets.yaml.backup-$(date +%Y%m%d-%H%M%S)"
    log_info "Creating backup: $(basename "$backup_file")"
    # Pre-create at 600 so the file is never world-readable.
    if ! install -m 600 /dev/null "$backup_file"; then
        log_error "Failed to pre-create backup file with secure permissions: $backup_file"
        return 1
    fi
    if ! cp "$secrets_file" "$backup_file"; then
        log_error "Failed to create backup"
        rm -f "$backup_file" 2>/dev/null || true
        return 1
    fi
    log_success "Backup created"
    return 0
}

cleanup_old_secret_backups() {
    local backup_dir="${1:-$SECRETS_BACKUP_DIR}"
    local keep_count="${2:-5}"
    # NUL-delimited pipeline — safe for paths containing spaces.
    find "$backup_dir" -name "secrets.yaml.backup-*" -type f -print0 2>/dev/null \
        | sort -rz \
        | tail -z -n +$(( keep_count + 1 )) \
        | xargs -0 rm -f
    log_debug "Cleaned up old secrets backups (keeping last $keep_count)"
    return 0
}

_secure_shred() {
    local target="$1"
    [[ -f "$target" ]] || return 0
    if command -v shred >/dev/null 2>&1; then
        shred -fuz "$target" 2>/dev/null && return 0
    fi
    # Portable stat (GNU -c%s || BSD -f%z), with safe default
    local file_size
    file_size=$(stat -c%s "$target" 2>/dev/null || stat -f%z "$target" 2>/dev/null || echo "4096")
    [[ -z "$file_size" || ! "$file_size" =~ ^[0-9]+$ ]] && file_size=4096
    (( file_size == 0 )) && file_size=4096
    dd if=/dev/urandom of="$target" bs="$file_size" count=1 conv=notrunc 2>/dev/null || true
    rm -f "$target"
}

_tmpfs_dir() {
    local uid
    uid=$(id -u)

    if [[ -d /dev/shm && -w /dev/shm ]]; then
        echo "/dev/shm"
        return 0
    fi

    local run_user="/run/user/$uid"
    if [[ -d "$run_user" && -w "$run_user" ]]; then
        echo "$run_user"
        return 0
    fi

    if [[ -w /tmp ]]; then
        printf '\n WARNING: /dev/shm and /run/user/%s are unavailable.\n' "$uid" > /dev/tty 2>/dev/null || true
        printf '            Recovery kit will be written to /tmp which may NOT be tmpfs.\n' > /dev/tty 2>/dev/null || true
        printf '            Shred effectiveness on CoW/journaled filesystems is not guaranteed.\n\n' > /dev/tty 2>/dev/null || true
        echo "/tmp"
        return 0
    fi

    log_error "_tmpfs_dir: no writable tmpfs candidate found (/dev/shm, /run/user/$uid, /tmp)"
    return 1
}

validate_cloudflare_token() {
    
    local token="$1"
    local token_type="$2"
    local zone_id="${3:-}"

    if [[ -z "$zone_id" ]]; then
        zone_id=$(decrypt_secret "cloudflare_zone_id" 2>/dev/null) || zone_id=""
    fi
    if [[ -z "$zone_id" ]]; then
        zone_id="${CLOUDFLARE_ZONE_ID:-}"
    fi

    if [[ -z "$zone_id" ]] \
        || [[ "$zone_id" == "your_cloudflare_zone_id_here" ]] \
        || [[ "$zone_id" == CHANGE_ME* ]] \
        || [[ "$zone_id" == PLACEHOLDER* ]] \
        || [[ "$zone_id" =~ ^[[:space:]]*$ ]]; then
        log_warn "validate_cloudflare_token: cloudflare_zone_id is not configured -- validation skipped (token NOT verified)"
        return 1
    fi

    local endpoint
    case "$token_type" in
        dns)      endpoint="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?per_page=1" ;;
        firewall) endpoint="https://api.cloudflare.com/client/v4/zones/$zone_id/rulesets" ;;
        *)        log_error "Invalid token type: $token_type"; return 1 ;;
    esac

    local curl_cfg
    if ! curl_cfg=$(mktemp) || ! install -m 600 /dev/null "$curl_cfg"; then
        rm -f "$curl_cfg" 2>/dev/null || true
        return 1
    fi
    printf 'header = "Authorization: Bearer %s"\n' "$token" > "$curl_cfg"

    local result=0
    if curl -sf --max-time 10 --config "$curl_cfg" "$endpoint" \
        | jq -e '.success == true' >/dev/null 2>&1; then
        result=0
    else
        result=1
    fi
    rm -f "$curl_cfg" 2>/dev/null || true
    return "$result"
}

prompt_password_with_confirmation() {
    local prompt_text="$1"
    local min_length="${2:-12}"
    local max_attempts="${3:-10}"
    local password password_confirm
    local attempt=0

    while true; do
        attempt=$(( attempt + 1 ))
        if [[ $attempt -gt $max_attempts ]]; then
            log_error "Too many failed password attempts (${max_attempts}). Aborting."
            return 1
        fi

        read -r -s -p "$prompt_text: " password
        echo ""
        if [[ -z "$password" ]]; then
            log_error "Password cannot be empty (attempt $attempt/$max_attempts)"
            continue
        fi
        if [[ ${#password} -lt $min_length ]]; then
            log_error "Password must be at least $min_length characters (attempt $attempt/$max_attempts)"
            continue
        fi
        read -r -s -p "Confirm password: " password_confirm
        echo ""
        if [[ "$password" != "$password_confirm" ]]; then
            log_error "Passwords don't match (attempt $attempt/$max_attempts)"
            continue
        fi
        break
    done
    printf '%s\n' "$password"
    return 0
}

secure_secrets_file() {
    local secrets_file="${1:-$SECRETS_FILE}"
    if [[ ! -f "$secrets_file" ]]; then return 0; fi
    chmod 600 "$secrets_file"
    local real_user real_group
    real_user=$(get_real_user)
    real_group=$(id -gn "$real_user" 2>/dev/null || printf '%s' "$real_user")
    chown "$real_user:$real_group" "$secrets_file"
    return 0
}

_bcrypt_format_ok() {
    local hash="$1"
    [[ "$hash" =~ ^\$2[aby]\$[0-9]+\$.{53}$ ]]
}

collect_secret_field() {
    local field="$1"

    case "$field" in

        admin_token)
            log_info "Collecting VaultWarden admin password (will be Argon2id hashed)" >&2
            local raw_pass
            raw_pass=$(prompt_password_with_confirmation "VaultWarden admin password" 12)
            log_info "Generating Argon2id hash..." >&2
            local hashed
            hashed=$(generate_argon2_hash "$raw_pass")
            if [[ -z "$hashed" ]]; then
                log_error "Argon2id hash generation failed" >&2
                return 1
            fi
            log_success "Argon2id hash generated" >&2
            printf '%s' "$hashed"
            ;;

        admin_basic_auth_hash)
            log_info "Collecting Caddy admin password (will be bcrypt hashed, htpasswd format)" >&2
            local raw_pass
            raw_pass=$(prompt_password_with_confirmation "Caddy admin password" 12)
            log_info "Generating bcrypt hash..." >&2
            local bcrypt_hash
            bcrypt_hash=$(generate_bcrypt_hash "$raw_pass")
            if [[ -z "$bcrypt_hash" ]]; then
                log_error "bcrypt hash generation failed. Ensure apache2-utils is installed." >&2
                return 1
            fi
            if ! _bcrypt_format_ok "$bcrypt_hash"; then
                log_error "Generated bcrypt hash has invalid format: $bcrypt_hash" >&2
                return 1
            fi
            log_success "bcrypt hash generated (htpasswd format: admin:\$2y\$...)" >&2
            printf '%s' "admin $bcrypt_hash"
            ;;

        caddy_cloudflare_dns_token)
            log_info "Required Permissions: Zone:DNS:Edit + Zone:Zone:Read" >&2
            log_info "Create at: https://dash.cloudflare.com/profile/api-tokens" >&2
            local token
            read -r -p "Cloudflare DNS API token: " token
            if [[ -n "$token" && "$token" != CHANGE_ME* ]]; then
                if validate_cloudflare_token "$token" "dns" 2>/dev/null; then
                    log_success "DNS token validated successfully" >&2
                else
                    log_warn "Token validation failed or zone not configured - continuing anyway" >&2
                fi
            fi
            printf '%s' "$token"
            ;;

        cloudflare_zone_id)
            log_info "Find your Zone ID at: Cloudflare dashboard → your domain → Overview → API section" >&2
            local val
            read -r -p "Cloudflare Zone ID: " val
            if [[ -z "$val" ]]; then
                log_error "No value entered. Aborting." >&2
                return 1
            fi
            printf '%s' "$val"
            ;;

        cf_account_id)
            log_info "Find your Account ID at: Cloudflare dashboard → any domain → Overview → API section" >&2
            local val
            read -r -p "Cloudflare Account ID: " val
            if [[ -z "$val" ]]; then
                log_error "No value entered. Aborting." >&2
                return 1
            fi
            printf '%s' "$val"
            ;;

        email_api_token)
            # Canonical key for the email provider HTTP API token.
            # Stored as-is (no hashing). Works for any EMAIL_PROVIDER value.
            log_info "Enter your email provider API key (Mailgun, MailerSend, SendGrid, etc.)" >&2
            log_info "This is stored as 'email_api_token' and used by all HTTP email drivers." >&2
            local token
            read -r -s -p "Email API token: " token
            echo "" >&2
            if [[ -z "$token" ]]; then
                log_error "No token entered. Aborting." >&2
                return 1
            fi
            printf '%s' "$token"
            ;;

        smtp_password)
            local pw
            read -r -s -p "SMTP password: " pw
            echo "" >&2
            printf '%s' "$pw"
            ;;

        push_installation_id)
            log_info "Get credentials from: https://bitwarden.com/host" >&2
            local val
            read -r -p "Push installation ID: " val
            printf '%s' "$val"
            ;;

        push_installation_key)
            local val
            read -r -p "Push installation key: " val
            printf '%s' "$val"
            ;;

        backup_passphrase)
            local passphrase
            passphrase=$(generate_secure_string 32)
            {
                printf '\n'
                printf ' AUTO-GENERATED BACKUP PASSPHRASE (save if needed):\n'
                printf '   %s\n' "$passphrase"
                printf '\n'
            } > /dev/tty 2>/dev/null || {
                log_warn "Backup passphrase auto-generated (32 chars) -- retrieve from secrets store." >&2
            }
            printf '%s' "$passphrase"
            ;;

        *)
            log_error "collect_secret_field: unknown field '$field'" >&2
            return 1
            ;;
    esac
    return 0
}

auto_generate_secret_field() {
    local field="$1"
    local _banner_width=86
    _print_secret_banner() {
        local title="$1"
        local value="$2"
        local border
        border=$(printf '%*s' "${_banner_width}" '' | tr ' ' '=')
        {
            printf '\n'
            printf '\033[1;97;41m%s\033[0m\n' "$border"
            printf '\033[1;97;41m  %-80s\033[0m\n' "🚨 SAVE THIS NOW — AUTO-GENERATED SECRET 🚨"
            printf '\033[1;97;41m%s\033[0m\n' "$border"
            printf '\033[1;33m%s\033[0m\n' "$title"
            printf '\033[1;32m%s\033[0m\n' "$value"
            printf '\033[1;97;41m  %-80s\033[0m\n' "This plaintext will not be shown again. Store it in your password manager."
            printf '\033[1;97;41m%s\033[0m\n' "$border"
            printf '\n'
        } > /dev/tty 2>/dev/null
    }

    case "$field" in

        admin_token)
            local vw_pass
            vw_pass=$(generate_secure_string 32)
            _print_secret_banner "VAULTWARDEN ADMIN PASSWORD" "$vw_pass" || {
                log_warn "VaultWarden admin password auto-generated -- retrieve from recovery kit." >&2
            }
            log_info "Generating Argon2id hash..." >&2
            local vw_hash
            vw_hash=$(generate_argon2_hash "$vw_pass")
            if [[ -z "$vw_hash" ]]; then
                log_error "Failed to generate Argon2id hash" >&2
                return 1
            fi
            log_success "VaultWarden admin hash generated (Argon2id)" >&2
            printf '%s' "$vw_hash"
            ;;

        admin_basic_auth_hash)
            local caddy_pass
            caddy_pass=$(generate_secure_string 32)
            _print_secret_banner "CADDY ADMIN PASSWORD" "$caddy_pass" || {
                log_warn "Caddy admin password auto-generated -- retrieve from recovery kit." >&2
            }
            log_info "Generating bcrypt hash for Caddy basic auth..." >&2
            local caddy_hash
            caddy_hash=$(generate_bcrypt_hash "$caddy_pass")
            if [[ -z "$caddy_hash" ]]; then
                log_error "Failed to generate bcrypt hash. Ensure apache2-utils is installed." >&2
                return 1
            fi
            if ! _bcrypt_format_ok "$caddy_hash"; then
                log_error "Generated bcrypt hash has invalid format: $caddy_hash" >&2
                return 1
            fi
            log_success "Caddy admin hash generated (htpasswd format: admin:\$2y\$...)" >&2
            printf '%s' "admin $caddy_hash"
            ;;

        caddy_cloudflare_dns_token)
            log_warn "Auto mode: Using placeholder for Cloudflare DNS token - MUST be updated before deployment" >&2
            printf '%s' "CHANGE_ME_DNS_TOKEN"
            ;;

        email_api_token)
            # Placeholder for the email provider API token.
            # Must be set via: ./utilities/secrets-rotate.sh email_api_token
            log_warn "Auto mode: Using placeholder for email API token - configure via rotate email_api_token" >&2
            printf '%s' "CHANGE_ME_EMAIL_API_TOKEN"
            ;;

        smtp_password)
            log_warn "Auto mode: Using placeholder for SMTP password - configure later in .env" >&2
            printf '%s' "CHANGE_ME_SMTP_PASSWORD"
            ;;

        push_installation_id)
            printf '%s' "CHANGE_ME_OR_LEAVE_EMPTY"
            ;;

        push_installation_key)
            printf '%s' "CHANGE_ME_OR_LEAVE_EMPTY"
            ;;

        backup_passphrase)
            local passphrase
            passphrase=$(generate_secure_string 32)
            log_success "Backup passphrase generated (32 characters)" >&2
            printf '%s' "$passphrase"
            ;;

        *)
            log_error "auto_generate_secret_field: unknown field '$field'" >&2
            return 1
            ;;
    esac
    return 0
}

_grk_sops_extract() {
    local _key="$1"
    local _secrets_file="$2"
    local _val
    # Suppress xtrace to prevent plaintext secret appearing in debug logs.
    { set +x; } 2>/dev/null
    _val=$(sops -d --extract "[\"${_key}\"]" "$_secrets_file" 2>/dev/null) \
        && printf '%s' "$_val" \
        || printf '%s' "Not Set"
    unset _val
}

generate_recovery_kit() {
    local output_file="$1"
    local age_key
    age_key=$(resolve_age_key_path) || return 1
    local secrets_file="${SECRETS_FILE}"
    local env_file="${PROJECT_ROOT:-.}/.env"

    if [[ ! -f "$age_key" ]]; then
        log_error "Age key not found: $age_key"
        return 1
    fi

    log_info "Collecting recovery data..."

    local hostname_val date_val pub_key priv_key
    hostname_val=$(hostname)
    date_val=$(date)

    if ! pub_key=$(_derive_age_public_key "$age_key"); then
        log_error "Failed to derive Age public key"
        return 1
    fi
    # Suppress xtrace before reading the private key to prevent it appearing in debug logs.
    { set +x; } 2>/dev/null
    priv_key=$(cat "$age_key")

    local domain="Not Configured"
    local admin_email="Not Configured"
    if [[ -f "$env_file" ]]; then
        domain=$(grep "^DOMAIN=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "Not Configured")
        admin_email=$(grep "^ADMIN_EMAIL=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "Not Configured")
    fi

    local repo_clone_url
    repo_clone_url="${RECOVERY_KIT_REPO_URL:-}"
    if [[ -z "$repo_clone_url" ]]; then
        repo_clone_url=$(git -C "${PROJECT_ROOT:-.}" remote get-url origin 2>/dev/null || true)
    fi
    if [[ -z "$repo_clone_url" ]]; then
        repo_clone_url="<your-repo-clone-url>"
    fi

    log_info "Decrypting secrets for export..."

    local vw_admin_hash="Not Set" caddy_hash="Not Set" smtp_pass="Not Set"
    local backup_pass="Not Set" cf_dns="Not Set"
    local push_id="Not Set" push_key="Not Set" email_api_tok="Not Set"

    if [[ -f "$secrets_file" ]]; then
        if ! ensure_sops_env; then return 1; fi
        # Guarantee cleanup_secrets_environment is called when this
        # function returns, even if an error occurs mid-way through extraction.
        trap 'cleanup_secrets_environment' RETURN

        vw_admin_hash=$(_grk_sops_extract admin_token              "$secrets_file")
        caddy_hash=$(_grk_sops_extract    admin_basic_auth_hash    "$secrets_file")
        smtp_pass=$(_grk_sops_extract     smtp_password            "$secrets_file")
        backup_pass=$(_grk_sops_extract   backup_passphrase        "$secrets_file")
        cf_dns=$(_grk_sops_extract        caddy_cloudflare_dns_token           "$secrets_file")
        push_id=$(_grk_sops_extract       push_installation_id     "$secrets_file")
        push_key=$(_grk_sops_extract      push_installation_key    "$secrets_file")
        email_api_tok=$(_grk_sops_extract email_api_token          "$secrets_file")

    else
        log_warn "secrets.yaml not found"
    fi

    if ! install -m 600 /dev/null "$output_file"; then
        log_error "Failed to create output file with secure permissions: $output_file"
        return 1
    fi

    # Use a quoted delimiter (<< 'EOF') so that the shell does
    # NOT expand any $ sequences inside the static body. Variables such as
    # $caddy_hash contain bcrypt hashes of the form "admin $2y$12$..." where
    # $2y would be silently dropped by shell expansion in an unquoted heredoc,
    # producing a garbled hash that cannot be used for Caddy auth recovery.
    # All dynamic values are injected after the static block with printf.
    # The heredoc-interspersed structure prevents full { } >> grouping here.
    # shellcheck disable=SC2129
    cat >> "$output_file" << 'EOF'
██████╗ ███████╗ ██████╗ ██████╗██╗   ██╗███████╗██████╗ ██╗   ██╗
██╔══██╗██╔════╝██╔════╝██╔═══██╗██║   ██║██╔════╝██╔══██╗╚██╗ ██╔╝
██████╔╝█████╗  ██║     ██║   ██║██║   ██║█████╗  ██████╔╝ ╚████╔╟ 
██╔══██╗██╔══╝  ██║     ██║   ██║╚██╗ ██╔╝██╔══╝  ██╔══██╗  ╚██╔╝  
██║  ██╗███████╗╚██████╗╚██████╔╝ ╚████╔╝ ███████╗██║  ██╗   ██║   
╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝   ╚═══╝  ╚══════╝╚═╝  ╚═╝   ╚═╝   
                                                                   
██╗  ██╗██╗███████╗
██║ ██╔╝██║╚══██╔══╝
█████╔╝ ██║   ██║   
██╔═██╗ ██║   ██║   
██║  ██╗██║   ██║   
╚═╝  ╚═╝╚═╝   ╚═╝   

EOF

    # Inject all dynamic values explicitly so that $ characters in secrets
    # (e.g. bcrypt hashes: $2y$12$...) are written verbatim.
    cat >> "$output_file" << 'EOF'
═══════════════════════════════════════════════════════════════════════
                        🚨 CRITICAL SECURITY DOCUMENT 🚨
═══════════════════════════════════════════════════════════════════════
EOF
    printf 'Created: %s\n' "$date_val"      >> "$output_file"
    printf 'Server:  %s\n' "$hostname_val" >> "$output_file"
    printf 'Domain:  %s\n' "$domain"       >> "$output_file"
    cat >> "$output_file" << 'EOF'

WARNING: This file contains highly sensitive UNENCRYPTED secrets.
1. Save this to your Password Manager (Secure Note) IMMEDIATELY.
2. Print a physical copy for your fireproof safe (optional).
3. DELETE THIS FILE from the server immediately after saving.

════════════════════════════════════════════════════════════════════════
SECTION 1: ENCRYPTION KEYS (THE MOST IMPORTANT PART)
════════════════════════════════════════════════════════════════════════
If you lose this key, your backups are FOREVER USELESS.

[AGE PRIVATE KEY]
EOF
    printf '%s\n' "$priv_key" >> "$output_file"
    cat >> "$output_file" << 'EOF'

[AGE PUBLIC KEY]
EOF
    printf '%s\n' "$pub_key" >> "$output_file"
    cat >> "$output_file" << 'EOF'

════════════════════════════════════════════════════════════════════════
SECTION 2: SERVER SECRETS (DECRYPTED)
════════════════════════════════════════════════════════════════════════

[SYSTEM CREDENTIALS]
Backup Encryption Passphrase:
EOF
    printf '%s\n' "$backup_pass" >> "$output_file"
    printf '\nSMTP Password (Email):\n' >> "$output_file"
    printf '%s\n' "$smtp_pass" >> "$output_file"
    printf '\nEmail API Token (email_api_token):\n' >> "$output_file"
    printf '%s\n' "$email_api_tok" >> "$output_file"
    printf '\nCloudflare DNS Token:\n' >> "$output_file"
    printf '%s\n' "$cf_dns" >> "$output_file"
    printf '\n[PUSH NOTIFICATIONS]\n' >> "$output_file"
    printf 'Installation ID:  %s\n' "$push_id" >> "$output_file"
    printf 'Installation Key: %s\n' "$push_key" >> "$output_file"
    printf '\n[ADMIN ACCESS]\n' >> "$output_file"
    printf 'Admin Email: %s\n' "$admin_email" >> "$output_file"
    cat >> "$output_file" << 'EOF'

VaultWarden Admin Password Hash (Argon2id):
EOF
    printf '%s\n' "$vw_admin_hash" >> "$output_file"
    cat >> "$output_file" << 'EOF'
(Note: Original password cannot be recovered from hash. Reset if lost.)

Caddy Basic Auth Hash (Bcrypt):
EOF
    printf '%s\n' "$caddy_hash" >> "$output_file"
    cat >> "$output_file" << 'EOF'
(Note: Original password cannot be recovered from hash. Reset if lost.)

════════════════════════════════════════════════════════════════════════
SECTION 3: DISASTER RECOVERY & MIGRATION CHECKLIST
════════════════════════════════════════════════════════════════════════

TO RESTORE THIS SERVER ON NEW HARDWARE:

1. PREPARATION
   [ ] Install Git, Docker, and SOPS on new server.
   [ ] Clone the repository:
EOF
    printf '       git clone %s\n' "$repo_clone_url" >> "$output_file"
    local repo_basename
    repo_basename=$(basename "$repo_clone_url" .git)
    {
        printf '   [ ] Run setup:\n'
        printf '       cd %s\n' "$repo_basename"
        printf '       ./setup.sh --domain %s --email %s\n' "$domain" "$admin_email"
    } >> "$output_file"
    cat >> "$output_file" << 'EOF'

2. RESTORE KEYS
   [ ] Create key directory:
       mkdir -p secrets/keys
   [ ] Restore Age Key:
       Paste the [AGE PRIVATE KEY] above into: secrets/keys/age-key.txt
   [ ] Set permissions:
       chmod 600 secrets/keys/age-key.txt

3. RESTORE DATA (Choose Option A or B)

   OPTION A: From Remote Backup (Rclone/S3)
   [ ] Configure Rclone:
       rclone config
   [ ] Download latest backup:
       rclone copy remote:bucket/backup.tar.gz.age ./backups/
   [ ] Run Restore:
       ./restore.sh latest emergency

   OPTION B: From Secrets Above (Manual Rebuild)
   [ ] Run secrets setup:
       ./setup.sh secrets
   [ ] Manually enter the values from [SECTION 2] when prompted.

4. FINALIZATION
   [ ] Start services:
       make up
   [ ] Check health:
       ./maintenance.sh health

════════════════════════════════════════════════════════════════════════
END OF RECOVERY KIT
════════════════════════════════════════════════════════════════════════
EOF

    # Unset plaintext Age private key from memory immediately after
    # the heredoc that wrote it to the output file.
    unset priv_key

    chmod 600 "$output_file"
}

_ork_generate_and_secure() {
    local output_file="$1"

    {
        printf '\n'
        printf $'═══════════════════════════════════════════════════════════════\n'
        printf ' SECURITY NOTICE -- PLAINTEXT FILE ABOUT TO BE WRITTEN\n'
        printf $'═══════════════════════════════════════════════════════════════\n'
        printf 'The recovery kit will be written to:\n'
        printf '  %s\n' "$output_file"
        printf '\n'
        printf 'Even on tmpfs, this file is visible to root and may appear\n'
        printf 'in OCI block-volume snapshots if /tmp falls back to disk.\n'
        printf 'The file will be securely deleted after you confirm.\n'
        printf $'═══════════════════════════════════════════════════════════════\n'
        printf '\n'
    } > /dev/tty 2>/dev/null || true

    # shellcheck disable=SC2064  # intentional: $output_file expands at registration to capture the path
    trap "_secure_shred '$output_file'; echo '[recovery-kit] Plaintext kit securely deleted.' >&2" RETURN

    if ! generate_recovery_kit "$output_file"; then
        log_error "Failed to generate recovery kit"
        return 1
    fi

    log_success "Recovery Kit created: $output_file"
    echo ""
    log_warn " ACTION REQUIRED -- SAVE NOW BEFORE THIS FILE IS AUTO-DELETED:"
    echo "  1. Copy ALL contents to your password manager (Secure Note)."
    echo "  2. Optionally print a physical copy for your fireproof safe."
    echo ""
    cat "$output_file"
    echo ""
    log_warn "This file will be securely deleted after you press Enter."
    log_warn "If you do not respond within 120 seconds it will be deleted automatically."
    echo ""

    # shellcheck disable=SC2034  # user_ack is the read target; value not needed, only the timeout/EOF behaviour
    local user_ack
    # shellcheck disable=SC2034
    if read -r -t 120 -p "Press Enter once you have saved the recovery kit: " user_ack 2>/dev/null \
       || true; then
        : 
    fi

    log_info "Securely deleting recovery kit from server..."
    _secure_shred "$output_file"
    trap - RETURN
    log_success "Recovery kit securely deleted from server."
    echo ""
}

offer_recovery_kit_export() {
    local auto_export="${1:-false}"

    # Always persist a secure on-disk copy in the current working
    # directory before any /dev/tty-dependent display flow. This prevents the
    # recovery kit from being lost when setup runs through an SSH jumphost,
    # nohup, or other detached TTY environment.
    local recovery_file
    recovery_file="./recovery-kit-$(date +%s).txt"
    if generate_recovery_kit "$recovery_file"; then
        chmod 600 "$recovery_file"
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_warn "  RECOVERY KIT SAVED TO: $recovery_file"
        log_warn "  SAVE THIS FILE SECURELY AND DELETE IT WHEN DONE."
        log_warn "  It contains your Age private key and all credentials."
        log_warn "  Auto-delete scheduled in 30 minutes via at(1) (if available)."
        log_warn "  Manual delete: shred -fuz '$recovery_file'"
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        # Schedule auto-delete of the on-disk plaintext recovery kit
        # so it does not persist indefinitely if the operator forgets to delete it.
        local _rk_abs
        _rk_abs="$(realpath "$recovery_file" 2>/dev/null || echo "$recovery_file")"
        if command -v at >/dev/null 2>&1; then
            if printf 'shred -fuz "%s" 2>/dev/null; rm -f "%s"\n' "$_rk_abs" "$_rk_abs" \
                    | at "now + 30 minutes" 2>/dev/null; then
                log_info "Auto-delete scheduled in 30 minutes for: $recovery_file"
            else
                log_warn "Could not schedule at(1) auto-delete — delete manually: shred -fuz '$recovery_file'"
            fi
        else
            log_warn "at(1) not available — delete manually within 30 minutes: shred -fuz '$recovery_file'"
        fi
    else
        log_error "Failed to write recovery kit to disk"
        return 1
    fi

    local tmpfs_base
    if ! tmpfs_base=$(_tmpfs_dir); then
        log_error "Cannot determine a safe (tmpfs) directory for the recovery kit. Aborting."
        return 1
    fi

    local output_file
    output_file="${tmpfs_base}/vaultwarden-recovery-kit-$(date +%Y%m%d%H%M%S).txt"

    if [[ "$auto_export" == "true" ]]; then
        log_info "Exporting recovery kit (--export-recovery-kit specified)..."
        _ork_generate_and_secure "$output_file"
        return $?
    fi

    echo ""
    read -r -p "Export a plaintext Recovery Kit? (yes/no): " export_kit
    if [[ "$export_kit" == "yes" ]]; then
        _ork_generate_and_secure "$output_file"
    fi
}

_read_dotenv_value() {
    local key="$1"
    local file="${2:-.env}"
    [[ -f "$file" ]] || { printf ''; return 0; }
    if [[ ! -r "$file" ]]; then
        log_warn "_read_dotenv_value: '${file}' is not readable by $(id -un) — returning empty for key '${key}'"
        printf ''; return 0
    fi
    local val
    val=$(grep -E "^${key}=" "$file" | head -1 | sed "s/^${key}=//;s/[[:space:]]\+#.*\$//;s/[[:space:]]*\$//")
    printf '%s' "$val"
}

# ---------------------------------------------------------------------------
# _run_yaml_nodupcheck FILE MODE
#
# Private helper shared by _validate_yaml_no_duplicates and
# _validate_no_placeholders. Runs a single python3 invocation that defines
# _NoDupLoader once and branches on MODE:
#
#   validate     — Exit 1 (with diagnostic on stderr) if any duplicate
#                  mapping key is found; exit 0 otherwise.
#   placeholders — Exit 1 and print offending key names to stdout if any
#                  value starts with PLACEHOLDER. The duplicate check is
#                  enforced first so a file with a dup key cannot silently
#                  pass the placeholder scan.
# ---------------------------------------------------------------------------
_run_yaml_nodupcheck() {
    local yaml_file="$1"
    local mode="$2"
    python3 - "$yaml_file" "$mode" <<'PYEOF'
import sys, yaml

class _NoDupLoader(yaml.SafeLoader):
    pass

def _check_no_dup_mapping(loader, node):
    keys_seen = {}
    for key_node, _ in node.value:
        key = loader.construct_object(key_node)
        if key in keys_seen:
            raise ValueError(
                "Duplicate mapping key '{}' "
                "(first at line {}, again at line {})".format(
                    key, keys_seen[key], key_node.start_mark.line + 1)
            )
        keys_seen[key] = key_node.start_mark.line + 1
    return loader.construct_mapping(node, deep=True)

_NoDupLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _check_no_dup_mapping,
)

yaml_file, mode = sys.argv[1], sys.argv[2]

try:
    with open(yaml_file, 'r', encoding='utf-8') as f:
        data = yaml.load(f, Loader=_NoDupLoader) or {}
except (yaml.YAMLError, ValueError) as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(1)

if mode == 'validate':
    sys.exit(0)

# mode == 'placeholders'
bad = []
for k, v in data.items():
    sv = str(v) if v is not None else ""
    if sv.startswith("PLACEHOLDER") or sv == "PLACEHOLDER_NOT_CONFIGURED":
        bad.append(k)

if bad:
    print("\n".join(bad))
    sys.exit(1)
PYEOF
}

_validate_yaml_no_duplicates() {
    local yaml_file="$1"
    _run_yaml_nodupcheck "$yaml_file" validate
}

_validate_no_placeholders() {
    local plain_yaml="$1"

    local offending
    local _py_rc=0
    offending=$(_run_yaml_nodupcheck "$plain_yaml" placeholders 2>/dev/null) || _py_rc=$?

    if [[ $_py_rc -ne 0 ]]; then
        log_error "Recovery kit contains unconfigured placeholder values for:"
        while IFS= read -r key; do
            log_error "  - $key"
        done <<< "$offending"
        log_error "Run './setup.sh secrets' or './utilities/secrets-rotate.sh <field>' to configure these fields first."
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# _warn_if_stack_unavailable
#
# Warn when separate-volume mode is configured but the data volume is not
# mounted. Secret editing still works; only Docker-dependent follow-up steps
# may fail.
# ---------------------------------------------------------------------------
_warn_if_stack_unavailable() {
    local env_file="${PROJECT_ROOT:-.}/.env"
    [[ -f "$env_file" ]] || return 0

    local data_volume_device data_volume_mount
    data_volume_device=$(_read_dotenv_value "DATA_VOLUME_DEVICE" "$env_file")
    data_volume_mount=$(_read_dotenv_value  "DATA_VOLUME_MOUNT"  "$env_file")

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
# export_docker_secrets DOCKER_DIR [SECRETS_FILE]
#
# Decrypt SECRETS_FILE (defaults to $SECRETS_FILE / secrets/secrets.yaml) and
# write one flat file per known secret key into DOCKER_DIR (mode 755).
# Each output file is created mode 444 (via write_secret_file). Placeholder
# values (CHANGE_ME*, NOT_USED*, null) are skipped with a warning so that
# genuinely-empty optional secrets do not overwrite populated files.
#
# Hardening (consolidated from startup.sh::prepare_docker_secrets):
#   1. SOPS decryption is written to a mktemp cache inside docker_dir (mode
#      700, not world-listable /tmp) to eliminate the TOCTOU window on
#      shared hosts.
#   2. After distributing per-key files, every output file is scanned for a
#      leading "ENC[" string. Any hit means SOPS silently produced ciphertext
#      instead of plaintext; the bad files are shredded and the function
#      returns 1 with an actionable remediation message.
#   3. The cache file is shredded via a RETURN-scoped trap inside this
#      function so it is always cleaned up, even on ERR paths.
#
# This is the canonical, single implementation shared by setup-secrets.sh and
# secrets-rotate.sh. Both previously carried inline copies of this logic.
# ---------------------------------------------------------------------------
export_docker_secrets() {
    local docker_dir="$1"
    local secrets_file="${2:-${SECRETS_FILE}}"

    log_info "Exporting decrypted secrets to Docker secrets directory..."

    if [[ ! -f "$secrets_file" ]]; then
        log_warn "export_docker_secrets: secrets file not found: $secrets_file — skipping"
        return 0
    fi

    if ! mkdir -p "$docker_dir"; then
        log_error "export_docker_secrets: failed to create $docker_dir"
        return 1
    fi
    chmod 755 "$docker_dir"

    # Create the SOPS cache file inside the docker_dir (mode 755, not
    # world-listable /tmp), eliminating the TOCTOU
    # window between mktemp and the subsequent chmod on a shared host.
    local _eds_cache
    _eds_cache=$(mktemp --tmpdir="$docker_dir" .sops-cache.XXXXXXXXXX) || {
        log_error "export_docker_secrets: failed to create secure temp file in $docker_dir"
        return 1
    }
    install -m 600 /dev/null "$_eds_cache" 2>/dev/null || true

    # Guarantee cache file cleanup and SOPS_CONFIG unset on any return path.
    # shellcheck disable=SC2064  # intentional: $_eds_cache expands at registration
    trap "{ _secure_shred '$_eds_cache' 2>/dev/null || true; cleanup_secrets_environment; }" RETURN

    if ! ensure_sops_env; then
        log_error "export_docker_secrets: failed to set up SOPS environment"
        return 1
    fi

    local _sops_rc=0
    sops -d "$secrets_file" > "$_eds_cache" || _sops_rc=$?
    cleanup_secrets_environment
    if [[ $_sops_rc -ne 0 ]]; then
        log_error "export_docker_secrets: SOPS decryption failed (exit ${_sops_rc})"
        return 1
    fi

    local _eds_keys=(
        admin_token
        admin_basic_auth_hash
        caddy_cloudflare_dns_token
        email_api_token
        smtp_password
        backup_passphrase
        push_installation_id
        push_installation_key
    )

    local _failed=0
    local _key _value

    while IFS='=' read -r _key _value; do
        [[ -z "$_key" ]] && continue
        local _known=false
        local _k
        for _k in "${_eds_keys[@]}"; do
            [[ "$_k" == "$_key" ]] && { _known=true; break; }
        done
        [[ "$_known" == "true" ]] || continue

        # Skip placeholder or null values; warn so the admin can act.
        if [[ -z "$_value" ]] \
            || [[ "$_value" == "CHANGE_ME"* ]] \
            || [[ "$_value" == "NOT_USED"* ]] \
            || [[ "$_value" == "null" ]]; then
            log_warn "export_docker_secrets: '$_key' skipped (placeholder/empty — rotate with: ./utilities/secrets-rotate.sh ${_key})"
            unset _value
            continue
        fi

        if ! write_secret_file "${docker_dir}/${_key}" "$_value"; then
            log_error "export_docker_secrets: failed to write ${docker_dir}/${_key}"
            _failed=$(( _failed + 1 ))
        fi
        unset _value
    done < <(
        python3 - "$_eds_cache" <<'PYEOF'
import sys, yaml
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}
for k, v in data.items():
    if isinstance(v, (str, int, float)):
        print(f"{k}={v}")
PYEOF
    )
    unset _key

    # Sanity-check: if any output file starts with "ENC[", SOPS produced
    # raw ciphertext — fail loudly before containers start.
    local _bad_secrets=()
    local _f _head
    for _f in "$docker_dir"/*; do
        [[ -f "$_f" ]] || continue
        [[ "$(basename "$_f")" == .sops-cache.* ]] && continue
        if read -r -n 4 _head < "$_f" 2>/dev/null && [[ "$_head" == "ENC[" ]]; then
            _bad_secrets+=("$(basename "$_f")")
            _secure_shred "$_f" 2>/dev/null || rm -f "$_f"
        fi
    done
    if [[ ${#_bad_secrets[@]} -gt 0 ]]; then
        log_error "export_docker_secrets: secret file(s) contain raw SOPS ciphertext — decryption failed silently:"
        local _s
        for _s in "${_bad_secrets[@]}"; do
            log_error "  ${docker_dir}/${_s}"
        done
        log_error "Remediation:"
        log_error "  1. Run: make key-health  (verify age key is present and readable)"
        log_error "  2. Run: sudo rm -f ${docker_dir}/*  (clear stale files)"
        log_error "  3. Run: make up  (re-decrypt and restart)"
        return 1
    fi

    # crowdsec_cf_firewall_token is intentionally not part of secrets.yaml.
    # Canonical location is a flat file at:
    #   ${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/secrets/.docker_secrets/crowdsec_cf_firewall_token
    # Mirror it into the active docker secret directory when present.
    local _project_state_dir _cf_flat
    _project_state_dir="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"
    _cf_flat="${_project_state_dir}/secrets/.docker_secrets/crowdsec_cf_firewall_token"
    if [[ -f "$_cf_flat" ]]; then
        local _cf_value
        _cf_value=$(tr -d '[:space:]' < "$_cf_flat" 2>/dev/null || true)
        if [[ -n "$_cf_value" && "$_cf_value" != CHANGE_ME* && "$_cf_value" != PLACEHOLDER* ]]; then
            write_secret_file "${docker_dir}/crowdsec_cf_firewall_token" "$_cf_value" || return 1
        fi
    fi

    if [[ $_failed -gt 0 ]]; then
        log_error "export_docker_secrets: $_failed key(s) failed to export"
        return 1
    fi

    log_success "Docker secrets exported to: $docker_dir"
    return 0
}
