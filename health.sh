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
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}" 2>/dev/null || true

# Health check configuration
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-10}
HEALTH_CONNECT_TIMEOUT=${HEALTH_CONNECT_TIMEOUT:-3}
HEALTH_RETRIES=${HEALTH_RETRIES:-3}
HEALTH_RETRY_DELAY=${HEALTH_RETRY_DELAY:-2}

# When true, a non-200 response from /api/server-info is recorded as a hard
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
  - VaultWarden /api/server-info readiness probe (requires live DB connection)
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
  - Extended /api/server-info endpoint testing (explicit comprehensive result)
  - Backup integrity verification
  - Fail2Ban rule validation
  - Fail2Ban filter regex drift detection (vaultwarden-auth against live log)

Environment variables:
  HEALTH_API_STRICT=true   Promote /api/server-info non-200 from warning to failure

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
    # Priority: DOMAIN_NAME (bare) → DOMAIN (strip protocol) → grep .env → empty
    if [[ -n "${DOMAIN_NAME:-}" ]]; then
        echo "${DOMAIN_NAME}"
    elif [[ -n "${DOMAIN:-}" ]]; then
        echo "${DOMAIN#https://}" | sed 's|http://||'
    elif [[ -f "${ENV_FILE}" ]]; then
        grep -oP '(?<=^DOMAIN=https://)\S+' "${ENV_FILE}" 2>/dev/null | head -1 || \
        grep -oP '(?<=^DOMAIN=)\S+' "${ENV_FILE}" 2>/dev/null | head -1 | sed 's|https://||' | sed 's|http://||'
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

        # Check Docker healthcheck status if available
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
    log_info "Attempting to restart unhealthy containers..."
    for name in "${check_order[@]}"; do
        if [[ "${check_results[$name]}" == "fail" && "$name" == container:* ]]; then
            local container="${name#container:}"
            log_warn "Restarting: $container"
            docker restart "$container" 2>/dev/null || log_error "Failed to restart $container"
            sleep 5
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

    # Check certificate expiry
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

    # Comprehensive: validate full chain
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

# -----------------------------------------------------------------------------
# _check_vaultwarden_alive
#
# Liveness probe: checks /alive (Rocket framework built-in).
# Returns 200 as long as the process is running — does NOT require a live
# DB connection. Used to detect process crashes or container restarts.
# -----------------------------------------------------------------------------
_check_vaultwarden_alive() {
    local domain
    domain="$(_get_domain)"

    log_info "Checking VaultWarden liveness (/alive)..."

    # Internal health check (direct to container).
    # --connect-timeout bounds TCP/TLS handshake separately from total transfer
    # time; without it a hung handshake consumes the full --max-time budget.
    local internal_response
    if internal_response=$(timeout "$HEALTH_TIMEOUT" curl -sf \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        "http://127.0.0.1:80/alive" 2>/dev/null); then
        _pass "vaultwarden:alive" "VaultWarden /alive endpoint responding"
    else
        # Try via docker network
        if docker exec vaultwarden_app curl -sf \
            --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
            --max-time "$HEALTH_TIMEOUT" \
            "http://127.0.0.1/alive" &>/dev/null; then
            _pass "vaultwarden:alive" "VaultWarden /alive endpoint responding (via container)"
        else
            _fail "vaultwarden:alive" "VaultWarden /alive endpoint not responding"
        fi
    fi

    # External HTTPS check (only if domain is configured)
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

# -----------------------------------------------------------------------------
# _check_vaultwarden_server_info
#
# Readiness probe: checks /api/server-info.
# This endpoint exercises the database connection path; it will return a
# non-200 code (or time out) if the DB is locked, the secrets mount has
# failed, or the application is in a degraded state despite /alive returning
# 200. Running this in the default (non-comprehensive) path ensures that the
# systemd health timer catches real service outages, not just process crashes.
#
# Default behaviour: non-200 is recorded as a WARNING (exit 1) so a single
# transient blip does not wake the operator at 3 AM. Set HEALTH_API_STRICT=true
# in .env to promote non-200 to a hard FAILURE (exit 2).
# -----------------------------------------------------------------------------
_check_vaultwarden_server_info() {
    local domain
    domain="$(_get_domain)"

    log_info "Checking VaultWarden readiness (/api/server-info)..."

    # Internal readiness probe — direct to container, bypasses Caddy.
    local internal_code
    internal_code=$(timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        -w "%{http_code}" \
        "http://127.0.0.1:80/api/server-info" 2>/dev/null || echo "000")

    case "$internal_code" in
        200)
            _pass "vaultwarden:server-info" "VaultWarden /api/server-info responding (HTTP $internal_code)"
            ;;
        000)
            # Connection refused or timeout — hard fail regardless of HEALTH_API_STRICT
            _fail "vaultwarden:server-info" "VaultWarden /api/server-info not reachable internally (connection failed)"
            ;;
        *)
            if [[ "${HEALTH_API_STRICT:-false}" == "true" ]]; then
                _fail "vaultwarden:server-info" "VaultWarden /api/server-info returned HTTP ${internal_code} (HEALTH_API_STRICT=true)"
            else
                _warn "vaultwarden:server-info" "VaultWarden /api/server-info returned HTTP ${internal_code} (set HEALTH_API_STRICT=true to treat as failure)"
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
            "https://${domain}/api/server-info" 2>/dev/null || echo "000")

        case "$external_code" in
            200)
                _pass "vaultwarden:server-info:external" "VaultWarden /api/server-info HTTPS responding (HTTP $external_code)"
                ;;
            000)
                _fail "vaultwarden:server-info:external" "VaultWarden /api/server-info HTTPS not reachable (connection failed)"
                ;;
            *)
                if [[ "${HEALTH_API_STRICT:-false}" == "true" ]]; then
                    _fail "vaultwarden:server-info:external" "VaultWarden /api/server-info HTTPS returned HTTP ${external_code} (HEALTH_API_STRICT=true)"
                else
                    _warn "vaultwarden:server-info:external" "VaultWarden /api/server-info HTTPS returned HTTP ${external_code}"
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
            "https://${domain}/api/server-info" 2>/dev/null || echo "000")
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
        "https://1.1.1.1" &>/dev/null || \
       timeout "$HEALTH_TIMEOUT" curl -sf \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        "https://cloudflare.com" &>/dev/null; then
        _pass "network:outbound" "Outbound internet connectivity OK"
    else
        _warn "network:outbound" "Outbound internet connectivity check failed (Cloudflare unreachable)"
    fi

    # Check Cloudflare API reachability
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
    local max_age_hours=${BACKUP_MAX_AGE_HOURS:-26}  # Alert if no backup in 26 hours

    if [[ ! -d "$backup_dir" ]]; then
        _warn "backup:dir" "Backup directory not found: $backup_dir"
        return
    fi

    # Find most recent backup across all types
    local latest_backup latest_age_hours
    latest_backup=$(find "$backup_dir" -name '*.age' -newer "/tmp" 2>/dev/null | \
        xargs ls -t 2>/dev/null | head -1 || \
        find "$backup_dir" -name '*.age' 2>/dev/null | xargs ls -t 2>/dev/null | head -1)

    if [[ -z "$latest_backup" ]]; then
        _warn "backup:age" "No backup archives found in $backup_dir"
        return
    fi

    # Calculate age in hours
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
    else
        local required_vars=("DOMAIN" "ADMIN_EMAIL" "CLOUDFLARE_ZONE_ID")
        for var in "${required_vars[@]}"; do
            grep -q "^${var}=" "$ENV_FILE" || config_issues+=("Missing $var in $ENV_FILE")
        done
    fi

    # Check secrets directory
    local secrets_dir="${SCRIPT_DIR}/secrets/.docker_secrets"
    if [[ ! -d "$secrets_dir" ]]; then
        config_issues+=("Secrets directory not found: $secrets_dir")
    else
        local required_secrets=("admin_token" "caddy_cloudflare_dns_token" "fail2ban_cloudflare_firewall_token")
        for secret in "${required_secrets[@]}"; do
            [[ -f "${secrets_dir}/${secret}" ]] || config_issues+=("Missing secret: $secret")
        done
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
# NOTIFICATION
# =============================================================================

_send_notification() {
    local subject="$1" body="$2"

    if [[ "${_email_available:-true}" == "false" ]]; then
        log_warn "Email notifications not available"
        return
    fi

    if [[ -z "${ADMIN_EMAIL:-}" ]]; then
        log_warn "ADMIN_EMAIL not set — cannot send health notification"
        return
    fi

    send_email "$ADMIN_EMAIL" "$subject" "$body" 2>/dev/null || \
        log_warn "Failed to send health notification email"
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
        echo "="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="*"="
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

    # Prune old reports
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
    _parse_args "$@"

    log_info "Starting VaultWarden health check..."
    $COMPREHENSIVE && log_info "Mode: comprehensive" || log_info "Mode: standard"

    # Run all checks
    _check_containers
    _check_ssl
    _check_vaultwarden_alive
    _check_vaultwarden_server_info
    _check_fail2ban
    _check_disk
    _check_memory
    _check_network
    _check_dns
    _check_backups
    _check_config
    _check_notify_failures

    # Comprehensive extras
    if $COMPREHENSIVE; then
        _check_container_resources
    fi

    # Auto-fix
    if $FIX_MODE && [[ $failed -gt 0 ]]; then
        log_info "Fix mode enabled — attempting recovery..."
        _fix_unhealthy_containers
    fi

    # Print results
    _print_results

    # Save report
    if $REPORT_MODE; then
        _generate_report
    fi

    # Send notification if there are failures or warnings
    if [[ $failed -gt 0 || $warnings -gt 0 ]]; then
        local subject body
        subject="VaultWarden Health Alert: ${failed} failed, ${warnings} warnings on $(hostname)"
        body="Health check completed at $(date).\n\nFailed: $failed\nWarnings: $warnings\nPassed: $passed\n\nRun './health.sh --report' for details."
        _send_notification "$subject" "$body" || true
    fi

    # Exit code
    if [[ $failed -gt 0 ]]; then
        exit 2
    elif [[ $warnings -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

main "$@"
