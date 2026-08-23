"""Appliance-style project update orchestration built on the immutable updater."""
from __future__ import annotations

import io
import json
import os
import shutil
import tarfile
import tempfile
import time
import urllib.request
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Callable, Iterator, Mapping, Sequence

from . import cli, edge, install, notification, recovery, runtime, secrets, storage, update
from .update_versions import (
    RESOLVED_STATE,
    FrozenVersions,
    UpdateError,
    frozen_versions_toml,
    record_frozen,
    resolve_latest_supported,
)

PROJECT_RELEASES_URL = "https://api.github.com/repos/killer23d/VaultWarden-OCI/releases?per_page=20"
UPDATE_STATE = Path("/var/lib/vaultwarden-oci/state/update-check.json")
MAX_RELEASE_BYTES = 64 * 1024 * 1024
MIN_FREE_BYTES = 512 * 1024 * 1024


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


def select_stable_release(payload: object) -> ProjectRelease:
    """Select GitHub's newest non-draft/non-prerelease project release."""
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
            and tarball.startswith("https://api.github.com/repos/killer23d/VaultWarden-OCI/tarball/")
            and isinstance(published, str)
        ):
            return ProjectRelease(tag, tarball, published)
    raise UpdateError("no stable VaultWarden-OCI project release is available")


def latest_project_release(*, getter: JsonGetter = _json_get) -> ProjectRelease:
    return select_stable_release(getter(PROJECT_RELEASES_URL))


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
    return root


@contextmanager
def candidate_source(
    source: Path | None,
    *,
    getter: JsonGetter = _json_get,
    downloader: Callable[[str], bytes] = _download,
) -> Iterator[tuple[Path, ProjectRelease | None]]:
    """Yield either an explicit developer source or the trusted stable project release."""
    if source is not None:
        root = source.resolve()
        update._validate_source(root)
        yield root, None
        return
    release = latest_project_release(getter=getter)
    raw = downloader(release.tarball_url)
    with tempfile.TemporaryDirectory(prefix="vwoci-project-release-") as directory:
        yield _extract_release(raw, Path(directory)), release


def prepare_plan(
    source_root: Path,
    *,
    project_release: ProjectRelease | None = None,
    use_latest: bool = False,
    root: Path = Path("/"),
    machine: str | None = None,
    runner: Runner = cli.run_command,
) -> PreparedPlan:
    """Create a source-coherent plan; --use-latest replaces pins with one frozen snapshot."""
    base = update.plan_update(source_root, root=root, machine=machine, runner=runner)
    if not use_latest:
        plan = base
    else:
        frozen = resolve_latest_supported(source_root, machine=machine)
        plan = update.UpdatePlan(
            source_root=source_root.resolve(),
            root=base.root,
            current_target=base.current_target,
            current_release=base.current_release,
            target_release=frozen.project_version,
            frozen=frozen,
        )
    if project_release is not None:
        source_version = update.resolve_pinned(source_root, machine=machine).project_version
        normalized = project_release.tag.removeprefix("v")
        if normalized != source_version:
            raise UpdateError(
                f"stable project release tag {project_release.tag!r} does not match its versions.toml project version {source_version!r}"
            )
    return PreparedPlan(plan=plan, project_release=project_release, use_latest=use_latest)


def _tree_bytes(root: Path) -> int:
    total = 0
    for path in root.rglob("*"):
        if path.is_symlink():
            raise UpdateError(f"candidate release contains an unsafe symlink: {path}")
        if path.is_file():
            total += path.stat().st_size
    return total


def _disk_space(source_root: Path, layout: install.Layout) -> None:
    required = max(MIN_FREE_BYTES, _tree_bytes(source_root) * 3)
    targets = {
        layout.path(install.INSTALL_ROOT).parent,
        layout.path(install.STATE_ROOT),
    }
    for target in targets:
        probe = target
        while not probe.exists() and probe != probe.parent:
            probe = probe.parent
        try:
            free = shutil.disk_usage(probe).free
        except OSError as exc:
            raise UpdateError(f"cannot inspect free disk space at {probe}: {exc}") from exc
        if free < required:
            raise UpdateError(
                f"insufficient free disk space at {probe}: need at least {required} bytes, have {free}"
            )


def _candidate_paths(directory: Path) -> runtime.Paths:
    transient = directory / "rendered"
    transient.mkdir(parents=True)
    return runtime.Paths(
        config=runtime.CONFIG,
        data=runtime.STATE / "data",
        caddy_data=runtime.STATE / "caddy/data",
        caddy_config=runtime.STATE / "caddy/config",
        caddy_log=runtime.STATE / "caddy/log",
        run=directory,
        transient=transient,
        lock=directory / "lock",
        secret_root=runtime.RUN / "secrets",
    )


def _prestage_exact_runtime(
    frozen: FrozenVersions,
    exact_source: Path,
    *,
    runner: Runner,
) -> None:
    """Pull, render, validate, and build while the current stack remains healthy."""
    docker = runner(["docker", "version", "--format", "{{.Server.Version}}"])
    if not docker.ok:
        raise UpdateError(f"Docker Engine unavailable: {_detail(docker)}")
    config = runtime.load_config()
    values = secrets.load(config.offline_recovery_recipient, runner=runner)
    admin_enabled = secrets.admin_enabled(values)
    for pin in (frozen.vaultwarden_image, frozen.caddy_builder_image, frozen.caddy_runtime_image):
        result = runner(["docker", "pull", pin.reference])
        if not result.ok:
            raise UpdateError(f"cannot pull exact {pin.name} image: {_detail(result)}")
    with tempfile.TemporaryDirectory(prefix="vwoci-update-validate-") as directory:
        paths = _candidate_paths(Path(directory))
        runtime.render(config, exact_source / "versions.toml", paths, admin_enabled=admin_enabled)
        compose = runner(["docker", "compose", "-f", str(paths.compose), "config", "--quiet"])
        if not compose.ok:
            raise UpdateError(f"candidate Compose validation failed: {_detail(compose)}")
        built = runner(
            [
                "docker", "build", "--pull=false", "--tag", frozen.caddy_image,
                "--file", str(paths.dockerfile), str(paths.transient),
            ]
        )
        if not built.ok:
            raise UpdateError(f"exact custom Caddy build failed: {_detail(built)}")
        caddy = runner(
            [
                "docker", "run", "--rm",
                "--env", f"VAULTWARDEN_DOMAIN={config.domain}",
                "--env", f"ACME_EMAIL={config.acme_email}",
                "--env", "CLOUDFLARE_API_TOKEN=validation-only",
                "--env", "ADMIN_BASIC_AUTH_HASH=$2a$14$validationonlyvalidationonlyvalidationonlyvalidationonly",
                "--volume", f"{paths.caddyfile}:/etc/caddy/Caddyfile:ro",
                frozen.caddy_image,
                "caddy", "validate", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile",
            ]
        )
        if not caddy.ok:
            raise UpdateError(f"candidate Caddy validation failed: {_detail(caddy)}")


def _preflight(exact_source: Path, plan: update.UpdatePlan, *, runner: Runner) -> runtime.RuntimeConfig:
    if plan.root == Path("/"):
        storage.verify()
    layout = install.Layout(plan.root.resolve())
    update._gate_current(layout, runner)
    config = runtime.load_config()
    secrets.load(config.offline_recovery_recipient, runner=runner)
    _disk_space(exact_source, layout)
    _prestage_exact_runtime(plan.frozen, exact_source, runner=runner)
    return config


def _stop_candidate(layout: install.Layout, runner: Runner) -> bool:
    current = layout.path(install.CURRENT_LINK) / "vwctl"
    result = runner([str(current), "stop"])
    return result.ok


def _prove_previous(layout: install.Layout, runner: Runner) -> None:
    update._gate_current(layout, runner)


def apply_prepared(
    prepared: PreparedPlan,
    *,
    runner: Runner = cli.run_command,
    activator: update.Activator = update._activate_runtime,
    record_path: Path | None = None,
    recovery_creator: Callable[..., recovery.VerifiedRecovery] = recovery.create_recovery,
) -> Path:
    """Prepare while healthy, verify recovery, then enter the short mutation boundary."""
    plan = prepared.plan
    layout = install.Layout(plan.root.resolve())
    if layout.root != Path("/") and (runner is cli.run_command or activator is update._activate_runtime):
        raise UpdateError("non-production update roots are test-only; inject test runner and activator")
    if layout.root == Path("/") and os.geteuid() != 0:
        raise UpdateError("vwctl update apply must run as root")
    current_target, current_release, previous_release = update._current(layout)
    if (current_target, current_release) != (plan.current_target, plan.current_release):
        raise UpdateError("current release changed since update check")
    if plan.already_active:
        return previous_release

    versions_text = frozen_versions_toml(plan.frozen)
    with install._frozen_source(plan.source_root, versions_text) as exact_source:
        update._validate_source(exact_source)
        config = _preflight(exact_source, plan, runner=runner)
        verified = recovery_creator(config.offline_recovery_recipient, runner=runner)
        if not verified.artifact.is_file() or verified.size <= 0:
            raise UpdateError("verified pre-update recovery did not produce a usable .vwrec artifact")
        if recovery._sha256(verified.artifact) != verified.sha256:
            raise UpdateError("verified pre-update recovery digest changed before mutation")
        update._gate_current(layout, runner)

        lock_path = install.ensure_lock_path(layout)
        with cli.mutation_lock(lock_path):
            if update._current(layout)[0] != current_target:
                raise UpdateError("current release changed after pre-update recovery")
            if plan.root == Path("/"):
                storage.verify()
            snapshot: dict[Path, tuple[bytes, int]] | None = None
            switched = False
            state_change_possible = False
            try:
                release_dir = install.stage_release(exact_source, layout, plan.target_release)
                update._verify_coherent(release_dir, exact_source)
                snapshot = update._install_units(release_dir, previous_release, layout)
                update._switch(layout, Path("releases") / plan.target_release)
                switched = True
                update._daemon_reload(layout, runner)
                try:
                    activator(plan.frozen, release_dir / "versions.toml", runner)
                except update.RuntimeActivationError as exc:
                    state_change_possible = exc.state_change_possible
                    raise
                except Exception:
                    state_change_possible = True
                    raise
                else:
                    state_change_possible = True
                update._gate_activated(layout, runner)
                crowdsec = runner([str(layout.path(install.CURRENT_LINK) / "vwctl"), "crowdsec", "status"])
                if not crowdsec.ok:
                    raise UpdateError(f"activated CrowdSec/origin gate failed: {_detail(crowdsec)}")
                record_frozen(plan.frozen, record_path or layout.path(RESOLVED_STATE))
                return release_dir
            except Exception as exc:
                if state_change_possible:
                    stopped = _stop_candidate(layout, runner)
                    action = (
                        f"coherent rollback requires recovery artifact {verified.artifact} "
                        f"sha256={verified.sha256} plus previous release {plan.current_release}"
                    )
                    raise PersistentStateFailure(
                        f"{exc}; old code was not auto-started against possibly-new persistent state; "
                        f"candidate services {'were stopped' if stopped else 'could not be proven stopped'}; {action}",
                        plan=plan,
                        verified=verified,
                        services_stopped=stopped,
                    ) from exc

                rollback_errors: list[str] = []
                if switched:
                    try:
                        update._switch(layout, current_target)
                    except Exception as rollback_exc:
                        rollback_errors.append(f"current symlink: {rollback_exc}")
                if snapshot is not None:
                    try:
                        update._restore_units(snapshot)
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
                message = str(exc)
                if rollback_errors:
                    message += "; rollback incomplete: " + "; ".join(rollback_errors)
                elif switched or snapshot is not None:
                    message += "; previous release/systemd resources restored and previous stack proved healthy"
                raise UpdateError(message) from exc


def coherent_rollback(
    failure: PersistentStateFailure,
    identity: Path,
    *,
    runner: Runner = cli.run_command,
) -> None:
    """Restore pre-update data, then previous immutable code, then prove previous health."""
    storage.verify()
    plan = failure.plan
    layout = install.Layout(plan.root.resolve())
    if not failure.services_stopped and not _stop_candidate(layout, runner):
        raise UpdateError("candidate services could not be stopped; refusing destructive recovery restore")
    if recovery._sha256(failure.verified.artifact) != failure.verified.sha256:
        raise UpdateError("pre-update recovery artifact digest no longer matches the recorded verified digest")
    recovery.restore_recovery(failure.verified.artifact, identity, start=False, runner=runner)
    lock_path = install.ensure_lock_path(layout)
    with cli.mutation_lock(lock_path):
        _, _, previous_release = update._current(layout)
        expected_previous = layout.path(install.RELEASES_DIR) / plan.current_release
        if not expected_previous.is_dir() or expected_previous.is_symlink():
            raise UpdateError("previous immutable application release is unavailable for coherent rollback")
        candidate_release = previous_release
        snapshot = update._install_units(expected_previous, candidate_release, layout)
        del snapshot
        update._switch(layout, plan.current_target)
        update._daemon_reload(layout, runner)
    start = runner([str(layout.path(install.CURRENT_LINK) / "vwctl"), "start"])
    if not start.ok:
        raise UpdateError(f"previous release failed to start after coherent data restore: {_detail(start)}")
    _prove_previous(layout, runner)


def recovery_command(failure: PersistentStateFailure) -> str:
    return (
        f"vwctl restore --file {failure.verified.artifact} --identity /path/to/offline-age-identity.txt; "
        f"then restore immutable application release {failure.plan.current_release} before starting services"
    )


def _atomic_state(payload: Mapping[str, object], path: Path = UPDATE_STATE) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(dict(payload), handle, indent=2, sort_keys=True)
            handle.write("\n"); handle.flush(); os.fsync(handle.fileno())
        os.replace(tmp, path); os.chmod(path, 0o600)
    except Exception:
        tmp.unlink(missing_ok=True); raise


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
        # Update-check truth remains in its secret-free state/journal even if notification transport fails.
        return


def record_check(
    *,
    current: str,
    candidate: str | None,
    error: str | None,
    path: Path = UPDATE_STATE,
) -> None:
    old = _load_state(path)
    available = candidate is not None and candidate != current and error is None
    payload = {
        "schema_version": 1,
        "checked_at": int(time.time()),
        "current": current,
        "candidate": candidate,
        "available": available,
        "error": error,
    }
    _atomic_state(payload, path)
    if error:
        _notify("[VaultWarden-OCI] update check failed", f"Project update check failed: {error}\n")
    elif available and (old.get("candidate") != candidate or old.get("available") is not True):
        _notify(
            "[VaultWarden-OCI] project update available",
            f"VaultWarden-OCI project update available: {current} -> {candidate}.\nRun: vwctl update check\n",
        )


def host_upgrade_check(*, runner: Runner = cli.run_command) -> tuple[int, bool, str]:
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
    refreshed = runner(["apt-get", "update"])
    if not refreshed.ok:
        raise UpdateError(f"Ubuntu package index refresh failed: {_detail(refreshed)}")
    applied = runner(["apt-get", "-y", "upgrade"])
    if not applied.ok:
        raise UpdateError(f"Ubuntu package upgrade failed: {_detail(applied)}")
    return verified, Path("/var/run/reboot-required").exists()
