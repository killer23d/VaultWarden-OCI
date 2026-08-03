#!/usr/bin/env bash
# lib/config.sh — Environment and configuration loading helpers for VaultWarden-OCI.
#
# Provides:
#   Load    : load_env_file, load_project_environment
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

if [[ -z "${_VW_CALLER_OVERRIDES_CAPTURED:-}" ]]; then
    _VW_CALLER_PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-}"
    _VW_CALLER_DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
    _VW_CALLER_DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-}"
    _VW_CALLER_SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-}"
    _VW_CALLER_BACKUP_DIR="${BACKUP_DIR:-}"
    _VW_CALLER_TZ="${TZ:-}"
    _VW_CALLER_RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-}"
    _VW_CALLER_RCLONE_REMOTE_PATH="${RCLONE_REMOTE_PATH:-}"
    _VW_CALLER_RCLONE_CONFIG="${RCLONE_CONFIG:-}"
    _VW_CALLER_SECRETS_FILE="${SECRETS_FILE:-}"
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

load_env_file() {
    local env_file="${1:-}"

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

    # A blank SOPS_AGE_KEY_FILE in repo .env is intentional: it keeps operator
    # editable config portable. Do not pass that blank value through to SOPS;
    # resolve a concrete key path for the current caller instead.
    if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
        local _config_project_root _age_candidate
        _config_project_root="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
        for _age_candidate in \
            "${AGE_KEY_FILE:-/etc/vaultwarden/age-key.txt}" \
            "/etc/vaultwarden/age-key.txt" \
            "${_config_project_root}/secrets/keys/age-key.txt"; do
            [[ -z "$_age_candidate" ]] && continue
            if [[ -r "$_age_candidate" ]]; then
                SOPS_AGE_KEY_FILE="$_age_candidate"
                break
            fi
        done
        SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${AGE_KEY_FILE:-/etc/vaultwarden/age-key.txt}}"
        export SOPS_AGE_KEY_FILE
        log_debug "load_env_file: SOPS_AGE_KEY_FILE was blank; using ${SOPS_AGE_KEY_FILE}"
    fi

    # Keep direct env-file callers aligned with the split-permission secrets
    # layout when they intentionally load a specific file.
    if declare -F resolve_secrets_file >/dev/null 2>&1; then
        resolve_secrets_file
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

resolve_secrets_file() {
    local default_state_dir="${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}"
    local root="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local persistent="${PROJECT_STATE_DIR:-$default_state_dir}/secrets/secrets.yaml"
    local legacy="${root}/secrets/secrets.yaml"

    if [[ -f "$persistent" ]]; then
        SECRETS_FILE="$persistent"
    elif [[ -f "$legacy" ]]; then
        SECRETS_FILE="$legacy"
        log_warn "Using repository-local secrets file — migrate to ${persistent}"
    else
        SECRETS_FILE="$persistent"
    fi
    export SECRETS_FILE
}

load_project_environment() {
    local override_state="${_VW_CALLER_PROJECT_STATE_DIR:-}"
    local override_device="${_VW_CALLER_DATA_VOLUME_DEVICE:-}"
    local override_mount="${_VW_CALLER_DATA_VOLUME_MOUNT:-}"
    local override_key="${_VW_CALLER_SOPS_AGE_KEY_FILE:-}"
    local override_backup="${_VW_CALLER_BACKUP_DIR:-}"
    local override_tz="${_VW_CALLER_TZ:-}"
    local override_remote="${_VW_CALLER_RCLONE_REMOTE_NAME:-}"
    local override_remote_path="${_VW_CALLER_RCLONE_REMOTE_PATH:-}"
    local override_rclone_config="${_VW_CALLER_RCLONE_CONFIG:-}"
    local override_secrets="${_VW_CALLER_SECRETS_FILE:-}"

    local root="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local default_state_dir="${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}"
    local repo_env="${root}/.env"
    local installed_env="/etc/vaultwarden/vaultwarden.env"
    installed_env="${VW_CONFIG_INSTALLED_ENV_FILE:-$installed_env}"
    local bootstrap_state="$default_state_dir"

    local _read_project_state_dir
    _read_project_state_dir() {
        local file="$1"
        [[ -f "$file" && -r "$file" ]] || return 0
        awk -F= -v sq="'" '$1 == "PROJECT_STATE_DIR" {
            value = substr($0, index($0, "=") + 1)
            gsub("^[\"" sq "]|[\"" sq "]$", "", value)
            if (value != "") found = value
        }
        END { if (found != "") print found }' "$file"
    }

    if [[ -n "$override_state" ]]; then
        bootstrap_state="$override_state"
    else
        local repo_state installed_state
        repo_state="$(_read_project_state_dir "$repo_env")"
        installed_state="$(_read_project_state_dir "$installed_env")"
        if [[ -n "$repo_state" ]]; then
            bootstrap_state="$repo_state"
        elif [[ -n "$installed_state" ]]; then
            bootstrap_state="$installed_state"
        fi
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
        if _config_env_candidate_state "$repo_env"; then
            selected_env="$repo_env"
            log_warn "Using repository .env — migrate to ${persistent_env} for production use"
        else
            candidate_status=$?
            (( candidate_status == 1 )) && return 1
        fi
    fi

    if [[ -z "$selected_env" ]]; then
        log_error "No project environment found. Expected ${persistent_env}, ${repo_env}, or ${installed_env}."
        return 2
    fi

    load_env_file "$selected_env" || return 1

    [[ -n "$override_state" ]] && PROJECT_STATE_DIR="$override_state"
    [[ -n "$override_device" ]] && DATA_VOLUME_DEVICE="$override_device"
    [[ -n "$override_mount" ]] && DATA_VOLUME_MOUNT="$override_mount"
    [[ -n "$override_key" ]] && SOPS_AGE_KEY_FILE="$override_key"
    [[ -n "$override_backup" ]] && BACKUP_DIR="$override_backup"
    [[ -n "$override_tz" ]] && TZ="$override_tz"
    [[ -n "$override_remote" ]] && RCLONE_REMOTE_NAME="$override_remote"
    [[ -n "$override_remote_path" ]] && RCLONE_REMOTE_PATH="$override_remote_path"
    [[ -n "$override_rclone_config" ]] && RCLONE_CONFIG="$override_rclone_config"
    export PROJECT_STATE_DIR DATA_VOLUME_DEVICE DATA_VOLUME_MOUNT SOPS_AGE_KEY_FILE
    export BACKUP_DIR TZ RCLONE_REMOTE_NAME RCLONE_REMOTE_PATH RCLONE_CONFIG

    resolve_secrets_file
    if [[ -n "$override_secrets" ]]; then
        SECRETS_FILE="$override_secrets"
        export SECRETS_FILE
    fi
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

    # chown can clear special mode bits, so restore ownership before mode.
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

export -f load_env_file get_config_value require_config resolve_secrets_file load_project_environment
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
