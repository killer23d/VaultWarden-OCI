from pathlib import Path

p = Path('docker-compose.yml.example')
t = p.read_text()
old = '''    # Caddy is started by vaultwarden-startup.service only after the
    # Docker packet-path firewall gate has reconciled. Do not let dockerd
    # auto-restart this public listener before that gate exists.
    restart: "no"
'''
new = '''    # Caddy is started by vaultwarden-startup.service only after the Docker
    # packet-path firewall gate has reconciled. on-failure recovers an
    # independent Caddy crash but does not auto-start the listener when dockerd
    # itself restarts, so the firewall/startup ordering remains authoritative.
    restart: on-failure
'''
if old not in t:
    raise SystemExit('Caddy restart-policy anchor missing')
p.write_text(t.replace(old, new, 1))

p = Path('utilities/setup-systemd.sh')
t = p.read_text()
t = t.replace(
    '# Caddy has restart: "no" so dockerd cannot publish it before this sequence.\n',
    '# Caddy uses restart: on-failure, which does not auto-start on dockerd restart.\n',
    1,
)
p.write_text(t)

p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
old = '''assert_file_contains "$caddy_block" 'restart: "no"'
! grep -Fq 'restart: unless-stopped' "$caddy_block" \
    || fail "Caddy can auto-restart before Docker firewall reconciliation"
'''
new = '''assert_file_contains "$caddy_block" 'restart: on-failure'
! grep -Eq 'restart:[[:space:]]+(always|unless-stopped)' "$caddy_block" \
    || fail "Caddy can auto-start on dockerd restart before firewall reconciliation"
'''
if old not in t:
    raise SystemExit('Caddy restart-policy test anchor missing')
t = t.replace(old, new, 1)

old = '''# Caddy has restart: "no" so dockerd cannot publish it before this sequence.
'''
new = '''# Caddy uses restart: on-failure, which does not auto-start on dockerd restart.
'''
if old not in t:
    raise SystemExit('Docker drop-in fixture comment anchor missing')
t = t.replace(old, new, 1)
p.write_text(t)
