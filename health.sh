#!/usr/bin/env bash
# health.sh - Enhanced health monitoring for VaultWarden-OCI with set-and-forget monitoring
# UPDATED: Added disk space monitoring, SSL expiration, DB growth, backup status, email test

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
ALERT_THRESHOLD=80  # Percentage threshold for alerts
OUTPUT_FILE=""

show_help() {
    cat << 'EOF'
VaultWarden-OCI Health Monitor - Set-and-Forget Edition

USAGE:
    ./health.sh [OPTIONS]

OPTIONS:
    --comprehensive     Run comprehensive health checks
    --email             Send email notification if issues found
    --quiet             Suppress non-error output
    --json              Output results in JSON format
    --output FILE       Save results to file
    --alert-threshold N Set alert threshold percentage (default: 80)
    --help              Show this help

EXAMPLES:
    ./health.sh                           # Basic health check
    ./health.sh --comprehensive           # Full system health check
    ./health.sh --comprehensive --email   # Full check with email alerts
    ./health.sh --json --output health.json  # Save results as JSON

SET-AND-FORGET MONITORING:
    Basic:
    - Container status and health
    - Service accessibility
    - Critical process monitoring

    Comprehensive:
    - Disk space < 80% alert
    - SSL certificate expiration < 30 days
    - Database size growth monitoring
    - Backup success/failure status
    - Email notification functionality test
    - Resource usage monitoring
    - Security status checks
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --comprehensive) COMPREHENSIVE=true; shift ;;
        --email) SEND_EMAIL=true; shift ;;
        --quiet) QUIET=true; shift ;;
        --json) JSON_OUTPUT=true; shift ;;
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        --alert-threshold) ALERT_THRESHOLD="$2"; shift 2 ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Health check results storage
declare -A HEALTH_RESULTS
declare -A HEALTH_DETAILS
OVERALL_STATUS="healthy"
ISSUES_FOUND=()
CRITICAL_ISSUES=()

# Logging functions that respect quiet mode
health_log_info() {
    [[ "$QUIET" == "true" ]] || log_info "$1"
}

health_log_success() {
    [[ "$QUIET" == "true" ]] || log_success "$1"
}

health_log_warn() {
    log_warn "$1"
    ISSUES_FOUND+=("WARNING: $1")
}

health_log_error() {
    log_error "$1"
    ISSUES_FOUND+=("ERROR: $1")
    CRITICAL_ISSUES+=("$1")
    OVERALL_STATUS="unhealthy"
}

# Basic health checks
check_container_status() {
    health_log_info "Checking container status..."

    local containers=("vaultwarden_app" "vaultwarden_caddy" "vaultwarden_fail2ban")
    local unhealthy_containers=()
    local stopped_containers=()

    for container in "${containers[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            local status
            status=$(docker inspect "$container" --format='{{.State.Health.Status}}' 2>/dev/null || echo "no-healthcheck")

            if [[ "$status" == "unhealthy" ]]; then
                unhealthy_containers+=("$container")
            elif [[ "$status" == "no-healthcheck" ]]; then
                # Check if container is running
                local state
                state=$(docker inspect "$container" --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
                if [[ "$state" != "running" ]]; then
                    stopped_containers+=("$container")
                fi
            fi
        else
            stopped_containers+=("$container")
        fi
    done

    if [[ ${#stopped_containers[@]} -gt 0 ]]; then
        health_log_error "Stopped containers: ${stopped_containers[*]}"
        HEALTH_RESULTS["containers"]="failed"
        HEALTH_DETAILS["containers"]="Stopped: ${stopped_containers[*]}"
    elif [[ ${#unhealthy_containers[@]} -gt 0 ]]; then
        health_log_warn "Unhealthy containers: ${unhealthy_containers[*]}"
        HEALTH_RESULTS["containers"]="degraded"
        HEALTH_DETAILS["containers"]="Unhealthy: ${unhealthy_containers[*]}"
    else
        health_log_success "All containers are running and healthy"
        HEALTH_RESULTS["containers"]="healthy"
        HEALTH_DETAILS["containers"]="All containers operational"
    fi
}

check_service_accessibility() {
    health_log_info "Checking service accessibility..."

    # Load domain from .env
    local domain
    domain=$(get_config_value "DOMAIN" "")

    if [[ -z "$domain" ]]; then
        health_log_error "DOMAIN not configured in .env file"
        HEALTH_RESULTS["accessibility"]="failed"
        return 1
    fi

    # Test local VaultWarden access
    if curl -sf "http://localhost/alive" >/dev/null 2>&1; then
        health_log_success "VaultWarden local access: OK"
    else
        health_log_error "VaultWarden local access: FAILED"
        HEALTH_RESULTS["accessibility"]="failed"
        return 1
    fi

    # Test external web access
    local clean_domain
    clean_domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')

    if curl -sf "https://$clean_domain" >/dev/null 2>&1; then
        health_log_success "External web access: OK"
        HEALTH_RESULTS["accessibility"]="healthy"
        HEALTH_DETAILS["accessibility"]="All services accessible"
    else
        health_log_warn "External web access: FAILED (DNS/SSL issue)"
        HEALTH_RESULTS["accessibility"]="degraded"
        HEALTH_DETAILS["accessibility"]="External access issues"
    fi
}

# NEW: Disk space monitoring (set-and-forget requirement)
check_disk_space() {
    health_log_info "Checking disk space usage..."

    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    local usage_percent

    # Check root filesystem
    usage_percent=$(df / | awk 'NR==2 {print $5}' | sed 's/%//' 2>/dev/null || echo "0")

    if (( usage_percent > ALERT_THRESHOLD )); then
        health_log_error "Root disk usage critical: ${usage_percent}%"
        HEALTH_RESULTS["disk_space"]="failed"
        HEALTH_DETAILS["disk_space"]="Root: ${usage_percent}% used"
        return 1
    elif (( usage_percent > 70 )); then
        health_log_warn "Root disk usage high: ${usage_percent}%"
        HEALTH_RESULTS["disk_space"]="degraded"
        HEALTH_DETAILS["disk_space"]="Root: ${usage_percent}% used (warning)"
    else
        health_log_success "Disk space OK: ${usage_percent}% used"
        HEALTH_RESULTS["disk_space"]="healthy"
        HEALTH_DETAILS["disk_space"]="Root: ${usage_percent}% used"
    fi

    # Check project state directory if different
    if [[ -d "$state_dir" ]] && [[ "$state_dir" != "/" ]]; then
        local state_usage
        state_usage=$(df "$state_dir" | awk 'NR==2 {print $5}' | sed 's/%//' 2>/dev/null || echo "0")
        if (( state_usage > ALERT_THRESHOLD )); then
            health_log_error "State directory usage critical: ${state_usage}%"
            HEALTH_RESULTS["disk_space"]="failed"
        fi
    fi
}

# NEW: SSL certificate expiration monitoring
check_ssl_certificates() {
    health_log_info "Checking SSL certificate expiration..."

    local domain
    domain=$(get_config_value "DOMAIN" "")
    if [[ -z "$domain" ]]; then
        health_log_warn "No domain configured for SSL check"
        return 0
    fi

    local clean_domain
    clean_domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')

    # Get certificate expiration info
    local cert_info expires_in
    if cert_info=$(echo | openssl s_client -servername "$clean_domain" -connect "$clean_domain:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null); then
        local expiry_date
        expiry_date=$(echo "$cert_info" | grep "notAfter" | cut -d= -f2)

        if [[ -n "$expiry_date" ]]; then
            local expiry_epoch current_epoch
            expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
            current_epoch=$(date +%s)
            expires_in=$(( (expiry_epoch - current_epoch) / 86400 ))

            if (( expires_in < 7 )); then
                health_log_error "SSL certificate expires in ${expires_in} days"
                HEALTH_RESULTS["ssl_certificates"]="failed"
                HEALTH_DETAILS["ssl_certificates"]="Expires in ${expires_in} days"
            elif (( expires_in < 30 )); then
                health_log_warn "SSL certificate expires in ${expires_in} days"
                HEALTH_RESULTS["ssl_certificates"]="degraded"
                HEALTH_DETAILS["ssl_certificates"]="Expires in ${expires_in} days"
            else
                health_log_success "SSL certificate OK: ${expires_in} days remaining"
                HEALTH_RESULTS["ssl_certificates"]="healthy"
                HEALTH_DETAILS["ssl_certificates"]="${expires_in} days remaining"
            fi
        else
            health_log_warn "Could not parse SSL certificate expiration"
            HEALTH_RESULTS["ssl_certificates"]="degraded"
        fi
    else
        health_log_warn "Could not check SSL certificate (connection failed)"
        HEALTH_RESULTS["ssl_certificates"]="degraded"
    fi
}

# NEW: Database size growth monitoring
check_database_growth() {
    health_log_info "Checking database size and growth..."

    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    local db_path="$state_dir/data/bwdata/db.sqlite3"

    if [[ -f "$db_path" ]]; then
        local current_size_bytes current_size_mb
        current_size_bytes=$(stat -c%s "$db_path" 2>/dev/null || stat -f%z "$db_path" 2>/dev/null || echo "0")
        current_size_mb=$((current_size_bytes / 1024 / 1024))

        # Store size for growth tracking
        local size_history_file="/tmp/.vw_db_size_history"
        local previous_size=0

        if [[ -f "$size_history_file" ]]; then
            previous_size=$(cat "$size_history_file" 2>/dev/null || echo "0")
        fi
        echo "$current_size_mb" > "$size_history_file"

        # Check for rapid growth (more than 10MB increase since last check)
        local growth=$((current_size_mb - previous_size))

        if (( current_size_mb > 500 )); then
            health_log_warn "Database size very large: ${current_size_mb}MB"
            HEALTH_RESULTS["database_growth"]="degraded"
            HEALTH_DETAILS["database_growth"]="Size: ${current_size_mb}MB (large)"
        elif (( growth > 10 )) && (( previous_size > 0 )); then
            health_log_warn "Database grew rapidly: +${growth}MB (now ${current_size_mb}MB)"
            HEALTH_RESULTS["database_growth"]="degraded"
            HEALTH_DETAILS["database_growth"]="Rapid growth: +${growth}MB"
        else
            health_log_success "Database size OK: ${current_size_mb}MB"
            HEALTH_RESULTS["database_growth"]="healthy"
            HEALTH_DETAILS["database_growth"]="Size: ${current_size_mb}MB"
        fi
    else
        health_log_warn "Database file not found: $db_path"
        HEALTH_RESULTS["database_growth"]="degraded"
        HEALTH_DETAILS["database_growth"]="Database file not found"
    fi
}

# NEW: Backup success/failure status monitoring
check_backup_status() {
    health_log_info "Checking backup status..."

    local backup_base_dir="$PROJECT_ROOT/backups"
    local latest_db_backup latest_full_backup

    # Find latest database backup
    if [[ -d "$backup_base_dir/db" ]]; then
        latest_db_backup=$(find "$backup_base_dir/db" -name "*.age" -type f 2>/dev/null | sort | tail -1)
    fi

    # Find latest full backup
    if [[ -d "$backup_base_dir/full" ]]; then
        latest_full_backup=$(find "$backup_base_dir/full" -name "*.age" -type f 2>/dev/null | sort | tail -1)
    fi

    local backup_issues=()

    # Check database backup age
    if [[ -n "$latest_db_backup" ]]; then
        local db_backup_age=$((($(date +%s) - $(stat -c%Y "$latest_db_backup" 2>/dev/null || stat -f%m "$latest_db_backup" 2>/dev/null || echo "0")) / 86400))
        if (( db_backup_age > 2 )); then
            backup_issues+=("Last database backup is ${db_backup_age} days old")
        else
            health_log_success "Database backup recent: ${db_backup_age} days old"
        fi
    else
        backup_issues+=("No database backups found")
    fi

    # Check full backup age (should be within 7 days)
    if [[ -n "$latest_full_backup" ]]; then
        local full_backup_age=$((($(date +%s) - $(stat -c%Y "$latest_full_backup" 2>/dev/null || stat -f%m "$latest_full_backup" 2>/dev/null || echo "0")) / 86400))
        if (( full_backup_age > 7 )); then
            backup_issues+=("Last full backup is ${full_backup_age} days old")
        fi
    else
        backup_issues+=("No full backups found")
    fi

    if [[ ${#backup_issues[@]} -gt 0 ]]; then
        health_log_error "Backup issues: ${backup_issues[*]}"
        HEALTH_RESULTS["backup_status"]="failed"
        HEALTH_DETAILS["backup_status"]="Issues: ${backup_issues[*]}"
    else
        health_log_success "Backup status OK"
        HEALTH_RESULTS["backup_status"]="healthy"
        HEALTH_DETAILS["backup_status"]="Recent backups available"
    fi
}

# NEW: Email notification functionality test
test_email_notifications() {
    health_log_info "Testing email notification functionality..."

    local admin_email
    admin_email=$(get_config_value "ADMIN_EMAIL" "")

    if [[ -z "$admin_email" ]]; then
        health_log_warn "ADMIN_EMAIL not configured - email notifications disabled"
        HEALTH_RESULTS["email_notifications"]="degraded"
        HEALTH_DETAILS["email_notifications"]="No admin email configured"
        return 0
    fi

    if ! has_command mail; then
        health_log_warn "mail command not available - email notifications disabled"
        HEALTH_RESULTS["email_notifications"]="degraded"
        HEALTH_DETAILS["email_notifications"]="mail command not available"
        return 0
    fi

    # Test email functionality (don't actually send during health check unless requested)
    if [[ "$SEND_EMAIL" == "true" ]]; then
        if send_notification_email "Health Check Test" "Email notifications are working correctly."; then
            health_log_success "Email notifications working"
            HEALTH_RESULTS["email_notifications"]="healthy"
            HEALTH_DETAILS["email_notifications"]="Test email sent successfully"
        else
            health_log_error "Email notification test failed"
            HEALTH_RESULTS["email_notifications"]="failed"
            HEALTH_DETAILS["email_notifications"]="Test email failed"
        fi
    else
        # Just verify the components are available
        health_log_success "Email notifications configured (use --email to test)"
        HEALTH_RESULTS["email_notifications"]="healthy"
        HEALTH_DETAILS["email_notifications"]="Configured but not tested"
    fi
}

check_resource_usage() {
    [[ "$COMPREHENSIVE" == "false" ]] && return 0

    health_log_info "Checking resource usage..."

    # CPU usage
    local cpu_usage
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 | cut -d'u' -f1 2>/dev/null || echo "0")

    # Memory usage
    local mem_usage
    mem_usage=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100.0}' 2>/dev/null || echo "0")

    local resource_issues=()

    if (( $(echo "$cpu_usage > $ALERT_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
        resource_issues+=("CPU: ${cpu_usage}%")
    fi

    if (( mem_usage > ALERT_THRESHOLD )); then
        resource_issues+=("Memory: ${mem_usage}%")
    fi

    if [[ ${#resource_issues[@]} -gt 0 ]]; then
        health_log_warn "High resource usage: ${resource_issues[*]}"
        HEALTH_RESULTS["resources"]="degraded"
        HEALTH_DETAILS["resources"]="High usage: ${resource_issues[*]}"
    else
        health_log_success "Resource usage within normal limits"
        HEALTH_RESULTS["resources"]="healthy"
        HEALTH_DETAILS["resources"]="CPU: ${cpu_usage}%, Memory: ${mem_usage}%"
    fi
}

check_configuration() {
    [[ "$COMPREHENSIVE" == "false" ]] && return 0

    health_log_info "Checking configuration..."

    local config_issues=()

    # Check .env file
    if [[ ! -f ".env" ]]; then
        config_issues+=("Missing .env file")
    else
        # Check required variables
        local required_vars=("DOMAIN" "ADMIN_EMAIL" "CLOUDFLARE_ZONE_ID")
        for var in "${required_vars[@]}"; do
            if ! grep -q "^${var}=" .env; then
                config_issues+=("Missing $var in .env")
            fi
        done
    fi

    # Check secrets file
    if [[ ! -f "secrets/secrets.yaml" ]]; then
        config_issues+=("Missing secrets.yaml file")
    elif ! ./edit-secrets.sh --test >/dev/null 2>&1; then
        config_issues+=("Secrets decryption failed")
    fi

    # Check Docker Compose syntax
    if ! docker compose config >/dev/null 2>&1; then
        config_issues+=("Docker Compose configuration error")
    fi

    if [[ ${#config_issues[@]} -gt 0 ]]; then
        health_log_error "Configuration issues: ${config_issues[*]}"
        HEALTH_RESULTS["configuration"]="failed"
        HEALTH_DETAILS["configuration"]="Issues: ${config_issues[*]}"
    else
        health_log_success "Configuration validation passed"
        HEALTH_RESULTS["configuration"]="healthy"
        HEALTH_DETAILS["configuration"]="All configurations valid"
    fi
}

check_security_status() {
    [[ "$COMPREHENSIVE" == "false" ]] && return 0

    health_log_info "Checking security status..."

    local security_issues=()

    # Check file permissions on secrets
    if [[ -d "secrets/.docker_secrets" ]]; then
        local bad_perms
        bad_perms=$(find secrets/.docker_secrets -type f ! -perm 600 2>/dev/null | wc -l)
        if (( bad_perms > 0 )); then
            security_issues+=("$bad_perms secret files with incorrect permissions")
        fi
    fi

    # Check if fail2ban is active
    if ! docker compose exec -T fail2ban fail2ban-client status >/dev/null 2>&1; then
        security_issues+=("fail2ban not responding")
    fi

    # Check Age key permissions
    if [[ -f "secrets/keys/age-key.txt" ]]; then
        local age_perms
        age_perms=$(stat -c "%a" "secrets/keys/age-key.txt" 2>/dev/null || echo "000")
        if [[ "$age_perms" != "600" ]]; then
            security_issues+=("Age key has incorrect permissions: $age_perms")
        fi
    fi

    if [[ ${#security_issues[@]} -gt 0 ]]; then
        health_log_warn "Security issues found: ${security_issues[*]}"
        HEALTH_RESULTS["security"]="degraded"
        HEALTH_DETAILS["security"]="Issues: ${security_issues[*]}"
    else
        health_log_success "Security status good"
        HEALTH_RESULTS["security"]="healthy"
        HEALTH_DETAILS["security"]="All security checks passed"
    fi
}

generate_report() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        generate_json_report
    else
        generate_text_report
    fi
}

generate_text_report() {
    local report=""
    report+="VaultWarden-OCI Health Report - Set-and-Forget Edition\n"
    report+="Generated: $(date)\n"
    report+="Overall Status: $OVERALL_STATUS\n\n"

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
        echo -e "$report" > "$OUTPUT_FILE"
        health_log_info "Report saved to: $OUTPUT_FILE"
    else
        echo -e "$report"
    fi
}

generate_json_report() {
    local json_report="{"
    json_report+=""timestamp": "$(date -Iseconds)","
    json_report+=""overall_status": "$OVERALL_STATUS","
    json_report+=""components": {"

    local first=true
    for component in "${!HEALTH_RESULTS[@]}"; do
        [[ "$first" == "true" ]] && first=false || json_report+=","
        json_report+=""$component": {"
        json_report+=""status": "${HEALTH_RESULTS[$component]}","
        json_report+=""details": "${HEALTH_DETAILS[$component]:-}""
        json_report+="}"
    done

    json_report+="},"
    json_report+=""issues": ["

    first=true
    for issue in "${ISSUES_FOUND[@]}"; do
        [[ "$first" == "true" ]] && first=false || json_report+=","
        json_report+=""$issue""
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
    health_log_info "VaultWarden-OCI Health Monitor - Set-and-Forget Edition"

    if [[ "$COMPREHENSIVE" == "true" ]]; then
        health_log_info "Running comprehensive health checks..."
    else
        health_log_info "Running basic health checks..."
    fi

    # Load environment if available
    load_env_file 2>/dev/null || true

    # Run health checks - NEW checks marked with comments
    check_container_status
    check_service_accessibility
    check_disk_space              # NEW: Disk space < 80%
    check_ssl_certificates         # NEW: SSL certificate expiration < 30 days
    check_database_growth          # NEW: VaultWarden database size growth rate
    check_backup_status           # NEW: Backup success/failure status
    test_email_notifications      # NEW: Email notification functionality

    # Comprehensive checks
    check_resource_usage
    check_configuration
    check_security_status

    # Generate report
    generate_report

    # Send email notification if there are critical issues and email is enabled
    if [[ "$SEND_EMAIL" == "true" ]] && [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
        local issue_summary
        issue_summary=$(printf "%s\n" "${CRITICAL_ISSUES[@]}")
        send_notification_email "VaultWarden Health Check CRITICAL Issues" "The following critical issues were found:\n\n$issue_summary\n\nPlease check your VaultWarden instance immediately."
    fi

    # Exit with appropriate code
    if [[ "$OVERALL_STATUS" == "healthy" ]]; then
        [[ "$QUIET" == "false" ]] && health_log_success "All health checks passed"
        exit 0
    else
        [[ "$QUIET" == "false" ]] && health_log_error "Health check failures detected"
        exit 1
    fi
}

main "$@"
