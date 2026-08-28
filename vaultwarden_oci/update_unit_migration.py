"""Transactional systemd unit migration helpers for immutable updates."""
from __future__ import annotations

import os
from pathlib import Path
from typing import Mapping, Sequence

from . import durability, install
from .update_versions import UpdateError

ABSENT_MODE = -1


def _release_barrier(release: Path) -> None:
    """Make one immutable release usable only after its tree and parent entry are durable."""
    durability.fsync_tree(release)
    durability.fsync_directory(release.parent)


def _systemd_source(release: Path) -> Path:
    """Resolve the canonical systemd source for one immutable release."""
    canonical = release / install.SYSTEMD_SOURCE_DIR
    if canonical.is_dir() and not canonical.is_symlink():
        return canonical
    if canonical.exists() or canonical.is_symlink():
        raise UpdateError(f"immutable release systemd source is unsafe: {canonical}")
    raise UpdateError(f"immutable release systemd source is missing or unsafe: {canonical}")


def install_units(new_release: Path, expected_release: Path, layout: install.Layout) -> dict[Path, tuple[bytes, int]]:
    """Move the installed owned-unit set from expected_release to new_release.

    Existing project-owned units must exactly match the expected immutable
    release. A new release may add or remove an owned unit; both transitions
    are snapshotted so a pre-start rollback can reverse them atomically.
    """
    snapshot: dict[Path, tuple[bytes, int]] = {}
    actions: list[tuple[Path, bytes | None]] = []
    new_source = _systemd_source(new_release)
    expected_source = _systemd_source(expected_release)
    for unit in install.SYSTEMD_UNITS:
        new = new_source / unit
        expected = expected_source / unit
        destination = layout.path(install.SYSTEMD_DIR / unit)
        new_exists = new.is_file()
        expected_exists = expected.is_file()
        if not new_exists and not expected_exists:
            continue

        if expected_exists:
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

        actions.append((destination, new.read_bytes() if new_exists else None))

    # No boot-relevant /etc mutation may begin until the selected immutable
    # release is fully durable under /opt (or the test root equivalent).
    _release_barrier(new_release)
    try:
        for destination, content in actions:
            if content is None:
                durability.unlink(destination, missing_ok=True)
            else:
                durability.atomic_write(destination, content, 0o644)
    except (Exception, KeyboardInterrupt):
        restore_units(snapshot)
        raise
    return snapshot


def _state_for_release(release: Path, unit: str) -> bytes | None:
    path = _systemd_source(release) / unit
    return path.read_bytes() if path.is_file() else None


def converge_units(
    new_release: Path,
    allowed_current_releases: Sequence[Path],
    layout: install.Layout,
) -> dict[Path, tuple[bytes, int]]:
    """Converge owned units after a fail-closed/quarantined rollback attempt.

    Every installed unit must be in an exact state owned by one of the supplied
    immutable releases (including exact absence).  This permits retrying after
    a previous transactional restore itself failed part-way, without accepting
    arbitrary administrator drift as project-owned content.
    """
    if not allowed_current_releases:
        raise UpdateError("unit convergence requires at least one allowed immutable release")
    snapshot: dict[Path, tuple[bytes, int]] = {}
    actions: list[tuple[Path, bytes | None]] = []
    for unit in install.SYSTEMD_UNITS:
        desired = _state_for_release(new_release, unit)
        allowed = {_state_for_release(release, unit) for release in allowed_current_releases}
        destination = layout.path(install.SYSTEMD_DIR / unit)

        if destination.exists() or destination.is_symlink():
            try:
                info = destination.lstat()
            except OSError as exc:
                raise UpdateError(f"cannot inspect installed systemd unit {destination}: {exc}") from exc
            if destination.is_symlink() or not destination.is_file() or info.st_uid != os.geteuid():
                raise UpdateError(f"installed systemd unit has incompatible type/ownership: {destination}")
            content: bytes | None = destination.read_bytes()
            if content not in allowed:
                raise UpdateError(f"installed systemd unit drift blocks recovery convergence: {destination}")
            snapshot[destination] = (content, info.st_mode & 0o777)
        else:
            content = None
            if None not in allowed:
                raise UpdateError(f"required project-owned systemd unit is unexpectedly absent: {destination}")
            destination.parent.mkdir(parents=True, exist_ok=True)
            snapshot[destination] = (b"", ABSENT_MODE)

        actions.append((destination, desired))

    # The old immutable release must be durable before old unit files are
    # published during coherent rollback.
    _release_barrier(new_release)
    try:
        for destination, content in actions:
            if content is None:
                durability.unlink(destination, missing_ok=True)
            else:
                durability.atomic_write(destination, content, 0o644)
    except (Exception, KeyboardInterrupt):
        restore_units(snapshot)
        raise
    return snapshot


def restore_units(snapshot: Mapping[Path, tuple[bytes, int]]) -> None:
    failures: list[str] = []
    for path, (content, mode) in snapshot.items():
        try:
            if mode == ABSENT_MODE:
                durability.unlink(path, missing_ok=True)
            else:
                durability.atomic_write(path, content, mode)
        except Exception as exc:
            failures.append(f"{path}: {exc}")
    if failures:
        raise UpdateError("failed to restore systemd unit snapshot: " + "; ".join(failures))
