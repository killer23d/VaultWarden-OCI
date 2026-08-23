from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import edge, runtime, secrets

OFFLINE = "age1" + "q" * 58


def versions_text() -> str:
    return '''schema_version = 1
[vaultwarden_oci]
version = "0.1.0-dev.9"
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


class CaddyEdgeAdminContractTests(unittest.TestCase):
    def _render(self, admin_enabled: bool):
        root = Path(self.directory.name)
        versions = root / "versions.toml"
        versions.write_text(versions_text(), encoding="utf-8")
        paths = runtime.Paths(
            config=root / "config.toml", data=root / "data", caddy_data=root / "caddy/data",
            caddy_config=root / "caddy/config", caddy_log=root / "caddy/log", run=root / "run",
            transient=root / "run/transient", lock=root / "run/lock", secret_root=root / "run/secrets",
        )
        paths.transient.mkdir(parents=True)
        cfg = runtime.RuntimeConfig(
            domain="vault.example.net", acme_email="admin@example.net", offline_recovery_recipient=OFFLINE,
            signups_allowed=False, smtp_host="smtp.example.net", smtp_port=587, smtp_security="starttls",
            smtp_from_email="vaultwarden@example.net", smtp_from_name="Vaultwarden", smtp_timeout_seconds=15,
        )
        runtime.render(cfg, versions, paths, admin_enabled=admin_enabled)
        return paths

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.directory.cleanup()

    def test_build_has_exact_required_addons_and_proxy_module_not_static_cidrs(self):
        paths = self._render(True)
        dockerfile = paths.dockerfile.read_text(encoding="utf-8")
        caddyfile = paths.caddyfile.read_text(encoding="utf-8")
        for pin in (
            "github.com/caddy-dns/cloudflare@v0.2.4",
            "github.com/WeidiDeng/caddy-cloudflare-ip@f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5",
            "github.com/fvbommel/caddy-combine-ip-ranges@v0.0.1",
            "github.com/mholt/caddy-ratelimit@v0.1.0",
        ):
            self.assertIn(pin, dockerfile)
        self.assertIn("trusted_proxies cloudflare", caddyfile)
        self.assertIn("client_ip_headers CF-Connecting-IP", caddyfile)
        self.assertNotIn("trusted_proxies static", caddyfile)
        self.assertNotIn("173.245.48.0/20", caddyfile)

    def test_admin_and_auth_rate_limits_use_real_client_ip_and_outer_gate(self):
        caddyfile = self._render(True).caddyfile.read_text(encoding="utf-8")
        self.assertGreaterEqual(caddyfile.count("key {client_ip}"), 2)
        self.assertIn("@admin path /admin*", caddyfile)
        self.assertIn("basic_auth", caddyfile)
        self.assertIn("admin {env.ADMIN_BASIC_AUTH_HASH}", caddyfile)
        self.assertIn("/identity/connect/token*", caddyfile)
        self.assertIn("/api/accounts/prelogin*", caddyfile)
        self.assertIn("/api/accounts/register*", caddyfile)
        self.assertNotIn("ADMIN_ALLOW_CIDR", caddyfile)

    def test_admin_disabled_is_closed_at_caddy(self):
        caddyfile = self._render(False).caddyfile.read_text(encoding="utf-8")
        self.assertIn("respond @admin 404", caddyfile)
        self.assertNotIn("ADMIN_BASIC_AUTH_HASH", caddyfile)

    def test_admin_source_secret_pairing_and_hash_boundary(self):
        with self.assertRaises(secrets.SecretsError):
            secrets.admin_enabled({"vaultwarden_admin_token": "token"})
        self.assertTrue(secrets.admin_enabled({
            "vaultwarden_admin_token": "token", "admin_basic_auth_password": "source-secret"
        }))
        completed = mock.Mock(returncode=0, stdout="$2a$14$hash\n", stderr="")
        with mock.patch("vaultwarden_oci.secrets.subprocess.run", return_value=completed) as run:
            value = secrets.derive_admin_basic_auth_hash("source-secret", "caddy:2.11.4@sha256:" + "a" * 64)
        self.assertEqual(value, "$2a$14$hash")
        argv = run.call_args.args[0]
        self.assertNotIn("source-secret", argv)
        self.assertNotIn("--plaintext", argv)
        self.assertEqual(run.call_args.kwargs["input"], "source-secret\n")

    def test_origin_firewall_implementation_remains_separate(self):
        self.assertTrue(callable(edge.refresh_origin_policy))
        self.assertEqual(edge.CHAIN, "VWOCI-CF-HTTPS")
        self.assertEqual(edge.GUARD_COMMENT, "vaultwarden-oci:cloudflare-guard")
        self.assertFalse(hasattr(edge, "caddy_trusted_proxy_block"))


if __name__ == "__main__":
    unittest.main()
