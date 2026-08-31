from __future__ import annotations

import builtins
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import operator_entrypoint, runtime, setup

OFFLINE = "age1" + "q" * 58


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


class OperatorConfigCatalogTests(unittest.TestCase):
    def test_setup_prepopulates_supported_small_team_settings(self) -> None:
        text = setup._config_text("vault.example.net", "admin@example.net", OFFLINE)
        cfg = runtime.parse_config(tomllib.loads(text))
        env = dict(cfg.vaultwarden_environment)

        self.assertIn('invitations_allowed = true', text)
        self.assertIn('sends_allowed = true', text)
        self.assertIn('org_creation_users = "all"', text)
        self.assertIn('admin_ratelimit_seconds = 300', text)
        self.assertIn('email_token_size = 6', text)
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
        self.assertEqual(cfg.caddy_admin_rate_limit_events, 60)
        self.assertEqual(cfg.caddy_admin_rate_limit_window, "1m")

    def test_existing_minimal_config_inherits_catalog_defaults(self) -> None:
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

    def test_render_uses_shared_smtp_and_interactive_safe_admin_limit(self) -> None:
        cfg = runtime.parse_config(
            tomllib.loads(setup._config_text("vault.example.net", "admin@example.net", OFFLINE))
        )
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
        with self.assertRaisesRegex(runtime.RuntimeConfigError, "10..1000"):
            runtime.parse_config(data)

    def test_interactive_edit_can_restart_immediately(self) -> None:
        fake_in = mock.Mock()
        fake_in.isatty.return_value = True
        fake_out = mock.Mock()
        fake_out.isatty.return_value = True
        with (
            mock.patch.object(operator_entrypoint.sys, "stdin", fake_in),
            mock.patch.object(operator_entrypoint.sys, "stdout", fake_out),
            mock.patch.object(builtins, "input", return_value="y"),
            mock.patch.object(runtime, "status", return_value=("running", [])),
            mock.patch.object(runtime, "lifecycle") as lifecycle,
        ):
            code = operator_entrypoint._restart_after_edit(["config", "edit"], 0)
        self.assertEqual(code, 0)
        lifecycle.assert_called_once_with("restart", runner=operator_entrypoint.lifecycle_run_command)

    def test_interactive_edit_does_not_prompt_when_stack_state_is_unknown(self) -> None:
        fake_in = mock.Mock()
        fake_in.isatty.return_value = True
        fake_out = mock.Mock()
        fake_out.isatty.return_value = True
        with (
            mock.patch.object(operator_entrypoint.sys, "stdin", fake_in),
            mock.patch.object(operator_entrypoint.sys, "stdout", fake_out),
            mock.patch.object(builtins, "input") as prompt,
            mock.patch.object(runtime, "status", return_value=("unavailable", [])),
            mock.patch.object(runtime, "lifecycle") as lifecycle,
        ):
            code = operator_entrypoint._restart_after_edit(["secrets", "edit"], 0)
        self.assertEqual(code, 0)
        prompt.assert_not_called()
        lifecycle.assert_not_called()


if __name__ == "__main__":
    unittest.main()
