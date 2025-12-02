#!/usr/bin/env bash
# caddy/entrypoint.sh - Caddy Entrypoint Script - VaultWarden-OCI
# Purpose: Securely load Docker secrets into environment variables
# Security: Validates secrets before starting Caddy

set -euo pipefail

# =============================================================================
# SECURITY: Load Cloudflare API Token
# =============================================================================
if [ ! -f /run/secrets/caddy_cloudflare_dns_token ]; then
    echo "ERROR: Cloudflare API token secret not found at /run/secrets/caddy_cloudflare_dns_token" >&2
    exit 1
fi

export CLOUDFLARE_API_TOKEN=$(cat /run/secrets/caddy_cloudflare_dns_token)

# Validate token format (basic check)
if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    echo "ERROR: Cloudflare API token is empty" >&2
    exit 1
fi

# Token should be alphanumeric with underscores/hyphens (basic validation)
if ! echo "$CLOUDFLARE_API_TOKEN" | grep -qE '^[A-Za-z0-9_-]+$'; then
    echo "ERROR: Cloudflare API token contains invalid characters" >&2
    exit 1
fi

echo "✓ Cloudflare API token loaded successfully"

# =============================================================================
# SECURITY: Load Admin Basic Auth Hash
# =============================================================================
if [ ! -f /run/secrets/admin_basic_auth_hash ]; then
    echo "ERROR: Admin basic auth hash secret not found at /run/secrets/admin_basic_auth_hash" >&2
    exit 1
fi

export ADMIN_BASIC_AUTH_HASH=$(cat /run/secrets/admin_basic_auth_hash)

# Validate hash format (should be "admin:$2a$14$...")
if [ -z "$ADMIN_BASIC_AUTH_HASH" ]; then
    echo "ERROR: Admin basic auth hash is empty" >&2
    exit 1
fi

# Validate htpasswd format: username:$2a$ or username:$2y$
if ! echo "$ADMIN_BASIC_AUTH_HASH" | grep -qE '^[a-zA-Z0-9_-]+:\$2[aby]\$'; then
    echo "ERROR: Admin basic auth hash is not in valid htpasswd format (expected: username:\$2a\$...)" >&2
    exit 1
fi

echo "✓ Admin basic auth hash loaded successfully"

# =============================================================================
# VALIDATION: Caddyfile Syntax Check
# =============================================================================
echo "Validating Caddyfile syntax..."

if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1; then
    echo "ERROR: Caddyfile validation failed" >&2
    echo "Please check your Caddyfile for syntax errors" >&2
    exit 1
fi

echo "✓ Caddyfile validation passed"

# =============================================================================
# START CADDY
# =============================================================================
echo "Starting Caddy server..."
echo "Domain: ${DOMAIN_NAME}"
echo "Config: /etc/caddy/Caddyfile"

# exec replaces this shell with Caddy process (PID 1 for proper signal handling)
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
