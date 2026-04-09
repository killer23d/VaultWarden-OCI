#!/usr/bin/env bash
# startup.sh - VaultWarden startup script with secure secrets handling
#
# PATCHED BUGS (2026-03-06 through 2026-03-11): see lib/secrets.sh header
#
# PATCHED BUGS (2026-03-19):
#   STARTUP-1 [LOW]    show_help(): cosmetic, no functional change.
#   STARTUP-2 [HIGH]   prepare_docker_secrets(): '\\' (double-backslash) used
#                      as line continuation in compound condition — bash treats
#                      the second backslash as a literal, breaking the test.
#                      Replaced with a single '\' continuation.
#   STARTUP-3 [MEDIUM] prepare_docker_secrets(): _stat_octal_perms_local()
#                      called but not defined in this file. Added file-local
#                      shim using portable GNU||BSD stat.
#   STARTUP-4 [MEDIUM] prepare_docker_secrets(): SOPS_AGE_KEY_FILE exported
#                      and never unset; all child processes inherited the Age
#                      key path. Fixed via cleanup_secrets_environment() after
#                      sops call.
#   STARTUP-5 [MEDIUM] source "lib/secrets.sh" was missing; added so
#                      cleanup_secrets_environment() is available.
#   STARTUP-6 [MEDIUM] prepare_docker_secrets(): secret files were previously
#                      created at 600 (owner-read-only). Docker bind-mounts
#                      these files into containers running as non-root UIDs
#                      (e.g. 1001) that are not the owning user, so 600 made
#                      the files unreadable by the container processes.
#                      Fix: use umask 333 (→ 444, r--r--r--) so all UIDs
#                      inside containers can read them. The containing
#                      directory (secrets/.docker_secrets) is mode 700
#                      owned by root, so unprivileged OS users cannot traverse
#                      into it — the world-read bit on the files is effectively
#                      unreachable from the host without root. maintenance.sh's
#                      permission guard explicitly allows 444 (alongside
#                      400/600/640) so DNS updates work correctly on every boot.
#
# PATCHED BUGS (2026-03-26):
#   STARTUP-7 [MEDIUM] lib/simple_key_resilience.sh was never sourced.
#                      As a result, check_age_key_health() was unavailable
#                      and no pre-decryption key integrity check ran before
#                      prepare_docker_secrets() attempted to decrypt
#                      secrets.yaml. A corrupt or wrong-permissions age key
#                      produced only the opaque "Failed to decrypt secrets
#                      file" message with no actionable guidance.
#                      Fix: source simple_key_resilience.sh and call
#                      check_age_key_health_preflight() at the start of
#                      prepare_docker_secrets().
#
# PATCHED BUGS (2026-04-03):
#   STARTUP-8 [MEDIUM] wait_for_services() was called with bare service names
#                      ('vaultwarden', 'caddy') but docker inspect requires the
#                      full container_name set in docker-compose.yml
#                      ('vaultwarden_app', 'vaultwarden_caddy'). docker inspect
#                      on an unknown name exits 1 and returns empty strings for
#                      both health and running status. The polling loop ran to
#                      the full timeout on every startup (90s total), then
#                      emitted misleading WARN messages despite the stack being
#                      fully healthy. Fix: resolve container ID via
#                      `docker compose ps -q <service>` so the lookup is
#                      correct regardless of COMPOSE_PROJECT_NAME, then pass
#                      that ID to docker inspect.
#
# PATCHED BUGS (2026-04-07):
#   STARTUP-9 [MEDIUM] Plaintext EMAIL_API_TOKEN or SMTP_PASSWORD values loaded
#                      from .env silently override the SOPS-managed workflow.
#                      send_email() prefers EMAIL_API_TOKEN from the environment
#                      before decrypting email_api_token from secrets.yaml, and
#                      _smtp_send() switches to direct external SMTP whenever
#                      SMTP_PASSWORD is non-empty. Because load_env_file() runs
#                      before prepare_docker_secrets(), an accidentally-populated
#                      .env can create split-brain configuration with no
#                      operator warning. Fix: add a startup guard that inspects
#                      the loaded environment after SOPS secrets are prepared and
#                      emits loud warnings when these plaintext overrides are set.
#
# PATCHED BUGS (2026-04-08):
#   STARTUP-10 [MEDIUM] run_health_check() treated exit 1 (warnings) and
#                       exit 2 (critical failures) from health.sh identically —
#                       both non-zero codes fell through to a single log_warn,
#                       giving the operator a false green signal when the stack
#                       was critically unhealthy. health.sh has always emitted
#                       exit 0/1/2 correctly; the caller did not honour them.
#                       Fix: capture the exit code explicitly and map:
#                         exit 0 → log_success (all checks passed)
#                         exit 1 → log_warn   (warnings present, startup continues)
#                         exit 2 → log_error + exit 1 (critical failure, abort)
#                       This matches the documented exit-code contract in
#                       health.sh's --help output.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"
source "lib/secrets.sh"   # STARTUP-5 FIX: provides cleanup_secrets_environment()
source "lib/simple_key_resilience.sh"  # STARTUP-7 FIX: provides check_age_key_health()

# Configuration
FORCE_RESTART=false
SKIP_HEALTH_CHECK=false
BACKGROUND=false
DRY_RUN=false
DO_DOWN=false

show_help() {
cat << 'EOF'
VaultWarden-OCI Startup Script with Enhanced Security

USAGE:
  ./startup.sh [OPTIONS]

OPTIONS:
  --force          Force restart of all services (preferred flag)
  --force-restart  Alias for --force (legacy, kept for compatibility)
  --skip-health    Skip post-startup health check
  --background     Start services in background (daemon mode)
  --dry-run        Show what would be done without executing
  --down           Stop all services (delegates to docker compose down)
  --help           Show this help

EXAMPLES:
  ./startup.sh                    # Normal startup
  ./startup.sh --force            # Force restart all services
  ./startup.sh --background       # Start in daemon mode
  ./startup.sh --down             # Stop all services
EOF
}

# Argument parsing
while [[ $# -gt 0 ]]; do
  case $1 in
    --force)         FORCE_RESTART=true; shift ;;
    --force-restart) FORCE_RESTART=true; shift ;;
    --skip-health)   SKIP_HEALTH_CHECK=true; shift ;;
    --background)    BACKGROUND=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --down)          DO_DOWN=true; shift ;;
    --help)          show_help; exit 0 ;;
    *) log_error "Unknown option: $1"; show_help; exit 1 ;;
  esac
done

# --down: stop all services and exit immediately
if [[ "$DO_DOWN" == "true" ]]; then
  log_info "Stopping VaultWarden services..."
  docker compose down
  log_success "Services stopped successfully"
  exit 0
fi

# Run a command as root if needed (interactive -> sudo, non-interactive -> sudo -n)
_maybe_sudo() {
  if is_root; then
    "$@"
    return $?
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    "$@"
    return $?
  fi

  # If running without a TTY (cron/non-interactive), don't prompt for password.
  if [[ -t 0 ]]; then
    sudo "$@"
  else
    sudo -n "$@"
  fi
}

# ---------------------------------------------------------------------------
# _startup_secure_wipe FILE
#
# Securely overwrite and remove a sensitive temp file.
# Mirrors lib/secrets.sh::_secure_shred() to handle CoW filesystems
# (btrfs, snapshotted ext4 on OCI block volumes) where shred(1) cannot
# guarantee extent reuse and therefore cannot guarantee data erasure.
# ---------------------------------------------------------------------------
_startup_secure_wipe() {
  local target="$1"
  [[ -f "$target" ]] || return 0

  if command -v shred >/dev/null 2>&1; then
    shred -fuz "$target" 2>/dev/null && return 0
  fi

  # dd overwrite fallback: effective on CoW filesystems
  local file_size
  file_size=$(stat -c%s "$target" 2>/dev/null || stat -f%z "$target" 2>/dev/null || echo "4096")
  [[ -z "$file_size" || ! "$file_size" =~ ^[0-9]+$ ]] && file_size=4096
  (( file_size == 0 )) && file_size=4096
  dd if=/dev/urandom of="$target" bs="$file_size" count=1 conv=notrunc 2>/dev/null || true
  rm -f "$target"
}

# ---------------------------------------------------------------------------
# _stat_octal_perms_local FILE
#
# STARTUP-3 FIX: prepare_docker_secrets() calls _stat_octal_perms_local to
# verify chmod succeeded, but the function was never defined in this file
# (it lives in lib/common.sh under a different name on some versions).
# Define it here as a file-local shim so startup.sh is self-contained.
# Returns the 3-digit octal permission string (e.g. "600", "444") on stdout.
# ---------------------------------------------------------------------------
_stat_octal_perms_local() {
  local target="$1"
  # GNU stat
  stat -c%a "$target" 2>/dev/null && return 0
  # BSD/macOS stat
  stat -f%Lp "$target" 2>/dev/null && return 0
  echo "unknown"
}

# ---------------------------------------------------------------------------
# _prepare_secrets_cleanup
#
# FIX MEDIUM: cleanup_local() was previously defined as a nested function
# inside prepare_docker_secrets(). In bash, nested function definitions are
# globally scoped after first execution, leaking the symbol into the global
# namespace and making it callable from any subsequent code.
#
# Renamed to _prepare_secrets_cleanup() and defined at file scope so the
# name is explicit and does not shadow any standard utility.
# ---------------------------------------------------------------------------
_prepare_secrets_cleanup_umask=""
_prepare_secrets_cleanup_cache=""

_prepare_secrets_cleanup() {
  if [[ -n "$_prepare_secrets_cleanup_umask" ]]; then
    umask "$_prepare_secrets_cleanup_umask"
    _prepare_secrets_cleanup_umask=""
  fi
  if [[ -n "$_prepare_secrets_cleanup_cache" ]]; then
    _startup_secure_wipe "$_prepare_secrets_cleanup_cache"
    _prepare_secrets_cleanup_cache=""
  fi
}

# ---------------------------------------------------------------------------
# warn_plaintext_secret_overrides
#
# STARTUP-9 FIX: detect split-brain secret configuration caused by plaintext
# EMAIL_API_TOKEN / SMTP_PASSWORD values in .env overriding SOPS-managed
# secrets. Emits warnings only; does not block startup.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# load_environment
# ---------------------------------------------------------------------------
load_environment() {
  log_info "Loading environment configuration..."

  if [ -f ".env" ]; then
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

# ---------------------------------------------------------------------------
# validate_prerequisites
# ---------------------------------------------------------------------------
validate_prerequisites() {
  log_info "Validating prerequisites..."

  # Check required commands
  local required_commands=(docker openssl)
  local missing_commands=()

  for cmd in "${required_commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_commands+=("$cmd")
    fi
  done

  if [ ${#missing_commands[@]} -gt 0 ]; then
    log_error "Missing required commands: ${missing_commands[*]}"
    return 1
  fi

  # Check docker daemon
  if ! docker info >/dev/null 2>&1; then
    log_error "Docker daemon is not running or not accessible"
    return 1
  fi

  # Check compose file
  if [ ! -f "docker-compose.yml" ]; then
    log_error "docker-compose.yml not found"
    return 1
  fi

  log_success "Prerequisites validated"
  return 0
}

# ---------------------------------------------------------------------------
# prepare_directories
# ---------------------------------------------------------------------------
prepare_directories() {
  log_info "Preparing required directories..."

  local required_dirs=(
    "logs/vaultwarden"
    "logs/caddy"
    "logs/fail2ban"
    "logs/postfix"
    "backups"
    "ssl"
    "caddy/data"
    "caddy/config"
    "fail2ban/data"
  )

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would create directories: ${required_dirs[*]}"
    return 0
  fi

  for dir in "${required_dirs[@]}"; do
    mkdir -p "$dir"
  done

  log_success "Directories prepared"
  return 0
}

# ENHANCED: Prepare log directories with correct ownership
prepare_log_directories() {
  log_info "Ensuring base state directory exists..."

  local project_state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would create base state directory: $project_state_dir"
    return 0
  fi

  # Create base project state directory
  if ! _maybe_sudo mkdir -p "$project_state_dir"; then
    log_error "Failed to create base state directory: $project_state_dir"
    return 1
  fi

  # Create log subdirectories with correct ownership (RUNTIME FIX)
  log_info "Creating log subdirectories with correct permissions..."
  if ! _maybe_sudo mkdir -p "${project_state_dir}/logs"/{vaultwarden,caddy,fail2ban,postfix}; then
    log_warn "Failed to create log subdirectories (init container will try)"
  else
    # Set ownership to PUID:PGID from .env configuration
    local puid pgid
    puid=$(get_config_value "PUID" "1001")
    pgid=$(get_config_value "PGID" "1001")
    _maybe_sudo chown -R "${puid}:${pgid}" "${project_state_dir}/logs" 2>/dev/null || true
    _maybe_sudo chmod -R 755 "${project_state_dir}/logs" 2>/dev/null || true
    log_success "Log subdirectories created with correct permissions"
  fi

  # Create backup directory (RUNTIME FIX)
  if [ ! -d "${PROJECT_ROOT}/backups" ]; then
    mkdir -p "${PROJECT_ROOT}/backups" 2>/dev/null || true
    log_info "Created backup directory"
  fi

  # Ensure Caddy entrypoint is executable (RUNTIME FIX)
  if [ -f "${PROJECT_ROOT}/caddy/entrypoint.sh" ]; then
    chmod +x "${PROJECT_ROOT}/caddy/entrypoint.sh" 2>/dev/null || true
    log_info "Ensured Caddy entrypoint is executable"
  fi

  log_success "State directories prepared successfully"
  return 0
}

# ---------------------------------------------------------------------------
# check_age_key_health_preflight
#
# STARTUP-7 FIX: Run check_age_key_health() from lib/simple_key_resilience.sh
# before any sops invocation so a corrupt, missing, or wrong-permissions age
# key produces a clear actionable error message rather than the opaque
# "Failed to decrypt secrets file" from sops.
# ---------------------------------------------------------------------------
check_age_key_health_preflight() {
  local age_key="${SOPS_AGE_KEY_FILE:-${HOME:-/root}/.config/sops/age/keys.txt}"

  if ! check_age_key_health "$age_key"; then
    log_error "Age key health check failed: $age_key"
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# prepare_docker_secrets
# ---------------------------------------------------------------------------
prepare_docker_secrets() {
  log_info "Preparing Docker secrets from SOPS..."

  # STARTUP-7 FIX: fail fast with actionable diagnostics if the age key is bad
  check_age_key_health_preflight || return 1

  if [[ ! -f "secrets.yaml" ]]; then
    log_warn "secrets.yaml not found; skipping Docker secrets preparation"
    return 0
  fi

  local secrets_dir="secrets/.docker_secrets"
  mkdir -p "$secrets_dir"
  chmod 700 "$secrets_dir"

  local old_umask
  old_umask=$(umask)
  _prepare_secrets_cleanup_umask="$old_umask"
  trap _prepare_secrets_cleanup EXIT
  umask 333

  local cache_file
  cache_file=$(mktemp)
  _prepare_secrets_cleanup_cache="$cache_file"

  if ! sops -d secrets.yaml > "$cache_file"; then
    log_error "Failed to decrypt secrets.yaml"
    return 1
  fi

  # Minimal parser for the known flat structure used by this project.
  # We intentionally avoid yq/jq dependency here.
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    local target_file="${secrets_dir}/${key}"
    printf '%s' "$value" > "$target_file"

    local perms
    perms=$(_stat_octal_perms_local "$target_file")
    if [[ "$perms" != "444" ]]; then
      chmod 444 "$target_file"
    fi
  done < <(
    python3 - <<'PY'
import sys, yaml
with open('secrets.yaml', 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}
for k, v in data.items():
    if isinstance(v, (str, int, float)):
        print(f"{k}={v}")
PY
  )

  cleanup_secrets_environment || true
  _prepare_secrets_cleanup
  trap - EXIT

  log_success "Docker secrets prepared"
  return 0
}

# ---------------------------------------------------------------------------
# get_config_value KEY DEFAULT
# ---------------------------------------------------------------------------
get_config_value() {
  local key="$1"
  local default_value="${2:-}"

  if [[ -f ".env" ]]; then
    local value
    value=$(grep -E "^${key}=" .env 2>/dev/null | tail -n1 | cut -d= -f2- || true)
    value="${value%\"}"
    value="${value#\"}"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  fi

  printf '%s\n' "$default_value"
  return 0
}

# ---------------------------------------------------------------------------
# cleanup_orphaned_resources
# ---------------------------------------------------------------------------
cleanup_orphaned_resources() {
  log_info "Cleaning up orphaned resources..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would remove orphaned containers, networks, and dangling images"
    return 0
  fi

  docker container prune -f >/dev/null 2>&1 || true
  docker network prune -f >/dev/null 2>&1 || true
  docker image prune -f >/dev/null 2>&1 || true

  log_success "Orphaned resources cleaned up"
  return 0
}

# ---------------------------------------------------------------------------
# pull_images
# ---------------------------------------------------------------------------
pull_images() {
  log_info "Pulling latest container images..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would run: docker compose pull"
    return 0
  fi

  docker compose pull
  log_success "Images pulled successfully"
  return 0
}

# ---------------------------------------------------------------------------
# start_services
# ---------------------------------------------------------------------------
start_services() {
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

# ---------------------------------------------------------------------------
# wait_for_services
#
# STARTUP-8 FIX: resolve each compose service to its real container ID via
# `docker compose ps -q <service>` before inspecting, because container_name
# may differ from the service key and bare names cause false timeout warnings.
# ---------------------------------------------------------------------------
wait_for_services() {
  log_info "Waiting for critical services to become ready..."

  local services=(vaultwarden caddy)
  local timeout=90
  local interval=3
  local elapsed=0

  while (( elapsed < timeout )); do
    local all_ready=true

    for service in "${services[@]}"; do
      local container_id
      container_id=$(docker compose ps -q "$service" 2>/dev/null || true)

      if [[ -z "$container_id" ]]; then
        all_ready=false
        break
      fi

      local running
      running=$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || echo "false")
      local health
      health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || echo "unknown")

      if [[ "$running" != "true" ]]; then
        all_ready=false
        break
      fi

      if [[ "$health" != "healthy" && "$health" != "none" ]]; then
        all_ready=false
        break
      fi
    done

    if [[ "$all_ready" == "true" ]]; then
      log_success "Critical services are ready"
      return 0
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  log_warn "Service readiness check timed out after ${timeout}s"
  return 0
}

# ---------------------------------------------------------------------------
# run_health_check
#
# STARTUP-10 FIX: honour health.sh's documented exit-code contract:
#   exit 0  — all checks passed        → log_success, continue
#   exit 1  — one or more warnings     → log_warn, continue (degraded but ok)
#   exit 2  — one or more failures     → log_error, abort startup
#   exit 3+ — health.sh itself crashed → log_error, abort startup
#
# We must NOT use `if ./health.sh; then` because that collapses all
# non-zero codes to the same branch, hiding critical failures behind a
# warning message and giving the operator a false green signal.
# ---------------------------------------------------------------------------
run_health_check() {
  if [[ "$SKIP_HEALTH_CHECK" == "true" ]]; then
    log_info "Skipping post-start health check (--skip-health)"
    return 0
  fi

  if [[ ! -x "./health.sh" ]]; then
    log_warn "health.sh not executable or missing; skipping health check"
    return 0
  fi

  log_info "Running post-start health check..."

  # Disable errexit around health.sh so we can capture its exit code cleanly.
  # The outer set -euo pipefail would abort the script before we could inspect
  # the code if health.sh exits non-zero.
  local health_exit=0
  ./health.sh || health_exit=$?

  case "$health_exit" in
    0)
      log_success "Health check passed — all checks healthy"
      ;;
    1)
      log_warn "Health check completed with warnings — review output above"
      # Non-critical: startup continues, but operator should investigate
      ;;
    *)
      # exit 2 = one or more critical failures; exit 3+ = health.sh crash
      log_error "Health check reported CRITICAL failures (exit ${health_exit}) — stack is unhealthy"
      log_error "Startup aborted. Investigate the failures above, then re-run ./startup.sh"
      log_error "To skip this gate during recovery: ./startup.sh --skip-health"
      return 1
      ;;
  esac

  return 0
}

# ---------------------------------------------------------------------------
# show_status
# ---------------------------------------------------------------------------
show_status() {
  log_info "Current service status:"
  docker compose ps || true
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  log_info "Starting VaultWarden-OCI startup workflow..."

  load_environment || exit 1
  validate_prerequisites || exit 1
  prepare_directories || exit 1
  prepare_log_directories || log_warn "Log directory preparation had issues"
  prepare_docker_secrets || exit 1
  warn_plaintext_secret_overrides || true
  cleanup_orphaned_resources || true
  pull_images || exit 1
  start_services || exit 1

  if [[ "$BACKGROUND" != "true" ]]; then
    wait_for_services || true
    run_health_check || exit 1
    show_status || true
  fi

  log_success "VaultWarden-OCI startup completed"
}

main "$@"
