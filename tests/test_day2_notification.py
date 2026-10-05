from __future__ import annotations

import io
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, notification, runtime

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "email-providers.toml"


class NotificationDay2BoundaryTests(unittest.TestCase):
    def config(self, *, notifications: bool = True) -> runtime.RuntimeConfig:
        return runtime.RuntimeConfig(
            domain="vault.example.invalid",
            acme_email="acme@example.invalid",
            offline_recovery_recipient="age1" + "a" * 58,
            signups_allowed=False,
            smtp_host="smtp.example.invalid",
            smtp_port=587,
            smtp_security="starttls",
            smtp_from_email="vault@example.invalid",
            smtp_from_name="Vaultwarden",
            smtp_timeout_seconds=15,
            notification_provider="mailersend" if notifications else None,
            notification_to_email="ops@example.invalid" if notifications else None,
        )

    def test_systemd_notify_skips_unconfigured_route_before_secrets_or_delivery(self) -> None:
        output = io.StringIO()
        with (
            mock.patch("vaultwarden_oci.runtime.load_config", return_value=self.config(notifications=False)),
            mock.patch("vaultwarden_oci.secrets.load") as load_secrets,
            mock.patch("vaultwarden_oci.notification.deliver") as deliver,
            redirect_stdout(output),
        ):
            code = cli.main(["notify", "--event", "vaultwarden-oci-health.service"])
        self.assertEqual(code, 0)
        self.assertEqual(output.getvalue().strip(), "SKIP: operational notifications are not configured")
        load_secrets.assert_not_called()
        deliver.assert_not_called()

    def test_systemd_notify_configured_success_uses_delivery_owner(self) -> None:
        result = notification.DeliveryResult(
            "vaultwarden-oci-health.service",
            "mailersend",
            "https",
            "success",
            "accepted",
            "ok",
            "2026-10-05T00:00:00Z",
        )
        with (
            mock.patch("vaultwarden_oci.runtime.load_config", return_value=self.config()),
            mock.patch("vaultwarden_oci.secrets.load", return_value={"email_api_token": "token"}) as load_secrets,
            mock.patch("vaultwarden_oci.notification.deliver", return_value=result) as deliver,
            redirect_stdout(io.StringIO()),
        ):
            code = cli.main(["notify", "--event", "vaultwarden-oci-health.service"])
        self.assertEqual(code, 0)
        load_secrets.assert_called_once()
        deliver.assert_called_once()
        self.assertEqual(deliver.call_args.kwargs["event_id"], "vaultwarden-oci-health.service")

    def test_systemd_notify_configured_delivery_failure_remains_nonzero(self) -> None:
        result = notification.DeliveryResult(
            "vaultwarden-oci-health.service",
            "mailersend",
            "https",
            "failure",
            "provider_rejected",
            "HTTP 403",
            "2026-10-05T00:00:00Z",
        )
        output = io.StringIO()
        with (
            mock.patch("vaultwarden_oci.runtime.load_config", return_value=self.config()),
            mock.patch("vaultwarden_oci.secrets.load", return_value={"email_api_token": "token"}),
            mock.patch("vaultwarden_oci.notification.deliver", return_value=result) as deliver,
            redirect_stdout(output),
        ):
            code = cli.main(["notify", "--event", "vaultwarden-oci-health.service"])
        self.assertEqual(code, 1)
        self.assertIn("FAIL: operational notification", output.getvalue())
        deliver.assert_called_once()

    def test_systemd_notify_invalid_event_remains_usage_failure(self) -> None:
        error = io.StringIO()
        with (
            mock.patch("vaultwarden_oci.runtime.load_config") as load_config,
            redirect_stderr(error),
        ):
            code = cli.main(["notify", "--event", "../bad event"])
        self.assertEqual(code, 2)
        self.assertIn("bounded systemd event identifier", error.getvalue())
        load_config.assert_not_called()

    def test_explicit_notification_test_still_fails_when_route_is_absent(self) -> None:
        error = io.StringIO()
        with (
            mock.patch("vaultwarden_oci.runtime.load_config", return_value=self.config(notifications=False)),
            mock.patch("vaultwarden_oci.secrets.load", return_value={}) as load_secrets,
            redirect_stderr(error),
        ):
            code = cli.main(["notification", "test"])
        self.assertEqual(code, 1)
        self.assertIn("operational notifications are not configured", error.getvalue())
        load_secrets.assert_called_once()

    def test_notification_doctor_keeps_absent_route_as_skip(self) -> None:
        checks = {
            check.check_id: check
            for check in notification.doctor_checks(
                config=self.config(notifications=False),
                secret_values=None,
                catalog_path=CATALOG,
            )
        }
        self.assertEqual(checks["notification.provider"].status, "SKIP")
        self.assertEqual(checks["notification.api_secret"].status, "SKIP")
        self.assertEqual(checks["notification.smtp_fallback"].status, "SKIP")
        self.assertEqual(
            checks["notification.provider"].message,
            "operational notifications are not configured",
        )

    def test_operational_notification_test_delegates_to_delivery_owner(self) -> None:
        result = notification.DeliveryResult(
            "operator-test", "provider", "https", "success", "accepted", "ok", "2026-08-24T00:00:00Z"
        )
        with (
            mock.patch("vaultwarden_oci.runtime.load_config", return_value=self.config()),
            mock.patch("vaultwarden_oci.secrets.load", return_value={"email_api_token": "token"}),
            mock.patch("vaultwarden_oci.notification.deliver", return_value=result) as deliver,
            redirect_stdout(io.StringIO()),
        ):
            code = cli.main(["notification", "test"])
        self.assertEqual(code, 0)
        deliver.assert_called_once()
        self.assertEqual(deliver.call_args.kwargs["event_id"], "operator-test")

    def test_direct_smtp_test_delegates_to_smtp_owner_and_propagates_failure(self) -> None:
        failed = notification.AttemptResult(False, False, "smtp_failure", "delivery failed")
        with (
            mock.patch("vaultwarden_oci.runtime.load_config", return_value=self.config()),
            mock.patch("vaultwarden_oci.secrets.load", return_value={"smtp_username": "user", "smtp_password": "pass"}),
            mock.patch("vaultwarden_oci.notification.message_context", return_value={"from_header": "Vault <vault@example.invalid>", "from_email": "vault@example.invalid", "to_email": "ops@example.invalid", "subject": "test", "text": "test"}) as context,
            mock.patch("vaultwarden_oci.notification.send_smtp", return_value=failed) as smtp,
            redirect_stdout(io.StringIO()),
        ):
            code = cli.main(["notification", "test", "--smtp"])
        self.assertEqual(code, 1)
        context.assert_called_once()
        smtp.assert_called_once()


if __name__ == "__main__":
    unittest.main()
