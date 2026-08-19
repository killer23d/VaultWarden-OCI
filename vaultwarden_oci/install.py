#!/usr/bin/env python3
"""Phase 2 host bootstrap and immutable installed-layout ownership."""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from vaultwarden_oci.cli import load_versions, normalize_architecture

APP_NAME = "vaultwarden-oci"
INSTALL_ROOT = Path("/opt/vaultwarden-oci")
RELEASES_DIR = INSTALL_ROOT / "releases"
CURRENT_LINK = INSTALL_ROOT / "current"
CONFIG_DIR = Path("/etc/vaultwarden-oci")
CONFIG_PATH = CONFIG_DIR / "config.toml"
SECRETS_PATH = CONFIG_DIR / "secrets.sops.yaml"
AGE_KEY_PATH = CONFIG_DIR / "age-key.txt"
STATE_ROOT = Path("/var/lib/vaultwarden-oci")
STATE_DIR = STATE_ROOT / "state"
RUNTIME_ROOT = Path("/run/vaultwarden-oci")
RUNTIME_SECRETS_DIR = RUNTIME_ROOT / "secrets"
RUNTIME_TRANSIENT_DIR = RUNTIME_ROOT / "transient"
LOCK_PATH = RUNTIME_ROOT / "lock"
VWCTL_LINK = Path("/usr/local/bin/vwctl")
SYSTEMD_UNIT = Path("/etc/systemd/system/vaultwarden-oci.target")

CONFIG_TEMPLATE = """# VaultWarden-OCI V2 operator configuration.\n# Phase-specific settings are added by later phases.\n"""
SYSTEMD_TARGET = """[Unit]\nDescription=VaultWarden-OCI lifecycle target\nDocumentation=https://github.com/killer23d/VaultWarden-OCI\nStopWhenUnneeded=no\n"""

_RELEASE_FILES = ("vwctl", "versions.toml")
_RELEASE_DIRS = ("vaultwarden_oci",)
_OPTIONAL_RELEASE_RESOURCES = ("email-providers.toml",)
_RELEASE_NAME_CHARS = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")


class InstallError(RuntimeError):
    """Raised when the installed layout is incompatible or unsafe to change."""


@dataclass(frozen=True)
class HostInfo:
    distro: str
    version: str
    architecture: str


@dataclass(frozen=True)
class Layout:
    root: Path

    def path(self, absolute: Path) -> Path:
        if self.root == Path("/"):
            return absolute
        return self.root / absolute.relative_to("/")


def _parse_os_release(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    with path.open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
                value = value[1:-1]
            values[key] = value
    return values


def validate_host(*, os_release: Path = Path("/etc/os-release"), machine: str | None = None) -> HostInfo:
    try:
        values = _parse_os_release(os_release)
    except OSError as exc:
        raise InstallError(f"cannot read host release information from {os_release}: {exc}") from exc
    distro = values.get("ID", "")
    version = values.get("VERSION_ID", "")
    if distro != "ubuntu" or version != "24.04":
        raise InstallError(
            f"unsupported host {distro or 'unknown'} {version or 'unknown'}; Ubuntu 24.04 is required"
        )
    try:
        architecture = normalize_architecture(machine if machine is not None else platform.machine())
    except ValueError as exc:
        raise InstallError(str(exc)) from exc
    return HostInfo(distro=distro, version=version, architecture=architecture)


def _assert_root(layout: Layout) -> None:
    if layout.root == Path("/") and os.geteuid() != 0:
        raise InstallError("installation into / requires root privileges")


def _validate_release_name(release: str) -> str:
    if release in {".", ".."} or not release or any(char not in _RELEASE_NAME_CHARS for char in release):
        raise InstallError(
            f"unsafe release version {release!r}; use only letters, digits, '.', '_', and '-'"
        )
    return release


def _owned_by_installer(path: Path) -> bool:
    return path.lstat().st_uid == os.geteuid()


def _ensure_directory(path: Path, mode: int) -> None:
    if path.exists() or path.is_symlink():
        if path.is_symlink() or not path.is_dir():
            raise InstallError(f"expected directory at {path}")
        if not _owned_by_installer(path):
            raise InstallError(f"incompatible ownership at {path}: expected uid {os.geteuid()}")
    else:
        path.mkdir(parents=True, mode=mode)
    os.chmod(path, mode)


def _ensure_regular_file(path: Path, content: str, mode: int, *, preserve_existing: bool) -> None:
    if path.exists() or path.is_symlink():
        if path.is_symlink() or not path.is_file():
            raise InstallError(f"expected regular file at {path}")
        if not _owned_by_installer(path):
            raise InstallError(f"incompatible ownership at {path}: expected uid {os.geteuid()}")
        if preserve_existing:
            os.chmod(path, mode)
            return
        existing = path.read_text(encoding="utf-8")
        if existing != content:
            raise InstallError(f"existing file differs from required content: {path}")
        os.chmod(path, mode)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    os.chmod(path, mode)


def _copy_release_tree(source_root: Path, staging: Path) -> None:
    for name in _RELEASE_FILES:
        source = source_root / name
        if not source.is_file():
            raise InstallError(f"required release file is missing: {source}")
        shutil.copy2(source, staging / name)
    for name in _RELEASE_DIRS:
        source = source_root / name
        if not source.is_dir():
            raise InstallError(f"required release directory is missing: {source}")
        shutil.copytree(source, staging / name, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    for name in _OPTIONAL_RELEASE_RESOURCES:
        source = source_root / name
        if source.is_file():
            shutil.copy2(source, staging / name)


def _make_release_immutable(release_dir: Path) -> None:
    for path in sorted(release_dir.rglob("*"), reverse=True):
        if path.is_symlink():
            raise InstallError(f"release must not contain symlinks: {path}")
        if path.is_dir():
            os.chmod(path, 0o555)
        else:
            executable = bool(path.stat().st_mode & stat.S_IXUSR)
            os.chmod(path, 0o555 if executable else 0o444)
    os.chmod(release_dir, 0o555)


def _tree_entries(root: Path) -> list[Path]:
    return [Path(".")] + sorted(path.relative_to(root) for path in root.rglob("*"))


def _same_tree(left: Path, right: Path) -> bool:
    left_entries = _tree_entries(left)
    right_entries = _tree_entries(right)
    if left_entries != right_entries:
        return False
    for relative in left_entries:
        left_path = left if relative == Path(".") else left / relative
        right_path = right if relative == Path(".") else right / relative
        if right_path.is_symlink() or left_path.is_symlink():
            return False
        if left_path.is_dir() != right_path.is_dir():
            return False
        if not _owned_by_installer(right_path):
            raise InstallError(f"incompatible ownership inside immutable release: {right_path}")
        left_mode = stat.S_IMODE(left_path.stat().st_mode)
        right_mode = stat.S_IMODE(right_path.stat().st_mode)
        if left_mode != right_mode:
            raise InstallError(
                f"incompatible mode inside immutable release: {right_path} is {right_mode:04o}, expected {left_mode:04o}"
            )
        if left_path.is_file() and left_path.read_bytes() != right_path.read_bytes():
            return False
    return True


def _install_release(source_root: Path, layout: Layout, release: str) -> Path:
    releases = layout.path(RELEASES_DIR)
    _ensure_directory(layout.path(INSTALL_ROOT), 0o755)
    _ensure_directory(releases, 0o755)
    destination = releases / release

    with tempfile.TemporaryDirectory(prefix=f"{APP_NAME}-release-", dir=str(releases)) as temp_dir:
        staging = Path(temp_dir) / release
        staging.mkdir(mode=0o755)
        _copy_release_tree(source_root, staging)
        _make_release_immutable(staging)
        if destination.exists() or destination.is_symlink():
            if destination.is_symlink() or not destination.is_dir():
                raise InstallError(f"release path is not a directory: {destination}")
            if not _same_tree(staging, destination):
                raise InstallError(
                    f"release {release} already exists with different content; choose a new release version"
                )
            return destination
        os.rename(staging, destination)
    return destination


def _ensure_symlink(path: Path, target: Path) -> None:
    if path.exists() or path.is_symlink():
        if not path.is_symlink():
            raise InstallError(f"expected symlink at {path}")
        if not _owned_by_installer(path):
            raise InstallError(f"incompatible ownership at {path}: expected uid {os.geteuid()}")
        actual = Path(os.readlink(path))
        if actual == target:
            return
        raise InstallError(f"existing symlink {path} points to {actual}, expected {target}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.symlink_to(target)


def install_layout(source_root: Path, *, root: Path = Path("/"), systemd_reload: bool = True) -> str:
    source_root = source_root.resolve()
    layout = Layout(root.resolve())
    _assert_root(layout)
    manifest = load_versions(source_root / "versions.toml")
    release = _validate_release_name(manifest.version)

    release_dir = _install_release(source_root, layout, release)

    config_dir = layout.path(CONFIG_DIR)
    _ensure_directory(config_dir, 0o700)
    _ensure_regular_file(layout.path(CONFIG_PATH), CONFIG_TEMPLATE, 0o600, preserve_existing=True)
    _ensure_regular_file(layout.path(SECRETS_PATH), "", 0o600, preserve_existing=True)
    _ensure_regular_file(layout.path(AGE_KEY_PATH), "", 0o600, preserve_existing=True)

    _ensure_directory(layout.path(STATE_ROOT), 0o700)
    _ensure_directory(layout.path(STATE_DIR), 0o700)
    _ensure_directory(layout.path(RUNTIME_ROOT), 0o700)
    _ensure_directory(layout.path(RUNTIME_SECRETS_DIR), 0o700)
    _ensure_directory(layout.path(RUNTIME_TRANSIENT_DIR), 0o700)
    _ensure_regular_file(layout.path(LOCK_PATH), "", 0o600, preserve_existing=True)

    current = layout.path(CURRENT_LINK)
    target = Path("releases") / release
    _ensure_symlink(current, target)
    _ensure_symlink(layout.path(VWCTL_LINK), layout.path(CURRENT_LINK) / "vwctl")

    unit_path = layout.path(SYSTEMD_UNIT)
    _ensure_regular_file(unit_path, SYSTEMD_TARGET, 0o644, preserve_existing=False)
    if layout.root == Path("/") and systemd_reload:
        result = subprocess.run(
            ["systemctl", "daemon-reload"], check=False, capture_output=True, text=True, shell=False
        )
        if result.returncode != 0:
            raise InstallError(f"systemctl daemon-reload failed: {result.stderr.strip() or result.stdout.strip()}")

    return str(release_dir)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Install the VaultWarden-OCI V2 immutable application layout")
    parser.add_argument("--source", required=True, type=Path, help="repository/release source root")
    parser.add_argument("--root", type=Path, default=Path("/"), help=argparse.SUPPRESS)
    parser.add_argument("--skip-host-check", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--skip-systemd-reload", action="store_true", help=argparse.SUPPRESS)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        if not args.skip_host_check:
            validate_host()
        release_dir = install_layout(
            args.source,
            root=args.root,
            systemd_reload=not args.skip_systemd_reload,
        )
    except (InstallError, ValueError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"PASS: installed immutable release at {release_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
