from pathlib import Path

for path in ['utilities/setup-firewall.sh', 'utilities/maintenance-update-firewall.sh']:
    p = Path(path)
    text = p.read_text()
    old = 'grep -qE "^${port}(/tcp)?([[:space:]]+\\\\(v6\\\\))?[[:space:]]+(ALLOW|ALLOW IN)[[:space:]].*${escaped}([[:space:]]|$)" <<< "$status"'
    if path.endswith('maintenance-update-firewall.sh'):
        old = 'grep -qE "^${port}(/tcp)?([[:space:]]+\\\\(v6\\\\))?[[:space:]]+(ALLOW|ALLOW IN)[[:space:]].*${escaped_range}([[:space:]]|$)" <<< "$status"'
        new = 'grep -qE "^${port}/tcp([[:space:]]+\\\\(v6\\\\))?[[:space:]]+(ALLOW|ALLOW IN)[[:space:]].*${escaped_range}([[:space:]]|$)" <<< "$status"'
        indent = '            '
    else:
        new = 'grep -qE "^${port}/tcp([[:space:]]+\\\\(v6\\\\))?[[:space:]]+(ALLOW|ALLOW IN)[[:space:]].*${escaped}([[:space:]]|$)" <<< "$status"'
        indent = '        '
    if old not in text:
        raise SystemExit(f'port matcher not found in {path}')
    text = text.replace(old, new, 1)
    old_rule = indent + 'rule_num="${BASH_REMATCH[1]}"\n' + indent + 'cidr="$(_ufw_line_cidr "$line" || true)"\n'
    new_rule = (
        indent + 'rule_num="${BASH_REMATCH[1]}"\n'
        + indent + 'if [[ -z "${BASH_REMATCH[3]}" ]]; then\n'
        + indent + '    printf \'%s\\n\' "$rule_num"\n'
        + indent + '    continue\n'
        + indent + 'fi\n'
        + indent + 'cidr="$(_ufw_line_cidr "$line" || true)"\n'
    )
    if old_rule not in text:
        raise SystemExit(f'conflict rule anchor not found in {path}')
    text = text.replace(old_rule, new_rule, 1)
    p.write_text(text)

p = Path('tests/suites/operations/case-firewall-update.bash')
text = p.read_text()
restricted_anchor = '''reset_case restricted-final-verification
'''
updater_case = '''reset_case non-tcp-ingress-conflict
write_ipv4_status true true
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 4] 80 ALLOW IN 203.0.113.0/24
EOF_RULES
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "non-TCP ingress reconciliation failed with $CASE_RC"
assert_call '--force delete 4'

'''
if restricted_anchor not in text:
    raise SystemExit('restricted final verification anchor not found')
text = text.replace(restricted_anchor, updater_case + restricted_anchor, 1)
setup_anchor = '''reset_case setup-single-cidr-failure
'''
setup_cases = '''reset_case setup-non-tcp-readiness
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW IN Anywhere
80/tcp ALLOW IN 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW IN Anywhere
[ 2] 80/tcp ALLOW IN 203.0.113.0/24
[ 3] 443/tcp ALLOW IN 203.0.113.0/24
[ 4] 443 ALLOW IN 203.0.113.0/24
EOF_RULES
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "initial UFW readiness accepted non-TCP port 443 ingress"
assert_file_contains "$LOG_FILE" 'Conflicting public or stale managed UFW 80/443 rules remain'

reset_case setup-bare-port-needs-tcp
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
80 ALLOW IN 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
EOF_STATUS
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=ensure "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -eq 0 ]] || fail "initial UFW TCP convergence returned $SETUP_UFW_RC"
assert_call 'port 80 comment CF-IPv4'

reset_case setup-single-cidr-failure
'''
if setup_anchor not in text:
    raise SystemExit('setup single CIDR anchor not found')
text = text.replace(setup_anchor, setup_cases, 1)
p.write_text(text)
