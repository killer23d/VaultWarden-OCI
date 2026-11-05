"""Negative contracts for P8O batched new-host local security acceptance."""
from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from types import SimpleNamespace
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8o-batched-local-security.py"
SPEC = importlib.util.spec_from_file_location("p8o_local_foundation", SCRIPT)
assert SPEC and SPEC.loader
p8o = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p8o)


class P8OLocalFoundationTests(unittest.TestCase):
    def test_source_pins_not_operator_overridable(self):
        self.assertEqual(p8o.HOST, "vaultwarden-oci-7-vnic")
        self.assertEqual(len(p8o.DB_SHA), 64)
        self.assertEqual(len(p8o.CIPHER_SHA), 64)
        self.assertEqual(len(p8o.P8M_COMMIT), 40)
        self.assertEqual(len(p8o.RECIPIENT_SHA), 64)
        self.assertEqual(p8o.VOLUME_FP, "2449f67320a1")
        self.assertEqual(p8o.REMOTE, "bw-backup:bw-backup")

    def test_five_foundation_ids_never_include_worker(self):
        self.assertEqual(len(p8o.FOUNDATION), 5)
        self.assertEqual(len(set(p8o.FOUNDATION)), 5)
        self.assertNotIn("crowdsec.cloudflare", p8o.FOUNDATION)
        self.assertIn("crowdsec.cloudflare", p8o.UNCONFIGURED)
        self.assertIn("runtime.paths", p8o.UNCONFIGURED)

    def test_wrong_commit_sha_blocks_before_git(self):
        self.assertFalse(p8o.source_clean("notasha"))
        self.assertFalse(p8o.source_clean("a" * 39))
        self.assertFalse(p8o.source_clean("a" * 41))

    def test_invalid_cli_fails_without_touching_evidence(self):
        for argv in ([], ["--expected-commit", "not-a-sha"],
                     ["--expected-commit", "a" * 40, "--apply-disposable"],
                     ["--expected-commit", "a" * 40, "--oci-console-ready"]):
            with self.subTest(argv=argv), mock.patch.object(sys, "argv", [str(SCRIPT), *argv]):
                with mock.patch.object(p8o, "historical_recovery") as evidence:
                    out = io.StringIO()
                    with redirect_stdout(out):
                        self.assertEqual(p8o.main(), 2)
                    evidence.assert_not_called()
                    self.assertIn("BLOCKED", out.getvalue())

    def test_attempt_marker_blocks_replay_prior_to_operations(self):
        with tempfile.TemporaryDirectory() as folder:
            attempt = Path(folder) / "existing.json"
            attempt.write_text("{}", encoding="utf-8")
            with mock.patch.object(p8o, "ATTEMPT", attempt), \
                 mock.patch.object(p8o, "authorized_host", return_value=True), \
                 mock.patch.object(p8o, "source_clean", return_value=True), \
                 mock.patch.object(p8o, "historical_recovery") as evidence, \
                 mock.patch.object(sys, "argv", [str(SCRIPT), "--expected-commit", "a" * 40]):
                out = io.StringIO()
                with redirect_stdout(out):
                    self.assertEqual(p8o.main(), 2)
                evidence.assert_called_once()
                self.assertIn("exclusive P8O attempt marker", out.getvalue())

    def test_private_marker_created_exclusively(self):
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / "attempt.json"
            p8o.write_exclusive(file, b'{"schema":1}\n')
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)
            self.assertEqual(file.read_bytes(), b'{"schema":1}\n')
            with self.assertRaises(FileExistsError):
                p8o.write_exclusive(file, b'{"schema":2}\n')
            self.assertEqual(file.read_bytes(), b'{"schema":1}\n')

    def test_report_holds_before_mutation(self):
        with tempfile.TemporaryDirectory() as folder:
            report = p8o.Report(Path(folder), apply=False)
            report.record("PASS", "preflight")
            with redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 0)
            self.assertIn("HOLD", (Path(folder) / "summary.txt").read_text())

    def test_report_blocks_after_partial_security_change(self):
        with tempfile.TemporaryDirectory() as folder:
            report = p8o.Report(Path(folder), apply=True)
            report.mutation_started = True
            with redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 2)
            text = (Path(folder) / "summary.txt").read_text()
            self.assertIn("BLOCKED", text)
            self.assertIn("do not rerun", text)

    def test_report_foundation_only_after_verified(self):
        with tempfile.TemporaryDirectory() as folder:
            report = p8o.Report(Path(folder), apply=True)
            report.mutation_started = True
            report.verified = True
            report.record("PASS", "post-state")
            with redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 0)
            self.assertIn("FOUNDATION", (Path(folder) / "summary.txt").read_text())

    def test_summary_cannot_echo_newline_or_unknown_status(self):
        with tempfile.TemporaryDirectory() as folder:
            report = p8o.Report(Path(folder), apply=False)
            for status, text in (("SECRET", "s"), ("PASS", "line\ncredential"),
                                 ("PASS", "x" * 241)):
                with self.assertRaises(ValueError):
                    report.record(status, text)

    def test_uninstalled_security_partial_fails_closed(self):
        inactive = {"LoadState": "not-found", "ActiveState": "inactive", "UnitFileState": ""}
        with mock.patch.object(p8o, "unit_state", return_value=inactive), \
             mock.patch.object(p8o.Path, "exists", return_value=False):
            p8o.security_state(installed=False)
        loaded = {"LoadState": "loaded", "ActiveState": "inactive", "UnitFileState": "disabled"}
        with mock.patch.object(p8o, "unit_state", return_value=loaded), \
             mock.patch.object(p8o.Path, "exists", return_value=False):
            with self.assertRaises(p8o.Blocked):
                p8o.security_state(installed=False)

    def test_installed_worker_must_be_disabled(self):
        worker = {"LoadState": "loaded", "ActiveState": "active", "UnitFileState": "enabled"}
        with mock.patch.object(p8o, "unit_state", return_value=worker), \
             mock.patch.object(p8o.Path, "is_file", return_value=True):
            with self.assertRaises(p8o.Blocked):
                p8o.security_state(installed=True)

    def test_audit_rejects_additional_failed_doctor_check(self):
        extra = {"host.os": "PASS", "host.architecture": "PASS",
                 "storage.dedicated": "PASS", "secrets.custody": "PASS",
                 "secrets.decrypt": "PASS", "crowdsec.engine": "FAIL",
                 "edge.cloudflare.cidrs": "FAIL", "edge.cloudflare.iptables": "FAIL",
                 "crowdsec.hub": "FAIL", "crowdsec.firewall": "FAIL",
                 "crowdsec.cloudflare": "FAIL", "runtime.paths": "FAIL",
                 "recovery.local": "FAIL"}
        helper = SimpleNamespace(
            diagnose_doctor=lambda *args, **kwargs: ("valid", extra, "not_needed"),
            product_doctor_ids=lambda: tuple(extra),
        )
        with self.assertRaises(p8o.Blocked):
            p8o.check_doctor(helper, Path("/tmp"), "fixture", after=False)

    def test_doctor_cannot_claim_worker_success(self):
        keys = p8o.MANDATORY | p8o.UNCONFIGURED
        sample = {k: ("PASS" if k in p8o.MANDATORY else "FAIL") for k in keys}
        sample["crowdsec.cloudflare"] = "PASS"
        helper = SimpleNamespace(
            diagnose_doctor=lambda *args, **kwargs: ("valid", sample, "not_needed"),
            product_doctor_ids=lambda: tuple(sample),
        )
        with self.assertRaises(p8o.Blocked):
            p8o.check_doctor(helper, Path("/tmp"), "fixture", after=False)

    def test_logged_shell_tool_does_not_emit_raw_output(self):
        with tempfile.TemporaryDirectory() as folder:
            with mock.patch.object(p8o.subprocess, "run", return_value=SimpleNamespace(
                returncode=0
            )):
                self.assertEqual(p8o.private_log(Path(folder), "edge",
                                                 ["/bin/true"], 10), 0)
            path = Path(folder) / "edge.private.log"
            self.assertTrue(path.exists())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_no_cloud_or_backup_mutation_commands_embedded(self):
        content = SCRIPT.read_text()
        for forbidden in ('"dns", "update"', '"remediation-start"', '"notification", "test"',
                          '"backup"', '"recovery", "prune"', '"start"', '"stop"',
                          'restore_recovery(', 'ensure_paths(', "rclone copy", "rclone delete"):
            self.assertNotIn(forbidden, content)


    def test_full_batched_success_invokes_only_two_installed_product_commands(self):
        """Mock the integrated one-shot path and assert marker precedes writes."""
        from contextlib import ExitStack

        class TTY(io.StringIO):
            def isatty(self):
                return True

        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            attempts = root / "p8o-attempt.json"
            actions = []

            def fake_log(out, name, command, seconds):
                self.assertTrue(attempts.is_file(), "one-shot marker must predate mutation")
                self.assertEqual(attempts.stat().st_mode & 0o777, 0o600)
                actions.append((name, command[-2:]))
                return 0

            stdout = TTY()
            with ExitStack() as stack:
                for target, value in (
                    ("EVIDENCE", root),
                    ("ATTEMPT", attempts),
                ):
                    stack.enter_context(mock.patch.object(p8o, target, value))
                stack.enter_context(mock.patch.object(p8o, "authorized_host", return_value=True))
                stack.enter_context(mock.patch.object(p8o, "source_clean", return_value=True))
                stack.enter_context(mock.patch.object(p8o, "historical_recovery"))
                stack.enter_context(mock.patch.object(p8o, "imported_module", return_value=SimpleNamespace()))
                stack.enter_context(mock.patch.object(p8o, "protected_state", return_value=b"same"))
                security = stack.enter_context(mock.patch.object(p8o, "security_state"))
                stack.enter_context(mock.patch.object(p8o, "host_operational", return_value=(False, True)))
                doctor = stack.enter_context(mock.patch.object(p8o, "check_doctor", return_value=({}, "PENDING")))
                stack.enter_context(mock.patch.object(p8o, "private_log", side_effect=fake_log))
                stack.enter_context(mock.patch.object(sys, "argv", [
                    str(SCRIPT), "--expected-commit", "a" * 40,
                    "--apply-disposable", "--oci-console-ready",
                ]))
                stack.enter_context(mock.patch.object(sys, "stdin", TTY()))
                stack.enter_context(mock.patch.object(sys, "stdout", stdout))
                self.assertEqual(p8o.main(), 0)

            self.assertEqual([label for label, _ in actions], ["edge-refresh", "crowdsec-setup"])
            self.assertEqual([command for _, command in actions], [
                ["edge", "refresh"], ["crowdsec", "setup"]
            ])
            self.assertEqual(doctor.call_count, 2)
            self.assertEqual(security.call_count, 3)
            self.assertEqual([c.kwargs.get("installed") for c in security.call_args_list],
                             [False, False, True])
            self.assertIn("FOUNDATION", stdout.getvalue())
            self.assertIn("FOUNDATION", next(root.glob("p8o-security-batch-*/summary.txt")).read_text())

    def test_edge_setup_failure_blocks_and_does_not_run_crowdsec(self):
        from contextlib import ExitStack

        class TTY(io.StringIO):
            def isatty(self):
                return True

        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            marker = root / "p8o-attempt.json"
            out = TTY()
            with ExitStack() as stack:
                stack.enter_context(mock.patch.object(p8o, "EVIDENCE", root))
                stack.enter_context(mock.patch.object(p8o, "ATTEMPT", marker))
                stack.enter_context(mock.patch.object(p8o, "authorized_host", return_value=True))
                stack.enter_context(mock.patch.object(p8o, "source_clean", return_value=True))
                stack.enter_context(mock.patch.object(p8o, "historical_recovery"))
                stack.enter_context(mock.patch.object(p8o, "imported_module", return_value=SimpleNamespace()))
                stack.enter_context(mock.patch.object(p8o, "protected_state", return_value=b"same"))
                stack.enter_context(mock.patch.object(p8o, "security_state"))
                stack.enter_context(mock.patch.object(p8o, "host_operational", return_value=(False, True)))
                stack.enter_context(mock.patch.object(p8o, "check_doctor", return_value=({}, "PENDING")))
                logs = stack.enter_context(mock.patch.object(p8o, "private_log", return_value=None))
                stack.enter_context(mock.patch.object(sys, "argv", [
                    str(SCRIPT), "--expected-commit", "b" * 40,
                    "--apply-disposable", "--oci-console-ready",
                ]))
                stack.enter_context(mock.patch.object(sys, "stdin", TTY()))
                stack.enter_context(mock.patch.object(sys, "stdout", out))
                self.assertEqual(p8o.main(), 2)
            self.assertTrue(marker.is_file())
            self.assertEqual(logs.call_count, 1)
            self.assertIn("BLOCKED", out.getvalue())


if __name__ == "__main__":
    unittest.main()
