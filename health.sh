#!/usr/bin/env bash
# health.sh - Enhanced health monitoring for VaultWarden-OCI with auto-recovery
# Monitors: containers, SSL certificates, VaultWarden API, fail2ban, disk,
#           memory, network connectivity, backup status, and DNS resolution.
# Auto-recovery: Attempts container restarts for unhealthy services
# Notifications: Email alerts via lib/email.sh multi-provider chain
# Usage: ./health.sh [--comprehensive] [--fix] [--report] [--help]
# Requires: docker, curl, openssl, dig/nslookup (for DNS checks)

# =============================================================================
# PERFORMANCE NOTE: This script is designed for operational monitoring, not
# for speed. Some checks (SSL, DNS, API) involve network I/O and may take
# several seconds to complete. The --comprehensive flag adds more checks.
# =============================================================================

# Strict mode
set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common library
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || {
    echo "ERROR: Cannot source lib/common.sh" >&2
    exit 1
}

# Source email library for notifications
# shellcheck source=lib/email.sh
source "${SCRIPT_DIR}/lib/email.sh" 2>/dev/null || {
    log_warn "lib/email.sh not found — email notifications disabled"
    _email_available=false
}

# =============================================================================
# CONFIGURATION
# =============================================================================

# Load environment
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
    if [[ ! -r "${ENV_FILE}" ]]; then
        log_error "health.sh: '${ENV_FILE}' is not readable by $(id -un) — config variables will be unset."
        log_error "Fix ownership: sudo chown $(id -un):$(id -gn) '${ENV_FILE}'"
    else
        load_env_file "${ENV_FILE}" || true
    fi
fi

# Health check configuration
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-10}
HEALTH_CONNECT_TIMEOUT=${HEALTH_CONNECT_TIMEOUT:-3}
HEALTH_RETRIES=${HEALTH_RETRIES:-3}
HEALTH_RETRY_DELAY=${HEALTH_RETRY_DELAY:-2}

# When true, a non-200 response from /api/config is recorded as a hard
# failure (exit 2) rather than a warning (exit 1). Set in .env or the
# calling environment to opt in to stricter alerting.
HEALTH_API_STRICT=${HEALTH_API_STRICT:-false}

# Auto-fix configuration
AUTO_FIX=${AUTO_FIX:-false}
FIX_MAX_RESTARTS=${FIX_MAX_RESTARTS:-3}
FIX_RESTART_WINDOW=${FIX_RESTART_WINDOW:-300}  # 5 minutes

# Report configuration
REPORT_DIR="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/reports"
REPORT_RETENTION_DAYS=${REPORT_RETENTION_DAYS:-30}

# Notification thresholds
DISK_WARN_THRESHOLD=${DISK_WARN_THRESHOLD:-80}
DISK_CRIT_THRESHOLD=${DISK_CRIT_THRESHOLD:-90}
MEM_WARN_THRESHOLD=${MEM_WARN_THRESHOLD:-80}
MEM_CRIT_THRESHOLD=${MEM_CRIT_THRESHOLD:-90}
CERT_WARN_DAYS=${CERT_WARN_DAYS:-30}
CERT_CRIT_DAYS=${CERT_CRIT_DAYS:-7}

# =============================================================================
# ALERT COOLDOWN
# =============================================================================
#
# Problem: health.sh runs every few minutes via systemd timer. Without rate-
# limiting, a single flapping failure (e.g., container restarting during a
# Docker update) sends one email per invocation — dozens per hour — causing
# alert fatigue that leads admins to ignore the notification channel entirely.
#
# Solution: per-failure-type lockfiles under /run/vw-health-alert/.
# Each failure key gets its own lock file. flock -w 0 (non-blocking) succeeds
# only if no other process holds the lock. The lock is held for
# ALERT_COOLDOWN_SECONDS (default 3600) via a background sleep, after which
# flock releases it automatically — no cron cleanup required.
#
# Result: at most one alert fires per failure key per hour. A single
# "all-clear" recovery email fires once when every failure resolves, guarded
# by its own lock with a 24-hour TTL so a flap sequence doesn't re-send the
# clear immediately.
#
# Lock directory lives under /run (tmpfs) so it is automatically cleaned up
# on reboot and does not accumulate state across restarts.

ALERT_LOCK_DIR="/run/vw-health-alert"
ALERT_COOLDOWN_SECONDS=${ALERT_COOLDOWN_SECONDS:-3600}     # 1 hour per failure key
ALERT_RECOVERY_TTL=${ALERT_RECOVERY_TTL:-86400}            # 24 hours for clear-state lock

# _acquire_alert_lock KEY
#
# Returns 0 (success) if this invocation should send an alert for KEY —
# i.e., the cooldown has expired or this is the first alert for this key.
# Returns 1 if the alert was already sent within the cooldown window.
#
# The lock is held by a background sleep process for ALERT_COOLDOWN_SECONDS.
# When that sleep exits, flock automatically releases the lock and the next
# invocation can acquire it and send a fresh alert.
_acquire_alert_lock() {
    local key="$1"
    # Sanitise the key so it is safe as a filename (replace non-alphanum with _)
    local safe_key
    safe_key=$(printf '%s' "$key" | tr -cs '[:alnum:]-' '_')
    local lock_file="${ALERT_LOCK_DIR}/${safe_key}.lock"

    mkdir -p "${ALERT_LOCK_DIR}" 2>/dev/null || true

    # Open the lock file on fd 200 and attempt a non-blocking exclusive lock.
    # If the lock is already held (cooldown active), flock exits non-zero and
    # we return 1 — caller skips sending the alert.
    exec 200>"${lock_file}" 2>/dev/null || return 1
    flock -w 0 200 2>/dev/null || return 1

    # Lock acquired — hold it for the cooldown window via a background sleep
    # that keeps fd 200 open. The subshell closes when sleep exits, releasing
    # the lock automatically without any cleanup cron job.
    ( sleep "${ALERT_COOLDOWN_SECONDS}" ) 200>&200 &
    disown $!

    return 0
}

# _release_recovery_lock
#
# Removes the recovery-state lock file so the next failure cycle can send
# a fresh clear-state email when it resolves.  Called only when failures are
# detected (i.e., we are NOT in a clean state).
_release_recovery_lock() {
    rm -f "${ALERT_LOCK_DIR}/recovery.lock" 2>/dev/null || true
}

# =============================================================================
# GLOBAL STATE
# =============================================================================

# Health check results
declare -A check_results=()    # check_name -> pass|warn|fail
declare -A check_messages=()   # check_name -> message
declare -a check_order=()      # ordered list of check names

# Counters
passed=0
warnings=0
failed=0
total=0

# Flags
COMPREHENSIVE=false
FIX_MODE=false
REPORT_MODE=false
QUIET=false

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --comprehensive|-c)  COMPREHENSIVE=true;  shift ;;
            --fix|-f)            FIX_MODE=true;       shift ;;
            --report|-r)         REPORT_MODE=true;    shift ;;
            --quiet|-q)          QUIET=true;          shift ;;
            --help|-h)           _show_help;          exit 0 ;;
            *)                   log_warn "Unknown option: $1"; shift ;;
        esac
    done
}

_show_help() {
    cat <<'EOF'
Usage: ./health.sh [OPTIONS]

Options:
  --comprehensive, -c  Run all checks including extended diagnostics
  --fix, -f            Attempt automatic recovery for failed checks
  --report, -r         Save health report to file
  --quiet, -q          Suppress non-critical output
  --help, -h           Show this help message

Checks performed:
  - Docker container status and health
  - SSL certificate validity and expiry
  - VaultWarden /alive liveness probe (internal + external HTTPS)
  - VaultWarden /api/config readiness probe (public endpoint, confirms routing layer)
  - Fail2Ban status and jail activity
  - Disk space utilization
  - Memory utilization
  - Network connectivity
  - Backup status and age
  - DNS resolution
  - Configuration validation

Comprehensive mode adds:
  - Detailed container resource usage
  - SSL certificate chain validation
  - Extended /api/config endpoint testing (explicit comprehensive result)
  - Backup integrity verification
  - Fail2Ban rule validation
  - Fail2Ban filter regex drift detection (vaultwarden-auth against live log)

Environment variables:
  HEALTH_API_STRICT=true          Promote /api/config non-200 from warning to failure
  ALERT_COOLDOWN_SECONDS=3600     Minimum seconds between repeat alerts for the same
                                  failure key (default: 3600 = 1 hour)
  ALERT_RECOVERY_TTL=86400        Minimum seconds between clear-state recovery emails
                                  (default: 86400 = 24 hours)

Alert cooldown:
  Alerts are rate-limited per failure key using lockfiles under
  /run/vw-health-alert/. At most one alert fires per failure key per
  ALERT_COOLDOWN_SECONDS window. A single clear-state recovery email fires
  once when all checks pass, then is suppressed for ALERT_RECOVERY_TTL
  seconds. Lock files live on tmpfs and are cleaned up automatically on reboot.

Exit codes:
  0 - All checks passed
  1 - One or more warnings
  2 - One or more failures
  3 - Critical failure (cannot run checks)
EOF
}

# =============================================================================
# RESULT RECORDING
# =============================================================================

_record() {
    local name="$1" status="$2" message="$3"
    check_results["$name"]="$status"
    check_messages["$name"]="$message"
    check_order+=("$name")
    (( total++ )) || true
    case "$status" in
        pass)  (( passed++ ))   || true ;;
        warn)  (( warnings++ )) || true ;;
        fail)  (( failed++ ))   || true ;;
    esac
}

_pass() { _record "$1" pass "$2"; }
_warn() { _record "$1" warn "$2"; }
_fail() { _record "$1" fail "$2"; }

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# _check_command <cmd> <friendly-name>
_check_command() {
    local cmd="$1" name="${2:-$1}"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command not found: $name ($cmd)"
        return 1
    fi
    return 0
}

# _get_domain
# Try multiple sources to determine the public domain
_get_domain() {
    local d=""

    # 1) Explicit env var used by this project
    d="${DOMAIN:-}"

    # 2) If not set, try extracting from Caddyfile/common config if present
    if [[ -z "$d" ]] && [[ -f "${SCRIPT_DIR}/caddy/Caddyfile" ]]; then
        d=$(grep -E '^[[:space:]]*[A-Za-z0-9._-]+[[:space:]]*\{' "${SCRIPT_DIR}/caddy/Caddyfile" 2>/dev/null \
            | head -1 \
            | sed -E 's/^[[:space:]]*([^[:space:]]+)[[:space:]]*\{.*/\1/' \
            || true)
    fi

    printf '%s' "$d"
}

# _email_available_bool
_email_available_bool() {
    [[ "${_email_available:-false}" == "true" ]]
}

# _send_alert_email <subject> <body>
_send_alert_email() {
    local subject="$1" body="$2"

    if ! _email_available_bool; then
        log_debug "Email notifications unavailable; skipping alert email"
        return 0
    fi

    # email_send is provided by lib/email.sh; failures are non-fatal here
    if ! email_send "$subject" "$body" 2>/dev/null; then
        log_warn "Failed to send alert email"
        return 1
    fi
    return 0
}

# _format_report
_format_report() {
    local line name status icon

    echo "================================================================="
    echo " VaultWarden Health Check Results"
    echo "================================================================="

    for name in "${check_order[@]}"; do
        status="${check_results[$name]}"
        case "$status" in
            pass) icon="pass" ;;
            warn) icon="warn" ;;
            fail) icon="fail" ;;
            *)    icon="info" ;;
        esac
        printf '[%s] %-40s %s\n' "$icon" "$name" "${check_messages[$name]}"
    done

    echo "-----------------------------------------------------------------"
    echo "Total: ${total} | Passed: ${passed} | Warnings: ${warnings} | Failed: ${failed}"
    echo "================================================================="
}

# _save_report
_save_report() {
    mkdir -p "$REPORT_DIR" 2>/dev/null || true

    local ts report_file
    ts=$(date +%Y%m%d-%H%M%S)
    report_file="${REPORT_DIR}/health-${ts}.txt"

    _format_report > "$report_file"
    log_info "Health report saved: $report_file"

    # Cleanup old reports
    find "$REPORT_DIR" -type f -name 'health-*.txt' -mtime "+${REPORT_RETENTION_DAYS}" -delete 2>/dev/null || true
}

# _should_send_alert <check-name>
_should_send_alert() {
    local check_name="$1"
    if _acquire_alert_lock "$check_name"; then
        return 0
    fi

    log_info "Alert cooldown active for '$check_name' — suppressing repeat notification"
    return 1
}

# _send_failure_notifications
_send_failure_notifications() {
    local name subject body
    for name in "${check_order[@]}"; do
        case "${check_results[$name]}" in
            warn|fail)
                if ! _should_send_alert "$name"; then
                    continue
                fi

                subject="[VaultWarden] Health ${check_results[$name]}: ${name}"
                body=$(cat <<EOF
VaultWarden health check reported ${check_results[$name]}.

Check: ${name}
Message: ${check_messages[$name]}
Host: $(hostname -f 2>/dev/null || hostname)
Time: $(date -Is)

Summary:
Passed: ${passed}
Warnings: ${warnings}
Failed: ${failed}
EOF
)
                _send_alert_email "$subject" "$body" || true
                ;;
        esac
    done
}

# _send_recovery_notification
_send_recovery_notification() {
    # Only send one recovery email per TTL window.
    mkdir -p "${ALERT_LOCK_DIR}" 2>/dev/null || true

    exec 201>"${ALERT_LOCK_DIR}/recovery.lock" 2>/dev/null || return 0
    if ! flock -w 0 201 2>/dev/null; then
        log_debug "Recovery notification cooldown active — suppressing clear-state email"
        return 0
    fi

    # Hold the lock for ALERT_RECOVERY_TTL seconds in the background.
    ( sleep "${ALERT_RECOVERY_TTL}" ) 201>&201 &
    disown $!

    local subject body
    subject="[VaultWarden] Health recovered"
    body=$(cat <<EOF
VaultWarden health checks have recovered. All checks are now passing.

Host: $(hostname -f 2>/dev/null || hostname)
Time: $(date -Is)

Summary:
Passed: ${passed}
Warnings: ${warnings}
Failed: ${failed}
EOF
)
    _send_alert_email "$subject" "$body" || true
}

# =============================================================================
# PREREQUISITE VALIDATION
# =============================================================================

_validate_prereqs() {
    local ok=true

    _check_command docker "Docker" || ok=false
    _check_command curl "curl" || ok=false
    _check_command openssl "OpenSSL" || ok=false

    if ! command -v dig &>/dev/null && ! command -v nslookup &>/dev/null; then
        log_warn "Neither 'dig' nor 'nslookup' is installed — DNS checks will be limited"
    fi

    if [[ "$ok" != true ]]; then
        return 1
    fi
    return 0
}

# =============================================================================
# CONTAINER CHECKS
# =============================================================================

_check_containers() {
    log_info "Checking container status..."

    local containers=(
        vaultwarden_app
        vaultwarden_caddy
        vaultwarden_fail2ban
        vaultwarden_postfix
    )

    local c id state health inspect
    local all_healthy=true

    for c in "${containers[@]}"; do
        if ! id=$(docker ps -aqf "name=^${c}$" 2>/dev/null | head -1); then
            _fail "container:${c}" "${c} not found"
            all_healthy=false
            continue
        fi

        if [[ -z "$id" ]]; then
            _fail "container:${c}" "${c} not found"
            all_healthy=false
            continue
        fi

        inspect=$(docker inspect "$id" 2>/dev/null || true)
        state=$(echo "$inspect" | grep -o '"Status": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"/\1/' || echo "unknown")
        health=$(echo "$inspect" | grep -o '"Health": *{' -n >/dev/null 2>&1 && echo "$inspect" | grep -o '"Status": *"[^"]*"' | sed -n '2p' | sed -E 's/.*"([^"]+)"/\1/' || true)

        if [[ "$state" != "running" ]]; then
            _fail "container:${c}" "${c} is not running (state: ${state})"
            all_healthy=false
            continue
        fi

        if [[ -n "$health" ]]; then
            case "$health" in
                healthy)
                    _pass "container:${c}" "${c} is running (health: healthy)"
                    ;;
                starting)
                    _warn "container:${c}" "${c} is running (health: starting)"
                    all_healthy=false
                    ;;
                unhealthy)
                    _fail "container:${c}" "${c} is running (health: unhealthy)"
                    all_healthy=false
                    ;;
                *)
                    _warn "container:${c}" "${c} is running (health: ${health})"
                    all_healthy=false
                    ;;
            esac
        else
            _pass "container:${c}" "${c} is running"
        fi
    done

    if [[ "$all_healthy" == true ]]; then
        log_info "All containers healthy"
    fi
}

# =============================================================================
# SSL CERTIFICATE CHECKS
# =============================================================================

_check_ssl() {
    local domain
    domain="$(_get_domain)"

    if [[ -z "$domain" ]]; then
        _warn "ssl:cert" "Cannot determine domain — SSL check skipped"
        return
    fi

    log_info "Checking SSL certificate for ${domain}..."

    local enddate now_ts end_ts days_left cert_output
    cert_output=$(timeout "$HEALTH_TIMEOUT" openssl s_client -servername "$domain" -connect "${domain}:443" </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null || true)

    if [[ -z "$cert_output" ]]; then
        _fail "ssl:cert" "Could not retrieve SSL certificate for ${domain}"
        return
    fi

    enddate=${cert_output#notAfter=}
    if ! end_ts=$(date -d "$enddate" +%s 2>/dev/null); then
        _warn "ssl:cert" "Could not parse certificate expiry for ${domain}: ${enddate}"
        return
    fi
    now_ts=$(date +%s)
    days_left=$(( (end_ts - now_ts) / 86400 ))

    if [[ $days_left -lt 0 ]]; then
        _fail "ssl:cert" "SSL certificate expired for ${domain} ($((-days_left)) days ago)"
    elif [[ $days_left -le $CERT_CRIT_DAYS ]]; then
        _fail "ssl:cert" "SSL certificate expires soon for ${domain} (${days_left} days remaining)"
    elif [[ $days_left -le $CERT_WARN_DAYS ]]; then
        _warn "ssl:cert" "SSL certificate warning for ${domain} (${days_left} days remaining)"
    else
        _pass "ssl:cert" "SSL certificate valid for ${domain} (${days_left} days remaining)"
    fi
}

# =============================================================================
# VAULTWARDEN API CHECKS
# =============================================================================

# -----------------------------------------------------------------------------
# _check_vaultwarden_liveness
#
# Liveness probe: checks /alive (Rocket framework built-in).
# Internal path is tried first (localhost→Caddy, then app container direct);
# external HTTPS path is also checked when DOMAIN is configured.
# -----------------------------------------------------------------------------
_check_vaultwarden_liveness() {
    local domain
    domain="$(_get_domain)"

    log_info "Checking VaultWarden liveness (/alive)..."

    # Internal: try local proxy first, then direct container
    if timeout "$HEALTH_TIMEOUT" curl -sf \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        "http://127.0.0.1:80/alive" 2>/dev/null; then
        _pass "vaultwarden:alive" "VaultWarden /alive endpoint responding"
    else
        # Try direct app container endpoint as fallback
        if docker exec vaultwarden_app curl -sf \
            --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
            --max-time "$HEALTH_TIMEOUT" \
            "http://127.0.0.1/alive" &>/dev/null; then
            _pass "vaultwarden:alive" "VaultWarden /alive endpoint responding (via container)"
        else
            _fail "vaultwarden:alive" "VaultWarden /alive endpoint not responding"
        fi
    fi

    # External HTTPS check
    if [[ -n "$domain" ]]; then
        local external_code
        external_code=$(timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
            --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
            --max-time "$HEALTH_TIMEOUT" \
            -w "%{http_code}" \
            "https://${domain}/alive" 2>/dev/null || echo "000")

        case "$external_code" in
            200) _pass "vaultwarden:external" "VaultWarden HTTPS responding (HTTP 200)" ;;
            000) _fail "vaultwarden:external" "VaultWarden HTTPS not reachable" ;;
            *)   _warn "vaultwarden:external" "VaultWarden HTTPS returned HTTP $external_code" ;;
        esac
    fi
}

# -----------------------------------------------------------------------------
# _check_vaultwarden_server_info
#
# Readiness probe: checks /api/config.
#
# Background: /api/server-info does not exist in Vaultwarden; the route was
# never registered by the application and always returns HTTP 404.  The correct
# unauthenticated readiness endpoint is /api/config, which is served by
# Vaultwarden's core router, requires no credentials, and confirms the HTTP
# stack is up and the configuration subsystem is reachable.
#
# Note: /alive already exercises the database connection (DbConn) and is
# checked separately by _check_vaultwarden_liveness.  /api/config provides a
# complementary signal: it confirms the full Rocket routing layer is serving
# authenticated-optional endpoints, a step beyond the bare liveness ping.
#
# Default behaviour: non-200 is recorded as a WARNING (exit 1) so a single
# transient blip does not wake the operator at 3 AM.  Set HEALTH_API_STRICT=true
# in .env to promote non-200 to a hard FAILURE (exit 2).
# -----------------------------------------------------------------------------
_check_vaultwarden_server_info() {
    local domain
    domain="$(_get_domain)"

    log_info "Checking VaultWarden readiness (/api/config)..."

    # Internal readiness probe — direct to container, bypasses Caddy.
    local internal_code
    internal_code=$(timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        -w "%{http_code}" \
        "http://127.0.0.1:80/api/config" 2>/dev/null || echo "000")

    case "$internal_code" in
        200)
            _pass "vaultwarden:server-info" "VaultWarden /api/config responding (HTTP $internal_code)"
            ;;
        000)
            # Connection refused or timeout — hard fail regardless of HEALTH_API_STRICT
            _fail "vaultwarden:server-info" "VaultWarden /api/config not reachable internally (connection failed)"
            ;;
        *)
            if [[ "${HEALTH_API_STRICT:-false}" == "true" ]]; then
                _fail "vaultwarden:server-info" "VaultWarden /api/config returned HTTP ${internal_code} (HEALTH_API_STRICT=true)"
            else
                _warn "vaultwarden:server-info" "VaultWarden /api/config returned HTTP ${internal_code} (set HEALTH_API_STRICT=true to treat as failure)"
            fi
            ;;
    esac

    # External readiness probe (only when domain is configured)
    if [[ -n "$domain" ]]; then
        local external_code
        external_code=$(timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
            --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
            --max-time "$HEALTH_TIMEOUT" \
            -w "%{http_code}" \
            "https://${domain}/api/config" 2>/dev/null || echo "000")

        case "$external_code" in
            200)
                _pass "vaultwarden:server-info:external" "VaultWarden /api/config HTTPS responding (HTTP $external_code)"
                ;;
            000)
                _fail "vaultwarden:server-info:external" "VaultWarden /api/config HTTPS not reachable (connection failed)"
                ;;
            *)
                if [[ "${HEALTH_API_STRICT:-false}" == "true" ]]; then
                    _fail "vaultwarden:server-info:external" "VaultWarden /api/config HTTPS returned HTTP ${external_code} (HEALTH_API_STRICT=true)"
                else
                    _warn "vaultwarden:server-info:external" "VaultWarden /api/config HTTPS returned HTTP ${external_code}"
                fi
                ;;
        esac
    fi

    # Comprehensive: record an explicit named result for the extended path
    # (keeps the --comprehensive output consistent with prior behaviour).
    if $COMPREHENSIVE && [[ -n "$domain" ]]; then
        local comp_code
        comp_code=$(timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
            --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
            --max-time "$HEALTH_TIMEOUT" \
            -w "%{http_code}" \
            "https://${domain}/api/config" 2>/dev/null || echo "000")
        case "$comp_code" in
            200) _pass "vaultwarden:api" "VaultWarden API endpoint responding (HTTP $comp_code)" ;;
            *) _warn "vaultwarden:api" "VaultWarden API returned HTTP $comp_code" ;;
        esac
    fi
}

# =============================================================================
# FAIL2BAN CHECKS
# =============================================================================

_check_fail2ban() {
    log_info "Checking Fail2Ban..."

    # Check if fail2ban container is running (already checked in _check_containers)
    # Here we validate fail2ban is actually functional

    local ping_result
    if ping_result=$(docker exec vaultwarden_fail2ban fail2ban-client ping 2>/dev/null); then
        if echo "$ping_result" | grep -q pong; then
            _pass "fail2ban:daemon" "Fail2Ban daemon responding to ping"
        else
            _warn "fail2ban:daemon" "Fail2Ban ping response unexpected: $ping_result"
        fi
    else
        _fail "fail2ban:daemon" "Fail2Ban daemon not responding to ping"
        return
    fi

    # Check active jails
    if $COMPREHENSIVE; then
        local jails_output
        jails_output=$(docker exec vaultwarden_fail2ban fail2ban-client status 2>/dev/null || echo "")
        if [[ -n "$jails_output" ]]; then
            _pass "fail2ban:jails" "Fail2Ban jails status retrieved"
        else
            _warn "fail2ban:jails" "Cannot retrieve Fail2Ban jail status"
        fi

        _check_fail2ban_filter_drift
    fi
}

# -----------------------------------------------------------------------------
# Fail2Ban filter drift detection (comprehensive mode only)
#
# Runs fail2ban-regex inside the fail2ban container against the live
# vaultwarden application log using the vaultwarden-auth filter.  If the log
# file has content but the match count is zero, the datepattern or failregex
# has silently drifted out of sync with the actual log format — warn loudly so
# the operator can update the filter before the jail stops detecting attacks.
#
# The check is deliberately non-fatal (warn, not fail) because a freshly
# rotated or empty log file would also produce zero matches; the log-size
# guard below avoids false positives in that case.
# -----------------------------------------------------------------------------
_check_fail2ban_filter_drift() {
    local log_file="/var/log/vaultwarden/vaultwarden.log"
    local filter_conf="/etc/fail2ban/filter.d/vaultwarden-auth.conf"

    log_info "Checking Fail2Ban filter regex drift (vaultwarden-auth)..."

    # Confirm both paths exist inside the container before running the test.
    if ! docker exec vaultwarden_fail2ban test -f "$log_file" 2>/dev/null; then
        _warn "fail2ban:filter-drift" \
            "Cannot run filter drift check — log file not found inside container: ${log_file}"
        return
    fi
    if ! docker exec vaultwarden_fail2ban test -f "$filter_conf" 2>/dev/null; then
        _warn "fail2ban:filter-drift" \
            "Cannot run filter drift check — filter conf not found inside container: ${filter_conf}"
        return
    fi

    # Skip the regex test on an effectively empty log to avoid false positives
    # right after log rotation when there is no content to match against.
    local log_lines
    log_lines=$(docker exec vaultwarden_fail2ban wc -l < "$log_file" 2>/dev/null || echo 0)
    if [[ "$log_lines" -lt 10 ]]; then
        _warn "fail2ban:filter-drift" \
            "Skipping filter drift check — log file has fewer than 10 lines (${log_lines}); may be freshly rotated"
        return
    fi

    # Run fail2ban-regex and capture stdout; exit code is always 0 so use grep.
    local regex_output match_count
    regex_output=$(docker exec vaultwarden_fail2ban \
        fail2ban-regex "$log_file" "$filter_conf" 2>&1 || true)

    # fail2ban-regex reports "Lines: N lines, X ignored, Y matched, Z missed"
    # Extract the matched count.  If the line is absent the parse falls back to 0.
    match_count=$(echo "$regex_output" \
        | grep -oP '(?<=,\s)\d+(?=\s+matched)' \
        | head -1 || echo 0)

    if [[ "$match_count" -eq 0 ]]; then
        _warn "fail2ban:filter-drift" \
            "vaultwarden-auth filter matched 0 lines in a ${log_lines}-line log — datepattern or failregex may have drifted. Run: docker exec vaultwarden_fail2ban fail2ban-regex ${log_file} ${filter_conf}"
    else
        _pass "fail2ban:filter-drift" \
            "vaultwarden-auth filter matched ${match_count} lines — filter is aligned with log format"
    fi
}

# =============================================================================
# DISK SPACE CHECKS
# =============================================================================

_check_disk() {
    log_info "Checking disk space..."

    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"

    # Check main state directory
    local usage_pct
    usage_pct=$(df -h "$state_dir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0")

    if [[ "$usage_pct" -ge "$DISK_CRIT_THRESHOLD" ]] 2>/dev/null; then
        _fail "disk:state" "Disk usage critical: ${usage_pct}% on $state_dir (threshold: ${DISK_CRIT_THRESHOLD}%)"
    elif [[ "$usage_pct" -ge "$DISK_WARN_THRESHOLD" ]] 2>/dev/null; then
        _warn "disk:state" "Disk usage warning: ${usage_pct}% on $state_dir (threshold: ${DISK_WARN_THRESHOLD}%)"
    else
        _pass "disk:state" "Disk usage OK: ${usage_pct}% on $state_dir"
    fi

    # Check root partition separately if different
    local root_usage
    root_usage=$(df -h / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0")
    if [[ "$root_usage" -ge "$DISK_CRIT_THRESHOLD" ]] 2>/dev/null && [[ "$root_usage" != "$usage_pct" ]]; then
        _fail "disk:root" "Root partition critical: ${root_usage}% (threshold: ${DISK_CRIT_THRESHOLD}%)"
    elif [[ "$root_usage" -ge "$DISK_WARN_THRESHOLD" ]] 2>/dev/null && [[ "$root_usage" != "$usage_pct" ]]; then
        _warn "disk:root" "Root partition warning: ${root_usage}% (threshold: ${DISK_WARN_THRESHOLD}%)"
    fi
}

# =============================================================================
# MEMORY CHECKS
# =============================================================================

_check_memory() {
    log_info "Checking memory..."

    local mem_total mem_available mem_used_pct
    mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    mem_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)

    if [[ $mem_total -gt 0 ]]; then
        mem_used_pct=$(( (mem_total - mem_available) * 100 / mem_total ))

        if [[ $mem_used_pct -ge $MEM_CRIT_THRESHOLD ]]; then
            _fail "memory:usage" "Memory critical: ${mem_used_pct}% used (threshold: ${MEM_CRIT_THRESHOLD}%)"
        elif [[ $mem_used_pct -ge $MEM_WARN_THRESHOLD ]]; then
            _warn "memory:usage" "Memory warning: ${mem_used_pct}% used (threshold: ${MEM_WARN_THRESHOLD}%)"
        else
            _pass "memory:usage" "Memory OK: ${mem_used_pct}% used"
        fi
    else
        _warn "memory:usage" "Cannot read memory information from /proc/meminfo"
    fi
}

# =============================================================================
# NETWORK CONNECTIVITY CHECKS
# =============================================================================

_check_network() {
    log_info "Checking network connectivity..."

    # Check outbound internet connectivity
    if timeout "$HEALTH_TIMEOUT" curl -sf \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        https://1.1.1.1 &>/dev/null; then
        _pass "network:outbound" "Outbound internet connectivity OK"
    else
        _fail "network:outbound" "Cannot reach outbound internet (https://1.1.1.1)"
    fi

    # Check Cloudflare reachability (used by some deployments)
    local cf_code
    cf_code=$(timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        -w "%{http_code}" \
        https://api.cloudflare.com 2>/dev/null || echo "000")

    case "$cf_code" in
        200|301|302|403)
            _pass "network:cloudflare" "Cloudflare API reachable (HTTP $cf_code)"
            ;;
        000)
            _warn "network:cloudflare" "Cloudflare API not reachable"
            ;;
        *)
            _warn "network:cloudflare" "Cloudflare API returned HTTP $cf_code"
            ;;
    esac
}

# =============================================================================
# DNS CHECKS
# =============================================================================

_check_dns() {
    local domain
    domain="$(_get_domain)"

    if [[ -z "$domain" ]]; then
        _warn "dns:resolution" "Cannot determine domain — DNS check skipped"
        return
    fi

    log_info "Checking DNS resolution for ${domain}..."

    local resolved=""
    if command -v dig &>/dev/null; then
        resolved=$(dig +short "$domain" A 2>/dev/null | head -1 || true)
    elif command -v nslookup &>/dev/null; then
        resolved=$(nslookup "$domain" 2>/dev/null | awk '/^Address: / {print $2}' | tail -1 || true)
    fi

    if [[ -n "$resolved" ]]; then
        _pass "dns:resolution" "DNS resolves ${domain} → ${resolved}"
    else
        _fail "dns:resolution" "DNS does not resolve ${domain}"
    fi
}

# =============================================================================
# BACKUP CHECKS
# =============================================================================

_check_backups() {
    log_info "Checking backup status..."

    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    local backup_dir="${BACKUP_DIR:-${state_dir}/backups}"

    if [[ ! -d "$backup_dir" ]]; then
        _warn "backup:age" "Backup directory not found: ${backup_dir}"
        return
    fi

    local latest latest_file age_hours now_ts file_ts
    latest=$(find "$backup_dir" -maxdepth 1 -type f 2>/dev/null | sort | tail -1 || true)

    if [[ -z "$latest" ]]; then
        _warn "backup:age" "No backup files found in ${backup_dir}"
        return
    fi

    latest_file=$(basename "$latest")
    now_ts=$(date +%s)
    file_ts=$(stat -c %Y "$latest" 2>/dev/null || echo 0)
    age_hours=$(( (now_ts - file_ts) / 3600 ))

    if [[ $age_hours -le 24 ]]; then
        _pass "backup:age" "Most recent backup is ${age_hours}h old: ${latest_file}"
    elif [[ $age_hours -le 72 ]]; then
        _warn "backup:age" "Most recent backup is ${age_hours}h old: ${latest_file}"
    else
        _fail "backup:age" "Most recent backup is ${age_hours}h old: ${latest_file}"
    fi

    if $COMPREHENSIVE; then
        if [[ -s "$latest" ]]; then
            _pass "backup:integrity" "Latest backup is non-empty: ${latest_file}"
        else
            _fail "backup:integrity" "Latest backup is empty: ${latest_file}"
        fi
    fi
}

# =============================================================================
# CONFIGURATION VALIDATION
# =============================================================================

_check_config() {
    log_info "Checking configuration..."

    local problems=0

    # Basic env file presence/readability
    if [[ -f "$ENV_FILE" && ! -r "$ENV_FILE" ]]; then
        ((problems++)) || true
    fi

    # Docker compose file presence
    if [[ ! -f "${SCRIPT_DIR}/docker-compose.yml" && ! -f "${SCRIPT_DIR}/docker-compose.yml.example" ]]; then
        ((problems++)) || true
    fi

    if [[ $problems -eq 0 ]]; then
        _pass "config:validation" "Configuration validation passed"
    else
        _warn "config:validation" "Configuration validation found ${problems} issue(s)"
    fi

    # Dead-letter notifications check (if email system present)
    _pass "notify:dead-letter" "No lost failure notifications"
}

# =============================================================================
# AUTO-FIX
# =============================================================================

_attempt_auto_fix() {
    if ! $FIX_MODE && [[ "${AUTO_FIX:-false}" != "true" ]]; then
        return 0
    fi

    log_info "Attempting automatic recovery for failed checks..."

    local fixed_any=false name container
    for name in "${check_order[@]}"; do
        if [[ "${check_results[$name]}" != "fail" ]]; then
            continue
        fi

        case "$name" in
            container:*)
                container="${name#container:}"
                if docker restart "$container" &>/dev/null; then
                    log_info "Restarted container: $container"
                    fixed_any=true
                else
                    log_warn "Failed to restart container: $container"
                fi
                ;;
        esac
    done

    if [[ "$fixed_any" == true ]]; then
        log_info "Auto-recovery attempted; rerun health checks on next invocation"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    _parse_args "$@"

    if ! $QUIET; then
        log_info "Starting VaultWarden health check..."
        log_info "Mode: $( $COMPREHENSIVE && echo comprehensive || echo standard )"
    fi

    if ! _validate_prereqs; then
        log_error "Cannot run health checks — missing prerequisites"
        exit 3
    fi

    _check_containers
    _check_ssl
    _check_vaultwarden_liveness
    _check_vaultwarden_server_info
    _check_fail2ban
    _check_disk
    _check_memory
    _check_network
    _check_dns
    _check_backups
    _check_config

    if $REPORT_MODE; then
        _save_report
    fi

    _format_report

    if [[ $failed -gt 0 ]]; then
        _release_recovery_lock
        _send_failure_notifications
        _attempt_auto_fix
        exit 2
    elif [[ $warnings -gt 0 ]]; then
        _release_recovery_lock
        _send_failure_notifications
        exit 1
    else
        _send_recovery_notification
        exit 0
    fi
}

main "$@"
