"""Fail-closed guard for an update that may have changed persistent state."""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Mapping

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
    """Atomically block normal start/restart paths with secret-free recovery metadata."""
    payload: dict[str, object] = {
        "schema_version": 1,
        "recovery_required": True,
        "candidate_release": candidate_release,
        "previous_release": previous_release,
    }
    if recovery_artifact is not None:
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
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        os.chmod(path, 0o600)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def load(path: Path = RECOVERY_REQUIRED_STATE) -> dict[str, object] | None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise UpdateGuardError(f"cannot inspect update recovery guard: {exc}") from exc
    if path.is_symlink() or not path.is_file() or info.st_uid != os.geteuid():
        raise UpdateGuardError(f"unsafe update recovery guard path: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
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
    """Clear only the exact regular root-owned guard after coherent recovery succeeds."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        raise UpdateGuardError(f"cannot inspect update recovery guard: {exc}") from exc
    if path.is_symlink() or not path.is_file() or info.st_uid != os.geteuid():
        raise UpdateGuardError(f"unsafe update recovery guard path: {path}")
    path.unlink()
