"""Explicit Phase 7 immutable-release update transaction."""
from __future__ import annotations

import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping

from . import cli, install
from .update_versions import (
    RESOLVED_STATE,
    FrozenVersions,
    UpdateError,
    frozen_versions_toml,
    record_frozen,
    resolve_pinned,
)


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
Activator = Callable[[FrozenVersions, Path, Runner], None]


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
            raise UpdateError(f"candidate release is missing Phase 7 owner: {name}")


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


def _selected_release_content(root: Path) -> dict[str, bytes | None]:
    result: dict[str, bytes | None] = {}
    for name in install.RELEASE_FILES:
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise UpdateError(f"release content is missing or unsafe: {path}")
        result[name] = path.read_bytes()
    for name in install.RELEASE_DIRS:
        base = root / name
        if base.is_symlink() or not base.is_dir():
            raise UpdateError(f"release content is missing or unsafe: {base}")
        result[name + "/"] = None
        for path in sorted(base.rglob("*")):
            relative = path.relative_to(root)
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


def plan_update(
    source_root: Path,
    *,
    root: Path = Path("/"),
    machine: str | None = None,
    runner: Runner = cli.run_command,
) -> UpdatePlan:
    """Plan an explicit source-pinned production update.

    Development/test --use-latest resolution is deliberately not supported here.
    Non-production roots are an injected unit-test boundary only; the public CLI
    always updates the production root and therefore uses Phase 3-6 production
    runtime/recovery ownership consistently.
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


def _prepare_runtime(frozen: FrozenVersions, runner: Runner) -> None:
    docker = runner(["docker", "version", "--format", "{{.Server.Version}}"])
    if not docker.ok:
        raise UpdateError(f"Docker Engine unavailable: {_detail(docker)}")
    for pin in (frozen.vaultwarden_image, frozen.caddy_builder_image, frozen.caddy_runtime_image):
        result = runner(["docker", "pull", pin.reference])
        if not result.ok:
            raise UpdateError(f"cannot pull exact {pin.name} image: {_detail(result)}")
    dockerfile = f"""FROM {frozen.caddy_builder_image.reference} AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare@{frozen.caddy_dns_cloudflare}
FROM {frozen.caddy_runtime_image.reference}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
"""
    with tempfile.TemporaryDirectory(prefix="vwoci-caddy-build-") as directory:
        file = Path(directory) / "Dockerfile"
        file.write_text(dockerfile, encoding="utf-8")
        built = runner(
            [
                "docker",
                "build",
                "--pull=false",
                "--tag",
                frozen.caddy_image,
                "--file",
                str(file),
                directory,
            ]
        )
    if not built.ok:
        raise UpdateError(f"exact pinned Caddy build failed: {_detail(built)}")


def _atomic_write(path: Path, content: bytes, mode: int) -> None:
    tmp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    try:
        fd = os.open(
            tmp,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            mode,
        )
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        os.chmod(path, mode)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def _install_units(
    new_release: Path,
    expected_release: Path,
    layout: install.Layout,
) -> dict[Path, tuple[bytes, int]]:
    snapshot: dict[Path, tuple[bytes, int]] = {}
    replacements: list[tuple[Path, bytes]] = []
    for unit in install.SYSTEMD_UNITS:
        new = new_release / install.SYSTEMD_SOURCE_DIR / unit
        expected = expected_release / install.SYSTEMD_SOURCE_DIR / unit
        destination = layout.path(install.SYSTEMD_DIR / unit)
        if not new.is_file() or not expected.is_file():
            raise UpdateError(f"release systemd unit is missing: {unit}")
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
        replacements.append((destination, new.read_bytes()))
    try:
        for destination, content in replacements:
            _atomic_write(destination, content, 0o644)
    except Exception:
        _restore_units(snapshot)
        raise
    return snapshot


def _restore_units(snapshot: Mapping[Path, tuple[bytes, int]]) -> None:
    failures = []
    for path, (content, mode) in snapshot.items():
        try:
            _atomic_write(path, content, mode)
        except Exception as exc:
            failures.append(f"{path}: {exc}")
    if failures:
        raise UpdateError("failed to restore systemd unit snapshot: " + "; ".join(failures))


def _switch(layout: install.Layout, target: Path) -> None:
    current = layout.path(install.CURRENT_LINK)
    temp = current.parent / f".current.{os.getpid()}.tmp"
    temp.unlink(missing_ok=True)
    try:
        temp.symlink_to(target)
        os.replace(temp, current)
    finally:
        temp.unlink(missing_ok=True)


def _daemon_reload(layout: install.Layout, runner: Runner) -> None:
    if layout.root == Path("/"):
        result = runner(["systemctl", "daemon-reload"])
        if not result.ok:
            raise UpdateError(f"systemctl daemon-reload failed: {_detail(result)}")


def _activate_runtime(frozen: FrozenVersions, versions_path: Path, runner: Runner) -> None:
    from . import edge, runtime, secrets

    try:
        if not runtime.tools(runner):
            raise UpdateError("Docker Engine + Compose with wait support are required")
        help_result = runner(["docker", "compose", "up", "--help"])
        if not help_result.ok or "--no-build" not in help_result.stdout or "--pull" not in help_result.stdout:
            raise UpdateError("Docker Compose with --no-build and --pull is required")
        runtime.validate_service_identities()
        paths = runtime.Paths()
        runtime.ensure_paths(paths)
        config = runtime.load_config(paths.config)
        try:
            policy = edge.refresh_origin_policy(runner=runner)
        except edge.EdgeError as exc:
            raise UpdateError(str(exc)) from exc
        runtime.render(config, versions_path, paths, cloudflare_policy=policy)
        check = runner(["docker", "compose", "-f", str(paths.compose), "config", "--quiet"])
        if not check.ok:
            raise UpdateError("rendered Compose validation failed during update activation")
        values = secrets.load(config.offline_recovery_recipient, paths=paths.secret_paths(), runner=runner)
        secrets.materialize(values, paths=paths.secret_paths())
    except Exception as exc:
        if isinstance(exc, KeyboardInterrupt):
            raise
        if isinstance(exc, RuntimeActivationError):
            raise
        raise RuntimeActivationError(str(exc), state_change_possible=False) from exc

    result = runner(
        [
            "docker",
            "compose",
            "-f",
            str(paths.compose),
            "up",
            "-d",
            "--no-build",
            "--pull",
            "never",
            "--force-recreate",
            "--wait",
            "--wait-timeout",
            "120",
        ]
    )
    if not result.ok:
        raise RuntimeActivationError(
            "frozen Docker Compose activation failed",
            state_change_possible=True,
        )


def _gate_activated(layout: install.Layout, runner: Runner) -> None:
    current = layout.path(install.CURRENT_LINK) / "vwctl"
    status = runner([str(current), "status"])
    if not status.ok:
        raise UpdateError(f"activated release status gate failed: {_detail(status)}")
    doctor = runner([str(current), "doctor", "--json"])
    if not doctor.ok:
        raise UpdateError(f"activated release doctor gate failed: {_detail(doctor)}")


def apply_update(
    plan: UpdatePlan,
    *,
    runner: Runner = cli.run_command,
    activator: Activator = _activate_runtime,
    record_path: Path | None = None,
) -> Path:
    """Recover first, then stage/prepare/switch/gate under one mutation lock."""
    layout = _layout(plan.root)
    if layout.root != Path("/") and (runner is cli.run_command or activator is _activate_runtime):
        raise UpdateError(
            "non-production update roots are test-only; inject both a test runner and test activator"
        )
    if layout.root == Path("/") and os.geteuid() != 0:
        raise UpdateError("vwctl update apply must run as root")
    current_target, current_release, previous_release = _current(layout)
    if (current_target, current_release) != (plan.current_target, plan.current_release):
        raise UpdateError("current release changed since update check")
    if plan.already_active:
        return previous_release

    current_candidate = resolve_pinned(
        plan.source_root, machine=plan.frozen.architecture
    )
    if current_candidate.as_dict() != plan.frozen.as_dict():
        raise UpdateError("candidate version pins changed since update check")

    _gate_current(layout, runner)
    recovery = runner([str(previous_release / "vwctl"), "backup"])
    if not recovery.ok:
        raise UpdateError(f"verified pre-update recovery failed: {_detail(recovery)}")
    _gate_current(layout, runner)

    lock_path = install.ensure_lock_path(layout)
    try:
        with cli.mutation_lock(lock_path):
            if _current(layout)[0] != current_target:
                raise UpdateError("current release changed after pre-update recovery")
            snapshot: dict[Path, tuple[bytes, int]] | None = None
            switched = False
            state_change_possible = False
            try:
                release_dir = install.stage_release(plan.source_root, layout, plan.target_release)
                _verify_coherent(release_dir, plan.source_root)
                _prepare_runtime(plan.frozen, runner)
                snapshot = _install_units(release_dir, previous_release, layout)
                _switch(layout, Path("releases") / plan.target_release)
                switched = True
                _daemon_reload(layout, runner)
                try:
                    activator(plan.frozen, release_dir / "versions.toml", runner)
                except RuntimeActivationError as exc:
                    state_change_possible = exc.state_change_possible
                    raise
                except Exception:
                    # A custom/test activator has no explicit safety signal.
                    # Conservatively assume it may have started candidate code.
                    state_change_possible = True
                    raise
                else:
                    state_change_possible = True
                _gate_activated(layout, runner)
                record_frozen(plan.frozen, record_path or layout.path(RESOLVED_STATE))
                return release_dir
            except Exception as exc:
                rollback_errors = []
                if not state_change_possible:
                    if switched:
                        try:
                            _switch(layout, current_target)
                        except Exception as rollback_exc:
                            rollback_errors.append(f"current symlink: {rollback_exc}")
                    if snapshot is not None:
                        try:
                            _restore_units(snapshot)
                        except Exception as rollback_exc:
                            rollback_errors.append(f"systemd units: {rollback_exc}")
                    if switched:
                        try:
                            _daemon_reload(layout, runner)
                        except Exception as rollback_exc:
                            rollback_errors.append(f"daemon-reload: {rollback_exc}")
                message = str(exc)
                if state_change_possible:
                    message += (
                        "; automatic rollback refused because candidate runtime activation may have "
                        "changed persistent state; candidate application release remains active and "
                        "the verified pre-update recovery is the downgrade boundary"
                    )
                elif rollback_errors:
                    message += "; rollback incomplete: " + "; ".join(rollback_errors)
                elif switched or snapshot is not None:
                    message += "; previous application release was restored before candidate runtime start"
                if isinstance(exc, KeyboardInterrupt):
                    raise
                raise UpdateError(message) from exc
    except cli.LockBusyError:
        raise
