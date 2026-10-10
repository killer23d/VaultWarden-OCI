"""Optional scheduled offsite publication using the existing .vwrec recovery owner."""
from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Sequence

from . import recovery, runtime
from .cli import LockBusyError, run_command


class OffsiteError(RuntimeError):
    pass


def destination() -> str | None:
    return runtime.load_config().offsite_remote


def status() -> None:
    config = runtime.load_config()
    remote = config.offsite_remote
    local_policy = "keep indefinitely" if config.local_retention_days == 0 else f"prune older than {config.local_retention_days} days"
    remote_policy = "keep indefinitely" if config.remote_retention_days == 0 else f"prune older than {config.remote_retention_days} days"
    print(f"Local retention: {local_policy}")
    print(f"Remote retention: {remote_policy}")
    if remote is None:
        print("INFO: scheduled offsite backup disabled; daily encrypted local backups remain active")
        print("ACTION: sudo vwctl recovery offsite configure")
        return
    ok, message = recovery.rclone_diagnostics(remote)
    print(f"Configured destination: {remote}")
    print(f"{'PASS' if ok else 'FAIL'}: {message}")
    print("Daily backup timer: creates a new local .vwrec, then publishes and re-download-verifies it")
    if not ok:
        raise OffsiteError("scheduled offsite publishing is configured but unavailable")


def _configured_names() -> list[str]:
    result = run_command(["rclone", "listremotes"])
    if not result.ok:
        raise OffsiteError("root rclone configuration unavailable; first run 'sudo rclone config'")
    names = sorted({line.strip().removesuffix(":") for line in result.stdout.splitlines() if line.strip()})
    if not names:
        raise OffsiteError("no root rclone remotes found; first run 'sudo rclone config'")
    return names


def configure(remote: str | None = None, *, interactive: bool = True) -> None:
    if os.geteuid() != 0:
        raise OffsiteError("offsite configuration requires sudo/root")
    if not remote:
        if not interactive or not (sys.stdin.isatty() and sys.stdout.isatty()):
            raise OffsiteError("headless configuration requires --remote REMOTE:folder")
        names = _configured_names()
        print("Choose an already-configured root rclone remote:")
        for i, name in enumerate(names, 1):
            print(f"  {i}) {name}:")
        answer = input("Remote number (q to cancel): ").strip()
        if answer.lower() in {"q", "quit", ""}:
            print("INFO: offsite setup cancelled; existing configuration unchanged")
            return
        try:
            index = int(answer)
        except ValueError as exc:
            raise OffsiteError("invalid remote selection") from exc
        if not 1 <= index <= len(names):
            raise OffsiteError("invalid remote selection")
        folder = input("Destination folder [Vaultwarden-OCI]: ").strip() or "Vaultwarden-OCI"
        remote = f"{names[index - 1]}:{folder}"
    try:
        remote = runtime.backup_remote_destination(remote)
    except runtime.RuntimeConfigError as exc:
        raise OffsiteError(str(exc)) from exc
    if remote is None:
        raise OffsiteError("configure requires a remote; use 'offsite disable' for local-only mode")
    ok, message = recovery.rclone_diagnostics(remote)
    if not ok:
        raise OffsiteError(message)
    if interactive and sys.stdin.isatty() and sys.stdout.isatty():
        print(f"Destination: {remote}")
        print("Only new encrypted .vwrec files are published; no remote objects are deleted.")
        if input("Type ENABLE to activate scheduled offsite backups: ").strip() != "ENABLE":
            print("INFO: offsite setup cancelled; existing configuration unchanged")
            return
    runtime.set_backup_remote(remote)
    print(f"PASS: daily scheduled offsite publication enabled: {remote}")
    print("ACTION: run 'sudo vwctl backup' to create and verify the first offsite recovery point")
    print("ACTION: run 'sudo vwctl recovery offsite status' and 'sudo vwctl timers'")


def disable(*, confirmed: bool) -> None:
    if os.geteuid() != 0:
        raise OffsiteError("offsite configuration requires sudo/root")
    if not confirmed:
        if not (sys.stdin.isatty() and sys.stdout.isatty()):
            raise OffsiteError("headless disable requires --confirm")
        if input("Disable scheduled offsite publishing (keep local backups)? Type DISABLE: ").strip() != "DISABLE":
            print("INFO: cancelled; nothing changed")
            return
    runtime.set_backup_remote("")
    print("PASS: scheduled offsite publishing disabled; existing local/remote recovery points untouched")


def backup(*, override: str | None = None) -> int:
    """One source of truth for manual and timer backup execution."""
    config = runtime.load_config()
    remote = override if override is not None else config.offsite_remote
    if remote:
        runtime.backup_remote_destination(remote)
    verified = recovery.create_recovery(config.offline_recovery_recipient, remote=remote)
    print(f"PASS: verified local recovery {verified.artifact} sha256={verified.sha256}")
    if remote:
        print("PASS: offsite publication was remotely re-downloaded and checksum-verified")

    # Retention is deliberately last. A failed backup/publication never deletes
    # older recovery points, and the just-created verified point is protected.
    if config.local_retention_days > 0:
        deleted = recovery.prune_local_by_age(
            config.local_retention_days,
            preserve=verified.artifact,
        )
        print(
            f"PASS: local retention ({config.local_retention_days} days) removed "
            f"{len(deleted)} expired recovery point(s)"
        )
    if (
        remote
        and override is None
        and remote == config.offsite_remote
        and config.remote_retention_days > 0
    ):
        deleted = recovery.prune_remote_by_age(
            remote,
            config.remote_retention_days,
            preserve_name=verified.artifact.name,
        )
        print(
            f"PASS: remote retention ({config.remote_retention_days} days) removed "
            f"{len(deleted)} expired recovery point(s)"
        )
    return 0
