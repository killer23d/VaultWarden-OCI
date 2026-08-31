from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import edge
from vaultwarden_oci.cli import CommandResult


def result(argv, *, ok: bool = True, stdout: str = "") -> CommandResult:
    return CommandResult(
        tuple(str(value) for value in argv),
        "success" if ok else "nonzero",
        0 if ok else 1,
        stdout,
        "",
    )


def nft_table(family: str, table: str) -> str:
    chain_base = "crowdsec-chain" if family == "ip" else "crowdsec6-chain"
    return json.dumps(
        {
            "nftables": [
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
        }
    )


class FirewallLiveValidationTests(unittest.TestCase):
    def test_live_proof_and_startup_config_check_never_invoke_destructive_t(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = edge.EdgePaths(acquisition=root / "acquis.d/vaultwarden-oci.yaml")
            local = paths.acquisition.parent / "crowdsec-firewall-bouncer.yaml.local"
            local.parent.mkdir(parents=True)
            local.write_text("nftables_hooks:\n  - input\n", encoding="utf-8")
            calls: list[tuple[str, ...]] = []

            def runner(argv, **_kwargs):
                call = tuple(str(value) for value in argv)
                calls.append(call)
                if call and call[0] == edge.FIREWALL_BOUNCER_BINARY and call[-1:] == ("-t",):
                    self.fail("live firewall proof must not invoke destructive crowdsec-firewall-bouncer -t")
                if call and call[0] == edge.FIREWALL_BOUNCER_BINARY and call[-1:] == ("-T",):
                    return result(argv, stdout=local.read_text(encoding="utf-8"))
                if call[:5] == ("nft", "--json", "list", "table", "ip"):
                    return result(argv, stdout=nft_table("ip", "crowdsec"))
                if call[:5] == ("nft", "--json", "list", "table", "ip6"):
                    return result(argv, stdout=nft_table("ip6", "crowdsec6"))
                raise AssertionError(call)

            self.assertTrue(edge._firewall_config_input_only(paths, runner))
            self.assertTrue(edge._firewall_boundary_healthy(paths, runner, require_live=True))
            self.assertFalse(any(call[-1:] == ("-t",) for call in calls))

    def test_prestart_boundary_retains_full_config_test(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = edge.EdgePaths(acquisition=root / "acquis.d/vaultwarden-oci.yaml")
            local = paths.acquisition.parent / "crowdsec-firewall-bouncer.yaml.local"
            local.parent.mkdir(parents=True)
            local.write_text("nftables_hooks:\n  - input\n", encoding="utf-8")
            calls: list[tuple[str, ...]] = []

            def runner(argv, **_kwargs):
                call = tuple(str(value) for value in argv)
                calls.append(call)
                if call and call[0] == edge.FIREWALL_BOUNCER_BINARY and call[-1:] == ("-t",):
                    return result(argv)
                if call and call[0] == edge.FIREWALL_BOUNCER_BINARY and call[-1:] == ("-T",):
                    return result(argv, stdout=local.read_text(encoding="utf-8"))
                raise AssertionError(call)

            self.assertTrue(edge._firewall_boundary_healthy(paths, runner, require_live=False))
            self.assertTrue(any(call[-1:] == ("-t",) for call in calls))


if __name__ == "__main__":
    unittest.main()
