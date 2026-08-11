from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"{label} anchor missing in {path}")
    p.write_text(text.replace(old, new, 1))


replace_once(
    'lib/firewall.sh',
    '''    while [[ "$count" =~ ^[0-9]+$ ]] && (( count > 2 )); do
        iptables -t filter -D "$VW_CF_DOCKER_CHAIN" 3 || return $?
        count=$((count - 1))
    done
    [[ "$count" == "2" ]] || {
        log_error "Could not normalize ${VW_CF_DOCKER_CHAIN} before rebuilding it."
        return 1
    }

    local cidr port
''',
    '''    while [[ "$count" =~ ^[0-9]+$ ]] && (( count > 2 )); do
        iptables -t filter -D "$VW_CF_DOCKER_CHAIN" 3 || return $?
        count=$((count - 1))
    done
    [[ "$count" == "2" ]] || {
        log_error "Could not normalize ${VW_CF_DOCKER_CHAIN} before rebuilding it."
        return 1
    }

    # Preserve replies to Caddy-initiated connections before attaching the new
    # fail-closed gate. NEW non-Cloudflare web traffic still falls through this
    # rule into the two DROP sentinels.
    iptables -t filter -I "$VW_CF_DOCKER_CHAIN" 1 \
        -d "$VW_CADDY_EXTERNAL_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN \
        || return $?

    # The chain now contains only known-safe project rules: established replies
    # plus the two web DROP sentinels. Attach it before adding Cloudflare RETURNs
    # so first-time migration is fail-closed without activating orphaned stale
    # rules for unrelated Docker traffic.
    iptables -t filter -I DOCKER-USER 1 -j "$VW_CF_DOCKER_CHAIN" || return $?
    _firewall_delete_duplicate_parent_jumps || {
        log_error "Could not normalize the DOCKER-USER jump to ${VW_CF_DOCKER_CHAIN}."
        return 1
    }

    local cidr port
''',
    'safe parent attachment after stale cleanup',
)
replace_once(
    'lib/firewall.sh',
    '''    # This must remain ahead of the source DROP rules: Caddy-initiated HTTP,
    # HTTPS, DNS, and related reply traffic is not new public ingress. RETURN
    # keeps Docker authoritative for the eventual forwarding decision.
    iptables -t filter -I "$VW_CF_DOCKER_CHAIN" 1 \
        -d "$VW_CADDY_EXTERNAL_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN \
        || return $?

    # Install a new first-rule jump before deleting older duplicate jumps, so
    # an existing gate is never removed before its replacement is active.
    iptables -t filter -I DOCKER-USER 1 -j "$VW_CF_DOCKER_CHAIN" || return $?
    _firewall_delete_duplicate_parent_jumps || {
        log_error "Could not normalize the DOCKER-USER jump to ${VW_CF_DOCKER_CHAIN}."
        return 1
    }

''',
    '',
    'late established/jump block removal',
)

p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
anchor = '''run_iptables_case initial-gate
run_iptables_probe
[[ "$IPT_RC" -eq 0 ]] || fail "initial Docker Cloudflare gate reconciliation returned $IPT_RC"
'''
replacement = anchor + '''sentinel80_line="$(grep -n 'iptables -t filter -I VW-CF-INGRESS 1 -d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 80 -j DROP' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
sentinel443_line="$(grep -n 'iptables -t filter -I VW-CF-INGRESS 1 -d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 443 -j DROP' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
established_line="$(grep -n 'iptables -t filter -I VW-CF-INGRESS 1 -d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
jump_line="$(grep -n 'iptables -t filter -I DOCKER-USER 1 -j VW-CF-INGRESS' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
allow_line="$(grep -n 'iptables -t filter -I VW-CF-INGRESS 1 -d 172.22.0.0/28 -s 203.0.113.0/24 -p tcp -m conntrack --ctorigdstport' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
[[ -n "$sentinel80_line" && -n "$sentinel443_line" && -n "$established_line" && -n "$jump_line" && -n "$allow_line" ]] \
    || fail "initial Docker gate mutation-order probe missed sentinel/established/jump/allow calls"
[[ "$sentinel80_line" -lt "$established_line" && "$sentinel443_line" -lt "$established_line" && "$established_line" -lt "$jump_line" && "$jump_line" -lt "$allow_line" ]] \
    || fail "initial Docker gate did not preserve established replies and attach fail-closed before Cloudflare RETURN rules"
'''
if anchor not in t:
    raise SystemExit('initial gate behavior anchor missing')
t = t.replace(anchor, replacement, 1)

anchor = '''assert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 443 -j DROP'
'''
block = anchor + '''
run_iptables_case orphan-stale-chain
printf '%s\n' '-A VW-CF-INGRESS -j ACCEPT' > "$IPT_CF_FILE"
run_iptables_probe
[[ "$IPT_RC" -eq 0 ]] || fail "orphan stale Docker gate reconciliation returned $IPT_RC"
stale_delete_line="$(grep -n 'iptables -t filter -D VW-CF-INGRESS 3' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
established_line="$(grep -n 'iptables -t filter -I VW-CF-INGRESS 1 -d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
jump_line="$(grep -n 'iptables -t filter -I DOCKER-USER 1 -j VW-CF-INGRESS' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
[[ -n "$stale_delete_line" && -n "$established_line" && -n "$jump_line" && "$stale_delete_line" -lt "$established_line" && "$established_line" -lt "$jump_line" ]] \
    || fail "orphan stale project-chain rules were activated before cleanup"
! grep -Fq -- '-A VW-CF-INGRESS -j ACCEPT' "$IPT_CF_FILE" || fail "orphan stale ACCEPT survived reconciliation"
'''
if anchor not in t:
    raise SystemExit('orphan stale chain test anchor missing')
p.write_text(t.replace(anchor, block, 1))
