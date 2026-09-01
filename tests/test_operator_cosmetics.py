from __future__ import annotations

import io
import unittest
from types import SimpleNamespace
from unittest import mock

from vaultwarden_oci import notification, operator_cosmetics, operator_entrypoint


class OperatorCosmeticsTests(unittest.TestCase):
    def test_status_reuses_authoritative_day2_payload_and_dashboard_renderer(self) -> None:
        payload = {
            "doctor": {"overall": "WARN"},
            "automation": {"overall": "PASS"},
        }
        with (
            mock.patch.object(operator_cosmetics.day2, "status_payload", return_value=payload),
            mock.patch.object(operator_cosmetics.dashboard, "draw_header") as header,
            mock.patch.object(operator_cosmetics.dashboard, "draw_status") as status,
        ):
            code = operator_cosmetics.status()
        self.assertEqual(code, 0)
        header.assert_called_once_with(payload)
        status.assert_called_once_with(payload)

    def test_status_failure_exit_is_preserved(self) -> None:
        payload = {
            "doctor": {"overall": "FAIL"},
            "automation": {"overall": "PASS"},
        }
        with (
            mock.patch.object(operator_cosmetics.day2, "status_payload", return_value=payload),
            mock.patch.object(operator_cosmetics.dashboard, "draw_header"),
            mock.patch.object(operator_cosmetics.dashboard, "draw_status"),
        ):
            self.assertEqual(operator_cosmetics.status(), 1)

    def test_json_status_keeps_machine_owner(self) -> None:
        self.assertIsNone(operator_entrypoint._cosmetic_override(["status", "--json"]))

    def test_notification_body_restores_v1_operator_context(self) -> None:
        with (
            mock.patch.object(operator_cosmetics, "_sent_at", return_value="2026-09-01T10:30:00-07:00"),
            mock.patch.object(operator_cosmetics, "_host", return_value="vault.example.test"),
        ):
            body = operator_cosmetics._notification_body(
                service="vaultwarden-oci-health.service",
                event="systemd OnFailure",
                transport="configured operational route",
                summary="The service failed.",
                checks=("systemctl status 'vaultwarden-oci-health.service'",),
            )
        self.assertIn("Service: vaultwarden-oci-health.service", body)
        self.assertIn("Event: systemd OnFailure", body)
        self.assertIn("Transport: configured operational route", body)
        self.assertIn("Date/Time: 2026-09-01T10:30:00-07:00", body)
        self.assertIn("Host: vault.example.test", body)
        self.assertIn("Suggested checks:", body)

    def test_direct_smtp_test_uses_rich_body_without_changing_transport_owner(self) -> None:
        config = SimpleNamespace(
            notification_to_email="ops@example.test",
            acme_email="admin@example.test",
            smtp_from_email="vault@example.test",
            smtp_from_name="Vaultwarden",
        )
        accepted = notification.AttemptResult(True, False, "accepted", "ok")
        with (
            mock.patch.object(operator_cosmetics, "_load_mail", return_value=(config, {"smtp_username": "u", "smtp_password": "p"})),
            mock.patch.object(operator_cosmetics, "_sent_at", return_value="2026-09-01T10:30:00-07:00"),
            mock.patch.object(operator_cosmetics, "_host", return_value="vault.example.test"),
            mock.patch.object(operator_cosmetics.notification, "send_smtp", return_value=accepted) as sender,
            mock.patch("sys.stdout", new_callable=io.StringIO),
        ):
            code = operator_cosmetics.notification_test(smtp_only=True)
        self.assertEqual(code, 0)
        context = sender.call_args.kwargs["context"]
        self.assertIn("Service: VaultWarden-OCI notification", context["text"])
        self.assertIn("Transport: direct authenticated SMTP", context["text"])
        self.assertIn("Date/Time: 2026-09-01T10:30:00-07:00", context["text"])
        self.assertIn("Host: vault.example.test", context["text"])

    def test_cosmetic_override_routes_supported_human_surfaces_only(self) -> None:
        with (
            mock.patch.object(operator_cosmetics, "status", return_value=0) as status,
            mock.patch.object(operator_cosmetics, "notification_test", return_value=0) as notification_test,
            mock.patch.object(operator_cosmetics, "notify_failure", return_value=0) as notify_failure,
        ):
            self.assertEqual(operator_entrypoint._cosmetic_override(["status"]), 0)
            self.assertEqual(operator_entrypoint._cosmetic_override(["notification", "test", "--smtp"]), 0)
            self.assertEqual(operator_entrypoint._cosmetic_override(["notify", "--event", "example.service"]), 0)
        status.assert_called_once_with()
        notification_test.assert_called_once_with(smtp_only=True)
        notify_failure.assert_called_once_with("example.service")


if __name__ == "__main__":
    unittest.main()
