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

# Fetch IP ranges directly into variables
CF_V4=$(curl -fsSL --max-time 30 "${CF_V4_URL}")
CF_V6=$(curl -fsSL --max-time 30 "${CF_V6_URL}")

if [[ -z "$CF_V4" || -z "$CF_V6" ]]; then
    echo "[ERROR] Failed to fetch Cloudflare IP ranges. Aborting."
    exit 1
fi

# Simple validation
if (( $(echo "$CF_V4" | wc -l) < 5 )) || (( $(echo "$CF_V6" | wc -l) < 3 )); then
    echo "[ERROR] Cloudflare IP list appears incomplete. Aborting."
    exit 1
fi

# Ensure directory exists
mkdir -p "${CADDY_DIR}"

# Backup existing file
if [[ -f "${IPS_FILE}" ]]; then
    cp "${IPS_FILE}" "${BACKUP_FILE}" || true
fi

# Create the new file content directly
cat > "${IPS_FILE}" << 'IPEOF'
# Cloudflare IP ranges - Generated $(date -u +'%Y-%m-%dT%H:%M:%SZ')
# Sources: https://www.cloudflare.com/ips-v4 https://www.cloudflare.com/ips-v6
# Do not edit manually; changes will be overwritten.

IPEOF

# Add IPv4 ranges (combine into fewer lines)
echo "remote_ip $CF_V4" | tr '\n' ' ' >> "${IPS_FILE}"
echo >> "${IPS_FILE}"

# Add IPv6 ranges  
echo "remote_ip $CF_V6" | tr '\n' ' ' >> "${IPS_FILE}"
echo >> "${IPS_FILE}"

total_ips=$(($(echo "$CF_V4" | wc -l) + $(echo "$CF_V6" | wc -l)))
echo "[INFO] Updated ${IPS_FILE} with ${total_ips} IP ranges"

# Only validate and reload if container is running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "[INFO] Validating Caddy configuration..."
    if docker exec "${CONTAINER}" caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        echo "[INFO] Reloading Caddy..."
        docker exec "${CONTAINER}" caddy reload --config /etc/caddy/Caddyfile
        echo "[SUCCESS] Cloudflare IP ranges updated and Caddy reloaded."
    else
        echo "[ERROR] Caddy configuration validation failed. Restoring backup."
        if [[ -f "${BACKUP_FILE}" ]]; then
            mv "${BACKUP_FILE}" "${IPS_FILE}"
        fi
        exit 1
    fi
else
    echo "[INFO] Caddy container not running. Configuration will be applied on next start."
fi

# Clean up backup on success
rm -f "${BACKUP_FILE}"
