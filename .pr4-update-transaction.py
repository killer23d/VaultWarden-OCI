from pathlib import Path

p = Path('utilities/maintenance-update-firewall.sh')
t = p.read_text()
start_marker = '    _ufw_validate_safety || return $?\n\n    local cidr label\n'
end_marker = '    log_success "Cloudflare UFW defence and Docker-published web ingress updated and verified"\n'
start = t.find(start_marker)
end = t.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit('updater transaction anchors not found')
end += len(end_marker)

block = r'''    _ufw_validate_safety || return $?

    # UFW's managed rules live in these files. Snapshot them before the first
    # mutation so a later UFW/Docker/cache failure can restore one coherent
    # firewall generation instead of leaving the defence layers drifted.
    local ufw_config_dir="${UFW_CONFIG_DIR:-/etc/ufw}"
    local ufw_snapshot_dir="" ufw_was_active=false rules_file
    local pre_mutation_verbose
    pre_mutation_verbose="$(_ufw_status verbose)" || return $?
    grep -q '^Status: active' <<< "$pre_mutation_verbose" && ufw_was_active=true
    [[ -d "$ufw_config_dir" && -w "$ufw_config_dir" ]] || {
        log_error "UFW configuration directory is not writable: ${ufw_config_dir}"
        return 1
    }
    ufw_snapshot_dir="$(mktemp -d -t vaultwarden-ufw.XXXXXXXXXX)" || {
        log_error "Could not allocate UFW rollback snapshot."
        return 1
    }
    register_cleanup rm -rf "$ufw_snapshot_dir"
    for rules_file in user.rules user6.rules; do
        if [[ -e "$ufw_config_dir/$rules_file" || -L "$ufw_config_dir/$rules_file" ]]; then
            cp -a -- "$ufw_config_dir/$rules_file" "$ufw_snapshot_dir/$rules_file" || {
                log_error "Could not snapshot UFW managed rules: ${rules_file}"
                rm -rf "$ufw_snapshot_dir"
                return 1
            }
        fi
    done

    local backup_v4="" mutation_rc=0

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
        _update_firewall_restore_iptables || rollback_rc=$?
        _update_firewall_restore_ufw || rollback_rc=$?
        return "$rollback_rc"
    }

    _update_firewall_fail() {
        local fail_rc="$1"
        _update_firewall_rollback_all || true
        _update_firewall_restore_outer_traps
        return "$fail_rc"
    }

    _update_firewall_signal_rollback() {
        local signal_rc="$1"
        _update_firewall_rollback_all || true
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
        _ufw_allow_range "$cidr" "$label" || {
            mutation_rc=$?
            _update_firewall_fail "$mutation_rc"
            return $?
        }
    done

    local numbered_status ufw_rc=0
    numbered_status="$(_ufw_status numbered)" || {
        mutation_rc=$?
        _update_firewall_fail "$mutation_rc"
        return $?
    }
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
    final_status="$(_ufw_status normal)" || {
        mutation_rc=$?
        _update_firewall_fail "$mutation_rc"
        return $?
    }
    final_numbered="$(_ufw_status numbered)" || {
        mutation_rc=$?
        _update_firewall_fail "$mutation_rc"
        return $?
    }
    if [[ -n "$(_ufw_collect_conflicts "$final_numbered" "${current_cidrs[@]}")" ]]; then
        log_error "Non-Cloudflare UFW 80/443 rule remains after reconciliation."
        _update_firewall_fail 1
        return $?
    fi
    for cidr in "${current_cidrs[@]}"; do
        _ufw_has_range_port "$final_status" "$cidr" 80 || {
            log_error "Final UFW verification missing ${cidr} -> 80/tcp"
            _update_firewall_fail 1
            return $?
        }
        _ufw_has_range_port "$final_status" "$cidr" 443 || {
            log_error "Final UFW verification missing ${cidr} -> 443/tcp"
            _update_firewall_fail 1
            return $?
        }
    done

    if ! firewall_docker_ingress_is_exact "${current_ipv4_cidrs[@]}"; then
        backup_v4="$(mktemp -t vaultwarden-firewall.XXXXXXXXXX)" || {
            log_error "Could not allocate Docker firewall rollback snapshot."
            _update_firewall_fail 1
            return $?
        }
        register_cleanup rm -f "$backup_v4"
        if ! iptables-save > "$backup_v4"; then
            log_error "Could not snapshot iptables state; refusing Docker ingress mutation."
            rm -f "$backup_v4"
            backup_v4=""
            _update_firewall_fail 1
            return $?
        fi

        firewall_reconcile_cloudflare_docker_ingress "${current_ipv4_cidrs[@]}" || mutation_rc=$?
        if (( mutation_rc != 0 )); then
            _update_firewall_fail "$mutation_rc"
            return $?
        fi
    fi

    # Publish the new CIDR generation atomically only after both firewall
    # layers verify. Keep rollback snapshots until the cache commit succeeds.
    local cf_cidr_cache="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/cf-cidrs.cache"
    local cache_dir cache_tmp=""
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
    if ! chmod 640 "$cache_tmp" || ! mv -f -- "$cache_tmp" "$cf_cidr_cache"; then
        log_error "Could not publish Cloudflare CIDR cache update."
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
'''
t = t[:start] + block + t[end:]
p.write_text(t)

# Extend the existing stateful UFW mock so rollback can be asserted against the
# real managed-rule files and reload operation.
p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()

anchor = '''printf '%s\\n' "$*" >> "${UFW_CALL_LOG:?}"

if [[ "${1:-}" == "status" && "${2:-}" == "numbered" ]]; then
'''
replacement = '''printf '%s\\n' "$*" >> "${UFW_CALL_LOG:?}"

if [[ "${1:-}" == "reload" ]]; then
    exit "${UFW_RELOAD_RC:-0}"
fi

if [[ "${1:-}" == "status" && "${2:-}" == "numbered" ]]; then
'''
if anchor not in t:
    raise SystemExit('ufw reload mock anchor missing')
t = t.replace(anchor, replacement, 1)

# Mark fake managed-rule file on every UFW mutation. A rollback copy must remove
# this marker by restoring the pre-mutation snapshot.
for anchor in [
    '''    printf 'Rule added\\n'\n    exit 0\nfi\n\nif [[ "$command_line" == *" allow "* && "$command_line" == *" port 443 "* ]]; then\n''',
    '''    printf 'Rule added\\n'\n    exit 0\nfi\n\nif [[ "${1:-}" == "--force" && "${2:-}" == "delete" ]]; then\n''',
    '''    printf 'Rule deleted\\n'\n    exit 0\nfi\n\nprintf 'unexpected ufw invocation: %s\\n' "$*" >&2\n''',
]:
    if anchor not in t:
        raise SystemExit('UFW mutation marker anchor missing')
    prefix = anchor.split("    printf", 1)[0]
    marked = anchor.replace("    printf", "    printf 'mutation\\n' >> \"${UFW_CONFIG_DIR:?}/user.rules\"\n    printf", 1)
    t = t.replace(anchor, marked, 1)

anchor = '''    CASE_OUTPUT="$CASE_DIR/output"

    printf '203.0.113.0/24\\n' > "$CF_IPV4_FILE"
'''
replacement = '''    CASE_OUTPUT="$CASE_DIR/output"
    UFW_CONFIG_DIR="$CASE_DIR/ufw-config"
    mkdir -p "$UFW_CONFIG_DIR"

    printf '203.0.113.0/24\\n' > "$CF_IPV4_FILE"
'''
if anchor not in t:
    raise SystemExit('case UFW config anchor missing')
t = t.replace(anchor, replacement, 1)

anchor = '''    printf 'DEFAULT_INPUT_POLICY="DROP"\\n' > "$UFW_DEFAULTS_FILE"
    : > "$UFW_CALL_LOG"
'''
replacement = '''    printf 'DEFAULT_INPUT_POLICY="DROP"\\n' > "$UFW_DEFAULTS_FILE"
    printf 'baseline-v4\\n' > "$UFW_CONFIG_DIR/user.rules"
    printf 'baseline-v6\\n' > "$UFW_CONFIG_DIR/user6.rules"
    : > "$UFW_CALL_LOG"
'''
if anchor not in t:
    raise SystemExit('case UFW baseline anchor missing')
t = t.replace(anchor, replacement, 1)

anchor = '''    unset UFW_DELETE_FAIL_RULE UFW_DELETE_RC UFW_DELETE_OUTPUT UFW_NO_MUTATE
    unset FW_PREFLIGHT_RC FW_EXACT_RC FW_RECONCILE_RC SSHD_PORT

    export CASE_DIR CF_IPV4_FILE CF_IPV6_FILE UFW_STATUS_FILE UFW_NUMBERED_FILE
    export UFW_VERBOSE_FILE UFW_DEFAULTS_FILE UFW_CALL_LOG FW_CALL_LOG LOG_FILE
'''
replacement = '''    unset UFW_DELETE_FAIL_RULE UFW_DELETE_RC UFW_DELETE_OUTPUT UFW_NO_MUTATE UFW_RELOAD_RC
    unset FW_PREFLIGHT_RC FW_EXACT_RC FW_RECONCILE_RC SSHD_PORT

    export CASE_DIR CF_IPV4_FILE CF_IPV6_FILE UFW_STATUS_FILE UFW_NUMBERED_FILE
    export UFW_VERBOSE_FILE UFW_DEFAULTS_FILE UFW_CONFIG_DIR UFW_CALL_LOG FW_CALL_LOG LOG_FILE
'''
if anchor not in t:
    raise SystemExit('case UFW export anchor missing')
t = t.replace(anchor, replacement, 1)

anchor = '''reset_case updater-docker-rollback
write_ipv4_status true true
IPT_CALL_LOG="$CASE_DIR/ipt-calls"; : > "$IPT_CALL_LOG"; export IPT_CALL_LOG
export FW_EXACT_RC=1 FW_RECONCILE_RC=55
run_case
[[ "$CASE_RC" -eq 55 ]] || fail "periodic Docker ingress failure returned $CASE_RC instead of 55"
assert_file_contains "$IPT_CALL_LOG" 'restore'
[[ ! -e "$CASE_DIR/state/cf-cidrs.cache" ]] || fail "failed Docker ingress refresh published a new CIDR cache"
'''
replacement = '''reset_case updater-docker-rollback
write_ipv4_status true false
IPT_CALL_LOG="$CASE_DIR/ipt-calls"; : > "$IPT_CALL_LOG"; export IPT_CALL_LOG
export FW_EXACT_RC=1 FW_RECONCILE_RC=55
run_case
[[ "$CASE_RC" -eq 55 ]] || fail "periodic Docker ingress failure returned $CASE_RC instead of 55"
assert_file_contains "$IPT_CALL_LOG" 'restore'
assert_call 'reload'
[[ "$(cat "$UFW_CONFIG_DIR/user.rules")" == 'baseline-v4' ]] \
    || fail "Docker ingress failure left UFW managed rules partially updated"
[[ ! -e "$CASE_DIR/state/cf-cidrs.cache" ]] || fail "failed Docker ingress refresh published a new CIDR cache"
'''
if anchor not in t:
    raise SystemExit('updater Docker rollback test anchor missing')
t = t.replace(anchor, replacement, 1)

# Deletion failure should also restore the managed-rule snapshot.
anchor = '''[[ "$CASE_RC" -eq 44 ]] || fail "delete failure returned $CASE_RC instead of 44"
assert_file_contains "$LOG_FILE" 'simulated delete failure'
'''
replacement = '''[[ "$CASE_RC" -eq 44 ]] || fail "delete failure returned $CASE_RC instead of 44"
assert_file_contains "$LOG_FILE" 'simulated delete failure'
assert_call 'reload'
[[ "$(cat "$UFW_CONFIG_DIR/user.rules")" == 'baseline-v4' ]] \
    || fail "UFW delete failure left managed rules partially updated"
'''
if anchor not in t:
    raise SystemExit('delete failure rollback assertion anchor missing')
t = t.replace(anchor, replacement, 1)

p.write_text(t)
