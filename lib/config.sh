#!/usr/bin/env bash
# lib/config.sh — Environment and configuration loading helpers for VaultWarden-OCI.
#
# Provides:
#   Load    : load_env_file, load_authoring_environment, load_project_environment
#   Query   : get_config_value, require_config
#   Helpers : _get_file_perms, _set_env_var, _read_env_value, resolve_secrets_file
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

# The appliance has one Compose project identity regardless of whether its
# Compose model is executed from the checkout or the installed /opt runtime.
# Reassert this after loading any env file so directory names and stale/custom
# COMPOSE_PROJECT_NAME entries cannot split one host into two Compose projects.
readonly _VW_CANONICAL_COMPOSE_PROJECT_NAME="vaultwarden-oci"
readonly _VW_CANONICAL_AGE_KEY_FILE="/etc/vaultwarden/age-key.txt"
COMPOSE_PROJECT_NAME="$_VW_CANONICAL_COMPOSE_PROJECT_NAME"
export COMPOSE_PROJECT_NAME

if [[ -z "${_VW_CALLER_OVERRIDES_CAPTURED:-}" ]]; then
    _VW_CALLER_PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-}"
    _VW_CALLER_DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
    _VW_CALLER_DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-}"
    _VW_CALLER_BACKUP_DIR="${BACKUP_DIR:-}"
    _VW_CALLER_TZ="${TZ:-}"
    _VW_CALLER_RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-}"
    _VW_CALLER_RCLONE_REMOTE_PATH="${RCLONE_REMOTE_PATH:-}"
    _VW_CALLER_RCLONE_CONFIG="${RCLONE_CONFIG:-}"
    _VW_CALLER_OVERRIDES_CAPTURED=1
fi

# Self-load log.sh if not already loaded so this lib can be sourced standalone.
_VW_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${VW_LOG_LIB_LOADED:-}" ]] || source "${_VW_CONFIG_LIB_DIR}/log.sh"
unset _VW_CONFIG_LIB_DIR

_get_file_perms() {
    stat -c '%a' "$1" 2>/dev/null \
        || stat -f '%OLp' "$1" 2>/dev/null \
        || printf 'unknown'
}

_config_env_candidate_state() {
    local env_file="$1" ancestor

    if [[ -f "$env_file" ]]; then
        if [[ -r "$env_file" ]]; then
            return 0
        fi
        log_error "Environment file is not readable: $env_file"
        (( EUID != 0 )) && log_hint "Re-run the command with sudo to read the installed configuration."
        return 1
    fi

    if [[ -e "$env_file" ]]; then
        log_error "Canonical environment path is not a regular file: $env_file"
        return 1
    fi

    ancestor="${env_file%/*}"
    [[ "$ancestor" == "$env_file" ]] && ancestor="."
    while [[ "$ancestor" != "/" && "$ancestor" != "." && ! -e "$ancestor" ]]; do
        ancestor="${ancestor%/*}"
        [[ -n "$ancestor" ]] || ancestor="/"
    done

    if [[ -d "$ancestor" && ! -x "$ancestor" ]]; then
        log_error "Canonical environment path is not accessible: $env_file"
        log_error "Directory is not searchable: $ancestor"
        (( EUID != 0 )) && log_hint "Re-run the command with sudo to read the installed configuration."
        return 1
    fi

    return 2
}

_validate_runtime_env_file() {
    local env_file="$1"
    local line key raw_value lineno=0 malformed=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        (( lineno++ )) || true
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" != *=* ]]; then
            log_error "Malformed runtime environment ${env_file}:${lineno}: expected KEY=value"
            malformed=true
            continue
        fi

        key="${line%%=*}"
        raw_value="${line#*=}"
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            log_error "Malformed runtime environment ${env_file}:${lineno}: invalid variable name '${key}'"
            malformed=true
            continue
        fi

        case "$key" in
            PATH|LD_PRELOAD|LD_LIBRARY_PATH|IFS|BASH_ENV|ENV|CDPATH|PS4)
                log_error "Malformed runtime environment ${env_file}:${lineno}: forbidden variable '${key}'"
                malformed=true
                continue
                ;;
        esac

        if [[ "$raw_value" == \"* && "$raw_value" != *\" ]] \
            || [[ "$raw_value" == \'* && "$raw_value" != *\' ]] \
            || [[ "$raw_value" != \"* && "$raw_value" == *\" ]] \
            || [[ "$raw_value" != \'* && "$raw_value" == *\' ]]; then
            log_error "Malformed runtime environment ${env_file}:${lineno}: unmatched quote for '${key}'"
            malformed=true
            continue
        fi

        # shellcheck disable=SC2016
        if [[ "$raw_value" == *'`'* || "$raw_value" == *'$('* ]]; then
            log_error "Malformed runtime environment ${env_file}:${lineno}: command-substitution syntax is not allowed for '${key}'"
            malformed=true
        fi
    done < "$env_file" || {
        log_error "Environment file could not be read: $env_file"
        return 1
    }

    if [[ "$malformed" == "true" ]]; then
        log_error "Runtime environment authority is invalid: $env_file"
        log_hint "Fix the runtime environment with: sudo make sync-env"
        return 1
    fi
    return 0
}

load_env_file() {
    local env_file="${1:-}"
    local mode="${2:-authoring}"

    if [[ -z "$env_file" ]]; then
        load_project_environment
        return $?
    fi

    if [[ ! -f "$env_file" ]]; then
        log_error "Environment file not found: $env_file"
        return 1
    fi

    if [[ ! -r "$env_file" ]]; then
        log_error "Environment file is not readable: $env_file"
        (( EUID != 0 )) && log_hint "Re-run the command with sudo to read the installed configuration."
        return 1
    fi

    if [[ "$mode" == "runtime" ]]; then
        _validate_runtime_env_file "$env_file" || return 1
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
    if ! while IFS= read -r line || [[ -n "$line" ]]; do
        (( lineno++ )) || true

        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" != *=* ]]; then
            [[ "$mode" == "runtime" ]] || malformed_lines+=("line ${lineno}: ${line}")
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
        # shellcheck disable=SC2016
        if [[ "$value" == *'`'* || "$value" == *'$('* ]]; then
            log_error "load_env_file: line ${lineno}: value for '${key}' contains" \
                      "shell command-substitution syntax (\`...\` or \$(...))" \
                      "— aborting load of '${env_file}'. Quote or escape the value."
            return 1
        fi
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
        # shellcheck disable=SC2163
        export "$key"

    done < "$env_file"; then
        log_error "Environment file could not be read: $env_file"
        return 1
    fi

    if (( ${#malformed_lines[@]} > 0 )); then
        log_warn "load_env_file: ${#malformed_lines[@]} malformed .env line(s) skipped from ${env_file}:"
        local malformed
        for malformed in "${malformed_lines[@]}"; do
            log_warn "  ${malformed}"
        done
        log_hint "Valid format: KEY=value or KEY=\"value with spaces\""
        log_hint "Common mistakes: spaces around '=', an 'export ' prefix, or invalid variable names."
    fi

    COMPOSE_PROJECT_NAME="$_VW_CANONICAL_COMPOSE_PROJECT_NAME"
    export COMPOSE_PROJECT_NAME

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

resolve_secrets_file() {
    local default_state_dir="${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}"
    SECRETS_FILE="${PROJECT_STATE_DIR:-$default_state_dir}/secrets/secrets.yaml"
    export SECRETS_FILE
}

_read_project_state_dir_from_env() {
    local file="$1"
    [[ -f "$file" && -r "$file" ]] || return 0
    awk -F= -v sq="'" '$1 == "PROJECT_STATE_DIR" {
        value = substr($0, index($0, "=") + 1)
        gsub("^[\"" sq "]|[\"" sq "]$", "", value)
        if (value != "") found = value
    }
    END { if (found != "") print found }' "$file"
}

load_authoring_environment() {
    local root="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local repo_env="${root}/.env"

    _config_env_candidate_state "$repo_env" || {
        local status=$?
        (( status == 2 )) && log_error "Authoring environment not found: $repo_env"
        return 1
    }
    load_env_file "$repo_env" authoring || return 1
    resolve_secrets_file
}

# Production/runtime authority is installed state only. The checkout .env is an
# authoring input consumed by env-edit.sh sync; it is never a production fallback.
load_project_environment() {
    local override_state="${_VW_CALLER_PROJECT_STATE_DIR:-}"
    local override_device="${_VW_CALLER_DATA_VOLUME_DEVICE:-}"
    local override_mount="${_VW_CALLER_DATA_VOLUME_MOUNT:-}"
    local override_backup="${_VW_CALLER_BACKUP_DIR:-}"
    local override_tz="${_VW_CALLER_TZ:-}"
    local override_remote="${_VW_CALLER_RCLONE_REMOTE_NAME:-}"
    local override_remote_path="${_VW_CALLER_RCLONE_REMOTE_PATH:-}"
    local override_rclone_config="${_VW_CALLER_RCLONE_CONFIG:-}"

    local default_state_dir="${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}"
    local installed_env="${VW_CONFIG_INSTALLED_ENV_FILE:-/etc/vaultwarden/vaultwarden.env}"
    local bootstrap_state="${override_state:-$default_state_dir}"
    local installed_state=""

    if _config_env_candidate_state "$installed_env"; then
        _validate_runtime_env_file "$installed_env" || return 1
        installed_state="$(_read_project_state_dir_from_env "$installed_env")"
        [[ -n "$override_state" ]] || bootstrap_state="${installed_state:-$bootstrap_state}"
    else
        local candidate_status=$?
        (( candidate_status == 1 )) && return 1
    fi

    PROJECT_STATE_DIR="$bootstrap_state"
    export PROJECT_STATE_DIR

    local persistent_env="${PROJECT_STATE_DIR}/config/install.env"
    local selected_env="" candidate_status
    if _config_env_candidate_state "$installed_env"; then
        selected_env="$installed_env"
    else
        candidate_status=$?
        (( candidate_status == 1 )) && return 1
    fi

    if [[ -z "$selected_env" ]]; then
        if _config_env_candidate_state "$persistent_env"; then
            selected_env="$persistent_env"
        else
            candidate_status=$?
            (( candidate_status == 1 )) && return 1
        fi
    fi

    if [[ -z "$selected_env" ]]; then
        log_error "Runtime environment authority is missing."
        log_error "Expected ${installed_env} or ${persistent_env}."
        log_hint "Run: sudo make sync-env"
        return 2
    fi

    load_env_file "$selected_env" runtime || return 1

    [[ -n "$override_state" ]] && PROJECT_STATE_DIR="$override_state"
    [[ -n "$override_device" ]] && DATA_VOLUME_DEVICE="$override_device"
    [[ -n "$override_mount" ]] && DATA_VOLUME_MOUNT="$override_mount"
    [[ -n "$override_backup" ]] && BACKUP_DIR="$override_backup"
    [[ -n "$override_tz" ]] && TZ="$override_tz"
    [[ -n "$override_remote" ]] && RCLONE_REMOTE_NAME="$override_remote"
    [[ -n "$override_remote_path" ]] && RCLONE_REMOTE_PATH="$override_remote_path"
    [[ -n "$override_rclone_config" ]] && RCLONE_CONFIG="$override_rclone_config"

    # Operational private-key custody is fixed; runtime environment data may not
    # redirect production decryption to a checkout or another implicit location.
    SOPS_AGE_KEY_FILE="$_VW_CANONICAL_AGE_KEY_FILE"
    AGE_KEY_FILE="$_VW_CANONICAL_AGE_KEY_FILE"
    export PROJECT_STATE_DIR DATA_VOLUME_DEVICE DATA_VOLUME_MOUNT SOPS_AGE_KEY_FILE AGE_KEY_FILE
    export BACKUP_DIR TZ RCLONE_REMOTE_NAME RCLONE_REMOTE_PATH RCLONE_CONFIG

    resolve_secrets_file
}

_set_env_var() (
    if (( $# != 3 )); then
        printf '_set_env_var: expected KEY VALUE FILE\n' >&2
        return 64
    fi

    local key="$1" value="$2" file="$3"
    local file_dir metadata mode uid gid
    local tmp_file=""

    if [[ ! -f "$file" ]]; then
        printf '_set_env_var: target is not an existing regular file: %s\n' "$file" >&2
        return 1
    fi

    if [[ "$file" == */* ]]; then
        file_dir="${file%/*}"
        [[ -n "$file_dir" ]] || file_dir="/"
    else
        file_dir="."
    fi

    _set_env_var_cleanup() {
        local rc=$?
        trap - EXIT INT HUP TERM
        if [[ -n "$tmp_file" && -e "$tmp_file" ]]; then
            rm -f -- "$tmp_file" || {
                (( rc != 0 )) || rc=1
            }
        fi
        exit "$rc"
    }
    trap _set_env_var_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 129' HUP
    trap 'exit 143' TERM

    if metadata="$(stat -c '%a:%u:%g' -- "$file" 2>/dev/null)"; then
        :
    elif metadata="$(stat -f '%Lp:%u:%g' "$file" 2>/dev/null)"; then
        :
    else
        return 1
    fi
    IFS=: read -r mode uid gid <<< "$metadata"
    [[ "$mode" =~ ^[0-7]+$ && "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] \
        || return 1

    umask 077
    tmp_file="$(mktemp "${file_dir}/.env.tmp.XXXXXXXXXX")" || return 1

    # Read key and value through the environment so awk receives backslashes
    # and punctuation as literal data instead of parsing them as -v escapes.
    if ! _VW_ENV_SET_KEY="$key" _VW_ENV_SET_VALUE="$value" awk '
        BEGIN {
            prefix = ENVIRON["_VW_ENV_SET_KEY"] "="
            replacement = prefix ENVIRON["_VW_ENV_SET_VALUE"]
        }
        index($0, prefix) == 1 {
            print replacement
            found = 1
            next
        }
        { print }
        END {
            if (!found) print replacement
        }
    ' < "$file" > "$tmp_file"; then
        return 1
    fi

    chown "${uid}:${gid}" "$tmp_file" || return 1
    chmod "$mode" "$tmp_file" || return 1

    mv -f -- "$tmp_file" "$file" || return 1
    tmp_file=""
)

_read_env_value() {
    local key="$1" file="$2"
    [[ -f "$file" ]] || return 0
    grep -E "^${key}=" "$file" 2>/dev/null \
        | tail -1 | cut -d= -f2- | tr -d "\"'" || true
}

export -f load_env_file load_authoring_environment load_project_environment
export -f get_config_value require_config resolve_secrets_file
export -f _get_file_perms _set_env_var _read_env_value

# ---------------------------------------------------------------------------
# Canonical compile-time fallbacks — sourced once here so every script that
# sources config.sh gets safe defaults under `set -u` even when .env is absent
# or these variables are not present in the loaded file.
# ---------------------------------------------------------------------------

AGE_KEY_FILE="${AGE_KEY_FILE:-/etc/vaultwarden/age-key.txt}"
SECRETS_FILE="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}}/secrets/secrets.yaml"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-}"

export AGE_KEY_FILE SECRETS_FILE SOPS_AGE_KEY_FILE

log_debug "Config library loaded"
