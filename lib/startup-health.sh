# shellcheck shell=bash

wait_for_services() {
  log_info "Waiting for critical services to become ready..."

  local timeout="${CRITICAL_SERVICE_STARTUP_TIMEOUT:-90}"
  local service

  for service in "${_VW_DEFAULT_CRITICAL_SERVICES[@]}"; do
    wait_for_service_ready "$service" "$timeout" || return 1
  done

  log_success "Critical services are ready"
  return 0
}

wait_for_optional_service_health() {
  local service="${1:?service name is required}"
  local timeout="${2:-60}"
  local interval=2
  local elapsed=0
  local container_id=""
  local status=""

  container_id=$(docker compose ps -q "$service" 2>/dev/null || true)
  if [[ -z "$container_id" ]]; then
    log_warn "Optional service '${service}' has no running container"
    return 1
  fi

  while (( elapsed < timeout )); do
    status=$(docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      "$container_id" 2>/dev/null || true)

    case "$status" in
      healthy|running)
        return 0
        ;;
      unhealthy|exited|dead)
        log_warn "Optional service '${service}' entered state '${status}'"
        return 1
        ;;
    esac

    sleep "$interval"
    (( elapsed += interval )) || true
  done

  log_warn "Optional service '${service}' remained '${status:-unknown}' after ${timeout}s"
  return 1
}

wait_for_optional_services() {
  local service="postfix"
  local timeout="${POSTFIX_STARTUP_TIMEOUT:-60}"

  log_info "Waiting up to ${timeout}s for optional service '${service}' to become ready..."

  if wait_for_optional_service_health "$service" "$timeout"; then
    log_success "Optional service '${service}' is ready"
    return 0
  fi

  _STARTUP_WARNINGS+=(
    "Postfix did not become ready during its startup grace period."
    " Vaultwarden remains available, but email delivery may be delayed."
    " Fix: docker logs vaultwarden_postfix --tail=100"
  )

  return 0
}


run_health_check() {
  if [[ "$SKIP_HEALTH_CHECK" == "true" ]]; then
    log_info "Skipping post-start health check (--skip-health)"
    return 0
  fi

  local _health_script="${PROJECT_ROOT}/utilities/maintenance-health.sh"
  if [[ ! -x "$_health_script" ]]; then
    log_error "utilities/maintenance-health.sh not executable or missing; cannot run health check"
    log_error "Ensure setup.sh has been run and scripts are correctly installed"
    log_error "To skip this gate during recovery: ./startup.sh --skip-health"
    return 1
  fi

  log_info "Running post-start health check..."

  # Disable errexit around the health check so its exit code can be captured
  # cleanly.
  log_info "Invoking: ${_health_script} health"
  local health_exit=0
  local health_attempt=1
  local health_max_attempts=3
  # Internal root/systemd path; direct health commands still refuse root.
  VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "$_health_script" health || health_exit=$?

  while (( health_exit == 75 && health_attempt < health_max_attempts )); do
    log_warn "Post-start health check is contended; retrying shortly (${health_attempt}/${health_max_attempts})..."
    sleep 1
    (( health_attempt++ )) || true
    health_exit=0
    VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "$_health_script" health || health_exit=$?
  done

  case "$health_exit" in
    0)
      log_success "Health check passed — all checks healthy"
      ;;
    1)
      log_warn "Health check completed with warnings — review output above"
      ;;
    75)
      log_error "Post-start health is unknown: the health check remained contended after ${health_max_attempts} attempts."
      log_error "Startup cannot confirm service health until the active health check completes."
      return 75
      ;;
    *)
      # Exit 2 means one or more critical failures; exit 3+ means the health
      # script crashed.
      log_error "Health check reported CRITICAL failures (exit ${health_exit}) — stack is unhealthy"
      log_error "Startup aborted. Investigate the failures above, then re-run sudo ./startup.sh"
      log_error "To skip this gate during recovery: ./startup.sh --skip-health"
      return 1
      ;;
  esac

  return 0
}


show_status() {
  log_info "Current service status:"
  docker compose ps || true
}

# #26 — Emit the accumulated warnings banner unconditionally so it is always
# the last thing printed, regardless of --background or --dry-run mode.
# Previously the banner lived inside the `BACKGROUND != true` gate and was
# silently swallowed on background-mode startups.
#
# Called as the very last statement in main() so every upstream function has
# had the opportunity to append to _STARTUP_WARNINGS before we display them.
_show_startup_warnings() {
  if [[ ${#_STARTUP_WARNINGS[@]} -eq 0 ]]; then
    return 0
  fi
  log_warn "============================================================"
  log_warn "STARTUP COMPLETED WITH WARNINGS — action may be required:"
  local _wmsg
  for _wmsg in "${_STARTUP_WARNINGS[@]}"; do
    log_warn "  ${_wmsg}"
  done
  log_warn "============================================================"
}
