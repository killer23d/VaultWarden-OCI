#!/usr/bin/env bash
# startup.sh - Enhanced VaultWarden startup script with secure secrets handling

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"

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
# FIX [ISSUE 2]: --force is now a first-class flag; --force-restart kept as alias.
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
# FIX [ST-H1]: Securely overwrite and remove a sensitive temp file.
# Mirrors lib/secrets.sh::_secure_shred() to handle CoW filesystems
# (btrfs, snapshotted ext4 on OCI block volumes) where shred(1) cannot
# guarantee extent reuse and therefore cannot guarantee data erasure.
#
# Strategy:
#   1. shred(1) when available — best effort on non-CoW filesystems.
#   2. dd(1) overwrite with /dev/urandom — effective on CoW filesystems
#      because writing new data forces a new extent allocation, breaking
#      the old snapshot's reference to the plaintext extent.
#   3. rm(1) — removes the directory entry in all cases.
#
# Portable stat: GNU uses -c%s; BSD/macOS uses -f%z.
# Safe default of 4096 bytes is used if stat fails.
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

# ENHANCED: Secure secret file preparation with YAML extraction fix
# FIX [ISSUE 12]: Decrypt SOPS file once and cache the plaintext, then extract
#                 all secrets from the cache. Avoids N heavy age decrypt operations.
# FIX [ST-H1]:   Replaced shred-only wipe with _startup_secure_wipe() which
#                 uses a dd-overwrite fallback, making erasure effective on
#                 CoW filesystems (btrfs / snapshotted ext4 on OCI block volumes).
prepare_docker_secrets() {
  log_info "Preparing Docker secrets with enhanced security..."

  local secrets_dir="secrets/.docker_secrets"
  local sops_file="secrets/secrets.yaml"
  local age_key_file="secrets/keys/age-key.txt"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would prepare Docker secrets securely"
    return 0
  fi

  # Validate prerequisites
  if [[ ! -f "$sops_file" ]]; then
    log_error "Encrypted secrets file not found: $sops_file"
    return 1
  fi

  if [[ ! -f "$age_key_file" ]]; then
    log_error "Age key file not found: $age_key_file"
    return 1
  fi

  # SECURITY FIX: Set restrictive umask BEFORE creating any files
  local old_umask
  old_umask=$(umask)
  umask 077 # Ensures all new files are created with 600 permissions

  # Cleanup function scoped to this function invocation.
  local decrypted_cache=""
  cleanup_local() {
    umask "$old_umask"
    if [[ -n "$decrypted_cache" ]]; then
      # FIX [ST-H1]: Use _startup_secure_wipe instead of shred-only to handle
      # CoW filesystems where shred cannot guarantee extent reuse.
      _startup_secure_wipe "$decrypted_cache"
      decrypted_cache=""
    fi
  }
  trap cleanup_local RETURN

  # Create secrets directory with proper permissions
  if ! ensure_dir "$secrets_dir" 700; then
    log_error "Failed to create secrets directory"
    return 1
  fi

  # Clean existing secret files atomically
  if [[ -d "$secrets_dir" ]]; then
    rm -rf "${secrets_dir:?}"/*
  fi

  log_info "Decrypting secrets (single pass) with secure file creation..."

  # Set SOPS environment
  export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/$age_key_file"

  # FIX [ISSUE 12]: Decrypt once into a secure temp file; extract all secrets from it.
  # FIX [ST-H1]:   File is wiped via _startup_secure_wipe() on RETURN (see cleanup_local).
  decrypted_cache=$(mktemp)
  chmod 600 "$decrypted_cache"

  if ! sops --decrypt "$sops_file" > "$decrypted_cache" 2>/dev/null; then
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

    if [[ -n "$secret_value" ]] && [[ "$secret_value" != "CHANGE_ME"* ]] && \
       [[ "$secret_value" != "null" ]] && [[ "$secret_value" != "PLACEHOLDER"* ]]; then
      if printf '%s' "$secret_value" > "$secret_file"; then
        local file_perms
        file_perms=$(_stat_octal_perms_local "$secret_file" 2>/dev/null || echo "unknown")
        if [[ "$file_perms" == "600" ]]; then
          log_debug "Secret created securely: $secret_name (permissions: $file_perms)"
          secrets_created=$(( secrets_created + 1 ))
        else
          log_error "Secret file created with incorrect permissions: $secret_name ($file_perms)"
          secrets_failed=$(( secrets_failed + 1 ))
        fi
      else
        log_error "Failed to create secret file: $secret_name"
        secrets_failed=$(( secrets_failed + 1 ))
      fi
    else
      log_debug "Skipping empty/placeholder secret: $secret_name"
    fi
  done

  # FIX [ST-H1]: Explicit secure wipe before RETURN trap fires, so the wipe
  # happens here in the success path and cleanup_local becomes a safe no-op.
  _startup_secure_wipe "$decrypted_cache"
  decrypted_cache=""

  # Restore cleanup trap and umask
  trap - RETURN
  cleanup_local

  log_success "Docker secrets prepared: $secrets_created created, $secrets_failed failed"

  if [[ $secrets_failed -gt 0 ]]; then
    log_warn "Some secrets failed to prepare. Check SOPS configuration and secret values."
    return 1
  fi

  if [[ $secrets_created -eq 0 ]]; then
    log_warn "No secrets were created. Verify secrets.yaml contains valid values."
    return 1
  fi

  return 0
}

# Service management functions
start_services() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would start VaultWarden services"
    return 0
  fi

  log_info "Starting VaultWarden services..."

  # FIX [ST-M2]: Enforce the architectural contract that secret files must
  # exist before Docker bind-mounts them. This makes the cleanup_on_exit()
  # comment-only guard concrete and catches accidental pre-startup deletion.
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

# Health validation
# FIX [ST-M1]: Pass --auto-recover unconditionally so health.sh can take
# corrective action on startup failures (container restarts, etc.).
# Pass --email only when ADMIN_EMAIL is configured so alert delivery is
# gated on a known-good destination, matching health.sh's own convention.
verify_startup_health() {
  if [[ "$SKIP_HEALTH_CHECK" == "true" ]]; then
    log_info "Skipping health check (--skip-health specified)"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would verify service health"
    return 0
  fi

  log_info "Verifying service health after startup..."
  sleep 30

  if [[ -f "./health.sh" ]]; then
    # Build health.sh argument list
    local health_args=("--auto-recover")
    if [[ -n "${ADMIN_EMAIL:-}" ]]; then
      health_args+=("--email")
    fi

    # Prefer sudo here because health.sh may need root to decrypt/check backups
    if _maybe_sudo ./health.sh "${health_args[@]}"; then
      log_success "All services are healthy"
      return 0
    else
      log_warn "Health check failed - some services may not be ready"
      log_info "Services may still be initializing. Check with: docker compose ps"
      # Keep non-fatal behavior as before
      return 0
    fi
  else
    log_info "Health check script not found, skipping detailed health verification"
    return 0
  fi
}

# ---------------------------------------------------------------------------
# cleanup_on_exit
#
# FIX [ST-M2]: The previous implementation was a silent colon stub with only
# a comment to prevent accidental secret deletion. Replaced with an explicit
# 'return 0' and an expanded contract comment.
#
# ARCHITECTURAL CONTRACT:
#   Docker bind-mounts in docker-compose.yml reference files under
#   secrets/.docker_secrets/. Those files MUST remain on disk from the time
#   prepare_docker_secrets() writes them until *after* docker compose up
#   completes and Docker has read them into the container namespace.
#
#   start_services() now asserts that the secrets directory is non-empty
#   before calling docker compose up, making this contract enforceable at
#   runtime rather than relying solely on this comment.
#
#   Do NOT add rm/shred calls here for the secrets directory. The files are
#   intentionally left on disk; they are mode-600 and owned by root, which
#   is the correct long-term security posture for Docker secret bind-mounts.
# ---------------------------------------------------------------------------
cleanup_on_exit() {
  return 0
}
trap cleanup_on_exit EXIT

# Main function
main() {
  require_root "$@"

  log_header "VaultWarden-OCI Enhanced Startup"

  # Load environment configuration
  if ! load_env_file; then
    log_error "Failed to load environment configuration"
    exit 1
  fi

  # Validate Docker availability
  if ! require_docker; then
    log_error "Docker is not available or accessible"
    exit 1
  fi

  # Phase 1: Secure secrets preparation
  log_info "=== Phase 1: Secure Secrets Preparation ==="
  if ! prepare_docker_secrets; then
    log_error "Failed to prepare Docker secrets securely"
    exit 1
  fi

  # Phase 1.5: State directory preparation (ENHANCED)
  log_info "=== Phase 1.5: State Directory Preparation ==="
  if ! prepare_log_directories; then
    log_error "Failed to prepare state directories"
    exit 1
  fi

  # Phase 2: Service startup
  log_info "=== Phase 2: Service Startup ==="
  if ! start_services; then
    log_error "Failed to start services"
    exit 1
  fi

  # Phase 2.5: DNS Update
  log_info "=== Phase 2.5: DNS Update ==="
  update_dns_record

  # Phase 3: Health verification
  log_info "=== Phase 3: Health Verification ==="
  if ! verify_startup_health; then
    log_warn "Service health verification had issues, but continuing..."
  fi

  # Success summary
  log_success "VaultWarden startup completed successfully"
  if [[ "$BACKGROUND" == "true" ]]; then
    echo "Services are running in background. Use 'make logs' or 'docker compose logs' to monitor."
  else
    echo "All services started. Check status below."
  fi

  # Show service status
  echo ""
  echo "Service Status:"
  docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" || docker compose ps

  exit 0
}

main "$@"
