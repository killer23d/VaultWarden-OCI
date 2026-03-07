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
# Fallback chain: SUDO_USER → USER → id -un → 'root'
get_real_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "$SUDO_USER"
    elif [[ -n "${USER:-}" ]]; then
        echo "$USER"
    else
        # Non-interactive / daemon context: derive from process credentials.
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

# BUG-C1 FIX: _rate_limit_check_and_stamp  (extracted helper)
#
# Previously both _send_email_via_postfix() and _send_email_via_mailutils()
# wrote the rate-limit timestamp BEFORE attempting to create the temp file
# for the email body.  If mktemp failed, the stamp was already written and
# the next hour of notifications was silently suppressed.
#
# This helper encapsulates the rate-limit logic so it can be called AFTER
# the temp file is successfully created.  It returns 0 when the message may
# be sent, 1 when the rate limit is active (caller should return 0 = "OK,
# but silently dropped").
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

    # Print the stamp-file path so the caller can write it after a successful send.
    echo "$last_email_file"
    return 0
}

# ENHANCED: Send notification email via postfix container
send_notification_email() {
    local subject="$1"
    local body="$2"
    local admin_email
    admin_email=$(get_config_value "ADMIN_EMAIL" "")

    if [[ -z "$admin_email" ]]; then
        log_warn "ADMIN_EMAIL not configured. Cannot send notification."
        return 1
    fi

    if docker inspect vaultwarden_postfix --format '{{.State.Running}}' 2>/dev/null | grep -qx 'true'; then
        log_debug "Using postfix container for email delivery"
        _send_email_via_postfix "$subject" "$body" "$admin_email"
        return $?
    fi

    if has_command mail; then
        log_debug "Using host mailutils for email delivery (fallback)"
        _send_email_via_mailutils "$subject" "$body" "$admin_email"
        return $?
    fi

    log_warn "No email backend available (tried postfix container and host mailutils)"
    return 1
}

_get_postfix_smtp_target_for_fail2ban() {
    local host="postfix"
    local port="587"

    local netmode
    netmode=$(docker inspect vaultwarden_fail2ban --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || echo "")

    if [[ "$netmode" == "host" ]]; then
        host="127.0.0.1"
    fi

    printf '%s:%s\n' "$host" "$port"
    return 0
}

_send_email_via_postfix() {
    local subject="$1"
    local body="$2"
    local admin_email="$3"

    local rate_limit_dir="${PROJECT_ROOT:-/var/lib/vaultwarden}/.rate-limit"
    mkdir -p "$rate_limit_dir" 2>/dev/null || true
    chmod 700 "$rate_limit_dir" 2>/dev/null || true

    # BUG-C1 FIX: create temp file FIRST, then check rate limit.
    # Previously the stamp was written before mktemp; a mktemp failure left
    # the rate-limit counter bumped and silently dropped the next hour of mail.
    local body_tmp
    if ! body_tmp=$(mktemp); then
        log_error "Failed to create temp file for email body"
        return 1
    fi
    chmod 600 "$body_tmp" 2>/dev/null || true

    # Check rate limit — if active, clean up temp file and return "sent" (silent drop).
    local stamp_file
    if ! stamp_file=$(_rate_limit_check "$subject" "$rate_limit_dir"); then
        rm -f "$body_tmp" 2>/dev/null || true
        return 0
    fi

    local full_subject="[VaultWarden] $subject"
    local full_body="$body

---
Host: $(hostname -f 2>/dev/null || hostname)
Timestamp: $(date -uIs)
Project: VaultWarden-OCI
Email Backend: postfix container (bokysan/docker-postfix)"

    local smtp_target smtp_host smtp_port
    smtp_target=$(_get_postfix_smtp_target_for_fail2ban)
    smtp_host="${smtp_target%:*}"
    smtp_port="${smtp_target##*:}"

    log_debug "Postfix SMTP target for fail2ban: ${smtp_host}:${smtp_port}"

    local email_script
    email_script=$(cat <<'PYEOF'
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
import sys
import os

def send_email():
    try:
        msg = MIMEMultipart()
        msg['From'] = os.environ.get('EMAIL_FROM', 'vaultwarden@localhost')
        msg['To'] = os.environ.get('EMAIL_TO', '')
        msg['Subject'] = os.environ.get('EMAIL_SUBJECT', 'No Subject')

        body = os.environ.get('EMAIL_BODY', '')
        if not body:
            try:
                with open('/tmp/.vw_email_body', 'r', encoding='utf-8') as f:
                    body = f.read()
            except Exception:
                body = ''
        msg.attach(MIMEText(body, 'plain'))

        host = os.environ.get('SMTP_HOST', '127.0.0.1')
        port = int(os.environ.get('SMTP_PORT', '587'))

        server = smtplib.SMTP(host, port, timeout=10)
        server.send_message(msg)
        server.quit()

        print('Email sent successfully via postfix')
        return True
    except Exception as e:
        print(f'Failed to send email via postfix: {e}', file=sys.stderr)
        return False

sys.exit(0 if send_email() else 1)
PYEOF
)

    printf '%s' "$full_body" > "$body_tmp"

    # Write the Python script to a secure temp file to avoid single-quote
    # injection: the email_script contains Python single-quoted strings
    # ('plain', 'No Subject', etc.) that would terminate an outer sh -c '...'
    # argument prematurely if embedded directly.
    local script_tmp
    script_tmp=$(mktemp /tmp/vw_email_XXXXXX.py)
    install -m 600 /dev/null "$script_tmp"
    printf '%s\n' "$email_script" > "$script_tmp"

    # Copy script into container, execute it, then clean up both copies.
    docker compose cp "$script_tmp" fail2ban:/tmp/.vw_email_send.py 2>/dev/null || true
    rm -f "$script_tmp" 2>/dev/null || true

    if docker compose exec -T \
        -e EMAIL_FROM="${SMTP_FROM:-vaultwarden@${DOMAIN_NAME:-localhost}}" \
        -e EMAIL_TO="$admin_email" \
        -e EMAIL_SUBJECT="$full_subject" \
        -e SMTP_HOST="$smtp_host" \
        -e SMTP_PORT="$smtp_port" \
        fail2ban sh -c "cat >/tmp/.vw_email_body && python3 /tmp/.vw_email_send.py; rc=\$?; rm -f /tmp/.vw_email_body /tmp/.vw_email_send.py; exit \$rc" < "$body_tmp"; then
        rm -f "$body_tmp" 2>/dev/null || true
        # Write rate-limit stamp only on successful send.
        date +%s > "$stamp_file" 2>/dev/null || true
        log_success "Notification email sent to $admin_email (via postfix)"
        return 0
    else
        rm -f "$body_tmp" 2>/dev/null || true
        log_error "Failed to send notification email via postfix"
        return 1
    fi
}

_send_email_via_mailutils() {
    local subject="$1"
    local body="$2"
    local admin_email="$3"

    local rate_limit_dir="${PROJECT_ROOT:-/var/lib/vaultwarden}/.rate-limit"
    mkdir -p "$rate_limit_dir" 2>/dev/null || true
    chmod 700 "$rate_limit_dir" 2>/dev/null || true

    # BUG-C1 FIX: same ordering fix as _send_email_via_postfix.
    # Check rate limit before doing any work; no temp file needed here but
    # the stamp must only be written after a successful send.
    local stamp_file
    if ! stamp_file=$(_rate_limit_check "$subject" "$rate_limit_dir"); then
        return 0
    fi

    local full_subject="[VaultWarden] $subject"
    local full_body="$body

---
Host: $(hostname -f 2>/dev/null || hostname)
Timestamp: $(date -uIs)
Project: VaultWarden-OCI
Email Backend: host mailutils (legacy)"

    if echo "$full_body" | mail -s "$full_subject" "$admin_email"; then
        # Write rate-limit stamp only on successful send.
        date +%s > "$stamp_file" 2>/dev/null || true
        log_success "Notification email sent to $admin_email (via mailutils)"
        return 0
    else
        log_error "Failed to send notification email via mailutils"
        return 1
    fi
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
export -f _rate_limit_check send_notification_email _get_postfix_smtp_target_for_fail2ban
export -f _send_email_via_postfix _send_email_via_mailutils
export -f validate_email validate_domain validate_port validate_ip validate_url
export -f setup_error_trap setup_cleanup_trap safe_execute
export -f init_common_lib

log_debug "Enhanced common library loaded successfully - postfix email integration + strict mode fixes + compatibility flag"
