from pathlib import Path
import re


def replace_once(text, old, new, label):
    if old not in text:
        raise SystemExit(f"anchor not found: {label}")
    return text.replace(old, new, 1)


def replace_top_function(text, name, new, label=None):
    pattern = re.compile(rf"(?ms)^{re.escape(name)}\(\) \{{.*?^\}}\n")
    updated, count = pattern.subn(new.rstrip() + "\n", text, count=1)
    if count != 1:
        raise SystemExit(f"function replacement failed: {label or name} ({count})")
    return updated


# ---------------------------------------------------------------------------
# utilities/setup-firewall.sh
# ---------------------------------------------------------------------------
p = Path("utilities/setup-firewall.sh")
text = p.read_text()
text = replace_once(
    text,
    'source "${PROJECT_ROOT}/lib/defaults.sh"\n',
    'source "${PROJECT_ROOT}/lib/defaults.sh"\n# shellcheck source=../lib/firewall.sh\nsource "${PROJECT_ROOT}/lib/firewall.sh"\n',
    "source firewall library",
)
text = text.replace(
    "    Reconciles the Cloudflare-only UFW ingress contract and removes the OCI\n"
    "    FORWARD reject that can block Docker forwarding. Docker remains authoritative\n"
    "    for bridge forwarding, inter-network isolation, and container masquerading.\n",
    "    Reconciles defence-in-depth UFW rules, enforces Cloudflare-only access to\n"
    "    Docker-published TCP 80/443 in DOCKER-USER, and removes the OCI FORWARD\n"
    "    reject. Allowed traffic returns to Docker's own isolation/forwarding rules.\n",
    1,
)

helper_start = text.index("_ufw_status() {")
phase_start = text.index("_phase_ufw() {", helper_start)
ufw_helpers = r'''_ufw_status() {
    local mode="${1:-normal}" output rc=0
    case "$mode" in
        true|numbered) output="$(ufw status numbered 2>&1)" || rc=$? ;;
        verbose)       output="$(ufw status verbose 2>&1)" || rc=$? ;;
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
    local status="$1" cidr="$2" port="$3" escaped
    escaped="$(printf '%s' "$cidr" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
    grep -qE "^${port}/tcp([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+ALLOW([[:space:]]+IN)?[[:space:]].*${escaped}([[:space:]]|$)" <<< "$status"
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

_ufw_validate_safety() {
    local verbose_status numbered_status
    verbose_status="$(_ufw_status verbose)" || return $?
    numbered_status="$(_ufw_status numbered)" || return $?
    _ufw_default_incoming_fail_closed "$verbose_status" || return $?
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

    grep -qE "^${ssh_port}/tcp([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?" <<< "$status" || {
        log_error "UFW SSH rule for ${ssh_port}/tcp is missing after reconciliation."
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

'''
text = text[:helper_start] + ufw_helpers + text[phase_start:]

text = replace_once(
    text,
    '    ssh_port="${ssh_port:-22}"\n    log_info "Detected SSH port: ${ssh_port}"\n',
    '    ssh_port="${ssh_port:-22}"\n'
    '    if [[ "$ssh_port" == "80" || "$ssh_port" == "443" ]]; then\n'
    '        log_error "SSH port ${ssh_port}/tcp conflicts with managed Cloudflare web ingress."\n'
    '        log_error "Move SSH to a dedicated non-web port before running firewall reconciliation."\n'
    '        return 1\n'
    '    fi\n'
    '    log_info "Detected SSH port: ${ssh_port}"\n',
    "SSH web-port collision",
)
text = replace_once(
    text,
    '    local ufw_active=false status numbered_status\n    status="$(_ufw_status false)" || return $?\n    grep -q \'^Status: active\' <<< "$status" && ufw_active=true\n\n    ufw allow "${ssh_port}/tcp" >/dev/null\n\n    numbered_status="$(_ufw_status true)" || return $?\n',
    '    local ufw_active=false status numbered_status\n'
    '    _ufw_validate_safety || return $?\n'
    '    status="$(_ufw_status normal)" || return $?\n'
    '    grep -q \'^Status: active\' <<< "$status" && ufw_active=true\n\n'
    '    ufw allow "${ssh_port}/tcp" >/dev/null\n\n'
    '    numbered_status="$(_ufw_status numbered)" || return $?\n',
    "pre-mutation UFW safety proof",
)

preflight = r'''_docker_iptables_preflight() {
    firewall_docker_backend_preflight
}
'''
text = replace_top_function(text, "_docker_iptables_preflight", preflight)

needs = r'''_iptables_needs_reconciliation() {
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
'''
text = replace_top_function(text, "_iptables_needs_reconciliation", needs)

phase_iptables = r'''_phase_iptables() {
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
    trap 'operation_release 130; exit 130' INT
    trap 'operation_release 129; exit 129' HUP
    trap 'operation_release 143; exit 143' TERM
    log_success "Docker firewall runtime reconciled with Cloudflare-only published web ingress and no ACCEPT isolation shortcuts"
}
'''
text = replace_top_function(text, "_phase_iptables", phase_iptables)
p.write_text(text)


# ---------------------------------------------------------------------------
# utilities/maintenance-update-firewall.sh
# ---------------------------------------------------------------------------
p = Path("utilities/maintenance-update-firewall.sh")
text = p.read_text()
text = replace_once(
    text,
    'source "$PROJECT_ROOT/lib/storage.sh"\n',
    'source "$PROJECT_ROOT/lib/storage.sh"\n# shellcheck source=../lib/firewall.sh\nsource "$PROJECT_ROOT/lib/firewall.sh"\n',
    "updater source firewall library",
)
text = text.replace(
    "    Fetches the current Cloudflare IP ranges (IPv4 + IPv6) and reconciles UFW\n"
    "    so ports 80 and 443 are allowed only from those ranges. Conflicting public\n"
    "    ingress and retired managed Cloudflare rules are removed.\n",
    "    Fetches current Cloudflare IP ranges, reconciles defence-in-depth UFW\n"
    "    rules, and refreshes the Docker DOCKER-USER gate for published TCP 80/443.\n"
    "    Ambiguous host-firewall policy fails closed instead of being guessed.\n",
    1,
)

updater_func = r'''update_firewall_ranges() {
    if [[ "$UPDATE_FIREWALL" != "true" ]]; then log_info "Skipping firewall update"; return 0; fi
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would safely update Cloudflare firewall ranges"; return 0; fi
    if [[ "${CLOUDFLARE_PROXY_ENABLED:-false}" != "true" ]]; then
        log_info "Skipping Cloudflare IP range firewall update (CLOUDFLARE_PROXY_ENABLED is not 'true')"
        return 0
    fi

    require_root "$@"

    log_info "Safely updating Cloudflare IP ranges in UFW and Docker ingress filtering..."
    local cf_ipv4_file cf_ipv6_file
    cf_ipv4_file=$(mktemp -t cf_ipv4.XXXXXXXXXX)
    cf_ipv6_file=$(mktemp -t cf_ipv6.XXXXXXXXXX)
    register_cleanup rm -f "$cf_ipv4_file" "$cf_ipv6_file"
    if retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v4" -o "$cf_ipv4_file" && \
       retry_with_backoff 3 2 curl -sf --max-time 10 "https://www.cloudflare.com/ips-v6" -o "$cf_ipv6_file"; then
        log_success "Successfully fetched current Cloudflare IP ranges"
    else
        log_error "Failed to fetch Cloudflare IP ranges - aborting firewall update"
        return 1
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
            return 1
        fi
    done < "$cf_ipv4_file"
    while IFS= read -r range; do
        [[ -z "$range" ]] && continue
        if [[ "$range" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]]; then
            current_cidrs+=("$range")
        else
            log_error "Invalid Cloudflare IPv6 CIDR: ${range}"
            return 1
        fi
    done < "$cf_ipv6_file"

    (( ${#current_cidrs[@]} > 0 && ${#current_ipv4_cidrs[@]} > 0 )) || {
        log_error "No valid Cloudflare CIDRs were fetched; refusing firewall changes."
        return 1
    }

    # Refuse all mutations if the running Docker daemon is using an unsupported
    # backend. A stale DOCKER-USER chain alone is not proof of the active mode.
    firewall_docker_backend_preflight || return $?

    _ufw_status() {
        local mode="${1:-normal}" output rc=0
        case "$mode" in
            numbered) output="$(ufw status numbered 2>&1)" || rc=$? ;;
            verbose)  output="$(ufw status verbose 2>&1)" || rc=$? ;;
            normal)   output="$(ufw status 2>&1)" || rc=$? ;;
            *) return 2 ;;
        esac
        if (( rc != 0 )); then
            log_error "Unable to read UFW status (exit ${rc}): ${output:-no output}"
            return "$rc"
        fi
        printf '%s\n' "$output"
    }

    _ufw_has_range_port() {
        local status="$1" cidr="$2" port="$3" escaped
        escaped=$(printf '%s' "$cidr" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
        grep -qE "^${port}/tcp([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+ALLOW([[:space:]]+IN)?[[:space:]].*${escaped}([[:space:]]|$)" <<< "$status"
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
                    [[ "$desired_cidr" == "$cidr" ]] && { keep=true; break; }
                done
            fi
            [[ "$keep" == "true" ]] || printf '%s\n' "$rule_num"
        done <<< "$numbered_status"
    }

    _ufw_default_incoming_fail_closed() {
        local verbose_status="$1" defaults_file="${UFW_DEFAULTS_FILE:-/etc/default/ufw}" policy=""
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
            [[ "$policy" == "DROP" || "$policy" == "REJECT" ]] && return 0
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
            if [[ "$body" =~ ^[0-9]+/(tcp|udp)([[:space:]]+\(v6\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)[[:space:]]+IN([[:space:]]|$) ]]; then
                continue
            fi
            log_error "Ambiguous inbound UFW allow rule ${rule_num}: ${body}"
            log_error "Use explicit single-port/protocol rules; remove profiles, ranges, multi-port, all-port, or routed allows before retrying."
            return 1
        done <<< "$numbered_status"
    }

    _ufw_validate_safety() {
        local verbose_status numbered_status
        verbose_status="$(_ufw_status verbose)" || return $?
        numbered_status="$(_ufw_status numbered)" || return $?
        _ufw_default_incoming_fail_closed "$verbose_status" || return $?
        _ufw_reject_ambiguous_inbound_allows "$numbered_status" || return $?
    }

    _ufw_allow_range() {
        local cidr="$1" label="$2" status output rc=0
        status="$(_ufw_status normal)" || return $?
        if ! _ufw_has_range_port "$status" "$cidr" 80; then
            output="$(ufw allow proto tcp from "$cidr" to any port 80 comment "$label" 2>&1)" || rc=$?
            if (( rc != 0 )); then
                log_error "Failed to add UFW port 80 rule for ${cidr} (exit ${rc}): ${output:-no output}"
                return "$rc"
            fi
        fi
        status="$(_ufw_status normal)" || return $?
        if ! _ufw_has_range_port "$status" "$cidr" 443; then
            rc=0
            output="$(ufw allow proto tcp from "$cidr" to any port 443 comment "$label" 2>&1)" || rc=$?
            if (( rc != 0 )); then
                log_error "Failed to add UFW port 443 rule for ${cidr} (exit ${rc}): ${output:-no output}"
                return "$rc"
            fi
        fi
    }

    _ufw_validate_safety || return $?

    local cidr label
    for cidr in "${current_cidrs[@]}"; do
        label="CF-IPv4"
        [[ "$cidr" == *:* ]] && label="CF-IPv6"
        _ufw_allow_range "$cidr" "$label" || return $?
    done

    local numbered_status ufw_rc=0
    numbered_status="$(_ufw_status numbered)" || return $?
    local -a old_rule_nums=()
    mapfile -t old_rule_nums < <(_ufw_collect_conflicts "$numbered_status" "${current_cidrs[@]}")
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
        done
    fi

    _ufw_validate_safety || return $?
    local final_status final_numbered
    final_status="$(_ufw_status normal)" || return $?
    final_numbered="$(_ufw_status numbered)" || return $?
    if [[ -n "$(_ufw_collect_conflicts "$final_numbered" "${current_cidrs[@]}")" ]]; then
        log_error "Non-Cloudflare UFW 80/443 rule remains after reconciliation."
        return 1
    fi
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

    local backup_v4="" mutation_rc=0
    if ! firewall_docker_ingress_is_exact "${current_ipv4_cidrs[@]}"; then
        backup_v4="$(mktemp -t vaultwarden-firewall.XXXXXXXXXX)" || {
            log_error "Could not allocate Docker firewall rollback snapshot."
            return 1
        }
        register_cleanup rm -f "$backup_v4"
        if ! iptables-save > "$backup_v4"; then
            log_error "Could not snapshot iptables state; refusing Docker ingress mutation."
            rm -f "$backup_v4"
            return 1
        fi

        _update_firewall_restore_iptables() {
            local restore_rc=0
            [[ -n "${backup_v4:-}" && -f "$backup_v4" ]] || return 0
            log_warn "Restoring iptables state after Docker ingress update failure"
            iptables-restore < "$backup_v4" || restore_rc=$?
            rm -f "$backup_v4"
            backup_v4=""
            (( restore_rc == 0 )) || log_error "CRITICAL: iptables rollback restore failed (exit ${restore_rc})"
        }
        _update_firewall_signal_rollback() {
            local signal_rc="$1"
            _update_firewall_restore_iptables
            operation_release "$signal_rc"
            perform_cleanup
            exit "$signal_rc"
        }
        trap '_update_firewall_signal_rollback 130' INT
        trap '_update_firewall_signal_rollback 143' HUP TERM

        firewall_reconcile_cloudflare_docker_ingress "${current_ipv4_cidrs[@]}" || mutation_rc=$?
        if (( mutation_rc != 0 )); then
            _update_firewall_restore_iptables
            trap 'operation_release 130; perform_cleanup; exit 130' INT
            trap 'operation_release 143; perform_cleanup; exit 143' HUP TERM
            return "$mutation_rc"
        fi
        rm -f "$backup_v4"
        backup_v4=""
        trap 'operation_release 130; perform_cleanup; exit 130' INT
        trap 'operation_release 143; perform_cleanup; exit 143' HUP TERM
    fi

    local cf_cidr_cache="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/cf-cidrs.cache"
    mkdir -p "$(dirname "$cf_cidr_cache")"
    printf '%s\n' "${current_cidrs[@]}" > "$cf_cidr_cache"
    chmod 640 "$cf_cidr_cache"

    log_success "Cloudflare UFW defence and Docker-published web ingress updated and verified"
    return 0
}
'''
text = replace_top_function(text, "update_firewall_ranges", updater_func)
p.write_text(text)


# ---------------------------------------------------------------------------
# Compose: public Caddy bindings are IPv4-only because the supported backend
# gate is iptables/IPv4. This closes the Docker userland-proxy IPv6 escape path.
# ---------------------------------------------------------------------------
p = Path("docker-compose.yml.example")
text = p.read_text()
text = replace_once(text, '      - "80:80"\n      - "443:443"\n', '      - "0.0.0.0:80:80"\n      - "0.0.0.0:443:443"\n', "Caddy IPv4-only public binds")
text = text.replace(
    "  # Pinned subnet keeps this network deterministic and within RFC1918 space\n"
    "  # already allowed by the DOCKER-USER catch-all in setup-iptables.sh.\n",
    "  # Pinned subnet keeps this network deterministic. Public TCP 80/443 is\n"
    "  # filtered by the VW-CF-INGRESS DOCKER-USER gate before Docker forwarding.\n",
    1,
)
p.write_text(text)


# ---------------------------------------------------------------------------
# systemd units and installer
# ---------------------------------------------------------------------------
p = Path("systemd/vaultwarden-iptables.service")
text = p.read_text()
text = replace_once(
    text,
    'WorkingDirectory=/opt/vaultwarden-scripts\n',
    'WorkingDirectory=/opt/vaultwarden-scripts\nEnvironmentFile=-/etc/vaultwarden/vaultwarden.env\n',
    "iptables EnvironmentFile",
)
p.write_text(text)

p = Path("systemd/vaultwarden-firewall-update.service")
text = p.read_text()
text = text.replace('After=network-online.target\nWants=network-online.target\n', 'After=network-online.target docker.service\nWants=network-online.target docker.service\n', 1)
p.write_text(text)

p = Path("utilities/setup-systemd.sh")
text = p.read_text()
old = '''# Timers skip identity checks, while iptables skips data-volume drop-ins.
_ROOT_REQUIRED_UNITS=("${COPIED_SERVICES[@]}" "$STARTUP_SERVICE")
_VW_DROPIN_UNITS=()
for unit in "${COPIED_SERVICES[@]}"; do
    [[ "$unit" == "vaultwarden-iptables.service" ]] || _VW_DROPIN_UNITS+=("$unit")
done
_VW_DROPIN_UNITS+=("${TIMERS[@]}")
unset unit
'''
new = '''# Timers skip identity checks. All managed units receive data-volume mount
# ordering; vaultwarden-iptables.service is read-only and is special-cased below
# so it does not receive a state-directory write grant.
_ROOT_REQUIRED_UNITS=("${COPIED_SERVICES[@]}" "$STARTUP_SERVICE")
_VW_DROPIN_UNITS=("${COPIED_SERVICES[@]}" "${TIMERS[@]}")
'''
text = replace_once(text, old, new, "systemd drop-in unit set")
text = replace_once(
    text,
    '        if [[ "$unit" == *.service ]]; then\n',
    '        if [[ "$unit" == *.service && "$unit" != "vaultwarden-iptables.service" ]]; then\n',
    "iptables read-only drop-in special case",
)
p.write_text(text)
