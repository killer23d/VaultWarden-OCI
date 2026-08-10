from pathlib import Path
p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()

old = '''[[ "$CASE_RC" -eq 45 ]] || fail "delete failure returned $CASE_RC instead of 45"
assert_file_contains "$LOG_FILE" 'Failed to delete UFW rule 12'
assert_file_contains "$LOG_FILE" 'simulated delete failure'
'''
new = '''[[ "$CASE_RC" -eq 45 ]] || fail "delete failure returned $CASE_RC instead of 45"
assert_file_contains "$LOG_FILE" 'Failed to delete UFW rule 12'
assert_file_contains "$LOG_FILE" 'simulated delete failure'
assert_call 'reload'
[[ "$(cat "$UFW_CONFIG_DIR/user.rules")" == 'baseline-v4' ]] \
    || fail "UFW delete failure left managed rules partially updated"
'''
if old not in t:
    raise SystemExit('delete-failure assertion anchor missing after transaction patch')
t = t.replace(old, new, 1)

old = '''reset_case only-port-80
write_ipv4_status true false
run_case
if [[ "$CASE_RC" -ne 0 ]]; then
    printf '%s\\n' '--- only-port-80 output ---' >&2
    cat "$CASE_OUTPUT" >&2 || true
    printf '%s\\n' '--- only-port-80 log ---' >&2
    cat "$LOG_FILE" >&2 || true
    printf '%s\\n' '--- only-port-80 status ---' >&2
    cat "$UFW_STATUS_FILE" >&2 || true
    printf '%s\\n' '--- only-port-80 numbered ---' >&2
    cat "$UFW_NUMBERED_FILE" >&2 || true
    printf '%s\\n' '--- only-port-80 verbose ---' >&2
    cat "$UFW_VERBOSE_FILE" >&2 || true
    printf '%s\\n' '--- only-port-80 ufw calls ---' >&2
    cat "$UFW_CALL_LOG" >&2 || true
    printf '%s\\n' '--- only-port-80 firewall calls ---' >&2
    cat "$FW_CALL_LOG" >&2 || true
fi
[[ "$CASE_RC" -eq 0 ]] || fail "port 80-only convergence failed with $CASE_RC"
'''
new = '''reset_case only-port-80
write_ipv4_status true false
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "port 80-only convergence failed with $CASE_RC"
'''
if old not in t:
    raise SystemExit('temporary only-port-80 diagnostics anchor missing')
t = t.replace(old, new, 1)
p.write_text(t)
