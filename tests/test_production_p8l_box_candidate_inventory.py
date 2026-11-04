"""P8L all-VM ciphertext inventory, independent pin and fail-closed streaming tests."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8l-box-candidate-inventory.py"
spec = importlib.util.spec_from_file_location("rc12_p8l_box_readonly", SCRIPT)
assert spec and spec.loader
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

PIN = "a" * 40
AGE_PUBLIC = "age1" + "a" * 58
AGE_HASH = hashlib.sha256(AGE_PUBLIC.encode()).hexdigest()
OLD_REMOTE = "bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec"
OLD_BYTES = b"age-encryption.org/v1\n" + b"ciphertext" * 8
OLD_SHA = hashlib.sha256(OLD_BYTES).hexdigest()


def historical():
    return {
        "HOST": "vaultwarden-oci-6-vnic",
        "HISTORICAL_REMOTE": OLD_REMOTE,
        "HISTORICAL_SHA256": OLD_SHA,
        "OFFLINE_RECIPIENT_SHA256": AGE_HASH,
    }


def p8k_summary():
    return "\n".join((
        "Gate P8K - MULTI-CHECK recovery and safety batch (READ-ONLY)",
        "PASS       Original P8I-R stopped-host HOLD and P8J PRE-TRANSFER HOLD evidence intact",
        "PASS       Original historical ciphertext candidate SHA reference unchanged",
        "PASS       Original PUBLIC offline Age recipient hash matches installed config",
        "PASS       Immutable rc.12 release pointer and owned dedicated non-root ext4 dual identity",
        "PASS       All 11 concrete units stopped/unenabled, static notify template has NO instances",
        "PASS       /run tmpfs still present",
        "PASS       Kernel swap remains disabled",
        "PASS       Read-only recursive Box object inventory succeeded; .vwrec count=9, newer_than_pin=2",
        "PASS       Independent exact historical Box ciphertext SHA-256 matched original pin; streamed_bytes=358680, none saved",
        "HOLD       P8K batched read-only only; no Age PRIVATE key, decryption, restore, live startup or production GO",
    )) + "\n"


def p8k_record():
    return {
        "schema": 1, "phase": "PRE_RESTORE_BATCH_ONLY",
        "source_commit": gate.P8K_SHA,
        "historical_remote_unverified": OLD_REMOTE,
        "historical_expected_sha256": OLD_SHA,
        "offline_public_recipient_sha256": AGE_HASH,
        "box_readback": {
            "status": "MATCHED_ORIGINAL_PIN",
            "bytes": 358680, "sha256": OLD_SHA,
        },
    }


def inventory():
    return [
        {"Path": "recovery-20261029T223200Z-1d319a79.vwrec", "Size": len(OLD_BYTES), "IsDir": False},
        {"Path": "new-host/recovery-20261101T023000Z-f00.vwrec", "Size": 200, "IsDir": False},
        {"Path": "different-host/recovery-20261103T000000Z-abc.vwrec", "Size": 220, "IsDir": False},
        {"Path": "old-host/recovery-20261020T103000Z-zzz.vwrec", "Size": 250, "IsDir": False},
    ]


class TTY(io.StringIO):
    def isatty(self):
        return True


class P8LCandidateTests(unittest.TestCase):
    def test_wrong_host_unpinned_source_and_dirty_git_refused(self):
        accepted = [
            SimpleNamespace(returncode=0, stdout=(PIN + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=(gate.BRANCH + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=b""),
        ]
        with mock.patch.object(gate.subprocess, "run", side_effect=accepted):
            self.assertTrue(gate.source_approved(PIN))
        accepted[-1] = SimpleNamespace(returncode=0, stdout=b"?? unexpected")
        with mock.patch.object(gate.subprocess, "run", side_effect=accepted):
            self.assertFalse(gate.source_approved(PIN))
        with mock.patch.object(gate.subprocess, "run") as backend:
            self.assertFalse(gate.source_approved("unreviewed"))
            backend.assert_not_called()
        with mock.patch.object(gate.platform, "node", return_value="vaultwarden-oci-6-vnic"):
            self.assertFalse(gate.host_approved())

    def test_original_successful_box_readback_is_required(self):
        current = {"summary": p8k_summary().encode(),
                   "candidate": json.dumps(p8k_record()).encode()}
        def fake_private(path, max_size=32768):
            return current["summary" if path.name == "summary.txt" else "candidate"]
        with tempfile.TemporaryDirectory() as name, \
             mock.patch.object(gate, "protected_dir", return_value=True), \
             mock.patch.object(gate, "read_private", side_effect=fake_private):
            base = Path(name)
            self.assertEqual(gate.previous_box_proof(base)["box_readback"]["status"], "MATCHED_ORIGINAL_PIN")
            current["summary"] = p8k_summary().replace(
                "HOLD       P8K", "BLOCKED    P8K",
            ).encode()
            with self.assertRaises(gate.Blocked):
                gate.previous_box_proof(base)
            current["summary"] = p8k_summary().encode()
            record = p8k_record()
            record["box_readback"]["status"] = "HASH_MISMATCH"
            current["candidate"] = json.dumps(record).encode()
            with self.assertRaises(gate.Blocked):
                gate.previous_box_proof(base)

    def test_original_metadata_is_only_literal_with_traversal_rejected(self):
        pin = historical()
        def src(remote=OLD_REMOTE, sha=OLD_SHA):
            return "\n".join((
                "HOST = 'vaultwarden-oci-6-vnic'",
                f"HISTORICAL_REMOTE = {remote!r}",
                f"HISTORICAL_SHA256 = {sha!r}",
                f"OFFLINE_RECIPIENT_SHA256 = {AGE_HASH!r}",
            ))
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "old.py"
            path.write_text(src())
            with mock.patch.object(gate, "ORIGINAL_PIN", path):
                self.assertEqual(gate.original_public_pins()["HISTORICAL_REMOTE"], OLD_REMOTE)
                path.write_text(src(remote="bw-backup:bw-backup/../recovery-20261029T223200Z-xyz.vwrec"))
                with self.assertRaises(gate.Blocked):
                    gate.original_public_pins()
                path.write_text(src(sha="f" * 63))
                with self.assertRaises(gate.Blocked):
                    gate.original_public_pins()
                path.write_text(src().replace(
                    f"HISTORICAL_SHA256 = {OLD_SHA!r}", "HISTORICAL_SHA256 = execute()"))
                with self.assertRaises(gate.Blocked):
                    gate.original_public_pins()

    def test_safe_path_counts_and_parent_provenance(self):
        entries, newer = gate.bounded_objects(json.dumps(inventory()), historical())
        self.assertEqual(len(entries), 4)
        self.assertEqual(newer, 2)
        self.assertEqual(entries[0]["name_date"], "20261103T000000Z")
        self.assertFalse(entries[0]["same_parent_as_historical"])
        self.assertTrue(next(x for x in entries if x["remote"] == OLD_REMOTE)["same_parent_as_historical"])
        self.assertEqual(len(entries[0]["path_fingerprint"]), 12)

    def test_box_survey_quarantines_unrelated_defective_fixtures_and_blocks_historical(self):
        good = inventory()
        invalids = [
            ("unsafe_path", {"Path": "../recovery-20261103T000000Z-evil.vwrec", "Size": 120, "IsDir": False}),
            ("not_file", {"Path": "backup/recovery-20261103T000000Z-evil.vwrec", "Size": 120, "IsDir": True}),
            ("missing_size", {"Path": "backup/recovery-20261103T000000Z-evil.vwrec", "Size": None, "IsDir": False}),
            ("undersized", {"Path": "backup/recovery-20261103T000000Z-evil.vwrec", "Size": 24, "IsDir": False}),
            ("oversized", {"Path": "backup/recovery-20261103T000000Z-evil.vwrec", "Size": gate.MAX_OBJECT_BYTES + 1, "IsDir": False}),
        ]
        for reason, item in invalids:
            with self.subTest(reason=reason):
                stats = {}
                safe, newer = gate.bounded_objects(
                    json.dumps(good + [item]), historical(), diagnostics=stats)
                self.assertEqual(len(safe), 4)
                self.assertEqual(newer, 2)
                self.assertEqual(stats["quarantined"], 1)
                self.assertEqual(stats[reason], 1)
                self.assertFalse(any(x["remote"].endswith(item["Path"]) for x in safe))
        for broken in (good + [good[0]], good[1:]):
            with self.assertRaises(gate.Blocked):
                gate.bounded_objects(json.dumps(broken), historical())
        historical_broken = [dict(x) for x in good]
        historical_broken[0]["Size"] = 12
        with self.assertRaises(gate.Blocked) as error:
            gate.bounded_objects(json.dumps(historical_broken), historical())
        self.assertEqual(str(error.exception), "BOX_HISTORICAL_OBJECT_INVALID_METADATA")
        many = [good[0]] + [
            {"Path": f"test/recovery-20261103T000000Z-x{i}.vwrec",
             "Size": 120, "IsDir": False} for i in range(12)]
        with self.assertRaises(gate.Blocked):
            gate.bounded_objects(json.dumps(many), historical())
        self.assertFalse(gate.valid_relative_path("nested/../../recovery-20261103T000000Z-abc.vwrec"))
        self.assertFalse(gate.valid_relative_path("nested\\recovery-20261103T000000Z-abc.vwrec"))


    def test_stream_ciphertext_age_envelope_hash_without_disk(self):
        payload = OLD_BYTES
        rd, wr = os.pipe()
        os.write(wr, payload)
        os.close(wr)
        with os.fdopen(rd, "rb") as stream:
            fake = SimpleNamespace(stdout=stream, poll=lambda: 0, wait=lambda timeout: 0)
            with mock.patch.object(gate.subprocess, "Popen", return_value=fake) as proc:
                sha, n, age = gate.hash_age_stream(OLD_REMOTE, size_limit=len(payload), seconds=5)
                self.assertEqual((sha, n, age), (OLD_SHA, len(payload), True))
                self.assertEqual(proc.call_args.kwargs["env"]["HOME"], "/root")
                self.assertEqual(proc.call_args.kwargs["stderr"], gate.subprocess.DEVNULL)
                self.assertEqual(proc.call_args.kwargs["stdout"], gate.subprocess.PIPE)
        with self.assertRaises(ValueError):
            gate.hash_age_stream("bw-backup:bw-backup/../../evil.vwrec", size_limit=300)

    def test_non_age_envelope_can_be_detected_without_decryption(self):
        data = b"INVALID" * 20
        rd, wr = os.pipe()
        os.write(wr, data)
        os.close(wr)
        with os.fdopen(rd, "rb") as stream:
            fake = SimpleNamespace(stdout=stream, poll=lambda: 0, wait=lambda timeout: 0)
            with mock.patch.object(gate.subprocess, "Popen", return_value=fake):
                _, n, ok = gate.hash_age_stream(OLD_REMOTE, size_limit=len(data), seconds=5)
                self.assertEqual(n, len(data))
                self.assertFalse(ok)

    def test_box_remote_always_uses_root_env_not_sudo_overrides(self):
        with mock.patch.dict(gate.os.environ, {
            "HOME": "/home/ubuntu",
            "RCLONE_CONFIG": "/tmp/untrusted.conf",
            "RCLONE_CONFIG_PASS": "not-for-logs",
        }):
            env = gate.rclone_root_env()
        self.assertEqual(env["HOME"], "/root")
        self.assertEqual(env["XDG_CONFIG_HOME"], "/root/.config")
        self.assertNotIn("RCLONE_CONFIG", env)
        self.assertNotIn("RCLONE_CONFIG_PASS", env)

    def test_vm_only_box_survey_has_no_interactive_prompt(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("--read-only-box", source)
        self.assertNotIn("input(", source)
        self.assertNotIn("exact_consent(", source)


    def test_existing_root_config_must_be_private(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / "rclone.conf"
            p.write_text("[bw-backup]\ntype=box\n")
            def meta(path):
                return SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=0)
            with mock.patch.object(gate, "RCLONE_CONFIG", p), \
                 mock.patch.object(gate.Path, "lstat", autospec=True, side_effect=meta), \
                 mock.patch.object(gate, "read_command", return_value=(0, "bw-backup:\n")):
                self.assertTrue(gate.root_remote_configured())
            p.chmod(0o644)
            with mock.patch.object(gate, "RCLONE_CONFIG", p), \
                 mock.patch.object(gate, "read_command") as read:
                self.assertFalse(gate.root_remote_configured())
                read.assert_not_called()

    def test_sanitized_report_is_private_and_no_auto_restore(self):
        with tempfile.TemporaryDirectory() as path:
            report = gate.Report(Path(path))
            report.add("PASS", "Historical SHA matched")
            report.add("PENDING", "New SHA is an untrusted observation")
            with self.assertRaises(ValueError):
                report.add("PASS", "private\nidentifier")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 0)
            p = Path(path) / "summary.txt"
            self.assertEqual(stat.S_IMODE(p.stat().st_mode), 0o600)
            self.assertIn("HOLD", p.read_text())
        with tempfile.TemporaryDirectory() as path:
            report = gate.Report(Path(path))
            report.add("BLOCKED", "Age v1 header missing")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 2)

    def test_root_private_symlink_evidence_is_not_followed(self):
        with tempfile.TemporaryDirectory() as name:
            base = Path(name)
            path = base / "payload"
            path.write_text("secret")
            alias = base / "alias"
            alias.symlink_to(path)
            with self.assertRaises(OSError):
                gate.read_private(alias)

    def test_no_live_or_destructive_operations_in_source(self):
        content = SCRIPT.read_text()
        for unsafe in (
            '["rclone", "copy"', '["rclone", "sync"', '["rclone", "delete"',
            '["mount"', '["mkfs.ext4"', '["docker"', '["systemctl", "start"',
            '["systemctl", "enable"', '["vwctl", "restore"', '["age", "--decrypt"',
            '["sops", "--decrypt"', '["7zz",', "requests.post(", "subprocess.Popen([\"age\"",
        ):
            self.assertNotIn(unsafe, content)
        self.assertIn("MAX_BATCH_BYTES = 8 * 1024**3", content)
        self.assertIn("NEW_OBSERVATION_ONLY", content)
        self.assertNotIn("input(", content)

    def test_early_wrong_invocation_never_reads_box_or_original_evidence(self):
        with mock.patch.object(gate.sys, "argv", ["p8l", "--expected-commit", PIN]), \
             mock.patch.object(gate.os, "geteuid", return_value=1000), \
             mock.patch.object(gate, "evidence_base") as evidence, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate.main(), 2)
            evidence.assert_not_called()

    def test_mocked_one_turn_batch_omits_box_without_read_only_flag(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            with mock.patch.object(gate.sys, "argv", ["p8l", "--expected-commit", PIN]), \
                 mock.patch.object(gate.os, "geteuid", return_value=0), \
                 mock.patch.dict(gate.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(gate.platform, "node", return_value=gate.HOST), \
                 mock.patch.object(gate, "source_approved", return_value=True), \
                 mock.patch.object(gate, "host_approved", return_value=True), \
                 mock.patch.object(gate, "evidence_base", return_value=base), \
                 mock.patch.object(gate, "previous_box_proof", return_value=p8k_record()), \
                 mock.patch.object(gate, "original_public_pins", return_value=historical()), \
                 mock.patch.object(gate, "local_isolation", return_value=11), \
                 mock.patch.object(gate, "root_remote_configured", return_value=True), \
                 mock.patch.object(gate, "read_command") as remote:
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(gate.main(), 0)
                remote.assert_not_called()
                self.assertIn("not requested by --read-only-box", output.getvalue())
                self.assertIn("HOLD", output.getvalue())
                private = json.loads(next(base.glob("p8l-box-source-*/candidates.private.json")).read_text())
                self.assertEqual(private["records"], [])


    def test_mocked_safety_failure_prevents_box_contact(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            with mock.patch.object(gate.sys, "argv", [
                     "p8l", "--expected-commit", PIN, "--read-only-box",
                 ]), mock.patch.object(gate.os, "geteuid", return_value=0), \
                 mock.patch.dict(gate.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(gate.platform, "node", return_value=gate.HOST), \
                 mock.patch.object(gate, "source_approved", return_value=True), \
                 mock.patch.object(gate, "host_approved", return_value=True), \
                 mock.patch.object(gate, "evidence_base", return_value=base), \
                 mock.patch.object(gate, "previous_box_proof", side_effect=gate.Blocked("previous evidence changed")), \
                 mock.patch.object(gate, "read_command") as remote, \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gate.main(), 2)
                remote.assert_not_called()


    def test_mocked_full_box_batch_keeps_newer_sha_untrusted(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            box_json = json.dumps(inventory())
            def fake_read(args, timeout=20, cap=gate.MAX_LIST_BYTES):
                if "lsjson" in args:
                    return (0, box_json)
                self.fail("only one read-only Box inventory expected")
            def fake_stream(remote, size_limit, seconds=600):
                if remote == OLD_REMOTE:
                    return OLD_SHA, len(OLD_BYTES), True
                return "c" * 64, size_limit, True
            with mock.patch.object(gate.sys, "argv", ["p8l", "--expected-commit", PIN, "--read-only-box"]), \
                 mock.patch.object(gate.os, "geteuid", return_value=0), \
                 mock.patch.dict(gate.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(gate.platform, "node", return_value=gate.HOST), \
                 mock.patch.object(gate, "source_approved", return_value=True), \
                 mock.patch.object(gate, "host_approved", return_value=True), \
                 mock.patch.object(gate, "evidence_base", return_value=base), \
                 mock.patch.object(gate, "previous_box_proof", return_value=p8k_record()), \
                 mock.patch.object(gate, "original_public_pins", return_value=historical()), \
                 mock.patch.object(gate, "local_isolation", return_value=11), \
                 mock.patch.object(gate, "root_remote_configured", return_value=True), \
                 mock.patch.object(gate, "read_command", side_effect=fake_read), \
                 mock.patch.object(gate, "hash_age_stream", side_effect=fake_stream):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(gate.main(), 0)
                self.assertIn("reviewed=4/4", output.getvalue())
                data = json.loads(next(base.glob("p8l-box-source-*/candidates.private.json")).read_text())
                self.assertEqual(len(data["records"]), 4)
                self.assertEqual(sum(x["status"] == "PIN_MATCH" for x in data["records"]), 1)
                self.assertEqual(sum(x["status"] == "NEW_OBSERVATION_ONLY" for x in data["records"]), 3)
                self.assertNotIn(AGE_PUBLIC, json.dumps(data))
                self.assertNotIn(OLD_REMOTE, output.getvalue())

    def test_failed_streams_consume_cumulative_network_budget(self):
        """Two failed max-size attempts must suppress third Box read."""
        large = gate.MAX_OBJECT_BYTES
        items = [
            {"Path": "recovery-20261029T223200Z-1d319a79.vwrec", "Size": large, "IsDir": False},
            {"Path": "test/recovery-20261101T100000Z-xyz.vwrec", "Size": large, "IsDir": False},
            {"Path": "test/recovery-20261103T100000Z-xyz.vwrec", "Size": large, "IsDir": False},
        ]
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            with mock.patch.object(gate.sys, "argv", ["p8l", "--expected-commit", PIN, "--read-only-box"]), \
                 mock.patch.object(gate.os, "geteuid", return_value=0), \
                 mock.patch.dict(gate.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(gate.platform, "node", return_value=gate.HOST), \
                 mock.patch.object(gate, "source_approved", return_value=True), \
                 mock.patch.object(gate, "host_approved", return_value=True), \
                 mock.patch.object(gate, "evidence_base", return_value=base), \
                 mock.patch.object(gate, "previous_box_proof", return_value=p8k_record()), \
                 mock.patch.object(gate, "original_public_pins", return_value=historical()), \
                 mock.patch.object(gate, "local_isolation", return_value=11), \
                 mock.patch.object(gate, "root_remote_configured", return_value=True), \
                 mock.patch.object(gate, "read_command", return_value=(0, json.dumps(items))), \
                 mock.patch.object(gate, "hash_age_stream", side_effect=gate.Blocked("remote lost")) as stream:
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(gate.main(), 0)
                self.assertEqual(stream.call_count, 2)
                record = json.loads(next(base.glob("p8l-box-source-*/candidates.private.json")).read_text())
                self.assertEqual(sum(x["status"] == "STREAM_UNAVAILABLE" for x in record["records"]), 2)
                self.assertEqual(sum(x["status"] == "NOT_READ_CUMULATIVE_SIZE_BOUND" for x in record["records"]), 1)



if __name__ == "__main__":
    unittest.main()
