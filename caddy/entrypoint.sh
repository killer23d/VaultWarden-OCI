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

export CLOUDFLARE_API_TOKEN=$(cat /run/secrets/caddy_cloudflare_dns_token)

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

export ADMIN_BASIC_AUTH_HASH=$(cat /run/secrets/admin_basic_auth_hash)

if [ -z "$ADMIN_BASIC_AUTH_HASH" ]; then
    echo "ERROR: Admin basic auth hash is empty" >&2
    exit 1
fi

# ✅ CRITICAL FIX: Validate SPACE-separated format (not colon)
# Expected format: "admin $2a$14$..."
if ! echo "$ADMIN_BASIC_AUTH_HASH" | grep -qE '^admin \$2[aby]\$'; then
    echo "ERROR: Admin basic auth hash has invalid format" >&2
    echo "Expected: admin \$2a\$14\$... (SPACE-separated)" >&2
    echo "Got: $ADMIN_BASIC_AUTH_HASH" >&2
    exit 1
fi

echo "✓ Admin basic auth hash loaded (format: admin \$2a\$...)"

# =============================================================================
# VALIDATION: Caddyfile Syntax Check
# =============================================================================
echo "Validating Caddyfile syntax..."

if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1; then
    echo "ERROR: Caddyfile validation failed" >&2
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

# SECURITY NOTE: Environment variables used because caddy-cloudflare
# plugin does not support file-based API tokens (plugin limitation).
# Secrets are:
# - NOT in docker-compose.yml (avoiding `docker inspect` exposure)
# - Visible only within container's process environment
# - Protected by container isolation and no-new-privileges

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
