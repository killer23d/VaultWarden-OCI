from pathlib import Path

path = Path('tests/suites/foundation/case-storage-setup.bash')
text = path.read_text()
old = 'assert_output "v3.13.2" \\\n    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-default-version'
new = 'assert_output "v3.13.3" \\\n    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-default-version'
if text.count(old) != 1:
    raise SystemExit(f'expected one SOPS default assertion, found {text.count(old)}')
path.write_text(text.replace(old, new, 1))
print('Aligned foundation SOPS default assertion to v3.13.3.')
