#!/usr/bin/env bash
# utilities/maintenance-health.sh — Runs VaultWarden health checks and diagnostics.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# lib/secrets.sh recomputes SCRIPT_DIR at load time, so save and restore PROJECT_ROOT's value.
_SAVE_SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/log.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/common.sh"
init_common_lib "$0"
source "$PROJECT_ROOT/lib/operations.sh"
source "$PROJECT_ROOT/lib/email.sh"
DOCKER_PROJECT_LABEL="${DOCKER_PROJECT_LABEL:-label=com.docker.compose.project=vaultwarden-oci}"
source "$PROJECT_ROOT/lib/docker.sh"
source "$PROJECT_ROOT/lib/backup-utils.sh"
source "$PROJECT_ROOT/lib/crypto.sh"
source "$PROJECT_ROOT/lib/secrets.sh"
source "$PROJECT_ROOT/lib/storage.sh"
SCRIPT_DIR="$_SAVE_SCRIPT_DIR"
unset _SAVE_SCRIPT_DIR

# Default path helpers mirror maintenance.sh, and storage.sh provides vw_default_backup_dir.
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

_resolve_age_key() {
    local candidates=(
        "${SOPS_AGE_KEY_FILE:-}"
        "/etc/vaultwarden/age-key.txt"
        "${PROJECT_ROOT}/secrets/keys/age-key.txt"
    )
    local candidate
    for candidate in "${candidates[@]}"; do
        [[ -z "$candidate" ]] && continue
        if [[ "$candidate" != /* ]]; then
            if [[ -f "$PROJECT_ROOT/$candidate" ]]; then
                echo "$PROJECT_ROOT/$candidate"
                return 0
            fi
            [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
            continue
        fi
        [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
    done
    # Mirror backup-run fallback behavior for diagnostics.
    for candidate in "${candidates[@]}"; do
        [[ -n "$candidate" && "$candidate" == /* ]] && { echo "$candidate"; return 1; }
    done
    echo "/etc/vaultwarden/age-key.txt"
    return 1
}

_resolve_backup_base_dir() {
    local configured
    configured="$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")"
    if [[ "$configured" != /* ]]; then
        printf '%s/%s\n' "$PROJECT_ROOT" "$configured"
    else
        printf '%s\n' "$configured"
    fi
}

run_health_check() {
_resolve_env_file() {
    local candidates=(
        "/etc/vaultwarden/vaultwarden.env"
        "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/config/install.env"
        "${PROJECT_ROOT}/.env"
    )
    local first_existing=""
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            [[ -n "$first_existing" ]] || first_existing="$candidate"
            if [[ -r "$candidate" ]]; then
                echo "$candidate"
                return 0
            fi
        fi
    done
    if [[ -n "$first_existing" ]]; then
        echo "$first_existing"
        return 0
    fi
    echo ""
    return 1
}

local ENV_FILE
ENV_FILE="$(_resolve_env_file || true)"

if [[ -n "${ENV_FILE}" ]]; then
    if [[ ! -r "${ENV_FILE}" ]]; then
        log_error "maintenance.sh health: '${ENV_FILE}' is not readable by $(id -un); refusing to continue with unset runtime config."
        log_error "Run health through the root-operated path: sudo make health"
        return 3
    else
        # load_env_file returns 1 when run as root and the file has permissions
        # wider than 0600, such as 640 or 644. That is a warning, not a fatal
        # error, so log it and continue to avoid silently aborting via set -e.
        load_env_file "${ENV_FILE}" 2>/dev/null || \
            log_warn "maintenance-health: env file '${ENV_FILE}' could not be loaded." \
                 "If running as root, permissions must be 600 (run: chmod 600 '${ENV_FILE}')." \
                 "Continuing with inherited environment only."
    fi
else
    log_error "maintenance.sh health: no runtime env file found at '/etc/vaultwarden/vaultwarden.env', '${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/config/install.env', or '${PROJECT_ROOT}/.env'."
    log_error "Run setup first, then use: sudo make health"
    ENV_FILE="/etc/vaultwarden/vaultwarden.env"
    return 3
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
local HEALTH_LOCK_FD=""

_health_readonly_lock_path() {
    if [[ -n "${VW_HEALTH_LOCK_FILE:-}" ]]; then
        printf '%s\n' "$VW_HEALTH_LOCK_FILE"
    elif [[ $EUID -eq 0 ]]; then
        printf '%s\n' "/run/lock/vaultwarden-health.lock"
    elif [[ -n "${XDG_RUNTIME_DIR:-}" && -d "${XDG_RUNTIME_DIR:-}" && -w "${XDG_RUNTIME_DIR:-}" ]]; then
        printf '%s\n' "${XDG_RUNTIME_DIR}/vaultwarden-health.lock"
    else
        printf '%s\n' "${TMPDIR:-/tmp}/vaultwarden-health-${EUID}.lock"
    fi
}

_acquire_readonly_health_lock() {
    local lock_path lock_dir fd
    lock_path="$(_health_readonly_lock_path)"
    lock_dir="$(dirname "$lock_path")"
    if ! mkdir -p "$lock_dir" 2>/dev/null; then
        log_error "Cannot prepare health coordination directory: $lock_dir"
        return 3
    fi
    if ! : >> "$lock_path" 2>/dev/null; then
        log_error "Cannot open health coordination lock: $lock_path"
        return 3
    fi
    chmod 0600 "$lock_path" 2>/dev/null || true
    if ! { exec {fd}>"$lock_path"; } 2>/dev/null; then
        log_error "Cannot open health coordination lock: $lock_path"
        return 3
    fi
    if ! flock -n "$fd" 2>/dev/null; then
        { eval "exec ${fd}>&-"; } 2>/dev/null || true
        log_warn "Another VaultWarden health check is already running; skipping this duplicate run."
        return 75
    fi
    HEALTH_LOCK_FD="$fd"
}

_acquire_run_lock() {
    if [[ "$FIX_MODE" == "true" ]]; then
        operation_acquire \
            --id health-repair \
            --label "Health repair" \
            --specific-lock /run/lock/vaultwarden-health.lock \
            --non-interactive skip || {
                local rc=$?
                (( rc == 75 )) && return 75
                log_error "Health repair operation guard failed before checks could run."
                return 4
            }
        operation_set_phase "repair" "Health check with auto-repair"
    else
        _acquire_readonly_health_lock
    fi
}

_release_run_lock() {
    local rc=$?
    if [[ "$FIX_MODE" == "true" ]]; then
        operation_release "$rc"
    elif [[ -n "${HEALTH_LOCK_FD:-}" ]]; then
        flock -u "$HEALTH_LOCK_FD" 2>/dev/null || true
        { eval "exec ${HEALTH_LOCK_FD}>&-"; } 2>/dev/null || true
        HEALTH_LOCK_FD=""
    fi
    return "$rc"
}

local ALERT_LOCK_DIR="${ALERT_STATE_DIR:-$(_default_alert_state_dir)}"
local ALERT_COOLDOWN_SECONDS=${ALERT_COOLDOWN_SECONDS:-3600}
local ALERT_RECOVERY_TTL=${ALERT_RECOVERY_TTL:-86400}
local ACTIVE_INCIDENT_FILE="${ALERT_LOCK_DIR}/active-incident.state"
local ACTIVE_INCIDENT_AVAILABLE=false
local ACTIVE_INCIDENT_ID=""
local ACTIVE_INCIDENT_STARTED_AT=""
local ACTIVE_INCIDENT_LAST_UNHEALTHY_AT=""
local ACTIVE_INCIDENT_HOSTNAME=""
local -A incident_statuses=()
local -A incident_details=()
local -a incident_check_order=()

# Create the cooldown state directory if it is missing.
# Returns 0 on success or 1 if the directory cannot be created, so callers can
# skip the alert for this cycle instead of producing confusing mktemp errors.
_ensure_alert_dir() {
    [[ -d "${ALERT_LOCK_DIR}" ]] && return 0
    if mkdir -p "${ALERT_LOCK_DIR}" 2>/dev/null; then
        chmod 0750 "${ALERT_LOCK_DIR}" 2>/dev/null || true
        return 0
    fi
    log_warn "_ensure_alert_dir: cannot create '${ALERT_LOCK_DIR}'" \
             "— alert cooldown tracking disabled for this cycle." \
             "Fix: sudo mkdir -p '${ALERT_LOCK_DIR}' && sudo chown $(id -un) '${ALERT_LOCK_DIR}'"
    return 1
}

_acquire_alert_lock() {
    local key="$1"
    local safe_key
    safe_key=$(printf '%s' "$key" | tr -cs '[:alnum:]-' '_')
    # Ensure the directory exists; if it cannot be created, skip the alert.
    _ensure_alert_dir || return 1
    local state_file="${ALERT_LOCK_DIR}/${safe_key}.cooldown"
    local ttl="${2:-${ALERT_COOLDOWN_SECONDS}}"
    local now; now=$(date +%s)
    if [[ -f "$state_file" ]]; then
        local last_sent; last_sent=$(cat "$state_file" 2>/dev/null || printf '0')
        if (( now - last_sent < ttl )); then return 1; fi
    fi
    local tmp_file
    tmp_file=$(mktemp "${ALERT_LOCK_DIR}/.tmp.XXXXXXXXXX") || {
        log_warn "_acquire_alert_lock: mktemp failed in '${ALERT_LOCK_DIR}' — skipping alert for '${key}'"
        return 1
    }
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

_incident_sanitize() {
    local value="${1:-}" max_length="${2:-512}"
    value="$(printf '%s' "$value" | LC_ALL=C sed -E \
        -e 's/[[:cntrl:]]/ /g' \
        -e 's/((password|passwd|token|api[_-]?key|authorization|credential|secret)[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' \
        -e 's/(Bearer)[[:space:]]+[^[:space:]]+/\1 [REDACTED]/Ig')"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    value="${value//$'\t'/ }"
    while [[ "$value" == *"  "* ]]; do value="${value//  / }"; done
    value="${value# }"; value="${value% }"
    printf '%s' "${value:0:max_length}"
}

_incident_set_check() {
    local name="$1" status="$2" detail="$3"
    if [[ -z "${incident_statuses[$name]+set}" ]]; then
        incident_check_order+=("$name")
    fi
    incident_statuses["$name"]="$status"
    incident_details["$name"]="$detail"
}

_incident_load() {
    local path="${1:-$ACTIVE_INCIDENT_FILE}" record key value name status detail
    [[ -r "$path" ]] || return 1
    [[ "$(wc -c < "$path" 2>/dev/null || printf '999999')" -le 16384 ]] || return 1
    ACTIVE_INCIDENT_ID=""
    ACTIVE_INCIDENT_STARTED_AT=""
    ACTIVE_INCIDENT_LAST_UNHEALTHY_AT=""
    ACTIVE_INCIDENT_HOSTNAME=""
    incident_statuses=()
    incident_details=()
    incident_check_order=()
    while IFS=$'\t' read -r record key value detail; do
        case "$record:$key" in
            meta:incident_id) ACTIVE_INCIDENT_ID="$(_incident_sanitize "$value" 80)" ;;
            meta:started_at) ACTIVE_INCIDENT_STARTED_AT="$(_incident_sanitize "$value" 64)" ;;
            meta:last_unhealthy_at) ACTIVE_INCIDENT_LAST_UNHEALTHY_AT="$(_incident_sanitize "$value" 64)" ;;
            meta:hostname) ACTIVE_INCIDENT_HOSTNAME="$(_incident_sanitize "$value" 255)" ;;
            check:*)
                name="$(_incident_sanitize "$key" 128)"
                status="$(_incident_sanitize "$value" 8)"
                detail="$(_incident_sanitize "$detail" 512)"
                [[ -n "$name" && ( "$status" == "warn" || "$status" == "fail" ) ]] || return 1
                _incident_set_check "$name" "$status" "$detail"
                ;;
        esac
    done < "$path"
    [[ -n "$ACTIVE_INCIDENT_ID" && -n "$ACTIVE_INCIDENT_STARTED_AT" ]] || return 1
    ACTIVE_INCIDENT_AVAILABLE=true
}

_incident_write() {
    if ! _ensure_alert_dir; then
        log_warn "Health incident context unavailable: alert-state directory is not writable; continuing without incident correlation."
        return 1
    fi
    local tmp_file old_umask line name bytes=0 max_bytes=16384
    old_umask="$(umask)"
    umask 077
    tmp_file="$(mktemp "${ALERT_LOCK_DIR}/.active-incident.XXXXXXXX")" || {
        umask "$old_umask"
        log_warn "Health incident context unavailable: cannot create state in '${ALERT_LOCK_DIR}'; continuing without incident correlation."
        return 1
    }
    umask "$old_umask"
    chmod 0600 "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    {
        printf 'meta\tincident_id\t%s\n' "$ACTIVE_INCIDENT_ID"
        printf 'meta\tstarted_at\t%s\n' "$ACTIVE_INCIDENT_STARTED_AT"
        printf 'meta\tlast_unhealthy_at\t%s\n' "$ACTIVE_INCIDENT_LAST_UNHEALTHY_AT"
        printf 'meta\thostname\t%s\n' "$ACTIVE_INCIDENT_HOSTNAME"
    } > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    bytes="$(wc -c < "$tmp_file")"
    for name in "${incident_check_order[@]}"; do
        printf -v line 'check\t%s\t%s\t%s\n' \
            "$name" "${incident_statuses[$name]}" "${incident_details[$name]}"
        if (( bytes + ${#line} > max_bytes )); then
            log_warn "Health incident context reached ${max_bytes} bytes; additional check details were omitted."
            break
        fi
        printf '%s' "$line" >> "$tmp_file" || { rm -f "$tmp_file"; return 1; }
        (( bytes += ${#line} )) || true
    done
    mv -f "$tmp_file" "$ACTIVE_INCIDENT_FILE" || { rm -f "$tmp_file"; return 1; }
    chmod 0600 "$ACTIVE_INCIDENT_FILE" 2>/dev/null || true
    ACTIVE_INCIDENT_AVAILABLE=true
}

_incident_update_unhealthy() {
    (( failed > 0 || warnings > 0 )) || return 0
    local now name original_name status detail
    now="$(date -Iseconds)"
    if [[ -e "$ACTIVE_INCIDENT_FILE" ]]; then
        if ! _incident_load "$ACTIVE_INCIDENT_FILE"; then
            log_warn "Health incident context is unreadable or invalid; preserving it and continuing without incident correlation."
            ACTIVE_INCIDENT_AVAILABLE=false
            return 1
        fi
    else
        ACTIVE_INCIDENT_ID="$(_incident_sanitize "vw-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 6 2>/dev/null || printf '%06d' "$RANDOM")" 80)"
        ACTIVE_INCIDENT_STARTED_AT="$now"
        ACTIVE_INCIDENT_HOSTNAME="$(_incident_sanitize "$(hostname -f 2>/dev/null || hostname)" 255)"
        incident_statuses=()
        incident_details=()
        incident_check_order=()
    fi
    ACTIVE_INCIDENT_LAST_UNHEALTHY_AT="$now"
    for original_name in "${check_order[@]}"; do
        status="${check_results[$original_name]:-}"
        [[ "$status" == "warn" || "$status" == "fail" ]] || continue
        name="$(_incident_sanitize "$original_name" 128)"
        detail="$(_incident_sanitize "${check_messages[$original_name]:-}" 512)"
        _incident_set_check "$name" "$status" "$detail"
    done
    if ! _incident_write; then
        ACTIVE_INCIDENT_AVAILABLE=false
        return 1
    fi
}

_incident_format_duration() {
    local seconds="${1:-0}" days hours minutes
    [[ "$seconds" =~ ^[0-9]+$ ]] || { printf 'unknown'; return; }
    days=$(( seconds / 86400 ))
    hours=$(( (seconds % 86400) / 3600 ))
    minutes=$(( (seconds % 3600) / 60 ))
    printf '%sd %sh %sm (%ss)' "$days" "$hours" "$minutes" "$seconds"
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
local JSON_OUTPUT=false

_health_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --comprehensive)     COMPREHENSIVE=true;  shift ;;
            --fix|-f)            FIX_MODE=true;       shift ;;
            --report|-r)         REPORT_MODE=true;    shift ;;
            --quiet|-q)          QUIET=true;          shift ;;
            --json)              JSON_OUTPUT=true;    QUIET=true; shift ;;
            --help|-h|help)      _health_show_help;   exit 0 ;;
            *)                   log_error "Unknown option for 'health': $1"; _health_show_help; exit 1 ;;
        esac
    done
}

_health_show_help() {
    cat <<'EOF'
VaultWarden-OCI Health Check (subcommand)

USAGE:
    ./maintenance.sh health [OPTIONS]
    utilities/maintenance-health.sh [OPTIONS]

Read-only path: ./maintenance.sh health
Repair path:    sudo ./maintenance.sh health --fix

DESCRIPTION:
    Runs health checks with narrow duplicate-run coordination. --fix is a
    root-operated repair mode and uses the shared operation guard.

OPTIONS:
    --comprehensive     Run all checks including extended diagnostics
    --fix, -f           Attempt automatic recovery for failed checks
    --report, -r        Save health report to file
    --quiet, -q         Suppress non-critical output
    --json              Emit machine-readable JSON summary
    --help, -h          Show this help
    --version, -V       Print the VaultWarden-OCI version and exit

CHECKS PERFORMED:
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

EXIT CODES:
    0 — All checks passed
    1 — One or more warnings
    2 — One or more failures
    3 — Critical failure (cannot run checks)
    4 — Operation guard infrastructure failure in --fix mode
    75 — Clean skip because another health or repair operation is active

EXAMPLES:
    ./maintenance.sh health
    ./maintenance.sh health --comprehensive
    ./maintenance.sh health --json
    sudo ./maintenance.sh health --fix
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
            unhealthy)              _fail "container:${container}" "$container is unhealthy (run: docker logs $container --tail=50)"; all_healthy=false ;;
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
            200) _pass "vaultwarden:api" "VaultWarden API endpoint responding (HTTP $comp_code)" ;;
            *)   _warn "vaultwarden:api" "VaultWarden API returned HTTP $comp_code" ;;
        esac
    fi
}

_check_caddy_storage_permissions() {
    log_info "Checking Caddy storage permissions..."
    local state_dir caddy_uid caddy_gid
    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    caddy_uid="${CADDY_UID:-2000}"
    caddy_gid="${CADDY_GID:-2000}"

    local issues=()

    _check_caddy_dir_contract() {
        local path="$1" label="$2"
        if [[ ! -d "$path" ]]; then
            issues+=("${label} missing: ${path}")
            return 0
        fi
        local uid gid mode
        uid="$(stat -c '%u' "$path" 2>/dev/null || echo unknown)"
        gid="$(stat -c '%g' "$path" 2>/dev/null || echo unknown)"
        mode="$(stat -c '%a' "$path" 2>/dev/null || echo unknown)"
        if [[ "$uid" != "$caddy_uid" || "$gid" != "$caddy_gid" || "$mode" != "750" ]]; then
            issues+=("${label} drift: ${path} is ${uid}:${gid} mode ${mode}; expected ${caddy_uid}:${caddy_gid} mode 750")
        fi
    }

    _check_caddy_file_contract() {
        local path="$1" label="$2"
        if [[ ! -f "$path" ]]; then
            issues+=("${label} missing: ${path}")
            return 0
        fi
        local uid gid mode
        uid="$(stat -c '%u' "$path" 2>/dev/null || echo unknown)"
        gid="$(stat -c '%g' "$path" 2>/dev/null || echo unknown)"
        mode="$(stat -c '%a' "$path" 2>/dev/null || echo unknown)"
        if [[ "$uid" != "$caddy_uid" || "$gid" != "$caddy_gid" || "$mode" != "640" ]]; then
            issues+=("${label} drift: ${path} is ${uid}:${gid} mode ${mode}; expected ${caddy_uid}:${caddy_gid} mode 640")
        fi
    }

    _check_caddy_dir_contract "${state_dir}/caddy/data" "Caddy /data mount root"
    _check_caddy_dir_contract "${state_dir}/caddy/data/caddy" "Caddy /data/caddy storage"
    _check_caddy_dir_contract "${state_dir}/caddy/config" "Caddy /config mount root"
    _check_caddy_dir_contract "${state_dir}/caddy/config/caddy" "Caddy /config/caddy storage"
    _check_caddy_dir_contract "${state_dir}/logs/caddy" "Caddy /var/log/caddy mount root"
    _check_caddy_file_contract "${state_dir}/logs/caddy/access.log" "Caddy access log"
    _check_caddy_file_contract "${state_dir}/logs/caddy/security.log" "Caddy security log"

    unset -f _check_caddy_dir_contract _check_caddy_file_contract

    if [[ ${#issues[@]} -eq 0 ]]; then
        _pass "permissions:caddy-storage" "Caddy storage/log permissions are correct"
    else
        local i=0
        for issue in "${issues[@]}"; do
            _warn "permissions:caddy-storage:${i}" "${issue} — run: sudo utilities/repair-permissions.sh"
            (( i++ )) || true
        done
    fi
}

_check_crowdsec() {
    log_info "Checking CrowdSec..."
    if systemctl is-active crowdsec >/dev/null 2>&1; then
        _pass "crowdsec:service" "CrowdSec service is active"
    else
        _fail "crowdsec:service" "CrowdSec service is not running (start: sudo systemctl start crowdsec)"
        return
    fi
    if sudo -n cscli metrics >/dev/null 2>&1; then
        _pass "crowdsec:lapi" "CrowdSec LAPI is responding"
    else
        log_warn "CrowdSec LAPI metrics unavailable without non-interactive root access; skipping optional cscli check."
    fi

    # Bouncer check priority: prefer crowdsec-firewall-bouncer, then
    # crowdsec-cloudflare-worker-bouncer. Warn when a bouncer unit is installed but not
    # running, and pass with an install note when no bouncer is installed.
    local _bouncer_active=false
    local _bouncer_name=""

    if systemctl is-active --quiet crowdsec-firewall-bouncer 2>/dev/null; then
        _bouncer_active=true
        _bouncer_name="crowdsec-firewall-bouncer"
    elif systemctl is-active --quiet crowdsec-cloudflare-worker-bouncer 2>/dev/null; then
        _bouncer_active=true
        _bouncer_name="crowdsec-cloudflare-worker-bouncer"
    fi

    if [[ "$_bouncer_active" == "true" ]]; then
        _pass "crowdsec:bouncer" "CrowdSec ${_bouncer_name} is active"
    elif systemctl list-unit-files 2>/dev/null \
            | grep -qE 'crowdsec-(firewall|cloudflare)-bouncer\.service'; then
        # A bouncer unit is installed but not running, so flag it.
        _warn "crowdsec:bouncer" \
            "CrowdSec bouncer is installed but not active — check: sudo systemctl status crowdsec-firewall-bouncer"
    else
        # No bouncer is installed, which is optional, so keep this as pass.
        _pass "crowdsec:bouncer" \
            "No CrowdSec bouncer installed (optional — install crowdsec-firewall-bouncer or crowdsec-cloudflare-worker-bouncer)"
    fi

    if $COMPREHENSIVE; then
        local decision_count
        if decision_count=$(sudo -n cscli decisions list -o raw 2>/dev/null | tail -n +2 | wc -l); then
            _pass "crowdsec:decisions" "CrowdSec has ${decision_count} active ban decision(s)"
        else
            log_warn "CrowdSec decisions unavailable without non-interactive root access; skipping optional cscli check."
        fi
    fi
}

_crowdsec_health_sanitize_validation_log() {
    local log_file="$1" detail
    [[ -r "$log_file" ]] || return 0

    detail="$(
        LC_ALL=C sed -E \
            -e $'s/\033\\[[0-?]*[ -\\/]*[@-~]//g' \
            -e $'s/\033\\][^\a]*(\a|\033\\\\)//g' \
            -e $'s/\033[@-_]//g' \
            "$log_file" 2>/dev/null \
            | tr '\r\t' '  ' \
            | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' \
            | awk '
                {
                    gsub(/[[:space:]]+/, " ")
                    sub(/^ /, "")
                    sub(/ $/, "")
                    if ($0 == "") next
                    fallback = $0
                    if ($0 ~ /(^|[[:space:]])(FATAL|ERROR|WARN)([[:space:]]|:)/) {
                        print
                        found = 1
                        exit
                    }
                }
                END {
                    if (!found && fallback != "") print fallback
                }
            '
    )"
    [[ -n "$detail" ]] || return 0

    detail="$(
        printf '%s\n' "$detail" \
            | LC_ALL=C sed -E \
                -e 's/((^|[[:space:]])(password|passwd|token|api[_-]?key|authorization|credential|secret|smtp_username)[[:space:]]*[:=][[:space:]]*).*/\1[REDACTED]/I' \
                -e 's/((^|[[:space:]])[A-Z][A-Z0-9_]{1,}[[:space:]]*=[[:space:]]*).*/\1[REDACTED]/' \
            | awk '{$1=$1; print}'
    )"
    printf '%s' "${detail:0:240}"
}

_crowdsec_health_validate_config() (
    local validation_log="" validation_rc=0
    local fd="${HEALTH_LOCK_FD:-}"

    validation_log="$(mktemp -t vw-crowdsec-health.XXXXXXXXXX 2>/dev/null)" || return 125
    _crowdsec_health_validation_cleanup() {
        rm -f -- "$validation_log"
    }
    trap _crowdsec_health_validation_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [[ "$fd" =~ ^[0-9]+$ ]] && (( fd > 2 )); then
        { eval "exec ${fd}>&-"; } 2>/dev/null || true
    fi
    unset HEALTH_LOCK_FD

    if declare -f operation_run_without_guard_fds >/dev/null 2>&1; then
        if operation_run_without_guard_fds crowdsec -t >"$validation_log" 2>&1; then
            return 0
        else
            validation_rc=$?
        fi
    elif crowdsec -t >"$validation_log" 2>&1; then
        return 0
    else
        validation_rc=$?
    fi

    _crowdsec_health_sanitize_validation_log "$validation_log"
    return "$validation_rc"
)

_check_crowdsec_email_notifications() {
    local enabled="${CROWDSEC_EMAIL_NOTIFICATIONS:-false}"
    local etc_dir="${VW_CROWDSEC_ETC_DIR:-/etc/crowdsec}"
    local plugin_file="${etc_dir}/notifications/vaultwarden-email.yaml"
    local profiles_file="${etc_dir}/profiles.yaml.local"
    local plugin_marker="# Managed by VaultWarden-OCI: CrowdSec email notification"
    local profile_begin="# BEGIN VaultWarden-OCI CrowdSec email notifications"
    enabled="${enabled,,}"
    if [[ "$enabled" != "true" ]]; then
        _pass "crowdsec:email-notifications" "CrowdSec security-event email notifications are disabled"
        return 0
    fi
    if [[ ! -f "$plugin_file" ]]; then
        _warn "crowdsec:email-notifications:plugin" \
            "CrowdSec email notifications are enabled but the managed plugin file is missing: ${plugin_file}"
        return 0
    fi
    if ! grep -Fxq "$plugin_marker" "$plugin_file"; then
        _warn "crowdsec:email-notifications:plugin" \
            "CrowdSec email notifications are enabled but ${plugin_file} is not the managed VaultWarden-OCI plugin"
        return 0
    fi
    if [[ ! -f "$profiles_file" ]] || ! grep -Fxq "$profile_begin" "$profiles_file"; then
        _warn "crowdsec:email-notifications:profile" \
            "CrowdSec email notifications are enabled but the managed profiles.yaml.local block is missing"
        return 0
    fi
    _pass "crowdsec:email-notifications:configured" \
        "CrowdSec email notifications are enabled and configured through 127.0.0.1:587"
    if ! command -v crowdsec >/dev/null 2>&1; then
        _warn "crowdsec:email-notifications:validation" \
            "CrowdSec email notification configuration is present but the crowdsec command is unavailable"
        return 0
    fi

    local validation_detail="" validation_rc=0
    if validation_detail="$(_crowdsec_health_validate_config)"; then
        _pass "crowdsec:email-notifications:validation" \
            "CrowdSec email notification configuration is statically valid"
        return 0
    else
        validation_rc=$?
    fi

    if (( validation_rc == 125 )); then
        _warn "crowdsec:email-notifications:validation" \
            "CrowdSec email notification configuration is present but health validation could not create a temporary log"
        return 0
    fi

    _warn "crowdsec:email-notifications:validation" \
        "CrowdSec email notification configuration is present but static validation failed${validation_detail:+ — ${validation_detail}} (run: sudo crowdsec -t)"
}

_check_disk() {
    log_info "Checking disk space..."
    local state_dir; state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    if [[ -z "$state_dir" ]]; then
        state_dir="/var/lib/vaultwarden"
    fi
    local state_mount root_mount
    state_mount=$(df --output=target "$state_dir" 2>/dev/null | tail -1 || echo "")
    root_mount=$(df --output=target / 2>/dev/null | tail -1 || echo "/")
    local usage_pct
    usage_pct=$(df "$state_dir" 2>/dev/null \
        | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0")
    if (( usage_pct >= DISK_CRIT_THRESHOLD )); then
        _fail "disk:state" "Disk usage critical: ${usage_pct}% on ${state_dir} (mount: ${state_mount}) — threshold: ${DISK_CRIT_THRESHOLD}%"
    elif (( usage_pct >= DISK_WARN_THRESHOLD )); then
        _warn "disk:state" "Disk usage warning: ${usage_pct}% on ${state_dir} (mount: ${state_mount}) — threshold: ${DISK_WARN_THRESHOLD}%"
    else
        _pass "disk:state" "Disk OK: ${usage_pct}% on ${state_dir} (mount: ${state_mount})"
    fi
    if [[ -n "$state_mount" && "$state_mount" != "$root_mount" ]]; then
        local root_usage
        root_usage=$(df / 2>/dev/null \
            | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0")
        if (( root_usage >= DISK_CRIT_THRESHOLD )); then
            _fail "disk:root" "Root partition critical: ${root_usage}% on / — threshold: ${DISK_CRIT_THRESHOLD}%"
        elif (( root_usage >= DISK_WARN_THRESHOLD )); then
            _warn "disk:root" "Root partition warning: ${root_usage}% on / — threshold: ${DISK_WARN_THRESHOLD}%"
        else
            _pass "disk:root" "Root partition OK: ${root_usage}% on /"
        fi
    fi
}

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
        *)                       _warn "network:cloudflare" "Cloudflare API not reachable (HTTP $cf_code)" ;;
    esac
}

_check_smtp() {
    log_info "Checking Postfix SMTP sidecar on port 587..."
    if [[ -n "${SMTP_PASSWORD:-}" && -z "${VW_SMTP_HOST_PORT:-}" ]]; then
        _pass "smtp:sidecar" "Direct external SMTP relay configured — sidecar check skipped"
        return
    fi
    local sidecar_addr="${VW_SMTP_HOST_PORT:-127.0.0.1:587}"
    local sidecar_host="${sidecar_addr%:*}"
    local sidecar_port="${sidecar_addr##*:}"
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
        _fail "smtp:sidecar" "Postfix sidecar not listening on ${sidecar_addr} — email delivery will fail silently"
        return
    fi
    local banner=""
    if command -v nc >/dev/null 2>&1; then
        banner=$(printf 'QUIT\r\n' | nc -w 3 "$sidecar_host" "$sidecar_port" 2>/dev/null \
            | head -1 | tr -d '\r' || true)
    fi
    if [[ "$banner" == "220"* ]]; then
        _pass "smtp:sidecar" "Postfix sidecar healthy on ${sidecar_addr} (banner: ${banner:0:60})"
    elif [[ -n "$banner" ]]; then
        _warn "smtp:sidecar" "Postfix sidecar port open but unexpected banner: '${banner:0:60}'"
    else
        _pass "smtp:sidecar" "Postfix sidecar port ${sidecar_addr} open (banner unavailable)"
    fi
}

_check_dns() {
    local domain; domain="$(_get_domain)"
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

_check_backups() {
    log_info "Checking backup status..."
    local backup_dir; backup_dir="$(_resolve_backup_base_dir)"
    local now_epoch; now_epoch=$(date +%s)
    if [[ ! -d "$backup_dir" ]]; then
        local real_user
        real_user="$(get_real_user)"
        local created_ok=true
        for _subdir in db full emergency; do
            if ! mkdir -p "$backup_dir/$_subdir" 2>/dev/null; then
                created_ok=false
                break
            fi
            chmod 750 "$backup_dir/$_subdir" 2>/dev/null || true
            # Only chown when running as root to avoid install -o style
            # failures when the username does not resolve in this namespace.
            if (( EUID == 0 )) && [[ -n "$real_user" ]] && id "$real_user" &>/dev/null; then
            chown "$real_user" "$backup_dir/$_subdir" 2>/dev/null || true
            fi
        done
        if [[ "$created_ok" == "true" ]]; then
            _pass "backup:dir" "Backup directory created: $backup_dir (owner: $real_user, mode: 750)"
        else
            _warn "backup:dir" "Backup directory not found and could not be created: $backup_dir — check permissions"
            return
        fi
    fi
    
    local -A max_age_hours
    max_age_hours=([db]=26 [full]=168)
    local any_found=false
    for btype in db full; do
        local type_dir="$backup_dir/$btype"
        if [[ ! -d "$type_dir" ]]; then
            _warn "backup:${btype}" "No $btype backup directory found: $type_dir"
            continue
        fi
        local latest_file
        latest_file=$(find "$type_dir" -maxdepth 1 -name '*.age' -type f \
            -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)
        if [[ -z "$latest_file" ]]; then
            _warn "backup:${btype}" "No $btype backups found in $type_dir"
            continue
        fi
        any_found=true
        local mtime age_h
        mtime=$(stat -c %Y "$latest_file" 2>/dev/null || stat -f %m "$latest_file" 2>/dev/null || echo 0)
        age_h=$(( (now_epoch - mtime) / 3600 ))
        if (( age_h > max_age_hours[$btype] )); then
            _warn "backup:${btype}" "$btype backup is ${age_h}h old (threshold: ${max_age_hours[$btype]}h): $(basename "$latest_file") (path: $type_dir)"
        else
            _pass "backup:${btype}" "$btype backup is ${age_h}h old: $(basename "$latest_file") (path: $type_dir)"
        fi
    done
    [[ "$any_found" == "false" ]] && _warn "backup:age" "No backup archives found in $backup_dir"
}

_check_config() {
    log_info "Checking configuration..."
    local config_issues=()
    if [[ ! -f "$ENV_FILE" ]]; then
        config_issues+=("Missing env file: $ENV_FILE")
    elif [[ ! -r "$ENV_FILE" ]]; then
        config_issues+=("$ENV_FILE is not readable by $(id -un) — run health through sudo make health and verify root-owned runtime env permissions")
    else
        local env_mode
        env_mode=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo "unknown")
        if [[ "$env_mode" != "unknown" ]]; then
            local env_mode_int
            env_mode_int=$((8#$env_mode))
            if (( (env_mode_int & 0177) != 0 )); then
                config_issues+=("${ENV_FILE} permissions are ${env_mode}; must be 600 so root-mode health checks can read config safely")
            fi
        fi
        local required_vars=("DOMAIN" "ADMIN_EMAIL")
        for var in "${required_vars[@]}"; do
            [[ -n "${!var:-}" ]] || config_issues+=("${var} is not set — verify '${var}=' is present in ${ENV_FILE}")
        done
    fi
    # cloudflare_zone_id lives in encrypted secrets.yaml — not in .env.
    # Check it is present and decryptable rather than testing an env var.
    local _cf_zone_id
    if _cf_zone_id=$(decrypt_secret "cloudflare_zone_id" 2>/dev/null) \
        && [[ -n "$_cf_zone_id" ]] \
        && [[ "$_cf_zone_id" != CHANGE_ME* ]] \
        && [[ "$_cf_zone_id" != PLACEHOLDER* ]]; then
        _pass "config:cloudflare_zone_id" \
            "cloudflare_zone_id is configured in secrets.yaml"
    else
        _warn "config:cloudflare_zone_id" \
            "cloudflare_zone_id not set or is a placeholder — run: ./edit-secrets.sh rotate cloudflare_zone_id"
    fi
    unset _cf_zone_id
    local secrets_dir="${DOCKER_SECRETS_DIR:-/run/vaultwarden-oci/secrets}"
    if [[ -d "$secrets_dir" ]]; then
        local required_secrets=("admin_token" "caddy_cloudflare_dns_token")
        for secret in "${required_secrets[@]}"; do
            [[ -f "${secrets_dir}/${secret}" ]] || config_issues+=("Missing secret: $secret")
        done
    fi
    # Resolve the age key using backup-run compatible precedence and relative-path handling.
    local age_key_file=""
    age_key_file="$(_resolve_age_key || true)"

    # Warn if SOPS_AGE_KEY_FILE is set but points nowhere so the operator can fix .env.
    if [[ -n "${SOPS_AGE_KEY_FILE:-}" ]]; then
        local _env_age_candidate="${SOPS_AGE_KEY_FILE}"
        [[ "$_env_age_candidate" != /* ]] && _env_age_candidate="${PROJECT_ROOT}/${_env_age_candidate}"
        if [[ ! -f "$_env_age_candidate" && -n "$age_key_file" ]]; then
            _warn "config:age-key-path" \
                "SOPS_AGE_KEY_FILE=${SOPS_AGE_KEY_FILE} not found — resolved via fallback to: ${age_key_file}. Remove or correct SOPS_AGE_KEY_FILE in .env"
        fi
    fi

    if [[ -z "$age_key_file" ]]; then
        config_issues+=("Age key not found in any expected location — run: ./utilities/setup-secrets.sh configure")
    fi
    if [[ ! -f "$age_key_file" ]]; then
        config_issues+=("Age key not found: ${age_key_file} — backups cannot encrypt. Run: ./utilities/setup-secrets.sh configure")
    elif [[ ! -r "$age_key_file" ]]; then
        config_issues+=("Age key not readable: ${age_key_file} — check file permissions")
    else
        if ! grep -q '^AGE-SECRET-KEY-' "$age_key_file" 2>/dev/null; then
            config_issues+=("Age key malformed or empty: ${age_key_file} — missing AGE-SECRET-KEY line")
        else
            local age_key_perms
            age_key_perms=$(stat -c '%a' "$age_key_file" 2>/dev/null || echo "unknown")
            if [[ "$age_key_perms" != "600" && "$age_key_perms" != "400" ]]; then
                _warn "config:age-key" "Age key has insecure permissions (${age_key_perms}): ${age_key_file} — run: chmod 600 '${age_key_file}'"
            else
                _pass "config:age-key" "Age key present and valid (${age_key_file}, perms: ${age_key_perms})"
            fi
        fi
    fi
    local root_owned_issues=()
    local expected_owner expected_group
    expected_owner=$(stat -c '%U' "$PROJECT_ROOT" 2>/dev/null || id -un)
    expected_group=$(stat -c '%G' "$PROJECT_ROOT" 2>/dev/null || id -gn)
    for f in ".env" "Makefile" "startup.sh" "backup.sh" "utilities/secrets-edit.sh"; do
        local fpath="${PROJECT_ROOT}/${f}"
        if [[ -e "$fpath" ]]; then
            local owner group
            owner=$(stat -c '%U' "$fpath" 2>/dev/null || echo "unknown")
            group=$(stat -c '%G' "$fpath" 2>/dev/null || echo "unknown")
            if [[ "$owner" == "root" && "$expected_owner" != "root" ]]; then
                root_owned_issues+=("${f} is owned by root:${group} (expected non-root, e.g. ${expected_owner}:${expected_group}) — run: sudo make fix-permissions")
            fi
        fi
    done
    if [[ ${#root_owned_issues[@]} -gt 0 ]]; then
        local _pi=0
        for issue in "${root_owned_issues[@]}"; do
            _warn "permissions:project-files:${_pi}" "$issue"
            (( _pi++ )) || true
        done
    elif [[ -f "${PROJECT_ROOT}/.env" || -f "${PROJECT_ROOT}/Makefile" ]]; then
        _pass "permissions:project-files" "Project file ownership is correct"
    fi
    if [[ ${#config_issues[@]} -eq 0 ]]; then
        _pass "config:validation" "Configuration validation passed"
    else
        local _ci=0
        for issue in "${config_issues[@]}"; do
            _fail "config:validation:${_ci}" "$issue"
            (( _ci++ )) || true
        done
    fi
}

_check_notify_failures() {
    local state_dir; state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    local -a markers=()
    mapfile -t markers < <(find "$state_dir" -maxdepth 1 -name 'NOTIFY_FAILED_*' 2>/dev/null | sort)
    if [[ ${#markers[@]} -eq 0 ]]; then
        _pass "notify:dead-letter" "No lost failure notifications"
        return
    fi
    for marker in "${markers[@]}"; do
        local unit="${marker##*/NOTIFY_FAILED_}"
        _fail "notify:dead-letter:${unit}" \
            "SMTP was down when ${unit} failed — notification lost. Investigate and remove: ${marker}"
    done
}

_check_container_resources() {
    log_info "Checking container resource usage..."
    local stats
    stats=$(docker stats --no-stream --format \
        'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' \
        2>/dev/null) || {
        _warn "resources:stats" "Cannot retrieve container resource stats"
        return
    }
    log_debug "Container resource stats:\n${stats}"
    _pass "resources:stats" "Container resource stats retrieved"
}

_send_notification() {
    local subject="$1" body="$2"
    if [[ "${_email_available:-true}" == "false" ]]; then
        log_warn "Email notifications not available"
        return 1
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
        if [[ "$ACTIVE_INCIDENT_AVAILABLE" == "true" && -n "$ACTIVE_INCIDENT_ID" ]]; then
            message="$(_incident_sanitize "$message" 512)"
            subject="VaultWarden Health [${status^^}] [Incident ${ACTIVE_INCIDENT_ID}]: ${name} on $(hostname)"
            printf -v body \
                'Health check alert at %s\n\nIncident: %s\nIncident started: %s\nCheck: %s\nStatus: %s\nDetail: %s\n\nThis alert will not repeat for %ss (%s min).\nFor the full live status, run: ./maintenance.sh health\nTo also write a report file, run: ./maintenance.sh health --report' \
                "$alert_date" "$ACTIVE_INCIDENT_ID" "$ACTIVE_INCIDENT_STARTED_AT" \
                "$name" "${status^^}" "$message" \
                "$ALERT_COOLDOWN_SECONDS" "$(( ALERT_COOLDOWN_SECONDS / 60 ))"
        else
            subject="VaultWarden Health [${status^^}]: ${name} on $(hostname)"
            printf -v body \
                'Health check alert at %s\n\nCheck: %s\nStatus: %s\nDetail: %s\n\nThis alert will not repeat for %ss (%s min).\nFor the full live status, run: ./maintenance.sh health\nTo also write a report file, run: ./maintenance.sh health --report' \
                "$alert_date" "$name" "${status^^}" "$message" \
                "$ALERT_COOLDOWN_SECONDS" "$(( ALERT_COOLDOWN_SECONDS / 60 ))"
        fi
        if ! _send_notification "$subject" "$body"; then
            log_warn "_notify_failures: delivery failed for '${name}' — releasing cooldown for retry next cycle"
            _release_alert_lock "$name"
            continue
        fi
        alerted_any=true
        log_info "Alert sent for '${name}' (${status})"
    done
    if [[ "$alerted_any" == "true" ]]; then
        log_debug "_notify_failures: at least one alert was sent this cycle"
    fi
    if [[ $failed -gt 0 || $warnings -gt 0 ]]; then
        _release_recovery_lock
    fi
}

_notify_recovery() {
    [[ $failed -eq 0 && $warnings -eq 0 ]] || return 0

    if [[ ! -e "$ACTIVE_INCIDENT_FILE" ]]; then
        log_debug "No active health incident — recovery notification not applicable"
        return 0
    fi
    if ! _incident_load "$ACTIVE_INCIDENT_FILE"; then
        log_warn "Active health incident state is unreadable or invalid; preserving '${ACTIVE_INCIDENT_FILE}' and suppressing recovery notification."
        return 0
    fi
    if ! _acquire_alert_lock "recovery" "${ALERT_RECOVERY_TTL}"; then
        log_info "Recovery notification already sent within TTL — suppressing"
        return 0
    fi

    local recovery_date recovery_time subject body recovered_file
    local started_epoch recovery_epoch duration prior_lines="" name
    recovery_date="$(date)"
    recovery_time="$(date -Iseconds)"
    started_epoch="$(date -d "$ACTIVE_INCIDENT_STARTED_AT" +%s 2>/dev/null || printf '')"
    recovery_epoch="$(date -d "$recovery_time" +%s 2>/dev/null || date +%s)"
    if [[ "$started_epoch" =~ ^[0-9]+$ && "$recovery_epoch" =~ ^[0-9]+$ \
        && "$recovery_epoch" -ge "$started_epoch" ]]; then
        duration="$(_incident_format_duration "$(( recovery_epoch - started_epoch ))")"
    else
        duration="unknown"
    fi
    for name in "${incident_check_order[@]}"; do
        printf -v prior_lines '%s- %s [%s]: %s\n' \
            "$prior_lines" "$name" "${incident_statuses[$name]^^}" "${incident_details[$name]}"
    done
    subject="VaultWarden Health RECOVERED [Incident ${ACTIVE_INCIDENT_ID}] on $(hostname)"
    printf -v body \
        'All health checks passed at %s\n\nIncident: %s\nIncident started: %s\nLast unhealthy observation: %s\nRecovered: %s\nDuration: %s\nHost: %s\n\nPreviously unhealthy checks:\n%s\nCurrent totals:\nPassed : %s\nWarnings: %s\nFailed : %s\n\nNo further alerts will fire until the next failure.' \
        "$recovery_date" "$ACTIVE_INCIDENT_ID" "$ACTIVE_INCIDENT_STARTED_AT" \
        "$ACTIVE_INCIDENT_LAST_UNHEALTHY_AT" "$recovery_time" "$duration" \
        "$ACTIVE_INCIDENT_HOSTNAME" "$prior_lines" "$passed" "$warnings" "$failed"
    if _send_notification "$subject" "$body"; then
        log_info "Recovery notification sent"
        recovered_file="${ACTIVE_INCIDENT_FILE}.recovered"
        if mv -f -- "$ACTIVE_INCIDENT_FILE" "$recovered_file"; then
            chmod 0600 "$recovered_file" 2>/dev/null || true
            if ! rm -f -- "$recovered_file"; then
                log_warn "Recovery email was delivered and the active incident was closed, but recovered incident cleanup failed; stale evidence remains at '${recovered_file}'. Review and remove this file manually."
            fi
        else
            log_warn "Recovery email was delivered, but the active incident could not be archived from '${ACTIVE_INCIDENT_FILE}' to '${recovered_file}'. Stale active incident state may require operator action; the recovery cooldown remains active."
        fi
        return 0
    fi
    _release_recovery_lock
    log_warn "Recovery notification delivery failed; cooldown released for retry next health cycle"
    return 1
}

_generate_report() {
    local timestamp; timestamp=$(date '+%Y%m%d_%H%M%S')
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


_health_json_escape() {
    local str="$1"
    str=${str//\\/\\\\}; str=${str//\"/\\\"}; str=${str//$'\n'/\\n}; str=${str//$'\r'/}
    printf '%s' "$str"
}

_print_results_json() {
    local overall="pass"
    (( warnings > 0 )) && overall="warn"
    (( failed > 0 )) && overall="fail"
    printf '{"overall":"%s","total":%d,"passed":%d,"warnings":%d,"failed":%d,"checks":[' \
        "$overall" "$total" "$passed" "$warnings" "$failed"
    local first=true name status message
    for name in "${check_order[@]}"; do
        status="${check_results[$name]:-unknown}"
        message="${check_messages[$name]:-}"
        [[ "$first" == "true" ]] && first=false || printf ','
        printf '{"name":"%s","status":"%s","message":"%s"}' \
            "$(_health_json_escape "$name")" "$(_health_json_escape "$status")" "$(_health_json_escape "$message")"
    done
    printf ']}\n'
}

_print_results() {
    if $QUIET && [[ $failed -eq 0 && $warnings -eq 0 ]]; then return; fi
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

_health_main() {
    set +e   # Bash 5.2 aarch64: nested function set -e propagation bug
    local lock_rc
    _health_parse_args "$@"
    if [[ "$FIX_MODE" == "true" && $EUID -ne 0 ]]; then
        log_error "health --fix requires root because it may restart containers and uses the shared operation guard."
        log_error "Run: sudo ./maintenance.sh health --fix"
        return 3
    fi
    _acquire_run_lock
    lock_rc=$?
    if (( lock_rc != 0 )); then
        return "$lock_rc"
    fi
    trap '_release_run_lock' EXIT HUP INT TERM
    log_info "Starting VaultWarden health check..."
    if $COMPREHENSIVE; then log_info "Mode: comprehensive"; else log_info "Mode: standard"; fi
    _check_containers
    _check_ssl
    _check_vaultwarden_alive
    _check_vaultwarden_server_info
    _check_caddy_storage_permissions
    _check_crowdsec
    _check_crowdsec_email_notifications
    _check_disk
    _check_memory
    _check_network
    _check_smtp
    _check_dns
    _check_backups
    _check_config
    _check_notify_failures
    if $COMPREHENSIVE; then _check_container_resources; fi
    if $FIX_MODE && [[ $failed -gt 0 ]]; then
        log_info "Fix mode enabled — attempting recovery..."
        _fix_unhealthy_containers
    fi
    _incident_update_unhealthy || true
    if $JSON_OUTPUT; then _print_results_json; else _print_results; fi
    if $REPORT_MODE; then _generate_report; fi
    _notify_failures
    _notify_recovery
    if [[ $failed -gt 0 ]]; then exit 2
    elif [[ $warnings -gt 0 ]]; then exit 1
    else exit 0
    fi
}

    _health_main "$@"
}

show_help() {
    cat << 'EOF'
VaultWarden-OCI Health Check

USAGE:
    ./maintenance.sh health [OPTIONS]
    utilities/maintenance-health.sh [OPTIONS]

Root-operated repair path: sudo make health
Direct read-only path: ./maintenance.sh health

OPTIONS:
    --comprehensive     Run all checks including extended diagnostics
    --fix, -f           Attempt automatic recovery for failed checks
    --report, -r        Save health report to file
    --quiet, -q         Suppress non-critical output
    --json              Emit machine-readable JSON summary
    --help, -h          Show this help
    --version, -V       Print the VaultWarden-OCI version and exit

EXIT CODES:
    0 — All checks passed
    1 — One or more warnings
    2 — One or more failures
    3 — Critical failure (cannot run checks)
    4 — Operation guard infrastructure failure in --fix mode
    75 — Clean skip because another health or repair operation is active
EOF
}

[[ $# -gt 0 && ( "$1" == "--help" || "$1" == "-h" || "$1" == "help" ) ]] && { show_help; exit 0; }
[[ $# -gt 0 && ( "$1" == "--version" || "$1" == "-V" ) ]] && { print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0; }

# Strip the leading 'health' token when the dispatcher prepends the subcommand.
[[ "${1:-}" == "health" ]] && shift
if [[ "${VAULTWARDEN_INTERNAL_HEALTH_CHECK:-false}" != "true" ]]; then
    true # root is allowed for direct/internal health checks under the root-operated contract
fi

main() {
    local arg
    for arg in "$@"; do
        if [[ "$arg" == "--json" ]]; then
            _LOG_CURRENT_WEIGHT=3
            break
        fi
    done
    run_health_check "$@"
}

main "$@"
