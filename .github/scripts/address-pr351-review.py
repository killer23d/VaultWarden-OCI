#!/usr/bin/env python3
from __future__ import annotations

import ast
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    (ROOT / path).write_text(text.rstrip() + "\n", encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one occurrence, found {count}")
    return text.replace(old, new, 1)


def remove_top_level_functions(text: str, names: set[str]) -> str:
    tree = ast.parse(text)
    lines = text.splitlines(keepends=True)
    spans: list[tuple[int, int, str]] = []
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in names:
            if node.end_lineno is None:
                raise SystemExit(f"missing end line for {node.name}")
            spans.append((node.lineno - 1, node.end_lineno, node.name))
    missing = names - {name for _, _, name in spans}
    if missing:
        raise SystemExit("missing functions to remove: " + ", ".join(sorted(missing)))
    for start, end, _ in sorted(spans, reverse=True):
        del lines[start:end]
        while start < len(lines) and lines[start].strip() == "" and start > 0 and lines[start - 1].strip() == "":
            del lines[start]
    return "".join(lines)


def remove_test_methods_containing(text: str, class_name: str, needle: str) -> str:
    tree = ast.parse(text)
    lines = text.splitlines(keepends=True)
    spans: list[tuple[int, int]] = []
    found_class = False
    for node in tree.body:
        if isinstance(node, ast.ClassDef) and node.name == class_name:
            found_class = True
            for child in node.body:
                if isinstance(child, ast.FunctionDef) and child.end_lineno is not None:
                    segment = "".join(lines[child.lineno - 1: child.end_lineno])
                    if needle in segment:
                        spans.append((child.lineno - 1, child.end_lineno))
    if not found_class or not spans:
        raise SystemExit(f"could not find {class_name} test methods containing {needle}")
    for start, end in sorted(spans, reverse=True):
        del lines[start:end]
        while start < len(lines) and lines[start].strip() == "" and start > 0 and lines[start - 1].strip() == "":
            del lines[start]
    return "".join(lines)


# 1. Immutable release identity must advance whenever immutable bytes change.
versions = read("versions.toml")
versions = replace_once(
    versions,
    'version = "0.1.0-dev.14"',
    'version = "0.1.0-dev.15"',
    "versions.toml release identity",
)
write("versions.toml", versions)

# 2. Preserve the immediately preceding updater's source contract without
# restoring the old path to the new immutable release manifest.
install = read("vaultwarden_oci/install.py")
install = replace_once(
    install,
    'SYSTEMD_SOURCE_DIR = "systemd"\n',
    'SYSTEMD_SOURCE_DIR = "systemd"\n'
    '# Source-only compatibility input for the immediately preceding updater.\n'
    '# New release staging deliberately ignores this directory.\n'
    'PREVIOUS_SYSTEMD_SOURCE_DIR = "systemd-v2"\n',
    "install systemd source constants",
)
write("vaultwarden_oci/install.py", install)

bridge = ROOT / "systemd-v2"
if bridge.exists():
    shutil.rmtree(bridge)
bridge.mkdir()
canonical = ROOT / "systemd"
for source in canonical.iterdir():
    if source.is_file():
        shutil.copy2(source, bridge / source.name)

# 3. New updater can compare/migrate an immutable release that was staged by
# the immediately preceding updater with only its historical systemd layout.
update = read("vaultwarden_oci/update.py")
update = replace_once(
    update,
    '"""Explicit pre-release implementation immutable-release update transaction."""',
    '"""Shared immutable-update planning and safety primitives."""',
    "update module docstring",
)
update = replace_once(
    update,
    'from typing import Callable, Mapping',
    'from typing import Callable',
    "update typing imports",
)
update = update.replace("import tempfile\n", "")
update = replace_once(
    update,
    'from .update_versions import (\n    RESOLVED_STATE,\n    FrozenVersions,\n    UpdateError,\n    frozen_versions_toml,\n    record_frozen,\n    resolve_pinned,\n)',
    'from .update_versions import FrozenVersions, UpdateError, resolve_pinned',
    "update version imports",
)
update = update.replace('Activator = Callable[[FrozenVersions, Path, Runner], None]\n', '')
update = replace_once(
    update,
    'raise UpdateError(f"candidate release is missing pre-release implementation owner: {name}")',
    'raise UpdateError(f"candidate release is missing required update owner: {name}")',
    "update owner error",
)
update = replace_once(
    update,
    'always updates the production root and therefore uses pre-release implementation production\n    runtime/recovery ownership consistently.',
    'always updates the production root and therefore uses the production\n    runtime/recovery ownership consistently.',
    "update plan docstring",
)
old_selected = '''def _selected_release_content(root: Path) -> dict[str, bytes | None]:\n    result: dict[str, bytes | None] = {}\n    for name in install.RELEASE_FILES:\n        path = root / name\n        if path.is_symlink() or not path.is_file():\n            raise UpdateError(f"release content is missing or unsafe: {path}")\n        result[name] = path.read_bytes()\n    for name in install.RELEASE_DIRS:\n        base = root / name\n        if base.is_symlink() or not base.is_dir():\n            raise UpdateError(f"release content is missing or unsafe: {base}")\n        result[name + "/"] = None\n        for path in sorted(base.rglob("*")):\n            relative = path.relative_to(root)\n            if "__pycache__" in relative.parts or path.suffix == ".pyc":\n                continue\n            key = relative.as_posix() + ("/" if path.is_dir() else "")\n            if path.is_symlink():\n                raise UpdateError(f"release content contains an unsafe symlink: {path}")\n            if path.is_dir():\n                result[key] = None\n            elif path.is_file():\n                result[key] = path.read_bytes()\n            else:\n                raise UpdateError(f"release content contains an unsupported file type: {path}")\n    return result\n'''
new_selected = '''def _release_content_directory(root: Path, name: str) -> Path:\n    canonical = root / name\n    if canonical.is_dir() and not canonical.is_symlink():\n        return canonical\n    if name == install.SYSTEMD_SOURCE_DIR:\n        previous = root / install.PREVIOUS_SYSTEMD_SOURCE_DIR\n        if previous.is_dir() and not previous.is_symlink():\n            return previous\n    return canonical\n\n\ndef _selected_release_content(root: Path) -> dict[str, bytes | None]:\n    result: dict[str, bytes | None] = {}\n    for name in install.RELEASE_FILES:\n        path = root / name\n        if path.is_symlink() or not path.is_file():\n            raise UpdateError(f"release content is missing or unsafe: {path}")\n        result[name] = path.read_bytes()\n    for name in install.RELEASE_DIRS:\n        base = _release_content_directory(root, name)\n        if base.is_symlink() or not base.is_dir():\n            raise UpdateError(f"release content is missing or unsafe: {base}")\n        result[name + "/"] = None\n        for path in sorted(base.rglob("*")):\n            relative = Path(name) / path.relative_to(base)\n            if "__pycache__" in relative.parts or path.suffix == ".pyc":\n                continue\n            key = relative.as_posix() + ("/" if path.is_dir() else "")\n            if path.is_symlink():\n                raise UpdateError(f"release content contains an unsafe symlink: {path}")\n            if path.is_dir():\n                result[key] = None\n            elif path.is_file():\n                result[key] = path.read_bytes()\n            else:\n                raise UpdateError(f"release content contains an unsupported file type: {path}")\n    return result\n'''
update = replace_once(update, old_selected, new_selected, "update release-content normalization")
update = remove_top_level_functions(
    update,
    {"_prepare_runtime", "_install_units", "_restore_units", "_switch", "_activate_runtime", "apply_update"},
)
write("vaultwarden_oci/update.py", update)

migration = read("vaultwarden_oci/update_unit_migration.py")
marker = '''def _release_barrier(release: Path) -> None:\n    """Make one immutable release usable only after its tree and parent entry are durable."""\n    durability.fsync_tree(release)\n    durability.fsync_directory(release.parent)\n'''
helper = marker + '''\n\ndef _systemd_source(release: Path, *, allow_previous_layout: bool) -> Path:\n    canonical = release / install.SYSTEMD_SOURCE_DIR\n    if canonical.is_dir() and not canonical.is_symlink():\n        return canonical\n    if allow_previous_layout:\n        previous = release / install.PREVIOUS_SYSTEMD_SOURCE_DIR\n        if previous.is_dir() and not previous.is_symlink():\n            return previous\n    return canonical\n'''
migration = replace_once(migration, marker, helper, "unit migration compatibility helper")
migration = replace_once(
    migration,
    '    snapshot: dict[Path, tuple[bytes, int]] = {}\n    actions: list[tuple[Path, bytes | None]] = []\n    for unit in install.SYSTEMD_UNITS:\n        new = new_release / install.SYSTEMD_SOURCE_DIR / unit\n        expected = expected_release / install.SYSTEMD_SOURCE_DIR / unit\n',
    '    snapshot: dict[Path, tuple[bytes, int]] = {}\n    actions: list[tuple[Path, bytes | None]] = []\n    new_source = _systemd_source(new_release, allow_previous_layout=False)\n    expected_source = _systemd_source(expected_release, allow_previous_layout=True)\n    for unit in install.SYSTEMD_UNITS:\n        new = new_source / unit\n        expected = expected_source / unit\n',
    "unit migration install paths",
)
migration = replace_once(
    migration,
    'def _state_for_release(release: Path, unit: str) -> bytes | None:\n    path = release / install.SYSTEMD_SOURCE_DIR / unit\n    return path.read_bytes() if path.is_file() else None\n',
    'def _state_for_release(release: Path, unit: str) -> bytes | None:\n    path = _systemd_source(release, allow_previous_layout=True) / unit\n    return path.read_bytes() if path.is_file() else None\n',
    "unit migration release state",
)
write("vaultwarden_oci/update_unit_migration.py", migration)

# 4. Remove semantic stage placeholders from runtime/operator surfaces.
runtime = read("vaultwarden_oci/runtime.py")
runtime = replace_once(
    runtime,
    '# pre-release implementation fail-closed rule: Docker must not republish Caddy after daemon/host',
    '# Fail closed: Docker must not republish Caddy after daemon/host',
    "runtime fail-closed comment",
)
runtime = replace_once(
    runtime,
    '"required pre-release implementation cloudflare_remediation_token is missing"',
    '"required cloudflare_remediation_token is missing"',
    "doctor missing remediation token",
)
runtime = replace_once(
    runtime,
    '"required pre-release implementation/4 secrets decrypt"',
    '"required appliance secrets decrypt"',
    "doctor decrypt success",
)
write("vaultwarden_oci/runtime.py", runtime)

secrets = read("vaultwarden_oci/secrets.py")
secrets = replace_once(
    secrets,
    '"""SOPS/Age custody and volatile pre-release implementation+ secret materialization."""',
    '"""SOPS/Age custody and volatile secret materialization."""',
    "secrets module docstring",
)
write("vaultwarden_oci/secrets.py", secrets)

# 5. Delete tests for the removed independent update transaction; retain the
# planning/version tests and add focused predecessor-transition coverage.
workflow_tests = read("tests/test_update_workflow.py")
workflow_tests = remove_test_methods_containing(
    workflow_tests,
    "UpdateTransactionTests",
    "update.apply_update",
)
write("tests/test_update_workflow.py", workflow_tests)

write("tests/test_update_transition.py", '''from __future__ import annotations\n\nimport os\nimport shutil\nimport tempfile\nimport unittest\nfrom pathlib import Path\n\nfrom vaultwarden_oci import install, update, update_unit_migration\n\nROOT = Path(__file__).resolve().parents[1]\n\n\nclass PreviousUpdaterTransitionTests(unittest.TestCase):\n    def test_previous_updater_source_contract_is_preserved_but_not_new_release_owned(self) -> None:\n        canonical = ROOT / install.SYSTEMD_SOURCE_DIR\n        bridge = ROOT / install.PREVIOUS_SYSTEMD_SOURCE_DIR\n        self.assertTrue(canonical.is_dir())\n        self.assertTrue(bridge.is_dir())\n        self.assertIn(install.SYSTEMD_SOURCE_DIR, install.RELEASE_DIRS)\n        self.assertNotIn(install.PREVIOUS_SYSTEMD_SOURCE_DIR, install.RELEASE_DIRS)\n        for unit in install.SYSTEMD_UNITS:\n            self.assertEqual((canonical / unit).read_bytes(), (bridge / unit).read_bytes(), unit)\n        # This is the immediately preceding updater's source preflight contract.\n        for name in install.RELEASE_FILES:\n            self.assertTrue((ROOT / name).is_file(), name)\n        self.assertTrue((ROOT / "vaultwarden_oci").is_dir())\n        self.assertTrue(bridge.is_dir())\n\n    def test_new_unit_migration_accepts_previous_release_historical_layout(self) -> None:\n        with tempfile.TemporaryDirectory() as directory:\n            root = Path(directory)\n            layout = install.Layout(root / "host")\n            previous = root / "previous"\n            candidate = root / "candidate"\n            previous_units = previous / install.PREVIOUS_SYSTEMD_SOURCE_DIR\n            candidate_units = candidate / install.SYSTEMD_SOURCE_DIR\n            previous_units.mkdir(parents=True)\n            candidate_units.mkdir(parents=True)\n            installed_units = layout.path(install.SYSTEMD_DIR)\n            installed_units.mkdir(parents=True)\n            for unit in install.SYSTEMD_UNITS:\n                old = f"old {unit}\\n".encode()\n                new = f"new {unit}\\n".encode()\n                (previous_units / unit).write_bytes(old)\n                (candidate_units / unit).write_bytes(new)\n                (installed_units / unit).write_bytes(old)\n            snapshot = update_unit_migration.install_units(candidate, previous, layout)\n            self.assertEqual(len(snapshot), len(install.SYSTEMD_UNITS))\n            for unit in install.SYSTEMD_UNITS:\n                self.assertEqual((installed_units / unit).read_bytes(), f"new {unit}\\n".encode())\n\n    def test_same_release_content_normalizes_previous_systemd_layout(self) -> None:\n        with tempfile.TemporaryDirectory() as directory:\n            root = Path(directory)\n            canonical = root / "canonical"\n            previous = root / "previous"\n            canonical.mkdir()\n            previous.mkdir()\n            for name in install.RELEASE_FILES:\n                (canonical / name).write_text(name + "\\n", encoding="utf-8")\n                (previous / name).write_text(name + "\\n", encoding="utf-8")\n            (canonical / "vaultwarden_oci").mkdir()\n            (previous / "vaultwarden_oci").mkdir()\n            (canonical / "vaultwarden_oci/marker").write_text("same\\n", encoding="utf-8")\n            (previous / "vaultwarden_oci/marker").write_text("same\\n", encoding="utf-8")\n            canonical_units = canonical / install.SYSTEMD_SOURCE_DIR\n            previous_units = previous / install.PREVIOUS_SYSTEMD_SOURCE_DIR\n            canonical_units.mkdir()\n            previous_units.mkdir()\n            for unit in install.SYSTEMD_UNITS:\n                payload = f"{unit}\\n".encode()\n                (canonical_units / unit).write_bytes(payload)\n                (previous_units / unit).write_bytes(payload)\n            self.assertEqual(\n                update._selected_release_content(canonical),\n                update._selected_release_content(previous),\n            )\n\n\nif __name__ == "__main__":\n    unittest.main()\n''')

surface = read("tests/test_release_surface.py")
insert = '''    def test_previous_updater_bridge_is_exact_and_source_only(self) -> None:\n        canonical = ROOT / install.SYSTEMD_SOURCE_DIR\n        bridge = ROOT / install.PREVIOUS_SYSTEMD_SOURCE_DIR\n        self.assertNotIn(install.PREVIOUS_SYSTEMD_SOURCE_DIR, install.RELEASE_DIRS)\n        self.assertEqual(\n            sorted(path.name for path in canonical.iterdir() if path.is_file()),\n            sorted(path.name for path in bridge.iterdir() if path.is_file()),\n        )\n        for unit in install.SYSTEMD_UNITS:\n            self.assertEqual((canonical / unit).read_bytes(), (bridge / unit).read_bytes())\n\n    def test_semantic_stage_placeholder_is_absent_from_runtime_sources(self) -> None:\n        for path in (ROOT / "vaultwarden_oci").glob("*.py"):\n            text = path.read_text(encoding="utf-8").lower()\n            self.assertNotIn("pre-release implementation", text, path)\n            self.assertNotIn("implementation stage", text, path)\n\n'''
surface = replace_once(
    surface,
    '    def test_fresh_install_template_matches_current_schema(self) -> None:\n',
    insert + '    def test_fresh_install_template_matches_current_schema(self) -> None:\n',
    "release surface regression insertion",
)
write("tests/test_release_surface.py", surface)

runtime_tests = read("tests/test_runtime.py")
new_doctor_test = '''    def test_doctor_secret_messages_are_release_neutral(self) -> None:\n        with tempfile.TemporaryDirectory() as directory:\n            root = Path(directory)\n            paths = temp_paths(root)\n            paths.config.write_text(config_text(), encoding="utf-8")\n\n            def runner(argv, *, env=None, cwd=None):\n                return result(argv, "--wait --wait-timeout\\n")\n\n            healthy = dict(VALUES, cloudflare_remediation_token="R" * 40)\n            with mock.patch.object(secrets, "validate_custody"), mock.patch.object(\n                secrets, "decrypt", return_value=healthy\n            ):\n                checks = runtime.doctor_checks(config_path=paths.config, paths=paths, runner=runner)\n            decrypt = next(check for check in checks if check.id == "secrets.decrypt")\n            self.assertEqual(decrypt.status, "PASS")\n            self.assertEqual(decrypt.detail, "required appliance secrets decrypt")\n\n            with mock.patch.object(secrets, "validate_custody"), mock.patch.object(\n                secrets, "decrypt", return_value=VALUES\n            ):\n                checks = runtime.doctor_checks(config_path=paths.config, paths=paths, runner=runner)\n            decrypt = next(check for check in checks if check.id == "secrets.decrypt")\n            self.assertEqual(decrypt.status, "FAIL")\n            self.assertEqual(decrypt.detail, "required cloudflare_remediation_token is missing")\n\n'''
runtime_tests = replace_once(
    runtime_tests,
    '\n\nif __name__ == "__main__":\n',
    '\n\n' + new_doctor_test + 'if __name__ == "__main__":\n',
    "runtime doctor regression insertion",
)
write("tests/test_runtime.py", runtime_tests)

# 6. Make /admin enable/rotate/disable an explicit junior-admin procedure.
operations = read("docs/OPERATIONS.md")
old_admin = '''`/admin` uses only the intended small stack: Vaultwarden admin token, Caddy rate limiting, and one outer Basic Auth gate. A deliberately disabled admin route is a valid closed state.\n\n```bash\nsudo vwctl doctor --json\nsudo vwctl edge refresh\n```\n\n**Expected success:** edge/trusted-proxy/admin checks pass. **On failure:** do not bypass the origin filter or remove admin protection to obtain green status; correct the range, credential, or rendered-policy problem.\n'''
new_admin = '''`/admin` uses only the intended small stack: Vaultwarden admin token, Caddy rate limiting, and one outer Basic Auth gate. A deliberately disabled admin route is a valid closed state.\n\nTo **enable or rotate** admin access, edit the encrypted secret authority and set both `vaultwarden_admin_token` and `admin_basic_auth_password` together; changing either value is treated as a rotation of that layer:\n\n```bash\nsudo vwctl secrets edit\nsudo vwctl secrets validate\nsudo vwctl restart\nsudo vwctl doctor --json\n```\n\nTo **disable** `/admin`, run `sudo vwctl secrets edit` and remove both `vaultwarden_admin_token` and `admin_basic_auth_password`, then run the same validate/restart/doctor sequence. Do not place either plaintext value in `config.toml`.\n\nRefresh or diagnose the separate Cloudflare origin policy with:\n\n```bash\nsudo vwctl edge refresh\nsudo vwctl doctor --json\n```\n\n**Expected success:** the secrets transaction validates, restart succeeds, and edge/trusted-proxy/admin doctor checks show either protected admin access or the deliberate closed/disabled state. **On failure:** the validated editor leaves the previous authority intact; do not bypass the origin filter or remove only one admin secret to obtain green status.\n'''
operations = replace_once(operations, old_admin, new_admin, "operations admin procedure")
write("docs/OPERATIONS.md", operations)

# Basic self-audits before the workflow runs the full unit suite.
for path in (ROOT / "vaultwarden_oci").glob("*.py"):
    text = path.read_text(encoding="utf-8").lower()
    if "pre-release implementation" in text or "implementation stage" in text:
        raise SystemExit(f"semantic stage placeholder remains: {path}")

if 'def apply_update(' in read("vaultwarden_oci/update.py"):
    raise SystemExit("obsolete update.apply_update remains")
if '_prepare_runtime' in read("vaultwarden_oci/update.py"):
    raise SystemExit("obsolete update runtime preparation remains")
if install_marker := ('PREVIOUS_SYSTEMD_SOURCE_DIR = "systemd-v2"' not in read("vaultwarden_oci/install.py")):
    raise SystemExit("previous updater systemd bridge constant missing")

print("PR 351 blocker transform completed")
