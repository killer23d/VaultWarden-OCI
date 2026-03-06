#!/usr/bin/env bash
# lib/docker.sh - Docker operations library for VaultWarden-OCI-NG
# ENHANCED: Reinforced standardized error handling patterns
# All functions return exit codes, callers decide exit strategy

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_DOCKER_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_DOCKER_LIB_LOADED=1

# --- Docker Availability Checks ---

# Check if Docker is installed and accessible - STANDARDIZED: Returns exit code
check_docker_available() {
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

# Check if Docker Compose plugin is available - STANDARDIZED: Returns exit code
check_compose_available() {
    docker compose version >/dev/null 2>&1
}

# Ensure Docker is ready for operations - STANDARDIZED: Returns exit code
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

# Get container status for a service - STANDARDIZED: Returns exit code
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
    return 0
}

# Check if service is running - STANDARDIZED: Returns exit code
is_service_running() {
    local service="$1"
    local status

    status=$(get_service_status "$service")
    [[ "$status" == "running" ]]
}

# Get service health status - STANDARDIZED: Returns exit code
get_service_health() {
    local service="$1"

    if ! check_docker_available; then
        echo "docker_unavailable"
        return 1
    fi

    local health
    health=$(docker compose ps "$service" --format json 2>/dev/null | jq -r '.Health // "none"' 2>/dev/null)

    echo "${health:-none}"
    return 0
}

# Check if service is healthy - STANDARDIZED: Returns exit code
is_service_healthy() {
    local service="$1"
    local status health

    status=$(get_service_status "$service")
    health=$(get_service_health "$service")

    [[ "$status" == "running" ]] && [[ "$health" =~ ^(healthy|none)$ ]]
}

# --- Service Management Operations ---

# Start services using compose - STANDARDIZED: Returns exit code
start_services() {
    local services=("$@")

    if ! require_docker; then
        return 1
    fi

    if [[ ${#services[@]} -eq 0 ]]; then
        # Start all services
        if ! docker compose up -d --remove-orphans; then
            log_error "Failed to start all services"
            return 1
        fi
    else
        # Start specific services
        if ! docker compose up -d "${services[@]}"; then
            log_error "Failed to start services: ${services[*]}"
            return 1
        fi
    fi

    return 0
}

# Stop services using compose - STANDARDIZED: Returns exit code
stop_services() {
    local services=("$@")

    if ! require_docker; then
        return 1
    fi

    if [[ ${#services[@]} -eq 0 ]]; then
        # Stop all services
        if ! docker compose stop; then
            log_error "Failed to stop all services"
            return 1
        fi
    else
        # Stop specific services
        if ! docker compose stop "${services[@]}"; then
            log_error "Failed to stop services: ${services[*]}"
            return 1
        fi
    fi

    return 0
}

# Restart services - STANDARDIZED: Returns exit code
restart_services() {
    local services=("$@")

    if ! require_docker; then
        return 1
    fi

    if [[ ${#services[@]} -eq 0 ]]; then
        # Restart all services
        if ! docker compose restart; then
            log_error "Failed to restart all services"
            return 1
        fi
    else
        # Restart specific services
        if ! docker compose restart "${services[@]}"; then
            log_error "Failed to restart services: ${services[*]}"
            return 1
        fi
    fi

    return 0
}

# Force recreate services - STANDARDIZED: Returns exit code
recreate_services() {
    local services=("$@")

    if ! require_docker; then
        return 1
    fi

    if [[ ${#services[@]} -eq 0 ]]; then
        # Recreate all services
        if ! docker compose up -d --force-recreate --remove-orphans; then
            log_error "Failed to recreate all services"
            return 1
        fi
    else
        # Recreate specific services
        if ! docker compose up -d --force-recreate "${services[@]}"; then
            log_error "Failed to recreate services: ${services[*]}"
            return 1
        fi
    fi

    return 0
}

# --- Image Management ---

# Pull latest images for services - STANDARDIZED: Returns exit code
pull_images() {
    local services=("$@")

    if ! require_docker; then
        return 1
    fi

    if [[ ${#services[@]} -eq 0 ]]; then
        # Pull all images
        if ! docker compose pull; then
            log_error "Failed to pull all images"
            return 1
        fi
    else
        # Pull specific service images
        if ! docker compose pull "${services[@]}"; then
            log_error "Failed to pull images for services: ${services[*]}"
            return 1
        fi
    fi

    return 0
}

# --- Container Execution ---

# Execute command in running service container - STANDARDIZED: Returns exit code
exec_in_service() {
    local service="$1"
    shift
    local cmd=("$@")

    if ! require_docker; then
        return 1
    fi

    if ! is_service_running "$service"; then
        log_error "Service $service is not running"
        return 1
    fi

    if ! docker compose exec "$service" "${cmd[@]}"; then
        log_error "Failed to execute command in service: $service"
        return 1
    fi

    return 0
}

# Execute command in service container - STANDARDIZED: Returns exit code
run_in_service() {
    local service="$1"
    shift
    local cmd=("$@")

    if ! require_docker; then
        return 1
    fi

    if ! docker compose run --rm "$service" "${cmd[@]}"; then
        log_error "Failed to run command in service: $service"
        return 1
    fi

    return 0
}

# --- Cleanup Operations ---

# Clean up stopped containers - STANDARDIZED: Returns exit code
cleanup_containers() {
    if ! require_docker; then
        return 1
    fi

    docker container prune -f --filter "${DOCKER_PROJECT_LABEL}" >/dev/null 2>&1
    return 0
}

# Clean up unused images - STANDARDIZED: Returns exit code
cleanup_images() {
    if ! require_docker; then
        return 1
    fi

    docker image prune -f --filter "${DOCKER_PROJECT_LABEL}" >/dev/null 2>&1
    return 0
}

# Clean up unused volumes - STANDARDIZED: Returns exit code
cleanup_volumes() {
    if ! require_docker; then
        return 1
    fi

    docker volume prune -f --filter "${DOCKER_PROJECT_LABEL}" >/dev/null 2>&1
    return 0
}

# Clean up unused networks - STANDARDIZED: Returns exit code
cleanup_networks() {
    if ! require_docker; then
        return 1
    fi

    docker network prune -f --filter "${DOCKER_PROJECT_LABEL}" >/dev/null 2>&1
    return 0
}

# Complete Docker cleanup - STANDARDIZED: Returns exit code
cleanup_docker_system() {
    local cleanup_failed=false

    if ! cleanup_containers; then
        cleanup_failed=true
    fi

    if ! cleanup_images; then
        cleanup_failed=true
    fi

    if ! cleanup_volumes; then
        cleanup_failed=true
    fi

    if ! cleanup_networks; then
        cleanup_failed=true
    fi

    if [[ "$cleanup_failed" == "true" ]]; then
        log_warn "Some Docker cleanup operations failed"
        return 1
    fi

    return 0
}

# --- Logging Operations ---

# Get logs for service - STANDARDIZED: Returns exit code
get_service_logs() {
    local service="$1"
    local lines="${2:-100}"

    if ! require_docker; then
        return 1
    fi

    if ! docker compose logs --tail="$lines" "$service"; then
        log_error "Failed to get logs for service: $service"
        return 1
    fi

    return 0
}

# Follow logs for service - STANDARDIZED: Returns exit code
follow_service_logs() {
    local service="$1"

    if ! require_docker; then
        return 1
    fi

    if ! docker compose logs -f "$service"; then
        log_error "Failed to follow logs for service: $service"
        return 1
    fi

    return 0
}

# --- Validation Helpers ---

# Wait for service to be ready - STANDARDIZED: Returns exit code
wait_for_service_ready() {
    local service="$1"
    local timeout="${2:-60}"
    local count=0

    while [[ $count -lt $timeout ]]; do
        if is_service_healthy "$service"; then
            return 0
        fi

        sleep 1
        count=$((count + 1))
    done

    log_error "Service $service did not become ready within ${timeout}s"
    return 1
}

# Validate compose file syntax - STANDARDIZED: Returns exit code
validate_compose_file() {
    local compose_file="${1:-docker-compose.yml}"

    if ! require_docker; then
        return 1
    fi

    if [[ ! -f "$compose_file" ]]; then
        log_error "Compose file not found: $compose_file"
        return 1
    fi

    if ! docker compose -f "$compose_file" config --quiet >/dev/null 2>&1; then
        log_error "Compose file validation failed: $compose_file"
        return 1
    fi

    return 0
}

# Export functions for use by scripts
export -f check_docker_available check_compose_available require_docker
export -f get_service_status is_service_running get_service_health is_service_healthy
export -f start_services stop_services restart_services recreate_services
export -f pull_images exec_in_service run_in_service
export -f cleanup_containers cleanup_images cleanup_volumes cleanup_networks cleanup_docker_system
export -f get_service_logs follow_service_logs wait_for_service_ready validate_compose_file

log_debug "Enhanced Docker library loaded successfully - standardized error handling" 2>/dev/null || true
