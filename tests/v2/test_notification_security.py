from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import notification, runtime, secrets

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "email-providers.toml"


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
        self.assertEqual(notification.load_catalog(CATALOG).resolve(parsed.notification_provider).provider_id, "cyberpersons")

    def test_provider_specific_options_cannot_leak_to_other_providers(self) -> None:
        data = config_data("resend")
        notifications = data["notifications"]
        assert isinstance(notifications, dict)
        notifications["mailgun_region"] = "eu"
        notifications["mailgun_domain"] = "mg.example.net"
        with self.assertRaises(runtime.RuntimeConfigError):
            runtime.parse_config(data)

    def test_body_retry_delay_schema_requires_known_unit(self) -> None:
        original = CATALOG.read_text(encoding="utf-8")
        marker = "retry_statuses = [429, 503]\n"
        self.assertIn(marker, original)
        mutations = (
            original.replace(marker, marker + 'retry_body_field = "retry_after"\n', 1),
            original.replace(
                marker,
                marker + 'retry_body_field = "retry_after"\nretry_body_unit = "fortnights"\n',
                1,
            ),
        )
        for text in mutations:
            with self.subTest(text=text[-180:]), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "catalog.toml"
                path.write_text(text, encoding="utf-8")
                with self.assertRaises(notification.CatalogError):
                    notification.load_catalog(path)

    def test_declared_body_retry_delay_is_numeric_bounded_and_malformed_values_are_ignored(self) -> None:
        original = CATALOG.read_text(encoding="utf-8")
        marker = "retry_statuses = [429, 503]\n"
        text = original.replace(
            marker,
            marker + 'retry_body_field = "retry_after"\nretry_body_unit = "seconds"\n',
            1,
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.toml"
            path.write_text(text, encoding="utf-8")
            provider = notification.load_catalog(path).resolve("cyberpersons")
            bounded = notification._response_result(provider, 429, {}, b'{"retry_after":999}')
            malformed = notification._response_result(provider, 429, {}, b'{"retry_after":"soon"}')
            missing = notification._response_result(provider, 429, {}, b'{}')
        self.assertTrue(bounded.transient)
        self.assertEqual(bounded.retry_after, 5.0)
        self.assertIsNone(malformed.retry_after)
        self.assertIsNone(missing.retry_after)

    def test_current_cyberpersons_catalog_does_not_enable_undocumented_body_delay_units(self) -> None:
        provider = notification.load_catalog(CATALOG).resolve("cyberpersons")
        self.assertIsNone(provider.retry_body_field)
        self.assertIsNone(provider.retry_body_unit)
        result = notification._response_result(provider, 429, {}, b'{"retry_after":4}')
        self.assertTrue(result.transient)
        self.assertIsNone(result.retry_after)

    def test_email_api_token_is_decrypted_in_memory_but_not_materialized_for_containers(self) -> None:
        self.assertIn("email_api_token", secrets.TRANSIENT_ONLY)
        self.assertNotIn("email_api_token", secrets.REQUIRED)
        self.assertNotIn("email_api_token", secrets.OPTIONAL)


if __name__ == "__main__":
    unittest.main()
