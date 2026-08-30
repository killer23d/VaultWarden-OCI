"""One bounded host-state transition for the supported direct predecessor.

This is deliberately not a generic migration framework.  The current release
needs one host-side CrowdSec expansion before its candidate health contract can
be enforced.  Every other release pair is a no-op here.
"""
from __future__ import annotations

import os
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from . import cli, edge, install, update
from .update_versions import UpdateError

_PREDECESSOR = "0.1.0-dev.16"
_TARGET = "0.1.0-dev.17"
_LATEST_MARKER = ".latest."

Runner = Callable[..., cli.CommandResult]


@dataclass(frozen=True)
class _WorkerSnapshot:
    invocation_id: str
    confirmation: bytes


def _base_release(value: str) -> str:
    return value.split(_LATEST_MARKER, 1)[0]


def _required(current_release: str, target_release: str) -> bool:
    return (
        _base_release(current_release) == _PREDECESSOR
        and _base_release(target_release) == _TARGET
    )


def _worker_snapshot(paths: edge.EdgePaths, runner: Runner) -> _WorkerSnapshot:
    if not edge._active(edge.BOUNCER_SERVICE, runner):
        raise UpdateError("supported predecessor CrowdSec Worker is not active")
    if not edge._disabled(edge.BOUNCER_SERVICE, runner):
        raise UpdateError("supported predecessor CrowdSec Worker is not boot-disabled")
    config_test = runner(
        [edge.BOUNCER_BINARY, "-c", str(paths.remediation_config), "-t"]
    )
    if not config_test.ok:
        raise UpdateError("supported predecessor CrowdSec Worker configuration is invalid")
    bouncer = runner(["cscli", "bouncers", "inspect", edge.BOUNCER_ID, "-o", "json"])
    if not bouncer.ok:
        raise UpdateError("supported predecessor CrowdSec Worker LAPI identity is unavailable")
    invocation = edge._service_invocation_id(runner)
    if invocation is None or not edge._fail_open_confirmed(paths.fail_open_confirmation, invocation):
        raise UpdateError(
            "supported predecessor CrowdSec Worker lacks Fail Open confirmation for its current invocation"
        )
    try:
        info = paths.fail_open_confirmation.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise OSError("not a regular file")
        confirmation = paths.fail_open_confirmation.read_bytes()
    except OSError as exc:
        raise UpdateError(
            f"cannot preserve supported predecessor CrowdSec Fail Open confirmation: {exc}"
        ) from exc
    return _WorkerSnapshot(invocation, confirmation)


def _contain_firewall(runner: Runner) -> str | None:
    result = runner(["systemctl", "disable", "--now", edge.FIREWALL_BOUNCER_SERVICE])
    if result.ok or edge._service_absent(result):
        return None
    detail = result.kind if result.returncode is None else f"exit {result.returncode}"
    return f"firewall bouncer disable/stop could not be proven ({detail})"


def _restore_acquisition(
    path: Path,
    original: tuple[str, int] | None,
) -> None:
    if original is None:
        path.unlink(missing_ok=True)
        return
    text, mode = original
    edge._write_root_file(path, text, mode)


def _capture_text_file(path: Path) -> tuple[str, int] | None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise UpdateError(f"cannot inspect predecessor CrowdSec acquisition {path}: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise UpdateError(f"predecessor CrowdSec acquisition is not a regular file: {path}")
    try:
        return path.read_text(encoding="utf-8"), stat.S_IMODE(info.st_mode)
    except (OSError, UnicodeError) as exc:
        raise UpdateError(f"cannot read predecessor CrowdSec acquisition {path}: {exc}") from exc


def _install_packages(
    paths: edge.EdgePaths,
    runner: Runner,
    *,
    policy_path: Path,
) -> None:
    installer: Path | None = None
    try:
        installer = edge._download_installer()
        edge._command(runner, ["/bin/sh", str(installer)], "CrowdSec repository setup")
    finally:
        if installer is not None:
            installer.unlink(missing_ok=True)
    edge._command(runner, ["apt-get", "update"], "apt metadata refresh")

    # This override exists before dpkg can configure the firewall package.  The
    # current upstream base contains INPUT+FORWARD, which is never acceptable
    # for this appliance even for a transient package-maintainer start attempt.
    edge._write_root_file(
        edge._firewall_local_path(paths),
        edge.firewall_bouncer_bootstrap_local_text(),
        0o600,
    )

    install_error: Exception | None = None
    try:
        with edge._suppress_package_service_starts(policy_path):
            edge._apt_command(
                runner,
                [
                    "apt-get",
                    "install",
                    "-y",
                    "crowdsec",
                    "crowdsec-firewall-bouncer-nftables",
                    "logrotate",
                ],
                "CrowdSec predecessor transition package installation",
                env=edge._package_install_env(),
            )
    except Exception as exc:
        install_error = exc

    containment_error = _contain_firewall(runner)
    if install_error is not None:
        suffix = f"; {containment_error}" if containment_error else ""
        raise UpdateError(f"{install_error}{suffix}") from install_error
    if containment_error:
        raise UpdateError(containment_error)


def _provision_candidate_crowdsec(paths: edge.EdgePaths, runner: Runner) -> None:
    edge._remove_cscli_setup_acquisitions(paths)
    edge._assert_acquisition_scope(paths)
    edge._command(runner, ["cscli", "hub", "update"], "CrowdSec Hub metadata refresh")
    for collection in edge.CROWDSEC_COLLECTIONS:
        edge._command(
            runner,
            ["cscli", "collections", "install", collection],
            f"CrowdSec collection installation ({collection})",
        )

    vaultwarden_log = edge._vaultwarden_log_path(paths)
    edge._prepare_vaultwarden_log(vaultwarden_log)
    edge._write_root_file(
        paths.acquisition,
        edge.acquisition_text(paths.caddy_log, vaultwarden_log),
        0o600,
    )
    edge._write_root_file(
        edge._logrotate_path(paths),
        edge.vaultwarden_logrotate_text(vaultwarden_log),
        0o644,
    )

    # The predecessor engine stays live until its replacement acquisition and
    # Hub state are complete.  Only then is it restarted; the already-running
    # Worker is deliberately not stopped, restarted, disabled, or reconfigured.
    edge._command(runner, ["systemctl", "restart", edge.CROWDSEC_SERVICE], "CrowdSec restart")
    if not edge._active(edge.CROWDSEC_SERVICE, runner):
        raise UpdateError("CrowdSec engine is not active after predecessor transition restart")

    firewall_key = edge._create_lapi_bouncer_key(
        runner,
        edge.FIREWALL_BOUNCER_ID,
        "host firewall remediation",
    )
    edge._write_root_file(
        edge._firewall_local_path(paths),
        edge.firewall_bouncer_local_text(
            api_key=firewall_key,
            lapi_url=edge._local_lapi_url(runner),
        ),
        0o600,
    )
    if not edge._firewall_boundary_healthy(paths, runner, require_live=False):
        raise UpdateError(
            "CrowdSec firewall bouncer effective configuration is not valid INPUT-only nftables policy"
        )
    edge._command(
        runner,
        ["systemctl", "enable", "--now", edge.FIREWALL_BOUNCER_SERVICE],
        "CrowdSec firewall bouncer enable/start",
    )
    if not edge._firewall_boundary_healthy(paths, runner, require_live=True):
        raise UpdateError("CrowdSec firewall bouncer live nftables ownership is not exactly host INPUT")


def _prove_candidate_crowdsec(
    paths: edge.EdgePaths,
    runner: Runner,
    worker: _WorkerSnapshot,
) -> None:
    if not edge._active(edge.CROWDSEC_SERVICE, runner):
        raise UpdateError("candidate CrowdSec engine proof failed")
    missing = [
        collection
        for collection in edge.CROWDSEC_COLLECTIONS
        if not runner(["cscli", "collections", "inspect", collection]).ok
    ]
    if missing:
        raise UpdateError("candidate CrowdSec Hub collection proof failed: " + ", ".join(missing))
    if (
        not edge._active(edge.FIREWALL_BOUNCER_SERVICE, runner)
        or not edge._enabled(edge.FIREWALL_BOUNCER_SERVICE, runner)
        or not runner(
            ["cscli", "bouncers", "inspect", edge.FIREWALL_BOUNCER_ID, "-o", "json"]
        ).ok
        or not edge._firewall_boundary_healthy(paths, runner, require_live=True)
    ):
        raise UpdateError("candidate CrowdSec host INPUT firewall proof failed")

    after = _worker_snapshot(paths, runner)
    if after != worker:
        raise UpdateError(
            "supported predecessor CrowdSec Worker invocation or Fail Open confirmation changed during host-state transition"
        )


def _migrate(
    *,
    paths: edge.EdgePaths,
    runner: Runner,
    policy_path: Path,
) -> None:
    worker = _worker_snapshot(paths, runner)
    acquisition_before = _capture_text_file(paths.acquisition)
    firewall_key_created = False
    try:
        _install_packages(paths, runner, policy_path=policy_path)
        _provision_candidate_crowdsec(paths, runner)
        firewall_key_created = True
        _prove_candidate_crowdsec(paths, runner, worker)
    except Exception as exc:
        cleanup: list[str] = []
        containment_error = _contain_firewall(runner)
        if containment_error:
            cleanup.append(containment_error)
        if firewall_key_created:
            deleted = runner(
                ["cscli", "bouncers", "delete", edge.FIREWALL_BOUNCER_ID, "--ignore-missing"]
            )
            if not deleted.ok:
                cleanup.append("new firewall LAPI identity could not be removed")
        try:
            _restore_acquisition(paths.acquisition, acquisition_before)
            restarted = runner(["systemctl", "restart", edge.CROWDSEC_SERVICE])
            if not restarted.ok or not edge._active(edge.CROWDSEC_SERVICE, runner):
                cleanup.append("predecessor CrowdSec acquisition/runtime could not be restored")
        except (OSError, edge.EdgeError, UpdateError) as restore_exc:
            cleanup.append(f"predecessor CrowdSec acquisition restore failed ({restore_exc})")
        suffix = "; rollback: " + "; ".join(cleanup) if cleanup else ""
        raise UpdateError(f"supported predecessor CrowdSec transition failed: {exc}{suffix}") from exc


def apply_if_required(
    target_release: str,
    *,
    current_release: str | None = None,
    root: Path = Path("/"),
    paths: edge.EdgePaths = edge.EdgePaths(),
    runner: Runner = cli.run_command,
    policy_path: Path | None = None,
) -> bool:
    """Apply the only supported predecessor host transition, otherwise no-op."""
    if current_release is None:
        layout = install.Layout(root.resolve())
        current = layout.path(install.CURRENT_LINK)
        # Standalone candidate-render tests have no installed appliance.  The
        # parent updater has already proven this path in real update execution.
        if not current.exists() and not current.is_symlink():
            return False
        try:
            _, current_release, _ = update._current(layout)
        except UpdateError:
            raise
    if not _required(current_release, target_release):
        return False
    if paths == edge.EdgePaths() and os.geteuid() != 0:
        raise UpdateError("supported predecessor CrowdSec transition must run as root")
    if policy_path is None:
        policy_path = (
            edge.POLICY_RC_D
            if paths == edge.EdgePaths()
            else paths.acquisition.parent / ".policy-rc.d"
        )
    _migrate(paths=paths, runner=runner, policy_path=policy_path)
    return True
