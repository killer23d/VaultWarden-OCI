from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"{label} anchor missing in {path}")
    p.write_text(text.replace(old, new, 1))


# First make the project chain contain only fail-closed sentinels. Only then
# attach it to DOCKER-USER, so an orphaned stale chain can never make unrelated
# legacy rules live during migration. After attachment, build the RETURN rules.
replace_once(
    'lib/firewall.sh',
    '''    while (( count > 2 )); do\n        iptables -t filter -D "$VW_CF_DOCKER_CHAIN" 3 || return $?\n        count=$((count - 1))\n    done\n\n    local cidr port\n''',
    '''    while (( count > 2 )); do\n        iptables -t filter -D "$VW_CF_DOCKER_CHAIN" 3 || return $?\n        count=$((count - 1))\n    done\n\n    # The chain is now exactly the two project-scoped DROP sentinels. Attach it\n    # before adding any RETURN rules so first-time migration is fail-closed, but\n    # never activate orphaned stale rules for unrelated Docker traffic. Insert a\n    # replacement first jump before removing older duplicates so an existing gate\n    # is never detached before its replacement is active.\n    iptables -t filter -I DOCKER-USER 1 -j "$VW_CF_DOCKER_CHAIN" || return $?\n    _firewall_delete_duplicate_parent_jumps || {\n        log_error "Could not normalize the DOCKER-USER jump to ${VW_CF_DOCKER_CHAIN}."\n        return 1\n    }\n\n    local cidr port\n''',
    'fail-closed parent attachment after stale cleanup',
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
t = t.replace(anchor, replacement, 1)

anchor = '''assert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 443 -j DROP'\n'''
block = anchor + '''\nrun_iptables_case orphan-stale-chain\nprintf '%s\\n' '-A VW-CF-INGRESS -j ACCEPT' > "$IPT_CF_FILE"\nrun_iptables_probe\n[[ "$IPT_RC" -eq 0 ]] || fail "orphan stale Docker gate reconciliation returned $IPT_RC"\nstale_delete_line="$(grep -n 'iptables -t filter -D VW-CF-INGRESS 3' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"\njump_line="$(grep -n 'iptables -t filter -I DOCKER-USER 1 -j VW-CF-INGRESS' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"\n[[ -n "$stale_delete_line" && -n "$jump_line" && "$stale_delete_line" -lt "$jump_line" ]] \\
    || fail "orphan stale project-chain rules were activated before cleanup"\n! grep -Fq -- '-A VW-CF-INGRESS -j ACCEPT' "$IPT_CF_FILE" || fail "orphan stale ACCEPT survived reconciliation"\n'''
if anchor not in t:
    raise SystemExit('orphan stale chain test anchor missing')
p.write_text(t.replace(anchor, block, 1))
