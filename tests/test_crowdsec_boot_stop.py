"""Cloudflare boot re-arm and narrowly verified upstream SIGTERM exit semantics."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import (
    cli,
    cloudflare_route_mode,
    crowdsec_boot,
    crowdsec_stop,
    crowdsec_worker_policy,
    edge,
    install,
    storage,
)

INV = "1" * 32
ROUTE = "2" * 32


def reply(args, ok=True, output=""):
    return cli.CommandResult(
        tuple(args),
        "success" if ok else "nonzero",
        0 if ok else 1,
        output,
        "",
    )


class BootOwnerTests(unittest.TestCase):
    def setUp(self):
        self.state = "inactive"
        self.pid = "0"
        self.calls = []

        def runner(args, **_kwargs):
            args = tuple(args)
            self.calls.append(args)
            if args[:3] == ("systemctl", "show", edge.BOUNCER_SERVICE):
                return reply(args, output=(
                    "LoadState=loaded\nActiveState=" + self.state + "\n"
                    "MainPID=" + self.pid + "\nRestart=no\nUnitFileState=disabled\n"
                ))
            return reply(args)

        self.runner = runner
        self.proof = cloudflare_route_mode.RouteProof(
            route_id=ROUTE, pattern="vault.example.net/*",
            script=cloudflare_route_mode.BOUNCER_SCRIPT,
            invocation_id=INV, changed=True,
        )
        patches = (
            mock.patch.object(crowdsec_boot.os, "geteuid", return_value=0),
            mock.patch.object(storage, "verify"),
            mock.patch.object(edge, "_disabled", return_value=True),
            mock.patch.object(edge, "_active", return_value=True),
            mock.patch.object(edge, "_service_invocation_id", return_value=INV),
            mock.patch.object(crowdsec_worker_policy, "runtime_policy_healthy", return_value=True),
            mock.patch.object(cloudflare_route_mode, "ensure_fail_open", return_value=self.proof),
            mock.patch.object(cloudflare_route_mode, "wait_owned_route_stable"),
        )
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def test_inactive_worker_boot_starts_once_with_verified_route(self):
        def mark_started(*, paths, runner):
            self.state = "active"
            self.pid = "313"
        with mock.patch.object(edge, "start_remediation", side_effect=mark_started) as start:
            result = crowdsec_boot.reconcile(runner=self.runner)
        self.assertTrue(result.started)
        self.assertEqual(result.invocation_id, INV)
        self.assertTrue(result.cloudflare_route_updated)
        start.assert_called_once()

    def test_active_worker_boot_only_rechecks_cloudflare(self):
        self.state, self.pid = "active", "333"
        with mock.patch.object(edge, "start_remediation") as start:
            result = crowdsec_boot.reconcile(runner=self.runner)
        self.assertFalse(result.started)
        start.assert_not_called()

    def test_boot_cannot_report_pass_if_provider_route_disappears(self):
        self.state, self.pid = "active", "333"
        with mock.patch.object(
            cloudflare_route_mode, "wait_owned_route_stable",
            side_effect=edge.EdgeError("Route inconsistent"),
        ):
            with self.assertRaisesRegex(edge.EdgeError, "Route inconsistent"):
                crowdsec_boot.reconcile(runner=self.runner)

    def test_failed_worker_not_silently_reset_or_restarted(self):
        self.state = "failed"
        with mock.patch.object(edge, "start_remediation") as start:
            with self.assertRaisesRegex(edge.EdgeError, "manual diagnosis"):
                crowdsec_boot.reconcile(runner=self.runner)
        start.assert_not_called()
        self.assertFalse(any("reset-failed" in c for args in self.calls for c in args))

    def test_active_worker_without_current_policy_cannot_be_reused(self):
        self.state, self.pid = "active", "333"
        with mock.patch.object(crowdsec_worker_policy, "runtime_policy_healthy", return_value=False):
            with self.assertRaisesRegex(edge.EdgeError, "trustworthy"):
                crowdsec_boot.reconcile(runner=self.runner)

    def test_missing_data_volume_prevents_any_worker_start(self):
        with mock.patch.object(storage, "verify", side_effect=storage.StorageError("missing")):
            with mock.patch.object(edge, "start_remediation") as start:
                with self.assertRaises(storage.StorageError):
                    crowdsec_boot.reconcile(runner=self.runner)
                start.assert_not_called()
        self.assertEqual(self.calls, [])

    def test_worker_boot_containment_must_not_be_enabled(self):
        with mock.patch.object(edge, "_disabled", return_value=False):
            with self.assertRaisesRegex(edge.EdgeError, "boot-disabled"):
                crowdsec_boot.reconcile(runner=self.runner)

    def test_boot_unit_is_opt_in_and_stops_on_failure(self):
        unit = Path(__file__).resolve().parents[1] / "systemd/vaultwarden-oci-crowdsec-boot.service"
        text = unit.read_text()
        self.assertIn("WantedBy=multi-user.target", text)
        self.assertIn("ExecStart=/opt/vaultwarden-oci/current/vwctl crowdsec boot-reconcile", text)
        self.assertIn("After=network-online.target crowdsec.service crowdsec-firewall-bouncer.service", text)
        self.assertIn("Requires=crowdsec.service crowdsec-firewall-bouncer.service", text)
        self.assertIn("RequiresMountsFor=/var/lib/vaultwarden-oci", text)
        self.assertIn("Restart=no", text)
        self.assertNotIn("ExecStart=/usr/bin/systemctl start", text)
        self.assertIn("vaultwarden-oci-crowdsec-boot.service", install.SYSTEMD_UNITS)

    def test_cli_commands_are_distinct_from_manual_confirm(self):
        parser = cli._parser()
        for argv, action in [
            (["crowdsec", "remediation-stop"], "remediation-stop"),
            (["crowdsec", "boot-reconcile"], "boot-reconcile"),
            (["crowdsec", "confirm-fail-open"], "confirm-fail-open"),
        ]:
            self.assertEqual(parser.parse_args(argv).crowdsec_command, action)


class ControlledShutdownTests(unittest.TestCase):
    def setUp(self):
        self.state = "active"
        self.exec_status = "0"
        self.result_state = "success"
        self.main_pid = "427"
        self.calls = []
        self.cleanup_calls = []

        def runner(args, **_kwargs):
            args = tuple(args)
            self.calls.append(args)
            if args[:3] == ("systemctl", "show", edge.BOUNCER_SERVICE):
                out = (
                    "LoadState=loaded\nActiveState=" + self.state + "\n"
                    "SubState=" + ("running" if self.state == "active" else self.state) + "\n"
                    "Result=" + self.result_state + "\nUnitFileState=disabled\n"
                    "MainPID=" + self.main_pid + "\nNRestarts=0\nRestart=no\n"
                    "InvocationID=" + INV + "\nExecMainStatus=" + self.exec_status + "\n"
                )
                return reply(args, output=out)
            if args == ("systemctl", "stop", edge.BOUNCER_SERVICE):
                self.state, self.result_state, self.exec_status, self.main_pid = (
                    "failed", "exit-code", "1", "0"
                )
                return reply(args)
            if args == ("systemctl", "reset-failed", edge.BOUNCER_SERVICE):
                self.state, self.result_state, self.exec_status = "inactive", "success", "0"
                return reply(args)
            return reply(args)

        self.runner = runner
        patches = (
            mock.patch.object(crowdsec_stop.os, "geteuid", return_value=0),
            mock.patch.object(edge, "_service_invocation_id", return_value=INV),
            mock.patch.object(crowdsec_worker_policy, "runtime_policy_healthy", return_value=True),
            mock.patch.object(edge, "_fail_open_confirmed", return_value=True),
            mock.patch.object(edge, "_unlink_state", side_effect=lambda *args: self.cleanup_calls.append(args)),
            mock.patch.object(cloudflare_route_mode, "read_owned_route_id", return_value=ROUTE),
            mock.patch.object(cloudflare_route_mode, "wait_owned_route_absent"),
        )
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def test_only_controlled_verified_exit_one_is_normalized(self):
        outcome = crowdsec_stop.stop(runner=self.runner)
        self.assertEqual(outcome.original_exit_status, 1)
        self.assertTrue(outcome.normalized)
        self.assertEqual(outcome.old_route_id, ROUTE)
        self.assertEqual(self.state, "inactive")
        self.assertEqual(len(self.cleanup_calls), 1)
        self.assertIn(("systemctl", "reset-failed", edge.BOUNCER_SERVICE), self.calls)

    def test_provider_cleanup_failure_preserves_unit_failure(self):
        with mock.patch.object(cloudflare_route_mode, "wait_owned_route_absent",
                               side_effect=edge.EdgeError("Route persisted")):
            with self.assertRaisesRegex(edge.EdgeError, "Route persisted"):
                crowdsec_stop.stop(runner=self.runner)
        self.assertEqual(self.state, "failed")
        self.assertFalse(self.cleanup_calls)
        self.assertNotIn(("systemctl", "reset-failed", edge.BOUNCER_SERVICE), self.calls)

    def test_unexpected_exit_reason_not_normalized(self):
        def fatal_runner(args, **kwargs):
            result = self.runner(args, **kwargs)
            if tuple(args) == ("systemctl", "stop", edge.BOUNCER_SERVICE):
                self.exec_status = "9"
            return result
        with self.assertRaisesRegex(edge.EdgeError, "unexpected failure"):
            crowdsec_stop.stop(runner=fatal_runner)
        self.assertNotIn(("systemctl", "reset-failed", edge.BOUNCER_SERVICE), self.calls)

    def test_unconfirmed_policy_prevents_shutdown(self):
        with mock.patch.object(edge, "_fail_open_confirmed", return_value=False):
            with self.assertRaisesRegex(edge.EdgeError, "confirmed Fail Open"):
                crowdsec_stop.stop(runner=self.runner)
        self.assertNotIn(("systemctl", "stop", edge.BOUNCER_SERVICE), self.calls)


if __name__ == "__main__":
    unittest.main()
