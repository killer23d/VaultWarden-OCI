"""P7 disposable rc.12 reboot gate: permission, no-mutation and postboot tests."""
from __future__ import annotations

import ast
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance" / "production-reboot-persistence-consent.py"
spec = importlib.util.spec_from_file_location("rc12_p7_reboot_persistence", SCRIPT)
assert spec and spec.loader
p7 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p7)

BOOT_OLD = "c0000000-1111-4222-8333-444444444444"
BOOT_NEW = "d0000000-1111-4222-8333-444444444444"


class InteractiveOutput(io.StringIO):
    def isatty(self):
        return True


class RebootPersistenceTests(unittest.TestCase):
    def checkpoint(self, phase="prepared"):
        return {
            "schema": 1,
            "host": p7.HOST,
            "release": p7.RELEASE,
            "phase": phase,
            "boot_id": BOOT_OLD,
            "evidence_dir": "p7-reboot-persistence-20261103T230000Z-1234",
            "sha256": {},
        }

    def test_exact_consent_only(self):
        self.assertTrue(p7.check_consent(p7.CONSENT))
        for candidate in ("", "yes", "P7 REBOOT", p7.CONSENT.lower(),
                          p7.CONSENT + "\n", p7.CONSENT + " now", " " + p7.CONSENT):
            self.assertFalse(p7.check_consent(candidate))

    def test_kernel_boot_id_requires_strict_uuid(self):
        with tempfile.TemporaryDirectory() as d:
            file = Path(d) / "boot"
            file.write_text(BOOT_OLD + "\n")
            with mock.patch.object(p7, "BOOT_ID", file):
                self.assertEqual(p7.read_boot_id(), BOOT_OLD)
                file.write_text("not-a-real-boot-id\n")
                with self.assertRaises(p7.Blocked):
                    p7.read_boot_id()

    def test_checkpoint_creation_and_atomic_update_are_exclusive(self):
        with tempfile.TemporaryDirectory() as d:
            file = Path(d) / "p7-reboot-checkpoint.json"
            original = self.checkpoint()
            p7.write_checkpoint(file, original, create=True)
            with self.assertRaises(FileExistsError):
                p7.write_checkpoint(file, original, create=True)
            # The CI runner isn't root; only the fstat ownership field is mocked.
            actual = p7.os.fstat
            def root_fstat(fd):
                real = actual(fd)
                return SimpleNamespace(st_mode=real.st_mode, st_uid=0, st_size=real.st_size)
            with mock.patch.object(p7.os, "fstat", side_effect=root_fstat):
                self.assertEqual(p7.read_checkpoint(file), original)
                newer = dict(original, phase="reboot-requested")
                p7.write_checkpoint(file, newer, create=False)
                self.assertEqual(p7.read_checkpoint(file)["phase"], "reboot-requested")
            self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)

    def test_checkpoint_symlink_and_unknown_contract_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            original = Path(d) / "actual.json"
            original.write_text("{}")
            symbolic = Path(d) / "p7-reboot-checkpoint.json"
            symbolic.symlink_to(original)
            with self.assertRaises(OSError):
                p7.read_checkpoint(symbolic)
            data = self.checkpoint()
            data["phase"] = "unauthorized-new-phase"
            file = Path(d) / "real.json"
            p7.write_checkpoint(file, data, create=True)
            real_fstat = p7.os.fstat
            with mock.patch.object(p7.os, "fstat", side_effect=lambda fd: SimpleNamespace(
                st_mode=real_fstat(fd).st_mode, st_uid=0, st_size=real_fstat(fd).st_size,
            )):
                with self.assertRaises(p7.Blocked):
                    p7.read_checkpoint(file)

    def test_protected_state_hashes_cannot_be_ignored(self):
        a, b = Path("/protected/A"), Path("/protected/B")
        current = {str(a): "a", str(b): "b"}
        cp = self.checkpoint()
        cp["sha256"] = current.copy()
        p7.verified_hashes(cp, (a, b), current)
        with self.assertRaises(p7.Blocked):
            p7.verified_hashes(cp, (a, b), {str(a): "a", str(b): "changed"})
        with self.assertRaises(p7.Blocked):
            p7.verified_hashes(cp, (a,), {str(a): "a"})

    def test_postboot_origin_filter_missing_is_pending_not_automatically_repaired(self):
        p5_module = p7.helper(p7.P5_FILE, "p7_test_p5_ids")
        checks = dict.fromkeys(p5_module.product_doctor_ids(), "PASS")
        checks["crowdsec.cloudflare"] = "FAIL"
        checks["runtime.paths"] = "FAIL"
        checks["edge.cloudflare.iptables"] = "FAIL"
        p5 = SimpleNamespace(
            diagnose_doctor=lambda *a, **k: ("valid", checks, "not_needed"),
            inspect_stopped_runtime_paths=lambda *a, **k: ("PENDING", "missing_count=9 unsafe_count=0"),
        )
        p6 = p7.helper(p7.P6_FILE, "test_p6_again")
        with tempfile.TemporaryDirectory() as d:
            gate = p7.Report(Path(d), "verify")
            p7.validate_doctor(p5, p6, object(), object(), Path(d), gate, after_boot=True)
            self.assertTrue(any(level == "PENDING" and "not persistent" in msg for level, msg in gate.rows))
            self.assertFalse(any(level == "PASS" and "All five" in msg for level, msg in gate.rows))
            with self.assertRaises(p7.Blocked):
                p7.validate_doctor(p5, p6, object(), object(), Path(d), gate, after_boot=False)

    def test_unexpected_postboot_doctor_failure_is_blocked(self):
        p6 = p7.helper(p7.P6_FILE, "test_p6_third")
        p5_module = p7.helper(p7.P5_FILE, "p7_test_p5_second_ids")
        checks = dict.fromkeys(p5_module.product_doctor_ids(), "PASS")
        checks["crowdsec.cloudflare"] = "FAIL"
        checks["runtime.paths"] = "FAIL"
        checks["edge.cloudflare.iptables"] = "FAIL"
        checks["secrets.decrypt"] = "FAIL"
        p5 = SimpleNamespace(
            diagnose_doctor=lambda *a, **k: ("valid", checks, "not_needed"),
            inspect_stopped_runtime_paths=lambda *a, **k: ("PENDING", "missing_count=9 unsafe_count=0"),
        )
        with tempfile.TemporaryDirectory() as d:
            gate = p7.Report(Path(d), "verify")
            with self.assertRaises(p7.Blocked):
                p7.validate_doctor(p5, p6, object(), object(), Path(d), gate, after_boot=True)

    def test_prepare_mode_never_calls_reboot_or_consent(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            out = base / "private"
            out.mkdir()
            with mock.patch.object(p7.sys, "argv", [str(SCRIPT), "prepare"]), \
                 mock.patch.object(p7.os, "geteuid", return_value=0), \
                 mock.patch.dict(p7.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(p7, "safe_base", return_value=base), \
                 mock.patch.object(p7, "evidence_dir", return_value=out), \
                 mock.patch.object(p7, "read_boot_id", return_value=BOOT_OLD), \
                 mock.patch.object(p7, "host_snapshot", return_value=((), {})), \
                 mock.patch.object(p7, "write_checkpoint") as write, \
                 mock.patch.object(p7, "run_reboot", side_effect=AssertionError("must not reboot")), \
                 mock.patch("builtins.input", side_effect=AssertionError("must not ask consent")), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(p7.main(), 0)
                self.assertEqual(write.call_count, 1)
                self.assertTrue(write.call_args.kwargs["create"])
                self.assertEqual(write.call_args.args[1]["phase"], "prepared")
            self.assertIn("PREPARED", (out / "prepare.summary.txt").read_text())

    def test_reboot_mode_cancellation_preserves_prepared_state(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            out = base / "private"
            out.mkdir()
            with mock.patch.object(p7.sys, "argv", [str(SCRIPT), "reboot"]), \
                 mock.patch.object(p7.sys, "stdin", SimpleNamespace(isatty=lambda: True)), \
                 mock.patch.object(p7.sys, "stdout", InteractiveOutput()), \
                 mock.patch.object(p7.os, "geteuid", return_value=0), \
                 mock.patch.dict(p7.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(p7, "safe_base", return_value=base), \
                 mock.patch.object(p7, "read_checkpoint", return_value=self.checkpoint()), \
                 mock.patch.object(p7, "evidence_dir", return_value=out), \
                 mock.patch.object(p7, "read_boot_id", return_value=BOOT_OLD), \
                 mock.patch.object(p7, "host_snapshot", return_value=((), {})), \
                 mock.patch.object(p7, "run_reboot", side_effect=AssertionError("must not reboot")), \
                 mock.patch.object(p7, "write_checkpoint") as write, \
                 mock.patch("builtins.input", return_value="CANCEL"):
                self.assertEqual(p7.main(), 0)
                write.assert_not_called()
            self.assertIn("CANCELLED", (out / "reboot.summary.txt").read_text())

    def test_reboot_requires_authorization_before_mutating_command(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            out = base / "private"
            out.mkdir()
            checkpoint = self.checkpoint()
            observed = []
            def write(*args, **kwargs):
                observed.append(("checkpoint", args[1]["phase"]))
            def reboot():
                observed.append(("reboot", "called"))
                return True
            with mock.patch.object(p7.sys, "argv", [str(SCRIPT), "reboot"]), \
                 mock.patch.object(p7.sys, "stdin", SimpleNamespace(isatty=lambda: True)), \
                 mock.patch.object(p7.sys, "stdout", InteractiveOutput()), \
                 mock.patch.object(p7.os, "geteuid", return_value=0), \
                 mock.patch.dict(p7.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(p7, "safe_base", return_value=base), \
                 mock.patch.object(p7, "read_checkpoint", return_value=checkpoint), \
                 mock.patch.object(p7, "evidence_dir", return_value=out), \
                 mock.patch.object(p7, "read_boot_id", return_value=BOOT_OLD), \
                 mock.patch.object(p7, "host_snapshot", return_value=((), {})), \
                 mock.patch.object(p7, "write_checkpoint", side_effect=write), \
                 mock.patch.object(p7, "run_reboot", side_effect=reboot), \
                 mock.patch("builtins.input", return_value=p7.CONSENT):
                self.assertEqual(p7.main(), 0)
            self.assertEqual(observed, [("checkpoint", "reboot-requested"), ("reboot", "called")])

    def test_verify_same_boot_is_denied_without_host_mutation(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            out = base / "private"
            out.mkdir()
            with mock.patch.object(p7.sys, "argv", [str(SCRIPT), "verify"]), \
                 mock.patch.object(p7.os, "geteuid", return_value=0), \
                 mock.patch.dict(p7.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(p7, "safe_base", return_value=base), \
                 mock.patch.object(p7, "read_checkpoint", return_value=self.checkpoint("reboot-requested")), \
                 mock.patch.object(p7, "evidence_dir", return_value=out), \
                 mock.patch.object(p7, "read_boot_id", return_value=BOOT_OLD), \
                 mock.patch.object(p7, "host_snapshot", side_effect=AssertionError("must not inspect same-boot")), \
                 mock.patch.object(p7, "run_reboot", side_effect=AssertionError("must not reboot")), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(p7.main(), 2)
            self.assertIn("BLOCKED", (out / "verify.summary.txt").read_text())

    def test_verify_new_boot_records_immutable_authority_and_never_reboots(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            out = base / "private"
            out.mkdir()
            cp = self.checkpoint("reboot-requested")
            with mock.patch.object(p7.sys, "argv", [str(SCRIPT), "verify"]), \
                 mock.patch.object(p7.os, "geteuid", return_value=0), \
                 mock.patch.dict(p7.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(p7, "safe_base", return_value=base), \
                 mock.patch.object(p7, "read_checkpoint", return_value=cp), \
                 mock.patch.object(p7, "evidence_dir", return_value=out), \
                 mock.patch.object(p7, "read_boot_id", return_value=BOOT_NEW), \
                 mock.patch.object(p7, "host_snapshot", return_value=((), {})), \
                 mock.patch.object(p7, "write_checkpoint") as write, \
                 mock.patch.object(p7, "run_reboot", side_effect=AssertionError("never again")), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(p7.main(), 0)
                self.assertEqual(write.call_args.args[1]["phase"], "verified")
            self.assertIn("VERIFIED", (out / "verify.summary.txt").read_text())

    def test_invalid_arguments_are_a_no_write_diagnostic(self):
        stderr = io.StringIO()
        with mock.patch.object(p7.sys, "argv", [str(SCRIPT), "--unsafe"]), \
             mock.patch.object(p7, "safe_base", side_effect=AssertionError("must not inspect host")), \
             contextlib.redirect_stderr(stderr):
            self.assertEqual(p7.main(), 2)
        self.assertIn("BLOCKED: usage", stderr.getvalue())

    def test_reboot_not_possible_from_prepare_or_verify_in_source(self):
        tree = ast.parse(SCRIPT.read_text(encoding="utf-8"))
        calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call)]
        sites = [(n.func.attr if isinstance(n.func, ast.Attribute) else n.func.id)
                 for n in calls if isinstance(n.func, (ast.Attribute, ast.Name))]
        self.assertEqual(sites.count("run_reboot"), 1)
        self.assertEqual(sites.count("input"), 1)
        self.assertEqual(sites.count("write_checkpoint"), 3)
        self.assertEqual(sites.count("refresh_origin_policy"), 0)
        self.assertEqual(sites.count("start_remediation"), 0)
        self.assertEqual(sites.count("restore_recovery"), 0)
        self.assertEqual(sites.count("lifecycle"), 0)


if __name__ == "__main__":
    unittest.main()
