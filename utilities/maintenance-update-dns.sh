#!/usr/bin/env bash
# utilities/maintenance-update-dns.sh — Updates the VaultWarden Cloudflare DNS record.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# lib/secrets.sh recomputes SCRIPT_DIR at load time, so save and restore PROJECT_ROOT's value.
_SAVE_SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/log.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/common.sh"
init_common_lib "$0"
source "$PROJECT_ROOT/lib/operations.sh"
source "$PROJECT_ROOT/lib/email.sh"
source "$PROJECT_ROOT/lib/crypto.sh"
source "$PROJECT_ROOT/lib/secrets.sh"
SCRIPT_DIR="$_SAVE_SCRIPT_DIR"
unset _SAVE_SCRIPT_DIR

trap 'log_error "${BASH_SOURCE[0]}: failed at line ${LINENO} (exit $?)"; exit 1' ERR

# Configuration defaults.
UPDATE_DNS="${UPDATE_DNS:-}"
DNS_UPDATE_REQUIRED="${DNS_UPDATE_REQUIRED:-false}"
DRY_RUN=false
EMAIL_NOTIFY=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI DNS Updater

USAGE:
    sudo utilities/maintenance-update-dns.sh [OPTIONS]
    sudo ./maintenance.sh update-dns [OPTIONS]

OPTIONS:
    --email       Send email notification if the DNS record is updated
    --require-dns  Treat missing DNS automation config as a failure
    --dry-run     Preview what would be done without making changes
    --help, -h    Show this help
    --version, -V Print the VaultWarden-OCI version and exit

SECRET SOURCE:
    caddy_cloudflare_dns_token and cloudflare_zone_id are resolved only from
    canonical encrypted $SECRETS_FILE through decrypt_secret().

    DNS_UPDATE_REQUIRED=true or --require-dns makes missing config fail.
    UPDATE_DNS=false skips cleanly. When UPDATE_DNS is unset, missing or
    placeholder Cloudflare config logs a warning and exits 0.

EXIT CODES:
    0 — DNS record up to date or updated successfully
    75 — skipped because another VaultWarden operation owns the lock
    Other non-zero — DNS update failed
EOF
}

# _resolve_cf_token
# Cloudflare mutation credentials have one authority: encrypted SOPS state.
_resolve_cf_token() {
    local token
    if token=$(decrypt_secret "caddy_cloudflare_dns_token" 2>/dev/null) && [[ -n "$token" ]]; then
        printf '%s' "$token"
        return 0
    fi
    log_error "caddy_cloudflare_dns_token could not be resolved from canonical SOPS state"
    log_error "Fix: ./edit-secrets.sh rotate caddy_cloudflare_dns_token"
    return 1
}

# _resolve_zone_id
# Cloudflare mutation credentials have one authority: encrypted SOPS state.
_resolve_zone_id() {
    local zone_id
    if zone_id=$(decrypt_secret "cloudflare_zone_id" 2>/dev/null) && [[ -n "$zone_id" ]]; then
        printf '%s' "$zone_id"
        return 0
    fi
    log_error "cloudflare_zone_id could not be resolved from canonical SOPS state"
    log_error "Fix: ./edit-secrets.sh rotate cloudflare_zone_id"
    return 1
}

_is_placeholder_value() {
    local value="${1:-}"
    [[ -z "$value" || "$value" == PLACEHOLDER* || "$value" == CHANGE_ME* || "$value" == *YOUR_* || "$value" == "changeme" ]]
}

_dns_strict_required() {
    [[ "${DNS_UPDATE_REQUIRED:-false}" == "true" || "${UPDATE_DNS:-}" == "true" ]]
}

_dns_optional_skip() {
    local reason="$1"
    if _dns_strict_required; then
        log_error "$reason"
        log_error "DNS update is required (UPDATE_DNS=true or DNS_UPDATE_REQUIRED=true); configure Cloudflare DNS secrets."
        return 1
    fi
    log_warn "DNS automation not configured: $reason"
    log_warn "Skipping DNS update successfully. Set UPDATE_DNS=true or DNS_UPDATE_REQUIRED=true to make this a hard failure."
    return 0
}

_check_optional_dns_config() {
    if [[ "${UPDATE_DNS:-}" == "false" ]]; then
        log_info "UPDATE_DNS=false; skipping DNS update."
        return 0
    fi

    local domain="${DOMAIN:-}"
    domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')
    if [[ -z "$domain" || "$domain" == example.* || "$domain" == *CHANGE_ME* || "$domain" == *PLACEHOLDER* ]]; then
        _dns_optional_skip "DOMAIN is missing or still a placeholder"
        return $?
    fi

    local zone_id=""
    if zone_id=$(_resolve_zone_id 2>/dev/null); then
        if _is_placeholder_value "$zone_id"; then
            _dns_optional_skip "cloudflare_zone_id is missing or still a placeholder"
            return $?
        fi
    else
        _dns_optional_skip "cloudflare_zone_id is not configured"
        return $?
    fi

    local cf_token=""
    if cf_token=$(_resolve_cf_token 2>/dev/null); then
        if _is_placeholder_value "$cf_token"; then
            _dns_optional_skip "Cloudflare DNS token is missing or still a placeholder"
            return $?
        fi
    else
        _dns_optional_skip "Cloudflare DNS token is not configured"
        return $?
    fi

    DNS_ZONE_ID="$zone_id"
    DNS_CF_TOKEN="$cf_token"
    export DNS_ZONE_ID DNS_CF_TOKEN
    return 2
}

# _cf_patch_proxied — issue a PATCH to flip proxied:true without touching the IP or TTL.
_cf_patch_proxied() {
    local zone_id="$1" cf_token="$2" record_id="$3"
    local patch_response
    patch_response=$(curl -s --max-time 15 \
        -X PATCH "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
        -H "Authorization: Bearer ${cf_token}" \
        -H "Content-Type: application/json" \
        --data '{"proxied":true}')

    if echo "$patch_response" | jq -e '.success' >/dev/null 2>&1; then
        return 0
    fi
    log_error "Cloudflare PATCH (proxied) failed: $patch_response"
    return 1
}

# _cf_put_record — issue a PUT to update IP and enforce proxied:true.
_cf_put_record() {
    local zone_id="$1" cf_token="$2" record_id="$3" domain="$4" ip="$5"
    local put_response
    put_response=$(curl -s --max-time 15 \
        -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
        -H "Authorization: Bearer ${cf_token}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${domain}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":true}")

    if echo "$put_response" | jq -e '.success' >/dev/null 2>&1; then
        return 0
    fi
    log_error "Cloudflare PUT (IP+proxied) failed: $put_response"
    return 1
}

update_dns_record() {
    local cfg_status=0
    _check_optional_dns_config || cfg_status=$?
    case "$cfg_status" in
        0) return 0 ;;
        1) return 1 ;;
        2) ;;
        *) return "$cfg_status" ;;
    esac
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would check and update Cloudflare DNS A record"
        return 0
    fi

    local domain="${DOMAIN:-}"
    domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')
    [[ -z "$domain" ]] && { log_error "DOMAIN not set in .env"; return 1; }

    operation_set_phase "check" "Checking Cloudflare DNS record" 2>/dev/null || true
    log_info "Checking DNS record for $domain..."

    local current_ip
    current_ip=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '\n\r ') || true
    if [[ -z "$current_ip" ]] || [[ ! "$current_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        current_ip=$(curl -s --max-time 10 https://ifconfig.me 2>/dev/null | tr -d '\n\r ') || true
    fi
    if [[ -z "$current_ip" ]] || [[ ! "$current_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        current_ip=$(curl -s --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '\n\r ') || true
    fi
    [[ -z "$current_ip" ]] && { log_error "Cannot determine current external IP"; return 1; }
    [[ ! "$current_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && {
        log_error "Invalid IP format: $current_ip"; return 1
    }

    local zone_id cf_token
    zone_id="${DNS_ZONE_ID:-}"
    cf_token="${DNS_CF_TOKEN:-}"
    [[ -z "$zone_id" ]]  && { log_error "Cloudflare zone ID is empty"; return 1; }
    [[ -z "$cf_token" ]] && { log_error "Cloudflare API token is empty"; return 1; }

    local cf_response
    cf_response=$(curl -s --max-time 15 \
        -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${domain}" \
        -H "Authorization: Bearer ${cf_token}" \
        -H "Content-Type: application/json") \
        || { log_error "Cloudflare API request failed (network error)"; return 1; }

    # Validate the GET response itself succeeded.
    if ! echo "$cf_response" | jq -e '.success' >/dev/null 2>&1; then
        log_error "Cloudflare GET DNS records failed: $cf_response"
        return 1
    fi

    local record_id stored_ip proxied_raw
    record_id=$(echo "$cf_response"   | jq -r '.result[0].id      // empty')
    stored_ip=$(echo "$cf_response"   | jq -r '.result[0].content // empty')
    proxied_raw=$(echo "$cf_response" | jq -r '.result[0].proxied // empty')

    [[ -z "$record_id" ]] && { log_error "Cannot find DNS A record for $domain in zone"; return 1; }

    # Treat missing/null proxied field as false (needs fixing).
    local is_proxied="false"
    if [[ "$proxied_raw" == "true" ]]; then
        is_proxied="true"
    fi

    log_debug "CF record state: ip=$stored_ip proxied=$is_proxied record_id=$record_id"

    # Determine what needs fixing using if/then to be safe under set -e.
    local ip_changed="false"
    if [[ "$current_ip" != "$stored_ip" ]]; then
        ip_changed="true"
    fi

    local proxy_wrong="false"
    if [[ "$is_proxied" != "true" ]]; then
        proxy_wrong="true"
    fi

    # Nothing to do.
    if [[ "$ip_changed" == "false" && "$proxy_wrong" == "false" ]]; then
        log_success "DNS record up to date: $domain -> $current_ip (proxied=true)"
        return 0
    fi

    # IP changed — PUT the full record with proxied:true.
    if [[ "$ip_changed" == "true" ]]; then
        log_info "IP changed: $stored_ip -> $current_ip. Updating record (proxied=true)..."
        _cf_put_record "$zone_id" "$cf_token" "$record_id" "$domain" "$current_ip" \
            || return 1
        log_success "DNS updated: $domain -> $current_ip (proxied=true)"

        if [[ "$EMAIL_NOTIFY" == "true" ]]; then
            local admin_email
            admin_email=$(get_config_value "ADMIN_EMAIL" "")
            if [[ -n "$admin_email" ]]; then
                local body="Domain: $domain
Old IP: $stored_ip
New IP: $current_ip
Proxied: true
DNS record updated automatically."
                if [[ "$proxy_wrong" == "true" ]]; then
                    body="Domain: $domain
Old IP: $stored_ip
New IP: $current_ip
Proxy state corrected: DNS Only -> Proxied
DNS record updated automatically."
                fi
                if send_notification_email "VaultWarden DNS Record Updated" "$body"; then
                    log_info "DNS change notification sent"
                else
                    log_warn "Failed to send DNS change notification email"
                fi
            fi
        fi
        return 0
    fi

    # IP is the same but proxy is wrong — PATCH only the proxied field.
    if [[ "$proxy_wrong" == "true" ]]; then
        log_info "IP unchanged ($current_ip) but proxied=false. Correcting proxy state..."
        _cf_patch_proxied "$zone_id" "$cf_token" "$record_id" \
            || return 1
        log_success "Proxy state corrected: $domain -> $current_ip (proxied=true)"

        if [[ "$EMAIL_NOTIFY" == "true" ]]; then
            local admin_email
            admin_email=$(get_config_value "ADMIN_EMAIL" "")
            if [[ -n "$admin_email" ]]; then
                if send_notification_email "VaultWarden DNS Proxy State Corrected" \
"Domain: $domain
IP: $current_ip
Proxy state corrected: DNS Only -> Proxied
DNS record updated automatically."; then
                    log_info "DNS change notification sent"
                else
                    log_warn "Failed to send DNS change notification email"
                fi
            fi
        fi
        return 0
    fi
}

[[ "${1:-}" == "update-dns" ]] && shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --email)           EMAIL_NOTIFY=true; shift ;;
        --dry-run)         DRY_RUN=true;      shift ;;
        --require-dns)     DNS_UPDATE_REQUIRED=true; shift ;;
        --help|-h|help)    show_help; exit 0 ;;
        --version|-V)      print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0 ;;
        *) log_error "Unknown option for 'update-dns': $1"; show_help; exit 1 ;;
    esac
done

main() {
    local rc
    require_root "$@"
    if [[ "$DRY_RUN" != "true" ]]; then
        operation_acquire \
            --id dns-update \
            --label "DNS update" \
            --specific-lock /run/lock/vaultwarden-dns-update.lock \
            --non-interactive skip || {
                rc=$?
                exit "$rc"
            }
        trap 'rc=$?; operation_release "$rc"; exit "$rc"' EXIT
        trap 'operation_release 130; exit 130' INT
        trap 'operation_release 143; exit 143' HUP TERM
    fi
    load_project_environment || exit 1
    auto_fix_critical_permissions "$PROJECT_ROOT"
    update_dns_record
    exit $?
}

main "$@"
