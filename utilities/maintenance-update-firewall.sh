#!/usr/bin/env bash
# utilities/maintenance-update-firewall.sh — VaultWarden Cloudflare firewall range updater
#
# Standalone entry point for the 'update-firewall' subcommand.
# Invoked directly by:
#   - maintenance.sh update-firewall [OPTIONS]  (thin dispatcher)
#   - systemd/vaultwarden-firewall-update.service
#
# EXIT CODES:
#   0 — Firewall IP ranges updated successfully (or skipped as appropriate)
#   1 — Firewall update failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_SAVE_SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/common.sh"
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
UPDATE_FIREWALL=true
DRY_RUN=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Firewall Range Updater

USAGE:
    sudo utilities/maintenance-update-firewall.sh [OPTIONS]
    ./maintenance.sh update-firewall [OPTIONS]

DESCRIPTION:
    Fetches the current Cloudflare IP ranges (IPv4 + IPv6) and adds any new
    ranges to UFW as allow rules for ports 80 and 443.  Removes stale rules
    for ranges Cloudflare has retired.

    Skipped automatically when CLOUDFLARE_PROXY_ENABLED is not "true".

OPTIONS:
    --dry-run     Preview what would be done without making changes
    --help, -h    Show this help

EXIT CODES:
    0 — Firewall ranges updated successfully (or skipped)
    1 — Firewall update failed
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
# update_firewall_ranges — verbatim from maintenance.sh
# ---------------------------------------------------------------------------
# shellcheck disable=SC2120  # $@ is forwarded to require_root; callers pass no args intentionally
update_firewall_ranges() {
    if [[ "$UPDATE_FIREWALL" != "true" ]]; then log_info "Skipping firewall update"; return 0; fi
    if [[ "$DRY_RUN"         == "true" ]]; then log_info "[DRY RUN] Would safely update Cloudflare IP ranges in firewall"; return 0; fi
    if [[ "${CLOUDFLARE_PROXY_ENABLED:-false}" != "true" ]]; then
        log_info "Skipping Cloudflare IP range firewall update (CLOUDFLARE_PROXY_ENABLED is not 'true')"
        return 0
    fi

    require_root "$@"

    log_info "Safely updating Cloudflare IP ranges in firewall..."
    local cf_ipv4_file cf_ipv6_file
    cf_ipv4_file=$(mktemp -t cf_ipv4.XXXXXXXXXX)
    cf_ipv6_file=$(mktemp -t cf_ipv6.XXXXXXXXXX)
    register_cleanup rm -f "$cf_ipv4_file" "$cf_ipv6_file"
    if retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v4" -o "$cf_ipv4_file" && \
       retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v6" -o "$cf_ipv6_file"; then
        log_success "Successfully fetched current Cloudflare IP ranges"
    else
        log_error "Failed to fetch Cloudflare IP ranges - aborting firewall update"; return 1
    fi

    _ufw_allow_range() {
        local range="$1" label="$2"
        _ufw_result=false
        local ufw_status; ufw_status=$(ufw status 2>/dev/null)
        local escaped_range; escaped_range=$(printf '%s' "$range" | sed 's/\./\\./g')
        local has_80=false has_443=false
        echo "$ufw_status" | grep -qE "^80(/tcp)?[[:space:]]+(ALLOW|ALLOW IN)[[:space:]].*${escaped_range}" && has_80=true
        echo "$ufw_status" | grep -qE "^443(/tcp)?[[:space:]]+(ALLOW|ALLOW IN)[[:space:]].*${escaped_range}" && has_443=true
        if [[ "$has_80" == "true" && "$has_443" == "true" ]]; then return 0; fi
        if ufw allow proto tcp from "$range" to any port 80  comment "${label}" >/dev/null 2>&1 && \
           ufw allow proto tcp from "$range" to any port 443 comment "${label}" >/dev/null 2>&1; then
            _ufw_result=true
        else
            log_warn "ufw allow failed for range: $range"
        fi
    }

    local ranges_added=false
    local _ufw_result=false

    if grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' "$cf_ipv4_file" >/dev/null; then
        log_info "Adding new Cloudflare IPv4 ranges..."
        while IFS= read -r range; do
            if [[ -n "$range" && "$range" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
                _ufw_allow_range "$range" "CF-IPv4-NEW"
                if [[ "$_ufw_result" == "true" ]]; then
                    ranges_added=true
                    log_debug "Added IPv4 range: $range"
                fi
            fi
        done < "$cf_ipv4_file"
    fi

    if grep -E '^[0-9a-fA-F:]+/[0-9]{1,3}$' "$cf_ipv6_file" >/dev/null; then
        log_info "Adding new Cloudflare IPv6 ranges..."
        while IFS= read -r range; do
            if [[ -n "$range" && "$range" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]]; then
                _ufw_allow_range "$range" "CF-IPv6-NEW"
                if [[ "$_ufw_result" == "true" ]]; then
                    ranges_added=true
                    log_debug "Added IPv6 range: $range"
                fi
            fi
        done < "$cf_ipv6_file"
    fi

    if [[ "$ranges_added" == "true" ]]; then
        log_success "New Cloudflare IP ranges added successfully"
    else
        log_info "No new IP ranges needed to be added"
    fi

    log_info "Removing outdated Cloudflare IP ranges..."
    local removed_count=0
    local -a old_rule_nums=()
    mapfile -t old_rule_nums < <(
        ufw status numbered \
        | grep -E "CF-IPv[46]" \
        | grep -v "CF-IPv[46]-NEW" \
        | sed -n 's/^\[\s*\([0-9]\+\)\].*/\1/p' \
        | sort -rn
    )
    for rule_num in "${old_rule_nums[@]}"; do
        [[ -n "$rule_num" ]] && ufw --force delete "$rule_num" >/dev/null 2>&1 && ((removed_count++))
    done
    [[ $removed_count -gt 0 ]] && log_success "Removed $removed_count outdated firewall rules"
    log_success "Firewall IP ranges updated safely"
    return 0
}

# ---------------------------------------------------------------------------
# Argument parsing & main
# ---------------------------------------------------------------------------
# Strip leading 'update-firewall' token if passed through from dispatcher
[[ "${1:-}" == "update-firewall" ]] && shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)         DRY_RUN=true; shift ;;
        --help|-h|help)    show_help; exit 0 ;;
        *) log_error "Unknown option for 'update-firewall': $1"; show_help; exit 1 ;;
    esac
done

main() {
    require_root "$@"
    _load_env
    auto_fix_critical_permissions "$PROJECT_ROOT"
    trap 'perform_cleanup' EXIT HUP INT TERM
    update_firewall_ranges
    exit $?
}

main "$@"
