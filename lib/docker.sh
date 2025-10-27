#!/usr/bin/env bash
# lib/docker.sh - Docker operations library for VaultWarden-OCI-NG
# Focused Docker helper functions

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_DOCKER_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_DOCKER_LIB_LOADED=1

# --- Docker Availability Checks ---

# Check if Docker is installed and accessible
check_docker_available() {
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

# Check if Docker Compose plugin is available
check_compose_available() {
    docker compose version >/dev/null 2>&1
}

# Ensure Docker is ready for operations
require_docker() {
    if ! check_docker_available; then
        log_error "Docker not available or daemon not running"
        log_info "Try: sudo systemctl start docker"
        return 1
    fi

    if ! check_compose_available; then
        log_error "Docker Compose plugin not available"
        log_info "Install with: sudo apt install docker-compose-plugin"
        return 1
    fi

    return 0
}

# --- Container Status Operations ---

# Get container status for a service
get_service_status() {
    local service="$1"

    if ! check_docker_available; then
        echo "docker_unavailable"
        return 1
    fi

    # Use compose ps with JSON format for reliable parsing
    local status
    status=$(docker compose ps "$service" --format json 2>/dev/null | jq -r '.State // "not_found"' 2>/dev/null)

    echo "${status:-not_found}"
}

# Check if service is running
is_service_running() {
    local service="$1"
    local status

    status=$(get_service_status "$service")
    [[ "$status" == "running" ]]
}

# Get service health status
get_service_health() {
    local service="$1"

    if ! check_docker_available; then
        echo "docker_unavailable"
        return 1
    fi

    local health
    health=$(docker compose ps "$service" --format json 2>/dev/null | jq -r '.Health // "none"' 2>/dev/null)

    echo "${health:-none}"
}

# Check if service is healthy (running + healthy status)
is_service_healthy() {
    local service="$1"
    local status health

    status=$(get_service_status "$service")
    health=$(get_service_health "$service")

    [[ "$status" == "running" ]] && [[ "$health" =~ ^(healthy|none)$ ]]
}

# --- Service Management Operations ---

# Start services using compose
start_services() {
    local services=("$@")

    require_docker || return 1

    if [[ ${#services[@]} -eq 0 ]]; then
        # Start all services
        docker compose up -d --remove-orphans
    else
        # Start specific services
        docker compose up -d "${services[@]}"
    fi
}

# Stop services using compose
stop_services() {
    local services=("$@")

    require_docker || return 1

    if [[ ${#services[@]} -eq 0 ]]; then
        # Stop all services
        docker compose down --remove-orphans
    else
        # Stop specific services
        docker compose stop "${services[@]}"
    fi
}

# Restart services
restart_services() {
    local services=("$@")

    require_docker || return 1

    if [[ ${#services[@]} -eq 0 ]]; then
        # Restart all services
        docker compose restart
    else
        # Restart specific services
        docker compose restart "${services[@]}"
    fi
}

# Force recreate services (useful for updates)
recreate_services() {
    local services=("$@")

    require_docker || return 1

    if [[ ${#services[@]} -eq 0 ]]; then
        # Recreate all services
        docker compose up -d --force-recreate --remove-orphans
    else
        # Recreate specific services
        docker compose up -d --force-recreate "${services[@]}"
    fi
}

# --- Image Management ---

# Pull latest images for services
pull_images() {
    local services=("$@")

    require_docker || return 1

    if [[ ${#services[@]} -eq 0 ]]; then
        # Pull all images
        docker compose pull
    else
        # Pull specific service images
        docker compose pull "${services[@]}"
    fi
}

# --- FIX #6: Removed has_image_updates function ---

# --- Container Execution ---

# Execute command in running service container
exec_in_service() {
    local service="$1"
    shift
    local cmd=("$@")

    require_docker || return 1

    if ! is_service_running "$service"; then
        return 1
    fi

    docker compose exec "$service" "${cmd[@]}"
}

# Execute command in service container (creates temporary container if not running)
run_in_service() {
    local service="$1"
    shift
    local cmd=("$@")

    require_docker || return 1

    docker compose run --rm "$service" "${cmd[@]}"
}

# --- Cleanup Operations ---

# Clean up stopped containers
cleanup_containers() {
    require_docker || return 1

    docker container prune -f >/dev/null 2>&1
}

# Clean up unused images
cleanup_images() {
    require_docker || return 1

    docker image prune -f >/dev/null 2>&1
}

# Clean up unused volumes (be careful!)
cleanup_volumes() {
    require_docker || return 1

    docker volume prune -f >/dev/null 2>&1
}

# Clean up unused networks
cleanup_networks() {
    require_docker || return 1

    docker network prune -f >/dev/null 2>&1
}

# Complete Docker cleanup
cleanup_docker_system() {
    cleanup_containers
    cleanup_images
    cleanup_volumes
    cleanup_networks
}

# --- Logging Operations ---

# Get logs for service
get_service_logs() {
    local service="$1"
    local lines="${2:-100}"

    require_docker || return 1

    docker compose logs --tail="$lines" "$service"
}

# Follow logs for service
follow_service_logs() {
    local service="$1"

    require_docker || return 1

    docker compose logs -f "$service"
}

# --- Validation Helpers ---

# Wait for service to be ready (running + healthy)
wait_for_service_ready() {
    local service="$1"
    local timeout="${2:-60}"
    local count=0

    while [[ $count -lt $timeout ]]; do
        if is_service_healthy "$service"; then
            return 0
        fi

        sleep 1
        ((count++))
    done

    return 1
}

# Validate compose file syntax
validate_compose_file() {
    local compose_file="${1:-docker-compose.yml}"

    require_docker || return 1

    if [[ ! -f "$compose_file" ]]; then
        return 1
    fi

    docker compose -f "$compose_file" config --quiet >/dev/null 2>&1
}

# Export functions for use by scripts
export -f check_docker_available check_compose_available require_docker
export -f get_service_status is_service_running get_service_health is_service_healthy
export -f start_services stop_services restart_services recreate_services
export -f pull_images exec_in_service run_in_service
export -f cleanup_containers cleanup_images cleanup_volumes cleanup_networks cleanup_docker_system
export -f get_service_logs follow_service_logs wait_for_service_ready validate_compose_file

log_debug "Docker library loaded successfully" 2>/dev/null || true
