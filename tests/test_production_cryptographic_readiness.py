"""Non-destructive P2 recovery-rehearsal fixtures; no real Box or private keys."""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance" / "production-cryptographic-readiness.py"
spec = importlib.util.spec_from_file_location("production_p2", SCRIPT)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class P2NoRestoreTests(unittest.TestCase):
    def test_sqlite_full_integrity_on_snapshot(self):
        with tempfile.TemporaryDirectory() as folder:
            db = Path(folder) / "db.sqlite3"
            connection = sqlite3.connect(db)
            connection.execute("CREATE TABLE ciphers (id TEXT PRIMARY KEY)")
            connection.execute("INSERT INTO ciphers VALUES ('test')")
            connection.commit()
            connection.close()
            self.assertTrue(mod.sqlite_snapshot_integrity(db))
            db.write_bytes(b"not sqlite")
            self.assertFalse(mod.sqlite_snapshot_integrity(db))
            self.assertFalse(mod.sqlite_snapshot_integrity(Path(folder) / "absent.db"))

    def test_restored_backup_policy_flags_only(self):
        class Config:
            offsite_remote = "bw-backup:from-original"
            local_retention_days = 7
            remote_retention_days = 0
        self.assertEqual(mod.preview_policy(Config()), (True, True, 7, 0))
        Config.remote_retention_days = -1
        with self.assertRaises(ValueError):
            mod.preview_policy(Config())
        Config.remote_retention_days = False
        with self.assertRaises(ValueError):
            mod.preview_policy(Config())

    def test_gate_classifies_cancel_pending_and_missing_privacy_blocked(self):
        with tempfile.TemporaryDirectory() as folder:
            gate = mod.Gate(Path(folder))
            gate.record("PASS", "Ciphertext checksum matched")
            gate.record("PENDING", "Offline identity not provided")
            self.assertEqual(gate.finish(), 0)
            report = (Path(folder) / "summary.txt").read_text()
            self.assertIn("PENDING", report)
            self.assertIn("no live restore was attempted", report)
            unsafe = mod.Gate(Path(folder))
            unsafe.record("BLOCKED", "Unsafe private storage")
            self.assertEqual(unsafe.finish(), 2)

    def test_bounded_stream_hash_to_temporary_file(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            destination = directory / "ciphertext.vwrec"
            with mock.patch.object(mod, "filename_guard", return_value=True):
                digest, size = mod.stream_exact_ciphertext(
                    destination,
                    argv=(sys.executable, "-c", "import sys;sys.stdout.buffer.write(b'age-encryption.org/v1\\nfixture')"),
                    max_bytes=1024,
                    timeout_seconds=10,
                )
                self.assertEqual(size, len(destination.read_bytes()))
                self.assertEqual(digest, mod.hashlib.sha256(destination.read_bytes()).hexdigest())
                with self.assertRaises(ValueError):
                    mod.stream_exact_ciphertext(destination, argv=(sys.executable, "-c", "print('NO')"))
                next_file = directory / "too-long"
                with self.assertRaises(ValueError):
                    mod.stream_exact_ciphertext(
                        next_file,
                        argv=(sys.executable, "-c", "import sys;sys.stdout.buffer.write(b'X'*100)"),
                        max_bytes=50, timeout_seconds=10,
                    )

    def test_tmpfs_required_and_swap_never_assumed_absent(self):
        class Proc:
            returncode = 0
            stdout = "ext4\n"
        with mock.patch.object(mod.subprocess, "run", return_value=Proc()):
            self.assertFalse(mod.verified_tmpfs())

    def test_only_root_private_folders_are_accepted(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            directory.chmod(0o700)
            if os.getuid() == 0:
                self.assertTrue(mod.filename_guard(directory))
            directory.chmod(0o755)
            self.assertFalse(mod.filename_guard(directory))
            alias = directory / "link"
            alias.symlink_to(directory)
            self.assertFalse(mod.filename_guard(alias))


    def test_complete_mocked_p2_verifies_and_sanitizes_without_promotion(self):
        """Ensure the whole operator path reaches a secure result, not just unit helpers."""
        import contextlib
        import io
        from types import SimpleNamespace
        from vaultwarden_oci import recovery, recovery_ux, runtime, secrets, storage

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            release = root / "immutable-release"
            release.mkdir()
            selected = root / "current"
            selected.symlink_to(release, target_is_directory=True)
            device = root / "dedicated"
            device.write_bytes(b"fixture")
            alias = root / "stable-by-id"
            alias.symlink_to(device)
            evidence = root / "evidence"
            evidence.mkdir()
            state = root / "state"
            state.mkdir()
            original_tmp = tempfile.TemporaryDirectory
            recipient = "age1example-public-fixture"
            config = SimpleNamespace(
                offline_recovery_recipient=recipient, offsite_remote=None,
                local_retention_days=0, remote_retention_days=0,
            )
            p1 = SimpleNamespace(
                EXPECTED_VOLUME_UUID="volume-fixture-uuid",
                EXPECTED_BYID=alias,
                UNITS=("service-a", "service-b"),
                release_integrity=lambda *args: (True, 52),
                systemd_unit_integrity=lambda *args: (True, 12),
                service_properties=lambda unit: {
                    "LoadState": "loaded", "ActiveState": "inactive",
                    "UnitFileState": "disabled",
                },
                stopped_units=lambda *args: True,
                daemon_running=lambda *args: False,
                matches_offline_recipient=lambda *args: True,
                backup_policy_safe=lambda *args: True,
                run_readonly=lambda *args, **kwargs: (0, "bw-backup:\n"),
                remote_available=lambda *args: True,
                root_command_env=lambda: {"HOME": "/root"},
            )
            output = io.StringIO()

            class Output(io.StringIO):
                def isatty(self):
                    return True

            tty = Output()
            tty.write("")
            tty.seek(0)
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(mod.os, "geteuid", return_value=0))
                stack.enter_context(mock.patch.object(mod.sys, "argv", ["p2.py"]))
                stack.enter_context(mock.patch.object(mod.sys, "path", list(sys.path)))
                stack.enter_context(mock.patch.object(mod.sys, "stdin", tty))
                stack.enter_context(mock.patch.object(mod.platform, "node", return_value=mod.HOST))
                stack.enter_context(mock.patch.object(mod.platform, "machine", return_value="aarch64"))
                stack.enter_context(mock.patch.object(mod, "CURRENT", selected))
                stack.enter_context(mock.patch.object(mod, "INSTALLED", release))
                stack.enter_context(mock.patch.object(mod, "STATE", state))
                stack.enter_context(mock.patch.object(mod, "root_private_evidence", return_value=evidence))
                stack.enter_context(mock.patch.object(mod, "p1_model", return_value=p1))
                stack.enter_context(mock.patch.object(mod, "verified_tmpfs", return_value=True))
                stack.enter_context(mock.patch.object(mod, "filename_guard", return_value=True))
                stack.enter_context(mock.patch.object(mod.signal, "signal"))
                stack.enter_context(mock.patch.object(mod.tempfile, "TemporaryDirectory",
                    side_effect=lambda *args, **kwargs: original_tmp(dir=root, prefix="test-p2-")))
                stack.enter_context(mock.patch.object(mod, "stream_exact_ciphertext",
                    return_value=(mod.EXPECTED_ARCHIVE_SHA, 358680)))
                stack.enter_context(mock.patch.object(mod, "sqlite_snapshot_integrity", return_value=True))
                stack.enter_context(mock.patch.object(storage, "verify", return_value=SimpleNamespace(
                    uuid=p1.EXPECTED_VOLUME_UUID, source=str(device))))
                stack.enter_context(mock.patch.object(runtime, "load_config", return_value=config))
                stack.enter_context(mock.patch.object(secrets, "validate_custody", return_value=None))
                stack.enter_context(mock.patch.object(recovery_ux, "acquire_offline_identity",
                    return_value=contextlib.nullcontext(root / "offline-private-identity")))
                stack.enter_context(mock.patch.object(recovery, "_decrypt_and_validate",
                    return_value={"created_at": "2026-10-29T22:32:00Z"}))
                stack.enter_context(mock.patch.object(recovery, "_validate_offline_sops",
                    return_value=(config, recipient)))
                stack.enter_context(mock.patch.object(recovery, "_preflight_targets", return_value=None))
                stack.enter_context(contextlib.redirect_stdout(tty))
                result = mod.main()
            self.assertEqual(result, 0)
            summary = (evidence / "summary.txt").read_text(encoding="utf-8")
            self.assertIn("VERIFIED", summary)
            self.assertIn("SQLite database passed full", summary)
            self.assertIn("no live restore was attempted", summary)
            self.assertNotIn("age1example-public-fixture", summary)
            self.assertNotIn("offline-private-identity", summary)


if __name__ == "__main__":
    unittest.main()
