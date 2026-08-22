"""Phase 7 CLI glue for explicit updates and development-only latest installs."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Sequence

from . import cli, install, update
from .update_versions import UpdateError, resolve_pinned_file


def _update_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vwctl update", description="Explicit pinned release update")
    commands = parser.add_subparsers(dest="update_command", required=True)
    for name in ("check", "apply"):
        command = commands.add_parser(name)
        command.add_argument(
            "--source",
            type=Path,
            default=Path.cwd(),
            help="candidate release/checkout root (default: current working directory)",
        )
    return parser


def _print_plan(plan: update.UpdatePlan) -> None:
    print(f"current release: {plan.current_release}")
    print(f"candidate release: {plan.target_release}")
    print(f"architecture: {plan.frozen.architecture}")
    print(
        "components: "
        f"vaultwarden={plan.frozen.vaultwarden} "
        f"caddy={plan.frozen.caddy} "
        f"caddy-dns/cloudflare={plan.frozen.caddy_dns_cloudflare}"
    )
    for pin in (
        plan.frozen.vaultwarden_image,
        plan.frozen.caddy_builder_image,
        plan.frozen.caddy_runtime_image,
    ):
        print(f"{pin.name}: {pin.reference}")
    print("result: already active" if plan.already_active else "result: explicit update available")


def _update_command(argv: Sequence[str]) -> int:
    args = _update_parser().parse_args(argv)
    try:
        plan = update.plan_update(args.source)
        _print_plan(plan)
        if args.update_command == "check":
            return 0
        if plan.already_active:
            print("PASS: requested release is already active")
            return 0
        release = update.apply_update(plan)
        print(f"PASS: activated immutable release {release}")
        return 0
    except (UpdateError, cli.LockBusyError, OSError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


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
    print("\nPhase 7 explicit updates:\n  update {check,apply}    check or apply a pinned immutable release")
    return code


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args in (["--help"], ["-h"]):
        return _print_top_help()
    if args[0] == "update":
        return _update_command(args[1:])
    if args[0] == "install":
        return install.main(args[1:])
    if args[0] == "versions":
        return _versions_command(args)
    return cli.main(args)


if __name__ == "__main__":
    raise SystemExit(main())
