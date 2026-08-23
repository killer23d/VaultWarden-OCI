"""Transactional systemd unit migration helpers for immutable updates."""
from __future__ import annotations

import os
from pathlib import Path
from typing import Mapping

from . import install, update
from .update_versions import UpdateError

ABSENT_MODE = -1


def install_units(new_release: Path, expected_release: Path, layout: install.Layout) -> dict[Path, tuple[bytes, int]]:
    snapshot: dict[Path, tuple[bytes, int]] = {}
    replacements: list[tuple[Path, bytes]] = []
    for unit in install.SYSTEMD_UNITS:
        new = new_release / install.SYSTEMD_SOURCE_DIR / unit
        expected = expected_release / install.SYSTEMD_SOURCE_DIR / unit
        destination = layout.path(install.SYSTEMD_DIR / unit)
        if not new.is_file():
            raise UpdateError(f"candidate release systemd unit is missing: {unit}")
        if expected.is_file():
            try:
                info = destination.lstat()
            except OSError as exc:
                raise UpdateError(f"cannot inspect installed systemd unit {destination}: {exc}") from exc
            if destination.is_symlink() or not destination.is_file() or info.st_uid != os.geteuid():
                raise UpdateError(f"installed systemd unit has incompatible type/ownership: {destination}")
            content = destination.read_bytes()
            if content != expected.read_bytes():
                raise UpdateError(f"installed systemd unit drift blocks update: {destination}")
            snapshot[destination] = (content, info.st_mode & 0o777)
        else:
            if destination.exists() or destination.is_symlink():
                raise UpdateError(f"new project-owned systemd unit path already exists: {destination}")
            destination.parent.mkdir(parents=True, exist_ok=True)
            snapshot[destination] = (b"", ABSENT_MODE)
        replacements.append((destination, new.read_bytes()))
    try:
        for destination, content in replacements:
            update._atomic_write(destination, content, 0o644)
    except Exception:
        restore_units(snapshot)
        raise
    return snapshot


def restore_units(snapshot: Mapping[Path, tuple[bytes, int]]) -> None:
    failures: list[str] = []
    for path, (content, mode) in snapshot.items():
        try:
            if mode == ABSENT_MODE:
                path.unlink(missing_ok=True)
            else:
                update._atomic_write(path, content, mode)
        except Exception as exc:
            failures.append(f"{path}: {exc}")
    if failures:
        raise UpdateError("failed to restore systemd unit snapshot: " + "; ".join(failures))
