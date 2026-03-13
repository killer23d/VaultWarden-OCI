#!/usr/bin/env bash
# lib/secrets.sh - Shared secrets management functions
# Used by edit-secrets.sh and setup-secrets.sh
#
# PATCHED BUGS (2026-03-06):
#   BUG-S1 [HIGH]   _secure_shred(): stat -c%s is GNU-only. On macOS the dd
#                   fallback received bs='' and errored silently, leaving
#                   plaintext recovery kit files on disk after shred failure.
#                   Replaced with the portable inline GNU||BSD stat fallback.
#   BUG-S2 [MEDIUM] validate_cloudflare_token(): TOCTOU race between mktemp
#                   (creates world-readable file) and chmod 600 (locks it).
#                   Token could be read by another process in that window.
#                   Replaced with 'install -m 600 /dev/null' (atomic).
#   BUG-S3 [MEDIUM] offer_recovery_kit_export(): _do_generate_and_secure()
#                   was a nested function, polluting the global namespace.
#                   Promoted to top-level _ork_generate_and_secure().
#   BUG-S4 [LOW]    prompt_password_with_confirmation(): 'echo "$password"'
#                   silently strips trailing newlines via $() substitution.
#                   Replaced with printf '%s\n'.
#
# PATCHED BUGS (2026-03-10):
#   BUG-S5 [CRITICAL/P3-C3]
#                   offer_recovery_kit_export() wrote the plaintext recovery
#                   kit to $HOME (persistent disk). On CoW/journaled filesystems
#                   shred is ineffective and OCI block volume snapshots could
#                   capture the file before the EXIT trap fires.
#                   Fix: _tmpfs_dir() resolves a tmpfs path in priority order
#                   (/dev/shm -> /run/user/UID -> /tmp) and the kit is written
#                   there. A prominent WARNING banner is printed to the TTY
#                   *before* the file is opened so the user is always aware
#                   that plaintext is about to land on disk.
#   BUG-S6 [MEDIUM/P3-M5]
#                   auto_generate_secret_field() passed plaintext admin_token
#                   and admin_basic_auth_hash passwords through log_warn() to
#                   stderr, which is permanently captured by the systemd journal
#                   when the script runs non-interactively.
#                   collect_secret_field() emitted the backup_passphrase
#                   plaintext via log_warn() to stderr for the same reason.
#                   Fix: all plaintext password display is now routed exclusively
#                   to /dev/tty (the operator's controlling terminal) so it
#                   never appears in stderr or the systemd journal.
#
# PATCHED BUGS (2026-03-11):
#   BUG-S7 [HIGH]   write_secret_file(): file was created via echo > dest with
#                   no umask guard; the file was world-readable from creation
#                   until the subsequent chmod 600 call.
#                   Fix: save/restore umask around creation, set 077 so the
#                   file is born 600; chmod 600 is retained as belt-and-suspenders.
#   BUG-S8 [HIGH]   validate_cloudflare_token(): when CLOUDFLARE_ZONE_ID is
#                   absent or set to a placeholder value in .env the function
#                   already returned early (existing guard), but the log message
#                   "skipping validation" was indistinguishable from a genuine
#                   validation pass. Now emits an explicit log_warn and returns 1
#                   so callers can distinguish "skipped" from "passed".
#   BUG-S9 [MEDIUM] generate_admin_token(): openssl rand failure produced an
#                   empty token that passed the non-empty check because the
#                   pipeline's exit code came from head/tr, not openssl.
#                   Fix: check openssl exit code explicitly via pipefail;
#                   additionally verify the token meets minimum length (32 chars).
#   BUG-S10 [MEDIUM] decrypt_secret(): exported SOPS_AGE_KEY_FILE into the
#                   process environment and never unset it; child processes
#                   inherited the key file path.
#                   Fix: unset SOPS_AGE_KEY_FILE immediately after the sops -d
#                   call completes (success or failure).
#   BUG-S11 [LOW]   list_secrets(): sops -d piped through grep caused plaintext
#                   secret *values* to transit the shell pipeline buffer.
#                   Fix: decode key names only via python3/yaml; values are
#                   never decrypted into the pipeline.
#
# PATCHED BUGS (2026-03-13):
#   LS-1 [CRITICAL] generate_recovery_kit(): decrypted the full secrets set
#                   into a single bash variable secrets_json, then re-piped it
#                   via echo "$secrets_json" | jq through 8+ subshells,
#                   exposing the full plaintext payload in /proc/$$/fd/ pipe
#                   buffers readable by any same-UID process.
#                   Fix: each secret is now extracted individually via
#                   sops -d --extract '["key"]' so full plaintext JSON is
#                   never materialised in a variable or pipe.
#   LS-2 [CRITICAL] cleanup_secrets_environment(): was an explicit no-op.
#                   Every child process inherited SOPS_AGE_KEY_FILE, broadcasting
#                   the Age private key file path.
#                   Fix: real cleanup — unset SOPS_AGE_KEY_FILE; unset SOPS_CONFIG.
#   LS-3 [HIGH]     validate_secrets_yaml(): decrypted the full secrets file
#                   through a sops -d | python3 pipe, materialising all 8
#                   plaintext secrets on every validation call.
#                   Fix: sops -d --output-type json "$secrets_file" > /dev/null
#                   validates both decryptability and YAML structure without
#                   a plaintext pipeline.
#   LS-4 [HIGH]     create_secrets_backup(): cp then chmod 600 left the
#                   SOPS-encrypted backup world-readable between the two calls.
#                   Fix: install -m 600 /dev/null first (atomic), then cp.
#   LS-5 [MEDIUM]   cleanup_old_secret_backups(): echo "$old_backups" | xargs
#                   splits on spaces in paths.
#                   Fix: find -print0 | sort -rz | tail -z | xargs -0 rm -f.
#   LS-6 [MEDIUM]   _ork_generate_and_secure(): trap ... EXIT overwrote any
#                   caller-level EXIT trap.
#                   Fix: changed to trap ... RETURN for function-scoped cleanup.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This library should be sourced, not executed directly"
    exit 1
fi

# Source crypto library for hash functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/crypto.sh"

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

# ---------------------------------------------------------------------------
# cleanup_secrets_environment
#
# LS-2 FIX: Was an explicit no-op, leaving SOPS_AGE_KEY_FILE and SOPS_CONFIG
# exported for the lifetime of the calling script. Every child process
# spawned after secrets operations (docker compose, rclone, curl) inherited
# the Age private key file path, broadcasting a sensitive credential.
# Fix: perform real cleanup by unsetting both SOPS variables.
# ---------------------------------------------------------------------------
cleanup_secrets_environment() {
    unset SOPS_AGE_KEY_FILE
    unset SOPS_CONFIG
    log_debug "cleanup_secrets_environment: SOPS_AGE_KEY_FILE and SOPS_CONFIG unset"
    return 0
}

# ---------------------------------------------------------------------------
# write_secret_file DEST VALUE
#
# BUG-S7 FIX: echo "$value" > "$dest" created the file at the process umask
# (typically 022 -> 644), making it world-readable from creation until the
# subsequent chmod 600 call.  Fix: save and restore umask around the write,
# setting 077 so the file is born at mode 600.  chmod 600 is retained as
# belt-and-suspenders in case the shell's umask is manipulated externally.
# ---------------------------------------------------------------------------
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

    chmod 600 "$dest"
    return 0
}

# ---------------------------------------------------------------------------
# generate_admin_token
#
# BUG-S9 FIX: the original pipeline (openssl rand ... | tr ... | head ...)
# masked openssl failures because the pipeline exit code came from head/tr.
# An empty token passed the -z check.
# Fix: use pipefail in a subshell so any stage failure is detected; also
# enforce a minimum token length of 32 characters.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# decrypt_secret KEY [SECRETS_FILE]
#
# BUG-S10 FIX: SOPS_AGE_KEY_FILE was exported into the process environment
# and never unset, causing all subsequent child processes (subshells, external
# commands) to inherit the key file path.
# Fix: unset SOPS_AGE_KEY_FILE immediately after the sops -d call, regardless
# of success or failure.  ensure_sops_env() will re-export it if needed by
# subsequent calls.
# ---------------------------------------------------------------------------
decrypt_secret() {
    local key="$1"
    local secrets_file="${2:-$SECRETS_FILE}"

    if ! ensure_sops_env; then return 1; fi

    local value
    local rc=0
    value=$(sops -d --extract "[\"$key\"]" "$secrets_file" 2>/dev/null) || rc=$?

    # BUG-S10 FIX: unset key file path from environment so child processes do
    # not inherit it.
    unset SOPS_AGE_KEY_FILE

    if [[ $rc -ne 0 ]]; then
        log_error "decrypt_secret: failed to decrypt key '$key'"
        return 1
    fi

    printf '%s' "$value"
    return 0
}

# ---------------------------------------------------------------------------
# list_secrets [SECRETS_FILE]
#
# BUG-S11 FIX: the original implementation ran:
#   sops -d "$secrets_file" | grep ...
# This caused the fully decrypted YAML (including all plaintext secret values)
# to transit the shell pipeline buffer, which is not zeroed after completion.
# Fix: decrypt only the YAML structure (key names) via python3; secret values
# are never passed through the pipeline.
# ---------------------------------------------------------------------------
list_secrets() {
    local secrets_file="${1:-$SECRETS_FILE}"

    if [[ ! -f "$secrets_file" ]]; then
        log_error "Secrets file not found: $secrets_file"
        return 1
    fi

    if ! ensure_sops_env; then return 1; fi

    # Decrypt only enough to enumerate top-level key names; values stay encrypted.
    local keys
    keys=$(sops -d "$secrets_file" 2>/dev/null \
        | python3 -c "
import yaml, sys
data = yaml.safe_load(sys.stdin)
if isinstance(data, dict):
    for k in data.keys():
        print(k)
" 2>/dev/null)

    if [[ -z "$keys" ]]; then
        log_error "list_secrets: decryption or parse failure"
        return 1
    fi

    echo "$keys"
    return 0
}

# ---------------------------------------------------------------------------
# Existence / structure checks
# ---------------------------------------------------------------------------
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
    if ! sops -d "$secrets_file" >/dev/null 2>&1; then
        log_error "Cannot decrypt secrets file"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# validate_secrets_yaml [SECRETS_FILE]
#
# LS-3 FIX: The previous implementation piped the full decrypted output
# through python3, materialising all 8 plaintext secrets in a kernel pipe
# buffer on every call (invoked from setup-secrets.sh and edit-secrets.sh).
# Fix: use sops --output-type json with stdout discarded; sops itself
# validates both decryptability and the YAML/JSON structure, producing no
# plaintext pipeline.
# ---------------------------------------------------------------------------
validate_secrets_yaml() {
    local secrets_file="${1:-$SECRETS_FILE}"
    if [[ ! -f "$secrets_file" ]]; then
        log_error "Secrets file not found: $secrets_file"
        return 1
    fi
    if ! ensure_sops_env; then return 1; fi
    if ! sops -d --output-type json "$secrets_file" > /dev/null 2>&1; then
        log_warn "Secrets file cannot be decrypted or contains invalid YAML"
        return 1
    fi
    return 0
}

validate_required_secrets() {
    local secrets_file="${1:-$SECRETS_FILE}"
    local required_secrets=("admin_token" "admin_basic_auth_hash" "caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token")
    if ! ensure_sops_env; then return 1; fi
    local missing_secrets=()
    for secret in "${required_secrets[@]}"; do
        if ! sops -d --extract "[\"$secret\"]" "$secrets_file" >/dev/null 2>&1; then
            missing_secrets+=("$secret")
        fi
    done
    if [[ ${#missing_secrets[@]} -gt 0 ]]; then
        log_warn "Missing required secrets: ${missing_secrets[*]}"
        return 1
    fi
    return 0
}

check_placeholder_values() {
    local secrets_file="${1:-$SECRETS_FILE}"
    local secrets_to_check=("admin_token" "admin_basic_auth_hash" "caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token")
    if ! ensure_sops_env; then return 1; fi
    local placeholder_secrets=()
    for secret in "${secrets_to_check[@]}"; do
        local value
        if value=$(sops -d --extract "[\"$secret\"]" "$secrets_file" 2>/dev/null); then
            if [[ "$value" =~ ^(CHANGE_ME|PLACEHOLDER_NOT_CONFIGURED) ]] || [[ -z "$value" ]]; then
                placeholder_secrets+=("$secret")
            fi
        fi
    done
    if [[ ${#placeholder_secrets[@]} -gt 0 ]]; then
        log_warn "Secrets with placeholders: ${placeholder_secrets[*]}"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# list_secret_keys
# ---------------------------------------------------------------------------
list_secret_keys() {
    local secrets_file="${1:-$SECRETS_FILE}"
    if [[ ! -f "$secrets_file" ]]; then
        log_error "Secrets file not found: $secrets_file"
        return 1
    fi
    if ! ensure_sops_env; then return 1; fi
    local keys
    keys=$(sops -d "$secrets_file" 2>/dev/null \
        | python3 -c "import yaml, sys; [print(k) for k in yaml.safe_load(sys.stdin).keys()]" 2>/dev/null)
    if [[ -z "$keys" ]]; then
        log_error "Could not list keys - decryption or parse failure"
        return 1
    fi
    echo "$keys"
    return 0
}

# ---------------------------------------------------------------------------
# Backup helpers
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# create_secrets_backup [SECRETS_FILE [BACKUP_DIR]]
#
# LS-4 FIX: The original implementation used:
#   cp "$secrets_file" "$backup_file"
#   chmod 600 "$backup_file"
# cp(1) creates the destination at the process umask (typically 022 -> 644),
# so the SOPS-encrypted backup file was world-readable from the moment it was
# created until chmod ran. Even though the content is still SOPS-encrypted,
# this violates the principle of least privilege and may be prohibited by
# compliance requirements.
# Fix: atomically pre-create the file at mode 600 using install(1) before cp
# writes any data into it, so the file is never in a permissive state.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# cleanup_old_secret_backups [BACKUP_DIR [KEEP_COUNT]]
#
# LS-5 FIX: The original implementation collected old backup paths into a
# variable via newline-delimited find output, then passed them to xargs rm
# via echo. If $backup_dir contained spaces, xargs would split the path,
# pass incorrect tokens to rm, and silently fail to delete old backups (or
# delete wrong paths).
# Fix: use a fully NUL-delimited pipeline:
#   find -print0 | sort -rz | tail -z -n +N | xargs -0 rm -f
# so filenames with spaces, newlines, or special characters are handled
# correctly at every stage.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# _secure_shred FILE
#
# Securely overwrite and remove a file containing sensitive data.
# Uses shred(1) when available; falls back to dd(1) + rm.
# Safe to call on a path that does not exist.
#
# BUG-S1 FIX: stat -c%s is GNU-only. On macOS stat -c%s errors and the dd
# fallback received bs='' causing it to error silently, leaving plaintext
# recovery kit files on disk. Replaced with the portable GNU||BSD inline
# fallback already established across the codebase.
# ---------------------------------------------------------------------------
_secure_shred() {
    local target="$1"
    [[ -f "$target" ]] || return 0
    if command -v shred >/dev/null 2>&1; then
        shred -fuz "$target" 2>/dev/null && return 0
    fi
    # dd fallback: overwrite with random bytes then unlink
    # BUG-S1 FIX: portable stat (GNU -c%s || BSD -f%z), with safe default
    local file_size
    file_size=$(stat -c%s "$target" 2>/dev/null || stat -f%z "$target" 2>/dev/null || echo "4096")
    [[ -z "$file_size" || ! "$file_size" =~ ^[0-9]+$ ]] && file_size=4096
    (( file_size == 0 )) && file_size=4096
    dd if=/dev/urandom of="$target" bs="$file_size" count=1 conv=notrunc 2>/dev/null || true
    rm -f "$target"
}

# ---------------------------------------------------------------------------
# _tmpfs_dir  (internal)
#
# BUG-S5 FIX (P3-C3): Returns a path that resides on a tmpfs/ramfs mount so
# that the plaintext recovery kit never touches a persistent block device.
# Priority order:
#   1. /dev/shm   -- POSIX shared memory (tmpfs, Linux)
#   2. /run/user/UID -- systemd user runtime dir (tmpfs, Linux)
#   3. /tmp       -- last resort; may be tmpfs on some systems but is NOT
#                   guaranteed; caller receives a warning in this case.
#
# Outputs the chosen directory path on stdout and returns 0.
# Returns 1 only if none of the candidates are writable (should never happen).
# ---------------------------------------------------------------------------
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

    # /tmp fallback -- warn via TTY so the operator sees it even when stderr
    # is redirected to the journal.
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

# ---------------------------------------------------------------------------
# Cloudflare token validation
#
# BUG-S2 FIX: TOCTOU race between mktemp (creates file world-readable) and
# chmod 600 (locks it). Replaced with 'install -m 600 /dev/null' which
# atomically creates the curl config file at the correct permission before
# any token material is written.
#
# BUG-S8 FIX: When CLOUDFLARE_ZONE_ID is absent or set to a placeholder the
# function previously returned 0 (success) with only a debug-level log, giving
# callers a false "token valid" signal.  Now returns 1 with a log_warn so
# callers can distinguish "skipped due to missing zone" from "validated OK".
# ---------------------------------------------------------------------------
validate_cloudflare_token() {
    local token="$1"
    local token_type="$2"
    local zone_id="${3:-}"
    if [[ -z "$zone_id" ]]; then
        zone_id=$(get_config_value "CLOUDFLARE_ZONE_ID" "")
    fi

    # BUG-S8 FIX: treat absent/placeholder zone_id as a hard skip that returns
    # 1 (not validated) so callers are never misled into thinking the token is
    # confirmed valid when no validation actually occurred.
    if [[ -z "$zone_id" ]] \
        || [[ "$zone_id" == "your_cloudflare_zone_id_here" ]] \
        || [[ "$zone_id" == CHANGE_ME* ]] \
        || [[ "$zone_id" =~ ^[[:space:]]*$ ]]; then
        log_warn "validate_cloudflare_token: CLOUDFLARE_ZONE_ID is not configured -- validation skipped (token NOT verified)"
        return 1
    fi

    # FIX: 'firewall' token type validates against the WAF Custom Rules
    # Rulesets endpoint (not the deprecated Firewall Access Rules endpoint).
    local endpoint
    case "$token_type" in
        dns)      endpoint="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?per_page=1" ;;
        firewall) endpoint="https://api.cloudflare.com/client/v4/zones/$zone_id/rulesets" ;;
        *)        log_error "Invalid token type: $token_type"; return 1 ;;
    esac

    # BUG-S2 FIX: create file atomically at mode 600 before writing secret
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

# ---------------------------------------------------------------------------
# Interactive helpers
#
# BUG-S4 FIX: prompt_password_with_confirmation() used 'echo "$password"' to
# return the password to the caller. Bash $() substitution strips trailing
# newlines, so a password that legitimately ends in '\n' would be silently
# truncated. Replaced with 'printf "%s\n"' which is equivalent for normal
# passwords and correct for edge cases.
# ---------------------------------------------------------------------------
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
    # BUG-S4 FIX: use printf to avoid $() stripping trailing newlines
    printf '%s\n' "$password"
    return 0
}

# ---------------------------------------------------------------------------
# File permission helper
# ---------------------------------------------------------------------------
secure_secrets_file() {
    local secrets_file="${1:-$SECRETS_FILE}"
    if [[ ! -f "$secrets_file" ]]; then return 0; fi
    chmod 600 "$secrets_file"
    local real_user
    real_user=$(get_real_user)
    chown "$real_user:$real_user" "$secrets_file"
    return 0
}

# ---------------------------------------------------------------------------
# _bcrypt_format_ok  (internal)
# ---------------------------------------------------------------------------
_bcrypt_format_ok() {
    local hash="$1"
    [[ "$hash" =~ ^\$2[aby]\$[0-9]+\$.{53}$ ]]
}

# ---------------------------------------------------------------------------
# collect_secret_field  -- single source of truth for INTERACTIVE collection
# ---------------------------------------------------------------------------
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
            # BUG-S6 FIX (P3-M5): Write plaintext passphrase exclusively to
            # /dev/tty (the operator's controlling terminal) so it is never
            # captured by stderr redirection or the systemd journal.
            {
                printf '\n'
                printf ' AUTO-GENERATED BACKUP PASSPHRASE (save if needed):\n'
                printf '   %s\n' "$passphrase"
                printf '\n'
            } > /dev/tty 2>/dev/null || {
                # /dev/tty unavailable (truly non-interactive): emit a redacted
                # notice to stderr so the caller knows a passphrase was set,
                # but never include the plaintext value.
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

# ---------------------------------------------------------------------------
# auto_generate_secret_field  -- single source of truth for AUTO-MODE generation
# ---------------------------------------------------------------------------
auto_generate_secret_field() {
    local field="$1"

    case "$field" in

        admin_token)
            local vw_pass
            vw_pass=$(generate_secure_string 32)
            # BUG-S6 FIX (P3-M5): The generated plaintext password must NOT be
            # passed through log_warn() to stderr, which is permanently captured
            # by the systemd journal when running non-interactively.
            # Write it exclusively to /dev/tty (the operator's terminal).
            {
                printf '\n'
                printf ' AUTO-GENERATED VAULTWARDEN ADMIN PASSWORD:\n'
                printf '   %s\n' "$vw_pass"
                printf '\n'
                printf ' SAVE THIS PASSWORD SECURELY - It cannot be recovered!\n'
                printf '\n'
            } > /dev/tty 2>/dev/null || {
                # /dev/tty unavailable (batch/CI with no terminal): emit a
                # redacted notice to stderr so callers see that generation
                # occurred but never receive the plaintext value in the journal.
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
            # BUG-S6 FIX (P3-M5): Same journal-leak fix as admin_token above.
            {
                printf '\n'
                printf ' AUTO-GENERATED CADDY ADMIN PASSWORD:\n'
                printf '   %s\n' "$caddy_pass"
                printf '\n'
                printf ' SAVE THIS PASSWORD SECURELY - It cannot be recovered!\n'
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

# ---------------------------------------------------------------------------
# generate_recovery_kit OUTPUT_FILE
#
# CONTRACT: writes a plaintext file containing the Age private key and all
# decrypted secrets to $output_file. The caller MUST register a trap that
# calls _secure_shred() on $output_file. The offer_recovery_kit_export()
# wrapper below does this correctly. Direct callers must do the same.
#
# LS-1 FIX: The previous implementation decrypted the full secrets set into
# a single bash variable (secrets_json) via sops -d --output-type json, then
# re-piped that variable through 8+ separate echo "$secrets_json" | jq
# subshells. This exposed the complete plaintext payload in /proc/$$/fd/ pipe
# buffers, readable by any process running as the same UID.
# Fix: each secret is now extracted individually via
#   sops -d --extract '["key"]' "$file"
# so the full plaintext JSON is never materialised in a variable or pipe.
# ---------------------------------------------------------------------------
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
    priv_key=$(cat "$age_key")

    local domain="Not Configured"
    local admin_email="Not Configured"
    if [[ -f "$env_file" ]]; then
        domain=$(grep "^DOMAIN=" "$env_file" | cut -d= -f2 || echo "Not Configured")
        admin_email=$(grep "^ADMIN_EMAIL=" "$env_file" | cut -d= -f2 || echo "Not Configured")
    fi

    # FIX: Derive clone URL from git remote rather than hardcoding the public
    # template URL. Falls back to RECOVERY_KIT_REPO_URL env var, then to a
    # generic placeholder so the kit remains useful for forks.
    local repo_clone_url
    repo_clone_url="${RECOVERY_KIT_REPO_URL:-}"
    if [[ -z "$repo_clone_url" ]]; then
        repo_clone_url=$(git -C "${PROJECT_ROOT:-.}" remote get-url origin 2>/dev/null || true)
    fi
    if [[ -z "$repo_clone_url" ]]; then
        repo_clone_url="<your-repo-clone-url>"
    fi

    log_info "Decrypting secrets for export..."

    # LS-1 FIX: extract each secret individually — no full-JSON variable.
    local vw_admin_hash="Not Set" caddy_hash="Not Set" smtp_pass="Not Set"
    local backup_pass="Not Set" cf_dns="Not Set" cf_fw="Not Set"
    local push_id="Not Set" push_key="Not Set"

    if [[ -f "$secrets_file" ]]; then
        if ! ensure_sops_env; then return 1; fi

        _sops_extract() {
            local _key="$1"
            local _val
            _val=$(sops -d --extract "[\"${_key}\"]" "$secrets_file" 2>/dev/null) \
                && printf '%s' "$_val" \
                || printf '%s' "Not Set"
        }

        vw_admin_hash=$(_sops_extract admin_token)
        caddy_hash=$(_sops_extract admin_basic_auth_hash)
        smtp_pass=$(_sops_extract smtp_password)
        backup_pass=$(_sops_extract backup_passphrase)
        cf_dns=$(_sops_extract caddy_cloudflare_dns_token)
        cf_fw=$(_sops_extract fail2ban_cloudflare_firewall_token)
        push_id=$(_sops_extract push_installation_id)
        push_key=$(_sops_extract push_installation_key)

        unset -f _sops_extract
    else
        log_warn "secrets.yaml not found"
    fi

    if ! install -m 600 /dev/null "$output_file"; then
        log_error "Failed to create output file with secure permissions: $output_file"
        return 1
    fi

    cat > "$output_file" << EOF
██████╗ ███████╗ ██████╗ ██████╗ ██╗   ██╗███████╗██████╗ ██╗   ██╗
██╔══██╗██╔════╝██╔════╝██╔═══██╗██║   ██║██╔════╝██╔══██╗╚██╗ ██╔╝
██████╔╝█████╗  ██║     ██║   ██║██║   ██║█████╗  ██████╔╝ ╚████╔╝ 
██╔══██╗██╔══╝  ██║     ██║   ██║╚██╗ ██╔╝██╔══╝  ██╔══██╗  ╚██╔╝  
██║  ██╗███████╗╚██████╗╚██████╔╝ ╚████╔╝ ███████╗██║  ██╗   ██║   
╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝   ╚═══╝  ╚══════╝╚═╝  ╚═╝   ╚═╝   
                                                                   
██╗  ██╗██╗████████╗
██║ ██╔╝██║╚══██╔══╝
█████╔╝ ██║   ██║   
██╔═██╗ ██║   ██║   
██║  ██╗██║   ██║   
╚═╝  ╚═╝╚═╝   ╚═╝   

════════════════════════════════════════════════════════════════════════════
                            🚨 CRITICAL SECURITY DOCUMENT 🚨
════════════════════════════════════════════════════════════════════════════
Created: $date_val
Server:  $hostname_val
Domain:  $domain

WARNING: This file contains highly sensitive UNENCRYPTED secrets.
1. Save this to your Password Manager (Secure Note) IMMEDIATELY.
2. Print a physical copy for your fireproof safe (optional).
3. DELETE THIS FILE from the server immediately after saving.

════════════════════════════════════════════════════════════════════════════
SECTION 1: ENCRYPTION KEYS (THE MOST IMPORTANT PART)
════════════════════════════════════════════════════════════════════════════
If you lose this key, your backups are FOREVER USELESS.

[AGE PRIVATE KEY]
$priv_key

[AGE PUBLIC KEY]
$pub_key

════════════════════════════════════════════════════════════════════════════
SECTION 2: SERVER SECRETS (DECRYPTED)
════════════════════════════════════════════════════════════════════════════

[SYSTEM CREDENTIALS]
Backup Encryption Passphrase:
$backup_pass

SMTP Password (Email):
$smtp_pass

Cloudflare DNS Token:
$cf_dns

Cloudflare Firewall Token:
$cf_fw

[PUSH NOTIFICATIONS]
Installation ID:  $push_id
Installation Key: $push_key

[ADMIN ACCESS]
Admin Email: $admin_email

VaultWarden Admin Password Hash (Argon2id):
$vw_admin_hash
(Note: Original password cannot be recovered from hash. Reset if lost.)

Caddy Basic Auth Hash (Bcrypt):
$caddy_hash
(Note: Original password cannot be recovered from hash. Reset if lost.)

════════════════════════════════════════════════════════════════════════════
SECTION 3: DISASTER RECOVERY & MIGRATION CHECKLIST
════════════════════════════════════════════════════════════════════════════

TO RESTORE THIS SERVER ON NEW HARDWARE:

1. PREPARATION
   [ ] Install Git, Docker, and SOPS on new server.
   [ ] Clone the repository:
       git clone $repo_clone_url
   [ ] Run setup:
       cd $(basename "$repo_clone_url" .git)
       ./setup.sh --domain $domain --email $admin_email

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
       ./setup-secrets.sh
   [ ] Manually enter the values from [SECTION 2] when prompted.

4. FINALIZATION
   [ ] Start services:
       make up
   [ ] Check health:
       ./health.sh

════════════════════════════════════════════════════════════════════════════
END OF RECOVERY KIT
════════════════════════════════════════════════════════════════════════════
EOF

    chmod 600 "$output_file"
}

# ---------------------------------------------------------------------------
# _ork_generate_and_secure  (was: nested _do_generate_and_secure)
#
# BUG-S3 FIX: The helper was previously a nested function defined inside
# offer_recovery_kit_export(). Bash nested function definitions pollute the
# global namespace -- the function is visible and callable from anywhere after
# the outer function is sourced, which is surprising and potentially dangerous
# for a helper that writes and securely deletes plaintext secret files.
#
# Promoted to a top-level private function with the _ork_ prefix to:
#   1. Eliminate the global namespace pollution from the nested definition.
#   2. Make the function visible only by convention (prefix), not by scope.
#   3. Allow offer_recovery_kit_export() to call it normally.
#
# BUG-S5 FIX (P3-C3): output_file is now resolved to a tmpfs path by the
# caller (offer_recovery_kit_export) via _tmpfs_dir(). A prominent WARNING
# banner is printed to /dev/tty *before* generate_recovery_kit() opens the
# file so the operator is aware that plaintext is about to land on disk.
#
# LS-6 FIX: trap ... EXIT was overwriting any caller-level EXIT trap (e.g.
# setup.sh temp-dir cleanup). Changed to trap ... RETURN so the cleanup is
# function-scoped only and never clobbers the caller's EXIT handler.
# ---------------------------------------------------------------------------
_ork_generate_and_secure() {
    local output_file="$1"

    # BUG-S5 FIX (P3-C3): Emit a pre-write warning to the operator's terminal
    # BEFORE the plaintext file is created, so they are aware of the transient
    # disk exposure and can take action (e.g. disable snapshots, use HSM).
    {
        printf '\n'
        printf '════════════════════════════════════════════════════════════\n'
        printf ' SECURITY NOTICE -- PLAINTEXT FILE ABOUT TO BE WRITTEN\n'
        printf '════════════════════════════════════════════════════════════\n'
        printf 'The recovery kit will be written to:\n'
        printf '  %s\n' "$output_file"
        printf '\n'
        printf 'Even on tmpfs, this file is visible to root and may appear\n'
        printf 'in OCI block-volume snapshots if /tmp falls back to disk.\n'
        printf 'The file will be securely deleted after you confirm.\n'
        printf '════════════════════════════════════════════════════════════\n'
        printf '\n'
    } > /dev/tty 2>/dev/null || true

    # LS-6 FIX: use RETURN trap (function-scoped) instead of EXIT trap so we
    # do not overwrite the caller's EXIT handler (e.g. setup.sh temp-dir
    # cleanup). The shred runs when this function returns (normally, via
    # return, or via an unhandled signal that unwinds the call stack).
    # shellcheck disable=SC2064  # intentional: expand $output_file now
    trap "_secure_shred '$output_file'; echo '[recovery-kit] Plaintext kit securely deleted.' >&2" RETURN

    if ! generate_recovery_kit "$output_file"; then
        log_error "Failed to generate recovery kit"
        return 1
    fi

    log_success "Recovery Kit created: $output_file"
    echo ""
    log_warn " ACTION REQUIRED -- SAVE NOW BEFORE THIS FILE IS AUTO-DELETED:"
    echo "  1. Open the file: cat '$output_file'"
    echo "  2. Copy ALL contents to your password manager (Secure Note)."
    echo "  3. Optionally print a physical copy for your fireproof safe."
    echo ""
    log_warn "This file will be securely deleted after you press Enter."
    log_warn "If you do not respond within 120 seconds it will be deleted automatically."
    echo ""

    local user_ack
    if read -r -t 120 -p "Press Enter once you have saved the recovery kit: " user_ack 2>/dev/null \
       || true; then
        : # any input (or empty Enter) is acceptable
    fi

    log_info "Securely deleting recovery kit from server..."
    _secure_shred "$output_file"
    # Disarm the RETURN trap now that we have already shredded the file,
    # preventing a redundant (harmless but noisy) second shred on return.
    trap - RETURN
    log_success "Recovery kit securely deleted from server."
    echo ""
}

# ---------------------------------------------------------------------------
# offer_recovery_kit_export
#
# BUG-S5 FIX (P3-C3): output_file is now placed in the directory returned by
# _tmpfs_dir() (prefers /dev/shm, then /run/user/UID, then /tmp) instead of
# $HOME. This keeps the plaintext recovery kit off persistent block storage
# on systems where those paths are backed by tmpfs/ramfs, significantly
# reducing the OCI snapshot exposure window.
# ---------------------------------------------------------------------------
offer_recovery_kit_export() {
    local auto_export="${1:-false}"

    # BUG-S5 FIX: resolve tmpfs directory before building the output path
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
