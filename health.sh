#!/usr/bin/env bash
# =============================================================================
# VaultWarden Health Check Script
# =============================================================================
#
# Usage: ./health.sh [OPTIONS]
#
# OPTIONS:
#   --comprehensive    Run extended checks (additional endpoints, jail details)
#   --json             Output results as JSON
#   --quiet            Suppress all output except errors
#   --no-notify        Skip notification sending
#   --auto-fix         Attempt to fix failed checks automatically
#   --check <name>     Run only the specified check
#   --help             Show this help message
#
# ENVIRONMENT VARIABLES (set in .env or calling environment):
#   HEALTH_TIMEOUT          curl total timeout in seconds (default: 10)
#   HEALTH_CONNECT_TIMEOUT  curl connect timeout in seconds (default: 3)
#   HEALTH_RETRIES          Number of retries for failed checks (default: 3)
#   HEALTH_RETRY_DELAY      Seconds between retries (default: 2)
#   HEALTH_API_STRICT=true  Promote /api/alive non-200 from warning to failure
#   AUTO_FIX=true           Enable automatic remediation
#   DISK_WARN_THRESHOLD     Disk usage warning percentage (default: 80)
#   DISK_CRIT_THRESHOLD     Disk usage critical percentage (default: 90)
#   MEM_WARN_THRESHOLD      Memory usage warning percentage (default: 80)
#   MEM_CRIT_THRESHOLD      Memory usage critical percentage (default: 90)
#
# EXIT CODES:
#   0   All checks passed
#   1   One or more warnings (non-critical)
#   2   One or more failures (critical)
#   3   Script error
#
# STANDARD CHECKS (always run):
#   - Container status (all 4 containers must be healthy)
#   - SSL certificate validity and expiry
#   - VaultWarden /alive liveness probe
#   - VaultWarden /api/alive readiness probe (requires live DB connection)
#   - Fail2Ban daemon health
#   - Disk space usage
#   - Memory usage
#   - Network connectivity
#   - DNS resolution
#   - Backup age
#   - Configuration validation
#
# COMPREHENSIVE CHECKS (--comprehensive flag):
#   - All standard checks
#   - Fail2Ban jail status and ban counts
#   - Extended /api/alive endpoint testing (explicit comprehensive result)
#   - Caddy admin API check
#
# =============================================================================
set -euo pipefail

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

HEALTH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# LIBRARY LOADING
# =============================================================================

if [[ -f "${HEALTH_SCRIPT_DIR}/lib/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${HEALTH_SCRIPT_DIR}/lib/common.sh"
else
    echo "[ERROR] lib/common.sh not found" >&2
    exit 3
fi

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

COMPREHENSIVE=false
JSON_OUTPUT=false
QUIET=false
NO_NOTIFY=false
CHECK_ONLY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --comprehensive)
            COMPREHENSIVE=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --quiet)
            QUIET=true
            shift
            ;;
        --no-notify)
            NO_NOTIFY=true
            shift
            ;;
        --auto-fix)
            AUTO_FIX=true
            shift
            ;;
        --check)
            CHECK_ONLY="$2"
            shift 2
            ;;
        --help)
            head -60 "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 3
            ;;
    esac
done

# =============================================================================
# ENVIRONMENT LOADING
# =============================================================================

_load_env() {
    local env_file
    env_file="${HEALTH_SCRIPT_DIR}/.env"

    if [[ -f "$env_file" ]]; then
        # shellcheck disable=SC1090
        set -o allexport
        source "$env_file"
        set +o allexport
        log_debug "Environment loaded successfully from: $env_file"
    else
        log_warn "No .env file found at $env_file — using defaults"
    fi
}

_load_env

# =============================================================================
# RESULT TRACKING
# =============================================================================

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
RESULTS=()

_pass() {
    local key="$1" msg="$2"
    PASS_COUNT=$((PASS_COUNT + 1))
    RESULTS+=("pass|${key}|${msg}")
    _record_result "$key" "pass" "$msg"
}

_warn() {
    local key="$1" msg="$2"
    WARN_COUNT=$((WARN_COUNT + 1))
    RESULTS+=("warn|${key}|${msg}")
    _record_result "$key" "warn" "$msg"
    if [[ "$NO_NOTIFY" != "true" ]]; then
        _send_alert_if_needed "$key" "warn" "$msg"
    fi
}

_fail() {
    local key="$1" msg="$2"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    RESULTS+=("fail|${key}|${msg}")
    _record_result "$key" "fail" "$msg"
    if [[ "$NO_NOTIFY" != "true" ]]; then
        _send_alert_if_needed "$key" "fail" "$msg"
    fi
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

_get_domain() {
    echo "${DOMAIN:-}"
}

# =============================================================================
# CONTAINER CHECKS
# =============================================================================

_check_containers() {
    log_info "Checking container status..."

    local containers=(
        "vaultwarden_app"
        "vaultwarden_caddy"
        "vaultwarden_fail2ban"
        "vaultwarden_postfix"
    )

    local all_healthy=true

    for container in "${containers[@]}"; do
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "missing")
        local health
        health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$container" 2>/dev/null || echo "unknown")

        case "$status" in
            running)
                case "$health" in
                    healthy|no-healthcheck)
                        _pass "container:${container}" "${container} is running (health: ${health})"
                        ;;
                    starting)
                        _warn "container:${container}" "${container} is running but health check is still starting"
                        all_healthy=false
                        ;;
                    unhealthy)
                        _fail "container:${container}" "${container} is running but health check reports UNHEALTHY"
                        all_healthy=false
                        ;;
                    *)
                        _warn "container:${container}" "${container} is running with unexpected health state: ${health}"
                        all_healthy=false
                        ;;
                esac
                ;;
            missing)
                _fail "container:${container}" "${container} container not found"
                all_healthy=false
                ;;
            *)
                _fail "container:${container}" "${container} is in unexpected state: ${status}"
                all_healthy=false
                ;;
        esac
    done

    if $all_healthy; then
        log_info "All containers healthy"
    fi
}

# =============================================================================
# SSL CERTIFICATE CHECK
# =============================================================================

_check_ssl() {
    local domain
    domain="$(_get_domain)"

    if [[ -z "$domain" ]]; then
        _warn "ssl:cert" "No domain configured — skipping SSL check"
        return
    fi

    log_info "Checking SSL certificate for ${domain}..."

    local expiry_output
    expiry_output=$(echo | timeout "$HEALTH_TIMEOUT" openssl s_client \
        -connect "${domain}:443" \
        -servername "$domain" \
        2>/dev/null | openssl x509 -noout -enddate 2>/dev/null || echo "")

    if [[ -z "$expiry_output" ]]; then
        _warn "ssl:cert" "Could not retrieve SSL certificate for ${domain}"
        return
    fi

    local expiry_date
    expiry_date=$(echo "$expiry_output" | cut -d= -f2)

    local expiry_epoch
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null || echo "0")

    local now_epoch
    now_epoch=$(date +%s)

    local days_remaining
    days_remaining=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [[ $days_remaining -le 0 ]]; then
        _fail "ssl:cert" "SSL certificate for ${domain} has EXPIRED"
    elif [[ $days_remaining -le 7 ]]; then
        _fail "ssl:cert" "SSL certificate for ${domain} expires in ${days_remaining} days (CRITICAL)"
    elif [[ $days_remaining -le 14 ]]; then
        _warn "ssl:cert" "SSL certificate for ${domain} expires in ${days_remaining} days (WARNING)"
    elif [[ $days_remaining -le 30 ]]; then
        _warn "ssl:cert" "SSL certificate for ${domain} expires in ${days_remaining} days"
    else
        _pass "ssl:cert" "SSL certificate valid for ${domain} (${days_remaining} days remaining)"
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
        local jails
        jails=$(docker exec vaultwarden_fail2ban fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*Jail list://' | tr -d ' ' | tr ',' '\n' || echo "")

        if [[ -z "$jails" ]]; then
            _warn "fail2ban:jails" "No active Fail2Ban jails found"
        else
            while IFS= read -r jail; do
                [[ -z "$jail" ]] && continue
                local jail_status
                jail_status=$(docker exec vaultwarden_fail2ban fail2ban-client status "$jail" 2>/dev/null || echo "")
                local banned_count
                banned_count=$(echo "$jail_status" | grep -i "currently banned" | awk '{print $NF}' || echo "0")
                _pass "fail2ban:jail:${jail}" "Jail '${jail}' active (${banned_count} currently banned)"
            done <<< "$jails"
        fi
    fi
}

# =============================================================================
# DISK SPACE CHECK
# =============================================================================

_check_disk() {
    log_info "Checking disk space..."

    local state_dir
    state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"

    local usage_output
    usage_output=$(df -h "$state_dir" 2>/dev/null | tail -1 || echo "")

    if [[ -z "$usage_output" ]]; then
        _warn "disk:state" "Could not check disk usage for ${state_dir}"
        return
    fi

    local usage_pct
    usage_pct=$(echo "$usage_output" | awk '{print $5}' | tr -d '%')

    if [[ -z "$usage_pct" ]] || ! [[ "$usage_pct" =~ ^[0-9]+$ ]]; then
        _warn "disk:state" "Could not parse disk usage for ${state_dir}"
        return
    fi

    if [[ $usage_pct -ge $DISK_CRIT_THRESHOLD ]]; then
        _fail "disk:state" "Disk usage CRITICAL: ${usage_pct}% on ${state_dir} (threshold: ${DISK_CRIT_THRESHOLD}%)"
    elif [[ $usage_pct -ge $DISK_WARN_THRESHOLD ]]; then
        _warn "disk:state" "Disk usage WARNING: ${usage_pct}% on ${state_dir} (threshold: ${DISK_WARN_THRESHOLD}%)"
    else
        _pass "disk:state" "Disk usage OK: ${usage_pct}% on ${state_dir}"
    fi
}

# =============================================================================
# MEMORY CHECK
# =============================================================================

_check_memory() {
    log_info "Checking memory..."

    local mem_info
    mem_info=$(free -m 2>/dev/null || echo "")

    if [[ -z "$mem_info" ]]; then
        _warn "memory:usage" "Could not read memory information"
        return
    fi

    local total_mem
    total_mem=$(echo "$mem_info" | awk '/^Mem:/{print $2}')
    local used_mem
    used_mem=$(echo "$mem_info" | awk '/^Mem:/{print $3}')

    if [[ -z "$total_mem" ]] || [[ -z "$used_mem" ]] || [[ $total_mem -eq 0 ]]; then
        _warn "memory:usage" "Could not parse memory information"
        return
    fi

    local usage_pct
    usage_pct=$(( (used_mem * 100) / total_mem ))

    if [[ $usage_pct -ge $MEM_CRIT_THRESHOLD ]]; then
        _fail "memory:usage" "Memory usage CRITICAL: ${usage_pct}% used (threshold: ${MEM_CRIT_THRESHOLD}%)"
    elif [[ $usage_pct -ge $MEM_WARN_THRESHOLD ]]; then
        _warn "memory:usage" "Memory usage WARNING: ${usage_pct}% used (threshold: ${MEM_WARN_THRESHOLD}%)"
    else
        _pass "memory:usage" "Memory OK: ${usage_pct}% used"
    fi
}

# =============================================================================
# NETWORK CHECKS
# =============================================================================

_check_network() {
    log_info "Checking network connectivity..."

    # Outbound internet check
    local outbound_code
    outbound_code=$(timeout "$HEALTH_TIMEOUT" curl -so /dev/null \
        --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        -w "%{http_code}" \
        "https://www.google.com" 2>/dev/null || echo "000")

    case "$outbound_code" in
        200|301|302)
            _pass "network:outbound" "Outbound internet connectivity OK"
            ;;
        000)
            _fail "network:outbound" "No outbound internet connectivity (connection failed)"
            ;;
        *)
            _warn "network:outbound" "Unexpected response from internet check: HTTP ${outbound_code}"
            ;;
    esac

    # Cloudflare API reachability (relevant when using Cloudflare DNS)
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
            _pass "network:cloudflare" "Cloudflare API reachable (HTTP $cf_code)"
            ;;
    esac
}

# =============================================================================
# DNS CHECK
# =============================================================================

_check_dns() {
    local domain
    domain="$(_get_domain)"

    if [[ -z "$domain" ]]; then
        return
    fi

    log_info "Checking DNS resolution for ${domain}..."

    local resolved_ip
    resolved_ip=$(dig +short "$domain" 2>/dev/null | tail -1 || \
                  nslookup "$domain" 2>/dev/null | grep -A1 'Name:' | tail -1 | awk '{print $2}' || \
                  echo "")

    if [[ -z "$resolved_ip" ]]; then
        _fail "dns:resolution" "DNS resolution failed for ${domain}"
    else
        _pass "dns:resolution" "DNS resolves ${domain} → ${resolved_ip}"
    fi
}

# =============================================================================
# BACKUP CHECK
# =============================================================================

_check_backup() {
    log_info "Checking backup status..."

    local backup_dir
    backup_dir="${BACKUP_DIR:-${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/backups}"

    if [[ ! -d "$backup_dir" ]]; then
        _warn "backup:age" "Backup directory not found: ${backup_dir}"
        return
    fi

    local latest_backup
    latest_backup=$(find "$backup_dir" -type f -newer /proc/1 2>/dev/null | sort -t/ -k1 | tail -1 || \
                    ls -t "$backup_dir" 2>/dev/null | head -1 || echo "")

    if [[ -z "$latest_backup" ]]; then
        # Try finding any file in the backup dir
        latest_backup=$(ls -t "$backup_dir" 2>/dev/null | head -1 || echo "")
    fi

    if [[ -z "$latest_backup" ]]; then
        _warn "backup:age" "No backups found in ${backup_dir}"
        return
    fi

    # Get the modification time of the latest backup
    local backup_file
    backup_file="${backup_dir}/${latest_backup}"
    if [[ ! -f "$backup_file" ]]; then
        backup_file="$latest_backup"
    fi

    local backup_mtime
    backup_mtime=$(stat -c %Y "$backup_file" 2>/dev/null || stat -f %m "$backup_file" 2>/dev/null || echo "0")
    local now_epoch
    now_epoch=$(date +%s)
    local age_hours
    age_hours=$(( (now_epoch - backup_mtime) / 3600 ))

    local backup_name
    backup_name=$(basename "$backup_file")

    local warn_hours=${BACKUP_WARN_AGE_HOURS:-25}
    local crit_hours=${BACKUP_CRIT_AGE_HOURS:-48}

    if [[ $age_hours -ge $crit_hours ]]; then
        _fail "backup:age" "Backup is ${age_hours}h old (CRITICAL — threshold: ${crit_hours}h): ${backup_name}"
    elif [[ $age_hours -ge $warn_hours ]]; then
        _warn "backup:age" "Backup is ${age_hours}h old (WARNING — threshold: ${warn_hours}h): ${backup_name}"
    else
        _pass "backup:age" "Most recent backup is ${age_hours}h old: ${backup_name}"
    fi
}

# =============================================================================
# CONFIGURATION VALIDATION
# =============================================================================

_check_config() {
    log_info "Checking configuration..."

    local issues=()

    # Check required variables
    local required_vars=(
        "DOMAIN"
        "PUID"
        "PGID"
    )

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            issues+=("Required variable ${var} is not set")
        fi
    done

    # Check that docker-compose.yml exists
    local compose_file="${HEALTH_SCRIPT_DIR}/docker-compose.yml"
    if [[ ! -f "$compose_file" ]]; then
        issues+=("docker-compose.yml not found at ${compose_file}")
    fi

    # Check that secrets directory exists
    local secrets_dir="${HEALTH_SCRIPT_DIR}/secrets"
    if [[ ! -d "$secrets_dir" ]]; then
        issues+=("Secrets directory not found: ${secrets_dir}")
    fi

    if [[ ${#issues[@]} -eq 0 ]]; then
        _pass "config:validation" "Configuration validation passed"
    else
        local issues_str
        issues_str=$(printf '%s; ' "${issues[@]}")
        _warn "config:validation" "Configuration issues: ${issues_str%%; }"
    fi
}

# =============================================================================
# NOTIFICATION DEAD-LETTER CHECK
# =============================================================================

_check_notify_dead_letter() {
    local dead_letter_dir
    dead_letter_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/alerts/dead-letter"

    if [[ ! -d "$dead_letter_dir" ]]; then
        _pass "notify:dead-letter" "No lost failure notifications"
        return
    fi

    local count
    count=$(find "$dead_letter_dir" -type f 2>/dev/null | wc -l)

    if [[ $count -eq 0 ]]; then
        _pass "notify:dead-letter" "No lost failure notifications"
    else
        _warn "notify:dead-letter" "${count} unsent failure notification(s) in dead-letter queue: ${dead_letter_dir}"
    fi
}

# =============================================================================
# REPORT FUNCTIONS
# =============================================================================

_print_results() {
    local total=$(( PASS_COUNT + WARN_COUNT + FAIL_COUNT ))
    local width=65

    echo ""
    printf '=%.0s' $(seq 1 $width); echo
    printf ' VaultWarden Health Check Results\n'
    printf '=%.0s' $(seq 1 $width); echo

    for result in "${RESULTS[@]}"; do
        IFS='|' read -r status key msg <<< "$result"
        printf '[%-4s] %-40s %s\n' "$status" "$key" "$msg"
    done

    printf -- '-%.0s' $(seq 1 $width); echo
    printf 'Total: %d | Passed: %d | Warnings: %d | Failed: %d\n' \
        "$total" "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
    printf '=%.0s' $(seq 1 $width); echo
}

_print_results_json() {
    local total=$(( PASS_COUNT + WARN_COUNT + FAIL_COUNT ))
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    echo "{"
    echo "  \"timestamp\": \"${timestamp}\","
    echo "  \"summary\": {"
    echo "    \"total\": ${total},"
    echo "    \"passed\": ${PASS_COUNT},"
    echo "    \"warnings\": ${WARN_COUNT},"
    echo "    \"failed\": ${FAIL_COUNT}"
    echo "  },"
    echo "  \"checks\": ["

    local first=true
    for result in "${RESULTS[@]}"; do
        IFS='|' read -r status key msg <<< "$result"
        if ! $first; then echo ","; fi
        printf '    {"status": "%s", "key": "%s", "message": "%s"}' \
            "$status" "$key" "$(echo "$msg" | sed 's/"/\\"/g')"
        first=false
    done

    echo ""
    echo "  ]"
    echo "}"
}

_save_report() {
    if [[ ! -d "$REPORT_DIR" ]]; then
        mkdir -p "$REPORT_DIR" 2>/dev/null || return
    fi

    local report_file
    report_file="${REPORT_DIR}/health-$(date +%Y%m%d-%H%M%S).json"

    _print_results_json > "$report_file" 2>/dev/null || return

    # Prune old reports
    find "$REPORT_DIR" -name 'health-*.json' -mtime +"${REPORT_RETENTION_DAYS}" -delete 2>/dev/null || true
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    log_info "Starting VaultWarden health check..."

    if $COMPREHENSIVE; then
        log_info "Mode: comprehensive"
    else
        log_info "Mode: standard"
    fi

    # Run checks (selective or all)
    if [[ -n "$CHECK_ONLY" ]]; then
        case "$CHECK_ONLY" in
            containers)     _check_containers ;;
            ssl)            _check_ssl ;;
            alive)          _check_vaultwarden_alive ;;
            server-info)    _check_vaultwarden_server_info ;;
            fail2ban)       _check_fail2ban ;;
            disk)           _check_disk ;;
            memory)         _check_memory ;;
            network)        _check_network ;;
            dns)            _check_dns ;;
            backup)         _check_backup ;;
            config)         _check_config ;;
            *)
                echo "Unknown check: ${CHECK_ONLY}" >&2
                exit 3
                ;;
        esac
    else
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
        _check_config
        _check_notify_dead_letter
    fi

    # Output results
    if $JSON_OUTPUT; then
        _print_results_json
    elif ! $QUIET; then
        _print_results
    fi

    _save_report

    # Exit with appropriate code
    if [[ $FAIL_COUNT -gt 0 ]]; then
        exit 2
    elif [[ $WARN_COUNT -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

main "$@"
