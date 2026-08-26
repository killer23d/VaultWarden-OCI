"""Shared immutable-update planning and safety primitives."""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from . import cli, durability, install
from .update_versions import FrozenVersions, UpdateError, resolve_pinned


class RuntimeActivationError(UpdateError):
    """Activation failed, with an explicit persistent-state safety boundary."""

    def __init__(self, message: str, *, state_change_possible: bool):
        super().__init__(message)
        self.state_change_possible = state_change_possible


@dataclass(frozen=True)
class UpdatePlan:
    source_root: Path
    root: Path
    current_target: Path
    current_release: str
    target_release: str
    frozen: FrozenVersions

    @property
    def already_active(self) -> bool:
        return self.current_release == self.target_release


Runner = Callable[..., cli.CommandResult]


def _layout(root: Path) -> install.Layout:
    return install.Layout(root.resolve())


def _validate_source(source_root: Path) -> None:
    for name in install.RELEASE_FILES:
        if not (source_root / name).is_file():
            raise UpdateError(f"candidate release file is missing: {source_root / name}")
    for name in install.RELEASE_DIRS:
        if not (source_root / name).is_dir():
            raise UpdateError(f"candidate release directory is missing: {source_root / name}")
    for name in ("update.py", "update_versions.py", "update_cli.py"):
        if not (source_root / "vaultwarden_oci" / name).is_file():
            raise UpdateError(f"candidate release is missing required update owner: {name}")


def _current(layout: install.Layout) -> tuple[Path, str, Path]:
    current = layout.path(install.CURRENT_LINK)
    if not current.is_symlink():
        raise UpdateError(f"installed current release symlink is missing or invalid: {current}")
    target = Path(os.readlink(current))
    if target.is_absolute() or len(target.parts) != 2 or target.parts[0] != "releases":
        raise UpdateError(f"installed current release target is unsafe: {target}")
    try:
        release = install.validate_release_name(target.parts[1])
    except install.InstallError as exc:
        raise UpdateError(str(exc)) from exc
    release_dir = current.parent / target
    if release_dir.is_symlink() or not release_dir.is_dir():
        raise UpdateError(f"installed current release directory is invalid: {release_dir}")
    return target, release, release_dir


def _detail(result: cli.CommandResult) -> str:
    return result.stderr.strip() or result.stdout.strip() or result.kind


def _gate_current(layout: install.Layout, runner: Runner) -> None:
    target, _, _ = _current(layout)
    vwctl = layout.path(install.INSTALL_ROOT) / target / "vwctl"
    status = runner([str(vwctl), "status"])
    if not status.ok:
        raise UpdateError(f"current runtime status is not safe for update: {_detail(status)}")
    doctor = runner([str(vwctl), "doctor", "--json"])
    if not doctor.ok:
        raise UpdateError(f"current doctor gate failed: {_detail(doctor)}")


def _release_content_directory(root: Path, name: str) -> Path:
    canonical = root / name
    if canonical.is_dir() and not canonical.is_symlink():
        return canonical
    if name == install.SYSTEMD_SOURCE_DIR:
        previous = root / install.PREVIOUS_SYSTEMD_SOURCE_DIR
        if previous.is_dir() and not previous.is_symlink():
            return previous
    return canonical


def _selected_release_content(root: Path) -> dict[str, bytes | None]:
    result: dict[str, bytes | None] = {}
    for name in install.RELEASE_FILES:
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise UpdateError(f"release content is missing or unsafe: {path}")
        result[name] = path.read_bytes()
    for name in install.RELEASE_DIRS:
        base = _release_content_directory(root, name)
        if base.is_symlink() or not base.is_dir():
            raise UpdateError(f"release content is missing or unsafe: {base}")
        result[name + "/"] = None
        for path in sorted(base.rglob("*")):
            relative = Path(name) / path.relative_to(base)
            if "__pycache__" in relative.parts or path.suffix == ".pyc":
                continue
            key = relative.as_posix() + ("/" if path.is_dir() else "")
            if path.is_symlink():
                raise UpdateError(f"release content contains an unsafe symlink: {path}")
            if path.is_dir():
                result[key] = None
            elif path.is_file():
                result[key] = path.read_bytes()
            else:
                raise UpdateError(f"release content contains an unsupported file type: {path}")
    return result


def _numeric_component_version(value: str, label: str) -> tuple[int, ...]:
    normalized = value.removeprefix("v")
    parts = normalized.split(".")
    if len(parts) < 2 or any(not part.isdigit() for part in parts):
        raise UpdateError(
            f"cannot prove {label} downgrade safety for version {value!r}; "
            "ordinary update requires a numeric release pin"
        )
    return tuple(int(part) for part in parts)


def _reject_component_downgrades(current_dir: Path, candidate: FrozenVersions) -> None:
    try:
        current = cli.load_versions(current_dir / "versions.toml", require_components=True)
    except cli.VersionsError as exc:
        raise UpdateError(f"cannot load installed component pins for downgrade safety: {exc}") from exc
    for attribute, label in (
        ("vaultwarden", "Vaultwarden"),
        ("caddy", "Caddy"),
        ("caddy_dns_cloudflare", "caddy-dns/cloudflare"),
        ("caddy_combine_ip_ranges", "caddy-combine-ip-ranges"),
        ("caddy_ratelimit", "caddy-ratelimit"),
    ):
        installed = getattr(current, attribute)
        proposed = getattr(candidate, attribute)
        if _numeric_component_version(proposed, label) < _numeric_component_version(installed, label):
            raise UpdateError(
                f"ordinary update refuses {label} downgrade: installed {installed}, candidate {proposed}; "
                "use a separately explicit recovery-aware downgrade procedure instead"
            )


def plan_update(
    source_root: Path,
    *,
    root: Path = Path("/"),
    machine: str | None = None,
    runner: Runner = cli.run_command,
    enforce_component_downgrades: bool = True,
) -> UpdatePlan:
    """Plan an explicit source-pinned production update.

    Development/test --use-latest resolution is deliberately not supported here.
    Non-production roots are an injected unit-test boundary only; the public CLI
    always updates the production root and therefore uses the production
    runtime/recovery ownership consistently. ``enforce_component_downgrades``
    may be disabled only by the appliance planner while it resolves the final
    ``--use-latest`` snapshot; that final snapshot is checked before return.
    """
    resolved_root = root.resolve()
    if resolved_root != Path("/") and runner is cli.run_command:
        raise UpdateError(
            "non-production update roots are test-only; inject a test runner instead of using live runtime state"
        )
    source_root = source_root.resolve()
    _validate_source(source_root)
    layout = _layout(resolved_root)
    current_target, current_release, current_dir = _current(layout)
    _gate_current(layout, runner)
    frozen = resolve_pinned(source_root, machine=machine)
    if enforce_component_downgrades:
        _reject_component_downgrades(current_dir, frozen)
    try:
        target_release = install.validate_release_name(frozen.project_version)
    except install.InstallError as exc:
        raise UpdateError(str(exc)) from exc
    if current_release == target_release:
        if _selected_release_content(current_dir) != _selected_release_content(source_root):
            raise UpdateError(
                f"candidate release {target_release} differs from the active immutable release; "
                "bump vaultwarden_oci.version before updating"
            )
    return UpdatePlan(
        source_root,
        resolved_root,
        current_target,
        current_release,
        target_release,
        frozen,
    )


def _verify_coherent(release_dir: Path, source_root: Path) -> None:
    paths = (
        Path("versions.toml"),
        Path("email-providers.toml"),
        Path("vaultwarden_oci/notification.py"),
        Path("vaultwarden_oci/update.py"),
        Path("vaultwarden_oci/update_versions.py"),
        Path("vaultwarden_oci/update_cli.py"),
    )
    for relative in paths:
        left, right = release_dir / relative, source_root / relative
        if not left.is_file() or not right.is_file() or left.read_bytes() != right.read_bytes():
            raise UpdateError(f"immutable release resource mismatch: {relative}")


def _atomic_write(path: Path, content: bytes, mode: int) -> None:
    """Compatibility boundary for durable project-owned file replacement."""
    durability.atomic_write(path, content, mode)


def _daemon_reload(layout: install.Layout, runner: Runner) -> None:
    if layout.root == Path("/"):
        result = runner(["systemctl", "daemon-reload"])
        if not result.ok:
            raise UpdateError(f"systemctl daemon-reload failed: {_detail(result)}")


def _gate_activated(layout: install.Layout, runner: Runner) -> None:
    current = layout.path(install.CURRENT_LINK) / "vwctl"
    status = runner([str(current), "status"])
    if not status.ok:
        raise UpdateError(f"activated release status gate failed: {_detail(status)}")
    doctor = runner([str(current), "doctor", "--json"])
    if not doctor.ok:
        raise UpdateError(f"activated release doctor gate failed: {_detail(doctor)}")
