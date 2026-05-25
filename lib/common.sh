#!/usr/bin/env bash
# lib/common.sh — Core utility functions for VaultWarden-OCI.
#
# Provides:
#   Privilege    : is_root, require_root, get_real_user, _maybe_sudo,
#                  auto_fix_critical_permissions
#   System       : has_command, require_commands, retry_with_backoff,
#                  _require_script
#   Filesystem   : ensure_dir, secure_file
#   Network/IO   : test_connectivity, test_http, download_file
#   Lifecycle    : register_cleanup, perform_cleanup, setup_error_trap,
#                  setup_cleanup_trap, safe_execute, init_common_lib
#   Architecture : HOST_ARCH, GITHUB_ARCH (exported by init_common_lib)
#
# Load order requirement:
#   lib/log.sh must be sourced before this file. Functions in this lib
#   call log_debug, log_warn, log_error internally. Sourcing common.sh
#   before log.sh will cause "command not found" errors at runtime.
#   lib/config.sh must be sourced before this file if load_env_file
#   or get_config_value are needed by the caller.
#
# Canonical caller source block:
#   source "${LIB_DIR}/log.sh"
#   source "${LIB_DIR}/config.sh"   # if needed
#   source "${LIB_DIR}/common.sh"
#   init_common_lib "$0"

[[ -n "${VAULTWARDEN_COMMON_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_COMMON_LIB_LOADED=1

# Sourced libraries do not change shell options; entry-point scripts own them.
# Call init_common_lib() after sourcing when you want the standard script setup.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$LIB_DIR/.." && pwd)"

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

# Best-effort remediation for common operational file permission drift.
# This is intentionally non-fatal and safe to call repeatedly.
auto_fix_critical_permissions() {
    local project_root="${1:-$PROJECT_ROOT}"
    local real_user real_group
    real_user=$(get_real_user 2>/dev/null || id -un)
    real_group=$(id -gn "$real_user" 2>/dev/null || id -gn)

    local env_file="${project_root}/.env"
    if [[ -f "$env_file" ]]; then
        chmod 600 "$env_file" 2>/dev/null || true
        chown "${real_user}:${real_group}" "$env_file" 2>/dev/null || true
    fi

    local age_key_file="${SOPS_AGE_KEY_FILE:-}"
    if [[ -z "$age_key_file" ]]; then
        age_key_file="/etc/vaultwarden/age-key.txt"
    fi
    if [[ -f "$age_key_file" ]]; then
        chmod 600 "$age_key_file" 2>/dev/null || true
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

    # Detect host architecture and map to Docker/GitHub platform strings.
    HOST_ARCH="$(uname -m)"
    case "$HOST_ARCH" in
        x86_64)        GITHUB_ARCH="linux/amd64" ;;
        aarch64|arm64) GITHUB_ARCH="linux/arm64" ;;
        *)             GITHUB_ARCH="linux/${HOST_ARCH}" ;;
    esac
    export HOST_ARCH GITHUB_ARCH

    log_debug "Common library initialized for: $script_name"
    log_debug "Project root: $PROJECT_ROOT"
    log_debug "Log level: $LOG_LEVEL"
}

export -f _require_script
export -f has_command require_commands retry_with_backoff is_root require_root get_real_user _maybe_sudo
export -f auto_fix_critical_permissions
export -f register_cleanup perform_cleanup
export -f ensure_dir secure_file test_connectivity test_http download_file
export -f setup_error_trap setup_cleanup_trap safe_execute
export -f init_common_lib

log_debug "Common library loaded"
