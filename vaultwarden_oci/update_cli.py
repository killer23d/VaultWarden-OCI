"""CLI glue for explicit updates plus the dedicated-storage runtime gate."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from . import cli, install, storage, update
from .update_versions import UpdateError, resolve_pinned_file

_STORAGE_REQUIRED = {"start", "restart", "backup", "restore", "recovery", "edge", "crowdsec", "notify"}
_STORAGE_DOCTOR_ID = "storage.dedicated"
if _STORAGE_DOCTOR_ID not in cli.DOCTOR_CHECK_IDS:
    position = cli.DOCTOR_CHECK_IDS.index("runtime.paths") + 1
    cli.DOCTOR_CHECK_IDS = (*cli.DOCTOR_CHECK_IDS[:position], _STORAGE_DOCTOR_ID, *cli.DOCTOR_CHECK_IDS[position:])


def _update_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vwctl update", description="Explicit pinned release update")
    commands = parser.add_subparsers(dest="update_command", required=True)
    for name in ("check", "apply"):
        command = commands.add_parser(name)
        command.add_argument("--source", type=Path, default=Path.cwd(), help="candidate release/checkout root (default: current working directory)")
    return parser


def _print_plan(plan: update.UpdatePlan) -> None:
    print(f"current release: {plan.current_release}"); print(f"candidate release: {plan.target_release}"); print(f"architecture: {plan.frozen.architecture}")
    print("components: " f"vaultwarden={plan.frozen.vaultwarden} " f"caddy={plan.frozen.caddy} " f"caddy-dns/cloudflare={plan.frozen.caddy_dns_cloudflare}")
    for pin in (plan.frozen.vaultwarden_image, plan.frozen.caddy_builder_image, plan.frozen.caddy_runtime_image): print(f"{pin.name}: {pin.reference}")
    print("result: already active" if plan.already_active else "result: explicit update available")


def _require_storage() -> bool:
    try: storage.verify(); return True
    except storage.StorageError as exc:
        print(f"FAIL: dedicated production storage is not ready: {exc}", file=sys.stderr)
        print(f"ACTION: restore/mount the filesystem recorded by {storage.HOST_IDENTITY_FILE} at {storage.STATE_ROOT}, then retry.", file=sys.stderr); return False


def _doctor_command(args: Sequence[str]) -> int:
    checks = cli.doctor_checks()
    try: identity = storage.verify()
    except storage.StorageError as exc: storage_check = cli.DoctorCheck(_STORAGE_DOCTOR_ID, "FAIL", str(exc))
    else: storage_check = cli.DoctorCheck(_STORAGE_DOCTOR_ID, "PASS", f"dedicated state filesystem UUID={identity.uuid} mounted at {identity.mount}")
    checks.insert(cli.DOCTOR_CHECK_IDS.index(_STORAGE_DOCTOR_ID), storage_check); payload = cli.doctor_payload(checks)
    if "--json" in args: print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        for check in checks: print(f"[{check.status}] {check.check_id}: {check.message}")
        print(f"Overall: {payload['overall']}")
    return 1 if payload["overall"] == "FAIL" else 0


def _update_command(argv: Sequence[str]) -> int:
    args = _update_parser().parse_args(argv)
    try:
        plan = update.plan_update(args.source)
        if getattr(plan, "root", None) == Path("/") and not _require_storage(): return 1
        _print_plan(plan)
        if args.update_command == "check": return 0
        if plan.already_active: print("PASS: requested release is already active"); return 0
        release = update.apply_update(plan); print(f"PASS: activated immutable release {release}"); return 0
    except (UpdateError, install.InstallError, cli.LockBusyError, OSError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr); return 1


def _versions_command(args: Sequence[str]) -> int:
    code = cli.main(args)
    if code != 0: return code
    try: frozen = resolve_pinned_file(Path(__file__).resolve().parents[1] / "versions.toml")
    except UpdateError as exc: print(f"FAIL: {exc}", file=sys.stderr); return 1
    print(f"architecture {frozen.architecture}")
    for label, pin in (("vaultwarden_image", frozen.vaultwarden_image), ("caddy_builder", frozen.caddy_builder_image), ("caddy_runtime", frozen.caddy_runtime_image)): print(f"{label} {pin.reference}")
    return 0


def _print_top_help() -> int:
    code = cli.main([])
    print("\nEnhanced recovery:\n  recovery {list,verify,prune}  inventory, verify, or prune recovery points\n  restore                       guided TTY picker or explicit restore\n  recovery-kit export           complete AES-256 credential handoff")
    print("\nExplicit updates:\n  update {check,apply}    check or apply a pinned immutable release")
    return code


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args in (["--help"], ["-h"]): return _print_top_help()
    if args[0] == "doctor":
        if any(flag in args[1:] for flag in ("--help", "-h")): return cli.main(args)
        return _doctor_command(args[1:])
    if args[0] == "update": return _update_command(args[1:])
    if args[0] == "install":
        if not _require_storage(): return 1
        return install.main(args[1:])
    if args[0] == "versions": return _versions_command(args)
    if args[0] in {"restore", "recovery", "recovery-kit"}:
        from . import recovery_ux, sevenzip_secure
        recovery_ux._seven = sevenzip_secure.run
        if any(flag in args[1:] for flag in ("--help", "-h")):
            return recovery_ux.main(args)
        if args[0] in {"restore", "recovery"} and not _require_storage():
            return 1
        return recovery_ux.main(args)
    if args[0] in _STORAGE_REQUIRED and not _require_storage(): return 1
    return cli.main(args)


if __name__ == "__main__": raise SystemExit(main())
