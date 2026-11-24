from __future__ import annotations

import unittest
from unittest import mock

from vaultwarden_oci import operations, setup_guide


def baseline():
    checks = [{"id": name, "status": "PASS", "message": "verified"}
              for name in operations._REQUIRED_FOUNDATIONS]
    target = {"load_state": "loaded", "active_state": "inactive", "enabled": "disabled"}
    return {
        "schema_version": 1, "doctor": {"checks": checks}, "storage": {"state": "ok"},
        "runtime": {"overall": "stopped", "services": [
            {"service": name, "state": "absent", "health": "-"} for name in ("vaultwarden", "caddy")]},
        "automation": {"overall": "FAIL", "target": target},
        "timers": [{"unit": name, **target} for name in operations.TIMER_UNITS],
        "operational": {"update_guard": {"state": "absent"},
                        "jobs": {name: {**target, "result": "success"} for name in operations._REQUIRED_JOBS},
                        "automation": {"boot_persistence": "disabled"},
                        "crowdsec": {"boot_reconciliation": target.copy()}},
    }


def readiness():
    return {"overall": "FAIL", "required": [
        {"id": name, "status": "FAIL" if name in setup_guide._AUTOMATION else "PASS"}
        for name in (*operations._REQUIRED_FOUNDATIONS, "diagnostics.overall", "runtime.running",
                     "update.guard", "recovery.local_receipt", "https.loopback", *setup_guide._AUTOMATION)]}


class SetupGuideTests(unittest.TestCase):
    def test_pre_activation_preserves_final_readiness(self):
        value = readiness()
        setup_guide._pre_activation(value)
        self.assertEqual(value["overall"], "FAIL")

    def test_pre_activation_blocks_unverified_foundations(self):
        for name in ("https.loopback", "runtime.paths", "crowdsec.cloudflare", "update.guard",
                     "diagnostics.overall", "recovery.local_receipt"):
            for status in ("FAIL", "UNKNOWN", "WARN"):
                with self.subTest(name=name, status=status):
                    value = readiness()
                    next(row for row in value["required"] if row["id"] == name)["status"] = status
                    with self.assertRaises(setup_guide.Hold):
                        setup_guide._pre_activation(value)

    def test_missing_readiness_check_blocks(self):
        value = readiness()
        value["required"].pop(0)
        with self.assertRaises(setup_guide.Hold):
            setup_guide._pre_activation(value)

    def test_backup_warn_only_allowed_before_backup(self):
        value = readiness()
        row = next(row for row in value["required"] if row["id"] == "recovery.local_receipt")
        row["status"] = "WARN"
        setup_guide._pre_activation(value, before_backup=True)
        row["status"] = "FAIL"
        with self.assertRaises(setup_guide.Hold):
            setup_guide._pre_activation(value, before_backup=True)

    def test_prestart_preserves_exact_partial_paths_failure(self):
        payload = baseline()
        checks = setup_guide._baseline(payload)
        checks["runtime.paths"].update(status="FAIL", message="runtime paths are only partially materialized")
        setup_guide._prestart(payload, checks)
        self.assertEqual(checks["runtime.paths"]["status"], "FAIL")
        checks["runtime.paths"]["message"] = "incompatible ownership/mode"
        with self.assertRaises(setup_guide.Hold):
            setup_guide._prestart(payload, checks)

    def test_prestart_refuses_origin_or_worker_failure(self):
        for name in ("edge.cloudflare.iptables", "crowdsec.cloudflare"):
            payload = baseline()
            checks = setup_guide._baseline(payload)
            checks[name]["status"] = "FAIL"
            with self.assertRaises(setup_guide.Hold):
                setup_guide._prestart(payload, checks)

    def test_isolation_requires_all_disabled_inactive_units(self):
        setup_guide._isolated(baseline())
        for name in ("target", "timer", "job", "boot", "missing"):
            with self.subTest(name=name):
                value = baseline()
                if name == "target":
                    value["automation"]["target"]["enabled"] = "enabled"
                elif name == "timer":
                    value["timers"][0]["active_state"] = "active"
                elif name == "job":
                    value["operational"]["jobs"].pop(operations._REQUIRED_JOBS[0])
                elif name == "boot":
                    value["operational"]["crowdsec"]["boot_reconciliation"]["enabled"] = "enabled"
                else:
                    value["timers"].pop()
                with self.assertRaises(setup_guide.Hold):
                    setup_guide._isolated(value)

    def test_activated_appliance_readiness_only(self):
        value = baseline()
        value["automation"]["overall"] = "PASS"
        value["operational"]["automation"]["boot_persistence"] = "persistent"
        value["runtime"]["overall"] = "running"
        for row in value["runtime"]["services"]:
            row.update(state="running", health="healthy")
        with (
            mock.patch.object(operations, "status_payload", return_value=value),
            mock.patch("builtins.input") as prompt,
            mock.patch.object(setup_guide.dns_publication, "update") as dns,
            mock.patch.object(setup_guide.cli, "run_command") as systemctl,
        ):
            run = mock.Mock(return_value=mock.Mock(returncode=0))
            self.assertEqual(setup_guide.main(run=run, ensure_selected=mock.Mock()), 0)
            run.assert_called_once_with(["readiness"])
            prompt.assert_not_called()
            dns.assert_not_called()
            systemctl.assert_not_called()

    def test_bad_storage_or_guard_blocks_all_commands(self):
        for field in ("storage", "guard"):
            value = baseline()
            if field == "storage":
                value["storage"]["state"] = "failure"
            else:
                value["operational"]["update_guard"]["state"] = "present"
            with mock.patch.object(operations, "status_payload", return_value=value):
                run = mock.Mock()
                self.assertEqual(setup_guide.main(run=run, ensure_selected=mock.Mock()), 2)
                run.assert_not_called()

    def test_consent_requires_exact_word(self):
        for answer in ("", "n", "yes"):
            with mock.patch("builtins.input", return_value=answer):
                with self.assertRaises(setup_guide.Hold):
                    setup_guide._consent("Publish DNS?", "PUBLISH")

    def test_ambiguous_custody_does_not_export_or_cleanup(self):
        with (
            mock.patch.object(setup_guide, "_workspaces", return_value=("one", "two")),
            mock.patch.object(setup_guide.recovery_ux, "export_recovery_kit") as export,
            mock.patch.object(setup_guide.recovery_ux, "_cleanup_workspace") as cleanup,
        ):
            with self.assertRaises(setup_guide.Hold):
                setup_guide._custody(mock.Mock())
            export.assert_not_called()
            cleanup.assert_not_called()


if __name__ == "__main__":
    unittest.main()
