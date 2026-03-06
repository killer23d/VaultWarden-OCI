#!/usr/bin/env bash
# lib/docker.sh - Docker operations library for VaultWarden-OCI-NG
# ENHANCED: Reinforced standardized error handling patterns
# All functions return exit codes, callers decide exit strategy
#
# PATCHED BUGS (2026-03-06):
#   BUG-D1 [MEDIUM] wait_for_service_ready(): trailing newline after progress
#                   dots was emitted unconditionally, producing a spurious
#                   blank line when the service was ready before any dots
#                   were printed. Added dots_printed flag.
#   BUG-D2 [MEDIUM] exec_oneshot_in_service(): 'docker container start
#                   --attach' mixed the container's stderr with the host
#                   shell's log output and could miss output from very fast-
#                   exiting containers. Replaced with start→wait→logs→rm.
#   BUG-D3 [LOW]    _docker_prune_filter(): emitted '--filter VALUE' as one
#                   token. Word-splitting in callers requires two tokens.
#                   Changed to emit two newline-separated tokens and updated
#                   all four cleanup_*() callers to use mapfile + array.

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

check_docker_available() {
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

check_compose_available() {
    docker compose version >/dev/null 2>&1
}

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

# Get container status for a service
#
# [MEDIUM FIX] docker compose ps --format json returns a JSON array when
# multiple replicas are running. The jq filter handles both scalar and array.
# [MEDIUM FIX] Added require_jq() guard.
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

    local status
    status=$(printf '%s' "$raw_json" \
        | jq -r 'if type == "array" then .[0].State // "not_found" else .State // "not_found" end' 2>/dev/null)

    echo "${status:-not_found}"
    return 0
}

is_service_running() {
    local service="$1"
    local status
    status=$(get_service_status "$service")
    [[ "$status" == "running" ]]
}

# Get service health status
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

is_service_healthy() {
    local service="$1"
    local status health
    status=$(get_service_status "$service")
    health=$(get_service_health "$service")
    [[ "$status" == "running" ]] && [[ "$health" =~ ^(healthy|none)$ ]]
}

# --- Service Management Operations ---

start_services() {
    local services=("$@")
    if ! require_docker; then return 1; fi
    if [[ ${#services[@]} -eq 0 ]]; then
        if ! docker compose up -d --remove-orphans; then
            log_error "Failed to start all services"
            return 1
        fi
    else
        if ! docker compose up -d "${services[@]}"; then
            log_error "Failed to start services: ${services[*]}"
            return 1
        fi
    fi
    return 0
}

stop_services() {
    local services=("$@")
    if ! require_docker; then return 1; fi
    if [[ ${#services[@]} -eq 0 ]]; then
        if ! docker compose stop; then
            log_error "Failed to stop all services"
            return 1
        fi
    else
        if ! docker compose stop "${services[@]}"; then
            log_error "Failed to stop services: ${services[*]}"
            return 1
        fi
    fi
    return 0
}

restart_services() {
    local services=("$@")
    if ! require_docker; then return 1; fi
    if [[ ${#services[@]} -eq 0 ]]; then
        if ! docker compose restart; then
            log_error "Failed to restart all services"
            return 1
        fi
    else
        if ! docker compose restart "${services[@]}"; then
            log_error "Failed to restart services: ${services[*]}"
            return 1
        fi
    fi
    return 0
}

recreate_services() {
    local services=("$@")
    if ! require_docker; then return 1; fi
    if [[ ${#services[@]} -eq 0 ]]; then
        if ! docker compose up -d --force-recreate --remove-orphans; then
            log_error "Failed to recreate all services"
            return 1
        fi
    else
        if ! docker compose up -d --force-recreate "${services[@]}"; then
            log_error "Failed to recreate services: ${services[*]}"
            return 1
        fi
    fi
    return 0
}

# --- Image Management ---

pull_images() {
    local services=("$@")
    if ! require_docker; then return 1; fi
    if [[ ${#services[@]} -eq 0 ]]; then
        if ! docker compose pull; then
            log_error "Failed to pull all images"
            return 1
        fi
    else
        if ! docker compose pull "${services[@]}"; then
            log_error "Failed to pull images for services: ${services[*]}"
            return 1
        fi
    fi
    return 0
}

# --- Container Execution ---

exec_in_service() {
    local service="$1"
    shift
    local cmd=("$@")
    if ! require_docker; then return 1; fi
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
# exec_oneshot_in_service  (replacement for run_in_service --rm)
#
# CAVEAT: This function resolves the image from the Compose config but does
# NOT inherit the service's environment variables, volume mounts, network
# aliases, or Docker labels. It is intended for simple validation commands
# that only need the image binary. For commands requiring the full service
# environment, use exec_in_service() against a running container instead.
#
# BUG-D2 FIX: 'docker container start --attach' was replaced with a
# start→wait→logs→rm sequence. Benefits:
#   1. Decouples output capture from execution — no missed output on
#      very fast-exiting containers.
#   2. Container's stderr no longer mixes inline with host log_error output.
#   3. Exit code is captured cleanly via 'docker container wait'.
# ---------------------------------------------------------------------------
exec_oneshot_in_service() {
    local service="$1"
    shift
    local cmd=("$@")

    if ! require_docker; then
        return 1
    fi

    if ! require_jq; then
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
    container_id=$(docker container create "$image" "${cmd[@]}" 2>/dev/null) || {
        log_error "Failed to create one-shot container for service: $service"
        return 1
    }

    # BUG-D2 FIX: start detached, wait for exit, replay logs, then remove.
    docker container start "$container_id" >/dev/null 2>&1 || true

    local exit_code=0
    exit_code=$(docker container wait "$container_id" 2>/dev/null) || exit_code=1

    # Replay container output (stdout+stderr) through our logger.
    docker container logs "$container_id" 2>&1 || true

    docker container rm -f "$container_id" >/dev/null 2>&1 || true

    return "${exit_code:-1}"
}

# run_in_service — DEPRECATED: use exec_oneshot_in_service() instead.
run_in_service() {
    log_warn "run_in_service() is deprecated; use exec_oneshot_in_service() to avoid" \
              "depends_on health-condition conflicts with --rm containers."
    local service="$1"
    shift
    local cmd=("$@")
    if ! require_docker; then return 1; fi
    if ! docker compose run --rm "$service" "${cmd[@]}"; then
        log_error "Failed to run command in service: $service"
        return 1
    fi
    return 0
}

# --- Cleanup Operations ---

# _docker_prune_filter  — emit --filter args as separate newline-delimited tokens
#
# BUG-D3 FIX: the previous implementation emitted '--filter VALUE' as a single
# string. Callers used unquoted $(_docker_prune_filter) for word-splitting, but
# that only works reliably when the two tokens are separated by IFS whitespace.
# Using printf '%s\n' for each token and mapfile in callers is the correct
# approach: it handles label values that contain spaces and avoids SC2046.
#
# Callers should use:
#   mapfile -t _prune_args < <(_docker_prune_filter)
#   docker prune -f "${_prune_args[@]}"
_docker_prune_filter() {
    if [[ -n "${DOCKER_PROJECT_LABEL:-}" ]]; then
        printf -- '--filter\n%s\n' "${DOCKER_PROJECT_LABEL}"
    fi
}

# Clean up stopped containers
cleanup_containers() {
    if ! require_docker; then return 1; fi
    local _prune_args=()
    mapfile -t _prune_args < <(_docker_prune_filter)
    docker container prune -f "${_prune_args[@]}" >/dev/null 2>&1
    return 0
}

# Clean up unused images
cleanup_images() {
    if ! require_docker; then return 1; fi
    local _prune_args=()
    mapfile -t _prune_args < <(_docker_prune_filter)
    docker image prune -f "${_prune_args[@]}" >/dev/null 2>&1
    return 0
}

# Clean up unused volumes
cleanup_volumes() {
    if ! require_docker; then return 1; fi
    local _prune_args=()
    mapfile -t _prune_args < <(_docker_prune_filter)
    docker volume prune -f "${_prune_args[@]}" >/dev/null 2>&1
    return 0
}

# Clean up unused networks
cleanup_networks() {
    if ! require_docker; then return 1; fi
    local _prune_args=()
    mapfile -t _prune_args < <(_docker_prune_filter)
    docker network prune -f "${_prune_args[@]}" >/dev/null 2>&1
    return 0
}

# Complete Docker cleanup
cleanup_docker_system() {
    local cleanup_failed=false
    if ! cleanup_containers; then cleanup_failed=true; fi
    if ! cleanup_images;    then cleanup_failed=true; fi
    if ! cleanup_volumes;   then cleanup_failed=true; fi
    if ! cleanup_networks;  then cleanup_failed=true; fi
    if [[ "$cleanup_failed" == "true" ]]; then
        log_warn "Some Docker cleanup operations failed"
        return 1
    fi
    return 0
}

# --- Logging Operations ---

get_service_logs() {
    local service="$1"
    local lines="${2:-250}"
    if ! require_docker; then return 1; fi
    if ! docker compose logs --tail="$lines" "$service"; then
        log_error "Failed to get logs for service: $service"
        return 1
    fi
    return 0
}

follow_service_logs() {
    local service="$1"
    if ! require_docker; then return 1; fi
    if ! docker compose logs -f "$service"; then
        log_error "Failed to follow logs for service: $service"
        return 1
    fi
    return 0
}

# --- Validation Helpers ---

# Wait for service to be ready
#
# BUG-D1 FIX: the trailing 'echo ""' (newline after progress dots) was
# emitted unconditionally. When the service became ready in less than
# dot_interval (5) seconds no dots were ever printed, producing a spurious
# blank line in log output.
# Added a dots_printed flag that is set to true on the first dot emission
# and checked before printing the trailing newline.
wait_for_service_ready() {
    local service="$1"
    local timeout="${2:-60}"
    local count=0
    local dot_interval=5
    local dots_printed=false   # BUG-D1 FIX: track whether any dots were emitted

    log_info "Waiting for service '$service' to become ready (timeout: ${timeout}s)..."

    while [[ $count -lt $timeout ]]; do
        if is_service_healthy "$service"; then
            # BUG-D1 FIX: only emit newline if we actually printed dots
            [[ "$dots_printed" == "true" ]] && echo "" >&2
            log_success "Service '$service' is ready (${count}s)"
            return 0
        fi

        if (( count % dot_interval == 0 && count > 0 )); then
            printf '.' >&2
            dots_printed=true
        fi

        sleep 1
        count=$(( count + 1 ))
    done

    [[ "$dots_printed" == "true" ]] && echo "" >&2
    log_error "Service '$service' did not become ready within ${count}s (timeout: ${timeout}s)"
    return 1
}

validate_compose_file() {
    local compose_file="${1:-docker-compose.yml}"
    if ! require_docker; then return 1; fi
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
