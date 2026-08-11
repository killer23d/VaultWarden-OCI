from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"{label} anchor missing in {path}")
    p.write_text(text.replace(old, new, 1))


for path in ('utilities/setup-firewall.sh', 'utilities/maintenance-update-firewall.sh'):
    replace_once(
        path,
        '''        body="${BASH_REMATCH[2]}"\n        [[ "$body" =~ [[:space:]](ALLOW|LIMIT)([[:space:]]|$) ]] || continue\n'''
        if path.endswith('setup-firewall.sh') else
        '''            body="${BASH_REMATCH[2]}"\n            [[ "$body" =~ [[:space:]](ALLOW|LIMIT)([[:space:]]|$) ]] || continue\n''',
        '''        body="${BASH_REMATCH[2]}"\n        body="${body%%#*}"\n        [[ "$body" =~ [[:space:]](ALLOW|LIMIT)([[:space:]]|$) ]] || continue\n'''
        if path.endswith('setup-firewall.sh') else
        '''            body="${BASH_REMATCH[2]}"\n            body="${body%%#*}"\n            [[ "$body" =~ [[:space:]](ALLOW|LIMIT)([[:space:]]|$) ]] || continue\n''',
        'ambiguous-rule comment boundary',
    )

p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
anchor = '''reset_case non-tcp-ingress-conflict
write_ipv4_status true true
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 4] 80 ALLOW IN 203.0.113.0/24
EOF_RULES
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "ambiguous non-TCP ingress rule was auto-mutated instead of failing closed"
assert_file_contains "$LOG_FILE" 'Ambiguous inbound UFW allow rule 4'
assert_no_call '--force delete'

'''
block = anchor + '''reset_case ambiguous-profile-comment-cannot-spoof-direction
write_ipv4_status true true
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 4] Nginx Full ALLOW Anywhere # operator note: ALLOW OUT is unrelated
EOF_RULES
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "comment text hid ambiguous inbound UFW application rule"
assert_file_contains "$LOG_FILE" 'Ambiguous inbound UFW allow rule 4'
assert_no_call '--force delete'

'''
if anchor not in t:
    raise SystemExit('updater ambiguous test anchor missing')
t = t.replace(anchor, block, 1)

anchor = '''reset_case setup-inactive-hidden-permissive-rule
'''
block = '''reset_case setup-ambiguous-profile-comment-cannot-spoof-direction
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW 198.51.100.10/32
80/tcp ALLOW 203.0.113.0/24
443/tcp ALLOW 203.0.113.0/24
Nginx Full ALLOW Anywhere # operator note: ALLOW OUT is unrelated
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW 198.51.100.10/32
[ 2] 80/tcp ALLOW 203.0.113.0/24
[ 3] 443/tcp ALLOW 203.0.113.0/24
[ 4] Nginx Full ALLOW Anywhere # operator note: ALLOW OUT is unrelated
EOF_RULES
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=safety "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "setup comment text hid ambiguous inbound UFW application rule"
assert_file_contains "$LOG_FILE" 'Ambiguous inbound UFW allow rule 4'

reset_case setup-inactive-hidden-permissive-rule
'''
if anchor not in t:
    raise SystemExit('setup ambiguity test insertion anchor missing')
p.write_text(t.replace(anchor, block, 1))
