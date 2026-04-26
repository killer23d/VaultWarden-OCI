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

# Load environment.
#
_resolve_env_file() {
    local candidates=(
        "${SCRIPT_DIR}/.env"
        "/etc/vaultwarden/vaultwarden.env"
    )
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    echo ""
    return 1
}

ENV_FILE="$(_resolve_env_file || true)"

if [[ -n "${ENV_FILE}" ]]; then
    if [[ ! -r "${ENV_FILE}" ]]; then
        log_error "health.sh: '${ENV_FILE}' is not readable by $(id -un) — config variables will be unset."
        log_error "Fix ownership: sudo chown $(id -un):$(id -gn) '${ENV_FILE}'"
    else
        load_env_file "${ENV_FILE}" || true
    fi
else
    # Neither candidate path exists; the script may still work if the
    # caller (e.g., systemd EnvironmentFile=) has already exported the
    # required variables into the process environment.
    log_warn "health.sh: no .env file found at '${SCRIPT_DIR}/.env' or '/etc/vaultwarden/vaultwarden.env' — relying on inherited environment"
    ENV_FILE="/etc/vaultwarden/vaultwarden.env"  # canonical path for error messages
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

# Fail2Ban daemon ping retry configuration.
# The fail2ban daemon socket may not be ready immediately after container
# start. Retry up to FAIL2BAN_PING_RETRIES times with FAIL2BAN_PING_DELAY
# seconds between attempts before recording a result.
FAIL2BAN_PING_RETRIES=${FAIL2BAN_PING_RETRIES:-5}
FAIL2BAN_PING_DELAY=${FAIL2BAN_PING_DELAY:-6}

# =============================================================================
# SINGLETON LOCK — prevents overlapping health-check runs
# =============================================================================

_HEALTH_RUN_LOCK_FILE="/run/lock/vaultwarden-health.lock"
_HEALTH_LOCK_FD=""

_acquire_run_lock() {
    exec {_HEALTH_LOCK_FD}>"$_HEALTH_RUN_LOCK_FILE" 2>/dev/null || {
        log_warn "Cannot open run-lock ${_HEALTH_RUN_LOCK_FILE} — proceeding without singleton guard"
        _HEALTH_LOCK_FD=""
        return 0
    }
    if ! flock -n "$_HEALTH_LOCK_FD" 2>/dev/null; then
        log_info "Another health check is already running — exiting"
        exit 0
    fi
}

_release_run_lock() {
    [[ -n "${_HEALTH_LOCK_FD:-}" ]] || return 0
    flock -u "$_HEALTH_LOCK_FD" 2>/dev/null || true
    eval "exec ${_HEALTH_LOCK_FD}>&-" 2>/dev/null || true
}

# =============================================================================
# ALERT COOLDOWN
# =============================================================================
#
# Cooldown state lives on persistent disk, not /run (which is wiped on
# container/host restart). Files are named <safe_key>.cooldown and contain
# a Unix epoch timestamp written at send time. TTL is checked on read.
# This survives reboots, container restarts, and systemd RuntimeDirectory
# teardown without losing cooldown state.
# =============================================================================

ALERT_LOCK_DIR="${ALERT_STATE_DIR:-/var/lib/vaultwarden/.vw-health-alert}"
ALERT_COOLDOWN_SECONDS=${ALERT_COOLDOWN_SECONDS:-3600}
ALERT_RECOVERY_TTL=${ALERT_RECOVERY_TTL:-86400}

# _acquire_alert_lock KEY
#
# Returns 0 if an alert should fire for KEY (cooldown expired or first alert).
# Returns 1 if still within the cooldown window.
# On return 0, writes the current epoch to the cooldown file — the caller
# MUST send the alert (or explicitly call _release_alert_lock KEY on failure).
#
# Uses a per-key timestamp file on persistent storage instead of flock on
# /run so that cooldown state survives container/host restarts.
_acquire_alert_lock() {
    local key="$1"
    local safe_key
    safe_key=$(printf '%s' "$key" | tr -cs '[:alnum:]-' '_')

    mkdir -p "${ALERT_LOCK_DIR}" 2>/dev/null || true

    local state_file="${ALERT_LOCK_DIR}/${safe_key}.cooldown"
    local ttl="${2:-${ALERT_COOLDOWN_SECONDS}}"
    local now
    now=$(date +%s)

    if [[ -f "$state_file" ]]; then
        local last_sent
        last_sent=$(cat "$state_file" 2>/dev/null || printf '0')
        if (( now - last_sent < ttl )); then
            return 1   # still within cooldown
        fi
    fi

    # Atomically claim the slot: write timestamp before returning 0.
    # Use a temp file + mv for atomic replacement (avoids partial reads).
    local tmp_file
    tmp_file=$(mktemp "${ALERT_LOCK_DIR}/.tmp.XXXXXXXXXX")
    printf '%s\n' "$now" > "$tmp_file"
    mv -f "$tmp_file" "$state_file"

    return 0
}

# _release_alert_lock KEY
#
# Removes the cooldown stamp for KEY so the next run can re-send immediately.
# Call this when a delivery failure occurs so the alert retries next cycle.
_release_alert_lock() {
    local key="$1"
    local safe_key
    safe_key=$(printf '%s' "$key" | tr -cs '[:alnum:]-' '_')
    rm -f "${ALERT_LOCK_DIR}/${safe_key}.cooldown" 2>/dev/null || true
}

# _release_recovery_lock
#
# Removes the recovery-state lock file so the next failure cycle can send
# a fresh clear-state email when it resolves.  Called only when failures are
# detected (i.e., we are NOT in a clean state).
_release_recovery_lock() {
    rm -f "${ALERT_LOCK_DIR}/recovery.cooldown" 2>/dev/null || true
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
  - VaultWarden /api/config readiness probe (requires live DB connection)
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
  FAIL2BAN_PING_RETRIES=5         Ping attempts before recording fail2ban result (default: 5)
  FAIL2BAN_PING_DELAY=6           Seconds between fail2ban ping retries (default: 6)
  ALERT_COOLDOWN_SECONDS=3600     Minimum seconds between repeat alerts for the same
                                  failure key (default: 3600 = 1 hour)
  ALERT_RECOVERY_TTL=86400        Minimum seconds between clear-state recovery emails
                                  (default: 86400 = 24 hours)

Alert cooldown:
  Alerts are rate-limited per failure key using timestamp files under
  /var/lib/vaultwarden/.vw-health-alert/. At most one alert fires per failure 
  key per ALERT_COOLDOWN_SECONDS window. A single clear-state recovery email 
  fires once when all checks pass, then is suppressed for ALERT_RECOVERY_TTL
  seconds. State survives reboots and container restarts.

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
# DOMAIN RESOLUTION
# =============================================================================

_get_domain() {
    if [[ -n "${DOMAIN_NAME:-}" ]]; then
        echo "${DOMAIN_NAME}"
    elif [[ -n "${DOMAIN:-}" ]]; then
        echo "${DOMAIN#https://}" | sed 's|http://||'
    else
        echo ""
    fi
}

# =============================================================================
# CONTAINER HEALTH CHECKS
# =============================================================================

_check_containers() {
    log_info "Checking container status..."

    local containers=("vaultwarden_app" "vaultwarden_caddy" "vaultwarden_fail2ban" "vaultwarden_postfix")
    local all_healthy=true

    for container in "${containers[@]}"; do
        if ! docker inspect "$container" &>/dev/null; then
            _fail "container:${container}" "Container not found: $container"
            all_healthy=false
            continue
        fi

        local status running health
        status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
        running=$(docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null || echo "false")

        if [[ "$running" != "true" ]]; then
            _fail "container:${container}" "Container not running: $container (status: $status)"
            all_healthy=false
            continue
        fi

        health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$container" 2>/dev/null || echo "unknown")

        case "$health" in
            healthy|no-healthcheck)
                _pass "container:${container}" "$container is running (health: $health)"
                ;;
            starting)
                _warn "container:${container}" "$container is starting up (health: starting)"
                ;;
            unhealthy)
                _fail "container:${container}" "$container is unhealthy"
                all_healthy=false
                ;;
            *)
                _warn "container:${container}" "$container health status unknown: $health"
                ;;
        esac
    done

    $all_healthy && log_info "All containers healthy" || true
}

_fix_unhealthy_containers() {
    local fix_lock_dir="${ALERT_LOCK_DIR}"
    local max_restarts="${MAX_AUTO_RESTARTS:-3}"
    local window_hours="${RESTART_COUNT_WINDOW_HOURS:-6}"

    log_info "Fix mode: attempting recovery for failed containers..."

    for name in "${check_order[@]}"; do
        [[ "${check_results[$name]:-}" == "fail" ]] || continue
        [[ "$name" == container:* ]] || continue

        local container="${name#container:}"
        local safe_name
        safe_name=$(printf '%s' "$container" | tr -cs '[:alnum:]-' '_')
        local count_file="${fix_lock_dir}/restart_count_${safe_name}"
        local window_file="${fix_lock_dir}/restart_window_${safe_name}"

        mkdir -p "$fix_lock_dir" 2>/dev/null || true

        # Reset counter when outside the rolling window
        local now; now=$(date +%s)
        local window_start=$(( now - window_hours * 3600 ))
        local window_ts; window_ts=$(cat "$window_file" 2>/dev/null || echo 0)
        if (( window_ts < window_start )); then
            printf '0\n'  > "$count_file"
            printf '%s\n' "$now" > "$window_file"
        fi

        local count; count=$(cat "$count_file" 2>/dev/null || echo 0)

        if (( count >= max_restarts )); then
            log_warn "Fix mode: ${container} suppressed — already auto-restarted ${count}x in the last ${window_hours}h. Investigate manually."
            _warn "fix:restart-limit" \
                "${container} auto-restart suppressed after ${count} attempts in ${window_hours}h — manual intervention required"
            continue
        fi

        log_warn "Fix mode: restarting ${container} (attempt $(( count + 1 ))/${max_restarts} in ${window_hours}h window)..."
        if docker restart "$container" 2>/dev/null; then
            printf '%s\n' $(( count + 1 )) > "$count_file"
            log_info "Fix mode: ${container} restarted successfully"
            sleep 8
        else
            log_error "Fix mode: failed to restart ${container}"
        fi
    done
}

# =============================================================================
# SSL CERTIFICATE CHECKS
# =============================================================================

_check_ssl() {
    local domain
    domain="$(_get_domain)"

    if [[ -z "$domain" ]]; then
        _warn "ssl:cert" "Cannot check SSL — domain not configured"
        return
    fi

    log_info "Checking SSL certificate for $domain..."

    local expiry_output
    expiry_output=$(echo | timeout "$HEALTH_TIMEOUT" openssl s_client \
        -connect "${domain}:443" \
        -servername "$domain" 2>/dev/null | \
        openssl x509 -noout -enddate 2>/dev/null) || {
        _fail "ssl:cert" "Cannot connect to ${domain}:443 for SSL check"
        return
    }

    local expiry_date expiry_epoch now_epoch days_remaining
    expiry_date=$(echo "$expiry_output" | sed 's/notAfter=//')
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -jf "%b %e %T %Y %Z" "$expiry_date" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    days_remaining=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [[ $days_remaining -le 0 ]]; then
        _fail "ssl:cert" "SSL certificate EXPIRED for $domain (expired $expiry_date)"
    elif [[ $days_remaining -le $CERT_CRIT_DAYS ]]; then
        _fail "ssl:cert" "SSL certificate expires in ${days_remaining} days for $domain (critical threshold: ${CERT_CRIT_DAYS} days)"
    elif [[ $days_remaining -le $CERT_WARN_DAYS ]]; then
        _warn "ssl:cert" "SSL certificate expires in ${days_remaining} days for $domain (warning threshold: ${CERT_WARN_DAYS} days)"
    else
        _pass "ssl:cert" "SSL certificate valid for $domain (${days_remaining} days remaining)"
    fi

    if $COMPREHENSIVE; then
        local verify_output
        verify_output=$(echo | timeout "$HEALTH_TIMEOUT" openssl s_client \
            -connect "${domain}:443" \
            -servername "$domain" \
            -verify_return_error 2>&1) && \
            _pass "ssl:chain" "SSL certificate chain valid for $domain" || \
            _warn "ssl:chain" "SSL chain validation warning for $domain"
    fi
}

# =============================================================================
# VAULTWARDEN API CHECKS
# =============================================================================

_check_vaultwarden_alive() {
    local domain
    domain="$(_get_domain)"

    log_info "Checking VaultWarden liveness (/alive)..."

    local internal_response
    if internal_response=$(timeout "$HEALTH_TIMEOUT" curl -sf \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        "http://127.0.0.1:80/alive" 2>/dev/null); then
        _pass "vaultwarden:alive" "VaultWarden /alive endpoint responding"
    else
        if docker exec vaultwarden_app curl -sf \
            --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
            --max-time "$HEALTH_TIMEOUT" \
            "http://127.0.0.1/alive" &>/dev/null; then
            _pass "vaultwarden:alive" "VaultWarden /alive endpoint responding (via container)"
        else
            _fail "vaultwarden:alive" "VaultWarden /alive endpoint not responding"
        fi
    fi

    if [[ -n "$domain" ]]; then
        local external_code
        external_code=$(timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
            --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
            --max-time "$HEALTH_TIMEOUT" \
            -w "%{http_code}" \
            "https://${domain}/alive" 2>/dev/null || echo "000")

        case "$external_code" in
            200) _pass "vaultwarden:external" "VaultWarden HTTPS responding (HTTP $external_code)" ;;
            301|302) _warn "vaultwarden:external" "VaultWarden HTTPS redirect (HTTP $external_code)" ;;
            000) _fail "vaultwarden:external" "VaultWarden HTTPS not reachable (connection failed)" ;;
            *) _warn "vaultwarden:external" "VaultWarden HTTPS returned HTTP $external_code" ;;
        esac
    fi
}

_check_vaultwarden_server_info() {
    local domain
    domain="$(_get_domain)"

    log_info "Checking VaultWarden readiness (/api/config)..."

    local internal_code
    internal_code=$(docker exec vaultwarden_app curl -so /dev/null \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        -w "%{http_code}" \
        "http://127.0.0.1/api/config" 2>/dev/null || echo "000")

    case "$internal_code" in
        200)
            _pass "vaultwarden:server-info" "VaultWarden /api/config responding (HTTP $internal_code)"
            ;;
        000)
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

    local initial_container_health
    initial_container_health=$(docker inspect \
        --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
        vaultwarden_fail2ban 2>/dev/null || echo "unknown")

    local attempt ping_result
    for (( attempt=1; attempt<=FAIL2BAN_PING_RETRIES; attempt++ )); do
        if ping_result=$(docker exec vaultwarden_fail2ban fail2ban-client ping 2>/dev/null); then
            if echo "$ping_result" | grep -q pong; then
                _pass "fail2ban:daemon" "Fail2Ban daemon responding to ping"
                break
            else
                _warn "fail2ban:daemon" "Fail2Ban ping response unexpected: $ping_result"
                return
            fi
        fi

        if [[ $attempt -lt $FAIL2BAN_PING_RETRIES ]]; then
            log_info "Fail2Ban ping attempt ${attempt}/${FAIL2BAN_PING_RETRIES} failed — retrying in ${FAIL2BAN_PING_DELAY}s..."
            sleep "$FAIL2BAN_PING_DELAY"
        fi
    done

    if [[ -z "${check_results[fail2ban:daemon]:-}" ]]; then
        local current_container_health
        current_container_health=$(docker inspect \
            --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
            vaultwarden_fail2ban 2>/dev/null || echo "unknown")

        if [[ "$initial_container_health" == "starting" || "$current_container_health" == "starting" ]]; then
            _warn "fail2ban:daemon" \
                "Fail2Ban daemon not yet responding (container was starting when check began — retried ${FAIL2BAN_PING_RETRIES}x${FAIL2BAN_PING_DELAY}s; will resolve automatically)"
        else
            _fail "fail2ban:daemon" \
                "Fail2Ban daemon not responding to ping after ${FAIL2BAN_PING_RETRIES} attempts (container health: ${current_container_health})"
        fi
        return
    fi

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

_check_fail2ban_filter_drift() {
    local log_file="/var/log/vaultwarden/vaultwarden.log"
    local filter_conf="/etc/fail2ban/filter.d/vaultwarden-auth.conf"

    log_info "Checking Fail2Ban filter regex drift (vaultwarden-auth)..."

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

    local log_lines
    log_lines=$(docker exec vaultwarden_fail2ban wc -l < "$log_file" 2>/dev/null || echo 0)
    if [[ "$log_lines" -lt 10 ]]; then
        _warn "fail2ban:filter-drift" \
            "Skipping filter drift check — log file has fewer than 10 lines (${log_lines}); may be freshly rotated"
        return
    fi

    local regex_output match_count
    regex_output=$(docker exec vaultwarden_fail2ban \
        fail2ban-regex "$log_file" "$filter_conf" 2>&1 || true)

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

    # Resolve mount points to detect shared filesystems
    local state_mount root_mount
    state_mount=$(df --output=target "$state_dir" 2>/dev/null | tail -1 || echo "")
    root_mount=$(df --output=target / 2>/dev/null | tail -1 || echo "/")

    local usage_pct
    usage_pct=$(df "$state_dir" 2>/dev/null \
        | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0")

    if (( usage_pct >= DISK_CRIT_THRESHOLD )); then
        _fail "disk:state" \
            "Disk usage critical: ${usage_pct}% on ${state_dir} (mount: ${state_mount}) — threshold: ${DISK_CRIT_THRESHOLD}%"
    elif (( usage_pct >= DISK_WARN_THRESHOLD )); then
        _warn "disk:state" \
            "Disk usage warning: ${usage_pct}% on ${state_dir} (mount: ${state_mount}) — threshold: ${DISK_WARN_THRESHOLD}%"
    else
        _pass "disk:state" \
            "Disk OK: ${usage_pct}% on ${state_dir} (mount: ${state_mount})"
    fi

    # Only check root separately if it is on a different filesystem
    if [[ -n "$state_mount" && "$state_mount" != "$root_mount" ]]; then
        local root_usage
        root_usage=$(df / 2>/dev/null \
            | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0")
        if (( root_usage >= DISK_CRIT_THRESHOLD )); then
            _fail "disk:root" \
                "Root partition critical: ${root_usage}% on / — threshold: ${DISK_CRIT_THRESHOLD}%"
        elif (( root_usage >= DISK_WARN_THRESHOLD )); then
            _warn "disk:root" \
                "Root partition warning: ${root_usage}% on / — threshold: ${DISK_WARN_THRESHOLD}%"
        else
            _pass "disk:root" "Root partition OK: ${root_usage}% on /"
        fi
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

    if timeout "$HEALTH_TIMEOUT" curl -sf \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        "https://1.1.1.1" &>/dev/null || \
       timeout "$HEALTH_TIMEOUT" curl -sf \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        "https://cloudflare.com" &>/dev/null; then
        _pass "network:outbound" "Outbound internet connectivity OK"
    else
        _warn "network:outbound" "Outbound internet connectivity check failed (Cloudflare unreachable)"
    fi

    local cf_code
    cf_code=$(timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        -w "%{http_code}" \
        "https://api.cloudflare.com/" 2>/dev/null || echo "000")
    case "$cf_code" in
        200|301|302|400|401|403) _pass "network:cloudflare" "Cloudflare API reachable (HTTP $cf_code)" ;;
        *) _warn "network:cloudflare" "Cloudflare API not reachable (HTTP $cf_code)" ;;
    esac
}

# =============================================================================
# SMTP SIDECAR HEALTH CHECK
# =============================================================================

_check_smtp() {
    log_info "Checking Postfix SMTP sidecar on port 587..."

    # Skip only when using a direct external relay with no local sidecar:
    # SMTP_PASSWORD set (credentials for external relay) AND
    # VW_SMTP_HOST_PORT not set (no local sidecar address configured).
    if [[ -n "${SMTP_PASSWORD:-}" && -z "${VW_SMTP_HOST_PORT:-}" ]]; then
        _pass "smtp:sidecar" "Direct external SMTP relay configured — sidecar check skipped"
        return
    fi

    local sidecar_addr="${VW_SMTP_HOST_PORT:-127.0.0.1:587}"
    local sidecar_host="${sidecar_addr%:*}"
    local sidecar_port="${sidecar_addr##*:}"

    # Port probe
    local port_open=false
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 3 "$sidecar_host" "$sidecar_port" >/dev/null 2>&1 && port_open=true
    elif (echo >/dev/tcp/"$sidecar_host"/"$sidecar_port") >/dev/null 2>&1; then
        port_open=true
    else
        _warn "smtp:sidecar" "Cannot probe port ${sidecar_addr} — nc not available and /dev/tcp failed"
        return
    fi

    if ! $port_open; then
        _fail "smtp:sidecar" \
            "Postfix sidecar not listening on ${sidecar_addr} — email delivery will fail silently"
        return
    fi

    # Banner probe: confirm it's actually an SMTP server, not a stray process
    local banner=""
    if command -v nc >/dev/null 2>&1; then
        banner=$(printf 'QUIT\r\n' | nc -w 3 "$sidecar_host" "$sidecar_port" 2>/dev/null \
            | head -1 | tr -d '\r' || true)
    fi

    if [[ "$banner" == "220"* ]]; then
        _pass "smtp:sidecar" \
            "Postfix sidecar healthy on ${sidecar_addr} (banner: ${banner:0:60})"
    elif [[ -n "$banner" ]]; then
        _warn "smtp:sidecar" \
            "Postfix sidecar port open but unexpected banner: '${banner:0:60}'"
    else
        _pass "smtp:sidecar" \
            "Postfix sidecar port ${sidecar_addr} open (banner unavailable)"
    fi
}

# =============================================================================
# DNS RESOLUTION CHECKS
# =============================================================================

_check_dns() {
    local domain
    domain="$(_get_domain)"

    if [[ -z "$domain" ]]; then
        _warn "dns:resolution" "Cannot check DNS — domain not configured"
        return
    fi

    log_info "Checking DNS resolution for $domain..."

    local resolved_ip
    if resolved_ip=$(timeout "$HEALTH_TIMEOUT" dig +short "$domain" 2>/dev/null | grep -v '^;' | head -1) && [[ -n "$resolved_ip" ]]; then
        _pass "dns:resolution" "DNS resolves $domain → $resolved_ip"
    elif resolved_ip=$(timeout "$HEALTH_TIMEOUT" nslookup "$domain" 2>/dev/null | awk '/^Address/ && NR>1 {print $2}' | head -1) && [[ -n "$resolved_ip" ]]; then
        _pass "dns:resolution" "DNS resolves $domain → $resolved_ip (via nslookup)"
    else
        _fail "dns:resolution" "DNS resolution failed for $domain"
    fi
}

# =============================================================================
# BACKUP STATUS CHECKS
# =============================================================================

_check_backups() {
    log_info "Checking backup status..."

    local backup_dir="${BACKUP_DIR:-${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/backups}"
    local max_age_hours=${BACKUP_MAX_AGE_HOURS:-26}

    if [[ ! -d "$backup_dir" ]]; then
        _warn "backup:dir" "Backup directory not found: $backup_dir"
        return
    fi

    local latest_backup latest_age_hours
    latest_backup=$(find "$backup_dir" -name '*.age' -newer "/tmp" 2>/dev/null | \
        xargs ls -t 2>/dev/null | head -1 || \
        find "$backup_dir" -name '*.age' 2>/dev/null | xargs ls -t 2>/dev/null | head -1)

    if [[ -z "$latest_backup" ]]; then
        _warn "backup:age" "No backup archives found in $backup_dir"
        return
    fi

    local backup_mtime now_epoch
    backup_mtime=$(stat -c %Y "$latest_backup" 2>/dev/null || stat -f %m "$latest_backup" 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    latest_age_hours=$(( (now_epoch - backup_mtime) / 3600 ))

    if [[ $latest_age_hours -gt $max_age_hours ]]; then
        _warn "backup:age" "Most recent backup is ${latest_age_hours}h old (threshold: ${max_age_hours}h): $(basename "$latest_backup")"
    else
        _pass "backup:age" "Most recent backup is ${latest_age_hours}h old: $(basename "$latest_backup")"
    fi
}

# =============================================================================
# CONFIGURATION VALIDATION
# =============================================================================

_check_config() {
    log_info "Checking configuration..."

    local config_issues=()

    if [[ ! -f "$ENV_FILE" ]]; then
        config_issues+=("Missing env file: $ENV_FILE")
    elif [[ ! -r "$ENV_FILE" ]]; then
        config_issues+=("$ENV_FILE is not readable by $(id -un) — run: sudo chown $(id -un):$(id -gn) $ENV_FILE")
    else
        local required_vars=("DOMAIN" "ADMIN_EMAIL" "CLOUDFLARE_ZONE_ID")
        for var in "${required_vars[@]}"; do
            [[ -n "${!var:-}" ]] || config_issues+=("${var} is not set — verify '${var}=' is present in ${ENV_FILE}")
        done
    fi

    local secrets_dir="${SCRIPT_DIR}/secrets/.docker_secrets"
    if [[ -d "$secrets_dir" ]]; then
        local required_secrets=("admin_token" "caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token")
        for secret in "${required_secrets[@]}"; do
            [[ -f "${secrets_dir}/${secret}" ]] || config_issues+=("Missing secret: $secret")
        done
    fi

    # --- Age encryption key validation ---
    local age_key_file="${SOPS_AGE_KEY_FILE:-${SCRIPT_DIR}/secrets/keys/age-key.txt}"
    if [[ ! -f "$age_key_file" ]]; then
        config_issues+=("Age key not found: ${age_key_file} — backups cannot encrypt. Run: ./edit-secrets.sh --init-key")
    elif [[ ! -r "$age_key_file" ]]; then
        config_issues+=("Age key not readable: ${age_key_file} — check file permissions")
    else
        if ! grep -q '^AGE-SECRET-KEY-' "$age_key_file" 2>/dev/null; then
            config_issues+=("Age key malformed or empty: ${age_key_file} — missing AGE-SECRET-KEY line")
        else
            local age_key_perms
            age_key_perms=$(stat -c '%a' "$age_key_file" 2>/dev/null || echo "unknown")
            if [[ "$age_key_perms" != "600" && "$age_key_perms" != "400" ]]; then
                _warn "config:age-key" \
                    "Age key has insecure permissions (${age_key_perms}): ${age_key_file} — run: chmod 600 '${age_key_file}'"
            else
                _pass "config:age-key" \
                    "Age key present and valid (${age_key_file}, perms: ${age_key_perms})"
            fi
        fi
    fi

    local root_owned_issues=()
    for f in ".env" "Makefile" "health.sh" "startup.sh" "backup.sh" "edit-secrets.sh"; do
        local fpath="${SCRIPT_DIR}/${f}"
        if [[ -e "$fpath" ]]; then
            local owner
            owner=$(stat -c '%U' "$fpath" 2>/dev/null || echo "unknown")
            if [[ "$owner" == "root" ]]; then
                root_owned_issues+=("${f} is owned by root — run: sudo make fix-permissions")
            fi
        fi
    done
    if [[ ${#root_owned_issues[@]} -gt 0 ]]; then
        for issue in "${root_owned_issues[@]}"; do
            _warn "permissions:project-files" "$issue"
        done
    elif [[ -f "${SCRIPT_DIR}/.env" || -f "${SCRIPT_DIR}/Makefile" ]]; then
        _pass "permissions:project-files" "Project file ownership is correct"
    fi

    if [[ ${#config_issues[@]} -eq 0 ]]; then
        _pass "config:validation" "Configuration validation passed"
    else
        for issue in "${config_issues[@]}"; do
            _fail "config:validation" "$issue"
        done
    fi
}

# =============================================================================
# NOTIFY-FAILURE DEAD-LETTER CHECKS
# =============================================================================

_check_notify_failures() {
    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    local -a markers=()
    mapfile -t markers < <(find "$state_dir" -maxdepth 1 -name 'NOTIFY_FAILED_*' 2>/dev/null | sort)

    if [[ ${#markers[@]} -eq 0 ]]; then
        _pass "notify:dead-letter" "No lost failure notifications"
        return
    fi

    for marker in "${markers[@]}"; do
        local unit="${marker##*/NOTIFY_FAILED_}"
        _fail "notify:dead-letter" \
            "SMTP was down when ${unit} failed — notification lost. Investigate and remove: ${marker}"
    done
}

# =============================================================================
# COMPREHENSIVE CHECKS
# =============================================================================

_check_container_resources() {
    log_info "Checking container resource usage..."

    local stats
    stats=$(docker stats --no-stream --format \
        'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' \
        2>/dev/null) || {
        _warn "resources:stats" "Cannot retrieve container resource stats"
        return
    }

    _pass "resources:stats" "Container resource stats retrieved (see --report for details)"
}

# =============================================================================
# NOTIFICATION (with per-key alert cooldown)
# =============================================================================

_send_notification() {
    local subject="$1" body="$2"

    if [[ "${_email_available:-true}" == "false" ]]; then
        log_warn "Email notifications not available"
        return
    fi

    if [[ -z "${ADMIN_EMAIL:-}" ]]; then
        log_warn "ADMIN_EMAIL not set — cannot send health notification"
        return 1
    fi

    if ! send_email "$ADMIN_EMAIL" "$subject" "$body" 2>/dev/null; then
        log_warn "Failed to send health notification email"
        return 1
    fi

    return 0
}

# _notify_failures — fixed version
_notify_failures() {
    local alerted_any=false

    for name in "${check_order[@]}"; do
        local status="${check_results[$name]:-}"
        [[ "$status" == "fail" || "$status" == "warn" ]] || continue

        if ! _acquire_alert_lock "$name"; then
            log_info "Alert cooldown active for '${name}' — suppressing repeat notification"
            continue
        fi

        local message="${check_messages[$name]:-}"
        local alert_date subject body
        alert_date="$(date)"

        subject="VaultWarden Health [${status^^}]: ${name} on $(hostname)"
        printf -v body \
            'Health check alert at %s\n\nCheck : %s\nStatus: %s\nDetail: %s\n\nThis alert will not repeat for %ss (%s min).\nRun '\''./health.sh --report'\'' for full status.' \
            "$alert_date" "$name" "${status^^}" "$message" \
            "$ALERT_COOLDOWN_SECONDS" "$(( ALERT_COOLDOWN_SECONDS / 60 ))"

        # NOTE: clear_email_rate_limit removed from here.
        # The flock/timestamp cooldown (above) is the deduplication layer.
        # Clearing the rate-limit stamp before sending defeated both guards
        # simultaneously on delivery failure, causing alert storms.

        if ! _send_notification "$subject" "$body"; then
            log_warn "_notify_failures: delivery failed for '${name}' — releasing cooldown for retry next cycle"
            _release_alert_lock "$name"
            continue
        fi

        alerted_any=true
        log_info "Alert sent for '${name}' (${status})"
    done

    if [[ $failed -gt 0 || $warnings -gt 0 ]]; then
        _release_recovery_lock
    fi
}

# _notify_recovery — updated to use ALERT_RECOVERY_TTL via _acquire_alert_lock
_notify_recovery() {
    [[ $failed -eq 0 && $warnings -eq 0 ]] || return 0

    if ! _acquire_alert_lock "recovery" "${ALERT_RECOVERY_TTL}"; then
        log_info "Recovery notification already sent within TTL — suppressing"
        return 0
    fi

    local recovery_date subject body
    recovery_date="$(date)"
    subject="VaultWarden Health RECOVERED on $(hostname)"
    printf -v body \
        'All health checks passed at %s\n\nPassed : %s\nWarnings: 0\nFailed : 0\n\nNo further alerts will fire until the next failure.' \
        "$recovery_date" "$passed"

    _send_notification "$subject" "$body" || true
    log_info "Recovery notification sent"
}

# =============================================================================
# REPORT GENERATION
# =============================================================================

_generate_report() {
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local report_file="${REPORT_DIR}/health_${timestamp}.txt"

    mkdir -p "$REPORT_DIR" 2>/dev/null || true

    {
        echo "VaultWarden Health Report"
        echo "Generated: $(date)"
        echo "Host: $(hostname)"
        echo "Mode: $( $COMPREHENSIVE && echo comprehensive || echo standard )"
        echo "================================================================="
        echo ""
        echo "SUMMARY: $passed passed, $warnings warnings, $failed failed (total: $total)"
        echo ""

        for name in "${check_order[@]}"; do
            local status="${check_results[$name]:-unknown}"
            local message="${check_messages[$name]:-no message}"
            printf '%-10s %-40s %s\n' "[$status]" "$name" "$message"
        done

        if $COMPREHENSIVE; then
            echo ""
            echo "CONTAINER RESOURCES:"
            docker stats --no-stream 2>/dev/null || echo "  (unavailable)"
        fi
    } > "$report_file" 2>/dev/null

    log_info "Report saved to: $report_file"

    find "$REPORT_DIR" -name 'health_*.txt' \
        -mtime +"$REPORT_RETENTION_DAYS" -delete 2>/dev/null || true
}

# =============================================================================
# OUTPUT
# =============================================================================

_print_results() {
    if $QUIET && [[ $failed -eq 0 && $warnings -eq 0 ]]; then
        return
    fi

    echo ""
    echo "================================================================="
    echo " VaultWarden Health Check Results"
    echo "================================================================="

    local status_color
    for name in "${check_order[@]}"; do
        local status="${check_results[$name]:-unknown}"
        local message="${check_messages[$name]:-}"

        case "$status" in
            pass) status_color="${COLOR_GREEN:-}" ;;
            warn) status_color="${COLOR_YELLOW:-}" ;;
            fail) status_color="${COLOR_RED:-}" ;;
            *)    status_color="" ;;
        esac

        printf '%s[%-4s]%s %-40s %s\n' \
            "$status_color" "$status" "${COLOR_RESET:-}" "$name" "$message"
    done

    echo "-----------------------------------------------------------------"
    printf 'Total: %d | Passed: %s%d%s | Warnings: %s%d%s | Failed: %s%d%s\n' \
        "$total" \
        "${COLOR_GREEN:-}" "$passed"   "${COLOR_RESET:-}" \
        "${COLOR_YELLOW:-}" "$warnings" "${COLOR_RESET:-}" \
        "${COLOR_RED:-}"   "$failed"   "${COLOR_RESET:-}"
    echo "================================================================="
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    _acquire_run_lock
    trap '_release_run_lock' EXIT HUP INT TERM
    _parse_args "$@"

    log_info "Starting VaultWarden health check..."
    $COMPREHENSIVE && log_info "Mode: comprehensive" || log_info "Mode: standard"

    _check_containers
    _check_ssl
    _check_vaultwarden_alive
    _check_vaultwarden_server_info
    _check_fail2ban
    _check_disk
    _check_memory
    _check_network
    _check_smtp
    _check_dns
    _check_backups
    _check_config
    _check_notify_failures

    if $COMPREHENSIVE; then
        _check_container_resources
    fi

    if $FIX_MODE && [[ $failed -gt 0 ]]; then
        log_info "Fix mode enabled — attempting recovery..."
        _fix_unhealthy_containers
    fi

    _print_results

    if $REPORT_MODE; then
        _generate_report
    fi

    _notify_failures
    _notify_recovery

    if [[ $failed -gt 0 ]]; then
        exit 2
    elif [[ $warnings -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

main "$@"