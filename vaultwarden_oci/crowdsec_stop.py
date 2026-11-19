"""Verified explicit CrowdSec Worker stop, without masking unexpected exits.

Upstream receives SIGTERM, removes its Worker Route, then logs a fatal
"received SIGTERM" error and exits 1. systemd consequently records failed.
We may reset that particular failed state only after an *operator-owned*
stop and independent Cloudflare Route cleanup proof, never via global
SuccessExitStatus=1 (which would conceal crashes).
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Mapping

from . import cloudflare_route_mode, crowdsec_worker_policy, edge


@dataclass(frozen=True)
class StopResult:
    old_invocation_id: str
    old_route_id: str
    original_exit_status: int
    normalized: bool


def _unit(runner) -> Mapping[str, str]:
    result = runner([
        "systemctl", "show", edge.BOUNCER_SERVICE, "--no-pager",
        "--property=LoadState,ActiveState,SubState,Result,UnitFileState,MainPID,NRestarts,Restart,InvocationID,ExecMainStatus",
    ])
    if not result.ok:
        raise edge.EdgeError("Worker unit status unavailable during controlled stop")
    return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)


def stop(*, paths: edge.EdgePaths = edge.EdgePaths(), runner=edge.run_command) -> StopResult:
    if os.geteuid() != 0:
        raise edge.EdgeError("controlled CrowdSec Worker stop requires root")
    before = _unit(runner)
    invocation = edge._service_invocation_id(runner)
    if (
        not invocation
        or before.get("LoadState") != "loaded"
        or before.get("ActiveState") != "active"
        or before.get("UnitFileState") != "disabled"
        or before.get("Restart") != "no"
        or before.get("InvocationID") != invocation
        or before.get("MainPID") in (None, "", "0")
        or not crowdsec_worker_policy.runtime_policy_healthy(paths, runner)
        or not edge._fail_open_confirmed(paths.fail_open_confirmation, invocation)
    ):
        raise edge.EdgeError("Worker must be active, current-invocation attested and confirmed Fail Open before controlled stop")

    # Read-only Cloudflare GET preflight: never stop a foreign or ambiguous
    # Route, even if a stale local operator confirmation exists.
    old_id = cloudflare_route_mode.read_owned_route_id(require_fail_open=True)
    command = runner(["systemctl", "stop", edge.BOUNCER_SERVICE])
    if not command.ok:
        raise edge.EdgeError("systemd did not accept the explicit Worker stop; inspect unit before retrying")
    state = _unit(runner)
    if (
        state.get("LoadState") != "loaded"
        or state.get("ActiveState") not in ("inactive", "failed")
        or state.get("UnitFileState") != "disabled"
        or state.get("Restart") != "no"
        or state.get("NRestarts") != "0"
        or state.get("MainPID") != "0"
        or state.get("InvocationID") != invocation
    ):
        raise edge.EdgeError("Worker not completely stopped or unit state changed; do not reset failure")
    if state.get("ActiveState") == "failed":
        if state.get("Result") != "exit-code" or state.get("ExecMainStatus") != "1":
            raise edge.EdgeError("Worker stopped with an unexpected failure, not the known upstream SIGTERM exit")
        status = 1
    else:
        if state.get("Result") != "success" or state.get("ExecMainStatus") not in ("0", ""):
            raise edge.EdgeError("Inactive Worker has an unexpected exit reason")
        status = 0

    cloudflare_route_mode.wait_owned_route_absent(old_id)
    # Cleanup is independently proven. Retire the old invocation proof, and
    # only now normalize *this specific* systemd unit's expected exit=1.
    edge._unlink_state(paths.fail_open_confirmation, "CrowdSec Fail Open confirmation")
    if status == 1:
        reset = runner(["systemctl", "reset-failed", edge.BOUNCER_SERVICE])
        if not reset.ok:
            raise edge.EdgeError("Cloudflare cleanup proven but systemd failed-state reset unsuccessful")
        state = _unit(runner)
        if state.get("ActiveState") != "inactive" or state.get("MainPID") != "0":
            raise edge.EdgeError("Worker unit not inactive after verified reset-failed")
    return StopResult(
        old_invocation_id=invocation,
        old_route_id=old_id,
        original_exit_status=status,
        normalized=status == 1,
    )
