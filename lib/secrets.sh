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
#                _check_recovery_kit_email_deps, _encrypt_recovery_kit_attachment,
#                _offer_email_recovery_kit
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
# shellcheck disable=SC1091 # sourced relative to this library at runtime
[[ -n "${VW_LOG_LIB_LOADED:-}" ]] || source "${_SECRETS_LIB_DIR}/log.sh"
# shellcheck disable=SC1091 # sourced relative to this library at runtime
[[ -n "${VAULTWARDEN_DEFAULTS_LOADED:-}" ]] || source "${_SECRETS_LIB_DIR}/defaults.sh"

# shellcheck disable=SC1091 # sourced relative to this library at runtime
source "${_SECRETS_LIB_DIR}/crypto.sh"
# shellcheck disable=SC1091 # sourced relative to this library at runtime
source "${_SECRETS_LIB_DIR}/schema.sh"
# shellcheck disable=SC1091 # sourced relative to this library at runtime
source "${_SECRETS_LIB_DIR}/email.sh"
unset _SECRETS_LIB_DIR

# Do NOT set -euo pipefail here — callers own their shell options.
# Entry-point scripts apply these options via init_common_lib(); this library
# is always sourced after that call.

# SECRETS_FILE is exported by lib/config.sh (canonical source of truth).
# lib/secrets.sh intentionally does NOT define a fallback here so that the
# two libraries always agree on the path. If you are sourcing this file
# standalone (without config.sh loaded first), export SECRETS_FILE before
# sourcing.
SECRETS_BACKUP_DIR="${SECRETS_BACKUP_DIR:-}"

ensure_sops_env() {
    local age_key
    if ! age_key=$(resolve_age_key_path); then
        return 1
    fi

    export SOPS_AGE_KEY_FILE="$age_key"

    local candidate_config=""
    if [[ -n "${SOPS_CONFIG:-}" && -f "${SOPS_CONFIG}" ]]; then
        candidate_config="$SOPS_CONFIG"
    elif [[ -f "${PROJECT_ROOT:-$(pwd)}/.sops.yaml" ]]; then
        candidate_config="${PROJECT_ROOT:-$(pwd)}/.sops.yaml"
    fi

    if [[ -n "$candidate_config" ]]; then
        if [[ ! -r "$candidate_config" ]]; then
            log_error "SOPS config exists but is not readable by the current user: $candidate_config"
            log_error ".sops.yaml contains public SOPS policy and Age public recipients, not private key material."
            log_error "Recommended repair: sudo utilities/repair-permissions.sh"
            log_error "Direct fallback: sudo chmod 0644 .sops.yaml"
            return 1
        fi
        export SOPS_CONFIG="$candidate_config"
        log_debug "SOPS env set: key=$SOPS_AGE_KEY_FILE  config=$SOPS_CONFIG"
    else
        unset SOPS_CONFIG
        log_debug "SOPS env set: key=$SOPS_AGE_KEY_FILE  config=<unset; no .sops.yaml found>"
    fi

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

# ---------------------------------------------------------------------------
# get_secret KEY [FILE]
#
# Public API — decrypt and return a single secret value by key name.
# This is the canonical call pattern for all consuming scripts.
#
# Usage:
#   local val
#   val=$(get_secret smtp_password) || return 1
#   # Use $val — never pass directly as a positional arg to an external
#   # command; the value would appear in /proc/$$/cmdline.
#
# Arguments:
#   KEY   — YAML key name (e.g. smtp_password, admin_token)
#   FILE  — optional path to secrets file (defaults to SECRETS_FILE)
#
# Returns:
#   0 and prints the plaintext value on success
#   1 on any decryption or validation error
# ---------------------------------------------------------------------------
get_secret() {
    decrypt_secret "$@"
}

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

_secret_value_is_inactive() {
    local value="${1-}"
    local placeholder="${2-}"
    [[ -z "$value" ]] && return 0
    [[ "$value" == "null" ]] && return 0
    [[ "$value" == CHANGE_ME* ]] && return 0
    [[ "$value" == NOT_USED* ]] && return 0
    [[ "$value" == PLACEHOLDER* ]] && return 0
    [[ -n "$placeholder" && "$value" == "$placeholder" ]] && return 0
    return 1
}

_runtime_secret_value_is_inactive() {
    local key="$1"
    local value="${2-}"
    local placeholder="${3-}"

    case "$key" in
        push_installation_id|push_installation_key)
            [[ "${PUSH_ENABLED:-false}" != "true" ]] && return 0
            ;;
    esac

    _secret_value_is_inactive "$value" "$placeholder"
}

_managed_secrets_manifest_path() {
    local docker_dir="${1%/}"
    printf '%s/managed-secrets' "$(dirname "$docker_dir")"
}

_schema_required_runtime_keys() {
    local _group _group_keys _email_mode
    local -a _runtime_groups=()

    schema_required_keys || return 1

    [[ "${CLOUDFLARE_PROXY_ENABLED:-false}" == "true" ]] && _runtime_groups+=("cloudflare_proxy")
    [[ "${PUSH_ENABLED:-false}" == "true" ]] && _runtime_groups+=("push")
    _runtime_groups+=("authenticated_integrity")

    _email_mode="${EMAIL_MODE:-auto}"
    case "$_email_mode" in
        auto|smtp|direct) _runtime_groups+=("email_smtp") ;;
        api)                   _runtime_groups+=("email_smtp" "email_api") ;;
        *)
            log_error "validate_required_secrets: unsupported EMAIL_MODE '${_email_mode}' while determining runtime-required secrets"
            return 1
            ;;
    esac

    for _group in "${_runtime_groups[@]}"; do
        if ! _group_keys=$(schema_keys_for_conditional_group "$_group" 2>/dev/null); then
            log_error "validate_required_secrets: failed to read conditional group '${_group}' from secrets-schema.yaml"
            return 1
        fi
        if [[ -z "$_group_keys" ]]; then
            log_error "validate_required_secrets: active conditional group '${_group}' has no keys in secrets-schema.yaml"
            return 1
        fi
        printf '%s\n' "$_group_keys"
    done
}

validate_required_secrets() {
    local secrets_file="${1:-$SECRETS_FILE}"

    local _required_keys
    if ! _required_keys=$(_schema_required_runtime_keys 2>/dev/null); then
        log_error "validate_required_secrets: failed to read required keys from secrets-schema.yaml"
        return 1
    fi

    if ! ensure_sops_env; then return 1; fi

    local missing_secrets=()
    local inactive_secrets=()
    declare -A _seen_required=()

    while IFS= read -r secret; do
        [[ -z "$secret" ]] && continue
        [[ -n "${_seen_required[$secret]+set}" ]] && continue
        _seen_required["$secret"]=1
        local sops_stderr rc=0
        local value placeholder
        sops_stderr=$(mktemp)
        # Prevent decrypted assignment values from appearing in caller xtrace output.
        { set +x; } 2>/dev/null
        value=$(sops -d --extract "[\"$secret\"]" "$secrets_file" 2>"$sops_stderr") || rc=$?
        if [[ $rc -ne 0 ]]; then
            log_error "validate_required_secrets: required secret '$secret' is missing or unreadable"
            missing_secrets+=("$secret")
            if [[ -s "$sops_stderr" ]]; then
                log_debug "validate_required_secrets: sops error for '$secret': $(cat "$sops_stderr")"
            fi
            rm -f "$sops_stderr"
            continue
        fi
        rm -f "$sops_stderr"
        placeholder=$(schema_placeholder_for_key "$secret" 2>/dev/null || printf '')
        if _secret_value_is_inactive "$value" "$placeholder"; then
            log_error "validate_required_secrets: required secret '$secret' is inactive or placeholder"
            inactive_secrets+=("$secret")
        fi
        unset value
    done <<< "$_required_keys"

    unset _seen_required
    cleanup_secrets_environment

    if [[ ${#missing_secrets[@]} -gt 0 ]]; then
        log_warn "Missing required secrets (${#missing_secrets[@]}): ${missing_secrets[*]}"
    fi
    if [[ ${#inactive_secrets[@]} -gt 0 ]]; then
        log_warn "Inactive required secrets (${#inactive_secrets[@]}): ${inactive_secrets[*]}"
    fi
    if [[ ${#missing_secrets[@]} -gt 0 || ${#inactive_secrets[@]} -gt 0 ]]; then
        return 1
    fi
    return 0
}

check_placeholder_values() {
    local secrets_file="${1:-$SECRETS_FILE}"

    local _required_keys
    if ! _required_keys=$(_schema_required_runtime_keys 2>/dev/null); then
        log_error "check_placeholder_values: failed to read required keys from secrets-schema.yaml"
        return 1
    fi

    if ! ensure_sops_env; then return 1; fi
    local placeholder_secrets=()
    local unreadable_secrets=()
    declare -A _seen_required=()

    while IFS= read -r secret; do
        [[ -z "$secret" ]] && continue
        [[ -n "${_seen_required[$secret]+set}" ]] && continue
        _seen_required["$secret"]=1
        local value rc=0 placeholder
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
        placeholder=$(schema_placeholder_for_key "$secret" 2>/dev/null || printf '')
        if _secret_value_is_inactive "$value" "$placeholder"; then
            log_warn "check_placeholder_values: secret '$secret' is set to a placeholder, sentinel, or empty value"
            placeholder_secrets+=("$secret")
        fi
        unset value
    done <<< "$_required_keys"

    unset _seen_required
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
    # The full decrypted YAML is assigned below; suppress xtrace before it can
    # expose values from an otherwise names-only operation.
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
    local backup_dir="${2:-${SECRETS_BACKUP_DIR:-${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/secrets/backups}}"
    if [[ ! -f "$secrets_file" ]]; then
        log_debug "No secrets file to backup"
        return 0
    fi
    if ! install -d -m 0700 -o root -g root "$backup_dir"; then
        log_error "Failed to prepare secrets backup directory: $backup_dir"
        return 1
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
    local backup_dir="${1:-${SECRETS_BACKUP_DIR:-${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/secrets/backups}}"
    local keep_count="${2:-5}"
    # NUL-delimited pipeline — safe for paths containing spaces.
    find "$backup_dir" -name "secrets.yaml.backup-*" -type f -print0 2>/dev/null \
        | sort -rz \
        | tail -z -n +$(( keep_count + 1 )) \
        | xargs -0 rm -f
    log_debug "Cleaned up old secrets backups (keeping last $keep_count)"
    return 0
}

_remove_sensitive_file() {
  local target="${1:-}"
  [[ -n "$target" ]] || return 1

  # Best-effort overwrite and unlink. Physical erasure is not guaranteed on
  # SSDs, snapshots, journaling filesystems, or copy-on-write storage.
  [[ ! -L "$target" ]] || return 1
  if [[ ! -e "$target" ]]; then
    return 0
  fi
  [[ -f "$target" ]] || return 1

  if command -v shred >/dev/null 2>&1; then
    shred -fuz -- "$target" 2>/dev/null || true
  fi

  # Recheck before the unlink fallback so a replacement symlink is rejected.
  [[ ! -L "$target" ]] || return 1
  if [[ -e "$target" ]]; then
    [[ -f "$target" ]] || return 1
    rm -f -- "$target" 2>/dev/null || return 1
  fi
  [[ ! -e "$target" && ! -L "$target" ]]
}

# Remove eligible plaintext recovery kits that survived the primary transient
# cleanup. This fallback runs only during the existing routine-maintenance flow.
cleanup_expired_recovery_kits() {
  local recovery_dir="/root/vaultwarden-recovery"
  local min_age_seconds=1800
  local dry_run="${1:-false}"
  local candidate parent filename directory_metadata
  local initial_metadata current_metadata
  local device inode current_device current_inode uid gid mode links mtime
  local now age cleanup_result=0 resolved_dir candidate_list

  case "$dry_run" in
    true|false) ;;
    *)
      log_error "recovery cleanup: invalid dry-run value: $dry_run"
      return 1
      ;;
  esac

  # Internal deterministic-test hooks only. They are intentionally unavailable
  # as operator configuration and cannot change production defaults.
  if [[ -n "${RECOVERY_KIT_DIR:-}" ]]; then
    if [[ "${VW_TEST_MODE:-false}" != "true" ]]; then
      log_error "recovery cleanup: RECOVERY_KIT_DIR override is test-only"
      return 1
    fi
    recovery_dir="$RECOVERY_KIT_DIR"
  fi
  if [[ -n "${VW_RECOVERY_CLEANUP_MIN_AGE_SECONDS:-}" ]]; then
    if [[ "${VW_TEST_MODE:-false}" != "true" ]] ||
       [[ ! "$VW_RECOVERY_CLEANUP_MIN_AGE_SECONDS" =~ ^[0-9]+$ ]]; then
      log_error "recovery cleanup: invalid internal age override"
      return 1
    fi
    min_age_seconds="$VW_RECOVERY_CLEANUP_MIN_AGE_SECONDS"
  fi

  [[ "$recovery_dir" == /* ]] || {
    log_error "recovery cleanup: directory must be absolute: $recovery_dir"
    return 1
  }
  if [[ -L "$recovery_dir" ]]; then
    log_error "recovery cleanup: refusing symlink recovery directory: $recovery_dir"
    return 1
  fi
  [[ -e "$recovery_dir" ]] || return 0
  [[ -d "$recovery_dir" ]] || {
    log_error "recovery cleanup: expected directory is not a directory: $recovery_dir"
    return 1
  }
  resolved_dir="$(realpath -e -- "$recovery_dir" 2>/dev/null)" || {
    log_error "recovery cleanup: cannot resolve recovery directory: $recovery_dir"
    return 1
  }
  if [[ "$resolved_dir" != "$recovery_dir" ]]; then
    log_error "recovery cleanup: directory is not the exact canonical path: $recovery_dir"
    return 1
  fi
  directory_metadata="$(stat -c '%u:%g:%a' -- "$recovery_dir" 2>/dev/null)" || {
    log_error "recovery cleanup: cannot inspect recovery directory: $recovery_dir"
    return 1
  }
  if [[ "$directory_metadata" != "0:0:700" ]]; then
    log_error "recovery cleanup: expected root:root mode 0700 directory: $recovery_dir"
    return 1
  fi

  now="$(date +%s)" || return 1
  candidate_list="$(mktemp "${TMPDIR:-/tmp}/vw-recovery-candidates.XXXXXXXXXX")" || {
    log_error "recovery cleanup: failed to allocate a protected candidate list"
    return 1
  }
  if ! find -P "$recovery_dir" -mindepth 1 -maxdepth 1 \
      -name 'vaultwarden-recovery-kit-*.txt' -print0 >"$candidate_list" 2>/dev/null; then
    log_error "recovery cleanup: failed to enumerate recovery-kit candidates"
    rm -f -- "$candidate_list" 2>/dev/null || true
    return 1
  fi
  while IFS= read -r -d '' candidate; do
    parent="$(dirname -- "$candidate")"
    filename="$(basename -- "$candidate")"

    if [[ "$parent" != "$recovery_dir" ]]; then
      log_warn "recovery cleanup: refusing candidate outside expected directory: $candidate"
      cleanup_result=1
      continue
    fi
    if [[ ! "$filename" =~ ^vaultwarden-recovery-kit-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}\.txt$ ]]; then
      log_warn "recovery cleanup: refusing matching candidate with an unexpected filename: $candidate"
      cleanup_result=1
      continue
    fi
    if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
      continue
    fi
    if [[ -L "$candidate" ]]; then
      log_warn "recovery cleanup: refusing symlink candidate: $candidate"
      cleanup_result=1
      continue
    fi
    if [[ ! -f "$candidate" ]]; then
      log_warn "recovery cleanup: refusing non-regular candidate: $candidate"
      cleanup_result=1
      continue
    fi

    initial_metadata="$(stat -c '%d:%i:%u:%g:%a:%h:%Y' -- "$candidate" 2>/dev/null)" || {
      if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
        continue
      fi
      log_warn "recovery cleanup: cannot inspect candidate: $candidate"
      cleanup_result=1
      continue
    }
    IFS=: read -r device inode uid gid mode links mtime <<<"$initial_metadata"
    if [[ "$uid" != 0 || "$gid" != 0 ]]; then
      log_warn "recovery cleanup: refusing candidate not owned by root:root: $candidate"
      cleanup_result=1
      continue
    fi
    if [[ "$mode" != 600 ]]; then
      log_warn "recovery cleanup: refusing candidate with mode $mode instead of 0600: $candidate"
      cleanup_result=1
      continue
    fi
    if [[ "$links" != 1 ]]; then
      log_warn "recovery cleanup: refusing candidate with link count $links: $candidate"
      cleanup_result=1
      continue
    fi
    if (( mtime > now )); then
      log_warn "recovery cleanup: retaining candidate with a future modification time: $candidate"
      cleanup_result=1
      continue
    fi
    age=$((now - mtime))
    if (( age < min_age_seconds )); then
      log_debug "recovery cleanup: retaining young recovery kit: $candidate"
      continue
    fi

    current_metadata="$(stat -c '%d:%i:%u:%g:%a:%h:%Y' -- "$candidate" 2>/dev/null)" || {
      if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
        continue
      fi
      log_warn "recovery cleanup: candidate became unreadable before removal: $candidate"
      cleanup_result=1
      continue
    }
    IFS=: read -r current_device current_inode _ <<<"$current_metadata"
    if [[ "$current_device" != "$device" ||
          "$current_inode" != "$inode" ||
          "$current_metadata" != "$initial_metadata" ]]; then
      log_warn "recovery cleanup: candidate identity or security metadata changed; leaving it untouched: $candidate"
      cleanup_result=1
      continue
    fi

    if [[ "$dry_run" == "true" ]]; then
      log_info "[DRY RUN] Would remove expired plaintext recovery kit: $candidate"
      continue
    fi
    if _remove_sensitive_file "$candidate"; then
      log_info "Removed expired plaintext recovery kit: $candidate"
    else
      log_error "recovery cleanup: failed to remove safe expired candidate: $candidate"
      cleanup_result=1
    fi
  done < "$candidate_list"
  if ! rm -f -- "$candidate_list" 2>/dev/null; then
    log_error "recovery cleanup: failed to remove the protected candidate list"
    cleanup_result=1
  fi
  return "$cleanup_result"
}

_prepare_recovery_dir() {
  # Recovery artifacts belong outside the checkout and outside the normal
  # full-backup input tree.
  local target_dir="${RECOVERY_KIT_DIR:-/root/vaultwarden-recovery}"
  if [[ -L "$target_dir" || ( -e "$target_dir" && ! -d "$target_dir" ) ]]; then
    log_error "Recovery directory is unsafe: $target_dir"
    return 1
  fi
  local old_umask
  old_umask="$(umask)"
  umask 077
  if ! mkdir -p -- "$target_dir"; then
    umask "$old_umask"
    log_error "Cannot create protected recovery directory: $target_dir"
    return 1
  fi
  umask "$old_umask"
  if (( EUID == 0 )); then
    chown root:root -- "$target_dir" || {
      log_error "Cannot set root ownership on recovery directory: $target_dir"
      return 1
    }
  elif [[ -z "${RECOVERY_KIT_DIR:-}" ]]; then
    log_error "The default recovery directory requires root."
    return 1
  fi
  chmod 0700 "$target_dir" || {
    log_error "Cannot set mode 0700 on recovery directory: $target_dir"
    return 1
  }
  printf '%s\n' "$target_dir"
}

# ---------------------------------------------------------------------------
# _schedule_recovery_cleanup FILE [DELAY]
#
# Accepts a transient cleanup job for the current regular, non-symlink FILE.
# systemd-run is primary; at is an optional fallback. The static detached
# command receives the absolute path as a positional argument and rechecks the
# file type before best-effort overwrite/unlink. No recovery content or
# passphrase is placed in scheduler arguments, unit metadata, or environment.
# ---------------------------------------------------------------------------
_schedule_recovery_cleanup() {
  local target="${1:-}" delay="${2:-30m}"
  local absolute_file delay_count delay_unit at_unit systemd_run="" at_cmd=""
  local unit_name cleanup_body at_command escaped_body escaped_file

  unset _RECOVERY_CLEANUP_SCHEDULER _RECOVERY_CLEANUP_DELAY
  [[ -n "$target" && ! -L "$target" && -f "$target" ]] || return 1
  absolute_file="$(realpath -- "$target" 2>/dev/null)" || return 1
  [[ "$absolute_file" == /* && ! -L "$absolute_file" && -f "$absolute_file" ]] || return 1

  if [[ "$delay" =~ ^([1-9][0-9]*)(s|m|h|d)$ ]]; then
    delay_count="${BASH_REMATCH[1]}"
    delay_unit="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  case "$delay_unit" in
    s) at_unit="seconds" ;;
    m) at_unit="minutes" ;;
    h) at_unit="hours" ;;
    d) at_unit="days" ;;
    *) return 1 ;;
  esac

  unit_name="vaultwarden-recovery-cleanup-$(date -u +%s)-$$-${RANDOM}"
  [[ "$unit_name" =~ ^[A-Za-z0-9_.@-]+$ ]] || return 1
  cleanup_body='
target=$1
if /bin/test -L "$target"; then exit 1; fi
if ! /bin/test -e "$target"; then exit 0; fi
/bin/test -f "$target" || exit 1
if /bin/test -x /usr/bin/shred; then
  /usr/bin/shred -fuz -- "$target" 2>/dev/null || true
fi
if /bin/test -L "$target"; then exit 1; fi
if /bin/test -e "$target"; then
  /bin/test -f "$target" || exit 1
  /bin/rm -f -- "$target" || exit 1
fi
! /bin/test -e "$target" && ! /bin/test -L "$target"
'

  local systemd_cleanup_body="$cleanup_body"
  systemd_cleanup_body="${systemd_cleanup_body#$'\n'}"
  systemd_cleanup_body="${systemd_cleanup_body%$'\n'}"
  systemd_cleanup_body="${systemd_cleanup_body//$'\n'/; }"
  systemd_cleanup_body="${systemd_cleanup_body//then; /then }"
  systemd_run="$(command -v systemd-run 2>/dev/null || true)"
  if [[ -n "$systemd_run" ]] && "$systemd_run" \
      --quiet \
      --collect \
      --unit="$unit_name" \
      --on-active="$delay" \
      /bin/sh -c "$systemd_cleanup_body" sh "$absolute_file"; then
    _RECOVERY_CLEANUP_SCHEDULER="systemd"
    _RECOVERY_CLEANUP_DELAY="$delay"
    return 0
  fi

  at_cmd="$(command -v at 2>/dev/null || true)"
  [[ -n "$at_cmd" ]] || return 1
  # at reads a POSIX-sh job from stdin. Single-quote each positional word
  # without relying on Bash-only printf %q output such as $'...'.
  escaped_body="${cleanup_body//\'/\'\\\'\'}"
  escaped_file="${absolute_file//\'/\'\\\'\'}"
  printf -v at_command "/bin/sh -c '%s' sh '%s'\n" \
    "$escaped_body" "$escaped_file"
  if printf '%s' "$at_command" |
      "$at_cmd" "now + ${delay_count} ${at_unit}" >/dev/null 2>&1; then
    _RECOVERY_CLEANUP_SCHEDULER="at"
    _RECOVERY_CLEANUP_DELAY="$delay"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _check_recovery_kit_email_deps
#
# Prints the AES-ZIP tool name when the secure prompt, SMTP attachment helper,
# and an archiver are available. Require upstream 7zz from Ubuntu's 7zip package; no legacy executable fallback is supported.
# ---------------------------------------------------------------------------
_check_recovery_kit_email_deps() {
  declare -F prompt_password_with_confirmation >/dev/null 2>&1 || {
    log_error "recovery-kit email: secure passphrase prompt helper is unavailable."
    return 1
  }
  declare -F send_smtp_attachment >/dev/null 2>&1 || {
    log_error "recovery-kit email: SMTP attachment helper is unavailable."
    return 1
  }
  if command -v 7zz >/dev/null 2>&1; then
    printf '%s\n' 7zz
    return 0
  fi
  log_warn "recovery-kit email: Ubuntu 7zz is required."
  log_warn "Install on Ubuntu 24.04 with: sudo apt-get install -y 7zip"
  return 1
}

# ---------------------------------------------------------------------------
# _run_7zip_with_passphrase PASSPHRASE TOOL ARG...
#
# Sends the passphrase only through the archiver's standard input. For archive
# creation/update, a standalone -p switch enables encryption and the confirmed
# passphrase is supplied twice. For read operations, standalone -p is removed:
# an encrypted archive causes 7-Zip to request the password from stdin, while
# avoiding non-TTY -p behavior while keeping passphrases out of process argv.
# Inline -pPASSWORD arguments are rejected so secrets never enter argv.
# ---------------------------------------------------------------------------
_run_7zip_with_passphrase() {
  local passphrase="$1"
  shift
  local tool="$1"
  shift

  [[ -n "$passphrase" ]] || return 64
  [[ "$passphrase" != *$'\n'* && "$passphrase" != *$'\r'* ]] || return 64
  command -v "$tool" >/dev/null 2>&1 || return 127

  local command_name="${1:-}"
  [[ -n "$command_name" ]] || return 64

  local -a argv=("$@") safe_argv=()
  local arg prompt_switch=false rc=0
  for arg in "${argv[@]}"; do
    case "$arg" in
      -p)
        if [[ "$command_name" == "a" || "$command_name" == "u" ]]; then
          prompt_switch=true
          safe_argv+=("$arg")
        fi
        ;;
      -p?*)
        # Never accept an inline password, even if a caller constructs one.
        return 64
        ;;
      *) safe_argv+=("$arg") ;;
    esac
  done

  if [[ "$command_name" == "a" || "$command_name" == "u" ]]; then
    if [[ "$prompt_switch" != "true" ]]; then
      safe_argv=("${safe_argv[0]}" -p "${safe_argv[@]:1}")
    fi
    if printf '%s\n%s\n' "$passphrase" "$passphrase" | "$tool" "${safe_argv[@]}"; then
      return 0
    else
      rc="${PIPESTATUS[1]}"
      return "$rc"
    fi
  fi

  # Test/extract/list operations prompt automatically when encrypted content is
  # encountered. Supplying one line on stdin is the supported 7zz transport.
  if printf '%s\n' "$passphrase" | "$tool" "${safe_argv[@]}"; then
    return 0
  else
    rc="${PIPESTATUS[1]}"
    return "$rc"
  fi
}

# ---------------------------------------------------------------------------
# _encrypt_recovery_kit_attachment PLAINTEXT_FILE OUTPUT_FILE TOOL
#
# Creates a single-member AES-256 ZIP. The independent attachment passphrase is
# collected with prompt_password_with_confirmation (minimum 16 characters) and
# sent to 7-Zip only on stdin. The helper validates the container type, AES
# method, member list, correct passphrase, wrong-passphrase rejection, and
# empty-passphrase rejection before returning success.
# ---------------------------------------------------------------------------
_encrypt_recovery_kit_attachment() {
  local plaintext_file="$1" output_file="$2" tool="$3"
  [[ -f "$plaintext_file" && -s "$plaintext_file" ]] || {
    log_error "Recovery-kit plaintext file is missing or empty."
    return 1
  }
  case "${tool##*/}" in 7zz) ;; *)
    log_error "Unsupported recovery ZIP tool: $tool"
    return 1
    ;;
  esac

  local passphrase xtrace_was_set=0 plain_dir plain_base listing member_count member_path
  case $- in *x*) xtrace_was_set=1 ;; esac
  { set +x; } 2>/dev/null
  passphrase="$(prompt_password_with_confirmation \
    "Passphrase to encrypt emailed AES-256 ZIP (independent from stored project credentials)" 16)" || {
      unset passphrase
      [[ $xtrace_was_set -eq 1 ]] && set -x
      log_error "Attachment passphrase entry failed or was aborted."
      return 1
    }

  plain_dir="$(dirname -- "$plaintext_file")"
  plain_base="$(basename -- "$plaintext_file")"
  rm -f -- "$output_file"
  if ! (
      cd -- "$plain_dir" &&
      _run_7zip_with_passphrase "$passphrase" "$tool" \
        a -tzip -mem=AES256 -mx=5 -bd -y -p -- "$output_file" "$plain_base" \
        >/dev/null 2>&1
    ); then
    unset passphrase
    [[ $xtrace_was_set -eq 1 ]] && set -x
    _remove_sensitive_file "$output_file" 2>/dev/null || true
    log_error "AES-256 ZIP creation failed."
    return 1
  fi

  [[ -s "$output_file" ]] || {
    unset passphrase
    [[ $xtrace_was_set -eq 1 ]] && set -x
    _remove_sensitive_file "$output_file" 2>/dev/null || true
    log_error "ZIP creation reported success but produced no archive."
    return 1
  }
  chmod 0600 -- "$output_file" || {
    unset passphrase
    [[ $xtrace_was_set -eq 1 ]] && set -x
    _remove_sensitive_file "$output_file" 2>/dev/null || true
    log_error "Could not restrict ZIP attachment permissions."
    return 1
  }
  if (( EUID == 0 )); then
    if ! chown root:root -- "$output_file"; then
      unset passphrase
      [[ $xtrace_was_set -eq 1 ]] && set -x
      _remove_sensitive_file "$output_file" 2>/dev/null || true
      log_error "Could not set root ownership on ZIP attachment."
      return 1
    fi
  fi

  listing="$("$tool" l -slt -- "$output_file" 2>/dev/null)" || {
    unset passphrase
    [[ $xtrace_was_set -eq 1 ]] && set -x
    _remove_sensitive_file "$output_file" 2>/dev/null || true
    log_error "Could not inspect ZIP attachment."
    return 1
  }
  grep -Eq '^Type = zip$' <<<"$listing" || {
    unset passphrase; [[ $xtrace_was_set -eq 1 ]] && set -x
    _remove_sensitive_file "$output_file" 2>/dev/null || true
    log_error "Attachment validation failed: container is not ZIP."
    return 1
  }
  grep -Eq '^Method = .*AES-256' <<<"$listing" || {
    unset passphrase; [[ $xtrace_was_set -eq 1 ]] && set -x
    _remove_sensitive_file "$output_file" 2>/dev/null || true
    log_error "Attachment validation failed: AES-256 encryption was not proven."
    return 1
  }
  if grep -Eqi 'ZipCrypto|ZipCrypto_AES' <<<"$listing"; then
    unset passphrase; [[ $xtrace_was_set -eq 1 ]] && set -x
    _remove_sensitive_file "$output_file" 2>/dev/null || true
    log_error "Attachment validation failed: legacy ZipCrypto was detected."
    return 1
  fi
  member_count="$(awk -F' = ' '/^----------$/{body=1; next} body && $1=="Path"{count++} END{print count+0}' <<<"$listing")"
  member_path="$(awk -F' = ' '/^----------$/{body=1; next} body && $1=="Path"{print $2}' <<<"$listing")"
  if [[ "$member_count" != "1" || "$member_path" != "$plain_base" ]]; then
    unset passphrase; [[ $xtrace_was_set -eq 1 ]] && set -x
    _remove_sensitive_file "$output_file" 2>/dev/null || true
    log_error "Attachment validation failed: expected exactly '$plain_base'."
    return 1
  fi
  if ! _run_7zip_with_passphrase "$passphrase" "$tool" \
      t -bd -y -p -- "$output_file" >/dev/null 2>&1; then
    unset passphrase; [[ $xtrace_was_set -eq 1 ]] && set -x
    _remove_sensitive_file "$output_file" 2>/dev/null || true
    log_error "Attachment validation failed with the selected passphrase."
    return 1
  fi
  if _run_7zip_with_passphrase 'VWOCI-DELIBERATELY-WRONG-PASSPHRASE' "$tool" \
      t -bd -y -p -- "$output_file" >/dev/null 2>&1; then
    unset passphrase; [[ $xtrace_was_set -eq 1 ]] && set -x
    _remove_sensitive_file "$output_file" 2>/dev/null || true
    log_error "Attachment validation failed: an incorrect passphrase was accepted."
    return 1
  fi
  if "$tool" t -bd -y -- "$output_file" </dev/null >/dev/null 2>&1; then
    unset passphrase; [[ $xtrace_was_set -eq 1 ]] && set -x
    _remove_sensitive_file "$output_file" 2>/dev/null || true
    log_error "Attachment validation failed: extraction without a passphrase succeeded."
    return 1
  fi

  unset passphrase listing member_path
  [[ $xtrace_was_set -eq 1 ]] && set -x
  return 0
}

# ---------------------------------------------------------------------------
# _offer_email_recovery_kit PLAINTEXT_FILE
#
# Sends the encrypted recovery kit only through the SMTP attachment path.
# The prompt is shown before passphrase collection, and non-secret direct-SMTP
# settings are validated before encryption so operators fail early.
# Returns 0 when sent, 2 when declined/timed out, and another nonzero status
# when email was requested but preparation or delivery failed.
# ---------------------------------------------------------------------------
_offer_email_recovery_kit() {
  # VWOCI-PRR-PATCH-02: only an independently encrypted AES-256 ZIP may be sent.
  local plaintext_file="$1" tool yn
  printf '\nEmail an AES-256 encrypted ZIP copy via SMTP? [yes/no] (default: no): ' >/dev/tty
  read -r -t 30 yn </dev/tty || yn="no"
  [[ "${yn,,}" == "yes" ]] || return 2
  tool="$(_check_recovery_kit_email_deps)" || {
    log_error "Email was requested, but the encrypted ZIP dependency contract is not satisfied."
    return 1
  }

  local from to recovery_dir attachment_file attachment_name
  from="$(resolve_email_sender)" || return 1
  [[ -n "$from" && "$from" != *$'\r'* && "$from" != *$'\n'* ]] || {
    log_error "Recovery-kit email preflight: SMTP_FROM is missing or invalid."
    return 1
  }
  [[ -n "${SMTP_HOST:-}" && "${SMTP_HOST:-}" != *$'\r'* && "${SMTP_HOST:-}" != *$'\n'* ]] || {
    log_error "Recovery-kit email preflight: SMTP_HOST is missing or invalid."
    return 1
  }
  [[ "${SMTP_PORT:-}" =~ ^[0-9]+$ ]] || {
    log_error "Recovery-kit email preflight: SMTP_PORT is missing or invalid."
    return 1
  }
  [[ -n "${SMTP_USERNAME:-}" && "${SMTP_USERNAME:-}" != *$'\r'* && "${SMTP_USERNAME:-}" != *$'\n'* ]] || {
    log_error "Recovery-kit email preflight: SMTP_USERNAME is missing or invalid."
    return 1
  }
  to="$(_read_dotenv_value "ADMIN_EMAIL" "${PROJECT_ROOT:-.}/.env")"
  [[ -n "$to" ]] || to="${ADMIN_EMAIL:-}"
  [[ -n "$to" ]] || {
    log_error "Recovery-kit email preflight: ADMIN_EMAIL is not configured."
    return 1
  }

  recovery_dir="$(_prepare_recovery_dir)" || return 1
  attachment_name="important-documents-$(date -u +%Y%m%d).zip"
  attachment_file="$(mktemp "${recovery_dir}/.important-documents.XXXXXXXX.zip")" || return 1
  chmod 0600 -- "$attachment_file" || { rm -f -- "$attachment_file"; return 1; }
  register_cleanup "_remove_sensitive_file" "$attachment_file"
  if ! _encrypt_recovery_kit_attachment "$plaintext_file" "$attachment_file" "$tool"; then
    log_error "Encrypted ZIP creation or validation failed; email was not attempted."
    _remove_sensitive_file "$attachment_file" 2>/dev/null || true
    return 1
  fi

  local subject body
  subject="Do not lose this — important account documents"
  body=$(cat <<'BODY'
Please keep the attached file somewhere safe.

It is a ZIP archive encrypted with AES-256. The attachment passphrase is independent from all stored VaultWarden-OCI credentials and is not included in this email.

Extraction:
- Windows: use 7-Zip or another AES-ZIP-capable application.
- macOS: use an AES-ZIP-capable application; the built-in Archive Utility may not support this archive.
- Linux: run `7zz x important-documents-YYYYMMDD.zip` and enter the attachment passphrase.

Store the extracted recovery document securely and delete plaintext copies after use.
BODY
)
  log_info "Sending encrypted recovery ZIP to ${to} via SMTP attachment path..."
  if ! send_smtp_attachment "$to" "$subject" "$body" "$attachment_file" "$attachment_name"; then
    log_error "SMTP delivery failed; the recovery ZIP was not emailed."
    _remove_sensitive_file "$attachment_file" 2>/dev/null || true
    return 1
  fi
  _remove_sensitive_file "$attachment_file" 2>/dev/null || {
    log_error "Email succeeded, but temporary ZIP cleanup failed."
    return 1
  }
  log_success "Encrypted recovery ZIP emailed to ${to}."
  return 0
}

validate_cloudflare_token() (
    
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

    local curl_cfg="" curl_workspace=""
    trap '[[ -z "${curl_workspace:-}" ]] || remove_sensitive_workspace "$curl_workspace" >/dev/null 2>&1 || true' EXIT
    trap 'exit 130' INT
    trap 'exit 129' HUP
    trap 'exit 143' TERM
    curl_workspace="$(create_sensitive_workspace cloudflare-token)" || return 1
    curl_cfg="${curl_workspace}/curl.conf"
    if ! install -m 600 /dev/null "$curl_cfg"; then
        remove_sensitive_workspace "$curl_workspace" 2>/dev/null || true
        return 1
    fi
    if ! printf 'header = "Authorization: Bearer %s"\n' "$token" > "$curl_cfg"; then
        log_error "Cloudflare token validation: failed to write protected curl configuration"
        return 1
    fi

    local result=0
    if curl -sf --max-time 10 --config "$curl_cfg" "$endpoint" \
        | jq -e '.success == true' >/dev/null 2>&1; then
        result=0
    else
        result=1
    fi
    if ! remove_sensitive_workspace "$curl_workspace"; then
        log_error "Cloudflare token validation: failed to clean sensitive workspace"
        return 1
    fi
    curl_workspace=""
    return "$result"
)

prompt_password_with_confirmation() {
    local prompt_text="$1"
    local min_length="${2:-12}"
    local max_attempts="${3:-3}"
    local password password_confirm
    local attempt=0

    while true; do
        attempt=$(( attempt + 1 ))
        if [[ $attempt -gt $max_attempts ]]; then
            log_error "Too many failed password attempts (${max_attempts}). Aborting."
            return 1
        fi

        printf '%s: ' "$prompt_text" >/dev/tty
        read -r -s password </dev/tty
        echo "" >/dev/tty
        if [[ -z "$password" ]]; then
            log_error "Password cannot be empty (attempt $attempt/$max_attempts)"
            continue
        fi
        if [[ ${#password} -lt $min_length ]]; then
            log_error "Password must be at least $min_length characters (attempt $attempt/$max_attempts)"
            continue
        fi
        printf 'Confirm password: ' >/dev/tty
        read -r -s password_confirm </dev/tty
        echo "" >/dev/tty
        if [[ "$password" != "$password_confirm" ]]; then
            log_error "Passwords don't match (attempt $attempt/$max_attempts)"
            continue
        fi
        break
    done
    printf '%s' "$password"
    return 0
}

secure_secrets_file() {
    local secrets_file="${1:-$SECRETS_FILE}"
    local secrets_dir
    secrets_dir="$(dirname "$secrets_file")"

    if [[ -d "$secrets_dir" ]]; then
        fix_known_path_permissions "$secrets_dir"
    fi

    if [[ ! -f "$secrets_file" ]]; then return 0; fi
    fix_known_path_permissions "$secrets_file"
    return 0
}

_bcrypt_format_ok() {
    local hash="$1"
    [[ "$hash" =~ ^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]]
}

# New auto keys (fields with auto_fn declared in the schema) must NOT be added
# here. They are dispatched through the schema to auto_generate_secret_field().
# file_integrity_hmac_key deliberately rejects interactive collection.
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

        file_integrity_hmac_key)
            log_error "collect_secret_field: '$field' is an auto key. Call auto_generate_secret_field() instead." >&2
            return 1
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
        admin_token|admin_basic_auth_hash)
            log_error "Automatic administrator credential generation requires protected capture and publication." >&2
            log_error "Use: sudo ./setup.sh install --auto" >&2
            log_error "Direct interactive configuration remains available without --auto." >&2
            return 1
            ;;
        caddy_cloudflare_dns_token)
            log_warn "Auto mode: Using placeholder for Cloudflare DNS token - MUST be updated before deployment" >&2
            printf '%s' "CHANGE_ME_DNS_TOKEN"
            ;;
        email_api_token)
            # Placeholder for the email provider API token.
            # Must be set via: sudo ./edit-secrets.sh rotate email_api_token
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
        # Single source of truth for this auto key.
        # collect_secret_field() returns an error for auto keys.
        # _dispatch_auto_fn() in setup-secrets.sh is the sole entry point.
        file_integrity_hmac_key)
            local integrity_key
            integrity_key=$(generate_secure_string 64)
            log_success "Backup integrity HMAC key generated (64 characters)" >&2
            printf '%s' "$integrity_key"
            ;;
        *)
            log_error "auto_generate_secret_field: unknown field '$field'" >&2
            return 1
            ;;
    esac
    return 0
}

_grk_sops_extract() {
    local _key="$1" _secrets_file="$2"
    local _val _rc=0

    # Suppress xtrace and SOPS stderr so recovery diagnostics cannot expose
    # plaintext-adjacent context. The key name and exit status are sufficient.
    { set +x; } 2>/dev/null
    _val=$(sops -d --extract "[\"${_key}\"]" "$_secrets_file" 2>/dev/null) || _rc=$?
    if (( _rc != 0 )); then
        log_error "generate_recovery_kit: failed to extract schema key '${_key}' (sops exit ${_rc})"
        unset _val
        return 1
    fi
    printf '%s' "$_val"
    unset _val
}

_grk_append() {
    local output_file="$1"
    shift
    if ! "$@" >> "$output_file"; then
        log_error "generate_recovery_kit: failed to append recovery document"
        return 1
    fi
}

_validate_recovery_kit_document() {
    local recovery_file="$1" expected_labels="$2"
    local label count

    [[ -s "$recovery_file" ]] || {
        log_error "Recovery-kit validation failed: staged document is empty"
        return 1
    }
    [[ "$(grep -Fxc 'END OF RECOVERY KIT' "$recovery_file" 2>/dev/null || true)" == "1" ]] || {
        log_error "Recovery-kit validation failed: completion marker is missing or duplicated"
        return 1
    }
    [[ "$(grep -c '^AGE-SECRET-KEY-1' "$recovery_file" 2>/dev/null || true)" == "1" ]] || {
        log_error "Recovery-kit validation failed: expected exactly one Age private identity"
        return 1
    }

    while IFS= read -r label; do
        [[ -n "$label" ]] || continue
        count=$(grep -Fxc "[$label]" "$recovery_file" 2>/dev/null || true)
        if [[ "$count" != "1" ]]; then
            log_error "Recovery-kit validation failed: field '$label' rendered ${count} times (expected once)"
            return 1
        fi
    done <<< "$expected_labels"
    return 0
}

generate_recovery_kit() {
    local output_file="$1"
    local age_key
    local secrets_file="${SECRETS_FILE}"
    local env_file="${PROJECT_ROOT:-.}/.env"
    local _schema_key_list _runtime_required_key_list _required_key

    if ! schema_validate; then
        log_error "generate_recovery_kit: secrets-schema.yaml validation failed"
        return 1
    fi
    if ! _schema_key_list=$(schema_keys); then
        log_error "generate_recovery_kit: failed to enumerate secrets-schema.yaml"
        return 1
    fi
    [[ -n "$_schema_key_list" ]] || {
        log_error "generate_recovery_kit: secrets-schema.yaml contains no managed secrets"
        return 1
    }
    if ! _runtime_required_key_list=$(_schema_required_runtime_keys); then
        log_error "generate_recovery_kit: failed to determine runtime-required recovery secrets"
        return 1
    fi
    declare -A _grk_runtime_required=()
    while IFS= read -r _required_key; do
        [[ -z "$_required_key" ]] && continue
        _grk_runtime_required["$_required_key"]=1
    done <<< "$_runtime_required_key_list"

    if [[ ! -f "$secrets_file" ]]; then
        log_error "generate_recovery_kit: secrets file not found: $secrets_file"
        return 1
    fi
    age_key=$(resolve_age_key_path) || return 1
    if [[ ! -f "$age_key" ]]; then
        log_error "Age key not found: $age_key"
        return 1
    fi
    if ! has_command age; then
        log_error "generate_recovery_kit: 'age' is required to cryptographically validate the Age private identity"
        return 1
    fi
    if ! check_age_key "$age_key"; then
        log_error "generate_recovery_kit: Age private identity validation failed"
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
    if ! priv_key=$(cat "$age_key"); then
        log_error "generate_recovery_kit: failed to read Age private identity"
        return 1
    fi

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

    declare -A _grk_values=() _grk_labels=() _grk_seen_labels=()
    local expected_labels=""

    if ! ensure_sops_env; then return 1; fi
    trap 'cleanup_secrets_environment' RETURN

    local _rk_key _rk_value _rk_placeholder _rk_label
    while IFS= read -r _rk_key; do
        [[ -z "$_rk_key" ]] && continue

        if ! _rk_label=$(schema_field "$_rk_key" label); then
            log_error "generate_recovery_kit: failed to read label for schema key '$_rk_key'"
            unset priv_key
            return 1
        fi
        if [[ -z "$_rk_label" || "$_rk_label" == *$'\n'* || "$_rk_label" == *$'\r'* ]]; then
            log_error "generate_recovery_kit: invalid recovery label for schema key '$_rk_key'"
            unset priv_key
            return 1
        fi
        if [[ -n "${_grk_seen_labels[$_rk_label]+set}" ]]; then
            log_error "generate_recovery_kit: duplicate recovery label in schema: $_rk_label"
            unset priv_key
            return 1
        fi
        _grk_seen_labels["$_rk_label"]=1

        if ! _rk_placeholder=$(schema_field "$_rk_key" placeholder); then
            log_error "generate_recovery_kit: failed to read placeholder for schema key '$_rk_key'"
            unset priv_key
            return 1
        fi

        if ! _rk_value=$(_grk_sops_extract "$_rk_key" "$secrets_file"); then
            unset priv_key
            return 1
        fi
        if _secret_value_is_inactive "$_rk_value" "$_rk_placeholder"; then
            if [[ -n "${_grk_runtime_required[$_rk_key]+set}" ]]; then
                log_error "generate_recovery_kit: runtime-required secret '$_rk_key' is unset or placeholder"
                unset _rk_value priv_key
                return 1
            fi
            _rk_value="<not set: optional>"
        fi

        _grk_labels["$_rk_key"]="$_rk_label"
        _grk_values["$_rk_key"]="$_rk_value"
        [[ -z "$expected_labels" ]] || expected_labels+=$'\n'
        expected_labels+="$_rk_label"
        unset _rk_value
    done <<< "$_schema_key_list"

    cleanup_secrets_environment

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
    # Every append is explicitly checked because callers invoke this function
    # from guarded boolean contexts where Bash errexit is not reliable.
    _grk_append "$output_file" cat << 'EOF' || return 1
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
    _grk_append "$output_file" cat << 'EOF' || return 1
═══════════════════════════════════════════════════════════════════════
                        🚨 CRITICAL SECURITY DOCUMENT 🚨
═══════════════════════════════════════════════════════════════════════
EOF
    _grk_append "$output_file" printf 'Created: %s\n' "$date_val" || return 1
    _grk_append "$output_file" printf 'Server:  %s\n' "$hostname_val" || return 1
    _grk_append "$output_file" printf 'Domain:  %s\n' "$domain" || return 1
    _grk_append "$output_file" cat << 'EOF' || return 1

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
    _grk_append "$output_file" printf '%s\n' "$priv_key" || return 1
    _grk_append "$output_file" cat << 'EOF' || return 1

[AGE PUBLIC KEY]
EOF
    _grk_append "$output_file" printf '%s\n' "$pub_key" || return 1
    _grk_append "$output_file" cat << 'EOF' || return 1

════════════════════════════════════════════════════════════════════════
SECTION 2: SERVER SECRETS (DECRYPTED)
════════════════════════════════════════════════════════════════════════

EOF

    # Render the same schema inventory collected above. No fallback or second
    # enumeration is permitted once generation begins.
    local _kit_key
    while IFS= read -r _kit_key; do
        [[ -z "$_kit_key" ]] && continue
        _grk_append "$output_file" printf '[%s]\n' "${_grk_labels[$_kit_key]}" || return 1
        _grk_append "$output_file" printf '%s\n\n' "${_grk_values[$_kit_key]}" || return 1
    done <<< "$_schema_key_list"

    unset _grk_values _grk_labels _grk_seen_labels _grk_runtime_required

        _grk_append "$output_file" cat << 'EOF' || return 1

════════════════════════════════════════════════════════════════════════
SECTION 3: DISASTER RECOVERY & MIGRATION CHECKLIST
════════════════════════════════════════════════════════════════════════

TO RESTORE THIS SERVER ON NEW HARDWARE:

1. PREPARATION
   [ ] Install Git, Docker, SOPS, Age, and required restore tools on the new server.
   [ ] Clone the repository:
EOF
    _grk_append "$output_file" printf '       git clone %s\n' "$repo_clone_url" || return 1
    local repo_basename
    repo_basename=$(basename "$repo_clone_url" .git)
    _grk_append "$output_file" printf '       cd %s\n' "$repo_basename" || return 1
    _grk_append "$output_file" printf '\n' || return 1
    _grk_append "$output_file" printf '   [ ] For a fresh install only, run setup:\n' || return 1
    _grk_append "$output_file" printf '       sudo ./setup.sh install --domain %s --email %s\n' "$domain" "$admin_email" || return 1
    _grk_append "$output_file" cat << 'EOF' || return 1

2. PRIMARY RECOVERY PATH: EXISTING STATE DIRECTORY OR ATTACHED DATA/BLOCK VOLUME
   Use this when /var/lib/vaultwarden or the dedicated VaultWarden data volume is available.

   [ ] Mount or attach the state directory/volume.
       Default state directory:
       /var/lib/vaultwarden

   [ ] Place the offline Age private key on removable media, for example:
       /mnt/usb/offline-age-key.txt

   [ ] Run recover.sh:
       sudo ./recover.sh --state-dir /var/lib/vaultwarden --key /mnt/usb/offline-age-key.txt --storage-mode auto

       For an explicit boot-volume state directory:
       sudo ./recover.sh --state-dir /var/lib/vaultwarden --key /mnt/usb/offline-age-key.txt --storage-mode boot

       For an explicit mounted block/data volume:
       sudo ./recover.sh --state-dir /var/lib/vaultwarden --key /mnt/usb/offline-age-key.txt --storage-mode block

   [ ] Save the new operational Age key generated during recovery.
       The server-installed operational key should live at:
       /etc/vaultwarden/age-key.txt

3. ENCRYPTED BACKUP RESTORE: LOCAL OR REMOTE
   Use this when restoring from a local or remote encrypted backup.

   [ ] Keep the [AGE PRIVATE KEY] from SECTION 1 ready in your password manager.
       You do not need to create an Age key file or attach removable media.

   [ ] For a local backup, start the guided restore:
       sudo ./restore.sh interactive

   [ ] For a remote backup, configure rclone if needed:
       rclone config

       Then start the guided remote restore:
       sudo ./restore.sh interactive --remote

   [ ] Select the backup to restore.

   [ ] At the "Age private key (hidden):" prompt, copy and paste the full
       AGE-SECRET-KEY-1... private key from SECTION 1, then press Enter.

       The pasted key is hidden and staged only for this restore session.
       You do not need to save the Age private key as a file on the server.

   [ ] Complete the guided restore prompts.

   [ ] Save the new operational Age key and updated recovery kit after restore.
       The restored secrets are rekeyed to the new operational Age key.

4. MANUAL REBUILD ONLY
   Use this only if no usable state directory or encrypted backup exists.

   [ ] Re-enter values from SECTION 2:
       sudo ./setup.sh secrets

   [ ] Rotate or edit any missing/placeholder secrets:
       sudo ./edit-secrets.sh rotate <field>
       sudo ./edit-secrets.sh edit

5. FINALIZATION
   [ ] Start services:
       sudo make up

   [ ] Check health:
       sudo make health

   [ ] Confirm Docker services:
       sudo docker compose ps

   [ ] Store the recovery kit and any new operational Age key outside the server.
   

════════════════════════════════════════════════════════════════════════
END OF RECOVERY KIT
════════════════════════════════════════════════════════════════════════
EOF

    # Unset plaintext Age private key from memory immediately after
    # the heredoc that wrote it to the output file.
    unset priv_key

    if ! _validate_recovery_kit_document "$output_file" "$expected_labels"; then
        _remove_sensitive_file "$output_file" 2>/dev/null || rm -f -- "$output_file"
        return 1
    fi
    if ! chmod 600 "$output_file"; then
        log_error "generate_recovery_kit: failed to enforce mode 0600 on staged recovery document"
        return 1
    fi
}

_ork_generate_and_secure() {
  # Render and validate plaintext only in a verified volatile workspace. The
  # persistent pathname is reserved using an empty same-directory stub; only
  # the intentional final recovery artifact ever contains plaintext on disk.
  local output_file="$1" output_dir sensitive_workspace temp_file publish_stub old_umask
  output_dir="$(dirname -- "$output_file")"
  [[ -d "$output_dir" && ! -L "$output_dir" ]] || return 1
  [[ ! -e "$output_file" && ! -L "$output_file" ]] || {
    log_error "Refusing to overwrite recovery kit: $output_file"
    return 1
  }

  sensitive_workspace="$(create_sensitive_workspace recovery-kit)" || return 1
  temp_file="${sensitive_workspace}/recovery-kit.txt"
  old_umask="$(umask)"; umask 077
  publish_stub="$(mktemp "${output_dir}/.vaultwarden-recovery-publish.XXXXXXXX")" || {
    umask "$old_umask"
    remove_sensitive_workspace "$sensitive_workspace" 2>/dev/null || true
    return 1
  }
  umask "$old_umask"
  chmod 0600 -- "$publish_stub" || {
    rm -f -- "$publish_stub"
    remove_sensitive_workspace "$sensitive_workspace" 2>/dev/null || true
    return 1
  }

  (
    local linked=false completed=false
    _ork_rollback_incomplete_publication() {
      [[ "$completed" == "true" ]] && return 0
      # The same-inode check closes the signal window after ln succeeds but
      # before linked=true. The disk-side stub is empty and never holds secrets.
      if [[ "$linked" == "true" ]] \
          || { [[ -e "$output_file" && -e "$publish_stub" ]] && [[ "$output_file" -ef "$publish_stub" ]]; }; then
        _remove_sensitive_file "$output_file" 2>/dev/null || true
      fi
      rm -f -- "$publish_stub" 2>/dev/null || true
      remove_sensitive_workspace "$sensitive_workspace" 2>/dev/null || true
    }
    trap _ork_rollback_incomplete_publication EXIT
    trap 'completed=false; exit 130' INT
    trap 'completed=false; exit 129' HUP
    trap 'completed=false; exit 143' TERM

    generate_recovery_kit "$temp_file" || exit 1
    [[ -s "$temp_file" ]] || exit 1
    grep -Fq 'END OF RECOVERY KIT' "$temp_file" || exit 1
    grep -Fq 'AGE-SECRET-KEY-1' "$temp_file" || exit 1
    chmod 0600 -- "$temp_file" || exit 1
    if (( EUID == 0 )); then
      chown root:root -- "$temp_file" || exit 1
    fi

    # Reserve the final path without placing plaintext in a persistent temp.
    ln -- "$publish_stub" "$output_file" || exit 1
    linked=true
    rm -f -- "$publish_stub" || exit 1
    cat -- "$temp_file" > "$output_file" || exit 1
    chmod 0600 -- "$output_file" || exit 1
    if (( EUID == 0 )); then
      chown root:root -- "$output_file" || exit 1
    fi
    cmp -s -- "$temp_file" "$output_file" || exit 1
    grep -Fq 'END OF RECOVERY KIT' "$output_file" || exit 1
    grep -Fq 'AGE-SECRET-KEY-1' "$output_file" || exit 1

    if ! remove_sensitive_workspace "$sensitive_workspace"; then
      log_error "Recovery-kit volatile plaintext cleanup failed; rolling back publication."
      exit 1
    fi
    if ! _schedule_recovery_cleanup "$output_file" "30m"; then
      log_error "Recovery-kit cleanup could not be scheduled; rolling back published plaintext."
      exit 1
    fi
    completed=true
  ) || return 1
  return 0
}

offer_recovery_kit_export() {
  # VWOCI-PRR-PATCH-02: the full kit is separate from setup credentials and is
  # published only under /root/vaultwarden-recovery (or an explicit test override).
  local auto_export="${1:-false}" recovery_dir stamp short_id recovery_file email_rc=0
  recovery_dir="$(_prepare_recovery_dir)" || return 1
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  short_id="$(openssl rand -hex 3 2>/dev/null)" || return 1
  recovery_file="${recovery_dir}/vaultwarden-recovery-kit-${stamp}-${short_id}.txt"

  if [[ "$auto_export" != "true" ]]; then
    local answer
    printf 'Export a protected plaintext Recovery Kit? [yes/no] (default: no): ' >/dev/tty
    read -r answer </dev/tty || answer="no"
    [[ "${answer,,}" == "yes" ]] || return 0
  fi

  _ork_generate_and_secure "$recovery_file" || {
    log_error "Recovery-kit publication failed."
    return 1
  }
  log_success "Recovery Kit saved: $recovery_file"
  log_info "Owner: root:root; permissions: 0600; document validation: passed"
  log_info "The recovery-kit body was not written to terminal output."
  log_info "Primary plaintext cleanup was accepted for approximately 30 minutes: $recovery_file"
  log_info "Routine maintenance also removes eligible leftovers that are at least 30 minutes old."

  _offer_email_recovery_kit "$recovery_file" || email_rc=$?
  case "$email_rc" in
    0)
      if ! _remove_sensitive_file "$recovery_file" || [[ -e "$recovery_file" || -L "$recovery_file" ]]; then
        log_error "Encrypted delivery succeeded, but the local plaintext copy could not be removed: $recovery_file"
        return 1
      fi
      log_success "Encrypted delivery succeeded; local plaintext recovery kit removed: $recovery_file"
      log_info "The accepted 30-minute cleanup timer remains as an idempotent safety net."
      return 0
      ;;
    2)
      log_info "Encrypted email declined; protected plaintext remains temporarily at: $recovery_file"
      log_info "Primary cleanup is scheduled for approximately 30 minutes."
      log_info "If it survives that cleanup, the next routine maintenance run removes eligible leftovers."
      return 0
      ;;
    *)
      log_error "Encrypted email was requested but failed; protected plaintext remains temporarily at: $recovery_file"
      log_info "Primary cleanup is scheduled for approximately 30 minutes."
      log_info "If it survives that cleanup, the next routine maintenance run removes eligible leftovers."
      return "$email_rc"
      ;;
  esac
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

validate_plaintext_secrets_schema_contract() {
    local plain_yaml="$1"
    local schema_file="${2:-${SECRETS_SCHEMA_FILE:-${PROJECT_ROOT}/secrets-schema.yaml}}"

    schema_keys "$schema_file" >/dev/null || return 1

    CLOUDFLARE_PROXY_ENABLED="${CLOUDFLARE_PROXY_ENABLED:-false}" \
        python3 - "$plain_yaml" "$schema_file" <<'PYEOF'
import os
import sys

try:
    import yaml
except Exception as exc:
    print(f"schema contract: Python PyYAML is required: {exc}", file=sys.stderr)
    sys.exit(1)

plain_path, schema_path = sys.argv[1], sys.argv[2]

class NoDupLoader(yaml.SafeLoader):
    pass

def no_duplicate_mapping(loader, node):
    seen = {}
    for key_node, _ in node.value:
        key = loader.construct_object(key_node)
        if key in seen:
            raise ValueError(
                "duplicate key '{}' at line {} (first declared at line {})".format(
                    key, key_node.start_mark.line + 1, seen[key]
                )
            )
        seen[key] = key_node.start_mark.line + 1
    return loader.construct_mapping(node, deep=True)

NoDupLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    no_duplicate_mapping,
)

def load(path, label):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = yaml.load(handle, Loader=NoDupLoader)
    except (OSError, yaml.YAMLError, ValueError) as exc:
        print(f"schema contract: {label}: {exc}", file=sys.stderr)
        sys.exit(1)
    if data is None:
        data = {}
    if not isinstance(data, dict):
        print(f"schema contract: {label} must be a mapping", file=sys.stderr)
        sys.exit(1)
    return data

def inactive(value, placeholder):
    if value is None:
        return True
    text = str(value)
    return (
        text == ""
        or text == "null"
        or text.startswith("CHANGE_ME")
        or text.startswith("NOT_USED")
        or text.startswith("PLACEHOLDER")
        or (placeholder and text == str(placeholder))
    )

plain = load(plain_path, "secrets YAML")
schema = load(schema_path, "schema")
entries = schema.get("secrets") or []
schema_by_key = {entry.get("key"): entry for entry in entries if isinstance(entry, dict)}
schema_keys = set(schema_by_key)
legacy_keys = set()
errors = []

for key in plain:
    if key == "sops":
        continue
    if key not in schema_keys:
        errors.append(f"{key}: unknown secret key not declared in schema")

for key, entry in schema_by_key.items():
    if entry.get("required") is True:
        if key not in plain:
            errors.append(f"{key}: required schema key is missing")
        elif inactive(plain.get(key), entry.get("placeholder", "")):
            errors.append(f"{key}: required schema key is inactive or placeholder")

if os.environ.get("CLOUDFLARE_PROXY_ENABLED", "false").lower() == "true":
    for key, entry in schema_by_key.items():
        if entry.get("conditional_group") == "cloudflare_proxy":
            if key not in plain:
                errors.append(f"{key}: required when CLOUDFLARE_PROXY_ENABLED=true")
            elif inactive(plain.get(key), entry.get("placeholder", "")):
                errors.append(f"{key}: inactive while CLOUDFLARE_PROXY_ENABLED=true")

for key, value in plain.items():
    if key == "sops" or key not in schema_by_key:
        continue
    if isinstance(value, (dict, list)):
        errors.append(f"{key}: secret value must be a scalar")

if errors:
    for error in errors:
        print(f"schema contract: {error}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

_validate_no_placeholders() {
    local plain_yaml="$1"
    if ! validate_plaintext_secrets_schema_contract "$plain_yaml"; then
        log_error "Recovery-kit secret preflight failed the authoritative schema contract."
        log_error "Configure required values before exporting; optional unset values are allowed and rendered explicitly."
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
# stage one flat file per active known secret key, then install it into
# DOCKER_DIR. Each output file is installed root:root mode 0444. Inactive
# values (empty, CHANGE_ME*, NOT_USED*, PLACEHOLDER*, null, the schema
# placeholder, or disabled push credentials) remove any previously exported
# schema-managed runtime file.
#
# Hardening (consolidated from startup.sh::prepare_docker_secrets):
#   1. SOPS decryption is written only inside a verified volatile root-only
#      workspace; no persistent plaintext staging location is permitted.
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

    local _eds_tmpdir _eds_cache
    _eds_tmpdir="$(create_sensitive_workspace runtime-secrets)" || {
        log_error "export_docker_secrets: no verified volatile plaintext staging directory is available"
        return 1
    }
    if declare -F register_cleanup >/dev/null 2>&1             && declare -p CLEANUP_ACTIONS >/dev/null 2>&1; then
        if ! register_cleanup "remove_sensitive_workspace" "$_eds_tmpdir"; then
            remove_sensitive_workspace "$_eds_tmpdir" 2>/dev/null || true
            log_error "export_docker_secrets: failed to register volatile workspace cleanup"
            return 1
        fi
    fi
    _eds_cache="${_eds_tmpdir}/secrets.yaml"
    install -m 600 /dev/null "$_eds_cache" 2>/dev/null || true

    # shellcheck disable=SC2064  # intentional: temp path is captured for RETURN cleanup
    trap "{ remove_sensitive_workspace '$_eds_tmpdir' 2>/dev/null || true; cleanup_secrets_environment; }" RETURN

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

    local _schema_keys_str
    if ! _schema_keys_str=$(schema_keys 2>/dev/null); then
        log_error "export_docker_secrets: failed to read key list from secrets-schema.yaml"
        return 1
    fi

    declare -A _eds_allowed_keys=()
    while IFS= read -r _sk; do
        [[ -z "$_sk" ]] && continue
        _eds_allowed_keys["$_sk"]=1
    done <<< "$_schema_keys_str"

    declare -A _eds_values=()
    while IFS='=' read -r _key _value; do
        [[ -z "$_key" ]] && continue
        [[ -n "${_eds_allowed_keys[$_key]+set}" ]] || continue
        _eds_values["$_key"]="$_value"
    done < <(
        python3 - "$_eds_cache" <<'PYEOF'
import sys, yaml
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}
if not isinstance(data, dict):
    sys.exit(0)
for k, v in data.items():
    if v is None:
        print(f"{k}=null")
    elif isinstance(v, bool):
        print(f"{k}={'true' if v else 'false'}")
    elif isinstance(v, (str, int, float)):
        print(f"{k}={v}")
PYEOF
    )

    local _failed=0
    local _key _value _staged _placeholder
    declare -A _eds_active_keys=()
    declare -A _eds_inactive_keys=()

    while IFS= read -r _key; do
        [[ -z "$_key" ]] && continue
        _value="${_eds_values[$_key]:-}"
        _placeholder=$(schema_placeholder_for_key "$_key" 2>/dev/null || printf '')

        if _runtime_secret_value_is_inactive "$_key" "$_value" "$_placeholder"; then
            _eds_inactive_keys["$_key"]=1
            log_warn "export_docker_secrets: '$_key' inactive (placeholder/sentinel/empty) — removing derived runtime file if present"
            unset _value
            continue
        fi

        _staged="${_eds_tmpdir}/${_key}"
        if ! write_secret_file "$_staged" "$_value"; then
            log_error "export_docker_secrets: failed to stage ${_key}"
            _failed=$(( _failed + 1 ))
        else
            _eds_active_keys["$_key"]=1
        fi
        unset _value
    done <<< "$_schema_keys_str"
    unset _key

    local _bad_secrets=()
    local _f _head
    for _f in "$_eds_tmpdir"/*; do
        [[ -f "$_f" ]] || continue
        [[ "$(basename "$_f")" == "secrets.yaml" ]] && continue
        if read -r -n 4 _head < "$_f" 2>/dev/null && [[ "$_head" == "ENC[" ]]; then
            _bad_secrets+=("$(basename "$_f")")
            _remove_sensitive_file "$_f" 2>/dev/null || rm -f "$_f"
        fi
    done
    if [[ ${#_bad_secrets[@]} -gt 0 ]]; then
        log_error "export_docker_secrets: secret file(s) contain raw SOPS ciphertext — decryption failed silently:"
        local _s
        for _s in "${_bad_secrets[@]}"; do
            log_error "  ${docker_dir}/${_s}"
        done
        log_error "Remediation: run make key-health, clear stale files as root, then re-run sudo make up."
        return 1
    fi

    if [[ $_failed -gt 0 ]]; then
        log_error "export_docker_secrets: $_failed key(s) failed to export"
        return 1
    fi

    if ! VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo install -d -m 0700 -o root -g root "$docker_dir"; then
        log_error "export_docker_secrets: cannot prepare root-owned runtime secret directory: $docker_dir"
        log_error "For sudo make up: run sudo make init-secrets, then re-run sudo make up"
        log_error "For direct scripts: run sudo ./setup.sh secrets"
        return 1
    fi

    for _f in "$_eds_tmpdir"/*; do
        [[ -f "$_f" ]] || continue
        [[ "$(basename "$_f")" == "secrets.yaml" ]] && continue
        if ! VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo install -m 0444 -o root -g root "$_f" "${docker_dir}/$(basename "$_f")"; then
            log_error "export_docker_secrets: failed to install ${docker_dir}/$(basename "$_f")"
            log_error "For sudo make up: run sudo make init-secrets, then re-run sudo make up"
            log_error "For direct scripts: run sudo ./setup.sh secrets"
            return 1
        fi
    done

    local _manifest
    _manifest="$(_managed_secrets_manifest_path "$docker_dir")"
    local _manifest_tmp="${_eds_tmpdir}/managed-secrets"
    declare -A _eds_remove_keys=()

    for _key in "${!_eds_inactive_keys[@]}"; do
        _eds_remove_keys["$_key"]=1
    done

    local _previous_manifest=""
    if VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo test -f "$_manifest"; then
        _previous_manifest=$(VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo cat "$_manifest" 2>/dev/null || true)
    fi
    while IFS= read -r _key; do
        [[ -z "$_key" ]] && continue
        [[ "$_key" =~ ^[a-z][a-z0-9_]*$ ]] || continue
        [[ -n "${_eds_active_keys[$_key]+set}" ]] && continue
        _eds_remove_keys["$_key"]=1
    done <<< "$_previous_manifest"

    for _key in "${!_eds_remove_keys[@]}"; do
        [[ "$_key" =~ ^[a-z][a-z0-9_]*$ ]] || continue
        if VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo test -e "${docker_dir}/${_key}"; then
            if VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo rm -f "${docker_dir}/${_key}"; then
                log_info "export_docker_secrets: removed inactive/stale runtime secret ${docker_dir}/${_key}"
            else
                log_error "export_docker_secrets: failed to remove inactive/stale runtime secret ${docker_dir}/${_key}"
                return 1
            fi
        fi
    done

    : > "$_manifest_tmp"
    for _key in "${!_eds_active_keys[@]}"; do
        printf '%s\n' "$_key" >> "$_manifest_tmp"
    done
    if ! VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo install -d -m 0700 -o root -g root "$(dirname "$_manifest")"; then
        log_error "export_docker_secrets: failed to prepare managed runtime metadata directory: $(dirname "$_manifest")"
        return 1
    fi
    if ! VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo install -m 0600 -o root -g root "$_manifest_tmp" "$_manifest"; then
        log_error "export_docker_secrets: failed to update managed runtime secret manifest"
        return 1
    fi

    local _cf_flat="/run/vaultwarden-oci/secrets/crowdsec_cf_firewall_token"
    local _cf_dest="${docker_dir}/crowdsec_cf_firewall_token"
    if [[ "$_cf_flat" != "$_cf_dest" ]]; then
        if VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo test -s "$_cf_flat"; then
            if ! VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo install -m 0444 -o root -g root "$_cf_flat" "$_cf_dest"; then
                log_warn "export_docker_secrets: could not preserve existing CrowdSec CF token from root-owned runtime secrets directory"
            fi
        elif VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo test -e "$_cf_flat"; then
            log_warn "export_docker_secrets: existing CrowdSec CF token is empty; not mirroring it"
        fi
    elif VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo test -e "$_cf_flat" \
        && ! VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo test -s "$_cf_flat"; then
        log_warn "export_docker_secrets: existing CrowdSec CF token is empty"
    fi

    log_success "Docker secrets exported to: $docker_dir"
    return 0
}

prepare_push_secret_placeholders() {
    local secrets_dir="${1:-${DOCKER_SECRETS_DIR:-/run/vaultwarden-oci/secrets}}"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would enforce push secret placeholder permissions in ${secrets_dir}"
        return 0
    fi

    local changed=false
    VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo mkdir -p "$secrets_dir" || return 1

    local dir_owner dir_mode
    dir_owner=$(stat -c '%u:%g' "$secrets_dir" 2>/dev/null || echo "")
    dir_mode=$(stat -c '%a' "$secrets_dir" 2>/dev/null || echo "")
    if [[ "$dir_owner" != "0:0" ]]; then
        VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo chown root:root "$secrets_dir" || return 1
        changed=true
    fi
    if [[ "$dir_mode" != "700" ]]; then
        VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo chmod 700 "$secrets_dir" || return 1
        changed=true
    fi

    local key path owner mode
    for key in push_installation_id push_installation_key; do
        path="${secrets_dir}/${key}"
        if [[ ! -f "$path" ]]; then
            VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo install -m 0444 -o root -g root /dev/null "$path" || return 1
            changed=true
        fi

        owner=$(stat -c '%u:%g' "$path" 2>/dev/null || echo "")
        mode=$(stat -c '%a' "$path" 2>/dev/null || echo "")
        if [[ "$owner" != "0:0" ]]; then
            VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo chown root:root "$path" || return 1
            changed=true
        fi
        if [[ "$mode" != "444" ]]; then
            VAULTWARDEN_NONINTERACTIVE_SUDO=true _maybe_sudo chmod 444 "$path" || return 1
            changed=true
        fi
    done

    dir_owner=$(stat -c '%u:%g' "$secrets_dir" 2>/dev/null || echo "")
    dir_mode=$(stat -c '%a' "$secrets_dir" 2>/dev/null || echo "")
    if [[ "$dir_owner" != "0:0" || "$dir_mode" != "700" ]]; then
        log_error "Runtime secret directory must remain root:root 0700: ${secrets_dir}"
        return 1
    fi

    if [[ "$changed" == "true" ]]; then
        log_success "Push secret placeholders remediated with host-private permissions"
    else
        log_success "Push secret placeholders already host-private"
    fi
}
