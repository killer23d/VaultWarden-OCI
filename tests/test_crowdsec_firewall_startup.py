from __future__ import annotations

import json
import unittest

from vaultwarden_oci import crowdsec_firewall_startup
from vaultwarden_oci.cli import CommandResult

SERVICE = "crowdsec-firewall-bouncer.service"


def result(argv, *, ok: bool = True, stdout: str = "", stderr: str = "") -> CommandResult:
    return CommandResult(
        tuple(str(value) for value in argv),
        "success" if ok else "nonzero",
        0 if ok else 1,
        stdout,
        stderr,
    )


def nft_table(family: str, table: str, *, forward: bool = False) -> str:
    chain_base = "crowdsec-chain" if family == "ip" else "crowdsec6-chain"
    chains = [
        {
            "chain": {
                "family": family,
                "table": table,
                "name": f"{chain_base}-input",
                "type": "filter",
                "hook": "input",
                "prio": -10,
            }
        }
    ]
    if forward:
        chains.append(
            {
                "chain": {
                    "family": family,
                    "table": table,
                    "name": f"{chain_base}-forward",
                    "type": "filter",
                    "hook": "forward",
                    "prio": -10,
                }
            }
        )
    return json.dumps({"nftables": chains})


class CrowdSecFirewallStartupTests(unittest.TestCase):
    def test_missing_tables_settle_to_exact_dual_stack_input(self) -> None:
        inspections = {"ip": 0, "ip6": 0}
        sleeps: list[float] = []
        clock = {"now": 0.0}

        def runner(argv, **_kwargs):
            call = tuple(str(value) for value in argv)
            if call == ("systemctl", "is-active", "--quiet", SERVICE):
                return result(argv)
            if call[:5] == ("nft", "--json", "list", "table", "ip"):
                inspections["ip"] += 1
                if inspections["ip"] == 1:
                    return result(argv, ok=False, stderr="No such file or directory")
                return result(argv, stdout=nft_table("ip", "crowdsec"))
            if call[:5] == ("nft", "--json", "list", "table", "ip6"):
                inspections["ip6"] += 1
                if inspections["ip6"] <= 2:
                    return result(argv, ok=False, stderr="No such file or directory")
                return result(argv, stdout=nft_table("ip6", "crowdsec6"))
            raise AssertionError(call)

        def sleeper(seconds: float) -> None:
            sleeps.append(seconds)
            clock["now"] += seconds

        crowdsec_firewall_startup.wait_for_input_only(
            runner,
            service=SERVICE,
            config_input_only=lambda: True,
            timeout=2.0,
            poll=0.25,
            sleeper=sleeper,
            clock=lambda: clock["now"],
        )
        self.assertGreaterEqual(inspections["ip"], 2)
        self.assertGreaterEqual(inspections["ip6"], 3)
        self.assertEqual(sleeps, [0.25, 0.25])

    def test_forward_hook_fails_immediately_without_retry(self) -> None:
        sleeps: list[float] = []

        def runner(argv, **_kwargs):
            call = tuple(str(value) for value in argv)
            if call == ("systemctl", "is-active", "--quiet", SERVICE):
                return result(argv)
            if call[:5] == ("nft", "--json", "list", "table", "ip"):
                return result(argv, stdout=nft_table("ip", "crowdsec", forward=True))
            if call[:5] == ("nft", "--json", "list", "table", "ip6"):
                return result(argv, stdout=nft_table("ip6", "crowdsec6"))
            raise AssertionError(call)

        with self.assertRaisesRegex(
            crowdsec_firewall_startup.FirewallStartupError,
            "unexpected live ip CrowdSec hook ownership",
        ):
            crowdsec_firewall_startup.wait_for_input_only(
                runner,
                service=SERVICE,
                config_input_only=lambda: True,
                sleeper=sleeps.append,
            )
        self.assertEqual(sleeps, [])

    def test_service_exit_and_config_drift_fail_immediately(self) -> None:
        inactive = lambda argv, **_kwargs: result(argv, ok=False)
        with self.assertRaisesRegex(
            crowdsec_firewall_startup.FirewallStartupError,
            "exited before INPUT-only",
        ):
            crowdsec_firewall_startup.wait_for_input_only(
                inactive,
                service=SERVICE,
                config_input_only=lambda: True,
                sleeper=lambda _seconds: self.fail("must not sleep"),
            )

        def active(argv, **_kwargs):
            call = tuple(str(value) for value in argv)
            self.assertEqual(call, ("systemctl", "is-active", "--quiet", SERVICE))
            return result(argv)

        with self.assertRaisesRegex(
            crowdsec_firewall_startup.FirewallStartupError,
            "effective configuration stopped being exactly INPUT-only",
        ):
            crowdsec_firewall_startup.wait_for_input_only(
                active,
                service=SERVICE,
                config_input_only=lambda: False,
                sleeper=lambda _seconds: self.fail("must not sleep"),
            )

    def test_non_missing_nft_error_is_not_retried(self) -> None:
        sleeps: list[float] = []

        def runner(argv, **_kwargs):
            call = tuple(str(value) for value in argv)
            if call == ("systemctl", "is-active", "--quiet", SERVICE):
                return result(argv)
            if call[:5] == ("nft", "--json", "list", "table", "ip"):
                return result(argv, ok=False, stderr="Operation not permitted")
            if call[:5] == ("nft", "--json", "list", "table", "ip6"):
                return result(argv, stdout=nft_table("ip6", "crowdsec6"))
            raise AssertionError(call)

        with self.assertRaisesRegex(
            crowdsec_firewall_startup.FirewallStartupError,
            "cannot inspect live ip table crowdsec",
        ):
            crowdsec_firewall_startup.wait_for_input_only(
                runner,
                service=SERVICE,
                config_input_only=lambda: True,
                sleeper=sleeps.append,
            )
        self.assertEqual(sleeps, [])


if __name__ == "__main__":
    unittest.main()
