from pathlib import Path
p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()

old = '''reset_case non-tcp-ingress-conflict
write_ipv4_status true true
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 4] 80 ALLOW IN 203.0.113.0/24
EOF_RULES
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "non-TCP ingress reconciliation failed with $CASE_RC"
assert_call '--force delete 4'
'''
new = '''reset_case non-tcp-ingress-conflict
write_ipv4_status true true
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 4] 80 ALLOW IN 203.0.113.0/24
EOF_RULES
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "ambiguous non-TCP ingress rule was auto-mutated instead of failing closed"
assert_file_contains "$LOG_FILE" 'Ambiguous inbound UFW allow rule 4'
assert_no_call '--force delete'
'''
if old not in t:
    raise SystemExit('non-TCP expectation anchor not found')
t = t.replace(old, new, 1)

old = '''[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "initial UFW readiness accepted non-TCP port 443 ingress"
assert_file_contains "$LOG_FILE" 'Conflicting public or stale managed UFW 80/443 rules remain'
'''
new = '''[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "initial UFW readiness accepted non-TCP port 443 ingress"
assert_file_contains "$LOG_FILE" 'Ambiguous inbound UFW allow rule 4'
'''
if old not in t:
    raise SystemExit('setup non-TCP expectation anchor not found')
t = t.replace(old, new, 1)

old = "assert_file_contains \"$LOG_FILE\" 'Non-Cloudflare UFW 80/443 allow rule remains'\n"
new = "assert_file_contains \"$LOG_FILE\" 'Non-Cloudflare UFW 80/443 rule remains'\n"
if old not in t:
    raise SystemExit('restricted final diagnostic anchor not found')
t = t.replace(old, new, 1)

old = '''reset_case ipv6-existing
: > "$CF_IPV4_FILE"
printf '2001:db8::/32\\n' > "$CF_IPV6_FILE"
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
80/tcp (v6) ALLOW IN 2001:db8::/32
443/tcp (v6) ALLOW IN 2001:db8::/32
EOF_STATUS
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "existing IPv6 rules failed with $CASE_RC"
assert_no_call ' allow '
'''
new = '''reset_case ipv6-existing
printf '203.0.113.0/24\\n' > "$CF_IPV4_FILE"
printf '2001:db8::/32\\n' > "$CF_IPV6_FILE"
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
80/tcp ALLOW IN 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
80/tcp (v6) ALLOW IN 2001:db8::/32
443/tcp (v6) ALLOW IN 2001:db8::/32
EOF_STATUS
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "existing IPv4+IPv6 rules failed with $CASE_RC"
assert_no_call ' allow '
'''
if old not in t:
    raise SystemExit('IPv6 idempotency anchor not found')
t = t.replace(old, new, 1)

p.write_text(t)
