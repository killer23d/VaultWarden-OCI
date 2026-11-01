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

    def test_missing_or_empty_backups_are_not_a_disk_failure(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            backups = root / 'backups'
            self.assertEqual(p0.local_backup_inventory(backups, root)[0], 'NOT RUN')
            backups.mkdir()
            self.assertEqual(p0.local_backup_inventory(backups, root)[0], 'NOT RUN')
            (backups / 'recovery.vwrec').write_bytes(b'encrypted-fixture')
            self.assertEqual(p0.local_backup_inventory(backups, root)[0], 'PENDING')
            (backups / 'bad.vwrec').symlink_to(backups / 'recovery.vwrec')
            self.assertEqual(p0.local_backup_inventory(backups, root)[0], 'BLOCKED')

    def test_backup_timer_default_success_is_not_a_firing(self):
        self.assertEqual(p0.last_backup_witness(
            {'Result': 'success'}, {'LastTriggerUSec': ''})[0], 'NOT RUN')
        self.assertEqual(p0.last_backup_witness(
            {'Result': 'success'}, {'LastTriggerUSec': 'Sat 2026-10-31 03:23:17 UTC'})[0], 'PENDING')
        self.assertEqual(p0.last_backup_witness(
            {'Result': 'exit-code'}, {'LastTriggerUSec': 'Sat 2026-10-31 03:23:17 UTC'})[0], 'WARN')

    def test_semantic_sops_failure_reasons_do_not_expose_values(self):
        self.assertEqual(p0.safe_secret_failure(
            ValueError('decrypted secret smtp_password must be a non-empty single-line string')),
            'invalid or missing required secret value: smtp_password')
        self.assertNotIn('highly-secret', p0.safe_secret_failure(
            ValueError('untrusted highly-secret error text')))


if __name__ == "__main__":
    unittest.main()
