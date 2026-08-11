from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"{label} anchor missing in {path}")
    p.write_text(text.replace(old, new, 1))


# UFW status renders ordinary inbound rules without a literal IN token. OUT is
# outbound, FWD is routed/ambiguous, and both implicit direction and explicit
# IN are treated as inbound.
replace_once(
    'utilities/setup-firewall.sh',
    '''        [[ "${fields[$i]:-}" == "ALLOW" ]] || continue
        i=$((i + 1))
        [[ "${fields[$i]:-}" == "IN" ]] || continue
        i=$((i + 1))

        for (( ; i<${#fields[@]}; i++ )); do
''',
    '''        [[ "${fields[$i]:-}" == "ALLOW" ]] || continue
        i=$((i + 1))
        case "${fields[$i]:-}" in
            OUT|FWD) continue ;;
            IN) i=$((i + 1)) ;;
        esac

        for (( ; i<${#fields[@]}; i++ )); do
''',
    'setup range direction',
)
replace_once(
    'utilities/maintenance-update-firewall.sh',
    '''            [[ "${fields[$i]:-}" == "ALLOW" ]] || continue
            i=$((i + 1))
            [[ "${fields[$i]:-}" == "IN" ]] || continue
            i=$((i + 1))

            for (( ; i<${#fields[@]}; i++ )); do
''',
    '''            [[ "${fields[$i]:-}" == "ALLOW" ]] || continue
            i=$((i + 1))
            case "${fields[$i]:-}" in
                OUT|FWD) continue ;;
                IN) i=$((i + 1)) ;;
            esac

            for (( ; i<${#fields[@]}; i++ )); do
''',
    'updater range direction',
)

replace_once(
    'utilities/setup-firewall.sh',
    '''_ufw_has_admin_port() {
    local status="$1" port="$2"
    # Preserve any explicit single-port TCP administrator rule, including a
    # source-restricted ALLOW/LIMIT. PR4 must not widen an operator's SSH ACL.
    grep -qE "^${port}/tcp([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)[[:space:]]+IN[[:space:]]+[^[:space:]#]+([[:space:]]|$)" <<< "$status"
}
''',
    '''_ufw_has_admin_port() {
    local status="$1" port="$2" line i action
    local -a fields=()
    # UFW status omits a direction token for normal inbound rules. Preserve any
    # explicit single-port TCP administrator rule unless it is OUT/FWD.
    while IFS= read -r line; do
        fields=()
        read -ra fields <<< "$line"
        (( ${#fields[@]} >= 3 )) || continue
        [[ "${fields[0]}" == "${port}/tcp" ]] || continue
        i=1
        [[ "${fields[$i]:-}" == "(v6)" ]] && i=$((i + 1))
        if [[ "${fields[$i]:-}" == "on" ]]; then
            i=$((i + 2))
        fi
        action="${fields[$i]:-}"
        [[ "$action" == "ALLOW" || "$action" == "LIMIT" ]] || continue
        i=$((i + 1))
        case "${fields[$i]:-}" in
            OUT|FWD) continue ;;
            IN) i=$((i + 1)) ;;
        esac
        [[ -n "${fields[$i]:-}" && "${fields[$i]}" != \#* ]] && return 0
    done <<< "$status"
    return 1
}
''',
    'SSH status direction parser',
)

# Literal web conflict collection accepts implicit inbound or explicit IN, but
# ignores OUT/FWD rows as inbound admission candidates.
replace_once(
    'utilities/setup-firewall.sh',
    '''        [[ "$line" =~ ^\\[[[:space:]]*([0-9]+)\\][[:space:]]+(80|443)(/tcp)?([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)[[:space:]]+IN([[:space:]]|$) ]] || continue
        rule_num="${BASH_REMATCH[1]}"
        action="${BASH_REMATCH[6]}"
''',
    '''        [[ "$line" =~ [[:space:]](ALLOW|LIMIT)[[:space:]]+(OUT|FWD)([[:space:]]|$) ]] && continue
        [[ "$line" =~ ^\\[[[:space:]]*([0-9]+)\\][[:space:]]+(80|443)(/tcp)?([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?([[:space:]]|$) ]] || continue
        rule_num="${BASH_REMATCH[1]}"
        action="${BASH_REMATCH[6]}"
''',
    'setup conflict direction',
)
replace_once(
    'utilities/maintenance-update-firewall.sh',
    '''            [[ "$line" =~ ^\\[[[:space:]]*([0-9]+)\\][[:space:]]+(80|443)(/tcp)?([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)[[:space:]]+IN([[:space:]]|$) ]] || continue
            rule_num="${BASH_REMATCH[1]}"
            action="${BASH_REMATCH[6]}"
''',
    '''            [[ "$line" =~ [[:space:]](ALLOW|LIMIT)[[:space:]]+(OUT|FWD)([[:space:]]|$) ]] && continue
            [[ "$line" =~ ^\\[[[:space:]]*([0-9]+)\\][[:space:]]+(80|443)(/tcp)?([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?([[:space:]]|$) ]] || continue
            rule_num="${BASH_REMATCH[1]}"
            action="${BASH_REMATCH[6]}"
''',
    'updater conflict direction',
)

# Ambiguous-rule safety treats OUT as non-inbound, continues to reject FWD,
# and allows simple numeric/protocol inbound rows with implicit or explicit IN.
for path, indent in (
    ('utilities/setup-firewall.sh', '        '),
    ('utilities/maintenance-update-firewall.sh', '            '),
):
    replace_once(
        path,
        f'''{indent}[[ "$body" =~ [[:space:]](ALLOW|LIMIT)[[:space:]]+(IN|FWD)([[:space:]]|$) ]] || continue
''',
        f'''{indent}[[ "$body" =~ [[:space:]](ALLOW|LIMIT)([[:space:]]|$) ]] || continue
{indent}[[ "$body" =~ [[:space:]](ALLOW|LIMIT)[[:space:]]+OUT([[:space:]]|$) ]] && continue
''',
        f'{path} ambiguity action/direction',
    )
    replace_once(
        path,
        f'''{indent}if [[ "$body" =~ ^[0-9]+/(tcp|udp)([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)[[:space:]]+IN([[:space:]]|$) ]]; then
''',
        f'''{indent}if [[ "$body" =~ ^[0-9]+/(tcp|udp)([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?([[:space:]]|$) ]]; then
''',
        f'{path} simple inbound ambiguity exemption',
    )

# Real-format regressions: normal inbound status without IN must converge,
# while OUT still cannot satisfy the same proof.
p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
anchor = '''reset_case outbound-web-not-ingress
'''
block = '''reset_case implicit-inbound-status
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
80/tcp ALLOW 203.0.113.0/24
443/tcp ALLOW 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 9] 80/tcp ALLOW 203.0.113.0/24
[10] 443/tcp ALLOW 203.0.113.0/24
EOF_RULES
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "implicit inbound UFW status failed convergence with $CASE_RC"
assert_no_call 'port 80 comment'
assert_no_call 'port 443 comment'
assert_no_call '--force delete 9'
assert_no_call '--force delete 10'

reset_case outbound-web-not-ingress
'''
if anchor not in t:
    raise SystemExit('implicit inbound updater test anchor missing')
t = t.replace(anchor, block, 1)
anchor = '''reset_case setup-outbound-ssh-not-admin
'''
block = '''reset_case setup-implicit-inbound-readiness
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW 198.51.100.10/32
80/tcp ALLOW 203.0.113.0/24
443/tcp ALLOW 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW 198.51.100.10/32
[ 2] 80/tcp ALLOW 203.0.113.0/24
[ 3] 443/tcp ALLOW 203.0.113.0/24
EOF_RULES
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1 \
    || fail "setup rejected normal implicit-inbound UFW status output"

reset_case setup-outbound-ssh-not-admin
'''
if anchor not in t:
    raise SystemExit('implicit inbound setup test anchor missing')
p.write_text(t.replace(anchor, block, 1))
