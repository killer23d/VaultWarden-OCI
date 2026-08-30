#!/usr/bin/env python3
"""Prove the actual predecessor remains healthy after the Worker prerequisite."""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def _paths(edge_module, root: Path):
    return edge_module.EdgePaths(
        lkg=root / "state/cloudflare.json",
        acquisition=root / "etc/crowdsec/acquis.d/vaultwarden-oci.yaml",
        bouncer_dropin=root / "systemd/crowdsec-worker.d/vaultwarden-oci.conf",
        remediation_config=root / "run/crowdsec-worker.yaml",
        caddy_log=root / "caddy/access.log",
        remediation_start_token=root / "run/crowdsec-start.token",
        fail_open_confirmation=root / "state/crowdsec-fail-open.json",
    )


def main(root: Path, state_file: Path) -> int:
    # CI deliberately invokes this with PYTHONPATH pointed at the actual
    # supported predecessor worktree.
    from vaultwarden_oci import cli, edge

    source = Path(edge.__file__).resolve().parent.parent
    predecessor = cli.load_versions(source / "versions.toml").version
    if predecessor.split(".latest.", 1)[0] != "0.1.0-dev.16":
        raise SystemExit(f"expected actual supported predecessor dev.16, got {predecessor}")

    state = json.loads(state_file.read_text(encoding="utf-8"))
    invocation = str(state["current_invocation"])
    paths = _paths(edge, root)

    base = paths.remediation_config.read_text(encoding="utf-8")
    local = Path(str(paths.remediation_config) + ".local").read_text(encoding="utf-8")
    if "only_include_decisions_from: []" not in base:
        raise SystemExit("transitional state lost the real dev.16 Worker base config")
    if 'only_include_decisions_from: ["cscli", "crowdsec"]' not in local:
        raise SystemExit("transitional state is missing the candidate local-only Worker override")
    if list(paths.acquisition.parent.glob("*firewall-bouncer*")):
        raise SystemExit("host firewall migration occurred before verified recovery")

    def result(argv, *, ok: bool = True, stdout: str = ""):
        return cli.CommandResult(
            tuple(str(value) for value in argv),
            "success" if ok else "nonzero",
            0 if ok else 1,
            stdout,
            "",
        )

    def runner(argv, **_kwargs):
        call = tuple(str(value) for value in argv)
        if call == ("systemctl", "is-active", "--quiet", edge.CROWDSEC_SERVICE):
            return result(argv)
        if call == ("systemctl", "is-active", "--quiet", edge.BOUNCER_SERVICE):
            return result(argv)
        if call == ("systemctl", "is-enabled", edge.BOUNCER_SERVICE):
            return result(argv, ok=False, stdout="disabled\n")
        if call == (
            "systemctl",
            "show",
            edge.BOUNCER_SERVICE,
            "--property=InvocationID",
            "--value",
        ):
            return result(argv, stdout=invocation + "\n")
        if call[:3] == ("cscli", "bouncers", "inspect"):
            return result(argv, stdout="{}\n")
        if call and call[0] == edge.BOUNCER_BINARY and call[-1:] == ("-t",):
            return result(argv)
        return result(argv)

    checks = edge.doctor_checks(paths=paths, runner=runner, now=1_700_000_200)
    crowdsec = [check for check in checks if check.check_id.startswith("crowdsec.")]
    if len(crowdsec) != 2 or any(check.status != "PASS" for check in crowdsec):
        raise SystemExit(
            "actual predecessor is not healthy after Worker prerequisite: "
            + "; ".join(f"{check.check_id}={check.status}" for check in crowdsec)
        )

    print(
        "PASS: actual dev.16 doctor remains green after local-only Worker re-arm/confirmation, with no host firewall migration before recovery"
    )
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("state_file", type=Path)
    args = parser.parse_args()
    raise SystemExit(main(args.root.resolve(), args.state_file.resolve()))
