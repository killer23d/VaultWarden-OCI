#!/usr/bin/env bash
# update-dns.sh - Simple dynamic DNS update for VaultWarden-OCI
# Uses Docker secrets securely without exposing tokens in environment variables

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"

# Configuration from .env
DOMAIN="${DOMAIN:-}"
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"

# Validation
if [[ -z "$DOMAIN" ]]; then
    log_error "DOMAIN not set in .env"
    exit 1
fi

if [[ -z "$CLOUDFLARE_ZONE_ID" ]]; then
    log_error "CLOUDFLARE_ZONE_ID not set in .env"
    exit 1
fi

# Get API token from Docker secret (mounted in caddy container)
get_cf_token() {
    if docker compose exec -T caddy cat /run/secrets/caddy_cloudflare_dns_token 2>/dev/null; then
        return 0
    else
        log_error "Cannot read Cloudflare API token from Docker secret"
        return 1
    fi
}

main() {
    log_info "Checking if DNS update needed for $DOMAIN..."

    # Get current external IP
    local current_ip
    if ! current_ip=$(curl -s --max-time 10 https://api64.ipify.org 2>/dev/null); then
        log_error "Cannot determine current external IP"
        exit 1
    fi

    # Get current DNS record
    local dns_ip
    if ! dns_ip=$(dig +short "$DOMAIN" @1.1.1.1 2>/dev/null | head -1); then
        log_error "Cannot resolve current DNS record for $DOMAIN"
        exit 1
    fi

    # Compare IPs
    if [[ "$current_ip" == "$dns_ip" ]]; then
        log_success "DNS record up to date: $DOMAIN -> $current_ip"
        exit 0
    fi

    log_info "DNS update needed: $dns_ip -> $current_ip"

    # Get API token from Docker secret
    local cf_token
    if ! cf_token=$(get_cf_token); then
        exit 1
    fi

    # Get DNS record ID
    local record_id
    record_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=A&name=$DOMAIN" \
                -H "Authorization: Bearer $cf_token" \
                -H "Content-Type: application/json" | \
                jq -r '.result[0].id // empty' 2>/dev/null)

    if [[ -z "$record_id" ]]; then
        log_error "Cannot find DNS record ID for $DOMAIN"
        exit 1
    fi

    # Update DNS record
    local response
    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records/$record_id" \
               -H "Authorization: Bearer $cf_token" \
               -H "Content-Type: application/json" \
               --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$current_ip\",\"ttl\":300}")

    # Check if update succeeded
    if echo "$response" | jq -e '.success' >/dev/null 2>&1; then
        log_success "DNS updated successfully: $DOMAIN -> $current_ip"

        # Optional: Send notification for IP changes
        local admin_email
        admin_email=$(get_config_value "ADMIN_EMAIL" "")
        if [[ -n "$admin_email" ]] && has_command mail; then
            send_notification_email "VaultWarden IP Address Changed" "Your VaultWarden public IP changed:\n\nOld IP: $dns_ip\nNew IP: $current_ip\nDomain: $DOMAIN\n\nDNS record updated automatically."
        fi
    else
        log_error "DNS update failed: $response"
        exit 1
    fi
}

main "$@"
