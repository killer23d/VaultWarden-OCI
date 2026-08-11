from pathlib import Path

p = Path('utilities/maintenance-update-firewall.sh')
t = p.read_text()

old = '    local backup_v4="" mutation_rc=0\n'
new = '    local backup_v4="" mutation_rc=0 cache_tmp="" cache_commit_started=false\n'
if old not in t:
    raise SystemExit('transaction locals anchor missing')
t = t.replace(old, new, 1)

old = '''    _update_firewall_rollback_all() {
        local rollback_rc=0
        _update_firewall_restore_iptables || rollback_rc=$?
        _update_firewall_restore_ufw || rollback_rc=$?
        return "$rollback_rc"
    }
'''
new = '''    _update_firewall_rollback_all() {
        local rollback_rc=0
        # UFW reload rewrites netfilter state, so restore its managed files first
        # and make the full iptables snapshot the final firewall write.
        _update_firewall_restore_ufw || rollback_rc=$?
        _update_firewall_restore_iptables || rollback_rc=$?
        return "$rollback_rc"
    }
'''
if old not in t:
    raise SystemExit('rollback ordering anchor missing')
t = t.replace(old, new, 1)

old = '''    _update_firewall_signal_rollback() {
        local signal_rc="$1"
        _update_firewall_rollback_all || true
        operation_release "$signal_rc"
        perform_cleanup
        exit "$signal_rc"
    }
'''
new = '''    _update_firewall_signal_rollback() {
        local signal_rc="$1"
        # The atomic cache rename is the transaction commit point. Bash defers
        # traps until a foreground command returns, so a signal delivered while
        # mv succeeds sees the temp path gone and must not roll back the already
        # committed firewall generation.
        if [[ "$cache_commit_started" != "true" || -z "$cache_tmp" || -e "$cache_tmp" ]]; then
            _update_firewall_rollback_all || true
        fi
        operation_release "$signal_rc"
        perform_cleanup
        exit "$signal_rc"
    }
'''
if old not in t:
    raise SystemExit('signal rollback anchor missing')
t = t.replace(old, new, 1)

old = '''    local cache_dir cache_tmp=""
    cache_dir="$(dirname "$cf_cidr_cache")"
'''
new = '''    local cache_dir
    cache_dir="$(dirname "$cf_cidr_cache")"
'''
if old not in t:
    raise SystemExit('cache local anchor missing')
t = t.replace(old, new, 1)

old = '''    if ! chmod 640 "$cache_tmp" || ! mv -f -- "$cache_tmp" "$cf_cidr_cache"; then
        log_error "Could not publish Cloudflare CIDR cache update."
        rm -f "$cache_tmp"
        _update_firewall_fail 1
        return $?
    fi
'''
new = '''    if ! chmod 640 "$cache_tmp"; then
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
'''
if old not in t:
    raise SystemExit('cache commit anchor missing')
t = t.replace(old, new, 1)
p.write_text(t)

p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
old = '''if [[ "${1:-}" == "reload" ]]; then
    exit "${UFW_RELOAD_RC:-0}"
fi
'''
new = '''if [[ "${1:-}" == "reload" ]]; then
    printf 'ufw-reload\\n' >> "${TXN_CALL_LOG:?}"
    exit "${UFW_RELOAD_RC:-0}"
fi
'''
if old not in t:
    raise SystemExit('UFW reload mock anchor missing')
t = t.replace(old, new, 1)

old = '''    FW_CALL_LOG="$CASE_DIR/firewall-calls"
    LOG_FILE="$CASE_DIR/log"
'''
new = '''    FW_CALL_LOG="$CASE_DIR/firewall-calls"
    TXN_CALL_LOG="$CASE_DIR/transaction-calls"
    LOG_FILE="$CASE_DIR/log"
'''
if old not in t:
    raise SystemExit('transaction call log path anchor missing')
t = t.replace(old, new, 1)

old = '''    : > "$FW_CALL_LOG"
    : > "$LOG_FILE"
'''
new = '''    : > "$FW_CALL_LOG"
    : > "$TXN_CALL_LOG"
    : > "$LOG_FILE"
'''
if old not in t:
    raise SystemExit('transaction call log reset anchor missing')
t = t.replace(old, new, 1)

old = '''    export UFW_VERBOSE_FILE UFW_DEFAULTS_FILE UFW_CONFIG_DIR UFW_CALL_LOG FW_CALL_LOG LOG_FILE
'''
new = '''    export UFW_VERBOSE_FILE UFW_DEFAULTS_FILE UFW_CONFIG_DIR UFW_CALL_LOG FW_CALL_LOG TXN_CALL_LOG LOG_FILE
'''
if old not in t:
    raise SystemExit('transaction call log export anchor missing')
t = t.replace(old, new, 1)

old = '''printf 'restore\\n' >> "${IPT_CALL_LOG:?}"
cat >/dev/null
'''
new = '''printf 'restore\\n' >> "${IPT_CALL_LOG:?}"
printf 'iptables-restore\\n' >> "${TXN_CALL_LOG:-/dev/null}"
cat >/dev/null
'''
if old not in t:
    raise SystemExit('iptables restore mock anchor missing')
t = t.replace(old, new, 1)

rollback_start = t.index('reset_case updater-docker-rollback\n')
insert_anchor = '''assert_file_contains "$IPT_CALL_LOG" 'restore'
assert_call 'reload'
'''
insert_at = t.index(insert_anchor, rollback_start) + len(insert_anchor)
ordering_assertions = '''ufw_restore_line="$(grep -n '^ufw-reload$' "$TXN_CALL_LOG" | cut -d: -f1 | head -1)"
iptables_restore_line="$(grep -n '^iptables-restore$' "$TXN_CALL_LOG" | cut -d: -f1 | head -1)"
[[ -n "$ufw_restore_line" && -n "$iptables_restore_line" && "$ufw_restore_line" -lt "$iptables_restore_line" ]] \\
    || fail "rollback did not make iptables-restore the final firewall write"
'''
t = t[:insert_at] + ordering_assertions + t[insert_at:]

anchor = '''assert_file_contains "$UPDATER" 'firewall_reconcile_cloudflare_docker_ingress "${current_ipv4_cidrs[@]}"'
'''
replacement = '''assert_file_contains "$UPDATER" 'firewall_reconcile_cloudflare_docker_ingress "${current_ipv4_cidrs[@]}"'
assert_file_contains "$UPDATER" 'cache_commit_started=true'
assert_file_contains "$UPDATER" 'cache_commit_started" != "true"'
'''
if anchor not in t:
    raise SystemExit('signal commit static assertion anchor missing')
t = t.replace(anchor, replacement, 1)
p.write_text(t)
