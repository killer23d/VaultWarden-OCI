#!/usr/bin/env bash
# lib/common.sh - Core shared functions for VaultWarden-OCI-NG
# ENHANCED: Standardized error handling patterns - functions return, callers decide
# ENHANCED: Updated email function to use msmtpd sidecar (replaces mailutils)
# FIXED: require_commands function properly declares loop variable for strict mode
# All library functions use 'return' with exit codes, never 'exit'

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_COMMON_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_COMMON_LIB_LOADED=1

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
    readonly COLOR_RESET=$(tput sgr0)
    readonly COLOR_BOLD=$(tput bold)
else
    readonly COLOR_RED=""
    readonly COLOR_GREEN=""
    readonly COLOR_YELLOW=""
    readonly COLOR_BLUE=""
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

# Set log prefix for current script
set_log_prefix() {
    LOG_PREFIX="$1"
}

# Get timestamp for logging
_get_timestamp() {
    [[ "$LOG_TIMESTAMP" == "true" ]] && date '+%H:%M:%S' || echo ""
}

# Core logging functions
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

log_header() {
    local message="$*"
    local line
    line=$(printf '=%.0s' $(seq 1 ${#message}))

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

# Load .env file safely - STANDARDIZED: Returns exit code, never exits
load_env_file() {
    local env_file="${1:-.env}"

    if [[ ! -f "$env_file" ]]; then
        log_error "Environment file not found: $env_file"
        return 1
    fi

    log_debug "Loading environment from: $env_file"

    # Source with export
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

# Get configuration value with default
get_config_value() {
    local key="$1"
    local default="${2:-}"

    # Use parameter expansion to get value or default
    local value="${!key:-$default}"
    echo "$value"
}

# Validate required configuration - STANDARDIZED: Returns exit code
require_config() {
    local missing=()
    local key # BEST PRACTICE FIX: Declare loop variable
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

# --- Command Caching for Performance ---
declare -A _command_cache

# Check if command exists (cached version) - STANDARDIZED: Returns exit code
has_command() {
    local cmd="$1"

    # Return cached result if available
    if [[ -n "${_command_cache[$cmd]:-}" ]]; then
        return "${_command_cache[$cmd]}"
    fi

    # Check and cache result
    if command -v "$cmd" >/dev/null 2>&1; then
        _command_cache["$cmd"]=0
        return 0
    else
        _command_cache["$cmd"]=1
        return 1
    fi
}

# FIXED: Require commands to exist - properly handles strict mode
require_commands() {
    local missing=()
    local cmd # BEST PRACTICE FIX: Declare loop variable
    
    for cmd in "$@"; do
        if ! has_command "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_info "Install with: sudo apt install ${missing[*]}"
        return 1
    fi

    return 0
}

# Retry logic with exponential backoff - STANDARDIZED: Returns exit code
retry_with_backoff() {
    local max_attempts="$1"
    local initial_delay="$2"
    local command=("${@:3}")
    local delay="$initial_delay"
    local i # BEST PRACTICE FIX: Declare loop variable

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

# Check if running as root
is_root() {
    [[ $EUID -eq 0 ]]
}

# Get current user (even when using sudo)
get_real_user() {
    echo "${SUDO_USER:-$USER}"
}

# --- File Operations ---

# Ensure directory exists with proper permissions - STANDARDIZED: Returns exit code
ensure_dir() {
    local dir="$1"
    local mode="${2:-755}"
    local owner="${3:-}"

    if [[ ! -d "$dir" ]]; then
        log_debug "Creating directory: $dir"
        if ! mkdir -p "$dir"; then
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

# Set secure file permissions - STANDARDIZED: Returns exit code
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

# Test network connectivity - STANDARDIZED: Returns exit code
test_connectivity() {
    local host="${1:-1.1.1.1}"
    local timeout="${2:-5}"

    ping -c 1 -W "$timeout" "$host" >/dev/null 2>&1
}

# Test HTTP connectivity - STANDARDIZED: Returns exit code
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

# Robust HTTP download with retry - STANDARDIZED: Returns exit code
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

# ENHANCED: Send notification email via msmtpd sidecar - STANDARDIZED: Returns exit code
send_notification_email() {
    local subject="$1"
    local body="$2"

    local admin_email
    admin_email=$(get_config_value "ADMIN_EMAIL" "")

    if [[ -z "$admin_email" ]]; then
        log_warn "ADMIN_EMAIL not configured. Cannot send notification."
        return 1
    fi

    # Check if msmtpd container is available (preferred method)
    if docker compose ps vaultwarden_msmtpd >/dev/null 2>&1; then
        log_debug "Using msmtpd container for email delivery"
        return _send_email_via_msmtpd "$subject" "$body" "$admin_email"
    fi

    # Fallback to host mailutils if available (legacy support)
    if has_command mail; then
        log_debug "Using host mailutils for email delivery (fallback)"
        return _send_email_via_mailutils "$subject" "$body" "$admin_email"
    fi

    log_warn "No email backend available (tried msmtpd container and host mailutils)"
    return 1
}

# ENHANCED: Send email via msmtpd container (preferred method)
_send_email_via_msmtpd() {
    local subject="$1"
    local body="$2"
    local admin_email="$3"

    # Rate limiting with critical exception
    local last_email_file="/tmp/.vw_last_email_$(echo "$subject" | md5sum | cut -d' ' -f1)"

    # Allow critical alerts through rate limiting
    if [[ "$subject" != *"CRITICAL"* ]] && [[ -f "$last_email_file" ]]; then
        local last_time current_time
        last_time=$(cat "$last_email_file")
        current_time=$(date +%s)

        if (( current_time - last_time < 3600 )); then
            log_debug "Email rate limited for non-critical notification: $subject"
            return 0
        fi
    fi
    echo "$(date +%s)" > "$last_email_file"

    local full_subject="[VaultWarden] $subject"
    local full_body="$body
---
Host: $(hostname -f 2>/dev/null || hostname)
Timestamp: $(date -uIs)
Project: VaultWarden-OCI
Email Backend: msmtpd container"

    # Create email using Python and send via msmtpd container
    local email_script
    email_script=$(cat <<EOF
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
import sys

def send_email():
    try:
        msg = MIMEMultipart()
        msg['From'] = '${SMTP_FROM:-vaultwarden@${DOMAIN:-localhost}}'
        msg['To'] = '$admin_email'
        msg['Subject'] = '$full_subject'

        body = '''$full_body'''
        msg.attach(MIMEText(body, 'plain'))

        server = smtplib.SMTP('msmtpd', 1025)
        server.send_message(msg)
        server.quit()
        print('Email sent successfully via msmtpd')
        return True
    except Exception as e:
        print(f'Failed to send email via msmtpd: {e}', file=sys.stderr)
        return False

import sys
sys.exit(0 if send_email() else 1)
EOF
)

    # Execute email script in fail2ban container (which has Python and network access to msmtpd)
    if docker compose exec -T vaultwarden_fail2ban python3 -c "$email_script"; then
        log_success "Notification email sent to $admin_email (via msmtpd)"
        return 0
    else
        log_error "Failed to send notification email via msmtpd"
        return 1
    fi
}

# ENHANCED: Send email via host mailutils (fallback method)
_send_email_via_mailutils() {
    local subject="$1"
    local body="$2"
    local admin_email="$3"

    # Rate limiting with critical exception
    local last_email_file="/tmp/.vw_last_email_$(echo "$subject" | md5sum | cut -d' ' -f1)"

    # Allow critical alerts through rate limiting
    if [[ "$subject" != *"CRITICAL"* ]] && [[ -f "$last_email_file" ]]; then
        local last_time current_time
        last_time=$(cat "$last_email_file")
        current_time=$(date +%s)

        if (( current_time - last_time < 3600 )); then
            log_debug "Email rate limited for non-critical notification: $subject"
            return 0
        fi
    fi
    echo "$(date +%s)" > "$last_email_file"

    local full_subject="[VaultWarden] $subject"
    local full_body="$body
---
Host: $(hostname -f 2>/dev/null || hostname)
Timestamp: $(date -uIs)
Project: VaultWarden-OCI
Email Backend: host mailutils (legacy)"

    if echo "$full_body" | mail -s "$full_subject" "$admin_email"; then
        log_success "Notification email sent to $admin_email (via mailutils)"
        return 0
    else
        log_error "Failed to send notification email via mailutils"
        return 1
    fi
}

# --- Validation Helpers ---

# Validate email format - STANDARDIZED: Returns exit code
validate_email() {
    local email="$1"
    [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]
}

# Validate domain format - STANDARDIZED: Returns exit code
validate_domain() {
    local domain="$1"

    # Remove protocol if present
    domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')

    [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# Validate port number - STANDARDIZED: Returns exit code
validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

# Validate IP address - STANDARDIZED: Returns exit code
validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

# Validate URL format - STANDARDIZED: Returns exit code
validate_url() {
    local url="$1"
    [[ "$url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]]
}

# --- Enhanced Error Handling ---

# Set up error trap with enhanced context
setup_error_trap() {
    trap 'log_error "Script failed at line $LINENO in $(basename "${BASH_SOURCE[0]}") with exit code $?"; exit 1' ERR
}

# Setup cleanup trap
setup_cleanup_trap() {
    local cleanup_function="$1"
    trap "$cleanup_function" EXIT HUP INT TERM
}

# Safe execution wrapper with error context - STANDARDIZED: Returns exit code
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

# Initialize common library for a script
init_common_lib() {
    local script_name="$1"

    # Set error handling
    set -euo pipefail

    # Set log prefix
    set_log_prefix "$(basename "$script_name" .sh)"

    # Change to project root
    cd "$PROJECT_ROOT"

    log_debug "Common library initialized for: $script_name"
    log_debug "Project root: $PROJECT_ROOT"
    log_debug "Log level: $LOG_LEVEL"
}

# --- Export Functions ---
export -f log_info log_success log_warn log_error log_debug log_header set_log_prefix _should_log
export -f load_env_file get_config_value require_config
export -f has_command require_commands retry_with_backoff is_root get_real_user
export -f ensure_dir secure_file test_connectivity test_http download_file
export -f send_notification_email _send_email_via_msmtpd _send_email_via_mailutils
export -f validate_email validate_domain validate_port validate_ip validate_url
export -f setup_error_trap setup_cleanup_trap safe_execute
export -f init_common_lib

log_debug "Enhanced common library loaded successfully - msmtpd email integration + strict mode fixes"
