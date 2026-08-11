from pathlib import Path


def replace_exact(path: str, old: str, new: str, expected: int | None = None) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if expected is not None and count != expected:
        raise SystemExit(f"{path}: expected {expected} occurrences, found {count}: {old!r}")
    if count == 0:
        raise SystemExit(f"{path}: anchor missing: {old!r}")
    p.write_text(text.replace(old, new))


# Conntrack direction is part of the ingress contract.  Replies to connections
# initiated by Caddy may bypass the public-ingress DROP sentinels, but ORIGINAL
# direction packets from a direct connection established before reconciliation
# must not.
replace_exact(
    "lib/firewall.sh",
    "--ctstate ESTABLISHED,RELATED -j RETURN",
    "--ctstate ESTABLISHED,RELATED --ctdir REPLY -j RETURN",
    expected=2,
)

# Keep every permanent assertion aligned with the exact managed rule.
p = Path("tests/suites/operations/case-firewall-update.bash")
text = p.read_text()
old = "--ctstate ESTABLISHED,RELATED -j RETURN"
new = "--ctstate ESTABLISHED,RELATED --ctdir REPLY -j RETURN"
count = text.count(old)
if count < 5:
    raise SystemExit(f"expected at least 5 established-rule assertions, found {count}")
text = text.replace(old, new)

anchor = '''assert_file_contains "$IPT_LOG_FILE" 'skipping mutation'\n\n# Exact-state verification must reject a chain whose DROP precedes any RETURN.\n'''
regression = '''assert_file_contains "$IPT_LOG_FILE" 'skipping mutation'\n\n# A directionless ESTABLISHED/RELATED RETURN is not exact: ORIGINAL-direction\n# packets from a direct connection established before cutover could otherwise\n# continue toward Caddy. Reconciliation must replace it with REPLY-only state.\nsed '1s/ --ctdir REPLY//' "$IPT_CF_FILE" > "$IPT_CF_FILE.tmp"\nmv "$IPT_CF_FILE.tmp" "$IPT_CF_FILE"\n[[ "$(head -n1 "$IPT_CF_FILE")" == '-A VW-CF-INGRESS -d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN' ]] \\\n    || fail "directionless established-state fixture was not created"\n: > "$IPT_CALL_LOG"\nrun_iptables_probe\n[[ "$IPT_RC" -eq 0 ]] || fail "directionless established-state reconciliation returned $IPT_RC"\ngrep -qx 'save' "$IPT_CALL_LOG" || fail "directionless established-state rule was incorrectly treated as exact"\n[[ "$(head -n1 "$IPT_CF_FILE")" == '-A VW-CF-INGRESS -d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j RETURN' ]] \\\n    || fail "reconciliation did not restore reply-direction-only established handling"\n! grep -Fxq -- '-A VW-CF-INGRESS -d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN' "$IPT_CF_FILE" \\\n    || fail "directionless established-state bypass survived reconciliation"\n\n# Exact-state verification must reject a chain whose DROP precedes any RETURN.\n'''
if anchor not in text:
    raise SystemExit("directionless-state regression anchor missing")
text = text.replace(anchor, regression, 1)

static_anchor = '''assert_file_contains "$FIREWALL_LIB" '--ctstate ESTABLISHED,RELATED --ctdir REPLY -j RETURN'\nassert_file_contains "$FIREWALL_LIB" '_firewall_managed_chain_order_is_safe || return 1'\n'''
static_replacement = '''assert_file_contains "$FIREWALL_LIB" '--ctstate ESTABLISHED,RELATED --ctdir REPLY -j RETURN'\n! grep -Fq -- '--ctstate ESTABLISHED,RELATED -j RETURN' "$FIREWALL_LIB" \\\n    || fail "Docker gate still has a directionless established-state ingress bypass"\nassert_file_contains "$FIREWALL_LIB" '_firewall_managed_chain_order_is_safe || return 1'\n'''
if static_anchor not in text:
    raise SystemExit("static reply-direction assertion anchor missing")
text = text.replace(static_anchor, static_replacement, 1)
p.write_text(text)
