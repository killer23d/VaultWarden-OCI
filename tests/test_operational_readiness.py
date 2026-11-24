from __future__ import annotations

import io
import json
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from vaultwarden_oci import dashboard, operations, recovery, update_guard, update_status, update_cli


class ReceiptEvidenceTests(unittest.TestCase):
    def test_policy_and_history_are_independent(self):
        historical = {
            "local": {"state": "verified", "verified_at": "2026-11-24T00:00:00Z"},
            "offsite": {"state": "verified", "verified_at": "2026-11-24T00:00:00Z", "matches_destination": False},
        }
        with (
            mock.patch.object(operations.recovery, "backup_receipt_evidence", return_value=historical),
            mock.patch.object(operations, "_age", return_value=3600),
        ):
            for remote, expected in ((None, "local_only"), ("box:current", "never_verified")):
                result = operations._backup_evidence(SimpleNamespace(offsite_remote=remote), True, {})
                self.assertEqual(result["offsite"]["state"], expected)
                self.assertEqual(result["offsite"]["historical_receipt"]["state"], "current")
            self.assertEqual(result["remote_current_presence"], "not_established")

    def test_receipt_invalid_missing_stale_and_exact_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = recovery.RecoveryPaths(backups=root, state_file=root / "state.json")
            name = "recovery-20261124T000000Z-12345678.vwrec"
            artifact = root / name
            artifact.write_bytes(b"ciphertext")
            self.assertEqual(recovery.backup_receipt_evidence(None, paths)["local"]["state"], "never_verified")
            state = {"schema_version": 1, "local": {
                "artifact": str(artifact), "verified_at": "2026-11-24T00:00:00Z",
                "sha256": "a" * 64, "size": artifact.stat().st_size,
            }, "offsite": {
                "remote_object": "box:folder/" + name, "verified_at": "2026-11-24T00:00:00Z",
                "sha256": "a" * 64, "size": artifact.stat().st_size,
            }}
            paths.state_file.write_text(json.dumps(state))
            before = paths.state_file.read_bytes()
            evidence = recovery.backup_receipt_evidence("box:folder", paths)
            self.assertEqual(evidence["local"]["state"], "verified")
            self.assertTrue(evidence["offsite"]["matches_destination"])
            self.assertFalse(recovery.backup_receipt_evidence("box:fol", paths)["offsite"]["matches_destination"])
            with mock.patch.object(operations, "_age", return_value=operations._RECOVERY_WARN_AGE + 1):
                self.assertEqual(operations._receipt_status(evidence["local"])["state"], "stale")
            self.assertEqual(paths.state_file.read_bytes(), before)
            artifact.unlink()
            self.assertEqual(recovery.backup_receipt_evidence(None, paths)["local"]["state"], "failed")
            paths.state_file.write_text("{")
            self.assertEqual(recovery.backup_receipt_evidence(None, paths)["local"]["state"], "unknown")

    def test_storage_failure_never_reads_receipts(self):
        with mock.patch.object(recovery, "backup_receipt_evidence") as reader:
            result = operations._backup_evidence(SimpleNamespace(offsite_remote="box:folder"), False, {})
        reader.assert_not_called()
        self.assertEqual(result["local"]["state"], "unknown")
        self.assertEqual(result["offsite"]["state"], "unknown")

    def test_job_failure_does_not_overwrite_receipt(self):
        with mock.patch.object(recovery, "backup_receipt_evidence", return_value={
            "local": {"state": "verified", "verified_at": "2026-11-24T00:00:00Z"},
            "offsite": {"state": "never_verified"},
        }), mock.patch.object(operations, "_age", return_value=60):
            result = operations._backup_evidence(SimpleNamespace(offsite_remote=None), True, {
                "vaultwarden-oci-backup.service": {"state": "failed"},
            })
        self.assertEqual(result["local"]["state"], "current")
        self.assertEqual(result["scheduled_job"], "failed")


class UpdateAndGuardTests(unittest.TestCase):
    def test_old_update_reason_is_not_current(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "update.json"
            record = {"schema_version": 1, "current": "0.1.0", "checked_at": 100,
                      "candidate": None, "available": False, "error": None,
                      "availability_reason": "no newer stable release"}
            path.write_text(json.dumps(record))
            with mock.patch.object(update_status.cli, "load_versions", return_value=SimpleNamespace(version="0.1.0")):
                self.assertEqual(update_status.snapshot(path=path, now=200)["check_state"], "current")
                stale = update_status.snapshot(path=path, now=100 + update_status.MAX_AGE_SECONDS + 1)
                self.assertEqual(stale["check_state"], "stale")
                self.assertEqual(update_status.snapshot(path=path, now=99)["check_state"], "unknown")
            with mock.patch.object(update_status.cli, "load_versions", return_value=SimpleNamespace(version="0.1.1")):
                self.assertEqual(update_status.snapshot(path=path, now=200)["check_state"], "stale")
        payload = {"update": stale, "runtime": {}, "storage": {"state": "failure"}}
        output = io.StringIO()
        with redirect_stdout(output):
            dashboard.draw_status(payload)
        self.assertIn("stale", output.getvalue())
        self.assertNotIn("no newer stable release", output.getvalue())

    def test_guard_absent_active_and_invalid(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "guard.json"
            self.assertEqual(update_guard.status_snapshot(path)["state"], "absent")
            path.write_text(json.dumps({"schema_version": 1, "recovery_required": True}))
            self.assertEqual(update_guard.status_snapshot(path)["state"], "active")
            path.write_text("{")
            self.assertEqual(update_guard.status_snapshot(path)["state"], "unknown")
            self.assertEqual(path.read_text(), "{")
        with mock.patch.object(update_guard, "load", side_effect=PermissionError):
            self.assertEqual(update_guard.status_snapshot()["state"], "unknown")


class OperationalReadinessTests(unittest.TestCase):
    def payload(self):
        ids = operations._REQUIRED_FOUNDATIONS
        return {
            "schema_version": 1,
            "doctor": {"overall": "PASS", "checks": [
                {"id": key, "status": "PASS", "message": "verified"} for key in ids
            ]},
            "runtime": {"overall": "running"}, "storage": {"state": "ok"},
            "automation": {"overall": "PASS"}, "update": {"check_state": "current"},
            "admin": {"status": "PASS", "message": "protected"},
            "operational": {"update_guard": {"state": "absent", "detail": "none"},
                            "backup": {"local": {"state": "current"}, "offsite": {"state": "local_only"}},
                            "notification": {"operational_route": "not_configured"}},
        }

    def test_readiness_is_scoped_and_no_mutation(self):
        payload = self.payload()
        config = SimpleNamespace(domain="vault.example.invalid")
        result = subprocess.CompletedProcess([], 0, "200", "")
        with (
            mock.patch.object(operations, "status_payload", return_value=payload),
            mock.patch.object(operations, "_config_snapshot", return_value=config),
            mock.patch.object(operations.subprocess, "run", side_effect=[
                result, result, subprocess.CompletedProcess([], 0, "401", ""),
            ]) as run,
            mock.patch.object(operations.cli, "mutation_lock") as lock,
            mock.patch.object(operations.recovery, "create_recovery") as backup,
            mock.patch.object(operations.notification, "deliver") as deliver,
        ):
            report = operations.readiness_payload()
        self.assertEqual(report["overall"], "PASS")
        self.assertEqual(report["deployment_approval"], "not_established")
        self.assertTrue(all(row["state"] == "not_established" for row in report["external_verification"]))
        self.assertTrue(all(row["state"] == "not_established" for row in report["administrator_attestations"]))
        lock.assert_not_called()
        backup.assert_not_called()
        deliver.assert_not_called()
        for call in run.call_args_list:
            argv = call.args[0]
            self.assertIn("vault.example.invalid:443:127.0.0.1", argv)
            self.assertNotIn("--insecure", argv)
            self.assertNotIn("-L", argv)

    def test_readiness_storage_and_automation_fail_closed(self):
        payload = self.payload()
        payload["storage"] = {"state": "failure"}
        payload["automation"] = {"overall": "FAIL"}
        payload["doctor"]["checks"] = [
            row if row["id"] != "storage.dedicated" else {**row, "status": "FAIL"}
            for row in payload["doctor"]["checks"]
        ]
        with mock.patch.object(operations, "status_payload", return_value=payload), mock.patch.object(operations, "_local_https") as tls:
            report = operations.readiness_payload()
        self.assertEqual(report["overall"], "FAIL")
        tls.assert_not_called()

    def test_optional_notifications_do_not_imply_delivery_failure(self):
        config = SimpleNamespace(notification_provider=None)
        payload = self.payload()
        payload["notification"] = {"state": "warning", "transport": "https"}
        result = operations._notification_evidence(config, payload, True)
        self.assertEqual(result["operational_route"], "not_configured")
        self.assertEqual(result["application_smtp"], "configured")
        self.assertEqual(result["delivery_history"]["state"], "warning")
        self.assertEqual(result["smtp_delivery"], "not_established")

    def test_classification_does_not_infer_intent_or_mask_fail(self):
        payload = self.payload()
        config = SimpleNamespace()
        backup = {"local": {"state": "current"}, "policy": "local_only"}
        mail = {"operational_route": "not_configured"}
        guard = {"state": "absent", "detail": "none"}
        classify = lambda: operations._operational_classification(payload, backup, guard, mail, config)
        self.assertEqual(classify()["state"], "OPERATIONAL")
        payload["automation"]["overall"] = "FAIL"
        self.assertEqual(classify()["state"], "ATTENTION")
        payload["runtime"]["overall"] = "stopped"
        self.assertEqual(classify()["state"], "MAINTENANCE / STOPPED")
        self.assertIn("intent is unknown", classify()["reason"])
        payload["doctor"]["overall"] = "FAIL"
        self.assertEqual(classify()["state"], "CRITICAL")
        guard["state"] = "unknown"
        self.assertEqual(classify()["state"], "RECOVERY REQUIRED")
        payload["storage"]["state"] = "failure"
        self.assertEqual(classify()["state"], "CRITICAL")

    def test_independent_job_result_does_not_claim_default_success(self):
        unit = {"load_state": "loaded", "active_state": "inactive", "result": "success"}
        self.assertEqual(operations._job_result(unit), "not_recorded")
        self.assertEqual(operations._job_result({**unit, "last_exited": "today"}), "success_recorded")
        self.assertEqual(operations._job_result({**unit, "result": "exit-code"}), "failed")

    def test_new_command_keeps_json_machine_readable_and_help_ungated(self):
        with (
            mock.patch.object(operations, "readiness_payload", return_value={"overall": "HOLD"}),
            mock.patch.object(update_cli.storage, "verify") as storage,
            redirect_stdout(io.StringIO()) as output,
        ):
            self.assertEqual(update_cli.main(["readiness", "--json"]), 1)
        storage.assert_not_called()
        self.assertEqual(json.loads(output.getvalue()), {"overall": "HOLD"})
        with mock.patch.object(update_cli.storage, "verify") as storage, redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as exc:
                update_cli.main(["readiness", "--help"])
            self.assertEqual(exc.exception.code, 0)
        storage.assert_not_called()


if __name__ == "__main__":
    unittest.main()
