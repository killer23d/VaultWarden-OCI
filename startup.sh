#!/usr/bin/env bash
# startup.sh - VaultWarden startup script with secure secrets handling

set -euo pipefail
# shellcheck disable=SC2154  # rc is assigned via rc=$? inside the trap body
trap 'rc=$?; log_error "${BASH_SOURCE[0]}: STARTUP FAILED at line ${LINENO} (exit ${rc}) — check journalctl -u vaultwarden-startup"; exit "$rc"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "${SCRIPT_DIR}/lib/common.sh"
init_common_lib "$0"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/crypto.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"   # provides cleanup_secrets_environment()
source "${SCRIPT_DIR}/lib/storage.sh"  # provides require_project_state_ready()

# Configuration
FORCE_RESTART=false
SKIP_HEALTH_CHECK=false
BACKGROUND=false
DRY_RUN=false
DO_DOWN=false
# Pass --skip-pull in the unit file to avoid image pulls on routine service restarts;
# use maintenance.sh update or ./startup.sh (without the flag) to refresh images.
SKIP_PULL=false
SKIP_EGRESS_FIX=false

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

EXAMPLES:
  ./startup.sh                    # Normal startup (pulls latest images)
  ./startup.sh --skip-pull        # Restart without pulling (fast path)
  ./startup.sh --force            # Force restart all services
  ./startup.sh --background       # Start in daemon mode
  ./startup.sh stop               # Stop all services
EOF
}

# Argument parsing — subcommand-first, then options.
# 'stop' is the only positional subcommand.
if [[ $# -gt 0 ]]; then
  case "$1" in
    stop)
      DO_DOWN=true; shift
      ;;
    help|--help|-h)
      show_help; exit 0
      ;;
    --*)
      # Falls through to the options while-loop below
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
    *) log_error "Unknown option: '$1'"; show_help; exit 1 ;;
  esac
done

# stop subcommand: stop all services and exit immediately
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
# _prepare_secrets_cleanup
#
# Cleans up temporary files and restores umask after prepare_docker_secrets().
# ---------------------------------------------------------------------------
_prepare_secrets_cleanup_umask=""
_prepare_secrets_cleanup_cache=""
_prepare_secrets_trap_registered=false

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
# Detects split-brain secret configuration where plaintext EMAIL_API_TOKEN or
# SMTP_PASSWORD values in .env override SOPS-managed secrets. Emits warnings only.
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
# check_email_config_consistency
#
# Cross-checks EMAIL_MODE against the presence of the required secret so the
# operator gets an actionable warning at startup rather than a silent failure
# on first email send.
#
# This is a WARN, not an error — email is not required for the stack to start.
# ---------------------------------------------------------------------------
check_email_config_consistency() {
  local email_mode="${EMAIL_MODE:-auto}"
  local secrets_dir="$DOCKER_SECRETS_DIR"

  case "$email_mode" in
    api)
      # EMAIL_MODE=api requires email_api_token to be present and non-empty.
      local token_file="${secrets_dir}/email_api_token"
      if [[ ! -f "$token_file" ]] || [[ ! -s "$token_file" ]]; then
        log_warn "EMAIL_MODE=api is set but '${token_file}' is absent or empty."
        log_warn "  All alert emails will fail silently until the token is populated."
        log_warn "  Fix: ./edit-secrets.sh rotate email_api_token"
      fi
      ;;
    smtp)
      # EMAIL_MODE=smtp requires smtp_password.
      local pw_file="${secrets_dir}/smtp_password"
      if [[ ! -f "$pw_file" ]] || [[ ! -s "$pw_file" ]]; then
        log_warn "EMAIL_MODE=smtp is set but '${pw_file}' is absent or empty."
        log_warn "  SMTP relay authentication will fail on first send."
        log_warn "  Fix: ./edit-secrets.sh rotate smtp_password"
      fi
      ;;
    auto|host)
      # auto and host do not require a specific secret — skip.
      ;;
    *)
      log_warn "EMAIL_MODE='${email_mode}' is not a recognised value (auto|api|smtp|host)."
      log_warn "  Email delivery may fail. Check EMAIL_MODE in .env."
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# load_environment
# ---------------------------------------------------------------------------
load_environment() {
  log_info "Loading environment configuration..."

  if [ -f ".env" ]; then
    # Permission check: if .env is not readable by the current user, fail early
    # with a clear, actionable error. This happens when setup.sh was run as root
    # without SUDO_USER set (e.g. sudo make setup) and get_real_user() fell back
    # to 'root', causing .env to be chowned root:root 600.
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

    # Warn if .env is root-owned while startup is running as a non-root user.
    # startup.sh runs via `sudo ./startup.sh` so it CAN read root:root 600 .env,
    # but non-root tools (edit-secrets.sh, etc.) will get Permission denied.
    local env_owner
    env_owner=$(stat -c '%U' ".env" 2>/dev/null || echo "unknown")
    local real_user
    real_user=$(get_real_user)
    if [[ "$env_owner" == "root" && "$real_user" != "root" ]]; then
      local real_group
      real_group=$(id -gn "${real_user}" 2>/dev/null || echo "${real_user}")
      log_warn ".env is owned by root but startup is running as ${real_user}."
      log_warn "Non-root tools (edit-secrets.sh, etc.) cannot read .env."
      log_warn "Fix: sudo chown ${real_user}:${real_group} .env && sudo chmod 600 .env"
    fi
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
  local required_commands=(docker openssl sops python3)
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

  # Verify python3-yaml is available — required for secrets parsing in prepare_docker_secrets
  if ! python3 -c "import yaml" 2>/dev/null; then
    log_error "python3-yaml (PyYAML) is not installed — required for secrets parsing"
    log_error "Install hint: pip install pyyaml  or  sudo apt install python3-yaml"
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
# Ensures all PROJECT_STATE_DIR subdirectories required by Docker bind mounts
# exist on the host before `docker compose up`.  Uses absolute paths so that
# separate-volume installs (PROJECT_STATE_DIR=/mnt/vw-data) create dirs on
# the data volume, not under PROJECT_ROOT.
#
# prepare_log_directories() handles logs/ and backups/ with ownership logic;
# this function covers the remaining non-log subtrees.
# ---------------------------------------------------------------------------
prepare_directories() {
  local project_state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"

  local required_dirs=(
    "${project_state_dir}/data"
    "${project_state_dir}/caddy/data"
    "${project_state_dir}/caddy/config"
    "${project_state_dir}/fail2ban"
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

# Prepare log directories with correct ownership
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

  # Create log subdirectories with correct ownership
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

  # Create backup directory
  local backup_dir
  backup_dir="$(get_config_value "BACKUP_DIR" "${project_state_dir}/backups")"
  if ! _maybe_sudo mkdir -p "$backup_dir" 2>/dev/null; then
    log_warn "Could not create backup directory: $backup_dir"
  else
    log_info "Backup directory ready: $backup_dir"
  fi

  # Ensure Caddy entrypoint is executable
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
# Runs check_age_key_health() before any SOPS invocation so a corrupt,
# missing, or wrong-permissions age key produces a clear actionable error
# rather than an opaque decryption failure from SOPS.
#
# If the configured key path does not exist but the repo-local key is
# present and healthy, the key path is overridden for this process only and
# a prominent ACTION REQUIRED advisory is printed so the operator fixes
# .env before the next restart.
# ---------------------------------------------------------------------------
check_age_key_health_preflight() {
  # Resolve the configured key path from .env (already sourced by load_environment)
  local configured_key="${SOPS_AGE_KEY_FILE:-}"

  # If SOPS_AGE_KEY_FILE is empty, fall back to the SOPS default
  if [[ -z "$configured_key" ]]; then
    configured_key="${HOME:-/root}/.config/sops/age/keys.txt"
  fi

  # Fast path: configured key exists and is healthy — proceed
  if check_age_key_health "$configured_key" 2>/dev/null; then
    return 0
  fi

  # Configured key is missing or unhealthy. Collect diagnostic context.
  local repo_local_key="${SCRIPT_DIR}/secrets/keys/age-key.txt"
  local canonical_key="/etc/vaultwarden/age-key.txt"

  if [[ -f "$repo_local_key" ]] && check_age_key_health "$repo_local_key" 2>/dev/null; then
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
    log_warn "    sudo install -d -m 700 /etc/vaultwarden"
    log_warn "    sudo install -m 600 ${repo_local_key} ${canonical_key}"
    log_warn "    sudo chown root:root /etc/vaultwarden ${canonical_key}"
    log_warn "    # Verify: make key-health"
    log_warn ""
    log_warn "  Option B — Update .env to point at the repo-local key (local/dev only):"
    log_warn "    sed -i 's|^SOPS_AGE_KEY_FILE=.*|SOPS_AGE_KEY_FILE=${repo_local_key}|' .env"
    log_warn "    # Verify: make key-health"
    log_warn ""
    log_warn "  Option C — Run setup again to reinstall everything cleanly:"
    log_warn "    sudo ./setup.sh --domain <your-domain> --email <your-email>"
    log_warn "=========================================================="

    # Export the repo-local path for this process only
    export SOPS_AGE_KEY_FILE="$repo_local_key"
    return 0
  fi

  # No usable key found anywhere — abort with full diagnostics.
  log_error "Age key health check FAILED for configured path: ${configured_key}"
  log_error ""
  log_error "SOPS cannot decrypt secrets without a valid Age private key."
  log_error ""

  # Case 1: configured path IS the canonical path — just report it missing.
  if [[ "$configured_key" == "$canonical_key" ]]; then
    log_error "Remediation:"
    log_error "  The canonical key file does not exist or is not readable."
    log_error "  Re-run setup to install it:"
    log_error "    sudo ./setup.sh --domain <your-domain> --email <your-email>"
    if [[ -f "$repo_local_key" ]]; then
      log_error ""
      log_warn "  A repo-local key was detected at: ${repo_local_key}"
      log_warn "  If this is the correct production key, install it with:"
      log_warn "    sudo install -d -m 700 /etc/vaultwarden"
      log_warn "    sudo install -m 600 ${repo_local_key} /etc/vaultwarden/age-key.txt"
      log_warn "    sudo chown root:root /etc/vaultwarden /etc/vaultwarden/age-key.txt"
      log_warn "  Then run: make key-health to verify before retrying startup."
    fi
    return 1
  fi

  # Case 2: configured path is NOT canonical — check whether the canonical path
  # exists so the operator understands the full picture.
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

# ---------------------------------------------------------------------------
# prepare_docker_secrets
# ---------------------------------------------------------------------------
prepare_docker_secrets() {
  log_info "Preparing Docker secrets from SOPS..."

  check_age_key_health_preflight || return 1

  # Use SECRETS_FILE (from lib/secrets.sh, defaults to secrets/secrets.yaml)
  # for consistency with all other secrets consumers in the codebase.
  local secrets_file="${SECRETS_FILE:-secrets/secrets.yaml}"

  if [[ ! -f "$secrets_file" ]]; then
    log_warn "$secrets_file not found; skipping Docker secrets preparation"
    return 0
  fi

  local secrets_dir="$DOCKER_SECRETS_DIR"
  mkdir -p "$secrets_dir"
  chmod 700 "$secrets_dir"

  local old_umask
  old_umask=$(umask)
  _prepare_secrets_cleanup_umask="$old_umask"
  # Register the cleanup EXIT trap exactly once using a boolean flag so that
  # we do not need to compose/decompose existing trap bodies via sed (which
  # breaks silently when the body contains single quotes).
  if [[ "$_prepare_secrets_trap_registered" != "true" ]]; then
    trap '_prepare_secrets_cleanup' EXIT
    _prepare_secrets_trap_registered=true
  fi
  # umask 077: new files are created as 0600 (no group/world bits).
  # This is consistent with lib/secrets.sh::write_secret_file() (chmod 600).
  umask 077

  # W3-M8 FIX: Create the cache file inside the already-restricted secrets_dir
  # (mode 700) rather than the world-listable /tmp, eliminating the TOCTOU
  # window between mktemp and the subsequent chmod on a shared host.
  local cache_file
  cache_file=$(mktemp --tmpdir="$secrets_dir" .sops-cache.XXXXXXXXXX)
  _prepare_secrets_cleanup_cache="$cache_file"

  if ! sops -d "$secrets_file" > "$cache_file"; then
    log_error "Failed to decrypt $secrets_file"
    return 1
  fi

  # Minimal parser for the known flat structure used by this project.
  # We intentionally avoid yq/jq dependency here.
  # Pass secrets file path as argument to avoid hardcoded relative paths.
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    local target_file="${secrets_dir}/${key}"
    printf '%s' "$value" > "$target_file"
  done < <(
    python3 - "$cache_file" <<'PY'
import sys, yaml
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}
for k, v in data.items():
    if isinstance(v, (str, int, float)):
        print(f"{k}={v}")
PY
  )

  # Sanity-check: if any secret file starts with "ENC[", SOPS decryption
  # silently produced raw ciphertext — fail loudly before containers start.
  local bad_secrets=()
  local f _head
  for f in "$secrets_dir"/*; do
    [[ -f "$f" ]] || continue
    if read -r -n 4 _head < "$f" 2>/dev/null && [[ "$_head" == "ENC[" ]]; then
      bad_secrets+=("$(basename "$f")")
    fi
  done
  if [[ ${#bad_secrets[@]} -gt 0 ]]; then
    log_error "prepare_docker_secrets: secret file(s) contain raw SOPS ciphertext — decryption failed silently:"
    local s
    for s in "${bad_secrets[@]}"; do
      log_error "  ${secrets_dir}/${s}"
    done
    log_error "Remediation:"
    log_error "  1. Run: make key-health  (verify age key is present and readable)"
    log_error "  2. Run: sudo rm -f ${secrets_dir}/*  (clear stale files)"
    log_error "  3. Run: make up  (re-decrypt and restart)"
    return 1
  fi

  cleanup_secrets_environment || true
  _prepare_secrets_cleanup
  # The EXIT trap remains active for the lifetime of the process so that any
  # unexpected exit after this point still cleans up any residual temp files.

  log_success "Docker secrets prepared"
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
  # Scope image prune to this project's images only to avoid removing dangling
  # layers belonging to unrelated services on shared Docker hosts.
  docker image prune -f \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-vaultwarden}" \
    >/dev/null 2>&1 || true

  log_success "Orphaned resources cleaned up"
  return 0
}

# ---------------------------------------------------------------------------
# pull_images
#
# Guarded by --skip-pull so systemd ExecStart restarts are instant.
# Image refreshes go through maintenance.sh update or a manual
# ./startup.sh without --skip-pull.
# ---------------------------------------------------------------------------
pull_images() {
  if [[ "$SKIP_PULL" == "true" ]]; then
    log_info "Skipping docker compose pull (--skip-pull)"
    return 0
  fi

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
# ensure_vaultwarden_egress_nat
#
# Admin-friendly, idempotent fallback for hardened VMs where Docker's normal
# MASQUERADE behavior is missing/overridden. We only target non-internal
# bridge networks attached to the vaultwarden container.
# ---------------------------------------------------------------------------
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

  # Preferred path: use repo-managed setup helper so NAT + DOCKER-USER
  # remediation stays in one place and can also be reused outside startup.
  if [[ -x "./utilities/setup-iptables.sh" ]]; then
    log_info "Invoking: $SCRIPT_DIR/utilities/setup-iptables.sh"
    if _maybe_sudo ./utilities/setup-iptables.sh; then
      log_success "Egress firewall remediation completed via utilities/setup-iptables.sh"
      return 0
    fi
    log_warn "utilities/setup-iptables.sh failed; falling back to inline NAT remediation"
  fi

  local container_id
  container_id=$(docker compose ps -q vaultwarden 2>/dev/null || true)
  if [[ -z "$container_id" ]]; then
    log_warn "vaultwarden container not found; skipping egress NAT remediation"
    return 0
  fi

  local network_name
  local fixed_any=false
  while IFS= read -r network_name; do
    [[ -z "$network_name" ]] && continue

    local driver internal subnet
    driver=$(docker network inspect -f '{{.Driver}}' "$network_name" 2>/dev/null || echo "")
    internal=$(docker network inspect -f '{{.Internal}}' "$network_name" 2>/dev/null || echo "")
    subnet=$(docker network inspect -f '{{with index .IPAM.Config 0}}{{.Subnet}}{{end}}' "$network_name" 2>/dev/null || echo "")

    [[ "$driver" == "bridge" ]] || continue
    [[ "$internal" == "false" ]] || continue
    [[ -n "$subnet" ]] || continue

    if _maybe_sudo iptables -t nat -C POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE >/dev/null 2>&1; then
      continue
    fi

    if _maybe_sudo iptables -t nat -A POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE >/dev/null 2>&1; then
      log_info "Added MASQUERADE fallback for network ${network_name} (${subnet})"
      log_warn "Inline iptables MASQUERADE rule is ephemeral — it will not survive a reboot."
      log_warn "For persistence, run: sudo ./utilities/setup-iptables.sh"
      fixed_any=true
    else
      log_warn "Could not add MASQUERADE fallback for network ${network_name} (${subnet})"
    fi
  done < <(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$container_id" 2>/dev/null || true)

  if [[ "$fixed_any" == "true" ]]; then
    log_success "Egress NAT remediation applied for VaultWarden network attachments"
  else
    log_info "Egress NAT remediation check complete (no changes needed)"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# wait_for_services
# ---------------------------------------------------------------------------
wait_for_services() {
  log_info "Waiting for critical services to become ready..."

  local services=(vaultwarden caddy fail2ban)
  local timeout=90
  local interval=3
  local progress_interval=9   # emit a status line every 3rd poll
  local elapsed=0
  local next_progress=0

  while (( elapsed < timeout )); do
    local all_ready=true
    local status_parts=()

    for service in "${services[@]}"; do
      local container_id
      container_id=$(docker compose ps -q "$service" 2>/dev/null || true)

      if [[ -z "$container_id" ]]; then
        all_ready=false
        status_parts+=("${service}:not-found")
        continue
      fi

      local running
      running=$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || echo "false")
      local health
      health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || echo "unknown")

      if [[ "$running" != "true" ]]; then
        all_ready=false
        status_parts+=("${service}:not-running")
        continue
      fi

      # W3-C2 FIX: VaultWarden must report health==healthy before it is
      # considered ready. Accepting health==none for VaultWarden means the
      # container starts without a healthcheck — which is a configuration error
      # that would cause startup to proceed with an unhealthy service silently.
      # Other services (caddy, fail2ban) are allowed to report health==none
      # if they don't define a HEALTHCHECK in their Dockerfile.
      if [[ "$service" == "vaultwarden" ]]; then
        if [[ "$health" != "healthy" ]]; then
          all_ready=false
          status_parts+=("${service}:${health}")
          continue
        fi
      else
        if [[ "$health" != "healthy" && "$health" != "none" ]]; then
          all_ready=false
          status_parts+=("${service}:${health}")
          continue
        fi
      fi

      status_parts+=("${service}:ready")
    done

    if [[ "$all_ready" == "true" ]]; then
      log_success "Critical services are ready"
      return 0
    fi

    # Emit a progress line periodically so the operator can see the wait is
    # active and which container is still not ready — prevents the terminal
    # from appearing frozen during slow-start containers (e.g. fail2ban).
    if (( elapsed >= next_progress )); then
      local remaining=$(( timeout - elapsed ))
      log_info "Still waiting... ${elapsed}s elapsed, up to ${remaining}s remaining — $(IFS=', '; echo "${status_parts[*]}")"
      next_progress=$(( elapsed + progress_interval ))
    fi

    sleep "$interval"
    elapsed=$(( elapsed + interval ))
  done

  log_error "Service readiness check timed out after ${timeout}s — stack may not be fully ready"
  return 1
}

# ---------------------------------------------------------------------------
# run_health_check
# ---------------------------------------------------------------------------
run_health_check() {
  if [[ "$SKIP_HEALTH_CHECK" == "true" ]]; then
    log_info "Skipping post-start health check (--skip-health)"
    return 0
  fi

  if [[ ! -x "./maintenance.sh" ]]; then
    log_warn "maintenance.sh not executable or missing; skipping health check"
    return 0
  fi

  log_info "Running post-start health check..."

  # Disable errexit around maintenance.sh health so we can capture its exit code cleanly.
  # The outer set -euo pipefail would abort the script before we could inspect
  # the code if maintenance.sh health exits non-zero.
  log_info "Invoking: $SCRIPT_DIR/maintenance.sh health"
  local health_exit=0
  ./maintenance.sh health || health_exit=$?

  case "$health_exit" in
    0)
      log_success "Health check passed — all checks healthy"
      ;;
    1)
      log_warn "Health check completed with warnings — review output above"
      # Non-critical: startup continues, but operator should investigate
      ;;
    *)
      # exit 2 = one or more critical failures; exit 3+ = maintenance.sh crash
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

  # W3-M2 FIX: Add INT/TERM signal traps so that secrets are cleaned up and
  # the exit code correctly reflects termination (130 for INT, 143 for TERM).
  trap '_prepare_secrets_cleanup; exit 130' INT
  trap '_prepare_secrets_cleanup; exit 143' TERM

  load_environment || exit 1
  require_project_state_ready || exit 1
  validate_prerequisites || exit 1
  prepare_directories || exit 1
  prepare_log_directories || exit 1
  prepare_docker_secrets || exit 1
  check_email_config_consistency || true   # warn only, never block startup
  warn_plaintext_secret_overrides || true
  cleanup_orphaned_resources || true
  ensure_vaultwarden_egress_nat || true
  pull_images || exit 1
  start_services || exit 1

  if [[ "$BACKGROUND" != "true" ]]; then
    wait_for_services || true
    run_health_check || {
      log_error "Startup tip: if the failure is key-related, run: make key-health"
      log_error "Canonical production key path: /etc/vaultwarden/age-key.txt"
      exit 1
    }
    show_status || true
  fi

  # Re-emit the key-path advisory at end of startup so it is not missed.
  if [[ "${SOPS_AGE_KEY_FILE:-}" == "${SCRIPT_DIR}/secrets/keys/age-key.txt" ]]; then
    local cfg_key
    cfg_key=$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2- || echo "(unknown)")
    if [[ "$cfg_key" != "${SCRIPT_DIR}/secrets/keys/age-key.txt" ]]; then
      log_warn "=========================================================="
      log_warn "REMINDER: SOPS_AGE_KEY_FILE in .env (${cfg_key}) was overridden"
      log_warn "at runtime by the repo-local key. Update .env or install"
      log_warn "the key to /etc/vaultwarden/age-key.txt before next restart."
      log_warn "=========================================================="
    fi
  fi

  log_success "VaultWarden-OCI startup completed"
}

main "$@"
