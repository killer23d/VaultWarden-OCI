from pathlib import Path

p = Path('utilities/maintenance-update-firewall.sh')
t = p.read_text()
anchor = '''    require_root "$@"

    log_info "Safely updating Cloudflare IP ranges in UFW and Docker ingress filtering..."
'''
replacement = '''    require_root "$@"

    local ssh_port
    ssh_port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
    if [[ -z "$ssh_port" ]]; then
        ssh_port="$(awk '/^Port[[:space:]]/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
    fi
    ssh_port="${ssh_port:-22}"
    if [[ "$ssh_port" == "80" || "$ssh_port" == "443" ]]; then
        log_error "SSH port ${ssh_port}/tcp conflicts with managed Cloudflare web ingress."
        log_error "Move SSH to a dedicated non-web port before updating firewall rules."
        return 1
    fi

    log_info "Safely updating Cloudflare IP ranges in UFW and Docker ingress filtering..."
'''
if anchor not in t:
    raise SystemExit('updater root/log anchor not found')
p.write_text(t.replace(anchor, replacement, 1))

p = Path('lib/firewall.sh')
t = p.read_text()
t = t.replace(
    '''    # Put fail-closed, project-scoped sentinels at the front before replacing
    # any existing managed rules. Unrelated Docker destinations fall through.
    # managed rules. A failed refresh may temporarily block web traffic, but it
    # cannot leave the origin publicly exposed.
''',
    '''    # Put fail-closed, project-scoped sentinels at the front before replacing
    # existing managed rules. A failed refresh may temporarily block project web
    # traffic, but unrelated Docker destinations fall through and the origin is
    # never left publicly exposed.
''',
    1,
)
p.write_text(t)

p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
anchor = '''cat > "$TMP/bin/curl" <<'EOF_CURL'
'''
ssh_mock = '''cat > "$TMP/bin/sshd" <<'EOF_SSHD_UPDATER'
#!/usr/bin/env bash
if [[ "${1:-}" == "-T" ]]; then
    printf 'port %s\\n' "${SSHD_PORT:-22}"
    exit 0
fi
exit 2
EOF_SSHD_UPDATER
chmod 0755 "$TMP/bin/sshd"

cat > "$TMP/bin/curl" <<'EOF_CURL'
'''
if anchor not in t:
    raise SystemExit('curl mock anchor not found')
t = t.replace(anchor, ssh_mock, 1)

anchor = '''    unset FW_PREFLIGHT_RC FW_EXACT_RC FW_RECONCILE_RC

    export CASE_DIR CF_IPV4_FILE CF_IPV6_FILE UFW_STATUS_FILE UFW_NUMBERED_FILE
'''
replacement = '''    unset FW_PREFLIGHT_RC FW_EXACT_RC FW_RECONCILE_RC SSHD_PORT

    export CASE_DIR CF_IPV4_FILE CF_IPV6_FILE UFW_STATUS_FILE UFW_NUMBERED_FILE
'''
if anchor not in t:
    raise SystemExit('reset-case unset anchor not found')
t = t.replace(anchor, replacement, 1)

anchor = '''reset_case docker-preflight-failure
'''
ssh_cases = '''reset_case updater-ssh-port-80-collision
export SSHD_PORT=80
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "periodic updater accepted SSH on port 80"
assert_file_contains "$LOG_FILE" 'SSH port 80/tcp conflicts with managed Cloudflare web ingress'
[[ ! -s "$UFW_CALL_LOG" ]] || fail "periodic updater mutated UFW before rejecting SSH port 80"
[[ ! -s "$FW_CALL_LOG" ]] || fail "periodic updater touched Docker firewall before rejecting SSH port 80"

reset_case updater-ssh-port-443-collision
export SSHD_PORT=443
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "periodic updater accepted SSH on port 443"
assert_file_contains "$LOG_FILE" 'SSH port 443/tcp conflicts with managed Cloudflare web ingress'
[[ ! -s "$UFW_CALL_LOG" ]] || fail "periodic updater mutated UFW before rejecting SSH port 443"
[[ ! -s "$FW_CALL_LOG" ]] || fail "periodic updater touched Docker firewall before rejecting SSH port 443"

reset_case docker-preflight-failure
'''
if anchor not in t:
    raise SystemExit('first updater case anchor not found')
t = t.replace(anchor, ssh_cases, 1)
p.write_text(t)
