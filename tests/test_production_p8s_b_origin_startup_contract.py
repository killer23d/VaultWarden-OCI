"""P8S-B fail-closed startup contract: exercised product policy and source invariants.

Source is intentionally imported from this branch, not the installed mutable VM.
No Docker, iptables, Cloudflare account or service operations are issued.
"""
from __future__ import annotations

import ast
import inspect
import ipaddress
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import edge, runtime
from vaultwarden_oci.cli import CommandResult

ROOT = Path(__file__).resolve().parents[1]


def rule_calls(actions: list[tuple[str, ...]], expression: tuple[str, ...]) -> list[int]:
    return [i for i, row in enumerate(actions) if row[:len(expression)] == expression]


class CapturingRunner:
    def __init__(self, *, fail_at: str | None = None):
        self.calls: list[tuple[str, ...]] = []
        self.fail_at = fail_at
        self.chain = {"iptables": False, "ip6tables": False}

    def __call__(self, argv, **kwargs):
        command = tuple(map(str, argv))
        self.calls.append(command)
        binary = command[0]
        if binary in ("iptables", "ip6tables"):
            if self.fail_at and self.fail_at in " ".join(command):
                return CommandResult(command, "exit", 1, "", "injected")
            if "-L" in command and "DOCKER-USER" in command:
                return CommandResult(command, "success", 0, "", "")
            if "-L" in command and edge.CHAIN in command:
                return CommandResult(command, "success" if self.chain[binary] else "exit", 0 if self.chain[binary] else 1, "", "")
            if "-N" in command and edge.CHAIN in command:
                self.chain[binary] = True
                return CommandResult(command, "success", 0, "", "")
            if "-C" in command:
                return CommandResult(command, "exit", 1, "", "")
            if "-D" in command and "DOCKER-USER" in command and edge.GUARD_COMMENT in command:
                return CommandResult(command, "success", 0, "", "")
        return CommandResult(command, "success", 0, "", "")


class OriginStartupContract(unittest.TestCase):
    @staticmethod
    def policy():
        return edge.validate_policy("173.245.48.0/20\n103.21.244.0/22", "2400:cb00::/32",
                                    fetched_at=1000, source="live")

    def test_unsafe_invalid_and_expired_cidrs_fail(self):
        for ipv4 in ("0.0.0.0/0", "127.0.0.1/8", "not-a-cidr"):
            with self.subTest(value=ipv4), self.assertRaises(edge.EdgeError):
                edge.validate_policy(ipv4, "2400:cb00::/32", fetched_at=1000, source="live")

    def test_fail_closed_guard_is_installed_before_remote_fetch(self):
        runner = CapturingRunner()
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(edge.EdgeError):
                edge.refresh_origin_policy(
                    path=Path(tmp) / "missing-cache", now=1000,
                    fetcher=lambda *args: (_ for _ in ()).throw(edge.EdgeError("offline")),
                    runner=runner)
        for binary in ("iptables", "ip6tables"):
            self.assertTrue(any(row[0] == binary and "-I" in row and
                                "DOCKER-USER" in row and edge.GUARD_COMMENT in row
                                for row in runner.calls))
        self.assertFalse(any("-F" in row for row in runner.calls))

    def test_dual_stack_chain_rebuilt_under_guard(self):
        runner = CapturingRunner()
        edge.apply_origin_policy(self.policy(), runner=runner)
        for binary in ("iptables", "ip6tables"):
            calls = [x for x in runner.calls if x[0] == binary]
            guard = next(i for i, row in enumerate(calls)
                         if "-I" in row and "DOCKER-USER" in row and edge.GUARD_COMMENT in row)
            chain_flush = next(i for i, row in enumerate(calls)
                               if "-F" in row and edge.CHAIN in row)
            drop = next(i for i, row in enumerate(calls)
                        if "-A" in row and edge.CHAIN in row and "DROP" in row)
            jump = next(i for i, row in enumerate(calls)
                        if "-I" in row and "DOCKER-USER" in row and edge.RULE_COMMENT in row)
            removal = next(i for i, row in enumerate(calls)
                           if "-D" in row and "DOCKER-USER" in row and edge.GUARD_COMMENT in row)
            self.assertLess(guard, chain_flush)
            self.assertLess(chain_flush, drop)
            self.assertLess(drop, jump)
            self.assertLess(jump, removal)
            self.assertTrue(any("-s" in row for row in calls if "-A" in row))

    def test_failed_ipv6_rebuild_does_not_publish_caddy_via_product(self):
        runner = CapturingRunner(fail_at="ip6tables -w -A " + edge.CHAIN)
        with self.assertRaises(edge.EdgeError):
            edge.apply_origin_policy(self.policy(), runner=runner)
        self.assertFalse(any(row[0] == "docker" for row in runner.calls))

    def test_main_start_refresh_order_and_compose_guard(self):
        source = inspect.getsource(runtime.lifecycle)
        tree = ast.parse(source)
        function = tree.body[0]
        ordered = []
        for node in ast.walk(function):
            if isinstance(node, ast.Call):
                try:
                    name = ast.unparse(node.func)
                except Exception:
                    continue
                if name in ("edge.refresh_origin_policy", "_compose"):
                    ordered.append((node.lineno, name))
        refreshes = [line for line, name in ordered if name == "edge.refresh_origin_policy"]
        starts = [line for line, name in ordered if name == "_compose"]
        self.assertEqual(len(refreshes), 1)
        self.assertTrue(starts)
        self.assertLess(refreshes[0], min(starts))
        self.assertIn('restart: "no"', inspect.getsource(runtime.render))
        self.assertIn('ports: ["443:443/tcp"]', inspect.getsource(runtime.render))

    def test_docker_bridge_is_ipv6_aware(self):
        source = inspect.getsource(runtime.render)
        self.assertIn("enable_ipv6: true", source)
        self.assertIn("gateway_mode_ipv6: nat", source)
        self.assertIn("restart: unless-stopped", source)  # Vaultwarden not publicly mapped
        self.assertIn('restart: "no"', source)  # Caddy is publicly mapped

    def test_crowdsec_boundary_is_input_only(self):
        text = edge.firewall_bouncer_bootstrap_local_text()
        self.assertNotIn("DOCKER-USER", text)
        self.assertNotIn("FORWARD", text)
        self.assertIn("INPUT", text)

    def test_firewall_unavailable_does_not_silently_allow(self):
        runner = CapturingRunner(fail_at="iptables -w -n -L DOCKER-USER")
        with self.assertRaises(edge.EdgeError):
            edge.apply_origin_policy(self.policy(), runner=runner)


if __name__ == "__main__":
    unittest.main()
