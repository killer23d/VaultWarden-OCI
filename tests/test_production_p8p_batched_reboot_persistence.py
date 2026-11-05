"""Mocked safety and integration contracts for P8P batched reboot acceptance."""
from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import ExitStack, redirect_stdout
from types import SimpleNamespace
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8p-batched-reboot-persistence-newvm.py"
SPEC = importlib.util.spec_from_file_location("p8p_batched_reboot", SCRIPT)
assert SPEC and SPEC.loader
p8p = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p8p)
PIN = "a" * 40
OLD_BOOT = "12345678-1234-1234-1234-1234567890ab"
NEW_BOOT = "23456789-1234-1234-1234-1234567890ab"

# Simulated root-file metadata for unprivileged CI. Actual P8P stays STRICT
# root-only (uid 0, mode 0600); only these mock tests reinterpret st_uid.
_REAL_FSTAT = os.fstat
def fake_root_fstat(fd):
    # Keep the complete stat_result interface (st_dev/st_ino needed by
    # tempfile cleanup), changing ONLY the simulated file-owner UID.
    values = list(_REAL_FSTAT(fd))
    values[4] = 0
    return os.stat_result(values)



class TTY(io.StringIO):
    def isatty(self):
        return True


def fixture_checkpoint(*, phase="requested"):
    return {"schema": 1, "host": p8p.HOST, "release": p8p.RELEASE,
            "phase": phase, "reviewed_commit": PIN, "p8o_commit": p8p.P8O_COMMIT,
            "original_boot_id": OLD_BOOT, "hashes": {"db": "abc"}, "requested_at": "sample"}


def fake_doctor(edge_pass=True, extra_fail=None, worker_pass=False):
    allowed = list(p8p.FOUNDATION) + list(p8p.MANDATORY) + sorted(p8p.EXPECTED_FAILURE)
    allowed += ["other.safe." + str(n) for n in range(27 - len(allowed))]
    status = {name: "PASS" for name in allowed}
    status["crowdsec.cloudflare"] = "PASS" if worker_pass else "FAIL"
    status["runtime.paths"] = "FAIL"
    if not edge_pass:
        status["edge.cloudflare.iptables"] = "FAIL"
    if extra_fail:
        status[extra_fail] = "FAIL"
    return SimpleNamespace(
        diagnose_doctor=lambda *args, **kwargs: ("valid", status, "private"),
        product_doctor_ids=lambda: tuple(allowed),
        inspect_stopped_runtime_paths=lambda *args: ("PENDING", "no unsafe entries"),
    )


class P8PTests(unittest.TestCase):
    def test_source_and_privacy_pins(self):
        self.assertEqual(p8p.HOST, "vaultwarden-oci-7-vnic")
        self.assertEqual(len(p8p.DB_SHA), 64)
        self.assertEqual(len(p8p.RECIPIENT_SHA), 64)
        self.assertEqual(len(p8p.P8O_COMMIT), 40)
        self.assertEqual(p8p.VOLUME_FP, "2449f67320a1")
        self.assertEqual(p8p.REMOTE, "bw-backup:bw-backup")
        self.assertEqual(len(p8p.FOUNDATION), 5)
        self.assertNotIn("crowdsec.cloudflare", p8p.FOUNDATION)

    def test_source_rejects_wrong_commit_before_git(self):
        for pin in ("invalid", "a" * 39, "a" * 41, "X" * 40):
            self.assertFalse(p8p.source_clean(pin))

    def test_invalid_options_block_before_privileged_evidence(self):
        candidates = [
            [],
            ["--expected-commit", "not-sha", "--mode", "reboot", "--oci-console-ready"],
            ["--expected-commit", PIN, "--mode", "reboot"],
            ["--expected-commit", PIN, "--mode", "verify", "--oci-console-ready"],
            ["--expected-commit", PIN, "--mode", "verify-and-rearm"],
            ["--expected-commit", PIN, "--mode", "unknown"],
            ["--expected-commit", PIN, "--mode", "reboot", "--oci-console-ready", "--extra"],
        ]
        for args in candidates:
            with self.subTest(args=args), mock.patch.object(sys, "argv", [str(SCRIPT), *args]), \
                 mock.patch.object(p8p, "accepted_p8o") as previous, \
                 mock.patch.object(p8p, "authorized_host", return_value=True), \
                 mock.patch.object(p8p, "source_clean", return_value=True), \
                 mock.patch.object(sys, "stdin", TTY()):
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(p8p.main(), 2)
                previous.assert_not_called()

    @mock.patch.object(p8p.os, "fstat", new=fake_root_fstat)
    def test_read_private_file_0600_and_no_symlink(self):
        with tempfile.TemporaryDirectory() as d:
            file = Path(d) / "private"
            file.write_bytes(b"accepted")
            file.chmod(0o600)
            self.assertEqual(p8p.private_read(file), b"accepted")
            file.chmod(0o644)
            with self.assertRaises(p8p.Blocked):
                p8p.private_read(file)
            file.chmod(0o600)
            link = Path(d) / "link"
            link.symlink_to(file)
            with self.assertRaises(OSError):
                p8p.private_read(link)

    def test_exclusive_persistent_attempt_marker(self):
        with tempfile.TemporaryDirectory() as folder:
            marker = Path(folder) / "marker"
            p8p.exclusive_file(marker, b'{"schema":1}\n')
            self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                p8p.exclusive_file(marker, b"replacement")
            self.assertEqual(marker.read_bytes(), b'{"schema":1}\n')

    @mock.patch.object(p8p.os, "fstat", new=fake_root_fstat)
    def test_checkpoint_exact_identity_and_phase(self):
        with tempfile.TemporaryDirectory() as d:
            checkpoint = Path(d) / "checkpoint"
            with mock.patch.object(p8p, "CHECKPOINT", checkpoint):
                p8p.exclusive_file(checkpoint, (json.dumps(fixture_checkpoint())+"\n").encode())
                self.assertEqual(p8p.checkpoint_read()["phase"], "requested")
                updated = dict(fixture_checkpoint(), phase="verified", verified_boot_id=NEW_BOOT)
                p8p.checkpoint_finish(updated)
                self.assertEqual(p8p.checkpoint_read()["phase"], "verified")
                with self.assertRaises(p8p.Blocked):
                    p8p.checkpoint_finish(updated)

    @mock.patch.object(p8p.os, "fstat", new=fake_root_fstat)
    def test_checkpoint_rejects_wrong_host(self):
        with tempfile.TemporaryDirectory() as d:
            checkpoint = Path(d) / "checkpoint"
            incorrect = dict(fixture_checkpoint(), host="original-vm")
            with mock.patch.object(p8p, "CHECKPOINT", checkpoint):
                p8p.exclusive_file(checkpoint, (json.dumps(incorrect)+"\n").encode())
                with self.assertRaises(p8p.Blocked):
                    p8p.checkpoint_read()

    @mock.patch.object(p8p.os, "fstat", new=fake_root_fstat)
    def test_checkpoint_never_allows_protected_digest_edit(self):
        with tempfile.TemporaryDirectory() as d:
            checkpoint = Path(d) / "checkpoint"
            with mock.patch.object(p8p, "CHECKPOINT", checkpoint):
                p8p.exclusive_file(checkpoint, (json.dumps(fixture_checkpoint())+"\n").encode())
                updated = dict(fixture_checkpoint(), phase="verified", hashes={"db": "altered"})
                with self.assertRaises(p8p.Blocked):
                    p8p.checkpoint_finish(updated)

    def test_protected_file_hashes_equal_or_block(self):
        valid = fixture_checkpoint()
        p8p.compare_paths(valid, {"db": "abc"})
        for invalid in ({"db": "xyz"}, {"extra": "abc"}, {}):
            with self.assertRaises(p8p.Blocked):
                p8p.compare_paths(valid, invalid)

    def test_full_doctor_preboot_pass(self):
        checks, paths, edge = p8p.doctor(fake_doctor(), Path("/tmp"), after_boot=False)
        self.assertTrue(edge)
        self.assertEqual(paths, "PENDING")
        self.assertEqual(checks["crowdsec.cloudflare"], "FAIL")

    def test_postboot_missing_443_rule_is_pending_only(self):
        checks, paths, edge = p8p.doctor(fake_doctor(edge_pass=False), Path("/tmp"), after_boot=True)
        self.assertFalse(edge)
        self.assertEqual(checks["crowdsec.engine"], "PASS")

    def test_missing_443_rule_preboot_fails(self):
        with self.assertRaises(p8p.Blocked):
            p8p.doctor(fake_doctor(edge_pass=False), Path("/tmp"), after_boot=False)

    def test_unsafe_other_doctor_failure_blocks_postboot(self):
        with self.assertRaises(p8p.Blocked):
            p8p.doctor(fake_doctor(edge_pass=False, extra_fail="other.safe.0"),
                       Path("/tmp"), after_boot=True)

    def test_worker_claiming_pass_is_blocked(self):
        with self.assertRaises(p8p.Blocked):
            p8p.doctor(fake_doctor(worker_pass=True), Path("/tmp"), after_boot=True)

    def test_report_hold_and_partial_rearm_block(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            report = p8p.Report(folder, "verify")
            report.add("PENDING", "filter missing")
            with redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish("HOLD"), 0)
            self.assertIn("HOLD", (folder / "summary.txt").read_text())
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            report = p8p.Report(folder, "verify-and-rearm")
            report.mutation_started = True
            with redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish("REARMED"), 2)
            self.assertIn("BLOCKED", (folder / "summary.txt").read_text())

    def test_report_rejects_unsafe_summary(self):
        with tempfile.TemporaryDirectory() as d:
            report = p8p.Report(Path(d), "verify")
            for kind, msg in (("PRIVATE", "x"), ("PASS", "secret\nkey"),
                              ("PASS", "x" * 251)):
                with self.assertRaises(ValueError):
                    report.add(kind, msg)

    def test_one_shot_reboot_flow_records_checkpoint_before_reboot(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            checkpoint = root / "checkpoint.json"
            def fake_reboot():
                self.assertTrue(checkpoint.is_file())
                self.assertEqual(checkpoint.stat().st_mode & 0o777, 0o600)
                return True
            out = TTY()
            with ExitStack() as stack:
                stack.enter_context(mock.patch.object(p8p, "EVIDENCE", root))
                stack.enter_context(mock.patch.object(p8p, "CHECKPOINT", checkpoint))
                stack.enter_context(mock.patch.object(p8p, "authorized_host", return_value=True))
                stack.enter_context(mock.patch.object(p8p, "source_clean", return_value=True))
                stack.enter_context(mock.patch.object(p8p, "accepted_p8o"))
                stack.enter_context(mock.patch.object(p8p, "snapshot", return_value={"db": "abc"}))
                stack.enter_context(mock.patch.object(p8p, "boot_id", return_value=OLD_BOOT))
                reboot = stack.enter_context(mock.patch.object(p8p, "reboot_once", side_effect=fake_reboot))
                stack.enter_context(mock.patch.object(sys, "stdin", TTY()))
                stack.enter_context(mock.patch.object(sys, "stdout", out))
                stack.enter_context(mock.patch.object(sys, "argv", [
                    str(SCRIPT), "--expected-commit", PIN, "--mode", "reboot",
                    "--oci-console-ready",
                ]))
                self.assertEqual(p8p.main(), 0)
            reboot.assert_called_once()
            self.assertIn("REBOOT_REQUESTED", out.getvalue())
            self.assertEqual(json.loads(checkpoint.read_text())["phase"], "requested")

    @mock.patch.object(p8p.os, "fstat", new=fake_root_fstat)
    def test_verify_without_new_boot_blocks(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            checkpoint = root / "checkpoint.json"
            p8p.exclusive_file(checkpoint, (json.dumps(fixture_checkpoint())+"\n").encode())
            out = TTY()
            with ExitStack() as stack:
                stack.enter_context(mock.patch.object(p8p, "EVIDENCE", root))
                stack.enter_context(mock.patch.object(p8p, "CHECKPOINT", checkpoint))
                stack.enter_context(mock.patch.object(p8p, "authorized_host", return_value=True))
                stack.enter_context(mock.patch.object(p8p, "source_clean", return_value=True))
                stack.enter_context(mock.patch.object(p8p, "accepted_p8o"))
                stack.enter_context(mock.patch.object(p8p, "boot_id", return_value=OLD_BOOT))
                snap = stack.enter_context(mock.patch.object(p8p, "snapshot"))
                stack.enter_context(mock.patch.object(sys, "stdout", out))
                stack.enter_context(mock.patch.object(sys, "argv", [
                    str(SCRIPT), "--expected-commit", PIN, "--mode", "verify",
                ]))
                self.assertEqual(p8p.main(), 2)
            snap.assert_not_called()
            self.assertIn("BLOCKED", out.getvalue())

    @mock.patch.object(p8p.os, "fstat", new=fake_root_fstat)
    def test_uncertain_prior_rearm_attempt_blocks_before_new_snapshot(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            checkpoint = root / "checkpoint.json"
            attempt = root / "rearm.json"
            p8p.exclusive_file(checkpoint, (json.dumps(fixture_checkpoint())+"\n").encode())
            p8p.exclusive_file(attempt, b'{"schema":1}\n')
            out = TTY()
            with ExitStack() as stack:
                for name, value in (("EVIDENCE", root), ("CHECKPOINT", checkpoint),
                                    ("REARM_MARKER", attempt)):
                    stack.enter_context(mock.patch.object(p8p, name, value))
                stack.enter_context(mock.patch.object(p8p, "authorized_host", return_value=True))
                stack.enter_context(mock.patch.object(p8p, "source_clean", return_value=True))
                stack.enter_context(mock.patch.object(p8p, "accepted_p8o"))
                snap = stack.enter_context(mock.patch.object(p8p, "snapshot"))
                stack.enter_context(mock.patch.object(sys, "stdout", out))
                stack.enter_context(mock.patch.object(sys, "argv", [
                    str(SCRIPT), "--expected-commit", PIN, "--mode", "verify",
                ]))
                self.assertEqual(p8p.main(), 2)
            snap.assert_not_called()
            self.assertIn("BLOCKED", out.getvalue())

    @mock.patch.object(p8p.os, "fstat", new=fake_root_fstat)
    def test_postboot_verify_and_one_shot_rearm(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            checkpoint = root / "checkpoint.json"
            rearm_marker = root / "rearm.json"
            p8p.exclusive_file(checkpoint, (json.dumps(fixture_checkpoint())+"\n").encode())
            out = TTY()
            def rearm(folder, name, argv, timeout):
                self.assertTrue(rearm_marker.is_file(), "rearm attempt must be durable before mutation")
                self.assertEqual(argv[-2:], ["edge", "refresh"])
                return 0
            before_state = ({"edge.cloudflare.iptables": "FAIL"}, "PENDING", False)
            after_state = ({key: "PASS" for key in p8p.FOUNDATION}, "PENDING", True)
            with ExitStack() as stack:
                for label, value in (("EVIDENCE", root), ("CHECKPOINT", checkpoint),
                                     ("REARM_MARKER", rearm_marker)):
                    stack.enter_context(mock.patch.object(p8p, label, value))
                stack.enter_context(mock.patch.object(p8p, "authorized_host", return_value=True))
                stack.enter_context(mock.patch.object(p8p, "source_clean", return_value=True))
                stack.enter_context(mock.patch.object(p8p, "accepted_p8o"))
                stack.enter_context(mock.patch.object(p8p, "boot_id", return_value=NEW_BOOT))
                stack.enter_context(mock.patch.object(p8p, "snapshot", return_value={"db": "abc"}))
                checks = stack.enter_context(mock.patch.object(
                    p8p, "doctor", side_effect=[before_state, after_state]))
                stack.enter_context(mock.patch.object(p8p, "load_helper", return_value=SimpleNamespace()))
                logs = stack.enter_context(mock.patch.object(p8p, "private_log", side_effect=rearm))
                stack.enter_context(mock.patch.object(sys, "stdin", TTY()))
                stack.enter_context(mock.patch.object(sys, "stdout", out))
                stack.enter_context(mock.patch.object(sys, "argv", [
                    str(SCRIPT), "--expected-commit", PIN, "--mode",
                    "verify-and-rearm", "--oci-console-ready",
                ]))
                self.assertEqual(p8p.main(), 0)
            self.assertEqual(logs.call_count, 1)
            self.assertEqual(checks.call_count, 2)
            self.assertTrue(rearm_marker.exists())
            self.assertEqual(json.loads(checkpoint.read_text())["phase"], "verified")
            self.assertIn("REARMED", out.getvalue())

    def test_no_public_runtime_or_box_mutation_primitives(self):
        code = SCRIPT.read_text()
        for disallowed in ('"dns", "update"', '"remediation-start"', '"backup"', '"restore"',
                           '"start"', "rclone copy", "rclone delete", "recovery.restore_recovery(",
                           '"notification", "test"', '"crowdsec", "setup"'):
            self.assertNotIn(disallowed, code)


if __name__ == "__main__":
    unittest.main()
