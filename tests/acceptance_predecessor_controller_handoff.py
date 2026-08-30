#!/usr/bin/env python3
"""Prove the supported predecessor can hand update control to the exact target safely."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, durability, install, update, update_controller_handoff


def command(argv, *, ok: bool = True, stdout: str = "") -> cli.CommandResult:
    return cli.CommandResult(
        tuple(str(value) for value in argv),
        "success" if ok else "nonzero",
        0 if ok else 1,
        stdout,
        "",
    )


def main(candidate_source: Path, host: Path) -> int:
    candidate_source = candidate_source.resolve()
    layout = install.Layout(host.resolve())
    _, predecessor_release, predecessor_dir = update._current(layout)
    candidate_release = cli.load_versions(candidate_source / "versions.toml").version
    if predecessor_release.split(".latest.", 1)[0] != "0.1.0-dev.16":
        raise SystemExit(f"expected installed supported predecessor dev.16, got {predecessor_release}")
    if candidate_release.split(".latest.", 1)[0] != "0.1.0-dev.17":
        raise SystemExit(f"expected candidate dev.17, got {candidate_release}")

    current = layout.path(install.CURRENT_LINK)
    launcher = layout.path(install.VWCTL_LINK)
    canonical = current / "vwctl"
    if not launcher.is_symlink() or Path(os.readlink(launcher)) != canonical:
        raise SystemExit("actual predecessor install did not begin with the canonical vwctl launcher")

    if not update_controller_handoff.prepare_if_required(
        candidate_release,
        candidate_source,
        current_release=predecessor_release,
        root=host,
    ):
        raise SystemExit("candidate did not publish the required predecessor controller handoff")

    if update._current(layout)[1] != predecessor_release:
        raise SystemExit("controller handoff changed the selected/running predecessor release")
    controller = layout.path(install.RELEASES_DIR) / candidate_release / "vwctl"
    if Path(os.readlink(launcher)) != controller:
        raise SystemExit("installed vwctl launcher does not point to the exact staged target controller")

    state_path = host / "var/lib/vaultwarden-oci/state/update-controller-handoff.json"
    state = json.loads(state_path.read_text(encoding="utf-8"))
    if state.get("predecessor_release") != predecessor_release:
        raise SystemExit("controller handoff did not bind the supported predecessor release")
    if state.get("target_release") != candidate_release or state.get("controller") != str(controller):
        raise SystemExit("controller handoff did not bind the exact staged target release")

    with mock.patch.object(update_controller_handoff.os, "execv") as execv:
        if not update_controller_handoff.delegate_non_update_if_handoff(
            ["doctor", "--json"],
            root=host,
            controller_vwctl=controller,
        ):
            raise SystemExit("ordinary command was not delegated to the selected predecessor")
        predecessor_vwctl = predecessor_dir / "vwctl"
        execv.assert_called_once_with(
            str(predecessor_vwctl),
            [str(predecessor_vwctl), "doctor", "--json"],
        )
    if update_controller_handoff.delegate_non_update_if_handoff(
        ["update", "apply", "--yes"],
        root=host,
        controller_vwctl=controller,
    ):
        raise SystemExit("update command was incorrectly delegated back to the predecessor")

    # Reproduce the arm64 recovery-window state against the candidate-owned
    # current-runtime gate. The first status is exactly the all-running
    # unhealthy condition observed live; the second is healthy. No sleep is
    # needed in CI, but the real controller uses the bounded 65-second window.
    unhealthy = "\n".join(
        (
            "vaultwarden: running (health=unhealthy)",
            "caddy: running (health=unhealthy)",
            "edge.caddy.health: FAIL (Caddy container is stopped, unhealthy, or could not be inspected)",
            "crowdsec.engine: PASS (CrowdSec Security Engine is active)",
            "crowdsec.cloudflare: PASS (Cloudflare Worker is healthy)",
            "notification: never (transport=-, detail=no delivery recorded)",
            "Overall: degraded",
        )
    )
    healthy = "\n".join(
        (
            "vaultwarden: running (health=healthy)",
            "caddy: running (health=healthy)",
            "edge.caddy.health: PASS (Caddy container is running and healthy)",
            "crowdsec.engine: PASS (CrowdSec Security Engine is active)",
            "crowdsec.cloudflare: PASS (Cloudflare Worker is healthy)",
            "notification: never (transport=-, detail=no delivery recorded)",
            "Overall: running",
        )
    )
    status_calls = 0

    def runner(argv, **_kwargs):
        nonlocal status_calls
        call = tuple(str(value) for value in argv)
        if call[-1:] == ("status",):
            status_calls += 1
            return command(call, ok=status_calls > 1, stdout=healthy if status_calls > 1 else unhealthy)
        if call[-2:] == ("doctor", "--json"):
            return command(call, stdout='{"schema_version":1,"overall":"PASS","checks":[]}\n')
        return command(call)

    with mock.patch.object(update.time, "sleep"):
        update._gate_current(layout, runner)
    if status_calls != 2:
        raise SystemExit(f"candidate current-runtime gate did not settle exactly once: {status_calls}")

    # Successful target selection returns the launcher to the stable canonical
    # current/vwctl form and removes the temporary handoff state.
    durability.atomic_symlink(current, Path("releases") / candidate_release)
    if not update_controller_handoff.finalize_if_target_current(
        root=host,
        controller_vwctl=controller,
    ):
        raise SystemExit("successful target selection did not finalize controller handoff")
    if Path(os.readlink(launcher)) != canonical:
        raise SystemExit("successful target selection did not restore canonical vwctl launcher")
    if state_path.exists():
        raise SystemExit("successful target selection left controller handoff state behind")

    print(
        "PASS: actual supported predecessor install handed only update control to the exact staged target, candidate health settling accepted the observed recovery window, and successful target selection restored the canonical launcher"
    )
    return 0


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("candidate_source", type=Path)
    parser.add_argument("host", type=Path)
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    raise SystemExit(main(args.candidate_source, args.host))
