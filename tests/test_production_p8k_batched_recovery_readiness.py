"""P8K multi-check source, local isolation and opt-in Box readback regression tests."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import stat
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8k-batched-recovery-readiness.py"
spec = importlib.util.spec_from_file_location("rc12_p8k_batch", SCRIPT)
assert spec and spec.loader
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

PIN = "a" * 40
AGE_RECIPIENT = "age1" + "a" * 58
AGE_HASH = hashlib.sha256(AGE_RECIPIENT.encode()).hexdigest()
REMOTE = "bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec"
CIPHER_SHA = hashlib.sha256(b"encrypted bytes only").hexdigest()
ORIGINAL = {
    "HOST": "vaultwarden-oci-6-vnic",
    "HISTORICAL_REMOTE": REMOTE,
    "HISTORICAL_SHA256": CIPHER_SHA,
    "OFFLINE_RECIPIENT_SHA256": AGE_HASH,
}


def p8ir():
    return "\n".join((
        "Gate P8I corrected - NEW isolated installed-but-stopped template-aware witness (READ-ONLY)",
        "PASS       Original one-shot P8H install attempt/checkpoint and successful HOLD evidence intact",
        "PASS       Full installed product files=52, systemd units=12 match immutable reviewed rc.12",
        "PASS       Mounted dedicated non-root ext4 and dual ownership markers",
        "PASS       Locked hostname/email, zero-prune/disabled Box config",
        "PASS       Concrete appliance units=11 inactive/unenabled; static notify template verified with zero instances",
        "PASS       No TCP 80/443 listeners or retained Docker containers=0",
        "PASS       No Vaultwarden database present",
        "HOLD       P8I post-install read-only witness only; no restore/live-start/production GO",
    )) + "\n"


def p8j():
    return "\n".join((
        "Gate P8J - off-host recovery source and isolation planning (READ-ONLY)",
        "PASS       Accepted original P8I-R HOLD evidence unchanged",
        "PASS       Installed OFFLINE public Age recipient matches original restored-host independent pin",
        "PASS       Original Box historical .vwrec candidate metadata pinned from original source",
        "PASS       Installed rc.12 and 12 unit-file inventory",
        "PASS       No TCP 80/443 listeners",
        "PASS       No encrypted .vwrec/kit staged in known new-host recovery paths",
        "PASS       /run is tmpfs",
        "PASS       No active kernel swap",
        "HOLD       P8J original recovery provenance PRE-TRANSFER only; no ciphertext/identity/restore/live service authorization",
    )) + "\n"


def candidate():
    return {
        "schema": 1, "status": "UNVERIFIED_HISTORICAL_CANDIDATE_ONLY",
        "new_host": gate.HOST,
        "verified_source_sha": gate.P8J_SHA,
        "accepted_p8ir_summary_fingerprint": hashlib.sha256(p8ir().encode()).hexdigest()[:12],
        "permissions": "NO_BOX_READ_TRANSFER_DECRYPT_RESTORE",
        "original_candidate_remote": REMOTE,
        "original_candidate_ciphertext_sha256": CIPHER_SHA,
        "original_offline_public_recipient_sha256": AGE_HASH,
    }


class TTY(io.StringIO):
    def isatty(self):
        return True


class P8KTests(unittest.TestCase):
    def test_exact_branch_clean_and_guest_only(self):
        sha = PIN
        good = [
            SimpleNamespace(returncode=0, stdout=(sha + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=(gate.BRANCH + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=b""),
        ]
        with mock.patch.object(gate.subprocess, "run", side_effect=good):
            self.assertTrue(gate.source_ok(sha))
        with mock.patch.object(gate.subprocess, "run", side_effect=good[:2] + [
            SimpleNamespace(returncode=0, stdout=b"?? unreviewed")
        ]):
            self.assertFalse(gate.source_ok(sha))
        with mock.patch.object(gate.subprocess, "run") as process:
            self.assertFalse(gate.source_ok("not-a-sha"))
            process.assert_not_called()
        with mock.patch.object(gate.platform, "node", return_value="vaultwarden-oci-6-vnic"):
            self.assertFalse(gate.host_ok())

    def test_rclone_is_always_root_scoped_without_sudo_caller_overrides(self):
        with mock.patch.dict(gate.os.environ, {
            "HOME": "/home/ubuntu",
            "XDG_CONFIG_HOME": "/home/ubuntu/.config",
            "RCLONE_CONFIG": "/tmp/unapproved.conf",
            "RCLONE_CONFIG_PASS": "sensitive",
        }):
            isolated = gate.root_rclone_env()
        self.assertEqual(isolated["HOME"], "/root")
        self.assertEqual(isolated["XDG_CONFIG_HOME"], "/root/.config")
        self.assertNotIn("RCLONE_CONFIG", isolated)
        self.assertNotIn("RCLONE_CONFIG_PASS", isolated)

    def test_immutable_prior_hold_and_candidate_binding(self):
        with tempfile.TemporaryDirectory() as name:
            base = Path(name)
            blobs = {
                "summary-i": p8ir().encode(),
                "summary-j": p8j().encode(),
                "candidate.private.json": json.dumps(candidate()).encode(),
            }
            def fake_read(path, cap=32768):
                if path.name == "summary.txt":
                    return blobs["summary-i" if path.parent.name == gate.P8IR_EVIDENCE else "summary-j"]
                return blobs["candidate.private.json"]
            with mock.patch.object(gate, "private_directory", return_value=True), \
                 mock.patch.object(gate, "private_bytes", side_effect=fake_read):
                self.assertEqual(gate.historical_evidence(base)["original_candidate_remote"], REMOTE)
                blobs["summary-i"] = p8ir().replace("HOLD       P8I", "BLOCKED    P8I").encode()
                with self.assertRaises(gate.Blocked):
                    gate.historical_evidence(base)
                blobs["summary-i"] = p8ir().encode()
                invalid = candidate()
                invalid["verified_source_sha"] = "f" * 40
                blobs["candidate.private.json"] = json.dumps(invalid).encode()
                with self.assertRaises(gate.Blocked):
                    gate.historical_evidence(base)

    def test_historical_pin_ast_is_data_not_executed(self):
        with tempfile.TemporaryDirectory() as name:
            p = Path(name) / "old-pin.py"
            def contents(remote=REMOTE, sha=CIPHER_SHA):
                return "\n".join((
                    "HOST = 'vaultwarden-oci-6-vnic'",
                    f"HISTORICAL_REMOTE = {remote!r}",
                    f"HISTORICAL_SHA256 = {sha!r}",
                    f"OFFLINE_RECIPIENT_SHA256 = {AGE_HASH!r}",
                ))
            p.write_text(contents())
            with mock.patch.object(gate, "ORIGINAL_PIN_FILE", p):
                self.assertEqual(gate.original_source_pin()["HISTORICAL_SHA256"], CIPHER_SHA)
                p.write_text(contents(sha="dangerous_command()").replace(
                    "HISTORICAL_SHA256 = 'dangerous_command()'",
                    "HISTORICAL_SHA256 = dangerous_command()",
                ))
                with self.assertRaises(gate.Blocked):
                    gate.original_source_pin()
                p.write_text(contents(remote="evil:dangerous"))
                with self.assertRaises(gate.Blocked):
                    gate.original_source_pin()
                p.write_text(contents(remote="bw-backup:bw-backup/../recovery-20261029T223200Z-abc.vwrec"))
                with self.assertRaises(gate.Blocked):
                    gate.original_source_pin()

    def test_recipient_config_isolated_and_exact_hash(self):
        cfg = f'''
[site]
domain = "{gate.TEST_DOMAIN}"
acme_email = "{gate.TEST_EMAIL}"
[secrets]
offline_recovery_recipient = "{AGE_RECIPIENT}"
[backup]
remote = ""
local_retention_days = 0
remote_retention_days = 0
'''
        with tempfile.TemporaryDirectory() as name:
            p = Path(name) / "config.toml"
            p.write_text(cfg)
            p.chmod(0o600)
            with mock.patch.object(gate, "CONFIG", p), \
                 mock.patch.object(gate.Path, "lstat", autospec=True, side_effect=lambda x: (
                    SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=0)
                 )):
                gate.installed_config(AGE_HASH)
                with self.assertRaises(gate.Blocked):
                    gate.installed_config("f" * 64)
                p.write_text(cfg.replace('remote = ""', 'remote = "bw-backup:bw-backup"'))
                with self.assertRaises(gate.Blocked):
                    gate.installed_config(AGE_HASH)

    def test_listings_classify_newer_without_leaking_names(self):
        old = REMOTE
        entries = [
            {"Path": "a/recovery-20261020T223200Z-old.vwrec"},
            {"Path": "b/recovery-20261029T223200Z-1d319a79.vwrec"},
            {"Path": "c/recovery-20261030T223200Z-new.vwrec"},
            {"Path": "noise-file.txt"},
        ]
        self.assertEqual(gate.listing_summary(json.dumps(entries), old), (3, 1))
        for bad in ("not-json", '{"Path": "not-list"}', "[2]"):
            with self.assertRaises((TypeError, ValueError)):
                gate.listing_summary(bad, old)

    def test_optional_box_requires_interactive_exact_consent(self):
        with mock.patch.object(gate.sys, "stdin", TTY()), \
             mock.patch.object(gate.sys, "stdout", TTY()), \
             mock.patch("builtins.input", return_value=gate.BOX_PHRASE):
            self.assertTrue(gate.interactive_box_permission())
        with mock.patch.object(gate.sys, "stdin", TTY()), \
             mock.patch.object(gate.sys, "stdout", TTY()), \
             mock.patch("builtins.input", return_value="RESTORE"):
            self.assertFalse(gate.interactive_box_permission())
        with mock.patch.object(gate.sys, "stdin", io.StringIO()), \
             mock.patch.object(gate.sys, "stdout", TTY()), \
             mock.patch("builtins.input") as typed:
            self.assertFalse(gate.interactive_box_permission())
            typed.assert_not_called()

    def test_streaming_ciphertext_hash_uses_pipe_no_disk(self):
        data = b"encrypted bytes only"
        read_fd, write_fd = os.pipe()
        os.write(write_fd, data)
        os.close(write_fd)
        with os.fdopen(read_fd, "rb") as stream:
            fake = SimpleNamespace(stdout=stream, poll=lambda: 0, wait=lambda timeout: 0)
            with mock.patch.object(gate.subprocess, "Popen", return_value=fake) as spawned:
                actual, size = gate.bounded_ciphertext_digest([
                    "rclone", "cat", REMOTE, "--retries", "1",
                ], seconds=5, max_bytes=1024)
                self.assertEqual(actual, hashlib.sha256(data).hexdigest())
                self.assertEqual(size, len(data))
                self.assertEqual(spawned.call_args.kwargs["stderr"], gate.subprocess.DEVNULL)
                self.assertEqual(spawned.call_args.kwargs["env"]["HOME"], "/root")
        with self.assertRaises(ValueError):
            gate.bounded_ciphertext_digest(["rclone", "copyto", "src", "dest"], seconds=0)

    def test_remote_success_or_mismatch_or_missing_never_prints_private_object(self):
        listing = json.dumps([{"Path": Path(REMOTE).name}, {
            "Path": "newer/recovery-20261101T200000Z-xx.vwrec",
        }])
        def fake_run(args, timeout=15):
            if "listremotes" in args:
                return 0, "bw-backup:\n"
            if "lsjson" in args:
                return 0, listing
            self.fail("only listremotes and lsjson allowed")
        with tempfile.TemporaryDirectory() as name:
            rpt = gate.Report(Path(name))
            with mock.patch.object(gate, "run", side_effect=fake_run), \
                 mock.patch.object(gate, "bounded_ciphertext_digest", return_value=(CIPHER_SHA, 22)):
                r = gate.box_readback(ORIGINAL, rpt)
            self.assertEqual(r["status"], "MATCHED_ORIGINAL_PIN")
            self.assertTrue(any("newer_than_pin=1" in v for _, v in rpt.rows))
            self.assertFalse(any(REMOTE in v for _, v in rpt.rows))
            rpt = gate.Report(Path(name))
            with mock.patch.object(gate, "run", side_effect=fake_run), \
                 mock.patch.object(gate, "bounded_ciphertext_digest", return_value=("f" * 64, 22)):
                r = gate.box_readback(ORIGINAL, rpt)
            self.assertEqual(r["status"], "HASH_MISMATCH")
            self.assertTrue(rpt.blocked)
            rpt = gate.Report(Path(name))
            with mock.patch.object(gate, "run", return_value=(1, "")), \
                 mock.patch.object(gate, "bounded_ciphertext_digest") as download:
                r = gate.box_readback(ORIGINAL, rpt)
            self.assertEqual(r["status"], "REMOTE_UNAVAILABLE")
            download.assert_not_called()

    def test_scratch_classification_without_swap_or_artifacts(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            with mock.patch.object(gate, "STATE", root), \
                 mock.patch.object(gate, "run", return_value=(0, "tmpfs\n")), \
                 mock.patch.object(gate.Path, "read_text", return_value="Filename Type Size Used Priority\n"), \
                 mock.patch.object(gate.shutil, "disk_usage", return_value=SimpleNamespace(free=22 * 1024**3)):
                self.assertEqual(gate.scratch_readiness(), (True, False, 22, False))
                backups = root / "backups"
                backups.mkdir()
                (backups / "decrypted.tar").write_bytes(b"plaintext marker")
                with self.assertRaises(gate.Blocked):
                    gate.scratch_readiness()

    def test_sanitized_report_hold_and_blocked(self):
        with tempfile.TemporaryDirectory() as path:
            r = gate.Report(Path(path))
            r.add("PASS", "Original P8J evidence unchanged")
            r.add("PENDING", "Private Age custody remains off-host")
            with self.assertRaises(ValueError):
                r.add("PASS", "private\noutput")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(r.finish(), 0)
            p = Path(path) / "summary.txt"
            self.assertEqual(stat.S_IMODE(p.stat().st_mode), 0o600)
            self.assertIn("HOLD", p.read_text())
        with tempfile.TemporaryDirectory() as path:
            r = gate.Report(Path(path))
            r.add("BLOCKED", "Historical ciphertext SHA mismatch")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(r.finish(), 2)

    def test_no_live_or_destructive_side_effect_source_calls(self):
        source = SCRIPT.read_text(encoding="utf-8")
        for bad in (
            '["rclone", "copyto"', '["age", "--decrypt"',
            '["systemctl", "start"', '["systemctl", "enable"',
            '["mkfs.ext4"', '["mount"', '["docker",',
            '["vwctl", "restore"', "urllib.request.urlopen(", "requests.post(",
        ):
            self.assertNotIn(bad, source)
        self.assertIn("MAX_CIPHERTEXT = 4 * 1024 ** 3", source)
        self.assertIn("BOX_PHRASE =", source)

    def test_bad_invocation_denies_before_private_evidence(self):
        with mock.patch.object(gate.sys, "argv", ["p8k", "--expected-commit", PIN]), \
             mock.patch.object(gate.os, "geteuid", return_value=1000), \
             mock.patch.object(gate, "evidence_base") as evidence, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate.main(), 2)
            evidence.assert_not_called()

    def test_full_batch_one_turn_no_box_or_offline_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            with mock.patch.object(gate.sys, "argv", [
                     "p8k", "--expected-commit", PIN, "--offer-box-readback",
                 ]), mock.patch.object(gate.os, "geteuid", return_value=0), \
                 mock.patch.dict(gate.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(gate.platform, "node", return_value=gate.HOST), \
                 mock.patch.object(gate, "source_ok", return_value=True), \
                 mock.patch.object(gate, "host_ok", return_value=True), \
                 mock.patch.object(gate, "evidence_base", return_value=base), \
                 mock.patch.object(gate, "historical_evidence", return_value=candidate()), \
                 mock.patch.object(gate, "original_source_pin", return_value=ORIGINAL), \
                 mock.patch.object(gate, "installed_config"), \
                 mock.patch.object(gate, "storage_identity", return_value="u" * 12), \
                 mock.patch.object(gate, "stopped_safety", return_value=(11, 0)), \
                 mock.patch.object(gate, "scratch_readiness", return_value=(True, False, 25, False)), \
                 mock.patch.object(gate, "interactive_box_permission", return_value=False), \
                 mock.patch.object(gate, "box_readback") as box:
                buffer = io.StringIO()
                with contextlib.redirect_stdout(buffer):
                    self.assertEqual(gate.main(), 0)
                box.assert_not_called()
                output = buffer.getvalue()
                self.assertIn("HOLD", output)
                self.assertIn("PENDING", output)
                self.assertIn("NOT RUN", output)
                folder = next(base.glob("p8k-batched-recovery-*"))
                record = json.loads((folder / "candidate.private.json").read_text())
                self.assertEqual(record["box_readback"], "NOT_RUN")
                self.assertNotIn(AGE_RECIPIENT, json.dumps(record))

    def test_critical_local_block_prevents_box_contact(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            with mock.patch.object(gate.sys, "argv", [
                     "p8k", "--expected-commit", PIN, "--offer-box-readback",
                 ]), mock.patch.object(gate.os, "geteuid", return_value=0), \
                 mock.patch.dict(gate.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(gate.platform, "node", return_value=gate.HOST), \
                 mock.patch.object(gate, "source_ok", return_value=True), \
                 mock.patch.object(gate, "host_ok", return_value=True), \
                 mock.patch.object(gate, "evidence_base", return_value=base), \
                 mock.patch.object(gate, "historical_evidence", side_effect=gate.Blocked("original P8J absent")), \
                 mock.patch.object(gate, "interactive_box_permission") as consent, \
                 mock.patch.object(gate, "box_readback") as box, \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gate.main(), 2)
                consent.assert_not_called()
                box.assert_not_called()


if __name__ == "__main__":
    unittest.main()
