#!/usr/bin/env bash
# lib/log.sh — Terminal output, colour management, and log-level filtering
#              for VaultWarden-OCI.
# Provides:
#   log_info, log_success, log_warn, log_error, log_debug,
#   log_header, log_rollback, log_dry_run
#   set_log_prefix, _should_log, _get_timestamp
#   COLOR_* constants
# Dependencies: none
# Sourced by: lib/common.sh (facade); scripts may source directly for
#             lightweight use without loading the full common stack.

[[ -n "${VW_LOG_LIB_LOADED:-}" ]] && return 0
readonly VW_LOG_LIB_LOADED=1

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
    # shellcheck disable=SC2034  # backward-compatible global consumed by callers
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



export -f log_info log_success log_warn log_error log_debug log_header set_log_prefix _should_log
export -f log_rollback log_dry_run _get_timestamp
export COLOR_RED COLOR_BOLD_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_MAGENTA COLOR_CYAN COLOR_RESET COLOR_BOLD
