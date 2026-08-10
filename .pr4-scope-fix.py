from pathlib import Path
import re

# Scope every managed Docker web rule to the pinned caddy_external subnet so
# unrelated Docker workloads publishing 80/443 fall through this project chain.
p = Path('lib/firewall.sh')
t = p.read_text()
anchor = 'readonly VW_CF_DOCKER_CHAIN="VW-CF-INGRESS"\n'
if anchor not in t:
    raise SystemExit('firewall constant anchor missing')
t = t.replace(anchor, anchor + 'readonly VW_CADDY_EXTERNAL_CIDR="172.22.0.0/28"\n', 1)

replacements = {
    '''                -s "$cidr" -p tcp -m conntrack --ctorigdstport "$port" -j RETURN \\
''': '''                -d "$VW_CADDY_EXTERNAL_CIDR" -s "$cidr" -p tcp -m conntrack --ctorigdstport "$port" -j RETURN \\
''',
    '''            -p tcp -m conntrack --ctorigdstport "$port" -j DROP \\
''': '''            -d "$VW_CADDY_EXTERNAL_CIDR" -p tcp -m conntrack --ctorigdstport "$port" -j DROP \\
''',
    '''        -p tcp -m conntrack --ctorigdstport 443 -j DROP || return $?\n''': '''        -d "$VW_CADDY_EXTERNAL_CIDR" -p tcp -m conntrack --ctorigdstport 443 -j DROP || return $?\n''',
    '''        -p tcp -m conntrack --ctorigdstport 80 -j DROP || return $?\n''': '''        -d "$VW_CADDY_EXTERNAL_CIDR" -p tcp -m conntrack --ctorigdstport 80 -j DROP || return $?\n''',
    '''                -s "$cidr" -p tcp -m conntrack --ctorigdstport "$port" -j RETURN \\
                || return $?\n''': '''                -d "$VW_CADDY_EXTERNAL_CIDR" -s "$cidr" -p tcp -m conntrack --ctorigdstport "$port" -j RETURN \\
                || return $?\n''',
}
for old, new in replacements.items():
    if old in t:
        t = t.replace(old, new)

# Verify all four logical command sites were actually scoped.
if t.count('-d "$VW_CADDY_EXTERNAL_CIDR"') < 4:
    raise SystemExit('expected Docker gate destination scoping was not applied')
t = t.replace(
    '    # Put fail-closed sentinels at the front before replacing any existing\n',
    '    # Put fail-closed, project-scoped sentinels at the front before replacing\n    # any existing managed rules. Unrelated Docker destinations fall through.\n',
    1,
)
t = t.replace(
    '    log_success "Docker-published TCP 80/443 restricted to current Cloudflare IPv4 ranges without ACCEPT shortcuts"\n',
    '    log_success "Project Caddy TCP 80/443 restricted to current Cloudflare IPv4 ranges without ACCEPT shortcuts"\n',
    1,
)
p.write_text(t)

# Normalize the updater's inactive-UFW defaults parser. The staged review fix
# accidentally rendered a carriage-return escape as a split regex line.
p = Path('utilities/maintenance-update-firewall.sh')
t = p.read_text()
pattern = re.compile(r'(?ms)^    _ufw_default_incoming_fail_closed\(\) \{.*?^    \}\n')
replacement = r'''    _ufw_default_incoming_fail_closed() {
        local verbose_status="$1" defaults_file="${UFW_DEFAULTS_FILE:-/etc/default/ufw}" policy=""
        if grep -Eqi '^Default:[[:space:]]+(deny|reject)[[:space:]]+\(incoming\)' <<< "$verbose_status"; then
            return 0
        fi
        if grep -Eq '^Status:[[:space:]]+inactive' <<< "$verbose_status" && [[ -r "$defaults_file" ]]; then
            policy="$(awk -F= '
                $1 ~ /^[[:space:]]*DEFAULT_INPUT_POLICY[[:space:]]*$/ {
                    value=$2
                    gsub(/^[[:space:]\"]+|[[:space:]\"]+$/, "", value)
                    print toupper(value)
                    exit
                }
            ' "$defaults_file")"
            [[ "$policy" == "DROP" || "$policy" == "REJECT" ]] && return 0
        fi
        log_error "UFW default incoming policy is not provably fail-closed (deny/reject)."
        log_error "Remediation: sudo ufw default deny incoming; then review 'sudo ufw status verbose'."
        return 1
    }
'''
t, count = pattern.subn(replacement, t, count=1)
if count != 1:
    raise SystemExit(f'updater default policy helper replacement failed: {count}')
p.write_text(t)

# Update permanent regression coverage for project scoping.
p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
changes = {
    '''assert_file_contains "$FIREWALL_LIB" 'VW_CF_DOCKER_CHAIN="VW-CF-INGRESS"'\n''': '''assert_file_contains "$FIREWALL_LIB" 'VW_CF_DOCKER_CHAIN="VW-CF-INGRESS"'\nassert_file_contains "$FIREWALL_LIB" 'VW_CADDY_EXTERNAL_CIDR="172.22.0.0/28"'\n''',
    '''assert_file_contains "$IPT_CF_FILE" '-s 203.0.113.0/24 -p tcp -m conntrack --ctorigdstport 80 -j RETURN'\n''': '''assert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -s 203.0.113.0/24 -p tcp -m conntrack --ctorigdstport 80 -j RETURN'\n''',
    '''assert_file_contains "$IPT_CF_FILE" '-s 203.0.113.0/24 -p tcp -m conntrack --ctorigdstport 443 -j RETURN'\n''': '''assert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -s 203.0.113.0/24 -p tcp -m conntrack --ctorigdstport 443 -j RETURN'\n''',
    '''assert_file_contains "$IPT_CF_FILE" '-p tcp -m conntrack --ctorigdstport 80 -j DROP'\n''': '''assert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 80 -j DROP'\n''',
    '''assert_file_contains "$IPT_CF_FILE" '-p tcp -m conntrack --ctorigdstport 443 -j DROP'\n''': '''assert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 443 -j DROP'\n''',
    '''export IPT_FAIL_MATCH='VW-CF-INGRESS 1 -p tcp -m conntrack --ctorigdstport 443 -j DROP'\n''': '''export IPT_FAIL_MATCH='VW-CF-INGRESS 1 -d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 443 -j DROP'\n''',
}
for old, new in changes.items():
    if old not in t:
        raise SystemExit(f'test anchor missing: {old.strip()}')
    t = t.replace(old, new, 1)

static_anchor = '''! grep -Fq -- '-j ACCEPT' "$IPT_CF_FILE" || fail "Cloudflare gate bypasses Docker isolation with ACCEPT"\n'''
static_extra = '''! grep -Fq -- '-j ACCEPT' "$IPT_CF_FILE" || fail "Cloudflare gate bypasses Docker isolation with ACCEPT"
while IFS= read -r managed_rule; do
    [[ "$managed_rule" == *'--ctorigdstport '* ]] || continue
    [[ "$managed_rule" == *'-d 172.22.0.0/28 '* ]] \
        || fail "managed Docker web rule is not scoped to caddy_external: $managed_rule"
done < "$IPT_CF_FILE"
! grep -Eq '^-A VW-CF-INGRESS (?!.*-d 172\\.22\\.0\\.0/28).*--ctorigdstport' "$IPT_CF_FILE" 2>/dev/null \
    || fail "unscoped Docker web gate could affect unrelated workloads"
'''
# Avoid relying on grep PCRE-negative-lookahead; the while-loop above is the
# authoritative assertion. Keep only that portable check.
static_extra = static_extra.split("! grep -Eq", 1)[0]
if static_anchor not in t:
    raise SystemExit('gate static assertion anchor missing')
t = t.replace(static_anchor, static_extra, 1)

compose_anchor = '''assert_file_contains "$compose_file" '"0.0.0.0:443:443"'\n'''
compose_extra = '''assert_file_contains "$compose_file" '"0.0.0.0:443:443"'
assert_file_contains "$compose_file" 'subnet: 172.22.0.0/28'
'''
if compose_anchor not in t:
    raise SystemExit('compose scoping test anchor missing')
t = t.replace(compose_anchor, compose_extra, 1)
p.write_text(t)
