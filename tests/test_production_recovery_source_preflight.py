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


    def test_doctor_readout_uses_only_identifiers_not_messages(self):
        import json
        result = json.dumps({
            "schema_version": 1, "overall": "FAIL",
            "checks": [{"id": "secrets.decrypt", "status": "FAIL", "message": "super-secret-token"},
                       {"id": "runtime.docker", "status": "PASS", "message": "secret-value"}],
        })
        self.assertEqual(mod.doctor_readout(result, 1), (True, "FAIL", ["secrets.decrypt"]))
        self.assertEqual(mod.doctor_readout(result, 0)[0], False)
        corrupted = result.replace("secrets.decrypt", "secret\nSENSITIVE")
        self.assertFalse(mod.doctor_readout(corrupted, 1)[0])
        self.assertEqual(mod.doctor_readout("not-json", 1)[0], False)

    def test_local_backup_file_presence_is_only_pending(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.assertEqual(mod.local_recovery_inventory(root)[0], "NOT RUN")
            backup = root / "backups"
            backup.mkdir()
            self.assertEqual(mod.local_recovery_inventory(root)[0], "NOT RUN")
            (backup / "recovery.vwrec").write_bytes(b"fake-encrypted-test")
            self.assertEqual(mod.local_recovery_inventory(root)[0], "PENDING")
            (backup / "unsafe.vwrec").symlink_to(backup / "recovery.vwrec")
            self.assertEqual(mod.local_recovery_inventory(root)[0], "BLOCKED")

    def test_release_owner_inventory_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "vwctl").write_bytes(b"fixture")
            (root / "versions.toml").write_bytes(b"fixture")
            (root / "email-providers.toml").write_bytes(b"fixture")
            (root / "vaultwarden_oci").mkdir()
            (root / "systemd").mkdir()
            (root / "systemd" / "service").write_bytes(b"fixture")
            self.assertEqual(len(mod.release_fingerprints(root)), 4)
            (root / "systemd" / "link").symlink_to(root / "vwctl")
            with self.assertRaises(ValueError):
                mod.release_fingerprints(root)

    def test_only_tcp_listeners_are_classified(self):
        with tempfile.TemporaryDirectory() as temp:
            tcp = Path(temp) / "tcp"
            tcp6 = Path(temp) / "tcp6"
            header = "sl  local_address rem_address st tx_queue rx_queue\n"
            tcp.write_text(header +
                "  0: 0100007F:01BB 00000000:0000 0A 0:0 0:0 0 0 0\n" +
                "  1: 0100007F:0050 00000000:0000 01 0:0 0:0 0 0 0\n")
            tcp6.write_text(header +
                "  2: 00000000000000000000000000000000:0050 00000000:0000 0A 0:0 0:0 0 0 0\n")
            self.assertEqual(mod.listening_ports((tcp, tcp6)), {80, 443})
            self.assertIsNone(mod.listening_ports((Path(temp) / "missing",)))

    def test_doctor_warn_no_false_pass(self):
        import json
        warning = json.dumps({"schema_version": 1, "overall": "WARN",
            "checks": [{"id": "recovery.offsite", "status": "WARN", "message": "private"}]})
        self.assertEqual(mod.doctor_readout(warning, 0), (True, "WARN", []))
        self.assertEqual(mod.doctor_readout(warning.replace('"overall": "WARN"', '"overall": "PASS"'), 0)[0], False)

    def test_no_socket_activated_docker_probe(self):
        self.assertFalse(mod.daemon_running(None))
        self.assertFalse(mod.daemon_running({"LoadState": "loaded", "ActiveState": "inactive"}))
        self.assertFalse(mod.daemon_running({"LoadState": "not-found", "ActiveState": "active"}))
        self.assertTrue(mod.daemon_running({"LoadState": "loaded", "ActiveState": "active"}))


if __name__ == "__main__":
    unittest.main()
