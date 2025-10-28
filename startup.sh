#!/usr/bin/env bash
# startup.sh - Simplified VaultWarden stack orchestration
# Uses centralized library functions
# Removed redundant secrets file creation for env-passed secrets
# FIX: Define PROJECT_ROOT before trap command

set -euo pipefail

# --- START FIX: Define PROJECT_ROOT earlier ---
# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
# --- END FIX ---

# --- START FIX: Set trap *after* PROJECT_ROOT is defined ---
trap "rm -rf '$PROJECT_ROOT/secrets/.docker_secrets' 2>/dev/null" EXIT HUP INT TERM
# --- END FIX ---

cd "$PROJECT_ROOT" # cd after defining PROJECT_ROOT

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0" # init_common_lib now correctly uses PROJECT_ROOT if needed
source "lib/docker.sh"
source "lib/crypto.sh"

# --- Configuration ---
FORCE_RESTART=false
DRY_RUN=false
SKIP_HEALTH=false
STOP_MODE=false

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

# --- Prepare Docker Secrets ---
# Writes necessary files for secrets not passed via environment
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

    local decrypted_json
    # Use SOPS_AGE_KEY_FILE environment variable set by edit-secrets.sh caller potentially
    # Or rely on .sops.yaml if variable not set. sops_decrypt handles this.
    decrypted_json=$(sops_decrypt "secrets/secrets.yaml" "" 2>/dev/null) || {
        log_error "Failed to decrypt secrets. Check age key and sops config."
        log_info "Try running './edit-secrets.sh --test' first."
        return 1
    }


    # Secrets that NEED files (vs being passed via env)
    local secrets_needing_files=("admin_token" "smtp_password" "push_installation_id" "push_installation_key")
    # Critical secrets (passed via env but need validation)
    local critical_env_secrets=("admin_basic_auth_hash" "ddclient_api_token" "fail2ban_api_token")
    local secret_file_path
    local missing_secrets=() # Array to track unconfigured critical secrets

    # Write files for secrets that need them
    for secret in "${secrets_needing_files[@]}"; do
        local value
        secret_file_path="$docker_secrets_dir/$secret"
        value=$(echo "$decrypted_json" | jq -r --arg secret "$secret" '.[$secret] // ""') # Default to empty string

        # Only write non-empty, non-placeholder values, otherwise write empty file for optional secrets
        if [[ -n "$value" ]] && [[ "$value" != "CHANGE_ME"* ]] && [[ "$value" != "null" ]]; then
            echo "$value" > "$secret_file_path"
        else
            # For optional secrets like smtp/push, create empty file if not set or placeholder
             if [[ "$secret" == "smtp_password" || "$secret" == "push_installation_id" || "$secret" == "push_installation_key" ]]; then
                # Create empty file, docker-compose expects it
                touch "$secret_file_path"
            else
                # For admin_token (required), if it's missing/placeholder, it's an error state implicitly caught later
                 echo "CHANGE_ME_#_Missing_or_Placeholder_Value" > "$secret_file_path" # Write placeholder to file for debug
                 # We don't add admin_token to missing_secrets here as it's not checked below
                 log_warn "Secret '$secret' (required file) seems unconfigured."

            fi
        fi
        secure_file "$secret_file_path" 600 || { log_error "Failed to secure temporary secret file: $secret"; return 1; }
    done

    # Validate critical secrets that are passed via environment
    for secret in "${critical_env_secrets[@]}"; do
        local value
        value=$(echo "$decrypted_json" | jq -r --arg secret "$secret" '.[$secret] // "CHANGE_ME"')
        if [[ -z "$value" ]] || [[ "$value" == "CHANGE_ME"* ]] || [[ "$value" == "null" ]]; then
             log_warn "Critical secret '$secret' not configured or has placeholder value"
             missing_secrets+=("$secret") # Add to the list of missing secrets
        fi
    done

    # --- START VALIDATION ---
    if [[ ${#missing_secrets[@]} -gt 0 ]]; then
        log_error "Deployment aborted due to unconfigured critical secrets:"
        for missing in "${missing_secrets[@]}"; do
             log_error "  - $missing is set to a placeholder (e.g., CHANGE_ME...)"
        done
        log_info "Please configure these secrets using: ./edit-secrets.sh"
        return 1 # Exit function with error status
    fi
    # --- END VALIDATION ---

    log_success "Docker secrets prepared and validated"
    return 0
}

# --- Prepare Environment Variables ---
# Exports necessary secrets as environment variables for docker-compose
prepare_environment_variables() {
    log_info "Preparing environment variables for containers..."

    local decrypted_json
    # Decrypt again, ensure SOPS_AGE_KEY_FILE is available if needed
    decrypted_json=$(sops_decrypt "secrets/secrets.yaml" "" 2>/dev/null) || {
        log_error "Failed to decrypt secrets for environment variables. Check age key and sops config."
        return 1
    }

    local admin_basic_auth_hash
    admin_basic_auth_hash=$(echo "$decrypted_json" | jq -r '.admin_basic_auth_hash // ""')
    # Validation already happened in prepare_docker_secrets, just export
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

    log_success "Secrets exported to environment"
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

    # Also check non-critical but important services
    local other_services=("fail2ban" "ddclient")
     for service in "${other_services[@]}"; do
        if ! wait_for_service_ready "$service" 30; then # Shorter timeout for these
            # Log warning, but don't count as failure for overall status if criticals are OK
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
                log_warn "Web interface not yet responding (may need more time or check DNS/Firewall)"
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

    load_env_file || { log_error "Failed to load configuration"; exit 1; }
    require_config "DOMAIN" "ADMIN_EMAIL" || exit 1
    require_docker || exit 1

    if [[ "$STOP_MODE" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would stop all services"
        else
            stop_services
            rm -rf secrets/.docker_secrets 2>/dev/null || true
            log_success "Services stopped successfully"
        fi
        return 0
    fi

    ensure_dir "$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")/logs" 755 || exit 1

    # Prepare secrets and environment variables
    # prepare_docker_secrets will now exit if validation fails
    prepare_docker_secrets || exit 1
    prepare_environment_variables || exit 1 # Should succeed if prepare_docker_secrets passed

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

    post_startup_health_check || log_warn "Health check detected issues with critical services, but stack attempted startup"

    local domain
    domain=$(get_config_value "DOMAIN")

    log_success "VaultWarden-OCI-NG startup procedure completed"
    echo ""
    # Check final status before declaring success message
    local all_running=true
    for service in vaultwarden caddy fail2ban ddclient; do
      if ! is_service_running "$service"; then
        all_running=false
        log_warn "Service $service is not running."
      fi
    done

    if [[ "$all_running" == "true" ]]; then
        echo "All services appear to be running!"
        echo "Web interface: https://$domain"
        echo "Admin panel: https://$domain/admin"
    else
         echo "Some services may not be running correctly. Please check logs."
    fi

    echo ""
    echo "Useful commands:"
    echo "  make status          # Check service status"
    echo "  make health          # Check system health"
    echo "  make logs SERVICE=... # View service logs"
    echo "  make down            # Stop services"
    echo ""
    echo "IMPORTANT NOTES:"
    echo "  • After editing secrets, always use: make restart"
}

# --- START FIX: Export SOPS_AGE_KEY_FILE if edit-secrets set it ---
# This ensures sops_decrypt within prepare_docker_secrets/prepare_environment_variables uses the correct key
export SOPS_AGE_KEY_FILE
# --- END FIX ---

main "$@"

