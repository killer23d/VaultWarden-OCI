from __future__ import annotations

import tomllib
import unittest
from pathlib import Path

from vaultwarden_oci import install, runtime

ROOT = Path(__file__).resolve().parents[1]


class Phase8SurfaceTests(unittest.TestCase):
    def test_beta_operator_docs_exist(self) -> None:
        for relative in (
            "README.md", "docs/INSTALL.md", "docs/OPERATIONS.md", "docs/SECURITY.md",
            "docs/RECOVERY.md", "docs/DEVELOPMENT.md", "docs/HOST-ACCEPTANCE.md",
        ):
            self.assertTrue((ROOT / relative).is_file(), relative)

    def test_retired_v1_product_owners_are_absent(self) -> None:
        for relative in (
            "CHANGELOG.md", "Makefile", "startup.sh", "backup.sh",
            "restore.sh", "recover.sh", "maintenance.sh", "edit-secrets.sh", "lib",
            "utilities", "systemd", "tests/run-tests.sh", "tests/lib", "tests/suites",
            "docs/COMMAND-REFERENCE.md", "docs/MIGRATION.md", "docs/V2-NOTIFICATIONS.md",
        ):
            self.assertFalse((ROOT / relative).exists(), relative)

    def test_v2_runtime_owners_remain(self) -> None:
        for relative in (
            "setup.sh", "dashboard.sh", "bootstrap-v2.sh", "vwctl", "email-providers.toml", "versions.toml",
            "vaultwarden_oci", "systemd", "tests", "docs/V2-DECISIONS.md",
            "docs/PROJECT-BOUNDARY.md", "reports/V2-ARCHITECTURE-PROPOSAL.md",
            "reports/V2-TEST-STRATEGY.md", "reports/V2-CODEX-PROMPTS.md",
        ):
            self.assertTrue((ROOT / relative).exists(), relative)

    def test_fresh_install_config_template_matches_beta_schema(self) -> None:
        self.assertNotIn("Phase-specific settings are added by later phases", install.CONFIG_TEMPLATE)
        parsed = runtime.parse_config(tomllib.loads(install.CONFIG_TEMPLATE))
        self.assertEqual(parsed.domain, "vault.invalid")
        self.assertEqual(parsed.smtp_host, "smtp.invalid")
        self.assertFalse(parsed.signups_allowed)
        self.assertIsNone(parsed.notification_provider)


if __name__ == "__main__": unittest.main()
