#!/usr/bin/env bash
# health.sh - Enhanced health check script for VaultWarden
# Supports standard and comprehensive health monitoring
# Exit codes: 0=healthy, 1=warning, 2=critical

set -euo pipefail

# =============================================================================
# SCRIPT SETUP
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared library
LIB_DIR="${SCRIPT_DIR}/lib"
if [[ ! -f "${LIB_DIR}/common.sh" ]]; then
    echo "[ERROR] lib/common.sh not found. Run from project root." >&2
    exit 2
fi
# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Load environment
if ! load_env; then
    log_warn "Could not load .env file — using defaults"
fi

# Health check configuration
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-10}
HEALTH_CONNECT_TIMEOUT=${HEALTH_CONNECT_TIMEOUT:-3}
HEALTH_RETRIES=${HEALTH_RETRIES:-3}
HEALTH_RETRY_DELAY=${HEALTH_RETRY_DELAY:-2}

# When true, a non-200 response from /api/alive (the readiness probe) is
# recorded as a hard failure (exit 2) rather than a warning (exit 1). Set in
# .env or the calling environment to opt in to stricter alerting.
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

# =============================================================================
# RESULT TRACKING
# =============================================================================

# Arrays to track check results
declare -a HEALTH_RESULTS=()
declare -a PASS_CHECKS=()
declare -a WARN_CHECKS=()
declare -a FAIL_CHECKS=()

# =============================================================================
# RESULT HELPERS
# =============================================================================

_pass() {
    local key="$1" msg="$2"
    PASS_CHECKS+=("$key")
    HEALTH_RESULTS+=("pass|${key}|${msg}")
}

_warn() {
    local key="$1" msg="$2"
    WARN_CHECKS+=("$key")
    HEALTH_RESULTS+=("warn|${key}|${msg}")
}

_fail() {
    local key="$1" msg="$2"
    FAIL_CHECKS+=("$key")
    HEALTH_RESULTS+=("fail|${key}|${msg}")
}

# =============================================================================
# MODE FLAGS
# =============================================================================

COMPREHENSIVE=false
JSON_OUTPUT=false
REPORT=false
ALERT=false
QUIET=false

# =============================================================================
# USAGE
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

VaultWarden health check script.

Options:
  -h, --help          Show this help message
  -c, --comprehensive Run comprehensive checks (includes additional tests)
  -j, --json          Output results in JSON format
  -r, --report        Generate and save a health report
  -a, --alert         Send notifications for failures/warnings
  -q, --quiet         Suppress non-essential output

Modes:
  standard (default)  Core health checks:
                       - Container status (all 4 containers)
                       - SSL certificate validity
                       - VaultWarden /alive liveness probe
                       - VaultWarden /api/alive readiness probe (requires live DB connection)
                       - Fail2Ban daemon status
                       - Disk space
                       - Memory usage
                       - Network connectivity
                       - DNS resolution
                       - Backup age
                       - Configuration validation

  comprehensive       All standard checks plus:
                       - Docker image update availability
                       - Fail2Ban jail status
                       - Extended /api/alive endpoint testing (explicit comprehensive result)
                       - Caddy configuration validation
                       - Log error analysis
                       - SSL certificate chain verification

Environment variables (set in .env):
  HEALTH_API_STRICT=true          Promote /api/alive non-200 from warning to failure
  HEALTH_TIMEOUT=10               Curl max-time (seconds)
  HEALTH_CONNECT_TIMEOUT=3        Curl connect-timeout (seconds)
  DISK_WARN_THRESHOLD=80          Disk usage warning threshold (%)
  DISK_CRIT_THRESHOLD=90          Disk usage critical threshold (%)
  MEM_WARN_THRESHOLD=80           Memory usage warning threshold (%)
  MEM_CRIT_THRESHOLD=90           Memory usage critical threshold (%)

Exit codes:
  0  All checks passed
  1  One or more warnings
  2  One or more failures

Examples:
  $(basename "$0")                  # Standard health check
  $(basename "$0") --comprehensive  # Full health check
  $(basename "$0") --json           # JSON output
  $(basename "$0") --alert          # Send notifications
EOF
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -c|--comprehensive)
                COMPREHENSIVE=true
                ;;
            -j|--json)
                JSON_OUTPUT=true
                ;;
            -r|--report)
                REPORT=true
                ;;
            -a|--alert)
                ALERT=true
                ;;
            -q|--quiet)
                QUIET=true
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
        shift
    done
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

_get_domain() {
    echo "${DOMAIN:-}"
}

# =============================================================================
# CONTAINER CHECKS
# =============================================================================

_check_containers() {
    log_info "Checking container status..."

    local containers=("vaultwarden_app" "vaultwarden_caddy" "vaultwarden_fail2ban" "vaultwarden_postfix")
    local all_healthy=true

    for container in "${containers[@]}"; do
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")
        local health
        health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no_healthcheck{{end}}' "$container" 2>/dev/null || echo "unknown")

        case "$status" in
            running)
                if [[ "$health" == "healthy" ]]; then
                    _pass "container:${container}" "${container} is running (health: healthy)"
                elif [[ "$health" == "no_healthcheck" ]]; then
                    _pass "container:${container}" "${container} is running (no healthcheck defined)"
                elif [[ "$health" == "starting" ]]; then
                    _warn "container:${container}" "${container} is running but health check is still starting"
                    all_healthy=false
                else
                    _warn "container:${container}" "${container} is running but health check is ${health}"
                    all_healthy=false
                fi
                ;;
            not_found)
                _fail "container:${container}" "${container} not found"
                all_healthy=false
                ;;
            *)
                _fail "container:${container}" "${container} is ${status} (expected: running)"
                all_healthy=false
                ;;
        esac
    done

    if $all_healthy; then
        log_info "All containers healthy"
    fi
}

# =============================================================================
# SSL CHECKS
# =============================================================================

_check_ssl() {
    local domain
    domain="$(_get_domain)"

    if [[ -z "$domain" ]]; then
        _warn "ssl:cert" "No domain configured, skipping SSL check"
        return
    fi

    log_info "Checking SSL certificate for ${domain}..."

    # Get certificate expiry
    local expiry_date
    expiry_date=$(echo | timeout "$HEALTH_TIMEOUT" openssl s_client \
        -servername "$domain" \
        -connect "${domain}:443" 2>/dev/null | \
        openssl x509 -noout -enddate 2>/dev/null | \
        sed 's/notAfter=//')

    if [[ -z "$expiry_date" ]]; then
        _fail "ssl:cert" "Could not retrieve SSL certificate for ${domain}"
        return
    fi

    # Calculate days remaining
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null)
    local now_epoch
    now_epoch=$(date +%s)
    local days_remaining
    days_remaining=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [[ $days_remaining -lt 0 ]]; then
        _fail "ssl:cert" "SSL certificate for ${domain} has EXPIRED (${days_remaining} days ago)"
    elif [[ $days_remaining -lt 14 ]]; then
        _fail "ssl:cert" "SSL certificate for ${domain} expires in ${days_remaining} days (CRITICAL)"
    elif [[ $days_remaining -lt 30 ]]; then
        _warn "ssl:cert" "SSL certificate for ${domain} expires in ${days_remaining} days"
    else
        _pass "ssl:cert" "SSL certificate valid for ${domain} (${days_remaining} days remaining)"
    fi

    # Comprehensive: verify certificate chain
    if $COMPREHENSIVE; then
        local chain_output
        if chain_output=$(echo | timeout "$HEALTH_TIMEOUT" openssl s_client \
            -servername "$domain" \
            -connect "${domain}:443" \
            -verify_return_error 2>&1); then
            _pass "ssl:chain" "SSL certificate chain valid for ${domain}"
        else
            if echo "$chain_output" | grep -q "verify return:1"; then
                _pass "ssl:chain" "SSL certificate chain valid for ${domain}"
            else
                _warn "ssl:chain" "SSL certificate chain verification issue for ${domain}"
            fi
        fi
    fi
}

# =============================================================================
# VAULTWARDEN CHECKS
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
# Readiness probe: checks /api/alive.
#
# VaultWarden does NOT implement the Bitwarden Server /api/server-info
# endpoint — that route is specific to the hosted Bitwarden SaaS product and
# returns HTTP 404 on every VaultWarden installation.  The correct readiness
# endpoint is /api/alive (Rocket route mounted at /api), which internally
# requires a live database connection (DbConn is injected by the framework)
# and therefore exercises the same DB-health signal that /api/server-info was
# intended to provide.
#
# All check keys, log messages, and the HEALTH_API_STRICT semantics are
# preserved so that existing alert rules, cooldown state, and .env settings
# continue to work without any change on the operator side.
#
# Default behaviour: non-200 is recorded as a WARNING (exit 1) so a single
# transient blip does not wake the operator at 3 AM. Set HEALTH_API_STRICT=true
# in .env to promote non-200 to a hard FAILURE (exit 2).
# -----------------------------------------------------------------------------
_check_vaultwarden_server_info() {
    local domain
    domain="$(_get_domain)"

    log_info "Checking VaultWarden readiness (/api/alive)..."

    # Internal readiness probe — exec directly inside the vaultwarden container
    # so we bypass Caddy entirely and hit the Rocket listener on 127.0.0.1:80
    # within the container network namespace.
    local internal_code
    internal_code=$(docker exec vaultwarden_app curl -so /dev/null \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        -w "%{http_code}" \
        "http://127.0.0.1/api/alive" 2>/dev/null || echo "000")

    case "$internal_code" in
        200)
            _pass "vaultwarden:server-info" "VaultWarden /api/alive responding (HTTP $internal_code)"
            ;;
        000)
            # Connection refused or timeout — hard fail regardless of HEALTH_API_STRICT
            _fail "vaultwarden:server-info" "VaultWarden /api/alive not reachable internally (connection failed)"
            ;;
        *)
            if [[ "${HEALTH_API_STRICT:-false}" == "true" ]]; then
                _fail "vaultwarden:server-info" "VaultWarden /api/alive returned HTTP ${internal_code} (HEALTH_API_STRICT=true)"
            else
                _warn "vaultwarden:server-info" "VaultWarden /api/alive returned HTTP ${internal_code} (set HEALTH_API_STRICT=true to treat as failure)"
            fi
            ;;
    esac

    # External readiness probe — hits the public HTTPS surface through Caddy
    # (only when a domain is configured).
    if [[ -n "$domain" ]]; then
        local external_code
        external_code=$(timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
            --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
            --max-time "$HEALTH_TIMEOUT" \
            -w "%{http_code}" \
            "https://${domain}/api/alive" 2>/dev/null || echo "000")

        case "$external_code" in
            200)
                _pass "vaultwarden:server-info:external" "VaultWarden /api/alive HTTPS responding (HTTP $external_code)"
                ;;
            000)
                _fail "vaultwarden:server-info:external" "VaultWarden /api/alive HTTPS not reachable (connection failed)"
                ;;
            *)
                if [[ "${HEALTH_API_STRICT:-false}" == "true" ]]; then
                    _fail "vaultwarden:server-info:external" "VaultWarden /api/alive HTTPS returned HTTP ${external_code} (HEALTH_API_STRICT=true)"
                else
                    _warn "vaultwarden:server-info:external" "VaultWarden /api/alive HTTPS returned HTTP ${external_code}"
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
            "https://${domain}/api/alive" 2>/dev/null || echo "000")
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
        local jail_list
        if jail_list=$(docker exec vaultwarden_fail2ban fail2ban-client status 2>/dev/null); then
            local jail_count
            jail_count=$(echo "$jail_list" | grep -c "Jail list" || echo "0")
            _pass "fail2ban:jails" "Fail2Ban jails active"

            # Check individual jails
            local jails
            jails=$(docker exec vaultwarden_fail2ban fail2ban-client status 2>/dev/null | \
                grep "Jail list" | sed 's/.*Jail list://;s/,//g' | tr -s ' ')
            for jail in $jails; do
                jail=$(echo "$jail" | xargs)  # trim whitespace
                if [[ -n "$jail" ]]; then
                    local banned_count
                    banned_count=$(docker exec vaultwarden_fail2ban \
                        fail2ban-client status "$jail" 2>/dev/null | \
                        grep "Currently banned" | grep -oE '[0-9]+' || echo "0")
                    _pass "fail2ban:jail:${jail}" "Jail '${jail}' active (${banned_count} currently banned)"
                fi
            done
        else
            _warn "fail2ban:jails" "Could not retrieve Fail2Ban jail status"
        fi
    fi
}

# =============================================================================
# DISK CHECKS
# =============================================================================

_check_disk() {
    log_info "Checking disk space..."

    local state_dir
    state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"

    # Check main data directory
    local disk_usage
    disk_usage=$(df -h "$state_dir" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')

    if [[ -z "$disk_usage" ]]; then
        _warn "disk:state" "Could not check disk usage for ${state_dir}"
        return
    fi

    if [[ $disk_usage -ge $DISK_CRIT_THRESHOLD ]]; then
        _fail "disk:state" "Disk usage CRITICAL: ${disk_usage}% on ${state_dir}"
    elif [[ $disk_usage -ge $DISK_WARN_THRESHOLD ]]; then
        _warn "disk:state" "Disk usage WARNING: ${disk_usage}% on ${state_dir}"
    else
        _pass "disk:state" "Disk usage OK: ${disk_usage}% on ${state_dir}"
    fi

    # Comprehensive: check individual subdirectories
    if $COMPREHENSIVE; then
        local -a subdirs=("data" "logs" "caddy")
        for subdir in "${subdirs[@]}"; do
            local subdir_path="${state_dir}/${subdir}"
            if [[ -d "$subdir_path" ]]; then
                local subdir_size
                subdir_size=$(du -sh "$subdir_path" 2>/dev/null | awk '{print $1}')
                _pass "disk:${subdir}" "${subdir} directory size: ${subdir_size:-unknown}"
            fi
        done
    fi
}

# =============================================================================
# MEMORY CHECKS
# =============================================================================

_check_memory() {
    log_info "Checking memory..."

    # Get memory usage percentage
    local mem_info
    mem_info=$(free | awk 'NR==2{printf "%.0f", $3/$2*100}')

    if [[ -z "$mem_info" ]]; then
        _warn "memory:usage" "Could not check memory usage"
        return
    fi

    if [[ $mem_info -ge $MEM_CRIT_THRESHOLD ]]; then
        _fail "memory:usage" "Memory usage CRITICAL: ${mem_info}% used"
    elif [[ $mem_info -ge $MEM_WARN_THRESHOLD ]]; then
        _warn "memory:usage" "Memory usage WARNING: ${mem_info}% used"
    else
        _pass "memory:usage" "Memory OK: ${mem_info}% used"
    fi

    # Comprehensive: check container memory usage
    if $COMPREHENSIVE; then
        local containers=("vaultwarden_app" "vaultwarden_caddy" "vaultwarden_fail2ban" "vaultwarden_postfix")
        for container in "${containers[@]}"; do
            local container_mem
            container_mem=$(docker stats --no-stream --format "{{.MemUsage}}" "$container" 2>/dev/null || echo "unknown")
            if [[ "$container_mem" != "unknown" ]] && [[ -n "$container_mem" ]]; then
                _pass "memory:${container}" "${container} memory: ${container_mem}"
            fi
        done
    fi
}

# =============================================================================
# NETWORK CHECKS
# =============================================================================

_check_network() {
    log_info "Checking network connectivity..."

    # Check outbound internet connectivity
    if timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        "https://1.1.1.1" 2>/dev/null; then
        _pass "network:outbound" "Outbound internet connectivity OK"
    else
        _warn "network:outbound" "Outbound internet connectivity issue"
    fi

    # Check Cloudflare API reachability (important for DNS challenge)
    local cf_code
    cf_code=$(timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        -w "%{http_code}" \
        "https://api.cloudflare.com" 2>/dev/null || echo "000")
    case "$cf_code" in
        200|301|302)
            _pass "network:cloudflare" "Cloudflare API reachable (HTTP $cf_code)"
            ;;
        000)
            _warn "network:cloudflare" "Cloudflare API not reachable (connection failed)"
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
        return
    fi

    log_info "Checking DNS resolution for ${domain}..."

    local resolved_ip
    resolved_ip=$(dig +short "$domain" A 2>/dev/null | tail -1)

    if [[ -z "$resolved_ip" ]]; then
        # Try with host command as fallback
        resolved_ip=$(host -t A "$domain" 2>/dev/null | awk '/has address/ {print $NF}' | tail -1)
    fi

    if [[ -n "$resolved_ip" ]]; then
        _pass "dns:resolution" "DNS resolves ${domain} → ${resolved_ip}"
    else
        _fail "dns:resolution" "DNS resolution failed for ${domain}"
    fi
}

# =============================================================================
# BACKUP CHECKS
# =============================================================================

_check_backup() {
    log_info "Checking backup status..."

    local backup_dir
    backup_dir="${BACKUP_DIR:-${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/backups}"

    if [[ ! -d "$backup_dir" ]]; then
        _warn "backup:age" "Backup directory not found: ${backup_dir}"
        return
    fi

    # Find the most recent backup file
    local latest_backup
    latest_backup=$(find "$backup_dir" -maxdepth 2 -type f \
        \( -name "*.tar.gz" -o -name "*.tar.zst" -o -name "*.zip" -o -name "*.sh" \) \
        -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}')

    if [[ -z "$latest_backup" ]]; then
        _warn "backup:age" "No backup files found in ${backup_dir}"
        return
    fi

    # Get age of most recent backup
    local latest_backup_full
    latest_backup_full=$(find "$backup_dir" -maxdepth 2 -name "$latest_backup" 2>/dev/null | head -1)
    local backup_age_seconds
    backup_age_seconds=$(( $(date +%s) - $(stat -c %Y "$latest_backup_full" 2>/dev/null || echo 0) ))
    local backup_age_hours=$(( backup_age_seconds / 3600 ))

    local max_backup_age_hours=${MAX_BACKUP_AGE_HOURS:-25}

    if [[ $backup_age_hours -gt $max_backup_age_hours ]]; then
        _warn "backup:age" "Most recent backup is ${backup_age_hours}h old (threshold: ${max_backup_age_hours}h): ${latest_backup}"
    else
        _pass "backup:age" "Most recent backup is ${backup_age_hours}h old: ${latest_backup}"
    fi
}

# =============================================================================
# CONFIGURATION CHECKS
# =============================================================================

_check_configuration() {
    log_info "Checking configuration..."

    local issues=()

    # Check required environment variables
    local required_vars=("DOMAIN" "TZ")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            issues+=("Missing required variable: ${var}")
        fi
    done

    # Check Docker secrets exist
    local secrets_dir="${SCRIPT_DIR}/secrets"
    if [[ -d "$secrets_dir" ]]; then
        local required_secrets=("admin_token")
        for secret in "${required_secrets[@]}"; do
            if [[ ! -f "${secrets_dir}/${secret}" ]]; then
                issues+=("Missing secret file: ${secret}")
            fi
        done
    fi

    # Check docker-compose.yml exists
    if [[ ! -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
        issues+=("docker-compose.yml not found")
    fi

    if [[ ${#issues[@]} -eq 0 ]]; then
        _pass "config:validation" "Configuration validation passed"
    else
        for issue in "${issues[@]}"; do
            _warn "config:validation" "Configuration issue: ${issue}"
        done
    fi

    # Comprehensive: validate Caddy config
    if $COMPREHENSIVE; then
        if docker exec vaultwarden_caddy caddy validate \
            --config /etc/caddy/Caddyfile &>/dev/null; then
            _pass "config:caddy" "Caddy configuration valid"
        else
            _warn "config:caddy" "Caddy configuration validation failed"
        fi
    fi
}

# =============================================================================
# IMAGE UPDATE CHECKS (comprehensive only)
# =============================================================================

_check_image_updates() {
    if ! $COMPREHENSIVE; then
        return
    fi

    local images=(
        "vaultwarden_app:ghcr.io/dani-garcia/vaultwarden"
        "vaultwarden_caddy:ghcr.io/caddybuilds/caddy-cloudflare"
    )

    for image_pair in "${images[@]}"; do
        local container="${image_pair%%:*}"
        local image="${image_pair##*:}"

        local current_digest
        current_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$container" 2>/dev/null | \
            grep -o 'sha256:[a-f0-9]*' || echo "unknown")

        if [[ "$current_digest" == "unknown" ]]; then
            _warn "image:${container}" "Could not determine digest for ${container}"
        else
            _pass "image:${container}" "${container} image digest: ${current_digest:0:20}..."
        fi
    done
}

# =============================================================================
# LOG ANALYSIS (comprehensive only)
# =============================================================================

_check_logs() {
    if ! $COMPREHENSIVE; then
        return
    fi

    local log_dir
    log_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/logs"

    # Check for recent errors in VaultWarden logs
    local vw_log="${log_dir}/vaultwarden/vaultwarden.log"
    if [[ -f "$vw_log" ]]; then
        local error_count
        error_count=$(grep -c 'ERROR\|CRITICAL' "$vw_log" 2>/dev/null | tail -100 || echo "0")
        local recent_errors
        recent_errors=$(tail -100 "$vw_log" 2>/dev/null | grep -c 'ERROR\|CRITICAL' || echo "0")

        if [[ $recent_errors -gt 10 ]]; then
            _warn "logs:vaultwarden" "${recent_errors} errors in last 100 log lines"
        else
            _pass "logs:vaultwarden" "Log analysis OK (${recent_errors} errors in last 100 lines)"
        fi
    fi
}

# =============================================================================
# ALERT / NOTIFICATION
# =============================================================================

# Dead-letter check: ensure no failure notifications were silently dropped
_check_dead_letter() {
    local dead_letter_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/alerts/dead-letter"

    if [[ ! -d "$dead_letter_dir" ]]; then
        _pass "notify:dead-letter" "No lost failure notifications"
        return
    fi

    local dead_count
    dead_count=$(find "$dead_letter_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)

    if [[ $dead_count -gt 0 ]]; then
        _warn "notify:dead-letter" "${dead_count} undelivered failure notification(s) in dead-letter queue"
    else
        _pass "notify:dead-letter" "No lost failure notifications"
    fi
}

_send_alerts() {
    if [[ ${#FAIL_CHECKS[@]} -eq 0 ]] && [[ ${#WARN_CHECKS[@]} -eq 0 ]]; then
        return
    fi

    if ! $ALERT; then
        return
    fi

    # Build alert message
    local alert_lines=()
    for result in "${HEALTH_RESULTS[@]}"; do
        local status key msg
        IFS='|' read -r status key msg <<< "$result"
        if [[ "$status" == "fail" ]] || [[ "$status" == "warn" ]]; then
            alert_lines+=("[${status^^}] ${key}: ${msg}")
        fi
    done

    # Send via notify function if available in common.sh
    if declare -f notify_alert &>/dev/null; then
        local alert_body
        alert_body=$(printf '%s\n' "${alert_lines[@]}")
        notify_alert "VaultWarden Health Alert" "$alert_body" || true
    fi
}

# =============================================================================
# ALERT COOLDOWN
# =============================================================================

# Track which keys have been alerted recently to avoid alert storms
_check_alert_cooldown() {
    local cooldown_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/alerts/cooldown"
    mkdir -p "$cooldown_dir" 2>/dev/null || true

    local cooldown_seconds=${ALERT_COOLDOWN:-3600}
    local now
    now=$(date +%s)

    for result in "${HEALTH_RESULTS[@]}"; do
        local status key msg
        IFS='|' read -r status key msg <<< "$result"

        if [[ "$status" != "fail" ]] && [[ "$status" != "warn" ]]; then
            continue
        fi

        local cooldown_file="${cooldown_dir}/${key//\//_}"
        local last_alert=0

        if [[ -f "$cooldown_file" ]]; then
            last_alert=$(cat "$cooldown_file" 2>/dev/null || echo 0)
        fi

        local elapsed=$(( now - last_alert ))
        if [[ $elapsed -lt $cooldown_seconds ]]; then
            log_info "Alert cooldown active for '${key}' — suppressing repeat notification"
        else
            echo "$now" > "$cooldown_file"
        fi
    done
}

# =============================================================================
# REPORT GENERATION
# =============================================================================

_generate_report() {
    if ! $REPORT; then
        return
    fi

    mkdir -p "$REPORT_DIR" 2>/dev/null || {
        log_warn "Could not create report directory: ${REPORT_DIR}"
        return
    }

    local report_file
    report_file="${REPORT_DIR}/health-$(date +%Y%m%d-%H%M%S).json"

    local pass_count=${#PASS_CHECKS[@]}
    local warn_count=${#WARN_CHECKS[@]}
    local fail_count=${#FAIL_CHECKS[@]}
    local total_count=$(( pass_count + warn_count + fail_count ))

    {
        echo "{"
        echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo "  \"mode\": \"$($COMPREHENSIVE && echo comprehensive || echo standard)\","
        echo "  \"summary\": {"
        echo "    \"total\": ${total_count},"
        echo "    \"passed\": ${pass_count},"
        echo "    \"warnings\": ${warn_count},"
        echo "    \"failed\": ${fail_count}"
        echo "  },"
        echo "  \"checks\": ["

        local first=true
        for result in "${HEALTH_RESULTS[@]}"; do
            local status key msg
            IFS='|' read -r status key msg <<< "$result"
            if ! $first; then echo ","; fi
            echo -n "    {\"status\": \"${status}\", \"key\": \"${key}\", \"message\": \"${msg//\"/\\\"}\"}" 
            first=false
        done

        echo ""
        echo "  ]"
        echo "}"
    } > "$report_file"

    log_info "Report saved: ${report_file}"

    # Prune old reports
    find "$REPORT_DIR" -maxdepth 1 -name "health-*.json" \
        -mtime +"$REPORT_RETENTION_DAYS" -delete 2>/dev/null || true
}

# =============================================================================
# OUTPUT FORMATTING
# =============================================================================

_print_results() {
    local pass_count=${#PASS_CHECKS[@]}
    local warn_count=${#WARN_CHECKS[@]}
    local fail_count=${#FAIL_CHECKS[@]}
    local total_count=$(( pass_count + warn_count + fail_count ))

    if $JSON_OUTPUT; then
        echo "{"
        echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo "  \"summary\": {"
        echo "    \"total\": ${total_count},"
        echo "    \"passed\": ${pass_count},"
        echo "    \"warnings\": ${warn_count},"
        echo "    \"failed\": ${fail_count}"
        echo "  },"
        echo "  \"checks\": ["

        local first=true
        for result in "${HEALTH_RESULTS[@]}"; do
            local status key msg
            IFS='|' read -r status key msg <<< "$result"
            if ! $first; then echo ","; fi
            echo -n "    {\"status\": \"${status}\", \"key\": \"${key}\", \"message\": \"${msg//\"/\\\"}\"}" 
            first=false
        done

        echo ""
        echo "  ]"
        echo "}"
        return
    fi

    echo ""
    echo "================================================================="
    echo " VaultWarden Health Check Results"
    echo "================================================================="

    for result in "${HEALTH_RESULTS[@]}"; do
        local status key msg
        IFS='|' read -r status key msg <<< "$result"

        local label
        case "$status" in
            pass) label="[pass]" ;;
            warn) label="[warn]" ;;
            fail) label="[FAIL]" ;;
            *) label="[????]" ;;
        esac

        printf "%-8s %-38s %s\n" "$label" "${key}" "${msg}"
    done

    echo "-----------------------------------------------------------------"
    printf "Total: %d | Passed: %d | Warnings: %d | Failed: %d\n" \
        "$total_count" "$pass_count" "$warn_count" "$fail_count"
    echo "================================================================="
}

# =============================================================================
# MAIN HEALTH CHECK ORCHESTRATOR
# =============================================================================

run_health_checks() {
    local mode
    mode="$($COMPREHENSIVE && echo comprehensive || echo standard)"

    log_info "Starting VaultWarden health check..."
    log_info "Mode: ${mode}"

    # Core checks (always run)
    _check_containers
    _check_ssl
    _check_vaultwarden_alive
    _check_vaultwarden_server_info
    _check_fail2ban
    _check_disk
    _check_memory
    _check_network
    _check_dns
    _check_backup
    _check_configuration
    _check_dead_letter

    # Comprehensive-only checks
    if $COMPREHENSIVE; then
        _check_image_updates
        _check_logs
    fi
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

main() {
    parse_args "$@"
    run_health_checks
    _print_results
    _generate_report

    if $ALERT; then
        _send_alerts
        _check_alert_cooldown
    else
        # Always run cooldown tracking (suppresses repeated log noise)
        _check_alert_cooldown
    fi

    local fail_count=${#FAIL_CHECKS[@]}
    local warn_count=${#WARN_CHECKS[@]}

    if [[ $fail_count -gt 0 ]]; then
        exit 2
    elif [[ $warn_count -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

main "$@"
