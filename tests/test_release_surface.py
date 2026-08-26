from __future__ import annotations

import tomllib
import unittest
from pathlib import Path

from vaultwarden_oci import install, runtime

ROOT = Path(__file__).resolve().parents[1]


class ReleaseSurfaceTests(unittest.TestCase):
    def test_operator_manual_exists(self) -> None:
        for relative in (
            "README.md", "docs/INSTALL.md", "docs/OPERATIONS.md", "docs/SECURITY.md",
            "docs/RECOVERY.md", "docs/HOST-ACCEPTANCE.md",
        ):
            self.assertTrue((ROOT / relative).is_file(), relative)

    def test_release_neutral_runtime_owners_exist(self) -> None:
        for relative in (
            "setup.sh", "dashboard.sh", "vwctl", "email-providers.toml", "versions.toml",
            "vaultwarden_oci", "systemd", "tests", "docs/DECISIONS.md",
            "docs/PROJECT-BOUNDARY.md", "reports/TEST-STRATEGY.md",
            "reports/CODEX-PROMPTS.md", "reports/REVIEW-PROMPTS.md",
        ):
            self.assertTrue((ROOT / relative).exists(), relative)

    def test_superseded_legacy_owners_are_absent(self) -> None:
        for relative in (
            "CHANGELOG.md", "Makefile", "startup.sh", "backup.sh", "restore.sh",
            "recover.sh", "maintenance.sh", "edit-secrets.sh", "lib", "utilities",
            "tests/run-tests.sh", "tests/lib", "tests/suites", "docs/MIGRATION.md",
        ):
            self.assertFalse((ROOT / relative).exists(), relative)

    def test_previous_updater_bridge_is_exact_and_source_only(self) -> None:
        canonical = ROOT / install.SYSTEMD_SOURCE_DIR
        bridge = ROOT / install.PREVIOUS_SYSTEMD_SOURCE_DIR
        self.assertNotIn(install.PREVIOUS_SYSTEMD_SOURCE_DIR, install.RELEASE_DIRS)
        self.assertEqual(
            sorted(path.name for path in canonical.iterdir() if path.is_file()),
            sorted(path.name for path in bridge.iterdir() if path.is_file()),
        )
        for unit in install.SYSTEMD_UNITS:
            self.assertEqual((canonical / unit).read_bytes(), (bridge / unit).read_bytes())

    def test_semantic_stage_placeholder_is_absent_from_runtime_sources(self) -> None:
        for path in (ROOT / "vaultwarden_oci").glob("*.py"):
            text = path.read_text(encoding="utf-8").lower()
            self.assertNotIn("pre-release implementation", text, path)
            self.assertNotIn("implementation stage", text, path)

    def test_fresh_install_template_matches_current_schema(self) -> None:
        parsed = runtime.parse_config(tomllib.loads(install.CONFIG_TEMPLATE))
        self.assertEqual(parsed.domain, "vault.invalid")
        self.assertEqual(parsed.smtp_host, "smtp.invalid")
        self.assertFalse(parsed.signups_allowed)
        self.assertIsNone(parsed.notification_provider)


if __name__ == "__main__":
    unittest.main()
