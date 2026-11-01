"""P0 read-model tests: no host, provider, or mutation involved."""
import importlib.util
from pathlib import Path
import unittest

source = Path(__file__).parent / "host-acceptance" / "production-readiness-inventory.py"
spec = importlib.util.spec_from_file_location("production_p0", source)
assert spec and spec.loader
p0 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p0)


class P0Tests(unittest.TestCase):
    def test_doctor_no_message_leak(self):
        overall, errors, warnings = p0.doctor_summary({
            "schema_version": 1, "overall": "FAIL", "checks": [
                {"id": "storage.dedicated", "status": "FAIL", "message": "SECRET"},
                {"id": "recovery.offsite", "status": "WARN", "message": "CREDENTIAL"}
            ]})
        self.assertEqual((overall, errors, warnings),
                         ("FAIL", ["storage.dedicated"], ["recovery.offsite"]))
        self.assertNotIn("SECRET", repr((overall, errors, warnings)))

    def test_doctor_refuses_false_pass(self):
        self.assertEqual(p0.doctor_summary({
            "schema_version": 1, "overall": "PASS",
            "checks": [{"id": "a.b", "status": "FAIL"}]})[0], "INVALID")
        self.assertEqual(p0.doctor_summary({
            "schema_version": 1, "overall": "PASS",
            "checks": [{"id": "bad\nSECRET", "status": "PASS"}]})[0], "INVALID")

    def test_timer_requires_exact_four(self):
        rows = [{"unit": unit, "health": "PASS"} for unit in p0.TIMERS]
        self.assertEqual(p0.timer_summary({
            "schema_version": 1, "overall": "PASS", "timers": rows}), (True, 4))
        self.assertEqual(p0.timer_summary({
            "schema_version": 1, "overall": "PASS", "timers": rows[:3]}), (False, 0))

    def test_recorded_backup_does_not_imply_current_remote_proof(self):
        self.assertEqual(p0.verified_recovery({
            "offsite": {"verified_at": "2026-10-31T03:23:17Z",
                        "remote_object": "private:credential"}}, "offsite"),
                         "2026-10-31T03:23:17Z")
        self.assertEqual(p0.verified_recovery({}, "offsite"), "none")

    def test_private_guard(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "sops"
            p.write_text("fixture")
            p.chmod(0o644)
            self.assertFalse(p0.safe_mode(p))
            q = Path(tmp) / "alias"
            q.symlink_to(p)
            self.assertFalse(p0.safe_mode(q))


if __name__ == "__main__":
    unittest.main()
