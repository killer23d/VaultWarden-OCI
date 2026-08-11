from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"{label} anchor missing in {path}")
    p.write_text(text.replace(old, new, 1))


for path, indent in (
    ('utilities/setup-firewall.sh', '        '),
    ('utilities/maintenance-update-firewall.sh', '            '),
):
    replace_once(
        path,
        f'''{indent}[[ "$line" =~ [[:space:]](ALLOW|LIMIT)[[:space:]]+(OUT|FWD)([[:space:]]|$) ]] && continue
{indent}[[ "$line" =~ ^\\[[[:space:]]*([0-9]+)\\][[:space:]]+(80|443)(/tcp)?([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?([[:space:]]|$) ]] || continue
''',
        f'''{indent}local body="${{line%%#*}}"
{indent}[[ "$body" =~ [[:space:]](ALLOW|LIMIT)[[:space:]]+(OUT|FWD)([[:space:]]|$) ]] && continue
{indent}[[ "$body" =~ ^\\[[[:space:]]*([0-9]+)\\][[:space:]]+(80|443)(/tcp)?([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?([[:space:]]|$) ]] || continue
''',
        f'{path} conflict comment direction',
    )

p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
anchor = '''reset_case broad-conflict
write_ipv4_status true true
printf '%s\n' '[ 9] 80/tcp ALLOW IN Anywhere' >> "$UFW_NUMBERED_FILE"
printf '%s\n' '80/tcp ALLOW IN Anywhere' >> "$UFW_STATUS_FILE"
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "broad conflict reconciliation failed with $CASE_RC"
assert_call '--force delete 9'

'''
block = anchor + '''reset_case broad-conflict-comment-cannot-spoof-direction
write_ipv4_status true true
printf '%s\n' '[ 9] 80/tcp ALLOW Anywhere # operator note: ALLOW OUT is unrelated' >> "$UFW_NUMBERED_FILE"
printf '%s\n' '80/tcp ALLOW Anywhere # operator note: ALLOW OUT is unrelated' >> "$UFW_STATUS_FILE"
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "commented broad conflict reconciliation failed with $CASE_RC"
assert_call '--force delete 9'

'''
if anchor not in t:
    raise SystemExit('updater broad-conflict test anchor missing')
t = t.replace(anchor, block, 1)

anchor = '''reset_case setup-broad-conflict
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW IN Anywhere
80/tcp ALLOW IN 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
80/tcp ALLOW IN Anywhere
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW IN Anywhere
[ 2] 80/tcp ALLOW IN 203.0.113.0/24
[ 3] 443/tcp ALLOW IN 203.0.113.0/24
[ 4] 80/tcp ALLOW IN Anywhere
EOF_RULES
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "setup final verification accepted broad public ingress"
assert_file_contains "$LOG_FILE" 'Conflicting UFW 80/443 rules remain'

'''
block = anchor + '''reset_case setup-broad-conflict-comment-cannot-spoof-direction
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW 198.51.100.10/32
80/tcp ALLOW 203.0.113.0/24
443/tcp ALLOW 203.0.113.0/24
80/tcp ALLOW Anywhere # operator note: ALLOW OUT is unrelated
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW 198.51.100.10/32
[ 2] 80/tcp ALLOW 203.0.113.0/24
[ 3] 443/tcp ALLOW 203.0.113.0/24
[ 4] 80/tcp ALLOW Anywhere # operator note: ALLOW OUT is unrelated
EOF_RULES
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "comment text hid broad inbound web exposure"
assert_file_contains "$LOG_FILE" 'Conflicting UFW 80/443 rules remain'

'''
if anchor not in t:
    raise SystemExit('setup broad-conflict test anchor missing')
p.write_text(t.replace(anchor, block, 1))
