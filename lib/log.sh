#!/usr/bin/env bash
# lib/log.sh — Logging subsystem for VaultWarden-OCI.
#
# Standalone; no dependencies on other lib files.
#
# Provides:
#   Colors      : COLOR_* variables (exported; available to sourcing scripts)
#   Level gate  : _log_level_weight, _LOG_CURRENT_WEIGHT, _should_log
#   Functions   : log_info, log_success, log_warn, log_error, log_debug,
#                 log_rollback, log_dry_run, log_hint, log_phase, spinner_start,
#                 spinner_stop, log_header, set_log_prefix, _get_timestamp
#
# Load order: source this file before any other lib file that calls log_*.
# init_common_lib() (in lib/common.sh) sets _VW_CALLING_SCRIPT to the
# entry-point script basename and resolves _LOG_CURRENT_WEIGHT from LOG_LEVEL.

[[ -n "${VW_LOG_LIB_LOADED:-}" ]] && return 0
readonly VW_LOG_LIB_LOADED=1

LOG_PREFIX=""
_VW_CALLING_SCRIPT=""
LOG_TIMESTAMP=true
LOG_COLORS=true
LOG_LEVEL="${LOG_LEVEL:-INFO}"
# LOG_PREFIX is set by init_common_lib() in lib/common.sh and may be read
# by sourcing scripts; export so subshells see the value.
export LOG_PREFIX

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
    COLOR_INVERT=$'\e[7m'
else
    COLOR_RED='' COLOR_BOLD_RED='' COLOR_GREEN='' COLOR_YELLOW=''
    # shellcheck disable=SC2034  # COLOR_CYAN is used by sourcing scripts
    COLOR_BLUE='' COLOR_MAGENTA='' COLOR_CYAN='' COLOR_RESET='' COLOR_BOLD=''
    COLOR_INVERT=''
fi
readonly COLOR_RED COLOR_BOLD_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_MAGENTA COLOR_CYAN COLOR_RESET COLOR_BOLD COLOR_INVERT

# Log level filtering for production environments.
# _LOG_CURRENT_WEIGHT is set once in init_common_lib().
_LOG_CURRENT_WEIGHT=1

_log_level_weight() {
    case "$1" in
        DEBUG) printf '0' ;;
        INFO)  printf '1' ;;
        WARN)  printf '2' ;;
        ERROR) printf '3' ;;
        *)     printf '1' ;;
    esac
}

_should_log() {
    (( $(_log_level_weight "$1") >= _LOG_CURRENT_WEIGHT ))
}

set_log_prefix() {
    LOG_PREFIX="$1"
}

_get_timestamp() {
    if [[ "$LOG_TIMESTAMP" != "true" ]]; then
        printf ''
        return
    fi
    if [[ -t 1 ]]; then
        date '+%H:%M:%S'
    else
        date '+%Y-%m-%dT%H:%M:%S%z'
    fi
}


_log_dry_prefix() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        if [[ "$LOG_COLORS" == "true" ]]; then
            printf '%s[DRY RUN]%s ' "${COLOR_BLUE}" "${COLOR_RESET}"
        else
            printf '[DRY RUN] '
        fi
    fi
}

log_hint() {
    _should_log "INFO" || return 0
    local ts tag prefix
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-log.sh}"; prefix="$(_log_dry_prefix)"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] HINT →%s %s%s\n' "${COLOR_BLUE}" "$ts" "$tag" "${COLOR_RESET}" "$prefix" "$*"
    else
        printf '[%s] [%s] HINT → %s%s\n' "$ts" "$tag" "$prefix" "$*"
    fi
}

log_phase() {
    local current="$1" total="$2" label="$3"
    local width=20 filled empty bar=""
    if [[ ! "$current" =~ ^[0-9]+$ || ! "$total" =~ ^[0-9]+$ || "$total" -le 0 ]]; then
        log_info "$label"
        return 0
    fi
    filled=$(( current * width / total ))
    (( filled > width )) && filled=$width
    empty=$(( width - filled ))
    if (( filled > 0 )); then bar+=$(printf '█%.0s' $(seq 1 "$filled")); fi
    if (( empty > 0 )); then bar+=$(printf '░%.0s' $(seq 1 "$empty")); fi
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '\n%s[%s/%s] [%s] %s%s\n' "${COLOR_BOLD}" "$current" "$total" "$bar" "$label" "${COLOR_RESET}"
    else
        printf '\n[%s/%s] [%s] %s\n' "$current" "$total" "$bar" "$label"
    fi
}

_spinner_pid=""
spinner_start() {
    [[ -t 1 ]] || return 0
    local msg="${1:-Working...}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local health_fd="${HEALTH_LOCK_FD:-}"
    (
        # The read-only health lock remains parent-owned. Keep this UI helper
        # from extending that secondary lock if the health process is killed.
        if [[ "$health_fd" =~ ^[0-9]+$ ]] && (( health_fd > 2 )); then
            { eval "exec ${health_fd}>&-"; } 2>/dev/null || true
        fi
        unset HEALTH_LOCK_FD

        # Re-evaluate TTY inside the subshell: the parent's COLOR_CYAN /
        # COLOR_RESET are exported with escape sequences that were set at
        # source-time.  If the subshell's stdout is redirected (e.g. the
        # caller later pipes output to a log file) those inherited values
        # would embed raw escape codes in the log.  Always derive colors
        # from the subshell's own stdout file descriptor.
        local _sp_cyan _sp_reset
        if [[ -t 1 ]]; then
            _sp_cyan=$'\e[0;36m'
            _sp_reset=$'\e[0m'
        else
            _sp_cyan=''
            _sp_reset=''
        fi
        local i=0
        while true; do
            printf '\r%s %s %s%s' "${_sp_cyan}" "${frames[$((i % 10))]}" "$msg" "${_sp_reset}"
            sleep 0.1
            # Use i=$(( i + 1 )) rather than (( i++ )) to avoid the
            # arithmetic exit-code trap under set -e: (( expr )) exits 1
            # when the expression evaluates to 0 (i.e. the very first
            # iteration), which can kill the background subshell even with
            # || true appended.
            i=$(( i + 1 ))
        done
    ) &
    _spinner_pid=$!
}

spinner_stop() {
    local success="${1:-true}"
    [[ -t 1 ]] || return 0
    if [[ -n "$_spinner_pid" ]]; then
        kill "$_spinner_pid" 2>/dev/null || true
        wait "$_spinner_pid" 2>/dev/null || true
        _spinner_pid=""
    fi
    if [[ "$success" == "true" ]]; then
        printf '\r%s✔ Done.%s%*s\n' "${COLOR_GREEN}" "${COLOR_RESET}" 20 ''
    else
        printf '\r%s✖ Failed.%s%*s\n' "${COLOR_BOLD_RED}" "${COLOR_RESET}" 20 ''
    fi
}

log_info() {
    _should_log "INFO" || return 0
    local ts tag prefix
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-log.sh}"; prefix="$(_log_dry_prefix)"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] INFO%s %s%s\n' "${COLOR_CYAN}" "$ts" "$tag" "${COLOR_RESET}" "$prefix" "$*"
    else
        printf '[%s] [%s] INFO %s%s\n' "$ts" "$tag" "$prefix" "$*"
    fi
}

log_success() {
    _should_log "INFO" || return 0
    local ts tag prefix
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-log.sh}"; prefix="$(_log_dry_prefix)"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] OK%s %s%s\n' "${COLOR_GREEN}" "$ts" "$tag" "${COLOR_RESET}" "$prefix" "$*"
    else
        printf '[%s] [%s] OK %s%s\n' "$ts" "$tag" "$prefix" "$*"
    fi
}

log_warn() {
    _should_log "WARN" || return 0
    local ts tag prefix
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-log.sh}"; prefix="$(_log_dry_prefix)"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] WARN%s %s%s\n' "${COLOR_YELLOW}" "$ts" "$tag" "${COLOR_RESET}" "$prefix" "$*" >&2
    else
        printf '[%s] [%s] WARN %s%s\n' "$ts" "$tag" "$prefix" "$*" >&2
    fi
}

log_error() {
    _should_log "ERROR" || return 0
    local ts tag prefix
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-log.sh}"; prefix="$(_log_dry_prefix)"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] ERROR%s %s%s\n' "${COLOR_BOLD_RED}" "$ts" "$tag" "${COLOR_RESET}" "$prefix" "$*" >&2
    else
        printf '[%s] [%s] ERROR %s%s\n' "$ts" "$tag" "$prefix" "$*" >&2
    fi
}

log_debug() {
    _should_log "DEBUG" || return 0
    local ts tag
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-log.sh}"
    printf '[%s] [%s] DEBUG %s\n' "$ts" "$tag" "$*" >&2
}

log_rollback() {
    local ts tag
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-log.sh}"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] ROLLBACK%s %s\n' "${COLOR_MAGENTA}" "$ts" "$tag" "${COLOR_RESET}" "$*" >&2
    else
        printf '[%s] [%s] ROLLBACK %s\n' "$ts" "$tag" "$*" >&2
    fi
}

log_dry_run() {
    local ts tag
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-log.sh}"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] [DRY RUN]%s %s\n' "${COLOR_BLUE}" "$ts" "$tag" "${COLOR_RESET}" "$*"
    else
        printf '[%s] [%s] [DRY RUN] %s\n' "$ts" "$tag" "$*"
    fi
}

log_header() {
    local message="$*"
    local len
    len=$(printf '%s' "$message" | wc -m 2>/dev/null | tr -d '[:space:]' || printf '%s' "${#message}")
    [[ "$len" =~ ^[0-9]+$ ]] || len=${#message}
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

export -f log_info log_success log_warn log_error log_debug log_header log_hint log_phase spinner_start spinner_stop set_log_prefix _should_log
export -f log_rollback log_dry_run
export -f _get_timestamp
export COLOR_RED COLOR_BOLD_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_MAGENTA COLOR_CYAN COLOR_RESET COLOR_BOLD COLOR_INVERT

log_debug "Log library loaded"
