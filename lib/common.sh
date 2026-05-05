#!/usr/bin/env bash
# lib/common.sh - Core shared functions for VaultWarden-OCI-NG

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_COMMON_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_COMMON_LIB_LOADED=1

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
    COLOR_RED=$(tput setaf 1 2>/dev/null)     || COLOR_RED=""
    COLOR_GREEN=$(tput setaf 2 2>/dev/null)   || COLOR_GREEN=""
    COLOR_YELLOW=$(tput setaf 3 2>/dev/null)  || COLOR_YELLOW=""
    COLOR_BLUE=$(tput setaf 4 2>/dev/null)    || COLOR_BLUE=""
    COLOR_CYAN=$(tput setaf 6 2>/dev/null)    || COLOR_CYAN=""
    COLOR_RESET=$(tput sgr0 2>/dev/null)      || COLOR_RESET=""
    COLOR_BOLD=$(tput bold 2>/dev/null)       || COLOR_BOLD=""
    readonly COLOR_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_CYAN COLOR_RESET COLOR_BOLD
else
    readonly COLOR_RED=""
    readonly COLOR_GREEN=""
    readonly COLOR_YELLOW=""
    readonly COLOR_BLUE=""
    # shellcheck disable=SC2034  # COLOR_CYAN is used by sourcing scripts (setup.sh, create-breakglass-admin.sh)
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

_ENV_FILE_SEARCH_PATHS=(
    ".env"
    "/etc/vaultwarden/vaultwarden.env"
)

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

        # Injection guard: only $( and ` are genuine risks here because we use
        # printf -v (not eval) for assignment. Bare $, |, <, >, and \ are
        # inert in this context and must be allowed for strong passwords.
        if [[ "$value" == *'`'* || "$value" == *'$('* ]]; then
            log_error "load_env_file: line ${lineno}: value for '${key}' contains" \
                      "shell command-substitution syntax (\`...\` or \$(...))" \
                      "— aborting load of '${env_file}'. Quote or escape the value."
            return 1
        fi
        # Warn (non-fatal) for chars that are unusual in config but legal
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

# --- Cleanup Registration ---

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

# _email_driver_lookup PROVIDER
# Prints the driver function suffix for PROVIDER, or returns 1 if unknown.
# Implemented as a single case statement so it works consistently in both the
# current shell and child subshells without exported registry state.
_email_driver_lookup() {
    local provider="${1,,}"
    case "$provider" in
        mailersend|sendgrid|mailgun|postmark|resend)
            printf '%s' "$provider"
            return 0
            ;;
        # host/postfix driver for EMAIL_MODE=host (postfix sidecar)
        host|postfix)
            printf '%s' "postfix"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# -- HELPER: JSON string escape -----------------------------------------------
# Strips raw control chars U+0000-U+001F (EM-M2) then encodes the five
# characters that MUST be escaped in a JSON string value.
_email_json_escape() {
    local str="$1"
    str=$(LC_ALL=C printf '%s' "$str" \
        | LC_ALL=C sed 's/[\x00-\x08\x0b\x0c\x0e-\x1f]//g')
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    printf '%s' "$str"
}

# -- HELPER: shared Bearer-token POST -----------------------------------------
_email_bearer_post() {
    local url="$1" payload="$2"
    local tmp cfg code
    tmp=$(mktemp -t vw_email.XXXXXXXXXX)
    # Harden tmp with install -m 600 so the response body file is
    # never world-readable regardless of the process umask. Matches the
    # existing pattern used for cfg below and in Mailgun/Postmark drivers.
    if ! install -m 600 /dev/null "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        log_error "_email_bearer_post: failed to secure response temp file"
        return 1
    fi
    cfg=$(mktemp -t vw_ecfg.XXXXXXXXXX)
    if ! install -m 600 /dev/null "$cfg" 2>/dev/null; then
        rm -f "$tmp" "$cfg"
        log_error "_email_bearer_post: failed to secure curl config temp file"
        return 1
    fi
    trap 'rm -f "$tmp" "$cfg" 2>/dev/null; trap - RETURN' RETURN

    printf 'header = "Authorization: Bearer %s"\n' "${EMAIL_API_TOKEN}" >"$cfg"

    code=$(curl -s \
        --config "$cfg" \
        --connect-timeout 10 \
        --max-time 20 \
        --retry 2 \
        --retry-delay 3 \
        --retry-all-errors \
        -o "$tmp" \
        -w "%{http_code}" \
        -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    _ECURL_CODE="$code"
    _ECURL_BODY=$(head -c 300 "$tmp" 2>/dev/null | tr -d '\n')
    [[ "$code" =~ ^2 ]] && return 0 || return 1
}

# -- DRIVER: MailerSend -------------------------------------------------------
_email_driver_mailersend() {
    local subject="$1" body="$2"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "${_from_email}")
    ae=$(_email_json_escape "${ADMIN_EMAIL}")

    local payload
    payload=$(cat <<EOF
{
    "from": { "email": "${fe}", "name": "${fn}" },
    "to":   [ { "email": "${ae}" } ],
    "subject": "${s}",
    "text":    "${b}",
    "settings": { "track_clicks": false, "track_opens": false }
}
EOF
)

    if _email_bearer_post "https://api.mailersend.com/v1/email" "$payload"; then
        [[ -n "${_ECURL_BODY}" ]] && log_warn "MailerSend: queued with warnings: ${_ECURL_BODY}"
        return 0
    fi
    log_warn "MailerSend API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}

# -- DRIVER: SendGrid ---------------------------------------------------------
_email_driver_sendgrid() {
    local subject="$1" body="$2"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "${_from_email}")
    ae=$(_email_json_escape "${ADMIN_EMAIL}")

    local payload
    payload=$(cat <<EOF
{
    "personalizations": [ { "to": [ { "email": "${ae}" } ] } ],
    "from":    { "email": "${fe}", "name": "${fn}" },
    "subject": "${s}",
    "content": [ { "type": "text/plain", "value": "${b}" } ],
    "tracking_settings": {
        "click_tracking":        { "enable": false },
        "open_tracking":         { "enable": false },
        "subscription_tracking": { "enable": false }
    }
}
EOF
)

    _email_bearer_post "https://api.sendgrid.com/v3/mail/send" "$payload" && return 0
    log_warn "SendGrid API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}

# -- DRIVER: Mailgun ----------------------------------------------------------
_email_driver_mailgun() {
    local subject="$1" body="$2"
    subject="${subject//$'\r'/}"
    subject="${subject//$'\n'/}"
    body="${body//$'\r'/}"
    body="${body//$'\n'/ }"
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    local domain="${MAILGUN_DOMAIN:-}"
    [[ -z "$domain" ]] && domain="${_from_email##*@}"
    if [[ -z "$domain" ]]; then
        log_error "Mailgun driver: cannot determine domain. Set MAILGUN_DOMAIN in .env"
        return 1
    fi

    if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        log_error "Mailgun driver: invalid domain '${domain}' (failed hostname validation). Check MAILGUN_DOMAIN or SMTP_FROM."
        return 1
    fi

    local mg_region="${MAILGUN_REGION:-us}"
    local mg_api_host
    case "${mg_region,,}" in
        us)  mg_api_host="api.mailgun.net" ;;
        eu)  mg_api_host="api.eu.mailgun.net" ;;
        *)
            log_error "Mailgun driver: unrecognised MAILGUN_REGION='${mg_region}'. Valid values: us eu"
            return 1
            ;;
    esac

    local tmp cfg code
    tmp=$(mktemp -t vw_email.XXXXXXXXXX)
    cfg=$(mktemp -t vw_ecfg.XXXXXXXXXX)
    if ! install -m 600 /dev/null "$cfg" 2>/dev/null; then
        rm -f "$tmp" "$cfg"
        log_error "Mailgun driver: failed to secure curl config temp file"
        return 1
    fi
    trap 'rm -f "$tmp" "$cfg" 2>/dev/null; trap - RETURN' RETURN

    printf 'user = "api:%s"\n' "${EMAIL_API_TOKEN}" >"$cfg"

    code=$(curl -s \
        --config "$cfg" \
        --connect-timeout 10 \
        --max-time 20 \
        --retry 2 \
        --retry-delay 3 \
        --retry-all-errors \
        -o "$tmp" \
        -w "%{http_code}" \
        -X POST "https://${mg_api_host}/v3/${domain}/messages" \
        -F "from=${SMTP_FROM_NAME:-VaultWarden} <${_from_email}>" \
        -F "to=${ADMIN_EMAIL}" \
        -F "subject=${subject}" \
        -F "text=${body}" \
        -F "o:tracking=no" 2>/dev/null)

    local resp; resp=$(head -c 300 "$tmp" 2>/dev/null | tr -d '\n')
    [[ "$code" =~ ^2 ]] && return 0
    log_warn "Mailgun API HTTP ${code} (region=${mg_region}, host=${mg_api_host}): ${resp}"
    return 1
}

# -- DRIVER: Postmark ---------------------------------------------------------
_email_driver_postmark() {
    local subject="$1" body="$2"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "${_from_email}")
    ae=$(_email_json_escape "${ADMIN_EMAIL}")

    local tmp cfg code
    tmp=$(mktemp -t vw_email.XXXXXXXXXX)
    cfg=$(mktemp -t vw_ecfg.XXXXXXXXXX)
    if ! install -m 600 /dev/null "$cfg" 2>/dev/null; then
        rm -f "$tmp" "$cfg"
        log_error "Postmark driver: failed to secure curl config temp file"
        return 1
    fi
    trap 'rm -f "$tmp" "$cfg" 2>/dev/null; trap - RETURN' RETURN

    printf 'header = "X-Postmark-Server-Token: %s"\n' "${EMAIL_API_TOKEN}" >"$cfg"

    local payload
    payload=$(cat <<EOF
{
    "From":          "${fn} <${fe}>",
    "To":            "${ae}",
    "Subject":       "${s}",
    "TextBody":      "${b}",
    "MessageStream": "outbound"
}
EOF
)

    code=$(curl -s \
        --config "$cfg" \
        --connect-timeout 10 \
        --max-time 20 \
        --retry 2 \
        --retry-delay 3 \
        --retry-all-errors \
        -o "$tmp" \
        -w "%{http_code}" \
        -X POST "https://api.postmarkapp.com/email" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    local resp; resp=$(head -c 300 "$tmp" 2>/dev/null | tr -d '\n')
    if [[ ! "$code" =~ ^2 ]]; then
        log_warn "Postmark API HTTP ${code}: ${resp}"
        return 1
    fi
    if echo "$resp" | grep -q '"ErrorCode":0'; then
        return 0
    fi
    log_warn "Postmark API: HTTP 200 but ErrorCode != 0: ${resp}"
    return 1
}

# -- DRIVER: Resend -----------------------------------------------------------
_email_driver_resend() {
    local subject="$1" body="$2"
    local s b fn fe ae
    s=$(_email_json_escape "$subject")
    b=$(_email_json_escape "$body")
    local _from_email="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"
    fn=$(_email_json_escape "${SMTP_FROM_NAME:-VaultWarden}")
    fe=$(_email_json_escape "${_from_email}")
    ae=$(_email_json_escape "${ADMIN_EMAIL}")

    local payload
    payload=$(cat <<EOF
{
    "from":    "${fn} <${fe}>",
    "to":      ["${ae}"],
    "subject": "${s}",
    "text":    "${b}"
}
EOF
)

    _email_bearer_post "https://api.resend.com/emails" "$payload" && return 0
    log_warn "Resend API HTTP ${_ECURL_CODE}: ${_ECURL_BODY}"
    return 1
}

# -- DRIVER: host/postfix (EMAIL_MODE=host, postfix sidecar) ------------------
# Implements the EMAIL_MODE=host driver. Pipes a minimal RFC-2822 message to
# sendmail -t which is provided by the postfix sidecar container. No API token
# is required or read.
#
# Usage: set EMAIL_MODE=host and EMAIL_PROVIDER=host (or EMAIL_PROVIDER=postfix)
# in .env. sendmail must be on PATH (standard in the postfix sidecar image).
_email_driver_postfix() {
    local subject="$1" body="$2"
    local _from_email="${SMTP_FROM:-${SMTP_FROM_EMAIL:-}}"
    local from_name="${SMTP_FROM_NAME:-VaultWarden}"
    local to_addr="${ADMIN_EMAIL:-}"

    if [[ -z "$to_addr" ]]; then
        log_error "postfix driver: ADMIN_EMAIL is not set"
        return 1
    fi

    if ! command -v sendmail >/dev/null 2>&1; then
        log_error "postfix driver: sendmail not found in PATH — is the postfix sidecar running?"
        return 1
    fi

    # Pipe a minimal RFC-2822 message to sendmail -t.
    # sendmail -t reads recipients from To:/Cc:/Bcc: headers so no separate
    # envelope argument is needed. -oi prevents a line with a single '.' from
    # prematurely ending the message body.
    printf 'From: %s <%s>\nTo: %s\nSubject: %s\n\n%s\n' \
        "$from_name" "$_from_email" "$to_addr" "$subject" "$body" \
        | sendmail -t -oi
}

# ─────────────────────────────────────────────────────────────────────────────
# _normalise_email_subject SUBJECT
#
# Single source of truth for the [VaultWarden] subject prefix used by every
# email-related function.  Prepends the prefix when not already present and
# prints the normalised subject to stdout.
#
# Both send_email() and clear_email_rate_limit() call this helper so that the
# two functions always hash the same string when computing the rate-limit stamp
# file path.  If the prefix is ever changed it only needs updating here.
# ─────────────────────────────────────────────────────────────────────────────
_normalise_email_subject() {
    local subject="$1"
    [[ "$subject" != "[VaultWarden]"* ]] && subject="[VaultWarden] ${subject}"
    printf '%s\n' "$subject"
}

# ─────────────────────────────────────────────────────────────────────────────
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
    local last_email_file
    last_email_file="$rate_limit_dir/.vw_last_email_$(printf '%s' "$subject" | sha256sum | cut -c1-16)"

    if [[ "$subject" != *"CRITICAL"* ]] && [[ -f "$last_email_file" ]]; then
        local last_time current_time
        last_time=$(cat "$last_email_file" 2>/dev/null || printf '0')
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
# clear_email_rate_limit SUBJECT
#
# Removes the rate-limit stamp file for SUBJECT so that the *next* call to
# send_email() for this subject fires immediately, regardless of how recently
# the previous alert was sent.
#
# Call this from health-check or monitoring scripts when a previously-alerting
# condition returns to a healthy state.  This ensures that if the same
# condition flaps, the recovery → next-fault cycle always produces a fresh
# notification rather than waiting out the 1-hour TTL.
#
# Usage:
#   clear_email_rate_limit "Health check failed"   # matches send_email subject
#
# The subject is normalised via _normalise_email_subject() — the same helper
# used by send_email() — so callers may pass the bare subject or the prefixed
# form interchangeably and the stamp file path always matches.
# ─────────────────────────────────────────────────────────────────────────────
clear_email_rate_limit() {
    local subject="${1:-}"
    [[ -z "$subject" ]] && { log_warn "clear_email_rate_limit: subject is empty — nothing to clear"; return 0; }

    subject=$(_normalise_email_subject "$subject")

    local rate_limit_dir
    rate_limit_dir=$(_resolve_rate_limit_dir) || {
        log_debug "clear_email_rate_limit: rate-limit dir unavailable — nothing to clear"
        return 0
    }

    local stamp_file
    stamp_file="$rate_limit_dir/.vw_last_email_$(printf '%s' "$subject" | sha256sum | cut -c1-16)"

    if [[ -f "$stamp_file" ]]; then
        rm -f "$stamp_file" 2>/dev/null || true
        log_debug "clear_email_rate_limit: cleared stamp for '${subject}'"
    else
        log_debug "clear_email_rate_limit: no stamp found for '${subject}' — nothing to clear"
    fi

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _resolve_smtp_method
#
# Single source of truth for the SMTP transport label used in delivery
# metadata and log lines.  Prints one of two values to stdout:
#
#   "smtp (direct relay)"    — SMTP_PASSWORD is set; _smtp_send() will
#                              authenticate directly to SMTP_HOST.
#   "smtp (postfix sidecar)" — No SMTP_PASSWORD; _smtp_send() will route
#                              through the Postfix sidecar at VW_SMTP_HOST_PORT
#                              (default 127.0.0.1:587).
#
# Both send_email() and _smtp_send() derive their label from this function
# so that the metadata footer and the actual transport path always agree,
# regardless of future changes to either caller.
# ─────────────────────────────────────────────────────────────────────────────
_resolve_smtp_method() {
    if [[ -n "${SMTP_PASSWORD:-}" ]]; then
        printf 'smtp (direct relay)\n'
    else
        printf 'smtp (postfix sidecar)\n'
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# _build_email_metadata_body BASE_BODY HOST_FQDN TIMESTAMP MODE PROVIDER METHOD
#
# Single source of truth for the "Email delivery metadata" footer appended to
# every outbound notification.  Accepts all fields as arguments so the caller
# controls what appears in each label without duplicating the template.
#
# Output is printed to stdout so callers capture it with $(...) or printf -v.
# ─────────────────────────────────────────────────────────────────────────────
_build_email_metadata_body() {
    local base_body="$1"
    local host_fqdn="$2"
    local ts="$3"
    local mode="$4"
    local provider="$5"
    local method="$6"

    printf '%s\n\nEmail delivery metadata:\nHost:      %s\nTimestamp: %s\nMode:      %s\nProvider:  %s\nMethod:    %s' \
        "$base_body" \
        "$host_fqdn" \
        "$ts" \
        "$mode" \
        "$provider" \
        "$method"
}

# ─────────────────────────────────────────────────────────────────────────────
# _smtp_send <to> <subject> <body>  (BUG-EM6 FIX)
#
# Path A: SMTP_PASSWORD present → direct external relay (dev/test override)
# Path B: no SMTP_PASSWORD → route through Postfix sidecar at 127.0.0.1:587
#
# The transport path selected here must always match the label returned by
# _resolve_smtp_method().  If a new transport path is ever added, update
# both functions together.
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

    # ── Path A: SMTP_PASSWORD present → direct external relay ─────────────────
    # This branch must stay in sync with _resolve_smtp_method returning
    # "smtp (direct relay)".
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
    # This branch must stay in sync with _resolve_smtp_method returning
    # "smtp (postfix sidecar)".
    local _sidecar_addr="${VW_SMTP_HOST_PORT:-127.0.0.1:587}"
    local _sidecar_host _sidecar_port
    _sidecar_host="${_sidecar_addr%:*}"
    _sidecar_port="${_sidecar_addr##*:}"

    log_debug "_smtp_send: no SMTP_PASSWORD — routing through Postfix sidecar at ${_sidecar_addr}"

    # Fast sidecar liveness probe to avoid long curl timeouts when postfix
    # is down/unbound on localhost.
    if command -v nc >/dev/null 2>&1; then
        if ! nc -z -w 2 "$_sidecar_host" "$_sidecar_port" >/dev/null 2>&1; then
            log_warn "_smtp_send: Postfix sidecar unreachable at ${_sidecar_addr} (probe failed) — skipping SMTP attempt"
            return 1
        fi
    elif ! (echo >/dev/tcp/"$_sidecar_host"/"$_sidecar_port") >/dev/null 2>&1; then
        log_warn "_smtp_send: Postfix sidecar unreachable at ${_sidecar_addr} (probe failed) — skipping SMTP attempt"
        return 1
    fi

    printf '%s' "$_msg" | curl -s \
        --connect-timeout 5 \
        --max-time 15 \
        --retry 1 \
        --retry-delay 2 \
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

    subject=$(_normalise_email_subject "$subject")

    local rate_limit_dir
    rate_limit_dir=$(_resolve_rate_limit_dir)

    local stamp_file
    if ! stamp_file=$(_rate_limit_check "$subject" "$rate_limit_dir"); then
        return 0
    fi

    # Capture shared metadata values once — avoids repeated subshell forks
    # and guarantees a consistent timestamp across all delivery-path bodies.
    local host_fqdn ts
    host_fqdn="$(hostname -f 2>/dev/null || hostname)"
    ts="$(date -uIs)"

    local base_body="$body"

    local api_token=""
    local api_driver_fn=""

    # ── Stage 1: HTTP API ─────────────────────────────────────────────────────
    if [[ "$mode" == "auto" || "$mode" == "api" ]]; then
        local driver_suffix
        if ! driver_suffix=$(_email_driver_lookup "$provider" 2>/dev/null); then
            log_error "Unknown EMAIL_PROVIDER='${provider}'"
            log_info  "Valid providers: mailersend sendgrid mailgun postmark resend smtp host"
            [[ "$mode" == "api" ]] && return 1
        else
            local driver_fn="_email_driver_${driver_suffix}"
            local _api_token="${EMAIL_API_TOKEN:-}"
            if [[ -z "$_api_token" ]] && declare -f decrypt_secret &>/dev/null; then
                _api_token="$(decrypt_secret email_api_token 2>/dev/null || true)"
            fi
            api_token="$_api_token"
            api_driver_fn="$driver_fn"

            local api_body
            api_body="$(_build_email_metadata_body \
                "$base_body" "$host_fqdn" "$ts" "$mode" "$provider" \
                "api (${provider})")"

            if [[ -z "$_api_token" ]]; then
                if [[ "$mode" == "api" ]]; then
                    log_error "EMAIL_MODE=api but EMAIL_API_TOKEN is empty — cannot send. Run: ./edit-secrets.sh --rotate email_api_token"
                    return 1
                fi
                log_warn "EMAIL_PROVIDER=${provider} set but EMAIL_API_TOKEN is empty — falling back to SMTP. Run: ./edit-secrets.sh --rotate email_api_token"
            elif EMAIL_API_TOKEN="$_api_token" "$driver_fn" "$subject" "$api_body"; then
                log_success "Email sent via ${provider} API: ${subject}"
                date +%s > "$stamp_file" 2>/dev/null || true
                return 0
            else
                if [[ "$mode" == "api" ]]; then
                    log_error "EMAIL_MODE=api: ${provider} API failed — no fallback configured"
                    return 1
                fi
                log_error "${provider} API failed — falling back to SMTP relay"
            fi
        fi
    fi

    # ── Stage 2: SMTP relay (Postfix sidecar or direct relay) ─────────────────
    if [[ "$mode" == "auto" || "$mode" == "smtp" ]]; then
        # _resolve_smtp_method() is the single source of truth for the transport
        # label.  _smtp_send() selects its actual path using the same condition
        # (SMTP_PASSWORD presence), so the metadata footer always matches what
        # was actually used.
        local smtp_method smtp_body
        smtp_method="$(_resolve_smtp_method)"
        smtp_body="$(_build_email_metadata_body \
            "$base_body" "$host_fqdn" "$ts" "$mode" "$provider" \
            "$smtp_method")"

        if _smtp_send "$to" "$subject" "$smtp_body"; then
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

    local host_mta_failed=false
    # ── Stage 3: Host MTA ─────────────────────────────────────────────────────
    if [[ "$mode" == "auto" || "$mode" == "host" ]]; then
        local host_body
        host_body="$(_build_email_metadata_body \
            "$base_body" "$host_fqdn" "$ts" "$mode" "$provider" \
            "host mta (sendmail/postfix)")"

        if command -v mail &>/dev/null; then
            if printf '%s' "$host_body" | mail -s "$subject" "$to" 2>/dev/null; then
                log_success "Email sent via host MTA: ${subject}"
                date +%s > "$stamp_file" 2>/dev/null || true
                return 0
            fi
            host_mta_failed=true
        else
            host_mta_failed=true
        fi
        if [[ "$mode" == "host" ]]; then
            log_error "EMAIL_MODE=host: host MTA failed or not available — no fallback configured"
            return 1
        fi
    fi

    # ── Stage 4 (auto): Emergency direct API bypass ────────────────────────────
    if [[ "$mode" == "auto" && "$host_mta_failed" == "true" && -n "$api_token" && -n "$api_driver_fn" ]]; then
        log_error "SMTP/host MTA delivery unavailable — attempting emergency API bypass (${provider})"

        local emergency_body
        emergency_body="$(_build_email_metadata_body \
            "$base_body" "$host_fqdn" "$ts" "$mode" "$provider" \
            "api emergency bypass (${provider})")"
        # Append the delivery warning note specific to this bypass path.
        emergency_body="${emergency_body}

⚠ Delivery note: Sent via emergency API bypass after SMTP/host MTA failure."

        if EMAIL_API_TOKEN="$api_token" "$api_driver_fn" "$subject" "$emergency_body"; then
            log_success "Emergency API bypass succeeded via ${provider}: ${subject}"
            date +%s > "$stamp_file" 2>/dev/null || true
            return 0
        fi
        log_error "Emergency API bypass failed via ${provider}"
    elif [[ "$mode" == "auto" && "$host_mta_failed" == "true" ]]; then
        log_error "Emergency API bypass skipped: EMAIL_API_TOKEN not resolved for provider '${provider}' — run: ./edit-secrets.sh --rotate email_api_token"
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
    # shellcheck disable=SC2064  # intentional: $cleanup_function expands at registration to capture the function name
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
export -f _normalise_email_subject _resolve_rate_limit_dir _rate_limit_check
export -f _resolve_smtp_method
export -f _build_email_metadata_body
export -f send_email send_notification_email _smtp_send
export -f clear_email_rate_limit
export -f _email_json_escape _email_bearer_post _email_driver_lookup
export -f _email_driver_mailersend _email_driver_sendgrid _email_driver_mailgun
export -f _email_driver_postmark _email_driver_resend _email_driver_postfix
export -f validate_email validate_domain validate_port validate_ip validate_url
export -f setup_error_trap setup_cleanup_trap safe_execute
export -f init_common_lib

log_debug "Common library loaded (email mode: ${EMAIL_MODE:-auto}, provider: ${EMAIL_PROVIDER:-smtp})"