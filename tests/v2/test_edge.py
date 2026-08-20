from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import edge, runtime, secrets
from vaultwarden_oci.cli import CommandResult

V4 = "173.245.48.0/20\n103.21.244.0/22"
V6 = "2400:cb00::/32"
OFFLINE = "age1" + "q" * 58
TOKEN = "A" * 40


def result(argv, stdout="", stderr="", code=0):
    return CommandResult(tuple(argv), "success" if code == 0 else "nonzero", code, stdout, stderr)


class FirewallRunner:
    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []
        self.chains: dict[str, set[str]] = {"iptables": set(), "ip6tables": set()}
        self.guards: set[str] = set()
        self.jumps: set[str] = set()

    def __call__(self, argv, *, env=None, cwd=None):
        call = tuple(argv)
        self.calls.append(call)
        binary = call[0]
        if binary not in {"iptables", "ip6tables"}:
            raise AssertionError(call)
        if "-L" in call:
            chain = call[call.index("-L") + 1]
            if chain == "DOCKER-USER" or chain in self.chains[binary]:
                return result(argv)
            return result(argv, code=1)
        if "-N" in call:
            self.chains[binary].add(call[-1])
            return result(argv)
        if "-C" in call and "DOCKER-USER" in call:
            if edge.GUARD_COMMENT in call:
                return result(argv, code=0 if binary in self.guards else 1)
            if edge.RULE_COMMENT in call:
                return result(argv, code=0 if binary in self.jumps else 1)
        if "-I" in call and "DOCKER-USER" in call:
            if edge.GUARD_COMMENT in call:
                self.guards.add(binary)
            if edge.RULE_COMMENT in call:
                self.jumps.add(binary)
            return result(argv)
        if "-D" in call and "DOCKER-USER" in call:
            if edge.GUARD_COMMENT in call:
                self.guards.discard(binary)
            if edge.RULE_COMMENT in call:
                self.jumps.discard(binary)
            return result(argv)
        return result(argv)


class CloudflarePolicyTests(unittest.TestCase):
    def test_strict_cidr_validation(self) -> None:
        policy = edge.validate_policy(V4, V6, fetched_at=1000, source="test")
        self.assertEqual(len(policy.ipv4), 2)
        self.assertEqual(len(policy.ipv6), 1)
        self.assertEqual(policy.cidrs[0], "103.21.244.0/22")

        invalid = (
            ("173.245.48.1/20\n103.21.244.0/22", V6),
            ("10.0.0.0/8\n103.21.244.0/22", V6),
            ("173.245.48.0/20\n173.245.48.0/20", V6),
            ("173.245.48.0/20\n 103.21.244.0/22", V6),
            (V4, "173.245.48.0/20"),
        )
        for ipv4, ipv6 in invalid:
            with self.subTest(ipv4=ipv4, ipv6=ipv6):
                with self.assertRaises(edge.EdgeError):
                    edge.validate_policy(ipv4, ipv6, fetched_at=1000, source="test")

    def test_last_known_good_is_bounded_and_revalidated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cloudflare.json"
            policy = edge.validate_policy(V4, V6, fetched_at=1000, source="current")
            edge.persist_lkg(policy, path)
            loaded = edge.load_lkg(path, now=1000 + edge.LKG_MAX_AGE_SECONDS)
            self.assertEqual(loaded.source, "last-known-good")
            with self.assertRaisesRegex(edge.EdgeError, "stale"):
                edge.load_lkg(path, now=1001 + edge.LKG_MAX_AGE_SECONDS)

            payload = json.loads(path.read_text(encoding="utf-8"))
            payload["fetched_at"] = 2000
            path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(edge.EdgeError, "future"):
                edge.load_lkg(path, now=1000)

    def test_current_policy_replaces_cache_and_failed_fetch_uses_fresh_cache(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cloudflare.json"

            def good(url: str, maximum: int) -> str:
                return V4 if url == edge.CLOUDFLARE_IPV4_URL else V6

            current = edge.select_policy(path=path, now=5000, fetcher=good)
            self.assertEqual(current.source, "current")

            def bad(url: str, maximum: int) -> str:
                raise edge.EdgeError("network down")

            cached = edge.select_policy(path=path, now=5001, fetcher=bad)
            self.assertEqual(cached.source, "last-known-good")
            with self.assertRaisesRegex(edge.EdgeError, "no safe Cloudflare"):
                edge.select_policy(path=path, now=5001 + edge.LKG_MAX_AGE_SECONDS, fetcher=bad)


class OriginPolicyTests(unittest.TestCase):
    def test_supported_iptables_path_is_deterministic_and_dual_stack(self) -> None:
        runner = FirewallRunner()
        policy = edge.validate_policy(V4, V6, fetched_at=1000, source="test")
        edge.apply_origin_policy(policy, runner=runner)

        self.assertEqual(runner.guards, set())
        self.assertEqual(runner.jumps, {"iptables", "ip6tables"})
        calls = [" ".join(call) for call in runner.calls]
        self.assertTrue(any("iptables -w -A VWOCI-CF-HTTPS -s 173.245.48.0/20 -j RETURN" in call for call in calls))
        self.assertTrue(any("ip6tables -w -A VWOCI-CF-HTTPS -s 2400:cb00::/32 -j RETURN" in call for call in calls))
        self.assertTrue(any("--ctorigdstport 443" in call and edge.RULE_COMMENT in call for call in calls))
        self.assertTrue(any("-A VWOCI-CF-HTTPS -j DROP" in call for call in calls))

    def test_refresh_fails_closed_before_network_or_cache_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            runner = FirewallRunner()

            def bad(url: str, maximum: int) -> str:
                raise edge.EdgeError("offline")

            with self.assertRaises(edge.EdgeError):
                edge.refresh_origin_policy(
                    path=Path(directory) / "missing.json",
                    now=1000,
                    fetcher=bad,
                    runner=runner,
                )
            self.assertEqual(runner.guards, {"iptables", "ip6tables"})
            self.assertEqual(runner.jumps, set())

    def test_caddy_render_uses_same_validated_policy_and_json_log(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            versions = root / "versions.toml"
            versions.write_text(
                '''schema_version = 1
[vaultwarden_oci]
version = "0.1.0-dev"
[components]
vaultwarden = "1.37.1"
caddy = "2.11.4"
caddy_dns_cloudflare = "v0.2.4"
''',
                encoding="utf-8",
            )
            paths = runtime.Paths(
                config=root / "config.toml",
                data=root / "state/data",
                caddy_data=root / "state/caddy/data",
                caddy_config=root / "state/caddy/config",
                caddy_log=root / "state/caddy/log",
                run=root / "run",
                transient=root / "run/transient",
                lock=root / "run/lock",
                secret_root=root / "run/secrets",
            )
            paths.transient.mkdir(parents=True)
            config = runtime.RuntimeConfig(
                domain="vault.example.net",
                acme_email="admin@example.net",
                offline_recovery_recipient=OFFLINE,
                signups_allowed=False,
                smtp_host="smtp.example.net",
                smtp_port=587,
                smtp_security="starttls",
                smtp_from_email="vaultwarden@example.net",
                smtp_from_name="Vaultwarden",
                smtp_timeout_seconds=15,
            )
            policy = edge.validate_policy(V4, V6, fetched_at=1000, source="test")
            runtime.render(config, versions, paths, cloudflare_policy=policy)

            caddyfile = paths.caddyfile.read_text(encoding="utf-8")
            compose = paths.compose.read_text(encoding="utf-8")
            self.assertIn("trusted_proxies static", caddyfile)
            self.assertIn("173.245.48.0/20", caddyfile)
            self.assertIn("2400:cb00::/32", caddyfile)
            self.assertIn("client_ip_headers CF-Connecting-IP", caddyfile)
            self.assertIn("output file /var/log/caddy/access.log", caddyfile)
            self.assertIn(str(paths.caddy_log_path) + ":/var/log/caddy", compose)
            self.assertIn('ports: ["443:443/tcp"]', compose)
            self.assertIn('restart: "no"', compose)


class CrowdSecBoundaryTests(unittest.TestCase):
    def test_product_acquisition_and_remediation_config_are_narrow(self) -> None:
        acquisition = edge.acquisition_text(Path("/logs/caddy.json"))
        self.assertIn("type: caddy", acquisition)
        self.assertIn("/logs/caddy.json", acquisition)
        self.assertNotIn("sshd", acquisition)

        rendered = edge.remediation_config_text(
            lapi_key="local-lapi-key",
            token=TOKEN,
            account_id="account-id",
            zone_id="zone-id",
            domain="vault.example.net",
        )
        self.assertIn('"vault.example.net/*"', rendered)
        self.assertIn("default_action: ban", rendered)
        self.assertIn("enabled: false", rendered)
        self.assertNotIn("firewall", rendered.lower())

    def test_prepare_remediation_keeps_cloudflare_token_out_of_argv(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config.toml"
            output = root / "bouncer.yaml"
            config.write_text(
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
''',
                encoding="utf-8",
            )
            calls: list[tuple[str, ...]] = []

            def runner(argv, *, env=None, cwd=None):
                calls.append(tuple(argv))
                if tuple(argv[:4]) == ("cscli", "-oraw", "bouncers", "add"):
                    return result(argv, "local-lapi-key\n")
                if tuple(argv[:4]) == ("cscli", "config", "show", "-oraw"):
                    return result(argv, "127.0.0.1:8080\n")
                return result(argv)

            with mock.patch.object(
                secrets,
                "load",
                return_value={
                    "cloudflare_api_token": TOKEN,
                    "smtp_username": "u",
                    "smtp_password": "p",
                    "cloudflare_remediation_token": TOKEN,
                },
            ), mock.patch.object(edge, "resolve_cloudflare_zone", return_value=("acct", "zone")):
                edge.prepare_remediation(config_path=config, output=output, runner=runner)

            self.assertTrue(output.exists())
            self.assertEqual(oct(output.stat().st_mode & 0o777), "0o600")
            self.assertIn(TOKEN, output.read_text(encoding="utf-8"))
            self.assertIn('lapi_url: "http://127.0.0.1:8080"', output.read_text(encoding="utf-8"))
            self.assertNotIn(TOKEN, " ".join(item for call in calls for item in call))

    def test_setup_uses_only_engine_caddy_collection_and_cloudflare_worker_bouncer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            acquisition_parent = root / "etc/crowdsec/acquis.d"
            dropin_parent = root / "systemd/bouncer.d"
            acquisition_parent.mkdir(parents=True, mode=0o755)
            dropin_parent.mkdir(parents=True, mode=0o755)
            os.chmod(acquisition_parent, 0o755)
            os.chmod(dropin_parent, 0o755)
            paths = edge.EdgePaths(
                lkg=root / "state/cloudflare.json",
                acquisition=acquisition_parent / "vaultwarden-oci.yaml",
                bouncer_dropin=dropin_parent / "vaultwarden-oci.conf",
                remediation_config=root / "run/bouncer.yaml",
                caddy_log=root / "caddy/access.log",
            )
            installer = root / "installer.sh"
            installer.write_text("exit 0\n", encoding="utf-8")
            calls: list[tuple[str, ...]] = []

            def runner(argv, *, env=None, cwd=None):
                calls.append(tuple(argv))
                return result(argv)

            with mock.patch.object(edge, "_download_installer", return_value=installer):
                edge.setup_crowdsec(paths=paths, runner=runner)

            flat = [" ".join(call) for call in calls]
            self.assertTrue(any("apt-get install -y crowdsec crowdsec-cloudflare-worker-bouncer" in call for call in flat))
            self.assertTrue(any("cscli collections install crowdsecurity/caddy" in call for call in flat))
            self.assertFalse(any("firewall-bouncer" in call for call in flat))
            self.assertTrue(paths.acquisition.exists())
            self.assertTrue(paths.bouncer_dropin.exists())
            self.assertEqual(stat_mode(acquisition_parent), 0o755)
            self.assertEqual(stat_mode(dropin_parent), 0o755)


def stat_mode(path: Path) -> int:
    return path.stat().st_mode & 0o777


if __name__ == "__main__":
    unittest.main()
