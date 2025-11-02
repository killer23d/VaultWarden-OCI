#!/usr/bin/env bash
# startup.sh - Enhanced VaultWarden stack orchestration
# ENHANCED: Standardized error handling - functions return, main() decides exit strategy
# All functions return exit codes, main() collects status and determines final exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Enhanced Cleanup Function
cleanup_secrets() {
    local exit_code=${?:-0}
    local cleanup_reason="${1:-exit}"

    if [[ $exit_code -eq 0 && "${STARTUP_SUCCESS:-false}" == "true" ]] || [[ "$cleanup_reason" == "stop" ]]; then
        rm -rf "$PROJECT_ROOT/secrets/.docker_secrets" 2>/dev/null || true
        log_debug "Cleaned up temporary secret files (successful completion)"
    else
        if [[ -d "$PROJECT_ROOT/secrets/.docker_secrets" ]]; then
            log_info "Preserving secret files for debugging (exit code: $exit_code)"
            log_info "  Location: secrets/.docker_secrets/"
            log_info "  Clean up manually with: sudo rm -rf secrets/.docker_secrets/"
        fi
    fi

    rm -rf "$PROJECT_ROOT/secrets/.docker_secrets".* 2>/dev/null || true
}

# STANDARDIZED: Fix secrets ownership - returns exit code
fix_secrets_ownership() {
    local docker_secrets_dir="secrets/.docker_secrets"
    local current_user
    current_user=$(get_real_user)

    if [[ -d "$docker_secrets_dir" ]]; then
        local owner
        owner=$(stat -c '%U' "$docker_secrets_dir" 2>/dev/null || echo "unknown")

        if [[ "$owner" != "$current_user" ]]; then
            log_warn "Fixing ownership of secrets directory (currently owned by $owner)"

            if [[ "$owner" == "root" ]] && [[ "$current_user" != "root" ]]; then
                if sudo chown -R "$current_user:$(id -gn $current_user)" "$docker_secrets_dir" 2>/dev/null; then
                    log_success "Fixed secrets directory ownership"
                    return 0
                else
                    log_warn "Could not fix ownership, recreating directory"
                    sudo rm -rf "$docker_secrets_dir" 2>/dev/null || true
                    return 1
                fi
            fi
        fi
    fi

    return 0
}

# Set trap to pass exit code
trap 'cleanup_secrets "error"' ERR
trap 'cleanup_secrets "interrupt"' HUP INT TERM
trap 'cleanup_secrets "exit"' EXIT

cd "$PROJECT_ROOT"

# Source Libraries
source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"

# Ensure the key file env var is set
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-"$PROJECT_ROOT/secrets/keys/age-key.txt"}"

# Configuration
FORCE_RESTART=false
DRY_RUN=false
SKIP_HEALTH=false
STOP_MODE=false
STRICT_SECRETS=false
STARTUP_SUCCESS=false
UPDATE_DNS=true

show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Startup Script (Modernized)

USAGE:
    ./startup.sh [OPTIONS]

OPTIONS:
    --help              Show this help
    --force-restart     Stop and recreate all containers (REQUIRED after secrets changes)
    --dry-run           Show what would be done without executing
    --skip-health       Skip post-startup health check
    --down              Stop and remove all containers
    --strict-secrets    Fail immediately if critical secrets are missing (production mode)
    --skip-dns          Skip DNS update after starting services

EXAMPLES:
    ./startup.sh                    # Normal startup with DNS update
    ./startup.sh --force-restart    # Force recreate containers (use after edit-secrets.sh)
    ./startup.sh --down             # Stop all services
    ./startup.sh --strict-secrets   # Production startup with strict validation
    ./startup.sh --skip-dns         # Start without DNS update

IMPORTANT:
    After editing secrets (./edit-secrets.sh), always use --force-restart to ensure
    environment variables are properly updated in containers.
EOF
}

# Argument Parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --help) show_help; exit 0 ;;
        --force-restart) FORCE_RESTART=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --skip-health) SKIP_HEALTH=true; shift ;;
        --down) STOP_MODE=true; shift ;;
        --strict-secrets) STRICT_SECRETS=true; shift ;;
        --skip-dns) UPDATE_DNS=false; shift ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# STANDARDIZED: DNS Update Function - returns exit code
update_dns_if_needed() {
    if [[ "$UPDATE_DNS" != "true" ]]; then
        log_info "Skipping DNS update (--skip-dns specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would update DNS record to current IP"
        return 0
    fi

    if [[ -f "./update-dns.sh" ]]; then
        log_info "Updating DNS record to current IP..."
        if ./update-dns.sh; then
            log_success "DNS update completed successfully"
            return 0
        else
            log_warn "DNS update failed."
            log_warn "This is okay if the IP hasn't changed, but check logs if access fails."
            return 1
        fi
    else
        log_debug "update-dns.sh not found, skipping DNS update"
        return 0
    fi
}

# STANDARDIZED: Atomic Docker Secrets Preparation - returns exit code
prepare_docker_secrets() {
    log_info "Preparing Docker secrets with atomic operations..."

    local docker_secrets_dir="secrets/.docker_secrets"
    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)

    # Fix ownership if needed before attempting operations
    if ! fix_secrets_ownership; then
        log_warn "Could not fix secrets ownership, continuing anyway"
    fi

    # Create temporary directory with unique name for atomic operations
    local temp_secrets_dir
    temp_secrets_dir=$(mktemp -d "${docker_secrets_dir}.XXXXXX")
    log_debug "Created temporary secrets directory: $(basename "$temp_secrets_dir")"

    # Ensure cleanup of temp directory
    local cleanup_temp_dir() {
        rm -rf "$temp_secrets_dir" 2>/dev/null || true
    }
    trap cleanup_temp_dir EXIT

    if ! chmod 700 "$temp_secrets_dir" || ! chown "$real_user:$real_group" "$temp_secrets_dir"; then
        log_error "Failed to set permissions on temp secrets directory"
        return 1
    fi

    if [[ ! -f "secrets/secrets.yaml" ]]; then
        log_error "Secrets file not found: secrets/secrets.yaml"
        log_info "Run: ./edit-secrets.sh --init to create it"
        return 1
    fi

    if ! is_sops_encrypted "secrets/secrets.yaml"; then
        log_error "Secrets file is not encrypted with SOPS"
        return 1
    fi

    if ! has_command jq; then
        log_error "jq command not found. Cannot parse secrets."
        log_info "Install with: sudo apt install jq"
        return 1
    fi

    local decrypted_json exit_status
    log_debug "Decrypting secrets to JSON format..."
    decrypted_json=$(sops --decrypt --output-type json "secrets/secrets.yaml" 2>&1)
    exit_status=$?
    if [[ $exit_status -ne 0 ]]; then
        log_error "Failed to decrypt secrets using key $SOPS_AGE_KEY_FILE."
        log_error "SOPS Output: $decrypted_json"
        log_info "Try running './edit-secrets.sh --test' first."
        return 1
    fi

    # Validate decrypted content is JSON
    if ! echo "$decrypted_json" | jq . > /dev/null 2>&1; then
        log_error "Decrypted secrets content is not valid JSON. File might be corrupted."
        log_debug "Content was: $decrypted_json"
        return 1
    fi

    # Define secrets that need files
    local secrets_needing_files=(
        "admin_token"
        "admin_basic_auth_hash"
        "smtp_password"
        "push_installation_id"
        "push_installation_key"
        "caddy_cloudflare_dns_token"
        "fail2ban_cloudflare_firewall_token"
    )

    # Define which secrets are critical for startup
    local critical_file_secrets=(
        "admin_token"
        "admin_basic_auth_hash"
        "caddy_cloudflare_dns_token"
        "fail2ban_cloudflare_firewall_token"
    )

    local secret_file_path
    local placeholder_critical=()

    # Write files for ALL secrets that need them IN TEMP DIRECTORY
    for secret in "${secrets_needing_files[@]}"; do
        local value
        secret_file_path="$temp_secrets_dir/$secret"
        value=$(echo "$decrypted_json" | jq -r --arg secret "$secret" '.[$secret] // ""')

        if [[ -n "$value" && "$value" != "null" && "$value" != "CHANGE_ME"* ]]; then
            echo -n "$value" > "$secret_file_path"
            log_debug "Created secret file in temp dir: $secret"
        else
            # Check if this is a critical vs optional secret
            local is_critical=false
            for critical_secret in "${critical_file_secrets[@]}"; do
                if [[ "$secret" == "$critical_secret" ]]; then
                    is_critical=true
                    break
                fi
            done

            if [[ "$is_critical" == "true" ]]; then
                echo "PLACEHOLDER_NOT_CONFIGURED" > "$secret_file_path"
                placeholder_critical+=("$secret")
                log_warn "Critical secret '$secret' has placeholder value"
            else
                touch "$secret_file_path"
                log_debug "Created empty file for optional secret: $secret"
            fi
        fi

        # Set ownership and secure permissions IN TEMP DIRECTORY
        if ! chown "$real_user:$real_group" "$secret_file_path" || ! secure_file "$secret_file_path" 600; then
            log_error "Failed to set secure permissions on temp secret file: $secret_file_path"
            return 1
        fi
    done

    # Strict mode handling
    local total_critical_issues=${#placeholder_critical[@]}

    if [[ $total_critical_issues -gt 0 ]]; then
        if [[ "$STRICT_SECRETS" == "true" ]]; then
            log_error "STRICT MODE: Critical secrets validation failed"
            log_error "Placeholder file secrets: ${placeholder_critical[*]}"
            log_error "Cannot start in strict mode with misconfigured secrets"
            log_info "Fix secrets with: ./edit-secrets.sh"
            return 1
        else
            log_warn "Placeholder critical file secrets: ${placeholder_critical[*]}"
            log_info "Edit secrets with: ./edit-secrets.sh"
            log_warn "Continuing startup for debugging (use --strict-secrets to enforce)"
        fi
    fi

    # Atomic move - either complete success or complete failure
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would atomically move secrets to final location"
    else
        rm -rf "$docker_secrets_dir" 2>/dev/null || true
        if mv "$temp_secrets_dir" "$docker_secrets_dir"; then
            log_success "Docker secrets prepared atomically (check warnings above)"
            # Clear the trap since we successfully moved the directory
            trap - EXIT
            return 0
        else
            log_error "Failed to atomically move secrets directory"
            return 1
        fi
    fi

    return 0
}

# STANDARDIZED: Prepare Environment Variables - returns exit code
prepare_environment_variables() {
    log_info "Preparing environment variables for containers..."

    if [[ ! -f ".env" ]]; then
        log_error ".env file not found. Please run setup.sh or create it."
        return 1
    fi

    if ! load_env_file; then
        return 1
    fi

    log_success "Environment variables prepared"
    return 0
}

# STANDARDIZED: Post-Startup Health Check - returns exit code
post_startup_health_check() {
    if [[ "$SKIP_HEALTH" == "true" || "$DRY_RUN" == "true" ]]; then
        log_info "Skipping health check"
        return 0
    fi

    log_info "Performing post-startup health check..."
    log_info "Waiting 15s for services to initialize..."
    sleep 15

    local critical_services=("vaultwarden" "caddy")
    local failed_services=()

    for service in "${critical_services[@]}"; do
        if ! wait_for_service_ready "$service" 60; then
            failed_services+=("$service")
        fi
    done

    # Check non-critical services
    local other_services=("fail2ban")
    local unhealthy_other=()
    for service in "${other_services[@]}"; do
        if ! wait_for_service_ready "$service" 30; then
            unhealthy_other+=("$service")
        fi
    done

    # More detailed health check results
    if [[ ${#failed_services[@]} -eq 0 ]]; then
        log_success "All critical services are running and healthy"

        if [[ ${#unhealthy_other[@]} -gt 0 ]]; then
            log_warn "Non-critical services with issues: ${unhealthy_other[*]}"
            log_info "System functional but some features may not work"
        fi

        local domain
        domain=$(get_config_value "DOMAIN" "")
        if [[ -n "$domain" ]] && has_command curl; then
            log_info "Testing web connectivity..."
            local clean_domain
            clean_domain=$(echo "$domain" | sed 's|https?://||; s|/.*$||')
            if test_http "https://$clean_domain" 15; then
                log_success "Web interface is responding"
            else
                log_warn "Web interface not yet responding (DNS/SSL may need time)"
            fi
        fi
        return 0
    else
        log_error "CRITICAL: Failed services: ${failed_services[*]}"
        log_error "VaultWarden application is likely NON-FUNCTIONAL"
        log_info "Check logs with: docker compose logs <service_name>"
        return 1
    fi
}

# ENHANCED: Main function with proper error handling and exit strategy
main() {
    log_info "VaultWarden-OCI-NG Stack Management (Modernized)"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    if [[ "$STRICT_SECRETS" == "true" ]]; then
        log_info "STRICT SECRETS MODE - Will abort on any critical secret issues"
    fi

    # Load configuration - early exit on failure
    if ! load_env_file; then
        log_error "Failed to load configuration. Have you run setup.sh?"
        exit 1
    fi

    if ! require_config "DOMAIN" "ADMIN_EMAIL"; then
        exit 1
    fi

    if ! require_docker; then
        exit 1
    fi

    # Handle stop mode
    if [[ "$STOP_MODE" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would stop all services"
        else
            log_info "Stopping services..."
            if stop_services; then
                cleanup_secrets "stop"
                log_success "Services stopped successfully"
                exit 0
            else
                log_error "Failed to stop services"
                exit 1
            fi
        fi
        return 0
    fi

    # Ensure state directories exist
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n $real_user)

    # Ensure state dirs are owned by the user running the script
    if ! ensure_dir "$state_dir/logs" 755 "$real_user:$real_group" || \
       ! ensure_dir "$state_dir/data" 700 "$real_user:$real_group" || \
       ! ensure_dir "$state_dir/caddy/data" 700 "$real_user:$real_group" || \
       ! ensure_dir "$state_dir/caddy/config" 700 "$real_user:$real_group" || \
       ! ensure_dir "$state_dir/fail2ban" 700 "$real_user:$real_group"; then
        log_error "Failed to create required state directories"
        exit 1
    fi

    # Prepare secrets and environment variables
    if ! prepare_docker_secrets; then
        log_error "Failed to prepare Docker secrets"
        exit 1
    fi

    if ! prepare_environment_variables; then
        log_error "Failed to prepare environment variables"
        exit 1
    fi

    # Start or restart services
    local service_start_failed=false
    if [[ "$FORCE_RESTART" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would force restart all services"
        else
            log_info "Force restarting services..."
            if ! stop_services; then
                log_error "Failed to stop services for restart"
                exit 1
            fi
            sleep 2
            if ! recreate_services; then
                service_start_failed=true
            fi
        fi
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would start services"
        else
            log_info "Starting services..."
            if ! start_services; then
                service_start_failed=true
            fi
        fi
    fi

    if [[ "$service_start_failed" == "true" ]]; then
        log_error "Failed to start services"
        exit 1
    fi

    # Health check handling
    local health_check_failed=false
    if ! post_startup_health_check; then
        health_check_failed=true
    fi

    # DNS update after health check
    if [[ "$health_check_failed" == "false" ]]; then
        if ! update_dns_if_needed; then
            log_warn "DNS update failed, but services are healthy"
        fi
    else
        log_warn "Skipping DNS update because services failed to start."
    fi

    # Final status determination
    local domain
    domain=$(get_config_value "DOMAIN")

    if [[ "$health_check_failed" == "true" ]]; then
        log_error "🚨 STARTUP COMPLETED WITH CRITICAL ISSUES"
        echo ""
        echo "❌ Critical services failed health checks"
        echo "❌ VaultWarden is likely NON-FUNCTIONAL"
        echo ""
        echo "Immediate actions:"
        echo "  1. Check container logs: make logs SERVICE=vaultwarden"
        echo "  2. Check container status: docker compose ps"
        echo "  3. Try restarting: make restart"
        echo "  4. Check system health: make health"
        echo ""
        exit 1
    else
        # Mark successful startup
        STARTUP_SUCCESS=true

        log_success "🎉 VaultWarden-OCI-NG startup completed successfully"

        # Check final service status
        local all_running=true
        for service in vaultwarden caddy fail2ban; do
            if ! is_service_running "$service"; then
                all_running=false
                log_warn "Service $service is not running."
            fi
        done

        echo ""
        if [[ "$all_running" == "true" ]]; then
            echo "✅ All services are running and healthy!"
            echo "🌐 Web interface: https://$domain"
            echo "⚙️  Admin panel: https://$domain/admin"
        else
            echo "⚠️  Some services may have issues. Check logs for details."
        fi

        echo ""
        echo "Useful commands:"
        echo "  make status          # Check service status"
        echo "  make health          # Comprehensive health check"
        echo "  make logs SERVICE=vaultwarden # View service logs"
        echo "  make down            # Stop services"
        echo ""
        echo "IMPORTANT NOTES:"
        echo "  • After editing secrets, always use: make restart"
        echo "  • DNS is updated automatically on startup"
        
        exit 0
    fi
}

main "$@"
