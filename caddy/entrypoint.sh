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
    echo "⚠️  WARNING: DEBUG_ENTRYPOINT enabled — credential names will be logged — DISABLE IN PRODUCTION" >&2
fi

# FIX [M-16]: Validate required environment variables BEFORE Caddyfile validation
# so we never print "validation passed" when DOMAIN_NAME is unset.
# C-07: Validate DOMAIN_NAME is set and looks like a valid FQDN (not localhost/bare IP)
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
echo "✓ DOMAIN_NAME validated: ${DOMAIN_NAME}"

# =============================================================================
# SECURITY: Load Cloudflare API Token
# =============================================================================
if [ ! -f /run/secrets/caddy_cloudflare_dns_token ]; then
    echo "ERROR: Cloudflare API token secret not found" >&2
    exit 1
fi

# FIX [M-17]: Separate assignment from export so the exit code of the command
# substitution is not masked by the 'export' builtin under POSIX set -eu.
# BUG-#5 FIX: Capture stderr to distinguish permission-denied from other read
# errors.  If the container user is non-root and the secret file is mode 0400
# root-owned, cat will fail with "Permission denied" — surface that clearly.
_caddy_secret_err=$(mktemp)
# Ensure temp file is removed on any exit path (success or failure).
trap 'rm -f "$_caddy_secret_err"' EXIT
if ! _token=$(cat /run/secrets/caddy_cloudflare_dns_token 2>"$_caddy_secret_err"); then
    _err=$(cat "$_caddy_secret_err" 2>/dev/null || true)
    rm -f "$_caddy_secret_err"
    case "$_err" in
        *"Permission denied"*)
            echo "ERROR: Permission denied reading Cloudflare token secret." >&2
            echo "       The Caddy container must run as root (user: root) to read Docker secrets." >&2
            echo "       Check the 'user:' directive in docker-compose.yml for the caddy service." >&2
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
# FIX: Tightened bcrypt pattern from \$2[aby]\$* to \$2[abxy]\$[0-9][0-9]\$*
# The previous pattern accepted single-digit cost factors and empty hash bodies.
# Valid bcrypt format: $2[abxy]$NN$<53 chars> where NN is a 2-digit cost (04-31).
case "$ADMIN_HASH_FULL" in
    admin\ \$2[abxy]\$[0-9][0-9]\$*) ;;
    *)
        echo "ERROR: Admin basic auth hash has invalid format" >&2
        echo "Expected: admin \$2a\$14\$... (SPACE-separated, 2-digit cost factor)" >&2
        exit 1
        ;;
esac

# FIX [CE-1]: Enforce OWASP minimum bcrypt cost of 10.
# The case pattern above accepts costs 04–99 (any two-digit number).
# This explicit check rejects costs below 10 with a clear error message.
_cost=$(printf '%s' "$ADMIN_HASH_FULL" | sed 's/.*\$2.\$\([0-9]*\)\$.*/\1/')
if [ "$_cost" -lt 10 ] 2>/dev/null; then
    echo "ERROR: bcrypt cost ${_cost} < minimum 10 (OWASP requirement)" >&2
    echo "Re-generate with: htpasswd -bnBC 14 admin <password>" >&2
    exit 1
fi
unset _cost

# FIX [CE-L2]: Replace awk pipelines with POSIX parameter expansion to avoid
# ash pipefail masking. ${var%% *} strips from the first space to end (username).
# ${var#* } strips from start to first space (hash body).
export ADMIN_USERNAME="${ADMIN_HASH_FULL%% *}"
export ADMIN_HASH="${ADMIN_HASH_FULL#* }"

# FIX [CE-M2]: Unset ADMIN_HASH_FULL after splitting to purge the full
# htpasswd-format string (username + bcrypt hash) from the container
# environment. Leaving it live for the entire Caddy process lifetime
# unnecessarily exposes it via /proc/1/environ to any process with
# sufficient privilege inside the container.
unset ADMIN_HASH_FULL

if [ "$DEBUG_ENTRYPOINT" = "true" ]; then
    # FIX: Include parsed ADMIN_USERNAME in debug output so operators can verify
    # the correct credential file was read. ADMIN_HASH is intentionally omitted.
    echo "✓ Admin basic auth loaded (username: ${ADMIN_USERNAME})"
fi

# Verify we got both parts
if [ -z "$ADMIN_USERNAME" ] || [ -z "$ADMIN_HASH" ]; then
    echo "ERROR: Failed to split admin credentials" >&2
    exit 1
fi

echo "✓ Admin credentials ready for Caddy"

# =============================================================================
# FIX [CF-1]: Set PUSH_CSP environment variable consumed by Caddyfile.
# When PUSH_ENABLED=true, include Bitwarden push endpoints in connect-src.
# Otherwise export an empty string to keep the CSP attack surface minimal.
# Leading space is intentional — it separates the value from the preceding
# wss://{$DOMAIN_NAME} token in the CSP directive.
# =============================================================================
PUSH_ENABLED=${PUSH_ENABLED:-false}
if [ "$PUSH_ENABLED" = "true" ]; then
    export PUSH_CSP=" https://push.bitwarden.com https://identity.bitwarden.com"
else
    export PUSH_CSP=""
fi

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
# C-08: log Caddy version at startup
echo " Caddy: $(caddy version 2>/dev/null || echo 'unknown')"
echo "==================================================================="

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
