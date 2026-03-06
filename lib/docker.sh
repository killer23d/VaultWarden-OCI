#!/usr/bin/env bash
# lib/docker.sh - Docker operations library for VaultWarden-OCI-NG
# ENHANCED: Reinforced standardized error handling patterns
# All functions return exit codes, callers decide exit strategy

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_DOCKER_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_DOCKER_LIB_LOADED=1

# ---------------------------------------------------------------------------
# DOCKER_PROJECT_LABEL — default guard
#
# [MEDIUM FIX] The cleanup_*() functions pass this value as a --filter
# argument to `docker prune`. If the caller has not set the variable, the
# empty string would produce `--filter ''` which causes docker to error OR,
# worse, to match every object on the host. Default to the Compose project
# label so only this project's resources are pruned.
# ---------------------------------------------------------------------------
DOCKER_PROJECT_LABEL="${DOCKER_PROJECT_LABEL:-label=com.docker.compose.project=vaultwarden-oci}"
export DOCKER_PROJECT_LABEL

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

# ---------------------------------------------------------------------------
# require_jq  (FIX [MEDIUM] — jq dependency undeclared)
#
# jq is used by get_service_status() and get_service_health() to parse
# docker compose ps --format json output.  Without a guard, absent jq causes
# the pipeline to fail silently and every container is reported as 'not_found'.
#
# This guard is called at the top of both functions; it logs a clear,
# actionable error message and returns 1 so callers can propagate the failure.
# ---------------------------------------------------------------------------
require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq is required but not installed."
        log_info  "Install with: sudo apt-get install -y jq"
        return 1
    fi
    return 0
}

# --- Container Status Operations ---

# Get container status for a service - STANDARDIZED: Returns exit code
#
# [MEDIUM FIX] docker compose ps --format json returns a JSON array when
# multiple replicas are running. The jq filter now handles both:
#   - Single object:  { "State": "running" }
#   - Array:          [ { "State": "running" }, ... ]
# The first element is used in the array case, consistent with service-level
# health checks (we report the state of the first/only container).
#
# [MEDIUM FIX] Added require_jq() guard so absent jq produces a clear error
# instead of silently reporting every service as 'not_found'.
get_service_status() {
    local service="$1"

    if ! check_docker_available; then
        echo "docker_unavailable"
        return 1
    fi

    if ! require_jq; then
        echo "jq_unavailable"
        return 1
    fi

    local raw_json
    raw_json=$(docker compose ps "$service" --format json 2>/dev/null)

    # Handle both scalar object and array responses from docker compose ps
    local status
    status=$(printf '%s' "$raw_json" \
        | jq -r 'if type == "array" then .[0].State // "not_found" else .State // "not_found" end' 2>/dev/null)

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
#
# [MEDIUM FIX] Same jq array-vs-object fix as get_service_status().
# [MEDIUM FIX] Added require_jq() guard.
get_service_health() {
    local service="$1"

    if ! check_docker_available; then
        echo "docker_unavailable"
        return 1
    fi

    if ! require_jq; then
        echo "jq_unavailable"
        return 1
    fi

    local raw_json
    raw_json=$(docker compose ps "$service" --format json 2>/dev/null)

    local health
    health=$(printf '%s' "$raw_json" \
        | jq -r 'if type == "array" then .[0].Health // "none" else .Health // "none" end' 2>/dev/null)

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

# ---------------------------------------------------------------------------
# exec_oneshot_in_service  (FIX [LOW] — replaces run_in_service with --rm)
#
# The original run_in_service() used `docker compose run --rm`, which is
# incompatible with services that have `depends_on:` health conditions
# because Compose re-evaluates the dependency graph on every `run` and the
# ephemeral --rm container is not tracked by the health machinery.
#
# This replacement uses the lower-level docker container lifecycle:
#   create → start → wait → logs → rm
# so the transient container never interferes with the Compose dependency
# graph and is always cleaned up regardless of exit code.
# ---------------------------------------------------------------------------
exec_oneshot_in_service() {
    local service="$1"
    shift
    local cmd=("$@")

    if ! require_docker; then
        return 1
    fi

    local image
    image=$(docker compose config --format json 2>/dev/null \
        | jq -r ".services.\"${service}\".image // empty" 2>/dev/null)
    if [[ -z "$image" ]]; then
        log_error "exec_oneshot_in_service: could not resolve image for service '$service'"
        return 1
    fi

    local container_id
    container_id=$(docker container create --rm=false "$image" "${cmd[@]}" 2>/dev/null) || {
        log_error "Failed to create one-shot container for service: $service"
        return 1
    }

    local exit_code=0
    docker container start --attach "$container_id" 2>&1 || exit_code=$?
    docker container rm -f "$container_id" >/dev/null 2>&1 || true

    return "$exit_code"
}

# run_in_service — DEPRECATED: use exec_oneshot_in_service() instead.
#
# Kept as a compatibility alias. The --rm flag is retained here so existing
# call-sites that do not use depends_on health conditions continue to work,
# but a warning is emitted to encourage migration.
run_in_service() {
    log_warn "run_in_service() is deprecated; use exec_oneshot_in_service() to avoid" \
              "depends_on health-condition conflicts with --rm containers."
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

# _docker_prune_filter  — emit --filter arg only if DOCKER_PROJECT_LABEL is set
#
# [MEDIUM FIX] Guard against empty DOCKER_PROJECT_LABEL, which would make
# `docker prune --filter ''` match every object on the host.
_docker_prune_filter() {
    if [[ -n "${DOCKER_PROJECT_LABEL:-}" ]]; then
        printf -- '--filter %s' "${DOCKER_PROJECT_LABEL}"
    fi
}

# Clean up stopped containers - STANDARDIZED: Returns exit code
cleanup_containers() {
    if ! require_docker; then
        return 1
    fi

    # shellcheck disable=SC2046  # intentional: may be empty
    docker container prune -f $(_docker_prune_filter) >/dev/null 2>&1
    return 0
}

# Clean up unused images - STANDARDIZED: Returns exit code
cleanup_images() {
    if ! require_docker; then
        return 1
    fi

    # shellcheck disable=SC2046
    docker image prune -f $(_docker_prune_filter) >/dev/null 2>&1
    return 0
}

# Clean up unused volumes - STANDARDIZED: Returns exit code
cleanup_volumes() {
    if ! require_docker; then
        return 1
    fi

    # shellcheck disable=SC2046
    docker volume prune -f $(_docker_prune_filter) >/dev/null 2>&1
    return 0
}

# Clean up unused networks - STANDARDIZED: Returns exit code
cleanup_networks() {
    if ! require_docker; then
        return 1
    fi

    # shellcheck disable=SC2046
    docker network prune -f $(_docker_prune_filter) >/dev/null 2>&1
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
#
# FIX [LOW]: Default raised from 100 → 250 lines. Callers requiring full
# context (e.g. post-incident review) should pass a larger value or "all".
# The variable name 'lines' is kept for readability; callers may pass "all"
# to fetch the complete log, e.g.: get_service_logs vaultwarden all
get_service_logs() {
    local service="$1"
    local lines="${2:-250}"

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
#
# [MEDIUM FIX] Added progress reporting every 5 seconds so operators are
# not left wondering whether the script has hung. The error message now
# includes the actual elapsed time for easier debugging.
wait_for_service_ready() {
    local service="$1"
    local timeout="${2:-60}"
    local count=0
    local dot_interval=5

    log_info "Waiting for service '$service' to become ready (timeout: ${timeout}s)..."

    while [[ $count -lt $timeout ]]; do
        if is_service_healthy "$service"; then
            echo ""  # newline after progress dots
            log_success "Service '$service' is ready (${count}s)"
            return 0
        fi

        # Print a progress dot every dot_interval seconds
        if (( count % dot_interval == 0 && count > 0 )); then
            printf '.' >&2
        fi

        sleep 1
        count=$((count + 1))
    done

    echo "" >&2
    log_error "Service '$service' did not become ready within ${count}s (timeout: ${timeout}s)"
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
export -f check_docker_available check_compose_available require_docker require_jq
export -f get_service_status is_service_running get_service_health is_service_healthy
export -f start_services stop_services restart_services recreate_services
export -f pull_images exec_in_service exec_oneshot_in_service run_in_service
export -f _docker_prune_filter
export -f cleanup_containers cleanup_images cleanup_volumes cleanup_networks cleanup_docker_system
export -f get_service_logs follow_service_logs wait_for_service_ready validate_compose_file

log_debug "Enhanced Docker library loaded successfully - standardized error handling" 2>/dev/null || true
