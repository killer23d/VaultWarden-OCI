from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"{label} anchor missing in {path}")
    p.write_text(text.replace(old, new, 1))


# UFW status renders ordinary inbound rules without a literal IN token. Treat
# OUT as outbound, FWD as routed/ambiguous, and both implicit direction and
# explicit IN as inbound.
for path, indent in (
    ('utilities/setup-firewall.sh', '        '),
    ('utilities/maintenance-update-firewall.sh', '            '),
):
    old = f'''{indent}[[ "${{fields[$i]:-}}" == "ALLOW" ]] || continue\n{indent}i=$((i + 1))\n{indent}[[ "${{fields[$i]:-}}" == "IN" ]] || continue\n{indent}i=$((i + 1))\n\n{indent}for (( ; i<${{#fields[@]}}; i++ )); do\n'''
    new = f'''{indent}[[ "${{fields[$i]:-}}" == "ALLOW" ]] || continue\n{indent}i=$((i + 1))\n{indent}case "${{fields[$i]:-}}" in\n{indent}    OUT|FWD) continue ;;\n{indent}    IN) i=$((i + 1)) ;;\n{indent}esac\n\n{indent}for (( ; i<${{#fields[@]}}; i++ )); do\n'''
    replace_once(path, old, new, f'{path} range direction')

# Admin-rule proof gets the same token semantics and preserves restricted SSH.
replace_once(
    'utilities/setup-firewall.sh',
    '''_ufw_has_admin_port() {\n    local status="$1" port="$2"\n    # Preserve any explicit single-port TCP administrator rule, including a\n    # source-restricted ALLOW/LIMIT. PR4 must not widen an operator's SSH ACL.\n    grep -qE "^${port}/tcp([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)[[:space:]]+IN[[:space:]]+[^[:space:]#]+([[:space:]]|$)" <<< "$status"\n}\n''',
    '''_ufw_has_admin_port() {\n    local status="$1" port="$2" line i action\n    local -a fields=()\n    # UFW status omits a direction token for normal inbound rules. Preserve any\n    # explicit single-port TCP administrator rule unless it is OUT/FWD.\n    while IFS= read -r line; do\n        fields=()\n        read -ra fields <<< "$line"\n        (( ${#fields[@]} >= 3 )) || continue\n        [[ "${fields[0]}" == "${port}/tcp" ]] || continue\n        i=1\n        [[ "${fields[$i]:-}" == "(v6)" ]] && i=$((i + 1))\n        if [[ "${fields[$i]:-}" == "on" ]]; then\n            i=$((i + 2))\n        fi\n        action="${fields[$i]:-}"\n        [[ "$action" == "ALLOW" || "$action" == "LIMIT" ]] || continue\n        i=$((i + 1))\n        case "${fields[$i]:-}" in\n            OUT|FWD) continue ;;\n            IN) i=$((i + 1)) ;;\n        esac\n        [[ -n "${fields[$i]:-}" && "${fields[$i]}" != \\#* ]] && return 0\n    done <<< "$status"\n    return 1\n}\n''',
    'SSH status direction parser',
)

# Conflict collection must accept either implicit inbound or explicit IN while
# never treating OUT/FWD rows as inbound web admission.
for path in ('utilities/setup-firewall.sh', 'utilities/maintenance-update-firewall.sh'):
    p = Path(path)
    t = p.read_text()
    old = '''        [[ "$line" =~ ^\\[[[:space:]]*([0-9]+)\\][[:space:]]+(80|443)(/tcp)?([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)[[:space:]]+IN([[:space:]]|$) ]] || continue\n        rule_num="${BASH_REMATCH[1]}"\n        action="${BASH_REMATCH[6]}"\n'''
    if path.endswith('maintenance-update-firewall.sh'):
        old = old.replace('        ', '            ')
    indent = '        ' if path.endswith('setup-firewall.sh') else '            '
    new = f'''{indent}[[ "$line" =~ [[:space:]](ALLOW|LIMIT)[[:space:]]+(OUT|FWD)([[:space:]]|$) ]] && continue\n{indent}[[ "$line" =~ ^\\[[[:space:]]*([0-9]+)\\][[:space:]]+(80|443)(/tcp)?([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?([[:space:]]|$) ]] || continue\n{indent}rule_num="${{BASH_REMATCH[4]}}"\n{indent}action="${{BASH_REMATCH[9]}}"\n'''
    # The first regex contributes no persistent BASH_REMATCH once the second runs.
    # In the second regex: 1=rule number, 2=port, 3=/tcp, 4=(v6), 5=on iface,
    # 6=action, 7=optional IN, 8=separator. Use those actual indices.
    new = new.replace('${BASH_REMATCH[4]}', '${BASH_REMATCH[1]}').replace('${BASH_REMATCH[9]}', '${BASH_REMATCH[6]}')
    if old not in t:
        raise SystemExit(f'{path} conflict direction anchor missing')
    p.write_text(t.replace(old, new, 1))

# Ambiguity detection: OUT is not inbound; FWD remains deliberately rejected;
# ordinary inbound rules may render with no IN token.
for path, indent in (
    ('utilities/setup-firewall.sh', '        '),
    ('utilities/maintenance-update-firewall.sh', '            '),
):
    replace_once(
        path,
        f'''{indent}[[ "$body" =~ [[:space:]](ALLOW|LIMIT)[[:space:]]+(IN|FWD)([[:space:]]|$) ]] || continue\n\n{indent}# A single numeric port with an explicit protocol is unambiguous. Literal\n{indent}# web-port rows are handled separately by _ufw_collect_conflicts.\n{indent}if [[ "$body" =~ ^[0-9]+/(tcp|udp)([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)[[:space:]]+IN([[:space:]]|$) ]]; then\n{indent}    continue\n{indent}fi\n''',
        f'''{indent}[[ "$body" =~ [[:space:]](ALLOW|LIMIT)([[:space:]]|$) ]] || continue\n{indent}[[ "$body" =~ [[:space:]](ALLOW|LIMIT)[[:space:]]+OUT([[:space:]]|$) ]] && continue\n\n{indent}# A single numeric port with an explicit protocol is unambiguous. UFW\n{indent}# renders ordinary inbound rules with no direction token, but accepts an\n{indent}# explicit IN token as well. Routed/FWD rules remain ambiguous here.\n{indent}if [[ "$body" =~ ^[0-9]+/(tcp|udp)([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?([[:space:]]|$) ]]; then\n{indent}    continue\n{indent}fi\n''',
        f'{path} ambiguous direction parser',
    )

# Add real-format regressions: inbound status with no IN token must converge,
# while OUT still cannot satisfy the same proof.
p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
anchor = '''reset_case outbound-web-not-ingress\n'''
block = '''reset_case implicit-inbound-status\ncat > "$UFW_STATUS_FILE" <<'EOF_STATUS'\n80/tcp ALLOW 203.0.113.0/24\n443/tcp ALLOW 203.0.113.0/24\nEOF_STATUS\ncat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'\n[ 9] 80/tcp ALLOW 203.0.113.0/24\n[10] 443/tcp ALLOW 203.0.113.0/24\nEOF_RULES\nrun_case\n[[ "$CASE_RC" -eq 0 ]] || fail "implicit inbound UFW status failed convergence with $CASE_RC"\nassert_no_call 'port 80 comment'\nassert_no_call 'port 443 comment'\nassert_no_call '--force delete 9'\nassert_no_call '--force delete 10'\n\nreset_case outbound-web-not-ingress\n'''
if anchor not in t:
    raise SystemExit('implicit inbound updater test anchor missing')
t = t.replace(anchor, block, 1)
anchor = '''reset_case setup-outbound-ssh-not-admin\n'''
block = '''reset_case setup-implicit-inbound-readiness\ncat > "$UFW_STATUS_FILE" <<'EOF_STATUS'\nStatus: active\n22/tcp ALLOW 198.51.100.10/32\n80/tcp ALLOW 203.0.113.0/24\n443/tcp ALLOW 203.0.113.0/24\nEOF_STATUS\ncat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'\n[ 1] 22/tcp ALLOW 198.51.100.10/32\n[ 2] 80/tcp ALLOW 203.0.113.0/24\n[ 3] 443/tcp ALLOW 203.0.113.0/24\nEOF_RULES\nPATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1 \\\n    || fail "setup rejected normal implicit-inbound UFW status output"\n\nreset_case setup-outbound-ssh-not-admin\n'''
if anchor not in t:
    raise SystemExit('implicit inbound setup test anchor missing')
p.write_text(t.replace(anchor, block, 1))
