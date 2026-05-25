#!/usr/bin/env bash
# utilities/maintenance-update-dns.sh — VaultWarden Cloudflare DNS updater
#
# Standalone entry point for the 'update-dns' subcommand.
# Invoked directly by:
#   - maintenance.sh update-dns [OPTIONS]  (thin dispatcher)
#   - systemd/vaultwarden-dns-update.service
#
# EXIT CODES:
#   0 — DNS record is up to date or was updated successfully
#   1 — DNS update failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_SAVE_SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/log.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/email.sh"
init_common_lib "$0"
source "$PROJECT_ROOT/lib/docker.sh"
source "$PROJECT_ROOT/lib/backup-utils.sh"
source "$PROJECT_ROOT/lib/crypto.sh"
_MAINT_SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/secrets.sh"
SCRIPT_DIR="$_MAINT_SCRIPT_DIR"
unset _MAINT_SCRIPT_DIR
source "$PROJECT_ROOT/lib/storage.sh"

# ---------------------------------------------------------------------------
# Configuration defaults
# ---------------------------------------------------------------------------
UPDATE_DNS=true
DRY_RUN=false
EMAIL_NOTIFY=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI DNS Updater

USAGE:
    sudo utilities/maintenance-update-dns.sh [OPTIONS]
    ./maintenance.sh update-dns [OPTIONS]

OPTIONS:
    --email       Send email notification if the DNS record is updated
    --dry-run     Preview what would be done without making changes
    --help, -h    Show this help

EXIT CODES:
    0 — DNS record up to date or updated successfully
    1 — DNS update failed
EOF
}

# ---------------------------------------------------------------------------
# _load_env
# ---------------------------------------------------------------------------
_load_env() {
    if load_env_file 2>/dev/null; then return 0; fi
    log_warn "No .env file found — relying on environment already set (e.g. systemd EnvironmentFile)"
    return 0
}

# ---------------------------------------------------------------------------
# update_dns_record — verbatim from maintenance.sh
# ---------------------------------------------------------------------------
update_dns_record() {
    if [[ "$UPDATE_DNS" != "true" ]]; then log_info "Skipping DNS update"; return 0; fi
    if [[ "$DRY_RUN"    == "true" ]]; then log_info "[DRY RUN] Would check and update Cloudflare DNS A record"; return 0; fi

    local domain="${DOMAIN:-}"
    domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')
    local zone_id="${CLOUDFLARE_ZONE_ID:-}"
    [[ -z "$domain"  ]] && { log_error "DOMAIN not set in .env"; return 1; }
    [[ -z "$zone_id" ]] && { log_error "CLOUDFLARE_ZONE_ID not set in .env"; return 1; }

    local DNS_LOCK="/run/lock/vaultwarden-dns-update.lock"
    local _DNS_LOCK_FD=""
    local _lock_user _lock_group _lock_owner
    _lock_user=$(id -un)
    _lock_group=$(id -gn)
    if [[ -f "$DNS_LOCK" ]]; then
        _lock_owner=$(stat -c '%U' "$DNS_LOCK" 2>/dev/null || echo "")
        if [[ -n "$_lock_owner" && "$_lock_owner" != "$_lock_user" ]]; then
            chown "${_lock_user}:${_lock_group}" "$DNS_LOCK" 2>/dev/null || true
            sudo chown "${_lock_user}:${_lock_group}" "$DNS_LOCK" 2>/dev/null || true
        fi
    else
        install -m 0660 /dev/null "$DNS_LOCK" 2>/dev/null || true
        chown "${_lock_user}:${_lock_group}" "$DNS_LOCK" 2>/dev/null || true
    fi
    chmod 0660 "$DNS_LOCK" 2>/dev/null || true
    if [[ ! -w "$DNS_LOCK" ]]; then
        log_error "Cannot write DNS run-lock: $DNS_LOCK"
        log_error "Fix once with: sudo chown ${_lock_user}:${_lock_group} $DNS_LOCK && sudo chmod 0660 $DNS_LOCK"
        return 1
    fi
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

    local token_file
    token_file="${CF_TOKEN_FILE:-${SCRIPT_DIR}/secrets/.docker_secrets/caddy_cloudflare_dns_token}"
    local cf_token
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
        cf_token=$(cat "$token_file") \
            || { log_error "Cannot read Cloudflare API token from host secret file"; return 1; }
    else
        cf_token=$(docker compose exec -T caddy \
            cat /run/secrets/caddy_cloudflare_dns_token 2>/dev/null) \
            || { log_error "Cannot read Cloudflare API token (host file: $token_file not found, Caddy container may be stopped)"; return 1; }
    fi
    [[ -z "$cf_token" ]] && { log_error "Cloudflare API token is empty"; return 1; }

    local cf_response record_id stored_ip
    cf_response=$(curl -s --max-time 15 \
        -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$domain" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json") \
        || { log_error "Cloudflare API request failed (network error)"; return 1; }

    record_id=$(echo "$cf_response" | jq -r '.result[0].id   // empty' 2>/dev/null)
    stored_ip=$(echo "$cf_response" | jq -r '.result[0].content // empty' 2>/dev/null)

    [[ -z "$record_id" ]] && { log_error "Cannot find DNS record ID for $domain"; return 1; }

    if [[ "$current_ip" == "$stored_ip" ]]; then
        log_success "DNS record up to date: $domain -> $current_ip (CF record content matches, proxy state irrelevant)"
        return 0
    fi

    log_info "DNS update needed: stored_ip=$stored_ip -> current_ip=$current_ip"

    local response
    response=$(curl -s --max-time 15 \
        -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$domain\",\"content\":\"$current_ip\",\"ttl\":300}")

    if echo "$response" | jq -e '.success' >/dev/null 2>&1; then
        log_success "DNS updated successfully: $domain -> $current_ip"
        if [[ "$EMAIL_NOTIFY" == "true" ]]; then
            local admin_email; admin_email=$(get_config_value "ADMIN_EMAIL" "")
            if [[ -n "$admin_email" ]]; then
                if send_notification_email "VaultWarden IP Address Changed" \
"Old IP: $stored_ip
New IP: $current_ip
Domain: $domain
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

# ---------------------------------------------------------------------------
# Argument parsing & main
# ---------------------------------------------------------------------------
# Strip leading 'update-dns' token if passed through from dispatcher
[[ "${1:-}" == "update-dns" ]] && shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --email)           EMAIL_NOTIFY=true; shift ;;
        --dry-run)         DRY_RUN=true;      shift ;;
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
