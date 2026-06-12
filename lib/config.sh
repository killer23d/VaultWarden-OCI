#!/usr/bin/env bash
# lib/config.sh — Environment and configuration loading helpers for VaultWarden-OCI.
#
# Provides:
#   Load    : load_env_file
#   Query   : get_config_value, require_config
#   Helpers : _get_file_perms, _set_env_var, _read_env_value
#
# Depends on / Load order:
#   lib/log.sh is auto-loaded if it has not already been sourced.
#
# Canonical caller source block:
#   source "${LIB_DIR}/log.sh"
#   source "${LIB_DIR}/config.sh"
#   source "${LIB_DIR}/common.sh"

[[ -n "${VW_CONFIG_LIB_LOADED:-}" ]] && return 0
readonly VW_CONFIG_LIB_LOADED=1

# Self-load log.sh if not already loaded so this lib can be sourced standalone.
_VW_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${VW_LOG_LIB_LOADED:-}" ]] || source "${_VW_CONFIG_LIB_DIR}/log.sh"

_ENV_FILE_SEARCH_PATHS=(
    "${PROJECT_ROOT:-$(cd "${_VW_CONFIG_LIB_DIR}/.." && pwd)}/.env"
    "/etc/vaultwarden/vaultwarden.env"
)
unset _VW_CONFIG_LIB_DIR

_get_file_perms() {
    stat -c '%a' "$1" 2>/dev/null \
        || stat -f '%OLp' "$1" 2>/dev/null \
        || printf 'unknown'
}

load_env_file() {
    local env_file="${1:-}"

    if [[ -z "$env_file" ]]; then
        local candidate
        for candidate in "${_ENV_FILE_SEARCH_PATHS[@]}"; do
            if [[ -f "$candidate" ]]; then
                env_file="$candidate"
                break
            fi
        done
    fi

    if [[ -z "$env_file" || ! -f "$env_file" ]]; then
        log_error "Environment file not found: ${env_file:-.env} (also searched: ${_ENV_FILE_SEARCH_PATHS[*]})"
        return 1
    fi

    local file_perms
    file_perms=$(_get_file_perms "$env_file")

    if [[ $EUID -eq 0 ]]; then
        if [[ "$file_perms" == "unknown" ]]; then
            log_warn "load_env_file: cannot stat '$env_file' — skipping permission check"
        else
            local perm_int
            perm_int=$(( 8#${file_perms} ))
            if (( perm_int & 0177 )); then
                log_error "load_env_file: '$env_file' has insecure permissions (${file_perms})." \
                          " Run: chmod 600 '$env_file'"
                return 1
            fi
        fi
    else
        if [[ "$file_perms" != "unknown" ]]; then
            local perm_int
            perm_int=$(( 8#${file_perms} ))
            if (( perm_int & 0044 )); then
                local _perm_detail=""
                (( perm_int & 0040 )) && _perm_detail+="group-readable "
                (( perm_int & 0004 )) && _perm_detail+="world-readable "
                log_warn "load_env_file: '$env_file' is ${_perm_detail}(${file_perms})." \
                         " Fix: chmod 600 '$env_file'"
            fi
        fi
    fi

    log_debug "Loading environment from: $env_file"

    local line key raw_value value lineno=0
    local -a malformed_lines=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( lineno++ )) || true

        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" != *=* ]]; then
            continue
        fi

        key="${line%%=*}"
        raw_value="${line#*=}"

        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            malformed_lines+=("line ${lineno}: ${line}")
            continue
        fi

        if [[ "$raw_value" == '"'*'"' ]]; then
            value="${raw_value:1:${#raw_value}-2}"
        elif [[ "$raw_value" == "'"*"'" ]]; then
            value="${raw_value:1:${#raw_value}-2}"
        else
            value="$raw_value"
        fi

        # Injection guard: only $( and ` are genuine risks here because we use
        # printf -v (not eval) for assignment. Bare $, |, <, >, and \ are
        # inert in this context and must be allowed for strong passwords.
        # shellcheck disable=SC2016  # single quotes are intentional: checking for literal $( and `
        if [[ "$value" == *'`'* || "$value" == *'$('* ]]; then
            log_error "load_env_file: line ${lineno}: value for '${key}' contains" \
                      "shell command-substitution syntax (\`...\` or \$(...))" \
                      "— aborting load of '${env_file}'. Quote or escape the value."
            return 1
        fi
        # Refuse to overwrite security-sensitive shell internals.
        # PATH, LD_PRELOAD, LD_LIBRARY_PATH, and IFS can be weaponised by a
        # malicious or misconfigured .env to hijack the shell's execution
        # environment. These variables must never come from an untrusted file.
        case "$key" in
            PATH|LD_PRELOAD|LD_LIBRARY_PATH|IFS|BASH_ENV|ENV|CDPATH|PS4)
                log_error "load_env_file: line ${lineno}: refusing to overwrite dangerous variable '${key}'" \
                          "from ${env_file} — set it in the system environment instead."
                return 1
                ;;
        esac
            if [[ "$value" == *';'* || "$value" == *'&'* ]]; then
            log_warn "load_env_file: line ${lineno}: value for '${key}' contains" \
                     "';' or '&' — loaded as literal. If unintended, check '${env_file}'."
        fi

        printf -v "$key" '%s' "$value"
        # shellcheck disable=SC2163  # export "$key" exports the variable whose name is in $key
        export "$key"

    done < "$env_file"

    if (( ${#malformed_lines[@]} > 0 )); then
        log_warn "load_env_file: ${#malformed_lines[@]} malformed .env line(s) skipped from ${env_file}:"
        local malformed
        for malformed in "${malformed_lines[@]}"; do
            log_warn "  ${malformed}"
        done
        log_hint "Valid format: KEY=value or KEY="value with spaces""
        log_hint "Common mistakes: spaces around '=', an 'export ' prefix, or invalid variable names."
    fi

    log_debug "Environment loaded successfully from: $env_file"
    return 0
}

get_config_value() {
    local key="$1"
    local default="${2:-}"
    local value="${!key:-}"
    if [[ -z "$value" && -n "$default" ]]; then
        log_debug "get_config_value: '$key' not set in environment — using default: '$default'"
        value="$default"
    fi
    printf '%s\n' "$value"
}

require_config() {
    local missing=()
    local key

    for key in "$@"; do
        if [[ -z "${!key:-}" ]]; then
            missing+=("$key")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required configuration: ${missing[*]}"
        return 1
    fi

    return 0
}

_set_env_var() {
    local key="$1" value="$2" file="$3"
    local escaped_key
    escaped_key=$(printf '%s' "$key" | sed 's/[]\/$*.^[]/\\&/g')

    # Write via a same-directory temp file so an interrupted write never leaves
    # the env file in a partially-updated or corrupted state.
    local tmp_file
    tmp_file="$(dirname "$file")/.env.tmp.$$"
    # Ensure the temp file is removed on any unexpected exit.
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" RETURN

    if grep -q "^${escaped_key}=" "$file" 2>/dev/null; then
        local escaped_value
        escaped_value="${value//\\/\\\\}"
        escaped_value="${escaped_value//&/\\&}"
        escaped_value="${escaped_value//|/\\|}"
        sed "s|^${escaped_key}=.*|${key}=${escaped_value}|" "$file" > "$tmp_file"
    else
        cp "$file" "$tmp_file"
        printf '%s=%s\n' "$key" "$value" >> "$tmp_file"
    fi

    chmod --reference="$file" "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$file"
}

_read_env_value() {
    local key="$1" file="$2"
    [[ -f "$file" ]] || return 0
    grep -E "^${key}=" "$file" 2>/dev/null \
        | tail -1 | cut -d= -f2- | tr -d "\"'" || true
}

export -f load_env_file get_config_value require_config
export -f _get_file_perms _set_env_var _read_env_value

# ---------------------------------------------------------------------------
# Canonical compile-time fallbacks — sourced once here so every script that
# sources config.sh gets safe defaults under `set -u` even when .env is absent
# or these variables are not present in the loaded file.
#
# Rules:
#  • Use ${VAR:-default}: set only when unset or empty, never override a value
#    already exported (e.g. by the .env loader above or the calling environment).
#  • PROJECT_ROOT is resolved lazily via BASH_SOURCE so this block is safe to
#    source from any working directory.
# ---------------------------------------------------------------------------
_VW_CONFIG_PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

AGE_KEY_FILE="${AGE_KEY_FILE:-/etc/vaultwarden/age-key.txt}"
SECRETS_FILE="${SECRETS_FILE:-${_VW_CONFIG_PROJECT_ROOT}/secrets/secrets.yaml}"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${AGE_KEY_FILE}}"

export AGE_KEY_FILE SECRETS_FILE SOPS_AGE_KEY_FILE
unset _VW_CONFIG_PROJECT_ROOT

log_debug "Config library loaded"
