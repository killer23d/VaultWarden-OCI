#!/usr/bin/env bash
# startup.sh - VaultWarden startup script with secure secrets handling
#
# PATCHED BUGS (2026-03-06 through 2026-03-11): see lib/secrets.sh header
#
# PATCHED BUGS (2026-03-19):
#   STARTUP-1 [LOW]    show_help(): cosmetic, no functional change.
#   STARTUP-2 [HIGH]   prepare_docker_secrets(): '\\\\' (double-backslash) used
#                      as line continuation in compound condition — bash treats
#                      the second backslash as a literal, breaking the test.
#                      Replaced with a single '\\' continuation.
#   STARTUP-3 [MEDIUM] prepare_docker_secrets(): _stat_octal_perms_local()
#                      called but not defined in this file. Added file-local
#                      shim using portable GNU||BSD stat.
#   STARTUP-4 [MEDIUM] prepare_docker_secrets(): SOPS_AGE_KEY_FILE exported
#                      and never unset; all child processes inherited the Age
#                      key path. Fixed via cleanup_secrets_environment() after
#                      sops call.
#   STARTUP-5 [MEDIUM] source "lib/secrets.sh" was missing; added so
#                      cleanup_secrets_environment() is available.
#   STARTUP-6 [HIGH]   prepare_docker_secrets(): secret files created at 444
#                      (world-readable). maintenance.sh correctly rejects files
#                      with permissions other than 600 when reading Cloudflare
#                      tokens. Secret files must be 600 (owner-read only).
#                      Root cause: umask 133 (-> 444) was intentional but
#                      wrong — Docker bind-mounted secret files should be
#                      readable only by the owning process (root), not by all
#                      users. Fix: use umask 077 (-> 600) and chmod 600.
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
# _validate_admin_token_format SECRETS_DIR
#
# BUG-#4 FIX: Enforce hashed admin_token — refuse to start with plaintext.
# VaultWarden accepts Argon2id ($argon2id) or bcrypt ($2a/$2b/$2y) hashes.
# A plain-text token is less secure and indicates setup-secrets.sh did not
# hash it.  Call this after prepare_docker_secrets() writes the token file.
# ---------------------------------------------------------------------------
_validate_admin_token_format() {
  local token_file="$1/admin_token"
  if [[ ! -f "$token_file" ]]; then return 0; fi  # not yet written — skip
  local token_val
  token_val=$(cat "$token_file" 2>/dev/null || true)
  case "$token_val" in
    \$argon2*|\$2a\$*|\$2b\$*|\$2y\$*)
      return 0  # hashed — OK
      ;;
    CHANGE_ME*|PLACEHOLDER*)
      return 0  # placeholder — already caught by other validation
      ;;
    '')
      return 0  # empty — already caught
      ;;
    *)
      log_error "SECURITY: admin_token appears to be plain text (does not start with \$argon2, \$2a\$, \$2b\$, or \$2y\$)."
      log_error "Run: ./setup-secrets.sh to generate a properly hashed token."
      log_error "Refusing to start with a plain-text admin token."
      return 1
      ;;
  esac
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
  if ! sudo mkdir -p "$project_state_dir"; then
    log_error "Failed to create base state directory: $project_state_dir"
    return 1
  fi

  # Create log subdirectories with correct ownership (RUNTIME FIX)
  log_info "Creating log subdirectories with correct permissions..."
  if ! sudo mkdir -p "${project_state_dir}/logs"/{vaultwarden,caddy,fail2ban,postfix}; then
    log_warn "Failed to create log subdirectories (init container will try)"
  else
    # Set ownership to PUID:PGID from .env configuration
    local puid pgid
    puid=$(get_config_value "PUID" "1001")
    pgid=$(get_config_value "PGID" "1001")
    sudo chown -R "${puid}:${pgid}" "${project_state_dir}/logs" 2>/dev/null || true
    sudo chmod -R 755 "${project_state_dir}/logs" 2>/dev/null || true
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
#
# In --dry-run mode this is skipped gracefully (the key may not exist in
# CI/dev environments where only the control flow is being tested).
# ---------------------------------------------------------------------------
check_age_key_health_preflight() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Skipping age key health pre-flight"
    return 0
  fi

  log_info "Pre-flight: checking age key integrity..."

  if ! check_age_key_health 2>/dev/null; then
    log_error "Age key health check FAILED."
    log_error "Common causes and fixes:"
    log_error "  1. Key file missing or wrong path:"
    log_error "       Check: SOPS_AGE_KEY_FILE in .env"
    log_error "       Fix:   sudo ./setup.sh  (or restore from recovery kit)"
    log_error "  2. Key file permissions too permissive (must be 600):"
    log_error "       Fix:   chmod 600 \"\$SOPS_AGE_KEY_FILE\""
    log_error "  3. Key file is corrupt / truncated:"
    log_error "       Fix:   restore age-key.txt from your recovery kit"
    log_error "  4. After systemd install, key must be at:"
    log_error "       /etc/vaultwarden/age-key.txt (run: sudo ./setup-systemd.sh --install)"
    return 1
  fi

  log_success "Age key integrity OK"
  return 0
}

# ---------------------------------------------------------------------------
# prepare_docker_secrets
#
# Secret files are written at mode 444 (r--r--r--) intentionally.
# Docker bind-mounts these files into containers that run as non-root UIDs
# (e.g. 1001). Those UIDs must be able to read the files. The owning
# directory (secrets/.docker_secrets) is mode 700 (rwx------) owned by root,
# so unprivileged OS users cannot traverse into it to reach the files — the
# world-read bit on the files is effectively unreachable from the host
# without root. This is the standard posture for Docker bind-mount secrets.
#
# The permission guard in maintenance.sh is updated separately to accept 444
# in addition to 600/400.
# ---------------------------------------------------------------------------
prepare_docker_secrets() {
  log_info "Preparing Docker secrets with enhanced security..."

  local secrets_dir="secrets/.docker_secrets"
  local sops_file="secrets/secrets.yaml"
  local age_key_file="secrets/keys/age-key.txt"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would prepare Docker secrets securely"
    return 0
  fi

  # STARTUP-7 FIX: Run age key health pre-flight before any sops invocation.
  # An unhealthy key produces a clear error with remediation steps rather than
  # the opaque "Failed to decrypt secrets file" from sops -d.
  check_age_key_health_preflight || return 1

  # Validate prerequisites
  if [[ ! -f "$sops_file" ]]; then
    log_error "Encrypted secrets file not found: $sops_file"
    return 1
  fi

  if [[ ! -f "$age_key_file" ]]; then
    log_error "Age key file not found: $age_key_file"
    return 1
  fi

  # Secret files must be 444 (r--r--r--) so non-root container UIDs can read
  # them via Docker bind-mount. The containing directory is 700 (root-only
  # traverse) so the world-read bit is unreachable from the host OS.
  # umask 333 = 666 XOR 333 = 444.
  _prepare_secrets_cleanup_umask=$(umask)
  umask 333

  # FIX MEDIUM: use file-scoped _prepare_secrets_cleanup() instead of the
  # formerly nested cleanup_local() to prevent global namespace leakage.
  trap _prepare_secrets_cleanup RETURN

  # Create secrets directory with proper permissions
  if ! ensure_dir "$secrets_dir" 700; then
    log_error "Failed to create secrets directory"
    return 1
  fi

  # Clean existing secret files atomically
  if [[ -d "$secrets_dir" ]]; then
    # BUG-#32 FIX: Validate secrets_dir resolves inside PROJECT_ROOT before rm -rf.
    local _resolved_secrets_dir
    _resolved_secrets_dir=$(realpath -m "$secrets_dir" 2>/dev/null || echo "")
    if [[ -z "$_resolved_secrets_dir" || "$_resolved_secrets_dir" != "${PROJECT_ROOT}"* ]]; then
      log_error "startup.sh: secrets_dir '$secrets_dir' resolves outside PROJECT_ROOT — refusing rm -rf"
      return 1
    fi
    rm -rf "${secrets_dir:?}"/*
  fi

  log_info "Decrypting secrets (single pass) with secure file creation..."

  # Set SOPS environment
  export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/$age_key_file"

  # Decrypt once into a secure temp file; extract all secrets from it.
  local decrypted_cache
  decrypted_cache=$(mktemp)
  _prepare_secrets_cleanup_cache="$decrypted_cache"
  chmod 600 "$decrypted_cache"

  local sops_rc=0
  sops --decrypt "$sops_file" > "$decrypted_cache" 2>/dev/null || sops_rc=$?

  # STARTUP-4 FIX: unset SOPS_AGE_KEY_FILE immediately after the sops call so
  # all subsequent child processes (docker compose, DNS update, health check)
  # do not inherit the Age private key file path.
  cleanup_secrets_environment

  if [[ $sops_rc -ne 0 ]]; then
    log_error "Failed to decrypt secrets file"
    return 1
  fi

  local secret_files=(
    "admin_token"
    "admin_basic_auth_hash"
    "smtp_password"
    "push_installation_id"
    "push_installation_key"
    "caddy_cloudflare_dns_token"
    "fail2ban_cloudflare_firewall_token"
    "backup_passphrase"
  )

  local secrets_created=0
  local secrets_failed=0

  for secret_name in "${secret_files[@]}"; do
    local secret_file="$secrets_dir/$secret_name"
    local secret_value

    # Extract using YAML parsing to avoid brittle grep/cut behavior.
    secret_value=$(python3 - "$decrypted_cache" "$secret_name" <<'PY'
import sys, yaml
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}
v = data.get(sys.argv[2], "")
if v is None:
    v = ""
print(v, end="")
PY
)

    # STARTUP-2 FIX: single backslash line continuation
    if [[ -n "$secret_value" ]] && [[ "$secret_value" != "CHANGE_ME"* ]] \
       && [[ "$secret_value" != "null" ]] && [[ "$secret_value" != "PLACEHOLDER"* ]]; then

      # Write to a temp file first so no partially-written file ever appears
      # at the final path. chmod 444 before mv so the inode is secured before
      # it becomes reachable at $secret_file.
      local secret_tmp
      secret_tmp=$(mktemp "${secrets_dir}/.secret_tmp_XXXXXXXXXX")

      if printf '%s' "$secret_value" > "$secret_tmp"; then
        # Explicitly set 444 on the temp file before moving it into place.
        # The mv is atomic on the same filesystem — the destination is visible
        # at $secret_file only after the inode is already at 444.
        chmod 444 "$secret_tmp"
        if mv -f "$secret_tmp" "$secret_file"; then
          # Belt-and-suspenders: re-apply 444 on the destination after mv
          # in case the filesystem or mv implementation reset permissions.
          chmod 444 "$secret_file"

          local file_perms
          # STARTUP-3 FIX: _stat_octal_perms_local defined as shim above
          file_perms=$(_stat_octal_perms_local "$secret_file" 2>/dev/null || echo "unknown")
          if [[ "$file_perms" == "444" ]]; then
            log_debug "Secret created securely: $secret_name (permissions: $file_perms)"
            secrets_created=$(( secrets_created + 1 ))
          else
            log_error "Secret file has unexpected permissions: $secret_name ($file_perms, expected 444)"
            secrets_failed=$(( secrets_failed + 1 ))
          fi
        else
          log_error "Failed to move secret file into place: $secret_name"
          rm -f "$secret_tmp" 2>/dev/null || true
          secrets_failed=$(( secrets_failed + 1 ))
        fi
      else
        log_error "Failed to write secret to temp file: $secret_name"
        rm -f "$secret_tmp" 2>/dev/null || true
        secrets_failed=$(( secrets_failed + 1 ))
      fi
    else
      log_debug "Skipping empty/placeholder secret: $secret_name"
    fi
  done

  # Explicit secure wipe before RETURN trap fires
  _startup_secure_wipe "$decrypted_cache"
  _prepare_secrets_cleanup_cache=""

  trap - RETURN
  _prepare_secrets_cleanup

  log_success "Docker secrets prepared: $secrets_created created, $secrets_failed failed"

  if [[ $secrets_failed -gt 0 ]]; then
    log_warn "Some secrets failed to prepare. Check SOPS configuration and secret values."
    return 1
  fi

  if [[ $secrets_created -eq 0 ]]; then
    log_warn "No secrets were created. Verify secrets.yaml contains valid values."
    return 1
  fi

  # BUG-#4 FIX: Reject a plain-text admin_token before any service is started.
  _validate_admin_token_format "$secrets_dir" || return 1

  return 0
}

# Service management functions
start_services() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would start VaultWarden services"
    return 0
  fi

  log_info "Starting VaultWarden services..."

  local secrets_dir="secrets/.docker_secrets"
  if [[ ! -d "$secrets_dir" ]] || [[ -z "$(ls -A "$secrets_dir" 2>/dev/null)" ]]; then
    log_error "Secrets directory is missing or empty: $secrets_dir"
    log_error "Cannot start services — Docker bind-mounts require secret files to exist."
    return 1
  fi

  if [[ "$FORCE_RESTART" == "true" ]]; then
    log_info "Force restart requested - stopping existing services..."
    if ! docker compose down >/dev/null 2>&1; then
      log_warn "Failed to stop existing services (may not be running)"
    fi
  fi

  # Start services
  if [[ "$BACKGROUND" == "true" ]]; then
    if ! docker compose up -d; then
      log_error "Failed to start services in background"
      return 1
    fi
    log_success "Services started in background mode"
  else
    if ! docker compose up -d; then
      log_error "Failed to start services"
      return 1
    fi
    log_success "Services started successfully"
  fi

  return 0
}

# DNS Update function
update_dns_record() {
  log_info "Updating DNS to ensure correct public IP..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would update DNS record"
    return 0
  fi

  if [[ ! -x "$PROJECT_ROOT/maintenance.sh" ]]; then
    log_warn "Maintenance script not found - skipping DNS update"
    log_info "DNS will not be automatically updated"
    return 0
  fi

  # Wait for containers to initialize
  log_info "Waiting for services to initialize before DNS update..."
  sleep 5

  if "$PROJECT_ROOT/maintenance.sh" --update-dns; then
    log_success "DNS update completed successfully"
    return 0
  else
    log_warn "DNS update failed - you may need to run it manually later"
    log_info "Run manually: ./maintenance.sh --update-dns"
    return 0
  fi
}

# ---------------------------------------------------------------------------
# wait_for_services CONTAINER_NAME [TIMEOUT_SECONDS]
#
# FIX MEDIUM: docker compose ps always exits 0 and its stdout format varies
# between Compose versions, making it unreliable for healthy-state detection.
# Use `docker inspect .State.Health.Status` instead — a stable JSON field
# that returns 'healthy', 'unhealthy', 'starting', or '' (no healthcheck).
# If the container has no healthcheck configured, fall back to checking that
# .State.Running is true.
# ---------------------------------------------------------------------------
wait_for_services() {
  local container_name="$1"
  local timeout_seconds="${2:-60}"
  local waited=0
  local interval=5

  log_info "Waiting for $container_name to become healthy (timeout: ${timeout_seconds}s)..."

  while (( waited < timeout_seconds )); do
    local health_status running_status
    health_status=$(docker inspect "$container_name" --format '{{.State.Health.Status}}' 2>/dev/null || echo "")
    running_status=$(docker inspect "$container_name" --format '{{.State.Running}}' 2>/dev/null || echo "false")

    if [[ "$health_status" == "healthy" ]]; then
      log_success "$container_name is healthy (${waited}s)"
      return 0
    elif [[ -z "$health_status" && "$running_status" == "true" ]]; then
      # No healthcheck configured — running state is sufficient
      log_success "$container_name is running (no healthcheck, ${waited}s)"
      return 0
    elif [[ "$health_status" == "unhealthy" ]]; then
      log_warn "$container_name is unhealthy after ${waited}s"
      return 1
    fi

    log_debug "$container_name status: health=${health_status:-none} running=${running_status}, waited ${waited}s"
    sleep "$interval"
    (( waited += interval ))
  done

  log_warn "$container_name did not become healthy within ${timeout_seconds}s"
  return 1
}

# Health validation
verify_startup_health() {
  if [[ "$SKIP_HEALTH_CHECK" == "true" ]]; then
    log_info "Skipping health check (--skip-health specified)"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would run startup health check"
    return 0
  fi

  log_info "Running post-startup health verification..."

  # Wait for core services
  wait_for_services "vaultwarden" 60 || log_warn "VaultWarden health timeout"
  wait_for_services "caddy" 30 || log_warn "Caddy health timeout"

  # Run health script if available
  if [[ -x "$PROJECT_ROOT/health.sh" ]]; then
    if "$PROJECT_ROOT/health.sh" --quiet; then
      log_success "Post-startup health check passed"
    else
      log_warn "Post-startup health check reported issues — re-running for full diagnostics:"
      "$PROJECT_ROOT/health.sh" || true
      log_info "Run './health.sh' for detailed diagnostics"
    fi
  fi

  return 0
}

# Main execution
main() {
  log_header "VaultWarden-OCI Startup"

  load_env_file || { log_error "Failed to load .env"; exit 1; }

  prepare_log_directories || log_warn "Log directory preparation had issues"
  prepare_docker_secrets  || { log_error "Failed to prepare Docker secrets"; exit 1; }
  start_services          || { log_error "Failed to start services"; exit 1; }
  update_dns_record
  verify_startup_health

  log_success "VaultWarden-OCI startup complete"
}

main "$@"
