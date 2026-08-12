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
# shellcheck source=../lib/firewall.sh
source "$PROJECT_ROOT/lib/firewall.sh"
# shellcheck source=../lib/firewall-ufw.sh
source "$PROJECT_ROOT/lib/firewall-ufw.sh"

UPDATE_FIREWALL=true
DRY_RUN=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Firewall Range Updater

USAGE:
    sudo utilities/maintenance-update-firewall.sh [OPTIONS]
    sudo ./maintenance.sh update-firewall [OPTIONS]

DESCRIPTION:
    Fetches current Cloudflare IP ranges, reconciles defence-in-depth UFW
    rules, and refreshes the Docker DOCKER-USER gate for published TCP 80/443.
    Ambiguous host-firewall policy fails closed instead of being guessed.

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
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would safely update Cloudflare firewall ranges"; return 0; fi
    if [[ "${CLOUDFLARE_PROXY_ENABLED:-false}" != "true" ]]; then
        log_info "Skipping Cloudflare IP range firewall update (CLOUDFLARE_PROXY_ENABLED is not 'true')"
        return 0
    fi

    require_root "$@"

    local ssh_port
    ssh_port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
    if [[ -z "$ssh_port" ]]; then
        ssh_port="$(awk '/^Port[[:space:]]/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
    fi
    ssh_port="${ssh_port:-22}"
    if [[ "$ssh_port" == "80" || "$ssh_port" == "443" ]]; then
        log_error "SSH port ${ssh_port}/tcp conflicts with managed Cloudflare web ingress."
        log_error "Move SSH to a dedicated non-web port before updating firewall rules."
        return 1
    fi

    # Until the current Docker backend and cached generation are proven safe,
    # an interrupt must not leave Caddy serving behind an unverified gate.
    local pre_update_docker_gate_exact=false
    _update_firewall_pretransaction_signal() {
        local signal_rc="$1"
        if [[ "$pre_update_docker_gate_exact" != "true" ]]; then
            if ! firewall_fail_closed_stop_caddy; then
                log_error "CRITICAL: firewall validation was interrupted and Caddy shutdown could not be confirmed."
            fi
        fi
        operation_release "$signal_rc"
        perform_cleanup
        exit "$signal_rc"
    }
    trap '_update_firewall_pretransaction_signal 130' INT
    trap '_update_firewall_pretransaction_signal 143' HUP TERM

    # Refuse all mutations if the running Docker daemon is using an unsupported
    # backend. A stale DOCKER-USER chain alone is not proof of the active mode.
    local docker_preflight_rc=0
    firewall_docker_backend_preflight || docker_preflight_rc=$?
    if (( docker_preflight_rc != 0 )); then
        if ! firewall_fail_closed_stop_caddy; then
            log_error "CRITICAL: Docker firewall backend preflight failed and Caddy shutdown could not be confirmed."
        fi
        return "$docker_preflight_rc"
    fi

    # Prove whether rollback would return to a known-safe Docker ingress
    # generation. A normal Cloudflare range change may make the gate non-exact
    # for the newly fetched set while it is still exact for the valid cached
    # generation. Only the latter is safe to restore without stopping Caddy.
    local -a pre_update_ipv4_cidrs=()
    if firewall_load_cached_cloudflare_ipv4 pre_update_ipv4_cidrs >/dev/null 2>&1 && \
       firewall_docker_ingress_is_exact "${pre_update_ipv4_cidrs[@]}"; then
        pre_update_docker_gate_exact=true
    else
        log_warn "Pre-update Docker ingress gate is not provably exact against a valid cached Cloudflare generation."
        log_warn "If this transaction cannot commit safely, Caddy will be stopped after rollback."
    fi

    _update_firewall_fail_closed_after_unproven_prior_gate() {
        if ! firewall_fail_closed_stop_caddy; then
            log_error "CRITICAL: pre-update Docker ingress gate was not provably exact and Caddy shutdown could not be confirmed."
        fi
    }

    _update_firewall_pretransaction_fail() {
        local fail_rc="$1"
        if [[ "$pre_update_docker_gate_exact" != "true" ]]; then
            _update_firewall_fail_closed_after_unproven_prior_gate
        fi
        return "$fail_rc"
    }

    log_info "Safely updating Cloudflare IP ranges in UFW and Docker ingress filtering..."
    local cf_ipv4_file="" cf_ipv6_file="" allocation_rc=0
    cf_ipv4_file="$(mktemp -t cf_ipv4.XXXXXXXXXX)" || allocation_rc=$?
    if (( allocation_rc != 0 )); then
        log_error "Could not allocate Cloudflare IPv4 range download file."
        _update_firewall_pretransaction_fail "$allocation_rc"
        return $?
    fi
    allocation_rc=0
    cf_ipv6_file="$(mktemp -t cf_ipv6.XXXXXXXXXX)" || allocation_rc=$?
    if (( allocation_rc != 0 )); then
        log_error "Could not allocate Cloudflare IPv6 range download file."
        rm -f "$cf_ipv4_file"
        _update_firewall_pretransaction_fail "$allocation_rc"
        return $?
    fi
    register_cleanup rm -f "$cf_ipv4_file" "$cf_ipv6_file"
    if retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v4" -o "$cf_ipv4_file" && \
       retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v6" -o "$cf_ipv6_file"; then
        log_success "Successfully fetched current Cloudflare IP ranges"
    else
        log_error "Failed to fetch Cloudflare IP ranges - aborting firewall update"
        _update_firewall_pretransaction_fail 1
        return $?
    fi

    local -a current_cidrs=() current_ipv4_cidrs=()
    local range
    while IFS= read -r range; do
        [[ -z "$range" ]] && continue
        if [[ "$range" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            current_cidrs+=("$range")
            current_ipv4_cidrs+=("$range")
        else
            log_error "Invalid Cloudflare IPv4 CIDR: ${range}"
            _update_firewall_pretransaction_fail 1
            return $?
        fi
    done < "$cf_ipv4_file"
    while IFS= read -r range; do
        [[ -z "$range" ]] && continue
        if [[ "$range" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]]; then
            current_cidrs+=("$range")
        else
            log_error "Invalid Cloudflare IPv6 CIDR: ${range}"
            _update_firewall_pretransaction_fail 1
            return $?
        fi
    done < "$cf_ipv6_file"

    (( ${#current_cidrs[@]} > 0 && ${#current_ipv4_cidrs[@]} > 0 )) || {
        log_error "No valid Cloudflare CIDRs were fetched; refusing firewall changes."
        _update_firewall_pretransaction_fail 1
        return $?
    }

    _ufw_validate_safety() {
        local verbose_status numbered_status
        verbose_status="$(firewall_ufw_status verbose)" || return $?
        if ! grep -q '^Status: active' <<< "$verbose_status"; then
            log_error "UFW is inactive; refusing periodic firewall mutation."
            log_error "Enable and verify UFW first, then rerun the Cloudflare firewall update."
            return 1
        fi
        numbered_status="$(firewall_ufw_status numbered)" || return $?
        firewall_ufw_validate_common_safety "$verbose_status" "$numbered_status" || return $?
    }

    _ufw_validate_safety || {
        local pretransaction_rc=$?
        _update_firewall_pretransaction_fail "$pretransaction_rc"
        return $?
    }

    # UFW's managed rules live in these files. Snapshot them before the first
    # mutation so a later UFW/Docker/cache failure can restore one coherent
    # firewall generation instead of leaving the defence layers drifted.
    local ufw_config_dir="${UFW_CONFIG_DIR:-/etc/ufw}"
    local ufw_snapshot_dir="" ufw_was_active=false rules_file
    local pre_mutation_verbose
    pre_mutation_verbose="$(firewall_ufw_status verbose)" || {
        local pretransaction_rc=$?
        _update_firewall_pretransaction_fail "$pretransaction_rc"
        return $?
    }
    grep -q '^Status: active' <<< "$pre_mutation_verbose" && ufw_was_active=true
    [[ -d "$ufw_config_dir" && -w "$ufw_config_dir" ]] || {
        log_error "UFW configuration directory is not writable: ${ufw_config_dir}"
        _update_firewall_pretransaction_fail 1
        return $?
    }
    ufw_snapshot_dir="$(mktemp -d -t vaultwarden-ufw.XXXXXXXXXX)" || {
        log_error "Could not allocate UFW rollback snapshot."
        _update_firewall_pretransaction_fail 1
        return $?
    }
    register_cleanup rm -rf "$ufw_snapshot_dir"
    for rules_file in user.rules user6.rules; do
        if [[ -e "$ufw_config_dir/$rules_file" || -L "$ufw_config_dir/$rules_file" ]]; then
            cp -a -- "$ufw_config_dir/$rules_file" "$ufw_snapshot_dir/$rules_file" || {
                log_error "Could not snapshot UFW managed rules: ${rules_file}"
                rm -rf "$ufw_snapshot_dir"
                _update_firewall_pretransaction_fail 1
                return $?
            }
        fi
    done

    local backup_v4="" mutation_rc=0 snapshot_rc=0 cache_tmp="" cache_commit_started=false

    backup_v4="$(mktemp -t vaultwarden-firewall.XXXXXXXXXX)" || {
        log_error "Could not allocate firewall rollback snapshot."
        rm -rf "$ufw_snapshot_dir"
        _update_firewall_pretransaction_fail 1
        return $?
    }
    register_cleanup rm -f "$backup_v4"
    iptables-save > "$backup_v4" || snapshot_rc=$?
    if (( snapshot_rc != 0 )); then
        log_error "Could not snapshot pre-update iptables state; refusing all firewall mutation."
        rm -f "$backup_v4"
        backup_v4=""
        rm -rf "$ufw_snapshot_dir"
        ufw_snapshot_dir=""
        _update_firewall_pretransaction_fail "$snapshot_rc"
        return $?
    fi

    _update_firewall_restore_ufw() {
        local restore_rc=0 file
        [[ -n "${ufw_snapshot_dir:-}" && -d "$ufw_snapshot_dir" ]] || return 0
        log_warn "Restoring UFW managed rules from rollback snapshot"
        for file in user.rules user6.rules; do
            if [[ -e "$ufw_snapshot_dir/$file" || -L "$ufw_snapshot_dir/$file" ]]; then
                cp -a -- "$ufw_snapshot_dir/$file" "$ufw_config_dir/$file" || restore_rc=$?
            else
                rm -f -- "$ufw_config_dir/$file" || restore_rc=$?
            fi
        done
        if [[ "$ufw_was_active" == "true" ]]; then
            ufw reload >/dev/null 2>&1 || restore_rc=$?
        fi
        if (( restore_rc != 0 )); then
            log_error "CRITICAL: UFW rollback restore failed (exit ${restore_rc})"
        fi
        return "$restore_rc"
    }

    _update_firewall_restore_iptables() {
        local restore_rc=0
        [[ -n "${backup_v4:-}" && -f "$backup_v4" ]] || return 0
        log_warn "Restoring iptables state after firewall update failure"
        iptables-restore < "$backup_v4" || restore_rc=$?
        if (( restore_rc != 0 )); then
            log_error "CRITICAL: iptables rollback restore failed (exit ${restore_rc})"
        fi
        return "$restore_rc"
    }

    _update_firewall_restore_outer_traps() {
        trap 'operation_release 130; perform_cleanup; exit 130' INT
        trap 'operation_release 143; perform_cleanup; exit 143' HUP TERM
    }

    _update_firewall_rollback_all() {
        local rollback_rc=0
        # UFW reload rewrites netfilter state, so restore its managed files first
        # and make the full iptables snapshot the final firewall write.
        _update_firewall_restore_ufw || rollback_rc=$?
        _update_firewall_restore_iptables || rollback_rc=$?
        return "$rollback_rc"
    }

    _update_firewall_fail_closed_after_rollback_error() {
        if ! firewall_fail_closed_stop_caddy; then
            log_error "CRITICAL: firewall rollback failed and Caddy shutdown could not be confirmed."
        fi
    }

    _update_firewall_fail() {
        local fail_rc="$1" rollback_rc=0
        _update_firewall_rollback_all || rollback_rc=$?
        if (( rollback_rc != 0 )); then
            _update_firewall_fail_closed_after_rollback_error
        elif [[ "$pre_update_docker_gate_exact" != "true" ]]; then
            _update_firewall_fail_closed_after_unproven_prior_gate
        fi
        _update_firewall_restore_outer_traps
        return "$fail_rc"
    }

    _update_firewall_signal_rollback() {
        local signal_rc="$1" rollback_rc=0
        # The atomic cache rename is the transaction commit point. Bash defers
        # traps until a foreground command returns, so a signal delivered while
        # mv succeeds sees the temp path gone and must not roll back the already
        # committed firewall generation.
        if [[ "$cache_commit_started" != "true" || -z "$cache_tmp" || -e "$cache_tmp" ]]; then
            _update_firewall_rollback_all || rollback_rc=$?
            if (( rollback_rc != 0 )); then
                _update_firewall_fail_closed_after_rollback_error
            elif [[ "$pre_update_docker_gate_exact" != "true" ]]; then
                _update_firewall_fail_closed_after_unproven_prior_gate
            fi
        fi
        operation_release "$signal_rc"
        perform_cleanup
        exit "$signal_rc"
    }
    trap '_update_firewall_signal_rollback 130' INT
    trap '_update_firewall_signal_rollback 143' HUP TERM

    local cidr label
    for cidr in "${current_cidrs[@]}"; do
        label="CF-IPv4"
        [[ "$cidr" == *:* ]] && label="CF-IPv6"
        firewall_ufw_ensure_web_range "$cidr" "$label" || {
            mutation_rc=$?
            _update_firewall_fail "$mutation_rc"
            return $?
        }
    done

    local numbered_status ufw_rc=0
    numbered_status="$(firewall_ufw_status numbered)" || {
        mutation_rc=$?
        _update_firewall_fail "$mutation_rc"
        return $?
    }
    local -a old_rule_nums=()
    mapfile -t old_rule_nums < <(firewall_ufw_collect_web_conflicts "$numbered_status" "${current_cidrs[@]}")
    if (( ${#old_rule_nums[@]} > 0 )); then
        mapfile -t old_rule_nums < <(printf '%s\n' "${old_rule_nums[@]}" | awk 'NF && !seen[$0]++' | sort -rn)
        local rule_num ufw_output
        for rule_num in "${old_rule_nums[@]}"; do
            ufw_rc=0
            ufw_output="$(ufw --force delete "$rule_num" 2>&1)" || ufw_rc=$?
            if (( ufw_rc != 0 )); then
                log_error "Failed to delete UFW rule ${rule_num} (exit ${ufw_rc}): ${ufw_output:-no output}"
                _update_firewall_fail "$ufw_rc"
                return $?
            fi
        done
    fi

    _ufw_validate_safety || {
        mutation_rc=$?
        _update_firewall_fail "$mutation_rc"
        return $?
    }
    local final_status final_numbered
    final_status="$(firewall_ufw_status normal)" || {
        mutation_rc=$?
        _update_firewall_fail "$mutation_rc"
        return $?
    }
    final_numbered="$(firewall_ufw_status numbered)" || {
        mutation_rc=$?
        _update_firewall_fail "$mutation_rc"
        return $?
    }
    if [[ -n "$(firewall_ufw_collect_web_conflicts "$final_numbered" "${current_cidrs[@]}")" ]]; then
        log_error "Non-Cloudflare UFW 80/443 rule remains after reconciliation."
        _update_firewall_fail 1
        return $?
    fi
    for cidr in "${current_cidrs[@]}"; do
        firewall_ufw_has_range_port "$final_status" "$cidr" 80 || {
            log_error "Final UFW verification missing ${cidr} -> 80/tcp"
            _update_firewall_fail 1
            return $?
        }
        firewall_ufw_has_range_port "$final_status" "$cidr" 443 || {
            log_error "Final UFW verification missing ${cidr} -> 443/tcp"
            _update_firewall_fail 1
            return $?
        }
    done

    if ! firewall_docker_ingress_is_exact "${current_ipv4_cidrs[@]}"; then
        firewall_reconcile_cloudflare_docker_ingress "${current_ipv4_cidrs[@]}" || mutation_rc=$?
        if (( mutation_rc != 0 )); then
            _update_firewall_fail "$mutation_rc"
            return $?
        fi
    fi

    # Publish the new CIDR generation atomically only after both firewall
    # layers verify. Keep rollback snapshots until the cache commit succeeds.
    local cf_cidr_cache="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/cf-cidrs.cache"
    local cache_dir
    cache_dir="$(dirname "$cf_cidr_cache")"
    mkdir -p "$cache_dir" || {
        log_error "Could not create Cloudflare CIDR cache directory: ${cache_dir}"
        _update_firewall_fail 1
        return $?
    }
    cache_tmp="$(mktemp -p "$cache_dir" .cf-cidrs.XXXXXXXXXX)" || {
        log_error "Could not allocate Cloudflare CIDR cache update."
        _update_firewall_fail 1
        return $?
    }
    if ! printf '%s\n' "${current_cidrs[@]}" > "$cache_tmp"; then
        log_error "Could not write Cloudflare CIDR cache update."
        rm -f "$cache_tmp"
        _update_firewall_fail 1
        return $?
    fi
    if ! chmod 640 "$cache_tmp"; then
        log_error "Could not set Cloudflare CIDR cache permissions."
        rm -f "$cache_tmp"
        _update_firewall_fail 1
        return $?
    fi
    cache_commit_started=true
    if ! mv -f -- "$cache_tmp" "$cf_cidr_cache"; then
        log_error "Could not publish Cloudflare CIDR cache update."
        cache_commit_started=false
        rm -f "$cache_tmp"
        _update_firewall_fail 1
        return $?
    fi

    rm -f "$backup_v4"
    backup_v4=""
    rm -rf "$ufw_snapshot_dir"
    ufw_snapshot_dir=""
    _update_firewall_restore_outer_traps

    log_success "Cloudflare UFW defence and Docker-published web ingress updated and verified"
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
