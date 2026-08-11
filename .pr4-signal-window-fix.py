from pathlib import Path

p = Path('utilities/setup-firewall.sh')
t = p.read_text()
old = '''    trap 'operation_release 130; exit 130' INT
    trap 'operation_release 129; exit 129' HUP
    trap 'operation_release 143; exit 143' TERM
'''
new = '''    # Keep fail-closed signal handling active through the post-iptables
    # Caddy runtime normalization performed by main().
    trap '_setup_firewall_signal_fail_closed 130' INT
    trap '_setup_firewall_signal_fail_closed 129' HUP
    trap '_setup_firewall_signal_fail_closed 143' TERM
'''
if old not in t:
    raise SystemExit('post-iptables trap reset anchor missing')
t = t.replace(old, new, 1)

old = '''        trap '_setup_firewall_signal_fail_closed 130' INT
        trap '_setup_firewall_signal_fail_closed 143' HUP TERM
'''
new = '''        trap '_setup_firewall_signal_fail_closed 130' INT
        trap '_setup_firewall_signal_fail_closed 129' HUP
        trap '_setup_firewall_signal_fail_closed 143' TERM
'''
if old not in t:
    raise SystemExit('main signal trap anchor missing')
t = t.replace(old, new, 1)
p.write_text(t)

p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
anchor = '''assert_file_contains "$SETUP_FIREWALL" '_setup_firewall_signal_fail_closed 130'
assert_file_contains "$SETUP_FIREWALL" 'firewall_fail_closed_stop_caddy || log_error "CRITICAL: signal rollback'
'''
replacement = '''assert_file_contains "$SETUP_FIREWALL" "trap '_setup_firewall_signal_fail_closed 130' INT"
assert_file_contains "$SETUP_FIREWALL" "trap '_setup_firewall_signal_fail_closed 129' HUP"
assert_file_contains "$SETUP_FIREWALL" "trap '_setup_firewall_signal_fail_closed 143' TERM"
assert_file_contains "$SETUP_FIREWALL" 'firewall_fail_closed_stop_caddy || log_error "CRITICAL: signal rollback'
! grep -Fq "trap 'operation_release 130; exit 130' INT" "$SETUP_FIREWALL" \
    || fail "post-iptables signal handling can bypass fail-closed Caddy shutdown"
'''
if anchor not in t:
    raise SystemExit('signal static assertion anchor missing')
t = t.replace(anchor, replacement, 1)
p.write_text(t)
