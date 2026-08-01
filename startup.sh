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
REPAIR=false
# Retained as compatibility flags for existing operator/systemd commands.
# Ordinary startup is now always no-pull and validation-only for egress state.
SKIP_PULL=false
SKIP_EGRESS_FIX=false

STARTUP_PERMISSION_REPAIR_COMMAND="sudo ./utilities/repair-permissions.sh"
STARTUP_FIREWALL_REPAIR_COMMAND="sudo ./utilities/setup-firewall.sh --phase iptables --auto"
STARTUP_DNS_REPAIR_COMMAND="sudo ./utilities/maintenance-update-dns.sh"
STARTUP_IMAGE_UPDATE_COMMAND="sudo ./utilities/maintenance-update.sh --images"
STARTUP_REPAIR_COMMAND="sudo ./startup.sh --repair"

_STARTUP_WARNINGS=()

DOCKER_SECRETS_DIR="/run/vaultwarden-oci/secrets"

show_help() {
cat << 'EOF'
VaultWarden-OCI Startup Script

USAGE:
  sudo ./startup.sh [OPTIONS]    # Validate current local state and start services
  sudo ./startup.sh --repair    # Reconcile supported runtime drift, then start
  sudo ./startup.sh stop        # Stop all services

SUBCOMMANDS:
  stop             Stop all services (delegates to docker compose down)

STARTUP OPTIONS:
  --repair         Explicitly repair permissions, managed container orphans,
                   egress NAT, and DNS before starting. Does not update images.
  --force          Recreate containers so compose/.env metadata is regenerated
  --skip-health    Skip post-startup health check
  --background     Start services in background (daemon mode)
  --dry-run        Show what would be done without executing
  --skip-pull      Deprecated compatibility no-op; startup never pulls images
  --skip-egress-fix  Deprecated compatibility no-op; startup validates NAT

GLOBAL OPTIONS:
  --help, -h       Show this help
  --version, -V    Print the VaultWarden-OCI version and exit

EXAMPLES:
  sudo ./startup.sh               # Validate and start with local pinned images
  sudo ./startup.sh --repair      # Explicitly reconcile supported runtime drift
  sudo ./utilities/maintenance-update.sh --images  # Acquire/refresh images
  sudo ./startup.sh --force       # Recreate containers without pulling images
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
      --repair)          REPAIR=true;          shift ;;
      --force)           FORCE_RESTART=true;   shift ;;
      --skip-health)     SKIP_HEALTH_CHECK=true; shift ;;
      --skip-pull)       SKIP_PULL=true;        shift ;;
      --background)      BACKGROUND=true;       shift ;;
      --skip-egress-fix) SKIP_EGRESS_FIX=true;  shift ;;
      --dry-run)         DRY_RUN=true;          shift ;;
      --help|-h)         show_help; exit 0 ;;
      --version|-V)      print_project_version "VaultWarden-OCI" "${PROJECT_ROOT}"; exit 0 ;;
      *) log_error "Unknown option: '$1'"; show_help; exit 1 ;;
    esac
  fi
done

if [[ "$REPAIR" == "true" && "$DRY_RUN" == "true" ]]; then
  log_error "--repair and --dry-run cannot be combined."
  log_error "Use './startup.sh --dry-run' for a read-only startup preview."
  exit 2
fi

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
  [[ "$REPAIR" == "true" ]] && _label="Startup repair"
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


# Security boundaries remain visible at the public entrypoint even though their
# implementations are split into focused startup modules:
# - Repository key use is limited to explicit bootstrap/development mode.
# - Correct this selected identity, then run: sudo make key-health
# - Root/systemd health uses: VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "$_health_script" health
# - lib/startup-filesystem.sh validates the schema and required secrets exactly once:
#   schema_validate || return 1
#   validate_required_secrets "$SECRETS_FILE" || return 1

source "${SCRIPT_DIR}/lib/startup-config.sh"
source "${SCRIPT_DIR}/lib/startup-preview.sh"
source "${SCRIPT_DIR}/lib/startup-filesystem.sh"
source "${SCRIPT_DIR}/lib/startup-reconciliation.sh"
source "${SCRIPT_DIR}/lib/startup-health.sh"
source "${SCRIPT_DIR}/lib/startup-main.sh"

main "$@"
