"""Installed vwctl entrypoint behavior for long-running lifecycle commands."""
from __future__ import annotations

import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator, Mapping, Sequence

from . import cli, operator_output

_BASE_RUN_COMMAND = cli.run_command
_LIFECYCLE_ACTIONS = {"start", "restart"}
_COMPOSE_LIFECYCLE_STARTED = False


def _is_compose_up(argv: Sequence[str]) -> bool:
    args = tuple(argv)
    return (
        len(args) >= 6
        and args[:3] == ("docker", "compose", "-f")
        and "up" in args[4:]
    )


def lifecycle_run_command(
    argv: Sequence[str],
    *,
    env: Mapping[str, str] | None = None,
    cwd: Path | None = None,
) -> cli.CommandResult:
    """Stream Compose lifecycle output while retaining captured output elsewhere."""
    if not _is_compose_up(argv):
        return _BASE_RUN_COMMAND(argv, env=env, cwd=cwd)

    if isinstance(argv, (str, bytes)):
        raise TypeError("argv must be a sequence of strings")
    args = tuple(argv)
    if not args or not all(isinstance(item, str) for item in args):
        raise ValueError("argv must contain at least one string")

    global _COMPOSE_LIFECYCLE_STARTED
    _COMPOSE_LIFECYCLE_STARTED = True
    print(
        "INFO: Docker Compose build/start output follows; the initial custom Caddy build can be lengthy.",
        flush=True,
    )
    try:
        completed = subprocess.run(
            list(args),
            check=False,
            text=True,
            shell=False,
            env=dict(env) if env is not None else None,
            cwd=str(cwd) if cwd else None,
        )
    except FileNotFoundError as exc:
        return cli.CommandResult(args, "not_found", None, "", str(exc))
    return cli.CommandResult(
        args,
        "success" if completed.returncode == 0 else "nonzero",
        completed.returncode,
        "",
        "",
    )


def _cleanup_interrupted_lifecycle(action: str) -> bool:
    """Use the existing lifecycle owner after Compose has actually begun."""
    if action not in _LIFECYCLE_ACTIONS or not _COMPOSE_LIFECYCLE_STARTED:
        return True
    from . import runtime

    print(
        "INFO: lifecycle interrupted; cleaning partial containers and volatile runtime state.",
        file=sys.stderr,
        flush=True,
    )
    try:
        runtime.lifecycle("stop", runner=_BASE_RUN_COMMAND)
    except Exception as exc:
        print(f"FAIL: interrupted lifecycle cleanup failed: {exc}", file=sys.stderr)
        return False
    return True


def _colorable(args: Sequence[str]) -> bool:
    """Keep structured output and raw application logs byte-stable."""
    return "--json" not in args and args[:1] != ["logs"]


@contextmanager
def _human_output(args: Sequence[str]) -> Iterator[None]:
    stdout, stderr = sys.stdout, sys.stderr
    if not _colorable(args):
        yield
        return
    sys.stdout = operator_output.ColorizingWriter(stdout)
    sys.stderr = operator_output.ColorizingWriter(stderr)
    try:
        yield
    finally:
        sys.stdout, sys.stderr = stdout, stderr


@contextmanager
def _release_edge_policy() -> Iterator[None]:
    """Compose the release-specific Worker source invariant into public checks.

    ``edge.doctor_checks`` remains the mechanical edge owner. The installed
    operator entrypoint adds the dev.17 release invariant so every public
    doctor/status/CrowdSec-status path sees the same truth without duplicating
    those command implementations.
    """
    from . import crowdsec_worker_policy, edge

    original = edge.doctor_checks

    # Preserve the mechanical owner's positional-compatible call shape. This is
    # a read-model composition boundary, not a replacement API.
    def checked(paths=edge.EdgePaths(), runner=None, now=None):
        effective_runner = cli.run_command if runner is None else runner
        checks = original(paths=paths, runner=effective_runner, now=now)
        return crowdsec_worker_policy.enforce_doctor_checks(
            checks,
            paths=paths,
            runner=effective_runner,
        )

    edge.doctor_checks = checked
    try:
        yield
    finally:
        edge.doctor_checks = original


def _attest_supported_worker_start(args: Sequence[str], code: int) -> int:
    """A supported remediation-start is not successful until policy is attested."""
    if code != 0 or list(args[:2]) != ["crowdsec", "remediation-start"]:
        return code
    from . import crowdsec_worker_policy, edge

    try:
        crowdsec_worker_policy.attest_current(edge.EdgePaths(), cli.run_command)
    except crowdsec_worker_policy.WorkerPolicyError as exc:
        print(f"FAIL: Cloudflare Worker started but its local-only policy cannot be proven: {exc}", file=sys.stderr)
        return 1
    return 0


def _automation_enable_action() -> str | None:
    """Return the supported first-run automation action only when it is needed."""
    from . import day2

    try:
        target = day2.automation_snapshot()["target"]
    except (OSError, RuntimeError, TypeError, KeyError):
        return None
    if not isinstance(target, dict):
        return None
    if target.get("enabled") in {"enabled", "enabled-runtime"} and target.get("active_state") == "active":
        return None
    return (
        "ACTION: enable persistent appliance automation with "
        "'sudo systemctl enable --now vaultwarden-oci.target', then run 'sudo vwctl timers'."
    )


def _completion_guidance(args: Sequence[str], code: int) -> None:
    """Add bounded human next-actions without changing machine/read-model contracts."""
    if not _colorable(args) or not sys.stdout.isatty():
        return

    if args[:1] == ["doctor"] and code != 0:
        try:
            checks = cli.doctor_checks()
        except (OSError, RuntimeError, ValueError):
            checks = []
        if any(check.check_id.startswith("crowdsec.") and check.status == "FAIL" for check in checks):
            print(
                "ACTION: complete CrowdSec protection with 'sudo vwctl crowdsec setup'; "
                "configure cloudflare_remediation_token first if setup reports it missing, then follow the displayed Worker Route Fail Open steps."
            )

    if (args[:1] == ["start"] and code == 0) or (args[:1] == ["timers"] and code != 0):
        action = _automation_enable_action()
        if action is not None:
            print(action)


def main(argv: Sequence[str] | None = None) -> int:
    global _COMPOSE_LIFECYCLE_STARTED
    _COMPOSE_LIFECYCLE_STARTED = False
    args = list(sys.argv[1:] if argv is None else argv)
    lifecycle_action = args[0] if args and args[0] in _LIFECYCLE_ACTIONS else None

    if lifecycle_action is not None:
        # update_cli imports the runtime owners. Installing the runner first keeps
        # the lifecycle mutation logic unchanged while making its long Compose
        # build/start subprocess visible to the operator.
        cli.run_command = lifecycle_run_command

    from . import update_cli

    try:
        with _release_edge_policy(), _human_output(args):
            try:
                code = update_cli.main(args)
            except KeyboardInterrupt:
                print(file=sys.stderr)
                cleanup_ok = _cleanup_interrupted_lifecycle(lifecycle_action or "")
                print(f"FAIL: {lifecycle_action or 'vwctl'} interrupted", file=sys.stderr)
                return 130 if cleanup_ok else 1
            code = _attest_supported_worker_start(args, code)
            _completion_guidance(args, code)
            return code
    finally:
        cli.run_command = _BASE_RUN_COMMAND
