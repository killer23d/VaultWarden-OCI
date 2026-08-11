from pathlib import Path


def replace_all(path, old, new, expected, label):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != expected:
        raise SystemExit(f"{label}: expected {expected} anchors in {path}, found {count}")
    p.write_text(text.replace(old, new))


def replace_once(path, old, new, label):
    replace_all(path, old, new, 1, label)


# Exact admission proof must never confuse UFW ALLOW OUT with inbound access.
replace_once(
    'utilities/setup-firewall.sh',
    '''        [[ "${fields[$i]:-}" == "ALLOW" ]] || continue
        i=$((i + 1))
        if [[ "${fields[$i]:-}" == "IN" ]]; then
            i=$((i + 1))
        fi

        for (( ; i<${#fields[@]}; i++ )); do
''',
    '''        [[ "${fields[$i]:-}" == "ALLOW" ]] || continue
        i=$((i + 1))
        [[ "${fields[$i]:-}" == "IN" ]] || continue
        i=$((i + 1))

        for (( ; i<${#fields[@]}; i++ )); do
''',
    'setup range direction',
)
replace_once(
    'utilities/maintenance-update-firewall.sh',
    '''            [[ "${fields[$i]:-}" == "ALLOW" ]] || continue
            i=$((i + 1))
            if [[ "${fields[$i]:-}" == "IN" ]]; then
                i=$((i + 1))
            fi

            for (( ; i<${#fields[@]}; i++ )); do
''',
    '''            [[ "${fields[$i]:-}" == "ALLOW" ]] || continue
            i=$((i + 1))
            [[ "${fields[$i]:-}" == "IN" ]] || continue
            i=$((i + 1))

            for (( ; i<${#fields[@]}; i++ )); do
''',
    'updater range direction',
)
for path in ('utilities/setup-firewall.sh', 'utilities/maintenance-update-firewall.sh'):
    replace_once(
        path,
        '''(ALLOW|LIMIT)([[:space:]]+IN)?([[:space:]]|$)''',
        '''(ALLOW|LIMIT)[[:space:]]+IN([[:space:]]|$)''',
        f'{path} conflict direction',
    )

replace_once(
    'utilities/setup-firewall.sh',
    '''grep -qE "^${port}/tcp([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?[[:space:]]+[^[:space:]#]+([[:space:]]|$)" <<< "$status"''',
    '''grep -qE "^${port}/tcp([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)[[:space:]]+IN[[:space:]]+[^[:space:]#]+([[:space:]]|$)" <<< "$status"''',
    'SSH ingress direction',
)

# Updater: an outbound web allow for the current CIDR is not an inbound CF rule.
replace_once(
    'tests/suites/operations/case-firewall-update.bash',
    '''reset_case only-port-443
write_ipv4_status false true
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "port 443-only convergence failed with $CASE_RC"
assert_call 'port 80 comment CF-IPv4'
assert_no_call 'port 443 comment'

''',
    '''reset_case only-port-443
write_ipv4_status false true
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "port 443-only convergence failed with $CASE_RC"
assert_call 'port 80 comment CF-IPv4'
assert_no_call 'port 443 comment'

reset_case outbound-web-not-ingress
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
80/tcp ALLOW OUT 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 9] 80/tcp ALLOW OUT 203.0.113.0/24
[10] 443/tcp ALLOW IN 203.0.113.0/24
EOF_RULES
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "outbound-only web rule convergence failed with $CASE_RC"
assert_call 'port 80 comment CF-IPv4'
assert_no_call '--force delete 9'

''',
    'updater outbound web regression',
)

# Setup verifier: outbound SSH/web rules cannot satisfy inbound readiness proof.
replace_once(
    'tests/suites/operations/case-firewall-update.bash',
    '''reset_case setup-non-tcp-readiness
''',
    '''reset_case setup-outbound-ssh-not-admin
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW OUT Anywhere
80/tcp ALLOW IN 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW OUT Anywhere
[ 2] 80/tcp ALLOW IN 203.0.113.0/24
[ 3] 443/tcp ALLOW IN 203.0.113.0/24
EOF_RULES
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "outbound SSH allow satisfied inbound administrator proof"
assert_file_contains "$LOG_FILE" 'Explicit UFW SSH ALLOW/LIMIT rule for 22/tcp is missing'

reset_case setup-outbound-web-not-ingress
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW IN 198.51.100.10/32
80/tcp ALLOW OUT 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW IN 198.51.100.10/32
[ 2] 80/tcp ALLOW OUT 203.0.113.0/24
[ 3] 443/tcp ALLOW IN 203.0.113.0/24
EOF_RULES
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "outbound port-80 allow satisfied Cloudflare ingress proof"
assert_file_contains "$LOG_FILE" 'Missing Cloudflare UFW rule: 203.0.113.0/24 -> 80/tcp'

reset_case setup-non-tcp-readiness
''',
    'setup outbound direction regressions',
)
