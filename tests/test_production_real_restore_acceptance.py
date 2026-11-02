"""P3 destructive-consent acceptance tests: mocked recovery, no real state changed."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance" / "production-real-restore-acceptance.py"
spec = importlib.util.spec_from_file_location("production_p3", SCRIPT)
assert spec and spec.loader
p3 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p3)


class P3ConsentTests(unittest.TestCase):
    def test_exact_consent_only(self):
        for input_value in ("", "restore", "RESTORED", "yes", "CANCEL", "RESTORE now", "RESTORE\nCANCEL"):
            self.assertFalse(p3.approve_restore(input_value))
        self.assertTrue(p3.approve_restore("RESTORE"))

    def test_gate_never_claims_success_for_cancellation_or_uncertain_promotion(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            with contextlib.redirect_stdout(io.StringIO()):
                cancelled = p3.Gate(root)
                cancelled.cancelled = True
                self.assertEqual(cancelled.finish(), 0)
                self.assertIn("CANCELLED", (root / "summary.txt").read_text())
                uncertain = p3.Gate(root)
                uncertain.restore_invoked = True
                self.assertEqual(uncertain.finish(), 2)
                self.assertIn("state may be partially changed", (root / "summary.txt").read_text())
                completed = p3.Gate(root)
                completed.restore_invoked = True
                completed.promoted = True
                completed.postverified = True
                self.assertEqual(completed.finish(), 0)
                self.assertIn("RESTORED", (root / "summary.txt").read_text())

    def test_empty_backup_directory_guards_and_symlink_refusal(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            candidate = base / "backups"
            self.assertTrue(p3.pristine_backup_dir(candidate, base))
            candidate.mkdir(mode=0o700)
            if os.geteuid() == 0:
                self.assertTrue(p3.pristine_backup_dir(candidate, base))
                p3.create_empty_backup_dir_after_consent(candidate, base)
            (candidate / "surprise.vwrec").write_bytes(b"do-not-delete")
            self.assertFalse(p3.pristine_backup_dir(candidate, base))
            with self.assertRaises(RuntimeError):
                p3.create_empty_backup_dir_after_consent(candidate, base)
            (candidate / "surprise.vwrec").unlink()
            candidate.rmdir()
            target = base / "real"
            target.mkdir()
            candidate.symlink_to(target)
            self.assertFalse(p3.pristine_backup_dir(candidate, base))

    def test_isolation_refuses_changed_original_volume_or_database(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            device = root / "device"
            device.write_bytes(b"fixture")
            alias = root / "alias"
            alias.symlink_to(device)
            p1 = SimpleNamespace(
                EXPECTED_BYID=alias,
                UNITS=("a", "b"),
                service_properties=lambda unit: {"LoadState":"loaded", "ActiveState":"inactive", "UnitFileState":"disabled"},
                stopped_units=lambda state: True,
                daemon_running=lambda state: True,
                run_readonly=lambda *args, **kw: (0, ""),
            )
            owner = SimpleNamespace(verify=lambda: SimpleNamespace(uuid=p3.ORIGINAL_UUID,source=str(device)))
            with mock.patch.object(p3,"STATE", root):
                self.assertTrue(p3.confirm_isolated(p1, owner, require_empty_database=True))
                (root/"data").mkdir()
                (root/"data"/"db.sqlite3").write_bytes(b"original")
                self.assertFalse(p3.confirm_isolated(p1, owner, require_empty_database=True))
                self.assertTrue(p3.confirm_isolated(p1, owner, require_empty_database=False))
                (root / "data" / "db.sqlite3").unlink()
                (root / "data" / "db.sqlite3-wal").write_bytes(b"uncommitted data")
                self.assertFalse(p3.confirm_isolated(p1, owner, require_empty_database=True))
                (root / "data" / "db.sqlite3-wal").unlink()
                (root / "data" / "db.sqlite3-shm").write_bytes(b"sidecar")
                self.assertFalse(p3.confirm_isolated(p1, owner, require_empty_database=True))
                (root / "data" / "db.sqlite3-shm").unlink()
                p1.daemon_running = lambda state: False
                self.assertFalse(p3.confirm_isolated(p1, owner, require_empty_database=False))
            wrong=SimpleNamespace(verify=lambda: SimpleNamespace(uuid="different",source=str(device)))
            self.assertFalse(p3.confirm_isolated(p1, wrong, require_empty_database=False))

    def _exercise_mocked_full_gate(self, authorization: str) -> tuple[str, int, int]:
        """Real P3 control flow with all filesystem/cloud/crypto mutation mocked."""
        from vaultwarden_oci import recovery, recovery_ux, runtime, secrets, storage
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            release = root / "release"
            release.mkdir()
            current = root / "current"
            current.symlink_to(release, target_is_directory=True)
            evidence = root / "evidence"
            evidence.mkdir()
            old_tmp = tempfile.TemporaryDirectory
            ciphertext = b"fixture-encrypted-archive"
            digest = hashlib.sha256(ciphertext).hexdigest()
            recipient = "age1-fixture-recipient"
            cfg = SimpleNamespace(offline_recovery_recipient=recipient, offsite_remote=None,
                                  local_retention_days=0, remote_retention_days=0)
            p1 = SimpleNamespace(
                release_integrity=lambda *a: (True,52),
                systemd_unit_integrity=lambda *a: (True,12),
                matches_offline_recipient=lambda *a: True,
                backup_policy_safe=lambda *a: True,
                run_readonly=lambda *a,**kw: (0,"bw-backup:\n"),
                remote_available=lambda *a: True,
                root_command_env=lambda: {"HOME":"/root"},
            )

            def box_stream(destination, **kwargs):
                destination.write_bytes(ciphertext)
                return digest, 358680

            def create_payload(artifact, identity, destination, **kw):
                db = destination / "payload/data"
                db.mkdir(parents=True)
                (db / "db.sqlite3").write_bytes(b"fixture-db-bytes")
                return {"format_version":2}

            p2=SimpleNamespace(
                p1_model=lambda: p1,
                verified_tmpfs=lambda: True,
                filename_guard=lambda *a: True,
                stream_exact_ciphertext=box_stream,
                sqlite_snapshot_integrity=lambda db: db.is_file(),
                preview_policy=lambda x: (True,False,0,0),
            )
            class TTY(io.StringIO):
                def isatty(self):
                    return True
            tty = TTY()
            restore_mock=mock.Mock(return_value={"format_version":2})
            create_mock=mock.Mock()
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(p3.os,"geteuid",return_value=0))
                stack.enter_context(mock.patch.object(p3.sys,"argv",["p3.py"]))
                stack.enter_context(mock.patch.object(p3.sys,"path",list(sys.path)))
                stack.enter_context(mock.patch.object(p3.sys,"stdin",tty))
                stack.enter_context(mock.patch.object(p3.platform,"node",return_value=p3.HOST))
                stack.enter_context(mock.patch.object(p3.platform,"machine",return_value="aarch64"))
                stack.enter_context(mock.patch.object(p3,"CURRENT",current))
                stack.enter_context(mock.patch.object(p3,"RELEASE",release))
                stack.enter_context(mock.patch.object(p3,"STATE",root))
                stack.enter_context(mock.patch.object(p3,"evidence_directory",return_value=evidence))
                stack.enter_context(mock.patch.object(p3,"p2_module",return_value=p2))
                stack.enter_context(mock.patch.object(p3,"confirm_isolated",return_value=True))
                stack.enter_context(mock.patch.object(p3,"pristine_backup_dir",return_value=True))
                stack.enter_context(mock.patch.object(p3,"create_empty_backup_dir_after_consent",create_mock))
                stack.enter_context(mock.patch.object(p3,"verify_promoted",return_value=(True,"mock verified")))
                stack.enter_context(mock.patch.object(p3,"EXPECTED_SHA",digest))
                stack.enter_context(mock.patch.object(p3.signal,"signal"))
                stack.enter_context(mock.patch.object(p3.tempfile,"TemporaryDirectory",
                    side_effect=lambda *a,**k: old_tmp(dir=root,prefix="p3-test-")))
                stack.enter_context(mock.patch.object(runtime,"load_config",return_value=cfg))
                stack.enter_context(mock.patch.object(secrets,"validate_custody",return_value=None))
                stack.enter_context(mock.patch.object(recovery_ux,"acquire_offline_identity",
                    return_value=contextlib.nullcontext(root/"offline-key")))
                stack.enter_context(mock.patch.object(recovery,"_decrypt_and_validate",side_effect=create_payload))
                stack.enter_context(mock.patch.object(recovery,"_validate_offline_sops",
                    return_value=(cfg,recipient)))
                stack.enter_context(mock.patch.object(recovery,"_preflight_targets",return_value=None))
                stack.enter_context(mock.patch.object(recovery,"restore_recovery",restore_mock))
                stack.enter_context(mock.patch("builtins.input",return_value=authorization))
                stack.enter_context(contextlib.redirect_stdout(tty))
                status=p3.main()
            result=(evidence/"summary.txt").read_text(encoding="utf-8")
            self.assertNotIn("offline-key",result)
            self.assertNotIn("age1-fixture-recipient",result)
            return result,status,restore_mock.call_count

    def test_cancel_never_calls_product_restore(self):
        result,status,count=self._exercise_mocked_full_gate("CANCEL")
        self.assertEqual(status,0)
        self.assertEqual(count,0)
        self.assertIn("CANCELLED",result)
        self.assertNotIn("RESTORED P3",result)

    def test_exact_consent_calls_product_restore_once_and_ends_stopped(self):
        result,status,count=self._exercise_mocked_full_gate("RESTORE")
        self.assertEqual(status,0)
        self.assertEqual(count,1)
        self.assertIn("RESTORED",result)
        self.assertIn("start=False",result)


if __name__=="__main__":
    unittest.main()
