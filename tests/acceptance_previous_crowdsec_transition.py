#!/usr/bin/env python3
"""Cross-release CrowdSec acceptance using actual predecessor-owned state."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from unittest import mock

_INVOCATION = "0123456789abcdef0123456789abcdef"


def _paths(edge_module, root: Path):
    acquisition = root / "etc/crowdsec/acquis.d/vaultwarden-oci.yaml"
    return edge_module.EdgePaths(
        lkg=root / "state/cloudflare.json",
        acquisition=acquisition,
        bouncer_dropin=root / "systemd/crowdsec-worker.d/vaultwarden-oci.conf",
        remediation_config=root / "run/crowdsec-worker.yaml",
        caddy_log=root / "caddy/access.log",
        remediation_start_token=root / "run/crowdsec-start.token",
        fail_open_confirmation=root / "state/crowdsec-fail-open.json",
    )


def _result(cli_module, argv, *, ok: bool = True, stdout: str = "", stderr: str = ""):
    return cli_module.CommandResult(
        tuple(str(value) for value in argv),
        "success" if ok else "nonzero",
        0 if ok else 1,
        stdout,
        stderr,
    )


def seed_predecessor(root: Path, state_file: Path) -> None:
    """Use the actual supported predecessor module to create its CrowdSec state."""
    from vaultwarden_oci import cli, edge

    source = Path(edge.__file__).resolve().parent.parent
    predecessor = cli.load_versions(source / "versions.toml").version
    if predecessor.split(".latest.", 1)[0] != "0.1.0-dev.16":
        raise SystemExit(f"expected actual supported predecessor dev.16, got {predecessor}")

    paths = _paths(edge, root)
    paths.acquisition.parent.mkdir(parents=True, exist_ok=True)
    paths.bouncer_dropin.parent.mkdir(parents=True, exist_ok=True)
    paths.remediation_config.parent.mkdir(parents=True, exist_ok=True)
    paths.fail_open_confirmation.parent.mkdir(parents=True, exist_ok=True)
    paths.acquisition.write_text(edge.acquisition_text(paths.caddy_log), encoding="utf-8")
    paths.bouncer_dropin.write_text(
        edge.bouncer_dropin_text(paths.remediation_config), encoding="utf-8"
    )
    paths.remediation_config.write_text("# predecessor Worker config fixture\n", encoding="utf-8")

    def runner(argv, **_kwargs):
        call = tuple(str(value) for value in argv)
        if call == ("systemctl", "is-active", "--quiet", edge.BOUNCER_SERVICE):
            return _result(cli, argv)
        if call == (
            "systemctl",
            "show",
            edge.BOUNCER_SERVICE,
            "--property=InvocationID",
            "--value",
        ):
            return _result(cli, argv, stdout=_INVOCATION + "\n")
        return _result(cli, argv)

    edge.confirm_fail_open(paths=paths, runner=runner, now=1_700_000_000)
    confirmation = paths.fail_open_confirmation.read_bytes()
    state_file.write_text(
        json.dumps(
            {
                "predecessor": predecessor,
                "invocation": _INVOCATION,
                "confirmation_sha256": hashlib.sha256(confirmation).hexdigest(),
                "acquisition_sha256": hashlib.sha256(paths.acquisition.read_bytes()).hexdigest(),
            },
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    print(
        "PASS: actual supported predecessor generated its Caddy-only acquisition and invocation-bound Worker Fail Open state"
    )


def migrate_with_candidate(root: Path, state_file: Path) -> None:
    """Apply the candidate's one bounded transition and prove its CrowdSec contract."""
    from vaultwarden_oci import cli, edge, predecessor_transition

    source = Path(edge.__file__).resolve().parent.parent
    candidate = cli.load_versions(source / "versions.toml").version
    if candidate.split(".latest.", 1)[0] != "0.1.0-dev.17":
        raise SystemExit(f"expected candidate dev.17, got {candidate}")

    state = json.loads(state_file.read_text(encoding="utf-8"))
    predecessor = state["predecessor"]
    paths = _paths(edge, root)
    confirmation_before = paths.fail_open_confirmation.read_bytes()
    acquisition_before = paths.acquisition.read_bytes()
    if hashlib.sha256(confirmation_before).hexdigest() != state["confirmation_sha256"]:
        raise SystemExit("predecessor Fail Open fixture changed before candidate transition")
    if hashlib.sha256(acquisition_before).hexdigest() != state["acquisition_sha256"]:
        raise SystemExit("predecessor acquisition fixture changed before candidate transition")

    services = {
        edge.CROWDSEC_SERVICE: {"active": True, "enabled": True},
        edge.BOUNCER_SERVICE: {"active": True, "enabled": False},
        edge.FIREWALL_BOUNCER_SERVICE: {"active": False, "enabled": False},
    }
    collections = {"crowdsecurity/caddy"}
    bouncers = {edge.BOUNCER_ID}
    calls: list[tuple[str, ...]] = []
    install_envs: list[dict[str, str]] = []

    def nft_table(family: str, table: str, chain: str) -> str:
        return json.dumps(
            {
                "nftables": [
                    {
                        "chain": {
                            "family": family,
                            "table": table,
                            "name": chain,
                            "type": "filter",
                            "hook": "input",
                            "prio": -10,
                            "policy": "accept",
                        }
                    }
                ]
            }
        )

    def runner(argv, *, env=None, cwd=None):
        call = tuple(str(value) for value in argv)
        calls.append(call)

        if call[:3] == ("apt-get", "install", "-y"):
            if edge.BOUNCER_SERVICE.replace(".service", "") in call or "crowdsec-cloudflare-worker-bouncer" in call:
                raise AssertionError("predecessor transition must not reinstall the active Worker package")
            if env is None:
                raise AssertionError("CrowdSec apt transaction lost its scoped environment")
            install_envs.append(dict(env))
            if env.get("SYSTEMD_OFFLINE") != "1":
                raise AssertionError("CrowdSec apt transaction is not SYSTEMD_OFFLINE")
            local = paths.acquisition.parent / "crowdsec-firewall-bouncer.yaml.local"
            bootstrap = local.read_text(encoding="utf-8")
            if "nftables_hooks:\n  - input" not in bootstrap or "forward" in bootstrap.lower():
                raise AssertionError("INPUT-only firewall safety override was not present before apt")
            # Model the real postinst's direct enable without allowing a start.
            services[edge.FIREWALL_BOUNCER_SERVICE]["enabled"] = True
            services[edge.FIREWALL_BOUNCER_SERVICE]["active"] = False
            return _result(cli, argv)
        if call[:2] == ("apt-get", "update") or call[:1] == ("/bin/sh",):
            return _result(cli, argv)

        if call[:2] == ("systemctl", "is-active"):
            service = call[-1]
            current = services.get(service, {"active": False})
            return _result(cli, argv, ok=bool(current["active"]))
        if call[:2] == ("systemctl", "is-enabled"):
            service = call[-1]
            current = services.get(service, {"enabled": False})
            enabled = bool(current["enabled"])
            return _result(cli, argv, ok=enabled, stdout=("enabled\n" if enabled else "disabled\n"))
        if call[:3] == ("systemctl", "show", edge.BOUNCER_SERVICE):
            return _result(cli, argv, stdout=_INVOCATION + "\n")
        if call[:3] == ("systemctl", "restart", edge.CROWDSEC_SERVICE):
            services[edge.CROWDSEC_SERVICE]["active"] = True
            return _result(cli, argv)
        if call[:3] == ("systemctl", "disable", "--now"):
            service = call[-1]
            if service == edge.BOUNCER_SERVICE:
                raise AssertionError("transition attempted to stop/disable the active Worker")
            services.setdefault(service, {})["active"] = False
            services[service]["enabled"] = False
            return _result(cli, argv)
        if call[:3] == ("systemctl", "enable", "--now"):
            service = call[-1]
            if service == edge.BOUNCER_SERVICE:
                raise AssertionError("transition attempted to enable/restart the active Worker")
            services.setdefault(service, {})["active"] = True
            services[service]["enabled"] = True
            return _result(cli, argv)
        if call[:2] == ("systemctl", "stop") and call[-1] == edge.BOUNCER_SERVICE:
            raise AssertionError("transition attempted to stop the active Worker")

        if call[:3] == ("cscli", "hub", "update"):
            return _result(cli, argv)
        if call[:3] == ("cscli", "collections", "install"):
            collections.add(call[3])
            return _result(cli, argv)
        if call[:3] == ("cscli", "collections", "inspect"):
            return _result(cli, argv, ok=call[3] in collections)
        if call[:3] == ("cscli", "bouncers", "inspect"):
            return _result(cli, argv, ok=call[3] in bouncers, stdout="{}\n")
        if call[:3] == ("cscli", "bouncers", "delete"):
            if call[3] == edge.BOUNCER_ID:
                raise AssertionError("transition attempted to replace the existing Worker LAPI identity")
            bouncers.discard(call[3])
            return _result(cli, argv)
        if call[:4] == ("cscli", "-oraw", "bouncers", "add"):
            if call[4] == edge.BOUNCER_ID:
                raise AssertionError("transition attempted to replace the existing Worker LAPI identity")
            bouncers.add(call[4])
            return _result(cli, argv, stdout="firewall-transition-key\n")
        if call[:4] == ("cscli", "config", "show", "-oraw"):
            return _result(cli, argv, stdout="127.0.0.1:8080\n")

        if call and call[0] == edge.BOUNCER_BINARY and call[-1:] == ("-t",):
            return _result(cli, argv)
        if call and call[0] == edge.FIREWALL_BOUNCER_BINARY and call[-1:] == ("-t",):
            return _result(cli, argv)
        if call and call[0] == edge.FIREWALL_BOUNCER_BINARY and call[-1:] == ("-T",):
            local = paths.acquisition.parent / "crowdsec-firewall-bouncer.yaml.local"
            return _result(cli, argv, stdout=local.read_text(encoding="utf-8"))
        if call[:5] == ("nft", "--json", "list", "table", "ip"):
            if not services[edge.FIREWALL_BOUNCER_SERVICE]["active"]:
                return _result(cli, argv, ok=False, stderr="table absent")
            return _result(cli, argv, stdout=nft_table("ip", "crowdsec", "crowdsec-chain-input"))
        if call[:5] == ("nft", "--json", "list", "table", "ip6"):
            if not services[edge.FIREWALL_BOUNCER_SERVICE]["active"]:
                return _result(cli, argv, ok=False, stderr="table absent")
            return _result(cli, argv, stdout=nft_table("ip6", "crowdsec6", "crowdsec6-chain-input"))
        if call[:3] == ("docker", "container", "inspect"):
            return _result(cli, argv, ok=False, stderr="No such container")
        return _result(cli, argv)

    installer = root / "crowdsec-repository-fixture.sh"
    installer.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    policy = root / "policy-rc.d"
    with mock.patch.object(edge, "_download_installer", return_value=installer):
        changed = predecessor_transition.apply_if_required(
            candidate,
            current_release=predecessor,
            paths=paths,
            runner=runner,
            policy_path=policy,
        )
    if not changed:
        raise SystemExit("candidate did not recognize the supported predecessor transition")

    if paths.fail_open_confirmation.read_bytes() != confirmation_before:
        raise SystemExit("candidate changed predecessor Worker Fail Open confirmation bytes")
    if services[edge.BOUNCER_SERVICE] != {"active": True, "enabled": False}:
        raise SystemExit("candidate changed predecessor Worker service state")
    if not install_envs or any(env.get("SYSTEMD_OFFLINE") != "1" for env in install_envs):
        raise SystemExit("candidate package transaction did not retain SYSTEMD_OFFLINE")
    if any(
        call[:3] in {
            ("systemctl", "restart", edge.BOUNCER_SERVICE),
            ("systemctl", "stop", edge.BOUNCER_SERVICE),
        }
        for call in calls
    ):
        raise SystemExit("candidate restarted/stopped the existing Worker")

    acquisition = paths.acquisition.read_text(encoding="utf-8")
    for marker in ("Vaultwarden", "_SYSTEMD_UNIT=ssh.service", "_TRANSPORT=kernel"):
        if marker not in acquisition:
            raise SystemExit(f"candidate acquisition is missing {marker}")
    if collections != set(edge.CROWDSEC_COLLECTIONS):
        raise SystemExit(f"candidate Hub set is incomplete: {sorted(collections)}")

    crowdsec_checks = [
        check
        for check in edge.doctor_checks(paths=paths, runner=runner, now=1_700_000_000)
        if check.check_id.startswith("crowdsec.")
    ]
    if len(crowdsec_checks) != 4 or any(check.status != "PASS" for check in crowdsec_checks):
        raise SystemExit(
            "candidate CrowdSec doctor contract is not fully green: "
            + "; ".join(f"{check.check_id}={check.status}" for check in crowdsec_checks)
        )

    print(
        "PASS: candidate migrated actual predecessor CrowdSec state to all four required checks without touching the active Worker invocation/Fail Open confirmation"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("seed-predecessor", "migrate-candidate"):
        command = commands.add_parser(name)
        command.add_argument("root", type=Path)
        command.add_argument("state_file", type=Path)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "seed-predecessor":
        seed_predecessor(args.root.resolve(), args.state_file.resolve())
    else:
        migrate_with_candidate(args.root.resolve(), args.state_file.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
