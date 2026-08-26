#!/usr/bin/env python3
from pathlib import Path
import re
root = Path(__file__).resolve().parents[2]

# Product boundary: current neutral authority names and current naming state.
p = root / 'docs/PROJECT-BOUNDARY.md'
s = p.read_text(encoding='utf-8')
s = s.replace('Normal final product/repository surfaces must be release-neutral. Product-generation, branch-stage, beta, or phase labels must not remain in normal runtime/docs/file names. Genuine technical schema/archive format version numbers remain valid. The dedicated naming-cleanup workstream owns mass renaming; do not opportunistically rename the tree as part of unrelated work.', 'Normal product/repository surfaces are release-neutral. Product-generation, branch-stage, preview, or implementation-stage labels must not appear in normal runtime/docs/file names. Genuine technical schema/archive/release format version values remain valid. Future changes must preserve this release-neutral state.')
s = s.replace('`docs/V2-DECISIONS.md` records the durable implementation decisions behind this boundary.', '`docs/DECISIONS.md` records the durable implementation decisions behind this boundary.')
p.write_text(s, encoding='utf-8')

# Release-surface test: keep useful legacy-owner absence checks, leave stage-name enforcement to CI.
p = root / 'tests/test_release_surface.py'
s = p.read_text(encoding='utf-8')
s = re.sub(r'\n    def test_superseded_stage_surfaces_are_absent\(self\) -> None:.*?\n    def test_fresh_install_template_matches_current_schema', '''\n    def test_superseded_legacy_owners_are_absent(self) -> None:\n        for relative in (\n            "CHANGELOG.md", "Makefile", "startup.sh", "backup.sh", "restore.sh",\n            "recover.sh", "maintenance.sh", "edit-secrets.sh", "lib", "utilities",\n            "tests/run-tests.sh", "tests/lib", "tests/suites", "docs/MIGRATION.md",\n        ):\n            self.assertFalse((ROOT / relative).exists(), relative)\n\n    def test_fresh_install_template_matches_current_schema''', s, flags=re.S)
p.write_text(s, encoding='utf-8')

# Naming audit necessarily contains detection literals; do not scan the guard implementation itself.
p = root / '.github/workflows/ci.yml'
s = p.read_text(encoding='utf-8')
s = s.replace("prompt_archives = {Path('reports/CODEX-PROMPTS.md'), Path('reports/REVIEW-PROMPTS.md')}", "content_exempt = {Path('reports/CODEX-PROMPTS.md'), Path('reports/REVIEW-PROMPTS.md'), Path('.github/workflows/ci.yml')}")
s = s.replace("or path in prompt_archives", "or path in content_exempt")
p.write_text(s, encoding='utf-8')

(root / '.github/scripts/audit-pass1-fixes.py').unlink()
(root / '.github/workflows/audit-pass1-fixes.yml').unlink()
