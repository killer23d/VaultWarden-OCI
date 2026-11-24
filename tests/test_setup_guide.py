from __future__ import annotations

import tempfile
import unittest
from contextlib import nullcontext
from pathlib import Path
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
                        "backup": {"local": {"state": "never_verified"}},
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


    def _exercise(self, *, publish="PUBLISH", enable="ENABLE", tls=True, backup=True):
        payload = baseline()
        events = []
        dns = setup_guide.dns_publication
        old = dns.DNSState("vault.example.net", "8.8.8.8", "8.8.4.4", True, "record")
        new = dns.DNSState("vault.example.net", "8.8.8.8", "8.8.8.8", True, "record")
        current = old
        config = mock.Mock(smtp_host="smtp.example.net", offline_recovery_recipient="age1test",
                           offsite_remote=None, local_retention_days=0, remote_retention_days=0)

        def command(args):
            events.append(tuple(args))
            if args == ["start"]:
                payload["runtime"]["overall"] = "running"
                for row in payload["runtime"]["services"]:
                    row.update(state="running", health="healthy")
            if args == ["backup"]:
                if not backup:
                    return mock.Mock(returncode=1)
                payload["operational"]["backup"]["local"]["state"] = "current"
            return mock.Mock(returncode=0)

        def ready():
            value = readiness()
            for row in value["required"]:
                if row["id"] == "https.loopback" and not tls:
                    row["status"] = "UNKNOWN"
                if row["id"] == "recovery.local_receipt" and payload["operational"]["backup"]["local"]["state"] != "current":
                    row["status"] = "WARN"
            return value

        def publication(*, dry_run=False, expected_before=None):
            nonlocal current
            if dry_run:
                return dns.DNSUpdateResult(current, current, not current.in_sync, False)
            self.assertEqual(expected_before, current)
            events.append(("publish",))
            before, current = current, new
            return dns.DNSUpdateResult(before, current, True, True)

        def systemctl(args):
            events.append(tuple(args))
            return mock.Mock(ok=True)

        with (
            mock.patch.object(operations, "status_payload", return_value=payload),
            mock.patch.object(operations, "readiness_payload", side_effect=ready),
            mock.patch.object(setup_guide.runtime, "load_config", return_value=config),
            mock.patch.object(setup_guide.secrets, "validate_encrypted", return_value={"cloudflare_remediation_token": "fixture"}),
            mock.patch.object(setup_guide, "_fingerprint", return_value=("config", "ciphertext")),
            mock.patch.object(setup_guide, "_workspaces", return_value=()),
            mock.patch.object(dns, "update", side_effect=publication),
            mock.patch.object(dns, "status", side_effect=lambda: current),
            mock.patch.object(setup_guide.cli, "run_command", side_effect=systemctl),
            mock.patch("builtins.input", side_effect=["CUSTODY", "VALIDATE", "RECEIVED", "START", publish, "BACKUP", enable]),
        ):
            code = setup_guide.main(run=command, ensure_selected=mock.Mock())
        return code, events

    def test_successful_guided_sequence_orders_consent_and_owners(self):
        code, events = self._exercise()
        self.assertEqual(code, 0)
        self.assertEqual(events, [
            ("config", "validate", "--file", str(setup_guide.install.CONFIG_PATH)),
            ("secrets", "validate"),
            ("notification", "test", "--smtp"), ("start",), ("publish",), ("backup",),
            ("systemctl", "enable", "--now", operations.AUTOMATION_TARGET),
            ("timers",), ("readiness",),
        ])

    def test_dns_decline_or_tls_unknown_never_publishes_or_activates(self):
        for kwargs in ({"publish": ""}, {"tls": False}):
            with self.subTest(kwargs=kwargs):
                code, events = self._exercise(**kwargs)
                self.assertEqual(code, 2)
                self.assertNotIn(("publish",), events)
                self.assertNotIn(("backup",), events)
                self.assertFalse(any(event[0] == "systemctl" for event in events))

    def test_backup_failure_or_activation_decline_never_activates(self):
        for kwargs in ({"backup": False}, {"enable": ""}):
            with self.subTest(kwargs=kwargs):
                code, events = self._exercise(**kwargs)
                self.assertEqual(code, 2)
                self.assertIn(("backup",), events)
                self.assertFalse(any(event[0] == "systemctl" for event in events))

    def test_dns_owner_refuses_changed_plan_before_patch(self):
        dns = setup_guide.dns_publication
        old = dns.DNSState("vault.example.net", "8.8.8.8", "8.8.4.4", True, "record")
        changed = dns.DNSState(old.domain, old.public_ipv4, "1.1.1.1", True, old.record_id)
        with (
            mock.patch.object(dns, "_context", return_value=(old.domain, old.public_ipv4, "fixture", "zone")),
            mock.patch.object(dns.cli, "mutation_lock", return_value=nullcontext()),
            mock.patch.object(dns, "inspect_state", return_value=changed),
            mock.patch.object(dns, "_api_request") as request,
        ):
            with self.assertRaisesRegex(dns.DNSError, "changed since"):
                dns.update(expected_before=old)
            request.assert_not_called()

    def test_manual_worker_owner_refuses_invocation_drift_before_receipt(self):
        edge = setup_guide.edge
        with tempfile.TemporaryDirectory() as folder:
            receipt = Path(folder) / "fail-open.json"
            paths = edge.EdgePaths(fail_open_confirmation=receipt)
            with mock.patch.object(edge, "_service_invocation_id", return_value="b" * 32):
                with self.assertRaisesRegex(edge.EdgeError, "invocation changed"):
                    edge.confirm_fail_open(paths=paths, expected_invocation="a" * 32)
            self.assertFalse(receipt.exists())


if __name__ == "__main__":
    unittest.main()
