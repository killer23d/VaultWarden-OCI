"""One bounded host-state transition for the supported direct predecessor.

This is deliberately not a generic migration framework. The current release
needs one CrowdSec compatibility transition from dev.16 to dev.17. Every other
release pair is a no-op here.
"""
from __future__ import annotations

import os
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from . import cli, crowdsec_firewall_startup, crowdsec_worker_policy, edge, install, update
from .update_versions import UpdateError

_PREDECESSOR = "0.1.0-dev.16"
_TARGET = "0.1.0-dev.17"
_LATEST_MARKER = ".latest."
_WORKER_CONFIRM_ACTION = (
    "Cloudflare Worker was re-armed with only local cscli/crowdsec decisions. "
    "ACTION: set every bouncer-created Worker Route to Fail Open in Cloudflare, "
    "run 'sudo vwctl crowdsec confirm-fail-open', then rerun the same update apply command"
)

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


def installed_current_release(*, root: Path = Path("/")) -> str | None:
    layout = install.Layout(root.resolve())
    current = layout.path(install.CURRENT_LINK)
    if not current.exists() and not current.is_symlink():
        return None
    return update._current(layout)[1]


def _worker_snapshot(
    paths: edge.EdgePaths,
    runner: Runner,
    *,
    require_local_policy: bool = True,
) -> _WorkerSnapshot:
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
    if require_local_policy and not crowdsec_worker_policy.runtime_policy_healthy(paths, runner):
        raise UpdateError(
            "supported predecessor CrowdSec Worker is not proven to use exactly local cscli/crowdsec decision sources"
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


def _worker_ready(paths: edge.EdgePaths, runner: Runner) -> bool:
    if not crowdsec_worker_policy.runtime_policy_healthy(paths, runner):
        return False
    try:
        _worker_snapshot(paths, runner, require_local_policy=True)
    except UpdateError:
        return False
    return True


def _start_rearmed_worker(
    paths: edge.EdgePaths,
    runner: Runner,
    *,
    previous_invocation: str | None,
) -> None:
    try:
        crowdsec_worker_policy.install_managed_override(paths)
        crowdsec_worker_policy.clear_attestation(paths)
    except crowdsec_worker_policy.WorkerPolicyError as exc:
        raise UpdateError(str(exc)) from exc
    edge._unlink_state(paths.fail_open_confirmation, "CrowdSec Fail Open confirmation")

    if edge._active(edge.BOUNCER_SERVICE, runner):
        stopped = runner(["systemctl", "stop", edge.BOUNCER_SERVICE])
        if not stopped.ok or edge._active(edge.BOUNCER_SERVICE, runner):
            raise UpdateError(
                "cannot stop the legacy CrowdSec Cloudflare Worker before local-only re-arm"
            )

    try:
        edge.start_remediation(paths=paths, runner=runner)
    except edge.EdgeError as exc:
        raise UpdateError(
            f"CrowdSec Cloudflare Worker local-only re-arm failed: {exc}; "
            "ACTION: retry the same update apply command; if the Worker remains inactive, "
            "run 'sudo vwctl crowdsec remediation-start', set the recreated route to Fail Open, "
            "confirm it, and retry the update"
        ) from exc

    invocation = edge._service_invocation_id(runner)
    if invocation is None:
        raise UpdateError("re-armed CrowdSec Cloudflare Worker has no valid systemd invocation")
    if previous_invocation is not None and invocation == previous_invocation:
        raise UpdateError("CrowdSec Cloudflare Worker re-arm did not create a new service invocation")
    try:
        crowdsec_worker_policy.attest_current(paths, runner)
    except crowdsec_worker_policy.WorkerPolicyError as exc:
        raise UpdateError(f"cannot prove re-armed Cloudflare Worker local-only policy: {exc}") from exc

    # The bouncer recreates Cloudflare infrastructure on start and new routes
    # default Fail Closed. Never carry the predecessor confirmation across this
    # invocation boundary; the operator must confirm the new route explicitly.
    raise UpdateError(_WORKER_CONFIRM_ACTION)


def prepare_worker_prerequisite(
    target_release: str,
    *,
    current_release: str | None = None,
    root: Path = Path("/"),
    paths: edge.EdgePaths = edge.EdgePaths(),
    runner: Runner = cli.run_command,
) -> str | None:
    """Make the predecessor Worker safe before any recovery/update mutation.

    The first dev.16 -> dev.17 apply may intentionally stop here after creating
    a new local-only Worker invocation. The operator sets that new route Fail
    Open and confirms it with the installed dev.16 ``vwctl``; rerunning the
    same update then proceeds. No application recovery or release activation
    has happened at this boundary.
    """
    if current_release is None:
        current_release = installed_current_release(root=root)
    if current_release is None or not _required(current_release, target_release):
        return current_release
    if paths == edge.EdgePaths() and os.geteuid() != 0:
        raise UpdateError("supported predecessor Worker transition must run as root")

    if _worker_ready(paths, runner):
        return current_release

    # If this is the expected second pass, the candidate-created policy
    # attestation is current but the new route has not yet been confirmed.
    if crowdsec_worker_policy.runtime_policy_healthy(paths, runner):
        invocation = edge._service_invocation_id(runner)
        if invocation is not None and not edge._fail_open_confirmed(
            paths.fail_open_confirmation,
            invocation,
        ):
            raise UpdateError(_WORKER_CONFIRM_ACTION)

    previous_invocation: str | None = None
    if edge._active(edge.BOUNCER_SERVICE, runner):
        if not crowdsec_worker_policy.managed_override_present(paths):
            # Initial predecessor state must itself be healthy before we destroy
            # its route. The parent updater has already gated dev.16, and this
            # independent proof keeps the compatibility primitive safe alone.
            previous = _worker_snapshot(paths, runner, require_local_policy=False)
            try:
                base, local, effective = crowdsec_worker_policy.source_state(paths)
            except crowdsec_worker_policy.WorkerPolicyError as exc:
                raise UpdateError(str(exc)) from exc
            if base != () or local is not None or effective != ():
                raise UpdateError(
                    "supported predecessor Cloudflare Worker does not have the expected legacy all-origin policy"
                )
            previous_invocation = previous.invocation_id
        else:
            previous_invocation = edge._service_invocation_id(runner)
    elif not crowdsec_worker_policy.managed_override_present(paths):
        raise UpdateError(
            "supported predecessor Cloudflare Worker is inactive before its local-only policy was staged"
        )

    _start_rearmed_worker(
        paths,
        runner,
        previous_invocation=previous_invocation,
    )
    return current_release


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

    # This override exists before dpkg can configure the firewall package. The
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
        if runner(["cscli", "collections", "inspect", collection]).ok:
            continue
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
    # Hub state are complete. The already re-armed Worker is not touched here.
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
    edge._command(runner, ["systemctl", "daemon-reload"], "systemd reload")
    edge._command(
        runner,
        ["systemctl", "enable", "--now", edge.FIREWALL_BOUNCER_SERVICE],
        "CrowdSec firewall bouncer enable/start",
    )
    try:
        crowdsec_firewall_startup.wait_for_input_only(
            runner,
            service=edge.FIREWALL_BOUNCER_SERVICE,
            config_input_only=lambda: edge._firewall_boundary_healthy(
                paths,
                runner,
                require_live=False,
            ),
        )
    except crowdsec_firewall_startup.FirewallStartupError as exc:
        raise UpdateError(str(exc)) from exc


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

    after = _worker_snapshot(paths, runner, require_local_policy=True)
    if after != worker:
        raise UpdateError(
            "re-armed CrowdSec Worker invocation or Fail Open confirmation changed during host-state transition"
        )


def _migrate(
    *,
    paths: edge.EdgePaths,
    runner: Runner,
    policy_path: Path,
) -> None:
    worker = _worker_snapshot(paths, runner, require_local_policy=True)
    acquisition_before = _capture_text_file(paths.acquisition)
    try:
        _install_packages(paths, runner, policy_path=policy_path)
        _provision_candidate_crowdsec(paths, runner)
        _prove_candidate_crowdsec(paths, runner, worker)
    except Exception as exc:
        cleanup: list[str] = []
        containment_error = _contain_firewall(runner)
        if containment_error:
            cleanup.append(containment_error)
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
        current_release = installed_current_release(root=root)
    if current_release is None or not _required(current_release, target_release):
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