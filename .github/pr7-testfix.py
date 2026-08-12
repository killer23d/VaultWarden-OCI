from pathlib import Path

p = Path('tests/suites/security/case-secrets.bash')
t = p.read_text()
old = '''! grep -Fq '7z' <(sed -n '/^_resolve_7zip_command()/,/^}/p' utilities/setup-system.sh | grep -v '7zz') \\
  || fail "setup dependency resolver retains 7z fallback"'''
new = '''! sed -n '/^_resolve_7zip_command()/,/^}/p' utilities/setup-system.sh \\
  | grep -Eq 'command -v[[:space:]]+7z([[:space:]]|$)' \\
  || fail "setup dependency resolver retains 7z executable fallback"'''
if old not in t:
    raise SystemExit('expected generated 7z fallback assertion not found')
p.write_text(t.replace(old, new, 1))
