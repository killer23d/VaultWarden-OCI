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
    # Set ownership to PUID:PGID from environment
    local puid="${PUID:-1001}"
    local pgid="${PGID:-1001}"
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

  # Cleanup function to restore umask
  cleanup_umask() {
    umask "$old_umask"
  }
  trap cleanup_umask EXIT

  # Create secrets directory with proper permissions
  if ! ensure_dir "$secrets_dir" 700; then
    log_error "Failed to create secrets directory"
    cleanup_umask
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
  local decrypted_cache
  decrypted_cache=$(mktemp)
  chmod 600 "$decrypted_cache"

  # Register for cleanup — will be removed on EXIT regardless of success/failure.
  local _orig_trap
  _orig_trap=$(trap -p EXIT)
  trap "rm -f '$decrypted_cache'; cleanup_umask" EXIT

  if ! sops --decrypt "$sops_file" > "$decrypted_cache" 2>/dev/null; then
    log_error "Failed to decrypt secrets file"
    rm -f "$decrypted_cache"
    cleanup_umask
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

    # Extract from the already-decrypted cache (no repeated sops calls)
    secret_value=$(grep "^${secret_name}:" "$decrypted_cache" | head -n1 | cut -d: -f2- | sed 's/^ *//' || echo "")

    if [[ -n "$secret_value" ]] && [[ "$secret_value" != "CHANGE_ME"* ]] && \
       [[ "$secret_value" != "null" ]] && [[ "$secret_value" != "PLACEHOLDER"* ]]; then
      if printf '%s' "$secret_value" > "$secret_file"; then
        local file_perms
        file_perms=$(stat -c "%a" "$secret_file" 2>/dev/null || echo "unknown")
        if [[ "$file_perms" == "600" ]]; then
          log_debug "Secret created securely: $secret_name (permissions: $file_perms)"
          ((secrets_created++))
        else
          log_error "Secret file created with incorrect permissions: $secret_name ($file_perms)"
          ((secrets_failed++))
        fi
      else
        log_error "Failed to create secret file: $secret_name"
        ((secrets_failed++))
      fi
    else
      log_debug "Skipping empty/placeholder secret: $secret_name"
    fi
  done

  # Securely wipe the decrypted cache
  if command -v shred >/dev/null 2>&1; then
    shred -fuz "$decrypted_cache" 2>/dev/null || rm -f "$decrypted_cache"
  else
    rm -f "$decrypted_cache"
  fi

  # Restore cleanup trap and umask
  cleanup_umask
  trap - EXIT

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
  sleep 10

  if [[ -f "./health.sh" ]]; then
    # Prefer sudo here because health.sh may need root to decrypt/check backups
    if _maybe_sudo ./health.sh; then
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

# Cleanup function
cleanup_on_exit() {
  # Secrets files need to persist for Docker to mount them
  :
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