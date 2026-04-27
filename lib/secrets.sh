#!/usr/bin/env bash
# P4 merge SKIPPED: combining backup_utils.sh (744 lines) + secrets.sh (~1098 lines)
# would produce an ~1842-line file exceeding the maintainability threshold.
# These libraries remain separate.
# lib/secrets.sh - Shared secrets management functions
# Used by edit-secrets.sh and setup.sh (--phase=secrets)
#

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This library should be sourced, not executed directly"
    exit 1
fi

# Source crypto library for hash functions.
# Use a private variable so we do not clobber the caller's SCRIPT_DIR.
_SECRETS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SECRETS_LIB_DIR}/crypto.sh"
unset _SECRETS_LIB_DIR

set -euo pipefail

# Configuration
SECRETS_FILE="${SECRETS_FILE:-secrets/secrets.yaml}"
AGE_KEY_FILE="${AGE_KEY_FILE:-secrets/keys/age-key.txt}"
SECRETS_BACKUP_DIR="${SECRETS_BACKUP_DIR:-secrets}"

# ---------------------------------------------------------------------------
# ensure_sops_env
# ---------------------------------------------------------------------------
ensure_sops_env() {
    local age_key="${1:-$AGE_KEY_FILE}"

    if [[ ! "$age_key" = /* ]]; then
        age_key="${PROJECT_ROOT:-$(pwd)}/$age_key"
    fi

    if [[ ! -f "$age_key" ]]; then
        log_error "Age key not found: $age_key"
        return 1
    fi

    export SOPS_AGE_KEY_FILE="$age_key"
    export SOPS_CONFIG="${PROJECT_ROOT:-$(pwd)}/.sops.yaml"
    log_debug "SOPS env set: key=$SOPS_AGE_KEY_FILE  config=$SOPS_CONFIG"
    return 0
}

setup_secrets_environment() { ensure_sops_env "${1:-}"; }

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

    chmod 600 "$dest"
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

    # Use a single sops invocation. stderr goes to a mktemp file
    # (cleaned up unconditionally via trap); stdout is captured as the value.
    local _tmp_err
    _tmp_err=$(mktemp) || { log_error "decrypt_secret: mktemp failed"; return 1; }
    # Unconditional cleanup: remove the temp file whether we succeed or fail.
    # shellcheck disable=SC2064
    trap "rm -f '$_tmp_err'" RETURN

    local value rc=0
    # Suppress xtrace around secret decryption to prevent value
    # appearing in debug logs or core dumps via set -x output.
    { set +x; } 2>/dev/null
    # Single sops call — stdout → value, stderr → temp file.
    # The key file path is included in error output to aid disaster recovery.
    value=$(sops -d --extract "[\"$key\"]" "$secrets_file" 2>"$_tmp_err") || rc=$?

    # Unset key file path from environment so child processes do not inherit it.
    unset SOPS_AGE_KEY_FILE

    if [[ $rc -ne 0 ]]; then
        local sops_stderr
        sops_stderr=$(cat "$_tmp_err")
        log_error "decrypt_secret: failed to decrypt key '$key' from $secrets_file (sops exit $rc)"
        log_error "  Expected AGE key: ${SOPS_AGE_KEY_FILE:-<unset — ensure_sops_env ran>}"
        if [[ -n "${sops_stderr:-}" ]]; then
            log_error "  sops error: $sops_stderr"
        fi
        return 1
    fi

    printf '%s' "$value"
    # Unset plaintext value immediately after use.
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
    # Capture sops stderr for actionable diagnostics on failure.
    sops_stderr=$(sops -d "$secrets_file" 2>&1 >/dev/null) || rc=$?
    if [[ $rc -eq 0 ]]; then
        keys=$(sops -d "$secrets_file" 2>/dev/null \
            | python3 -c "
import yaml, sys
data = yaml.safe_load(sys.stdin)
if isinstance(data, dict):
    for k in data.keys():
        print(k)
" 2>/dev/null) || rc=$?
    fi

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
    cleanup_secrets_environment
    if [[ $rc -ne 0 ]]; then
        log_error "Cannot decrypt secrets file: $secrets_file (sops exit $rc)"
        log_error "  Check AGE key at: ${SOPS_AGE_KEY_FILE:-<unset>}"
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
    # Capture sops stderr for actionable diagnostics.
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
        "fail2ban_cloudflare_firewall_token"
        "email_api_token"
        "backup_passphrase"
    )
    if ! ensure_sops_env; then return 1; fi
    local missing_secrets=()
    for secret in "${required_secrets[@]}"; do
        local sops_stderr rc=0
        # Capture sops stderr per-key so missing vs. undecryptable
        # secrets produce distinct diagnostic messages.
        sops_stderr=$(sops -d --extract "[\"$secret\"]" "$secrets_file" 2>&1 >/dev/null) || rc=$?
        if [[ $rc -ne 0 ]]; then
            # One clear log_error per missing key so the admin sees
            # an individual actionable line for each absent secret.
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
    local secrets_to_check=(
        "admin_token"
        "admin_basic_auth_hash"
        "caddy_cloudflare_dns_token"
        "fail2ban_cloudflare_firewall_token"
        "email_api_token"
        "backup_passphrase"
    )
    if ! ensure_sops_env; then return 1; fi
    local placeholder_secrets=()
    local unreadable_secrets=()
    for secret in "${secrets_to_check[@]}"; do
        local value sops_stderr rc=0
        # Suppress xtrace to prevent plaintext secret appearing in debug logs.
        { set +x; } 2>/dev/null
        sops_stderr=$(sops -d --extract "[\"$secret\"]" "$secrets_file" 2>&1 >/dev/null) || rc=$?
        if [[ $rc -ne 0 ]]; then
            log_error "check_placeholder_values: failed to read secret '$secret' from $secrets_file (sops exit $rc)"
            if [[ -n "${sops_stderr:-}" ]]; then
                log_error "  sops error: $sops_stderr"
            fi
            unreadable_secrets+=("$secret")
            continue
        fi
        value=$(sops -d --extract "[\"$secret\"]" "$secrets_file" 2>/dev/null) || {
            log_error "check_placeholder_values: internal error re-reading secret '$secret' after successful validation"
            unreadable_secrets+=("$secret")
            continue
        }
        if [[ "$value" =~ ^(CHANGE_ME|PLACEHOLDER_NOT_CONFIGURED) ]] || [[ -z "$value" ]]; then
            # One clear log_warn per placeholder key so the admin
            # sees an individual actionable line for each stale value.
            log_warn "check_placeholder_values: secret '$secret' is set to a placeholder or is empty"
            placeholder_secrets+=("$secret")
        fi
        unset value
    done
    # LS-9 FIX: clean up SOPS env before returning
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
    # Capture sops stderr for actionable diagnostics on failure.
    sops_stderr=$(sops -d "$secrets_file" 2>&1 >/dev/null) || rc=$?
    if [[ $rc -eq 0 ]]; then
        keys=$(sops -d "$secrets_file" 2>/dev/null \
            | python3 -c "import yaml, sys; [print(k) for k in yaml.safe_load(sys.stdin).keys()]" 2>/dev/null) || rc=$?
    fi
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
    local backup_file="$backup_dir/secrets.yaml.backup-$(date +%Y%m%d-%H%M%S)"
    log_info "Creating backup: $(basename "$backup_file")"
    # LS-4 FIX: pre-create at 600 so the file is never world-readable.
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
    # LS-5 FIX: NUL-delimited pipeline — safe for paths containing spaces.
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
    # dd fallback: overwrite with random bytes then unlink
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
        zone_id=$(get_config_value "CLOUDFLARE_ZONE_ID" "")
    fi

    if [[ -z "$zone_id" ]] \
        || [[ "$zone_id" == "your_cloudflare_zone_id_here" ]] \
        || [[ "$zone_id" == CHANGE_ME* ]] \
        || [[ "$zone_id" =~ ^[[:space:]]*$ ]]; then
        log_warn "validate_cloudflare_token: CLOUDFLARE_ZONE_ID is not configured -- validation skipped (token NOT verified)"
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

        fail2ban_cloudflare_firewall_token)
            log_info "Required Permissions: Zone:Firewall Services:Edit" >&2
            log_info "Create at: https://dash.cloudflare.com/profile/api-tokens" >&2
            local token
            read -r -p "Cloudflare Firewall API token: " token
            if [[ -n "$token" && "$token" != CHANGE_ME* ]]; then
                if validate_cloudflare_token "$token" "firewall" 2>/dev/null; then
                    log_success "Firewall token validated successfully" >&2
                else
                    log_warn "Token validation failed or zone not configured - continuing anyway" >&2
                fi
            fi
            printf '%s' "$token"
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

    case "$field" in

        admin_token)
            local vw_pass
            vw_pass=$(generate_secure_string 32)
            {
                printf '\n'
                printf '\033[0;31m! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !\033[0m\n'
                printf '\033[0;31m!\033[0m                                                             \033[0;31m!\033[0m\n'
                printf '\033[0;31m AUTO-GENERATED VAULTWARDEN ADMIN PASSWORD:\033[0m\n'
                printf '   \033[0;32m%s\033[0m\n' "$vw_pass"
                printf '\n'
                printf '\033[0;31m SAVE THIS PASSWORD SECURELY - It cannot be recovered!\033[0m\n'
                printf '\033[0;31m!\033[0m                                                             \033[0;31m!\033[0m\n'
                printf '\033[0;31m! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !\033[0m\n'
                printf '\n'
            } > /dev/tty 2>/dev/null || {
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
            {
                printf '\n'
                printf '\033[0;31m! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !\033[0m\n'
                printf '\033[0;31m!\033[0m                                                             \033[0;31m!\033[0m\n'
                printf '\033[0;31m AUTO-GENERATED CADDY ADMIN PASSWORD:\033[0m\n'
                printf '   \033[0;32m%s\033[0m\n' "$caddy_pass"
                printf '\n'
                printf '\033[0;31m SAVE THIS PASSWORD SECURELY - It cannot be recovered!\033[0m\n'
                printf '\033[0;31m!\033[0m                                                             \033[0;31m!\033[0m\n'
                printf '\033[0;31m! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !\033[0m\n'
                printf '\n'
            } > /dev/tty 2>/dev/null || {
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

        fail2ban_cloudflare_firewall_token)
            log_warn "Auto mode: Using placeholder for Cloudflare Firewall token - MUST be updated before deployment" >&2
            printf '%s' "CHANGE_ME_FIREWALL_TOKEN"
            ;;

        email_api_token)
            # Placeholder for the email provider API token.
            # Must be set via: ./edit-secrets.sh --rotate email_api_token
            log_warn "Auto mode: Using placeholder for email API token - configure via --rotate email_api_token" >&2
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
    local age_key="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"
    local secrets_file="${SECRETS_FILE:-secrets/secrets.yaml}"
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
    { set +x; } 2>/dev/null    priv_key=$(cat "$age_key")

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
    local backup_pass="Not Set" cf_dns="Not Set" cf_fw="Not Set"
    local push_id="Not Set" push_key="Not Set" email_api_tok="Not Set"

    if [[ -f "$secrets_file" ]]; then
        if ! ensure_sops_env; then return 1; fi

        vw_admin_hash=$(_grk_sops_extract admin_token              "$secrets_file")
        caddy_hash=$(_grk_sops_extract    admin_basic_auth_hash    "$secrets_file")
        smtp_pass=$(_grk_sops_extract     smtp_password            "$secrets_file")
        backup_pass=$(_grk_sops_extract   backup_passphrase        "$secrets_file")
        cf_dns=$(_grk_sops_extract        caddy_cloudflare_dns_token           "$secrets_file")
        cf_fw=$(_grk_sops_extract         fail2ban_cloudflare_firewall_token   "$secrets_file")
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
    printf '%s\n' \
        "\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550" \
        "                            \U0001F6A8 CRITICAL SECURITY DOCUMENT \U0001F6A8" \
        "\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550" \
        >> "$output_file"
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
    printf '\nCloudflare Firewall Token:\n' >> "$output_file"
    printf '%s\n' "$cf_fw" >> "$output_file"
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
    # repo_basename: strip trailing .git if present
    local repo_basename
    repo_basename=$(basename "$repo_clone_url" .git)
    printf '   [ ] Run setup:\n' >> "$output_file"
    printf '       cd %s\n' "$repo_basename" >> "$output_file"
    printf '       ./setup.sh --domain %s --email %s\n' "$domain" "$admin_email" >> "$output_file"
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
       ./restore.sh --type emergency

   OPTION B: From Secrets Above (Manual Rebuild)
   [ ] Run secrets setup:
       ./setup.sh --phase=secrets
   [ ] Manually enter the values from [SECTION 2] when prompted.

4. FINALIZATION
   [ ] Start services:
       make up
   [ ] Check health:
       ./maintenance.sh --health

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
        printf '\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n'
        printf ' SECURITY NOTICE -- PLAINTEXT FILE ABOUT TO BE WRITTEN\n'
        printf '\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n'
        printf 'The recovery kit will be written to:\n'
        printf '  %s\n' "$output_file"
        printf '\n'
        printf 'Even on tmpfs, this file is visible to root and may appear\n'
        printf 'in OCI block-volume snapshots if /tmp falls back to disk.\n'
        printf 'The file will be securely deleted after you confirm.\n'
        printf '\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n'
        printf '\n'
    } > /dev/tty 2>/dev/null || true

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

    local user_ack
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

    # SS-RK1 FIX: Always persist a secure on-disk copy in the current working
    # directory before any /dev/tty-dependent display flow. This prevents the
    # recovery kit from being lost when setup runs through an SSH jumphost,
    # nohup, or other detached TTY environment.
    local recovery_file="./recovery-kit-$(date +%s).txt"
    if generate_recovery_kit "$recovery_file"; then
        chmod 600 "$recovery_file"
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_warn "  RECOVERY KIT SAVED TO: $recovery_file"
        log_warn "  SAVE THIS FILE SECURELY AND DELETE IT WHEN DONE."
        log_warn "  It contains your Age private key and all credentials."
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log_error "Failed to write recovery kit to disk"
        return 1
    fi

    local tmpfs_base
    if ! tmpfs_base=$(_tmpfs_dir); then
        log_error "Cannot determine a safe (tmpfs) directory for the recovery kit. Aborting."
        return 1
    fi

    local output_file="${tmpfs_base}/vaultwarden-recovery-kit-$(date +%Y%m%d%H%M%S).txt"

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
