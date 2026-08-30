"""One bounded update-controller handoff for the supported direct predecessor.

The selected/running appliance remains on the predecessor release. Only
``vwctl update ...`` is temporarily routed through the pre-staged exact target
release so the supported predecessor can benefit from target-owned update
orchestration that did not exist in the immutable predecessor code. All other
operator commands continue to execute from ``/opt/vaultwarden-oci/current``.
"""
from __future__ import annotations

import json
import os
import stat
from pathlib import Path
from typing import Sequence

from . import cli, durability, install, update
from .update_versions import UpdateError

_PREDECESSOR = "0.1.0-dev.16"
_TARGET = "0.1.0-dev.17"
_LATEST_MARKER = ".latest."
_STATE = Path("/var/lib/vaultwarden-oci/state/update-controller-handoff.json")
_SCHEMA_VERSION = 1

HANDOFF_ACTION = (
    "ACTION: exact target update controller was staged before recovery; "
    "rerun the same 'sudo vwctl update apply ...' command. The selected/running "
    "appliance remains on the supported predecessor until the verified update transaction begins."
)


class HandoffRequired(UpdateError):
    """The caller must rerun the same update command through the staged controller."""


def _base_release(value: str) -> str:
    return value.split(_LATEST_MARKER, 1)[0]


def _required(current_release: str, target_release: str) -> bool:
    return (
        _base_release(current_release) == _PREDECESSOR
        and _base_release(target_release) == _TARGET
    )


def _state_path(layout: install.Layout) -> Path:
    return layout.path(_STATE)


def _controller_path(layout: install.Layout, target_release: str) -> Path:
    return layout.path(install.RELEASES_DIR) / target_release / "vwctl"


def _canonical_launcher_target(layout: install.Layout) -> Path:
    return layout.path(install.CURRENT_LINK) / "vwctl"


def _launcher(layout: install.Layout) -> Path:
    return layout.path(install.VWCTL_LINK)


def _read_symlink(path: Path, label: str) -> Path:
    try:
        info = path.lstat()
    except OSError as exc:
        raise UpdateError(f"cannot inspect {label} {path}: {exc}") from exc
    if not stat.S_ISLNK(info.st_mode):
        raise UpdateError(f"{label} is not the expected symlink: {path}")
    try:
        return Path(os.readlink(path))
    except OSError as exc:
        raise UpdateError(f"cannot read {label} {path}: {exc}") from exc


def _payload(
    current_release: str,
    target_release: str,
    controller: Path,
) -> dict[str, object]:
    return {
        "schema_version": _SCHEMA_VERSION,
        "predecessor_release": current_release,
        "target_release": target_release,
        "controller": str(controller),
    }


def _load_state(path: Path) -> dict[str, object] | None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise UpdateError(f"cannot inspect update-controller handoff state {path}: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise UpdateError(f"update-controller handoff state is not a regular file: {path}")
    if stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.geteuid():
        raise UpdateError(f"update-controller handoff state has incompatible ownership/mode: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise UpdateError(f"update-controller handoff state is unreadable: {exc}") from exc
    if not isinstance(value, dict) or value.get("schema_version") != _SCHEMA_VERSION:
        raise UpdateError("update-controller handoff state has an unsupported schema")
    for key in ("predecessor_release", "target_release", "controller"):
        if not isinstance(value.get(key), str) or not value[key]:
            raise UpdateError(f"update-controller handoff state has invalid {key}")
    return value


def _state_matches(
    state: dict[str, object],
    *,
    current_release: str,
    target_release: str,
    controller: Path,
) -> bool:
    return state == _payload(current_release, target_release, controller)


def _write_state(path: Path, payload: dict[str, object]) -> None:
    durability.atomic_write(
        path,
        (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"),
        0o600,
    )


def _validate_controller(controller: Path) -> None:
    try:
        info = controller.lstat()
    except OSError as exc:
        raise UpdateError(f"cannot inspect staged update controller {controller}: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise UpdateError(f"staged update controller is not a regular file: {controller}")
    if not (info.st_mode & stat.S_IXUSR):
        raise UpdateError(f"staged update controller is not executable: {controller}")


def prepare_if_required(
    target_release: str,
    source_root: Path,
    *,
    current_release: str | None = None,
    root: Path = Path("/"),
) -> bool:
    """Pre-stage and route only update commands through the exact target controller.

    Returns ``True`` only when this call newly publishes/repairs the handoff and
    the caller must stop before recovery so the operator can rerun the exact
    same update command through the staged controller.
    """
    layout = install.Layout(root.resolve())
    if current_release is None:
        current_release = update._current(layout)[1]
    if not _required(current_release, target_release):
        return False
    if layout.root == Path("/") and os.geteuid() != 0:
        raise UpdateError("supported predecessor update-controller handoff must run as root")

    actual_current = update._current(layout)[1]
    if actual_current != current_release:
        raise UpdateError("current release changed before update-controller handoff")

    source_root = source_root.resolve()
    try:
        source_version = cli.load_versions(source_root / "versions.toml").version
    except cli.VersionsError as exc:
        raise UpdateError(f"cannot validate update-controller source version: {exc}") from exc
    if source_version != target_release:
        raise UpdateError(
            f"update-controller source version {source_version} does not match target {target_release}"
        )

    controller = _controller_path(layout, target_release)
    launcher = _launcher(layout)
    canonical = _canonical_launcher_target(layout)
    state_path = _state_path(layout)
    expected = _payload(current_release, target_release, controller)
    state = _load_state(state_path)

    if state is not None and not _state_matches(
        state,
        current_release=current_release,
        target_release=target_release,
        controller=controller,
    ):
        raise UpdateError("another update-controller handoff is already recorded")

    launcher_target = _read_symlink(launcher, "installed vwctl launcher")
    if state is not None and launcher_target == controller:
        _validate_controller(controller)
        return False
    if launcher_target != canonical:
        raise UpdateError(
            f"installed vwctl launcher changed outside the supported handoff: {launcher_target}"
        )

    lock_path = install.ensure_lock_path(layout)
    with cli.mutation_lock(lock_path):
        if update._current(layout)[1] != current_release:
            raise UpdateError("current release changed while staging update controller")
        release_dir = install.stage_release(source_root, layout, target_release)
        if release_dir != controller.parent:
            raise UpdateError("staged update-controller release path is inconsistent")
        _validate_controller(controller)

        state = _load_state(state_path)
        if state is None:
            _write_state(state_path, expected)
        elif not _state_matches(
            state,
            current_release=current_release,
            target_release=target_release,
            controller=controller,
        ):
            raise UpdateError("update-controller handoff state changed while staging")

        try:
            durability.atomic_symlink(launcher, controller)
        except Exception:
            # State is published first so a crash cannot expose the candidate
            # controller without proof. If publication itself fails normally,
            # restore the canonical no-handoff state before returning failure.
            try:
                durability.unlink(state_path, missing_ok=True)
            except OSError:
                pass
            raise

    if _read_symlink(launcher, "installed vwctl launcher") != controller:
        raise UpdateError("update-controller launcher handoff could not be proven")
    state = _load_state(state_path)
    if state is None or not _state_matches(
        state,
        current_release=current_release,
        target_release=target_release,
        controller=controller,
    ):
        raise UpdateError("update-controller handoff state could not be proven")
    return True


def _controller_for_this_process(controller_vwctl: Path | None) -> Path:
    if controller_vwctl is not None:
        return controller_vwctl.resolve()
    return (Path(__file__).resolve().parents[1] / "vwctl").resolve()


def delegate_non_update_if_handoff(
    argv: Sequence[str],
    *,
    root: Path = Path("/"),
    controller_vwctl: Path | None = None,
) -> bool:
    """Delegate ordinary commands to the selected predecessor during handoff."""
    if argv and argv[0] in {"update", "__update-candidate"}:
        return False
    layout = install.Layout(root.resolve())
    state = _load_state(_state_path(layout))
    if state is None:
        return False

    controller = Path(str(state["controller"])).resolve()
    if _controller_for_this_process(controller_vwctl) != controller:
        return False

    _, current_release, current_dir = update._current(layout)
    target_release = str(state["target_release"])
    predecessor_release = str(state["predecessor_release"])
    if current_release == target_release:
        return False
    if current_release != predecessor_release:
        raise UpdateError(
            "selected release is outside the recorded update-controller handoff boundary"
        )

    current_vwctl = current_dir / "vwctl"
    _validate_controller(current_vwctl)
    os.execv(str(current_vwctl), [str(current_vwctl), *argv])
    return True


def finalize_if_target_current(
    *,
    root: Path = Path("/"),
    controller_vwctl: Path | None = None,
) -> bool:
    """Restore the canonical launcher only after the target is selected successfully."""
    layout = install.Layout(root.resolve())
    state_path = _state_path(layout)
    state = _load_state(state_path)
    if state is None:
        return False

    controller = Path(str(state["controller"])).resolve()
    if _controller_for_this_process(controller_vwctl) != controller:
        return False

    _, current_release, _ = update._current(layout)
    if current_release != str(state["target_release"]):
        return False

    launcher = _launcher(layout)
    canonical = _canonical_launcher_target(layout)
    launcher_target = _read_symlink(launcher, "installed vwctl launcher")
    if launcher_target not in {controller, canonical}:
        raise UpdateError(
            f"installed vwctl launcher changed outside the supported handoff: {launcher_target}"
        )

    lock_path = install.ensure_lock_path(layout)
    with cli.mutation_lock(lock_path):
        if update._current(layout)[1] != current_release:
            raise UpdateError("current release changed while finalizing update-controller handoff")
        if _read_symlink(launcher, "installed vwctl launcher") != canonical:
            durability.atomic_symlink(launcher, canonical)
        durability.unlink(state_path, missing_ok=True)
    return True


def post_command(
    exit_code: int,
    argv: Sequence[str],
    *,
    root: Path = Path("/"),
) -> int:
    """Apply hidden-prepare handoff or successful-update cleanup at entrypoint exit."""
    if exit_code != 0:
        return exit_code

    if len(argv) >= 2 and argv[0] == "__update-candidate" and argv[1] == "prepare":
        try:
            index = list(argv).index("--versions")
            versions_path = Path(argv[index + 1])
        except (ValueError, IndexError) as exc:
            raise UpdateError("candidate prepare did not provide a usable --versions path") from exc
        try:
            target_release = cli.load_versions(versions_path).version
        except cli.VersionsError as exc:
            raise UpdateError(f"cannot read candidate prepare target version: {exc}") from exc
        layout = install.Layout(root.resolve())
        current_release = update._current(layout)[1]
        if prepare_if_required(
            target_release,
            versions_path.parent,
            current_release=current_release,
            root=root,
        ):
            raise HandoffRequired(HANDOFF_ACTION)
        return exit_code

    finalize_if_target_current(root=root)
    return exit_code
