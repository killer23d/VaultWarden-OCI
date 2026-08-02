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
source "$PROJECT_ROOT/lib/health-alerts.sh"
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
local HEALTH_OPERATION_GUARD_ACQUIRED=false

_health_readonly_lock_target() {
    printf '%s\n' "${VW_HEALTH_LOCK_TARGET:-/run/lock/vaultwarden-health}"
}

_health_stat_mode_uid_gid() {
    local target="$1"
    stat -Lc '%a:%u:%g' -- "$target" 2>/dev/null \
        || stat -f '%Lp:%u:%g' -- "$target" 2>/dev/null
}

_health_path_identity() {
    local target="$1"
    stat -Lc '%d:%i' -- "$target" 2>/dev/null \
        || stat -f '%d:%i' -- "$target" 2>/dev/null
}

_health_lock_fd_path() {
    local fd="$1" owner_pid="$2"
    if [[ -e "/proc/${owner_pid}/fd/${fd}" ]]; then
        printf '/proc/%s/fd/%s\n' "$owner_pid" "$fd"
    else
        printf '/dev/fd/%s\n' "$fd"
    fi
}

_health_lock_directory_is_trusted() {
    local dir="$1" metadata mode uid gid mode_value
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    metadata="$(_health_stat_mode_uid_gid "$dir")" || return 1
    IFS=: read -r mode uid gid <<< "$metadata"
    [[ "$mode" =~ ^[0-7]{3,4}$ && "$uid" == 0 && "$gid" == 0 ]] || return 1
    mode_value=$((8#$mode))

    # Root-group write is acceptable on the supported Ubuntu /run/lock path.
    # Other-write is accepted only for a root-owned sticky directory such as /tmp.
    if (( (mode_value & 0002) == 0 )); then
        return 0
    fi
    (( (mode_value & 01000) != 0 ))
}

_health_lock_ancestry_is_trusted() {
    local current="$1" parent
    [[ "$current" == /* ]] || return 1

    while :; do
        _health_lock_directory_is_trusted "$current" || return 1
        parent="$(dirname "$current")"
        [[ "$parent" == "$current" ]] && break
        current="$parent"
    done
}

_health_lock_target_is_trusted() {
    local target="$1" metadata mode uid gid
    _health_lock_ancestry_is_trusted "$target" || return 1
    metadata="$(_health_stat_mode_uid_gid "$target")" || return 1
    IFS=: read -r mode uid gid <<< "$metadata"
    [[ "$mode" == 755 && "$uid" == 0 && "$gid" == 0 ]]
}

_health_prepare_lock_target() {
    local lock_target="$1" parent metadata mode uid gid
    [[ "$lock_target" == /* ]] || {
        log_error "Health coordination target must be an absolute path: $lock_target"
        return 1
    }
    parent="$(dirname "$lock_target")"
    if ! _health_lock_ancestry_is_trusted "$parent"; then
        log_error "Health coordination parent ancestry is unsafe: $parent"
        return 1
    fi

    if [[ -e "$lock_target" || -L "$lock_target" ]]; then
        [[ -d "$lock_target" && ! -L "$lock_target" ]] || {
            log_error "Health coordination target is not a real directory: $lock_target"
            return 1
        }
    else
        if (( EUID != 0 )); then
            log_error "Health coordination target is not initialized: $lock_target"
            log_error "Initialize it through the root-operated path: sudo make health"
            return 1
        fi
        if ! mkdir -m 0755 -- "$lock_target" 2>/dev/null; then
            [[ -d "$lock_target" && ! -L "$lock_target" ]] || {
                log_error "Cannot create health coordination target: $lock_target"
                return 1
            }
        fi
    fi

    metadata="$(_health_stat_mode_uid_gid "$lock_target")" || {
        log_error "Cannot inspect health coordination target: $lock_target"
        return 1
    }
    IFS=: read -r mode uid gid <<< "$metadata"
    if [[ "$uid" != 0 || "$gid" != 0 ]]; then
        log_error "Health coordination target must be owned by root:root: $lock_target"
        return 1
    fi
    if [[ "$mode" != 755 ]]; then
        if (( EUID != 0 )) || ! chmod 0755 -- "$lock_target" 2>/dev/null; then
            log_error "Health coordination target must have mode 0755: $lock_target"
            return 1
        fi
    fi

    if ! _health_lock_target_is_trusted "$lock_target"; then
        log_error "Health coordination target metadata is unsafe: $lock_target"
        return 1
    fi
}

_health_open_lock_matches_target() {
    local lock_target="$1" fd="$2" fd_path target_identity fd_identity owner_pid="$BASHPID"
    fd_path="$(_health_lock_fd_path "$fd" "$owner_pid")"
    fd_identity="$(_health_path_identity "$fd_path")" || return 1
    target_identity="$(_health_path_identity "$lock_target")" || return 1
    [[ "$fd_identity" == "$target_identity" ]]
}

_health_close_lock_fd() {
    local fd="$1"
    [[ "$fd" =~ ^[0-9]+$ ]] || return 0
    { eval "exec ${fd}>&-"; } 2>/dev/null
}

_release_readonly_health_lock() {
    local release_rc=0
    if [[ -n "${HEALTH_LOCK_FD:-}" ]]; then
        flock -u "$HEALTH_LOCK_FD" 2>/dev/null || release_rc=$?
        _health_close_lock_fd "$HEALTH_LOCK_FD" || release_rc=$?
    fi
    HEALTH_LOCK_FD=""
    return "$release_rc"
}

_acquire_readonly_health_lock() {
    local lock_target fd flock_rc
    lock_target="$(_health_readonly_lock_target)"

    if ! _health_prepare_lock_target "$lock_target"; then
        return 3
    fi
    if ! { exec {fd}<"$lock_target"; } 2>/dev/null; then
        log_error "Cannot open health coordination target: $lock_target"
        return 3
    fi
    if ! _health_open_lock_matches_target "$lock_target" "$fd" \
        || ! _health_lock_target_is_trusted "$lock_target"; then
        _health_close_lock_fd "$fd" || true
        log_error "Health coordination target changed while opening: $lock_target"
        return 3
    fi

    if flock -n -E 75 "$fd" 2>/dev/null; then
        flock_rc=0
    else
        flock_rc=$?
    fi
    case "$flock_rc" in
        0) ;;
        75)
            _health_close_lock_fd "$fd" || true
            log_warn "Another VaultWarden health check is already running; skipping this duplicate run."
            return 75
            ;;
        *)
            _health_close_lock_fd "$fd" || true
            log_error "Health coordination flock failed with status ${flock_rc}: $lock_target"
            return 3
            ;;
    esac

    if ! _health_open_lock_matches_target "$lock_target" "$fd" \
        || ! _health_lock_target_is_trusted "$lock_target"; then
        flock -u "$fd" 2>/dev/null || true
        _health_close_lock_fd "$fd" || true
        log_error "Health coordination target changed after acquisition: $lock_target"
        return 3
    fi
    HEALTH_LOCK_FD="$fd"
}

_acquire_run_lock() {
    local rc
    _acquire_readonly_health_lock || return $?
    if [[ "$FIX_MODE" != "true" ]]; then
        return 0
    fi

    if operation_acquire \
        --id health-repair \
        --label "Health repair" \
        --non-interactive skip; then
        HEALTH_OPERATION_GUARD_ACQUIRED=true
    else
        rc=$?
        if ! _release_readonly_health_lock; then
            log_error "Health coordination cleanup reported a failure after global guard acquisition failed."
        fi
        if (( rc == 75 )); then
            return 75
        fi
        log_error "Health repair operation guard failed before checks could run."
        return 4
    fi

    if ! operation_set_phase "repair" "Health check with auto-repair"; then
        operation_release 4 || true
        HEALTH_OPERATION_GUARD_ACQUIRED=false
        _release_readonly_health_lock || true
        log_error "Health repair operation guard could not record its phase."
        return 4
    fi
}

_release_run_lock() {
    local original_rc="${1:-0}" cleanup_rc=0 rc
    if [[ "$HEALTH_OPERATION_GUARD_ACQUIRED" == "true" ]]; then
        if operation_release "$original_rc"; then
            :
        else
            rc=$?
            cleanup_rc="$rc"
        fi
        HEALTH_OPERATION_GUARD_ACQUIRED=false
    fi
    if _release_readonly_health_lock; then
        :
    else
        rc=$?
        cleanup_rc="$rc"
    fi
    if (( original_rc != 0 )); then
        return "$original_rc"
    fi
    (( cleanup_rc == 0 )) || return 4
    return 0
}

_health_exit_cleanup() {
    local original_rc=$? final_rc=0
    trap - EXIT HUP INT TERM
    _release_run_lock "$original_rc" || final_rc=$?
    if (( original_rc != 0 )); then
        exit "$original_rc"
    fi
    exit "$final_rc"
}

_health_signal_cleanup() {
    local signal_rc="$1"
    trap - EXIT HUP INT TERM
    _release_run_lock "$signal_rc" || true
    exit "$signal_rc"
}

local ALERT_LOCK_DIR="${ALERT_STATE_DIR:-$(_default_alert_state_dir)}"
local ALERT_COOLDOWN_SECONDS=${ALERT_COOLDOWN_SECONDS:-3600}
local ALERT_RECOVERY_TTL=${ALERT_RECOVERY_TTL:-86400}
local ALERT_RECOVERY_PENDING_TTL=${ALERT_RECOVERY_PENDING_TTL:-900}
local ALERT_STATE_LOCK_WAIT_SECONDS=${ALERT_STATE_LOCK_WAIT_SECONDS:-5}
local ACTIVE_INCIDENT_FILE="${ALERT_LOCK_DIR}/active-incident.state"
local RECOVERY_DELIVERY_STATE_FILE="${ALERT_LOCK_DIR}/recovery-delivery.state"
local ACTIVE_INCIDENT_AVAILABLE=false
local ACTIVE_INCIDENT_ID=""
local ACTIVE_INCIDENT_STARTED_AT=""
local ACTIVE_INCIDENT_LAST_UNHEALTHY_AT=""
local ACTIVE_INCIDENT_HOSTNAME=""
local RECOVERY_DELIVERY_PHASE=""
local RECOVERY_DELIVERY_INCIDENT_ID=""
local RECOVERY_DELIVERY_UPDATED_AT=""
local HEALTH_ALERT_STATE_LOCK_FD=""
local -A incident_statuses=()
local -A incident_details=()
local -a incident_check_order=()

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

    if crowdsec -t >"$validation_log" 2>&1; then
        return 0
    else
        validation_rc=$?
    fi

    _crowdsec_health_sanitize_validation_log "$validation_log"
    return "$validation_rc"
)

_check_crowdsec_email_notifications() {
    local enabled="${CROWDSEC_EMAIL_NOTIFICATIONS:-false}"
    local event_policy="${CROWDSEC_EMAIL_EVENT_POLICY:-all}"
    local etc_dir="${VW_CROWDSEC_ETC_DIR:-/etc/crowdsec}"
    local plugin_file="${etc_dir}/notifications/vaultwarden-email.yaml"
    local profiles_file="${etc_dir}/profiles.yaml.local"
    local plugin_marker="# Managed by VaultWarden-OCI: CrowdSec email notification"
    local profile_begin="# BEGIN VaultWarden-OCI CrowdSec email notifications"
    local profile_end="# END VaultWarden-OCI CrowdSec email notifications"
    enabled="${enabled,,}"
    if [[ "$event_policy" != "all" && "$event_policy" != "none" ]]; then
        _warn "crowdsec:email-notifications:policy" \
            "CROWDSEC_EMAIL_EVENT_POLICY must be exactly all or none"
        return 0
    fi
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
    if [[ "$event_policy" == "all" ]]; then
        if [[ ! -f "$profiles_file" ]] \
            || ! grep -Fxq "$profile_begin" "$profiles_file" \
            || ! grep -Fxq "$profile_end" "$profiles_file"; then
            _warn "crowdsec:email-notifications:profile" \
                "CrowdSec automatic event email is enabled but the managed profiles.yaml.local block is missing"
            return 0
        fi
        _pass "crowdsec:email-notifications:configured" \
            "CrowdSec automatic event email is configured through 127.0.0.1:587"
    else
        if [[ -f "$profiles_file" ]] \
            && { grep -Fxq "$profile_begin" "$profiles_file" \
                || grep -Fxq "$profile_end" "$profiles_file"; }; then
            _warn "crowdsec:email-notifications:profile" \
                "CrowdSec event policy is none but the managed automatic email profile is still present"
            return 0
        fi
        _pass "crowdsec:email-notifications:configured" \
            "CrowdSec automatic event email is disabled by policy; manual plugin tests remain available"
    fi
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
    trap '_health_exit_cleanup' EXIT
    trap '_health_signal_cleanup 129' HUP
    trap '_health_signal_cleanup 130' INT
    trap '_health_signal_cleanup 143' TERM
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
    local notification_rc=0
    _notify_failures || notification_rc=$?
    _notify_recovery || notification_rc=$?
    if (( notification_rc != 0 )); then
        return "$notification_rc"
    fi
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
