from __future__ import annotations

import json
import ssl
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import notification, runtime

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "email-providers.toml"


def context() -> dict[str, str]:
    return notification.message_context(
        from_email="ops@example.net",
        from_name="VaultWarden OCI",
        to_email="admin@example.org",
        subject="test subject",
        text="test body",
    )


class NotificationCatalogTests(unittest.TestCase):
    def setUp(self) -> None:
        self.catalog = notification.load_catalog(CATALOG)

    def rendered(self, provider: str, **options: str) -> notification.RenderedRequest:
        return notification.render_request(
            self.catalog.resolve(provider),
            context=context(),
            token="secret-token-value",
            options=options,
        )

    def test_catalog_has_exact_canonical_provider_set_and_alias(self) -> None:
        self.assertEqual(
            set(self.catalog.providers),
            {"mailersend", "sendgrid", "mailgun", "postmark", "resend", "cyberpersons"},
        )
        self.assertEqual(self.catalog.aliases, {"cyberpanel": "cyberpersons"})
        self.assertIs(self.catalog.resolve("cyberpanel"), self.catalog.resolve("cyberpersons"))

    def test_canonical_message_vocabulary_is_exact(self) -> None:
        self.assertEqual(
            set(context()),
            {"from_email", "from_name", "from_header", "to_email", "subject", "text"},
        )
        with self.assertRaises(notification.NotificationError):
            notification.render_request(
                self.catalog.resolve("mailersend"),
                context={**context(), "to": "admin@example.org"},
                token="token",
            )

    def test_mailersend_renders_bearer_json_and_202_success(self) -> None:
        request = self.rendered("mailersend")
        self.assertEqual(request.endpoint, "https://api.mailersend.com/v1/email")
        self.assertEqual(request.headers["Authorization"], "Bearer secret-token-value")
        payload = json.loads(request.body)
        self.assertEqual(payload["from"], {"email": "ops@example.net", "name": "VaultWarden OCI"})
        self.assertEqual(payload["to"], [{"email": "admin@example.org"}])
        self.assertTrue(notification._response_result(request.provider, 202, {}, b"").ok)
        self.assertFalse(notification._response_result(request.provider, 429, {}, b"{}").transient)
        self.assertTrue(notification._response_result(request.provider, 421, {}, b"{}").transient)

    def test_sendgrid_renders_bearer_json_and_202_success(self) -> None:
        request = self.rendered("sendgrid")
        payload = json.loads(request.body)
        self.assertEqual(request.headers["Authorization"], "Bearer secret-token-value")
        self.assertEqual(payload["personalizations"][0]["to"][0]["email"], "admin@example.org")
        self.assertEqual(payload["content"][0], {"type": "text/plain", "value": "test body"})
        self.assertTrue(notification._response_result(request.provider, 202, {}, b"").ok)
        self.assertTrue(notification._response_result(request.provider, 429, {}, b"{}").transient)

    def test_mailgun_renders_region_domain_basic_auth_and_form(self) -> None:
        request = self.rendered("mailgun", region="eu", domain="mg.example.org")
        self.assertEqual(request.endpoint, "https://api.eu.mailgun.net/v3/mg.example.org/messages")
        self.assertTrue(request.headers["Authorization"].startswith("Basic "))
        self.assertTrue(request.headers["Content-Type"].startswith("multipart/form-data; boundary="))
        body = request.body.decode("utf-8")
        self.assertIn('name="from"', body)
        self.assertIn("VaultWarden OCI <ops@example.net>", body)
        self.assertIn('name="to"', body)
        self.assertTrue(notification._response_result(request.provider, 200, {}, b"{}").ok)
        self.assertTrue(notification._response_result(request.provider, 429, {}, b"{}").transient)
        self.assertTrue(notification._response_result(request.provider, 500, {}, b"{}").transient)

    def test_postmark_renders_fixed_header_and_success_rule(self) -> None:
        request = self.rendered("postmark")
        self.assertEqual(request.headers["X-Postmark-Server-Token"], "secret-token-value")
        payload = json.loads(request.body)
        self.assertEqual(payload["From"], "VaultWarden OCI <ops@example.net>")
        self.assertEqual(payload["MessageStream"], "outbound")
        self.assertTrue(notification._response_result(request.provider, 200, {}, b'{"ErrorCode":0}').ok)
        self.assertFalse(notification._response_result(request.provider, 200, {}, b'{"ErrorCode":10}').transient)
        self.assertTrue(notification._response_result(request.provider, 503, {}, b"{}").transient)

    def test_resend_renders_bearer_json_and_keeps_429_quota_ambiguous_visible(self) -> None:
        request = self.rendered("resend")
        payload = json.loads(request.body)
        self.assertEqual(payload["from"], "VaultWarden OCI <ops@example.net>")
        self.assertEqual(payload["to"], ["admin@example.org"])
        self.assertTrue(notification._response_result(request.provider, 200, {}, b"{}").ok)
        self.assertFalse(notification._response_result(request.provider, 429, {}, b"{}").transient)
        self.assertTrue(notification._response_result(request.provider, 500, {}, b"{}").transient)

    def test_cyberpersons_exact_success_and_retry_contract(self) -> None:
        request = self.rendered("cyberpanel")
        self.assertEqual(request.provider.provider_id, "cyberpersons")
        self.assertEqual(request.endpoint, "https://platform.cyberpersons.com/email/v1/send")
        payload = json.loads(request.body)
        self.assertEqual(
            payload,
            {"from": "ops@example.net", "to": "admin@example.org", "subject": "test subject", "text": "test body"},
        )
        self.assertTrue(notification._response_result(request.provider, 202, {}, b'{"success":true}').ok)
        self.assertFalse(notification._response_result(request.provider, 202, {}, b'{"success":false}').transient)
        self.assertTrue(notification._response_result(request.provider, 429, {}, b'{"retry_after":2}').transient)
        self.assertTrue(notification._response_result(request.provider, 503, {}, b'{}').transient)
        for status in (400, 403, 500):
            with self.subTest(status=status):
                result = notification._response_result(request.provider, status, {}, b'{"error":"send_failed"}')
                self.assertFalse(result.transient)

    def test_catalog_rejects_unknown_fields_placeholders_non_https_and_duplicates(self) -> None:
        text = CATALOG.read_text(encoding="utf-8")
        mutations = (
            text.replace('display_name = "MailerSend"', 'display_name = "MailerSend"\nunknown = true', 1),
            text.replace('"subject":"{subject}"', '"subject":"{to}"', 1),
            text.replace("https://api.mailersend.com", "http://api.mailersend.com", 1),
            text.replace('id = "sendgrid"', 'id = "mailersend"', 1),
        )
        for mutated in mutations:
            with self.subTest(mutated=mutated[:80]):
                with tempfile.TemporaryDirectory() as directory:
                    path = Path(directory) / "catalog.toml"
                    path.write_text(mutated, encoding="utf-8")
                    with self.assertRaises(notification.CatalogError):
                        notification.load_catalog(path)

    def test_mailgun_options_are_closed_and_validated(self) -> None:
        provider = self.catalog.resolve("mailgun")
        with self.assertRaises(notification.CatalogError):
            notification.validate_provider_options(provider, {"region": "ap", "domain": "mg.example.org"})
        with self.assertRaises(notification.CatalogError):
            notification.validate_provider_options(provider, {"region": "us", "domain": "bad/domain"})
        with self.assertRaises(notification.CatalogError):
            notification.validate_provider_options(
                provider,
                {"region": "us", "domain": "mg.example.org", "endpoint": "https://evil.example"},
            )

    def test_retry_after_is_bounded_and_malformed_values_fall_back(self) -> None:
        self.assertEqual(notification._retry_after({"Retry-After": "999"}), 5.0)
        self.assertIsNone(notification._retry_after({"Retry-After": "not-a-delay"}))

    def test_authorized_requests_reject_redirects(self) -> None:
        handler = notification._NoRedirect()
        self.assertIsNone(handler.redirect_request(None, None, 302, "Found", {}, "https://evil.example"))


class NotificationDeliveryTests(unittest.TestCase):
    def config(self) -> runtime.RuntimeConfig:
        return runtime.RuntimeConfig(
            domain="vault.example.org",
            acme_email="acme@example.org",
            offline_recovery_recipient="age1" + "q" * 58,
            signups_allowed=False,
            smtp_host="smtp.example.org",
            smtp_port=587,
            smtp_security="starttls",
            smtp_from_email="ops@example.net",
            smtp_from_name="VaultWarden OCI",
            smtp_timeout_seconds=10,
            notification_provider="cyberpersons",
            notification_to_email="admin@example.org",
        )

    def secrets(self) -> dict[str, str]:
        return {
            "email_api_token": "api-secret-value",
            "smtp_username": "smtp-user",
            "smtp_password": "smtp-secret-value",
        }

    def test_api_success_stops_without_smtp(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            smtp = mock.Mock()
            result = notification.deliver(
                event_id="health.service",
                config=self.config(),
                secrets=self.secrets(),
                subject="subject",
                text="body",
                catalog=notification.load_catalog(CATALOG),
                api_sender=lambda _: notification.AttemptResult(True, False, "accepted", "HTTP 202"),
                smtp_sender=smtp,
                state_path=Path(directory) / "state.json",
            )
            self.assertEqual(result.transport, "https")
            smtp.assert_not_called()

    def test_transient_api_failure_falls_back_only_after_bounded_retry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            attempts = []
            smtp = mock.Mock(return_value=notification.AttemptResult(True, False, "accepted", "smtp accepted"))

            def api(_: notification.RenderedRequest) -> notification.AttemptResult:
                attempts.append(1)
                return notification.AttemptResult(False, True, "provider_transient", "HTTP 503")

            result = notification.deliver(
                event_id="backup.service",
                config=self.config(),
                secrets=self.secrets(),
                subject="subject",
                text="body",
                catalog=notification.load_catalog(CATALOG),
                api_sender=api,
                smtp_sender=smtp,
                state_path=Path(directory) / "state.json",
            )
            self.assertEqual(len(attempts), 3)
            self.assertEqual(result.transport, "smtp_fallback")
            smtp.assert_called_once()

    def test_permanent_or_ambiguous_failure_does_not_get_masked(self) -> None:
        for category in ("provider_rejected", "tls_verification", "ambiguous_response"):
            with self.subTest(category=category), tempfile.TemporaryDirectory() as directory:
                smtp = mock.Mock()
                result = notification.deliver(
                    event_id="maintenance.service",
                    config=self.config(),
                    secrets=self.secrets(),
                    subject="subject",
                    text="body",
                    catalog=notification.load_catalog(CATALOG),
                    api_sender=lambda _: notification.AttemptResult(False, False, category, "safe failure"),
                    smtp_sender=smtp,
                    state_path=Path(directory) / "state.json",
                )
                self.assertEqual(result.outcome, "failure")
                self.assertEqual(result.transport, "https")
                smtp.assert_not_called()

    def test_persisted_result_is_small_and_secret_free(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            notification.deliver(
                event_id="health.service",
                config=self.config(),
                secrets=self.secrets(),
                subject="secret-ish subject that must not be persisted",
                text="message body that must not be persisted",
                catalog=notification.load_catalog(CATALOG),
                api_sender=lambda _: notification.AttemptResult(False, False, "provider_rejected", "HTTP 403"),
                state_path=state,
            )
            persisted = state.read_text(encoding="utf-8")
            self.assertNotIn("api-secret-value", persisted)
            self.assertNotIn("smtp-secret-value", persisted)
            self.assertNotIn("secret-ish subject", persisted)
            self.assertNotIn("message body", persisted)
            self.assertLess(len(persisted), 1000)

    def test_smtp_starttls_and_implicit_tls_use_default_context_and_auth(self) -> None:
        class FakeSMTP:
            instances = []

            def __init__(self, *args, **kwargs):
                self.args = args
                self.kwargs = kwargs
                self.calls = []
                FakeSMTP.instances.append(self)

            def ehlo(self): self.calls.append(("ehlo",))
            def starttls(self, *, context): self.calls.append(("starttls", context))
            def login(self, username, password): self.calls.append(("login", username, password))
            def send_message(self, *args, **kwargs): self.calls.append(("send_message",))
            def quit(self): self.calls.append(("quit",))

        with mock.patch.object(notification.smtplib, "SMTP", FakeSMTP), mock.patch.object(notification.smtplib, "SMTP_SSL", FakeSMTP):
            result = notification.send_smtp(config=self.config(), secrets=self.secrets(), context=context())
            self.assertTrue(result.ok)
            self.assertTrue(any(call[0] == "starttls" and isinstance(call[1], ssl.SSLContext) for call in FakeSMTP.instances[-1].calls))
            self.assertIn(("login", "smtp-user", "smtp-secret-value"), FakeSMTP.instances[-1].calls)

            implicit = self.config().__class__(**{**self.config().__dict__, "smtp_security": "force_tls", "smtp_port": 465})
            result = notification.send_smtp(config=implicit, secrets=self.secrets(), context=context())
            self.assertTrue(result.ok)
            self.assertIsInstance(FakeSMTP.instances[-1].kwargs["context"], ssl.SSLContext)
            self.assertFalse(any(call[0] == "starttls" for call in FakeSMTP.instances[-1].calls))


class SystemdSurfaceTests(unittest.TestCase):
    def test_units_use_installed_current_vwctl_and_no_wrapper_scripts(self) -> None:
        unit_dir = ROOT / "systemd-v2"
        names = {path.name for path in unit_dir.iterdir() if path.is_file()}
        self.assertEqual(
            names,
            {
                "vaultwarden-oci.target",
                "vaultwarden-oci.service",
                "vaultwarden-oci-health.service",
                "vaultwarden-oci-health.timer",
                "vaultwarden-oci-backup.service",
                "vaultwarden-oci-backup.timer",
                "vaultwarden-oci-maintenance.service",
                "vaultwarden-oci-maintenance.timer",
                "vaultwarden-oci-notify@.service",
            },
        )
        for path in unit_dir.glob("*.service"):
            text = path.read_text(encoding="utf-8")
            self.assertIn("/opt/vaultwarden-oci/current/vwctl", text)
            self.assertNotIn("/workspaces/", text)
            self.assertNotIn("/opt/vaultwarden-scripts", text)


if __name__ == "__main__":
    unittest.main()
