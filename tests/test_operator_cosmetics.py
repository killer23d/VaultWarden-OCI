from __future__ import annotations

import io
import unittest
from types import SimpleNamespace
from unittest import mock

from vaultwarden_oci import notification, operator_cosmetics, operator_entrypoint


class OperatorCosmeticsTests(unittest.TestCase):
    def _healthy_payload(self) -> dict[str, object]:
        return {
            "runtime": {"overall": "running", "services": []},
            "doctor": {"overall": "WARN"},
            "automation": {"overall": "FAIL"},
            "notification": {"state": "never"},
            "edge": {"checks": [{"status": "PASS"}]},
        }

    def test_status_reuses_authoritative_day2_payload_and_dashboard_renderer(self) -> None:
        payload = self._healthy_payload()
        with (
            mock.patch.object(operator_cosmetics.day2, "status_payload", return_value=payload),
            mock.patch.object(operator_cosmetics.dashboard, "draw_header") as header,
            mock.patch.object(operator_cosmetics.dashboard, "draw_status") as status,
        ):
            code = operator_cosmetics.status()
        self.assertEqual(code, 0)
        header.assert_called_once_with(payload)
        status.assert_called_once_with(payload)

    def test_status_preserves_existing_human_health_boundary(self) -> None:
        payload = self._healthy_payload()
        payload["doctor"] = {"overall": "FAIL"}
        payload["automation"] = {"overall": "FAIL"}
        self.assertEqual(operator_cosmetics._status_exit_code(payload), 0)

        payload["notification"] = {"state": "failure"}
        self.assertEqual(operator_cosmetics._status_exit_code(payload), 1)

        payload["notification"] = {"state": "never"}
        payload["edge"] = {"checks": [{"status": "FAIL"}]}
        self.assertEqual(operator_cosmetics._status_exit_code(payload), 1)

        payload["edge"] = {"checks": [{"status": "PASS"}]}
        payload["runtime"] = {"overall": "degraded", "services": []}
        self.assertEqual(operator_cosmetics._status_exit_code(payload), 1)

    def test_json_status_keeps_machine_owner(self) -> None:
        self.assertIsNone(operator_entrypoint._cosmetic_override(["status", "--json"]))

    def test_captured_human_status_keeps_stable_cli_owner(self) -> None:
        stream = SimpleNamespace(isatty=lambda: False)
        with (
            mock.patch.object(operator_entrypoint.sys, "stdout", stream),
            mock.patch.object(operator_cosmetics, "status", return_value=0) as status,
        ):
            self.assertIsNone(operator_entrypoint._cosmetic_override(["status"]))
        status.assert_not_called()

    def test_notification_body_restores_operator_context(self) -> None:
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

    def test_operational_test_labels_actual_api_and_fallback_transport(self) -> None:
        config = SimpleNamespace(
            notification_provider="mailgun",
            notification_to_email="ops@example.test",
            acme_email="admin@example.test",
            smtp_from_email="vault@example.test",
            smtp_from_name="Vaultwarden",
        )
        values = {"email_api_token": "secret", "smtp_username": "u", "smtp_password": "p"}
        delivered = notification.DeliveryResult(
            "operator-test", "mailgun", "https", "success", "accepted", "ok", "2026-09-01T17:30:00Z"
        )
        accepted = notification.AttemptResult(True, False, "accepted", "ok")
        with (
            mock.patch.object(operator_cosmetics, "_load_mail", return_value=(config, values)),
            mock.patch.object(operator_cosmetics, "_sent_at", return_value="2026-09-01T10:30:00-07:00"),
            mock.patch.object(operator_cosmetics, "_host", return_value="vault.example.test"),
            mock.patch.object(operator_cosmetics.notification, "deliver", return_value=delivered) as deliver,
            mock.patch("sys.stdout", new_callable=io.StringIO),
        ):
            code = operator_cosmetics.notification_test(smtp_only=False)
        self.assertEqual(code, 0)
        kwargs = deliver.call_args.kwargs
        self.assertIn("Transport: HTTPS API (Mailgun)", kwargs["text"])

        context = notification.message_context(
            from_email=config.smtp_from_email,
            from_name=config.smtp_from_name,
            to_email=config.notification_to_email,
            subject="fallback test",
            text=kwargs["text"],
        )
        with mock.patch.object(operator_cosmetics.notification, "send_smtp", return_value=accepted) as sender:
            result = kwargs["smtp_sender"](config=config, secrets=values, context=context)
        self.assertTrue(result.ok)
        fallback_context = sender.call_args.kwargs["context"]
        self.assertIn(
            "Transport: authenticated SMTP fallback (after Mailgun API transient failure)",
            fallback_context["text"],
        )
        self.assertIn("Transport: HTTPS API (Mailgun)", context["text"])

    def test_operator_entrypoint_notify_skips_unconfigured_before_secrets_or_delivery(self) -> None:
        config = SimpleNamespace(
            notification_provider=None,
            offline_recovery_recipient="age1" + "a" * 58,
        )
        output = io.StringIO()
        with (
            mock.patch.object(operator_cosmetics.storage, "verify") as verify_storage,
            mock.patch.object(operator_cosmetics.runtime, "load_config", return_value=config) as load_config,
            mock.patch.object(operator_cosmetics.secrets, "load") as load_secrets,
            mock.patch.object(operator_cosmetics, "_deliver_with_transport_context") as deliver,
            mock.patch.object(operator_entrypoint.sys, "stdout", output),
        ):
            code = operator_entrypoint.main(
                ["notify", "--event", "vaultwarden-oci-health.service"]
            )
        self.assertEqual(code, 0)
        self.assertIn(
            "SKIP: operational notifications are not configured",
            output.getvalue(),
        )
        verify_storage.assert_called_once_with()
        load_config.assert_called_once_with()
        load_secrets.assert_not_called()
        deliver.assert_not_called()

    def test_operator_entrypoint_notify_configured_success_preserves_delivery_owner(self) -> None:
        config = SimpleNamespace(
            notification_provider="mailgun",
            offline_recovery_recipient="age1" + "a" * 58,
        )
        result = notification.DeliveryResult(
            "vaultwarden-oci-health.service",
            "mailgun",
            "https",
            "success",
            "accepted",
            "ok",
            "2026-10-05T23:30:00Z",
        )
        with (
            mock.patch.object(operator_cosmetics.storage, "verify"),
            mock.patch.object(operator_cosmetics.runtime, "load_config", return_value=config),
            mock.patch.object(operator_cosmetics.secrets, "load", return_value={"email_api_token": "token"}) as load_secrets,
            mock.patch.object(operator_cosmetics, "_host", return_value="vault.example.test"),
            mock.patch.object(operator_cosmetics, "_deliver_with_transport_context", return_value=result) as deliver,
            mock.patch.object(operator_entrypoint.sys, "stdout", io.StringIO()),
        ):
            code = operator_entrypoint.main(
                ["notify", "--event", "vaultwarden-oci-health.service"]
            )
        self.assertEqual(code, 0)
        load_secrets.assert_called_once_with(config.offline_recovery_recipient)
        deliver.assert_called_once()
        self.assertEqual(
            deliver.call_args.kwargs["event_id"],
            "vaultwarden-oci-health.service",
        )

    def test_operator_entrypoint_notify_configured_failure_remains_nonzero(self) -> None:
        config = SimpleNamespace(
            notification_provider="mailgun",
            offline_recovery_recipient="age1" + "a" * 58,
        )
        error = io.StringIO()
        with (
            mock.patch.object(operator_cosmetics.storage, "verify"),
            mock.patch.object(operator_cosmetics.runtime, "load_config", return_value=config),
            mock.patch.object(operator_cosmetics.secrets, "load", return_value={"email_api_token": "token"}),
            mock.patch.object(
                operator_cosmetics,
                "_deliver_with_transport_context",
                side_effect=notification.NotificationError("provider rejected request"),
            ) as deliver,
            mock.patch.object(operator_entrypoint.sys, "stderr", error),
        ):
            code = operator_entrypoint.main(
                ["notify", "--event", "vaultwarden-oci-health.service"]
            )
        self.assertEqual(code, 1)
        self.assertIn("provider rejected request", error.getvalue())
        deliver.assert_called_once()

    def test_operator_entrypoint_notify_invalid_event_stays_usage_failure(self) -> None:
        error = io.StringIO()
        with (
            mock.patch.object(operator_cosmetics.runtime, "load_config") as load_config,
            mock.patch.object(operator_entrypoint.sys, "stderr", error),
        ):
            code = operator_entrypoint.main(["notify", "--event", "../bad event"])
        self.assertEqual(code, 2)
        self.assertIn("bounded systemd event identifier", error.getvalue())
        load_config.assert_not_called()

    def test_operator_entrypoint_notification_test_absent_route_stays_failure(self) -> None:
        config = SimpleNamespace(
            notification_provider=None,
            notification_to_email=None,
            acme_email="admin@example.test",
            smtp_from_email="vault@example.test",
            smtp_from_name="Vaultwarden",
        )
        error = io.StringIO()
        with (
            mock.patch.object(operator_cosmetics, "_load_mail", return_value=(config, {})),
            mock.patch.object(operator_entrypoint.sys, "stderr", error),
        ):
            code = operator_entrypoint.main(["notification", "test"])
        self.assertEqual(code, 1)
        self.assertIn("operational notifications are not configured", error.getvalue())

    def test_cosmetic_override_routes_supported_human_surfaces_only(self) -> None:
        stream = SimpleNamespace(isatty=lambda: True)
        with (
            mock.patch.object(operator_entrypoint.sys, "stdout", stream),
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
