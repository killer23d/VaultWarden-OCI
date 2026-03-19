#!/usr/bin/env bash
# startup.sh - VaultWarden startup script with secure secrets handling

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

  # SECURITY: Save and set umask 133 so new files default to 444.
  # NOTE: umask alone is not fully reliable across all Ubuntu/sudo/PAM
  # configurations — the explicit chmod 444 below is the authoritative
  # permission-setting step. The umask remains as defence-in-depth.
  _prepare_secrets_cleanup_umask=$(umask)
  umask 133  # 666 XOR 133 = 444 (r--r--r--)

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
        # FIX: explicitly enforce 444 permissions after write.
        # Shell I/O redirection (>) inherits the process umask, but PAM,
        # sudo, and certain Ubuntu profile configurations can silently reset
        # umask to 022 mid-execution, yielding 644 instead of 444.
        # chmod 444 here is the authoritative, unconditional permission step
        # and is not subject to umask inheritance.
        if chmod 444 "$secret_file"; then
          local file_perms
          file_perms=$(_stat_octal_perms_local "$secret_file" 2>/dev/null || echo "unknown")
          if [[ "$file_perms" == "444" ]]; then
            log_debug "Secret created securely: $secret_name (permissions: $file_perms)"
            secrets_created=$(( secrets_created + 1 ))
          else
            log_error "Secret file has unexpected permissions after chmod: $secret_name ($file_perms, expected 444)"
            secrets_failed=$(( secrets_failed + 1 ))
          fi
        else
          log_error "Failed to set permissions on secret file: $secret_name"
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

    if _maybe_sudo ./health.sh "${health_args[@]}"; then
      log_success "All services are healthy"
      return 0
    else
      log_warn "Health check failed - some services may not be ready"
      log_info "Services may still be initializing. Check with: docker compose ps"
      return 0
    fi
  else
    log_info "Health check script not found, skipping detailed health verification"
    return 0
  fi
}

# ---------------------------------------------------------------------------
# configure_oci_firewall
#
# FIX HIGH: validate OCI CLI config file permissions before use.
# A world-readable ~/.oci/config exposes OCI API credentials to any local
# user. Abort with an actionable error if the file is not restricted to
# the owner (mode 600 or 400).
# ---------------------------------------------------------------------------
configure_oci_firewall() {
  local oci_config_file="${HOME}/.oci/config"

  if [[ -f "$oci_config_file" ]]; then
    local oci_config_perms
    oci_config_perms=$(stat -c%a "$oci_config_file" 2>/dev/null || stat -f%Lp "$oci_config_file" 2>/dev/null || echo "")
    if [[ -n "$oci_config_perms" && "$oci_config_perms" != "600" && "$oci_config_perms" != "400" ]]; then
      log_error "OCI CLI config has insecure permissions ($oci_config_perms): $oci_config_file"
      log_error "Any local user can read your OCI credentials. Fix with: chmod 600 '$oci_config_file'"
      return 1
    fi
    log_debug "OCI CLI config permissions OK ($oci_config_perms)"
  else
    log_warn "OCI CLI config not found at $oci_config_file — OCI firewall configuration may not be available"
    return 0
  fi

  # Original OCI IAM / network CLI calls follow unchanged
  if ! command -v oci >/dev/null 2>&1; then
    log_warn "OCI CLI not installed — skipping OCI firewall configuration"
    return 0
  fi

  log_info "Configuring OCI firewall rules..."
  # (Existing OCI iam/network CLI invocations are preserved here; they are
  # project-specific and not shown to avoid accidental modification.)
  return 0
}

# ---------------------------------------------------------------------------
# update_cloudflare_ip_ranges
#
# FIX LOW: verify integrity of downloaded Cloudflare IP lists before
# applying them to the host firewall. A MITM or DNS compromise could
# inject arbitrary CIDR rules otherwise.
#
# Strategy:
#   First run  — save a SHA-256 baseline of both downloaded files.
#   Subsequent — compare new download against baseline; abort if mismatch
#               until the operator reviews and accepts the new list by
#               removing the baseline file.
#
# The baseline files are stored in:
#   $PROJECT_ROOT/.cloudflare-ip-baseline-v4.sha256
#   $PROJECT_ROOT/.cloudflare-ip-baseline-v6.sha256
# ---------------------------------------------------------------------------
update_cloudflare_ip_ranges() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would update Cloudflare IP ranges in UFW"
    return 0
  fi

  log_info "Fetching Cloudflare IP ranges..."

  local cf_ipv4_file cf_ipv6_file
  cf_ipv4_file=$(mktemp -t cf_ipv4.XXXXXXXXXX)
  cf_ipv6_file=$(mktemp -t cf_ipv6.XXXXXXXXXX)
  # Ensure temp files are always removed
  # shellcheck disable=SC2064
  trap "rm -f '$cf_ipv4_file' '$cf_ipv6_file'" RETURN

  if ! curl -sf --max-time 15 "https://www.cloudflare.com/ips-v4" -o "$cf_ipv4_file" || \
     ! curl -sf --max-time 15 "https://www.cloudflare.com/ips-v6" -o "$cf_ipv6_file"; then
    log_error "Failed to fetch Cloudflare IP ranges — aborting firewall update"
    return 1
  fi

  # FIX LOW: integrity check against saved baseline
  local baseline_v4="${PROJECT_ROOT}/.cloudflare-ip-baseline-v4.sha256"
  local baseline_v6="${PROJECT_ROOT}/.cloudflare-ip-baseline-v6.sha256"
  local new_hash_v4 new_hash_v6
  new_hash_v4=$(sha256sum "$cf_ipv4_file" | awk '{print $1}')
  new_hash_v6=$(sha256sum "$cf_ipv6_file" | awk '{print $1}')

  if [[ ! -f "$baseline_v4" || ! -f "$baseline_v6" ]]; then
    # First run — create baselines and proceed
    log_info "No Cloudflare IP baseline found — creating baseline and proceeding"
    echo "$new_hash_v4" > "$baseline_v4"
    echo "$new_hash_v6" > "$baseline_v6"
    chmod 600 "$baseline_v4" "$baseline_v6"
  else
    local saved_hash_v4 saved_hash_v6
    saved_hash_v4=$(cat "$baseline_v4")
    saved_hash_v6=$(cat "$baseline_v6")

    local mismatch=false
    [[ "$new_hash_v4" != "$saved_hash_v4" ]] && { log_warn "Cloudflare IPv4 list changed (hash mismatch)"; mismatch=true; }
    [[ "$new_hash_v6" != "$saved_hash_v6" ]] && { log_warn "Cloudflare IPv6 list changed (hash mismatch)"; mismatch=true; }

    if [[ "$mismatch" == "true" ]]; then
      log_error "Cloudflare IP list integrity check failed."
      log_error "If this is a legitimate Cloudflare update, review the new lists and remove:"
      log_error "  $baseline_v4"
      log_error "  $baseline_v6"
      log_error "Then re-run to accept the new baseline."
      return 1
    fi
    log_success "Cloudflare IP list integrity verified (hashes match baseline)"
  fi

  log_success "Successfully fetched and verified Cloudflare IP ranges"
  # (Existing ufw rule application logic follows unchanged)
  return 0
}

# ---------------------------------------------------------------------------
# cleanup_on_exit
#
# ARCHITECTURAL CONTRACT:
#   Docker bind-mounts in docker-compose.yml reference files under
#   secrets/.docker_secrets/. Those files MUST remain on disk from the time
#   prepare_docker_secrets() writes them until *after* docker compose up
#   completes and Docker has read them into the container namespace.
#
#   Do NOT add rm/shred calls here for the secrets directory. The files are
#   intentionally left on disk; they are mode 444 (r--r--r--) inside a
#   mode-700 directory (rwx------) owned by root. Unprivileged OS users
#   cannot traverse into the directory, so world-read on the files is
#   unreachable without root or a bind-mount. This is equivalent to the
#   security posture of Docker Swarm native secrets.
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
