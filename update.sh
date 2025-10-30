#!/usr/bin/env bash
# update.sh - Simplified VaultWarden container and system updates with library integration
# MODIFIED: Corrected fragile image name parsing to support different image formats like ghcr.io.

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"

# --- Configuration ---
UPDATE_TYPE="containers"
AUTO_BACKUP=true
DRY_RUN=false
FORCE=false
PIN_SERVICE=""
PIN_VERSION=""
UNPIN_SERVICE=""
SHOW_PINS=false
ENV_FILE=".env"

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Update Tool

USAGE:
   ./update.sh
   ./update.sh --pin <service> <version>
   ./update.sh --unpin <service>
   ./update.sh --show-pins

STANDARD UPDATE OPTIONS:
    --type TYPE        Update type: containers, system, all (default: containers)
    --no-backup       Skip automatic backup before update
    --dry-run         Show what would be updated without executing
    --force           Skip confirmation prompts (and auto-reboot if required)
    --help            Show this help

VERSION MANAGEMENT OPTIONS:
    --pin SERVICE VERSION   Pin a specific service to a version in.env
                            (e.g., --pin vaultwarden 1.31.0)
    --unpin SERVICE         Remove version pin for a service in.env (defaults to latest)
                            (e.g., --unpin caddy)
    --show-pins             Display currently pinned versions from.env

UPDATE TYPES:
    containers    Update Docker containers based on.env pins or 'latest'
    system        Update system packages (will auto-reboot if needed with --force)
    all           Update both containers and system

NOTE:
    Using --pin or --unpin modifies the.env file. Run
    './update.sh --type containers' afterwards to apply the changes.

EXAMPLES:
   ./update.sh                     # Update containers based on.env
   ./update.sh --type system      # Update system packages
   ./update.sh --pin vaultwarden 1.31.0 # Pin Vaultwarden to 1.31.0 in.env
   ./update.sh --unpin caddy        # Let Caddy use the 'latest' tag
   ./update.sh --show-pins          # View current pins
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --type) UPDATE_TYPE="$2"; shift 2 ;;
        --no-backup) AUTO_BACKUP=false; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --force) FORCE=true; shift ;;
        --pin)
            if [[ $# -lt 3 ]]; then log_error "--pin requires SERVICE and VERSION arguments"; show_help; exit 1; fi
            PIN_SERVICE="$2"; PIN_VERSION="$3"; shift 3 ;;
        --unpin)
            if [[ $# -lt 2 ]]; then log_error "--unpin requires SERVICE argument"; show_help; exit 1; fi
            UNPIN_SERVICE="$2"; shift 2 ;;
        --show-pins) SHOW_PINS=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Version Management Functions ---

validate_service_name() {
    local service="$1"
    case "$service" in
        vaultwarden|caddy|fail2ban|ddclient) return 0 ;;
        *) log_error "Invalid service name: '$service'. Must be one of: vaultwarden, caddy, fail2ban, ddclient."; return 1 ;;
    esac
}

get_version_var_name() {
    local service="$1"
    echo "${service^^}_VERSION"
}

pin_service_version() {
    local service="$1"
    local version="$2"
    local var_name

    validate_service_name "$service" |

| return 1
    var_name=$(get_version_var_name "$service")

    log_info "Pinning $service to version $version in $ENV_FILE..."

    if [[! -f "$ENV_FILE" ]]; then
        log_error "$ENV_FILE not found. Cannot pin version."
        return 1
    fi

    local temp_env
    temp_env=$(mktemp)
    setup_cleanup_trap "rm -f '$temp_env'"

    awk -v var="$var_name" -v val="$version" '
    BEGIN { found = 0 }
    $0 ~ "^" var "=" { print var "=" val; found = 1; next }
    $0 ~ "^#" var "=" { print var "=" val; found = 1; next }
    { print }
    END { if (!found) print var "=" val }
    ' "$ENV_FILE" > "$temp_env"

    if mv "$temp_env" "$ENV_FILE"; then
        log_success "$service pinned to $version in $ENV_FILE"
        log_info "Run './update.sh --type containers' to apply this change."
    else
        log_error "Failed to update $ENV_FILE"
        rm -f "$temp_env"
        return 1
    fi
    return 0
}

unpin_service_version() {
    local service="$1"
    local var_name

    validate_service_name "$service" |

| return 1
    var_name=$(get_version_var_name "$service")

    log_info "Unpinning $service version in $ENV_FILE (will default to latest)..."

    if [[! -f "$ENV_FILE" ]]; then
        log_warn "$ENV_FILE not found. Nothing to unpin."
        return 0
    fi

    if grep -q "^\s*[^#]*${var_name}=" "$ENV_FILE"; then
        sed -i -e "/^\s*${var_name}=/s/^/#/" "$ENV_FILE"
        log_success "$service unpinned in $ENV_FILE. It will now default to 'latest'."
        log_info "Run './update.sh --type containers' to apply this change."
    elif grep -q "^\s*#\s*${var_name}=" "$ENV_FILE"; then
        log_info "$service version is already commented out (unpinned) in $ENV_FILE."
    else
        log_info "$service version variable not found in $ENV_FILE. Already defaulting to 'latest'."
    fi
    return 0
}

show_pinned_versions() {
    log_info "Currently pinned versions in $ENV_FILE:"
    echo ""
    local found_pins=false
    if [[ -f "$ENV_FILE" ]]; then
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                 echo "  $line"
                 found_pins=true
            fi
        done < <(grep -E "^\s*[^#]*(VAULTWARDEN|CADDY|FAIL2BAN|DDCLIENT)_VERSION=" "$ENV_FILE" |

| true)
    fi

    if [[ "$found_pins" == "false" ]]; then
        log_info "  No versions are currently pinned. All services will use 'latest' tag."
    fi
    echo ""
    log_info "Services without a line above will default to the 'latest' tag."
}

# --- Pre-Update Backup ---
create_backup() {
    if]; then
        log_info "Skipping backup (--no-backup specified)"
        return 0
    fi

    log_info "Creating pre-update backup..."

    if]; then
        log_info " Would create backup with:./backup.sh --type full"
        return 0
    fi

    if./backup.sh --type full >/dev/null 2>&1; then
        log_success "Pre-update backup created"
        return 0
    else
        log_error "Failed to create pre-update backup"
        log_warn "Continue without backup? This is not recommended."

        if]; then
            log_warn "Continuing without backup (--force specified)"
            return 0
        fi

        read -p "Continue anyway? (y/N): " continue_choice
        if$ ]]; then
            log_warn "Proceeding without backup"
            return 0
        else
            log_info "Update cancelled"
            exit 1
        fi
    fi
}

# --- Container Updates ---
update_containers() {
    log_info "Updating Docker containers..."

    if]; then
        log_info " Would pull container images based on.env or 'latest'"
        log_info " Would restart containers if images were updated"
        return 0
    fi

    require_docker |

| return 1

    if! validate_compose_file; then
        log_error "Docker Compose configuration is invalid"
        return 1
    fi

    local services
    services=$(docker compose config --services 2>/dev/null |

| echo "")

    if [[ -z "$services" ]]; then
        log_error "Could not determine services from docker-compose.yml"
        return 1
    fi

    log_info "Current container versions (before pull):"
    declare -A old_ids
    for service in $services; do
        local image current_id
        local var_name pinned_version effective_tag
        var_name=$(get_version_var_name "$service")
        pinned_version="${!var_name:-}"
        [[ -n "$pinned_version" ]] && effective_tag="$pinned_version" |

| effective_tag="latest"

        # CORRECTED: Robust image name construction to handle names like ghcr.io/...
        image_base=$(docker compose config | awk -v service="$service" '/^ *'"$service"':/,/image:/' | grep 'image:' | awk '{print $2}' | sed 's/:.*//')
        image="${image_base}:${effective_tag}"

        current_id=$(docker images --format "{{.ID}}" "$image" 2>/dev/null | head -1 |

| echo "not_found")
        old_ids["$service"]="$current_id"
        log_info "  $service: $image ($current_id)"
    done

    echo ""
    log_info "Pulling container images specified in docker-compose.yml (using.env pins or defaulting to 'latest')..."
    pull_images |

| log_warn "Image pull command encountered issues."

    local updated_services=()
    log_info "Checking for updated images..."
    for service in $services; do
        local image new_id
        local var_name pinned_version effective_tag
        var_name=$(get_version_var_name "$service")
        pinned_version="${!var_name:-}"
        [[ -n "$pinned_version" ]] && effective_tag="$pinned_version" |

| effective_tag="latest"

        # CORRECTED: Robust image name construction
        image_base=$(docker compose config | awk -v service="$service" '/^ *'"$service"':/,/image:/' | grep 'image:' | awk '{print $2}' | sed 's/:.*//')
        image="${image_base}:${effective_tag}"

        new_id=$(docker inspect --format='{{.Id}}' "$image" 2>/dev/null |

| echo "unknown")

        if [[ "${old_ids["$service"]}"!= "$new_id" && "$new_id"!= "unknown" ]]; then
             if [[ "${old_ids["$service"]}" == "not_found" ]]; then
                log_info "  $service: New image pulled ($image -> $new_id)"
             else
                log_info "  $service: Image updated ($image: ${old_ids["$service"]} -> $new_id)"
             fi
            updated_services+=("$service")
        elif [[ "$new_id" == "unknown" ]]; then
             log_warn "  $service: Could not inspect image '$image'. Pull might have failed."
        fi
    done

    if [[ ${#updated_services[@]} -eq 0 ]]; then
        log_success "All container images are already up to date"
        return 0
    fi

    log_info "Services with image updates: ${updated_services[*]}"
    log_info "Recreating containers with new images..."
    if recreate_services; then
        log_success "Containers recreated successfully"
        log_info "Waiting for services to stabilize..."
        sleep 15

        local failed_services=()
        for service in $services; do
            if! wait_for_service_ready "$service" 30; then
                failed_services+=("$service")
            fi
        done

        if [[ ${#failed_services[@]} -eq 0 ]]; then
            log_success "All services are running after update"
        else
            log_error "Some services failed to start: ${failed_services[*]}"
            log_info "Check logs: docker compose logs <service_name>"
            return 1
        fi
    else
        log_error "Failed to recreate containers"
        return 1
    fi

    log_info "Cleaning up old Docker images..."
    if cleanup_images; then
        log_success "Old images cleaned up"
    else
        log_warn "Failed to clean up old images (non-critical)"
    fi

    return 0
}

# --- System Updates ---
update_system() {
    log_info "Updating system packages..."

    if]; then
        log_info " Would run: apt update && apt upgrade"
        log_info " Would check if reboot is required"
        return 0
    fi

    if! is_root; then
        log_error "System updates require root privileges"
        log_info "Run with: sudo./update.sh --type system"
        return 1
    fi

    log_info "Updating package lists..."
    if! apt update; then
        log_error "Failed to update package lists"
        return 1
    fi

    local update_count
    update_count=$(apt list --upgradable 2>/dev/null | grep -c upgradable |

| echo "0")

    if [[ "$update_count" -eq 0 ]]; then
        log_success "System is already up to date"
        return 0
    fi

    log_info "Found $update_count package updates available"
    log_info "Available updates:"
    apt list --upgradable 2>/dev/null | grep upgradable | head -10
    if [[ "$update_count" -gt 10 ]]; then
        log_info "... and $((update_count - 10)) more packages"
    fi

    if]; then
        echo ""
        read -p "Proceed with system package updates? (y/N): " confirm_updates
        if$ ]]; then
            log_info "System updates cancelled"
            return 0
        fi
    fi

    log_info "Installing system updates (unattended)..."
    export DEBIAN_FRONTEND=noninteractive

    if apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade; then
        log_success "System packages updated successfully"
    else
        log_error "Failed to update some system packages"
        return 1
    fi

    if [[ -f /var/run/reboot-required ]]; then
        log_warn "⚠️  SYSTEM REBOOT REQUIRED"
        log_info "Some updates require a system reboot to take effect"

        if [[ -f /var/run/reboot-required.pkgs ]]; then
            log_info "Packages requiring reboot:"
            cat /var/run/reboot-required.pkgs | head -5
        fi

        if]; then
            log_warn "Auto-rebooting system (--force specified)"
            send_notification_email "System Update: Rebooting" "System update completed. Reboot is required and being initiated now."
            sleep 5
            sudo reboot
            exit 0
        else
            echo ""
            log_warn "Schedule a system reboot when convenient:"
            log_info "  sudo reboot"
        fi

        return 2
    else
        log_success "System update completed, no reboot required"
        return 0
    fi
}

# --- Health Check After Update ---
verify_system_health() {
    log_info "Verifying system health after update..."

    if]; then
        log_info " Would run health check:./health.sh"
        return 0
    fi

    sleep 5

    if./health.sh --quiet; then
        log_success "Health check passed after update"
        return 0
    else
        log_warn "Health check detected issues after update"
        log_info "Run full health check:./health.sh --comprehensive"
        return 1
    fi
}

# --- Main Execution ---
main() {
    log_info "VaultWarden Update Manager"

    if]; then
        pin_service_version "$PIN_SERVICE" "$PIN_VERSION"
        exit $?
    elif]; then
        unpin_service_version "$UNPIN_SERVICE"
        exit $?
    elif]; then
        show_pinned_versions
        exit 0
    fi

    load_env_file |

| {
        log_warn "No.env file found, using defaults (likely 'latest' tags)"
    }

    local exit_code=0
    local reboot_required=false
    local update_summary="Update job started."

    echo ""
    log_info "Update Plan:"
    case "$UPDATE_TYPE" in
        "containers")
            log_info "  - Update Docker containers (using.env pins or 'latest')"
            log_info "  - Verify service health"
            update_summary="Container update task."
            ;;
        "system")
            log_info "  - Update system packages"
            log_info "  - Check reboot requirements"
            update_summary="System update task."
            ;;
        "all")
            if]; then log_info "  - Create backup"; fi
            log_info "  - Update Docker containers (using.env pins or 'latest')"
            log_info "  - Update system packages"
            log_info "  - Verify service health"
            update_summary="Full system and container update task."
            ;;
        *)
            log_error "Unknown update type: $UPDATE_TYPE"
            log_info "Valid types: containers, system, all"
            exit 1
            ;;
    esac

    if]; then
        log_info "  - Create pre-update backup"
    elif]; then
         log_info "  - Skip pre-update backup (--no-backup specified)"
    fi

    echo ""

    if]; then
        read -p "Proceed with update? (Y/n): " confirm_proceed
        if [[ "$confirm_proceed" =~ ^[Nn]$ ]]; then
            log_info "Update cancelled"
            exit 0
        fi
    fi

    echo ""

    case "$UPDATE_TYPE" in
        "containers")
            create_backup |

| exit_code=$?
            if [[ $exit_code -eq 0 ]]; then
                update_containers |

| exit_code=$?
            fi
            update_summary="Container update completed."
            ;;
        "system")
            update_system
            case $? in
                0) update_summary="System update completed. No reboot required." ;;
                1) exit_code=1; update_summary="System update FAILED." ;;
                2) reboot_required=true; update_summary="System update completed. REBOOT REQUIRED." ;;
            esac
            ;;
        "all")
            create_backup |

| exit_code=$?
            if [[ $exit_code -eq 0 ]]; then
                update_containers |

| exit_code=$?
            fi
            if [[ $exit_code -eq 0 ]]; then
                update_system
                case $? in
                    0) update_summary="Full update completed. No reboot required." ;;
                    1) exit_code=1; update_summary="Full update FAILED during system phase." ;;
                    2) reboot_required=true; update_summary="Full update completed. REBOOT REQUIRED." ;;
                esac
            else
                update_summary="Full update FAILED during container phase."
            fi
            ;;
    esac

    if]; then
        verify_system_health |

| log_warn "Post-update health check issues detected"
    fi

    echo ""
    if [[ $exit_code -eq 0 ]]; then
        if [[ "$reboot_required" == "true" ]]; then
            log_success "Update completed successfully - REBOOT REQUIRED"
        else
            log_success "Update completed successfully"
        fi
        log_info "Update successful, no notification sent."
    else
        log_error "Update failed"
        log_info "Sending update failure email..."
        send_notification_email "Update FAILED: $UPDATE_TYPE" "$update_summary"
    fi

    echo ""
    echo "Update Summary:"
    echo "  Type: $UPDATE_TYPE"
    echo "  Status: $update_summary"
    if [[ "$reboot_required" == "true" ]]; then
        echo "  Reboot: Required"
    fi
    echo "  Completed: $(date)"

    if [[ $exit_code -ne 0 ]]; then
        echo ""
        echo "Update failed. Common troubleshooting:"
        echo "  - Check service logs: docker compose logs"
        echo "  - Verify system resources:./health.sh"
        echo "  - Restore from backup if needed:./restore.sh"
    fi

    exit $exit_code
}

main "$@"
