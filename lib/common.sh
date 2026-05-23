#!/usr/bin/env bash
# lib/common.sh - Core shared functions for VaultWarden-OCI-NG
#
# Function inventory highlights:
#   - _maybe_sudo()      — TTY-aware root escalation helper (moved from startup.sh)
#   - validate_domain()  — RFC 1035 length guard (253) + bare-IPv4 rejection
#   - validate_email()   — RFC 5321 length guard (254) + stricter regex

[[ -n "${VAULTWARDEN_COMMON_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_COMMON_LIB_LOADED=1

# Sourced libraries do not change shell options; entry-point scripts own them.
# Call init_common_lib() after sourcing when you want the standard script setup.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$LIB_DIR/.." && pwd)"

LOG_PREFIX=""
_VW_CALLING_SCRIPT=""
LOG_TIMESTAMP=true
LOG_COLORS=true
LOG_LEVEL="${LOG_LEVEL:-INFO}"

if [[ -t 1 ]]; then
    COLOR_RED=$'\e[0;31m'
    COLOR_BOLD_RED=$'\e[1;31m'
    COLOR_GREEN=$'\e[0;32m'
    COLOR_YELLOW=$'\e[0;33m'
    COLOR_BLUE=$'\e[0;34m'
    COLOR_MAGENTA=$'\e[0;35m'
    # shellcheck disable=SC2034  # COLOR_CYAN is used by sourcing scripts
    COLOR_CYAN=$'\e[0;36m'
    COLOR_RESET=$'\e[0m'
    COLOR_BOLD=$'\e[1m'
else
    COLOR_RED='' COLOR_BOLD_RED='' COLOR_GREEN='' COLOR_YELLOW=''
    # shellcheck disable=SC2034  # COLOR_CYAN is used by sourcing scripts
    COLOR_BLUE='' COLOR_MAGENTA='' COLOR_CYAN='' COLOR_RESET='' COLOR_BOLD=''
fi
readonly COLOR_RED COLOR_BOLD_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_MAGENTA COLOR_CYAN COLOR_RESET COLOR_BOLD

# Log level filtering for production environments.
# Static associative array maps level names to numeric weights;
# _LOG_CURRENT_WEIGHT is set once in init_common_lib() for O(1) comparison.
declare -gA _LOG_LEVEL_WEIGHT=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
_LOG_CURRENT_WEIGHT=1  # default INFO

_should_log() {
    (( ${_LOG_LEVEL_WEIGHT[$1]:-0} >= _LOG_CURRENT_WEIGHT ))
}

set_log_prefix() {
    LOG_PREFIX="$1"
}

_get_timestamp() {
    [[ "$LOG_TIMESTAMP" == "true" ]] && date '+%H:%M:%S' || printf ''
}

log_info() {
    _should_log "INFO" || return 0
    local ts tag
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-common.sh}"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] INFO%s %s\n' "${COLOR_CYAN}" "$ts" "$tag" "${COLOR_RESET}" "$*"
    else
        printf '[%s] [%s] INFO %s\n' "$ts" "$tag" "$*"
    fi
}

log_success() {
    _should_log "INFO" || return 0
    local ts tag
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-common.sh}"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] OK%s %s\n' "${COLOR_GREEN}" "$ts" "$tag" "${COLOR_RESET}" "$*"
    else
        printf '[%s] [%s] OK %s\n' "$ts" "$tag" "$*"
    fi
}

log_warn() {
    _should_log "WARN" || return 0
    local ts tag
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-common.sh}"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] WARN%s %s\n' "${COLOR_YELLOW}" "$ts" "$tag" "${COLOR_RESET}" "$*" >&2
    else
        printf '[%s] [%s] WARN %s\n' "$ts" "$tag" "$*" >&2
    fi
}

log_error() {
    _should_log "ERROR" || return 0
    local ts tag
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-common.sh}"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] ERROR%s %s\n' "${COLOR_BOLD_RED}" "$ts" "$tag" "${COLOR_RESET}" "$*" >&2
    else
        printf '[%s] [%s] ERROR %s\n' "$ts" "$tag" "$*" >&2
    fi
}

log_debug() {
    _should_log "DEBUG" || return 0
    local ts tag
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-common.sh}"
    printf '[%s] [%s] DEBUG %s\n' "$ts" "$tag" "$*" >&2
}

log_rollback() {
    local ts tag
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-common.sh}"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] ROLLBACK%s %s\n' "${COLOR_MAGENTA}" "$ts" "$tag" "${COLOR_RESET}" "$*" >&2
    else
        printf '[%s] [%s] ROLLBACK %s\n' "$ts" "$tag" "$*" >&2
    fi
}

log_dry_run() {
    local ts tag
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-common.sh}"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] [DRY RUN]%s %s\n' "${COLOR_BLUE}" "$ts" "$tag" "${COLOR_RESET}" "$*"
    else
        printf '[%s] [%s] [DRY RUN] %s\n' "$ts" "$tag" "$*"
    fi
}

log_header() {
    local message="$*"
    local len=${#message}
    local line
    line=$(printf '%*s' "$len" '' | tr ' ' '=')
    printf '\n'
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s%s%s\n' "${COLOR_BOLD}" "${line}" "${COLOR_RESET}"
        printf '%s%s%s\n' "${COLOR_BOLD}" "${message}" "${COLOR_RESET}"
        printf '%s%s%s\n' "${COLOR_BOLD}" "${line}" "${COLOR_RESET}"
    else
        printf '%s\n' "$line"
        printf '%s\n' "$message"
        printf '%s\n' "$line"
    fi
    printf '\n'
}


_ENV_FILE_SEARCH_PATHS=(
    "${PROJECT_ROOT}/.env"
    "/etc/vaultwarden/vaultwarden.env"
)

# Return the octal permission string for a file, portable across GNU and BSD stat.
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
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( lineno++ )) || true

        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" != *=* ]]; then
            log_warn "load_env_file: line ${lineno}: not a key=value pair — skipped"
            continue
        fi

        key="${line%%=*}"
        raw_value="${line#*=}"

        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            log_error "load_env_file: line ${lineno}: invalid variable name '${key}' — aborting"
            return 1
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

has_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1
}

_command_to_package_hint() {
    local cmd="$1"
    case "$cmd" in
        htpasswd) printf 'apache2-utils' ;;
        docker)   printf 'docker-ce (or docker.io)' ;;
        sops)     printf 'sops' ;;
        age)      printf 'age' ;;
        zstd)     printf 'zstd' ;;
        *)        printf '%s' "$cmd" ;;
    esac
}

_package_manager_hint() {
    if has_command apt-get; then
        printf 'sudo apt install'
    elif has_command dnf; then
        printf 'sudo dnf install'
    elif has_command yum; then
        printf 'sudo yum install'
    else
        printf 'Install required packages using your system package manager'
    fi
}

require_commands() {
    local missing=()
    local packages=()
    local cmd pkg

    for cmd in "$@"; do
        if ! has_command "$cmd"; then
            missing+=("$cmd")
            pkg=$(_command_to_package_hint "$cmd")
            packages+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        local installer
        installer=$(_package_manager_hint)
        log_info "Install hint: ${installer} ${packages[*]}"
        return 1
    fi

    return 0
}

retry_with_backoff() {
    local max_attempts="$1"
    local initial_delay="$2"
    shift 2
    local delay="$initial_delay"
    local i

    for ((i=1; i<=max_attempts; i++)); do
        if "$@"; then
            return 0
        fi

        if [[ $i -lt $max_attempts ]]; then
            log_warn "Attempt $i failed, retrying in ${delay}s..."
            sleep "$delay"
            delay=$(( delay * 2 ))
        fi
    done

    log_error "All $max_attempts attempts failed for command: $1"
    return 1
}

is_root() {
    [[ $EUID -eq 0 ]]
}

require_root() {
    if ! is_root; then
        log_error "This script must be run as root."
        log_error "Re-run with: sudo ${BASH_SOURCE[1]:-$0} ${*:-}"
        exit 1
    fi
}

get_real_user() {
    # Prefer SUDO_USER — set reliably by sudo regardless of shell nesting depth
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        printf '%s\n' "$SUDO_USER"
        return 0
    fi

    # logname resolves the login user even through sudo/su chains
    local login_user
    if login_user=$(logname 2>/dev/null) \
        && [[ -n "$login_user" && "$login_user" != "root" ]]; then
        printf '%s\n' "$login_user"
        return 0
    fi

    # $USER is often "root" in `sudo make` sub-shells — only trust it when non-root
    if [[ -n "${USER:-}" && "${USER}" != "root" ]]; then
        printf '%s\n' "$USER"
        return 0
    fi

    # Genuine root context (direct root login, sudo su -, etc.)
    local effective_user
    effective_user=$(id -un 2>/dev/null) || effective_user="root"
    log_warn "get_real_user: could not resolve a non-root user; using '${effective_user}'. If unexpected, verify sudo invocation context (use: sudo ./setup.sh, not sudo make setup)."
    printf '%s\n' "$effective_user"
}

# _maybe_sudo COMMAND [ARGS...]
# Run a command as root, with automatic privilege escalation when needed.
# - Already root: executes directly.
# - sudo available + interactive TTY: uses 'sudo' (may prompt for password).
# - sudo available + non-interactive (cron/systemd): uses 'sudo -n' (never prompts).
# - sudo not installed: falls back to direct execution and lets the OS
#   reject it with EPERM when the caller truly requires root.
_maybe_sudo() {
    if is_root; then
        "$@"
        return $?
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        "$@"
        return $?
    fi

    if [[ -t 0 ]]; then
        sudo "$@"
    else
        sudo -n "$@"
    fi
}


CLEANUP_ACTIONS_MAX_SIZE="${CLEANUP_ACTIONS_MAX_SIZE:-64}"
declare -a CLEANUP_ACTIONS=()

_CLEANUP_SEP=$'\x1f'

register_cleanup() {
    local _sep=$'\x1f'
    local serialised="" sep="" arg
    for arg in "$@"; do
        serialised+="${sep}${arg}"
        sep="$_sep"
    done

    local entry
    for entry in "${CLEANUP_ACTIONS[@]+${CLEANUP_ACTIONS[@]}}"; do
        if [[ "$entry" == "$serialised" ]]; then
            log_debug "register_cleanup: duplicate entry skipped: $serialised"
            return 0
        fi
    done

    if (( ${#CLEANUP_ACTIONS[@]} >= CLEANUP_ACTIONS_MAX_SIZE )); then
        log_warn "register_cleanup: CLEANUP_ACTIONS_MAX_SIZE (${CLEANUP_ACTIONS_MAX_SIZE}) reached; ignoring: $serialised"
        return 1
    fi

    CLEANUP_ACTIONS+=("$serialised")
    log_debug "register_cleanup: registered [${#CLEANUP_ACTIONS[@]}/${CLEANUP_ACTIONS_MAX_SIZE}]: $serialised"
}

perform_cleanup() {
    local idx entry
    log_debug "Running cleanup actions (${#CLEANUP_ACTIONS[@]} registered)"

    for (( idx = ${#CLEANUP_ACTIONS[@]} - 1; idx >= 0; idx-- )); do
        entry="${CLEANUP_ACTIONS[$idx]}"
        local _sep=$'\x1f'
        local action_args=()
        IFS="$_sep" read -r -a action_args <<< "$entry"
        if [[ ${#action_args[@]} -gt 0 ]]; then
            if ! "${action_args[@]}"; then
                log_warn "Cleanup action failed: ${action_args[*]}"
            fi
        fi
    done

    CLEANUP_ACTIONS=()
}


ensure_dir() {
    local dir="$1"
    local mode="${2:-750}"
    local owner="${3:-}"

    if [[ ! -d "$dir" ]]; then
        log_debug "Creating directory: $dir"
        if ! install -d -m "$mode" "$dir"; then
            log_error "Failed to create directory: $dir"
            return 1
        fi
    fi

    if [[ -n "$owner" ]]; then
        if ! chown "$owner" "$dir"; then
            log_error "Failed to set ownership on directory: $dir"
            return 1
        fi
    fi

    return 0
}

secure_file() {
    local file="$1"
    local mode="${2:-600}"
    local owner="${3:-}"
    local group="${4:-}"

    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        return 1
    fi
    if ! chmod "$mode" "$file"; then
        log_error "Failed to secure file: $file"
        return 1
    fi
    if [[ -n "$owner" ]]; then
        local chown_target="$owner"
        [[ -n "$group" ]] && chown_target="$owner:$group"
        if ! chown "$chown_target" "$file"; then
            log_error "Failed to set ownership on file: $file ($chown_target)"
            return 1
        fi
    fi
    log_debug "Secured file: $file (mode: $mode${owner:+, owner: $owner${group:+:$group}})"
    return 0
}


test_connectivity() {
    local host="${1:-1.1.1.1}"
    local timeout="${2:-5}"
    ping -c 1 -W "$timeout" "$host" >/dev/null 2>&1
}

test_http() {
    local url="$1"
    local timeout="${2:-10}"

    if has_command curl; then
        curl -sf --max-time "$timeout" "$url" >/dev/null 2>&1
    elif has_command wget; then
        wget -q --timeout="$timeout" --spider "$url" >/dev/null 2>&1
    else
        log_error "Neither curl nor wget available for HTTP testing"
        return 1
    fi
}

download_file() {
    local url="$1"
    local output_file="$2"
    local max_attempts="${3:-3}"

    if retry_with_backoff "$max_attempts" 2 curl -fsSL "$url" -o "$output_file"; then
        log_success "Downloaded: $url -> $output_file"
        return 0
    fi
    rm -f "$output_file" 2>/dev/null || true
    if retry_with_backoff "$max_attempts" 2 wget -q "$url" -O "$output_file"; then
        log_success "Downloaded: $url -> $output_file"
        return 0
    else
        rm -f "$output_file" 2>/dev/null || true
        log_error "Failed to download: $url"
        return 1
    fi
}


validate_email() {
    local email="$1"
    # RFC 5321: maximum total length is 254 characters.
    [[ ${#email} -le 254 ]] || return 1
    [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

validate_domain() {
    local domain="$1"
    domain=$(printf '%s' "$domain" | sed 's|https\?://||; s|/.*$||')
    # RFC 1035: maximum total length is 253 characters.
    [[ ${#domain} -le 253 ]] || return 1
    # Bare IPv4 addresses are rejected: production deployments require a proper
    # domain name so that Caddy can obtain a TLS certificate via ACME/HTTPS.
    [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 1
    [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

validate_ip() {
    local ip="$1"
    local -i octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( octet >= 0 && octet <= 255 )) || return 1
    done
    return 0
}

validate_url() {
    local url="$1"
    [[ "$url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]]
}


# NOTE: Do not call both setup_error_trap() and setup_cleanup_trap() in the
# same script. setup_cleanup_trap() registers ERR and will silently overwrite
# the trap set by setup_error_trap(). Use setup_cleanup_trap() exclusively
# when cleanup is also required on failure.
setup_error_trap() {
    trap 'log_error "Script failed at line $LINENO in $(basename -- "${BASH_SOURCE[0]}") with exit code $?"; exit 1' ERR
}

setup_cleanup_trap() {
    local cleanup_function="$1"
    # Also register for ERR so cleanup runs when the script fails
    # with a non-zero exit code, not only on normal exit or signal termination.
    # shellcheck disable=SC2064  # intentional: $cleanup_function expands at registration to capture the function name
    trap "$cleanup_function" EXIT HUP INT TERM ERR
}

safe_execute() {
    local description="$1"
    shift

    log_debug "Executing: $description"
    if "$@"; then
        log_debug "Success: $description"
        return 0
    else
        local exit_code=$?
        log_error "Failed: $description (exit code: $exit_code)"
        return $exit_code
    fi
}

# _require_script PATH
# Verify a utility script exists and is executable.
# Emits ERROR and exits 1 if missing; chmod +x if not executable.
_require_script() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        log_error "Required script not found: $path"
        log_error "Ensure the repository was cloned completely."
        exit 1
    fi
    [[ -x "$path" ]] || chmod +x "$path"
}

# _set_env_var KEY VALUE FILE
# Add or replace a KEY=VALUE line in an env file.
_set_env_var() {
    local key="$1" value="$2" file="$3"
    local escaped_key
    escaped_key=$(printf '%s' "$key" | sed 's/[]\/$*.^[]/\\&/g')
    if grep -q "^${escaped_key}=" "$file" 2>/dev/null; then
        local escaped_value
        escaped_value="${value//\\/\\\\}"
        escaped_value="${escaped_value//&/\\&}"
        escaped_value="${escaped_value//|/\\|}"
        sed -i "s|^${escaped_key}=.*|${key}=${escaped_value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# _read_env_value KEY FILE
# Read a KEY=VALUE from an env file, stripping surrounding quotes.
_read_env_value() {
    local key="$1" file="$2"
    [[ -f "$file" ]] || return 0
    grep -E "^${key}=" "$file" 2>/dev/null \
        | tail -1 | cut -d= -f2- | tr -d "\"'" || true
}

init_common_lib() {
    local script_name="$1"

    set -euo pipefail

    # Store the calling script's basename (with extension) for log tagging.
    _VW_CALLING_SCRIPT="$(basename -- "$script_name")"
    # Keep LOG_PREFIX for backward compatibility with any code that reads it.
    # shellcheck disable=SC2034  # exported for external backward compat
    LOG_PREFIX="$(basename -- "$script_name" .sh)"

    cd "$PROJECT_ROOT"

    # Resolve _LOG_CURRENT_WEIGHT once now that LOG_LEVEL is known.
    if [[ -n "${_LOG_LEVEL_WEIGHT[${LOG_LEVEL^^}]+_}" ]]; then
        _LOG_CURRENT_WEIGHT=${_LOG_LEVEL_WEIGHT[${LOG_LEVEL^^}]}
    else
        printf '[WARN] LOG_LEVEL="%s" is not recognised (valid: DEBUG INFO WARN ERROR) — defaulting to INFO\n' \
            "$LOG_LEVEL" >&2
        _LOG_CURRENT_WEIGHT=1
    fi

    log_debug "Common library initialized for: $script_name"
    log_debug "Project root: $PROJECT_ROOT"
    log_debug "Log level: $LOG_LEVEL"
}

export -f log_info log_success log_warn log_error log_debug log_header set_log_prefix _should_log
export -f log_rollback log_dry_run
export -f _require_script _set_env_var _read_env_value
export -f _get_timestamp _get_file_perms
export -f load_env_file get_config_value require_config
export -f has_command require_commands retry_with_backoff is_root require_root get_real_user _maybe_sudo
export -f register_cleanup perform_cleanup
export -f ensure_dir secure_file test_connectivity test_http download_file
export COLOR_RED COLOR_BOLD_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_MAGENTA COLOR_CYAN COLOR_RESET COLOR_BOLD
export -f validate_email validate_domain validate_port validate_ip validate_url
export -f setup_error_trap setup_cleanup_trap safe_execute
export -f init_common_lib

log_debug "Common library loaded"
