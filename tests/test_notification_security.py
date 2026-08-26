from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import notification, runtime, secrets

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "email-providers.toml"
_PROVIDER_IDS = ("mailersend", "sendgrid", "mailgun", "postmark", "resend", "cyberpersons")


def config_data(provider: str = "cyberpersons") -> dict[str, object]:
    return {
        "schema_version": 1,
        "site": {"domain": "vault.example.net", "acme_email": "admin@example.net"},
        "secrets": {"offline_recovery_recipient": "age1" + "q" * 58},
        "vaultwarden": {"signups_allowed": False},
        "smtp": {
            "host": "smtp.example.net",
            "port": 587,
            "security": "starttls",
            "from_email": "vaultwarden@example.net",
            "from_name": "Vaultwarden",
            "timeout_seconds": 15,
        },
        "notifications": {"provider": provider, "to_email": "ops@example.net"},
    }


def synthetic_catalog(
    *,
    cyber_retry_body_field: str | None = None,
    cyber_retry_body_unit: str | None = None,
    sendgrid_option: bool = False,
) -> str:
    """Build a complete structural test catalog without editing production TOML text."""
    lines = ["schema_version = 1"]
    for provider_id in _PROVIDER_IDS:
        aliases = '["cyberpanel"]' if provider_id == "cyberpersons" else "[]"
        endpoint = f"https://{provider_id}.example.invalid/send"
        if provider_id == "sendgrid" and sendgrid_option:
            endpoint = "https://{api_host}/v3/mail/send"
        retry_statuses = "[503]" if provider_id == "cyberpersons" else "[]"
        lines.extend(
            [
                "",
                "[[providers]]",
                f'id = "{provider_id}"',
                f"aliases = {aliases}",
                f'display_name = "Synthetic {provider_id}"',
                f'endpoint = "{endpoint}"',
                'auth_mode = "bearer"',
                'encoding = "json"',
                "request_template = '{\"to\":\"{to_email}\"}'",
                "success_statuses = [202]",
                f"retry_statuses = {retry_statuses}",
            ]
        )
        if provider_id == "cyberpersons" and cyber_retry_body_field is not None:
            lines.append(f'retry_body_field = "{cyber_retry_body_field}"')
            if cyber_retry_body_unit is not None:
                lines.append(f'retry_body_unit = "{cyber_retry_body_unit}"')
        if provider_id == "sendgrid" and sendgrid_option:
            lines.extend(
                [
                    "",
                    "[providers.options.region]",
                    'kind = "enum"',
                    'default = "global"',
                    'allowed = ["global", "synthetic"]',
                    "",
                    "[providers.substitutions.api_host]",
                    'option = "region"',
                    'values = { global = "api.sendgrid.com", synthetic = "api.synthetic.invalid" }',
                ]
            )
    return "\n".join(lines) + "\n"


class NotificationSecurityTests(unittest.TestCase):
    def test_operator_config_cannot_override_catalog_transport_mechanics(self) -> None:
        for key, value in (
            ("endpoint", "https://evil.example/send"),
            ("auth_mode", "none"),
            ("auth_header", "X-Evil"),
            ("request_template", "{}"),
            ("success_statuses", [200]),
            ("retry_statuses", [599]),
        ):
            with self.subTest(key=key):
                data = config_data()
                notifications = data["notifications"]
                assert isinstance(notifications, dict)
                notifications[key] = value
                with self.assertRaises(runtime.RuntimeConfigError):
                    runtime.parse_config(data)

    def test_unknown_provider_fails_and_cyberpanel_alias_is_accepted(self) -> None:
        with self.assertRaises(runtime.RuntimeConfigError):
            runtime.parse_config(config_data("unknown-provider"))
        parsed = runtime.parse_config(config_data("cyberpanel"))
        self.assertEqual(parsed.notification_provider, "cyberpanel")
        self.assertEqual(
            notification.load_catalog(CATALOG).resolve(parsed.notification_provider).provider_id,
            "cyberpersons",
        )

    def test_provider_specific_options_cannot_leak_to_other_providers(self) -> None:
        data = config_data("resend")
        notifications = data["notifications"]
        assert isinstance(notifications, dict)
        notifications["options"] = {"region": "eu", "domain": "mg.example.net"}
        with self.assertRaises(runtime.RuntimeConfigError):
            runtime.parse_config(data)

    def test_catalog_declared_option_flows_through_config_and_delivery_without_provider_python(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            catalog_path = Path(directory) / "catalog.toml"
            catalog_path.write_text(synthetic_catalog(sendgrid_option=True), encoding="utf-8")
            catalog = notification.load_catalog(catalog_path)
            data = config_data("sendgrid")
            notifications = data["notifications"]
            assert isinstance(notifications, dict)
            notifications["options"] = {"region": "synthetic"}
            with mock.patch.object(notification, "load_catalog", return_value=catalog):
                parsed = runtime.parse_config(data)
            self.assertEqual(parsed.notification_options, (("region", "synthetic"),))

            endpoints: list[str] = []

            def api(request: notification.RenderedRequest) -> notification.AttemptResult:
                endpoints.append(request.endpoint)
                return notification.AttemptResult(True, False, "accepted", "HTTP 202")

            result = notification.deliver(
                event_id="synthetic-option-test",
                config=parsed,
                secrets={
                    "email_api_token": "api-token",
                    "smtp_username": "smtp-user",
                    "smtp_password": "smtp-password",
                },
                subject="subject",
                text="body",
                catalog=catalog,
                api_sender=api,
                state_path=Path(directory) / "state.json",
            )
        self.assertEqual(endpoints, ["https://api.synthetic.invalid/v3/mail/send"])
        self.assertEqual(result.outcome, "success")

    def test_body_retry_delay_schema_requires_known_unit(self) -> None:
        mutations = (
            synthetic_catalog(cyber_retry_body_field="retry_after"),
            synthetic_catalog(
                cyber_retry_body_field="retry_after",
                cyber_retry_body_unit="fortnights",
            ),
        )
        for text in mutations:
            with self.subTest(text=text[-180:]), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "catalog.toml"
                path.write_text(text, encoding="utf-8")
                with self.assertRaises(notification.CatalogError):
                    notification.load_catalog(path)

    def test_declared_body_retry_delay_is_numeric_bounded_and_malformed_values_are_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.toml"
            path.write_text(
                synthetic_catalog(
                    cyber_retry_body_field="retry_after",
                    cyber_retry_body_unit="seconds",
                ),
                encoding="utf-8",
            )
            provider = notification.load_catalog(path).resolve("cyberpersons")
            bounded = notification._response_result(provider, 503, {}, b'{"retry_after":999}')
            malformed = notification._response_result(provider, 503, {}, b'{"retry_after":"soon"}')
            missing = notification._response_result(provider, 503, {}, b'{}')
        self.assertTrue(bounded.transient)
        self.assertEqual(bounded.retry_after, 5.0)
        self.assertIsNone(malformed.retry_after)
        self.assertIsNone(missing.retry_after)

    def test_current_cyberpersons_catalog_keeps_429_visible_and_body_delay_disabled(self) -> None:
        provider = notification.load_catalog(CATALOG).resolve("cyberpersons")
        self.assertIsNone(provider.retry_body_field)
        self.assertIsNone(provider.retry_body_unit)
        result = notification._response_result(provider, 429, {}, b'{"retry_after":4}')
        self.assertFalse(result.transient)
        self.assertIsNone(result.retry_after)

    def test_email_api_token_is_decrypted_in_memory_but_not_materialized_for_containers(self) -> None:
        self.assertIn("email_api_token", secrets.TRANSIENT_ONLY)
        self.assertNotIn("email_api_token", secrets.REQUIRED)
        self.assertNotIn("email_api_token", secrets.OPTIONAL)


if __name__ == "__main__":
    unittest.main()
