from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import notification, recovery_ux, runtime


class RecoverySMTPAttachmentTests(unittest.TestCase):
    def config(self) -> runtime.RuntimeConfig:
        return runtime.RuntimeConfig(
            domain="vault.example.org",
            acme_email="acme@example.org",
            offline_recovery_recipient="age1" + "q" * 58,
            signups_allowed=False,
            smtp_host="smtp.example.org",
            smtp_port=587,
            smtp_security="starttls",
            smtp_from_email="ops@example.org",
            smtp_from_name="VaultWarden OCI",
            smtp_timeout_seconds=10,
            notification_provider="cyberpersons",
            notification_to_email="admin@example.org",
        )

    def secrets(self) -> dict[str, str]:
        return {"smtp_username": "smtp-user", "smtp_password": "smtp-password"}

    def test_notification_owner_builds_attachment_then_uses_shared_smtp_transport(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "kit.zip"
            archive.write_bytes(b"verified encrypted zip bytes")
            accepted = notification.AttemptResult(True, False, "accepted", "smtp accepted")
            with mock.patch.object(notification, "_smtp_send_message", return_value=accepted) as transport:
                result = notification.send_smtp_attachment(
                    config=self.config(),
                    secrets=self.secrets(),
                    to_email="admin@example.org",
                    subject="Verified recovery kit",
                    text="The passphrase is not included.",
                    attachment=archive,
                )
            self.assertTrue(result.ok)
            transport.assert_called_once()
            message = transport.call_args.kwargs["message"]
            attachments = list(message.iter_attachments())
            self.assertEqual(len(attachments), 1)
            self.assertEqual(attachments[0].get_filename(), "kit.zip")
            self.assertEqual(attachments[0].get_content_type(), "application/zip")
            self.assertEqual(attachments[0].get_payload(decode=True), b"verified encrypted zip bytes")

    def test_recovery_layer_delegates_to_notification_attachment_owner(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "kit.zip"
            archive.write_bytes(b"verified encrypted zip bytes")
            accepted = notification.AttemptResult(True, False, "accepted", "smtp accepted")
            with mock.patch.object(notification, "send_smtp_attachment", return_value=accepted) as sender:
                recovery_ux._smtp_attachment(
                    config=self.config(),
                    values=self.secrets(),
                    archive=archive,
                    recipient="admin@example.org",
                )
            sender.assert_called_once()
            self.assertEqual(sender.call_args.kwargs["attachment"], archive)
            self.assertEqual(sender.call_args.kwargs["to_email"], "admin@example.org")

    def test_recovery_layer_surfaces_notification_smtp_failure_without_secret_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "kit.zip"
            archive.write_bytes(b"verified encrypted zip bytes")
            failed = notification.AttemptResult(False, False, "smtp_failure", "authenticated SMTP delivery failed")
            with (
                mock.patch.object(notification, "send_smtp_attachment", return_value=failed),
                self.assertRaisesRegex(recovery_ux.RecoveryUXError, "smtp_failure"),
            ):
                recovery_ux._smtp_attachment(
                    config=self.config(),
                    values=self.secrets(),
                    archive=archive,
                    recipient="admin@example.org",
                )


if __name__ == "__main__":
    unittest.main()
