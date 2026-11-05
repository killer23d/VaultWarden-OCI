"""P8R new-VM one-shot local postboot origin re-arm negative and integration tests."""
from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import ExitStack, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8r-postboot-origin-rearm-batch.py"
SPEC = importlib.util.spec_from_file_location("p8r_postboot_origin_rearm", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
p8r = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p8r)
PIN = "a" * 40
P8O_SHA = "f989f2c91a1276501aab126443b96d593261e54e"


class TTY(io.StringIO):
    def isatty(self):
        return True


def accepted_p8q_summary() -> str:
    lines = ["Gate P8Q - NEW disposable VM independent P8P postboot blocker diagnosis (READ-ONLY)"]
    expected = dict(p8r.REQUIRED_P8Q)
    for index in range(50 - len(expected)):
        expected["diagnostic.extra" + str(index)] = "PASS"
    for name, state in expected.items():
        lines.append(state + "  " + name)
    lines.append("READONLY  p8q.no-mutation.no-reboot.no-rearm.no-box.no-live-go")
    return "\n".join(lines) + "\n"


def fake_p8p(root: Path, *, result=0):
    marker = root / "original-p8p-rearm.json"
    def exclusive(path, data):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())

    calls = []
    def private_log(output, label, args, seconds):
        assert (root / "p8r-rearm.json").is_file()
        assert label == "edge-rearm"
        assert args[-2:] == ["edge", "refresh"]
        assert args[0] == sys.executable
        calls.append(tuple(args))
        return result

    obj = SimpleNamespace(
        SRC=p8r.P8P, HOST=p8r.HOST, P8O_COMMIT=P8O_SHA,
        REARM_MARKER=marker, INSTALLED=Path("/opt/vaultwarden-oci/releases/0.1.0-rc.12"),
        boot_id=lambda: "23456789-1234-1234-1234-1234567890ab",
        exclusive_file=exclusive,
        private_log=private_log,
    )
    return obj, calls


class P8RTests(unittest.TestCase):
    def test_exact_source_contract(self):
        self.assertEqual(p8r.HOST, "vaultwarden-oci-7-vnic")
        self.assertEqual(len(p8r.P8P_COMMIT), 40)
        self.assertEqual(len(p8r.P8Q_COMMIT), 40)
        self.assertEqual(p8r.BRANCH, "audit/rc12-p8r-postboot-origin-rearm-batch-newvm")
        self.assertEqual(p8r.P8Q_REPORT.name, "summary.txt")

    def test_invalid_commit_never_calls_git(self):
        with mock.patch.object(p8r.subprocess, "run") as git:
            for bad in ("", "A" * 40, "a" * 39, "x" * 40):
                self.assertFalse(p8r.source_clean(bad, Path("/tmp"), "branch"))
            git.assert_not_called()

    def test_p8q_success_schema_and_original_filter_gap(self):
        statuses = p8r.p8q_statuses(accepted_p8q_summary())
        self.assertEqual(statuses["doctor.edge.cloudflare.iptables"], "PENDING")
        self.assertEqual(statuses["original-p8p.snapshot-parity"], "PASS")

    def test_p8q_rejects_missing_prior_snapshot_parity(self):
        text = accepted_p8q_summary().replace(
            "PASS  original-p8p.snapshot-parity",
            "NOT RUN  original-p8p.snapshot-parity")
        with self.assertRaises(p8r.Blocked):
            p8r.p8q_statuses(text)

    def test_p8q_rejects_prior_blocked_category(self):
        text = accepted_p8q_summary().replace(
            "PASS  sqlite.readonly-integrity-and-historical-sha",
            "BLOCKED  sqlite.readonly-integrity-and-historical-sha")
        with self.assertRaises(p8r.Blocked):
            p8r.p8q_statuses(text)

    def test_p8q_rejects_missing_cloudflare_guard_gap(self):
        text = accepted_p8q_summary().replace(
            "PENDING  doctor.edge.cloudflare.iptables",
            "PASS  doctor.edge.cloudflare.iptables")
        with self.assertRaises(p8r.Blocked):
            p8r.p8q_statuses(text)

    def test_p8q_rejects_malformed_duplicate(self):
        text = accepted_p8q_summary().replace(
            "READONLY  p8q.no-mutation.no-reboot.no-rearm.no-box.no-live-go",
            "PASS  doctor.edge.cloudflare.iptables\nREADONLY  p8q.no-mutation.no-reboot.no-rearm.no-box.no-live-go",
        )
        with self.assertRaises(p8r.Blocked):
            p8r.p8q_statuses(text)

    def test_p8q_rejects_replay_without_readonly_outcome(self):
        text = accepted_p8q_summary().replace(
            "READONLY  p8q.no-mutation.no-reboot.no-rearm.no-box.no-live-go",
            "PASS  p8q.no-mutation.no-reboot.no-rearm.no-box.no-live-go")
        with self.assertRaises(p8r.Blocked):
            p8r.p8q_statuses(text)

    def test_report_private_and_no_success_on_blocked(self):
        with tempfile.TemporaryDirectory() as d:
            out = io.StringIO()
            with redirect_stdout(out):
                rc = p8r.private_summary(Path(d), [
                    ("PASS", "Recovered data verified"), ("PENDING", "Worker remains disabled")
                ], "REARMED")
            self.assertEqual(rc, 0)
            file = Path(d) / "summary.txt"
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)
            self.assertIn("REARMED", file.read_text())
            with self.assertRaises(FileExistsError):
                # Exclusive summary prevents silent replacement in a real gate.
                os.open(file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)

    def test_report_suppresses_potential_secret_bearing_rows(self):
        with tempfile.TemporaryDirectory() as d:
            for label in ("unsafe\rlabel", "a\nsecret", "a" * 211):
                with self.assertRaises(p8r.Blocked):
                    p8r.private_summary(Path(d), [("PASS", label)], "REARMED")

    def test_wrong_flags_block_before_reviewed_helper_import(self):
        choices = [
            [],
            ["--expected-commit", "bad", "--apply-disposable", "--oci-console-ready"],
            ["--expected-commit", PIN, "--apply-disposable"],
            ["--expected-commit", PIN, "--oci-console-ready"],
            ["--expected-commit", PIN, "--apply-disposable", "--oci-console-ready", "--extra"],
        ]
        for args in choices:
            with self.subTest(args=args):
                with mock.patch.object(sys, "argv", [str(SCRIPT), *args]), \
                     mock.patch.object(p8r, "module") as prior:
                    with redirect_stdout(io.StringIO()):
                        self.assertEqual(p8r.main(), 2)
                    prior.assert_not_called()

    def test_doctor_audit_allows_expected_stopped_path_and_origin_gap(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            required = ("host.os", "host.architecture", "storage.dedicated",
                        "secrets.custody", "secrets.decrypt")
            foundation = ("edge.cloudflare.cidrs", "edge.cloudflare.iptables",
                          "crowdsec.engine", "crowdsec.hub", "crowdsec.firewall")
            statuses = dict.fromkeys((*required, *foundation), "PASS")
            statuses.update({"crowdsec.cloudflare": "FAIL", "runtime.paths": "FAIL"})
            statuses.update({"extra." + str(i): "PASS" for i in range(27 - len(statuses))})
            p8p = SimpleNamespace(
                Report=lambda d, label: SimpleNamespace(),
                snapshot=lambda rep, d, after_boot: {"file": "sha"},
                compare_paths=lambda checkpoint, digest: None,
                P5_FILE=Path("/safe"),
                load_helper=lambda path, name: SimpleNamespace(),
                doctor=lambda p5, path, after_boot: (statuses, "PENDING", False),
                MANDATORY=set(required),
            )
            healthy, paths = p8r.postboot_audit(p8p, folder, {}, "test-phase")
            self.assertFalse(healthy)
            self.assertEqual(paths, "PENDING")

    def test_doctor_audit_rejects_unexpected_crowdsec_regression(self):
        with tempfile.TemporaryDirectory() as d:
            foundation = ("edge.cloudflare.cidrs", "edge.cloudflare.iptables",
                          "crowdsec.engine", "crowdsec.hub", "crowdsec.firewall")
            statuses = dict.fromkeys(foundation, "PASS")
            statuses.update({"host.os": "PASS", "crowdsec.cloudflare": "FAIL",
                             "runtime.paths": "FAIL", "crowdsec.engine": "FAIL"})
            statuses.update({"extra." + str(i): "PASS" for i in range(27 - len(statuses))})
            p8p = SimpleNamespace(
                Report=lambda d, label: SimpleNamespace(),
                snapshot=lambda rep, d, after_boot: {"file": "sha"},
                compare_paths=lambda c, hashes: None,
                P5_FILE=Path("/safe"), load_helper=lambda path, name: SimpleNamespace(),
                doctor=lambda p5, path, after_boot: (statuses, "PENDING", False),
                MANDATORY={"host.os"},
            )
            with self.assertRaises(p8r.Blocked):
                p8r.postboot_audit(p8p, Path(d), {}, "one")

    def test_no_action_if_filter_already_passes(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            p8p, calls = fake_p8p(root)
            p8q = SimpleNamespace(SRC=p8r.P8Q, HOST=p8r.HOST, PRIOR_SHA=p8r.P8P_COMMIT)
            out = TTY()
            with ExitStack() as stack:
                stack.enter_context(mock.patch.object(p8r, "ATTEMPT", root / "p8r-rearm.json"))
                stack.enter_context(mock.patch.object(p8r, "host_ok", return_value=True))
                stack.enter_context(mock.patch.object(p8r, "source_clean", return_value=True))
                stack.enter_context(mock.patch.object(p8r, "module", side_effect=[p8p, p8q]))
                stack.enter_context(mock.patch.object(p8r, "historical_evidence", return_value={"original_boot_id": "old"}))
                stack.enter_context(mock.patch.object(p8r, "new_private_folder", return_value=root))
                audit = stack.enter_context(mock.patch.object(
                    p8r, "postboot_audit", return_value=(True, "PENDING")))
                stack.enter_context(mock.patch.object(sys, "stdin", TTY()))
                stack.enter_context(mock.patch.object(sys, "stdout", out))
                stack.enter_context(mock.patch.object(sys, "argv", [
                    str(SCRIPT), "--expected-commit", PIN, "--apply-disposable", "--oci-console-ready"
                ]))
                self.assertEqual(p8r.main(), 0)
            self.assertFalse((root / "p8r-rearm.json").exists())
            self.assertEqual(audit.call_count, 1)
            self.assertFalse(calls)
            self.assertIn("HOLD", out.getvalue())

    def test_one_shot_rearm_checks_marker_and_runs_three_audits(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            p8p, calls = fake_p8p(root)
            p8q = SimpleNamespace(SRC=p8r.P8Q, HOST=p8r.HOST, PRIOR_SHA=p8r.P8P_COMMIT)
            out = TTY()
            with ExitStack() as stack:
                stack.enter_context(mock.patch.object(p8r, "ATTEMPT", root / "p8r-rearm.json"))
                stack.enter_context(mock.patch.object(p8r, "host_ok", return_value=True))
                stack.enter_context(mock.patch.object(p8r, "source_clean", return_value=True))
                stack.enter_context(mock.patch.object(p8r, "module", side_effect=[p8p, p8q]))
                stack.enter_context(mock.patch.object(p8r, "historical_evidence", return_value={"original_boot_id": "old"}))
                stack.enter_context(mock.patch.object(p8r, "new_private_folder", return_value=root))
                audit = stack.enter_context(mock.patch.object(
                    p8r, "postboot_audit", side_effect=[
                        (False, "PENDING"), (False, "PENDING"), (True, "PENDING")
                    ]))
                stack.enter_context(mock.patch.object(sys, "stdin", TTY()))
                stack.enter_context(mock.patch.object(sys, "stdout", out))
                stack.enter_context(mock.patch.object(sys, "argv", [
                    str(SCRIPT), "--expected-commit", PIN, "--apply-disposable", "--oci-console-ready"
                ]))
                self.assertEqual(p8r.main(), 0)
            self.assertEqual(audit.call_count, 3)
            self.assertEqual(len(calls), 1)
            self.assertTrue((root / "p8r-rearm.json").is_file())
            self.assertEqual((root / "p8r-rearm.json").stat().st_mode & 0o777, 0o600)
            self.assertIn("REARMED", out.getvalue())
            self.assertIn("one Cloudflare-only", (root / "summary.txt").read_text())

    def test_failure_after_mutation_preserves_attempt_and_blocks(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            p8p, calls = fake_p8p(root, result=None)
            p8q = SimpleNamespace(SRC=p8r.P8Q, HOST=p8r.HOST, PRIOR_SHA=p8r.P8P_COMMIT)
            out = TTY()
            with ExitStack() as stack:
                stack.enter_context(mock.patch.object(p8r, "ATTEMPT", root / "p8r-rearm.json"))
                stack.enter_context(mock.patch.object(p8r, "host_ok", return_value=True))
                stack.enter_context(mock.patch.object(p8r, "source_clean", return_value=True))
                stack.enter_context(mock.patch.object(p8r, "module", side_effect=[p8p, p8q]))
                stack.enter_context(mock.patch.object(p8r, "historical_evidence", return_value={"original_boot_id": "old"}))
                stack.enter_context(mock.patch.object(p8r, "new_private_folder", return_value=root))
                audit = stack.enter_context(mock.patch.object(
                    p8r, "postboot_audit", side_effect=[(False, "PENDING"), (False, "PENDING")]))
                stack.enter_context(mock.patch.object(sys, "stdin", TTY()))
                stack.enter_context(mock.patch.object(sys, "stdout", out))
                stack.enter_context(mock.patch.object(sys, "argv", [
                    str(SCRIPT), "--expected-commit", PIN, "--apply-disposable", "--oci-console-ready"
                ]))
                self.assertEqual(p8r.main(), 2)
            self.assertEqual(audit.call_count, 2)
            self.assertEqual(len(calls), 1)
            self.assertTrue((root / "p8r-rearm.json").exists())
            self.assertIn("BLOCKED", out.getvalue())

    def test_no_cloud_dns_box_worker_mutation_primitives(self):
        src = SCRIPT.read_text()
        forbidden = (
            '"dns", "update"', '"remediation-start"', '"backup"',
            '"crowdsec", "setup"', '"start"', '"reboot"',
            "rclone copy", "rclone sync", "rclone delete",
            "restore_recovery(", "checkpoint_finish(", "vwctl stop",
        )
        for phrase in forbidden:
            with self.subTest(phrase=phrase):
                self.assertNotIn(phrase, src)


if __name__ == "__main__":
    unittest.main()
