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
#
# Depends on / Load order:
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

# Enforce Bash 5.0+; the production host contract is Ubuntu 24.04 LTS Noble.
if (( BASH_VERSINFO[0] < 5 )); then
    echo "ERROR: Bash 5.0+ is required (found ${BASH_VERSION})." \
         "This project targets Ubuntu 24.04 LTS Noble." >&2
    exit 1
fi

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
    local i remaining
    local total_max_wait=0 projected_delay="$initial_delay"

    for ((i=1; i<max_attempts; i++)); do
        total_max_wait=$(( total_max_wait + projected_delay ))
        projected_delay=$(( projected_delay * 2 ))
    done

    for ((i=1; i<=max_attempts; i++)); do
        if "$@"; then
            return 0
        fi

        if [[ $i -lt $max_attempts ]]; then
            local attempts_left remaining_wait next_delay
            attempts_left=$(( max_attempts - i ))
            remaining_wait=0
            next_delay="$delay"
            for ((remaining=i; remaining<max_attempts; remaining++)); do
                remaining_wait=$(( remaining_wait + next_delay ))
                next_delay=$(( next_delay * 2 ))
            done

            log_warn "Attempt $i/${max_attempts} failed; ${attempts_left} retry(ies) left; sleeping ${delay}s (remaining max wait ${remaining_wait}s / total ${total_max_wait}s)."
            if [[ -t 1 ]]; then
                for ((remaining=delay; remaining>0; remaining--)); do
                    printf '\r%sRetrying in %2ss...%s' "${COLOR_YELLOW:-}" "$remaining" "${COLOR_RESET:-}"
                    sleep 1
                done
                printf '\r%*s\r' 32 ''
            else
                sleep "$delay"
            fi
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
        # Arguments are the invoking script's original command arguments.
        # They are rendered into an executable sudo remediation command; they
        # are not a place for custom diagnostic prose.
        local caller="${BASH_SOURCE[1]:-$0}" remediation arg
        printf -v remediation 'sudo %q' "$caller"
        for arg in "$@"; do
            printf -v remediation '%s %q' "$remediation" "$arg"
        done
        log_error "This script must be run as root."
        log_hint "Re-run with: ${remediation}"
        exit 1
    fi
}

press_enter_to_continue() {
    local msg="${1:- Press [Enter] to continue...}"
    local _dummy
    printf '\n'
    if [[ -t 1 ]]; then
        printf '%s%s%s\n' "${COLOR_INVERT:-}" "$msg" "${COLOR_RESET:-}"
    else
        printf '%s\n' "$msg"
    fi
    if [[ -t 0 ]]; then
        read -r _dummy || true
    fi
}

operator_attention() {
    local severity="${1:-info}" title="${2:-Attention}" level label color fd line
    if (( $# >= 2 )); then
        shift 2
    else
        shift "$#"
    fi

    case "${severity,,}" in
        error)
            level="ERROR"; label="ERROR"; color="${COLOR_BOLD_RED:-}"; fd=2 ;;
        warn|warning)
            level="WARN"; label="WARNING"; color="${COLOR_YELLOW:-}"; fd=2 ;;
        *)
            level="INFO"; label="NOTICE"; color="${COLOR_CYAN:-}"; fd=1 ;;
    esac

    _should_log "$level" || return 0
    if [[ "${LOG_COLORS:-true}" == "true" && -n "$color" ]]; then
        printf '\n%s[%s] %s%s\n' "$color" "$label" "$title" "${COLOR_RESET:-}" >&"$fd"
    else
        printf '\n[%s] %s\n' "$label" "$title" >&"$fd"
    fi
    for line in "$@"; do
        printf '  - %s\n' "$line" >&"$fd"
    done
}

operator_confirm_yes_no() {
    local prompt="$1" default="${2:-no}" timeout="${3:-0}" reply status prompt_text
    default="${default,,}"
    case "$default" in
        yes|no) ;;
        *)
            log_error "operator_confirm_yes_no: default must be 'yes' or 'no'"
            return 2
            ;;
    esac

    prompt_text="${prompt} [yes/no] (default: ${default}): "
    if [[ "${LOG_COLORS:-true}" == "true" && -t 2 ]]; then
        printf '%s%s%s' "${COLOR_BOLD:-}" "$prompt_text" "${COLOR_RESET:-}" >&2
    else
        printf '%s' "$prompt_text" >&2
    fi

    if [[ "$timeout" =~ ^[0-9]+([.][0-9]+)?$ && "$timeout" != "0" ]]; then
        if read -r -t "$timeout" reply; then
            :
        else
            status=$?
            [[ -t 2 ]] && printf '\n' >&2
            if (( status > 128 )); then
                log_warn "No confirmation received within ${timeout}s; failing closed."
            else
                log_warn "No confirmation received; failing closed."
            fi
            return 1
        fi
    else
        if ! read -r reply; then
            [[ -t 2 ]] && printf '\n' >&2
            log_warn "No confirmation received; failing closed."
            return 1
        fi
    fi

    [[ -z "$reply" ]] && reply="$default"
    case "${reply,,}" in
        yes) return 0 ;;
        no) return 1 ;;
        *)
            log_warn "Invalid response; please answer yes or no."
            return 1
            ;;
    esac
}

operator_next_steps() {
    local title="${1:-Next steps}" item
    if (( $# > 0 )); then
        shift
    fi

    _should_log "INFO" || return 0
    if [[ "${LOG_COLORS:-true}" == "true" && -n "${COLOR_BOLD:-}" ]]; then
        printf '\n%s%s%s\n' "${COLOR_BOLD:-}" "$title" "${COLOR_RESET:-}"
    else
        printf '\n%s\n' "$title"
    fi
    for item in "$@"; do
        printf '  - %s\n' "$item"
    done
}

# Best-effort remediation for common operational file permission drift.
# This is intentionally non-fatal and safe to call repeatedly.
_common_stat_mode() {
    if stat --version >/dev/null 2>&1; then stat -c '%a' "$1" 2>/dev/null; else stat -f '%OLp' "$1" 2>/dev/null; fi
}

_common_stat_owner() {
    if stat --version >/dev/null 2>&1; then stat -c '%U' "$1" 2>/dev/null; else stat -f '%Su' "$1" 2>/dev/null; fi
}

_common_stat_group() {
    if stat --version >/dev/null 2>&1; then stat -c '%G' "$1" 2>/dev/null; else stat -f '%Sg' "$1" 2>/dev/null; fi
}

_canonical_permission_path() {
    local path="$1"
    case "$path" in
        .env|.sops.yaml|secrets/*) printf '%s/%s' "$PROJECT_ROOT" "$path" ;;
        *) printf '%s' "$path" ;;
    esac
}

_operator_user_group() {
    local real_user real_group
    real_user=$(get_real_user 2>/dev/null || id -un)
    real_group=$(id -gn "$real_user" 2>/dev/null || id -gn)
    printf '%s:%s' "$real_user" "$real_group"
}

_is_operator_permission_path() {
    local path state_dir
    path="$(_canonical_permission_path "$1")"
    state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    case "$path" in
        "$PROJECT_ROOT/.env"|"$PROJECT_ROOT/secrets"|"$PROJECT_ROOT/secrets/keys/age-key.txt"|"$PROJECT_ROOT/.sops.yaml"|"$PROJECT_ROOT/secrets/secrets.yaml")
            return 0 ;;
        *) return 1 ;;
    esac
}

expected_owner_for_path() {
    local path state_dir
    path="$(_canonical_permission_path "$1")"
    state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    case "$path" in
        /etc/vaultwarden|/etc/vaultwarden/age-key.txt|/etc/vaultwarden/vaultwarden.env|/etc/vaultwarden/rclone.conf|\
        "$state_dir"/config|"$state_dir"/config/install.env|"$state_dir"/config/dr-manifest.env|\
        /run/vaultwarden-oci/secrets|/run/vaultwarden-oci/secrets/*|/run/vaultwarden-oci/managed-secrets|\
        "$state_dir"/secrets|"$state_dir"/secrets/secrets.yaml)
            printf 'root' ;;
        "$PROJECT_ROOT/.env"|"$PROJECT_ROOT/secrets"|"$PROJECT_ROOT/secrets/keys/age-key.txt"|"$PROJECT_ROOT/.sops.yaml"|"$PROJECT_ROOT/secrets/secrets.yaml")
            _operator_user_group | cut -d: -f1 ;;
        *) return 1 ;;
    esac
}

expected_group_for_path() {
    local path state_dir
    path="$(_canonical_permission_path "$1")"
    state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    case "$path" in
        /etc/vaultwarden|/etc/vaultwarden/age-key.txt|/etc/vaultwarden/vaultwarden.env|/etc/vaultwarden/rclone.conf|\
        "$state_dir"/config|"$state_dir"/config/install.env|"$state_dir"/config/dr-manifest.env|\
        /run/vaultwarden-oci/secrets|/run/vaultwarden-oci/secrets/*|/run/vaultwarden-oci/managed-secrets|\
        "$state_dir"/secrets|"$state_dir"/secrets/secrets.yaml)
            printf 'root' ;;
        "$PROJECT_ROOT/.env"|"$PROJECT_ROOT/secrets"|"$PROJECT_ROOT/secrets/keys/age-key.txt"|"$PROJECT_ROOT/.sops.yaml"|"$PROJECT_ROOT/secrets/secrets.yaml")
            _operator_user_group | cut -d: -f2 ;;
        *) return 1 ;;
    esac
}

expected_mode_for_path() {
    local path state_dir
    path="$(_canonical_permission_path "$1")"
    state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    case "$path" in
        /etc/vaultwarden) printf '700' ;;
        /run/vaultwarden-oci/secrets) printf '700' ;;
        "$PROJECT_ROOT/secrets") printf '700' ;;
        "$state_dir"/config) printf '700' ;;
        "$state_dir"/secrets) printf '700' ;;
        /run/vaultwarden-oci/secrets/*) printf '444' ;;
        /run/vaultwarden-oci/managed-secrets) printf '600' ;;
        "$PROJECT_ROOT/.sops.yaml") printf '644' ;;
        /etc/vaultwarden/age-key.txt|/etc/vaultwarden/vaultwarden.env|/etc/vaultwarden/rclone.conf|\
        "$state_dir"/config/install.env|"$state_dir"/config/dr-manifest.env|\
        "$PROJECT_ROOT/.env"|"$PROJECT_ROOT/secrets/keys/age-key.txt"|"$PROJECT_ROOT/secrets/secrets.yaml"|\
        "$state_dir"/secrets/secrets.yaml)
            printf '600' ;;
        *) return 1 ;;
    esac
}

fix_known_path_permissions() {
    local path owner group mode
    path="$(_canonical_permission_path "$1")"
    [[ -e "$path" ]] || return 0
    owner="$(expected_owner_for_path "$path")" || return 0
    group="$(expected_group_for_path "$path")" || return 0
    mode="$(expected_mode_for_path "$path")" || return 0
    if [[ "$(_common_stat_owner "$path"):$(_common_stat_group "$path")" != "${owner}:${group}" ]]; then
        if [[ "$owner" == "root" && -z "${SUDO_USER:-}" ]] && _is_operator_permission_path "$path"; then
            log_warn "Skipping ownership correction for operator-owned ${path}: non-root operator could not be resolved"
        else
            log_warn "Correcting ownership for ${path}: expected ${owner}:${group}"
            chown "${owner}:${group}" "$path" 2>/dev/null || true
        fi
    fi
    if [[ "$(_common_stat_mode "$path")" != "$mode" ]]; then
        log_warn "Correcting mode for ${path}: expected ${mode}"
        chmod "$mode" "$path" 2>/dev/null || true
    fi
}

assert_known_path_permissions() {
    local path owner group mode actual_owner actual_group actual_mode
    path="$(_canonical_permission_path "$1")"
    [[ -e "$path" ]] || return 0
    owner="$(expected_owner_for_path "$path")" || return 0
    group="$(expected_group_for_path "$path")" || return 0
    mode="$(expected_mode_for_path "$path")" || return 0
    actual_owner="$(_common_stat_owner "$path")"; actual_group="$(_common_stat_group "$path")"; actual_mode="$(_common_stat_mode "$path")"
    [[ "$actual_owner:$actual_group" == "$owner:$group" && "$actual_mode" == "$mode" ]]
}

auto_fix_critical_permissions() {
    local project_root="${1:-$PROJECT_ROOT}"

    # Repo .env is never chowned to root. It may be repaired back to the
    # real operator owner/group when that owner can be resolved; persistent
    # runtime env is installed under ${PROJECT_STATE_DIR}/config/install.env.

    local age_key_file="${SOPS_AGE_KEY_FILE:-}"
    if [[ -z "$age_key_file" ]]; then
        age_key_file="/etc/vaultwarden/age-key.txt"
    fi
    if [[ -f "$age_key_file" ]]; then
        fix_known_path_permissions "$age_key_file"
    fi

    for _vw_path in \
        /etc/vaultwarden \
        /etc/vaultwarden/vaultwarden.env \
        /etc/vaultwarden/rclone.conf \
        "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/config" \
        "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/config/install.env" \
        "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/config/dr-manifest.env" \
        "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/secrets" \
        "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/secrets/secrets.yaml" \
        "${project_root}/.env" \
        "${project_root}/secrets/keys/age-key.txt" \
        "${project_root}/.sops.yaml" \
        "${project_root}/secrets/secrets.yaml" \
        /run/vaultwarden-oci/managed-secrets \
        /run/vaultwarden-oci/secrets; do
        [[ -e "$_vw_path" ]] && fix_known_path_permissions "$_vw_path"
    done
    if [[ -d /run/vaultwarden-oci/secrets ]]; then
        while IFS= read -r -d '' _vw_secret_path; do
            fix_known_path_permissions "$_vw_secret_path"
        done < <(find /run/vaultwarden-oci/secrets -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
    fi

    local caddy_ep="${project_root}/caddy/entrypoint.sh"
    if [[ -f "$caddy_ep" && ! -x "$caddy_ep" ]]; then
        chmod +x "$caddy_ep" 2>/dev/null || true
        log_warn "auto_fix_critical_permissions: caddy/entrypoint.sh was not executable — corrected"
    fi
}

# _ensure_lock_file LOCKPATH
#
# Idempotent pre-flight for flock usage:
#   1. Creates the lock file and parent directory if they do not exist.
#   2. Sets ownership to root:vaultwarden and mode 0660.
#      - The 'vaultwarden' group is shared by the service user (ubuntu) and
#        root, allowing both systemd-launched services AND sudo invocations
#        to open the fd without AppArmor interference.
#      - setup-systemd.sh install creates this group and adds both users.
#   3. Returns 1 with a loud, actionable error — never silently fails.
#
# Security model:
#   Lock files are coordination primitives, not secrets. They hold no data.
#   Lock ownership is determined by flock(), never by pathname existence.
#   0660 root:vaultwarden in /run/lock/ (sticky drwxrwxrwt) means:
#     - Only vaultwarden group members can acquire/interfere with the lock
#     - Sticky bit prevents other users from deleting the file
#     - AppArmor allows root to open files it created (root:vaultwarden)
_ensure_lock_file() {
    local lockpath="$1"
    local lockdir
    lockdir="$(dirname "$lockpath")"

    # Create parent directory if required.
    if [[ ! -d "$lockdir" ]]; then
        mkdir -p "$lockdir" 2>/dev/null || {
            log_error "_ensure_lock_file: cannot create lock directory '${lockdir}'"
            log_error "  Fix: sudo mkdir -p ${lockdir} && sudo chmod 1777 ${lockdir}"
            return 1
        }
    fi

    # Create if it doesn't exist. Do not delete a lock file merely because it
    # appears old; flock state, not pathname existence, is the authority.
    if [[ ! -f "$lockpath" ]]; then
        # install atomically sets owner+mode in one syscall, avoiding a
        # window where the file exists but has wrong permissions.
        if ! install -m 0660 -o root -g vaultwarden /dev/null "$lockpath" 2>/dev/null; then
            # Fallback: 'vaultwarden' group may not exist yet (pre-setup).
            # Use root:root until setup-systemd.sh creates the shared group.
            touch "$lockpath" 2>/dev/null || {
                log_error "_ensure_lock_file: cannot create '${lockpath}'"
                log_error "  Check: ls -la ${lockdir}"
                log_error "  Fix:   sudo touch ${lockpath} && sudo chmod 0660 ${lockpath}"
                return 1
            }
            chown root:root "$lockpath" 2>/dev/null || true
            chmod 0660 "$lockpath" 2>/dev/null || true
            log_warn "_ensure_lock_file: 'vaultwarden' group not found — using root:root 0660 temporarily."
            log_warn "  Run 'sudo utilities/setup-systemd.sh install' to create the group and fix permanently."
            return 0
        fi
    fi

    # Ensure permissions are correct even on pre-existing files.
    chmod 0660 "$lockpath" 2>/dev/null || true
    chown root:vaultwarden "$lockpath" 2>/dev/null || true
}
# _fix_rclone_ownership
#
# When rclone is called under sudo, the rclone config file can become owned
# by root, making it unreadable by the real service user on subsequent runs.
# This function detects and silently corrects that ownership drift.
#
# Resolves the real user home path even when HOME=/root (sudo context).
# Silent no-op when ownership is already correct or the file does not exist.
_fix_rclone_ownership() {
    local real_user
    real_user=$(get_real_user 2>/dev/null || id -un)

    local rclone_conf
    if [[ -n "${SUDO_USER:-}" ]]; then
        # Under sudo, HOME is /root; resolve the actual user's home directory.
        local sudo_user_home
        sudo_user_home=$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6 || true)
        [[ -n "$sudo_user_home" ]] || return 0
        rclone_conf="${sudo_user_home}/.config/rclone/rclone.conf"
    else
        rclone_conf="${HOME}/.config/rclone/rclone.conf"
    fi

    if [[ ! -f "$rclone_conf" ]]; then
        return 0
    fi

    local owner
    owner=$(stat -c '%U' "$rclone_conf" 2>/dev/null || echo "")
    if [[ -n "$owner" && "$owner" != "$real_user" ]]; then
        log_warn "_fix_rclone_ownership: '${rclone_conf}' owned by '${owner}' — correcting to '${real_user}'"
        if chown "${real_user}:$(id -gn "$real_user" 2>/dev/null || id -gn)" "$rclone_conf" 2>/dev/null; then
            log_info "_fix_rclone_ownership: ownership corrected → ${rclone_conf}"
        else
            log_warn "_fix_rclone_ownership: chown failed — rclone.conf may still be root-owned"
        fi
    fi
}

# _run_rclone [ARGS...]
#
# Wrapper around rclone that drops privileges when running as root via sudo.
# Prevents the rclone config file from becoming root-owned after invocation.
# When not running under sudo, executes rclone directly (no overhead).
_run_rclone() {
    if [[ "$EUID" -eq 0 && -n "${SUDO_USER:-}" ]]; then
        log_warn "_run_rclone: called as root under sudo — dropping to '${SUDO_USER}' to preserve rclone.conf ownership"
        sudo -u "${SUDO_USER}" rclone "$@"
    else
        rclone "$@"
    fi
}

# _check_sudo_requirement CMD
#
# For read-only subcommands that do not need elevated privileges, emit a
# human-readable advisory when the script is invoked with sudo.  Does NOT
# abort — callers that legitimately need root are unaffected.
#
# Usage:
#   _check_sudo_requirement "${1:-}"   # at top of main(), before arg dispatch
#
# The advisory is suppressed for write/install subcommands (no-op).
_check_sudo_requirement() {
    local cmd="${1:-}"
    local readonly_cmds=("list" "help" "--help" "-h" "verify" "status")
    local ro
    for ro in "${readonly_cmds[@]}"; do
        if [[ "$cmd" == "$ro" ]]; then
            if [[ "$EUID" -eq 0 ]]; then
                log_warn "_check_sudo_requirement: subcommand '${cmd}' does not require root."
                log_warn "  Re-run without sudo: ./${0##*/} ${cmd}"
                log_warn "  Continuing — but file ownership may be affected."
            fi
            return 0
        fi
    done
}

project_version() {
    local project_root="${1:-$PROJECT_ROOT}"
    local version
    version=$(tr -d '[:space:]' < "${project_root}/VERSION" 2>/dev/null || echo "unknown")
    printf '%s\n' "${version:-unknown}"
}

print_project_version() {
    local label="${1:-VaultWarden-OCI}"
    local project_root="${2:-$PROJECT_ROOT}"
    printf '%s %s\n' "$label" "$(project_version "$project_root")"
}

get_real_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        printf '%s\n' "$SUDO_USER"
        return 0
    fi

    local login_user
    if login_user=$(logname 2>/dev/null) \
        && [[ -n "$login_user" && "$login_user" != "root" ]]; then
        printf '%s\n' "$login_user"
        return 0
    fi

    if [[ -n "${USER:-}" && "${USER}" != "root" ]]; then
        printf '%s\n' "$USER"
        return 0
    fi

    local effective_user
    effective_user=$(id -un 2>/dev/null) || effective_user="root"
    log_warn "get_real_user: could not resolve a non-root user; using '${effective_user}'. If unexpected, verify sudo invocation context (use: sudo ./setup.sh install --domain ... --email ...)."
    printf '%s\n' "$effective_user"
}

refuse_root_for_user_command() {
    local recommended="${1:-Run this command as your normal user, without sudo.}"
    if (( EUID == 0 )); then
        log_error "This command should not be run as root or with sudo."
        log_error "$recommended"
        log_error "Running it as root can create root-owned files in the checkout and cause later permission errors."
        exit 1
    fi
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

    if [[ "${VAULTWARDEN_NONINTERACTIVE_SUDO:-false}" == "true" ]]; then
        sudo -n "$@"
    elif [[ -t 0 ]]; then
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

# download_file URL OUTPUT_FILE [MAX_ATTEMPTS]
#
# Downloads URL to OUTPUT_FILE, wrapping the transfer in a spinner when
# spinner_start/spinner_stop are available (lib/log.sh loaded). Degrades
# gracefully — all download logic is unchanged when log.sh has not been
# sourced (e.g. unit-test contexts that source common.sh standalone).
#
# Try order: curl first, then wget.
download_file() {
    local url="$1"
    local output_file="$2"
    local max_attempts="${3:-3}"
    local _has_spinner=false
    declare -f spinner_start &>/dev/null && _has_spinner=true

    [[ "${_has_spinner}" == true ]] && spinner_start "Downloading $(basename "$output_file") with curl..."
    if retry_with_backoff "$max_attempts" 2 curl -fsSL "$url" -o "$output_file"; then
        [[ "${_has_spinner}" == true ]] && spinner_stop true
        log_success "Downloaded: $url -> $output_file"
        return 0
    fi
    [[ "${_has_spinner}" == true ]] && spinner_stop false
    rm -f "$output_file" 2>/dev/null || true

    [[ "${_has_spinner}" == true ]] && spinner_start "Downloading $(basename "$output_file") with wget..."
    if retry_with_backoff "$max_attempts" 2 wget -q "$url" -O "$output_file"; then
        [[ "${_has_spinner}" == true ]] && spinner_stop true
        log_success "Downloaded: $url -> $output_file"
        return 0
    fi
    [[ "${_has_spinner}" == true ]] && spinner_stop false
    rm -f "$output_file" 2>/dev/null || true
    log_error "Failed to download: $url"
    return 1
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

    _VW_CALLING_SCRIPT="$(basename -- "$script_name")"
    # Keep LOG_PREFIX for backward compatibility with any code that reads it.
    # shellcheck disable=SC2034  # exported for external backward compat
    LOG_PREFIX="$(basename -- "$script_name" .sh)"

    cd "$PROJECT_ROOT"

    # Resolve _LOG_CURRENT_WEIGHT once now that LOG_LEVEL is known.
    local _log_level_upper
    _log_level_upper="$(printf '%s' "$LOG_LEVEL" | tr '[:lower:]' '[:upper:]')"
    case "$_log_level_upper" in
        DEBUG|INFO|WARN|ERROR)
            _LOG_CURRENT_WEIGHT="$(_log_level_weight "$_log_level_upper")"
            ;;
        *)
        printf '[WARN] LOG_LEVEL="%s" is not recognised (valid: DEBUG INFO WARN ERROR) — defaulting to INFO\n' \
            "$LOG_LEVEL" >&2
        _LOG_CURRENT_WEIGHT=1
            ;;
    esac

    log_debug "Common library initialized for: $script_name"
    log_debug "Project root: $PROJECT_ROOT"
    log_debug "Log level: $LOG_LEVEL"
}


# wait_for_entropy [THRESHOLD [MAX_WAIT]]
#
# Wait until /proc/sys/kernel/random/entropy_avail reaches THRESHOLD bits.
# Prints a visible countdown every 5 seconds so the operator knows setup is not
# stuck. Non-fatal: after MAX_WAIT seconds it prints a warning and continues.
#
# Default THRESHOLD: ${ENTROPY_THRESHOLD:-200} (overridable in environment)
# Default MAX_WAIT:  ${ENTROPY_MAX_WAIT:-60}  (overridable in environment)
#
# Called from setup.sh before the secrets phase.  Also usable standalone.
wait_for_entropy() {
    local threshold="${1:-${ENTROPY_THRESHOLD:-200}}"
    local max_wait="${2:-${ENTROPY_MAX_WAIT:-60}}"
    local entropy_file="/proc/sys/kernel/random/entropy_avail"

    if [[ ! -f "$entropy_file" ]]; then
        log_warn "wait_for_entropy: $entropy_file not found — skipping entropy check (non-Linux?)"
        return 0
    fi

    local elapsed=0 interval=5 current
    current=$(cat "$entropy_file" 2>/dev/null || echo 9999)

    if (( current >= threshold )); then
        printf '\r\xe2\x9c\x94 Entropy ready: %d bits\n' "$current"
        return 0
    fi

    log_info "Waiting for sufficient kernel entropy (need ${threshold} bits, have ${current})..."

    while (( elapsed < max_wait )); do
        current=$(cat "$entropy_file" 2>/dev/null || echo 9999)
        if (( current >= threshold )); then
            printf '\r\xe2\x9c\x94 Entropy ready: %d bits                           \n' "$current"
            return 0
        fi
        printf '\r\xe2\x8f\xb3 Entropy: %d/%d bits \xe2\x80\x94 %ds elapsed...' \
            "$current" "$threshold" "$elapsed"
        sleep "$interval"
        (( elapsed += interval ))
    done

    current=$(cat "$entropy_file" 2>/dev/null || echo 0)
    if (( current >= threshold )); then
        printf '\r\xe2\x9c\x94 Entropy ready: %d bits                           \n' "$current"
        return 0
    fi

    printf '\n'
    log_warn "wait_for_entropy: entropy still low after ${max_wait}s (have ${current}/${threshold} bits)."
    log_warn "  Key generation may be slower. Install haveged or rng-tools to speed up: sudo apt install haveged"
    return 0   # Non-fatal — let setup continue.
}

export -f wait_for_entropy

export -f _require_script
export -f has_command require_commands retry_with_backoff is_root require_root press_enter_to_continue operator_attention operator_confirm_yes_no operator_next_steps
export -f project_version print_project_version get_real_user _maybe_sudo
export -f expected_owner_for_path expected_group_for_path expected_mode_for_path fix_known_path_permissions assert_known_path_permissions
export -f auto_fix_critical_permissions
export -f _ensure_lock_file _fix_rclone_ownership _run_rclone _check_sudo_requirement
export -f register_cleanup perform_cleanup
export -f ensure_dir secure_file test_connectivity test_http download_file
export -f setup_error_trap setup_cleanup_trap safe_execute
export -f init_common_lib

log_debug "Common library loaded"
