#!/usr/bin/env bash
# update-cloudflare-ips.sh - Update Cloudflare IP ranges for Caddy and fail2ban
set -euo pipefail

CADDY_DIR="caddy"
IPS_FILE="${CADDY_DIR}/cloudflare-ips.caddy"
BACKUP_FILE="${CADDY_DIR}/cloudflare-ips.caddy.bak"
CONTAINER="vaultwarden_caddy"

CF_V4_URL="https://www.cloudflare.com/ips-v4"
CF_V6_URL="https://www.cloudflare.com/ips-v6"

echo "[INFO] Fetching Cloudflare IP ranges..."

# Create temp directory
TMP_DIR="$(mktemp -d)"
trap "rm -rf ${TMP_DIR}" EXIT

# Fetch IP ranges
curl -fsSL --max-time 30 "${CF_V4_URL}" > "${TMP_DIR}/cf-v4.txt"
curl -fsSL --max-time 30 "${CF_V6_URL}" > "${TMP_DIR}/cf-v6.txt"

# Validation
if [[ ! -s "${TMP_DIR}/cf-v4.txt" || ! -s "${TMP_DIR}/cf-v6.txt" ]]; then
    echo "[ERROR] Failed to fetch Cloudflare IP ranges. Aborting."
    exit 1
fi

if (( $(wc -l < "${TMP_DIR}/cf-v4.txt") < 5 )) || (( $(wc -l < "${TMP_DIR}/cf-v6.txt") < 3 )); then
    echo "[ERROR] Cloudflare IP list appears incomplete. Aborting."
    exit 1
fi

# Create directory and backup
mkdir -p "${CADDY_DIR}"
[[ -f "${IPS_FILE}" ]] && cp "${IPS_FILE}" "${BACKUP_FILE}"

# Generate the named matcher file using reliable method
{
    echo "# Cloudflare IP ranges - Generated $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "# Sources: ${CF_V4_URL} ${CF_V6_URL}"
    echo "# This snippet defines @cloudflare_ips matcher"
    echo
    echo "@cloudflare_ips {"

    # IPv4 ranges - use tr to convert newlines to spaces, then clean up
    echo -n "    remote_ip "
    tr '\n' ' ' < "${TMP_DIR}/cf-v4.txt" | sed 's/[[:space:]]*$//'
    echo

    # IPv6 ranges - same approach
    echo -n "    remote_ip "
    tr '\n' ' ' < "${TMP_DIR}/cf-v6.txt" | sed 's/[[:space:]]*$//'
    echo

    echo "}"
} > "${IPS_FILE}"

total_ips=$(($(wc -l < "${TMP_DIR}/cf-v4.txt") + $(wc -l < "${TMP_DIR}/cf-v6.txt")))
echo "[INFO] Updated ${IPS_FILE} with ${total_ips} IP ranges"

# Validate and reload if container is running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "[INFO] Validating Caddy configuration..."
    if docker exec "${CONTAINER}" caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        echo "[INFO] Reloading Caddy..."
        docker exec "${CONTAINER}" caddy reload --config /etc/caddy/Caddyfile
        echo "[SUCCESS] Cloudflare IP ranges updated and Caddy reloaded."
        rm -f "${BACKUP_FILE}"
    else
        echo "[ERROR] Caddy configuration validation failed. Restoring backup."
        [[ -f "${BACKUP_FILE}" ]] && mv "${BACKUP_FILE}" "${IPS_FILE}"
        exit 1
    fi
else
    echo "[INFO] Caddy container not running. Configuration will be applied on next start."
fi
