#!/usr/bin/env python3
"""Cross-release CrowdSec acceptance using actual predecessor-owned state."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from unittest import mock

_OLD_INVOCATION = "0123456789abcdef0123456789abcdef"
_NEW_INVOCATION = "fedcba9876543210fedcba9876543210"


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


def _read_state(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit("invalid acceptance state")
    return value


def _write_state(path: Path, state: dict[str, object]) -> None:
    path.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")


def seed_predecessor(root: Path, state_file: Path) -> None:
    """Use actual dev.16 renderers for its acquisition, Worker config and confirmation."""
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
    paths.remediation_config.write_text(
        edge.remediation_config_text(
            lapi_key="predecessor-lapi-key",
            token="predecessor-cloudflare-token",
            account_id="predecessor-account",
            zone_id="predecessor-zone",
            domain="vault.example.net",
            lapi_url="http://127.0.0.1:8080",
        ),
        encoding="utf-8",
    )
    config_text = paths.remediation_config.read_text(encoding="utf-8")
    if "only_include_decisions_from: []" not in config_text:
        raise SystemExit("actual predecessor no longer renders the expected all-origin Worker policy")

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
            return _result(cli, argv, stdout=_OLD_INVOCATION + "\n")
        return _result(cli, argv)

    edge.confirm_fail_open(paths=paths, runner=runner, now=1_700_000_000)
    confirmation = paths.fail_open_confirmation.read_bytes()
    _write_state(
        state_file,
        {
            "predecessor": predecessor,
            "old_invocation": _OLD_INVOCATION,
            "current_invocation": _OLD_INVOCATION,
            "old_confirmation_sha256": hashlib.sha256(confirmation).hexdigest(),
            "acquisition_sha256": hashlib.sha256(paths.acquisition.read_bytes()).hexdigest(),
            "legacy_config_sha256": hashlib.sha256(paths.remediation_config.read_bytes()).hexdigest(),
        },
    )
    print(
        "PASS: actual supported predecessor generated its Caddy-only acquisition, real all-origin Worker config, and invocation-bound Fail Open state"
    )


def rearm_candidate(root: Path, state_file: Path) -> None:
    """Candidate must re-arm the legacy Worker and stop before recovery."""
    from vaultwarden_oci import cli, crowdsec_worker_policy, edge, predecessor_transition
    from vaultwarden_oci.update_versions import UpdateError

    source = Path(edge.__file__).resolve().parent.parent
    candidate = cli.load_versions(source / "versions.toml").version
    if candidate.split(".latest.", 1)[0] != "0.1.0-dev.17":
        raise SystemExit(f"expected candidate dev.17, got {candidate}")

    state = _read_state(state_file)
    predecessor = str(state["predecessor"])
    paths = _paths(edge, root)
    if hashlib.sha256(paths.remediation_config.read_bytes()).hexdigest() != state["legacy_config_sha256"]:
        raise SystemExit("predecessor Worker config changed before candidate re-arm")
    base, local, effective = crowdsec_worker_policy.source_state(paths)
    if base != () or local is not None or effective != ():
        raise SystemExit("candidate did not begin from the real dev.16 all-origin Worker policy")

    worker = {"active": True, "enabled": False, "invocation": _OLD_INVOCATION}
    bouncers = {edge.BOUNCER_ID}
    calls: list[tuple[str, ...]] = []

    def runner(argv, *, env=None, cwd=None):
        call = tuple(str(value) for value in argv)
        calls.append(call)
        if call == ("systemctl", "is-active", "--quiet", edge.BOUNCER_SERVICE):
            return _result(cli, argv, ok=bool(worker["active"]))
        if call == ("systemctl", "is-enabled", edge.BOUNCER_SERVICE):
            return _result(cli, argv, ok=False, stdout="disabled\n")
        if call == (
            "systemctl",
            "show",
            edge.BOUNCER_SERVICE,
            "--property=InvocationID",
            "--value",
        ):
            return _result(cli, argv, stdout=str(worker["invocation"]) + "\n")
        if call == ("systemctl", "stop", edge.BOUNCER_SERVICE):
            worker["active"] = False
            return _result(cli, argv)
        if call == ("systemctl", "start", edge.BOUNCER_SERVICE):
            paths.remediation_start_token.unlink(missing_ok=True)
            worker["active"] = True
            worker["invocation"] = _NEW_INVOCATION
            return _result(cli, argv)
        if call[:3] == ("cscli", "bouncers", "inspect"):
            return _result(cli, argv, ok=call[3] in bouncers, stdout="{}\n")
        if call and call[0] == edge.BOUNCER_BINARY and call[-1:] == ("-t",):
            return _result(cli, argv)
        return _result(cli, argv)

    try:
        predecessor_transition.prepare_worker_prerequisite(
            candidate,
            current_release=predecessor,
            paths=paths,
            runner=runner,
        )
    except UpdateError as exc:
        if "set every bouncer-created Worker Route to Fail Open" not in str(exc):
            raise
    else:
        raise SystemExit("candidate incorrectly proceeded without new Fail Open confirmation")

    if paths.fail_open_confirmation.exists():
        raise SystemExit("candidate preserved the predecessor Fail Open confirmation across Worker re-arm")
    if worker["invocation"] != _NEW_INVOCATION:
        raise SystemExit("candidate did not create a new Worker invocation")
    if not crowdsec_worker_policy.managed_override_present(paths):
        raise SystemExit("candidate did not install the managed local-only Worker override")
    if not crowdsec_worker_policy.runtime_policy_healthy(paths, runner):
        raise SystemExit("candidate did not attest the re-armed Worker as local-origin-only")
    base, local, effective = crowdsec_worker_policy.source_state(paths)
    if base != () or local != crowdsec_worker_policy.LOCAL_DECISION_SOURCES or effective != crowdsec_worker_policy.LOCAL_DECISION_SOURCES:
        raise SystemExit("candidate Worker source policy did not migrate from [] to local-only")

    state["current_invocation"] = _NEW_INVOCATION
    state["policy_attestation_sha256"] = hashlib.sha256(
        crowdsec_worker_policy.attestation_path(paths).read_bytes()
    ).hexdigest()
    _write_state(state_file, state)
    print(
        "PASS: candidate re-armed the real dev.16 Worker under local-only source policy, invalidated the old confirmation, and stopped before recovery"
    )


def confirm_with_predecessor(root: Path, state_file: Path) -> None:
    """Use the installed predecessor confirmation schema for the new invocation."""
    from vaultwarden_oci import cli, edge

    source = Path(edge.__file__).resolve().parent.parent
    predecessor = cli.load_versions(source / "versions.toml").version
    state = _read_state(state_file)
    if predecessor != state["predecessor"]:
        raise SystemExit("confirmation phase is not using the recorded actual predecessor")
    invocation = str(state["current_invocation"])
    paths = _paths(edge, root)

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
            return _result(cli, argv, stdout=invocation + "\n")
        return _result(cli, argv)

    edge.confirm_fail_open(paths=paths, runner=runner, now=1_700_000_100)
    confirmation = paths.fail_open_confirmation.read_bytes()
    if hashlib.sha256(confirmation).hexdigest() == state["old_confirmation_sha256"]:
        raise SystemExit("new Worker reused the old Fail Open confirmation bytes")
    state["new_confirmation_sha256"] = hashlib.sha256(confirmation).hexdigest()
    _write_state(state_file, state)
    print("PASS: actual dev.16 vwctl confirmation schema bound Fail Open to the new local-only Worker invocation")


def migrate_with_candidate(root: Path, state_file: Path) -> None:
    """Second candidate pass proves confirmation, then expands host CrowdSec state."""
    from vaultwarden_oci import cli, crowdsec_worker_policy, edge, predecessor_transition

    source = Path(edge.__file__).resolve().parent.parent
    candidate = cli.load_versions(source / "versions.toml").version
    if candidate.split(".latest.", 1)[0] != "0.1.0-dev.17":
        raise SystemExit(f"expected candidate dev.17, got {candidate}")

    state = _read_state(state_file)
    predecessor = str(state["predecessor"])
    paths = _paths(edge, root)
    invocation = str(state["current_invocation"])
    confirmation_before = paths.fail_open_confirmation.read_bytes()
    if hashlib.sha256(confirmation_before).hexdigest() != state.get("new_confirmation_sha256"):
        raise SystemExit("new invocation Fail Open confirmation changed before host transition")
    if hashlib.sha256(paths.acquisition.read_bytes()).hexdigest() != state["acquisition_sha256"]:
        raise SystemExit("predecessor acquisition changed before host transition")

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
            if "crowdsec-cloudflare-worker-bouncer" in call:
                raise AssertionError("host transition must not reinstall the re-armed Worker package")
            if env is None:
                raise AssertionError("CrowdSec apt transaction lost its scoped environment")
            install_envs.append(dict(env))
            if env.get("SYSTEMD_OFFLINE") != "1":
                raise AssertionError("CrowdSec apt transaction is not SYSTEMD_OFFLINE")
            local = paths.acquisition.parent / "crowdsec-firewall-bouncer.yaml.local"
            bootstrap = local.read_text(encoding="utf-8")
            if "nftables_hooks:\n  - input" not in bootstrap or "forward" in bootstrap.lower():
                raise AssertionError("INPUT-only firewall safety override was not present before apt")
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
            return _result(cli, argv, stdout=invocation + "\n")
        if call[:3] == ("systemctl", "restart", edge.CROWDSEC_SERVICE):
            services[edge.CROWDSEC_SERVICE]["active"] = True
            return _result(cli, argv)
        if call[:3] == ("systemctl", "disable", "--now"):
            service = call[-1]
            if service == edge.BOUNCER_SERVICE:
                raise AssertionError("host transition attempted to stop/disable the re-armed Worker")
            services.setdefault(service, {})["active"] = False
            services[service]["enabled"] = False
            return _result(cli, argv)
        if call[:3] == ("systemctl", "enable", "--now"):
            service = call[-1]
            if service == edge.BOUNCER_SERVICE:
                raise AssertionError("host transition attempted to enable/restart the re-armed Worker")
            services.setdefault(service, {})["active"] = True
            services[service]["enabled"] = True
            return _result(cli, argv)
        if call[:2] == ("systemctl", "stop") and call[-1] == edge.BOUNCER_SERVICE:
            raise AssertionError("host transition attempted to stop the re-armed Worker")

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
                raise AssertionError("host transition attempted to replace the existing Worker LAPI identity")
            bouncers.discard(call[3])
            return _result(cli, argv)
        if call[:4] == ("cscli", "-oraw", "bouncers", "add"):
            if call[4] == edge.BOUNCER_ID:
                raise AssertionError("host transition attempted to replace the existing Worker LAPI identity")
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

    # The second prepare pass must now accept the local-only Worker and current
    # invocation-bound Fail Open proof without another restart.
    ready = predecessor_transition.prepare_worker_prerequisite(
        candidate,
        current_release=predecessor,
        paths=paths,
        runner=runner,
    )
    if ready != predecessor:
        raise SystemExit("candidate did not accept the confirmed local-only predecessor Worker")

    installer = root / "crowdsec-repository-fixture.sh"
    installer.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    policy = root / "policy-rc.d"
    call_start = len(calls)
    with mock.patch.object(edge, "_download_installer", return_value=installer):
        changed = predecessor_transition.apply_if_required(
            candidate,
            current_release=predecessor,
            paths=paths,
            runner=runner,
            policy_path=policy,
        )
    if not changed:
        raise SystemExit("candidate did not recognize the supported predecessor host transition")

    host_calls = calls[call_start:]
    if paths.fail_open_confirmation.read_bytes() != confirmation_before:
        raise SystemExit("host transition changed the new Worker Fail Open confirmation bytes")
    if not crowdsec_worker_policy.runtime_policy_healthy(paths, runner):
        raise SystemExit("host transition lost the local-only running Worker proof")
    if any(
        edge.BOUNCER_SERVICE in call
        and call[:2]
        in {
            ("systemctl", "restart"),
            ("systemctl", "stop"),
            ("systemctl", "enable"),
            ("systemctl", "disable"),
        }
        for call in host_calls
    ):
        raise SystemExit("host transition restarted/stopped the already confirmed Worker")
    if not install_envs or any(env.get("SYSTEMD_OFFLINE") != "1" for env in install_envs):
        raise SystemExit("candidate package transaction did not retain SYSTEMD_OFFLINE")

    acquisition = paths.acquisition.read_text(encoding="utf-8")
    for marker in ("Vaultwarden", "_SYSTEMD_UNIT=ssh.service", "_TRANSPORT=kernel"):
        if marker not in acquisition:
            raise SystemExit(f"candidate acquisition is missing {marker}")
    if collections != set(edge.CROWDSEC_COLLECTIONS):
        raise SystemExit(f"candidate Hub set is incomplete: {sorted(collections)}")

    mechanical = edge.doctor_checks(paths=paths, runner=runner, now=1_700_000_000)
    enforced = crowdsec_worker_policy.enforce_doctor_checks(
        mechanical,
        paths=paths,
        runner=runner,
    )
    crowdsec_checks = [check for check in enforced if check.check_id.startswith("crowdsec.")]
    if len(crowdsec_checks) != 4 or any(check.status != "PASS" for check in crowdsec_checks):
        raise SystemExit(
            "candidate CrowdSec doctor contract is not fully green: "
            + "; ".join(f"{check.check_id}={check.status}" for check in crowdsec_checks)
        )

    print(
        "PASS: confirmed local-only Worker survived the post-recovery host expansion and all four candidate CrowdSec checks are green"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    for name in (
        "seed-predecessor",
        "rearm-candidate",
        "confirm-predecessor",
        "migrate-candidate",
    ):
        command = commands.add_parser(name)
        command.add_argument("root", type=Path)
        command.add_argument("state_file", type=Path)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    root = args.root.resolve()
    state_file = args.state_file.resolve()
    if args.command == "seed-predecessor":
        seed_predecessor(root, state_file)
    elif args.command == "rearm-candidate":
        rearm_candidate(root, state_file)
    elif args.command == "confirm-predecessor":
        confirm_with_predecessor(root, state_file)
    else:
        migrate_with_candidate(root, state_file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
