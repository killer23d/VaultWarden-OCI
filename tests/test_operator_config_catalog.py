from __future__ import annotations

import builtins
import json
import tempfile
import tomllib
import unittest
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from vaultwarden_oci import operator_entrypoint, operator_settings, runtime, setup

OFFLINE = "age1" + "q" * 58

# Verified against the exact pinned Vaultwarden 1.37.1 configuration surface.
# Curated additions must exist in that binary before they are exposed as an
# appliance-supported setting.
PINNED_VAULTWARDEN_1371_ENV = {
    "SIGNUPS_ALLOWED",
    "SIGNUPS_VERIFY",
    "SIGNUPS_VERIFY_RESEND_TIME",
    "SIGNUPS_VERIFY_RESEND_LIMIT",
    "SENDS_ALLOWED",
    "INVITATIONS_ALLOWED",
    "INVITATION_ORG_NAME",
    "INVITATION_EXPIRATION_HOURS",
    "EMERGENCY_ACCESS_ALLOWED",
    "EMAIL_CHANGE_ALLOWED",
    "ORG_EVENTS_ENABLED",
    "ORG_CREATION_USERS",
    "INCOMPLETE_2FA_TIME_LIMIT",
    "PASSWORD_ITERATIONS",
    "PASSWORD_HINTS_ALLOWED",
    "SHOW_PASSWORD_HINT",
    "REQUIRE_DEVICE_EMAIL",
    "EMAIL_TOKEN_SIZE",
    "EMAIL_EXPIRATION_TIME",
    "EMAIL_ATTEMPTS_LIMIT",
    "EMAIL_2FA_ENFORCE_ON_VERIFIED_INVITE",
    "EMAIL_2FA_AUTO_FALLBACK",
    "ADMIN_RATELIMIT_SECONDS",
    "ADMIN_RATELIMIT_MAX_BURST",
    "ADMIN_SESSION_LIFETIME",
    "LOGIN_RATELIMIT_SECONDS",
    "LOGIN_RATELIMIT_MAX_BURST",
    "UNAUTHENTICATED_RATELIMIT_SECONDS",
    "UNAUTHENTICATED_RATELIMIT_MAX_BURST",
}


def versions_text() -> str:
    return '''schema_version = 1
[vaultwarden_oci]
version = "0.1.0-dev.18"
[components]
vaultwarden = "1.37.1"
caddy = "2.11.4"
caddy_dns_cloudflare = "v0.2.4"
caddy_cloudflare_ip = "f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5"
caddy_combine_ip_ranges = "v0.0.1"
caddy_ratelimit = "v0.1.0"
[image_digests.vaultwarden]
amd64 = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
arm64 = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
[image_digests.caddy_builder]
amd64 = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
arm64 = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
[image_digests.caddy_runtime]
amd64 = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
arm64 = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
'''


def parsed_config(*, org_creation_users: str = "all") -> runtime.RuntimeConfig:
    data = tomllib.loads(setup._config_text("vault.example.net", "admin@example.net", OFFLINE))
    data["vaultwarden"]["org_creation_users"] = org_creation_users
    with mock.patch.object(operator_settings, "legacy_admin_active", return_value=False):
        return runtime.parse_config(data)


class OperatorConfigCatalogTests(unittest.TestCase):
    def test_catalog_is_bounded_to_exact_pinned_vaultwarden_surface(self) -> None:
        actual = {spec.env for spec in operator_settings.VAULTWARDEN_SETTINGS}
        self.assertEqual(actual, PINNED_VAULTWARDEN_1371_ENV)
        self.assertNotIn("CLIENT_SUPPRESS_ONBOARDING", actual)

    def test_setup_prepopulates_supported_small_team_settings(self) -> None:
        text = setup._config_text("vault.example.net", "admin@example.net", OFFLINE)
        with mock.patch.object(operator_settings, "legacy_admin_active", return_value=False):
            cfg = runtime.parse_config(tomllib.loads(text))
        env = dict(cfg.vaultwarden_environment)

        self.assertIn('invitations_allowed = true', text)
        self.assertIn('sends_allowed = true', text)
        self.assertIn('org_creation_users = "all"', text)
        self.assertIn('admin_ratelimit_seconds = 300', text)
        self.assertIn('email_token_size = 6', text)
        self.assertNotIn("client_suppress_onboarding", text)
        self.assertIn('embed_images = true', text)
        self.assertIn('accept_invalid_certs = false', text)
        self.assertIn('[caddy]', text)
        self.assertIn('admin_rate_limit_events = 60', text)
        self.assertIn('admin_rate_limit_window = "1m"', text)
        self.assertEqual(env["CONFIG_FILE"], "/tmp/vaultwarden-admin-config.json")
        self.assertEqual(env["SIGNUPS_ALLOWED"], "false")
        self.assertEqual(env["INVITATIONS_ALLOWED"], "true")
        self.assertEqual(env["SENDS_ALLOWED"], "true")
        self.assertEqual(env["ADMIN_RATELIMIT_SECONDS"], "300")
        self.assertNotIn("CLIENT_SUPPRESS_ONBOARDING", env)
        self.assertEqual(cfg.caddy_admin_rate_limit_events, 60)
        self.assertEqual(cfg.caddy_admin_rate_limit_window, "1m")

    def test_existing_minimal_config_inherits_catalog_defaults(self) -> None:
        with mock.patch.object(operator_settings, "legacy_admin_active", return_value=False):
            cfg = runtime.parse_config(
                tomllib.loads(
                    f'''schema_version = 1
[site]
domain = "vault.example.net"
acme_email = "admin@example.net"
[secrets]
offline_recovery_recipient = "{OFFLINE}"
[vaultwarden]
signups_allowed = false
[smtp]
host = "smtp.example.net"
port = 587
security = "starttls"
from_email = "vaultwarden@example.net"
from_name = "Vaultwarden"
timeout_seconds = 15
'''
                )
            )
        env = dict(cfg.vaultwarden_environment)
        self.assertEqual(env["CONFIG_FILE"], "/tmp/vaultwarden-admin-config.json")
        self.assertEqual(env["INVITATIONS_ALLOWED"], "true")
        self.assertEqual(env["SENDS_ALLOWED"], "true")
        self.assertEqual(cfg.caddy_admin_rate_limit_events, 60)

    def test_legacy_admin_file_remains_effective_until_explicit_finalization(self) -> None:
        settings = {spec.name: spec.default for spec in operator_settings.VAULTWARDEN_SETTINGS}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            legacy = root / "config.json"
            marker = root / "state" / "legacy-admin-config-finalized.json"
            legacy.write_text('{"org_creation_users":"none"}\n', encoding="utf-8")

            env = dict(
                operator_settings.environment(
                    settings,
                    legacy_path=legacy,
                    marker_path=marker,
                )
            )
            self.assertEqual(env["CONFIG_FILE"], "/data/config.json")

            report = operator_settings.legacy_admin_report(
                parsed_config(),
                {"smtp_username": "user", "smtp_password": "password"},
                legacy_path=legacy,
                marker_path=marker,
            )
            self.assertTrue(report.active)
            self.assertFalse(report.finalized)
            self.assertEqual(len(report.differences), 1)
            self.assertEqual(report.differences[0].target, "vaultwarden.org_creation_users")
            self.assertEqual(report.differences[0].legacy_value, "none")
            self.assertEqual(report.differences[0].current_value, "all")
            with self.assertRaisesRegex(
                operator_settings.OperatorSettingError,
                "still differ",
            ):
                operator_settings.finalize_legacy_admin(report, confirm=True)

    def test_reconciled_legacy_admin_finalization_is_digest_bound_and_redacted(self) -> None:
        settings = {spec.name: spec.default for spec in operator_settings.VAULTWARDEN_SETTINGS}
        settings["org_creation_users"] = "none"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            legacy = root / "config.json"
            marker = root / "state" / "legacy-admin-config-finalized.json"
            legacy_secret = "do-not-print-this-password"
            legacy.write_text(
                json.dumps(
                    {
                        "org_creation_users": "none",
                        "allowed_iframe_ancestors": "https://portal.example.net",
                        "smtp_password": legacy_secret,
                        "admin_token": "legacy-admin-secret",
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            report = operator_settings.legacy_admin_report(
                parsed_config(org_creation_users="none"),
                {
                    "smtp_username": "user",
                    "smtp_password": "current-password",
                    "vaultwarden_admin_token": "current-admin-secret",
                },
                legacy_path=legacy,
                marker_path=marker,
            )
            self.assertEqual(report.differences, ())
            self.assertEqual(
                set(report.discard_keys),
                {"admin_token", "allowed_iframe_ancestors", "smtp_password"},
            )
            operator_settings.finalize_legacy_admin(report, confirm=True)

            marker_text = marker.read_text(encoding="utf-8")
            self.assertNotIn(legacy_secret, marker_text)
            self.assertNotIn("legacy-admin-secret", marker_text)
            self.assertIn('"smtp_password"', marker_text)

            env = dict(
                operator_settings.environment(
                    settings,
                    legacy_path=legacy,
                    marker_path=marker,
                )
            )
            self.assertEqual(env["CONFIG_FILE"], "/tmp/vaultwarden-admin-config.json")

            # The marker is bound to the exact historical file. If it changes,
            # the transition becomes active again instead of silently ignoring
            # newly persisted Admin policy.
            legacy.write_text(
                json.dumps({"org_creation_users": "none", "sends_allowed": False}) + "\n",
                encoding="utf-8",
            )
            env = dict(
                operator_settings.environment(
                    settings,
                    legacy_path=legacy,
                    marker_path=marker,
                )
            )
            self.assertEqual(env["CONFIG_FILE"], "/data/config.json")

    def test_render_uses_shared_smtp_and_interactive_safe_admin_limit(self) -> None:
        cfg = parsed_config()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = runtime.Paths(
                config=root / "config.toml",
                data=root / "data",
                caddy_data=root / "caddy-data",
                caddy_config=root / "caddy-config",
                run=root / "run",
                transient=root / "run/transient",
                lock=root / "run/lock",
                secret_root=root / "run/secrets",
            )
            paths.transient.mkdir(parents=True)
            versions = root / "versions.toml"
            versions.write_text(versions_text(), encoding="utf-8")
            runtime.render(cfg, versions, paths, admin_enabled=True)
            compose = paths.compose.read_text(encoding="utf-8")
            caddyfile = paths.caddyfile.read_text(encoding="utf-8")

        self.assertIn('CONFIG_FILE: "/tmp/vaultwarden-admin-config.json"', compose)
        self.assertIn('INVITATIONS_ALLOWED: "true"', compose)
        self.assertIn('SENDS_ALLOWED: "true"', compose)
        self.assertNotIn("CLIENT_SUPPRESS_ONBOARDING", compose)
        self.assertIn('SMTP_HOST: "smtp.invalid"', compose)
        self.assertIn('SMTP_EMBED_IMAGES: "true"', compose)
        self.assertIn('SMTP_ACCEPT_INVALID_CERTS: "false"', compose)
        self.assertIn('cat /run/vw-secrets/smtp_username', compose)
        self.assertIn('cat /run/vw-secrets/smtp_password', compose)
        self.assertIn('events 60', caddyfile)
        self.assertIn('window 1m', caddyfile)
        self.assertNotIn('events 5\n    window 5m', caddyfile)

    def test_caddy_admin_limit_validation_is_bounded(self) -> None:
        data = tomllib.loads(setup._config_text("vault.example.net", "admin@example.net", OFFLINE))
        data["caddy"]["admin_rate_limit_events"] = 1
        with (
            mock.patch.object(operator_settings, "legacy_admin_active", return_value=False),
            self.assertRaisesRegex(runtime.RuntimeConfigError, "10..1000"),
        ):
            runtime.parse_config(data)

    def test_interactive_edit_can_finalize_legacy_transition_then_restart(self) -> None:
        fake_in = mock.Mock()
        fake_in.isatty.return_value = True
        fake_out = mock.Mock()
        fake_out.isatty.return_value = True
        report = SimpleNamespace(
            active=True,
            finalized=False,
            legacy_path=Path("/var/lib/vaultwarden-oci/data/config.json"),
            differences=(),
            discard_keys=("allowed_iframe_ancestors",),
        )
        config = SimpleNamespace(offline_recovery_recipient=OFFLINE)
        with (
            mock.patch.object(operator_entrypoint.sys, "stdin", fake_in),
            mock.patch.object(operator_entrypoint.sys, "stdout", fake_out),
            mock.patch.object(builtins, "input", side_effect=["y", "y"]),
            mock.patch.object(operator_settings, "legacy_admin_active", side_effect=[True, False]),
            mock.patch.object(operator_entrypoint.cli, "mutation_lock", return_value=nullcontext()),
            mock.patch("vaultwarden_oci.storage.verify"),
            mock.patch.object(runtime, "load_config", return_value=config),
            mock.patch("vaultwarden_oci.secrets.load", return_value={"smtp_username": "u", "smtp_password": "p"}),
            mock.patch.object(operator_settings, "legacy_admin_report", return_value=report),
            mock.patch.object(operator_settings, "finalize_legacy_admin") as finalize,
            mock.patch.object(runtime, "status", return_value=("running", [])),
            mock.patch.object(runtime, "lifecycle") as lifecycle,
        ):
            code = operator_entrypoint._legacy_transition_after_edit(["config", "edit"], 0)
            code = operator_entrypoint._restart_after_edit(["config", "edit"], code)
        self.assertEqual(code, 0)
        finalize.assert_called_once_with(report, confirm=True)
        lifecycle.assert_called_once_with("restart", runner=operator_entrypoint.lifecycle_run_command)

    def test_legacy_supported_difference_blocks_finalization_and_restart(self) -> None:
        fake_in = mock.Mock()
        fake_in.isatty.return_value = True
        fake_out = mock.Mock()
        fake_out.isatty.return_value = True
        report = SimpleNamespace(
            active=True,
            finalized=False,
            legacy_path=Path("/var/lib/vaultwarden-oci/data/config.json"),
            differences=(
                operator_settings.LegacyDifference(
                    "org_creation_users", "vaultwarden.org_creation_users", "none", "all"
                ),
            ),
            discard_keys=(),
        )
        config = SimpleNamespace(offline_recovery_recipient=OFFLINE)
        with (
            mock.patch.object(operator_entrypoint.sys, "stdin", fake_in),
            mock.patch.object(operator_entrypoint.sys, "stdout", fake_out),
            mock.patch.object(operator_settings, "legacy_admin_active", return_value=True),
            mock.patch("vaultwarden_oci.storage.verify"),
            mock.patch.object(runtime, "load_config", return_value=config),
            mock.patch("vaultwarden_oci.secrets.load", return_value={"smtp_username": "u", "smtp_password": "p"}),
            mock.patch.object(operator_settings, "legacy_admin_report", return_value=report),
            mock.patch.object(operator_settings, "finalize_legacy_admin") as finalize,
            mock.patch.object(runtime, "lifecycle") as lifecycle,
        ):
            code = operator_entrypoint._legacy_transition_after_edit(["config", "edit"], 0)
            code = operator_entrypoint._restart_after_edit(["config", "edit"], code)
        self.assertEqual(code, 0)
        finalize.assert_not_called()
        lifecycle.assert_not_called()

    def test_interactive_edit_does_not_prompt_when_stack_state_is_unknown(self) -> None:
        fake_in = mock.Mock()
        fake_in.isatty.return_value = True
        fake_out = mock.Mock()
        fake_out.isatty.return_value = True
        with (
            mock.patch.object(operator_entrypoint.sys, "stdin", fake_in),
            mock.patch.object(operator_entrypoint.sys, "stdout", fake_out),
            mock.patch.object(builtins, "input") as prompt,
            mock.patch.object(operator_entrypoint, "_legacy_transition_pending", return_value=False),
            mock.patch.object(runtime, "status", return_value=("unavailable", [])),
            mock.patch.object(runtime, "lifecycle") as lifecycle,
        ):
            code = operator_entrypoint._restart_after_edit(["secrets", "edit"], 0)
        self.assertEqual(code, 0)
        prompt.assert_not_called()
        lifecycle.assert_not_called()


if __name__ == "__main__":
    unittest.main()
