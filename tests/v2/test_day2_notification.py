from __future__ import annotations

import io
import unittest
from contextlib import redirect_stdout
from unittest import mock

from vaultwarden_oci import cli, notification


class NotificationDay2BoundaryTests(unittest.TestCase):
    def config(self):
        return mock.Mock(
            offline_recovery_recipient="age1" + "a" * 58,
            notification_to_email="ops@example.invalid",
            acme_email="acme@example.invalid",
            smtp_from_email="vault@example.invalid",
            smtp_from_name="Vaultwarden",
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
