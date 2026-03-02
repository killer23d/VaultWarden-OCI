#!/usr/bin/env bash
# update.sh - Update VaultWarden, Caddy, Fail2Ban, Postfix, and Host OS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"

# Configuration
UPDATE_SYSTEM=false
UPDATE_IMAGES=true
DRY_RUN=false
RESTART_SERVICES=true
CLEANUP_OLD=true
QUIET=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Update Script

USAGE:
    ./update.sh [OPTIONS]

OPTIONS:
    --system        Also update host OS packages (apt-get update && apt-get upgrade)
    --no-images     Skip pulling new Docker images
    --no-restart    Do not restart services after update
    --no-cleanup    Do not remove old Docker images after update
    --dry-run       Show what would be updated without making changes
    --quiet         Suppress non-error output
    --help          Show this help

EXAMPLES:
    ./update.sh                   # Update containers and restart
    ./update.sh --system          # Update host OS and containers
    ./update.sh --dry-run         # See what images have updates available
EOF
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --system)       UPDATE_SYSTEM=true; shift ;;
        --no-images)    UPDATE_IMAGES=false; shift ;;
        --no-restart)   RESTART_SERVICES=false; shift ;;
        --no-cleanup)   CLEANUP_OLD=false; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --quiet)        QUIET=true; shift ;;
        --help)         show_help; exit 0 ;;
        *)              log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

u_log_info() { [[ "$QUIET" == "true" ]] || log_info "$1"; }
u_log_success() { [[ "$QUIET" == "true" ]] || log_success "$1"; }

check_for_updates() {
    local updates_found=false
    local compose_file="docker-compose.yml"
    
    if [[ ! -f "$compose_file" ]]; then
        log_error "docker-compose.yml not found in $PROJECT_ROOT"
        return 1
    fi
    
    # Extract images from docker-compose.yml
    local images
    images=$(grep -E '^[[:space:]]+image:' "$compose_file" | awk '{print $2}' | tr -d '"'\''')
    
    u_log_info "Checking for image updates..."
    
    for image in $images; do
        # Extract name and tag
        local name tag
        if [[ "$image" == *":"* ]]; then
            name="${image%%:*}"
            tag="${image##*:}"
        else
            name="$image"
            tag="latest"
        fi
        
        # Get local image ID
        local local_id
        local_id=$(docker inspect --type=image --format '{{.Id}}' "$image" 2>/dev/null || echo "none")
        
        # In dry-run, we use docker manifest inspect to check remote without pulling
        if [[ "$DRY_RUN" == "true" ]]; then
            # Needs experimental features enabled, fallback to pull simulation
            export DOCKER_CLI_EXPERIMENTAL=enabled
            local remote_digest
            remote_digest=$(docker manifest inspect "$image" 2>/dev/null | grep -A 1 "config" | grep "digest" | awk -F'"' '{print $4}' || echo "unknown")
            
            if [[ "$local_id" == "none" ]]; then
                u_log_info "  [NEW] $image (Not pulled yet)"
                updates_found=true
            elif [[ "$remote_digest" != "unknown" ]]; then
                # This is an approximation. A true check requires comparing digests properly
                u_log_info "  [CHECK] $image (Remote checking requires pull to be 100% accurate)"
                updates_found=true # Assume update might be available for dry-run
            fi
        else
            u_log_info "  Pulling $image..."
            local pull_output
            pull_output=$(docker pull "$image" 2>&1)
            
            if echo "$pull_output" | grep -q "Downloaded newer image"; then
                u_log_success "  [UPDATED] $image has been updated"
                updates_found=true
            elif echo "$pull_output" | grep -q "Image is up to date"; then
                u_log_info "  [CURRENT] $image is up to date"
            else
                log_warn "  [UNKNOWN] Could not determine status for $image"
            fi
        fi
    done
    
    if [[ "$updates_found" == "true" ]]; then
        return 0
    else
        return 2 # Special exit code for "no updates"
    fi
}

update_system_packages() {
    if [[ "$UPDATE_SYSTEM" != "true" ]]; then
        log_info "Skipping system package updates (use --system to enable)"
        return 0
    fi

    require_root "$@"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: apt-get update && apt-get upgrade -y"
        return 0
    fi

    log_info "Updating system packages..."
    
    if ! command -v apt-get >/dev/null 2>&1; then
        log_warn "apt-get not found. Skipping system update."
        return 0
    fi

    # Use sudo if we aren't root
    local SUDO=""
    if ! is_root; then
        SUDO="sudo"
    fi

    $SUDO apt-get update
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    
    # Check if a reboot is required
    if [[ -f /var/run/reboot-required ]]; then
        log_warn "A system reboot is required due to package updates."
    fi

    u_log_success "System packages updated"
    return 0
}

restart_vaultwarden_services() {
    if [[ "$RESTART_SERVICES" != "true" ]]; then
        log_info "Skipping service restart (--no-restart specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would restart services via docker compose up -d"
        return 0
    fi

    log_info "Applying updates and restarting services..."
    
    # Recreate containers with new images
    if docker compose up -d; then
        u_log_success "Services restarted with updated images"
        
        # Verify health
        log_info "Waiting for services to become healthy..."
        sleep 5
        
        if [[ -x "./health.sh" ]]; then
            if ./health.sh --quiet; then
                u_log_success "All services are healthy after update"
            else
                log_warn "Some services may not be healthy after update. Check logs."
            fi
        fi
        return 0
    else
        log_error "Failed to restart services"
        return 1
    fi
}

perform_cleanup() {
    if [[ "$CLEANUP_OLD" != "true" ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would remove dangling Docker images"
        return 0
    fi

    log_info "Cleaning up old Docker images..."
    if docker image prune -f >/dev/null 2>&1; then
        u_log_success "Cleanup completed"
    else
        log_warn "Image cleanup had issues, but update was successful"
    fi
    return 0
}

main() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_header "VaultWarden-OCI Update [DRY RUN]"
    else
        log_header "VaultWarden-OCI Update"
    fi

    if ! load_env_file; then
        log_error "Failed to load environment configuration"
        exit 1
    fi

    if ! require_docker; then
        log_error "Docker is not available"
        exit 1
    fi

    # Phase 1: Create safety backup
    if [[ "$DRY_RUN" == "false" && "$UPDATE_IMAGES" == "true" ]]; then
        log_info "Creating pre-update safety backup..."
        if [[ -x "./backup.sh" ]]; then
            # Call backup script directly
            if ./backup.sh --type db --quiet; then
                u_log_success "Pre-update safety backup created"
            else
                log_warn "Failed to create safety backup! Proceeding anyway..."
            fi
        else
            log_warn "backup.sh not found, skipping safety backup"
        fi
    fi

    # Phase 2: Host OS Updates
    update_system_packages

    # Phase 3: Docker Image Updates
    local images_updated=false
    if [[ "$UPDATE_IMAGES" == "true" ]]; then
        check_for_updates
        local update_status=$?
        
        if [[ $update_status -eq 0 ]]; then
            images_updated=true
            log_info "Updates pulled successfully"
        elif [[ $update_status -eq 2 ]]; then
            log_info "All Docker images are up to date"
        else
            log_error "Failed to check for or pull image updates"
            exit 1
        fi
    fi

    # Phase 4: Apply Updates & Restart
    if [[ "$images_updated" == "true" || "$UPDATE_SYSTEM" == "true" ]]; then
        restart_vaultwarden_services
    else
        log_info "No updates required service restarts"
    fi

    # Phase 5: Cleanup
    if [[ "$images_updated" == "true" ]]; then
        perform_cleanup
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        u_log_success "Dry run completed successfully"
    else
        u_log_success "Update process completed successfully"
        
        # Send notification if email is configured
        local admin_email
        admin_email=$(get_config_value "ADMIN_EMAIL" "")
        
        if [[ -n "$admin_email" && -x "./maintenance.sh" ]]; then
            # Call maintenance script with email-only option
            # This is a bit of a hack since maintenance.sh doesn't have an explicit 'send generic email' flag
            # But the common library has the function we need
            local subject="VaultWarden Updated Successfully"
            local body="The VaultWarden-OCI stack has been updated.\nDate: $(date -Iseconds)\nUpdates applied: $([[ "$images_updated" == "true" ]] && echo "Docker Images" || echo "None") $([[ "$UPDATE_SYSTEM" == "true" ]] && echo ", System Packages" || echo "")"
            
            # Export the variables needed by the script
            export LOG_LEVEL="ERROR"
            bash -c "source lib/common.sh && send_notification_email '$subject' '$body'" >/dev/null 2>&1 || true
        fi
    fi

    exit 0
}

main "$@"