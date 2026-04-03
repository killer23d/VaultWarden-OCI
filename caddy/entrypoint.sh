#!/bin/sh
# caddy/entrypoint.sh - Caddy Entrypoint Script - VaultWarden-OCI
# Purpose: Securely load Docker secrets into environment variables
# Security: Validates secrets before starting Caddy
# NOTE: This script runs inside the Alpine-based Caddy container which has
# busybox ash, not bash. POSIX sh only — do NOT add bash constructs or pipes
# that rely on pipefail (ash does not support set -o pipefail). Test all
# pipeline additions manually for failure propagation.
# WARNING [CE-L2]: ash has no pipefail support. Pipelines silently swallow
# errors from all stages except the last command. Avoid pipelines for any
# command whose failure must abort the script. Use intermediate variables,
# case statements, or explicit exit checks instead.
set -eu

echo "==================================================================="
echo " Caddy Entrypoint - Loading Secrets"
echo "==================================================================="

# FIX [CE-2]: Emit a loud production warning immediately when debug mode is
# enabled so operators are reminded to disable it before deploying.
DEBUG_ENTRYPOINT=${DEBUG_ENTRYPOINT:-false}
if [ "$DEBUG_ENTRYPOINT" = "true" ]; then
    echo "WARNING: DEBUG_ENTRYPOINT enabled — credential names will be logged — DISABLE IN PRODUCTION" >&2
fi

# =============================================================================
# BUG-5 FIX: Ensure log directory exists AND is writable BEFORE caddy run
#
# Two-step problem:
#
# Step 1 — mkdir:
#   The Caddyfile FileWriter opens /var/log/caddy/access.log at startup.
#   The path is a bind-mount from the host (PROJECT_STATE_DIR/logs/caddy).
#   If the host directory does not exist, Docker creates it as root:root 700.
#   mkdir -p here is a no-op when the bind-mount already exists, but creates
#   the path in the container overlay when no bind-mount is present.
#
# Step 2 — chmod 755 (the fix for the permission denied crash loop):
#   The Caddy container runs as root (required for Docker secrets access).
#   The init-permissions container is supposed to set /logs/caddy to 755, but
#   on OCI Compute it fails silently:
#
#     mkdir -p /logs/caddy   <- fails: /logs is root:root 700, OCI user-ns
#                               maps container uid 0 to unprivileged host uid
#     ... || true            <- failure swallowed, chmod 755 never runs
#     echo 'completed'       <- printed even though nothing was done
#
#   Docker then auto-creates the missing bind-mount dir as root:root 700.
#   The 'find /logs -type d -exec chmod 750' and 'chmod 755 /logs/caddy'
#   steps in the init command never ran because the directory did not exist
#   at the time those commands executed.
#
#   The Caddy container declares 'user: root' in the compose file. This maps
#   to real host UID 0 (not a remapped UID) because Docker Engine on OCI
#   Compute does not enable userns-remap at the daemon level by default.
#   Container root = host root. Root can always chmod a bind-mounted directory
#   regardless of its current ownership or mode.
#
#   chmod 755 here is idempotent, costs ~0ms, and makes Caddy self-healing:
#   it does not depend on the init container having succeeded.
# =============================================================================
mkdir -p /var/log/caddy
chmod 755 /var/log/caddy

# FIX [M-16]: Validate required environment variables BEFORE starting Caddy
# so we fail fast with a clear error, not a cryptic Caddy parse error.
# C-07: Validate DOMAIN_NAME is set and looks like a valid FQDN.
: "${DOMAIN_NAME:?ERROR: DOMAIN_NAME environment variable must be set}"
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
if [ ! -f /run/secrets/caddy_cloudflare_dns_token ]; then
    echo "ERROR: Cloudflare API token secret not found" >&2
    exit 1
fi

# FIX [M-17]: Separate assignment from export so the exit code of the command
# substitution is not masked by the 'export' builtin under POSIX set -eu.
_caddy_secret_err=$(mktemp)
trap 'rm -f "$_caddy_secret_err"' EXIT
if ! _token=$(cat /run/secrets/caddy_cloudflare_dns_token 2>"$_caddy_secret_err"); then
    _err=$(cat "$_caddy_secret_err" 2>/dev/null || true)
    rm -f "$_caddy_secret_err"
    case "$_err" in
        *"Permission denied"*)
            echo "ERROR: Permission denied reading Cloudflare token secret." >&2
            echo "       Caddy container must run as root (user: root) to read Docker secrets." >&2
            ;;
        *)
            echo "ERROR: Cannot read Cloudflare API token secret: $_err" >&2
            ;;
    esac
    exit 1
fi
rm -f "$_caddy_secret_err"
trap - EXIT

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
if [ ! -f /run/secrets/admin_basic_auth_hash ]; then
    echo "ERROR: Admin basic auth hash secret not found" >&2
    exit 1
fi

ADMIN_HASH_FULL=$(cat /run/secrets/admin_basic_auth_hash)

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
