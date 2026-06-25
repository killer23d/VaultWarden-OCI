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

SECRET SOURCE PRIORITY:
    caddy_cloudflare_dns_token — resolved in order:
        1. decrypt_secret() from encrypted $SECRETS_FILE
        2. Host file: $CF_TOKEN_FILE or /run/vaultwarden-oci/secrets/caddy_cloudflare_dns_token
        3. Caddy container: /run/secrets/caddy_cloudflare_dns_token

    DNS_UPDATE_REQUIRED=true or --require-dns makes missing config fail.
    UPDATE_DNS=false skips cleanly. When UPDATE_DNS is unset, missing or
    placeholder Cloudflare config logs a warning and exits 0.

    cloudflare_zone_id — resolved in order:
        1. decrypt_secret() from encrypted $SECRETS_FILE
        2. Legacy CLOUDFLARE_ZONE_ID shell variable fallback (do not add to .env)

EXIT CODES:
    0 — DNS record up to date or updated successfully
    1 — DNS update failed
EOF
}

_load_env() {
    if load_project_environment 2>/dev/null; then
        return 0
    fi

    if load_env_file /etc/vaultwarden/vaultwarden.env 2>/dev/null; then
        resolve_secrets_file
        return 0
    fi

    log_warn "No project environment found — relying on environment already set."
    resolve_secrets_file
    return 0
}

# _resolve_cf_token
# Priority: decrypt_secret → host secret file → Caddy container secret.
_resolve_cf_token() {
    local token

    # 1. Encrypted secrets file (preferred — no plaintext on disk).
    if token=$(decrypt_secret "caddy_cloudflare_dns_token" 2>/dev/null) && [[ -n "$token" ]]; then
        log_debug "Cloudflare token loaded via decrypt_secret"
        printf '%s' "$token"
        return 0
    fi

    # 2. Host-side Docker secret file.
    local token_file
    token_file="${CF_TOKEN_FILE:-/run/vaultwarden-oci/secrets/caddy_cloudflare_dns_token}"
    if [[ -f "$token_file" ]]; then
        local token_perms
        token_perms=$(stat -c%a "$token_file" 2>/dev/null \
                   || stat -f%Lp "$token_file" 2>/dev/null \
                   || echo "")
        case "$token_perms" in
            444|400|600|640)
                log_debug "Cloudflare token file permissions OK ($token_perms)"
                ;;
            "")
                log_warn "Cannot determine permissions on $token_file — proceeding with caution"
                ;;
            *)
                log_error "Cloudflare token file has insecure permissions ($token_perms): $token_file"
                log_error "Expected 444 (docker secret) or 400/600. Fix with: chmod 444 '$token_file'"
                return 1
                ;;
        esac
        token=$(cat "$token_file") \
            || { log_error "Cannot read Cloudflare API token from host secret file"; return 1; }
        log_debug "Cloudflare token loaded from host secret file: $token_file"
        printf '%s' "$token"
        return 0
    fi

    # 3. Caddy container secret (fallback when host file is absent).
    token=$(docker compose exec -T caddy \
        cat /run/secrets/caddy_cloudflare_dns_token 2>/dev/null) \
        || { log_error "Cannot read Cloudflare API token (host file: $token_file not found, Caddy container may be stopped)"; return 1; }
    log_debug "Cloudflare token loaded from Caddy container secret"
    printf '%s' "$token"
    return 0
}

# _resolve_zone_id
# Priority: decrypt_secret → legacy CLOUDFLARE_ZONE_ID shell variable fallback.
_resolve_zone_id() {
    local zone_id

    # 1. Encrypted secrets file (preferred).
    if zone_id=$(decrypt_secret "cloudflare_zone_id" 2>/dev/null) && [[ -n "$zone_id" ]]; then
        log_debug "Cloudflare zone_id loaded via decrypt_secret"
        printf '%s' "$zone_id"
        return 0
    fi

    # 2. Legacy shell environment variable fallback; do not add it to .env for new installs.
    if [[ -n "${CLOUDFLARE_ZONE_ID:-}" ]]; then
        log_debug "Cloudflare zone_id loaded from CLOUDFLARE_ZONE_ID environment variable"
        printf '%s' "${CLOUDFLARE_ZONE_ID}"
        return 0
    fi

    log_error "cloudflare_zone_id not found in encrypted secrets (legacy CLOUDFLARE_ZONE_ID shell fallback also empty)"
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

update_dns_record() {
    local cfg_status=0
    _check_optional_dns_config || cfg_status=$?
    case "$cfg_status" in
        0) return 0 ;;
        1) return 1 ;;
        2) ;;
        *) return "$cfg_status" ;;
    esac
    if [[ "$DRY_RUN"    == "true" ]]; then log_info "[DRY RUN] Would check and update Cloudflare DNS A record"; return 0; fi

    local domain="${DOMAIN:-}"
    domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')
    [[ -z "$domain" ]] && { log_error "DOMAIN not set in .env"; return 1; }

    local DNS_LOCK="/run/lock/vaultwarden-dns-update.lock"
    local _DNS_LOCK_FD=""
    _ensure_lock_file "$DNS_LOCK"
    exec {_DNS_LOCK_FD}>"$DNS_LOCK" 2>/dev/null || {
        log_error "Cannot open DNS run-lock: ${DNS_LOCK}"
        return 1
    }
    if ! flock -n "$_DNS_LOCK_FD"; then
        log_info "DNS update already in progress (lock: $DNS_LOCK). Skipping."
        return 0
    fi

    log_info "Checking if DNS update needed for $domain..."

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
    [[ -z "$zone_id" ]] && { log_error "Cloudflare zone ID is empty"; return 1; }
    [[ -z "$cf_token" ]] && { log_error "Cloudflare API token is empty"; return 1; }

    local cf_response record_id stored_ip proxied
    cf_response=$(curl -s --max-time 15 \
        -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$domain" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json") \
        || { log_error "Cloudflare API request failed (network error)"; return 1; }

    record_id=$(echo "$cf_response" | jq -r '.result[0].id      // empty' 2>/dev/null)
    stored_ip=$(echo "$cf_response" | jq -r '.result[0].content // empty' 2>/dev/null)
    proxied=$(echo "$cf_response"   | jq -r '.result[0].proxied // true'  2>/dev/null)

    [[ -z "$record_id" ]] && { log_error "Cannot find DNS record ID for $domain"; return 1; }

    if [[ "$current_ip" == "$stored_ip" ]]; then
        log_success "DNS record up to date: $domain -> $current_ip (proxied=$proxied)"
        return 0
    fi

    log_info "DNS update needed: stored_ip=$stored_ip -> current_ip=$current_ip (proxied=$proxied)"

    local response
    response=$(curl -s --max-time 15 \
        -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$domain\",\"content\":\"$current_ip\",\"ttl\":1,\"proxied\":$proxied}")

    if echo "$response" | jq -e '.success' >/dev/null 2>&1; then
        log_success "DNS updated successfully: $domain -> $current_ip (proxied=$proxied)"
        if [[ "$EMAIL_NOTIFY" == "true" ]]; then
            local admin_email; admin_email=$(get_config_value "ADMIN_EMAIL" "")
            if [[ -n "$admin_email" ]]; then
                if send_notification_email "VaultWarden IP Address Changed" \
"Old IP: $stored_ip
New IP: $current_ip
Domain: $domain
Proxied: $proxied
DNS record updated automatically."; then
                    log_info "DNS change notification sent"
                else
                    log_warn "Failed to send DNS change notification email"
                fi
            fi
        fi
    else
        log_error "DNS update failed: $response"; return 1
    fi
    return 0
}

[[ "${1:-}" == "update-dns" ]] && shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --email)           EMAIL_NOTIFY=true; shift ;;
        --dry-run)         DRY_RUN=true;      shift ;;
        --require-dns)     DNS_UPDATE_REQUIRED=true; shift ;;
        --help|-h|help)    show_help; exit 0 ;;
        *) log_error "Unknown option for 'update-dns': $1"; show_help; exit 1 ;;
    esac
done

main() {
    require_root "$@"
    _load_env
    auto_fix_critical_permissions "$PROJECT_ROOT"
    update_dns_record
    exit $?
}

main "$@"
