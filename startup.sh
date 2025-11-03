#!/usr/bin/env bash
# startup.sh - Enhanced VaultWarden startup script with secure secrets handling
# ENHANCED: Fixed secret file permissions race condition - set umask before file creation
# ENHANCED: Atomic secret file creation with proper permissions from the start

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh" 
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"

# Configuration
FORCE_RESTART=false
SKIP_HEALTH_CHECK=false
BACKGROUND=false
DRY_RUN=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Startup Script with Enhanced Security

USAGE:
    ./startup.sh [OPTIONS]

OPTIONS:
    --force-restart         Force restart of all services
    --skip-health           Skip post-startup health check
    --background           Start services in background (daemon mode)
    --dry-run              Show what would be done without executing
    --help                 Show this help

EXAMPLES:
    ./startup.sh                    # Normal startup
    ./startup.sh --force-restart    # Force restart all services
    ./startup.sh --background       # Start in daemon mode
EOF
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --force-restart) FORCE_RESTART=true; shift ;;
        --skip-health) SKIP_HEALTH_CHECK=true; shift ;;
        --background) BACKGROUND=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# ENHANCED: Secure secret file preparation with fixed race condition
prepare_docker_secrets() {
    log_info "Preparing Docker secrets with enhanced security..."

    local secrets_dir="secrets/.docker_secrets"
    local sops_file="secrets/secrets.yaml"
    local age_key_file="secrets/keys/age-key.txt"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would prepare Docker secrets securely"
        return 0
    fi

    # Validate prerequisites
    if [[ ! -f "$sops_file" ]]; then
        log_error "Encrypted secrets file not found: $sops_file"
        return 1
    fi

    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        return 1
    fi

    # SECURITY FIX: Set restrictive umask BEFORE creating any files
    # This prevents the race condition where files are created with default permissions
    local old_umask
    old_umask=$(umask)
    umask 077  # Ensures all new files are created with 600 permissions

    # Cleanup function to restore umask
    cleanup_umask() {
        umask "$old_umask"
    }
    trap cleanup_umask EXIT

    # Create secrets directory with proper permissions
    if ! ensure_dir "$secrets_dir" 700; then
        log_error "Failed to create secrets directory"
        cleanup_umask
        return 1
    fi

    # Clean existing secret files atomically
    if [[ -d "$secrets_dir" ]]; then
        rm -rf "${secrets_dir:?}"/*
    fi

    log_info "Decrypting secrets with secure file creation..."

    # Set SOPS environment
    export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/$age_key_file"

    # Retrieve secrets using SOPS and create files atomically
    # Each file is created with 600 permissions due to umask 077
    local secret_files=(
        "admin_token"
        "admin_basic_auth_hash" 
        "smtp_password"
        "push_installation_id"
        "push_installation_key"
        "caddy_cloudflare_dns_token"
        "fail2ban_cloudflare_firewall_token"
    )

    local secrets_created=0
    local secrets_failed=0

    for secret_name in "${secret_files[@]}"; do
        local secret_file="$secrets_dir/$secret_name"
        local secret_value

        # Extract secret value using SOPS
        if secret_value=$(sops -d --extract "["$secret_name"]" "$sops_file" 2>/dev/null); then
            # Skip empty or placeholder values
            if [[ -n "$secret_value" ]] && [[ "$secret_value" != "CHANGE_ME"* ]] && [[ "$secret_value" != "null" ]]; then
                # Create secret file atomically - umask 077 ensures 600 permissions
                if echo "$secret_value" > "$secret_file"; then
                    # Verify file was created with correct permissions
                    local file_perms
                    file_perms=$(stat -c "%a" "$secret_file" 2>/dev/null || echo "unknown")
                    if [[ "$file_perms" == "600" ]]; then
                        log_debug "Secret created securely: $secret_name (permissions: $file_perms)"
                        ((secrets_created++))
                    else
                        log_error "Secret file created with incorrect permissions: $secret_name ($file_perms)"
                        ((secrets_failed++))
                    fi
                else
                    log_error "Failed to create secret file: $secret_name"
                    ((secrets_failed++))
                fi
            else
                log_debug "Skipping empty/placeholder secret: $secret_name"
            fi
        else
            log_error "Failed to decrypt secret: $secret_name"
            ((secrets_failed++))
        fi
    done

    # Restore original umask before returning
    cleanup_umask
    trap - EXIT

    # Report results
    log_success "Docker secrets prepared: $secrets_created created, $secrets_failed failed"

    if [[ $secrets_failed -gt 0 ]]; then
        log_warn "Some secrets failed to prepare. Check SOPS configuration and secret values."
        return 1
    fi

    if [[ $secrets_created -eq 0 ]]; then
        log_warn "No secrets were created. Verify secrets.yaml contains valid values."
        return 1
    fi

    return 0
}

# STANDARDIZED: Service management functions
start_services() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would start VaultWarden services"
        return 0
    fi

    log_info "Starting VaultWarden services..."

    if [[ "$FORCE_RESTART" == "true" ]]; then
        log_info "Force restart requested - stopping existing services..."
        if ! docker compose down >/dev/null 2>&1; then
            log_warn "Failed to stop existing services (may not be running)"
        fi
    fi

    # Start services with dependency ordering
    if [[ "$BACKGROUND" == "true" ]]; then
        if ! docker compose up -d; then
            log_error "Failed to start services in background"
            return 1
        fi
        log_success "Services started in background mode"
    else
        if ! docker compose up -d; then
            log_error "Failed to start services"
            return 1
        fi
        log_success "Services started successfully"
    fi

    return 0
}

# STANDARDIZED: Health validation
verify_startup_health() {
    if [[ "$SKIP_HEALTH_CHECK" == "true" ]]; then
        log_info "Skipping health check (--skip-health specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would verify service health"
        return 0
    fi

    log_info "Verifying service health after startup..."

    # Wait for services to initialize
    sleep 10

    # Run comprehensive health check
    if ./health.sh --quick; then
        log_success "All services are healthy"
        return 0
    else
        log_error "Health check failed - some services may not be ready"
        return 1
    fi
}

# STANDARDIZED: Cleanup function
cleanup_on_exit() {
    # Clean up any temporary files or processes
    if [[ -d "secrets/.docker_secrets" ]]; then
        # Secure cleanup of secret files
        find "secrets/.docker_secrets" -type f -exec shred -vfz -n 3 {} \; 2>/dev/null || true
    fi
}

trap cleanup_on_exit EXIT

# ENHANCED: Main function with proper error handling
main() {
    log_header "VaultWarden-OCI Enhanced Startup"

    # Load environment configuration
    if ! load_env_file; then
        log_error "Failed to load environment configuration"
        exit 1
    fi

    # Validate Docker availability
    if ! require_docker; then
        log_error "Docker is not available or accessible"
        exit 1
    fi

    # Phase 1: Secure secrets preparation
    log_info "=== Phase 1: Secure Secrets Preparation ==="
    if ! prepare_docker_secrets; then
        log_error "Failed to prepare Docker secrets securely"
        exit 1
    fi

    # Phase 2: Service startup
    log_info "=== Phase 2: Service Startup ==="
    if ! start_services; then
        log_error "Failed to start services"
        exit 1
    fi

    # Phase 3: Health verification
    log_info "=== Phase 3: Health Verification ==="
    if ! verify_startup_health; then
        log_error "Service health verification failed"
        exit 1
    fi

    # Success summary
    log_success "VaultWarden startup completed successfully"

    if [[ "$BACKGROUND" == "true" ]]; then
        echo "Services are running in background. Use 'make logs' to monitor."
    else
        echo "All services are healthy and ready."
    fi

    # Show service status
    echo ""
    echo "Service Status:"
    docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

    exit 0
}

main "$@"
