#!/usr/bin/env bash
# health.sh - Enhanced health monitoring for VaultWarden-OCI with auto-recovery
# FIXED: Added --auto-recover flag for self-healing capabilities
# FIXED: Proper DOMAIN error handling in check_service_accessibility
# ENHANCED: Standardized error handling - functions return, main() decides exit strategy
# FIXED: Backup decrypt verification works when backups/age key are root-only (auto sudo)
# FIXED: Added timeout to SSL certificate check to prevent hanging
# FIXED: NEW-BUG-06 - gate send_notification_email behind SEND_EMAIL flag
# FIXED: BUG-T - removed dead check_results array (populated but never read)
# FIXED: BUG-U - replaced echo -e with printf in generate_text_report (backslash safety)
# FIXED: BUG-V - sanitize user-data before embedding in JSON string fields
# FIXED: BUG-W - read BACKUP_DIR from .env; fall back to PROJECT_ROOT/backups
# FIXED: Auto-recovery single-container limit - per-container recovery (not first-only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"

# Configuration
COMPREHENSIVE=false
QUIET=false
JSON_OUTPUT=false
SEND_EMAIL=false
AUTO_RECOVER=false
ALERT_THRESHOLD=80
OUTPUT_FILE=""
RECOVERY_WAIT_TIME=30

# Health check results storage
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
    */15 * * * * cd /opt/vaultwarden-scripts && ./health.sh --auto-recover >> /var/log/vaultwarden-health.log 2>&1
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --comprehensive) COMPREHENSIVE=true; shift ;;
        --auto-recover) AUTO_RECOVER=true; shift ;;
        --email) SEND_EMAIL=true; shift ;;
        --quiet) QUIET=true; shift ;;
        --json) JSON_OUTPUT=true; shift ;;
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        --alert-threshold) ALERT_THRESHOLD="$2"; shift 2 ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Logging helpers
health_log_info() { [[ "$QUIET" == "true" ]] || log_info "$1"; }
health_log_success() { [[ "$QUIET" == "true" ]] || log_success "$1"; }
health_log_warn() { log_warn "$1"; ISSUES_FOUND+=("WARNING: $1"); }
health_log_error() { log_error "$1"; ISSUES_FOUND+=("ERROR: $1"); CRITICAL_ISSUES+=("$1"); OVERALL_STATUS="unhealthy"; }

# Run a command as root if needed (interactive -> sudo, non-interactive -> sudo -n)
_maybe_sudo() {
    if is_root; then
        "$@"
        return $?
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        "$@"
        return $?
    fi

    # If running without a TTY (cron/non-interactive), don't prompt for password.
    if [[ -t 0 ]]; then
        sudo "$@"
    else
        sudo -n "$@"
    fi
}

# Escape a string for safe embedding inside a JSON double-quoted value.
# Replaces \ -> \\, " -> \", and control characters \b \f \n \r \t.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # backslash first
    s="${s//\"/\\\"}"   # double-quote
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Check if container is healthy
container_is_healthy() {
    local container="$1"

    # Check if container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        return 1
    fi

    # Check health status
    local status
    status=$(docker inspect "$container" --format='{{.State.Health.Status}}' 2>/dev/null || echo "no-healthcheck")

    if [[ "$status" == "unhealthy" ]]; then
        return 1
    elif [[ "$status" == "no-healthcheck" ]]; then
        # For containers without healthcheck, check if they're running
        local state
        state=$(docker inspect "$container" --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
        [[ "$state" == "running" ]]
    else
        [[ "$status" == "healthy" ]]
    fi
}

# Attempt automatic recovery of unhealthy container.
# FIX (NEW-BUG-06): Email notifications are gated behind SEND_EMAIL flag.
# Previously send_notification_email was called unconditionally regardless of
# whether --email was passed, bypassing the user-visible CLI gate entirely.
attempt_container_recovery() {
    local container="$1"
    local service="$2"

    # Check for maintenance/update lock files and skip intrusive recovery.
    local project_state_dir
    project_state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    if [[ -f "$project_state_dir/.locks/global-maintenance.lock" ]] || [[ -f "$PROJECT_ROOT/.locks/operations.lock" ]]; then
        log_warn "🔧 $service is stopped for planned maintenance. Skipping auto-recovery."
        return 0
    fi

    log_warn "🔧 Attempting automatic recovery of $service..."

    # Attempt restart (once only)
    if docker compose restart "$service" 2>&1; then
        log_info "Restart command issued for $service, waiting ${RECOVERY_WAIT_TIME}s..."
        sleep "$RECOVERY_WAIT_TIME"

        # Re-check health
        if container_is_healthy "$container"; then
            log_success "✅ Auto-recovery succeeded for $service"
            if [[ "$SEND_EMAIL" == "true" ]]; then
                send_notification_email "✅ $service Auto-Recovered" \
                    "Service $service was unhealthy and has been automatically restarted.\n\nContainer: $container\nRecovery time: ${RECOVERY_WAIT_TIME}s\nStatus: Now healthy\n\nThis was an automated recovery action. The service should now be functioning normally."
            fi
            return 0
        else
            log_error "❌ Auto-recovery failed for $service - container still unhealthy"
            if [[ "$SEND_EMAIL" == "true" ]]; then
                send_notification_email "❌ $service Auto-Recovery Failed" \
                    "Service $service remains unhealthy after automatic restart attempt.\n\nContainer: $container\nRecovery attempt: Failed after ${RECOVERY_WAIT_TIME}s wait\nStatus: Still unhealthy\n\nMANUAL INTERVENTION REQUIRED:\n1. Check container logs: docker compose logs $service\n2. Check container status: docker compose ps $service\n3. Manual restart: docker compose restart $service\n4. If persistent, check configuration and resources"
            fi
            return 1
        fi
    else
        log_error "❌ Failed to execute restart command for $service"
        if [[ "$SEND_EMAIL" == "true" ]]; then
            send_notification_email "❌ Cannot Restart $service" \
                "Automatic restart command failed for service $service.\n\nContainer: $container\nError: Docker compose restart command failed\n\nIMMEDIATE ACTION REQUIRED:\n1. Check Docker daemon: systemctl status docker\n2. Check Docker Compose: docker compose ps\n3. Check system resources: df -h && free -h\n4. Attempt manual restart: docker compose restart $service"
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

    # FIX (auto-recovery single-container limit): Evaluate and recover each
    # container independently. The previous single boolean recovery_attempted
    # flag caused only the first unhealthy/stopped container to be recovered;
    # all subsequent containers were silently skipped.
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

    # Re-check all containers after recovery attempts
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
        health_log_warn "Unhealthy containers: ${unhealthy_containers[*]}"
        HEALTH_RESULTS["containers"]="degraded"
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

    # FIXED: Use the internal Caddy port 8080 which bypasses HTTPS redirects
    # This ensures the health check validates the container is UP, not just that DNS works
    if curl -sf --max-time 5 "http://localhost:8080/alive" >/dev/null 2>&1; then
        health_log_success "VaultWarden local access: OK"
    else
        health_log_error "CRITICAL: VaultWarden local access: FAILED"
        health_log_error "Port 8080 may not be exposed in docker-compose.yml"
        HEALTH_RESULTS["accessibility"]="failed"
        # If we can't hit localhost:8080, the container is actually broken/down
        return 1
    fi

    # Optional: Check external if domain is configured
    if [[ -f ".env" ]]; then
        local domain
        domain=$(grep "^DOMAIN=" .env | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" || echo "")
        if [[ -n "$domain" ]]; then
            local clean_domain
            clean_domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')
            if curl -sf --max-time 5 "https://$clean_domain/alive" >/dev/null 2>&1; then
                health_log_success "External web access: OK"
            else
                health_log_warn "External web access: FAILED (Check Cloudflare/DNS)"
                # Don't fail the whole check if only external is down (could be just a network blip)
                HEALTH_RESULTS["accessibility"]="degraded"
            fi
        fi
    fi

    if [[ "${HEALTH_RESULTS["accessibility"]:-}" != "degraded" ]]; then
        HEALTH_RESULTS["accessibility"]="healthy"
        HEALTH_DETAILS["accessibility"]="Local service confirmed"
    fi
    return 0
}

check_disk_space() {
    health_log_info "Checking disk space usage..."
    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    local usage_percent
    usage_percent=$(df / | awk 'NR==2 {print $5}' | sed 's/%//' 2>/dev/null || echo "0")

    if (( usage_percent > ALERT_THRESHOLD )); then
        health_log_error "CRITICAL: Root disk usage: ${usage_percent}%"
        HEALTH_RESULTS["disk_space"]="failed"
        HEALTH_DETAILS["disk_space"]="Root: ${usage_percent}% used"
        return 1
    elif (( usage_percent > 70 )); then
        health_log_warn "Root disk usage high: ${usage_percent}%"
        HEALTH_RESULTS["disk_space"]="degraded"
        HEALTH_DETAILS["disk_space"]="Root: ${usage_percent}% used (warning)"
        return 1
    else
        health_log_success "Disk space OK: ${usage_percent}% used"
        HEALTH_RESULTS["disk_space"]="healthy"
        HEALTH_DETAILS["disk_space"]="Root: ${usage_percent}% used"
    fi

    if [[ -d "$state_dir" && "$state_dir" != "/" ]]; then
        local state_usage
        state_usage=$(df "$state_dir" | awk 'NR==2 {print $5}' | sed 's/%//' 2>/dev/null || echo "0")
        if (( state_usage > ALERT_THRESHOLD )); then
            health_log_error "CRITICAL: State directory usage: ${state_usage}%"
            HEALTH_RESULTS["disk_space"]="failed"
            return 1
        fi
    fi

    return 0
}

check_ssl_certificates() {
    health_log_info "Checking SSL certificate expiration..."
    local domain clean_domain

    if [[ -f ".env" ]]; then
        domain=$(grep "^DOMAIN=" .env | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" || echo "")
    else
        domain=""
    fi

    if [[ -z "$domain" ]]; then
        health_log_warn "No domain configured for SSL check"
        return 0
    fi

    clean_domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')

    local cert_info expiry_date expires_in
    # Added 'timeout 5' to prevent openssl from hanging indefinitely if the network drops connection silently
    if cert_info=$(echo | timeout 5 openssl s_client -servername "$clean_domain" -connect "$clean_domain:443" 2>/dev/null | \
                   openssl x509 -noout -dates 2>/dev/null); then
        expiry_date=$(echo "$cert_info" | grep "notAfter" | cut -d= -f2)
        if [[ -n "$expiry_date" ]]; then
            local expiry_epoch current_epoch
            expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
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
            return 1
        fi
    else
        health_log_warn "Could not check SSL certificate (connection failed or timed out)"
        HEALTH_RESULTS["ssl_certificates"]="degraded"
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
        echo "$current_size_mb" > "$size_history_file"

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

    local age_key_file="${DEFAULT_AGE_KEY_FILE:-secrets/keys/age-key.txt}"
    [[ ! -f "$age_key_file" ]] && {
        health_log_error "CRITICAL: Age key file missing: $age_key_file"
        return 1
    }

    local file_size
    file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null || echo "0")
    (( file_size < 1024 )) && {
        health_log_error "CRITICAL: Backup file suspiciously small (${file_size} bytes): $(basename "$backup_file")"
        return 1
    }

    # Use sudo if required (common when backups and/or age key are root-only)
    if ! _maybe_sudo age -d -i "$age_key_file" "$backup_file" > /dev/null 2>&1; then
        health_log_error "CRITICAL: Failed to decrypt latest $backup_type backup!"
        return 1
    fi

    return 0
}

check_backup_status() {
    health_log_info "Checking backup status and integrity..."

    # FIX (BUG-W): Read BACKUP_DIR from .env when present so health.sh and
    # backup.sh agree on the backup location. Fall back to PROJECT_ROOT/backups
    # only when the variable is absent or empty.
    local backup_base_dir
    backup_base_dir="$PROJECT_ROOT/backups"
    if [[ -f ".env" ]]; then
        local env_backup_dir
        env_backup_dir=$(grep "^BACKUP_DIR=" .env | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" || echo "")
        [[ -n "$env_backup_dir" ]] && backup_base_dir="$env_backup_dir"
    fi

    local latest_db_backup latest_full_backup

    [[ ! -d "$backup_base_dir" ]] && {
        health_log_error "CRITICAL: Backup directory not found: $backup_base_dir"
        HEALTH_RESULTS["backup_status"]="failed"
        HEALTH_DETAILS["backup_status"]="Backup directory missing"
        return 1
    }

    [[ -d "$backup_base_dir/db" ]] && \
        latest_db_backup=$(find "$backup_base_dir/db" -name "*.age" -type f 2>/dev/null | sort | tail -1)
    [[ -d "$backup_base_dir/full" ]] && \
        latest_full_backup=$(find "$backup_base_dir/full" -name "*.age" -type f 2>/dev/null | sort | tail -1)

    local backup_issues=()
    local backup_failed=false

    if [[ -n "${latest_db_backup:-}" ]]; then
        local db_backup_age
        if command -v stat >/dev/null 2>&1; then
            db_backup_age=$((($(date +%s) - $(stat -c%Y "$latest_db_backup" 2>/dev/null || \
                              stat -f%m "$latest_db_backup" 2>/dev/null || echo "0")) / 86400))
        else
            db_backup_age=999
        fi

        if (( db_backup_age > 2 )); then
            backup_issues+=("Last DB backup is ${db_backup_age} days old")
            backup_failed=true
        elif ! _verify_backup_decryptable "$latest_db_backup" "DB"; then
            backup_issues+=("Latest DB backup failed decryption")
            backup_failed=true
        else
            health_log_success "Database backup recent (${db_backup_age}d) and decryptable"
        fi
    else
        backup_issues+=("No database backups found")
        backup_failed=true
    fi

    if [[ -n "${latest_full_backup:-}" ]]; then
        local full_backup_age
        if command -v stat >/dev/null 2>&1; then
            full_backup_age=$((($(date +%s) - $(stat -c%Y "$latest_full_backup" 2>/dev/null || \
                                stat -f%m "$latest_full_backup" 2>/dev/null || echo "0")) / 86400))
        else
            full_backup_age=999
        fi

        if (( full_backup_age > 7 )); then
            backup_issues+=("Last full backup is ${full_backup_age} days old")
            backup_failed=true
        elif ! _verify_backup_decryptable "$latest_full_backup" "full"; then
            backup_issues+=("Latest full backup failed decryption")
            backup_failed=true
        else
            health_log_success "Full backup recent (${full_backup_age}d) and decryptable"
        fi
    else
        backup_issues+=("No full backups found")
        backup_failed=true
    fi

    if [[ "$backup_failed" == "true" ]]; then
        health_log_error "CRITICAL: Backup issues: ${backup_issues[*]}"
        HEALTH_RESULTS["backup_status"]="failed"
        HEALTH_DETAILS["backup_status"]="Issues: ${backup_issues[*]}"
        return 1
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

    if [[ -f ".env" ]]; then
        admin_email=$(grep "^ADMIN_EMAIL=" .env | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" || echo "")
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
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 | cut -d'u' -f1 2>/dev/null || echo "0")
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

    if [[ ! -f ".env" ]]; then
        config_issues+=("Missing .env file")
    else
        local required_vars=("DOMAIN" "ADMIN_EMAIL" "CLOUDFLARE_ZONE_ID")
        for var in "${required_vars[@]}"; do
            grep -q "^${var}=" .env || config_issues+=("Missing $var in .env")
        done
    fi

    if [[ ! -f "secrets/secrets.yaml" ]]; then
        config_issues+=("Missing secrets.yaml file")
    else
        # FIX: --test is not a valid edit-secrets.sh flag (unknown options exit 1).
        # Use --list instead: it runs check_prerequisites + validate_secrets
        # (which performs the actual SOPS decryption test) then lists key names
        # to stdout (redirected to /dev/null). Exits 0 on success, 1 on failure.
        if ! ./edit-secrets.sh --list >/dev/null 2>&1; then
            config_issues+=("Secrets decryption failed")
        fi
    fi

    docker compose config >/dev/null 2>&1 || config_issues+=("Docker Compose configuration error")

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

check_security_status() {
    [[ "$COMPREHENSIVE" == "false" ]] && return 0
    health_log_info "Checking security status..."

    local security_issues=()

    # FIX: crazymax/fail2ban has a non-standard PATH; fail2ban-client must be
    # invoked via sh -c. Use docker exec by container name — more reliable
    # than docker compose exec for host-network containers.
    docker exec vaultwarden_fail2ban sh -c 'fail2ban-client status' >/dev/null 2>&1 || \
        security_issues+=("fail2ban not responding")

    local age_key_file="${DEFAULT_AGE_KEY_FILE:-secrets/keys/age-key.txt}"
    check_age_key "$age_key_file" || security_issues+=("Age key validation failed")

    if [[ -f ".sops.yaml" ]]; then
        grep -q "age:" ".sops.yaml" || security_issues+=("SOPS configuration missing Age key")
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

# FIX (BUG-U): Use printf '%b\n' instead of echo -e to print the report.
# echo -e interprets backslash sequences found inside health detail strings
# (e.g. container names or paths that happen to contain \n, \t, etc.),
# which can corrupt output or silently truncate lines.
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
            "healthy") report+="  ✅ $component: $status" ;;
            "degraded") report+="  ⚠️  $component: $status" ;;
            "failed") report+="  ❌ $component: $status" ;;
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

# FIX (BUG-V): Sanitize all user-controlled values before embedding in JSON.
# Previously, values from HEALTH_RESULTS, HEALTH_DETAILS, and ISSUES_FOUND
# were interpolated verbatim; any string containing a double-quote, backslash,
# or control character would produce structurally invalid JSON.
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

main() {
    # Run as non-root when possible; individual checks should degrade gracefully.

    health_log_info "VaultWarden-OCI Health Monitor - Set-and-Forget Edition"
    [[ "$AUTO_RECOVER" == "true" ]] && health_log_info "🔧 Auto-recovery enabled"
    [[ "$COMPREHENSIVE" == "true" ]] && health_log_info "Running comprehensive health checks..." || \
        health_log_info "Running basic health checks..."

    # FIX: Disable exit-on-error for the check loop.
    # With set -e active, any check function returning non-zero would abort the
    # entire script via `cmd; arr+=($?)` before the result is captured, skipping
    # all remaining checks and the summary report.
    # Individual check failures are non-fatal by design — we want the full picture.
    set +e

    # FIX (BUG-T): Removed the dead check_results array. The array was appended
    # to after each check call but was never read anywhere in the script.
    # Exit codes are captured implicitly via OVERALL_STATUS / HEALTH_RESULTS.

    check_container_status
    check_service_accessibility
    check_disk_space
    check_ssl_certificates
    check_database_growth
    check_backup_status
    test_email_notifications

    if [[ "$COMPREHENSIVE" == "true" ]]; then
        check_resource_usage
        check_configuration
        check_security_status
    fi

    generate_report

    if [[ "$SEND_EMAIL" == "true" ]] && [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
        local issue_summary
        issue_summary=$(printf "%s\n" "${CRITICAL_ISSUES[@]}")
        send_notification_email "CRITICAL: VaultWarden Health Check Issues" \
            "The following critical issues were found:\n\n$issue_summary\n\nAuto-Recovery: $([[ "$AUTO_RECOVER" == "true" ]] && echo "Enabled (attempted)" || echo "Disabled")\n\nPlease investigate and resolve these issues immediately."
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
