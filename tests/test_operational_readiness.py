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

from vaultwarden_oci import cli, dashboard, edge, notification, operations, recovery, storage, update_guard, update_status, update_cli


class ReceiptEvidenceTests(unittest.TestCase):
    def test_policy_and_history_are_independent(self):
        historical = {
            "local": {"state": "verified", "verified_at": "2026-11-24T00:00:00Z"},
            "offsite": {"state": "verified", "verified_at": "2026-11-24T00:00:00Z", "matches_destination": False},
        }
        with (
            mock.patch.object(operations.recovery, "backup_receipt_evidence", return_value=historical),
            mock.patch.object(operations.recovery, "rclone_local_diagnostics", return_value=(True, "configured")),
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

    def test_invalid_update_record_is_not_fresh(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "update.json"
            path.write_text(json.dumps({"checked_at": 100, "available": False}))
            with mock.patch.object(update_status.cli, "load_versions", return_value=SimpleNamespace(version="0.1.0")):
                result = update_status.snapshot(path=path, now=101)
        self.assertEqual(result["check_state"], "unknown")
        self.assertTrue(result["check_stale"])

    def test_incomplete_or_boolean_schema_update_cannot_be_current(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "update.json"
            base = {"schema_version": 1, "current": "0.1.0", "checked_at": 100,
                    "candidate": None, "available": False, "error": None,
                    "availability_reason": "no newer stable release"}
            cases = [
                {**base, "schema_version": True},
                {**base, "availability_reason": None},
                {**base, "error": ""},
                {key: value for key, value in base.items() if key != "error"},
            ]
            with mock.patch.object(update_status.cli, "load_versions", return_value=SimpleNamespace(version="0.1.0")):
                for record in cases:
                    with self.subTest(record=record):
                        path.write_text(json.dumps(record))
                        result = update_status.snapshot(path=path, now=101)
                        self.assertEqual(result["check_state"], "unknown")
                        self.assertTrue(result["check_stale"])

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
                            "notification": {"operational_route": "not_configured"},
                            "automation": {"activation": "PASS", "boot_persistence": "persistent",
                                           "execution": "success_recorded", "masked_timers": []}},
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
        payload["operational"]["automation"]["activation"] = "FAIL"
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
        auto = payload["operational"]["automation"]
        classify = lambda: operations._operational_classification(payload, backup, guard, mail, config, auto)
        self.assertEqual(classify()["state"], "OPERATIONAL")
        auto["activation"] = "FAIL"
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

    def test_required_foundations_and_setup_are_truthful(self):
        payload = self.payload()
        backup = {"local": {"state": "current"}, "policy": "local_only"}
        guard = {"state": "absent", "detail": "none"}
        mail = {"operational_route": "not_configured"}
        auto = payload["operational"]["automation"]
        config = SimpleNamespace()
        classify = lambda: operations._operational_classification(payload, backup, guard, mail, config, auto)
        checks = payload["doctor"]["checks"]
        caddy = next(row for row in checks if row["id"] == "edge.caddy.trusted_proxy")
        for state in ("SKIP", "WARN", "UNKNOWN"):
            caddy["status"] = state
            self.assertEqual(classify()["state"], "ATTENTION")
        checks.remove(caddy)
        self.assertEqual(classify()["state"], "ATTENTION")
        payload["runtime"]["overall"] = "stopped"
        config = None
        self.assertEqual(classify()["state"], "SETUP INCOMPLETE")
        checks.append({"id": "edge.cloudflare.iptables", "status": "FAIL"})
        self.assertEqual(classify()["state"], "CRITICAL")

    def test_offsite_exact_remote_and_no_cloud_polling(self):
        calls = []
        def runner(argv):
            calls.append(argv)
            return cli.CommandResult(tuple(argv), "success", 0, "other:\n" if argv[1] == "listremotes" else "", "")
        self.assertTrue(recovery.rclone_local_diagnostics(runner=runner)[0])
        self.assertFalse(recovery.rclone_local_diagnostics("box:folder", runner=runner)[0])
        self.assertTrue(recovery.rclone_local_diagnostics("other:folder", runner=runner)[0])
        self.assertTrue(all(argv[1] in {"version", "config", "listremotes"} for argv in calls))
        receipts = {"local": {"state": "verified"}, "offsite": {"state": "verified", "matches_destination": True}}
        with mock.patch.object(recovery, "backup_receipt_evidence", return_value=receipts), mock.patch.object(operations, "_age", return_value=1), mock.patch.object(recovery, "rclone_local_diagnostics", return_value=(False, "missing")):
            backup = operations._backup_evidence(SimpleNamespace(offsite_remote="box:folder"), True, {})
        self.assertEqual(backup["offsite"]["state"], "current")
        self.assertEqual(backup["destination_state"], "not_established")
        self.assertEqual(backup["destination_connectivity"], "not_established")
        payload = self.payload()
        result = operations._operational_classification(payload, backup, {"state": "absent", "detail": "none"}, {"operational_route": "not_configured"}, SimpleNamespace(), payload["operational"]["automation"])
        self.assertEqual(result["state"], "ATTENTION")

    def test_automation_persistence_and_independent_jobs(self):
        payload = self.payload()
        payload["automation"]["target"] = {"enabled": "enabled-runtime"}
        jobs = {name: {"state": "success_recorded"} for name in operations._REQUIRED_JOBS}
        evidence = operations._automation_evidence(payload, jobs)
        self.assertEqual(evidence["boot_persistence"], "runtime_only")
        self.assertEqual(evidence["execution"], "success_recorded")
        payload["automation"]["target"]["enabled"] = "enabled"
        jobs["vaultwarden-oci-dns.service"] = {"state": "not_recorded"}
        evidence = operations._automation_evidence(payload, jobs)
        self.assertEqual(evidence["execution"], "not_established")
        self.assertIn("vaultwarden-oci-dns.service", evidence["unverified_jobs"])
        jobs["vaultwarden-oci-dns.service"] = {"state": "failed"}
        self.assertEqual(operations._automation_evidence(payload, jobs)["execution"], "failed")
        payload["timers"] = [{"unit": operations.TIMER_UNITS[0], "enabled": "masked"}]
        self.assertEqual(operations._automation_evidence(payload, jobs)["masked_timers"], [operations.TIMER_UNITS[0]])

    def test_storage_failure_withholds_persistent_evidence(self):
        with (
            mock.patch.object(operations, "_storage_status", return_value={"state": "failure"}),
            mock.patch.object(operations.runtime, "status", return_value=("running", [])),
            mock.patch.object(operations.cli, "doctor_checks", return_value=[]) as doctor,
            mock.patch.object(operations, "automation_snapshot", return_value={"overall": "PASS", "target": {}, "healthy": 4, "expected": 4, "timers": []}),
            mock.patch.object(operations, "_config_snapshot", return_value=None),
            mock.patch.object(operations, "_systemd_properties", return_value={}),
            mock.patch.object(recovery, "status_rows") as legacy,
            mock.patch.object(recovery, "backup_receipt_evidence") as receipts,
            mock.patch.object(notification, "status_row") as delivery,
            mock.patch.object(update_status, "load") as update,
            mock.patch.object(update_guard, "load") as guard,
            mock.patch.object(edge, "worker_invocation_snapshot") as worker,
        ):
            payload = operations.status_payload()
        doctor.assert_called_once_with(persistent_state_verified=False)
        for reader in (legacy, receipts, delivery, update, guard, worker):
            reader.assert_not_called()
        self.assertEqual(payload["operational"]["state"], "CRITICAL")
        self.assertEqual(payload["doctor"]["overall"], "FAIL")
        self.assertTrue(all(row["state"] == "unknown" and row["stale"] for row in payload["recovery"]))
        self.assertEqual(payload["update"]["check_state"], "unknown")
        self.assertTrue(payload["update"]["check_stale"])
        self.assertEqual(payload["notification"]["state"], "unknown")

    def test_doctor_owners_withhold_untrusted_persistent_state(self):
        with (
            mock.patch.object(recovery, "status_rows") as receipts,
            mock.patch.object(recovery, "rclone_local_diagnostics", return_value=(True, "local")),
            mock.patch.object(notification, "load_result") as delivery,
        ):
            checks = recovery.doctor_checks(state_verified=False)
            self.assertEqual([row.status for row in checks[:2]], ["SKIP", "SKIP"])
            mail = notification.doctor_checks(config=None, secret_values=None, state_verified=False)
            self.assertEqual(next(row.status for row in mail if row.check_id == "notification.last_delivery"), "SKIP")
        receipts.assert_not_called()
        delivery.assert_not_called()
        def runner(argv):
            return cli.CommandResult(tuple(argv), "nonzero", 1, "", "")
        with mock.patch.object(edge, "load_lkg") as ranges, mock.patch.object(edge, "_fail_open_confirmed") as confirm:
            checks = edge.doctor_checks(runner=runner, state_verified=False)
        ranges.assert_not_called()
        confirm.assert_not_called()
        by_id = {row.check_id: row.status for row in checks}
        self.assertEqual(by_id["edge.cloudflare.cidrs"], "FAIL")
        self.assertEqual(by_id["edge.cloudflare.iptables"], "FAIL")
        self.assertEqual(by_id["crowdsec.cloudflare"], "FAIL")

    def test_guard_blocks_https_and_execution_gap_holds(self):
        payload = self.payload()
        payload["operational"]["update_guard"]["state"] = "unknown"
        with mock.patch.object(operations, "status_payload", return_value=payload), mock.patch.object(operations, "_local_https") as tls:
            self.assertEqual(operations.readiness_payload()["overall"], "FAIL")
        tls.assert_not_called()
        payload["operational"]["update_guard"]["state"] = "absent"
        payload["operational"]["automation"]["execution"] = "not_established"
        with mock.patch.object(operations, "status_payload", return_value=payload), mock.patch.object(operations, "_config_snapshot", return_value=SimpleNamespace(domain="vault.example.invalid")), mock.patch.object(operations, "_local_https", return_value={"status": "PASS", "message": "loopback"}):
            self.assertEqual(operations.readiness_payload()["overall"], "HOLD")

    def test_disabled_admin_tls_requires_404(self):
        config = SimpleNamespace(domain="vault.example.invalid")
        with mock.patch.object(operations.subprocess, "run", side_effect=[
            subprocess.CompletedProcess([], 0, "200", ""),
            subprocess.CompletedProcess([], 0, "200", ""),
            subprocess.CompletedProcess([], 0, "404", ""),
        ]) as run:
            self.assertEqual(operations._local_https(config, {"status": "PASS", "message": "disabled at Caddy"})["status"], "PASS")
        self.assertEqual(run.call_count, 3)
        with mock.patch.object(operations.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "302", "")):
            self.assertEqual(operations._local_https(config, {"status": "PASS", "message": "protected"})["status"], "FAIL")

    def test_independent_job_result_does_not_claim_default_success(self):
        unit = {"load_state": "loaded", "active_state": "inactive", "result": "success"}
        self.assertEqual(operations._job_result(unit), "not_recorded")
        self.assertEqual(operations._job_result({**unit, "last_exited": "today"}), "success_recorded")
        self.assertEqual(operations._job_result({**unit, "result": "exit-code"}), "failed")

    def test_non_tty_status_fails_closed_before_persistent_receipt_reads(self):
        with (
            mock.patch.object(storage, "verify", side_effect=storage.StorageError("missing mount")),
            mock.patch.object(operations.runtime, "status", return_value=("running", [])),
            mock.patch.object(recovery, "status_rows") as receipts,
            mock.patch.object(notification, "status_row") as delivery,
            mock.patch.object(edge, "doctor_checks", return_value=[]) as checks,
            redirect_stdout(io.StringIO()) as output,
        ):
            self.assertEqual(update_cli.main(["status"]), 1)
        receipts.assert_not_called()
        delivery.assert_not_called()
        checks.assert_called_once_with(state_verified=False)
        self.assertIn("storage.dedicated: FAIL", output.getvalue())
        self.assertIn("recovery-offsite: unknown", output.getvalue())
        self.assertIn("Overall: degraded", output.getvalue())

    def test_provider_change_cannot_inherit_successful_delivery(self):
        payload = self.payload()
        payload["doctor"]["checks"].extend([
            {"id": key, "status": "PASS", "message": "configured"}
            for key in ("notification.provider", "notification.api_secret")
        ])
        config = SimpleNamespace(notification_provider="mailersend")
        payload["notification"] = {"state": "success", "provider": "cyberpersons", "transport": "https"}
        evidence = operations._notification_evidence(config, payload, True)
        self.assertEqual(evidence["history_provider_match"], "different_provider")
        self.assertEqual(evidence["current_route_delivery"], "not_established")
        backup = {"local": {"state": "current"}, "policy": "local_only"}
        guard = {"state": "absent", "detail": "none"}
        auto = payload["operational"]["automation"]
        result = operations._operational_classification(payload, backup, guard, evidence, config, auto)
        self.assertEqual(result["state"], "ATTENTION")
        payload["notification"]["provider"] = "mailersend"
        evidence = operations._notification_evidence(config, payload, True)
        self.assertEqual(evidence["history_provider_match"], "matches_configured_provider")
        self.assertEqual(evidence["current_route_delivery"], "not_established")
        self.assertEqual(operations._operational_classification(payload, backup, guard, evidence, config, auto)["state"], "OPERATIONAL")

    def test_unknown_doctor_aggregate_never_passes_readiness(self):
        payload = self.payload()
        payload["doctor"]["overall"] = "UNKNOWN"
        with (
            mock.patch.object(operations, "status_payload", return_value=payload),
            mock.patch.object(operations, "_config_snapshot", return_value=SimpleNamespace(domain="vault.example.invalid")),
            mock.patch.object(operations, "_local_https", return_value={"status": "PASS", "message": "loopback"}),
        ):
            report = operations.readiness_payload()
        self.assertEqual(report["overall"], "HOLD")
        self.assertEqual(next(row["status"] for row in report["required"] if row["id"] == "diagnostics.overall"), "UNKNOWN")

    def test_optional_boot_failure_is_visible_but_disabled_is_not_failure(self):
        payload = self.payload()
        backup = {"local": {"state": "current"}, "policy": "local_only"}
        guard = {"state": "absent", "detail": "none"}
        mail = {"operational_route": "not_configured"}
        auto = payload["operational"]["automation"]
        config = SimpleNamespace()
        boot = {"load_state": "loaded", "active_state": "inactive", "result": "success", "enabled": "disabled"}
        self.assertEqual(operations._operational_classification(payload, backup, guard, mail, config, auto, boot)["state"], "OPERATIONAL")
        boot["result"] = "exit-code"
        boot["active_state"] = "failed"
        result = operations._operational_classification(payload, backup, guard, mail, config, auto, boot)
        self.assertEqual(result["state"], "ATTENTION")
        self.assertIn("CrowdSec boot reconciliation reported failure", result["reason"])

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
