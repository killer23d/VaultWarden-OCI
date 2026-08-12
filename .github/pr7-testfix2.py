from pathlib import Path

p = Path('tests/suites/security/case-secrets.bash')
t = p.read_text()
old = '''# Re-source to restore the real backing verifier, then verify root-only cleanup.
source "$ROOT/lib/crypto.sh"
workspace="$(create_sensitive_workspace test-cleanup)" || fail 'could not create verified volatile workspace on Noble runner'
'''
new = '''# Switch the verifier test double to "acceptable" for the cleanup-only assertion.
# lib/crypto.sh is source-guarded, so a second source would intentionally not replace it.
_sensitive_backing_is_volatile() { return 0; }
workspace="$(create_sensitive_workspace test-cleanup)" || fail 'could not create root-only workspace for cleanup regression'
'''
if old in t:
    t = t.replace(old, new, 1)
elif '_sensitive_backing_is_volatile() { return 0; }' not in t:
    raise SystemExit('workspace test reset contract not found')
p.write_text(t)
