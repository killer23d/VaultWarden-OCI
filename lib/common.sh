#!/usr/bin/env bash
# lib/common.sh - Core shared functions for VaultWarden-OCI-NG
#
# All library functions use 'return' with exit codes, never 'exit'
#
# PATCHED BUGS (2026-03-06):
#   BUG-C1 [MEDIUM] _send_email_via_postfix/_send_email_via_mailutils(): rate-limit
#                   timestamp written BEFORE mktemp — on mktemp failure the counter
#                   is bumped and the next hour of notifications is silently dropped.
#                   Fixed: mktemp first; stamp written only after temp file succeeds.
#   BUG-C2 [LOW]    get_real_user(): empty SUDO_USER + empty USER returns "",
#                   causing downstream chown '' to silently chown to root.
#                   Fixed: falls back to `id -un`, then literal 'root'.
#   BUG-C3 [LOW]    log_header(): printf '=%.0s' $(seq ...) uses seq(1) which is
#                   absent on Alpine/BusyBox. Replaced with a pure-bash while loop.
#
# MODERNIZATION (2026-03-08):
#   EMAIL [MAJOR]   Replaced postfix-container email delivery with a three-stage
#                   provider-driver system (API -> SMTP relay -> host MTA).
#                   All provider drivers live in lib/email.sh.
#                   send_notification_email() is kept as a backward-compat shim.
#                   Removed: _send_email_via_postfix, _send_email_via_mailutils,
#                            _get_postfix_smtp_target_for_fail2ban

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_COMMON_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_COMMON_LIB_LOADED=1

# COMPATIBILITY: Set the flag that lib/security.sh checks before loading.
readonly LIB_COMMON_LOADED=1

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
    [[ "$LOG_TIMESTAMP" == "true" ]] && date '+%H:%M:%S' || echo ""
}

log_info() {
    _should_log "INFO" || return 0
    local timestamp prefix_part
    timestamp=$(_get_timestamp)
    prefix_part="${LOG_PREFIX:+[$LOG_PREFIX] }"
    if [[ "$LOG_COLORS" == "true" ]]; then
        echo "${COLOR_BLUE}[${timestamp}] [INFO]${COLOR_RESET} ${prefix_part}$*"
    else
        echo "[${timestamp}] [INFO] ${prefix_part}$*"
    fi
}

log_success() {
    _should_log "INFO" || return 0
    local timestamp prefix_part
    timestamp=$(_get_timestamp)
    prefix_part="${LOG_PREFIX:+[$LOG_PREFIX] }"
    if [[ "$LOG_COLORS" == "true" ]]; then
        echo "${COLOR_GREEN}[${timestamp}] [SUCCESS]${COLOR_RESET} ${prefix_part}$*"
    else
        echo "[${timestamp}] [SUCCESS] ${prefix_part}$*"
    fi
}

log_warn() {
    _should_log "WARN" || return 0
    local timestamp prefix_part
    timestamp=$(_get_timestamp)
    prefix_part="${LOG_PREFIX:+[$LOG_PREFIX] }"
    if [[ "$LOG_COLORS" == "true" ]]; then
        echo "${COLOR_YELLOW}[${timestamp}] [WARN]${COLOR_RESET} ${prefix_part}$*" >&2
    else
        echo "[${timestamp}] [WARN] ${prefix_part}$*" >&2
    fi
}

log_error() {
    _should_log "ERROR" || return 0
    local timestamp prefix_part
    timestamp=$(_get_timestamp)
    prefix_part="${LOG_PREFIX:+[$LOG_PREFIX] }"
    if [[ "$LOG_COLORS" == "true" ]]; then
        echo "${COLOR_RED}[${timestamp}] [ERROR]${COLOR_RESET} ${prefix_part}$*" >&2
    else
        echo "[${timestamp}] [ERROR] ${prefix_part}$*" >&2
    fi
}

log_debug() {
    _should_log "DEBUG" || return 0
    local timestamp prefix_part
    timestamp=$(_get_timestamp)
    prefix_part="${LOG_PREFIX:+[$LOG_PREFIX] }"
    echo "[${timestamp}] [DEBUG] ${prefix_part}$*" >&2
}

# BUG-C3 FIX: replaced `printf '=%.0s' $(seq 1 N)` with a pure-bash while
# loop. seq(1) is absent on Alpine/BusyBox; the while loop has no external
# dependency and runs on every POSIX-compatible bash.
log_header() {
    local message="$*"
    local len=${#message}
    local line=""
    local i=0
    while (( i < len )); do
        line+="="
        (( i++ )) || true
    done
    echo ""
    if [[ "$LOG_COLORS" == "true" ]]; then
        echo "${COLOR_BOLD}${line}${COLOR_RESET}"
        echo "${COLOR_BOLD}${message}${COLOR_RESET}"
        echo "${COLOR_BOLD}${line}${COLOR_RESET}"
    else
        echo "$line"
        echo "$message"
        echo "$line"
    fi
    echo ""
}

# --- Configuration Management ---

load_env_file() {
    local env_file="${1:-.env}"

    if [[ ! -f "$env_file" ]]; then
        log_error "Environment file not found: $env_file"
        return 1
    fi

    log_debug "Loading environment from: $env_file"

    set -a
    source "$env_file" || {
        log_error "Failed to source environment file: $env_file"
        set +a
        return 1
    }
    set +a

    log_debug "Environment loaded successfully"
    return 0
}

get_config_value() {
    local key="$1"
    local default="${2:-}"
    local value="${!key:-$default}"
    echo "$value"
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
        htpasswd) echo "apache2-utils" ;;
        docker) echo "docker-ce (or docker.io)" ;;
        sops) echo "sops" ;;
        age) echo "age" ;;
        zstd) echo "zstd" ;;
        *) echo "$cmd" ;;
    esac
}

_package_manager_hint() {
    if has_command apt-get; then
        echo "sudo apt install"
    elif has_command dnf; then
        echo "sudo dnf install"
    elif has_command yum; then
        echo "sudo yum install"
    else
        echo "Install required packages using your system package manager"
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
    local command=("${@:3}")
    local delay="$initial_delay"
    local i

    for ((i=1; i<=max_attempts; i++)); do
        if "${command[@]}"; then
            return 0
        fi

        if [[ $i -lt $max_attempts ]]; then
            log_warn "Attempt $i failed, retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done

    log_error "All $max_attempts attempts failed for command: ${command[*]}"
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

# BUG-C2 FIX: when both SUDO_USER and USER are unset (non-interactive daemon
# context), the function previously returned an empty string. Downstream
# callers like secure_secrets_file() pass the result to chown, so an empty
# string caused `chown :` to silently transfer ownership to root.
#
# Fallback chain: SUDO_USER -> USER -> id -un -> 'root'
get_real_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "$SUDO_USER"
    elif [[ -n "${USER:-}" ]]; then
        echo "$USER"
    else
        local effective_user
        effective_user=$(id -un 2>/dev/null) || effective_user="root"
        echo "$effective_user"
    fi
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

# Load provider-specific email drivers (MailerSend, SendGrid, Mailgun, Postmark, Resend)
# shellcheck source=lib/email.sh
source "${LIB_DIR}/email.sh"

# _rate_limit_check SUBJECT RATE_LIMIT_DIR
#
# Returns 0 and prints the stamp-file path when the message may be sent.
# Returns 1 (silent drop) when the non-critical rate limit is active.
#
# BUG-C1 NOTE: callers must create their temp body file BEFORE calling this
# function, and write the stamp ONLY after a successful send.
_rate_limit_check() {
    local subject="$1"
    local rate_limit_dir="$2"
    local last_email_file="$rate_limit_dir/.vw_last_email_$(printf '%s' "$subject" | md5sum | cut -d' ' -f1)"

    if [[ "$subject" != *"CRITICAL"* ]] && [[ -f "$last_email_file" ]]; then
        local last_time current_time
        last_time=$(cat "$last_email_file" 2>/dev/null || echo 0)
        current_time=$(date +%s)
        if (( current_time - last_time < 3600 )); then
            log_debug "Email rate limited for non-critical notification: $subject"
            return 1
        fi
    fi

    echo "$last_email_file"
    return 0
}

# _smtp_send SUBJECT BODY
#
# Provider-agnostic SMTP relay delivery via curl.
# Builds a proper RFC 5322 message — required by all standards-compliant MTAs.
# Missing headers cause rejection or body-as-headers corruption.
#
# Change SMTP_HOST/PORT/USERNAME/PASSWORD in .env to switch providers;
# this function never needs to change.
#
# Port 465 = implicit TLS (smtps://)
# Port 587 = explicit TLS via STARTTLS (smtp:// + --ssl-reqd)
_smtp_send() {
    local subject="$1" body="$2"

    if [[ -z "${SMTP_HOST:-}" || -z "${SMTP_USERNAME:-}" || -z "${SMTP_PASSWORD:-}" ]]; then
        log_debug "SMTP relay not configured (SMTP_HOST/USERNAME/PASSWORD missing) — skipping"
        return 1
    fi

    local smtp_port="${SMTP_PORT:-465}"
    local smtp_url
    if [[ "$smtp_port" == "465" ]]; then
        smtp_url="smtps://${SMTP_HOST}:465"
    else
        smtp_url="smtp://${SMTP_HOST}:${smtp_port}"
    fi

    local date_str
    date_str=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

    # RFC 5322 message: headers, blank line, body
    # CRLF line endings required by SMTP spec (RFC 2822 §2.2)
    {
        printf "From: \"%s\" <%s>\r\n" "${SMTP_FROM_NAME:-VaultWarden}" "${SMTP_FROM_EMAIL}"
        printf "To: %s\r\n"            "${ADMIN_EMAIL}"
        printf "Subject: %s\r\n"       "${subject}"
        printf "Date: %s\r\n"          "${date_str}"
        printf "MIME-Version: 1.0\r\n"
        printf "Content-Type: text/plain; charset=UTF-8\r\n"
        printf "Content-Transfer-Encoding: 7bit\r\n"
        printf "\r\n"
        printf "%s\r\n"                "${body}"
    } | curl -s \
        --connect-timeout 15 \
        --max-time 30 \
        --retry 2 \
        --retry-delay 5 \
        --ssl-reqd \
        --url "$smtp_url" \
        --mail-from "${SMTP_FROM_EMAIL}" \
        --mail-rcpt "${ADMIN_EMAIL}" \
        --user "${SMTP_USERNAME}:${SMTP_PASSWORD}" \
        --upload-file - 2>/dev/null

    return $?
}

# send_email SUBJECT BODY
#
# Public entry point for all email delivery.
# Three-stage delivery chain controlled by EMAIL_PROVIDER in .env:
#
#   Named provider  ->  HTTP API driver  ->  SMTP relay  ->  host MTA
#   smtp            ->  (skip API)       ->  SMTP relay  ->  host MTA
#   host            ->  (skip all)       ->              ->  host MTA
#
# API drivers live in lib/email.sh. To add a new provider:
#   1. Add function _email_driver_PROVIDERNAME() to lib/email.sh
#   2. Add entry to _EMAIL_DRIVERS in lib/email.sh
#   3. Set EMAIL_PROVIDER=PROVIDERNAME in .env
# No other files need changing.
#
# Subjects containing "CRITICAL" bypass the rate limiter.
send_email() {
    local subject="${1:-VaultWarden Notification}"
    local body="${2:-}"
    local provider="${EMAIL_PROVIDER:-smtp}"

    local rate_limit_dir="${PROJECT_ROOT:-/var/lib/vaultwarden}/.rate-limit"
    mkdir -p "$rate_limit_dir" 2>/dev/null || true
    chmod 700 "$rate_limit_dir" 2>/dev/null || true

    local stamp_file
    if ! stamp_file=$(_rate_limit_check "$subject" "$rate_limit_dir"); then
        return 0  # silently suppressed — rate limit active
    fi

    # Append standard footer
    local full_body
    full_body="${body}

---
Host:      $(hostname -f 2>/dev/null || hostname)
Timestamp: $(date -uIs)
Provider:  ${provider}"

    # ── Stage 1: HTTP API via named driver ──────────────────────────────
    if [[ "$provider" != "smtp" && "$provider" != "host" ]]; then
        if [[ -z "${_EMAIL_DRIVERS[$provider]:-}" ]]; then
            log_error "Unknown EMAIL_PROVIDER='${provider}'"
            log_info  "Valid providers: ${!_EMAIL_DRIVERS[*]} smtp host"
            return 1
        fi

        local driver_fn="_email_driver_${provider}"

        if [[ -z "${EMAIL_API_TOKEN:-}" ]]; then
            log_warn "EMAIL_PROVIDER=${provider} set but EMAIL_API_TOKEN is empty — falling back to SMTP"
        elif "$driver_fn" "$subject" "$full_body"; then
            log_success "Email sent via ${provider} API: ${subject}"
            date +%s > "$stamp_file" 2>/dev/null || true
            return 0
        else
            log_warn "${provider} API failed — falling back to SMTP relay"
        fi
    fi

    # ── Stage 2: SMTP relay via curl ────────────────────────────────────
    if [[ "$provider" != "host" ]]; then
        if _smtp_send "$subject" "$full_body"; then
            log_success "Email sent via SMTP relay (${SMTP_HOST:-unconfigured}:${SMTP_PORT:-465}): ${subject}"
            date +%s > "$stamp_file" 2>/dev/null || true
            return 0
        fi
        log_warn "SMTP relay failed — falling back to host MTA"
    fi

    # ── Stage 3: Host MTA (Postfix or sendmail) ─────────────────────────
    if command -v mail &>/dev/null; then
        if echo "$full_body" | mail -s "$subject" "${ADMIN_EMAIL}" 2>/dev/null; then
            log_success "Email sent via host MTA: ${subject}"
            date +%s > "$stamp_file" 2>/dev/null || true
            return 0
        fi
    fi

    log_error "All email delivery methods failed (provider=${provider}, subject=${subject})"
    return 1
}

# send_notification_email SUBJECT BODY
# Backward-compatibility shim. All new code should call send_email() directly.
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
    domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')
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
    local command=("$@")

    log_debug "Executing: $description"
    if "${command[@]}"; then
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
export -f ensure_dir secure_file test_connectivity test_http download_file
export -f _rate_limit_check send_email send_notification_email _smtp_send
export -f validate_email validate_domain validate_port validate_ip validate_url
export -f setup_error_trap setup_cleanup_trap safe_execute
export -f init_common_lib

log_debug "Common library loaded (email provider: ${EMAIL_PROVIDER:-smtp})"
