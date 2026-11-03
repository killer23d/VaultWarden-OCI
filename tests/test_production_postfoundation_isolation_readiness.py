"""P6 post-foundation security and isolation test coverage (no live host writes)."""
from __future__ import annotations

import ast
import importlib.util
from pathlib import Path
import unittest
from types import SimpleNamespace
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance" / "production-postfoundation-isolation-readiness.py"
spec = importlib.util.spec_from_file_location("rc12_p6_postfoundation", SCRIPT)
assert spec and spec.loader
p6 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p6)


class PostfoundationIsolationTests(unittest.TestCase):
    def fixture(self):
        return dict.fromkeys(("runtime.paths", "crowdsec.cloudflare", *p6.FOUNDATION_IDS,
                              "storage.dedicated", "secrets.decrypt"), "PASS")

    def test_expected_prestart_diagnostic_does_not_false_pass_runtime(self):
        checks = self.fixture()
        checks["runtime.paths"] = "FAIL"
        checks["crowdsec.cloudflare"] = "FAIL"
        self.assertEqual(p6.evaluate_stopped_doctor(checks, "PENDING"),
                         (True, "only_expected_prestart_failures"))

    def test_stopped_runtime_satisfied_without_worker_start(self):
        checks = self.fixture()
        checks["crowdsec.cloudflare"] = "FAIL"
        self.assertEqual(p6.evaluate_stopped_doctor(checks, "PASS")[0], True)

    def test_foundation_regression_never_accepted(self):
        for key in (*p6.FOUNDATION_IDS, "storage.dedicated"):
            with self.subTest(key=key):
                checks = self.fixture()
                checks["crowdsec.cloudflare"] = "FAIL"
                checks[key] = "FAIL"
                self.assertFalse(p6.evaluate_stopped_doctor(checks, "PASS")[0])

    def test_unknown_doctor_failure_is_blocking(self):
        checks = self.fixture()
        checks["crowdsec.cloudflare"] = "FAIL"
        checks["secrets.decrypt"] = "FAIL"
        ok, reason = p6.evaluate_stopped_doctor(checks, "PASS")
        self.assertFalse(ok)
        self.assertIn("secrets.decrypt", reason)

    def test_runtime_path_mismatch_blocked(self):
        checks = self.fixture()
        checks["crowdsec.cloudflare"] = "FAIL"
        self.assertFalse(p6.evaluate_stopped_doctor(checks, "PENDING")[0])
        checks["runtime.paths"] = "FAIL"
        self.assertFalse(p6.evaluate_stopped_doctor(checks, "PASS")[0])
        self.assertFalse(p6.evaluate_stopped_doctor(checks, "BLOCKED")[0])

    def test_worker_must_be_stopped_and_boot_disabled(self):
        def props(key):
            if key == p6.WORKER_UNIT:
                return {"LoadState": "loaded", "ActiveState": "inactive", "UnitFileState": "disabled"}
            return {"LoadState": "loaded", "ActiveState": "active", "UnitFileState": "enabled"}
        p1 = SimpleNamespace(service_properties=props)
        self.assertTrue(p6.expected_security_units(p1))
        with mock.patch.object(p1, "service_properties", side_effect=lambda k: {
            "LoadState": "loaded", "ActiveState": "active",
            "UnitFileState": "disabled" if k == p6.WORKER_UNIT else "enabled"
        }):
            self.assertFalse(p6.expected_security_units(p1))
        with mock.patch.object(p1, "service_properties", side_effect=lambda k: {
            "LoadState": "loaded", "ActiveState": "inactive" if k == p6.WORKER_UNIT else "active",
            "UnitFileState": "enabled"
        }):
            self.assertFalse(p6.expected_security_units(p1))

    def test_evidence_summary_rejects_untrusted_newlines(self):
        class FakeEvidence:
            def __truediv__(self, suffix):
                return self
        report = p6.Report(FakeEvidence())
        with self.assertRaises(ValueError):
            report.add("PASS", "PRIVATE\nTOKEN")
        with self.assertRaises(ValueError):
            report.add("GO", "unsupported status")

    def test_main_rejects_arguments_and_does_not_write(self):
        with mock.patch.object(p6.sys, "argv", [str(SCRIPT), "--start"]), \
             mock.patch.object(p6.os, "geteuid", return_value=0), \
             mock.patch.dict(p6.os.environ, {"SUDO_USER": "ubuntu"}), \
             mock.patch.object(p6, "private_evidence", side_effect=AssertionError("must not write")):
            self.assertEqual(p6.main(), 2)

    def test_no_mutation_or_consent_functions_in_p6_ast(self):
        tree = ast.parse(SCRIPT.read_text(encoding="utf-8"))
        names = {n.attr for n in ast.walk(tree) if isinstance(n, ast.Attribute)}
        for forbidden in ("run_private", "run_command", "start_remediation",
                          "refresh_origin_policy", "lifecycle", "materialize",
                          "mkdirs", "restore_recovery"):
            self.assertNotIn(forbidden, names)
        calls = {n.func.id for n in ast.walk(tree)
                 if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
        self.assertNotIn("input", calls)
        self.assertNotIn("exec", calls)
        self.assertNotIn("eval", calls)


if __name__ == "__main__":
    unittest.main()
