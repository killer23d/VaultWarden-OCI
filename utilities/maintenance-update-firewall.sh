#!/usr/bin/env bash
# utilities/maintenance-update-firewall.sh — Updates UFW rules for Cloudflare IP ranges.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_SAVE_SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/log.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/common.sh"
init_common_lib "$0"
source "$PROJECT_ROOT/lib/operations.sh"
source "$PROJECT_ROOT/lib/docker.sh"
source "$PROJECT_ROOT/lib/backup-utils.sh"
source "$PROJECT_ROOT/lib/crypto.sh"
_MAINT_SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/secrets.sh"
SCRIPT_DIR="$_MAINT_SCRIPT_DIR"
unset _MAINT_SCRIPT_DIR
source "$PROJECT_ROOT/lib/storage.sh"

UPDATE_FIREWALL=true
DRY_RUN=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Firewall Range Updater

USAGE:
    sudo utilities/maintenance-update-firewall.sh [OPTIONS]
    sudo ./maintenance.sh update-firewall [OPTIONS]

DESCRIPTION:
    Fetches the current Cloudflare IP ranges (IPv4 + IPv6) and reconciles UFW
    so ports 80 and 443 are allowed only from those ranges. Conflicting public
    ingress and retired managed Cloudflare rules are removed.

    Skipped automatically when CLOUDFLARE_PROXY_ENABLED is not "true".

OPTIONS:
    --dry-run     Preview what would be done without making changes
    --help, -h    Show this help
    --version, -V Print the VaultWarden-OCI version and exit

EXIT CODES:
    0 — Firewall ranges updated successfully or skipped by configuration
    75 — skipped because another VaultWarden operation owns the lock
    Other non-zero — Firewall update failed
EOF
}

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

    _ufw_has_range_port() {
        local status="$1" range="$2" port="$3" escaped_range
        escaped_range=$(printf '%s' "$range" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
        grep -qE "^${port}/tcp([[:space:]]+\\(v6\\))?[[:space:]]+(ALLOW|ALLOW IN)[[:space:]].*${escaped_range}([[:space:]]|$)" <<< "$status"
    }

    _ufw_line_cidr() {
        local line="$1" word
        local -a words=()
        read -ra words <<< "$line"
        for word in "${words[@]}"; do
            word="${word%\#*}"
            if [[ "$word" =~ ^[0-9]+(\.[0-9]+){3}/[0-9]+$ || "$word" =~ ^[0-9a-fA-F:]+/[0-9]+$ ]]; then
                printf '%s\n' "$word"
                return 0
            fi
        done
        return 1
    }

    _ufw_collect_conflicts() {
        local numbered_status="$1"
        shift
        local -a desired=("$@")
        local line rule_num cidr keep desired_cidr

        while IFS= read -r line; do
            [[ "$line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+(80|443)(/tcp)?([[:space:]]+\(v6\))?[[:space:]]+(ALLOW|ALLOW[[:space:]]+IN)([[:space:]]|$) ]] || continue
            rule_num="${BASH_REMATCH[1]}"
            if [[ -z "${BASH_REMATCH[3]}" ]]; then
                printf '%s\n' "$rule_num"
                continue
            fi
            cidr="$(_ufw_line_cidr "$line" || true)"
            keep=false
            if [[ -n "$cidr" ]]; then
                for desired_cidr in "${desired[@]}"; do
                    if [[ "$desired_cidr" == "$cidr" ]]; then
                        keep=true
                        break
                    fi
                done
            fi
            [[ "$keep" == "true" ]] || printf '%s\n' "$rule_num"
        done <<< "$numbered_status"
    }

    _ufw_allow_range() {
        local range="$1" label="$2"
        _ufw_result=false

        local ufw_status ufw_rc=0
        ufw_status="$(ufw status 2>&1)" || ufw_rc=$?
        if (( ufw_rc != 0 )); then
            log_error "Unable to read UFW status for ${range} (exit ${ufw_rc}): ${ufw_status:-no output}"
            return "$ufw_rc"
        fi

        local has_80=false has_443=false
        _ufw_has_range_port "$ufw_status" "$range" 80 && has_80=true
        _ufw_has_range_port "$ufw_status" "$range" 443 && has_443=true
        if [[ "$has_80" == "true" && "$has_443" == "true" ]]; then return 0; fi

        local ufw_output
        if [[ "$has_80" != "true" ]]; then
            ufw_rc=0
            ufw_output="$(ufw allow proto tcp from "$range" to any port 80 comment "$label" 2>&1)" || ufw_rc=$?
            if (( ufw_rc != 0 )); then
                log_error "Failed to add UFW port 80 rule for ${range} (exit ${ufw_rc}): ${ufw_output:-no output}"
                return "$ufw_rc"
            fi
        fi
        if [[ "$has_443" != "true" ]]; then
            ufw_rc=0
            ufw_output="$(ufw allow proto tcp from "$range" to any port 443 comment "$label" 2>&1)" || ufw_rc=$?
            if (( ufw_rc != 0 )); then
                log_error "Failed to add UFW port 443 rule for ${range} (exit ${ufw_rc}): ${ufw_output:-no output}"
                return "$ufw_rc"
            fi
        fi
        _ufw_result=true
    }

    local ranges_added=false
    local _ufw_result=false
    local -a current_cidrs=()
    local cf_cidr_cache="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/cf-cidrs.cache"

    if grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' "$cf_ipv4_file" >/dev/null; then
        log_info "Adding new Cloudflare IPv4 ranges..."
        while IFS= read -r range; do
            if [[ -n "$range" && "$range" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
                current_cidrs+=("$range")
                _ufw_allow_range "$range" "CF-IPv4" || return $?
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
                current_cidrs+=("$range")
                _ufw_allow_range "$range" "CF-IPv6" || return $?
                if [[ "$_ufw_result" == "true" ]]; then
                    ranges_added=true
                    log_debug "Added IPv6 range: $range"
                fi
            fi
        done < "$cf_ipv6_file"
    fi

    if (( ${#current_cidrs[@]} == 0 )); then
        log_error "No valid Cloudflare CIDRs were fetched; refusing to change UFW."
        return 1
    fi

    if [[ "$ranges_added" == "true" ]]; then
        log_success "New Cloudflare IP ranges added successfully"
    else
        log_info "No new IP ranges needed to be added"
    fi

    log_info "Removing conflicting or outdated Cloudflare ingress rules..."
    local removed_count=0
    local -a old_rule_nums=()
    local ufw_status ufw_rc=0
    ufw_status="$(ufw status numbered 2>&1)" || ufw_rc=$?
    if (( ufw_rc != 0 )); then
        log_error "Unable to read numbered UFW rules (exit ${ufw_rc}): ${ufw_status:-no output}"
        return "$ufw_rc"
    fi

    mapfile -t old_rule_nums < <(_ufw_collect_conflicts "$ufw_status" "${current_cidrs[@]}")

    if (( ${#old_rule_nums[@]} > 0 )); then
        mapfile -t old_rule_nums < <(printf '%s\n' "${old_rule_nums[@]}" | awk 'NF && !seen[$0]++' | sort -rn)
        local rule_num ufw_output
        for rule_num in "${old_rule_nums[@]}"; do
            ufw_rc=0
            ufw_output="$(ufw --force delete "$rule_num" 2>&1)" || ufw_rc=$?
            if (( ufw_rc != 0 )); then
                log_error "Failed to delete UFW rule ${rule_num} (exit ${ufw_rc}): ${ufw_output:-no output}"
                return "$ufw_rc"
            fi
            removed_count=$((removed_count + 1))
        done
    fi
    [[ $removed_count -gt 0 ]] && log_success "Removed $removed_count conflicting/outdated firewall rules"

    local final_status final_numbered
    ufw_rc=0
    final_status="$(ufw status 2>&1)" || ufw_rc=$?
    if (( ufw_rc != 0 )); then
        log_error "Unable to verify final UFW status (exit ${ufw_rc}): ${final_status:-no output}"
        return "$ufw_rc"
    fi
    ufw_rc=0
    final_numbered="$(ufw status numbered 2>&1)" || ufw_rc=$?
    if (( ufw_rc != 0 )); then
        log_error "Unable to verify final numbered UFW status (exit ${ufw_rc}): ${final_numbered:-no output}"
        return "$ufw_rc"
    fi
    if [[ -n "$(_ufw_collect_conflicts "$final_numbered" "${current_cidrs[@]}")" ]]; then
        log_error "Non-Cloudflare UFW 80/443 allow rule remains after Cloudflare reconciliation."
        return 1
    fi
    local cidr
    for cidr in "${current_cidrs[@]}"; do
        _ufw_has_range_port "$final_status" "$cidr" 80 || {
            log_error "Final UFW verification missing ${cidr} -> 80/tcp"
            return 1
        }
        _ufw_has_range_port "$final_status" "$cidr" 443 || {
            log_error "Final UFW verification missing ${cidr} -> 443/tcp"
            return 1
        }
    done

    mkdir -p "$(dirname "$cf_cidr_cache")" 2>/dev/null || true
    printf '%s\n' "${current_cidrs[@]}" > "$cf_cidr_cache" 2>/dev/null || true
    chmod 640 "$cf_cidr_cache" 2>/dev/null || true

    log_success "Firewall IP ranges updated and verified safely"
    return 0
}

[[ "${1:-}" == "update-firewall" ]] && shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)         DRY_RUN=true; shift ;;
        --help|-h|help)    show_help; exit 0 ;;
        --version|-V)      print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0 ;;
        *) log_error "Unknown option for 'update-firewall': $1"; show_help; exit 1 ;;
    esac
done

main() {
    local rc
    require_root "$@"
    if [[ "$DRY_RUN" != "true" ]]; then
        operation_acquire \
            --id firewall-update \
            --label "Firewall update" \
            --specific-lock /run/lock/vaultwarden-firewall-update.lock \
            --non-interactive skip || {
                rc=$?
                exit "$rc"
            }
        operation_set_phase "update" "Updating Cloudflare firewall ranges"
    fi
    load_project_environment || exit 1
    auto_fix_critical_permissions "$PROJECT_ROOT"
    trap 'rc=$?; operation_release "$rc"; perform_cleanup; exit "$rc"' EXIT
    trap 'operation_release 130; perform_cleanup; exit 130' INT
    trap 'operation_release 143; perform_cleanup; exit 143' HUP TERM
    update_firewall_ranges
    exit $?
}

main "$@"
