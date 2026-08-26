#!/usr/bin/env python3
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]

def read(path): return (root / path).read_text(encoding='utf-8')
def write(path, text): (root / path).write_text(text, encoding='utf-8')

# Keep the developer --source guard, but decouple it from the supported --use-latest resolver.
p = 'vaultwarden_oci/update_appliance.py'
s = read(p)
s = s.replace('    DEVELOPMENT_ENV,\n', '')
s = s.replace('    resolve_latest_supported,\n', '    resolve_latest,\n')
s = s.replace('_LATEST_MARKER = ".latest."\n', '_LATEST_MARKER = ".latest."\nSOURCE_OVERRIDE_ENV = "VWOCI_SOURCE_OVERRIDE"\n')
s = s.replace('"""Yield a trusted stable release or an explicitly development-gated source."""', '"""Yield a trusted stable release or an explicitly source-override-gated local tree."""')
s = s.replace('os.environ.get(DEVELOPMENT_ENV)', 'os.environ.get(SOURCE_OVERRIDE_ENV)')
s = s.replace('f"--source is developer/testing-only; set {DEVELOPMENT_ENV}=1 explicitly"', 'f"--source is an explicit developer/test override; set {SOURCE_OVERRIDE_ENV}=1"')
s = s.replace('resolve_latest_supported(source_root, machine=machine)', 'resolve_latest(source_root, machine=machine)')
write(p, s)

# Move tests that explicitly exercise --source to the neutral override name.
for p in (root / 'tests').glob('*.py'):
    s = p.read_text(encoding='utf-8')
    s = s.replace('update_versions.DEVELOPMENT_ENV', 'update_appliance.SOURCE_OVERRIDE_ENV')
    s = s.replace('DEVELOPMENT_ENV', 'SOURCE_OVERRIDE_ENV')
    p.write_text(s, encoding='utf-8')

# Remove obsolete construction-state notes from the durable decisions without altering decisions.
p = 'docs/DECISIONS.md'
s = read(p)
s = s.replace('Historical phase/audit reports remain evidence and rationale, not competing product authority.', 'Historical audit reports remain evidence and rationale, not competing product authority.')
s = s.replace('Final normal product/repository surfaces must be release-neutral. Do not leave product-generation names, branch-stage names, `beta`, or phase labels in normal runtime/docs/file names.', 'Normal product/repository surfaces are release-neutral. Do not leave product-generation names, branch-stage names, preview labels, or implementation-stage labels in normal runtime/docs/file names.')
s = s.replace('Mass naming cleanup belongs to the dedicated naming workstream. Other tasks may document the end state but should not opportunistically rename the tree.', 'The repository follows this release-neutral end state; future changes must not reintroduce stage-era naming into normal product surfaces.')
s = re.sub(r'\n## Current implementation gaps are not new product decisions\n.*\Z', '\n', s, flags=re.S)
write(p, s)

# Normalize remaining stage-era test class/function identifiers and comments, while leaving real version values alone.
for p in list((root / 'vaultwarden_oci').glob('*.py')) + list((root / 'tests').glob('*.py')) + list((root / 'systemd').glob('*')):
    if not p.is_file():
        continue
    s = p.read_text(encoding='utf-8')
    s = re.sub(r'Phase([0-9]+)([A-Za-z_]*)', r'Release\1\2', s)
    s = re.sub(r'\bPhase\s+[0-9]+(?:[-–][0-9]+)?\b', 'pre-release implementation', s)
    p.write_text(s, encoding='utf-8')

# Keep historical prompt bodies unchanged; update only their own renamed path references.
for rel in ('reports/CODEX-PROMPTS.md', 'reports/REVIEW-PROMPTS.md'):
    p = root / rel
    s = p.read_text(encoding='utf-8')
    s = s.replace('reports/V2-CODEX-PROMPTS.md', 'reports/CODEX-PROMPTS.md')
    s = s.replace('reports/V2-REVIEW-PROMPTS.md', 'reports/REVIEW-PROMPTS.md')
    s = s.replace('reports/V2-TEST-STRATEGY.md', 'reports/TEST-STRATEGY.md')
    p.write_text(s, encoding='utf-8')

(root / '.github/scripts/fix-final-regressions.py').unlink()
(root / '.github/workflows/fix-final-regressions.yml').unlink()
