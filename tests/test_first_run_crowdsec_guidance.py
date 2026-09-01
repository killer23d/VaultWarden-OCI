from __future__ import annotations

import io
import unittest
from contextlib import redirect_stdout
from types import SimpleNamespace
from unittest import mock

from vaultwarden_oci import operator_cosmetics, operator_entrypoint, operator_output, setup_frontend
from vaultwarden_oci.cli import DoctorCheck


class _TTYStringIO(io.StringIO):
    def isatty(self) -> bool:
        return True


class FirstRunCrowdSecGuidanceTests(unittest.TestCase):
    def test_post_handoff_actions_follow_real_fresh_host_order(self) -> None:
        output = io.StringIO()
        with redirect_stdout(output):
            setup_frontend._print_post_handoff_next_actions()

        rendered = output.getvalue()
        ordered = (
            "ACTION run: sudo vwctl crowdsec setup",
            "ACTION run: sudo vwctl crowdsec remediation-start",
            "ACTION then run: sudo vwctl crowdsec confirm-fail-open",
            "ACTION run: sudo vwctl start",
            "ACTION run: sudo vwctl backup to create and verify the first application recovery point",
            "ACTION run: sudo vwctl doctor after start has materialized the runtime and Cloudflare origin policy",
            "ACTION enable persistent automation with: sudo systemctl enable --now vaultwarden-oci.target",
            "ACTION run: sudo vwctl timers",
            "ACTION run: sudo vwctl update check to seed the initial update-status snapshot",
        )
        positions = [rendered.index(item) for item in ordered]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("when doctor is ready", rendered)
        self.assertIn("sudo vwctl notification test --smtp", rendered)
        self.assertIn("offsite/rclone recovery is expected", rendered)

    def test_explicit_recipient_public_setup_uses_same_completion_path(self) -> None:
        output = io.StringIO()
        args = ["install"]
        with (
            mock.patch.object(setup_frontend, "_confirm_use_latest", return_value=True),
            mock.patch.object(setup_frontend, "_should_generate", return_value=False),
            mock.patch.object(setup_frontend, "_parse_install_args", return_value=SimpleNamespace(dry_run=False)),
            mock.patch.object(setup_frontend.setup, "main", return_value=0) as setup_main,
            redirect_stdout(output),
        ):
            code = setup_frontend.main(args)

        self.assertEqual(code, 0)
        setup_main.assert_called_once_with(args, defer_next_actions=True)
        rendered = output.getvalue()
        self.assertIn("sudo vwctl config edit && sudo vwctl secrets edit", rendered)
        self.assertIn("sudo vwctl notification test --smtp", rendered)
        self.assertLess(rendered.index("sudo vwctl start"), rendered.index("sudo vwctl doctor after start"))

    def test_public_human_writer_adds_sudo_to_root_only_crowdsec_followups(self) -> None:
        output = io.StringIO()
        writer = operator_output.ColorizingWriter(output, enabled=False)

        writer.write("ACTION: run 'vwctl crowdsec remediation-start' to create one explicit Worker Route invocation\n")
        writer.write(
            "ACTION: set every bouncer-created Worker Route to Fail Open in Cloudflare, "
            "then run 'vwctl crowdsec confirm-fail-open'\n"
        )

        rendered = output.getvalue()
        self.assertIn("run 'sudo vwctl crowdsec remediation-start'", rendered)
        self.assertIn("then run 'sudo vwctl crowdsec confirm-fail-open'", rendered)
        self.assertNotIn("run 'vwctl crowdsec remediation-start'", rendered)
        self.assertNotIn("then run 'vwctl crowdsec confirm-fail-open'", rendered)

    def test_doctor_guidance_rearms_worker_when_only_cloudflare_remediation_failed(self) -> None:
        output = _TTYStringIO()
        checks = [
            DoctorCheck("crowdsec.engine", "PASS", "healthy"),
            DoctorCheck("crowdsec.hub", "PASS", "healthy"),
            DoctorCheck("crowdsec.firewall", "PASS", "healthy"),
            DoctorCheck("crowdsec.cloudflare", "FAIL", "worker is not armed"),
        ]
        with (
            mock.patch.object(operator_entrypoint.cli, "doctor_checks", return_value=checks),
            redirect_stdout(output),
        ):
            operator_entrypoint._completion_guidance(["doctor"], 1)

        rendered = output.getvalue()
        self.assertIn("sudo vwctl crowdsec remediation-start", rendered)
        self.assertIn("sudo vwctl crowdsec confirm-fail-open", rendered)
        self.assertNotIn("sudo vwctl crowdsec setup", rendered)

    def test_doctor_guidance_uses_setup_for_foundational_crowdsec_failure(self) -> None:
        output = _TTYStringIO()
        checks = [
            DoctorCheck("crowdsec.engine", "FAIL", "not active"),
            DoctorCheck("crowdsec.hub", "FAIL", "incomplete"),
            DoctorCheck("crowdsec.firewall", "FAIL", "unhealthy"),
            DoctorCheck("crowdsec.cloudflare", "FAIL", "unhealthy"),
        ]
        with (
            mock.patch.object(operator_entrypoint.cli, "doctor_checks", return_value=checks),
            redirect_stdout(output),
        ):
            operator_entrypoint._completion_guidance(["doctor"], 1)

        rendered = output.getvalue()
        self.assertIn("sudo vwctl crowdsec setup", rendered)

    def test_human_timer_view_explains_target_managed_monotonic_timer(self) -> None:
        output = io.StringIO()
        snapshot = {
            "overall": "PASS",
            "target": {
                "health": "PASS",
                "active_state": "active",
                "enabled": "enabled",
                "problems": [],
            },
            "timers": [
                {
                    "health": "PASS",
                    "unit": "vaultwarden-oci-health.timer",
                    "active_state": "active",
                    "sub_state": "waiting",
                    "enabled": "disabled",
                    "next": None,
                    "last_trigger": "Tue 2026-09-01 22:45:41 UTC",
                    "trigger_active_state": "inactive",
                    "trigger_result": "success",
                    "problems": [],
                }
            ],
        }
        with (
            mock.patch.object(operator_cosmetics.day2, "automation_snapshot", return_value=snapshot),
            redirect_stdout(output),
        ):
            code = operator_cosmetics.timers()

        self.assertEqual(code, 0)
        rendered = output.getvalue()
        self.assertIn("activation=target-managed", rendered)
        self.assertIn("unit-file=disabled", rendered)
        self.assertIn("next=monotonic/systemd-managed", rendered)

    def test_human_status_calls_unconfigured_operational_notifications_what_they_are(self) -> None:
        payload = {
            "notification": {"state": "never", "detail": "no delivery recorded"},
            "doctor": {
                "checks": [
                    {
                        "id": "notification.provider",
                        "status": "SKIP",
                        "message": "operational notifications are not configured",
                    }
                ]
            },
        }

        rendered = operator_cosmetics._human_status_payload(payload)

        self.assertEqual(rendered["notification"]["state"], "not configured")
        self.assertEqual(payload["notification"]["state"], "never")


if __name__ == "__main__":
    unittest.main()
