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

FORCE_RESTART=false
SKIP_HEALTH_CHECK=false
BACKGROUND=false
DRY_RUN=false
DO_DOWN=false
# Pass --skip-pull in the unit file to avoid image pulls on routine service
# restarts. Use maintenance.sh update or ./startup.sh without the flag to
# refresh images.
SKIP_PULL=false
SKIP_EGRESS_FIX=false

_STARTUP_WARNINGS=()

DOCKER_SECRETS_DIR="${PROJECT_ROOT}/secrets/.docker_secrets"

show_help() {
cat << 'EOF'
VaultWarden-OCI Startup Script

USAGE:
  ./startup.sh [OPTIONS]         # Start all services (normal path)
  ./startup.sh stop              # Stop all services

SUBCOMMANDS:
  stop             Stop all services (delegates to docker compose down)

STARTUP OPTIONS:
  --force          Force restart of all services
  --skip-health    Skip post-startup health check
  --skip-pull      Skip docker compose pull (use for systemd restarts
                   or when images are already current)
  --background     Start services in background (daemon mode)
  --skip-egress-fix  Skip automatic egress NAT remediation for
                     non-internal VaultWarden Docker bridge networks
  --dry-run        Show what would be done without executing

GLOBAL OPTIONS:
  --help, -h       Show this help
  --version, -V    Print the VaultWarden-OCI version and exit

EXAMPLES:
  ./startup.sh                    # Normal startup (pulls latest images)
  ./startup.sh --skip-pull        # Restart without pulling (fast path)
  ./startup.sh --force            # Force restart all services
  ./startup.sh --background       # Start in daemon mode
  ./startup.sh stop               # Stop all services
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
  case $1 in
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
done

if [[ "$DO_DOWN" == "true" ]]; then
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

# Cross-check EMAIL_MODE against the required secret so operators get an
# actionable warning at startup instead of a silent failure on first email
# send. This remains a warning because email is not required for the stack to
# start.
#
# Valid modes are declared in _VW_DEFAULT_EMAIL_MODES (lib/defaults.sh).
# Add a new mode there; no edit to this function is needed.
check_email_config_consistency() {
  local email_mode="${EMAIL_MODE:-auto}"
  local secrets_dir="$DOCKER_SECRETS_DIR"

  case "$email_mode" in
    api)
      local token_file="${secrets_dir}/email_api_token"
      if [[ ! -f "$token_file" ]] || [[ ! -s "$token_file" ]]; then
        log_warn "EMAIL_MODE=api is set but '${token_file}' is absent or empty."
        log_warn "  All alert emails will fail silently until the token is populated."
        log_warn "  Fix: ./utilities/secrets-rotate.sh email_api_token"
      fi
      ;;
    smtp)
      local pw_file="${secrets_dir}/smtp_password"
      if [[ ! -f "$pw_file" ]] || [[ ! -s "$pw_file" ]]; then
        log_warn "EMAIL_MODE=smtp is set but '${pw_file}' is absent or empty."
        log_warn "  SMTP relay authentication will fail on first send."
        log_warn "  Fix: ./utilities/secrets-rotate.sh smtp_password"
      fi
      ;;
    auto|host)
      ;;
    *)
      local _valid_modes_str
      _valid_modes_str=$(IFS='|'; echo "${_VW_DEFAULT_EMAIL_MODES[*]}")
      log_warn "EMAIL_MODE='${email_mode}' is not a recognised value (${_valid_modes_str})."
      log_warn "  Email delivery may fail. Check EMAIL_MODE in .env."
      ;;
  esac
  return 0
}

load_environment() {
  log_info "Loading environment configuration..."

  if [[ -f ".env" ]]; then
    local real_user real_group env_owner
    real_user=$(get_real_user)
    real_group=$(id -gn "${real_user}" 2>/dev/null || echo "${real_user}")
    env_owner=$(stat -c '%U' ".env" 2>/dev/null || echo "unknown")

    # Auto-remediate a root-owned .env when startup is invoked by a non-root
    # user, such as via sudo. This keeps non-root tooling functional.
    if [[ "$env_owner" == "root" && "$real_user" != "root" ]]; then
      if _maybe_sudo chown "${real_user}:${real_group}" ".env" \
        && _maybe_sudo chmod 600 ".env"; then
        log_success ".env ownership corrected to ${real_user}:${real_group} (mode 600)"
      else
        log_warn "Could not auto-correct .env ownership to ${real_user}:${real_group}"
      fi
    fi

    # Fail early when .env is unreadable so non-root tooling does not break later.
    if [[ ! -r ".env" ]]; then
      log_error ".env is not readable by the current user ($(id -un))."
      log_error "Fix ownership: sudo chown $(id -un):$(id -gn) .env"
      return 1
    fi
    set -a
    # shellcheck disable=SC1091
    source ".env"
    set +a
    log_success "Environment loaded from .env"
  else
    log_error ".env file not found!"
    log_info "Copy .env.example to .env and configure it first"
    return 1
  fi
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

  if [ ! -f "docker-compose.yml" ]; then
    log_error "docker-compose.yml not found"
    return 1
  fi

  log_success "Prerequisites validated"
  return 0
}


# Ensure all PROJECT_STATE_DIR subdirectories required by Docker bind mounts
# exist on the host before `docker compose up`. Use absolute paths so
# separate-volume installs create directories on the data volume rather than
# under PROJECT_ROOT.
#
# prepare_log_directories() handles logs/ and backups/ with ownership logic;
# this function covers the remaining non-log subtrees.
prepare_directories() {
  local project_state_dir="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"

  local required_dirs=(
    "${project_state_dir}/data"
    "${project_state_dir}/caddy/data"
    "${project_state_dir}/caddy/config"
  )

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would create state directories: ${required_dirs[*]}"
    return 0
  fi

  log_info "Preparing required state directories under ${project_state_dir}..."

  local dir
  for dir in "${required_dirs[@]}"; do
    if ! _maybe_sudo mkdir -p "$dir"; then
      log_warn "Could not create directory: $dir (init container will retry)"
    fi
  done

  log_success "State directories prepared"
  return 0
}

prepare_log_directories() {
  log_info "Ensuring base state directory exists..."

  local project_state_dir="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would create base state directory: $project_state_dir"
    return 0
  fi

  if ! _maybe_sudo mkdir -p "$project_state_dir"; then
    log_error "Failed to create base state directory: $project_state_dir"
    return 1
  fi

  log_info "Creating log subdirectories with correct permissions..."

  local svc log_dirs=();
  for svc in "${_VW_DEFAULT_LOG_SERVICES[@]}"; do
    log_dirs+=("${project_state_dir}/logs/${svc}")
  done

  if ! _maybe_sudo mkdir -p "${log_dirs[@]}"; then
    log_warn "Failed to create log subdirectories (init container will try)"
  else
    local puid pgid
    puid=$(get_config_value "PUID" "${_VW_DEFAULT_PUID}")
    pgid=$(get_config_value "PGID" "${_VW_DEFAULT_PGID}")
    _maybe_sudo chown -R "${puid}:${pgid}" "${project_state_dir}/logs" 2>/dev/null || true
    _maybe_sudo chmod -R 755 "${project_state_dir}/logs" 2>/dev/null || true
    log_success "Log subdirectories created with correct permissions"
  fi

  if ! ensure_caddy_log_permissions "${project_state_dir}/logs/caddy"; then
    log_error "Failed to enforce Caddy log directory and file permissions"
    return 1
  fi

  local backup_dir
  backup_dir="$(get_config_value "BACKUP_DIR" "${project_state_dir}/backups")"
  if ! _maybe_sudo mkdir -p "$backup_dir" 2>/dev/null; then
    log_warn "Could not create backup directory: $backup_dir"
  else
    log_info "Backup directory ready: $backup_dir"
  fi

  log_success "State directories prepared successfully"
  return 0
}

prepare_push_secret_placeholders() {
  local secrets_dir="$DOCKER_SECRETS_DIR"

  local puid pgid
  puid=$(get_config_value "PUID" "${_VW_DEFAULT_PUID}")
  pgid=$(get_config_value "PGID" "${_VW_DEFAULT_PGID}")

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would enforce push secret placeholder permissions in ${secrets_dir}"
    return 0
  fi

  local changed=false
  _maybe_sudo mkdir -p "$secrets_dir" || return 1

  local dir_owner dir_mode
  dir_owner=$(stat -c '%u:%g' "$secrets_dir" 2>/dev/null || echo "")
  dir_mode=$(stat -c '%a' "$secrets_dir" 2>/dev/null || echo "")
  if [[ "$dir_owner" != "0:${pgid}" ]]; then
    _maybe_sudo chown root:"${pgid}" "$secrets_dir" || return 1
    changed=true
  fi
  if [[ "$dir_mode" != "755" ]]; then
    _maybe_sudo chmod 755 "$secrets_dir" || return 1
    changed=true
  fi

  local key path owner mode
  for key in push_installation_id push_installation_key; do
    path="${secrets_dir}/${key}"
    if [[ ! -f "$path" ]]; then
      _maybe_sudo touch "$path" || return 1
      changed=true
    fi

    owner=$(stat -c '%u:%g' "$path" 2>/dev/null || echo "")
    mode=$(stat -c '%a' "$path" 2>/dev/null || echo "")
    if [[ "$owner" != "${puid}:${pgid}" ]]; then
      _maybe_sudo chown "${puid}:${pgid}" "$path" || return 1
      changed=true
    fi
    if [[ "$mode" != "444" ]]; then
      _maybe_sudo chmod 444 "$path" || return 1
      changed=true
    fi
  done

  if [[ "$changed" == "true" ]]; then
    log_success "Push secret placeholders remediated for VaultWarden readability"
  else
    log_success "Push secret placeholders already readable for VaultWarden"
  fi
}

# Run check_age_key_health() before any SOPS invocation so a corrupt,
# missing, or wrong-permissions Age key produces a clear actionable error
# instead of an opaque decryption failure.
#
# If the configured key path does not exist but the repo-local key is present
# and healthy, override the key path for this process only and print a
# prominent advisory so the operator fixes .env before the next restart.
check_age_key_health_preflight() {
  local configured_key="${SOPS_AGE_KEY_FILE:-}"

  if [[ -z "$configured_key" ]]; then
    configured_key="${HOME:-/root}/.config/sops/age/keys.txt"
  fi

  if check_age_key_health "$configured_key" 2>/dev/null; then
    return 0
  fi

  local repo_local_key="${SCRIPT_DIR}/secrets/keys/age-key.txt"

  # canonical_key resolves from AGE_KEY_FILE (set by lib/config.sh compile-time
  # defaults). Changing AGE_KEY_FILE in .env therefore propagates to every
  # advisory message below automatically — no script edit required.
  local canonical_key="${AGE_KEY_FILE}"

  if [[ -f "$repo_local_key" ]] && check_age_key_health "$repo_local_key" 2>/dev/null; then
    local _vw_real_user _vw_real_group
    _vw_real_user=$(get_real_user)
    _vw_real_group=$(id -gn "${_vw_real_user}" 2>/dev/null || echo "${_vw_real_user}")

    log_warn "=========================================================="
    log_warn "ACTION REQUIRED — Age key path mismatch detected"
    log_warn "=========================================================="
    log_warn "Configured path (SOPS_AGE_KEY_FILE in .env): ${configured_key}"
    log_warn "That file does not exist or failed the health check."
    log_warn ""
    log_warn "A healthy repo-local key was found at: ${repo_local_key}"
    log_warn "Using it for THIS startup only (process-scoped override)."
    log_warn ""
    log_warn "This is a temporary workaround. Before the next restart, do ONE of:"
    log_warn ""
    log_warn "  Option A — Install key to canonical system path (recommended for production):"
    log_warn "    sudo install -d -m 750 /etc/vaultwarden"
    log_warn "    sudo install -m 600 ${repo_local_key} ${canonical_key}"
    log_warn "    sudo chown ${_vw_real_user}:${_vw_real_group} ${canonical_key}"
    log_warn "    sudo chgrp ${_vw_real_group} /etc/vaultwarden && sudo chmod 750 /etc/vaultwarden"
    log_warn "    # Verify: make key-health"
    log_warn ""
    log_warn "  Option B — Update .env to point at the repo-local key (local/dev only):"
    log_warn "    sed -i 's|^SOPS_AGE_KEY_FILE=.*|SOPS_AGE_KEY_FILE=${repo_local_key}|' .env"
    log_warn "    # Verify: make key-health"
    log_warn ""
    log_warn "  Option C — Run setup again to reinstall everything cleanly:"
    log_warn "    sudo ./setup.sh --domain <your-domain> --email <your-email>"
    log_warn "=========================================================="

    export SOPS_AGE_KEY_FILE="$repo_local_key"
    return 0
  fi

  log_error "Age key health check FAILED for configured path: ${configured_key}"
  log_error ""
  log_error "SOPS cannot decrypt secrets without a valid Age private key."
  log_error ""

  if [[ "$configured_key" == "$canonical_key" ]]; then
    log_error "Remediation:"
    log_error "  The canonical key file does not exist or is not readable."
    log_error "  Re-run setup to install it:"
    log_error "    sudo ./setup.sh --domain <your-domain> --email <your-email>"
    if [[ -f "$repo_local_key" ]]; then
      local _vw_real_user _vw_real_group
      _vw_real_user=$(get_real_user)
      _vw_real_group=$(id -gn "${_vw_real_user}" 2>/dev/null || echo "${_vw_real_user}")
      log_error ""
      log_warn "  A repo-local key was detected at: ${repo_local_key}"
      log_warn "  If this is the correct production key, install it with:"
      log_warn "    sudo install -d -m 750 /etc/vaultwarden"
      log_warn "    sudo install -m 600 ${repo_local_key} ${canonical_key}"
      log_warn "    sudo chown ${_vw_real_user}:${_vw_real_group} ${canonical_key}"
      log_warn "    sudo chgrp ${_vw_real_group} /etc/vaultwarden && sudo chmod 750 /etc/vaultwarden"
      log_warn "  Then run: make key-health to verify before retrying startup."
    fi
    return 1
  fi

  log_error "  Configured key path (from .env):  ${configured_key}"
  log_error "  Canonical production path:         ${canonical_key}"
  log_error ""

  if [[ -f "$canonical_key" ]]; then
    log_warn "  A key exists at the canonical production path (${canonical_key})."
    log_warn "  .env currently points elsewhere. To fix:"
    log_warn "    1. Update SOPS_AGE_KEY_FILE in .env to: ${canonical_key}"
    log_warn "    2. Verify with: make key-health"
    log_warn "    3. Retry: make up  (or ./startup.sh)"
  else
    log_error "  No key was found at any known path. Run: sudo make setup"
  fi

  log_error ""
  log_error "Run 'make key-health' for a detailed key status report."
  return 1
}

# #38 — prepare_docker_secrets() skips all SOPS/filesystem operations under
# --dry-run. Previously only _startup_pull_images and _startup_start_services
# were gated; this function still ran full SOPS decryption and secret-file
# writes even in dry-run mode, which could fail on machines without a
# configured Age key and misrepresented what "dry-run" means.
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
  export_docker_secrets "$DOCKER_SECRETS_DIR" || return 1
  log_success "Docker secrets prepared"
  return 0
}


cleanup_orphaned_resources() {
  log_info "Cleaning up orphaned resources..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would remove orphaned containers, networks, and dangling images"
    return 0
  fi

  # cleanup_docker_system() prunes containers, images, volumes, and networks
  # scoped to the project label so shared hosts do not lose unrelated
  # services.
  cleanup_docker_system || true

  log_success "Orphaned resources cleaned up"
  return 0
}

# Guard this wrapper with --skip-pull so systemd ExecStart restarts stay fast.
# Refresh images through maintenance.sh update or a manual ./startup.sh run
# without --skip-pull.
#
# Use direct `docker compose pull` so output streams to the journal without
# buffering.
_startup_pull_images() {
  if [[ "$SKIP_PULL" == "true" ]]; then
    log_info "Skipping docker compose pull (--skip-pull)"
    return 0
  fi

  log_info "Pulling latest container images..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would run: docker compose pull"
    return 0
  fi

  docker compose pull --quiet
  log_success "Images pulled successfully"
  return 0
}

update_dns_on_startup() {
  local dns_script="${PROJECT_ROOT}/utilities/maintenance-update-dns.sh"
  if [[ ! -x "$dns_script" ]]; then
    log_warn "DNS update script missing/not executable; skipping startup DNS check: $dns_script"
    return 0
  fi

  log_info "Running startup DNS reconciliation check..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would run: ${dns_script} update-dns"
    return 0
  fi

  if _maybe_sudo "$dns_script" update-dns; then
    log_success "Startup DNS reconciliation completed"
  else
    log_warn "Startup DNS reconciliation failed; continuing startup"
    _STARTUP_WARNINGS+=("DNS reconciliation failed — your domain may still point to a stale IP address.")
    _STARTUP_WARNINGS+=("  Fix: sudo ./utilities/maintenance-update-dns.sh update-dns")
  fi
  return 0
}

# Honour FORCE_RESTART and DRY_RUN here.
# Pass --force-recreate when FORCE_RESTART=true so containers are re-created
# even if the image digest has not changed.
_startup_start_services() {
  log_info "Starting VaultWarden services..."

  local compose_args=(up -d)

  if [[ "$FORCE_RESTART" == "true" ]]; then
    compose_args+=(--force-recreate)
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would run: docker compose ${compose_args[*]}"
    return 0
  fi

  docker compose "${compose_args[@]}"
  log_success "Services started"
  return 0
}

# Provide an idempotent fallback for hardened VMs where Docker's normal
# MASQUERADE behavior is missing or overridden. Only non-internal bridge
# networks attached to the vaultwarden container are targeted.
ensure_vaultwarden_egress_nat() {
  if [[ "$SKIP_EGRESS_FIX" == "true" ]]; then
    log_info "Skipping automatic egress NAT remediation (--skip-egress-fix)"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would verify/add MASQUERADE for vaultwarden non-internal bridge networks"
    return 0
  fi

  if ! command -v iptables >/dev/null 2>&1; then
    log_warn "iptables not found; skipping egress NAT remediation"
    return 0
  fi

  # Prefer the repo-managed setup helper so NAT and DOCKER-USER remediation
  # stay in one place and remain reusable outside startup.
  local _fw_script="${PROJECT_ROOT}/utilities/setup-firewall.sh"
  if [[ -x "$_fw_script" ]]; then
    log_info "Invoking: ${_fw_script} --phase iptables"
    if _maybe_sudo "$_fw_script" --phase iptables; then
      log_success "Egress firewall remediation completed via utilities/setup-firewall.sh"
      return 0
    fi
    log_warn "utilities/setup-firewall.sh failed — egress NAT not applied."
    log_warn "Run manually to restore: sudo ./utilities/setup-firewall.sh --phase iptables"
    _STARTUP_WARNINGS+=("Egress NAT not applied — Docker containers may have no outbound internet access.")
    _STARTUP_WARNINGS+=("  Fix: sudo ./utilities/setup-firewall.sh --phase iptables")
    return 0
  fi

  log_warn "utilities/setup-firewall.sh not found or not executable; skipping egress NAT remediation."
  log_warn "Run manually to configure: sudo ./utilities/setup-firewall.sh --phase iptables"
  _STARTUP_WARNINGS+=("Egress NAT not verified — utilities/setup-firewall.sh not found or not executable.")
  _STARTUP_WARNINGS+=("  Fix: sudo ./utilities/setup-firewall.sh --phase iptables")
  return 0
}


# Critical services to health-wait are declared in _VW_DEFAULT_CRITICAL_SERVICES
# (lib/defaults.sh). Add a new sidecar there — not here — when the stack grows.
wait_for_services() {
  log_info "Waiting for critical services to become ready..."
  local timeout=90
  local service
  for service in "${_VW_DEFAULT_CRITICAL_SERVICES[@]}"; do
    wait_for_service_ready "$service" "$timeout" || return 1
  done
  log_success "Critical services are ready"
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
  "$_health_script" health || health_exit=$?

  case "$health_exit" in
    0)
      log_success "Health check passed — all checks healthy"
      ;;
    1)
      log_warn "Health check completed with warnings — review output above"
      ;;
    *)
      # Exit 2 means one or more critical failures; exit 3+ means the health
      # script crashed.
      log_error "Health check reported CRITICAL failures (exit ${health_exit}) — stack is unhealthy"
      log_error "Startup aborted. Investigate the failures above, then re-run ./startup.sh"
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
  trap 'exit 130' INT
  trap 'exit 143' TERM

  load_environment || exit 1
  auto_fix_critical_permissions "$PROJECT_ROOT"
  require_project_state_ready || exit 1
  validate_prerequisites || exit 1
  prepare_directories || exit 1
  prepare_log_directories || exit 1
  prepare_docker_secrets || exit 1
  prepare_push_secret_placeholders || exit 1
  check_email_config_consistency || true # Warn only; never block startup.
  warn_plaintext_secret_overrides || true
  cleanup_orphaned_resources || true
  ensure_vaultwarden_egress_nat || true
  update_dns_on_startup || true
  _startup_pull_images || exit 1
  _startup_start_services || exit 1

  # Post-start: service readiness poll + health check.
  # Skipped in --background mode because the caller manages orchestration.
  if [[ "$BACKGROUND" != "true" && "$DRY_RUN" != "true" ]]; then
    wait_for_services || true
    run_health_check || {
      log_error "Startup tip: if the failure is key-related, run: make key-health"
      log_error "Canonical production key path: ${AGE_KEY_FILE}"
      # Emit warnings before exiting so operators see them even on failure.
      _show_startup_warnings
      exit 1
    }
    show_status || true
  fi

  # Re-emit the key-path advisory immediately before the final success line
  # so it is not missed in the log stream.
  if [[ "${SOPS_AGE_KEY_FILE:-}" == "${SCRIPT_DIR}/secrets/keys/age-key.txt" ]]; then
    local cfg_key
    cfg_key=$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2- || echo "(unknown)")
    if [[ "$cfg_key" != "${SCRIPT_DIR}/secrets/keys/age-key.txt" ]]; then
      log_warn "=========================================================="
      log_warn "REMINDER: SOPS_AGE_KEY_FILE in .env (${cfg_key}) was overridden"
      log_warn "at runtime by the repo-local key. Update .env or install"
      log_warn "the key to ${AGE_KEY_FILE} before next restart."
      log_warn "=========================================================="
    fi
  fi

  log_success "VaultWarden-OCI startup completed"

  # #26 — Always the absolute last output, regardless of --background or
  # --dry-run, so accumulated warnings are never silently swallowed.
  _show_startup_warnings
}

main "$@"
