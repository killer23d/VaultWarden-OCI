#!/usr/bin/env bash
# update-cloudflare-ips.sh - Update Cloudflare IP ranges for Caddy and fail2ban

set -euo pipefail

# Paths relative to repo root (matches docker-compose volume mounts)
CADDY_DIR="caddy"
IPS_FILE="${CADDY_DIR}/cloudflare-ips.caddy"
BACKUP_FILE="${CADDY_DIR}/cloudflare-ips.caddy.bak"

# Container name from docker-compose.yml
CADDY_CONTAINER="vaultwarden_caddy"
CADDYFILE_PATH="/etc/caddy/Caddyfile"

# Cloudflare IP sources
CF_V4_URL="https://www.cloudflare.com/ips-v4"
CF_V6_URL="https://www.cloudflare.com/ips-v6"

# Temporary files
TMP_DIR="$(mktemp -d)"
TMP_V4="${TMP_DIR}/cf-v4.txt"
TMP_V6="${TMP_DIR}/cf-v6.txt"
TMP_OUT="${TMP_DIR}/cloudflare-ips.caddy"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "[INFO] Fetching Cloudflare IP ranges..."

# Download IP ranges
if ! curl -fsSL --max-time 30 "${CF_V4_URL}" -o "${TMP_V4}"; then
    echo "[ERROR] Failed to fetch Cloudflare IPv4 ranges. Aborting."
    exit 1
fi

if ! curl -fsSL --max-time 30 "${CF_V6_URL}" -o "${TMP_V6}"; then
    echo "[ERROR] Failed to fetch Cloudflare IPv6 ranges. Aborting."
    exit 1
fi

# Basic validation
if [[ ! -s "${TMP_V4}" || ! -s "${TMP_V6}" ]]; then
    echo "[ERROR] Empty response from Cloudflare. Aborting."
    exit 1
fi

# Sanity check: expect reasonable number of ranges
if (( $(wc -l < "${TMP_V4}") < 5 )) || (( $(wc -l < "${TMP_V6}") < 3 )); then
    echo "[ERROR] Cloudflare IP list appears incomplete. Aborting."
    exit 1
fi

# Build the named matcher file content
{
    echo "# Cloudflare IP ranges - Generated $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "# Sources: ${CF_V4_URL} ${CF_V6_URL}"
    echo "# Do not edit manually; changes will be overwritten."
    echo
    echo "@cloudflare_ips {"
    
    # Add IPv4 ranges (multiple per line for readability)
    echo -n "    remote_ip"
    count=0
    while IFS= read -r cidr; do
        [[ -z "${cidr}" ]] && continue
        (( count++ ))
        if (( count > 12 )); then
            echo
            echo -n "    remote_ip"
            count=1
        fi
        echo -n " ${cidr}"
    done < "${TMP_V4}"
    echo
    
    # Add IPv6 ranges (fewer per line due to length)
    echo -n "    remote_ip"
    count=0
    while IFS= read -r cidr; do
        [[ -z "${cidr}" ]] && continue
        (( count++ ))
        if (( count > 6 )); then
            echo
            echo -n "    remote_ip"
            count=1
        fi
        echo -n " ${cidr}"
    done < "${TMP_V6}"
    echo
    echo "}"
} > "${TMP_OUT}"

# Ensure directory exists
mkdir -p "${CADDY_DIR}"

# Backup existing file
if [[ -f "${IPS_FILE}" ]]; then
    cp "${IPS_FILE}" "${BACKUP_FILE}" || {
        echo "[WARN] Failed to create backup"
    }
fi

# Atomic replacement
mv "${TMP_OUT}" "${IPS_FILE}"

total_ips=$(($(wc -l < "${TMP_V4}") + $(wc -l < "${TMP_V6}")))
echo "[INFO] Updated ${IPS_FILE} with ${total_ips} IP ranges"

# Validate configuration inside running container
echo "[INFO] Validating Caddy configuration..."
if ! docker exec "${CADDY_CONTAINER}" caddy validate --config "${CADDYFILE_PATH}" >/dev/null 2>&1; then
    echo "[ERROR] Caddy configuration validation failed. Restoring backup."
    
    # Restore backup if available
    if [[ -f "${BACKUP_FILE}" ]]; then
        mv "${BACKUP_FILE}" "${IPS_FILE}"
        echo "[INFO] Previous configuration restored."
        
        # Verify backup works
        if docker exec "${CADDY_CONTAINER}" caddy validate --config "${CADDYFILE_PATH}" >/dev/null 2>&1; then
            echo "[INFO] Backup configuration is valid."
        else
            echo "[ERROR] Even backup configuration is invalid. Manual intervention required."
        fi
    else
        echo "[ERROR] No backup available. Manual intervention required."
    fi
    exit 1
fi

# Reload Caddy with new configuration
echo "[INFO] Reloading Caddy with updated IP ranges..."
if docker exec "${CADDY_CONTAINER}" caddy reload --config "${CADDYFILE_PATH}"; then
    echo "[SUCCESS] Cloudflare IP ranges updated and Caddy reloaded successfully."
else
    echo "[ERROR] Caddy reload failed. Service may be using old configuration."
    exit 1
fi

# Clean up backup on success
rm -f "${BACKUP_FILE}"
