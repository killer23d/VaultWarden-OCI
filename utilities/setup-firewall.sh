#!/usr/bin/env bash
# utilities/setup-firewall.sh — Configures VaultWarden-OCI UFW and Docker firewall reconciliation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/log.sh
source "${PROJECT_ROOT}/lib/log.sh"
# shellcheck source=../lib/config.sh
source "${PROJECT_ROOT}/lib/config.sh"
# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
# shellcheck source=../lib/operations.sh
source "${PROJECT_ROOT}/lib/operations.sh"
# shellcheck source=../lib/defaults.sh
source "${PROJECT_ROOT}/lib/defaults.sh"
# shellcheck source=../lib/firewall.sh
source "${PROJECT_ROOT}/lib/firewall.sh"

show_help() {
    cat <<'HELP'
VaultWarden-OCI Firewall Configuration

USAGE:
    sudo utilities/setup-firewall.sh [--phase ufw|iptables|all] [OPTIONS]

DESCRIPTION:
    Reconciles defence-in-depth UFW rules, enforces Cloudflare-only access to
    Docker-published TCP 80/443 in DOCKER-USER, and removes the OCI FORWARD
    reject. Allowed traffic returns to Docker's own isolation/forwarding rules.

OPTIONS:
    --phase ufw|iptables|all   Phase to run (default: all)
    --auto                     Non-interactive mode
    --dry-run                  Preview actions without executing
    --force                    Reconcile even when the current state appears ready
    --help, -h                 Show this help
    --version, -V              Print the VaultWarden-OCI version and exit

NOTES:
    The iptables phase supports Docker's iptables firewall backend only. Native
    Docker nftables firewall mode or disabled Docker iptables management is not
    supported by this project.

    vaultwarden-iptables.service owns boot-time runtime reconciliation. This
    script does not install firewall packages or persist rules to disk.

EXAMPLES:
    sudo utilities/setup-firewall.sh
    sudo utilities/setup-firewall.sh --dry-run
    sudo utilities/setup-firewall.sh --phase ufw
HELP
}

_require_cli_value() {
    local opt="$1" value="${2-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        log_error "Option '$opt' requires a value."
        show_help
        exit 1
    fi
}

PHASE="all"
AUTO_MODE=false
DRY_RUN=false
FORCE=false
ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)      _require_cli_value "$1" "${2-}"; PHASE="$2"; shift 2 ;;
        --auto)       AUTO_MODE=true; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --force)      FORCE=true; shift ;;
        --help|-h)    show_help; exit 0 ;;
        --version|-V) print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0 ;;
        help)         show_help; exit 0 ;;
        *)            log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

case "$PHASE" in
    ufw|iptables|all) ;;
    *) log_error "--phase must be ufw|iptables|all (got: '$PHASE')"; exit 1 ;;
esac

_ufw_status() {
    local mode="${1:-normal}" output rc=0
    case "$mode" in
        true|numbered) output="$(ufw status numbered 2>&1)" || rc=$? ;;
        verbose)       output="$(ufw status verbose 2>&1)" || rc=$? ;;
        added)         output="$(ufw show added 2>&1)" || rc=$? ;;
        false|normal)  output="$(ufw status 2>&1)" || rc=$? ;;
        *)
            log_error "Unknown UFW status mode: ${mode}"
            return 2
            ;;
    esac
    if (( rc != 0 )); then
        log_error "Unable to read UFW status (exit ${rc}): ${output:-no output}"
        return "$rc"
    fi
    printf '%s\n' "$output"
}

_ufw_has_range_port() {
    local status="$1" cidr="$2" port="$3" line token i
    local -a fields=()

    while IFS= read -r line; do
        fields=()
        read -ra fields <<< "$line"
        (( ${#fields[@]} >= 4 )) || continue
        [[ "${fields[0]}" == "${port}/tcp" ]] || continue

        i=1
        if [[ "${fields[$i]:-}" == "(v6)" ]]; then
            i=$((i + 1))
        fi
        if [[ "${fields[$i]:-}" == "on" ]]; then
            i=$((i + 2))
        fi
        [[ "${fields[$i]:-}" == "ALLOW" ]] || continue
        i=$((i + 1))
        if [[ "${fields[$i]:-}" == "IN" ]]; then
            i=$((i + 1))
        fi

        for (( ; i<${#fields[@]}; i++ )); do
            token="${fields[$i]}"
            [[ "$token" == \#* ]] && break
            token="${token%#*}"
            [[ "$token" == "$cidr" ]] && return 0
        done
    done <<< "$status"
    return 1
}

_ufw_has_admin_port() {
    local status="$1" port="$2"
    # Preserve any explicit single-port TCP administrator rule, including a
    # source-restricted ALLOW/LIMIT. PR4 must not widen an operator's SSH ACL.
    grep -qE "^${port}/tcp([[:space:]]+\(v6\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?[[:space:]]+[^[:space:]#]+([[:space:]]|$)" <<< "$status"
}

_ufw_line_cidr() {
    local line="$1" word
    local -a words=()
    read -ra words <<< "$line"
    for word in "${words[@]}"; do
        [[ "$word" == \#* ]] && break
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
    local line rule_num cidr keep desired_cidr action

    while IFS= read -r line; do
        [[ "$line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+(80|443)(/tcp)?([[:space:]]+\(v6\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?([[:space:]]|$) ]] || continue
        rule_num="${BASH_REMATCH[1]}"
        action="${BASH_REMATCH[6]}"
        if [[ -z "${BASH_REMATCH[3]}" || "$action" != "ALLOW" ]]; then
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

_ufw_default_incoming_fail_closed() {
    local verbose_status="$1"
    local defaults_file="${UFW_DEFAULTS_FILE:-/etc/default/ufw}" policy=""

    if grep -Eqi '^Default:[[:space:]]+(deny|reject)[[:space:]]+\(incoming\)' <<< "$verbose_status"; then
        return 0
    fi

    if grep -Eq '^Status:[[:space:]]+inactive' <<< "$verbose_status" && [[ -r "$defaults_file" ]]; then
        policy="$(awk -F= '
            $1 ~ /^[[:space:]]*DEFAULT_INPUT_POLICY[[:space:]]*$/ {
                gsub(/[[:space:]\"'\''\r]/, "", $2)
                print toupper($2)
                exit
            }
        ' "$defaults_file")"
        case "$policy" in
            DROP|REJECT) return 0 ;;
        esac
    fi

    log_error "UFW default incoming policy is not provably fail-closed (deny/reject)."
    log_error "Remediation: sudo ufw default deny incoming; then review 'sudo ufw status verbose'."
    return 1
}

_ufw_reject_ambiguous_inbound_allows() {
    local numbered_status="$1" line rule_num body
    while IFS= read -r line; do
        [[ "$line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+(.*)$ ]] || continue
        rule_num="${BASH_REMATCH[1]}"
        body="${BASH_REMATCH[2]}"
        [[ "$body" =~ [[:space:]](ALLOW|LIMIT)[[:space:]]+(IN|FWD)([[:space:]]|$) ]] || continue

        # A single numeric port with an explicit protocol is unambiguous. Literal
        # web-port rows are handled separately by _ufw_collect_conflicts.
        if [[ "$body" =~ ^[0-9]+/(tcp|udp)([[:space:]]+\(v6\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)[[:space:]]+IN([[:space:]]|$) ]]; then
            continue
        fi

        log_error "Ambiguous inbound UFW allow rule ${rule_num}: ${body}"
        log_error "Use explicit single-port/protocol rules; remove application profiles, port ranges, multi-port, all-port, or routed allows before retrying."
        return 1
    done <<< "$numbered_status"
}

_ufw_reject_hidden_inactive_permissive_rules() {
    local verbose_status="$1" added line
    grep -Eq '^Status:[[:space:]]+inactive' <<< "$verbose_status" || return 0

    added="$(_ufw_status added)" || return $?
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*ufw[[:space:]]+ ]] || continue
        if [[ "$line" =~ (^|[[:space:]])(allow|limit)([[:space:]]|$) ]] || \
           [[ "$line" =~ (^|[[:space:]])route[[:space:]]+(allow|limit)([[:space:]]|$) ]]; then
            log_error "Inactive UFW has preconfigured permissive rules that cannot be safely proven before enablement: ${line}"
            log_error "Review 'sudo ufw show added'; enable/review UFW manually or reset the stale rules before retrying setup."
            return 1
        fi
    done <<< "$added"
    return 0
}

_ufw_validate_safety() {
    local verbose_status numbered_status
    verbose_status="$(_ufw_status verbose)" || return $?
    numbered_status="$(_ufw_status numbered)" || return $?
    _ufw_default_incoming_fail_closed "$verbose_status" || return $?
    _ufw_reject_hidden_inactive_permissive_rules "$verbose_status" || return $?
    _ufw_reject_ambiguous_inbound_allows "$numbered_status" || return $?
}

_ufw_delete_rules() {
    local -a rule_nums=("$@")
    (( ${#rule_nums[@]} > 0 )) || return 0
    mapfile -t rule_nums < <(printf '%s\n' "${rule_nums[@]}" | awk 'NF && !seen[$0]++' | sort -rn)
    local rule_num output rc=0
    for rule_num in "${rule_nums[@]}"; do
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry_run "Would delete conflicting UFW rule ${rule_num}"
            continue
        fi
        rc=0
        output="$(ufw --force delete "$rule_num" 2>&1)" || rc=$?
        if (( rc != 0 )); then
            log_error "Failed to delete UFW rule ${rule_num} (exit ${rc}): ${output:-no output}"
            return "$rc"
        fi
    done
}

_ufw_ensure_range() {
    local cidr="$1" label="$2" status output rc=0
    status="$(_ufw_status normal)" || return $?
    if ! _ufw_has_range_port "$status" "$cidr" 80; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry_run "Would allow Cloudflare ${cidr} to 80/tcp"
        else
            output="$(ufw allow proto tcp from "$cidr" to any port 80 comment "$label" 2>&1)" || rc=$?
            if (( rc != 0 )); then
                log_error "Failed to add UFW port 80 rule for ${cidr} (exit ${rc}): ${output:-no output}"
                return "$rc"
            fi
        fi
    fi

    status="$(_ufw_status normal)" || return $?
    if ! _ufw_has_range_port "$status" "$cidr" 443; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry_run "Would allow Cloudflare ${cidr} to 443/tcp"
        else
            rc=0
            output="$(ufw allow proto tcp from "$cidr" to any port 443 comment "$label" 2>&1)" || rc=$?
            if (( rc != 0 )); then
                log_error "Failed to add UFW port 443 rule for ${cidr} (exit ${rc}): ${output:-no output}"
                return "$rc"
            fi
        fi
    fi
}

_ufw_verify_exact() {
    local ssh_port="$1"
    shift
    local -a desired=("$@")
    local status numbered_status verbose_status cidr
    status="$(_ufw_status normal)" || return $?
    numbered_status="$(_ufw_status numbered)" || return $?
    verbose_status="$(_ufw_status verbose)" || return $?

    grep -q '^Status: active' <<< "$status" || {
        log_error "UFW is not active after reconciliation."
        return 1
    }
    _ufw_default_incoming_fail_closed "$verbose_status" || return $?
    _ufw_reject_ambiguous_inbound_allows "$numbered_status" || return $?

    _ufw_has_admin_port "$status" "$ssh_port" || {
        log_error "Explicit UFW SSH ALLOW/LIMIT rule for ${ssh_port}/tcp is missing after reconciliation."
        return 1
    }

    if [[ -n "$(_ufw_collect_conflicts "$numbered_status" "${desired[@]}")" ]]; then
        log_error "Conflicting UFW 80/443 rules remain after reconciliation."
        return 1
    fi

    for cidr in "${desired[@]}"; do
        _ufw_has_range_port "$status" "$cidr" 80 || {
            log_error "Missing Cloudflare UFW rule: ${cidr} -> 80/tcp"
            return 1
        }
        _ufw_has_range_port "$status" "$cidr" 443 || {
            log_error "Missing Cloudflare UFW rule: ${cidr} -> 443/tcp"
            return 1
        }
    done
    return 0
}

_phase_ufw() {
    local ssh_port
    ssh_port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
    if [[ -z "$ssh_port" ]]; then
        ssh_port="$(awk '/^Port[[:space:]]/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
    fi
    ssh_port="${ssh_port:-22}"
    if [[ "$ssh_port" == "80" || "$ssh_port" == "443" ]]; then
        log_error "SSH port ${ssh_port}/tcp conflicts with managed Cloudflare web ingress."
        log_error "Move SSH to a dedicated non-web port before running firewall reconciliation."
        return 1
    fi
    log_info "Detected SSH port: ${ssh_port}"

    local cf_ipv4_url="https://www.cloudflare.com/ips-v4"
    local cf_ipv6_url="https://www.cloudflare.com/ips-v6"
    local cf_cidr_cache="${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}/cf-cidrs.cache"
    local ipv4_list="" ipv6_list="" cf_fetch_failed=false
    local -a cf_cidrs=() validated_cidrs=()

    log_info "Fetching Cloudflare CIDR lists for firewall restriction..."
    ipv4_list="$(curl -fsSL --max-time 15 "$cf_ipv4_url" 2>/dev/null)" || cf_fetch_failed=true
    ipv6_list="$(curl -fsSL --max-time 15 "$cf_ipv6_url" 2>/dev/null)" || cf_fetch_failed=true

    if [[ "$cf_fetch_failed" == "false" && -n "$ipv4_list" && -n "$ipv6_list" ]]; then
        local cidr
        while IFS= read -r cidr; do
            [[ -z "$cidr" || "$cidr" == \#* ]] || cf_cidrs+=("$cidr")
        done <<< "$ipv4_list"
        while IFS= read -r cidr; do
            [[ -z "$cidr" || "$cidr" == \#* ]] || cf_cidrs+=("$cidr")
        done <<< "$ipv6_list"
        log_info "Fetched ${#cf_cidrs[@]} Cloudflare CIDRs"
    elif [[ -s "$cf_cidr_cache" ]]; then
        if [[ -n "$(find "$cf_cidr_cache" -mtime +7 2>/dev/null)" ]]; then
            log_warn "Cloudflare CIDR cache is older than 7 days — treating as stale."
            log_error "Could not fetch fresh Cloudflare CIDR lists and cache is expired."
            log_error "SECURITY: Refusing to configure ports 80/443 with stale CIDR data."
            return 1
        fi
        log_warn "Could not fetch Cloudflare CIDR lists — using cached copy: $cf_cidr_cache"
        while IFS= read -r cidr; do
            [[ -z "$cidr" || "$cidr" == \#* ]] || cf_cidrs+=("$cidr")
        done < "$cf_cidr_cache"
        log_warn "SECURITY: Rules are based on cached CIDRs. Re-run when network access is restored."
    else
        log_error "Could not fetch Cloudflare CIDR lists and no recent cache is available."
        log_error "SECURITY: Refusing to configure ports 80/443 without valid CIDR data."
        return 1
    fi

    local cidr
    for cidr in "${cf_cidrs[@]}"; do
        if [[ "$cidr" =~ ^[0-9a-fA-F.:]+/[0-9]+$ ]]; then
            validated_cidrs+=("$cidr")
        else
            log_error "Invalid Cloudflare CIDR entry: ${cidr}"
            return 1
        fi
    done
    (( ${#validated_cidrs[@]} > 0 )) || {
        log_error "No valid Cloudflare CIDRs found."
        return 1
    }

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Would reconcile UFW to Cloudflare-only 80/443 ingress for ${#validated_cidrs[@]} CIDRs"
        return 0
    fi

    local ufw_active=false status numbered_status
    _ufw_validate_safety || return $?
    status="$(_ufw_status normal)" || return $?
    grep -q '^Status: active' <<< "$status" && ufw_active=true

    if ! _ufw_has_admin_port "$status" "$ssh_port"; then
        local ssh_output ssh_rc=0
        ssh_output="$(ufw allow "${ssh_port}/tcp" 2>&1)" || ssh_rc=$?
        if (( ssh_rc != 0 )); then
            log_error "Failed to add default UFW SSH rule for ${ssh_port}/tcp (exit ${ssh_rc}): ${ssh_output:-no output}"
            return "$ssh_rc"
        fi
        log_info "Added default UFW SSH rule for ${ssh_port}/tcp because no explicit SSH rule existed."
    else
        log_info "Preserving existing explicit UFW SSH rule for ${ssh_port}/tcp."
    fi

    numbered_status="$(_ufw_status numbered)" || return $?
    local -a conflicts=()
    mapfile -t conflicts < <(_ufw_collect_conflicts "$numbered_status" "${validated_cidrs[@]}")
    _ufw_delete_rules "${conflicts[@]}" || return $?

    for cidr in "${validated_cidrs[@]}"; do
        local label="CF-IPv4"
        [[ "$cidr" == *:* ]] && label="CF-IPv6"
        _ufw_ensure_range "$cidr" "$label" || return $?
    done

    [[ "$ufw_active" == "true" ]] || ufw --force enable >/dev/null
    _ufw_verify_exact "$ssh_port" "${validated_cidrs[@]}" || return $?

    mkdir -p "$(dirname "$cf_cidr_cache")"
    printf '%s\n' "${validated_cidrs[@]}" > "$cf_cidr_cache"
    chmod 640 "$cf_cidr_cache"

    log_success "UFW reconciled: 80/443 are restricted to ${#validated_cidrs[@]} Cloudflare CIDRs"
}

_docker_iptables_preflight() {
    firewall_docker_backend_preflight
}

_iptables_rule_state() {
    local table="$1" chain="$2"
    shift 2
    local rc=0
    iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) return 0 ;;
        1) return 1 ;;
        *) return "$rc" ;;
    esac
}

_iptables_delete_all_exact() {
    local table="$1" chain="$2" description="$3"
    shift 3
    local rc=0 count=0
    while true; do
        rc=0
        _iptables_rule_state "$table" "$chain" "$@" || rc=$?
        case "$rc" in
            0) ;;
            1) break ;;
            *) log_error "Could not inspect ${description} (iptables exit ${rc})."; return "$rc" ;;
        esac
        rc=0
        iptables -t "$table" -D "$chain" "$@" || rc=$?
        if (( rc != 0 )); then
            log_error "Failed to remove ${description} (iptables exit ${rc})."
            return "$rc"
        fi
        count=$((count + 1))
    done
    (( count == 0 )) || log_success "Removed ${description} (x${count})"
}

_iptables_needs_reconciliation() {
    local -a cf_ipv4=("$@")
    local rc=0 cidr

    if ! firewall_docker_ingress_is_exact "${cf_ipv4[@]}"; then
        return 0
    fi

    _iptables_rule_state filter FORWARD -j REJECT --reject-with icmp-host-prohibited || rc=$?
    [[ "$rc" -eq 0 ]] && return 0
    [[ "$rc" -eq 1 ]] || return "$rc"

    for cidr in 172.21.0.0/16 172.22.0.0/16 172.23.0.0/16 172.21.0.0/28 172.22.0.0/28 172.23.0.0/28; do
        rc=0
        _iptables_rule_state filter DOCKER-USER -s "$cidr" -j ACCEPT || rc=$?
        [[ "$rc" -eq 0 ]] && return 0
        [[ "$rc" -eq 1 ]] || return "$rc"
        rc=0
        _iptables_rule_state nat POSTROUTING -s "$cidr" '!' -o docker0 -j MASQUERADE || rc=$?
        [[ "$rc" -eq 0 ]] && return 0
        [[ "$rc" -eq 1 ]] || return "$rc"
    done
    return 1
}

_phase_iptables() {
    _docker_iptables_preflight || return $?

    local -a cf_ipv4=()
    firewall_load_cached_cloudflare_ipv4 cf_ipv4 || return $?

    local rc=0
    _iptables_needs_reconciliation "${cf_ipv4[@]}" || rc=$?
    if [[ "$rc" -eq 1 && "$FORCE" != "true" ]]; then
        log_info "Docker firewall runtime and Cloudflare ingress gate are already reconciled; skipping mutation."
        return 0
    fi
    if [[ "$rc" -eq 1 ]]; then
        log_info "Force reconciliation requested; rebuilding the managed Docker ingress gate."
        rc=0
    fi
    if [[ "$rc" -ne 0 ]]; then
        log_error "Could not determine whether firewall remediation is required (iptables exit ${rc})."
        return "$rc"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Would enforce Cloudflare-only Docker-published TCP 80/443 with RETURN/DROP rules"
        log_dry_run "Would remove the OCI FORWARD reject and legacy VaultWarden forwarding/NAT exceptions if present"
        return 0
    fi

    local backup_dir="${TMPDIR:-/run}" backup_v4
    [[ -d "$backup_dir" && -w "$backup_dir" ]] || {
        log_error "Firewall rollback directory is not writable: ${backup_dir}"
        return 1
    }
    backup_v4="$(mktemp -p "$backup_dir" vaultwarden-iptables.XXXXXX)" || {
        log_error "Could not allocate an iptables rollback snapshot."
        return 1
    }
    if ! iptables-save > "$backup_v4"; then
        log_error "Could not snapshot current iptables state; refusing firewall mutation."
        rm -f "$backup_v4"
        return 1
    fi

    _restore_snapshot() {
        local restore_rc=0
        [[ -n "${backup_v4:-}" && -f "$backup_v4" ]] || return 0
        log_rollback "Restoring iptables rules from rollback snapshot"
        iptables-restore < "$backup_v4" || restore_rc=$?
        rm -f "$backup_v4"
        backup_v4=""
        if (( restore_rc != 0 )); then
            log_error "CRITICAL: iptables rollback restore failed (exit ${restore_rc})"
        fi
    }

    _iptables_signal_rollback() {
        local signal_rc="$1"
        _restore_snapshot
        firewall_fail_closed_stop_caddy || log_error "CRITICAL: signal rollback could not confirm fail-closed Caddy shutdown."
        exit "$signal_rc"
    }
    trap '_iptables_signal_rollback 130' INT
    trap '_iptables_signal_rollback 129' HUP
    trap '_iptables_signal_rollback 143' TERM

    if firewall_reconcile_cloudflare_docker_ingress "${cf_ipv4[@]}"; then
        :
    else
        rc=$?
        _restore_snapshot
        return "$rc"
    fi

    if _iptables_delete_all_exact filter FORWARD "OCI default FORWARD REJECT rule" \
        -j REJECT --reject-with icmp-host-prohibited; then
        :
    else
        rc=$?
        _restore_snapshot
        return "$rc"
    fi

    local cidr
    for cidr in 172.21.0.0/16 172.22.0.0/16 172.23.0.0/16 172.21.0.0/28 172.22.0.0/28 172.23.0.0/28; do
        if _iptables_delete_all_exact filter DOCKER-USER "legacy source-only DOCKER-USER ACCEPT for ${cidr}" \
            -s "$cidr" -j ACCEPT; then
            :
        else
            rc=$?
            _restore_snapshot
            return "$rc"
        fi
        if _iptables_delete_all_exact nat POSTROUTING "legacy VaultWarden MASQUERADE for ${cidr}" \
            -s "$cidr" '!' -o docker0 -j MASQUERADE; then
            :
        else
            rc=$?
            _restore_snapshot
            return "$rc"
        fi
    done

    if ! firewall_docker_ingress_is_exact "${cf_ipv4[@]}"; then
        log_error "Final Docker Cloudflare ingress verification failed."
        _restore_snapshot
        return 1
    fi

    rm -f "$backup_v4"
    backup_v4=""
    # Keep fail-closed signal handling active through the post-iptables
    # Caddy runtime normalization performed by main().
    trap '_setup_firewall_signal_fail_closed 130' INT
    trap '_setup_firewall_signal_fail_closed 129' HUP
    trap '_setup_firewall_signal_fail_closed 143' TERM
    log_success "Docker firewall runtime reconciled with Cloudflare-only published web ingress and no ACCEPT isolation shortcuts"
}

_setup_firewall_signal_fail_closed() {
    local signal_rc="$1"
    firewall_fail_closed_stop_caddy || log_error "CRITICAL: interrupted firewall setup could not confirm fail-closed Caddy shutdown."
    operation_release "$signal_rc"
    exit "$signal_rc"
}

main() {
    require_root "${ORIGINAL_ARGS[@]}"
    if [[ "$DRY_RUN" != "true" ]]; then
        local ops_policy="fail"
        if [[ "$AUTO_MODE" == "true" || ! -t 0 || ! -t 1 ]]; then
            ops_policy="skip"
        fi
        operation_acquire --id setup --label "Setup" --non-interactive "$ops_policy" || exit $?
        _setup_firewall_cleanup() {
            local exit_rc=$?
            operation_release "$exit_rc"
            return "$exit_rc"
        }
        trap _setup_firewall_cleanup EXIT
        trap '_setup_firewall_signal_fail_closed 130' INT
        trap '_setup_firewall_signal_fail_closed 129' HUP
        trap '_setup_firewall_signal_fail_closed 143' TERM
        operation_set_phase "firewall" "Firewall setup"
    fi

    local rc=0 stop_rc=0
    case "$PHASE" in
        ufw)
            _phase_ufw || rc=$?
            ;;
        iptables)
            _phase_iptables || rc=$?
            ;;
        all)
            _phase_ufw || rc=$?
            if (( rc == 0 )); then
                _phase_iptables || rc=$?
            fi
            ;;
    esac

    if (( rc == 0 )) && [[ "$DRY_RUN" != "true" ]] && [[ "$PHASE" != "ufw" ]]; then
        firewall_normalize_caddy_runtime_contract || rc=$?
    fi

    if (( rc != 0 )) && [[ "$DRY_RUN" != "true" ]]; then
        firewall_fail_closed_stop_caddy || stop_rc=$?
        if (( stop_rc != 0 )); then
            log_error "CRITICAL: firewall setup failed and fail-closed Caddy shutdown could not be confirmed."
        fi
    fi
    return "$rc"
}

main
