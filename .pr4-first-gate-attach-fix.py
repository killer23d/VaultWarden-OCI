from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"{label} anchor missing in {path}")
    p.write_text(text.replace(old, new, 1))


replace_once(
    'lib/firewall.sh',
    '''    iptables -t filter -I "$VW_CF_DOCKER_CHAIN" 1 \\
        -d "$VW_CADDY_EXTERNAL_CIDR" -p tcp -m conntrack --ctorigdstport 80 -j DROP || return $?\n\n    local count\n''',
    '''    iptables -t filter -I "$VW_CF_DOCKER_CHAIN" 1 \\
        -d "$VW_CADDY_EXTERNAL_CIDR" -p tcp -m conntrack --ctorigdstport 80 -j DROP || return $?\n\n    # Attach the fail-closed sentinels immediately. On the first migration from\n    # the legacy/UFW-only model, waiting until after RETURN rules are built would\n    # leave an already-running public Caddy directly reachable during mutation.\n    # Insert a replacement first jump before removing older duplicates so an\n    # existing gate is never detached before its replacement is active.\n    iptables -t filter -I DOCKER-USER 1 -j "$VW_CF_DOCKER_CHAIN" || return $?\n    _firewall_delete_duplicate_parent_jumps || {\n        log_error "Could not normalize the DOCKER-USER jump to ${VW_CF_DOCKER_CHAIN}."\n        return 1\n    }\n\n    local count\n''',
    'early fail-closed parent attachment',
)
replace_once(
    'lib/firewall.sh',
    '''    # Install a new first-rule jump before deleting older duplicate jumps, so\n    # an existing gate is never removed before its replacement is active.\n    iptables -t filter -I DOCKER-USER 1 -j "$VW_CF_DOCKER_CHAIN" || return $?\n    _firewall_delete_duplicate_parent_jumps || {\n        log_error "Could not normalize the DOCKER-USER jump to ${VW_CF_DOCKER_CHAIN}."\n        return 1\n    }\n\n''',
    '',
    'late parent attachment removal',
)

p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
anchor = '''run_iptables_case initial-gate\nrun_iptables_probe\n[[ "$IPT_RC" -eq 0 ]] || fail "initial Docker Cloudflare gate reconciliation returned $IPT_RC"\n'''
replacement = anchor + '''sentinel80_line="$(grep -n 'iptables -t filter -I VW-CF-INGRESS 1 -d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 80 -j DROP' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"\nsentinel443_line="$(grep -n 'iptables -t filter -I VW-CF-INGRESS 1 -d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 443 -j DROP' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"\njump_line="$(grep -n 'iptables -t filter -I DOCKER-USER 1 -j VW-CF-INGRESS' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"\nallow_line="$(grep -n 'iptables -t filter -I VW-CF-INGRESS 1 -d 172.22.0.0/28 -s 203.0.113.0/24 -p tcp -m conntrack --ctorigdstport' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"\n[[ -n "$sentinel80_line" && -n "$sentinel443_line" && -n "$jump_line" && -n "$allow_line" ]] \\
    || fail "initial Docker gate mutation-order probe missed sentinel/jump/allow calls"\n[[ "$sentinel80_line" -lt "$jump_line" && "$sentinel443_line" -lt "$jump_line" && "$jump_line" -lt "$allow_line" ]] \\
    || fail "initial Docker gate was not attached fail-closed before Cloudflare RETURN rules were built"\n'''
if anchor not in t:
    raise SystemExit('initial gate behavior anchor missing')
p.write_text(t.replace(anchor, replacement, 1))
