"""Operator CLI glue for appliance updates, recovery, and dedicated-storage gates."""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Sequence

from . import cli, install, storage, update, update_appliance, update_guard
from .update_versions import UpdateError, resolve_pinned_file

_STORAGE_REQUIRED = {"start", "restart", "backup", "restore", "recovery", "edge", "crowdsec", "notify", "notification"}
_STORAGE_DOCTOR_ID = "storage.dedicated"
if _STORAGE_DOCTOR_ID not in cli.DOCTOR_CHECK_IDS:
    position = cli.DOCTOR_CHECK_IDS.index("runtime.paths") + 1
    cli.DOCTOR_CHECK_IDS = (
        *cli.DOCTOR_CHECK_IDS[:position],
        _STORAGE_DOCTOR_ID,
        *cli.DOCTOR_CHECK_IDS[position:],
    )


class UI:
    def __init__(self, *, color: bool | None = None) -> None:
        if color is None:
            color = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
        self.color = color

    def _line(self, label: str, text: str, code: str) -> None:
        prefix = f"\033[{code}m{label}\033[0m" if self.color else label
        print(f"{prefix} {text}")

    def ok(self, text: str) -> None:
        self._line("PASS", text, "32")

    def warn(self, text: str) -> None:
        self._line("WARN", text, "33")

    def info(self, text: str) -> None:
        self._line("INFO", text, "36")

    def action(self, text: str) -> None:
        self._line("ACTION", text, "34")


def _update_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vwctl update", description="Safe immutable project update")
    commands = parser.add_subparsers(dest="update_command", required=True)
    for name in ("check", "apply"):
        command = commands.add_parser(name)
        command.add_argument("--source", type=Path, help=argparse.SUPPRESS)
        command.add_argument(
            "--use-latest",
            action="store_true",
            help="use one frozen snapshot of currently available upstream component/addon versions",
        )
        command.add_argument("--json", action="store_true", help="machine-readable uncolored output")
        if name == "check":
            command.add_argument("--timer", action="store_true", help=argparse.SUPPRESS)
        else:
            command.add_argument("--yes", action="store_true", help="confirm the displayed update plan noninteractively")
            command.add_argument(
                "--rollback-identity",
                type=Path,
                help="explicitly authorize coherent .vwrec+previous-release rollback on post-start failure",
            )
    rollback = commands.add_parser(
        "rollback",
        help="coherently restore a recorded pre-update .vwrec and previous immutable release",
    )
    rollback.add_argument("--recovery-artifact", type=Path, required=True)
    rollback.add_argument("--recovery-sha256", required=True)
    rollback.add_argument("--previous-release", required=True)
    rollback.add_argument(
        "--candidate-release",
        required=True,
        help="failed immutable candidate recorded by update apply",
    )
    rollback.add_argument("--identity", type=Path, required=True)
    rollback.add_argument("--yes", action="store_true")
    rollback.add_argument("--json", action="store_true")
    return parser


def _host_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vwctl host-upgrade", description="Separate Ubuntu host package maintenance")
    commands = parser.add_subparsers(dest="host_command", required=True)
    check = commands.add_parser("check")
    check.add_argument("--json", action="store_true")
    apply = commands.add_parser("apply")
    apply.add_argument("--yes", action="store_true")
    apply.add_argument("--json", action="store_true")
    return parser


def _require_storage(*, machine: bool = False) -> bool:
    try:
        storage.verify()
        return True
    except storage.StorageError as exc:
        if machine:
            print(
                json.dumps(
                    {
                        "schema_version": 1,
                        "error": f"dedicated production storage is not ready: {exc}",
                        "action": (
                            f"restore/mount the filesystem recorded by {storage.HOST_IDENTITY_FILE} "
                            f"at {storage.STATE_ROOT}, then retry"
                        ),
                    },
                    sort_keys=True,
                ),
                file=sys.stderr,
            )
        else:
            print(f"FAIL: dedicated production storage is not ready: {exc}", file=sys.stderr)
            print(
                f"ACTION: restore/mount the filesystem recorded by {storage.HOST_IDENTITY_FILE} "
                f"at {storage.STATE_ROOT}, then retry.",
                file=sys.stderr,
            )
        return False


def _guard_state() -> dict[str, object] | None:
    try:
        return update_guard.load()
    except update_guard.UpdateGuardError as exc:
        raise UpdateError(str(exc)) from exc


def _guard_recovery_command(state: dict[str, object]) -> str | None:
    candidate = state.get("candidate_release")
    previous = state.get("previous_release")
    artifact = state.get("recovery_artifact")
    sha256 = state.get("recovery_sha256")
    if not all(isinstance(value, str) and value for value in (candidate, previous, artifact, sha256)):
        return None
    return (
        f"/opt/vaultwarden-oci/releases/{candidate}/vwctl update rollback "
        f"--recovery-artifact {artifact} --recovery-sha256 {sha256} "
        f"--previous-release {previous} --candidate-release {candidate} "
        "--identity /path/to/offline-age-identity.txt --yes"
    )


def _guard_error(*, machine: bool) -> bool:
    state = _guard_state()
    if state is None:
        return False
    command = _guard_recovery_command(state)
    message = "coherent update recovery is required before this mutation is allowed"
    if machine:
        payload: dict[str, object] = {
            "schema_version": 1,
            "error": message,
            "recovery_required": True,
        }
        if command is not None:
            payload["recovery_command"] = command
        print(json.dumps(payload, sort_keys=True), file=sys.stderr)
    else:
        print(f"FAIL: {message}", file=sys.stderr)
        if command is not None:
            print(f"ACTION: {command}", file=sys.stderr)
        else:
            print("ACTION: use the recorded failed-update recovery instructions before starting or restoring application state", file=sys.stderr)
    return True


def _current_frozen(plan: update.UpdatePlan):
    layout = install.Layout(plan.root.resolve())
    _, _, current = update._current(layout)
    return resolve_pinned_file(current / "versions.toml", machine=plan.frozen.architecture)


def _plan_payload(prepared: update_appliance.PreparedPlan) -> dict[str, object]:
    plan = prepared.plan
    current = _current_frozen(plan)
    return {
        "schema_version": 1,
        "current": {
            "project": plan.current_release,
            "vaultwarden": current.vaultwarden,
            "caddy": current.caddy,
            "caddy_dns_cloudflare": current.caddy_dns_cloudflare,
            "caddy_cloudflare_ip": current.caddy_cloudflare_ip,
            "caddy_combine_ip_ranges": current.caddy_combine_ip_ranges,
            "caddy_ratelimit": current.caddy_ratelimit,
        },
        "candidate": {
            "project": plan.target_release,
            "vaultwarden": plan.frozen.vaultwarden,
            "caddy": plan.frozen.caddy,
            "caddy_dns_cloudflare": plan.frozen.caddy_dns_cloudflare,
            "caddy_cloudflare_ip": plan.frozen.caddy_cloudflare_ip,
            "caddy_combine_ip_ranges": plan.frozen.caddy_combine_ip_ranges,
            "caddy_ratelimit": plan.frozen.caddy_ratelimit,
        },
        "architecture": plan.frozen.architecture,
        "use_latest": prepared.use_latest,
        "available": prepared.available,
        "availability_reason": prepared.availability_reason,
        "already_active": plan.already_active,
        "project_release_tag": prepared.project_release.tag if prepared.project_release else None,
    }


def _print_plan(prepared: update_appliance.PreparedPlan, ui: UI) -> None:
    payload = _plan_payload(prepared)
    current = payload["current"]
    candidate = payload["candidate"]
    assert isinstance(current, dict) and isinstance(candidate, dict)
    ui.info(f"architecture: {payload['architecture']}")
    labels = (
        ("project", "VaultWarden-OCI"),
        ("vaultwarden", "Vaultwarden"),
        ("caddy", "Caddy"),
        ("caddy_dns_cloudflare", "xcaddy caddy-dns/cloudflare"),
        ("caddy_cloudflare_ip", "xcaddy cloudflare-ip"),
        ("caddy_combine_ip_ranges", "xcaddy combine-ip-ranges"),
        ("caddy_ratelimit", "xcaddy rate-limit"),
    )
    for key, label in labels:
        before, after = current[key], candidate[key]
        marker = "=" if before == after else "->"
        print(f"  {label}: {before} {marker} {after}")
    if prepared.use_latest:
        ui.warn(
            "--use-latest bypasses the project's tested release pins; this exact resolved snapshot will be frozen for this update."
        )
    if not prepared.available:
        ui.ok(prepared.availability_reason)
        return
    ui.info("rollback boundary: before candidate start, old code/systemd is restored and health-proved automatically")
    ui.info(
        "after candidate start, old code is never launched against possibly-new data; coherent rollback requires the verified pre-update .vwrec plus the previous immutable release"
    )


def _confirm(prompt: str, *, yes: bool) -> bool:
    if yes:
        return True
    if not sys.stdin.isatty():
        print("FAIL: noninteractive operation requires --yes", file=sys.stderr)
        return False
    try:
        return input(prompt).strip().lower() in {"y", "yes"}
    except EOFError:
        return False


def _persistent_payload(
    failure: update_appliance.PersistentStateFailure,
    *,
    rollback_attempted: bool,
    rollback_succeeded: bool,
    rollback_error: str | None = None,
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "error": str(failure),
        "possible_persistent_state_change": True,
        "old_code_auto_started": False,
        "services_stopped": failure.services_stopped,
        "recovery_artifact": str(failure.verified.artifact),
        "recovery_sha256": failure.verified.sha256,
        "previous_release": failure.plan.current_release,
        "candidate_release": failure.plan.target_release,
        "recovery_command": update_appliance.recovery_command(failure),
        "rollback_attempted": rollback_attempted,
        "rollback_succeeded": rollback_succeeded,
        "rollback_error": rollback_error,
    }


def _handle_persistent_failure(
    failure: update_appliance.PersistentStateFailure,
    *,
    identity: Path | None,
    ui: UI,
    machine: bool = False,
) -> int:
    if machine:
        if identity is None:
            print(
                json.dumps(
                    _persistent_payload(
                        failure,
                        rollback_attempted=False,
                        rollback_succeeded=False,
                    ),
                    sort_keys=True,
                ),
                file=sys.stderr,
            )
            return 1
        try:
            update_appliance.coherent_rollback(failure, identity)
        except Exception as exc:
            print(
                json.dumps(
                    _persistent_payload(
                        failure,
                        rollback_attempted=True,
                        rollback_succeeded=False,
                        rollback_error=str(exc),
                    ),
                    sort_keys=True,
                ),
                file=sys.stderr,
            )
            return 1
        print(
            json.dumps(
                _persistent_payload(
                    failure,
                    rollback_attempted=True,
                    rollback_succeeded=True,
                ),
                sort_keys=True,
            ),
            file=sys.stderr,
        )
        return 1

    print(f"FAIL: {failure}", file=sys.stderr)
    print(f"ACTION: {update_appliance.recovery_command(failure)}", file=sys.stderr)
    if identity is not None:
        try:
            update_appliance.coherent_rollback(failure, identity)
            ui.ok("coherent rollback restored pre-update application state and previous immutable code; previous stack is healthy")
            return 1
        except Exception as exc:
            print(f"FAIL: coherent rollback failed: {exc}", file=sys.stderr)
            return 1
    if not sys.stdin.isatty():
        print(
            "ACTION: no data restore was attempted noninteractively; candidate services remain stopped/failed safe for troubleshooting.",
            file=sys.stderr,
        )
        return 1
    try:
        answer = input(
            "Candidate may have changed persistent state. [1] coherent rollback  [2] leave safely stopped for troubleshooting: "
        ).strip()
    except EOFError:
        answer = "2"
    if answer != "1":
        ui.action("services remain safely stopped/failed safe; no destructive data restore was attempted")
        return 1
    try:
        identity_text = input("Path to the matching offline Age identity: ").strip()
    except EOFError:
        identity_text = ""
    if not identity_text:
        ui.action("no identity supplied; services remain stopped and the verified recovery artifact is unchanged")
        return 1
    try:
        update_appliance.coherent_rollback(failure, Path(identity_text))
        ui.ok("coherent rollback restored pre-update application state and previous immutable code; previous stack is healthy")
    except Exception as exc:
        print(f"FAIL: coherent rollback failed: {exc}", file=sys.stderr)
    return 1


def _rollback_command(args: argparse.Namespace, ui: UI) -> int:
    if not _require_storage(machine=args.json):
        return 1
    if args.json and not args.yes:
        print(
            json.dumps(
                {"schema_version": 1, "error": "--yes is required with --json update rollback"},
                sort_keys=True,
            ),
            file=sys.stderr,
        )
        return 2
    if not args.json and not _confirm(
        "Restore this exact pre-update .vwrec and previous immutable release now? [y/N]: ",
        yes=args.yes,
    ):
        ui.action("coherent rollback cancelled before data mutation")
        return 2
    failure = update_appliance.reconstruct_failure(
        args.recovery_artifact,
        args.recovery_sha256,
        args.previous_release,
        args.candidate_release,
    )
    update_appliance.coherent_rollback(failure, args.identity)
    if args.json:
        print(
            json.dumps(
                {
                    "schema_version": 1,
                    "result": "rolled_back",
                    "recovery_artifact": str(args.recovery_artifact),
                    "recovery_sha256": args.recovery_sha256,
                    "previous_release": args.previous_release,
                    "candidate_release": args.candidate_release,
                },
                sort_keys=True,
            )
        )
    else:
        ui.ok("pre-update application state and previous immutable release restored; previous stack is healthy")
    return 0


def _update_command(argv: Sequence[str]) -> int:
    args = _update_parser().parse_args(argv)
    ui = UI(color=False if args.json else None)
    current_for_error = "unknown"
    try:
        if args.update_command == "rollback":
            return _rollback_command(args, ui)
        if not _require_storage(machine=args.json):
            return 1
        if args.update_command == "apply" and _guard_error(machine=args.json):
            return 1
        try:
            current_for_error = update._current(install.Layout(Path("/")))[1]
        except Exception:
            pass
        with update_appliance.candidate_source(args.source) as (source, project_release):
            prepared = update_appliance.prepare_plan(
                source,
                project_release=project_release,
                use_latest=args.use_latest,
            )
            payload = _plan_payload(prepared)
            if args.json:
                print(json.dumps(payload, sort_keys=True))
            else:
                _print_plan(prepared, ui)
            if args.update_command == "check":
                if args.timer:
                    update_appliance.record_check(
                        current=prepared.plan.current_release,
                        candidate=prepared.plan.target_release,
                        available=prepared.available,
                        error=None,
                    )
                return 0
            if not prepared.available:
                return 0
            if args.json and not args.yes:
                print(
                    json.dumps(
                        {"schema_version": 1, "error": "--yes is required with --json apply"},
                        sort_keys=True,
                    ),
                    file=sys.stderr,
                )
                return 2
            if not args.json and not _confirm(
                "Apply this exact update now? A verified .vwrec will be created before the short maintenance boundary. [y/N]: ",
                yes=args.yes,
            ):
                ui.action("update cancelled before mutation")
                return 2
            try:
                release = update_appliance.apply_prepared(prepared)
            except update_appliance.PersistentStateFailure as failure:
                return _handle_persistent_failure(
                    failure,
                    identity=args.rollback_identity,
                    ui=ui,
                    machine=args.json,
                )
            if args.json:
                print(
                    json.dumps(
                        {"schema_version": 1, "result": "applied", "release": str(release)},
                        sort_keys=True,
                    )
                )
            else:
                ui.ok(f"activated and health-gated immutable release {release}")
            return 0
    except (UpdateError, install.InstallError, cli.LockBusyError, storage.StorageError, OSError) as exc:
        if args.update_command == "check" and getattr(args, "timer", False):
            try:
                update_appliance.record_check(
                    current=current_for_error,
                    candidate=None,
                    available=False,
                    error=str(exc),
                )
            except Exception:
                pass
        if args.json:
            print(json.dumps({"schema_version": 1, "error": str(exc)}, sort_keys=True), file=sys.stderr)
        else:
            print(f"FAIL: {exc}", file=sys.stderr)
        return 1


def _host_upgrade_command(argv: Sequence[str]) -> int:
    args = _host_parser().parse_args(argv)
    ui = UI(color=False if args.json else None)
    try:
        if args.host_command == "check":
            count, reboot, _ = update_appliance.host_upgrade_check()
            payload = {
                "schema_version": 1,
                "packages_available": count,
                "reboot_required_now": reboot,
                "package_indexes_refreshed": True,
            }
            if args.json:
                print(json.dumps(payload, sort_keys=True))
            else:
                ui.info(f"Ubuntu packages available to upgrade: {count}")
                ui.info(f"reboot currently required: {'yes' if reboot else 'no'}")
                ui.warn(
                    "host package changes are separate from the application update transaction; .vwrec cannot roll back apt, kernel, Docker, or other system packages"
                )
            return 0
        if _guard_error(machine=args.json):
            return 1
        if not _require_storage(machine=args.json):
            return 1
        if args.json and not args.yes:
            print(
                json.dumps(
                    {"schema_version": 1, "error": "--yes is required with --json host-upgrade apply"},
                    sort_keys=True,
                ),
                file=sys.stderr,
            )
            return 2
        if not args.json:
            ui.warn("Ubuntu host packages will be upgraded separately from VaultWarden-OCI application code.")
            ui.warn(
                "The verified .vwrec created first can restore application data/config only; it cannot undo apt/kernel/system package changes."
            )
            ui.info("No reboot will be performed automatically.")
            if not _confirm("Apply conservative Ubuntu package upgrades now? [y/N]: ", yes=args.yes):
                return 2
        verified, reboot = update_appliance.host_upgrade_apply()
        payload = {
            "schema_version": 1,
            "result": "applied",
            "application_recovery_artifact": str(verified.artifact),
            "application_recovery_sha256": verified.sha256,
            "reboot_required": reboot,
            "auto_rebooted": False,
        }
        if args.json:
            print(json.dumps(payload, sort_keys=True))
        else:
            ui.ok(
                f"Ubuntu package upgrade completed; application recovery point: {verified.artifact} sha256={verified.sha256}"
            )
            ui.info(f"reboot required: {'yes' if reboot else 'no'}; the appliance was not rebooted automatically")
        return 0
    except (UpdateError, install.InstallError, cli.LockBusyError, storage.StorageError, OSError) as exc:
        if args.json:
            print(json.dumps({"schema_version": 1, "error": str(exc)}, sort_keys=True), file=sys.stderr)
        else:
            print(f"FAIL: {exc}", file=sys.stderr)
        return 1


def _doctor_command(args: Sequence[str]) -> int:
    checks = cli.doctor_checks()
    try:
        identity = storage.verify()
    except storage.StorageError as exc:
        storage_check = cli.DoctorCheck(_STORAGE_DOCTOR_ID, "FAIL", str(exc))
    else:
        storage_check = cli.DoctorCheck(
            _STORAGE_DOCTOR_ID,
            "PASS",
            f"dedicated state filesystem UUID={identity.uuid} mounted at {identity.mount}",
        )
    checks.insert(cli.DOCTOR_CHECK_IDS.index(_STORAGE_DOCTOR_ID), storage_check)
    payload = cli.doctor_payload(checks)
    if "--json" in args:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        for check in checks:
            print(f"[{check.status}] {check.check_id}: {check.message}")
        print(f"Overall: {payload['overall']}")
    return 1 if payload["overall"] == "FAIL" else 0


def _versions_command(args: Sequence[str]) -> int:
    code = cli.main(args)
    if code != 0:
        return code
    try:
        frozen = resolve_pinned_file(Path(__file__).resolve().parents[1] / "versions.toml")
    except UpdateError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"architecture {frozen.architecture}")
    for label, pin in (
        ("vaultwarden_image", frozen.vaultwarden_image),
        ("caddy_builder", frozen.caddy_builder_image),
        ("caddy_runtime", frozen.caddy_runtime_image),
    ):
        print(f"{label} {pin.reference}")
    return 0


def _print_top_help() -> int:
    code = cli.main([])
    print(
        "\nEnhanced recovery:\n"
        "  recovery {list,verify,prune}  inventory, verify, or prune recovery points\n"
        "  restore                       guided TTY picker or explicit restore\n"
        "  recovery-kit export           complete AES-256 credential handoff"
    )
    print(
        "\nSafe project updates:\n"
        "  update check                  discover newest stable project release without mutation\n"
        "  update apply                  pre-stage exact runtime, verify recovery, then activate\n"
        "  update rollback               coherent recorded .vwrec + previous-release recovery\n"
        "  update ... --use-latest       freeze currently available upstream component/addon refs"
    )
    print(
        "\nSeparate Ubuntu maintenance:\n"
        "  host-upgrade {check,apply}     apt/package maintenance; never claims .vwrec can undo OS changes"
    )
    return code


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args[:1] == ["__update-candidate"]:
        from . import update_candidate

        return update_candidate.main(args[1:])
    if not args or args in (["--help"], ["-h"]):
        return _print_top_help()
    if args[0] == "doctor":
        if any(flag in args[1:] for flag in ("--help", "-h")):
            return cli.main(args)
        return _doctor_command(args[1:])
    if args[0] == "update":
        return _update_command(args[1:])
    if args[0] == "host-upgrade":
        return _host_upgrade_command(args[1:])

    help_requested = any(flag in args[1:] for flag in ("--help", "-h"))
    if help_requested:
        if args[0] in {"restore", "recovery", "recovery-kit"}:
            from . import recovery_ux

            return recovery_ux.main(args)
        if args[0] == "install":
            return install.main(args[1:])
        return cli.main(args)

    if args[0] in {"start", "restart", "restore", "install"} and _guard_error(machine=False):
        return 1
    if args[0] == "install":
        if not _require_storage():
            return 1
        return install.main(args[1:])
    if args[0] == "versions":
        return _versions_command(args)
    if args[0] in {"restore", "recovery", "recovery-kit"}:
        from . import recovery_ux

        if args[0] in {"restore", "recovery"} and not _require_storage():
            return 1
        return recovery_ux.main(args)
    if args[0] == "crowdsec" and len(args) > 1 and args[1] in {"decisions", "unban"}:
        return cli.main(args)
    if args[0] in _STORAGE_REQUIRED and not _require_storage():
        return 1
    return cli.main(args)


if __name__ == "__main__":
    raise SystemExit(main())
