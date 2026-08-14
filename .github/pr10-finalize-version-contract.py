from pathlib import Path

p = Path('tests/suites/foundation/case-runner-contracts.bash')
text = p.read_text()

old = '''grep -Fq 'v3.13.2/sops-v3.13.2.linux.amd64' .github/workflows/doc-drift.yml \\
    || fail 'CI SOPS binary must match the production SOPS default version'
'''
new = '''sops_default="$(sed -n 's/^SOPS_DEFAULT_VERSION="\\([^"]*\\)"/\\1/p' utilities/setup-system.sh)"
[[ -n "$sops_default" ]] || fail 'setup-system SOPS default missing'
grep -Fq "${sops_default}/sops-${sops_default}.linux.amd64" .github/workflows/doc-drift.yml \\
    || fail 'CI SOPS binary must match the production SOPS default version'
'''
if text.count(old) != 1:
    raise SystemExit(f'expected one stale CI SOPS assertion, found {text.count(old)}')
text = text.replace(old, new, 1)

anchor = '''! grep -Fq 'SOPS_VERSION not pinned' utilities/setup-system.sh \\
    || fail 'normal setup must not resolve latest merely because SOPS_VERSION is blank'
'''
insert = anchor + '''grep -Fq '[[ "$USE_LATEST" == "true" ]] && _crowdsec_setup_cmd+=" --use-latest"' setup.sh \\
    || fail 'setup.sh must carry explicit latest mode into CrowdSec continuation guidance'
for latest_surface in setup.sh utilities/setup-system.sh utilities/setup-env.sh utilities/setup-crowdsec.sh; do
    grep -Fq -- '--use-latest' "$latest_surface" \\
        || fail "explicit --use-latest override missing from $latest_surface"
done
'''
if text.count(anchor) != 1:
    raise SystemExit(f'expected one SOPS normal-path anchor, found {text.count(anchor)}')
text = text.replace(anchor, insert, 1)

p.write_text(text)
print('Aligned repository-interface assertions with the scoped latest-version override.')
