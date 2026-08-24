"""Filesystem durability barriers for crash-safe update/recovery publication.

Atomic rename/replace gives process-level atomicity but does not by itself make a
new directory entry durable across sudden power loss.  These helpers pair file
content fsync with explicit directory fsync barriers so update ordering can be
reasoned about across /var/lib, /etc, and /opt independently.
"""
from __future__ import annotations

import errno
import os
import shutil
import stat
from pathlib import Path
from typing import Iterable


def _readonly_flags() -> int:
    return os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)


def fsync_file(path: Path) -> None:
    """Synchronize one existing regular file, including its metadata."""
    fd = os.open(path, _readonly_flags())
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise OSError(errno.EINVAL, f"durability file is not regular: {path}")
        os.fsync(fd)
    finally:
        os.close(fd)


def fsync_directory(path: Path) -> None:
    """Synchronize a directory inode and its entry updates."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_DIRECTORY", 0)
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISDIR(info.st_mode):
            raise OSError(errno.ENOTDIR, f"durability path is not a directory: {path}")
        os.fsync(fd)
    finally:
        os.close(fd)


def fsync_directories(paths: Iterable[Path]) -> None:
    """Establish a completed barrier on every distinct supplied directory."""
    seen: set[Path] = set()
    for path in paths:
        absolute = path.absolute()
        if absolute in seen:
            continue
        seen.add(absolute)
        fsync_directory(path)


def fsync_tree(path: Path) -> None:
    """Synchronize a complete regular-file/directory tree bottom-up.

    The caller can then publish the already-durable tree with ``replace`` and
    synchronize only the destination parent directory entry.
    """
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode):
        raise OSError(errno.ELOOP, f"durability tree must not be a symlink: {path}")
    if stat.S_ISREG(info.st_mode):
        fsync_file(path)
        return
    if not stat.S_ISDIR(info.st_mode):
        raise OSError(errno.EINVAL, f"unsupported durability tree type: {path}")

    directories: list[Path] = []
    for child in path.rglob("*"):
        child_info = child.lstat()
        if stat.S_ISLNK(child_info.st_mode):
            raise OSError(errno.ELOOP, f"durability tree contains a symlink: {child}")
        if stat.S_ISREG(child_info.st_mode):
            fsync_file(child)
        elif stat.S_ISDIR(child_info.st_mode):
            directories.append(child)
        else:
            raise OSError(errno.EINVAL, f"unsupported durability tree entry: {child}")
    for directory in sorted(directories, key=lambda item: len(item.parts), reverse=True):
        fsync_directory(directory)
    fsync_directory(path)


def fsync_file_and_parent(path: Path) -> None:
    """Prove an existing file and its containing directory entry durable."""
    fsync_file(path)
    fsync_directory(path.parent)


def replace(source: Path, destination: Path) -> None:
    """Atomically replace/rename and durably publish both affected directories."""
    source_parent = source.parent
    destination_parent = destination.parent
    os.replace(source, destination)
    # The destination entry is the safety-critical publication point.  If the
    # rename crossed directories on one filesystem, the removed source entry
    # must be synchronized independently as well.
    fsync_directory(destination_parent)
    if source_parent != destination_parent:
        fsync_directory(source_parent)


def unlink(path: Path, *, missing_ok: bool = False) -> bool:
    """Remove one non-directory entry and durably publish its absence."""
    try:
        os.unlink(path)
    except FileNotFoundError:
        if missing_ok:
            return False
        raise
    fsync_directory(path.parent)
    return True


def remove(path: Path, *, missing_ok: bool = False) -> bool:
    """Remove a file/symlink/tree and durably publish the top-level absence."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        if missing_ok:
            return False
        raise
    if stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode):
        shutil.rmtree(path)
        fsync_directory(path.parent)
        return True
    return unlink(path, missing_ok=missing_ok)
