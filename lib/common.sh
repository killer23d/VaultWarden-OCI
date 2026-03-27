#!/usr/bin/env bash
# lib/common.sh - Core shared functions for VaultWarden-OCI-NG

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_COMMON_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_COMMON_LIB_LOADED=1
readonly LIB_COMMON_LOADED=1

set -euo pipefail

# --- Library Configuration ---
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$LIB_DIR/.." && pwd)"

# --- Enhanced Logging System ---
LOG_PREFIX=""
LOG_TIMESTAMP=true
LOG_COLORS=true
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Colors for output (if supported)
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    readonly COLOR_RED=$(tput setaf 1)
    readonly COLOR_GREEN=$(tput setaf 2)
    readonly COLOR_YELLOW=$(tput setaf 3)
    readonly COLOR_BLUE=$(tput setaf 4)
    readonly COLOR_CYAN=$(tput setaf 6)
    readonly COLOR_RESET=$(tput sgr0)
    readonly COLOR_BOLD=$(tput bold)
else
    readonly COLOR_RED=""
    readonly COLOR_GREEN=""
    readonly COLOR_YELLOW=""
    readonly COLOR_BLUE=""
    readonly COLOR_CYAN=""
    readonly COLOR_RESET=""
    readonly COLOR_BOLD=""
fi

# Log level filtering for production environments
_should_log() {
    local level="$1"
    local levels=("DEBUG" "INFO" "WARN" "ERROR")
    local current_index=-1
    local target_index=-1

    for i in "${!levels[@]}"; do
        [[ "${levels[i]}" == "$LOG_LEVEL" ]] && current_index=$i
        [[ "${levels[i]}" == "$level" ]] && target_index=$i
    done

    (( target_index >= current_index ))
}

set_log_prefix() {
    LOG_PREFIX="$1"
}

_get_timestamp() {
    [[ "$LOG_TIMESTAMP" == "true" ]] && date '+%H:%M:%S' || printf ''
}

log_info() {
    _should_log "INFO" || return 0
    local timestamp prefix_part
    timestamp=$(_get_timestamp)
    prefix_part="${LOG_PREFIX:+[$LOG_PREFIX] }"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [INFO]%s %s%s\n' \
            "${COLOR_BLUE}" "${timestamp}" "${COLOR_RESET}" \
            "${prefix_part}" "$*"
    else
        printf '[%s] [INFO] %s%s\n' "${timestamp}" "${prefix_part}" "$*"
    fi
}

log_success() {
    _should_log "INFO" || return 0
    local timestamp prefix_part
    timestamp=$(_get_timestamp)
    prefix_part="${LOG_PREFIX:+[$LOG_PREFIX] }"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [SUCCESS]%s %s%s\n' \
            "${COLOR_GREEN}" "${timestamp}" "${COLOR_RESET}" \
            "${prefix_part}" "$*"
    else
        printf '[%s] [SUCCESS] %s%s\n' "${timestamp}" "${prefix_part}" "$*"
    fi
}

log_warn() {
    _should_log "WARN" || return 0
    local timestamp prefix_part
    timestamp=$(_get_timestamp)
    prefix_part="${LOG_PREFIX:+[$LOG_PREFIX] }"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [WARN]%s %s%s\n' \
            "${COLOR_YELLOW}" "${timestamp}" "${COLOR_RESET}" \
            "${prefix_part}" "$*" >&2
    else
        printf '[%s] [WARN] %s%s\n' "${timestamp}" "${prefix_part}" "$*" >&2
    fi
}

log_error() {
    _should_log "ERROR" || return 0
    local timestamp prefix_part
    timestamp=$(_get_timestamp)
    prefix_part="${LOG_PREFIX:+[$LOG_PREFIX] }"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [ERROR]%s %s%s\n' \
            "${COLOR_RED}" "${timestamp}" "${COLOR_RESET}" \
            "${prefix_part}" "$*" >&2
    else
        printf '[%s] [ERROR] %s%s\n' "${timestamp}" "${prefix_part}" "$*" >&2
    fi
}

log_debug() {
    _should_log "DEBUG" || return 0
    local timestamp prefix_part
    timestamp=$(_get_timestamp)
    prefix_part="${LOG_PREFIX:+[$LOG_PREFIX] }"
    printf '[%s] [DEBUG] %s%s\n' "${timestamp}" "${prefix_part}" "$*" >&2
}

log_header() {
    local message="$*"
    local len=${#message}
    local line=""
    local i=0
    while (( i < len )); do
        line+="="
        (( i++ )) || true
    done
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

# --- Configuration Management ---

# Candidate paths searched (in order) when no explicit env_file is supplied.
# /etc/vaultwarden/vaultwarden.env is the production location written by
# setup-systemd.sh --install; .env covers interactive / development use.
_ENV_FILE_SEARCH_PATHS=(
    ".env"
    "/etc/vaultwarden/vaultwarden.env"
)

load_env_file() {
    local env_file="${1:-}"

    # When called without an argument (the common case), resolve the first
    # candidate path that actually exists on disk.
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

    if [[ $EUID -eq 0 ]]; then
        local file_perms
        file_perms=$(stat -c '%a' "$env_file" 2>/dev/null \
                     || stat -f '%OLp' "$env_file" 2>/dev/null \
                     || printf 'unknown')

        if [[ "$file_perms" == "unknown" ]]; then
            log_warn "load_env_file: cannot stat '$env_file' — skipping permission check"
        else
            local perm_int=$(( 8#${file_perms} ))
            if (( perm_int & 0177 )); then
                log_error "load_env_file: '$env_file' has insecure permissions (${file_perms})." \
                          " Run: chmod 600 '$env_file'"
                return 1
            fi
        fi
    else
        # Issue #42: Non-root — cannot enforce strict permissions, but warn if
        # the file is world-readable since it may contain secrets.
        local file_perms
        file_perms=$(stat -c '%a' "$env_file" 2>/dev/null \
                     || stat -f '%OLp' "$env_file" 2>/dev/null \
                     || printf 'unknown')

        if [[ "$file_perms" != "unknown" ]]; then
            local perm_int=$(( 8#${file_perms} ))
            if (( perm_int & 0004 )); then
                log_warn "load_env_file: '$env_file' is world-readable (${file_perms})." \
                         " Consider: chmod 640 '$env_file'"
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

        if [[ "$value" == *'`'* || "$value" == *'$('* ||
              "$value" == *';'* || "$value" == *'&'* ||
              "$value" == *'|'* || "$value" == *'<'* ||
              "$value" == *'>'* || "$value" == *'\\'* ]]; then
            log_error "load_env_file: line ${lineno}: value for '${key}' contains" \
                      "forbidden shell metacharacters — aborting load of '$env_file'"
            return 1
        fi

        export "${key}=${value}"

    done < "$env_file"

    log_debug "Environment loaded successfully from: $env_file"
    return 0
}

get_config_value() {
    local key="$1"
    local default="${2:-}"
    local value="${!key:-$default}"
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

# --- Command Availability ---
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

    log_error "All $max_attempts attempts failed for command: $*"
    return 1
}

is_root() {
    [[ $EUID -eq 0 ]]
}

require_root() {
    if ! is_root; then
        log_error "This script must be run as root."
        log_error "Re-run with: sudo $0 ${*:-}"
        exit 1
    fi
}

get_real_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        printf '%s\n' "$SUDO_USER"
        return 0
    fi

    if [[ -n "${USER:-}" ]]; then
        printf '%s\n' "$USER"
        return 0
    fi

    local effective_user
    effective_user=$(id -un 2>/dev/null) || effective_user="root"
    log_warn "get_real_user: SUDO_USER and USER are both unset; falling back to '${effective_user}' (from id -un). If this is unexpected, verify the invocation context."
    printf '%s\n' "$effective_user"
}

# --- Cleanup Registration ---

CLEANUP_ACTIONS_MAX_SIZE="${CLEANUP_ACTIONS_MAX_SIZE:-64}"
declare -a CLEANUP_ACTIONS=()

# Separator token used to store multiple arguments in a single CLEANUP_ACTIONS element.
# Unit-separator (0x1f) is safe: it cannot appear in normal shell arguments.
# Defined at module scope to document the protocol; inlined in each function so
# neither register_cleanup nor perform_cleanup requires an exported variable.
_CLEANUP_SEP=$'\x1f'

register_cleanup() {
    # Serialise all arguments with the unit-separator so eval is not needed.
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
        # Split on separator without eval — no shell injection risk.
        # The separator matches the one used in register_cleanup.
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

# --- File Operations ---

ensure_dir() {
    local dir="$1"
    local mode="${2:-755}"
    local owner="${3:-}"

    if [[ ! -d "$dir" ]]; then
        log_debug "Creating directory: $dir"
        if ! install -d -m "$mode" "$dir"; then
            log_error "Failed to create directory: $dir"
            return 1
        fi
    fi

    if ! chmod "$mode" "$dir"; then
        log_error "Failed to set permissions on directory: $dir"
        return 1
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

    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        return 1
    fi

    if ! chmod "$mode" "$file"; then
        log_error "Failed to secure file: $file"
        return 1
    fi

    log_debug "Secured file: $file (mode: $mode)"
    return 0
}

# --- Network Helpers ---

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
    elif retry_with_backoff "$max_attempts" 2 wget -q "$url" -O "$output_file"; then
        log_success "Downloaded: $url -> $output_file"
        return 0
    else
        log_error "Failed to download: $url"
        return 1
    fi
}

# --- Email Helpers ---

# shellcheck source=lib/email.sh
source "${LIB_DIR}/email.sh"

# ─────────────────────────────────────────────────────────────────────────────
# _resolve_rate_limit_dir  (BUG-EM7 FIX)
#
# Tries candidate directories in priority order and returns the first one
# that is (or can be) created AND is writable by the current user:
#   1. PROJECT_ROOT/.rate-limit   — preferred
#   2. XDG_CACHE_HOME/vaultwarden/rate-limit
#   3. HOME/.cache/vaultwarden/rate-limit
#   4. /tmp/vaultwarden-rate-limit-<euid>  (last resort)
# ─────────────────────────────────────────────────────────────────────────────
_resolve_rate_limit_dir() {
    local candidates=(
        "${PROJECT_ROOT}/.rate-limit"
        "${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/vaultwarden/rate-limit"
        "/tmp/vaultwarden-rate-limit-${EUID:-$(id -u)}"
    )

    local dir
    for dir in "${candidates[@]}"; do
        mkdir -p "$dir" 2>/dev/null || true
        chmod 700 "$dir" 2>/dev/null || true
        if [[ -d "$dir" ]] && touch "${dir}/.write_test_$$" 2>/dev/null; then
            rm -f "${dir}/.write_test_$$" 2>/dev/null || true
            printf '%s\n' "$dir"
            return 0
        fi
    done

    log_debug "_resolve_rate_limit_dir: no writable candidate found; rate-limiting disabled for this run"
    printf '/tmp\n'
    return 1
}

_rate_limit_check() {
    local subject="$1"
    local rate_limit_dir="$2"
    local last_email_file="$rate_limit_dir/.vw_last_email_$(printf '%s' "$subject" | sha256sum | cut -c1-16)"

    if [[ "$subject" != *"CRITICAL"* ]] && [[ -f "$last_email_file" ]]; then
        local last_time current_time
        last_time=$(cat "$last_email_file" 2>/dev/null || printf '0')
        # BUG-P4-4 FIX: date +%s is not POSIX but is supported by both GNU coreutils
        # and BSD date. It IS available on all supported platforms (Linux/macOS/Alpine).
        # The original comment claiming it was GNU-only was incorrect — no change needed
        # to the date call itself. Document this explicitly.
        current_time=$(date +%s)
        if (( current_time - last_time < 3600 )); then
            log_debug "Email rate limited for non-critical notification: $subject"
            return 1
        fi
    fi

    printf '%s\n' "$last_email_file"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _smtp_send <to> <subject> <body>  (BUG-EM6 FIX)
#
# Path A: SMTP_PASSWORD present → direct external relay (dev/test override)
# Path B: no SMTP_PASSWORD → route through Postfix sidecar at 127.0.0.1:587
# ─────────────────────────────────────────────────────────────────────────────
_smtp_send() {
    local to="$1"
    local subject="$2"
    local body="$3"

    [[ -z "$to" ]] && { log_error "_smtp_send: recipient (to) is empty"; return 1; }

    local _smtp_from_addr="${SMTP_FROM_EMAIL:-${SMTP_FROM:-${SMTP_USERNAME:-}}}"
    local _smtp_from_name="${SMTP_FROM_NAME:-VaultWarden}"

    local date_str
    date_str=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')

    local _msg
    _msg=$(
        printf 'From: "%s" <%s>\r\n' "$_smtp_from_name" "$_smtp_from_addr"
        printf 'To: %s\r\n'          "$to"
        printf 'Subject: %s\r\n'     "$subject"
        printf 'Date: %s\r\n'        "$date_str"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf 'Content-Transfer-Encoding: 7bit\r\n'
        printf '\r\n'
        while IFS= read -r line; do
            printf '%s\r\n' "$line"
        done <<< "$body"
        printf '\r\n'
    )

    # ── Path A: SMTP_PASSWORD present → direct external relay ────────────────────
    if [[ -n "${SMTP_PASSWORD:-}" ]]; then
        [[ -z "${SMTP_HOST:-}"     ]] && { log_error "_smtp_send: SMTP_HOST is not set";     return 1; }
        [[ -z "${SMTP_USERNAME:-}" ]] && { log_error "_smtp_send: SMTP_USERNAME is not set"; return 1; }

        local smtp_port="${SMTP_PORT:-587}"
        local smtp_security="${SMTP_SECURITY:-}"
        local smtp_url
        local smtp_tls_flags=()

        [[ -z "$smtp_security" ]] && { [[ "$smtp_port" == "465" ]] && smtp_security="tls" || smtp_security="starttls"; }

        case "${smtp_security,,}" in
            tls|ssl)    smtp_url="smtps://${SMTP_HOST}:${smtp_port}" ;;
            starttls)   smtp_url="smtp://${SMTP_HOST}:${smtp_port}"; smtp_tls_flags=(--ssl-reqd) ;;
            none|plain) smtp_url="smtp://${SMTP_HOST}:${smtp_port}" ;;
            *)
                log_error "_smtp_send: Unknown SMTP_SECURITY='${smtp_security}'. Valid: tls starttls none"
                return 1
                ;;
        esac

        printf '%s' "$_msg" | curl -s \
            --connect-timeout 15 \
            --max-time 30 \
            --retry 2 \
            --retry-delay 5 \
            "${smtp_tls_flags[@]}" \
            --url "$smtp_url" \
            --mail-from "$_smtp_from_addr" \
            --mail-rcpt "$to" \
            --user "${SMTP_USERNAME}:${SMTP_PASSWORD}" \
            --upload-file -
        return $?
    fi

    # ── Path B: No SMTP_PASSWORD → Postfix sidecar (normal production path) ───
    local _sidecar_addr="${VW_SMTP_HOST_PORT:-127.0.0.1:587}"
    local _sidecar_host _sidecar_port
    _sidecar_host="${_sidecar_addr%:*}"
    _sidecar_port="${_sidecar_addr##*:}"

    log_debug "_smtp_send: no SMTP_PASSWORD — routing through Postfix sidecar at ${_sidecar_addr}"

    printf '%s' "$_msg" | curl -s \
        --connect-timeout 15 \
        --max-time 30 \
        --retry 2 \
        --retry-delay 5 \
        --url "smtp://${_sidecar_host}:${_sidecar_port}" \
        --mail-from "$_smtp_from_addr" \
        --mail-rcpt "$to" \
        --upload-file -
    local _rc=$?
    if [[ $_rc -ne 0 ]]; then
        log_warn "_smtp_send: Postfix sidecar at ${_sidecar_addr} returned curl exit ${_rc}. Is the container running and port 127.0.0.1:587 bound?"
    fi
    return $_rc
}

# ─────────────────────────────────────────────────────────────────────────────
# send_email [TO] SUBJECT BODY
#
# TO is optional; defaults to ${ADMIN_EMAIL}.
# Tries providers in order: HTTP API → SMTP/Postfix sidecar → host MTA.
#
# Token resolution for HTTP API providers:
#   The canonical secrets key is 'email_api_token'. This matches what
#   ./edit-secrets.sh --rotate email_api_token writes into secrets.yaml.
#   Resolution order:
#     1. EMAIL_API_TOKEN env var (direct override, e.g. set in shell)
#     2. decrypt_secret email_api_token  (from secrets.yaml via SOPS/age)
# ─────────────────────────────────────────────────────────────────────────────
send_email() {
    local to subject body
    if [[ $# -ge 3 ]]; then
        to="$1"
        subject="${2:-VaultWarden Notification}"
        body="${3:-}"
    else
        to="${ADMIN_EMAIL:-}"
        subject="${1:-VaultWarden Notification}"
        body="${2:-}"
    fi

    local mode="${EMAIL_MODE:-auto}"
    local provider="${EMAIL_PROVIDER:-smtp}"

    if [[ "$provider" == "smtp" ]]; then
        mode="smtp"
    elif [[ "$provider" == "host" ]]; then
        mode="host"
    fi

    case "$mode" in
        auto|api|smtp|host) ;;
        *)
            log_error "Unknown EMAIL_MODE='${mode}'. Valid values: auto api smtp host"
            return 1
            ;;
    esac

    [[ "$subject" != "[VaultWarden]"* ]] && subject="[VaultWarden] ${subject}"

    local rate_limit_dir
    rate_limit_dir=$(_resolve_rate_limit_dir)

    local stamp_file
    if ! stamp_file=$(_rate_limit_check "$subject" "$rate_limit_dir"); then
        return 0
    fi

    local full_body
    full_body="${body}

---
Host:      $(hostname -f 2>/dev/null || hostname)
Timestamp: $(date -uIs)
Mode:      ${mode}${provider:+ / provider: ${provider}}"

    # ── Stage 1: HTTP API ────────────────────────────────────────────────────────────────
    if [[ "$mode" == "auto" || "$mode" == "api" ]]; then
        if [[ -z "${_EMAIL_DRIVERS[$provider]:-}" ]]; then
            log_error "Unknown EMAIL_PROVIDER='${provider}'"
            log_info  "Valid providers: ${!_EMAIL_DRIVERS[*]} smtp host"
            [[ "$mode" == "api" ]] && return 1
        else
            local driver_fn="_email_driver_${provider}"
            local _api_token="${EMAIL_API_TOKEN:-}"
            # Canonical secrets key is 'email_api_token'.
            # edit-secrets.sh --rotate email_api_token writes under this exact key.
            if [[ -z "${_api_token}" ]] && declare -f decrypt_secret &>/dev/null; then
                _api_token="$(decrypt_secret email_api_token 2>/dev/null || true)"
            fi
            if [[ -z "${_api_token}" ]]; then
                if [[ "$mode" == "api" ]]; then
                    log_error "EMAIL_MODE=api but EMAIL_API_TOKEN is empty — cannot send. Run: ./edit-secrets.sh --rotate email_api_token"
                    return 1
                fi
                log_warn "EMAIL_PROVIDER=${provider} set but EMAIL_API_TOKEN is empty — falling back to SMTP. Run: ./edit-secrets.sh --rotate email_api_token"
            elif EMAIL_API_TOKEN="${_api_token}" "$driver_fn" "$subject" "$full_body"; then
                log_success "Email sent via ${provider} API: ${subject}"
                date +%s > "$stamp_file" 2>/dev/null || true
                return 0
            else
                if [[ "$mode" == "api" ]]; then
                    log_error "EMAIL_MODE=api: ${provider} API failed — no fallback configured"
                    return 1
                fi
                log_warn "${provider} API failed — falling back to SMTP relay"
            fi
        fi
    fi

    # ── Stage 2: SMTP relay (Postfix sidecar) ───────────────────────────────────
    if [[ "$mode" == "auto" || "$mode" == "smtp" ]]; then
        if _smtp_send "$to" "$subject" "$full_body"; then
            log_success "Email sent via SMTP relay (${SMTP_HOST:-unconfigured}:${SMTP_PORT:-587}): ${subject}"
            date +%s > "$stamp_file" 2>/dev/null || true
            return 0
        fi
        if [[ "$mode" == "smtp" ]]; then
            log_error "EMAIL_MODE=smtp: SMTP relay failed — no fallback configured"
            return 1
        fi
        log_warn "SMTP relay failed — falling back to host MTA"
    fi

    # ── Stage 3: Host MTA ────────────────────────────────────────────────────────────
    if [[ "$mode" == "auto" || "$mode" == "host" ]]; then
        if command -v mail &>/dev/null; then
            if printf '%s' "$full_body" | mail -s "$subject" "$to" 2>/dev/null; then
                log_success "Email sent via host MTA: ${subject}"
                date +%s > "$stamp_file" 2>/dev/null || true
                return 0
            fi
        fi
        if [[ "$mode" == "host" ]]; then
            log_error "EMAIL_MODE=host: host MTA failed or not available — no fallback configured"
            return 1
        fi
    fi

    log_error "All email delivery methods failed (mode=${mode}, provider=${provider}, subject=${subject})"
    return 1
}

send_notification_email() {
    send_email "$1" "$2"
}

# --- Validation Helpers ---

validate_email() {
    local email="$1"
    [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]
}

validate_domain() {
    local domain="$1"
    domain=$(printf '%s' "$domain" | sed 's|https\?://||; s|/.*$||')
    [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
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

# --- Enhanced Error Handling ---

setup_error_trap() {
    trap 'log_error "Script failed at line $LINENO in $(basename -- "${BASH_SOURCE[0]}") with exit code $?"; exit 1' ERR
}

setup_cleanup_trap() {
    local cleanup_function="$1"
    trap "$cleanup_function" EXIT HUP INT TERM
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

# --- Library Initialization ---

init_common_lib() {
    local script_name="$1"

    set -euo pipefail

    # Warn if ADMIN_TOKEN is set but is not a bcrypt hash (must start with $2y$).
    # A plaintext token is a security risk; Vaultwarden requires bcrypt.
    if [[ -n "${ADMIN_TOKEN:-}" && "${ADMIN_TOKEN}" != '$2y$'* ]]; then
        echo "ERROR: ADMIN_TOKEN is set but does not appear to be a bcrypt hash (expected prefix: \$2y\$)." >&2
        echo "       Hash your admin token with: echo -n 'yourpassword' | argon2 ... or use setup-secrets.sh" >&2
        exit 1
    fi

    set_log_prefix "$(basename -- "$script_name" .sh)"

    cd "$PROJECT_ROOT"

    log_debug "Common library initialized for: $script_name"
    log_debug "Project root: $PROJECT_ROOT"
    log_debug "Log level: $LOG_LEVEL"
}

# --- Export Functions ---
export -f log_info log_success log_warn log_error log_debug log_header set_log_prefix _should_log
export -f load_env_file get_config_value require_config
export -f has_command require_commands retry_with_backoff is_root require_root get_real_user
export -f register_cleanup perform_cleanup
export -f ensure_dir secure_file test_connectivity test_http download_file
export -f _resolve_rate_limit_dir _rate_limit_check send_email send_notification_email _smtp_send
export -f validate_email validate_domain validate_port validate_ip validate_url
export -f setup_error_trap setup_cleanup_trap safe_execute
export -f init_common_lib

log_debug "Common library loaded (email mode: ${EMAIL_MODE:-auto}, provider: ${EMAIL_PROVIDER:-smtp})"
