"""P8M new disposable VM recovery-source/identity/restore batched acceptance tests."""
from __future__ import annotations

import contextlib
import datetime
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8m-batched-crypto-restore-newvm.py"
spec = importlib.util.spec_from_file_location("p8m_batched_crypto", SCRIPT)
assert spec and spec.loader
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

PIN = "a" * 40
RECIPIENT = "age1" + "a" * 58
OLDER = "20261029T223200Z"


def records_fixture():
    def obj(path, sha, stamp, status, parent=True):
        return {
            "remote": "bw-backup:bw-backup/" + path, "sha256": sha,
            "streamed_bytes": gate.ORIGINAL_BYTES, "name_date": stamp,
            "status": status, "same_parent_as_historical": parent,
        }
    return [
        obj(gate.ORIGINAL_REMOTE.removeprefix("bw-backup:bw-backup/"),
            gate.ORIGINAL_SHA, OLDER, "PIN_MATCH"),
        obj("recovery-20261031T032317Z-new.vwrec", "a"*64,
            "20261031T032317Z", "NEW_OBSERVATION_ONLY"),
        obj("recovery-20261030T232803Z-new.vwrec", "b"*64,
            "20261030T232803Z", "NEW_OBSERVATION_ONLY"),
        obj("recovery-20261029T215312Z-old.vwrec", "c"*64,
            "20261029T215312Z", "NEW_OBSERVATION_ONLY"),
        obj("old-host/recovery-20261015T221817Z-a.vwrec", "d"*64,
            "20261015T221817Z", "NEW_OBSERVATION_ONLY", False),
        obj("old-host/recovery-20261015T221732Z-a.vwrec", "e"*64,
            "20261015T221732Z", "NEW_OBSERVATION_ONLY", False),
        obj("test/recovery-20261015T221609Z-a.vwrec", "f"*64,
            "20261015T221609Z", "NEW_OBSERVATION_ONLY", False),
        obj("test/recovery-20261015T221609Z-b.vwrec", "1"*64,
            "20261015T221609Z", "NEW_OBSERVATION_ONLY", False),
    ]


def p8lr_summary():
    return "\n".join((
        "Gate P8L - batched remote encrypted recovery source integrity (READ-ONLY)",
        "PASS       Previous P8K Box readback and original independent historical SHA+358680 bytes match unchanged",
        "PASS       Box recovery filenames=9, safe encrypted candidates=8, newer safe by filename date=2",
        "PENDING    Untrusted Box fixtures QUARANTINED=1: path=0 type=0 size_missing=0 tiny=1 oversize=0; none streamed",
        "PASS       Candidate rank=3 name_date=20261029T223200Z same_parent=True ciphertext_bytes=358680 Age envelope version one=yes path_fp=b9b058145bc7 sha_fp=ee2b43a859ca scope=PIN_MATCH",
        "PASS       Encrypted recovery object streams age-header and SHA reviewed=8/8, without files on disk",
        "HOLD       P8L READ-ONLY remote set survey; no ciphertext authenticity for newer pins, Age private key, decrypt, restore, or live startup",
    )) + "\n"


def p8lr_private():
    return json.dumps({
        "schema": 1, "source_sha": gate.P8LR_SHA,
        "purpose": "UNTRUSTED_BOX_READ_ONLY_CIPHERTEXT_OBSERVATIONS",
        "original_historical_pin": gate.ORIGINAL_REMOTE,
        "no_restore_consent": True,
        "records": records_fixture(),
    }).encode()


class P8MTests(unittest.TestCase):
    def test_release_branch_dirty_commit_wrong_host_fail_closed(self):
        outputs = [
            SimpleNamespace(returncode=0, stdout=(PIN + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=(gate.BRANCH + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=b""),
        ]
        with mock.patch.object(gate.subprocess, "run", side_effect=outputs):
            self.assertTrue(gate.pinned_checkout(PIN))
        outputs[-1] = SimpleNamespace(returncode=0, stdout=b"?? extra")
        with mock.patch.object(gate.subprocess, "run", side_effect=outputs):
            self.assertFalse(gate.pinned_checkout(PIN))
        with mock.patch.object(gate.subprocess, "run") as run:
            self.assertFalse(gate.pinned_checkout("not-sha"))
            run.assert_not_called()
        with mock.patch.object(gate.platform, "node", return_value="vaultwarden-oci-6-vnic"):
            self.assertFalse(gate.guest_ok())

    def test_source_binds_original_historical_sha_and_only_two_untrusted_newer(self):
        with tempfile.TemporaryDirectory() as name:
            base = Path(name)
            with mock.patch.object(gate, "private_dir", return_value=True), \
                 mock.patch.object(gate, "private_read", side_effect=lambda path, *args, **kw:
                     p8lr_summary().encode() if path.name == "summary.txt" else p8lr_private()):
                chosen = gate.source_candidates(base)
                self.assertEqual(len(chosen), 3)
                self.assertEqual(chosen[0]["remote"], gate.ORIGINAL_REMOTE)
                self.assertEqual(chosen[0]["sha256"], gate.ORIGINAL_SHA)
                self.assertEqual(chosen[1]["name_date"], "20261031T032317Z")
                self.assertEqual(chosen[2]["name_date"], "20261030T232803Z")
                self.assertTrue(all(x["same_parent_as_historical"] for x in chosen))

    def test_source_refuses_missing_pin_and_attacker_fake_pin(self):
        with tempfile.TemporaryDirectory() as name:
            base = Path(name)
            corrupt = json.loads(p8lr_private())
            corrupt["records"][0]["sha256"] = "0"*64
            with mock.patch.object(gate, "private_dir", return_value=True), \
                 mock.patch.object(gate, "private_read", side_effect=lambda path, *args, **kw:
                     p8lr_summary().encode() if path.name == "summary.txt" else json.dumps(corrupt).encode()):
                with self.assertRaises(gate.Blocked):
                    gate.source_candidates(base)
            corrupt = json.loads(p8lr_private())
            corrupt["records"][1]["status"] = "PIN_MATCH"
            with mock.patch.object(gate, "private_dir", return_value=True), \
                 mock.patch.object(gate, "private_read", side_effect=lambda path, *args, **kw:
                     p8lr_summary().encode() if path.name == "summary.txt" else json.dumps(corrupt).encode()):
                with self.assertRaises(gate.Blocked):
                    gate.source_candidates(base)

    def test_source_refuses_untrusted_historical_hold_or_extra_same_parent_newer(self):
        with tempfile.TemporaryDirectory() as name:
            base = Path(name)
            with mock.patch.object(gate, "private_dir", return_value=True), \
                 mock.patch.object(gate, "private_read", side_effect=lambda path, *args, **kw:
                     p8lr_summary().replace("HOLD       P8L", "BLOCKED    P8L").encode()
                     if path.name == "summary.txt" else p8lr_private()):
                with self.assertRaises(gate.Blocked):
                    gate.source_candidates(base)
            corrupt = json.loads(p8lr_private())
            corrupt["records"][3]["name_date"] = "20261102T215312Z"
            with mock.patch.object(gate, "private_dir", return_value=True), \
                 mock.patch.object(gate, "private_read", side_effect=lambda path, *args, **kw:
                     p8lr_summary().encode() if path.name == "summary.txt" else json.dumps(corrupt).encode()):
                with self.assertRaises(gate.Blocked):
                    gate.source_candidates(base)

    def test_sensitive_remote_environment_root_only(self):
        with mock.patch.dict(gate.os.environ, {
            "RCLONE_CONFIG": "/tmp/unreviewed", "RCLONE_CONFIG_PASS": "secret",
            "HOME": "/home/ubuntu",
        }):
            env = gate.root_environment()
        self.assertEqual(env["HOME"], "/root")
        self.assertEqual(env["XDG_CONFIG_HOME"], "/root/.config")
        self.assertNotIn("RCLONE_CONFIG", env)
        self.assertNotIn("RCLONE_CONFIG_PASS", env)

    def test_bounded_ciphertext_bytes_to_private_tmpfs_and_source_sha(self):
        ciphertext = b"sealed" * 20
        with tempfile.TemporaryDirectory() as name:
            private = Path(name)
            private.chmod(0o700)
            path = private / "ciphertext.vwrec"
            pipe_r, pipe_w = os.pipe()
            os.write(pipe_w, ciphertext)
            os.close(pipe_w)
            with os.fdopen(pipe_r, "rb") as read:
                fake = SimpleNamespace(stdout=read, poll=lambda: 0, wait=lambda timeout: 0)
                with mock.patch.object(gate, "private_dir", return_value=True), \
                     mock.patch.object(gate.subprocess, "Popen", return_value=fake) as popen, \
                     mock.patch.object(gate, "ORIGINAL_BYTES", len(ciphertext)):
                    self.assertEqual(gate.stream_tmpfs(
                        gate.ORIGINAL_REMOTE, path, hashlib.sha256(ciphertext).hexdigest()), len(ciphertext))
                self.assertEqual(path.read_bytes(), ciphertext)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                self.assertEqual(popen.call_args.kwargs["stderr"], gate.subprocess.DEVNULL)
                self.assertEqual(popen.call_args.kwargs["env"]["HOME"], "/root")

    def test_unsafe_remote_traversal_never_invokes_box_stream(self):
        with mock.patch.object(gate.subprocess, "Popen") as process:
            with self.assertRaises(gate.Blocked):
                gate.stream_tmpfs("bw-backup:bw-backup/../../attack.vwrec", Path("/tmp/no"), "f"*64)
            process.assert_not_called()

    def test_sqlite_readonly_integrity_no_wal_or_shm(self):
        with tempfile.TemporaryDirectory() as name:
            db = Path(name) / "vault.db"
            con = sqlite3.connect(db)
            con.execute("CREATE TABLE vault (id INTEGER PRIMARY KEY, value TEXT)")
            con.execute("INSERT INTO vault(value) VALUES ('test')")
            con.commit()
            con.close()
            valid, sha = gate.sqlite_readonly(db)
            self.assertTrue(valid)
            self.assertEqual(len(sha), 64)
            self.assertFalse((Path(name) / "vault.db-wal").exists())
            self.assertFalse((Path(name) / "vault.db-shm").exists())
            db.write_bytes(b"invalid")
            self.assertEqual(gate.sqlite_readonly(db), (False, ""))

    def test_no_staged_local_secret_or_box_write_in_script(self):
        content = SCRIPT.read_text()
        self.assertNotIn("getpass.getpass(", content)
        for bad in (
            '["rclone", "copy"', '["rclone", "sync"',
            '["rclone", "delete"', '["rclone", "purge"',
            '["mkfs.ext4"', '["mount"', '["systemctl", "start"',
            '["systemctl", "enable"', '["cloudflare",',
            '["docker", "run"', 'requests.post(', 'urllib.request.urlopen(',
            'input("Authorization', 'input("RESTORE',
        ):
            self.assertNotIn(bad, content)
        self.assertIn("recovery_ux.acquire_offline_identity(", content)
        self.assertIn("recovery.restore_recovery(artifact, identity, start=False)", content)
        self.assertIn("Original historical", content)

    def test_private_exclusive_restore_attempt_marker_blocks_reuse(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "attempt.json"
            gate.private_write(path, b'{"attempted": true}\n')
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            with self.assertRaises(FileExistsError):
                gate.private_write(path, b'{"attempted": false}\n')
            self.assertIn("true", path.read_text())

    def test_sanitized_gate_holds_when_requested_restore_not_attempted(self):
        with tempfile.TemporaryDirectory() as name:
            report = gate.Report(Path(name))
            report.crypto_verified = True
            report.restoration_requested = True
            report.row("PENDING", "Docker service unavailable; restore NOT RUN")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 0)
            self.assertIn("HOLD", (Path(name) / "summary.txt").read_text())
            self.assertNotIn("RESTORED", (Path(name) / "summary.txt").read_text())
        with tempfile.TemporaryDirectory() as name:
            report = gate.Report(Path(name))
            report.crypto_verified = True
            report.restoration_requested = False
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 0)
            self.assertIn("VERIFIED", (Path(name) / "summary.txt").read_text())
        with tempfile.TemporaryDirectory() as name:
            report = gate.Report(Path(name))
            report.restoration_requested = True
            report.restore_invoked = True
            report.row("BLOCKED", "postrestore change detected")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 2)
            self.assertIn("uncertain partial", (Path(name) / "summary.txt").read_text())

    def test_bad_invocation_rejected_before_host_or_private_evidence(self):
        with mock.patch.object(gate.sys, "argv", [
            "p8m", "--expected-commit", PIN, "--restore-disposable",
        ]), mock.patch.object(gate.os, "geteuid", return_value=1000), \
             mock.patch.object(gate, "evidence_root") as evidence, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate.main(), 2)
            evidence.assert_not_called()

    def test_main_mocked_crypto_custody_cancel_leaves_no_restore_marker(self):
        from vaultwarden_oci import recovery_ux
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            scratch = root / "run"
            scratch.mkdir()
            original_temp = tempfile.TemporaryDirectory
            cfg = SimpleNamespace(offline_recovery_recipient=RECIPIENT)
            def stream(remote, dest, sha):
                dest.write_bytes(b"test encrypted bytes")
                return gate.ORIGINAL_BYTES
            with mock.patch.object(gate.sys, "argv", [
                    "p8m", "--expected-commit", PIN, "--restore-disposable",
                 ]), mock.patch.object(gate.os, "geteuid", return_value=0), \
                 mock.patch.dict(gate.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(gate.platform, "node", return_value=gate.HOST), \
                 mock.patch.object(gate, "pinned_checkout", return_value=True), \
                 mock.patch.object(gate, "guest_ok", return_value=True), \
                 mock.patch.object(gate, "evidence_root", return_value=root), \
                 mock.patch.object(gate, "source_candidates", return_value=records_fixture()[:3]), \
                 mock.patch.object(gate, "stopped_local", return_value=(cfg, None)), \
                 mock.patch.object(gate, "private_dir", return_value=True), \
                 mock.patch.object(gate, "stream_tmpfs", side_effect=stream), \
                 mock.patch.object(gate.sys, "stdin", TTY()), \
                 mock.patch.object(gate.sys, "stdout", TTY()), \
                 mock.patch.object(gate.tempfile, "TemporaryDirectory",
                     side_effect=lambda *a, **kw: original_temp(dir=scratch, prefix="test-")), \
                 mock.patch.object(recovery_ux, "acquire_offline_identity",
                     return_value=contextlib.nullcontext(None)), \
                 mock.patch.object(gate, "docker_ready") as docker:
                self.assertEqual(gate.main(), 0)
                docker.assert_not_called()
            self.assertFalse((root / gate.ATTEMPT).exists())
            summaries = list(root.glob("p8m-crypto-and-restore-*/summary.txt"))
            self.assertEqual(len(summaries), 1)
            self.assertIn("HOLD", summaries[0].read_text())
            self.assertIn("private Age identity/ZIP unavailable", summaries[0].read_text())

    def test_main_mocked_one_shot_real_restore_stopped_only(self):
        from vaultwarden_oci import recovery, recovery_ux
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            scratch = base / "tmpfs"
            scratch.mkdir()
            original_temp = tempfile.TemporaryDirectory
            cfg = SimpleNamespace(
                offline_recovery_recipient=RECIPIENT, domain=gate.DOMAIN,
                acme_email=gate.EMAIL, offsite_remote=None, local_retention_days=0,
                remote_retention_days=0,
            )
            class TTY(io.StringIO):
                def isatty(self):
                    return True
            identity_path = []
            def fake_stage(remote, destination, sha):
                destination.write_bytes(b"ciphertext")
                return gate.ORIGINAL_BYTES
            def fake_choice(recipient, **kwargs):
                location = kwargs["sensitive_root"] / "fixture-identity"
                location.write_text("AGE-SECRET-KEY-only-a-fixture")
                location.chmod(0o600)
                identity_path.append(location)
                return contextlib.nullcontext(location)
            def fake_decrypt(archive, identity, extracted, **kw):
                directory = extracted / "payload/data"
                directory.mkdir(parents=True)
                (directory / "db.sqlite3").write_bytes(b"fixtures")
                return {"format_version": 2}
            def lstat(path):
                if path.name == "fixture-identity":
                    return SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o600)
                return os.stat(path, follow_symlinks=False)
            restored = mock.Mock(return_value={"format_version": 2})
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(gate.sys, "argv", [
                    "p8m", "--expected-commit", PIN, "--restore-disposable"]))
                stack.enter_context(mock.patch.object(gate.os, "geteuid", return_value=0))
                stack.enter_context(mock.patch.dict(gate.os.environ, {"SUDO_USER": "ubuntu"}))
                stack.enter_context(mock.patch.object(gate.platform, "node", return_value=gate.HOST))
                stack.enter_context(mock.patch.object(gate, "pinned_checkout", return_value=True))
                stack.enter_context(mock.patch.object(gate, "guest_ok", return_value=True))
                stack.enter_context(mock.patch.object(gate, "evidence_root", return_value=base))
                stack.enter_context(mock.patch.object(gate, "source_candidates", return_value=records_fixture()[:3]))
                stack.enter_context(mock.patch.object(gate, "stopped_local", return_value=(cfg, None)))
                stack.enter_context(mock.patch.object(gate, "private_dir", return_value=True))
                stack.enter_context(mock.patch.object(gate, "stream_tmpfs", side_effect=fake_stage))
                stack.enter_context(mock.patch.object(gate.sys, "stdin", TTY()))
                terminal = TTY()
                stack.enter_context(mock.patch.object(gate.sys, "stdout", terminal))
                stack.enter_context(mock.patch.object(gate.tempfile, "TemporaryDirectory",
                    side_effect=lambda *a, **kw: original_temp(dir=scratch, prefix="test-")))
                stack.enter_context(mock.patch.object(recovery_ux, "acquire_offline_identity", side_effect=fake_choice))
                stack.enter_context(mock.patch.object(recovery, "_decrypt_and_validate", side_effect=fake_decrypt))
                stack.enter_context(mock.patch.object(recovery, "_validate_offline_sops", return_value=(cfg, RECIPIENT)))
                stack.enter_context(mock.patch.object(recovery, "_preflight_targets"))
                stack.enter_context(mock.patch.object(gate, "sqlite_readonly", return_value=(True, "f"*64)))
                stack.enter_context(mock.patch.object(gate, "docker_ready", return_value=True))
                stack.enter_context(mock.patch.object(gate, "postrestore", return_value=(True, "mock recovered SQLite and stopped app")))
                stack.enter_context(mock.patch.object(recovery, "restore_recovery", restored))
                stack.enter_context(mock.patch.object(gate.Path, "lstat", autospec=True, side_effect=lstat))
                rc = gate.main()
            self.assertEqual(rc, 0)
            self.assertEqual(restored.call_count, 1)
            self.assertFalse(restored.call_args.kwargs["start"])
            self.assertTrue((base / gate.ATTEMPT).is_file())
            summary = next(base.glob("p8m-crypto-and-restore-*/summary.txt")).read_text()
            self.assertIn("RESTORED", summary)
            self.assertIn("start=False", summary)
            self.assertNotIn("AGE-SECRET-KEY", summary)
            self.assertNotIn("AGE-SECRET-KEY", terminal.getvalue())

    def test_expected_crypto_without_docker_is_hold_not_restored(self):
        report = gate.Report(Path("/tmp/not-created"))
        report.restoration_requested = True
        report.crypto_verified = True
        self.assertFalse(gate.docker_ready.__name__ == "should_run_any_service")
        self.assertFalse(report.restore_invoked)


class TTY(io.StringIO):
    def isatty(self):
        return True


if __name__ == "__main__":
    unittest.main()
