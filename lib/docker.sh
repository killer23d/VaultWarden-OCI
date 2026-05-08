#!/usr/bin/env bash
# lib/docker.sh - Docker operations library for VaultWarden-OCI-NG
# ENHANCED: Reinforced standardized error handling patterns
# All functions return exit codes, callers decide exit strategy

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_DOCKER_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_DOCKER_LIB_LOADED=1

set -euo pipefail

# ---------------------------------------------------------------------------
# DOCKER_PROJECT_LABEL — default guard
#
# The cleanup_*() functions pass this value as a --filter argument to
# `docker prune`. If the caller has not set the variable, the empty string
# would produce `--filter ''` which causes docker to error OR, worse, to
# match every object on the host. Default to the Compose project label so
# only this project's resources are pruned.
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
# require_jq
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
# docker compose ps --format json returns a JSON array when multiple replicas
# are running. The jq filter handles both scalar and array.
# Validates raw output is valid JSON before piping to jq; returns "not_found"
# gracefully on Compose v1 plain-text or other non-JSON output.
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

    # Guard against non-JSON output (Compose v1, plain-text mode)
    if ! printf '%s' "$raw_json" | jq -e . >/dev/null 2>&1; then
        log_debug "get_service_status: non-JSON output from docker compose ps for '$service'; falling back to not_found"
        echo "not_found"
        return 0
    fi

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
# docker compose ps --format json returns a JSON array when multiple replicas
# are running. The jq filter handles both scalar and array.
# An empty Health field (no HEALTHCHECK defined) is explicitly mapped to
# "none" so callers never see an empty string.
# Validates raw output is valid JSON before piping to jq.
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

    # Guard against non-JSON output (Compose v1, plain-text mode)
    if ! printf '%s' "$raw_json" | jq -e . >/dev/null 2>&1; then
        log_debug "get_service_health: non-JSON output from docker compose ps for '$service'; falling back to none"
        echo "none"
        return 0
    fi

    local health
    # Empty string and null both map to "none" via // "none"
    health=$(printf '%s' "$raw_json" \
        | jq -r 'if type == "array" then (.[0].Health // "none") else (.Health // "none") end' 2>/dev/null)

    # Extra guard: if jq somehow emits an empty string, normalise to "none"
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

# Helper — returns 0 when a service has no HEALTHCHECK defined.
# Used by wait_for_service_ready() to short-circuit the polling loop.
_service_has_no_healthcheck() {
    local service="$1"
    local health
    health=$(get_service_health "$service")
    [[ "$health" == "none" ]]
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

# ---------------------------------------------------------------------------
# pull_images
#
# Uses --quiet to suppress per-layer progress bars. Without it, a full pull
# of the four project images (vaultwarden, caddy, fail2ban, postfix) produces
# several hundred KB of output per run that floods the systemd journal on
# every update-timer invocation. On a VPS with a limited SystemMaxUse journal
# cap this noise evicts genuinely useful log lines.
#
# stderr is merged and passed through `tail -5` so only the last 5 lines
# (summary digests or any error message) reach the journal. Pull errors are
# still surfaced: docker compose pull --quiet exits non-zero on failure and
# the error text appears in the final tail output.
# ---------------------------------------------------------------------------
pull_images() {
    local services=("$@")
    if ! require_docker; then return 1; fi
    if [[ ${#services[@]} -eq 0 ]]; then
        if ! docker compose pull --quiet 2>&1 | tail -5; then
            log_error "Failed to pull all images"
            return 1
        fi
    else
        if ! docker compose pull --quiet "${services[@]}" 2>&1 | tail -5; then
            log_error "Failed to pull images for services: ${services[*]}"
            return 1
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# pull_image_with_retry
#
# Retries a `docker pull` up to MAX_RETRIES times with exponential backoff.
# Permanent errors (image not found, auth failure, etc.) cause an immediate
# bail-out rather than exhausting all retries.
#
# Usage: pull_image_with_retry <image> [max_retries] [initial_sleep_seconds]
#   max_retries:        default 3
#   initial_sleep_secs: default 5  (doubles each attempt: 5→10→20)
# ---------------------------------------------------------------------------
pull_image_with_retry() {
    local image="$1"
    local max_retries="${2:-3}"
    local sleep_secs="${3:-5}"

    if ! require_docker; then return 1; fi

    local attempt=1
    while [[ $attempt -le $max_retries ]]; do
        local pull_output pull_rc
        pull_output=$(docker pull "$image" 2>&1)
        pull_rc=$?

        if [[ $pull_rc -eq 0 ]]; then
            log_debug "pull_image_with_retry: pulled '$image' on attempt $attempt"
            return 0
        fi

        # Detect permanent errors and bail immediately — these indicate
        # the image reference itself is invalid or the credentials are wrong;
        # retrying will not help.
        local lower_output
        lower_output=$(printf '%s' "$pull_output" | tr '[:upper:]' '[:lower:]')
        if printf '%s' "$lower_output" | grep -qE \
            'not found|unauthorized|denied|does not exist|no such manifest|manifest unknown|access forbidden'; then
            log_error "pull_image_with_retry: permanent error pulling '$image' (attempt $attempt): ${pull_output}"
            return 1
        fi

        log_warn "pull_image_with_retry: transient error pulling '$image' (attempt $attempt/$max_retries, retry in ${sleep_secs}s): ${pull_output}"

        if [[ $attempt -lt $max_retries ]]; then
            sleep "$sleep_secs"
            sleep_secs=$(( sleep_secs * 2 ))  # exponential backoff
        fi

        attempt=$(( attempt + 1 ))
    done

    log_error "pull_image_with_retry: failed to pull '$image' after $max_retries attempts"
    return 1
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
# environment (env vars, volumes, networks) against a stopped service,
# use run_in_service_full_env() instead.
#
# 'docker container start --attach' was replaced with a
# start→wait→logs→rm sequence. Benefits:
#   1. Decouples output capture from execution — no missed output on
#      very fast-exiting containers.
#   2. Container's stderr no longer mixes inline with host log_error output.
#   3. Exit code is captured cleanly via 'docker container wait'.
#
# docker container start exit code is now checked explicitly.
# If start fails (OOM, volume mount error, etc.) the orphaned container is
# removed and the function returns 1 immediately instead of hanging forever
# on docker container wait.
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

    # DOC-H1 FIX: capture start exit code explicitly; do NOT use || true.
    # If start fails, clean up the orphaned container and return 1 immediately
    # rather than hanging forever on 'docker container wait'.
    local start_rc=0
    docker container start "$container_id" >/dev/null 2>&1 || start_rc=$?
    if [[ $start_rc -ne 0 ]]; then
        log_error "exec_oneshot_in_service: 'docker container start' failed (rc=${start_rc}) for service '$service'"
        local docker_err
        if ! docker_err=$(docker container rm -f "$container_id" >/dev/null 2>&1); then
            log_debug "exec_oneshot_in_service: docker container rm failed (non-fatal): $docker_err"
        fi
        return 1
    fi

    local exit_code=0
    exit_code=$(docker container wait "$container_id" 2>/dev/null) || exit_code=1

    # Replay container output (stdout+stderr) through our logger.
    docker container logs "$container_id" 2>&1 || true

    local docker_err
    if ! docker_err=$(docker container rm -f "$container_id" >/dev/null 2>&1); then
        log_debug "exec_oneshot_in_service: docker container rm failed (non-fatal): $docker_err"
    fi

    return "${exit_code:-1}"
}

# ---------------------------------------------------------------------------
# run_in_service_full_env  (DOC-M1: new helper — full service environment)
#
# Unlike exec_oneshot_in_service(), this function uses `docker compose run
# --rm` which inherits ALL service settings from docker-compose.yml:
# environment variables, volume mounts, network aliases, labels, etc.
# Works against both running and stopped services.
#
# Usage:
#   run_in_service_full_env <service> <cmd> [args...]
#
# NOTE: `docker compose run --rm` will start the service's depends_on
# containers if they are not already running. If the depends_on containers
# have health conditions, this may block until they are healthy.
# ---------------------------------------------------------------------------
run_in_service_full_env() {
    local service="$1"
    shift
    local cmd=("$@")

    if ! require_docker; then return 1; fi

    if ! docker compose run --rm "$service" "${cmd[@]}"; then
        log_error "run_in_service_full_env: command failed in service '$service'"
        return 1
    fi
    return 0
}

# run_in_service — DEPRECATED (DOC-L1): calling this function is now a hard
# error. Use exec_oneshot_in_service() for image-only one-shots, or
# run_in_service_full_env() for commands that require the full service
# environment. This stub is retained only to produce an actionable error
# message for any script that accidentally calls the old API.
# NOTE: removed from export -f so subshells cannot inherit it silently.
run_in_service() {
    log_error "run_in_service() has been removed. "\
              "Use exec_oneshot_in_service() or run_in_service_full_env() instead."
    return 1
}

# --- Cleanup Operations ---

# _docker_prune_filter  — emit --filter args as separate newline-delimited tokens
#
# Emits '--filter VALUE' as separate tokens using printf '%s\n'.
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
    local docker_err
    if ! docker_err=$(docker container prune -f "${_prune_args[@]}" 2>&1 >/dev/null); then
        log_debug "cleanup_containers: docker container prune failed (non-fatal): $docker_err"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# cleanup_images  (IMG-R1 FIX)
#
# Removes dangling (untagged) image layers that are older than 48 hours.
#
# The --filter "until=48h" guard preserves the most recent two days of
# pulled image layers as a passive rollback buffer. This is important
# because the maintenance timer runs independently of maintenance.sh update 's own
# snapshot/rollback mechanism: without a time filter, a routine maintenance
# run shortly after a bad update could destroy the previous image layers
# before the operator has had a chance to validate or roll back.
#
# Rationale for NOT using --all:
#   `docker image prune` without --all only removes *dangling* images —
#   untagged layers that are no longer referenced by any tag or container.
#   Named, tagged images in active use are never affected regardless of
#   the time filter. Adding --all would also remove unused-but-tagged
#   images (e.g. a previous version still tagged locally), which is
#   outside the intended scope of routine maintenance cleanup.
# ---------------------------------------------------------------------------
cleanup_images() {
    if ! require_docker; then return 1; fi
    local _prune_args=()
    mapfile -t _prune_args < <(_docker_prune_filter)
    local docker_err
    # IMG-R1 FIX: --filter "until=48h" retains the last 48 hours of dangling
    # image layers as a rollback buffer; see function header for rationale.
    if ! docker_err=$(docker image prune -f --filter "until=48h" "${_prune_args[@]}" 2>&1 >/dev/null); then
        log_debug "cleanup_images: docker image prune failed (non-fatal): $docker_err"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# cleanup_volumes  (DOC-M2 FIX)
#
# `docker volume prune --filter label=` was added in Docker Engine 25.0.
# On older engines (Docker 20.x common on OCI free-tier) the flag is silently
# ignored and ALL anonymous volumes on the host are pruned — including those
# belonging to unrelated projects.
#
# Fix: detect the Docker Engine major version at call time.
#   >= 25 → use docker volume prune -f with label filter (original behaviour)
#   <  25 → fall back to `docker compose down -v` which is correctly scoped
#            to this project on all Engine versions.
# ---------------------------------------------------------------------------
cleanup_volumes() {
    if ! require_docker; then return 1; fi

    # Parse major version from "Docker version XX.Y.Z, build ..." output.
    local docker_version_str docker_major
    docker_version_str=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0.0")
    docker_major=$(printf '%s' "$docker_version_str" | cut -d. -f1)
    docker_major=$(( docker_major + 0 ))   # coerce to integer

    if [[ $docker_major -ge 25 ]]; then
        # label filter supported — safe to use volume prune
        local _prune_args=()
        mapfile -t _prune_args < <(_docker_prune_filter)
        local docker_err
        if ! docker_err=$(docker volume prune -f "${_prune_args[@]}" 2>&1 >/dev/null); then
            log_debug "cleanup_volumes: docker volume prune failed (non-fatal): $docker_err"
        fi
    else
        # Older engine: fall back to compose-scoped volume removal
        log_debug "cleanup_volumes: Docker Engine ${docker_version_str} < 25.0; "\
                  "falling back to 'docker compose down -v' for safe scoped volume cleanup"
        local docker_err
        if ! docker_err=$(docker compose down -v 2>&1 >/dev/null); then
            log_debug "cleanup_volumes: docker compose down -v failed (non-fatal): $docker_err"
        fi
    fi
    return 0
}

# Clean up unused networks
cleanup_networks() {
    if ! require_docker; then return 1; fi
    local _prune_args=()
    mapfile -t _prune_args < <(_docker_prune_filter)
    local docker_err
    if ! docker_err=$(docker network prune -f "${_prune_args[@]}" 2>&1 >/dev/null); then
        log_debug "cleanup_networks: docker network prune failed (non-fatal): $docker_err"
    fi
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
# A dots_printed flag tracks whether any progress dots were emitted; the
# trailing newline is only printed if at least one dot was output.
wait_for_service_ready() {
    local service="$1"
    local timeout="${2:-60}"
    local count=0
    local dot_interval=5
    local dots_printed=false   # tracks whether any dots were emitted

    log_info "Waiting for service '$service' to become ready (timeout: ${timeout}s)..."

    while [[ $count -lt $timeout ]]; do
        local current_status current_health raw_json
        # Wrap docker compose ps in a timeout so a hung Docker daemon
        # does not block the entire polling loop indefinitely.
        raw_json=$(timeout 10 docker compose ps "$service" --format json 2>/dev/null) || {
            log_warn "wait_for_service_ready: docker compose ps timed out — daemon may be unresponsive"
            sleep 2
            count=$(( count + 1 ))
            continue
        }
        current_status=$(printf '%s' "$raw_json" \
            | jq -r 'if type == "array" then .[0].State // "not_found" else .State // "not_found" end' 2>/dev/null \
            || echo "not_found")
        current_health=$(printf '%s' "$raw_json" \
            | jq -r 'if type == "array" then (.[0].Health // "none") else (.Health // "none") end' 2>/dev/null \
            || echo "none")
        current_health="${current_health:-none}"

        # No-healthcheck containers: running + health=="none" means healthy
        # by definition; return immediately.
        if [[ "$current_status" == "running" && "$current_health" == "none" ]]; then
            [[ "$dots_printed" == "true" ]] && echo "" >&2
            log_success "Service '$service' is ready (no healthcheck; running after ${count}s)"
            return 0
        fi

        if [[ "$current_status" == "running" && "$current_health" == "healthy" ]]; then
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
# NOTE: run_in_service is intentionally NOT exported (DOC-L1: hard deprecation)
export -f check_docker_available check_compose_available require_docker require_jq
export -f get_service_status is_service_running get_service_health is_service_healthy
export -f _service_has_no_healthcheck
export -f start_services stop_services restart_services recreate_services
export -f pull_images pull_image_with_retry exec_in_service exec_oneshot_in_service run_in_service_full_env
export -f _docker_prune_filter
export -f cleanup_containers cleanup_images cleanup_volumes cleanup_networks cleanup_docker_system
export -f get_service_logs follow_service_logs wait_for_service_ready validate_compose_file

log_debug "Enhanced Docker library loaded successfully - standardized error handling" 2>/dev/null || true
