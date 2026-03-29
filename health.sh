#!/usr/bin/env bash
# health.sh - Enhanced health monitoring for VaultWarden-OCI with auto-recovery

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

source "$SCRIPT_DIR/lib/common.sh"
init_common_lib "$0"
source "$SCRIPT_DIR/lib/docker.sh"
source "$SCRIPT_DIR/lib/crypto.sh"
source "$SCRIPT_DIR/lib/secrets.sh"
source "$SCRIPT_DIR/lib/simple_key_resilience.sh"

ENV_DIR="${ENV_DIR:-/etc/vaultwarden}"
ENV_FILE="$ENV_DIR/vaultwarden.env"

# Configuration
COMPREHENSIVE=false
QUIET=false
JSON_OUTPUT=false
SEND_EMAIL=false
AUTO_RECOVER=false
ALERT_THRESHOLD=80
OUTPUT_FILE=""
RECOVERY_WAIT_TIME=30

declare -A HEALTH_RESULTS
declare -A HEALTH_DETAILS
OVERALL_STATUS="healthy"
ISSUES_FOUND=()
CRITICAL_ISSUES=()

show_help() {
    cat << 'EOF'
VaultWarden-OCI Health Monitor - Set-and-Forget Edition with Auto-Recovery

USAGE:
    ./health.sh [OPTIONS]

OPTIONS:
    --comprehensive     Run comprehensive health checks
    --auto-recover      Attempt automatic recovery of unhealthy containers
    --email             Send email notification if issues found
    --quiet             Suppress non-error output
    --json              Output results in JSON format
    --output FILE       Save results to file
    --alert-threshold N Set alert threshold percentage (default: 80)
    --recovery-wait N   Seconds to wait after container restart before re-check (default: 30)
    --help              Show this help

EXAMPLES:
    ./health.sh                           # Basic health check
    ./health.sh --comprehensive           # Full system health check
    ./health.sh --auto-recover            # Check with automatic recovery
    ./health.sh --comprehensive --email --auto-recover   # Full check with recovery and alerts

SET-AND-FORGET MONITORING:
    Basic: Container status and service accessibility
    Comprehensive: Disk space, SSL certificates, database, backups, email test
    Auto-Recovery: Automatically restart unhealthy containers

CRON USAGE:
    */15 * * * * /opt/vaultwarden-scripts/health.sh --auto-recover >> /var/log/vaultwarden-health.log 2>&1
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --comprehensive) COMPREHENSIVE=true; shift ;;
        --auto-recover) AUTO_RECOVER=true; shift ;;
        --email) SEND_EMAIL=true; shift ;;
        --quiet) QUIET=true; shift ;;
        --json) JSON_OUTPUT=true; shift ;;
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        --alert-threshold) ALERT_THRESHOLD="$2"; shift 2 ;;
        --recovery-wait) RECOVERY_WAIT_TIME="$2"; shift 2 ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

health_log_info()    { [[ "$QUIET" == "true" ]] || log_info "$1"; }
health_log_success() { [[ "$QUIET" == "true" ]] || log_success "$1"; }
health_log_warn()    { log_warn "$1"; ISSUES_FOUND+=("WARNING: $1"); }
health_log_error()   { log_error "$1"; ISSUES_FOUND+=("ERROR: $1"); CRITICAL_ISSUES+=("$1"); OVERALL_STATUS="unhealthy"; }

_maybe_sudo() {
    if is_root; then
        "$@"
        return $?
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        "$@"
        return $?
    fi

    if [[ -t 0 ]]; then
        sudo "$@"
    else
        sudo -n "$@"
    fi
}

_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

run_check() {
    local component="$1"; shift
    local rc=0
    "$@" || rc=$?
    if [[ -z "${HEALTH_RESULTS[$component]+isset}" ]]; then
        HEALTH_RESULTS[$component]="skipped"
        HEALTH_DETAILS[$component]="Check exited prematurely (rc=${rc})"
        ISSUES_FOUND+=("WARNING: $component check did not complete (rc=${rc})")
        [[ "$OVERALL_STATUS" != "unhealthy" ]] && OVERALL_STATUS="degraded"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _resolve_age_key
#
# BUG-AK2 FIX: health.sh previously hardcoded DEFAULT_AGE_KEY_FILE which
# falls back to $SCRIPT_DIR/secrets/keys/age-key.txt.  Under systemd with
# ProtectHome=yes, SCRIPT_DIR=/opt/vaultwarden-scripts — that path does not
# exist.  setup-systemd.sh --install copies the key to
# /etc/vaultwarden/age-key.txt and sets SOPS_AGE_KEY_FILE in the env file,
# but health.sh never honoured that variable for its internal checks.
#
# BUG-AK3 FIX: When /etc/vaultwarden/vaultwarden.env contains a stale
# relative SOPS_AGE_KEY_FILE=secrets/keys/age-key.txt (written before the
# BUG-AK1 fix), the old error-fallback loop returned that relative string
# immediately, masking the hardcoded /etc/vaultwarden/age-key.txt candidate.
# Fix: skip any candidate that is a relative path AND does not exist on disk.
# Absolute non-existent paths are still returned so callers get a useful
# diagnostic.
#
# Resolution order (mirrors backup.sh / crypto.sh):
#   1. SOPS_AGE_KEY_FILE  (set by setup-systemd.sh --install in vaultwarden.env)
#   2. DEFAULT_AGE_KEY_FILE  (explicit env-var override)
#   3. /etc/vaultwarden/age-key.txt  (canonical systemd install path)
#   4. $SCRIPT_DIR/secrets/keys/age-key.txt  (local/dev fallback)
#
# Prints the resolved path to stdout; returns 0 if the file exists, 1 if not.
# ---------------------------------------------------------------------------
_resolve_age_key() {
    local candidates=(
        "${SOPS_AGE_KEY_FILE:-}"
        "${DEFAULT_AGE_KEY_FILE:-}"
        "/etc/vaultwarden/age-key.txt"
        "$SCRIPT_DIR/secrets/keys/age-key.txt"
    )
    for candidate in "${candidates[@]}"; do
        [[ -z "$candidate" ]] && continue
        # BUG-AK3 FIX: skip relative paths that don't exist — they come from a
        # stale env file and must not shadow the absolute fallbacks below them.
        [[ "$candidate" != /* && ! -f "$candidate" ]] && continue
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    # None found — return the first non-empty absolute candidate (or last
    # resort relative one) for a useful error message.
    for candidate in "${candidates[@]}"; do
        [[ -z "$candidate" ]] && continue
        # Prefer absolute paths in the error message; skip bare relative ones.
        if [[ "$candidate" == /* ]]; then
            echo "$candidate"
            return 1
        fi
    done
    # All candidates were relative and non-existent — fall back to the
    # canonical install path so the error message is actionable.
    echo "/etc/vaultwarden/age-key.txt"
    return 1
}

container_is_healthy() {
    local container="$1"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        return 1
    fi

    local status
    status=$(docker inspect "$container" --format='{{.State.Health.Status}}' 2>/dev/null || echo "no-healthcheck")

    if [[ "$status" == "unhealthy" ]]; then
        return 1
    elif [[ "$status" == "no-healthcheck" ]]; then
        local state
        state=$(docker inspect "$container" --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
        [[ "$state" == "running" ]]
    else
        [[ "$status" == "healthy" ]]
    fi
}

attempt_container_recovery() {
    local container="$1"
    local service="$2"

    if [[ -f "/tmp/.vw_maintenance.lock" ]]; then
        log_warn "🔧 $service is stopped for planned maintenance. Skipping auto-recovery."
        return 0
    fi

    log_warn "🔧 Attempting automatic recovery of $service..."

    # BUG-SY3: use --project-directory so docker compose does not depend on CWD
    local compose_file
    compose_file="$(find /opt/vaultwarden-scripts /var/lib/vaultwarden /etc/vaultwarden -maxdepth 2 \
        -name "docker-compose.yml" -o -name "docker-compose.yaml" 2>/dev/null | head -1 || true)"
    local compose_args=()
    [[ -n "$compose_file" ]] && compose_args=(--project-directory "$(dirname "$compose_file")")

    if docker compose "${compose_args[@]}" restart "$service" 2>&1; then
        log_info "Restart command issued for $service, waiting ${RECOVERY_WAIT_TIME}s..."
        sleep "$RECOVERY_WAIT_TIME"

        if container_is_healthy "$container"; then
            log_success "✅ Auto-recovery succeeded for $service"
            if [[ "$SEND_EMAIL" == "true" ]]; then
                local _body
                _body=$(printf 'Service %s was unhealthy and has been automatically restarted.\n\nContainer: %s\nRecovery time: %ss\nStatus: Now healthy\n\nThis was an automated recovery action. The service should now be functioning normally.' \
                    "$service" "$container" "$RECOVERY_WAIT_TIME")
                send_notification_email "✅ $service Auto-Recovered" "$_body"
            fi
            return 0
        else
            log_error "❌ Auto-recovery failed for $service - container still unhealthy"
            if [[ "$SEND_EMAIL" == "true" ]]; then
                local _body
                _body=$(printf 'Service %s remains unhealthy after automatic restart attempt.\n\nContainer: %s\nRecovery attempt: Failed after %ss wait\nStatus: Still unhealthy\n\nMANUAL INTERVENTION REQUIRED:\n1. Check container logs: docker compose logs %s\n2. Check container status: docker compose ps %s\n3. Manual restart: docker compose restart %s\n4. If persistent, check configuration and resources' \
                    "$service" "$container" "$RECOVERY_WAIT_TIME" \
                    "$service" "$service" "$service")
                send_notification_email "❌ $service Auto-Recovery Failed" "$_body"
            fi
            return 1
        fi
    else
        log_error "❌ Failed to execute restart command for $service"
        if [[ "$SEND_EMAIL" == "true" ]]; then
            local _body
            _body=$(printf 'Automatic restart command failed for service %s.\n\nContainer: %s\nError: Docker compose restart command failed\n\nIMMEDIATE ACTION REQUIRED:\n1. Check Docker daemon: systemctl status docker\n2. Check Docker Compose: docker compose ps\n3. Check system resources: df -h && free -h\n4. Attempt manual restart: docker compose restart %s' \
                "$service" "$container" "$service")
            send_notification_email "❌ Cannot Restart $service" "$_body"
        fi
        return 1
    fi
}

check_container_status() {
    health_log_info "Checking container status..."
    local containers=(
        "vaultwarden_app:vaultwarden"
        "vaultwarden_caddy:caddy"
        "vaultwarden_fail2ban:fail2ban"
        "vaultwarden_postfix:postfix"
    )
    local unhealthy_containers=() stopped_containers=()

    for container_service in "${containers[@]}"; do
        local container="${container_service%%:*}"
        local service="${container_service##*:}"

        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            local status
            status=$(docker inspect "$container" --format='{{.State.Health.Status}}' 2>/dev/null || echo "no-healthcheck")
            if [[ "$status" == "unhealthy" ]]; then
                unhealthy_containers+=("$container")

                if [[ "$AUTO_RECOVER" == "true" ]]; then
                    attempt_container_recovery "$container" "$service"
                fi
            elif [[ "$status" == "no-healthcheck" ]]; then
                local state
                state=$(docker inspect "$container" --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
                if [[ "$state" != "running" ]]; then
                    stopped_containers+=("$container")
                    if [[ "$AUTO_RECOVER" == "true" ]]; then
                        log_error "CRITICAL: $container is stopped"
                        attempt_container_recovery "$container" "$service"
                    fi
                fi
            fi
        else
            stopped_containers+=("$container")

            if [[ "$AUTO_RECOVER" == "true" ]]; then
                log_error "CRITICAL: $container is stopped"
                attempt_container_recovery "$container" "$service"
            fi
        fi
    done

    if [[ "$AUTO_RECOVER" == "true" ]] && \
       [[ ${#unhealthy_containers[@]} -gt 0 || ${#stopped_containers[@]} -gt 0 ]]; then
        unhealthy_containers=()
        stopped_containers=()

        for container_service in "${containers[@]}"; do
            local container="${container_service%%:*}"

            if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
                stopped_containers+=("$container")
            else
                local status
                status=$(docker inspect "$container" --format='{{.State.Health.Status}}' 2>/dev/null || echo "no-healthcheck")
                [[ "$status" == "unhealthy" ]] && unhealthy_containers+=("$container")
            fi
        done
    fi

    if [[ ${#stopped_containers[@]} -gt 0 ]]; then
        health_log_error "CRITICAL: Stopped containers: ${stopped_containers[*]}"
        HEALTH_RESULTS["containers"]="failed"
        HEALTH_DETAILS["containers"]="Stopped: ${stopped_containers[*]}"
        return 1
    elif [[ ${#unhealthy_containers[@]} -gt 0 ]]; then
        health_log_error "CRITICAL: Unhealthy containers: ${unhealthy_containers[*]}"
        HEALTH_RESULTS["containers"]="failed"
        HEALTH_DETAILS["containers"]="Unhealthy: ${unhealthy_containers[*]}"
        return 1
    else
        health_log_success "All containers are running and healthy"
        HEALTH_RESULTS["containers"]="healthy"
        HEALTH_DETAILS["containers"]="All containers operational"
        return 0
    fi
}

check_service_accessibility() {
    health_log_info "Checking service accessibility..."

    if curl -sf --max-time 5 "http://localhost:8080/alive" >/dev/null 2>&1; then
        health_log_success "VaultWarden local access: OK"
    else
        health_log_error "CRITICAL: VaultWarden local access: FAILED"
        health_log_error "Port 8080 may not be exposed in docker-compose.yml"
        HEALTH_RESULTS["accessibility"]="failed"
        return 1
    fi

    local domain
    domain=$(get_config_value "DOMAIN" 2>/dev/null || echo "")
    if [[ -n "$domain" ]]; then
        local clean_domain
        clean_domain=$(printf '%s' "$domain" | sed 's|https\?://||; s|/.*$||')
        if curl -sf --max-time 5 "https://$clean_domain/alive" >/dev/null 2>&1; then
            health_log_success "External web access: OK"
        else
            health_log_warn "External web access: FAILED (Check Cloudflare/DNS)"
            HEALTH_RESULTS["accessibility"]="degraded"
            return 0
        fi
    fi

    HEALTH_RESULTS["accessibility"]="healthy"
    HEALTH_DETAILS["accessibility"]="Local service confirmed"
    return 0
}

check_disk_space() {
    health_log_info "Checking disk space usage..."
    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"

    _check_mount() {
        local label="$1" mount="$2"
        local usage_percent free_kib
        read -r usage_percent free_kib < <(
            df -k "$mount" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5, $4}'
        )
        usage_percent=${usage_percent:-0}
        free_kib=${free_kib:-0}

        local free_human
        if   (( free_kib >= 1048576 )); then
            free_human="$(( free_kib / 1048576 )) GB"
        elif (( free_kib >= 1024 )); then
            free_human="$(( free_kib / 1024 )) MB"
        else
            free_human="${free_kib} KB"
        fi

        if (( usage_percent > ALERT_THRESHOLD )) || (( free_kib < 512000 )); then
            health_log_error "CRITICAL: ${label} disk usage: ${usage_percent}% (${free_human} free)"
            HEALTH_RESULTS["disk_space"]="failed"
            HEALTH_DETAILS["disk_space"]="${label}: ${usage_percent}% used, ${free_human} free"
            return 1
        elif (( usage_percent > 70 )) || (( free_kib < 2097152 )); then
            health_log_warn "${label} disk usage high: ${usage_percent}% (${free_human} free)"
            [[ "${HEALTH_RESULTS[disk_space]:-}" != "failed" ]] && {
                HEALTH_RESULTS["disk_space"]="degraded"
                HEALTH_DETAILS["disk_space"]="${label}: ${usage_percent}% used, ${free_human} free (warning)"
            }
            return 1
        else
            health_log_success "${label} disk space OK: ${usage_percent}% used (${free_human} free)"
            [[ -z "${HEALTH_RESULTS[disk_space]+isset}" ]] && {
                HEALTH_RESULTS["disk_space"]="healthy"
                HEALTH_DETAILS["disk_space"]="${label}: ${usage_percent}% used, ${free_human} free"
            }
            return 0
        fi
    }

    local disk_ok=true
    _check_mount "Root (/)" "/" || disk_ok=false

    if [[ -d "$state_dir" && "$state_dir" != "/" ]]; then
        _check_mount "State dir (${state_dir})" "$state_dir" || disk_ok=false
    fi

    if [[ -z "${HEALTH_RESULTS[disk_space]+isset}" ]]; then
        HEALTH_RESULTS["disk_space"]="healthy"
        HEALTH_DETAILS["disk_space"]="All mount points within thresholds"
    fi

    [[ "$disk_ok" == "true" ]]
}

_resolve_domain() {
    local domain="$1"
    if command -v getent >/dev/null 2>&1; then
        timeout 3 getent hosts "$domain" >/dev/null 2>&1 && return 0
    fi
    if command -v dig >/dev/null 2>&1; then
        local result
        result=$(timeout 3 dig +short +tries=1 +time=3 "$domain" 2>/dev/null)
        [[ -n "$result" ]] && return 0
        return 1
    fi
    if command -v host >/dev/null 2>&1; then
        timeout 3 host -W 3 "$domain" >/dev/null 2>&1 && return 0
    fi
    return 0
}

check_ssl_certificates() {
    health_log_info "Checking SSL certificate expiration..."
    local domain clean_domain

    if [[ -f "$ENV_FILE" ]]; then
        domain=$(grep "^DOMAIN=" "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" || echo "")
    else
        domain=""
    fi

    if [[ -z "$domain" ]]; then
        health_log_warn "No domain configured for SSL check"
        HEALTH_RESULTS["ssl_certificates"]="degraded"
        HEALTH_DETAILS["ssl_certificates"]="No domain configured"
        return 0
    fi

    clean_domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')

    if ! _resolve_domain "$clean_domain"; then
        health_log_warn "SSL check skipped: domain '$clean_domain' does not resolve (NXDOMAIN or DNS timeout)"
        HEALTH_RESULTS["ssl_certificates"]="degraded"
        HEALTH_DETAILS["ssl_certificates"]="DNS resolution failed for ${clean_domain}"
        return 1
    fi

    local cert_info expiry_date expires_in
    if cert_info=$(echo | timeout 5 openssl s_client \
            -servername "$clean_domain" \
            -connect "$clean_domain:443" 2>/dev/null | \
            openssl x509 -noout -dates 2>/dev/null); then
        expiry_date=$(echo "$cert_info" | grep "notAfter" | cut -d= -f2)
        if [[ -n "$expiry_date" ]]; then
            local expiry_epoch current_epoch
            expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null \
                        || date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null \
                        || echo "0")
            current_epoch=$(date +%s)
            expires_in=$(( (expiry_epoch - current_epoch) / 86400 ))

            if (( expires_in < 7 )); then
                health_log_error "CRITICAL: SSL certificate expires in ${expires_in} days"
                HEALTH_RESULTS["ssl_certificates"]="failed"
                HEALTH_DETAILS["ssl_certificates"]="Expires in ${expires_in} days"
                return 1
            elif (( expires_in < 30 )); then
                health_log_warn "SSL certificate expires in ${expires_in} days"
                HEALTH_RESULTS["ssl_certificates"]="degraded"
                HEALTH_DETAILS["ssl_certificates"]="Expires in ${expires_in} days"
                return 1
            else
                health_log_success "SSL certificate OK: ${expires_in} days remaining"
                HEALTH_RESULTS["ssl_certificates"]="healthy"
                HEALTH_DETAILS["ssl_certificates"]="${expires_in} days remaining"
                return 0
            fi
        else
            health_log_warn "Could not parse SSL certificate expiration"
            HEALTH_RESULTS["ssl_certificates"]="degraded"
            HEALTH_DETAILS["ssl_certificates"]="Could not parse cert dates"
            return 1
        fi
    else
        health_log_warn "Could not check SSL certificate (connection failed or timed out)"
        HEALTH_RESULTS["ssl_certificates"]="degraded"
        HEALTH_DETAILS["ssl_certificates"]="Connection failed or timed out"
        return 1
    fi
}

check_database_growth() {
    health_log_info "Checking database size and growth..."
    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    local db_path="$state_dir/data/db.sqlite3"

    if [[ -f "$db_path" ]]; then
        local current_size_bytes current_size_mb
        current_size_bytes=$(stat -c%s "$db_path" 2>/dev/null || stat -f%z "$db_path" 2>/dev/null || echo "0")
        current_size_mb=$((current_size_bytes / 1024 / 1024))

        local size_history_file="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/.vw_db_size_history"
        local previous_size=0
        [[ -f "$size_history_file" ]] && previous_size=$(cat "$size_history_file" 2>/dev/null || echo "0")

        if [[ ! -f "$size_history_file" ]]; then
            install -m 600 /dev/null "$size_history_file" 2>/dev/null || true
        fi
        printf '%s\n' "$current_size_mb" > "${size_history_file}.tmp" && \
            mv "${size_history_file}.tmp" "$size_history_file" || true
        chmod 600 "$size_history_file" 2>/dev/null || true

        local growth=$((current_size_mb - previous_size))

        if (( current_size_mb > 500 )); then
            health_log_warn "Database size very large: ${current_size_mb}MB"
            HEALTH_RESULTS["database_growth"]="degraded"
            HEALTH_DETAILS["database_growth"]="Size: ${current_size_mb}MB (large)"
            return 1
        elif (( growth > 10 )) && (( previous_size > 0 )); then
            health_log_warn "Database grew rapidly: +${growth}MB (now ${current_size_mb}MB)"
            HEALTH_RESULTS["database_growth"]="degraded"
            HEALTH_DETAILS["database_growth"]="Rapid growth: +${growth}MB"
            return 1
        else
            health_log_success "Database size OK: ${current_size_mb}MB"
            HEALTH_RESULTS["database_growth"]="healthy"
            HEALTH_DETAILS["database_growth"]="Size: ${current_size_mb}MB"
            return 0
        fi
    else
        health_log_warn "Database file not found: $db_path"
        HEALTH_RESULTS["database_growth"]="degraded"
        HEALTH_DETAILS["database_growth"]="Database file not found"
        return 1
    fi
}

_verify_backup_decryptable() {
    local backup_file="$1"
    local backup_type="$2"
    [[ -z "$backup_file" || ! -f "$backup_file" ]] && return 0

    # BUG-AK2 FIX: use _resolve_age_key() so SOPS_AGE_KEY_FILE (set by
    # setup-systemd.sh --install in /etc/vaultwarden/vaultwarden.env) is
    # honoured.  The old DEFAULT_AGE_KEY_FILE fallback always resolved to
    # $SCRIPT_DIR/secrets/keys/age-key.txt which does not exist under
    # systemd (ProtectHome=yes, SCRIPT_DIR=/opt/vaultwarden-scripts).
    local age_key_file
    age_key_file=$(_resolve_age_key) || {
        health_log_error "CRITICAL: Age key file missing: $age_key_file"
        return 1
    }

    local file_size
    file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null || echo "0")
    (( file_size < 1024 )) && {
        health_log_error "CRITICAL: Backup file suspiciously small (${file_size} bytes): $(basename "$backup_file")"
        return 1
    }

    if ! _maybe_sudo age -d -i "$age_key_file" "$backup_file" > /dev/null 2>&1; then
        health_log_error "CRITICAL: Failed to decrypt latest $backup_type backup!"
        return 1
    fi

    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    local stamp_file="${state_dir}/.vw_backup_verified.$(basename "$backup_file")"
    install -m 600 /dev/null "${stamp_file}.tmp" 2>/dev/null && \
        printf '%s\n' "$(date +%s)" > "${stamp_file}.tmp" && \
        mv "${stamp_file}.tmp" "$stamp_file" || true

    return 0
}

_backup_verified_age_days() {
    local backup_file="$1"
    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    local stamp_file="${state_dir}/.vw_backup_verified.$(basename "$backup_file")"

    local ref_epoch=0
    if [[ -f "$stamp_file" ]]; then
        ref_epoch=$(cat "$stamp_file" 2>/dev/null || echo "0")
    else
        ref_epoch=$(stat -c%Y "$backup_file" 2>/dev/null || \
                    stat -f%m "$backup_file" 2>/dev/null || echo "0")
    fi

    echo $(( ($(date +%s) - ref_epoch) / 86400 ))
}

# ---------------------------------------------------------------------------
# check_backup_status
#
# Three-state logic for backup directory and backup file presence:
#
#   State 1 — Directory absent (fresh install, never backed up yet):
#     Auto-create the directory tree (base/full, base/db, base/emergency) with
#     mode 750 so the very next backup.sh run can write into it.  Emit a WARN
#     (not CRITICAL) and set status="initialising" so the overall health result
#     stays healthy.  No alert email is sent.
#
#   State 2 — Directory present but no backup files found:
#     Emit a WARN for each missing backup type and set status="degraded".
#     This covers the window between dir creation and the first scheduled run.
#     Overall health stays healthy (degraded != failed).
#
#   State 3 — Backup files exist:
#     Check age and decrypt integrity.  Stale (>2d DB, >7d full) or corrupt
#     backups are escalated to CRITICAL / status="failed" as before.
# ---------------------------------------------------------------------------
check_backup_status() {
    health_log_info "Checking backup status and integrity..."

    local backup_base_dir
    backup_base_dir="${BACKUP_DIR:-/var/lib/vaultwarden/backups}"
    if [[ -f "$ENV_FILE" ]]; then
        local env_backup_dir
        env_backup_dir=$(grep "^BACKUP_DIR=" "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" || echo "")
        [[ -n "$env_backup_dir" ]] && backup_base_dir="$env_backup_dir"
    fi

    # ---- State 1: directory absent → auto-initialise, warn only ------------
    if [[ ! -d "$backup_base_dir" ]]; then
        health_log_info "Backup directory not found: $backup_base_dir — initialising structure..."
        local _owner
        _owner=$(get_real_user 2>/dev/null || echo "root")
        local _init_ok=true
        for _subdir in full db emergency; do
            if ! mkdir -p "${backup_base_dir}/${_subdir}" 2>/dev/null; then
                log_warn "Could not create backup subdir: ${backup_base_dir}/${_subdir}"
                _init_ok=false
            fi
        done
        if [[ "$_init_ok" == "true" ]]; then
            chmod 750 "$backup_base_dir" 2>/dev/null || true
            chown "${_owner}" "$backup_base_dir" 2>/dev/null || true
            health_log_warn "Backup directory initialised: $backup_base_dir — no backups yet (first run pending)"
            HEALTH_RESULTS["backup_status"]="initialising"
            HEALTH_DETAILS["backup_status"]="Directory created; awaiting first backup run"
        else
            # mkdir failed (permissions issue) — this is a real problem
            health_log_error "CRITICAL: Cannot create backup directory: $backup_base_dir"
            HEALTH_RESULTS["backup_status"]="failed"
            HEALTH_DETAILS["backup_status"]="Cannot create backup directory"
            return 1
        fi
        return 0
    fi

    # ---- State 2 / 3: directory exists — check for backup files -----------
    local latest_db_backup="" latest_full_backup=""

    [[ -d "$backup_base_dir/db" ]] && \
        latest_db_backup=$(find "$backup_base_dir/db" -name "*.age" -type f 2>/dev/null | sort | tail -1)
    [[ -d "$backup_base_dir/full" ]] && \
        latest_full_backup=$(find "$backup_base_dir/full" -name "*.age" -type f 2>/dev/null | sort | tail -1)

    local backup_issues=()
    local backup_failed=false

    if [[ -n "${latest_db_backup:-}" ]]; then
        local db_backup_age
        db_backup_age=$(_backup_verified_age_days "$latest_db_backup")

        if (( db_backup_age > 2 )); then
            backup_issues+=("Last DB backup is ${db_backup_age} days old (verified stamp)")
            backup_failed=true
        elif ! _verify_backup_decryptable "$latest_db_backup" "DB"; then
            backup_issues+=("Latest DB backup failed decryption")
            backup_failed=true
        else
            health_log_success "Database backup recent (${db_backup_age}d) and decryptable"
        fi
    else
        # State 2: dir exists but no files yet — warn, not critical
        health_log_warn "No database backups found in $backup_base_dir/db — first backup run pending"
        backup_issues+=("No database backups yet")
    fi

    if [[ -n "${latest_full_backup:-}" ]]; then
        local full_backup_age
        full_backup_age=$(_backup_verified_age_days "$latest_full_backup")

        if (( full_backup_age > 7 )); then
            backup_issues+=("Last full backup is ${full_backup_age} days old (verified stamp)")
            backup_failed=true
        elif ! _verify_backup_decryptable "$latest_full_backup" "full"; then
            backup_issues+=("Latest full backup failed decryption")
            backup_failed=true
        else
            health_log_success "Full backup recent (${full_backup_age}d) and decryptable"
        fi
    else
        # State 2: dir exists but no files yet — warn, not critical
        health_log_warn "No full backups found in $backup_base_dir/full — first backup run pending"
        backup_issues+=("No full backups yet")
    fi

    if [[ "$backup_failed" == "true" ]]; then
        health_log_error "CRITICAL: Backup issues: ${backup_issues[*]}"
        HEALTH_RESULTS["backup_status"]="failed"
        HEALTH_DETAILS["backup_status"]="Issues: ${backup_issues[*]}"
        return 1
    elif [[ ${#backup_issues[@]} -gt 0 ]]; then
        # Warnings only (missing files, not stale/corrupt existing ones)
        HEALTH_RESULTS["backup_status"]="degraded"
        HEALTH_DETAILS["backup_status"]="Pending: ${backup_issues[*]}"
        return 0
    else
        health_log_success "Backup status OK"
        HEALTH_RESULTS["backup_status"]="healthy"
        HEALTH_DETAILS["backup_status"]="Recent backups available and decryptable"
        return 0
    fi
}

test_email_notifications() {
    health_log_info "Testing email notification functionality..."
    local admin_email

    if [[ -f "$ENV_FILE" ]]; then
        admin_email=$(grep "^ADMIN_EMAIL=" "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" || echo "")
    else
        admin_email=""
    fi

    if [[ -z "$admin_email" ]]; then
        health_log_warn "ADMIN_EMAIL not configured - email notifications disabled"
        HEALTH_RESULTS["email_notifications"]="degraded"
        HEALTH_DETAILS["email_notifications"]="No admin email configured"
        return 1
    fi

    if [[ "$SEND_EMAIL" == "true" ]]; then
        local _has_api_token=false
        [[ -n "${EMAIL_API_TOKEN:-}" ]] && _has_api_token=true

        if [[ "$_has_api_token" == "false" && -z "${SMTP_PASSWORD:-}" ]]; then
            health_log_error "No email credential available: EMAIL_API_TOKEN env var and SMTP_PASSWORD are both unset — check that secrets.yaml key email_api_key decrypts successfully"
            HEALTH_RESULTS["email_notifications"]="failed"
            HEALTH_DETAILS["email_notifications"]="No API token or SMTP_PASSWORD; secrets not loaded"
            return 1
        fi

        if send_notification_email "Health Check Test" "Email notifications are working correctly."; then
            health_log_success "Email notifications working"
            HEALTH_RESULTS["email_notifications"]="healthy"
            HEALTH_DETAILS["email_notifications"]="Test email sent successfully"
            return 0
        else
            health_log_error "Email notification test failed"
            HEALTH_RESULTS["email_notifications"]="failed"
            HEALTH_DETAILS["email_notifications"]="Test email failed"
            return 1
        fi
    else
        health_log_success "Email notifications configured (use --email to test)"
        HEALTH_RESULTS["email_notifications"]="healthy"
        HEALTH_DETAILS["email_notifications"]="Configured but not tested"
        return 0
    fi
}

check_resource_usage() {
    [[ "$COMPREHENSIVE" == "false" ]] && return 0
    health_log_info "Checking resource usage..."

    local cpu_usage mem_usage cpu_int

    if [[ -r /proc/stat ]]; then
        local cpu1 cpu2 idle1 total1 idle2 total2
        cpu1=$(grep -m1 '^cpu ' /proc/stat)
        sleep 1
        cpu2=$(grep -m1 '^cpu ' /proc/stat)
        read -r _ u1 n1 s1 i1 rest1 <<< "$cpu1"
        read -r _ u2 n2 s2 i2 rest2 <<< "$cpu2"
        total1=$(( u1 + n1 + s1 + i1 ))
        total2=$(( u2 + n2 + s2 + i2 ))
        idle1=$i1; idle2=$i2
        local dtotal=$(( total2 - total1 ))
        local didle=$(( idle2 - idle1 ))
        if (( dtotal > 0 )); then
            cpu_usage=$(( 100 * (dtotal - didle) / dtotal ))
        else
            cpu_usage=0
        fi
    else
        cpu_usage=$(top -bn1 | awk '/[Cc][Pp][Uu]/ && /[0-9]/ {
            for(i=1;i<=NF;i++) {
                if ($i ~ /^[0-9.]+$/ && $(i-1) ~ /[uU][sS]/) { print $i; exit }
                if ($i ~ /[0-9.]+%?us,?/) { gsub(/[^0-9.]/,"",$i); print $i; exit }
            }
        } NR==3 {exit}' 2>/dev/null | head -1 || echo "")
        cpu_usage=${cpu_usage%.*}
        if [[ -z "$cpu_usage" ]] || ! [[ "$cpu_usage" =~ ^[0-9]+$ ]]; then
            log_warn "check_resource_usage: could not parse CPU usage from top output; defaulting to 0"
            cpu_usage=0
        fi
    fi
    mem_usage=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100.0}' 2>/dev/null || echo "0")

    local resource_issues=()
    local resource_failed=false

    cpu_int=${cpu_usage%.*}
    (( cpu_int > ALERT_THRESHOLD )) && {
        resource_issues+=("CPU: ${cpu_usage}%")
        resource_failed=true
    }

    (( mem_usage > ALERT_THRESHOLD )) && {
        resource_issues+=("Memory: ${mem_usage}%")
        resource_failed=true
    }

    if [[ "$resource_failed" == "true" ]]; then
        health_log_warn "High resource usage: ${resource_issues[*]}"
        HEALTH_RESULTS["resources"]="degraded"
        HEALTH_DETAILS["resources"]="High usage: ${resource_issues[*]}"
        return 1
    else
        health_log_success "Resource usage within normal limits"
        HEALTH_RESULTS["resources"]="healthy"
        HEALTH_DETAILS["resources"]="CPU: ${cpu_usage}%, Memory: ${mem_usage}%"
        return 0
    fi
}

check_configuration() {
    [[ "$COMPREHENSIVE" == "false" ]] && return 0
    health_log_info "Checking configuration..."

    local config_issues=()

    if [[ ! -f "$ENV_FILE" ]]; then
        config_issues+=("Missing env file: $ENV_FILE")
    else
        local required_vars=("DOMAIN_NAME" "ADMIN_EMAIL" "CLOUDFLARE_ZONE_ID")
        for var in "${required_vars[@]}"; do
            grep -q "^${var}=" "$ENV_FILE" || config_issues+=("Missing $var in $ENV_FILE")
        done
    fi

    local secrets_file="$SCRIPT_DIR/secrets/secrets.yaml"
    if [[ ! -f "$secrets_file" ]]; then
        config_issues+=("Missing secrets.yaml file")
    else
        if ! "$SCRIPT_DIR/edit-secrets.sh" --list >/dev/null 2>&1; then
            config_issues+=("Secrets decryption failed")
        fi
    fi

    local compose_dir
    compose_dir="$(find /var/lib/vaultwarden /opt/vaultwarden-scripts -maxdepth 2 \
        -name "docker-compose.yml" -o -name "docker-compose.yaml" 2>/dev/null | head -1 | xargs -I{} dirname {} || true)"
    if [[ -n "$compose_dir" ]]; then
        docker compose --project-directory "$compose_dir" config >/dev/null 2>&1 \
            || config_issues+=("Docker Compose configuration error")
    else
        config_issues+=("docker-compose.yml not found")
    fi

    if [[ ${#config_issues[@]} -gt 0 ]]; then
        health_log_error "CRITICAL: Configuration issues: ${config_issues[*]}"
        HEALTH_RESULTS["configuration"]="failed"
        HEALTH_DETAILS["configuration"]="Issues: ${config_issues[*]}"
        return 1
    else
        health_log_success "Configuration validation passed"
        HEALTH_RESULTS["configuration"]="healthy"
        HEALTH_DETAILS["configuration"]="All configurations valid"
        return 0
    fi
}

_check_fail2ban_responding() {
    if docker exec vaultwarden_fail2ban sh -c \
            'fail2ban-client --json status 2>/dev/null' \
            | grep -q '"status"' 2>/dev/null; then
        return 0
    fi
    docker exec vaultwarden_fail2ban sh -c \
        'fail2ban-client status >/dev/null 2>&1'
}

check_security_status() {
    [[ "$COMPREHENSIVE" == "false" ]] && return 0
    health_log_info "Checking security status..."

    local security_issues=()

    _check_fail2ban_responding 2>/dev/null || \
        security_issues+=("fail2ban not responding")

    # Wire: use simple_verify_age_key() from lib/simple_key_resilience.sh
    # instead of the old two-step _resolve_age_key() + check_age_key() pair.
    # simple_verify_age_key() resolves the key path internally (honouring
    # SOPS_AGE_KEY_FILE, /etc/vaultwarden/age-key.txt, and the local dev
    # fallback), then validates permissions, ownership, and performs a
    # crypto roundtrip — a strict superset of the previous check_age_key().
    # BUG-AK2 / BUG-AK3 resilience is preserved via _resolve_age_key() inside
    # the library.
    if ! simple_verify_age_key 2>/dev/null; then
        security_issues+=("Age key validation failed")
    fi

    if [[ -f "$SCRIPT_DIR/.sops.yaml" ]]; then
        grep -q "age:" "$SCRIPT_DIR/.sops.yaml" || security_issues+=("SOPS configuration missing Age key")
    else
        security_issues+=("SOPS configuration file missing")
    fi

    if [[ ${#security_issues[@]} -gt 0 ]]; then
        health_log_warn "Security issues found: ${security_issues[*]}"
        HEALTH_RESULTS["security"]="degraded"
        HEALTH_DETAILS["security"]="Issues: ${security_issues[*]}"
        return 1
    else
        health_log_success "Security status good"
        HEALTH_RESULTS["security"]="healthy"
        HEALTH_DETAILS["security"]="All security checks passed"
        return 0
    fi
}

generate_report() {
    [[ "$JSON_OUTPUT" == "true" ]] && generate_json_report || generate_text_report
}

generate_text_report() {
    local report=""
    report+="VaultWarden-OCI Health Report - Set-and-Forget Edition\n"
    report+="Generated: $(date)\n"
    report+="Overall Status: $OVERALL_STATUS\n"
    [[ "$AUTO_RECOVER" == "true" ]] && report+="Auto-Recovery: Enabled\n"
    report+="\n"
    report+="Component Status:\n"

    for component in "${!HEALTH_RESULTS[@]}"; do
        local status="${HEALTH_RESULTS[$component]}"
        local details="${HEALTH_DETAILS[$component]:-}"
        case $status in
            "healthy")       report+="  ✅ $component: $status" ;;
            "degraded")      report+="  ⚠️  $component: $status" ;;
            "initialising")  report+="  🔄 $component: $status" ;;
            "failed")        report+="  ❌ $component: $status" ;;
            "skipped")       report+="  ⏭️  $component: $status" ;;
        esac
        [[ -n "$details" ]] && report+=" - $details"
        report+="\n"
    done

    if [[ ${#ISSUES_FOUND[@]} -gt 0 ]]; then
        report+="\nIssues Found:\n"
        for issue in "${ISSUES_FOUND[@]}"; do
            report+="  • $issue\n"
        done
    fi

    if [[ -n "$OUTPUT_FILE" ]]; then
        printf '%b\n' "$report" > "$OUTPUT_FILE"
        health_log_info "Report saved to: $OUTPUT_FILE"
    else
        printf '%b\n' "$report"
    fi
}

generate_json_report() {
    local json_report="{"
    json_report+="\"timestamp\": \"$(date -Iseconds)\","
    json_report+="\"overall_status\": \"$(_json_escape "$OVERALL_STATUS")\","
    json_report+="\"auto_recovery_enabled\": $AUTO_RECOVER,"
    json_report+="\"components\": {"

    local first=true
    for component in "${!HEALTH_RESULTS[@]}"; do
        [[ "$first" == "true" ]] && first=false || json_report+=","
        local comp_status
        local comp_details
        comp_status="$(_json_escape "${HEALTH_RESULTS[$component]}")"
        comp_details="$(_json_escape "${HEALTH_DETAILS[$component]:-}")"
        json_report+="\"$(_json_escape "$component")\": {"
        json_report+="\"status\": \"${comp_status}\","
        json_report+="\"details\": \"${comp_details}\""
        json_report+="}"
    done

    json_report+="},"
    json_report+="\"issues\": ["
    first=true
    for issue in "${ISSUES_FOUND[@]}"; do
        [[ "$first" == "true" ]] && first=false || json_report+=","
        json_report+="\"$(_json_escape "$issue")\""
    done
    json_report+="]"
    json_report+="}"

    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "$json_report" > "$OUTPUT_FILE"
        health_log_info "JSON report saved to: $OUTPUT_FILE"
    else
        echo "$json_report"
    fi
}

_load_email_secrets_from_sops() {
    [[ "$SEND_EMAIL" != "true" ]] && return 0

    local secrets_file="${SECRETS_FILE:-$SCRIPT_DIR/secrets/secrets.yaml}"
    if [[ ! -f "$secrets_file" ]]; then
        log_warn "_load_email_secrets_from_sops: secrets file not found: $secrets_file"
        return 0
    fi

    local provider="${EMAIL_PROVIDER:-smtp}"

    local _already_have_smtp=false
    local _already_have_api=false
    [[ -n "${SMTP_PASSWORD:-}"    ]] && _already_have_smtp=true
    [[ -n "${EMAIL_API_TOKEN:-}"  ]] && _already_have_api=true
    if [[ "$_already_have_smtp" == "true" && "$_already_have_api" == "true" ]]; then
        log_debug "_load_email_secrets_from_sops: all credentials already set; skipping SOPS"
        return 0
    fi

    if ! ensure_sops_env; then
        log_warn "_load_email_secrets_from_sops: SOPS environment setup failed"
        return 0
    fi

    if [[ "$_already_have_smtp" == "false" ]]; then
        local smtp_pw
        if smtp_pw=$(decrypt_secret "smtp_password" "$secrets_file" 2>/dev/null) \
           && [[ -n "$smtp_pw" ]] \
           && [[ "$smtp_pw" != CHANGE_ME* ]]; then
            export SMTP_PASSWORD="$smtp_pw"
            log_debug "_load_email_secrets_from_sops: SMTP_PASSWORD loaded from SOPS"
        else
            log_warn "_load_email_secrets_from_sops: smtp_password not found or is a placeholder"
        fi
    fi

    if [[ "$_already_have_api" == "false" ]] \
       && [[ "$provider" != "smtp" && "$provider" != "host" ]]; then
        local _provider_key="${provider^^}_API_TOKEN"
        local api_token=""

        if api_token=$(decrypt_secret "$_provider_key" "$secrets_file" 2>/dev/null) \
           && [[ -n "$api_token" ]] \
           && [[ "$api_token" != CHANGE_ME* ]] \
           && [[ "$api_token" != NOT_USED* ]]; then
            export EMAIL_API_TOKEN="${api_token}"
            log_debug "_load_email_secrets_from_sops: EMAIL_API_TOKEN loaded from SOPS key '${_provider_key}'"
        elif api_token=$(decrypt_secret "email_api_token" "$secrets_file" 2>/dev/null) \
           && [[ -n "$api_token" ]] \
           && [[ "$api_token" != CHANGE_ME* ]] \
           && [[ "$api_token" != NOT_USED* ]]; then
            export EMAIL_API_TOKEN="${api_token}"
            log_debug "_load_email_secrets_from_sops: EMAIL_API_TOKEN loaded from SOPS key 'email_api_token' (generic fallback)"
        else
            log_warn "_load_email_secrets_from_sops: no API token found for provider '${provider}' in secrets.yaml — run: ./edit-secrets.sh --rotate email_api_token"
        fi
    fi

    cleanup_secrets_environment 2>/dev/null || true
}

main() {
    require_root "$@"

    load_env_file 2>/dev/null || true

    _load_email_secrets_from_sops

    health_log_info "VaultWarden-OCI Health Monitor - Set-and-Forget Edition"
    [[ "$AUTO_RECOVER" == "true" ]] && health_log_info "🔧 Auto-recovery enabled"
    [[ "$COMPREHENSIVE" == "true" ]] && health_log_info "Running comprehensive health checks..." || \
        health_log_info "Running basic health checks..."

    set +e

    run_check "containers"          check_container_status
    run_check "accessibility"       check_service_accessibility
    run_check "disk_space"          check_disk_space
    run_check "ssl_certificates"    check_ssl_certificates
    run_check "database_growth"     check_database_growth
    run_check "backup_status"       check_backup_status
    run_check "email_notifications" test_email_notifications

    if [[ "$COMPREHENSIVE" == "true" ]]; then
        run_check "resources"      check_resource_usage
        run_check "configuration"  check_configuration
        run_check "security"       check_security_status
    fi

    generate_report

    # BUG-EM1 FIX: the critical alert email body previously used \n escape
    # sequences inside a double-quoted string passed directly to
    # send_notification_email().  Bash does NOT expand \n in double quotes —
    # they arrive at the function as literal backslash-n characters, which the
    # email library passes verbatim (showing \n or \n\ in the rendered email
    # body depending on how the provider's JSON payload is assembled).
    #
    # Fix: build the body with printf into a local variable first.  printf
    # expands \n to real newline (0x0A) characters before the string is
    # assigned, so send_notification_email receives a properly-formatted
    # multi-line body regardless of how it encodes the payload.
    if [[ "$SEND_EMAIL" == "true" ]] && [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
        local issue_list issue_summary email_body recovery_status
        issue_list=$(printf '%s\n' "${CRITICAL_ISSUES[@]}")
        issue_summary=$(printf '%s' "$issue_list")
        recovery_status=$([[ "$AUTO_RECOVER" == "true" ]] && echo "Enabled (attempted)" || echo "Disabled")
        email_body=$(printf 'The following critical issues were found:\n\n%s\n\nAuto-Recovery: %s\n\nPlease investigate and resolve these issues immediately.' \
            "$issue_summary" "$recovery_status")
        send_notification_email "CRITICAL: VaultWarden Health Check Issues" "$email_body"
    fi

    if [[ "$OVERALL_STATUS" == "healthy" ]]; then
        [[ "$QUIET" == "false" ]] && health_log_success "All health checks passed"
        exit 0
    else
        [[ "$QUIET" == "false" ]] && health_log_error "Health check failures detected"
        exit 1
    fi
}

main "$@"
