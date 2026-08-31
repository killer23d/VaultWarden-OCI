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
        ):
            self.assertTrue((ROOT / relative).exists(), relative)

    def test_release_tree_has_one_systemd_source_owner(self) -> None:
        canonical = ROOT / install.SYSTEMD_SOURCE_DIR
        self.assertEqual(install.SYSTEMD_SOURCE_DIR, "systemd")
        self.assertIn(install.SYSTEMD_SOURCE_DIR, install.RELEASE_DIRS)
        self.assertTrue(canonical.is_dir())
        for unit in install.SYSTEMD_UNITS:
            self.assertTrue((canonical / unit).is_file(), unit)
        historical_name = "systemd-" + "v" + "2"
        self.assertFalse((ROOT / historical_name).exists())

    def test_systemd_lifecycle_allows_bounded_arm64_cold_build_window(self) -> None:
        service = (ROOT / "systemd/vaultwarden-oci.service").read_text(encoding="utf-8")
        self.assertIn("TimeoutStartSec=600", service)
        self.assertNotIn("TimeoutStartSec=infinity", service)

    def test_semantic_stage_placeholder_is_absent_from_runtime_sources(self) -> None:
        forbidden = ("pre-release" + " implementation", "implementation" + " stage")
        for path in (ROOT / "vaultwarden_oci").glob("*.py"):
            text = path.read_text(encoding="utf-8").lower()
            for phrase in forbidden:
                self.assertNotIn(phrase, text, path)

    def test_fresh_install_template_matches_current_schema(self) -> None:
        parsed = runtime.parse_config(tomllib.loads(install.CONFIG_TEMPLATE))
        self.assertEqual(parsed.domain, "vault.invalid")
        self.assertEqual(parsed.smtp_host, "smtp.invalid")
        self.assertFalse(parsed.signups_allowed)
        self.assertIsNone(parsed.notification_provider)


if __name__ == "__main__":
    unittest.main()
