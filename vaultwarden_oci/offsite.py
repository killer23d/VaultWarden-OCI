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
        print("INFO: remote publishing is disabled: every scheduled/manual backup is currently LOCAL-ONLY")
        print("INFO: rclone credentials alone do not authorize an upload destination")
        print("ACTION: choose the destination once with 'sudo vwctl recovery offsite configure'")
        return
    ok, message = recovery.rclone_destination_diagnostics(remote)
    print(f"Configured destination: {remote}")
    print(f"{'PASS' if ok else 'FAIL'}: {message}")
    print("PASS: the SAME backup command (scheduled or manual) creates a local .vwrec,")
    print("      then publishes and re-download-verifies that exact recovery point to this destination")
    print("INFO: no separate remote backup timer or per-backup upload command is needed")
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
            print("INFO: offsite setup cancelled; existing configuration and remote are unchanged")
            return
    ok, message = recovery.prepare_rclone_destination(remote)
    if not ok:
        raise OffsiteError(message)
    runtime.set_backup_remote(remote)
    print(f"PASS: automatic offsite publication enabled for EVERY local backup: {remote}")
    print("INFO: both the existing daily timer and manual 'sudo vwctl backup' now upload")
    print("      each new encrypted recovery point and verify its remote copy")
    print("ACTION: optionally run 'sudo vwctl backup' to verify publication immediately")
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
    """One local snapshot, optionally mirrored in the SAME job; no remote timer.

    The saved backup.remote opt-in is the only authority for routine offsite
    publication. Do not guess a cloud destination from root's rclone config.
    A one-time --remote overrides this invocation without changing the policy.
    """
    config = runtime.load_config()
    remote = override if override is not None else config.offsite_remote
    if remote:
        runtime.backup_remote_destination(remote)
        print(f"INFO: this backup will create a local .vwrec and publish the same point to {remote}")
    else:
        print("INFO: LOCAL-ONLY backup: no saved offsite destination; enable once with")
        print("      'sudo vwctl recovery offsite configure' to mirror EVERY future backup")
    verified = recovery.create_recovery(
        config.offline_recovery_recipient,
        remote=remote,
        require_current_remote=(override is None),
    )
    print(f"PASS: verified local recovery {verified.artifact} sha256={verified.sha256}")
    if remote:
        print("PASS: offsite publication was remotely re-downloaded and checksum-verified")

    # Retention is deliberately last. A failed backup/publication never deletes
    # older recovery points, and the just-created verified point is protected.
    retention_remote = (
        remote
        if remote and override is None and remote == config.offsite_remote
        else None
    )
    local_deleted, remote_deleted = recovery.apply_retention(
        config.local_retention_days,
        remote=retention_remote,
        remote_days=config.remote_retention_days,
        preserve=verified,
        expected_backup_policy=(
            config.offsite_remote, config.local_retention_days, config.remote_retention_days
        ),
    )
    if config.local_retention_days > 0:
        print(
            f"PASS: local retention ({config.local_retention_days} days) removed "
            f"{len(local_deleted)} expired recovery point(s)"
        )
    if retention_remote and config.remote_retention_days > 0:
        print(
            f"PASS: remote retention ({config.remote_retention_days} days) removed "
            f"{len(remote_deleted)} expired recovery point(s)"
        )
    return 0
