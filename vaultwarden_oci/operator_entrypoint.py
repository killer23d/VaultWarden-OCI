"""Installed vwctl entrypoint behavior for long-running lifecycle commands."""
from __future__ import annotations

import json
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


def _cosmetic_override(args: Sequence[str]) -> int | None:
    """Keep machine contracts in cli/day2 while restoring the proven human presentation."""
    from . import operator_cosmetics

    command = tuple(args)
    if command == ("status",) and sys.stdout.isatty():
        return operator_cosmetics.status()
    if command == ("timers",) and sys.stdout.isatty():
        return operator_cosmetics.timers()
    if command == ("notification", "test"):
        return operator_cosmetics.notification_test(smtp_only=False)
    if command == ("notification", "test", "--smtp"):
        return operator_cosmetics.notification_test(smtp_only=True)
    if len(command) == 3 and command[:2] == ("notify", "--event"):
        return operator_cosmetics.notify_failure(command[2])
    return None


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


def _legacy_transition_pending() -> bool:
    from . import operator_settings

    try:
        return operator_settings.legacy_admin_active()
    except (operator_settings.OperatorSettingError, OSError):
        return False


def _completion_guidance(args: Sequence[str], code: int) -> None:
    """Add bounded human next-actions without changing machine/read-model contracts."""
    if not _colorable(args) or not sys.stdout.isatty():
        return

    if args[:1] == ["doctor"] and code != 0:
        try:
            checks = cli.doctor_checks()
        except (OSError, RuntimeError, ValueError):
            checks = []
        crowdsec_failures = {
            check.check_id
            for check in checks
            if check.check_id.startswith("crowdsec.") and check.status == "FAIL"
        }
        foundational = {"crowdsec.engine", "crowdsec.hub", "crowdsec.firewall"}
        if crowdsec_failures & foundational:
            print(
                "ACTION: complete CrowdSec protection with 'sudo vwctl crowdsec setup'; "
                "configure cloudflare_remediation_token first if setup reports it missing, then follow the displayed Worker Route Fail Open steps."
            )
        elif "crowdsec.cloudflare" in crowdsec_failures:
            print(
                "ACTION: re-arm the boot-disabled CrowdSec Cloudflare Worker with "
                "'sudo vwctl crowdsec remediation-start', set every recreated Worker Route to Fail Open, "
                "then run 'sudo vwctl crowdsec confirm-fail-open'."
            )

    if args[:1] == ["start"] and code == 0:
        action = _automation_enable_action()
        if action is not None:
            print(
                "ACTION: create and verify the first application recovery point with 'sudo vwctl backup', "
                "then run the post-start acceptance check with 'sudo vwctl doctor'; after both succeed, "
                "enable persistent appliance automation with 'sudo systemctl enable --now vaultwarden-oci.target' "
                "and run 'sudo vwctl timers'."
            )
    elif args[:1] == ["timers"] and code != 0:
        action = _automation_enable_action()
        if action is not None:
            print(action)

    remind = (
        code == 0
        and tuple(args[:2]) not in {("config", "edit"), ("secrets", "edit")}
        and (args[:1] in (["start"], ["status"], ["doctor"]) or args[:2] == ["update", "apply"])
    )
    if remind and _legacy_transition_pending():
        print(
            "ACTION: a pre-existing Vaultwarden Admin config remains temporarily authoritative "
            "to preserve its policy. Run 'sudo vwctl config edit' to reconcile the supported "
            "values and explicitly finalize the one-time transition."
        )


def _display_legacy_report(report: object) -> None:
    differences = tuple(getattr(report, "differences", ()))
    discard_keys = tuple(getattr(report, "discard_keys", ()))
    legacy_path = getattr(report, "legacy_path", "legacy config.json")
    print(
        f"NOTICE: {legacy_path} remains temporarily authoritative so an upgrade does not "
        "silently replace existing Vaultwarden Admin policy."
    )
    if differences:
        print("Supported values that still differ from config.toml:")
        for difference in differences:
            print(
                f"  {difference.target}: legacy={json.dumps(difference.legacy_value, ensure_ascii=False)} "
                f"config={json.dumps(difference.current_value, ensure_ascii=False)}"
            )
    if discard_keys:
        print(
            "NOTICE: finalizing will stop honoring these legacy-only, incompatible, or "
            "sensitive keys (values are intentionally not displayed): "
            + ", ".join(discard_keys)
        )


def _legacy_transition_after_edit(args: Sequence[str], code: int) -> int:
    """Reconcile an old Admin config before switching its durable authority off."""
    if code != 0 or tuple(args[:2]) not in {("config", "edit"), ("secrets", "edit")}:
        return code

    from . import operator_settings, runtime, secrets, storage

    try:
        if not operator_settings.legacy_admin_active():
            return code
        storage.verify()
        config = runtime.load_config()
        values = secrets.load(config.offline_recovery_recipient)
        report = operator_settings.legacy_admin_report(config, values)
    except (
        operator_settings.OperatorSettingError,
        runtime.RuntimeConfigError,
        secrets.SecretsError,
        storage.StorageError,
        OSError,
    ) as exc:
        print(f"FAIL: legacy Vaultwarden Admin reconciliation could not be evaluated: {exc}", file=sys.stderr)
        return 1

    if not report.active:
        return code
    _display_legacy_report(report)
    if report.differences:
        print(
            "ACTION: copy the supported legacy values above into config.toml with "
            "'sudo vwctl config edit'. The legacy file stays effective until they match."
        )
        return code

    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print(
            "ACTION: rerun 'sudo vwctl config edit' interactively to explicitly finalize "
            "the reconciled legacy Admin configuration before switching to appliance-only authority."
        )
        return code

    answer = input(
        "Finalize the reconciled legacy Vaultwarden Admin config and use config.toml/SOPS after restart? [y/N]: "
    ).strip().lower()
    if answer not in {"y", "yes"}:
        print(
            "ACTION: the legacy Admin config remains effective. Run 'sudo vwctl config edit' "
            "again when you are ready to finalize the transition."
        )
        return code

    try:
        with cli.mutation_lock(runtime.LOCK):
            storage.verify()
            current_config = runtime.load_config()
            current_values = secrets.load(current_config.offline_recovery_recipient)
            current_report = operator_settings.legacy_admin_report(current_config, current_values)
            if current_report.differences:
                raise operator_settings.OperatorSettingError(
                    "supported legacy Admin values changed during reconciliation; review config.toml again"
                )
            operator_settings.finalize_legacy_admin(current_report, confirm=True)
    except (
        operator_settings.OperatorSettingError,
        runtime.RuntimeConfigError,
        secrets.SecretsError,
        storage.StorageError,
        cli.LockBusyError,
        RuntimeError,
        OSError,
    ) as exc:
        print(f"FAIL: legacy Vaultwarden Admin transition was not finalized: {exc}", file=sys.stderr)
        return 1

    print(
        "PASS: legacy Vaultwarden Admin configuration was explicitly reconciled; "
        "the next start/restart will use config.toml/SOPS as the sole durable authority"
    )
    return code


def _restart_after_edit(args: Sequence[str], code: int) -> int:
    """Offer an immediate restart after a successful interactive config/secret edit."""
    if code != 0 or tuple(args[:2]) not in {("config", "edit"), ("secrets", "edit")}:
        return code
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        return code

    from . import runtime

    if _legacy_transition_pending():
        print(
            "ACTION: restart is deferred while the pre-existing Vaultwarden Admin config "
            "remains authoritative; reconcile/finalize it first."
        )
        return code

    try:
        state, _ = runtime.status(runner=_BASE_RUN_COMMAND)
    except Exception:
        state = "unknown"
    if state == "stopped":
        print("ACTION: the stack is stopped; the validated changes will apply on the next 'sudo vwctl start'.")
        return code
    if state not in {"running", "degraded"}:
        print(
            f"ACTION: stack state is {state}; apply the validated changes later with 'sudo vwctl restart'."
        )
        return code

    answer = input("Restart VaultWarden-OCI now to apply these changes? [y/N]: ").strip().lower()
    if answer not in {"y", "yes"}:
        print("ACTION: restart later with 'sudo vwctl restart' to apply the validated changes.")
        return code
    try:
        runtime.lifecycle("restart", runner=lifecycle_run_command)
    except (runtime.RuntimeConfigError, runtime.RuntimeOperationError, cli.LockBusyError, OSError) as exc:
        print(f"FAIL: changes were committed but restart failed: {exc}", file=sys.stderr)
        print("ACTION: correct the runtime issue and run 'sudo vwctl restart'.", file=sys.stderr)
        return 1
    print("PASS: restart completed; validated config/credential changes are active")
    return 0


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
        with _human_output(args):
            try:
                override = _cosmetic_override(args)
                code = update_cli.main(args) if override is None else override
            except KeyboardInterrupt:
                print(file=sys.stderr)
                cleanup_ok = _cleanup_interrupted_lifecycle(lifecycle_action or "")
                print(f"FAIL: {lifecycle_action or 'vwctl'} interrupted", file=sys.stderr)
                return 130 if cleanup_ok else 1
            code = _legacy_transition_after_edit(args, code)
            _completion_guidance(args, code)
            return _restart_after_edit(args, code)
    finally:
        cli.run_command = _BASE_RUN_COMMAND
