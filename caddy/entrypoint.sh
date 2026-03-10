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

# FIX [M-16]: Validate required environment variables BEFORE Caddyfile validation
# so we never print "validation passed" when DOMAIN_NAME is unset.
: "${DOMAIN_NAME:?ERROR: DOMAIN_NAME environment variable must be set}"

# =============================================================================
# SECURITY: Load Cloudflare API Token
# =============================================================================
if [ ! -f /run/secrets/caddy_cloudflare_dns_token ]; then
    echo "ERROR: Cloudflare API token secret not found" >&2
    exit 1
fi

# FIX [M-17]: Separate assignment from export so the exit code of the command
# substitution is not masked by the 'export' builtin under POSIX set -eu.
_token=$(cat /run/secrets/caddy_cloudflare_dns_token) || { echo "ERROR: cannot read CF token" >&2; exit 1; }

if [ -z "$_token" ]; then
    echo "ERROR: Cloudflare API token is empty" >&2
    exit 1
fi

# FIX [CE-M1]: Validate token format BEFORE exporting into the environment.
# Exporting first and then validating leaves an invalid token live in
# /proc/1/environ for the window between export and exit.
# FIX [CE-L2]: Use a case statement instead of echo|grep to avoid the
# pipeline exit-code masking problem under ash (no pipefail support).
case "$_token" in
    *[!A-Za-z0-9_-]*)
        echo "ERROR: Cloudflare API token contains invalid characters" >&2
        exit 1
        ;;
esac

export CLOUDFLARE_API_TOKEN="$_token"
unset _token

echo "✓ Cloudflare API token loaded successfully"

# =============================================================================
# SECURITY: Load Admin Basic Auth Hash
# =============================================================================
if [ ! -f /run/secrets/admin_basic_auth_hash ]; then
    echo "ERROR: Admin basic auth hash secret not found" >&2
    exit 1
fi

# Read the full hash (format: "admin $2a$14$...")
ADMIN_HASH_FULL=$(cat /run/secrets/admin_basic_auth_hash)

if [ -z "$ADMIN_HASH_FULL" ]; then
    echo "ERROR: Admin basic auth hash is empty" >&2
    exit 1
fi

# Validate format before splitting
# FIX [CE-L2]: case statement avoids echo|grep pipeline masking under ash.
case "$ADMIN_HASH_FULL" in
    admin\ \$2[aby]\$*) ;;
    *)
        echo "ERROR: Admin basic auth hash has invalid format" >&2
        echo "Expected: admin \$2a\$14\$... (SPACE-separated)" >&2
        exit 1
        ;;
esac

# FIX [M-17]: Separate assignment from export for each variable
_admin_username=$(echo "$ADMIN_HASH_FULL" | awk '{print $1}') || { echo "ERROR: cannot parse admin username" >&2; exit 1; }
export ADMIN_USERNAME="$_admin_username"
unset _admin_username

_admin_hash=$(echo "$ADMIN_HASH_FULL" | awk '{$1=""; print substr($0,2)}') || { echo "ERROR: cannot parse admin hash" >&2; exit 1; }
export ADMIN_HASH="$_admin_hash"
unset _admin_hash

# FIX [CE-M2]: Unset ADMIN_HASH_FULL after splitting to purge the full
# htpasswd-format string (username + bcrypt hash) from the container
# environment. Leaving it live for the entire Caddy process lifetime
# unnecessarily exposes it via /proc/1/environ to any process with
# sufficient privilege inside the container.
unset ADMIN_HASH_FULL

DEBUG_ENTRYPOINT=${DEBUG_ENTRYPOINT:-false}
if [ "$DEBUG_ENTRYPOINT" = "true" ]; then
    echo "✓ Admin basic auth loaded"
fi

# Verify we got both parts
if [ -z "$ADMIN_USERNAME" ] || [ -z "$ADMIN_HASH" ]; then
    echo "ERROR: Failed to split admin credentials" >&2
    exit 1
fi

echo "✓ Admin credentials ready for Caddy"

# =============================================================================
# VALIDATION: Caddyfile Syntax Check
# =============================================================================
echo "Validating Caddyfile syntax..."

# FIX [CE-L1]: Suppress all caddy validate output (including any env-var
# expansions that could reflect ADMIN_HASH into Docker logs on failure).
# Print only a fixed, non-sensitive error message when validation fails.
if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null; then
    echo "ERROR: Caddyfile validation failed — check config syntax" >&2
    exit 1
fi

echo "✓ Caddyfile validation passed"

# =============================================================================
# START CADDY
# =============================================================================
echo "==================================================================="
echo " Starting Caddy Server"
echo " Domain: ${DOMAIN_NAME}"
echo "==================================================================="

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
