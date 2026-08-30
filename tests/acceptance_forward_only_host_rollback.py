#!/usr/bin/env python3
"""Cross-release acceptance for forward-only host dependency state after app rollback."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from unittest import mock


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


def _load_state(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit("invalid cross-release CrowdSec acceptance state")
    return value


def _assert_forward_host_files(root: Path, state: dict[str, object]) -> None:
    acquisition = root / "etc/crowdsec/acquis.d/vaultwarden-oci.yaml"
    firewall_local = acquisition.parent / "crowdsec-firewall-bouncer.yaml.local"
    worker_base = root / "run/crowdsec-worker.yaml"
    worker_local = Path(str(worker_base) + ".local")
    confirmation = root / "state/crowdsec-fail-open.json"
    attestation = root / "state/crowdsec-cloudflare-worker-policy.json"

    acquisition_text = acquisition.read_text(encoding="utf-8")
    for marker in ("Vaultwarden", "_SYSTEMD_UNIT=ssh.service", "_TRANSPORT=kernel"):
        if marker not in acquisition_text:
            raise SystemExit(f"forward-only host acquisition is missing {marker}")

    firewall_text = firewall_local.read_text(encoding="utf-8")
    if "nftables_hooks:\n  - input" not in firewall_text or "forward" in firewall_text.lower():
        raise SystemExit("forward-only host firewall policy is not strictly INPUT-only")
    if "api_key:" not in firewall_text:
        raise SystemExit("forward-only host firewall policy lost its LAPI credential")

    if "only_include_decisions_from: []" not in worker_base.read_text(encoding="utf-8"):
        raise SystemExit("forward-only state lost the actual predecessor Worker base config")
    if 'only_include_decisions_from: ["cscli", "crowdsec"]' not in worker_local.read_text(encoding="utf-8"):
        raise SystemExit("forward-only state lost the managed local-only Worker override")
    if not attestation.is_file():
        raise SystemExit("forward-only state lost the Worker invocation/config policy attestation")

    expected_confirmation = state.get("new_confirmation_sha256")
    if not isinstance(expected_confirmation, str):
        raise SystemExit("cross-release state lacks the new Fail Open confirmation digest")
    actual_confirmation = hashlib.sha256(confirmation.read_bytes()).hexdigest()
    if actual_confirmation != expected_confirmation:
        raise SystemExit("forward-only state changed the confirmed Worker invocation evidence")


def predecessor_health(root: Path, state_file: Path) -> int:
    """Use actual predecessor doctor after application rollback while host state remains forward."""
    from vaultwarden_oci import cli, edge

    source = Path(edge.__file__).resolve().parent.parent
    predecessor = cli.load_versions(source / "versions.toml").version
    if predecessor.split(".latest.", 1)[0] != "0.1.0-dev.16":
        raise SystemExit(f"expected actual supported predecessor dev.16, got {predecessor}")

    state = _load_state(state_file)
    _assert_forward_host_files(root, state)
    invocation = str(state["current_invocation"])
    paths = _paths(edge, root)

    def runner(argv, **_kwargs):
        call = tuple(str(value) for value in argv)
        if call == ("systemctl", "is-active", "--quiet", edge.CROWDSEC_SERVICE):
            return _result(cli, argv)
        if call == ("systemctl", "is-active", "--quiet", edge.BOUNCER_SERVICE):
            return _result(cli, argv)
        if call == ("systemctl", "is-enabled", edge.BOUNCER_SERVICE):
            return _result(cli, argv, ok=False, stdout="disabled\n")
        if call == (
            "systemctl",
            "show",
            edge.BOUNCER_SERVICE,
            "--property=InvocationID",
            "--value",
        ):
            return _result(cli, argv, stdout=invocation + "\n")
        if call[:3] == ("cscli", "bouncers", "inspect"):
            return _result(cli, argv, stdout="{}\n")
        if call and call[0] == edge.BOUNCER_BINARY and call[-1:] == ("-t",):
            return _result(cli, argv)
        return _result(cli, argv)

    checks = edge.doctor_checks(paths=paths, runner=runner, now=1_700_000_300)
    crowdsec = [check for check in checks if check.check_id.startswith("crowdsec.")]
    if len(crowdsec) != 2 or any(check.status != "PASS" for check in crowdsec):
        raise SystemExit(
            "actual predecessor is not healthy with retained forward-only host state: "
            + "; ".join(f"{check.check_id}={check.status}" for check in crowdsec)
        )

    print(
        "PASS: actual dev.16 remains healthy after application rollback while the forward-only host security dependency state stays installed"
    )
    return 0


def candidate_retry(root: Path, state_file: Path) -> int:
    """Prove retained host state is safe and the same target update can converge again."""
    from vaultwarden_oci import cli, crowdsec_worker_policy, edge, predecessor_transition

    source = Path(edge.__file__).resolve().parent.parent
    candidate = cli.load_versions(source / "versions.toml").version
    if candidate.split(".latest.", 1)[0] != "0.1.0-dev.17":
        raise SystemExit(f"expected candidate dev.17, got {candidate}")

    state = _load_state(state_file)
    predecessor = str(state["predecessor"])
    invocation = str(state["current_invocation"])
    _assert_forward_host_files(root, state)
    paths = _paths(edge, root)

    services = {
        edge.CROWDSEC_SERVICE: {"active": True, "enabled": True},
        edge.BOUNCER_SERVICE: {"active": True, "enabled": False},
        edge.FIREWALL_BOUNCER_SERVICE: {"active": True, "enabled": True},
    }
    collections = set(edge.CROWDSEC_COLLECTIONS)
    bouncers = {edge.BOUNCER_ID, edge.FIREWALL_BOUNCER_ID}
    calls: list[tuple[str, ...]] = []
    install_count = 0

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
        nonlocal install_count
        call = tuple(str(value) for value in argv)
        calls.append(call)

        if call[:3] == ("apt-get", "install", "-y"):
            install_count += 1
            if "crowdsec-cloudflare-worker-bouncer" in call:
                raise AssertionError("retry must not reinstall the already re-armed Worker package")
            if env is None or env.get("SYSTEMD_OFFLINE") != "1":
                raise AssertionError("retry package transaction lost SYSTEMD_OFFLINE containment")
            bootstrap = (paths.acquisition.parent / "crowdsec-firewall-bouncer.yaml.local").read_text(
                encoding="utf-8"
            )
            if "nftables_hooks:\n  - input" not in bootstrap or "forward" in bootstrap.lower():
                raise AssertionError("retry did not preserve INPUT-only pre-apt containment")
            return _result(cli, argv)
        if call[:2] == ("apt-get", "update") or call[:1] == ("/bin/sh",):
            return _result(cli, argv)

        if call[:2] == ("systemctl", "is-active"):
            service = call[-1]
            return _result(cli, argv, ok=bool(services.get(service, {}).get("active", False)))
        if call[:2] == ("systemctl", "is-enabled"):
            service = call[-1]
            enabled = bool(services.get(service, {}).get("enabled", False))
            return _result(cli, argv, ok=enabled, stdout=("enabled\n" if enabled else "disabled\n"))
        if call[:3] == ("systemctl", "show", edge.BOUNCER_SERVICE):
            return _result(cli, argv, stdout=invocation + "\n")
        if call[:3] == ("systemctl", "restart", edge.CROWDSEC_SERVICE):
            services[edge.CROWDSEC_SERVICE]["active"] = True
            return _result(cli, argv)
        if call[:3] == ("systemctl", "disable", "--now"):
            service = call[-1]
            if service == edge.BOUNCER_SERVICE:
                raise AssertionError("retry attempted to disable/stop the confirmed Worker")
            services.setdefault(service, {})["active"] = False
            services[service]["enabled"] = False
            return _result(cli, argv)
        if call[:3] == ("systemctl", "enable", "--now"):
            service = call[-1]
            if service == edge.BOUNCER_SERVICE:
                raise AssertionError("retry attempted to enable/restart the confirmed Worker")
            services.setdefault(service, {})["active"] = True
            services[service]["enabled"] = True
            return _result(cli, argv)
        if call[:2] == ("systemctl", "stop") and call[-1] == edge.BOUNCER_SERVICE:
            raise AssertionError("retry attempted to stop the confirmed Worker")

        if call[:3] == ("cscli", "hub", "update"):
            return _result(cli, argv)
        if call[:3] == ("cscli", "collections", "inspect"):
            return _result(cli, argv, ok=call[3] in collections)
        if call[:3] == ("cscli", "collections", "install"):
            collections.add(call[3])
            return _result(cli, argv)
        if call[:3] == ("cscli", "bouncers", "inspect"):
            return _result(cli, argv, ok=call[3] in bouncers, stdout="{}\n")
        if call[:3] == ("cscli", "bouncers", "delete"):
            if call[3] == edge.BOUNCER_ID:
                raise AssertionError("retry attempted to replace the confirmed Worker LAPI identity")
            bouncers.discard(call[3])
            return _result(cli, argv)
        if call[:4] == ("cscli", "-oraw", "bouncers", "add"):
            if call[4] == edge.BOUNCER_ID:
                raise AssertionError("retry attempted to replace the confirmed Worker LAPI identity")
            bouncers.add(call[4])
            return _result(cli, argv, stdout="firewall-retry-key\n")
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

    confirmation_before = paths.fail_open_confirmation.read_bytes()
    attestation_before = crowdsec_worker_policy.attestation_path(paths).read_bytes()
    if not crowdsec_worker_policy.runtime_policy_healthy(paths, runner):
        raise SystemExit("retained Worker state is not local-only/current-invocation healthy after rollback")
    if not edge._firewall_boundary_healthy(paths, runner, require_live=True):
        raise SystemExit("retained forward-only firewall state is not strictly INPUT-only after rollback")

    ready = predecessor_transition.prepare_worker_prerequisite(
        candidate,
        current_release=predecessor,
        paths=paths,
        runner=runner,
    )
    if ready != predecessor:
        raise SystemExit("retry did not accept the already confirmed local-only predecessor Worker")

    installer = root / "crowdsec-repository-retry-fixture.sh"
    installer.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    policy = root / "policy-retry-rc.d"
    with mock.patch.object(edge, "_download_installer", return_value=installer):
        changed = predecessor_transition.apply_if_required(
            candidate,
            current_release=predecessor,
            paths=paths,
            runner=runner,
            policy_path=policy,
        )
    if not changed or install_count != 1:
        raise SystemExit("retry did not safely reconverge the bounded host dependency transition")

    if paths.fail_open_confirmation.read_bytes() != confirmation_before:
        raise SystemExit("retry changed the confirmed Worker Fail Open evidence")
    if crowdsec_worker_policy.attestation_path(paths).read_bytes() != attestation_before:
        raise SystemExit("retry changed the confirmed Worker policy attestation")
    if not crowdsec_worker_policy.runtime_policy_healthy(paths, runner):
        raise SystemExit("retry lost the local-only Worker policy proof")
    if not edge._firewall_boundary_healthy(paths, runner, require_live=True):
        raise SystemExit("retry lost strict INPUT-only firewall ownership")

    checks = edge.doctor_checks(paths=paths, runner=runner, now=1_700_000_400)
    crowdsec = [check for check in checks if check.check_id.startswith("crowdsec.")]
    if len(crowdsec) != 4 or any(check.status != "PASS" for check in crowdsec):
        raise SystemExit(
            "retry did not return the target CrowdSec contract to fully green: "
            + "; ".join(f"{check.check_id}={check.status}" for check in crowdsec)
        )

    if any(
        edge.BOUNCER_SERVICE in call
        and call[:2]
        in {
            ("systemctl", "restart"),
            ("systemctl", "stop"),
            ("systemctl", "enable"),
            ("systemctl", "disable"),
        }
        for call in calls
    ):
        raise SystemExit("retry mutated the already confirmed Worker service invocation")

    print(
        "PASS: retained local-only Worker and INPUT-only firewall state survive application rollback, and the same dev.17 host transition safely reconverges on retry"
    )
    return 0


def parse_args():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("predecessor-health", "candidate-retry"):
        command = commands.add_parser(name)
        command.add_argument("root", type=Path)
        command.add_argument("state_file", type=Path)
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    if args.command == "predecessor-health":
        raise SystemExit(predecessor_health(args.root.resolve(), args.state_file.resolve()))
    raise SystemExit(candidate_retry(args.root.resolve(), args.state_file.resolve()))
