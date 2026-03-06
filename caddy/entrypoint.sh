#!/bin/sh
# caddy/entrypoint.sh - Caddy Entrypoint Script - VaultWarden-OCI
# Purpose: Securely load Docker secrets into environment variables
# Security: Validates secrets before starting Caddy

set -eu

echo "==================================================================="
echo " Caddy Entrypoint - Loading Secrets"
echo "==================================================================="

# =============================================================================
# SECURITY: Load Cloudflare API Token
# =============================================================================
if [ ! -f /run/secrets/caddy_cloudflare_dns_token ]; then
    echo "ERROR: Cloudflare API token secret not found" >&2
    exit 1
fi

if ! CLOUDFLARE_API_TOKEN=$(cat /run/secrets/caddy_cloudflare_dns_token); then
    echo "ERROR: Failed to read Cloudflare API token secret" >&2
    exit 1
fi
export CLOUDFLARE_API_TOKEN

if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    echo "ERROR: Cloudflare API token is empty" >&2
    exit 1
fi

if ! echo "$CLOUDFLARE_API_TOKEN" | grep -qE '^[A-Za-z0-9_-]+$'; then
    echo "ERROR: Cloudflare API token contains invalid characters" >&2
    exit 1
fi

echo "✓ Cloudflare API token loaded successfully"

# =============================================================================
# SECURITY: Load Admin Basic Auth Hash
# =============================================================================
if [ ! -f /run/secrets/admin_basic_auth_hash ]; then
    echo "ERROR: Admin basic auth hash secret not found" >&2
    exit 1
fi

# Read the full hash (format: "admin $2a$14$...")
if ! ADMIN_HASH_FULL=$(cat /run/secrets/admin_basic_auth_hash); then
    echo "ERROR: Failed to read admin basic auth secret" >&2
    exit 1
fi

if [ -z "$ADMIN_HASH_FULL" ]; then
    echo "ERROR: Admin basic auth hash is empty" >&2
    exit 1
fi

# Validate format before splitting
if ! echo "$ADMIN_HASH_FULL" | grep -qE '^[^[:space:]]+ \$2[aby]\$'; then
    echo "ERROR: Admin basic auth hash has invalid format" >&2
    echo "Expected: admin \$2a\$14\$... (SPACE-separated)" >&2
    exit 1
fi

# Extract username (everything before first space)
export ADMIN_USERNAME=$(echo "$ADMIN_HASH_FULL" | awk '{print $1}')

# Extract hash (everything after first space)
export ADMIN_HASH=$(echo "$ADMIN_HASH_FULL" | awk '{$1=""; print substr($0,2)}')

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

if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1; then
    echo "ERROR: Caddyfile validation failed" >&2
    exit 1
fi

echo "✓ Caddyfile validation passed"

if ! echo "${DOMAIN_NAME:-}" | grep -qE '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; then
    echo "ERROR: DOMAIN_NAME appears invalid or unset: '${DOMAIN_NAME:-}'" >&2
    exit 1
fi

# =============================================================================
# START CADDY
# =============================================================================
echo "==================================================================="
echo " Starting Caddy Server"
echo " Domain: ${DOMAIN_NAME}"
echo "==================================================================="

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
