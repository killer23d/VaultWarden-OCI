#!/usr/bin/env python3
"""Cross-release acceptance for source staging and candidate-owned coherent rollback."""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import runpy
import sys
import tomllib
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

PREVIOUS_VERSION = "0.1.0-dev.15"
TWO_BACK_VERSION = "0.1.0-dev.14"
_DATA_MARKER = Path("var/lib/vaultwarden-oci/state/acceptance-update-data.txt")


def _current_candidate_version() -> str:
    manifest = Path(__file__).resolve().parents[1] / "versions.toml"
    with manifest.open("rb") as handle:
        payload = tomllib.load(handle)
    value = payload.get("vaultwarden_oci", {}).get("version")
    if not isinstance(value, str) or not value:
        raise SystemExit(f"current candidate version is missing from {manifest}")
    return value


CANDIDATE_VERSION = _current_candidate_version()


def _command(cli_module, argv, *, stdout: str = ""):
    return cli_module.CommandResult(
        tuple(str(value) for value in argv),
        "success",
        0,
        stdout,
        "",
    )


def install_previous(source: Path, host: Path) -> None:
    """Use the two-back installer to materialize the supported predecessor exactly."""
    from vaultwarden_oci import cli, install

    installer_root = Path(install.__file__).resolve().parent.parent
    installer_version = cli.load_versions(installer_root / "versions.toml").version
    source_version = cli.load_versions(source / "versions.toml").version
    if installer_version != TWO_BACK_VERSION:
        raise SystemExit(f"expected two-back installer {TWO_BACK_VERSION}, got {installer_version}")
    if source_version != PREVIOUS_VERSION:
        raise SystemExit(f"expected predecessor source {PREVIOUS_VERSION}, got {source_version}")
    if install.SYSTEMD_SOURCE_DIR == "systemd":
        raise SystemExit("two-back installer unexpectedly already uses the canonical systemd source directory")

    installed = Path(
        install.install_layout(
            source,
            root=host,
            systemd_reload=False,
            require_all_architectures=True,
        )
    )
    historical_units = installed / install.SYSTEMD_SOURCE_DIR
    if installed.name != PREVIOUS_VERSION or not historical_units.is_dir():
        raise SystemExit("two-back installer did not materialize the predecessor historical unit layout")
    missing = [unit for unit in install.SYSTEMD_UNITS if not (historical_units / unit).is_file()]
    if missing:
        raise SystemExit("predecessor historical unit layout is incomplete: " + ", ".join(missing))
    if (installed / "systemd").exists():
        raise SystemExit("acceptance predecessor unexpectedly contains a canonical systemd source directory")

    marker = host / _DATA_MARKER
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text("previous-data\n", encoding="utf-8")
    print(
        "PASS: two-back installer materialized supported predecessor using its historical unit layout "
        f"({TWO_BACK_VERSION} -> {PREVIOUS_VERSION})"
    )


def fail_forward_update(candidate_source: Path, host: Path, state_file: Path) -> None:
    """Run the predecessor updater through a post-start failure and leave its durable guard."""
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
    candidate_version = cli.load_versions(candidate_source / "versions.toml").version
    if predecessor_version != PREVIOUS_VERSION:
        raise SystemExit(f"expected predecessor updater {PREVIOUS_VERSION}, got {predecessor_version}")
    if candidate_version != CANDIDATE_VERSION:
        raise SystemExit(f"expected candidate {CANDIDATE_VERSION}, got {candidate_version}")

    layout = install.Layout(host.resolve())
    current_target, current_release, _ = update._current(layout)
    if current_release != PREVIOUS_VERSION:
        raise SystemExit(f"host current release is {current_release}, expected {PREVIOUS_VERSION}")
    frozen = update_versions.resolve_pinned(candidate_source, machine="x86_64")
    plan = update.UpdatePlan(
        source_root=candidate_source.resolve(),
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
        availability_reason="cross-release acceptance",
    )

    artifact = host / "var/lib/vaultwarden-oci/backups/acceptance-pre-update.vwrec"
    marker = host / _DATA_MARKER

    def runner(argv, **_kwargs):
        stopped = "__update-candidate" in [str(value) for value in argv] and str(argv[-1]) == "stop"
        return _command(cli, argv, stdout='{"stopped": true}' if stopped else "")

    def preflight(*_args, **_kwargs):
        return SimpleNamespace(offline_recovery_recipient="age1acceptance")

    def recovery_creator(*_args, **_kwargs):
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.write_text("previous-data\n", encoding="utf-8")
        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        return recovery.VerifiedRecovery(
            artifact=artifact,
            sha256=digest,
            size=artifact.stat().st_size,
            created_at="cross-release-acceptance",
        )

    def activator(_release_dir, _render_root, _runner):
        marker.write_text("candidate-data\n", encoding="utf-8")
        raise update.RuntimeActivationError(
            "acceptance post-start failure",
            state_change_possible=True,
        )

    with mock.patch.object(update_appliance, "_preflight", side_effect=preflight):
        try:
            update_appliance.apply_prepared(
                prepared,
                runner=runner,
                activator=activator,
                recovery_creator=recovery_creator,
            )
        except update_appliance.PersistentStateFailure as failure:
            guard = layout.path(update_guard.RECOVERY_REQUIRED_STATE)
            if not guard.is_file():
                raise SystemExit("predecessor updater did not leave the durable recovery guard")
            if update._current(layout)[1] != CANDIDATE_VERSION:
                raise SystemExit("post-start failure did not leave the candidate selected for guarded recovery")
            candidate = layout.path(install.RELEASES_DIR) / CANDIDATE_VERSION
            installed_units = layout.path(install.SYSTEMD_DIR)
            for unit in install.SYSTEMD_UNITS:
                if (installed_units / unit).read_bytes() != (candidate / install.SYSTEMD_SOURCE_DIR / unit).read_bytes():
                    raise SystemExit(f"candidate unit was not active at persistent-state failure: {unit}")
            if marker.read_text(encoding="utf-8") != "candidate-data\n":
                raise SystemExit("persistent-state failure marker was not changed by the candidate")
            state_file.write_text(
                json.dumps(
                    {
                        "artifact": str(failure.verified.artifact),
                        "sha256": failure.verified.sha256,
                        "previous": failure.plan.current_release,
                        "candidate": failure.plan.target_release,
                    },
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
        else:
            raise SystemExit("predecessor updater unexpectedly accepted the simulated post-start failure")

    print(
        "PASS: supported predecessor performed forward mutation and failed closed after simulated post-start state change "
        f"({PREVIOUS_VERSION} -> {CANDIDATE_VERSION})"
    )


def rollback_with_candidate(host: Path, state_file: Path) -> None:
    """Execute installed candidate vwctl to restore data, old code, units, health, and guard state."""
    from vaultwarden_oci import cli, install, update, update_appliance, update_guard, update_unit_migration

    layout = install.Layout(host.resolve())
    candidate_root = Path(update_appliance.__file__).resolve().parent.parent
    expected_candidate_root = layout.path(install.RELEASES_DIR) / CANDIDATE_VERSION
    if candidate_root != expected_candidate_root.resolve():
        raise SystemExit(
            f"rollback imports are not owned by installed candidate {expected_candidate_root}: {candidate_root}"
        )
    candidate_version = cli.load_versions(candidate_root / "versions.toml").version
    if candidate_version != CANDIDATE_VERSION:
        raise SystemExit(f"expected candidate-owned rollback {CANDIDATE_VERSION}, got {candidate_version}")
    candidate_vwctl = candidate_root / "vwctl"
    if not candidate_vwctl.is_file():
        raise SystemExit(f"installed candidate vwctl is missing: {candidate_vwctl}")

    state = json.loads(state_file.read_text(encoding="utf-8"))
    artifact = Path(state["artifact"])
    failure = update_appliance.reconstruct_failure(
        artifact,
        state["sha256"],
        state["previous"],
        state["candidate"],
        root=host,
    )
    identity = host / "offline-acceptance.age"
    identity.write_text("acceptance identity\n", encoding="utf-8")
    marker = host / _DATA_MARKER
    calls: list[tuple[str, ...]] = []

    def runner(argv, **_kwargs):
        normalized = tuple(str(value) for value in argv)
        calls.append(normalized)
        stopped = "__update-candidate" in normalized and normalized[-1] == "stop"
        return _command(cli, normalized, stdout='{"stopped": true}' if stopped else "")

    @contextlib.contextmanager
    def prepared_restore(requested_artifact, requested_identity, *, runner):
        if requested_artifact != artifact or requested_identity != identity:
            raise AssertionError("rollback did not use the recorded recovery artifact and supplied identity")

        class Prepared:
            def promote_locked(self, *, runner):
                marker.write_bytes(artifact.read_bytes())

        yield Prepared()

    def reconstruct(requested_artifact, requested_sha256, previous_release, candidate_release):
        if (
            requested_artifact != artifact
            or requested_sha256 != state["sha256"]
            or previous_release != state["previous"]
            or candidate_release != state["candidate"]
        ):
            raise AssertionError("installed candidate vwctl changed the recorded rollback identity")
        return failure

    original_coherent_rollback = update_appliance.coherent_rollback

    def coherent_rollback(recorded_failure, requested_identity):
        if recorded_failure is not failure or requested_identity != identity:
            raise AssertionError("installed candidate vwctl did not pass the reconstructed recovery state through")
        return original_coherent_rollback(recorded_failure, requested_identity, runner=runner)

    argv = [
        str(candidate_vwctl),
        "update",
        "rollback",
        "--recovery-artifact",
        str(artifact),
        "--recovery-sha256",
        state["sha256"],
        "--previous-release",
        state["previous"],
        "--candidate-release",
        state["candidate"],
        "--identity",
        str(identity),
        "--yes",
        "--json",
    ]
    with (
        mock.patch.object(update_appliance.storage, "verify"),
        mock.patch.object(update_appliance.update_recovery, "prepare_restore", prepared_restore),
        mock.patch.object(update_appliance, "reconstruct_failure", side_effect=reconstruct),
        mock.patch.object(update_appliance, "coherent_rollback", side_effect=coherent_rollback),
        mock.patch.object(sys, "argv", argv),
    ):
        try:
            runpy.run_path(str(candidate_vwctl), run_name="__main__")
        except SystemExit as exc:
            if exc.code not in (None, 0):
                raise SystemExit(f"installed candidate vwctl rollback failed with exit {exc.code}") from exc
        else:
            raise SystemExit("installed candidate vwctl did not terminate through its normal entrypoint")

    _, active_release, previous = update._current(layout)
    if active_release != PREVIOUS_VERSION:
        raise SystemExit(f"candidate-owned rollback selected {active_release}, expected {PREVIOUS_VERSION}")
    previous_units = update_unit_migration._systemd_source(
        previous,
        allow_supported_predecessor=True,
    )
    installed_units = layout.path(install.SYSTEMD_DIR)
    for unit in install.SYSTEMD_UNITS:
        if (installed_units / unit).read_bytes() != (previous_units / unit).read_bytes():
            raise SystemExit(f"candidate-owned rollback did not restore predecessor unit: {unit}")
    if marker.read_text(encoding="utf-8") != "previous-data\n":
        raise SystemExit("candidate-owned rollback did not restore pre-update data")
    if layout.path(update_guard.RECOVERY_REQUIRED_STATE).exists():
        raise SystemExit("candidate-owned rollback did not clear the exact recovery guard")
    if not any(call and call[-1] == "status" for call in calls):
        raise SystemExit("candidate-owned rollback did not health-check previous status")
    if not any(len(call) >= 2 and call[-2:] == ("doctor", "--json") for call in calls):
        raise SystemExit("candidate-owned rollback did not health-check previous doctor state")

    print(
        "PASS: installed candidate vwctl coherent rollback restored predecessor data, release selection, systemd units, health proof, and guard state "
        f"({CANDIDATE_VERSION} -> {PREVIOUS_VERSION})"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    install_parser = subparsers.add_parser("install-previous")
    install_parser.add_argument("source", type=Path)
    install_parser.add_argument("host", type=Path)

    fail_parser = subparsers.add_parser("fail-forward-update")
    fail_parser.add_argument("candidate_source", type=Path)
    fail_parser.add_argument("host", type=Path)
    fail_parser.add_argument("state_file", type=Path)

    rollback_parser = subparsers.add_parser("rollback-with-candidate")
    rollback_parser.add_argument("host", type=Path)
    rollback_parser.add_argument("state_file", type=Path)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "install-previous":
        install_previous(args.source.resolve(), args.host.resolve())
    elif args.command == "fail-forward-update":
        fail_forward_update(args.candidate_source.resolve(), args.host.resolve(), args.state_file.resolve())
    else:
        rollback_with_candidate(args.host.resolve(), args.state_file.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
