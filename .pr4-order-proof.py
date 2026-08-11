from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"{label} anchor missing")
    p.write_text(text.replace(old, new, 1))


replace_once(
    'lib/firewall.sh',
    '''firewall_docker_ingress_is_exact() {\n''',
    '''_firewall_managed_chain_order_is_safe() {\n    iptables -t filter -S "$VW_CF_DOCKER_CHAIN" 2>/dev/null |\n        awk -v chain="$VW_CF_DOCKER_CHAIN" '\n            $1 == "-A" && $2 == chain {\n                if ($NF == "RETURN" && seen_drop) bad=1\n                if ($NF == "DROP") seen_drop=1\n            }\n            END { exit bad ? 1 : 0 }\n        '\n}\n\nfirewall_docker_ingress_is_exact() {\n''',
    'managed-chain order helper',
)
replace_once(
    'lib/firewall.sh',
    '''    [[ "$actual_count" =~ ^[0-9]+$ && "$actual_count" -eq "$expected_count" ]] || return 1\n\n    # Replies to connections initiated by Caddy must return to Docker's normal\n''',
    '''    [[ "$actual_count" =~ ^[0-9]+$ && "$actual_count" -eq "$expected_count" ]] || return 1\n    _firewall_managed_chain_order_is_safe || return 1\n\n    # Replies to connections initiated by Caddy must return to Docker's normal\n''',
    'order proof in exact verifier',
)

replace_once(
    'tests/suites/operations/case-firewall-update.bash',
    '''assert_file_contains "$FIREWALL_LIB" '--ctstate ESTABLISHED,RELATED -j RETURN'\n''',
    '''assert_file_contains "$FIREWALL_LIB" '--ctstate ESTABLISHED,RELATED -j RETURN'\nassert_file_contains "$FIREWALL_LIB" '_firewall_managed_chain_order_is_safe || return 1'\n''',
    'order verifier static assertion',
)
replace_once(
    'tests/suites/operations/case-firewall-update.bash',
    '''assert_file_contains "$IPT_LOG_FILE" 'skipping mutation'\n\n: > "$IPT_REJECT_MARKER"\n''',
    '''assert_file_contains "$IPT_LOG_FILE" 'skipping mutation'\n\n# Exact-state verification must reject a chain whose DROP precedes any RETURN.\n# Otherwise a manually reordered chain can be misclassified as safe and break\n# Cloudflare ingress or Caddy-initiated outbound replies.\ndrop_rule="$(grep -F -- '-p tcp -m conntrack --ctorigdstport 80 -j DROP' "$IPT_CF_FILE" | head -1)"\n[[ -n "$drop_rule" ]] || fail "could not locate managed port-80 DROP for order-drift test"\n{\n    printf '%s\\n' "$drop_rule"\n    grep -Fvx -- "$drop_rule" "$IPT_CF_FILE"\n} > "$IPT_CF_FILE.tmp"\nmv "$IPT_CF_FILE.tmp" "$IPT_CF_FILE"\n[[ "$(head -n1 "$IPT_CF_FILE")" == *'-j DROP' ]] || fail "order-drift fixture did not move a DROP ahead of RETURN rules"\n: > "$IPT_CALL_LOG"\nrun_iptables_probe\n[[ "$IPT_RC" -eq 0 ]] || fail "misordered Docker gate reconciliation returned $IPT_RC"\ngrep -qx 'save' "$IPT_CALL_LOG" || fail "misordered Docker gate was incorrectly treated as exact"\n[[ "$(head -n1 "$IPT_CF_FILE")" == '-A VW-CF-INGRESS -d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN' ]] \\\n    || fail "misordered Docker gate did not restore RETURN-before-DROP ordering"\n\n: > "$IPT_REJECT_MARKER"\n''',
    'order-drift behavior regression',
)