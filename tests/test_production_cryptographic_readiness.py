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


if __name__ == "__main__":
    unittest.main()
