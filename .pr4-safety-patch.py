from pathlib import Path

p = Path('utilities/setup-firewall.sh')
text = p.read_text()
start = text.index('    _restore_snapshot() {')
end = text.index('    if _iptables_delete_all_exact filter FORWARD', start)
replacement = "\n".join([
    '    _restore_snapshot() {',
    '        local restore_rc=0',
    '        [[ -n "${backup_v4:-}" && -f "$backup_v4" ]] || return 0',
    '        log_rollback "Restoring iptables rules from rollback snapshot"',
    '        iptables-restore < "$backup_v4" || restore_rc=$?',
    '        rm -f "$backup_v4"',
    '        backup_v4=""',
    '        if (( restore_rc != 0 )); then',
    '            log_error "CRITICAL: iptables rollback restore failed (exit ${restore_rc})"',
    '        fi',
    '    }',
    '',
    '    _iptables_signal_rollback() {',
    '        local signal_rc="$1"',
    '        _restore_snapshot',
    '        exit "$signal_rc"',
    '    }',
    "    trap '_iptables_signal_rollback 130' INT",
    "    trap '_iptables_signal_rollback 129' HUP",
    "    trap '_iptables_signal_rollback 143' TERM",
    '',
])
text = text[:start] + replacement + text[end:]
cleanup_start = text.rindex('    rm -f "$backup_v4"')
log_marker = '    log_success "Docker firewall runtime reconciled without project forwarding exceptions"'
log_start = text.index(log_marker, cleanup_start)
log_end = text.index('\n', log_start) + 1
cleanup = "\n".join([
    '    rm -f "$backup_v4"',
    '    backup_v4=""',
    "    trap 'operation_release 130; exit 130' INT",
    "    trap 'operation_release 129; exit 129' HUP",
    "    trap 'operation_release 143; exit 143' TERM",
    log_marker,
    '',
])
text = text[:cleanup_start] + cleanup + text[log_end:]
p.write_text(text)

p = Path('tests/suites/operations/case-firewall-update.bash')
text = p.read_text()
needle = 'assert_file_contains "$SETUP_FIREWALL" "Docker DOCKER-USER chain is unavailable."\n'
extra = "assert_file_contains \"$SETUP_FIREWALL\" \"trap '_iptables_signal_rollback 130' INT\"\nassert_file_contains \"$SETUP_FIREWALL\" \"trap '_iptables_signal_rollback 143' TERM\"\n"
if needle not in text:
    raise SystemExit('expected firewall assertion anchor not found')
p.write_text(text.replace(needle, needle + extra, 1))
