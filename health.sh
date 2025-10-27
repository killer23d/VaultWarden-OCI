#!/usr/bin/env bash
# health.sh - Simplified VaultWarden health monitoring with library integration
# Uses centralized library functions

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"

# --- Configuration ---
COMPREHENSIVE=false
AUTO_HEAL=false
QUIET=false
# --- START P2: Add email flag ---
EMAIL_ALERT=false
# --- END P2 ---

# --- Health Tracking ---
WARNINGS=0
ERRORS=0
ERROR_DETAILS=""

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Health Check

USAGE:
    ./health.sh [OPTIONS]

OPTIONS:
    --comprehensive  Run extended health checks
    --auto-heal      Automatically attempt to fix issues
    --email-alert    Send email notification if errors are found
    --quiet          Only show warnings and errors
    --help           Show this help

EXAMPLES:
    ./health.sh                    # Basic health check
    ./health.sh --comprehensive    # Full system health check
    ./health.sh --auto-heal        # Check health and auto-repair
    ./health.sh --email-alert      # Check and send email on failure
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --comprehensive) COMPREHENSIVE=true; shift ;;
        --auto-heal) AUTO_HEAL=true; shift ;;
        # --- START P2: Parse email flag ---
        --email-alert) EMAIL_ALERT=true; shift ;;
        # --- END P2 ---
        --quiet) QUIET=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Health Check Functions ---
check_pass() {
    [[ "$QUIET" != "true" ]] && log_success "✅ $*"
}

check_warn() {
    log_warn "⚠️  $*"
    ((WARNINGS++))
}

check_fail() {
    log_error "❌ $*"
    ((ERRORS++))
    ERROR_DETAILS+="- $*\n"
}

# --- Core Health Checks ---
check_docker_health() {
    [[ "$QUIET" != "true" ]] && log_info "Checking Docker health..."

    if ! check_docker_available; then
        check_fail "Docker daemon not accessible"
        return 1
    fi
    check_pass "Docker daemon accessible"

    if ! check_compose_available; then
        check_fail "Docker Compose not available"
        return 1
    fi
    check_pass "Docker Compose available"

    return 0
}

check_container_health() {
    [[ "$QUIET" != "true" ]] && log_info "Checking container health..."

    local services=("vaultwarden" "caddy" "fail2ban" "ddclient")
    local unhealthy_services=()
    local stopped_services=()

    for service in "${services[@]}"; do
        local status health
        status=$(get_service_status "$service")
        health=$(get_service_health "$service")

        case "$status" in
            "running")
                if [[ "$health" == "unhealthy" ]]; then
                    unhealthy_services+=("$service")
                    check_fail "$service is running but unhealthy"
                elif [[ "$health" == "starting" ]]; then
                    check_warn "$service is starting up"
                else
                    check_pass "$service is running and healthy"
                fi
                ;;
            "exited"|"dead"|"not_found")
                stopped_services+=("$service")
                check_fail "$service is not running"
                ;;
            *)
                check_warn "$service in unexpected state: $status"
                ;;
        esac
    done

    # Return status based on issues found
    if [[ ${#stopped_services[@]} -gt 0 ]]; then
        return 2  # Critical - services stopped
    elif [[ ${#unhealthy_services[@]} -gt 0 ]]; then
        return 1  # Warning - services unhealthy
    else
        return 0  # All good
    fi
}

check_system_resources() {
    [[ "$QUIET" != "true" ]] && log_info "Checking system resources..."

    # Memory usage
    if has_command free; then
        local mem_percent
        mem_percent=$(free | awk '/^Mem:/ {printf "%.0f", ($3/$2)*100}')

        if [[ "$mem_percent" -lt 85 ]]; then
            check_pass "Memory usage: ${mem_percent}%"
        elif [[ "$mem_percent" -lt 95 ]]; then
            check_warn "Memory usage high: ${mem_percent}%"
        else
            check_fail "Memory usage critical: ${mem_percent}%"
        fi
    fi

    # Disk usage
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    if [[ -d "$state_dir" ]]; then
        local disk_percent
        disk_percent=$(df -h "$state_dir" | awk 'NR==2{print $5}' | sed 's/%//')

        if [[ "$disk_percent" -lt 85 ]]; then
            check_pass "Disk usage: ${disk_percent}%"
        elif [[ "$disk_percent" -lt 95 ]]; then
            check_warn "Disk usage high: ${disk_percent}%"
        else
            check_fail "Disk usage critical: ${disk_percent}%"
        fi
    fi

    return 0
}

# --- START User Suggestion: Backup Disk Space Check ---
check_backup_space() {
    [[ "$QUIET" != "true" ]] && log_info "Checking backup disk space..."
    
    local backup_dir="$PROJECT_ROOT/backups"
    if [[ ! -d "$backup_dir" ]]; then
        check_warn "Backup directory not found, skipping space check."
        return
    fi
    
    local backup_usage
    backup_usage=$(df "$backup_dir" | awk 'NR==2{print $5}' | sed 's/%//')
    
    if [[ "$backup_usage" -lt 85 ]]; then
        check_pass "Backup disk usage: ${backup_usage}%"
    elif [[ "$backup_usage" -lt 95 ]]; then
        check_warn "Backup disk usage high: ${backup_usage}%"
    else
        check_fail "Backup disk usage critical: ${backup_usage}%"
    fi
}
# --- END User Suggestion ---

check_network_health() {
    [[ "$QUIET" != "true" ]] && log_info "Checking network connectivity..."

    # Internet connectivity
    if test_connectivity; then
        check_pass "Internet connectivity working"
    else
        check_fail "No internet connectivity"
        return 1
    fi

    # Domain connectivity (if configured)
    local domain
    domain=$(get_config_value "DOMAIN" "")
    if [[ -n "$domain" ]]; then
        local clean_domain
        clean_domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')

        # DNS resolution
        if has_command getent && getent hosts "$clean_domain" >/dev/null 2>&1; then
            check_pass "DNS resolution for $clean_domain"
        else
            check_fail "DNS resolution failed for $clean_domain"
            return 1
        fi

        # HTTPS connectivity
        if test_http "https://$clean_domain" 10; then
            check_pass "HTTPS connectivity to $clean_domain"
        else
            check_warn "HTTPS connectivity failed to $clean_domain"
        fi
    fi

    return 0
}

check_backup_health() {
    [[ "$QUIET" != "true" ]] && log_info "Checking backup health..."

    local backup_dir="$PROJECT_ROOT/backups"

    if [[ ! -d "$backup_dir" ]]; then
        check_warn "Backup directory not found: $backup_dir"
        return 1
    fi

    # Check for recent backups
    local recent_backups
    recent_backups=$(find "$backup_dir" -name "*.age" -mtime -7 2>/dev/null | wc -l)

    if [[ "$recent_backups" -gt 0 ]]; then
        check_pass "Found $recent_backups recent backup(s)"
    else
        check_warn "No recent backups found (last 7 days)"
    fi

    return 0
}

check_secrets_health() {
    [[ "$QUIET" != "true" ]] && log_info "Checking secrets health..."

    # Check Age key
    if check_age_key; then
        check_pass "Age encryption key accessible and secure"
    else
        check_fail "Age encryption key missing or insecure"
        return 1
    fi

    # Check secrets file
    if [[ -f "secrets/secrets.yaml" ]]; then
        if is_sops_encrypted "secrets/secrets.yaml"; then
            check_pass "Secrets file encrypted with SOPS"

            # Test decryption
            if get_secret "admin_token" >/dev/null 2>&1; then
                check_pass "Secrets decryption working"
            else
                check_fail "Cannot decrypt secrets file"
                return 1
            fi
        else
            check_fail "Secrets file exists but not encrypted"
            return 1
        fi
    else
        check_warn "Secrets file not found"
    fi

    return 0
}

# --- Auto-Healing Functions ---
auto_heal_containers() {
    log_info "Attempting to heal container issues..."

    # Get list of services that need healing
    local services=("vaultwarden" "caddy" "fail2ban" "ddclient")
    local services_to_heal=()

    for service in "${services[@]}"; do
        if ! is_service_healthy "$service"; then
            services_to_heal+=("$service")
        fi
    done

    if [[ ${#services_to_heal[@]} -gt 0 ]]; then
        log_info "Healing services: ${services_to_heal[*]}"

        # Try restart first
        if restart_services "${services_to_heal[@]}"; then
            log_success "Services restarted successfully"
            sleep 10  # Wait for services to initialize

            # Check if healing worked
            local still_unhealthy=()
            for service in "${services_to_heal[@]}"; do
                if ! wait_for_service_ready "$service" 30; then
                    still_unhealthy+=("$service")
                fi
            done

            if [[ ${#still_unhealthy[@]} -eq 0 ]]; then
                return 0
            else
                log_warn "Restart failed for: ${still_unhealthy[*]}, trying recreate..."

                # If restart failed, try full recreate
                if recreate_services "${still_unhealthy[@]}"; then
                    log_success "Services recreated successfully"
                    sleep 15  # Longer wait after recreate
                    return 0
                else
                    log_error "Auto-healing failed"
                    return 1
                fi
            fi
        else
            log_error "Failed to restart services"
            return 1
        fi
    else
        log_info "No container healing needed"
        return 0
    fi
}

# --- Main Health Check ---
run_health_checks() {
    log_info "Running VaultWarden health checks..."
    echo ""

    # Load configuration
    load_env_file 2>/dev/null || log_warn "No .env file found, using defaults"

    # Core checks
    check_docker_health || return 1
    local container_status=0
    check_container_health || container_status=$?

    # Extended checks if requested
    if [[ "$COMPREHENSIVE" == "true" ]]; then
        check_system_resources
        check_network_health
        check_backup_health
        check_secrets_health
        check_backup_space # User Suggestion
    fi

    # Auto-heal if requested and issues found
    if [[ "$AUTO_HEAL" == "true" && "$container_status" -gt 0 ]]; then
        echo ""
        auto_heal_containers
        echo ""

        # Re-check container health after healing
        log_info "Re-checking container health after auto-heal..."
        check_container_health || container_status=$?
    fi

    return "$container_status"
}

# --- Main Execution ---
main() {
    local exit_code=0

    run_health_checks || exit_code=$?

    echo ""
    echo "Health Check Summary:"
    echo "  Warnings: $WARNINGS"
    echo "  Errors: $ERRORS"

    if [[ "$ERRORS" -eq 0 ]]; then
        if [[ "$WARNINGS" -eq 0 ]]; then
            log_success "All health checks passed ✅"
        else
            log_warn "Health check completed with $WARNINGS warning(s) ⚠️"
        fi
    else
        log_error "Health check failed with $ERRORS error(s) ❌"
        echo ""
        echo "Common fixes:"
        echo "  - Run: ./startup.sh --force-restart"
        echo "  - Check logs: docker compose logs <service>"
        echo "  - Restart system: sudo systemctl restart docker"
        
        # --- START P2: Send Email Alert ---
        if [[ "$EMAIL_ALERT" == "true" ]]; then
            log_info "Sending failure alert email..."
            local email_subject="HEALTH CHECK FAILED"
            local email_body="VaultWarden health check detected $ERRORS error(s).

Errors:
$ERROR_DETAILS
Please review the system."
            send_notification_email "$email_subject" "$email_body"
        fi
        # --- END P2 ---
    fi

    exit "$exit_code"
}

main "$@"
