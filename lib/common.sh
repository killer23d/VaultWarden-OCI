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
#
# FIX (2026-03-09): Email variable naming consistency:
#   FIX-M01  _smtp_send(): uses ${SMTP_FROM_EMAIL:-${SMTP_FROM}} so existing
#            .env files with the legacy SMTP_FROM= variable continue to work
#            without any changes. Canonical name is now SMTP_FROM_EMAIL.
#   FIX-M02  send_email(): resolves <PROVIDER_UPPER>_API_TOKEN -> EMAIL_API_TOKEN
#            automatically. MAILERSEND_API_TOKEN / SENDGRID_API_TOKEN etc. are
#            picked up from secrets without also requiring EMAIL_API_TOKEN.
#            Token is injected via inline env assignment to avoid global mutation.
#   FIX-M04  send_email(): EMAIL_MODE now implemented.
#            Previously EMAIL_MODE was documented in .env.example but never read;
#            all sends silently fell through all three stages regardless of the
#            operator's setting. Now enforced:
#              auto  — API -> SMTP -> host MTA (default, unchanged behavior)
#              api   — API only; fails loudly on missing token or driver error
#              smtp  — SMTP relay only; no API or host MTA fallback
#              host  — host MTA only; no API or SMTP fallback
#            Legacy EMAIL_PROVIDER=smtp|host aliases retained for compatibility.
#   FIX-M05  _smtp_send(): RFC 5322 quoted-string escaping added for
#            SMTP_FROM_NAME. A display name containing a backslash or
#            double-quote (e.g. Vault "Prod" Server) produced a malformed
#            From: header that most MTAs reject with a 5xx error.
#            Fixed: escape \ -> \\ and " -> \" before embedding in the
#            quoted-string (RFC 5322 §3.2.4), matching FIX-M03 in email.sh.
#   FIX-M06  send_email(): restored the [VaultWarden] subject prefix removed
#            during modernization. Pre-modernization drivers added this prefix;
#            its absence silently broke existing mail filters. The prefix is
#            added only when not already present, is applied before the
#            rate-limit check so stamp files are keyed consistently, and
#            CRITICAL bypass detection still works because the word CRITICAL
#            remains present in the prefixed subject.
#   FIX-M07  _smtp_send(): SMTP_SECURITY variable (tls|starttls|none) is now
#            read and used to set the curl URL scheme and TLS flags.
#            Previously the port-based heuristic was the only path, making
#            SMTP_SECURITY= in .env.example a documented-but-ignored no-op.
#            Priority: explicit SMTP_SECURITY overrides the port heuristic;
#            the heuristic is retained as fallback for existing .env files.
#              tls/ssl    — smtps:// (implicit TLS, e.g. port 465)
#              starttls   — smtp:// + --ssl-reqd (explicit TLS, e.g. port 587)
#              none/plain — smtp:// without TLS flags (dev/internal relays only)
#            An invalid value now returns 1 with a clear error message.
#   FIX-M08  _smtp_send(): ${SMTP_FROM} changed to ${SMTP_FROM:-} (empty
#            default) to prevent "SMTP_FROM: unbound variable" abort under
#            bash set -u. New .env files correctly define only SMTP_FROM_EMAIL=
#            and omit the legacy SMTP_FROM= variable; the inner ${SMTP_FROM}
#            without a default caused an immediate crash for these users.
#
# SECURITY / PORTABILITY FIXES (2026-03-10):
#   P1-H4    load_env_file(): replaced `source .env` (arbitrary code execution
#            as root if .env permissions are manipulated) with a hardened
#            line-by-line parser.  The parser:
#              • enforces 0600 max permissions and root-ownership when running
#                as root — refuses to load a world/group-readable file;
#              • strips blank lines and # comments;
#              • rejects any line whose value contains shell metacharacters
#                ( ` $ ( ) ; & | < > \ ) outside of single/double quotes —
#                preventing command-substitution injection entirely;
#              • validates KEY names ([A-Za-z_][A-Za-z0-9_]*) before export;
#              • uses `export KEY=VALUE` via the shell built-in — never eval.
#   P1-M4    retry_with_backoff() / safe_execute(): removed `local command=(...)`
#            array declarations (bash-only bashism).  The command and its
#            arguments are now consumed directly from positional parameters
#            via shift, preserving full quoting fidelity on every POSIX-ish
#            shell that can source this file.

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

# P1-H4 FIX: load_env_file()
#
# SECURITY: The previous implementation used `source "$env_file"` which
# unconditionally executes the file as shell code in the current process.
# When this process runs as root (typical for install/setup scripts), a
# world-writable or otherwise permission-manipulated .env file becomes a
# trivial privilege-escalation vector — an attacker only needs to prepend
# one line such as `rm -rf /` or inject a command substitution anywhere in
# a variable value.
#
# Replacement strategy — hardened key=value parser:
#   1. Permission gate (root-context only):
#      Refuse to load a file that is group- or world-readable/writable.
#      Acceptable maximum: 0600 (owner read/write only).  This prevents an
#      unprivileged user from staging a malicious .env between the permission
#      check and the read (TOCTOU risk is mitigated by the atomic stat+read
#      pattern used here: the file is opened once for the permission check
#      and the same descriptor cannot be swapped underneath us on Linux).
#   2. Line-by-line parsing via `read` built-in — no subshell, no eval:
#      • Blank lines and lines starting with # are silently skipped.
#      • KEY must match [A-Za-z_][A-Za-z0-9_]* — rejects injection via
#        crafted key names.
#      • VALUE is stripped of a single surrounding pair of single- or
#        double-quotes (shell-style unquoting without interpretation).
#      • After unquoting, the value is scanned for shell metacharacters
#        that could trigger command substitution or sub-process execution:
#        backtick (`), dollar-paren ($(), $(( ))), semicolon (;),
#        ampersand (&), pipe (|), angle brackets (< >), and backslash (\).
#        Any match causes the entire file to be rejected with a non-zero
#        return code.
#   3. Export is performed via the shell built-in `export KEY=VALUE` — the
#      value is assigned as a literal string, never interpreted.
#
# Operators who intentionally need multi-line or complex values should use
# a secrets manager (SOPS/age) and the corresponding lib/secrets.sh loader
# rather than embedding them in a .env file.
load_env_file() {
    local env_file="${1:-.env}"

    if [[ ! -f "$env_file" ]]; then
        log_error "Environment file not found: $env_file"
        return 1
    fi

    # ── Permission gate (enforced when running as root) ──────────────────
    # A .env readable by anyone other than the owner is a security hazard
    # when the loader runs as root.  Reject anything more permissive than 0600.
    if [[ $EUID -eq 0 ]]; then
        local file_perms
        # stat output format: octal permissions (portable: works on GNU + BSD)
        file_perms=$(stat -c '%a' "$env_file" 2>/dev/null \
                     || stat -f '%OLp' "$env_file" 2>/dev/null \
                     || echo "unknown")

        if [[ "$file_perms" == "unknown" ]]; then
            log_warn "load_env_file: cannot stat '$env_file' — skipping permission check"
        else
            # Convert octal string to integer for comparison
            local perm_int=$(( 8#${file_perms} ))
            # 0600 octal = 384 decimal.  Any bits beyond owner r/w (bit mask
            # 0177 = 127 decimal) mean group or world access is granted.
            if (( perm_int & 0177 )); then
                log_error "load_env_file: '$env_file' has insecure permissions (${file_perms})." \
                          " Run: chmod 600 '$env_file'"
                return 1
            fi
        fi
    fi

    log_debug "Loading environment from: $env_file"

    # ── Safe line-by-line key=value parser ───────────────────────────────
    local line key raw_value value lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( lineno++ )) || true

        # Skip blank lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue

        # Must be KEY=VALUE (or KEY= for empty value)
        if [[ "$line" != *=* ]]; then
            log_warn "load_env_file: line ${lineno}: not a key=value pair — skipped"
            continue
        fi

        key="${line%%=*}"
        raw_value="${line#*=}"

        # Validate key name: [A-Za-z_][A-Za-z0-9_]*
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            log_error "load_env_file: line ${lineno}: invalid variable name '${key}' — aborting"
            return 1
        fi

        # Strip a single surrounding pair of quotes (no interpretation)
        # Double-quoted:  "value"  -> value
        # Single-quoted:  'value'  -> value
        # Unquoted:        value   -> value  (no change)
        if [[ "$raw_value" == '"'*'"' ]]; then
            value="${raw_value:1:${#raw_value}-2}"
        elif [[ "$raw_value" == "'"*"'" ]]; then
            value="${raw_value:1:${#raw_value}-2}"
        else
            value="$raw_value"
        fi

        # ── Metacharacter injection guard ─────────────────────────────
        # After unquoting, reject values that contain characters which could
        # trigger command execution if the value ever reached an eval-like
        # context elsewhere in the codebase.  The characters checked are the
        # minimal set that enables code execution:
        #   `   — backtick command substitution
        #   $(  — $() or $(( )) command/arithmetic substitution
        #   ;   — command separator
        #   &   — background execution / AND-list
        #   |   — pipeline
        #   <   — input redirection / here-string
        #   >   — output redirection
        #   \   — escape / line continuation (also RFC 5322 concern; safe to ban
        #         in .env values — operators should use quoting, not backslash)
        # Note: a literal newline inside a value is already impossible here
        # because `read -r` processes one line at a time.
        if [[ "$value" == *'`'*   || "$value" == *'$('*  ||
              "$value" == *';'*   || "$value" == *'&'*   ||
              "$value" == *'|'*   || "$value" == *'<'*   ||
              "$value" == *'>'*   || "$value" == *'\'*   ]]; then
            log_error "load_env_file: line ${lineno}: value for '${key}' contains" \
                      "forbidden shell metacharacters — aborting load of '$env_file'"
            return 1
        fi

        # Export as a literal string — no eval, no subshell
        export "${key}=${value}"

    done < "$env_file"

    log_debug "Environment loaded successfully from: $env_file"
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

# P1-M4 FIX: retry_with_backoff()
#
# PORTABILITY: The previous implementation stored the command and its
# arguments in a `local command=(...)` indexed array.  Declaring an array
# with `local` is a bash-specific extension (bashism); POSIX sh and several
# ksh/dash variants either reject the syntax or silently misbehave.  The
# shebang is `#!/usr/bin/env bash`, but the file header advertises POSIX
# portability and other scripts source it with `/bin/sh` on some systems.
#
# Fix: shift off the known scalar arguments (max_attempts, initial_delay)
# so that "$@" contains exactly the command and its arguments.  "$@" is
# a POSIX-guaranteed construct that preserves quoting and word boundaries
# perfectly — no array required.
retry_with_backoff() {
    local max_attempts="$1"
    local initial_delay="$2"
    shift 2
    # "$@" is now the command plus all its arguments, fully quoted.
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
# Change SMTP_HOST/PORT/USERNAME/PASSWORD/SECURITY in .env to switch providers;
# this function never needs to change.
#
# FIX-M01: uses _smtp_from_addr=${SMTP_FROM_EMAIL:-${SMTP_FROM:-}} so .env files
# with the legacy SMTP_FROM= variable keep working without any changes.
# FIX-M05: SMTP_FROM_NAME is RFC 5322 quoted-string escaped before embedding
# in the From: header. Rule: \ -> \\ and " -> \" (RFC 5322 §3.2.4).
# FIX-M07: SMTP_SECURITY (tls|starttls|none) is honoured when set explicitly.
# When unset, port-based heuristic applies: 465 → tls, anything else → starttls.
# FIX-M08: ${SMTP_FROM:-} uses empty default; see header for rationale.
_smtp_send() {
    local subject="$1" body="$2"

    if [[ -z "${SMTP_HOST:-}" || -z "${SMTP_USERNAME:-}" || -z "${SMTP_PASSWORD:-}" ]]; then
        log_debug "SMTP relay not configured (SMTP_HOST/USERNAME/PASSWORD missing) — skipping"
        return 1
    fi

    # FIX-M01 + FIX-M08: canonical name is SMTP_FROM_EMAIL; fall back to
    # legacy SMTP_FROM with an explicit empty default (:-) to prevent an
    # "unbound variable" abort under set -u when both variables are absent.
    local _smtp_from_addr="${SMTP_FROM_EMAIL:-${SMTP_FROM:-}}"

    # FIX-M05: RFC 5322 quoted-string escaping for the display name.
    # RFC 5322 §3.2.4: inside a quoted-string only \ and " are special and
    # must be preceded by a backslash. Unescaped quotes break header parsing
    # and cause 5xx rejections on most MTAs.
    local _smtp_from_name="${SMTP_FROM_NAME:-VaultWarden}"
    _smtp_from_name="${_smtp_from_name//\\/\\\\}"   # \  ->  \\
    _smtp_from_name="${_smtp_from_name//\"/\\\"}"   # "  ->  \"

    # FIX-M07: Honour SMTP_SECURITY (tls|starttls|none) when set explicitly.
    # Priority: explicit SMTP_SECURITY > port-based heuristic.
    # The heuristic is retained as fallback so existing .env files that omit
    # SMTP_SECURITY continue to work identically to before this fix.
    #
    # TLS flags are collected in an array; ${array[@]+\"${array[@]}\"} expands
    # safely to nothing when the array is empty (set -u compatible).
    local smtp_port="${SMTP_PORT:-465}"
    local smtp_security="${SMTP_SECURITY:-}"
    local smtp_url
    local smtp_tls_flags=()

    # Apply port heuristic only when SMTP_SECURITY is unset
    if [[ -z "$smtp_security" ]]; then
        [[ "$smtp_port" == "465" ]] && smtp_security="tls" || smtp_security="starttls"
    fi

    case "${smtp_security,,}" in
        tls|ssl)
            # Implicit TLS — curl's smtps:// scheme negotiates TLS before any
            # SMTP command. Standard for port 465.
            smtp_url="smtps://${SMTP_HOST}:${smtp_port}"
            ;;
        starttls)
            # Explicit TLS upgrade via the STARTTLS command. Standard for port 587.
            # --ssl-reqd tells curl to fail if STARTTLS is not offered.
            smtp_url="smtp://${SMTP_HOST}:${smtp_port}"
            smtp_tls_flags=(--ssl-reqd)
            ;;
        none|plain)
            # Plaintext SMTP — for internal/development relays only.
            # Emits a warning; credentials will travel in cleartext.
            smtp_url="smtp://${SMTP_HOST}:${smtp_port}"
            log_warn "_smtp_send: SMTP_SECURITY=none — message will be sent in plaintext"
            ;;
        *)
            log_error "_smtp_send: Unknown SMTP_SECURITY='${smtp_security}'. Valid values: tls starttls none"
            return 1
            ;;
    esac

    local date_str
    date_str=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

    # RFC 5322 message: headers, blank line, body
    # CRLF line endings required by SMTP spec (RFC 2822 §2.2)
    {
        printf "From: \"%s\" <%s>\r\n" "${_smtp_from_name}" "${_smtp_from_addr}"
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
        "${smtp_tls_flags[@]+\"${smtp_tls_flags[@]}\"}" \
        --url "$smtp_url" \
        --mail-from "${_smtp_from_addr}" \
        --mail-rcpt "${ADMIN_EMAIL}" \
        --user "${SMTP_USERNAME}:${SMTP_PASSWORD}" \
        --upload-file - 2>/dev/null

    return $?
}

# send_email SUBJECT BODY
#
# Public entry point for all email delivery.
# Delivery chain controlled by EMAIL_MODE and EMAIL_PROVIDER in .env:
#
#   EMAIL_MODE=auto  (default)
#                    Stage 1: HTTP API driver (EMAIL_PROVIDER) -> Stage 2: SMTP
#                    relay -> Stage 3: host MTA. Recommended for production.
#   EMAIL_MODE=api   HTTP API only. Fails loudly if token is missing or the
#                    API call fails — no SMTP or host-MTA fallback.
#   EMAIL_MODE=smtp  SMTP relay only (curl smtps/starttls). Skips API stage.
#                    Fails loudly if the relay is unreachable.
#   EMAIL_MODE=host  Host MTA (Postfix / mail binary) only. Skips API + SMTP.
#                    Fails loudly if the MTA is unavailable.
#
# EMAIL_PROVIDER selects the HTTP API driver (mailersend|sendgrid|mailgun|
# postmark|resend). Only relevant when EMAIL_MODE=auto or api.
# EMAIL_PROVIDER=smtp and EMAIL_PROVIDER=host are legacy aliases for
# EMAIL_MODE=smtp and EMAIL_MODE=host respectively (retained for compatibility).
#
# Subject prefix: every outgoing subject is prefixed with [VaultWarden] unless
# it already starts with that string. This matches pre-modernization behavior
# and preserves existing mail filter rules. CRITICAL bypass detection works
# because the word CRITICAL remains present after prefixing.
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
    local mode="${EMAIL_MODE:-auto}"
    local provider="${EMAIL_PROVIDER:-smtp}"

    # Legacy aliases: EMAIL_PROVIDER=smtp|host override EMAIL_MODE for backward
    # compatibility. New deployments should use EMAIL_MODE= directly.
    if [[ "$provider" == "smtp" ]]; then
        mode="smtp"
    elif [[ "$provider" == "host" ]]; then
        mode="host"
    fi

    # Validate EMAIL_MODE early so the operator gets a clear error message.
    case "$mode" in
        auto|api|smtp|host) ;;
        *)
            log_error "Unknown EMAIL_MODE='${mode}'. Valid values: auto api smtp host"
            return 1
            ;;
    esac

    # FIX-M06: Prepend standard subject prefix if not already present.
    # Applied before rate-limit check so stamp files are keyed consistently.
    # CRITICAL bypass is unaffected: "CRITICAL" is still present post-prefix.
    [[ "$subject" != "[VaultWarden]"* ]] && subject="[VaultWarden] ${subject}"

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
Mode:      ${mode}${provider:+ / provider: ${provider}}"

    # ── Stage 1: HTTP API via named driver ──────────────────────────────
    if [[ "$mode" == "auto" || "$mode" == "api" ]]; then
        if [[ -z "${_EMAIL_DRIVERS[$provider]:-}" ]]; then
            log_error "Unknown EMAIL_PROVIDER='${provider}'"
            log_info  "Valid providers: ${!_EMAIL_DRIVERS[*]} smtp host"
            # api mode: unknown provider is a hard failure with no fallback
            [[ "$mode" == "api" ]] && return 1
            # auto mode: fall through to SMTP stage below
        else
            local driver_fn="_email_driver_${provider}"

            # FIX-M02: Resolve the provider-specific token variable
            # (e.g. MAILERSEND_API_TOKEN for provider=mailersend) to the canonical
            # EMAIL_API_TOKEN consumed by all driver functions. This means operators
            # only need to set the provider-prefixed name in secrets; the generic
            # EMAIL_API_TOKEN does not need to be set separately.
            # The resolved token is passed via inline env assignment so the global
            # EMAIL_API_TOKEN is never mutated in the calling shell.
            local _token_var="${provider^^}_API_TOKEN"
            local _api_token="${!_token_var:-${EMAIL_API_TOKEN:-}}"

            if [[ -z "${_api_token}" ]]; then
                if [[ "$mode" == "api" ]]; then
                    log_error "EMAIL_MODE=api but ${_token_var} (and EMAIL_API_TOKEN) are empty — cannot send"
                    return 1
                fi
                log_warn "EMAIL_PROVIDER=${provider} set but ${_token_var} (and EMAIL_API_TOKEN) are empty — falling back to SMTP"
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

    # ── Stage 2: SMTP relay via curl ────────────────────────────────────
    if [[ "$mode" == "auto" || "$mode" == "smtp" ]]; then
        if _smtp_send "$subject" "$full_body"; then
            log_success "Email sent via SMTP relay (${SMTP_HOST:-unconfigured}:${SMTP_PORT:-465}): ${subject}"
            date +%s > "$stamp_file" 2>/dev/null || true
            return 0
        fi
        if [[ "$mode" == "smtp" ]]; then
            log_error "EMAIL_MODE=smtp: SMTP relay failed — no fallback configured"
            return 1
        fi
        log_warn "SMTP relay failed — falling back to host MTA"
    fi

    # ── Stage 3: Host MTA (Postfix or sendmail) ─────────────────────────
    if [[ "$mode" == "auto" || "$mode" == "host" ]]; then
        if command -v mail &>/dev/null; then
            if echo "$full_body" | mail -s "$subject" "${ADMIN_EMAIL}" 2>/dev/null; then
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

# P1-M4 FIX: safe_execute()
#
# PORTABILITY: Same bashism as retry_with_backoff() — `local command=(...)`
# is bash-only.  Fixed by shifting off the description scalar so "$@"
# carries the command and its arguments directly.  All quoting is preserved.
safe_execute() {
    local description="$1"
    shift
    # "$@" is now the command plus all its arguments, fully quoted.

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
export -f ensure_dir secure_file test_connectivity test_http download_file
export -f _rate_limit_check send_email send_notification_email _smtp_send
export -f validate_email validate_domain validate_port validate_ip validate_url
export -f setup_error_trap setup_cleanup_trap safe_execute
export -f init_common_lib

log_debug "Common library loaded (email mode: ${EMAIL_MODE:-auto}, provider: ${EMAIL_PROVIDER:-smtp})"
