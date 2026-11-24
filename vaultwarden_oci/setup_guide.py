"""Interactive first-run continuation over existing operation owners."""
from __future__ import annotations

import hashlib
import stat
from pathlib import Path
from typing import Callable, Sequence

from . import cli, crowdsec_worker_policy, dns_publication, edge, install, operations, recovery_ux, runtime, secrets

_BASE = ("host.os", "host.architecture", "versions.toml", "runtime.docker",
         "runtime.compose", "storage.dedicated", "notification.catalog")
_SECURITY = ("crowdsec.engine", "crowdsec.hub", "crowdsec.firewall")
_ORIGIN = ("edge.cloudflare.cidrs", "edge.cloudflare.iptables")
_AUTOMATION = {"automation.required", "automation.persistence", "automation.execution"}
_PRESTART = {
    "runtime.paths": {
        ("SKIP", "runtime paths are not materialized yet"),
        ("FAIL", "runtime paths are only partially materialized"),
    },
    "edge.caddy.trusted_proxy": {("SKIP", "rendered Caddy config is not present; service may be stopped")},
    "edge.admin.protection": {("SKIP", "rendered Caddy admin policy is not present; service may be stopped")},
    "edge.caddy.health": {("SKIP", "Caddy container is not present; service may be stopped")},
}


class Hold(RuntimeError):
    """A specific incomplete or unapproved boundary."""


def _pass(checks: dict, names: Sequence[str]) -> bool:
    return all(checks.get(name, {}).get("status") == "PASS" for name in names)


def _baseline(payload: dict) -> dict:
    rows = payload["doctor"]["checks"]
    checks = {row["id"]: row for row in rows}
    if (payload.get("schema_version") != 1 or len(checks) != len(rows)
            or not _pass(checks, _BASE)
            or any(row.get("status") not in {"PASS", "FAIL", "WARN", "SKIP"} for row in rows)
            or payload["storage"]["state"] not in {"ok", "warning"}
            or payload["operational"]["update_guard"]["state"] != "absent"):
        raise Hold("Host, version, dedicated storage or recovery guard is not verified; inspect Doctor.")
    current = payload["runtime"]
    services = current["services"]
    if len(services) != 2 or {row["service"] for row in services} != {"vaultwarden", "caddy"}:
        raise Hold("Runtime inventory is incomplete.")
    if current["overall"] == "stopped":
        valid = all(row["state"] == "absent" for row in services)
    elif current["overall"] == "running":
        valid = all(row["state"] == "running" and row["health"] == "healthy" for row in services)
    else:
        valid = False
    if not valid:
        raise Hold("Runtime is degraded or unknown; diagnose before continuing.")
    return checks


def _isolated(payload: dict) -> None:
    target = payload["automation"]["target"]
    timers = payload["timers"]
    jobs = payload["operational"]["jobs"]
    boot = payload["operational"]["crowdsec"]["boot_reconciliation"]

    def inactive(row: dict) -> bool:
        return row.get("load_state") == "loaded" and row.get("active_state") == "inactive"

    if (not inactive(target) or target.get("enabled") != "disabled"
            or len(timers) != len(operations.TIMER_UNITS)
            or {row.get("unit") for row in timers} != set(operations.TIMER_UNITS)
            or any(not inactive(row) or row.get("enabled") != "disabled" for row in timers)
            or any(not inactive(jobs.get(name, {})) or jobs[name].get("result") not in {"success", ""}
                   for name in operations._REQUIRED_JOBS)
            or not inactive(boot) or boot.get("enabled") != "disabled"):
        raise Hold("Target, timers, jobs or optional Worker boot unit are not verifiably isolated; no schedule changed.")


def _prestart(payload: dict, checks: dict) -> None:
    if payload["runtime"]["overall"] != "stopped":
        raise Hold("First start requires verified absent containers.")
    for name in operations._REQUIRED_FOUNDATIONS:
        row = checks.get(name, {})
        if row.get("status") == "PASS":
            continue
        if (row.get("status"), row.get("message")) in _PRESTART.get(name, set()):
            print(f"{row['status']}: {name}: {row['message']} (recheck after supported start)")
            continue
        raise Hold(f"First-start prerequisite not PASS: {name}")
    for name, row in checks.items():
        if row["status"] == "FAIL" and (row["status"], row.get("message")) not in _PRESTART.get(name, set()):
            raise Hold(f"Unresolved Doctor FAIL: {name}")


def _pre_activation(readiness: dict, *, before_backup: bool = False) -> None:
    """Check prerequisites separately; final readiness is not relabelled."""
    rows = readiness["required"]
    checks = {row["id"]: row for row in rows}
    expected = set(operations._REQUIRED_FOUNDATIONS) | {
        "diagnostics.overall", "runtime.running", "update.guard", "recovery.local_receipt",
        "https.loopback", *_AUTOMATION,
    }
    if not expected <= checks.keys() or len(checks) != len(rows):
        raise Hold("Readiness evidence is incomplete.")
    for name, row in checks.items():
        if name in _AUTOMATION:
            continue
        if name == "recovery.local_receipt" and before_backup and row["status"] == "WARN":
            print("WARN: current verified local recovery receipt remains required before automation.")
            continue
        if row["status"] != "PASS":
            raise Hold(f"Pre-activation prerequisite not PASS: {name}; inspect readiness.")


def _fingerprint() -> tuple[str, ...]:
    return tuple(hashlib.sha256(path.read_bytes()).hexdigest()
                 for path in (install.CONFIG_PATH, install.SECRETS_PATH))


def _consent(prompt: str, word: str) -> None:
    if input(f"{prompt} Type {word} to continue (anything else stops): ").strip() != word:
        raise Hold("Operator did not confirm; no further operations will run.")


def _workspaces() -> tuple[Path, ...]:
    root = recovery_ux.SENSITIVE_RUN
    try:
        info = root.lstat()
    except FileNotFoundError:
        return ()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        raise Hold("Transient recovery directory is not a protected real root-owned directory.")
    return tuple(sorted(root.glob("setup-offline-recovery-*")))


def _retained_identity(workspace: Path) -> tuple:
    directory = workspace.lstat()
    if not stat.S_ISDIR(directory.st_mode) or directory.st_uid != 0 or stat.S_IMODE(directory.st_mode) != 0o700:
        raise Hold("Retained workspace is not an exact protected directory; secure the existing identity.")
    identity = workspace / "offline-age-identity.txt"
    key = identity.lstat()
    if (not stat.S_ISREG(key.st_mode) or key.st_uid != 0 or stat.S_IMODE(key.st_mode) != 0o600
            or key.st_nlink != 1 or key.st_size <= 0 or set(workspace.iterdir()) != {identity}):
        raise Hold("Retained identity is uncertain; no export or cleanup attempted.")
    return (identity, directory.st_dev, directory.st_ino, key.st_dev, key.st_ino,
            key.st_size, key.st_mtime_ns, key.st_ctime_ns)


def _custody(recheck: Callable) -> None:
    workspaces = _workspaces()
    if len(workspaces) > 1:
        raise Hold("Multiple retained offline recovery workspaces; identify the correct existing key before reboot.")
    if workspaces:
        workspace = workspaces[0]
        witness = _retained_identity(workspace)
        print(f"Existing transient offline identity: {witness[0]}. No replacement will be generated.")
        _consent("Export a verified encrypted recovery kit using this exact identity?", "EXPORT")
        recheck()
        if _retained_identity(workspace) != witness:
            raise Hold("Retained identity changed; no export attempted.")
        result = recovery_ux.export_recovery_kit(witness[0])
        print(f"Verified encrypted recovery kit: {result.archive}. SMTP acceptance is not mailbox proof.")
        _consent("Confirm the kit is secured off-host with passphrase separate; remove this exact transient copy?", "SAVED")
        recheck()
        if _retained_identity(workspace) != witness:
            raise Hold("Retained identity changed; no cleanup attempted.")
        recovery_ux._cleanup_workspace(workspace)
    else:
        _consent("Confirm the correct offline recovery identity and verified encrypted kit are secured off-host (passphrase separate). If not, use vwctl guide recovery-kit first.", "CUSTODY")
    print("Administrator custody acknowledgment; not independent off-host proof.")


def main(*, run: Callable, ensure_selected: Callable) -> int:
    """Observe real state, require explicit consent, and delegate mutations."""
    print("Purpose: continue first-run setup and safe activation.")
    print("Prerequisites: installed immutable appliance, dedicated storage and exclusive administrator session.")
    print("Impact and consent: each operation is separate; DNS publication and recurring DNS writes require their own consent.")
    print("Verification and next action: local readiness is not production approval.")

    def observe(*, isolated: bool = True) -> tuple[dict, dict]:
        ensure_selected()
        payload = operations.status_payload()
        checks = _baseline(payload)
        if isolated:
            _isolated(payload)
        return payload, checks

    def command(args: Sequence[str]) -> None:
        ensure_selected()
        if run(args).returncode != 0:
            raise Hold("Operation did not succeed: vwctl " + " ".join(args) + "; inspect its result.")
        ensure_selected()

    def apply(args: Sequence[str], prompt: str, word: str) -> None:
        _consent(prompt, word)
        observe()
        command(args)

    try:
        payload, checks = observe(isolated=False)
        if (payload["automation"]["overall"] == "PASS"
                and payload["operational"]["automation"]["boot_persistence"] == "persistent"
                and payload["runtime"]["overall"] == "running"):
            print("Already activated: read-only readiness review; no setup operation will be replayed.")
            return run(["readiness"]).returncode
        _isolated(payload)
        if not _pass(checks, ("config.toml",)):
            apply(["config", "edit"], "Open the validated config editor?", "EDIT")
        if runtime.load_config().smtp_host == "smtp.invalid":
            apply(["config", "edit"], "Complete SMTP configuration?", "EDIT")
        if runtime.load_config().smtp_host == "smtp.invalid":
            raise Hold("SMTP hostname is still the initial placeholder.")
        command(["config", "validate", "--file", str(install.CONFIG_PATH)])
        payload, checks = observe()
        if not _pass(checks, ("secrets.custody",)):
            raise Hold("Existing Age/SOPS custody is not verified; do not generate another identity.")
        if not _pass(checks, ("secrets.decrypt",)):
            apply(["secrets", "edit"], "Open the encrypted credentials editor?", "EDIT")
        command(["secrets", "validate"])
        config = runtime.load_config()
        values = secrets.validate_encrypted(config.offline_recovery_recipient, paths=runtime.Paths().secret_paths())
        if not values.get("cloudflare_remediation_token"):
            raise Hold("Standard CrowdSec remediation credential is missing; use vwctl secrets edit.")
        del values
        stable = _fingerprint()

        def recheck() -> tuple[dict, dict]:
            current, current_checks = observe()
            if _fingerprint() != stable or not _pass(current_checks, ("config.toml", "secrets.custody", "secrets.decrypt")):
                raise Hold("Configuration or credentials changed or no longer validate; review and resume.")
            return current, current_checks

        _custody(recheck)
        _consent("Inspect the Cloudflare DNS record and send a real SMTP test message?", "VALIDATE")
        recheck()
        plan = dns_publication.update(dry_run=True)
        print(f"DNS plan (no write): {plan.before.domain} {plan.before.record_ipv4} -> {plan.before.public_ipv4}")
        command(["notification", "test", "--smtp"])
        _consent("SMTP transport succeeded; confirm receipt in the intended mailbox?", "RECEIVED")

        payload, checks = recheck()
        if not _pass(checks, _SECURITY):
            worker = operations._systemd_properties(edge.BOUNCER_SERVICE)
            if (payload["runtime"]["overall"] != "stopped"
                    or worker.get("active_state") != "inactive"
                    or worker.get("load_state") not in {"loaded", "not-found"}):
                raise Hold("Security prerequisites failed on a running or uncertain appliance/Worker; no setup replay.")
            _consent("Configure the supported CrowdSec engine and host INPUT-only firewall?", "SECURITY")
            payload, _ = recheck()
            if (payload["runtime"]["overall"] != "stopped"
                    or operations._systemd_properties(edge.BOUNCER_SERVICE).get("active_state") != "inactive"):
                raise Hold("Application or Worker is no longer stopped.")
            command(["crowdsec", "setup"])
            payload, checks = recheck()
        if not _pass(checks, _SECURITY):
            raise Hold("CrowdSec engine/hub/firewall verification failed.")

        if not _pass(checks, ("crowdsec.cloudflare",)):
            worker = operations._systemd_properties(edge.BOUNCER_SERVICE)
            if worker.get("load_state") != "loaded" or worker.get("enabled") != "disabled":
                raise Hold("Worker must be loaded and boot-disabled.")
            if worker.get("active_state") == "inactive":
                _consent("Start one explicit Worker invocation (may create a Cloudflare Route)?", "START-WORKER")
                recheck()
                command(["crowdsec", "remediation-start"])
            elif worker.get("active_state") != "active":
                raise Hold("Worker state uncertain; do not restart it automatically.")
            payload, checks = recheck()
            if not _pass(checks, ("crowdsec.cloudflare",)):
                invocation = edge._service_invocation_id(edge.run_command)
                if invocation is None or not crowdsec_worker_policy.runtime_policy_healthy(edge.EdgePaths(), edge.run_command):
                    raise Hold("Current Worker invocation/source policy is unproven.")
                print("Manual Fail Open review or opt-in API assistance (undocumented provider field, independent readback). Neither restarts the Worker.")
                method = input("Type MANUAL, API or anything else to stop: ").strip()
                if method == "MANUAL":
                    _consent("Set every bouncer-created Worker Route to Fail Open in Cloudflare and verify it.", "FAIL-OPEN")
                    recheck()
                    edge.confirm_fail_open(expected_invocation=invocation)
                elif method == "API":
                    _consent("Authorize API-assisted Fail Open for the exact current managed Route?", "SET-FAIL-OPEN")
                    recheck()
                    if edge._service_invocation_id(edge.run_command) != invocation:
                        raise Hold("Worker invocation changed; review the current Route.")
                    command(["crowdsec", "ensure-fail-open"])
                else:
                    raise Hold("Fail Open method not authorized.")
        payload, checks = recheck()
        if not _pass(checks, (*_SECURITY, "crowdsec.cloudflare")):
            raise Hold("Current Worker policy/Fail Open not verified.")

        if not _pass(checks, _ORIGIN):
            _consent("Refresh and verify Cloudflare-only origin filtering?", "ORIGIN")
            recheck()
            command(["edge", "refresh"])
            payload, checks = recheck()
        if not _pass(checks, _ORIGIN):
            raise Hold("Origin filtering is not verified.")
        if payload["runtime"]["overall"] == "stopped":
            _prestart(payload, checks)
            _consent("Start the protected application locally? This does not authorize moving public traffic.", "START")
            payload, checks = recheck()
            _prestart(payload, checks)
            command(["start"])

        recheck()
        _pre_activation(operations.readiness_payload(), before_backup=True)
        print("PASS: local foundations and trusted loopback HTTPS; not public ingress proof.")
        plan = dns_publication.update(dry_run=True)
        print(f"DNS plan: {plan.before.domain} {plan.before.record_ipv4} -> {plan.before.public_ipv4}")
        if plan.changed:
            _consent("Publish this exact proxied A-record change? This may move public traffic.", "PUBLISH")
            recheck()
            _pre_activation(operations.readiness_payload(), before_backup=True)
            result = dns_publication.update(expected_before=plan.before)
            if not result.applied or not result.after.in_sync:
                raise Hold("DNS publication not verified.")
            print("PASS: DNS owner verified the A-record readback.")
        else:
            print("DNS already in sync; no write requested.")
        payload, _ = recheck()
        config = runtime.load_config()
        if config.offsite_remote or config.local_retention_days or config.remote_retention_days:
            raise Hold("First-run guide does not authorize remote publication or pruning; review backup policy explicitly.")
        if payload["operational"]["backup"]["local"].get("state") != "current":
            _consent("Create and verify the first local encrypted application backup (no pruning)?", "BACKUP")
            recheck()
            command(["backup"])
        else:
            print("Current local verification receipt found; not a new restore or off-host proof.")
        recheck()
        _pre_activation(operations.readiness_payload())
        _consent("Enable persistent systemd automation? The health timer launches DNS synchronization which can CHANGE PUBLIC TRAFFIC.", "ENABLE")
        recheck()
        _pre_activation(operations.readiness_payload())
        if not dns_publication.status().in_sync:
            raise Hold("DNS no longer matches this origin; review publication before automation.")
        recheck()
        ensure_selected()
        if not cli.run_command(["systemctl", "enable", "--now", operations.AUTOMATION_TARGET]).ok:
            raise Hold("Activation did not return success; inspect target/timers; state is not assumed rolled back.")
        ensure_selected()
        command(["timers"])
        print("Activation returned successfully. Final readiness may remain incomplete until scheduled execution is recorded.")
        return run(["readiness"]).returncode
    except (EOFError, KeyboardInterrupt):
        print("HOLD: interrupted; completed owner operations may remain applied. Inspect status before resuming.")
        return 2
    except Hold as exc:
        print(f"HOLD: {exc}")
        return 2
    except (OSError, RuntimeError, ValueError, KeyError, TypeError) as exc:
        print(f"HOLD: verification or operation failed ({type(exc).__name__}); inspect the owner before resuming.")
        return 2
