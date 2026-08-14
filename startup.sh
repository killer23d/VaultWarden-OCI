#!/usr/bin/env bash
# startup.sh — Start VaultWarden-OCI with secrets preparation and health checks.

set -euo pipefail
# shellcheck disable=SC2154 # rc is assigned via rc=$? inside the trap body
trap 'rc=$?; log_error "${BASH_SOURCE[0]}: STARTUP FAILED at line ${LINENO} (exit ${rc}) — check journalctl -u vaultwarden-startup"; exit "$rc"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/defaults.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/common.sh"
init_common_lib "$0"
DOCKER_PROJECT_LABEL="${DOCKER_PROJECT_LABEL:-label=com.docker.compose.project=vaultwarden-oci}"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/crypto.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/storage.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/runtime-permissions.sh"
source "${SCRIPT_DIR}/lib/operations.sh"

ORIGINAL_ARGS=("$@")
FORCE_RESTART=false
SKIP_HEALTH_CHECK=false
BACKGROUND=false
DRY_RUN=false
DO_DOWN=false

_STARTUP_WARNINGS=()

DOCKER_SECRETS_DIR="/run/vaultwarden-oci/secrets"

show_help() {
cat << 'EOF'
VaultWarden-OCI Startup Script

USAGE:
  sudo ./startup.sh [OPTIONS]    # Start all services (root-operated path)
  sudo ./startup.sh stop         # Stop all services

SUBCOMMANDS:
  stop             Stop all services (delegates to docker compose down)

STARTUP OPTIONS:
  --force          Recreate containers to apply current Compose and runtime environment values
  --skip-health    Skip post-startup health check
  --background     Start services in background (daemon mode)
  --dry-run        Show what would be done without executing

GLOBAL OPTIONS:
  --help, -h       Show this help
  --version, -V    Print the VaultWarden-OCI version and exit

EXAMPLES:
  sudo ./startup.sh               # Start with existing local images
  sudo ./startup.sh --force       # Recreate containers after explicit env sync
  sudo ./startup.sh --background  # Start in daemon mode
  sudo ./startup.sh stop          # Stop all services
EOF
}


if [[ $# -gt 0 ]]; then
  case "$1" in
    stop)
      DO_DOWN=true; shift
      ;;
    help|--help|-h)
      show_help; exit 0
      ;;
    --version|-V)
      print_project_version "VaultWarden-OCI" "${PROJECT_ROOT}"
      exit 0
      ;;
    --*)
      ;;
    *)
      log_error "Unknown subcommand: '$1'"
      log_error "Valid subcommands: stop"
      log_error "Run './startup.sh --help' for usage."
      show_help; exit 1
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  if [[ "$DO_DOWN" == "true" ]]; then
    case $1 in
      --help|-h)         show_help; exit 0 ;;
      --version|-V)      print_project_version "VaultWarden-OCI" "${PROJECT_ROOT}"; exit 0 ;;
      *) log_error "Unknown option for 'stop': '$1'"; log_error "Usage: sudo ./startup.sh stop"; show_help; exit 1 ;;
    esac
  else
    case $1 in
      --force)           FORCE_RESTART=true;   shift ;;
      --skip-health)     SKIP_HEALTH_CHECK=true; shift ;;
      --background)      BACKGROUND=true;       shift ;;
      --dry-run)         DRY_RUN=true;          shift ;;
      --help|-h)         show_help; exit 0 ;;
      --version|-V)      print_project_version "VaultWarden-OCI" "${PROJECT_ROOT}"; exit 0 ;;
      *) log_error "Unknown option: '$1'"; show_help; exit 1 ;;
    esac
  fi
done

# Real startup/stop operations are root-operated. Keep harmless metadata/help
# paths above this guard so users can inspect usage/version without sudo.
if [[ "${DRY_RUN}" != "true" || "${DO_DOWN}" == "true" ]]; then
  require_root "${ORIGINAL_ARGS[@]}"
fi

_startup_acquire_operation_guard() {
  local _ops_policy="fail"
  if [[ ! -t 0 || ! -t 1 ]]; then
    _ops_policy="skip"
  fi

  local _label="Startup"
  [[ "$DO_DOWN" == "true" ]] && _label="Startup stop"
  operation_acquire \
    --id startup \
    --label "$_label" \
    --specific-lock /run/lock/vaultwarden-startup.lock \
    --non-interactive "$_ops_policy" || exit $?

  _startup_operation_cleanup() {
    local rc=$?
    operation_release "$rc"
    return "$rc"
  }
  trap _startup_operation_cleanup EXIT
  trap 'operation_release 130; exit 130' INT
  trap 'operation_release 143; exit 143' HUP TERM
}

if [[ "${DRY_RUN}" != "true" || "${DO_DOWN}" == "true" ]]; then
  _startup_acquire_operation_guard
fi

if [[ "$DO_DOWN" == "true" ]]; then
  operation_set_phase "stop" "Stopping VaultWarden services"
  if ! command -v docker >/dev/null 2>&1; then
    log_error "docker not found — cannot stop services."
    exit 1
  fi
  log_info "Stopping VaultWarden services..."
  docker compose down
  log_success "Services stopped successfully"
  exit 0
fi


# Warn about split-brain secret configuration when plaintext EMAIL_API_TOKEN or
# SMTP_PASSWORD values override SOPS-managed secrets. This is advisory only.
warn_plaintext_secret_overrides() {
  local warned=false

  if [[ -n "${EMAIL_API_TOKEN:-}" ]]; then
    log_warn "EMAIL_API_TOKEN is set in the live environment. This overrides the SOPS-managed email_api_token secret and can cause split-brain configuration."
    warned=true
  fi

  if [[ -n "${SMTP_PASSWORD:-}" ]]; then
    log_warn "SMTP_PASSWORD is set in the live environment. This forces direct external SMTP auth and overrides the SOPS-managed smtp_password secret."
    warned=true
  fi

  if [[ "$warned" == "true" ]]; then
    log_warn "Best practice: keep EMAIL_API_TOKEN and SMTP_PASSWORD out of .env and manage them only through secrets.yaml / SOPS."
  fi
}

# Cross-check EMAIL_MODE after stack-level secret validation so operators get
# delivery-specific diagnostics before the first email send. The unconditional
# Postfix smtp_password requirement is already enforced by prepare_docker_secrets()
# through validate_required_secrets(); this later check is advisory only.
#
# Valid modes are declared in _VW_DEFAULT_EMAIL_MODES (lib/defaults.sh).
# Add a new mode there; no edit to this function is needed.
check_email_config_consistency() {
  # VWOCI-PRR-PATCH-03: canonical modes are declared in lib/defaults.sh.
  local email_mode="${EMAIL_MODE:-auto}"
  local secrets_dir="$DOCKER_SECRETS_DIR"
  case "$email_mode" in
    api)
      local token_file="${secrets_dir}/email_api_token"
      if [[ ! -s "$token_file" ]]; then
        log_warn "EMAIL_MODE=api is set but '${token_file}' is absent or empty."
        log_warn "Email API delivery will fail until the token is populated."
        log_warn "Fix: ./utilities/secrets-rotate.sh email_api_token"
      fi
      ;;
    smtp|direct)
      local pw_file="${secrets_dir}/smtp_password"
      if [[ ! -s "$pw_file" ]]; then
        log_warn "EMAIL_MODE=${email_mode} requires '${pw_file}', but it is absent or empty."
        log_warn "Direct SMTP authentication will fail on first send."
        log_warn "Fix: ./utilities/secrets-rotate.sh smtp_password"
      fi
      ;;
    auto)
      ;;
    *)
      local valid_modes
      valid_modes="$(IFS='|'; echo "${_VW_DEFAULT_EMAIL_MODES[*]}")"
      log_warn "EMAIL_MODE='${email_mode}' is not a recognised value (${valid_modes})."
      log_warn "Email delivery may fail."
      ;;
  esac
  return 0
}

warn_env_drift() {
  local repo_env="${PROJECT_ROOT}/.env"
  local installed_envs=(
    "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/config/install.env"
    "${VW_CONFIG_INSTALLED_ENV_FILE:-/etc/vaultwarden/vaultwarden.env}"
  )

  [[ -r "$repo_env" ]] || return 0

  local keys=(
    SMTP_FROM
    SMTP_FROM_NAME
    ALLOWED_SENDER_DOMAINS
    MAILGUN_DOMAIN
    EMAIL_MODE
    EMAIL_PROVIDER
    SMTP_HOST
    SMTP_PORT
    SMTP_SECURITY
  )

  local installed_env key repo_value installed_value drift_found=false
  for installed_env in "${installed_envs[@]}"; do
    [[ -r "$installed_env" ]] || continue
    for key in "${keys[@]}"; do
      repo_value="$(_read_env_value "$key" "$repo_env")"
      installed_value="$(_read_env_value "$key" "$installed_env")"
      if [[ "$repo_value" != "$installed_value" ]]; then
        if [[ "$drift_found" == "false" ]]; then
          log_warn "Repository .env differs from generated runtime env file(s) for non-secret email settings."
          log_warn "Run: sudo make sync-env"
          drift_found=true
        fi
        log_warn "  ${installed_env}: ${key}: repo='${repo_value}' installed='${installed_value}'"
      fi
    done
  done
}

validate_caddy_version_pin() {
  if [[ "${CADDY_VERSION:-}" == "latest" ]]; then
    log_error "CADDY_VERSION=latest is invalid for this stack's custom Caddy build."
    log_error "The Dockerfile uses caddy:\${CADDY_VERSION}-builder; caddy:latest-builder is not published."
    log_error "Fix .env by setting: CADDY_VERSION=2.11.4"
    log_error "Then run: sudo make sync-env"
    log_error "Update the local image explicitly with: sudo ./maintenance.sh update --images"
    return 1
  fi
  return 0
}

load_environment() {
  log_info "Loading environment configuration..."

  load_project_environment || return 1
  validate_caddy_version_pin || return 1
  warn_env_drift || true
  DOCKER_SECRETS_DIR="/run/vaultwarden-oci/secrets"
  export DOCKER_SECRETS_DIR
  log_success "Environment loaded"

  log_info "Note: changes to compose/.env values are applied to containers only when they are recreated."
}

# Required commands are declared in _VW_DEFAULT_REQUIRED_COMMANDS (lib/defaults.sh).
# Add a new dependency there; no edit to this function is needed.
validate_prerequisites() {
  log_info "Validating prerequisites..."

  local missing_commands=()

  for cmd in "${_VW_DEFAULT_REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_commands+=("$cmd")
    fi
  done

  if [ ${#missing_commands[@]} -gt 0 ]; then
    log_error "Missing required commands: ${missing_commands[*]}"
    return 1
  fi

  if ! python3 -c "import yaml" 2>/dev/null; then
    log_error "python3-yaml (PyYAML) is not installed — required for secrets parsing"
    log_error "Install hint: pip install pyyaml  or  sudo apt install python3-yaml"
    return 1
  fi

  if ! check_docker_available; then
    log_error "Docker daemon is not running or not accessible"
    return 1
  fi
  if ! check_compose_available; then
    log_error "Docker Compose v2 plugin is not available"
    log_error "Install with: sudo apt install docker-compose-plugin"
    return 1
  fi

  if [ ! -f "docker-compose.yml" ]; then
    log_error "docker-compose.yml not found"
    return 1
  fi

  log_success "Prerequisites validated"
  return 0
}

validate_runtime_permissions() {
  log_info "Validating runtime permissions..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would validate known runtime permissions without repairing them"
    return 0
  fi

  if check_runtime_state_permissions \
      "${PROJECT_STATE_DIR:-/var/lib/vaultwarden}" \
      "${PUID:-}" \
      "${PGID:-}" \
      "$PROJECT_ROOT"; then
    log_success "Runtime permissions validated"
    return 0
  fi

  log_error "Runtime permission validation failed. Startup did not repair persistent state."
  log_error "Run: sudo utilities/repair-permissions.sh"
  log_error "Then retry: sudo make up"
  return 1
}


# Run check_age_key_health() before any SOPS invocation so a corrupt,
# missing, or wrong-permissions canonical key produces an actionable error.
check_age_key_health_preflight() {
  local canonical_key="/etc/vaultwarden/age-key.txt"
  if check_age_key_health "$canonical_key" 2>/dev/null; then
    SOPS_AGE_KEY_FILE="$canonical_key"
    export SOPS_AGE_KEY_FILE
    return 0
  fi
  log_error "Age key health check FAILED: ${canonical_key}"
  log_error "Restore the operational Age private key at ${canonical_key}, then run: sudo make key-health"
  return 1
}

# #38 — prepare_docker_secrets() skips all SOPS/filesystem operations under
# --dry-run. Previously only the service-start function was gated; this
# function still ran full SOPS decryption and secret-file writes even in
# dry-run mode, which could fail on machines without a configured Age key and
# misrepresented what "dry-run" means.
#
# Under --dry-run we log the two operations that would occur so the operator
# sees the full plan, then return 0 without touching the filesystem or
# invoking SOPS/age.
prepare_docker_secrets() {
  log_info "Preparing Docker secrets from SOPS..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would run: check_age_key_health_preflight (verify/locate Age key)"
    log_info "[DRY RUN] Would run: export_docker_secrets ${DOCKER_SECRETS_DIR} (SOPS decrypt → secret files)"
    return 0
  fi

  check_age_key_health_preflight || return 1
  schema_validate || return 1
  validate_required_secrets "$SECRETS_FILE" || return 1
  export_docker_secrets "$DOCKER_SECRETS_DIR" || return 1
  log_success "Docker secrets prepared"
  return 0
}

validate_local_images() {
  log_info "Confirming required local container images..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would inspect images declared by: docker compose config --images"
    return 0
  fi

  local images image
  local missing_image=false

  if ! images="$(docker compose config --images)"; then
    log_error "Unable to resolve the images required by docker-compose.yml"
    return 1
  fi

  while IFS= read -r image; do
    [[ -n "$image" ]] || continue
    if ! docker image inspect "$image" >/dev/null 2>&1; then
      log_error "Required local image is missing: $image"
      missing_image=true
    fi
  done <<< "$images"

  if [[ "$missing_image" == "true" ]]; then
    log_error "Startup does not pull or update images."
    log_error "Run the existing image-maintenance command: sudo ./maintenance.sh update --images"
    log_error "Then retry: sudo make up"
    return 1
  fi

  log_success "Declared local images are available"
  return 0
}

# Honour FORCE_RESTART and DRY_RUN here.
# Pass --force-recreate when FORCE_RESTART=true so containers are re-created
# even if the image digest has not changed.
_startup_start_services() {
  log_info "Starting VaultWarden services with existing local images..."

  local compose_args=(
    up
    -d
    --pull
    never
    --no-build
  )

  if [[ "$FORCE_RESTART" == "true" ]]; then
    compose_args+=(--force-recreate)
    log_info "Force restart requested; Docker Compose will recreate existing containers."
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would run: docker compose ${compose_args[*]}"
    return 0
  fi

  if ! docker compose "${compose_args[@]}"; then
    log_error "docker compose ${compose_args[*]} failed"
    return 1
  fi

  log_success "Services started"
  return 0
}


# Critical services to health-wait are declared in _VW_DEFAULT_CRITICAL_SERVICES
# (lib/defaults.sh). Add a new sidecar there — not here — when the stack grows.
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


main() {
  log_info "Starting VaultWarden-OCI startup workflow..."

  # Add INT/TERM traps so cleanup still runs and the exit code correctly
  # reflects termination (130 for INT, 143 for TERM).
  trap 'operation_release 130; exit 130' INT
  trap 'operation_release 143; exit 143' HUP TERM

  operation_set_phase "startup" "Validating runtime and starting services"
  load_environment || exit 1
  check_project_state_ready || exit 1
  validate_prerequisites || exit 1
  validate_runtime_permissions || exit 1
  prepare_docker_secrets || exit 1
  prepare_push_secret_placeholders || exit 1
  check_email_config_consistency || true # Warn only; never block startup.
  warn_plaintext_secret_overrides || true
  validate_local_images || exit 1
  _startup_start_services || exit 1

  # Post-start: service readiness poll + health check.
  # Skipped in --background mode because the caller manages orchestration.
  if [[ "$BACKGROUND" != "true" && "$DRY_RUN" != "true" ]]; then
    local readiness_rc=0
    local health_rc=0

    # Preserve the readiness result, but still run the comprehensive health
    # check so a failed startup includes actionable diagnostics.
    wait_for_services || readiness_rc=$?

    # Postfix is optional for core availability. Give its Docker health check a
    # bounded grace period before running the comprehensive health report.
    wait_for_optional_services || true

    run_health_check || health_rc=$?

    if (( readiness_rc != 0 )); then
      log_error "One or more critical services failed their startup readiness check"
      log_error "Review the health output and container logs before retrying"
      _show_startup_warnings
      exit "$readiness_rc"
    fi

    if (( health_rc != 0 )); then
      log_error "Startup tip: if the failure is key-related, run: sudo make key-health"
      log_error "Canonical production key path: ${AGE_KEY_FILE}"
      # Emit warnings before exiting so operators see them even on failure.
      _show_startup_warnings
      exit "$health_rc"
    fi

    show_status || true
  fi


  log_success "VaultWarden-OCI startup completed"

  # #26 — Always the absolute last output, regardless of --background or
  # --dry-run, so accumulated warnings are never silently swallowed.
  _show_startup_warnings
}

main "$@"
