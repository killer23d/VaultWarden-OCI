"""Appliance-style project update orchestration built on the immutable updater."""
from __future__ import annotations

import io
import json
import os
import re
import shlex
import shutil
import tarfile
import tempfile
import time
import urllib.request
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Callable, Iterator, Mapping

from . import (
    cli,
    install,
    notification,
    recovery,
    runtime,
    secrets,
    storage,
    update,
    update_guard,
    update_recovery,
    update_unit_migration,
)
from .update_candidate import PRESTART_FAILURE
from .update_versions import (
    DEVELOPMENT_ENV,
    RESOLVED_STATE,
    FrozenVersions,
    UpdateError,
    frozen_versions_toml,
    record_frozen,
    resolve_latest_supported,
    resolve_pinned_file,
)

PROJECT_RELEASES_URL = (
    "https://api.github.com/repos/killer23d/VaultWarden-OCI/releases?per_page=100&page={page}"
)
MAX_RELEASE_PAGES = 10
UPDATE_STATE = Path("/var/lib/vaultwarden-oci/state/update-check.json")
MAX_RELEASE_BYTES = 64 * 1024 * 1024
MIN_FREE_BYTES = 1024 * 1024 * 1024
_UPDATE_TIMER = "vaultwarden-oci-update-check.timer"
_APPLICATION_SERVICE = "vaultwarden-oci.service"
_QUARANTINE_TARGET = Path("recovery-required")
_LATEST_MARKER = ".latest."
_SEMVER = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


@dataclass(frozen=True)
class ProjectRelease:
    tag: str
    tarball_url: str
    published_at: str


@dataclass(frozen=True)
class PreparedPlan:
    plan: update.UpdatePlan
    project_release: ProjectRelease | None
    use_latest: bool
    available: bool = True
    availability_reason: str = ""


class PersistentStateFailure(UpdateError):
    """Candidate may have touched persistent state; data+code rollback is required."""

    def __init__(
        self,
        message: str,
        *,
        plan: update.UpdatePlan,
        verified: recovery.VerifiedRecovery,
        services_stopped: bool,
    ) -> None:
        super().__init__(message)
        self.plan = plan
        self.verified = verified
        self.services_stopped = services_stopped


Runner = Callable[..., cli.CommandResult]
JsonGetter = Callable[[str], object]
CandidateActivator = Callable[[Path, Path, Runner], None]


def _detail(result: cli.CommandResult) -> str:
    return result.stderr.strip() or result.stdout.strip() or result.kind


def _json_get(url: str) -> object:
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/vnd.github+json", "User-Agent": "vaultwarden-oci-update"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            if response.status != 200:
                raise UpdateError(f"project release lookup returned HTTP {response.status}")
            raw = response.read(1024 * 1024 + 1)
    except (OSError, TimeoutError) as exc:
        raise UpdateError(f"project release lookup failed: {exc}") from exc
    if len(raw) > 1024 * 1024:
        raise UpdateError("project release lookup response was unexpectedly large")
    try:
        return json.loads(raw)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise UpdateError("project release lookup returned invalid JSON") from exc


def _stable_from_page(payload: object) -> ProjectRelease | None:
    if not isinstance(payload, list):
        raise UpdateError("project release lookup returned an invalid release list")
    for item in payload:
        if not isinstance(item, dict) or item.get("draft") is True or item.get("prerelease") is True:
            continue
        tag = item.get("tag_name")
        tarball = item.get("tarball_url")
        published = item.get("published_at") or item.get("created_at") or ""
        if (
            isinstance(tag, str)
            and tag
            and tag.strip() == tag
            and not any(c.isspace() for c in tag)
            and isinstance(tarball, str)
            and tarball.startswith(
                "https://api.github.com/repos/killer23d/VaultWarden-OCI/tarball/"
            )
            and isinstance(published, str)
        ):
            return ProjectRelease(tag, tarball, published)
    return None


def select_stable_release(payload: object) -> ProjectRelease:
    """Select the first non-draft/non-prerelease project release in one page."""
    selected = _stable_from_page(payload)
    if selected is None:
        raise UpdateError("no stable VaultWarden-OCI project release is available")
    return selected


def latest_project_release(*, getter: JsonGetter = _json_get) -> ProjectRelease:
    """Find the newest stable release across bounded GitHub release pagination."""
    for page in range(1, MAX_RELEASE_PAGES + 1):
        payload = getter(PROJECT_RELEASES_URL.format(page=page))
        selected = _stable_from_page(payload)
        if selected is not None:
            return selected
        assert isinstance(payload, list)
        if len(payload) < 100:
            break
    raise UpdateError(
        f"no stable VaultWarden-OCI project release was found in the newest {MAX_RELEASE_PAGES * 100} releases"
    )


def _download(url: str) -> bytes:
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/vnd.github+json", "User-Agent": "vaultwarden-oci-update"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read(MAX_RELEASE_BYTES + 1)
    except (OSError, TimeoutError) as exc:
        raise UpdateError(f"project release download failed: {exc}") from exc
    if len(raw) > MAX_RELEASE_BYTES:
        raise UpdateError("project release archive exceeds the allowed size")
    return raw


def _extract_release(raw: bytes, destination: Path) -> Path:
    try:
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as archive:
            members = archive.getmembers()
            if not members:
                raise UpdateError("project release archive is empty")
            roots: set[str] = set()
            for member in members:
                pure = PurePosixPath(member.name)
                if pure.is_absolute() or ".." in pure.parts or not pure.parts:
                    raise UpdateError("project release archive contains an unsafe path")
                roots.add(pure.parts[0])
                if not (member.isdir() or member.isreg()):
                    raise UpdateError("project release archive contains an unsupported file type")
            if len(roots) != 1:
                raise UpdateError("project release archive must contain one source root")
            archive.extractall(destination, members=members)
    except (tarfile.TarError, OSError) as exc:
        if isinstance(exc, UpdateError):
            raise
        raise UpdateError(f"project release archive is invalid: {exc}") from exc
    root = destination / next(iter(roots))
    update._validate_source(root)
    if not (root / "vaultwarden_oci/update_candidate.py").is_file():
        raise UpdateError("project release is missing the candidate-owned update interface")
    return root


@contextmanager
def candidate_source(
    source: Path | None,
    *,
    getter: JsonGetter = _json_get,
    downloader: Callable[[str], bytes] = _download,
) -> Iterator[tuple[Path, ProjectRelease | None]]:
    """Yield a trusted stable release or an explicitly development-gated source."""
    if source is not None:
        if os.environ.get(DEVELOPMENT_ENV) != "1":
            raise UpdateError(
                f"--source is developer/testing-only; set {DEVELOPMENT_ENV}=1 explicitly"
            )
        root = source.resolve()
        update._validate_source(root)
        if not (root / "vaultwarden_oci/update_candidate.py").is_file():
            raise UpdateError("developer source is missing the candidate-owned update interface")
        yield root, None
        return
    release = latest_project_release(getter=getter)
    raw = downloader(release.tarball_url)
    with tempfile.TemporaryDirectory(prefix="vwoci-project-release-") as directory:
        yield _extract_release(raw, Path(directory)), release


def _base_project_version(release: str) -> str:
    return release.split(_LATEST_MARKER, 1)[0]


def _parse_semver(value: str) -> tuple[tuple[int, int, int], tuple[str, ...] | None]:
    match = _SEMVER.fullmatch(value)
    if match is None:
        raise UpdateError(
            f"project release version {value!r} is not comparable semantic version syntax"
        )
    prerelease = tuple(match.group(4).split(".")) if match.group(4) is not None else None
    return (int(match.group(1)), int(match.group(2)), int(match.group(3))), prerelease


def _compare_prerelease(left: tuple[str, ...] | None, right: tuple[str, ...] | None) -> int:
    if left is None and right is None:
        return 0
    if left is None:
        return 1
    if right is None:
        return -1
    for one, two in zip(left, right):
        if one == two:
            continue
        one_num, two_num = one.isdigit(), two.isdigit()
        if one_num and two_num:
            return 1 if int(one) > int(two) else -1
        if one_num != two_num:
            return -1 if one_num else 1
        return 1 if one > two else -1
    if len(left) == len(right):
        return 0
    return 1 if len(left) > len(right) else -1


def compare_project_versions(left: str, right: str) -> int:
    left_core, left_pre = _parse_semver(left)
    right_core, right_pre = _parse_semver(right)
    if left_core != right_core:
        return 1 if left_core > right_core else -1
    return _compare_prerelease(left_pre, right_pre)


def _recommended_availability(current_release: str, candidate_version: str) -> tuple[bool, str]:
    current_base = _base_project_version(current_release)
    ordering = compare_project_versions(candidate_version, current_base)
    if ordering > 0:
        return True, "newer stable project release"
    if ordering < 0:
        return False, "discovered stable release is older than the installed project release; downgrade refused"
    if _LATEST_MARKER in current_release:
        return (
            False,
            "active --use-latest snapshot is based on this stable project release; returning to its tested pins would be an implicit component downgrade",
        )
    return False, "already at the newest stable project release"


def prepare_plan(
    source_root: Path,
    *,
    project_release: ProjectRelease | None = None,
    use_latest: bool = False,
    root: Path = Path("/"),
    machine: str | None = None,
    runner: Runner = cli.run_command,
) -> PreparedPlan:
    """Create a coherent plan with explicit project applicability before downgrade checks."""
    defer_component_check = use_latest or project_release is not None
    base = update.plan_update(
        source_root,
        root=root,
        machine=machine,
        runner=runner,
        enforce_component_downgrades=not defer_component_check,
    )
    source_frozen = update.resolve_pinned(source_root, machine=machine)
    source_version = source_frozen.project_version
    if project_release is not None:
        normalized = project_release.tag.removeprefix("v")
        if normalized != source_version:
            raise UpdateError(
                f"stable project release tag {project_release.tag!r} does not match its versions.toml project version {source_version!r}"
            )

    if use_latest:
        current_base = _base_project_version(base.current_release)
        if compare_project_versions(source_version, current_base) < 0:
            raise UpdateError(
                "--use-latest candidate is based on an older project release than the installed appliance; downgrade refused"
            )
        frozen = resolve_latest_supported(source_root, machine=machine)
        current_dir = install.Layout(base.root).path(install.INSTALL_ROOT) / base.current_target
        update._reject_component_downgrades(current_dir, frozen)
        plan = update.UpdatePlan(
            source_root=source_root.resolve(),
            root=base.root,
            current_target=base.current_target,
            current_release=base.current_release,
            target_release=frozen.project_version,
            frozen=frozen,
        )
        available = plan.target_release != plan.current_release
        reason = (
            "new exact --use-latest snapshot"
            if available
            else "the exact --use-latest snapshot is already active"
        )
    else:
        plan = base
        if project_release is not None:
            available, reason = _recommended_availability(base.current_release, source_version)
            if available:
                current_dir = install.Layout(base.root).path(install.INSTALL_ROOT) / base.current_target
                update._reject_component_downgrades(current_dir, source_frozen)
        else:
            available = not plan.already_active
            reason = "developer source differs from active release" if available else "developer source is already active"
    return PreparedPlan(
        plan=plan,
        project_release=project_release,
        use_latest=use_latest,
        available=available,
        availability_reason=reason,
    )


def _tree_bytes(root: Path) -> int:
    total = 0
    for path in root.rglob("*"):
        if path.is_symlink():
            raise UpdateError(f"candidate release contains an unsafe symlink: {path}")
        if path.is_file():
            total += path.stat().st_size
    return total


def _existing_ancestor(path: Path) -> Path:
    current = path
    while not current.exists() and current != current.parent:
        current = current.parent
    return current


def _disk_space(source_root: Path, layout: install.Layout, *, runner: Runner) -> None:
    required = max(MIN_FREE_BYTES, _tree_bytes(source_root) * 3)
    targets = {
        layout.path(install.INSTALL_ROOT).parent,
        layout.path(install.STATE_ROOT),
    }
    docker = runner(["docker", "info", "--format", "{{.DockerRootDir}}"])
    if not docker.ok:
        raise UpdateError(f"cannot inspect Docker image/build storage: {_detail(docker)}")
    docker_root = docker.stdout.strip()
    if not docker_root or not Path(docker_root).is_absolute():
        raise UpdateError("Docker reported an invalid image/build storage root")
    targets.add(Path(docker_root))
    for target in targets:
        probe = _existing_ancestor(target)
        try:
            free = shutil.disk_usage(probe).free
        except OSError as exc:
            raise UpdateError(f"cannot inspect free disk space at {probe}: {exc}") from exc
        if free < required:
            raise UpdateError(
                f"insufficient free disk space at {probe}: need at least {required} bytes, have {free}"
            )


def _candidate_error(label: str, result: cli.CommandResult) -> UpdateError:
    detail = _detail(result)
    try:
        payload = json.loads(result.stdout)
    except (TypeError, json.JSONDecodeError):
        payload = None
    if isinstance(payload, dict) and isinstance(payload.get("error"), str):
        detail = str(payload["error"])
    return UpdateError(f"{label}: {detail}")


def _prepare_candidate_release(exact_source: Path, render_root: Path, *, runner: Runner) -> None:
    result = runner(
        [
            str(exact_source / "vwctl"),
            "__update-candidate",
            "prepare",
            "--versions",
            str(exact_source / "versions.toml"),
            "--render-root",
            str(render_root),
        ],
        cwd=exact_source,
    )
    if not result.ok:
        raise _candidate_error("candidate-owned pre-stage failed", result)


def _activate_candidate_release(release_dir: Path, render_root: Path, runner: Runner) -> None:
    result = runner(
        [
            str(release_dir / "vwctl"),
            "__update-candidate",
            "activate",
            "--versions",
            str(release_dir / "versions.toml"),
            "--render-root",
            str(render_root),
        ],
        cwd=release_dir,
    )
    if result.ok:
        return
    # Only the candidate's explicit PRESTART code proves that runtime start was
    # never attempted. Unknown exits (signal, OOM, crash) are conservatively
    # treated as potentially state-changing so old code is never auto-launched.
    state_change_possible = result.returncode != PRESTART_FAILURE
    detail = _detail(result)
    try:
        payload = json.loads(result.stdout)
    except (TypeError, json.JSONDecodeError):
        payload = None
    if isinstance(payload, dict):
        if isinstance(payload.get("error"), str):
            detail = str(payload["error"])
        if payload.get("state_change_possible") is True:
            state_change_possible = True
    raise update.RuntimeActivationError(detail, state_change_possible=state_change_possible)


def _stop_candidate_locked(release_dir: Path, runner: Runner) -> bool:
    result = runner(
        [str(release_dir / "vwctl"), "__update-candidate", "stop"],
        cwd=release_dir,
    )
    if not result.ok:
        return False
    try:
        payload = json.loads(result.stdout)
    except (TypeError, json.JSONDecodeError):
        return True
    return not isinstance(payload, dict) or payload.get("stopped") is True


def _settle_systemd_stopped(layout: install.Layout, runner: Runner) -> bool:
    """After the updater lock is released, make systemd's service state truthful."""
    if layout.root != Path("/"):
        return True
    stopped = runner(["systemctl", "stop", _APPLICATION_SERVICE])
    active = runner(["systemctl", "is-active", "--quiet", _APPLICATION_SERVICE])
    return stopped.ok and not active.ok


def _start_previous_service(layout: install.Layout, previous: Path, runner: Runner) -> None:
    if layout.root == Path("/"):
        started = runner(["systemctl", "start", _APPLICATION_SERVICE])
        if not started.ok:
            raise UpdateError(f"previous release systemd start failed: {_detail(started)}")
        active = runner(["systemctl", "is-active", "--quiet", _APPLICATION_SERVICE])
        if not active.ok:
            raise UpdateError("previous release systemd service could not be proven active")
        return
    started = runner([str(previous / "vwctl"), "start"], cwd=previous)
    if not started.ok:
        raise UpdateError(f"previous release failed to start after coherent data restore: {_detail(started)}")


def _quarantine_current(layout: install.Layout) -> None:
    """Fail closed: normal vwctl/systemd start paths resolve to no application code."""
    update._switch(layout, _QUARANTINE_TARGET)


def _guard_path(layout: install.Layout) -> Path:
    return layout.path(update_guard.RECOVERY_REQUIRED_STATE)


def _current_target(layout: install.Layout) -> Path:
    current = layout.path(install.CURRENT_LINK)
    if not current.is_symlink():
        raise UpdateError(f"installed current release symlink is missing or invalid: {current}")
    target = Path(os.readlink(current))
    if target.is_absolute():
        raise UpdateError(f"installed current release target is unsafe: {target}")
    return target


def _rollback_selection(layout: install.Layout, plan: update.UpdatePlan) -> Path:
    """Accept only the recorded failed candidate, previous release, or quarantine."""
    target = _current_target(layout)
    allowed = {
        Path("releases") / plan.target_release,
        Path("releases") / plan.current_release,
        _QUARANTINE_TARGET,
    }
    if target not in allowed:
        raise UpdateError(
            f"current selection changed outside the recorded update recovery set: {target}"
        )
    return target


def _preflight(
    exact_source: Path,
    plan: update.UpdatePlan,
    render_root: Path,
    *,
    runner: Runner,
) -> runtime.RuntimeConfig:
    if plan.root == Path("/"):
        storage.verify()
    layout = install.Layout(plan.root.resolve())
    update._gate_current(layout, runner)
    config = runtime.load_config()
    secrets.load(config.offline_recovery_recipient, runner=runner)
    _disk_space(exact_source, layout, runner=runner)
    _prepare_candidate_release(exact_source, render_root, runner=runner)
    return config


def _prove_previous(layout: install.Layout, runner: Runner) -> None:
    update._gate_current(layout, runner)


def _start_update_timer(layout: install.Layout, runner: Runner) -> None:
    if layout.root != Path("/"):
        return
    started = runner(["systemctl", "start", _UPDATE_TIMER])
    if not started.ok:
        raise UpdateError(f"update-check timer failed to start: {_detail(started)}")
    active = runner(["systemctl", "is-active", "--quiet", _UPDATE_TIMER])
    if not active.ok:
        raise UpdateError("update-check timer could not be proven active after upgrade")


def apply_prepared(
    prepared: PreparedPlan,
    *,
    runner: Runner = cli.run_command,
    activator: CandidateActivator = _activate_candidate_release,
    record_path: Path | None = None,
    recovery_creator: Callable[..., recovery.VerifiedRecovery] = recovery.create_recovery,
) -> Path:
    """Prepare while healthy, then mutate under one short appliance lock boundary."""
    plan = prepared.plan
    layout = install.Layout(plan.root.resolve())
    guard_path = _guard_path(layout)
    if layout.root != Path("/") and (
        runner is cli.run_command or activator is _activate_candidate_release
    ):
        raise UpdateError("non-production update roots are test-only; inject test runner and activator")
    if layout.root == Path("/") and os.geteuid() != 0:
        raise UpdateError("vwctl update apply must run as root")
    current_target, current_release, previous_release = update._current(layout)
    if (current_target, current_release) != (plan.current_target, plan.current_release):
        raise UpdateError("current release changed since update check")
    if not prepared.available:
        return previous_release

    versions_text = frozen_versions_toml(plan.frozen)
    with install._frozen_source(plan.source_root, versions_text) as exact_source:
        update._validate_source(exact_source)
        with tempfile.TemporaryDirectory(prefix="vwoci-update-prepared-") as render_directory:
            render_root = Path(render_directory)
            config = _preflight(exact_source, plan, render_root, runner=runner)
            verified = recovery_creator(config.offline_recovery_recipient, runner=runner)
            if not verified.artifact.is_file() or verified.size <= 0:
                raise UpdateError("verified pre-update recovery did not produce a usable .vwrec artifact")
            if recovery._sha256(verified.artifact) != verified.sha256:
                raise UpdateError("verified pre-update recovery digest changed before mutation")
            update._gate_current(layout, runner)

            lock_path = install.ensure_lock_path(layout)
            try:
                with cli.mutation_lock(lock_path):
                    if update._current(layout)[0] != current_target:
                        raise UpdateError("current release changed after pre-update recovery")
                    if plan.root == Path("/"):
                        storage.verify()
                    snapshot: dict[Path, tuple[bytes, int]] | None = None
                    switched = False
                    state_change_possible = False
                    release_dir: Path | None = None
                    try:
                        release_dir = install.stage_release(exact_source, layout, plan.target_release)
                        update._verify_coherent(release_dir, exact_source)
                        snapshot = update_unit_migration.install_units(
                            release_dir,
                            previous_release,
                            layout,
                        )
                        update._switch(layout, Path("releases") / plan.target_release)
                        switched = True
                        update._daemon_reload(layout, runner)
                        try:
                            activator(release_dir, render_root, runner)
                        except update.RuntimeActivationError as exc:
                            state_change_possible = exc.state_change_possible
                            raise
                        except (Exception, KeyboardInterrupt):
                            # An interrupted/abnormal candidate activation is an
                            # unknown state boundary; fail closed as post-start.
                            state_change_possible = True
                            raise
                        else:
                            state_change_possible = True
                        update._gate_activated(layout, runner)
                        crowdsec = runner(
                            [
                                str(layout.path(install.CURRENT_LINK) / "vwctl"),
                                "crowdsec",
                                "status",
                            ]
                        )
                        if not crowdsec.ok:
                            raise UpdateError(f"activated CrowdSec/origin gate failed: {_detail(crowdsec)}")
                        _start_update_timer(layout, runner)
                        record_frozen(plan.frozen, record_path or layout.path(RESOLVED_STATE))
                        return release_dir
                    except (Exception, KeyboardInterrupt) as exc:
                        if state_change_possible:
                            stopped = (
                                release_dir is not None
                                and _stop_candidate_locked(release_dir, runner)
                            )
                            guard_detail = "recovery-required start guard engaged"
                            try:
                                update_guard.engage(
                                    candidate_release=plan.target_release,
                                    previous_release=plan.current_release,
                                    recovery_artifact=str(verified.artifact),
                                    recovery_sha256=verified.sha256,
                                    path=guard_path,
                                )
                            except Exception as guard_exc:
                                guard_detail = f"recovery guard failed ({guard_exc}); current quarantined"
                                try:
                                    _quarantine_current(layout)
                                except Exception as quarantine_exc:
                                    guard_detail += f"; quarantine also failed ({quarantine_exc})"
                            action = (
                                f"coherent rollback requires recovery artifact {verified.artifact} "
                                f"sha256={verified.sha256} plus previous release {plan.current_release}"
                            )
                            raise PersistentStateFailure(
                                f"{exc}; old code was not auto-started against possibly-new persistent state; "
                                f"candidate containers {'were stopped and removal was proven' if stopped else 'could not be proven stopped'}; "
                                f"{guard_detail}; {action}",
                                plan=plan,
                                verified=verified,
                                services_stopped=bool(stopped),
                            ) from exc

                        rollback_errors: list[str] = []
                        if switched:
                            try:
                                update._switch(layout, current_target)
                            except Exception as rollback_exc:
                                rollback_errors.append(f"current symlink: {rollback_exc}")
                        if snapshot is not None:
                            try:
                                update_unit_migration.restore_units(snapshot)
                            except Exception as rollback_exc:
                                rollback_errors.append(f"systemd units: {rollback_exc}")
                        if switched:
                            try:
                                update._daemon_reload(layout, runner)
                            except Exception as rollback_exc:
                                rollback_errors.append(f"daemon-reload: {rollback_exc}")
                        if not rollback_errors and (switched or snapshot is not None):
                            try:
                                _prove_previous(layout, runner)
                            except Exception as rollback_exc:
                                rollback_errors.append(f"previous health proof: {rollback_exc}")
                        message = str(exc) or exc.__class__.__name__
                        if rollback_errors:
                            message += "; rollback incomplete: " + "; ".join(rollback_errors)
                        elif switched or snapshot is not None:
                            message += "; previous release/systemd resources restored and previous stack proved healthy"
                        raise UpdateError(message) from exc
            except PersistentStateFailure as failure:
                systemd_stopped = _settle_systemd_stopped(layout, runner)
                fully_stopped = failure.services_stopped and systemd_stopped
                if fully_stopped:
                    raise PersistentStateFailure(
                        f"{failure}; systemd application service is inactive and candidate containers are absent",
                        plan=failure.plan,
                        verified=failure.verified,
                        services_stopped=True,
                    ) from failure
                raise PersistentStateFailure(
                    f"{failure}; failed to prove both inactive systemd state and absent candidate containers; normal start/restart remains guarded or current is quarantined",
                    plan=failure.plan,
                    verified=failure.verified,
                    services_stopped=False,
                ) from failure


def coherent_rollback(
    failure: PersistentStateFailure,
    identity: Path,
    *,
    runner: Runner = cli.run_command,
) -> None:
    """Restore pre-update data and previous immutable code as one crash-safe lock transaction."""
    storage.verify()
    plan = failure.plan
    layout = install.Layout(plan.root.resolve())
    guard_path = _guard_path(layout)
    if recovery._sha256(failure.verified.artifact) != failure.verified.sha256:
        raise UpdateError("pre-update recovery artifact digest no longer matches the recorded verified digest")

    expected_previous = layout.path(install.RELEASES_DIR) / plan.current_release
    candidate_path = layout.path(install.RELEASES_DIR) / plan.target_release
    candidate_target = Path("releases") / plan.target_release
    if not expected_previous.is_dir() or expected_previous.is_symlink():
        raise UpdateError("previous immutable application release is unavailable for coherent rollback")
    if not candidate_path.is_dir() or candidate_path.is_symlink():
        raise UpdateError("failed candidate immutable application release is unavailable for coherent rollback")
    original_target = _rollback_selection(layout, plan)

    completed = False
    try:
        with update_recovery.prepare_restore(
            failure.verified.artifact,
            identity,
            runner=runner,
        ) as prepared_restore:
            lock_path = install.ensure_lock_path(layout)
            with cli.mutation_lock(lock_path):
                if _rollback_selection(layout, plan) != original_target:
                    raise UpdateError("current selection changed while coherent rollback was being prepared")
                if plan.root == Path("/"):
                    storage.verify()
                try:
                    update_guard.engage(
                        candidate_release=plan.target_release,
                        previous_release=plan.current_release,
                        recovery_artifact=str(failure.verified.artifact),
                        recovery_sha256=failure.verified.sha256,
                        path=guard_path,
                    )
                except Exception as guard_exc:
                    try:
                        _quarantine_current(layout)
                    except Exception as quarantine_exc:
                        raise UpdateError(
                            f"coherent rollback recovery guard failed and current could not be quarantined: {guard_exc}; quarantine failure: {quarantine_exc}"
                        ) from guard_exc
                    raise UpdateError(
                        f"coherent rollback recovery guard failed; current was quarantined before releasing the mutation lock: {guard_exc}"
                    ) from guard_exc

                if _current_target(layout) != candidate_target:
                    try:
                        update._switch(layout, candidate_target)
                    except Exception as switch_exc:
                        try:
                            _quarantine_current(layout)
                        except Exception as quarantine_exc:
                            raise UpdateError(
                                f"could not select guard-aware candidate before recovery promotion: {switch_exc}; quarantine failure: {quarantine_exc}"
                            ) from switch_exc
                        raise UpdateError(
                            f"could not select guard-aware candidate before recovery promotion; current was quarantined: {switch_exc}"
                        ) from switch_exc

                if not _stop_candidate_locked(candidate_path, runner):
                    raise UpdateError(
                        "candidate containers could not be proven stopped; refusing destructive recovery promotion while recovery guard remains active"
                    )

                data_promoted = False
                switched_old = False
                try:
                    # Keep guard-aware candidate code selected until old data is fully
                    # promoted. A process/host crash before this returns can therefore
                    # only reboot into candidate code that knows to honor the guard.
                    prepared_restore.promote_locked(runner=runner)
                    data_promoted = True
                    update_unit_migration.converge_units(
                        expected_previous,
                        (candidate_path, expected_previous),
                        layout,
                    )
                    update._switch(layout, plan.current_target)
                    switched_old = True
                    update._daemon_reload(layout, runner)
                except update_recovery.PromotionError as exc:
                    try:
                        _quarantine_current(layout)
                    except Exception as quarantine_exc:
                        raise UpdateError(
                            f"coherent rollback data promotion failed and current could not be quarantined: {exc}; quarantine failure: {quarantine_exc}"
                        ) from exc
                    if exc.rollback_complete:
                        raise UpdateError(
                            f"coherent rollback data promotion failed; original live data was restored and current was quarantined for a safe retry: {exc}"
                        ) from exc
                    raise UpdateError(
                        f"coherent rollback promotion failed with unproven live-data state; current was quarantined and services remain stopped: {exc}"
                    ) from exc
                except (Exception, KeyboardInterrupt) as exc:
                    if data_promoted and not switched_old:
                        try:
                            _quarantine_current(layout)
                        except Exception as quarantine_exc:
                            raise UpdateError(
                                f"pre-update data was restored but previous-code selection failed, and current could not be quarantined: {exc}; quarantine failure: {quarantine_exc}"
                            ) from exc
                        raise UpdateError(
                            f"pre-update data was restored but previous-code selection did not complete; current was quarantined and services remain stopped: {exc}"
                        ) from exc
                    if data_promoted and switched_old:
                        raise UpdateError(
                            f"pre-update data and previous code were selected, but final systemd reload failed; services remain stopped: {exc}"
                        ) from exc
                    raise UpdateError(
                        f"coherent rollback failed before data promotion; guard-aware candidate selection remains blocked from normal start: {exc}"
                    ) from exc
                completed = True
    except (Exception, KeyboardInterrupt):
        if layout.root == Path("/"):
            _settle_systemd_stopped(layout, runner)
        raise

    if not completed:
        raise UpdateError("coherent rollback did not reach a complete data+code state")
    try:
        update_guard.clear(path=guard_path)
    except update_guard.UpdateGuardError as exc:
        raise UpdateError(f"coherent rollback completed but recovery guard could not be cleared: {exc}") from exc
    _start_previous_service(layout, expected_previous, runner)
    _prove_previous(layout, runner)


def reconstruct_failure(
    artifact: Path,
    sha256: str,
    previous_release: str,
    candidate_release: str,
    *,
    root: Path = Path("/"),
) -> PersistentStateFailure:
    """Reconstruct an explicit rollback from candidate/previous/quarantined selection."""
    if not _SHA256.fullmatch(sha256):
        raise UpdateError("--recovery-sha256 must be exactly 64 lowercase hexadecimal characters")
    layout = install.Layout(root.resolve())
    previous = install.validate_release_name(previous_release)
    candidate = install.validate_release_name(candidate_release)
    expected_previous = layout.path(install.RELEASES_DIR) / previous
    candidate_dir = layout.path(install.RELEASES_DIR) / candidate
    if not expected_previous.is_dir() or expected_previous.is_symlink():
        raise UpdateError("requested previous immutable release is unavailable")
    if not candidate_dir.is_dir() or candidate_dir.is_symlink():
        raise UpdateError("requested failed candidate immutable application release is unavailable")
    if recovery._sha256(artifact) != sha256:
        raise UpdateError("recovery artifact does not match the supplied verified SHA-256")
    frozen = resolve_pinned_file(candidate_dir / "versions.toml")
    plan = update.UpdatePlan(
        source_root=candidate_dir,
        root=layout.root,
        current_target=Path("releases") / previous,
        current_release=previous,
        target_release=candidate,
        frozen=frozen,
    )
    _rollback_selection(layout, plan)
    verified = recovery.VerifiedRecovery(
        artifact=artifact,
        sha256=sha256,
        size=artifact.stat().st_size,
        created_at="explicit-update-rollback",
    )
    return PersistentStateFailure(
        "explicit coherent rollback requested",
        plan=plan,
        verified=verified,
        services_stopped=False,
    )


def recovery_command(failure: PersistentStateFailure) -> str:
    layout = install.Layout(failure.plan.root.resolve())
    candidate_vwctl = layout.path(install.RELEASES_DIR) / failure.plan.target_release / "vwctl"
    return " ".join(
        (
            shlex.quote(str(candidate_vwctl)),
            "update rollback",
            "--recovery-artifact",
            shlex.quote(str(failure.verified.artifact)),
            "--recovery-sha256",
            failure.verified.sha256,
            "--previous-release",
            shlex.quote(failure.plan.current_release),
            "--candidate-release",
            shlex.quote(failure.plan.target_release),
            "--identity",
            "/path/to/offline-age-identity.txt",
            "--yes",
        )
    )


def _atomic_state(payload: Mapping[str, object], path: Path = UPDATE_STATE) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(dict(payload), handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        os.chmod(path, 0o600)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def _load_state(path: Path = UPDATE_STATE) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, UnicodeError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def _notify(subject: str, text: str) -> None:
    try:
        config = runtime.load_config()
        if config.notification_provider is None:
            return
        values = secrets.load(config.offline_recovery_recipient)
        notification.deliver(
            event_id="update-check",
            config=config,
            secrets=values,
            subject=subject,
            text=text,
        )
    except Exception:
        return


def record_check(
    *,
    current: str,
    candidate: str | None,
    error: str | None,
    available: bool | None = None,
    path: Path = UPDATE_STATE,
) -> None:
    old = _load_state(path)
    resolved_available = (
        candidate is not None and candidate != current
        if available is None
        else bool(available)
    )
    resolved_available = resolved_available and error is None
    payload = {
        "schema_version": 1,
        "checked_at": int(time.time()),
        "current": current,
        "candidate": candidate,
        "available": resolved_available,
        "error": error,
    }
    _atomic_state(payload, path)
    if error:
        _notify("[VaultWarden-OCI] update check failed", f"Project update check failed: {error}\n")
    elif resolved_available and (
        old.get("candidate") != candidate or old.get("available") is not True
    ):
        _notify(
            "[VaultWarden-OCI] project update available",
            f"VaultWarden-OCI project update available: {current} -> {candidate}.\nRun: vwctl update check\n",
        )


def _host_lock() -> Path:
    return install.ensure_lock_path(install.Layout(Path("/")))


def host_upgrade_check(*, runner: Runner = cli.run_command) -> tuple[int, bool, str]:
    if os.geteuid() != 0:
        raise UpdateError("vwctl host-upgrade check must run as root so Ubuntu indexes can be refreshed")
    with cli.mutation_lock(_host_lock()):
        refreshed = runner(["apt-get", "update"])
        if not refreshed.ok:
            raise UpdateError(f"Ubuntu package index refresh failed: {_detail(refreshed)}")
        simulated = runner(["apt-get", "-s", "upgrade"])
        if not simulated.ok:
            raise UpdateError(f"Ubuntu package simulation failed: {_detail(simulated)}")
    count = sum(1 for line in simulated.stdout.splitlines() if line.startswith("Inst "))
    reboot = Path("/var/run/reboot-required").exists()
    return count, reboot, simulated.stdout


def host_upgrade_apply(*, runner: Runner = cli.run_command) -> tuple[recovery.VerifiedRecovery, bool]:
    if os.geteuid() != 0:
        raise UpdateError("vwctl host-upgrade apply must run as root")
    storage.verify()
    config = runtime.load_config()
    verified = recovery.create_recovery(config.offline_recovery_recipient, runner=runner)
    with cli.mutation_lock(_host_lock()):
        storage.verify()
        refreshed = runner(["apt-get", "update"])
        if not refreshed.ok:
            raise UpdateError(f"Ubuntu package index refresh failed: {_detail(refreshed)}")
        applied = runner(["apt-get", "-y", "upgrade"])
        if not applied.ok:
            raise UpdateError(f"Ubuntu package upgrade failed: {_detail(applied)}")
    return verified, Path("/var/run/reboot-required").exists()
