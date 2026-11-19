"""Explicit opt-in one-shot CrowdSec re-arm at boot, never a Worker restart policy.

systemd only invokes this through the separately enabled
vaultwarden-oci-crowdsec-boot.service. Its parent unit stays disabled.
The local-only policy and Cloudflare Route Fail Open must be proven for
the *new* invocation; no background retries and no fake confirmation.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

from . import cloudflare_route_mode, crowdsec_worker_policy, edge, storage


@dataclass(frozen=True)
class BootResult:
    invocation_id: str
    started: bool
    cloudflare_route_updated: bool


def reconcile(*, paths: edge.EdgePaths = edge.EdgePaths(), runner=edge.run_command) -> BootResult:
    if os.geteuid() != 0:
        raise edge.EdgeError("CrowdSec boot reconciliation requires root")
    # Do not bring the bouncer up without the approved durable volume.
    # This is intentionally done before any Cloudflare/API mutation.
    storage.verify()
    if not edge._disabled(edge.BOUNCER_SERVICE, runner):
        raise edge.EdgeError("CrowdSec Worker must remain boot-disabled; only the opt-in reconciliation unit may start it")
    for unit in (edge.CROWDSEC_SERVICE, edge.FIREWALL_BOUNCER_SERVICE):
        if not edge._active(unit, runner):
            raise edge.EdgeError("CrowdSec engine and host INPUT-only firewall bouncer must be active before Worker boot re-arm")

    state = runner([
        "systemctl", "show", edge.BOUNCER_SERVICE, "--no-pager",
        "--property=LoadState,ActiveState,MainPID,Restart,UnitFileState",
    ])
    if not state.ok:
        raise edge.EdgeError("CrowdSec Worker systemd state could not be read")
    values = dict(line.split("=", 1) for line in state.stdout.splitlines() if "=" in line)
    if (values.get("LoadState") != "loaded"
            or values.get("Restart") != "no"
            or values.get("UnitFileState") != "disabled"):
        raise edge.EdgeError("CrowdSec Worker boot containment differs from the accepted policy")

    active_state = values.get("ActiveState")
    if active_state == "active":
        if (values.get("MainPID") in ("0", "", None)
                or not crowdsec_worker_policy.runtime_policy_healthy(paths, runner)):
            raise edge.EdgeError("Already-running Worker lacks trustworthy current-invocation policy")
        started = False
    elif active_state == "inactive":
        if values.get("MainPID") != "0":
            raise edge.EdgeError("Inactive Worker unexpectedly has a main process")
        # The approved one-shot token and source-policy attestation owners
        # remain inside the existing CLI implementation.
        edge.start_remediation(paths=paths, runner=runner)
        started = True
    else:
        # "failed" must not be silently reset or restarted by a boot unit.
        # An unexpected crash is a real failure, unlike a verified manual stop.
        raise edge.EdgeError("Worker is neither cleanly inactive nor validly active; manual diagnosis required")

    proof = cloudflare_route_mode.ensure_fail_open(paths=paths, runner=runner)
    if (proof.invocation_id != edge._service_invocation_id(runner)
            or not crowdsec_worker_policy.runtime_policy_healthy(paths, runner)):
        raise edge.EdgeError("Cloudflare Worker invocation changed during boot reconciliation")
    return BootResult(
        invocation_id=proof.invocation_id,
        started=started,
        cloudflare_route_updated=proof.changed,
    )
