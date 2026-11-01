"""Focused P1 recovery-source preflight tests (no host/cloud/secret operations)."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).parent / "host-acceptance" / "production-recovery-source-preflight.py"
spec = importlib.util.spec_from_file_location("production_recovery_source_p1", ROOT)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class P1SourcePreflightTests(unittest.TestCase):
    def test_original_offline_public_identity_matches_both_accepted_gates(self):
        self.assertTrue(mod.matches_offline_recipient(
            "age1z7tqg4zrlnul8kang4lny9405elnya5nh3rt3dk440s766rf8assh33sku"))
        self.assertFalse(mod.matches_offline_recipient("age1INVALID"))
        self.assertFalse(mod.matches_offline_recipient(None))

    def test_remote_name_requires_actual_root_config_listing(self):
        self.assertTrue(mod.remote_available("bw-backup:\nother:\n", 0))
        self.assertFalse(mod.remote_available("bw-backup:\n", 1))
        self.assertFalse(mod.remote_available("evil:bw-backup:\n", 0))
        self.assertFalse(mod.remote_available("other:\n", 0))
        self.assertFalse(mod.remote_available("", None))

    def test_only_inactive_disabled_and_static_dns_units_are_allowed(self):
        states = {
            unit: {
                "LoadState": "loaded", "ActiveState": "inactive",
                "UnitFileState": "static" if unit.endswith("dns.service") else "disabled"
            }
            for unit in mod.UNITS
        }
        self.assertTrue(mod.stopped_units(states))
        states["vaultwarden-oci-backup.timer"]["ActiveState"] = "active"
        self.assertFalse(mod.stopped_units(states))
        states["vaultwarden-oci-backup.timer"]["ActiveState"] = "inactive"
        states["vaultwarden-oci-dns.service"]["UnitFileState"] = "enabled"
        self.assertFalse(mod.stopped_units(states))
        del states["vaultwarden-oci-dns.service"]
        self.assertFalse(mod.stopped_units(states))

    def test_no_pruning_or_publishing_is_accepted(self):
        self.assertTrue(mod.backup_policy_safe(None, 0, 0))
        self.assertTrue(mod.backup_policy_safe("", 0, 0))
        self.assertFalse(mod.backup_policy_safe("bw-backup:somewhere", 0, 0))
        self.assertFalse(mod.backup_policy_safe("", 1, 0))
        self.assertFalse(mod.backup_policy_safe("", 0, 1))
        self.assertFalse(mod.backup_policy_safe("", False, 0))

    def test_zip_metadata_never_reads_encrypted_contents(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            zip_file = directory / "encrypted.zip"
            self.assertEqual(mod.kit_metadata(zip_file, os.getuid()), "absent")
            zip_file.write_bytes(b"not-a-zip")
            zip_file.chmod(0o600)
            self.assertEqual(mod.kit_metadata(zip_file, os.getuid()), "present-unverified")
            zip_file.chmod(0o644)
            self.assertEqual(mod.kit_metadata(zip_file, os.getuid()), "unsafe")
            zip_file.chmod(0o600)
            alias = directory / "link.zip"
            alias.symlink_to(zip_file)
            self.assertEqual(mod.kit_metadata(alias, os.getuid()), "unsafe")


if __name__ == "__main__":
    unittest.main()
