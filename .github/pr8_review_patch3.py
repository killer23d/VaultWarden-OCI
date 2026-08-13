from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}")
    p.write_text(text.replace(old, new, 1))


# The metadata-only pass establishes _SS_MODE without loading environment data.
# Load defaults next, then parse the full CLI so explicit operator values win.
replace_once(
    "utilities/setup-storage.sh",
    '''main() {
    _ss_dispatch_metadata "$@"
    _parse_outer_args "$@"
    _ss_load_environment

    if [[ "${_SS_MODE}" == "migrate" ]]; then
''',
    '''main() {
    _ss_dispatch_metadata "$@"
    _ss_load_environment
    _parse_outer_args "$@"

    if [[ "${_SS_MODE}" == "migrate" ]]; then
''',
)

# Complete the DNS fixture and remove a redundant test-only assignment.
p = Path("tests/suites/foundation/case-runtime-authority.bash")
text = p.read_text()
text = text.replace('setup_storage="$(cat utilities/setup-storage.sh)"\n', '', 1)
old_dns = '''DOMAIN=https://dns-authority.example.test
UPDATE_DNS=true
DNS_UPDATE_REQUIRED=true
'''
new_dns = '''DOMAIN=https://dns-authority.example.test
PUID=1000
PGID=1000
UPDATE_DNS=true
DNS_UPDATE_REQUIRED=true
'''
if text.count(old_dns) != 1:
    raise SystemExit(f"case-runtime-authority: DNS env marker count {text.count(old_dns)}")
text = text.replace(old_dns, new_dns, 1)

lines = text.splitlines()
try:
    start = next(i for i, line in enumerate(lines) if line.startswith('storage_parse_pos='))
    end = next(i for i in range(start, len(lines)) if lines[i] == 'pass "setup-storage first-install path uses authoring authority without runtime fallback noise"')
except StopIteration as exc:
    raise SystemExit("case-runtime-authority: storage ordering block not found") from exc
lines[start:end + 1] = [
    'storage_metadata_pos="$(grep -n \'    _ss_dispatch_metadata "$@"\' utilities/setup-storage.sh | head -1 | cut -d: -f1)"',
    'storage_load_pos="$(grep -n \'    _ss_load_environment\' utilities/setup-storage.sh | head -1 | cut -d: -f1)"',
    'storage_parse_pos="$(grep -n \'    _parse_outer_args "$@"\' utilities/setup-storage.sh | head -1 | cut -d: -f1)"',
    '[[ -n "$storage_metadata_pos" && -n "$storage_load_pos" && -n "$storage_parse_pos" && "$storage_metadata_pos" -lt "$storage_load_pos" && "$storage_load_pos" -lt "$storage_parse_pos" ]] || fail "setup-storage must resolve mode metadata, load mode-appropriate defaults, then let CLI parsing win"',
    'pass "setup-storage first-install path uses authoring authority without runtime fallback noise"',
]
p.write_text('\n'.join(lines) + '\n')

# Both backup branches must use canonical-key remediation. patch2 fixes one exact
# indentation variant; replace any remaining copy regardless of indentation.
p = Path("utilities/backup-run.sh")
text = p.read_text()
text = text.replace(
    'Set SOPS_AGE_KEY_FILE in .env, or place the key at /etc/vaultwarden/age-key.txt',
    'Restore the operational Age key at /etc/vaultwarden/age-key.txt, then re-run the backup.',
)
p.write_text(text)

# Storage tests should reference the new loader name, but preserve the established
# precedence contract: metadata -> mode-specific defaults -> full CLI parse.
p = Path("tests/suites/foundation/case-storage-setup.bash")
text = p.read_text().replace('_ss_load_runtime_environment', '_ss_load_environment')
text = text.replace(
    'dispatch metadata, load env defaults, parse outer CLI, parse migration once, resolve, then execute',
    'dispatch metadata, load mode-appropriate env defaults, parse outer CLI, parse migration once, resolve, then execute',
)
p.write_text(text)
