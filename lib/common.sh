#!/usr/bin/env bash
# lib/common.sh - Core shared functions for VaultWarden-OCI-NG
# Essential utilities and logging

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_COMMON_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_COMMON_LIB_LOADED=1

# --- Library Configuration ---
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$LIB_DIR/.." && pwd)"

# --- Logging System ---
LOG_PREFIX=""
LOG_TIMESTAMP=true
LOG_COLORS=true

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
    # Only show debug if DEBUG is set
    [[ "${DEBUG:-false}" == "true" ]] || return 0

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

# Load .env file safely
load_env_file() {
    local env_file="${1:-.env}"

    if [[ ! -f "$env_file" ]]; then
        log_error "Environment file not found: $env_file"
        return 1
    fi

    log_debug "Loading environment from: $env_file"

    # Source with export
    set -a
    source "$env_file"
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

# Validate required configuration
require_config() {
    local missing=()

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

# --- Command and System Checks ---

# Check if command exists
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Require commands to exist
require_commands() {
    local missing=()

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

# Check if running as root
is_root() {
    [[ $EUID -eq 0 ]]
}

# Get current user (even when using sudo)
get_real_user() {
    echo "${SUDO_USER:-$USER}"
}

# --- File Operations ---

# Ensure directory exists with proper permissions
ensure_dir() {
    local dir="$1"
    local mode="${2:-755}"
    local owner="${3:-}"

    if [[ ! -d "$dir" ]]; then
        log_debug "Creating directory: $dir"
        mkdir -p "$dir"
    fi

    chmod "$mode" "$dir"

    if [[ -n "$owner" ]]; then
        chown "$owner" "$dir"
    fi

    return 0
}

# Set secure file permissions
secure_file() {
    local file="$1"
    local mode="${2:-600}"

    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        return 1
    fi

    chmod "$mode" "$file"
    log_debug "Secured file: $file (mode: $mode)"

    return 0
}

# --- Network Helpers ---

# Test network connectivity
test_connectivity() {
    local host="${1:-1.1.1.1}"
    local timeout="${2:-5}"

    ping -c 1 -W "$timeout" "$host" >/dev/null 2>&1
}

# Test HTTP connectivity
test_http() {
    local url="$1"
    local timeout="${2:-10}"

    if has_command curl; then
        curl -sf --max-time "$timeout" "$url" >/dev/null 2>&1
    else
        log_warn "curl not available, cannot test HTTP connectivity"
        return 1
    fi
}

# --- START P1/P2: New Email Notification Function ---
# Send notification email with rate limiting
# Usage: send_notification_email "Subject" "Body"
send_notification_email() {
    local subject="$1"
    local body="$2"
    
    local admin_email
    admin_email=$(get_config_value "ADMIN_EMAIL" "")
    
    if [[ -z "$admin_email" ]]; then
        log_warn "ADMIN_EMAIL not configured. Cannot send notification."
        return 1
    fi
    
    if ! has_command mail; then
        log_warn "mail command (mailutils) not available. Cannot send notification."
        return 1
    fi
    
    # --- Start User Suggestion: Rate Limiting ---
    local last_email_file="/tmp/.vw_last_email_$(echo "$subject" | md5sum | cut -d' ' -f1)"
    if [[ -f "$last_email_file" ]]; then
        local last_time current_time
        last_time=$(cat "$last_email_file")
        current_time=$(date +%s)
        
        # Don't send the same subject email more than once per hour
        if (( current_time - last_time < 3600 )); then
            log_debug "Email rate limited, skipping notification"
            return 0
        fi
    fi
    echo "$(date +%s)" > "$last_email_file"
    # --- End User Suggestion ---

    local full_subject="[VaultWarden] $subject"
    local full_body="$body
---
Host: $(hostname -f 2>/dev/null || hostname)
Timestamp: $(date -uIs)"

    if echo "$full_body" | mail -s "$full_subject" "$admin_email"; then
        log_success "Notification email sent to $admin_email"
    else
        log_error "Failed to send notification email"
        return 1
    fi
}
# --- END P1/P2 ---

# --- Validation Helpers ---

# Validate email format (basic)
validate_email() {
    local email="$1"
    [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]
}

# Validate domain format (basic)
validate_domain() {
    local domain="$1"

    # Remove protocol if present
    domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')

    [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# --- Error Handling ---

# Set up error trap
setup_error_trap() {
    trap 'log_error "Script failed at line $LINENO in $(basename "${BASH_SOURCE[0]}")"; exit 1' ERR
}

# Setup cleanup trap
setup_cleanup_trap() {
    local cleanup_function="$1"
    trap "$cleanup_function" EXIT HUP INT TERM
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
}

# --- Export Functions ---
export -f log_info log_success log_warn log_error log_debug log_header set_log_prefix
export -f load_env_file get_config_value require_config
export -f has_command require_commands is_root get_real_user
export -f ensure_dir secure_file test_connectivity test_http
export -f send_notification_email
export -f validate_email validate_domain setup_error_trap setup_cleanup_trap
export -f init_common_lib

log_debug "Common library loaded successfully"
