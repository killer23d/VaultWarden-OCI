#!/bin/sh
# caddy/entrypoint.sh - Caddy Entrypoint Script - VaultWarden-OCI
# Purpose: Securely load Docker secrets into environment variables
# Security: Validates secrets before starting Caddy
# NOTE: This script runs inside the Alpine-based Caddy container which has
# busybox ash, not bash. POSIX sh only — do NOT add bash constructs or pipes
# that rely on pipefail (ash does not support set -o pipefail). Test all
# pipeline additions manually for failure propagation.
set -eu

echo "==================================================================="
echo " Caddy Entrypoint - Loading Secrets"
echo "==================================================================="

DEBUG_ENTRYPOINT=${DEBUG_ENTRYPOINT:-false}
if [ "$DEBUG_ENTRYPOINT" = "true" ]; then
    echo "WARNING: DEBUG_ENTRYPOINT enabled — credential names will be logged — DISABLE IN PRODUCTION" >&2
fi

# =============================================================================
# read_secret <secret_path>
#
# Reads the content of a Docker secret file and writes it to stdout.
# Exits 1 with an actionable message on any failure.
# =============================================================================
read_secret() {
    _rs_path="$1"

    if [ ! -f "$_rs_path" ]; then
        echo "ERROR: Secret not found: $_rs_path" >&2
        echo "       Ensure the Docker secret is declared in compose.yaml and the service is restarted." >&2
        exit 1
    fi

    _rs_out=$(cat "$_rs_path" 2>&1) || {
        case "$_rs_out" in
            *"Permission denied"*)
                echo "ERROR: Permission denied reading secret: $_rs_path" >&2
                echo "       The Caddy container must run as root (user: root) to read Docker secrets." >&2
                ;;
            *)
                echo "ERROR: Cannot read secret $_rs_path: $_rs_out" >&2
                ;;
        esac
        exit 1
    }

    printf '%s' "$_rs_out"
    unset _rs_path _rs_out
}

# =============================================================================
# BUG-caddy-perms-3 FIX: Ensure log directory AND log files exist and are
# writable by this process before caddy run is called.
#
# WHY TWO STEPS:
#
#   Step 1 — directory: mkdir -p /var/log/caddy
#     Creates the bind-mount target inside the container overlay if the host
#     directory was not pre-created. No-op if it already exists.
#
#   Step 2 — files: touch /var/log/caddy/access.log + security.log
#     Caddy's FileWriter calls open() with O_CREAT | O_WRONLY on startup.
#     On OCI Compute with userns-remap, container UID 0 maps to an
#     unprivileged host UID. The bind-mounted /var/log/caddy is owned by
#     PUID:PGID. Mode 755 gives 'other' r-x but NOT write. O_CREAT on a
#     non-existent file inside a directory where 'other' has no write bit
#     fails with EACCES — the exact error observed in production.
#
#     If touch succeeds, caddy's open() on an already-existing file only
#     needs write permission on the FILE itself (which caddy owns after
#     creating it), not on the directory. Files created by container root
#     are owned by the host root (mapped UID) and get mode 0644 by default.
#
#     If touch fails, the only fix is to run on the HOST (as real root):
#       sudo touch /var/lib/vaultwarden/logs/caddy/access.log \
#                  /var/lib/vaultwarden/logs/caddy/security.log
#       sudo chown root:root /var/lib/vaultwarden/logs/caddy/access.log \
#                            /var/lib/vaultwarden/logs/caddy/security.log
#       sudo chmod 644 /var/lib/vaultwarden/logs/caddy/access.log \
#                      /var/lib/vaultwarden/logs/caddy/security.log
#       sudo chmod 755 /var/lib/vaultwarden/logs/caddy
#     setup.sh does this automatically for new installs.
#
# WHY NOT chmod INSIDE THE CONTAINER:
#   cap_drop: ALL + cap_add: [NET_BIND_SERVICE] only.
#   FOWNER and DAC_OVERRIDE are absent. chmod on a directory owned by
#   another UID fails EPERM unconditionally, regardless of container root.
# =============================================================================
mkdir -p /var/log/caddy

# Check directory is reachable (can at minimum list it)
if ! test -d /var/log/caddy; then
    echo "ERROR: /var/log/caddy does not exist and could not be created." >&2
    exit 1
fi

# Attempt to pre-create log files so caddy run's open(O_CREAT) doesn't need
# directory write permission — only file write permission (which it will have
# as owner of the file it just created or that root created here).
_log_touch_failed=false
touch /var/log/caddy/access.log  2>/dev/null || _log_touch_failed=true
touch /var/log/caddy/security.log 2>/dev/null || _log_touch_failed=true

if [ "$_log_touch_failed" = "true" ]; then
    echo "" >&2
    echo "ERROR: Cannot create log files in /var/log/caddy." >&2
    echo "" >&2
    echo "This is caused by OCI Compute userns-remap: container UID 0 maps to an" >&2
    echo "unprivileged host UID that does NOT own /var/lib/vaultwarden/logs/caddy." >&2
    echo "" >&2
    echo "ONE-TIME HOST FIX (run on the server as ubuntu/root):" >&2
    echo "" >&2
    echo "  LOG_DIR=\${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/logs/caddy" >&2
    echo "  sudo mkdir -p \"\$LOG_DIR\"" >&2
    echo "  sudo touch \"\$LOG_DIR/access.log\" \"\$LOG_DIR/security.log\"" >&2
    echo "  sudo chown root:root \"\$LOG_DIR/access.log\" \"\$LOG_DIR/security.log\"" >&2
    echo "  sudo chmod 644 \"\$LOG_DIR/access.log\" \"\$LOG_DIR/security.log\"" >&2
    echo "  sudo chmod 755 \"\$LOG_DIR\"" >&2
    echo "  cd ~/VaultWarden-OCI" >&2
    echo "  docker compose up -d --force-recreate caddy" >&2
    echo "" >&2
    echo "setup.sh performs this automatically for new installs." >&2
    exit 1
fi

# Final writability probe: verify caddy will actually be able to write to the
# log files before handing off to 'caddy run'.
if ! test -w /var/log/caddy/access.log; then
    echo "" >&2
    echo "ERROR: /var/log/caddy/access.log exists but is NOT writable by this container." >&2
    echo "" >&2
    echo "The file is likely owned by PUID:PGID from a previous run." >&2
    echo "Run the following on the host to fix ownership:" >&2
    echo "" >&2
    echo "  LOG_DIR=\${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/logs/caddy" >&2
    echo "  sudo chown root:root \"\$LOG_DIR/access.log\" \"\$LOG_DIR/security.log\"" >&2
    echo "  sudo chmod 644 \"\$LOG_DIR/access.log\" \"\$LOG_DIR/security.log\"" >&2
    echo "  sudo chmod 755 \"\$LOG_DIR\"" >&2
    echo "  cd ~/VaultWarden-OCI" >&2
    echo "  docker compose up -d --force-recreate caddy" >&2
    exit 1
fi

# Derive DOMAIN_NAME from DOMAIN when not explicitly set — single source of truth.
# Strips the https:// (or http://) prefix so Caddy receives a bare hostname.
# If DOMAIN_NAME is already present in the environment it is left untouched.
: "${DOMAIN_NAME:=${DOMAIN#https://}}"
: "${DOMAIN_NAME:=${DOMAIN#http://}}"

# FIX [M-16]: Validate required environment variables BEFORE starting Caddy
# so we fail fast with a clear error, not a cryptic Caddy parse error.
# C-07: Validate DOMAIN_NAME is set and looks like a valid FQDN.
: "${DOMAIN_NAME:?ERROR: DOMAIN_NAME could not be derived — ensure DOMAIN=https://your.host}"
case "$DOMAIN_NAME" in
    localhost|127.0.0.1|0.0.0.0)
        echo "ERROR: DOMAIN_NAME='$DOMAIN_NAME' is not a valid production domain" >&2
        exit 1
        ;;
    *[!a-zA-Z0-9._-]*)
        echo "ERROR: DOMAIN_NAME='$DOMAIN_NAME' contains invalid characters (allowed: a-z A-Z 0-9 . _ -)" >&2
        exit 1
        ;;
esac
echo "DOMAIN_NAME validated: ${DOMAIN_NAME}"

# =============================================================================
# SECURITY: Load Cloudflare API Token
# =============================================================================
read_secret /run/secrets/caddy_cloudflare_dns_token _token

if [ -z "$_token" ]; then
    echo "ERROR: Cloudflare API token is empty" >&2
    exit 1
fi

# Validate token charset: Cloudflare scoped tokens are Base64url with dots
# (<prefix>.<body>.<signature>). Allow A-Z a-z 0-9 _ . = + -
case "$_token" in
    *[!A-Za-z0-9_.=+-]*)
        echo "ERROR: Cloudflare API token contains invalid characters" >&2
        echo "       Allowed: A-Z a-z 0-9 _ . = + -" >&2
        echo "       Ensure the secret file has no surrounding whitespace, quotes, or braces." >&2
        exit 1
        ;;
esac

export CLOUDFLARE_API_TOKEN="$_token"
unset _token

echo "Cloudflare API token loaded successfully"

# =============================================================================
# SECURITY: Load Admin Basic Auth Hash
# =============================================================================
read_secret /run/secrets/admin_basic_auth_hash ADMIN_HASH_FULL

if [ -z "$ADMIN_HASH_FULL" ]; then
    echo "ERROR: Admin basic auth hash is empty" >&2
    exit 1
fi

# Validate format: must be "<username> $2[abxy]$NN$<hash>"
case "$ADMIN_HASH_FULL" in
    *\ \$2[abxy]\$[0-9][0-9]\$*) ;;
    *)
        echo "ERROR: Admin basic auth hash has invalid format" >&2
        echo "Expected: <username> \$2a\$14\$... (space-separated, 2-digit cost)" >&2
        exit 1
        ;;
esac

# FIX [CE-1]: Enforce OWASP minimum bcrypt cost of 10.
_cost=$(printf '%s' "$ADMIN_HASH_FULL" | sed 's/.*\$2.\$\([0-9]*\)\$.*/\1/')
if [ "$_cost" -lt 10 ] 2>/dev/null; then
    echo "ERROR: bcrypt cost ${_cost} < minimum 10 (OWASP requirement)" >&2
    echo "Re-generate with: htpasswd -bnBC 14 admin <password>" >&2
    exit 1
fi
unset _cost

export ADMIN_USERNAME="${ADMIN_HASH_FULL%% *}"
export ADMIN_HASH="${ADMIN_HASH_FULL#* }"
unset ADMIN_HASH_FULL

if [ "$DEBUG_ENTRYPOINT" = "true" ]; then
    echo "Admin basic auth loaded (username: ${ADMIN_USERNAME})"
fi

if [ -z "$ADMIN_USERNAME" ] || [ -z "$ADMIN_HASH" ]; then
    echo "ERROR: Failed to split admin credentials" >&2
    exit 1
fi

echo "Admin credentials ready for Caddy"

# =============================================================================
# FIX [CF-1]: Set PUSH_CSP environment variable consumed by Caddyfile.
# =============================================================================
PUSH_ENABLED=${PUSH_ENABLED:-false}
if [ "$PUSH_ENABLED" = "true" ]; then
    export PUSH_CSP=" https://push.bitwarden.com https://identity.bitwarden.com"
else
    export PUSH_CSP=""
fi

# =============================================================================
# BUG-2 FIX: 'caddy validate' removed
#
# 'caddy validate' fully provisions all Caddy modules at validation time,
# including FileWriter log writers. Provisioning calls open() on every log
# file path listed in the Caddyfile. This means validate fails with:
#
#   open /var/log/caddy/access.log: permission denied
#
# ...if /var/log/caddy is owned by PUID:PGID (set by the init container)
# and the validate call races ahead of the mkdir -p guard above, or if the
# Docker bind-mount UID mapping prevents root inside the container from
# writing to the host directory.
#
# Caddy already validates its configuration at 'caddy run' startup before
# serving any requests — a separate validate call is therefore redundant.
# Removing it eliminates the permission-denied crash loop with zero loss
# of config safety: a bad Caddyfile still causes caddy run to exit 1.
# =============================================================================

# =============================================================================
# START CADDY
# =============================================================================
echo "==================================================================="
echo " Starting Caddy Server"
echo " Domain: ${DOMAIN_NAME}"
echo " Caddy:  $(caddy version 2>/dev/null || echo 'unknown')"
echo "==================================================================="

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
