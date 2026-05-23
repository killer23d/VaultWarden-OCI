#!/usr/bin/env bash
# utilities/maintenance-health.sh — VaultWarden health check utility
#
# Standalone entry point for the 'health' subcommand.
# Invoked directly by:
#   - maintenance.sh health [OPTIONS]  (thin dispatcher)
#   - systemd/vaultwarden-health.service
#   - startup.sh post-startup check
#   - restore-run.sh post-restore check
#
# EXIT CODES:
#   0 — all checks passed
#   1 — one or more warnings
#   2 — one or more failures
#   3 — critical failure (cannot run checks)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# lib/secrets.sh recomputes SCRIPT_DIR at load time; save/restore PROJECT_ROOT's SCRIPT_DIR.
_SAVE_SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/email.sh"
init_common_lib "$0"
source "$PROJECT_ROOT/lib/docker.sh"
source "$PROJECT_ROOT/lib/backup-utils.sh"
source "$PROJECT_ROOT/lib/crypto.sh"
source "$PROJECT_ROOT/lib/storage.sh"
SCRIPT_DIR="$_SAVE_SCRIPT_DIR"
unset _SAVE_SCRIPT_DIR

# ---------------------------------------------------------------------------
# _default_backup_dir / _default_alert_state_dir / _default_report_dir
# (mirrors maintenance.sh helpers; storage.sh provides vw_default_backup_dir)
# ---------------------------------------------------------------------------
_default_backup_dir()     { vw_default_backup_dir; }
_default_alert_state_dir() {
    local state_dir
    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    printf '%s/.vw-health-alert' "$state_dir"
}
_default_report_dir() {
    local state_dir
    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    printf '%s/reports' "$state_dir"
}

# ---------------------------------------------------------------------------
# run_health_check — all logic verbatim from maintenance.sh
# ---------------------------------------------------------------------------
run_health_check() {
_resolve_env_file() {
    local candidates=(
        # PROJECT_ROOT is derived from BASH_SOURCE at the top of this file.
        "${PROJECT_ROOT}/.env"
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

local ENV_FILE
ENV_FILE="$(_resolve_env_file || true)"

if [[ -n "${ENV_FILE}" ]]; then
    if [[ ! -r "${ENV_FILE}" ]]; then
        log_error "maintenance.sh health: '${ENV_FILE}' is not readable by $(id -un) — config variables will be unset."
        log_error "Fix ownership: sudo chown $(id -un):$(id -gn) '${ENV_FILE}'"
    else
        load_env_file "${ENV_FILE}" || true
    fi
else
    log_warn "maintenance.sh health: no .env file found at '${PROJECT_ROOT}/.env' or '/etc/vaultwarden/vaultwarden.env' — relying on inherited environment"
    ENV_FILE="/etc/vaultwarden/vaultwarden.env"
fi

local HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-10}
local HEALTH_CONNECT_TIMEOUT=${HEALTH_CONNECT_TIMEOUT:-3}
local HEALTH_RETRIES=${HEALTH_RETRIES:-3}
local HEALTH_RETRY_DELAY=${HEALTH_RETRY_DELAY:-2}
local HEALTH_API_STRICT=${HEALTH_API_STRICT:-false}
local AUTO_FIX=${AUTO_FIX:-false}
local FIX_MAX_RESTARTS=${FIX_MAX_RESTARTS:-3}
local FIX_RESTART_WINDOW=${FIX_RESTART_WINDOW:-300}
local REPORT_DIR; REPORT_DIR="$(_default_report_dir)"
local REPORT_RETENTION_DAYS=${REPORT_RETENTION_DAYS:-30}
local DISK_WARN_THRESHOLD=${DISK_WARN_THRESHOLD:-80}
local DISK_CRIT_THRESHOLD=${DISK_CRIT_THRESHOLD:-90}
local MEM_WARN_THRESHOLD=${MEM_WARN_THRESHOLD:-80}
local MEM_CRIT_THRESHOLD=${MEM_CRIT_THRESHOLD:-90}
local CERT_WARN_DAYS=${CERT_WARN_DAYS:-30}
local CERT_CRIT_DAYS=${CERT_CRIT_DAYS:-7}

local _HEALTH_RUN_LOCK_FILE="/run/lock/vaultwarden-health.lock"
local _HEALTH_LOCK_FD=""

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

local ALERT_LOCK_DIR="${ALERT_STATE_DIR:-$(_default_alert_state_dir)}"
local ALERT_COOLDOWN_SECONDS=${ALERT_COOLDOWN_SECONDS:-3600}
local ALERT_RECOVERY_TTL=${ALERT_RECOVERY_TTL:-86400}

_acquire_alert_lock() {
    local key="$1"
    local safe_key
    safe_key=$(printf '%s' "$key" | tr -cs '[:alnum:]-' '_')
    mkdir -p "${ALERT_LOCK_DIR}" 2>/dev/null || true
    local state_file="${ALERT_LOCK_DIR}/${safe_key}.cooldown"
    local ttl="${2:-${ALERT_COOLDOWN_SECONDS}}"
    local now; now=$(date +%s)
    if [[ -f "$state_file" ]]; then
        local last_sent; last_sent=$(cat "$state_file" 2>/dev/null || printf '0')
        if (( now - last_sent < ttl )); then return 1; fi
    fi
    local tmp_file; tmp_file=$(mktemp "${ALERT_LOCK_DIR}/.tmp.XXXXXXXXXX")
    printf '%s\n' "$now" > "$tmp_file"
    mv -f "$tmp_file" "$state_file"
    return 0
}

_release_alert_lock() {
    local key="$1"
    local safe_key; safe_key=$(printf '%s' "$key" | tr -cs '[:alnum:]-' '_')
    rm -f "${ALERT_LOCK_DIR}/${safe_key}.cooldown" 2>/dev/null || true
}

_release_recovery_lock() {
    rm -f "${ALERT_LOCK_DIR}/recovery.cooldown" 2>/dev/null || true
}

local -A check_results=()
local -A check_messages=()
local -a check_order=()
local passed=0
local warnings=0
local failed=0
local total=0
local COMPREHENSIVE=false
local FIX_MODE=false
local REPORT_MODE=false
local QUIET=false

_health_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --comprehensive)     COMPREHENSIVE=true;  shift ;;
            --fix|-f)            FIX_MODE=true;       shift ;;
            --report|-r)         REPORT_MODE=true;    shift ;;
            --quiet|-q)          QUIET=true;          shift ;;
            *)                   log_error "Unknown option for 'health': $1"; _show_help; exit 1 ;;
        esac
    done
}

_show_help() {
    cat <<'EOF'
Usage: ./maintenance.sh health [OPTIONS]

Options:
  --comprehensive     Run all checks including extended diagnostics
  --fix, -f            Attempt automatic recovery for failed checks
  --report, -r         Save health report to file
  --quiet, -q          Suppress non-critical output

Checks performed:
  - Docker container status and health
  - SSL certificate validity and expiry
  - VaultWarden /alive liveness probe (internal + external HTTPS)
  - VaultWarden /api/config readiness probe (requires live DB connection)
  - CrowdSec integration check (systemd service + bouncer)
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
  - CrowdSec integration check

Environment variables:
  HEALTH_API_STRICT=true          Promote /api/config non-200 from warning to failure
  ALERT_COOLDOWN_SECONDS=3600     Minimum seconds between repeat alerts for the same
                                  failure key (default: 3600 = 1 hour)
  ALERT_RECOVERY_TTL=86400        Minimum seconds between clear-state recovery emails
                                  (default: 86400 = 24 hours)

Alert cooldown:
  Alerts are rate-limited per failure key using timestamp files under
  $PROJECT_STATE_DIR/.vw-health-alert/. At most one alert fires per failure
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

_get_domain() {
    if [[ -n "${DOMAIN_NAME:-}" ]]; then
        echo "${DOMAIN_NAME}"
    elif [[ -n "${DOMAIN:-}" ]]; then
        local _d="${DOMAIN#https://}"
        echo "${_d#http://}"
    else
        echo ""
    fi
}

_check_containers() {
    log_info "Checking container status..."
    local containers=("vaultwarden_app" "vaultwarden_caddy" "vaultwarden_postfix")
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
            healthy|no-healthcheck) _pass "container:${container}" "$container is running (health: $health)" ;;
            starting)               _warn "container:${container}" "$container is starting up (health: starting)" ;;
            unhealthy)              _fail "container:${container}" "$container is unhealthy"; all_healthy=false ;;
            *)                      _warn "container:${container}" "$container health status unknown: $health" ;;
        esac
    done
    if $all_healthy; then log_info "All containers healthy"; fi
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
        local safe_name; safe_name=$(printf '%s' "$container" | tr -cs '[:alnum:]-' '_')
        local count_file="${fix_lock_dir}/restart_count_${safe_name}"
        local window_file="${fix_lock_dir}/restart_window_${safe_name}"
        mkdir -p "$fix_lock_dir" 2>/dev/null || true
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
            _warn "fix:restart-limit:${container}" \
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

_check_ssl() {
    local domain; domain="$(_get_domain)"
    if [[ -z "$domain" ]]; then _warn "ssl:cert" "Cannot check SSL — domain not configured"; return; fi
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
    expiry_date="${expiry_output#notAfter=}"
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
        if echo | timeout "$HEALTH_TIMEOUT" openssl s_client \
            -connect "${domain}:443" \
            -servername "$domain" \
            -verify_return_error >/dev/null 2>&1; then
            _pass "ssl:chain" "SSL certificate chain valid for $domain"
        else
            _warn "ssl:chain" "SSL chain validation warning for $domain"
        fi
    fi
}

_check_vaultwarden_alive() {
    local domain; domain="$(_get_domain)"
    log_info "Checking VaultWarden liveness (/alive)..."
    local alive_response
    if alive_response=$(timeout "$HEALTH_TIMEOUT" curl -sf \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        "http://127.0.0.1:80/alive" 2>/dev/null); then
        _pass "vaultwarden:alive" "VaultWarden /alive endpoint responding (response: ${alive_response:-<empty>})"
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
            200)         _pass "vaultwarden:external" "VaultWarden HTTPS responding (HTTP $external_code)" ;;
            301|302)     _warn "vaultwarden:external" "VaultWarden HTTPS redirect (HTTP $external_code)" ;;
            000)         _fail "vaultwarden:external" "VaultWarden HTTPS not reachable (connection failed)" ;;
            *)           _warn "vaultwarden:external" "VaultWarden HTTPS returned HTTP $external_code" ;;
        esac
    fi
}

_check_vaultwarden_server_info() {
    local domain; domain="$(_get_domain)"
    log_info "Checking VaultWarden readiness (/api/config)..."
    local internal_code
    internal_code=$(docker exec vaultwarden_app curl -so /dev/null \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        -w "%{http_code}" \
        "http://127.0.0.1/api/config" 2>/dev/null || echo "000")
    case "$internal_code" in
        200) _pass "vaultwarden:server-info" "VaultWarden /api/config responding (HTTP $internal_code)" ;;
        000) _fail "vaultwarden:server-info" "VaultWarden /api/config not reachable internally (connection failed)" ;;
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
            200)  _pass "vaultwarden:server-info:external" "VaultWarden /api/config HTTPS responding (HTTP $external_code)" ;;
            000)  _fail "vaultwarden:server-info:external" "VaultWarden /api/config HTTPS not reachable (connection failed)" ;;
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
            200) _pass "vaultwarden:api" "VaultWarden API endpoint r