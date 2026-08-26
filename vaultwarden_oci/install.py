#!/usr/bin/env python3
"""Immutable installed-layout ownership for VaultWarden-OCI."""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import stat
import sys
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

from vaultwarden_oci import durability
from vaultwarden_oci.cli import (
    DEFAULT_CONFIG_PATH,
    GLOBAL_LOCK_PATH,
    OS_RELEASE_PATH,
    LockBusyError,
    load_versions,
    mutation_lock,
    normalize_architecture,
    run_command,
)

APP_NAME = "vaultwarden-oci"
INSTALL_ROOT = Path("/opt/vaultwarden-oci")
RELEASES_DIR = INSTALL_ROOT / "releases"
CURRENT_LINK = INSTALL_ROOT / "current"
CONFIG_DIR = DEFAULT_CONFIG_PATH.parent
CONFIG_PATH = DEFAULT_CONFIG_PATH
SECRETS_PATH = CONFIG_DIR / "secrets.sops.yaml"
AGE_KEY_PATH = CONFIG_DIR / "age-key.txt"
STATE_ROOT = Path("/var/lib/vaultwarden-oci")
STATE_DIR = STATE_ROOT / "state"
RUNTIME_ROOT = GLOBAL_LOCK_PATH.parent
RUNTIME_SECRETS_DIR = RUNTIME_ROOT / "secrets"
RUNTIME_TRANSIENT_DIR = RUNTIME_ROOT / "transient"
VWCTL_LINK = Path("/usr/local/bin/vwctl")
SYSTEMD_DIR = Path("/etc/systemd/system")
SYSTEMD_SOURCE_DIR = "systemd"
# Source-only compatibility input for the immediately preceding updater.
# New release staging deliberately ignores this directory.
PREVIOUS_SYSTEMD_SOURCE_DIR = "systemd-v2"
SYSTEMD_UNITS = (
    "vaultwarden-oci.target",
    "vaultwarden-oci.service",
    "vaultwarden-oci-health.service",
    "vaultwarden-oci-health.timer",
    "vaultwarden-oci-backup.service",
    "vaultwarden-oci-backup.timer",
    "vaultwarden-oci-maintenance.service",
    "vaultwarden-oci-maintenance.timer",
    "vaultwarden-oci-update-check.service",
    "vaultwarden-oci-update-check.timer",
    "vaultwarden-oci-notify@.service",
)

CONFIG_TEMPLATE = """# VaultWarden-OCI operator configuration.
# Replace the reserved .invalid values and offline Age recipient before first start.
# Secrets belong in /etc/vaultwarden-oci/secrets.sops.yaml, never in this file.
schema_version = 1

[site]
domain = "vault.invalid"
acme_email = "admin@vault.invalid"

[secrets]
# Public recipient for a distinct offline recovery Age identity. Keep its private key off-host.
offline_recovery_recipient = "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"

[vaultwarden]
signups_allowed = false

[smtp]
# Direct authenticated TLS SMTP used by Vaultwarden and operational fallback.
host = "smtp.invalid"
port = 587
security = "starttls"
from_email = "vaultwarden@vault.invalid"
from_name = "Vaultwarden"
timeout_seconds = 15

# Optional operational notifications. Uncomment this table as a unit after configuring SOPS email_api_token.
# [notifications]
# provider = "cyberpersons"
# to_email = "ops@vault.invalid"
#
# Provider options are allowed only when declared by the immutable catalog. Mailgun example:
# [notifications.options]
# region = "us"
# domain = "mg.vault.invalid"
"""

RELEASE_FILES = ("vwctl", "versions.toml", "email-providers.toml")
RELEASE_DIRS = ("vaultwarden_oci", SYSTEMD_SOURCE_DIR)
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


def validate_host(*, os_release: Path = OS_RELEASE_PATH, machine: str | None = None) -> HostInfo:
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


def validate_release_name(release: str) -> str:
    """Validate a release directory name for installer/update ownership."""
    return _validate_release_name(release)


def _owned_by_installer(path: Path) -> bool:
    return path.lstat().st_uid == os.geteuid()


def _ensure_directory(path: Path, mode: int) -> None:
    try:
        path.mkdir(parents=True, mode=mode, exist_ok=True)
    except OSError:
        if not (path.exists() or path.is_symlink()):
            raise
    if path.is_symlink() or not path.is_dir():
        raise InstallError(f"expected directory at {path}")
    if not _owned_by_installer(path):
        raise InstallError(f"incompatible ownership at {path}: expected uid {os.geteuid()}")
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


def _ensure_lock_path(layout: Layout) -> Path:
    """Create/validate the canonical lock inode before acquiring the global flock."""
    runtime_root = layout.path(GLOBAL_LOCK_PATH.parent)
    _ensure_directory(runtime_root, 0o700)
    lock_path = layout.path(GLOBAL_LOCK_PATH)

    while not (lock_path.exists() or lock_path.is_symlink()):
        try:
            descriptor = os.open(
                lock_path,
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
            )
        except FileExistsError:
            continue
        except OSError as exc:
            raise InstallError(f"cannot create mutation lock {lock_path}: {exc}") from exc
        else:
            os.close(descriptor)
            break

    if lock_path.is_symlink() or not lock_path.is_file():
        raise InstallError(f"expected regular file at {lock_path}")
    if not _owned_by_installer(lock_path):
        raise InstallError(
            f"incompatible ownership at {lock_path}: expected uid {os.geteuid()}"
        )
    os.chmod(lock_path, 0o600)
    return lock_path


def ensure_lock_path(layout: Layout) -> Path:
    """Expose the installer-owned canonical mutation-lock path to update orchestration."""
    return _ensure_lock_path(layout)


def _copy_release_tree(source_root: Path, staging: Path) -> None:
    for name in RELEASE_FILES:
        source = source_root / name
        if not source.is_file():
            raise InstallError(f"required release file is missing: {source}")
        shutil.copy2(source, staging / name)
    for name in RELEASE_DIRS:
        source = source_root / name
        if not source.is_dir():
            raise InstallError(f"required release directory is missing: {source}")
        shutil.copytree(source, staging / name, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))


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


def _remove_release_staging(staging: Path) -> None:
    """Best-effort cleanup for a possibly read-only unpublished staging tree."""
    if not staging.exists() and not staging.is_symlink():
        return
    if staging.is_symlink() or not staging.is_dir():
        staging.unlink(missing_ok=True)
        return
    for path in sorted((item for item in staging.rglob("*") if item.is_dir()), reverse=True):
        try:
            os.chmod(path, 0o700)
        except OSError:
            pass
    try:
        os.chmod(staging, 0o700)
    except OSError:
        pass
    shutil.rmtree(staging, ignore_errors=True)


def _install_release(source_root: Path, layout: Layout, release: str) -> Path:
    releases = layout.path(RELEASES_DIR)
    _ensure_directory(layout.path(INSTALL_ROOT), 0o755)
    _ensure_directory(releases, 0o755)
    destination = releases / release
    staging = Path(
        tempfile.mkdtemp(
            prefix=f".{APP_NAME}-release-{release}-",
            dir=str(releases),
        )
    )
    try:
        _copy_release_tree(source_root, staging)
        # Freeze and synchronize the complete sibling staging tree before it
        # can appear at the canonical immutable release path.  The durable
        # rename plus releases-directory fsync is the publication boundary.
        _make_release_immutable(staging)
        durability.fsync_tree(staging)
        if destination.exists() or destination.is_symlink():
            if destination.is_symlink() or not destination.is_dir():
                raise InstallError(f"release path is not a directory: {destination}")
            if not _same_tree(staging, destination):
                raise InstallError(
                    f"release {release} already exists with different content; choose a new release version"
                )
            durability.fsync_tree(destination)
            durability.fsync_directory(releases)
            return destination
        durability.replace(staging, destination)
        return destination
    finally:
        _remove_release_staging(staging)


def stage_release(source_root: Path, layout: Layout, release: str) -> Path:
    """Stage one immutable release through the installer-owned release transaction."""
    return _install_release(source_root, layout, release)


def _check_symlink_compatible(path: Path, target: Path) -> bool:
    if not (path.exists() or path.is_symlink()):
        return False
    if not path.is_symlink():
        raise InstallError(f"expected symlink at {path}")
    if not _owned_by_installer(path):
        raise InstallError(f"incompatible ownership at {path}: expected uid {os.geteuid()}")
    actual = Path(os.readlink(path))
    if actual != target:
        raise InstallError(f"existing symlink {path} points to {actual}, expected {target}")
    return True


def _ensure_symlink(path: Path, target: Path) -> None:
    if _check_symlink_compatible(path, target):
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.symlink_to(target)


def _install_systemd_units(release_dir: Path, layout: Layout) -> None:
    source = release_dir / SYSTEMD_SOURCE_DIR
    for unit in SYSTEMD_UNITS:
        unit_source = source / unit
        if not unit_source.is_file():
            raise InstallError(f"required systemd unit is missing from immutable release: {unit_source}")
        destination = layout.path(SYSTEMD_DIR / unit)
        _ensure_regular_file(
            destination,
            unit_source.read_text(encoding="utf-8"),
            0o644,
            preserve_existing=False,
        )


def _install_layout_locked(
    source_root: Path,
    layout: Layout,
    release: str,
    *,
    systemd_reload: bool,
) -> str:
    current = layout.path(CURRENT_LINK)
    current_target = Path("releases") / release
    vwctl = layout.path(VWCTL_LINK)
    vwctl_target = current / "vwctl"

    # Cheap hard conflicts are checked before immutable release promotion.
    _check_symlink_compatible(current, current_target)
    _check_symlink_compatible(vwctl, vwctl_target)

    release_dir = stage_release(source_root, layout, release)

    _ensure_directory(layout.path(CONFIG_DIR), 0o700)
    _ensure_regular_file(layout.path(CONFIG_PATH), CONFIG_TEMPLATE, 0o600, preserve_existing=True)
    _ensure_regular_file(layout.path(SECRETS_PATH), "", 0o600, preserve_existing=True)
    _ensure_regular_file(layout.path(AGE_KEY_PATH), "", 0o600, preserve_existing=True)

    _ensure_directory(layout.path(STATE_ROOT), 0o700)
    _ensure_directory(layout.path(STATE_DIR), 0o700)
    _ensure_directory(layout.path(RUNTIME_ROOT), 0o700)
    _ensure_directory(layout.path(RUNTIME_SECRETS_DIR), 0o700)
    _ensure_directory(layout.path(RUNTIME_TRANSIENT_DIR), 0o700)

    _ensure_symlink(current, current_target)
    _ensure_symlink(vwctl, vwctl_target)
    _install_systemd_units(release_dir, layout)

    if layout.root == Path("/") and systemd_reload:
        result = run_command(["systemctl", "daemon-reload"])
        if not result.ok:
            detail = result.stderr.strip() or result.stdout.strip() or result.kind
            raise InstallError(f"systemctl daemon-reload failed: {detail}")

    return str(release_dir)


def _validate_runtime_pins(source_root: Path, *, require_all_architectures: bool) -> None:
    from .update_versions import UpdateError, resolve_pinned_file

    try:
        resolve_pinned_file(
            source_root / "versions.toml",
            require_all_architectures=require_all_architectures,
        )
    except UpdateError as exc:
        raise InstallError(str(exc)) from exc


def install_layout(
    source_root: Path,
    *,
    root: Path = Path("/"),
    systemd_reload: bool = True,
    require_all_architectures: bool = True,
) -> str:
    source_root = source_root.resolve()
    layout = Layout(root.resolve())
    _assert_root(layout)
    _validate_runtime_pins(
        source_root,
        require_all_architectures=require_all_architectures,
    )
    manifest = load_versions(source_root / "versions.toml")
    release = validate_release_name(manifest.version)

    lock_path = ensure_lock_path(layout)
    try:
        with mutation_lock(lock_path):
            return _install_layout_locked(
                source_root,
                layout,
                release,
                systemd_reload=systemd_reload,
            )
    except LockBusyError:
        raise
    except RuntimeError as exc:
        if isinstance(exc, InstallError):
            raise
        raise InstallError(str(exc)) from exc


@contextmanager
def _frozen_source(source_root: Path, versions_toml: str) -> Iterator[Path]:
    source_root = source_root.resolve()
    with tempfile.TemporaryDirectory(prefix="vwoci-install-source-") as directory:
        root = Path(directory)
        for name in RELEASE_FILES:
            if name != "versions.toml":
                shutil.copy2(source_root / name, root / name)
        for name in RELEASE_DIRS:
            shutil.copytree(
                source_root / name,
                root / name,
                ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
            )
        (root / "versions.toml").write_text(versions_toml, encoding="utf-8")
        yield root


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Install the VaultWarden-OCI immutable application layout")
    parser.add_argument("--source", required=True, type=Path, help="repository/release source root")
    parser.add_argument("--use-latest", action="store_true", help="resolve supported upstreams once and freeze exact immutable values")
    parser.add_argument("--root", type=Path, default=Path("/"), help=argparse.SUPPRESS)
    parser.add_argument("--skip-host-check", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--skip-systemd-reload", action="store_true", help=argparse.SUPPRESS)
    return parser


def main(argv: list[str] | None = None) -> int:
    from .update_versions import (
        RESOLVED_STATE,
        UpdateError,
        frozen_versions_toml,
        record_frozen,
        resolve_latest,
        resolve_pinned,
    )

    args = _build_parser().parse_args(argv)
    try:
        if not args.skip_host_check:
            validate_host()
        root = args.root.resolve()
        if args.use_latest:
            frozen = resolve_latest(args.source)
            with _frozen_source(args.source, frozen_versions_toml(frozen)) as source:
                release_dir = install_layout(
                    source,
                    root=root,
                    systemd_reload=not args.skip_systemd_reload,
                    require_all_architectures=False,
                )
        else:
            frozen = resolve_pinned(args.source)
            release_dir = install_layout(
                args.source,
                root=root,
                systemd_reload=not args.skip_systemd_reload,
            )
        record_frozen(frozen, Layout(root).path(RESOLVED_STATE))
    except (InstallError, LockBusyError, ValueError, OSError, UpdateError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    label = "latest-frozen" if args.use_latest else "pinned"
    print(f"PASS: installed {label} immutable release at {release_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
