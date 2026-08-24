"""Fail-closed guard for an update that may have changed persistent state."""
from __future__ import annotations

import json
import os
from pathlib import Path

from . import durability

RECOVERY_REQUIRED_STATE = Path("/var/lib/vaultwarden-oci/state/update-recovery-required.json")


class UpdateGuardError(RuntimeError):
    pass


def engage(
    *,
    candidate_release: str,
    previous_release: str,
    recovery_artifact: str | None = None,
    recovery_sha256: str | None = None,
    path: Path = RECOVERY_REQUIRED_STATE,
) -> None:
    """Atomically and durably block normal start/restart paths.

    File fsync alone is insufficient for a newly replaced directory entry.  The
    shared durability boundary fsyncs the recovery artifact first, the temporary
    guard file before publication, and the containing guard directory after
    ``replace`` returns.  Later /etc or /opt mutations therefore cannot be
    reached until both the rollback artifact and guard are durable on their
    respective filesystems.
    """
    payload: dict[str, object] = {
        "schema_version": 1,
        "recovery_required": True,
        "candidate_release": candidate_release,
        "previous_release": previous_release,
    }
    if recovery_artifact is not None:
        artifact = Path(recovery_artifact)
        durability.fsync_file_and_parent(artifact)
        payload["recovery_artifact"] = recovery_artifact
    if recovery_sha256 is not None:
        payload["recovery_sha256"] = recovery_sha256
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    try:
        fd = os.open(
            tmp,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fchmod(handle.fileno(), 0o600)
            os.fsync(handle.fileno())
        durability.replace(tmp, path)
    except (Exception, KeyboardInterrupt):
        tmp.unlink(missing_ok=True)
        raise


def _expected_owner(path: Path) -> int:
    return 0 if path == RECOVERY_REQUIRED_STATE else os.geteuid()


def load(path: Path = RECOVERY_REQUIRED_STATE) -> dict[str, object] | None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    except PermissionError:
        # A non-root caller unable to inspect the root-owned guard must fail
        # closed rather than accidentally permit a start/restart operation.
        if os.geteuid() != 0 and path == RECOVERY_REQUIRED_STATE:
            return {
                "schema_version": 1,
                "recovery_required": True,
                "detail": "root-owned recovery guard is not readable by this caller",
            }
        raise
    except OSError as exc:
        raise UpdateGuardError(f"cannot inspect update recovery guard: {exc}") from exc
    if path.is_symlink() or not path.is_file() or info.st_uid != _expected_owner(path):
        raise UpdateGuardError(f"unsafe update recovery guard path: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except PermissionError:
        if os.geteuid() != 0 and path == RECOVERY_REQUIRED_STATE:
            return {
                "schema_version": 1,
                "recovery_required": True,
                "detail": "root-owned recovery guard is not readable by this caller",
            }
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise UpdateGuardError(f"cannot load update recovery guard: {exc}") from exc
    if (
        not isinstance(value, dict)
        or value.get("schema_version") != 1
        or value.get("recovery_required") is not True
    ):
        raise UpdateGuardError("update recovery guard has invalid content")
    return value


def active(path: Path = RECOVERY_REQUIRED_STATE) -> bool:
    return load(path) is not None


def clear(path: Path = RECOVERY_REQUIRED_STATE) -> None:
    """Clear only the exact regular expected-owner guard after coherent recovery succeeds."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        raise UpdateGuardError(f"cannot inspect update recovery guard: {exc}") from exc
    if path.is_symlink() or not path.is_file() or info.st_uid != _expected_owner(path):
        raise UpdateGuardError(f"unsafe update recovery guard path: {path}")
    try:
        durability.unlink(path)
    except OSError as exc:
        raise UpdateGuardError(f"cannot durably clear update recovery guard {path}: {exc}") from exc
