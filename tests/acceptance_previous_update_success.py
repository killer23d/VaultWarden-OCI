#!/usr/bin/env python3
"""Prove the actual supported predecessor can complete a successful forward update."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


def main(candidate_source: Path, host: Path) -> int:
    # PYTHONPATH intentionally points at the actual predecessor worktree. Every
    # updater owner imported here therefore belongs to the supported predecessor.
    from vaultwarden_oci import (
        cli,
        install,
        recovery,
        update,
        update_appliance,
        update_guard,
        update_versions,
    )

    predecessor_root = Path(update_appliance.__file__).resolve().parent.parent
    predecessor_version = cli.load_versions(predecessor_root / "versions.toml").version
    candidate_source = candidate_source.resolve()
    candidate_version = cli.load_versions(candidate_source / "versions.toml").version
    if predecessor_version.split(".latest.", 1)[0] != "0.1.0-dev.16":
        raise SystemExit(f"expected actual supported predecessor dev.16, got {predecessor_version}")
    if candidate_version.split(".latest.", 1)[0] != "0.1.0-dev.17":
        raise SystemExit(f"expected candidate dev.17, got {candidate_version}")

    layout = install.Layout(host.resolve())
    current_target, current_release, _ = update._current(layout)
    if current_release != predecessor_version:
        raise SystemExit(
            f"successful-forward host is {current_release}, expected predecessor {predecessor_version}"
        )
    frozen = update_versions.resolve_pinned(candidate_source, machine="x86_64")
    plan = update.UpdatePlan(
        source_root=candidate_source,
        root=host.resolve(),
        current_target=current_target,
        current_release=current_release,
        target_release=frozen.project_version,
        frozen=frozen,
    )
    prepared = update_appliance.PreparedPlan(
        plan=plan,
        project_release=None,
        use_latest=False,
        available=True,
        availability_reason="successful direct-predecessor acceptance",
    )

    events: list[str] = []
    calls: list[tuple[str, ...]] = []
    marker = host / "var/lib/vaultwarden-oci/state/acceptance-success-data.txt"
    artifact = host / "var/lib/vaultwarden-oci/backups/acceptance-success-pre-update.vwrec"
    config = SimpleNamespace(offline_recovery_recipient="age1acceptance")

    def command(argv, *, stdout: str = ""):
        return cli.CommandResult(
            tuple(str(value) for value in argv),
            "success",
            0,
            stdout,
            "",
        )

    def runner(argv, **_kwargs):
        call = tuple(str(value) for value in argv)
        calls.append(call)
        return command(call)

    def candidate_prepare(exact_source: Path, _render_root: Path, *, runner):
        prepared_version = cli.load_versions(exact_source / "versions.toml").version
        if prepared_version != candidate_version:
            raise AssertionError(
                f"predecessor delegated pre-stage for {prepared_version}, expected {candidate_version}"
            )
        events.append("candidate-prestage")

    def recovery_creator(*_args, **_kwargs):
        events.append("recovery")
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.write_text("pre-update-data\n", encoding="utf-8")
        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        return recovery.VerifiedRecovery(
            artifact=artifact,
            sha256=digest,
            size=artifact.stat().st_size,
            created_at="successful-forward-acceptance",
        )

    def activator(release_dir: Path, _render_root: Path, _runner):
        if release_dir.name != candidate_version:
            raise AssertionError("predecessor activated the wrong immutable candidate")
        events.append("candidate-activate")
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text("candidate-running\n", encoding="utf-8")

    with (
        mock.patch.object(update_appliance.runtime, "load_config", return_value=config),
        mock.patch.object(update_appliance.secrets, "load", return_value={}),
        mock.patch.object(update_appliance, "_disk_space"),
        mock.patch.object(
            update_appliance,
            "_prepare_candidate_release",
            side_effect=candidate_prepare,
        ),
    ):
        release = update_appliance.apply_prepared(
            prepared,
            runner=runner,
            activator=activator,
            recovery_creator=recovery_creator,
        )

    if release.name != candidate_version:
        raise SystemExit(f"successful forward update returned {release.name}, expected {candidate_version}")
    if update._current(layout)[1] != candidate_version:
        raise SystemExit("actual predecessor updater did not select the candidate release")
    if events != ["candidate-prestage", "recovery", "candidate-activate"]:
        raise SystemExit(f"unexpected successful update ordering: {events}")
    if marker.read_text(encoding="utf-8") != "candidate-running\n":
        raise SystemExit("successful candidate activation marker is missing")
    if layout.path(update_guard.RECOVERY_REQUIRED_STATE).exists():
        raise SystemExit("successful predecessor update left the recovery-required guard engaged")

    candidate = layout.path(install.RELEASES_DIR) / candidate_version
    installed_units = layout.path(install.SYSTEMD_DIR)
    for unit in install.SYSTEMD_UNITS:
        if (installed_units / unit).read_bytes() != (candidate / install.SYSTEMD_SOURCE_DIR / unit).read_bytes():
            raise SystemExit(f"successful predecessor update did not install candidate unit: {unit}")

    candidate_vwctl = str(layout.path(install.CURRENT_LINK) / "vwctl")
    if not any(call == (candidate_vwctl, "status") for call in calls):
        raise SystemExit("successful predecessor update did not run the candidate status gate")
    if not any(call == (candidate_vwctl, "doctor", "--json") for call in calls):
        raise SystemExit("successful predecessor update did not run the candidate doctor gate")
    if not any(call == (candidate_vwctl, "crowdsec", "status") for call in calls):
        raise SystemExit("successful predecessor update did not run the candidate CrowdSec gate")

    print(
        "PASS: actual supported predecessor updater completed a successful dev.16 -> dev.17 transaction with candidate pre-stage before recovery, candidate health/CrowdSec gates, and no recovery guard left behind"
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
