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
#
# USAGE — always capture via command substitution:
#   value=$(read_secret /run/secrets/my_secret)
#
# DO NOT pass a variable name as a second argument; read_secret is a
# stdout-returning function (POSIX sh has no namerefs). The second-arg
# pattern silently leaves the variable unset and triggers an unbound-
# variable abort under `set -eu`.
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
# log_warn <message>
#
# Writes a WARNING line to stderr with a consistent prefix so operators can
# grep journalctl / docker logs for degraded-mode events.
# =============================================================================
log_warn() {
    echo "[WARN] caddy-entrypoint: $*" >&2
}

# =============================================================================
# Ensure log directory AND log files exist and are
# writable by this process before caddy run is called.
#
# DEGRADED MODE (non-writable logs):
#   Instead of exit 1 (which causes an infinite Docker restart loop), Caddy
#   is started with stdout-only logging when the log files cannot be written.
#   CADDY_DEGRADED=true is exported so maintenance.sh --health can surface the condition.
#   The operator can fix file ownership on the host and then restart Caddy.
# =============================================================================
mkdir -p /var/log/caddy

# Check directory is reachable (can at minimum list it)
if ! test -d /var/log/caddy; then
    echo "ERROR: /var/log/caddy does not exist and could not be created." >&2
    exit 1
fi

# Attempt to pre-create log files so caddy run's open(O_CREAT) doesn't need
# directory write permission — only file write permission.
export CADDY_DEGRADED=false
_log_touch_failed=false
touch /var/log/caddy/access.log  2>/dev/null || _log_touch_failed=true
touch /var/log/caddy/security.log 2>/dev/null || _log_touch_failed=true

if [ "$_log_touch_failed" = "true" ]; then
    log_warn "Cannot create log files in /var/log/caddy — falling back to stdout-only logging."
    log_warn ""
    log_warn "Root cause: OCI Compute userns-remap maps container UID 0 to an unprivileged host"
    log_warn "UID that does NOT own /var/lib/vaultwarden/logs/caddy."
    log_warn ""
    log_warn "ONE-TIME HOST FIX (run on the server as ubuntu/root):"
    log_warn "  # Find your caddy log dir — it is the host path bound to /var/log/caddy"
    log_warn "  # in docker-compose.yml (PROJECT_STATE_DIR/logs/caddy)"
    log_warn "  LOG_DIR=\"\$(docker inspect --format '{{ range .Mounts }}{{ if eq .Destination \"/var/log/caddy\" }}{{ .Source }}{{ end }}{{ end }}' vaultwarden_caddy 2>/dev/null || echo '<check docker-compose volumes for /var/log/caddy>')\""
    log_warn "  sudo mkdir -p \"\$LOG_DIR\""
    log_warn "  sudo touch \"\$LOG_DIR/access.log\" \"\$LOG_DIR/security.log\""
    log_warn "  sudo chown root:root \"\$LOG_DIR/access.log\" \"\$LOG_DIR/security.log\""
    log_warn "  sudo chmod 644 \"\$LOG_DIR/access.log\" \"\$LOG_DIR/security.log\""
    log_warn "  sudo chmod 755 \"\$LOG_DIR\""
    log_warn "  cd ~/VaultWarden-OCI && docker compose restart caddy"
    log_warn ""
    log_warn "setup.sh performs this automatically for new installs."
    log_warn "Caddy will start with stdout logging only — set CADDY_DEGRADED in health check."
    export CADDY_DEGRADED=true
fi

# Final writability probe (only if touch succeeded)
if [ "$CADDY_DEGRADED" = "false" ] && ! test -w /var/log/caddy/access.log; then
    log_warn "/var/log/caddy/access.log exists but is NOT writable — falling back to stdout-only logging."
    log_warn ""
    log_warn "The file is likely owned by PUID:PGID from a previous run."
    log_warn "Run the following on the host to fix ownership:"
    log_warn "  LOG_DIR=\"\$(docker inspect --format '{{ range .Mounts }}{{ if eq .Destination \"/var/log/caddy\" }}{{ .Source }}{{ end }}{{ end }}' vaultwarden_caddy 2>/dev/null || echo '<check docker-compose volumes for /var/log/caddy>')\""
    log_warn "  sudo chown root:root \"\$LOG_DIR/access.log\" \"\$LOG_DIR/security.log\""
    log_warn "  sudo chmod 644 \"\$LOG_DIR/access.log\" \"\$LOG_DIR/security.log\""
    log_warn "  sudo chmod 755 \"\$LOG_DIR\""
    log_warn "  cd ~/VaultWarden-OCI && docker compose restart caddy"
    export CADDY_DEGRADED=true
fi

if [ "$CADDY_DEGRADED" = "true" ]; then
    log_warn "DEGRADED MODE: file logging disabled. Proxy and TLS will still function."
    log_warn "Check container health: docker inspect --format='{{.State.Health.Status}}' vaultwarden_caddy"
fi

# Derive DOMAIN_NAME from DOMAIN — strip https:// first, then http:// from the result.
# Two unconditional assignments handle http://example.com correctly:
#   first strip is a no-op, second strips http://.
# Using := (only-if-unset) would silently skip the second strip when DOMAIN starts
# with http:// because the first := already set DOMAIN_NAME to "http://host".
DOMAIN_NAME="${DOMAIN#https://}"
DOMAIN_NAME="${DOMAIN_NAME#http://}"
export DOMAIN_NAME

# Validate required environment variables BEFORE starting Caddy
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
#
# Capture read_secret output via $(...) command substitution.
# Skip when TLS_PROVIDER=acme_http (token not required).
# =============================================================================
TLS_PROVIDER=${TLS_PROVIDER:-cloudflare}

# Validate TLS_PROVIDER early so an unsupported value produces a clear message
# instead of a cryptic 'undefined snippet: tls_<value>' error from Caddy.
case "$TLS_PROVIDER" in
    cloudflare|acme_http) ;;
    *)
        echo "ERROR: TLS_PROVIDER='$TLS_PROVIDER' is not supported." >&2
        echo "       Supported values: cloudflare, acme_http" >&2
        echo "       Update TLS_PROVIDER in .env and restart Caddy." >&2
        exit 1
        ;;
esac

if [ "$TLS_PROVIDER" = "cloudflare" ]; then
    _token=$(read_secret /run/secrets/caddy_cloudflare_dns_token)

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
else
    echo "TLS_PROVIDER=${TLS_PROVIDER}: skipping Cloudflare token load."
    # Export an empty value so {env.CLOUDFLARE_API_TOKEN} in Caddyfile never
    # causes a 'variable not found' error.
    export CLOUDFLARE_API_TOKEN=""
fi

# =============================================================================
# SECURITY: Load Admin Basic Auth Hash
# =============================================================================
ADMIN_HASH_FULL=$(read_secret /run/secrets/admin_basic_auth_hash)

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

# Enforce OWASP minimum bcrypt cost of 10.
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
# Set PUSH_CSP environment variable consumed by Caddyfile.
# =============================================================================
PUSH_ENABLED=${PUSH_ENABLED:-false}
if [ "$PUSH_ENABLED" = "true" ]; then
    export PUSH_CSP=" https://push.bitwarden.com https://identity.bitwarden.com"
else
    export PUSH_CSP=""
fi

# =============================================================================
# 'caddy validate' removed — Caddy validates at 'caddy run' startup.
# =============================================================================

# =============================================================================
# DEGRADED MODE: use the pre-committed Caddyfile.degraded
#
# caddy/Caddyfile.degraded is identical to caddy/Caddyfile except all
# 'output file /var/log/caddy/...' blocks are replaced with 'output stdout'.
# Using a static file avoids the maintenance burden and edge-case failures
# of the previous runtime awk rewriter.
# =============================================================================
CADDYFILE=/etc/caddy/Caddyfile
if [ "$CADDY_DEGRADED" = "true" ]; then
    if [ -f /etc/caddy/Caddyfile.degraded ]; then
        CADDYFILE=/etc/caddy/Caddyfile.degraded
    else
        log_warn "Caddyfile.degraded not found — using original (file logging may fail)."
    fi
fi

# =============================================================================
# START CADDY
# =============================================================================
echo "==================================================================="
echo " Starting Caddy Server"
echo " Domain:   ${DOMAIN_NAME}"
echo " Caddy:    $(caddy version 2>/dev/null || echo 'unknown')"
echo " Degraded: ${CADDY_DEGRADED}  (true = stdout logging only, fix host perms)"
echo "==================================================================="

exec caddy run --config "$CADDYFILE" --adapter caddyfile
