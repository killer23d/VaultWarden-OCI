from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import edge, runtime
from vaultwarden_oci.cli import CommandResult

V4 = "173.245.48.0/20\n103.21.244.0/22"
V6 = "2400:cb00::/32"
OFFLINE = "age1" + "q" * 58


def result(argv, stdout="", code=0):
    return CommandResult(tuple(argv), "success" if code == 0 else "nonzero", code, stdout, "")


def exact_versions() -> str:
    return '''schema_version = 1
[vaultwarden_oci]
version = "0.1.0-dev.7"
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


class ExactPolicyRunner:
    def __init__(self, policy: edge.CloudflarePolicy, *, extra_rule: bool = False) -> None:
        self.policy = policy
        self.extra_rule = extra_rule

    def __call__(self, argv, *, env=None, cwd=None):
        call = tuple(argv)
        binary = call[0]
        if "-C" in call and "DOCKER-USER" in call:
            if edge.GUARD_COMMENT in call:
                return result(argv, code=1)
            if edge.RULE_COMMENT in call:
                required = (
                    "-o",
                    edge.BRIDGE_IFACE,
                    "-m",
                    "conntrack",
                    "--ctdir",
                    "ORIGINAL",
                    "--ctorigdstport",
                    "443",
                )
                joined = " ".join(call)
                return result(argv, code=0 if " ".join(required) in joined else 1)
        if call[:4] == (binary, "-w", "-S", edge.CHAIN):
            networks = self.policy.ipv4 if binary == "iptables" else self.policy.ipv6
            lines = [f"-A {edge.CHAIN} -s {network} -j RETURN" for network in networks]
            if self.extra_rule:
                lines.append(f"-A {edge.CHAIN} -s 203.0.113.0/24 -j RETURN")
            lines.append(f"-A {edge.CHAIN} -j DROP")
            return result(argv, "\n".join(lines) + "\n")
        raise AssertionError(call)


class RemediationRunner:
    def __init__(self, paths: edge.EdgePaths) -> None:
        self.paths = paths
        self.active = False
        self.invocation = "a" * 32
        self.calls: list[tuple[str, ...]] = []

    def __call__(self, argv, *, env=None, cwd=None):
        call = tuple(argv)
        self.calls.append(call)
        if call == ("systemctl", "is-active", "--quiet", edge.BOUNCER_SERVICE):
            return result(argv, code=0 if self.active else 3)
        if call == ("systemctl", "is-enabled", edge.BOUNCER_SERVICE):
            return result(argv, "disabled\n", code=1)
        if call == ("systemctl", "start", edge.BOUNCER_SERVICE):
            edge.consume_remediation_start_token(path=self.paths.remediation_start_token)
            self.active = True
            return result(argv)
        if call == (
            "systemctl",
            "show",
            edge.BOUNCER_SERVICE,
            "--property=InvocationID",
            "--value",
        ):
            return result(argv, self.invocation + "\n")
        raise AssertionError(call)


class Phase4BlockerTests(unittest.TestCase):
    def test_origin_jump_matches_only_original_packets_toward_project_bridge(self) -> None:
        rule = edge._rule("iptables", edge.RULE_COMMENT, edge.CHAIN)
        joined = " ".join(rule)
        self.assertIn(f"-o {edge.BRIDGE_IFACE}", joined)
        self.assertIn("--ctdir ORIGINAL", joined)
        self.assertIn("--ctorigdstport 443", joined)
        self.assertNotIn("--ctdir REPLY", joined)

    def test_rendered_bridge_is_native_dual_stack_for_published_443(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            versions = root / "versions.toml"
            versions.write_text(exact_versions(), encoding="utf-8")
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
            runtime.render(config, versions, paths)
            compose = paths.compose.read_text(encoding="utf-8")

        self.assertIn('ports: ["443:443/tcp"]', compose)
        self.assertIn("enable_ipv6: true", compose)
        self.assertIn(f'com.docker.network.bridge.name: "{edge.BRIDGE_IFACE}"', compose)
        self.assertIn("com.docker.network.bridge.gateway_mode_ipv4: nat", compose)
        self.assertIn("com.docker.network.bridge.gateway_mode_ipv6: nat", compose)

    def test_doctor_policy_requires_exact_direction_sources_and_final_drop(self) -> None:
        policy = edge.validate_policy(V4, V6, fetched_at=1000, source="test")
        self.assertTrue(edge._iptables_healthy("iptables", policy.ipv4, ExactPolicyRunner(policy)))
        self.assertTrue(edge._iptables_healthy("ip6tables", policy.ipv6, ExactPolicyRunner(policy)))
        self.assertFalse(
            edge._iptables_healthy(
                "iptables",
                policy.ipv4,
                ExactPolicyRunner(policy, extra_rule=True),
            )
        )

    def test_bouncer_start_is_one_shot_and_confirmation_is_invocation_bound(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = edge.EdgePaths(
                lkg=root / "state/cloudflare.json",
                acquisition=root / "etc/crowdsec/acquis.d/vaultwarden-oci.yaml",
                bouncer_dropin=root / "systemd/bouncer.d/vaultwarden-oci.conf",
                remediation_config=root / "run/bouncer.yaml",
                caddy_log=root / "caddy/access.log",
                remediation_start_token=root / "run/start.token",
                fail_open_confirmation=root / "state/fail-open.json",
            )
            runner = RemediationRunner(paths)
            edge.start_remediation(paths=paths, runner=runner)
            self.assertTrue(runner.active)
            self.assertFalse(paths.remediation_start_token.exists())
            self.assertFalse(paths.fail_open_confirmation.exists())

            edge.confirm_fail_open(paths=paths, runner=runner, now=1234)
            self.assertTrue(edge._fail_open_confirmed(paths.fail_open_confirmation, "a" * 32))
            self.assertFalse(edge._fail_open_confirmed(paths.fail_open_confirmation, "b" * 32))

            with self.assertRaisesRegex(edge.EdgeError, "not authorized"):
                edge.consume_remediation_start_token(path=paths.remediation_start_token)

    def test_systemd_dropin_blocks_automatic_recreation(self) -> None:
        dropin = edge.bouncer_dropin_text(Path("/run/test-bouncer.yaml"))
        self.assertIn("Restart=no", dropin)
        self.assertIn("ExecCondition=/usr/local/bin/vwctl crowdsec consume-start-token", dropin)
        self.assertIn("ExecStart=/usr/bin/crowdsec-cloudflare-worker-bouncer -c /run/test-bouncer.yaml", dropin)


if __name__ == "__main__":
    unittest.main()
