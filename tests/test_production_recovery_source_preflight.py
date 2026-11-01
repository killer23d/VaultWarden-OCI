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


    def test_broad_gate_report_buffer_is_not_reassigned(self):
        """Regression: docker ps stdout must never replace report rows."""
        import ast
        tree = ast.parse(ROOT.read_text(encoding="utf-8"))
        main = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "main")
        report_bindings = [
            name for node in ast.walk(main)
            if isinstance(node, (ast.Assign, ast.AnnAssign, ast.NamedExpr, ast.For, ast.AsyncFor))
            for target in (
                node.targets if isinstance(node, ast.Assign)
                else [node.target] if hasattr(node, "target")
                else []
            )
            for name in ast.walk(target)
            if isinstance(name, ast.Name) and name.id == "report_rows"
        ]
        self.assertEqual(len(report_bindings), 1)
        self.assertIn("for state, msg in report_rows", ROOT.read_text(encoding="utf-8"))
        self.assertIn("code, container_id_output = run_readonly", ROOT.read_text(encoding="utf-8"))

    def test_stream_hash_without_materializing_ciphertext(self):
        import hashlib
        import sys
        payload = b"encrypted-fixture"
        sha, size = mod.digest_bounded_stdout(
            [sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'encrypted-fixture')"],
            timeout_seconds=10, max_bytes=1024,
        )
        self.assertEqual(sha, hashlib.sha256(payload).hexdigest())
        self.assertEqual(size, len(payload))

    def test_stream_failure_and_bounded_refusal(self):
        import sys
        with self.assertRaises(ValueError):
            mod.digest_bounded_stdout(
                [sys.executable, "-c", "import sys;sys.stdout.buffer.write(b'abc')"],
                timeout_seconds=10, max_bytes=2,
            )
        with self.assertRaises(RuntimeError):
            mod.digest_bounded_stdout(
                [sys.executable, "-c", "import sys;sys.stdout.buffer.write(b'abc');sys.exit(3)"],
                timeout_seconds=10, max_bytes=1024,
            )
        with self.assertRaises(ValueError):
            mod.digest_bounded_stdout(
                [sys.executable, "-c", "print('bad')"], timeout_seconds=0
            )

    def test_box_opt_in_never_contacts_remote_without_intent_and_preflight(self):
        from unittest.mock import patch
        with patch.object(mod, "digest_bounded_stdout") as digest:
            self.assertEqual(mod.box_ciphertext_readback(False, True, True)[0], "NOT RUN")
            self.assertEqual(mod.box_ciphertext_readback(True, False, True)[0], "PENDING")
            self.assertEqual(mod.box_ciphertext_readback(True, True, False)[0], "NOT RUN")
            digest.assert_not_called()
            digest.return_value = (mod.HISTORICAL_SHA256, 76543)
            state, info = mod.box_ciphertext_readback(True, True, True)
            self.assertEqual(state, "PASS")
            self.assertIn("76543", info)
            self.assertEqual(digest.call_args.args[0][:3],
                             ["rclone", "cat", mod.HISTORICAL_REMOTE])
            digest.return_value = ("0" * 64, 76543)
            self.assertEqual(mod.box_ciphertext_readback(True, True, True)[0], "BLOCKED")
            digest.side_effect = OSError("private-auth-secret")
            result = mod.box_ciphertext_readback(True, True, True)
            self.assertEqual(result[0], "PENDING")
            self.assertNotIn("private-auth-secret", result[1])


    def test_root_rclone_environment_uses_root_config(self):
        from unittest.mock import patch
        with patch.dict(os.environ, {"RCLONE_CONFIG": "/tmp/unsafe.conf", "HOME": "/home/ubuntu",
                                    "XDG_CONFIG_HOME": "/home/ubuntu/.config"}):
            environment = mod.root_command_env()
        self.assertEqual(environment["HOME"], "/root")
        self.assertEqual(environment["XDG_CONFIG_HOME"], "/root/.config")
        self.assertNotIn("RCLONE_CONFIG", environment)

    def test_stream_timeout_terminates_child(self):
        import sys
        from unittest.mock import patch
        with patch.object(mod.select, "select", return_value=([], [], [])):
            with self.assertRaises(TimeoutError):
                mod.digest_bounded_stdout(
                    [sys.executable, "-c", "import time; time.sleep(4)"],
                    timeout_seconds=10, max_bytes=1024,
                )


    def test_mocked_main_active_docker_produces_full_private_summary(self):
        """Exercise the exact branch that crashed on the operator's VM."""
        import contextlib
        from types import SimpleNamespace
        from unittest.mock import patch
        from vaultwarden_oci import cli, runtime, secrets, storage

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            release = root / "releases" / mod.VERSION
            release.mkdir(parents=True)
            current = root / "current"
            current.symlink_to(release, target_is_directory=True)
            device = root / "device"
            device.write_bytes(b"test-device-placeholder")
            alias = root / "disk-by-id"
            alias.symlink_to(device)
            state = root / "state"
            state.mkdir()
            output_dir = root / "evidence"
            output_dir.mkdir()

            def fake_read(argv, timeout=15):
                if argv[:2] == ["systemctl", "show"]:
                    unit = argv[2]
                    file_state = "static" if unit.endswith("dns.service") else "disabled"
                    return 0, (f"LoadState=loaded\nActiveState=inactive\n"
                               f"UnitFileState={file_state}\n")
                if argv[:2] == ["rclone", "listremotes"]:
                    return 0, "bw-backup:\n"
                if argv[0] == "dpkg":
                    return 0, ""
                if argv[0] == "docker":
                    if argv[1] == "version":
                        return 0, "27.0.0\n"
                    if argv[1] == "compose":
                        return 0, "2.0.0\n"
                    if argv[1] == "ps":
                        return 0, "SENSITIVE-CONTAINER-ID-DO-NOT-PRINT\n"
                if argv[0] == "timedatectl":
                    return 0, "yes\n"
                if "doctor" in argv:
                    return 1, '{"schema_version":1,"overall":"FAIL","checks":[{"id":"secrets.decrypt","status":"FAIL"}]}'
                raise AssertionError(f"unexpected command: {argv[0]}")

            config = SimpleNamespace(
                offline_recovery_recipient="age1z7tqg4zrlnul8kang4lny9405elnya5nh3rt3dk440s766rf8assh33sku",
                offsite_remote="", local_retention_days=0, remote_retention_days=0,
            )
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(mod.os, "geteuid", return_value=0))
                stack.enter_context(patch.object(mod.sys, "argv", ["preflight.py"]))
                stack.enter_context(patch.object(mod.sys, "path", list(mod.sys.path)))
                stack.enter_context(patch.object(mod.platform, "node", return_value=mod.HOST))
                stack.enter_context(patch.object(mod.platform, "machine", return_value="aarch64"))
                stack.enter_context(patch.object(mod, "evidence_dir", return_value=output_dir))
                stack.enter_context(patch.object(mod, "CURRENT", current))
                stack.enter_context(patch.object(mod, "RELEASE", release))
                stack.enter_context(patch.object(mod, "EXPECTED_BYID", alias))
                stack.enter_context(patch.object(mod, "STATE", state))
                stack.enter_context(patch.object(mod, "run_readonly", side_effect=fake_read))
                stack.enter_context(patch.object(mod, "release_integrity", return_value=(True, 100)))
                stack.enter_context(patch.object(mod, "systemd_unit_integrity", return_value=(True, 12)))
                stack.enter_context(patch.object(mod, "kit_metadata", return_value="absent"))
                stack.enter_context(patch.object(mod, "secret_schema_readout", return_value="missing cloudflare_api_token"))
                stack.enter_context(patch.object(mod, "listening_ports", return_value=set()))
                stack.enter_context(patch.object(mod, "service_properties",
                    side_effect=lambda unit: {"LoadState": "loaded", "ActiveState": "active"}
                    if unit == "docker.service"
                    else {"LoadState": "not-found", "ActiveState": "inactive"}))
                stack.enter_context(patch.object(mod.pwd, "getpwnam",
                    return_value=SimpleNamespace(pw_uid=os.getuid())))
                stack.enter_context(patch.object(storage, "verify",
                    return_value=SimpleNamespace(uuid=mod.EXPECTED_VOLUME_UUID, source=str(device))))
                stack.enter_context(patch.object(runtime, "load_config", return_value=config))
                stack.enter_context(patch.object(secrets, "validate_custody", return_value=None))
                stack.enter_context(patch.object(cli, "validate_config", return_value={}))
                stack.enter_context(patch.object(cli, "read_os_release",
                    return_value={"ID": "ubuntu", "VERSION_ID": "26.04", "VERSION_CODENAME": "resolute"}))
                stack.enter_context(patch.object(cli, "validate_supported_ubuntu_release",
                    return_value=("26.04", "resolute")))
                import io
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                self.assertIn(mod.main(), (0, 2))
            summary = (output_dir / "summary.txt").read_text(encoding="utf-8")
            self.assertIn("BLOCKED  Appliance-named containers total=1 running=1", summary)
            self.assertIn("Root's bw-backup: rclone name exists", summary)
            self.assertIn("Pre-restore readiness", summary)
            self.assertNotIn("SENSITIVE-CONTAINER-ID", summary)


if __name__ == "__main__":
    unittest.main()
