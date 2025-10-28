#!/usr/bin/env bash
# startup.sh - Fixed VaultWarden stack orchestration
# MAJOR FIX: Create ALL required secret files including API tokens
# ENHANCED: Better trap handling and error recovery

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# --- Enhanced Cleanup Function ---
cleanup_secrets() {
    local cleanup_reason="${1:-unknown}"
    
    # Only clean up on successful completion or explicit stop
    if [[ "${STARTUP_SUCCESS:-false}" == "true" || "$cleanup_reason" == "stop" ]]; then
        rm -rf "$PROJECT_ROOT/secrets/.docker_secrets" 2>/dev/null || true
        log_debug "Cleaned up temporary secret files"
    else
        log_debug "Keeping secret files for debugging (startup failed or interrupted)"
        if [[ -d "$PROJECT_ROOT/secrets/.docker_secrets" ]]; then
            log_info "Debug: Secret files preserved in secrets/.docker_secrets/"
        fi
    fi
}

# Set up trap with enhanced cleanup
trap 'cleanup_secrets "error"' ERR
trap 'cleanup_secrets "interrupt"' HUP INT TERM
trap 'cleanup_secrets "exit"' EXIT

cd "$PROJECT_ROOT"

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"

# Ensure the key file env var is set
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-"$PROJECT_ROOT/secrets/keys/age-key.txt"}"

# --- Configuration ---
FORCE_RESTART=false
DRY_RUN=false
SKIP_HEALTH=false
STOP_MODE=false
STARTUP_SUCCESS=false

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Startup Script

USAGE:
    ./startup.sh [OPTIONS]

OPTIONS:
    --help           Show this help
    --force-restart  Stop and recreate all containers (REQUIRED after secrets changes)
    --dry-run        Show what would be done without executing
    --skip-health    Skip post-startup health check
    --down           Stop and remove all containers

EXAMPLES:
    ./startup.sh                    # Normal startup
    ./startup.sh --force-restart    # Force recreate containers (use after edit-secrets.sh)
    ./startup.sh --down             # Stop all services

IMPORTANT:
    After editing secrets (./edit-secrets.sh), always use --force-restart to ensure
    environment variables are properly updated in containers.
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --help) show_help; exit 0 ;;
        --force-restart) FORCE_RESTART=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --skip-health) SKIP_HEALTH=true; shift ;;
        --down) STOP_MODE=true; shift ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- FIXED: Prepare Docker Secrets ---
prepare_docker_secrets() {
    log_info "Preparing Docker secrets..."

    local docker_secrets_dir="secrets/.docker_secrets"
    rm -rf "$docker_secrets_dir"
    mkdir -p "$docker_secrets_dir"

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
    echo "$decrypted_json" | jq . > /dev/null 2>&1 || {
        log_error "Decrypted secrets content is not valid JSON. File might be corrupted."
        log_debug "Content was: $decrypted_json"
        return 1
    }

    # FIXED: ALL secrets that need files (including API tokens)
    local secrets_needing_files=("admin_token" "smtp_password" "push_installation_id" "push_installation_key" "ddclient_api_token" "fail2ban_api_token")
    # FIXED: Only admin_basic_auth_hash is environment-only
    local critical_env_secrets=("admin_basic_auth_hash")
    local secret_file_path
    local missing_secrets=()
    local placeholder_secrets=()

    # Write files for ALL secrets that need them
    for secret in "${secrets_needing_files[@]}"; do
        local value
        secret_file_path="$docker_secrets_dir/$secret"
        value=$(echo "$decrypted_json" | jq -r --arg secret "$secret" '.[$secret] // ""')

        if [[ -n "$value" && "$value" != "null" && "$value" != "CHANGE_ME"* ]]; then
            echo -n "$value" > "$secret_file_path"
            log_debug "Created secret file: $secret_file_path"
        else
            # Handle missing/placeholder secrets appropriately
            if [[ "$secret" == "smtp_password" || "$secret" == "push_installation_id" || "$secret" == "push_installation_key" ]]; then
                # Optional secrets - create empty file
                touch "$secret_file_path"
                log_debug "Created empty file for optional secret: $secret"
            else
                # Critical secrets - create placeholder but warn
                echo "PLACEHOLDER_NOT_CONFIGURED" > "$secret_file_path"
                placeholder_secrets+=("$secret")
                log_warn "Critical secret '$secret' has placeholder value"
            fi
        fi
        secure_file "$secret_file_path" 600 || { log_error "Failed to secure secret file: $secret"; return 1; }
    done

    # Validate critical secrets that are passed via environment
    for secret in "${critical_env_secrets[@]}"; do
        local value
        value=$(echo "$decrypted_json" | jq -r --arg secret "$secret" '.[$secret] // "CHANGE_ME"')
        if [[ -z "$value" ]] || [[ "$value" == "CHANGE_ME"* ]] || [[ "$value" == "null" ]]; then
             missing_secrets+=("$secret")
        fi
    done

    # Report issues but allow startup for debugging
    if [[ ${#missing_secrets[@]} -gt 0 ]]; then
        log_warn "Missing critical environment secrets: ${missing_secrets[*]}"
        log_info "Edit secrets with: ./edit-secrets.sh"
    fi
    
    if [[ ${#placeholder_secrets[@]} -gt 0 ]]; then
        log_warn "Placeholder critical file secrets: ${placeholder_secrets[*]}"
        log_info "Edit secrets with: ./edit-secrets.sh"
    fi

    # Allow startup even with warnings - containers can start and we can debug
    log_success "Docker secrets prepared (check warnings above)"
    return 0
}

# --- Prepare Environment Variables ---
prepare_environment_variables() {
    log_info "Preparing environment variables for containers..."

    local decrypted_json exit_status
    log_debug "Decrypting secrets to JSON format for environment variables..."
    decrypted_json=$(sops --decrypt --output-type json "secrets/secrets.yaml" 2>&1)
    exit_status=$?
    if [[ $exit_status -ne 0 ]]; then
        log_error "Failed to decrypt secrets for environment variables."
        log_error "SOPS Output: $decrypted_json"
        return 1
    fi

    # Validate decrypted content is JSON
    echo "$decrypted_json" | jq . > /dev/null 2>&1 || {
        log_error "Decrypted secrets content for env vars is not valid JSON."
        return 1
    }

    # Export environment variables that containers need
    local admin_basic_auth_hash
    admin_basic_auth_hash=$(echo "$decrypted_json" | jq -r '.admin_basic_auth_hash // ""')
    export ADMIN_BASIC_AUTH_HASH="$admin_basic_auth_hash"
    log_debug "Exported ADMIN_BASIC_AUTH_HASH"

    local ddclient_token
    ddclient_token=$(echo "$decrypted_json" | jq -r '.ddclient_api_token // ""')
    export DDCLIENT_API_TOKEN="$ddclient_token"
    log_debug "Exported DDCLIENT_API_TOKEN"

    local fail2ban_token
    fail2ban_token=$(echo "$decrypted_json" | jq -r '.fail2ban_api_token // ""')
    export FAIL2BAN_API_TOKEN="$fail2ban_token"
    log_debug "Exported FAIL2BAN_API_TOKEN"

    log_success "Environment variables prepared"
    return 0
}

# --- Post-Startup Health Check ---
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
    local other_services=("fail2ban" "ddclient")
     for service in "${other_services[@]}"; do
        if ! wait_for_service_ready "$service" 30; then
            log_warn "Service '$service' failed post-startup health check."
        fi
    done

    if [[ ${#failed_services[@]} -eq 0 ]]; then
        log_success "All critical services are running and healthy"
        
        local domain
        domain=$(get_config_value "DOMAIN" "")
        if [[ -n "$domain" ]] && has_command curl; then
            log_info "Testing web connectivity..."
            local clean_domain
            clean_domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')
            if test_http "https://$clean_domain" 15; then
                log_success "Web interface is responding"
            else
                log_warn "Web interface not yet responding (may need more time)"
            fi
        fi
    else
        log_error "Failed critical services: ${failed_services[*]}"
        log_info "Check logs with: docker compose logs <service_name>"
        return 1
    fi

    return 0
}

# --- Main Execution ---
main() {
    log_info "VaultWarden-OCI-NG Stack Management"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    # Load configuration
    load_env_file || { log_error "Failed to load configuration"; exit 1; }
    require_config "DOMAIN" "ADMIN_EMAIL" || exit 1
    require_docker || exit 1

    # Handle stop mode
    if [[ "$STOP_MODE" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would stop all services"
        else
            stop_services
            cleanup_secrets "stop"
            log_success "Services stopped successfully"
        fi
        return 0
    fi

    # Ensure state directories exist
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    ensure_dir "$state_dir/logs" 755 || exit 1

    # Prepare secrets and environment variables
    prepare_docker_secrets || exit 1
    prepare_environment_variables || exit 1

    # Start or restart services
    if [[ "$FORCE_RESTART" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would force restart all services"
        else
            log_info "Force restarting services..."
            stop_services
            sleep 2
            recreate_services
        fi
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would start services"
        else
            start_services
        fi
    fi

    # Health check
    post_startup_health_check || log_warn "Health check detected issues"

    # Mark successful startup
    STARTUP_SUCCESS=true

    # Final status
    local domain
    domain=$(get_config_value "DOMAIN")

    log_success "VaultWarden-OCI-NG startup completed"
    echo ""
    
    # Check final status
    local all_running=true
    for service in vaultwarden caddy fail2ban ddclient; do
      if ! is_service_running "$service"; then
        all_running=false
        log_warn "Service $service is not running."
      fi
    done

    if [[ "$all_running" == "true" ]]; then
        echo "🎉 All services are running!"
        echo "Web interface: https://$domain"
        echo "Admin panel: https://$domain/admin"
    else
         echo "⚠️  Some services may not be running correctly. Please check logs."
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
}

main "$@"
