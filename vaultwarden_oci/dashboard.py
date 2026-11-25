"""Interactive operations dashboard for the authoritative ``vwctl`` surface."""
from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
from pathlib import Path
from typing import Callable, Sequence

from . import install, operator_output

RELEASE_ROOT = Path(__file__).resolve().parents[1]
VWCTL = RELEASE_ROOT / "vwctl"
DIVIDER = "------------------------------------------------------------"


class Style:
    def __init__(self, *, stream=None) -> None:
        stream = stream or sys.stdout
        self.enabled = operator_output.color_enabled(stream)

    def code(self, value: str, code: str) -> str:
        return f"\033[{code}m{value}\033[0m" if self.enabled else value

    def success(self, value: str) -> str: return self.code(value, "32")
    def warning(self, value: str) -> str: return self.code(value, "33")
    def failure(self, value: str) -> str: return self.code(value, "31")
    def info(self, value: str) -> str: return self.code(value, "36")
    def action(self, value: str) -> str: return self.code(value, "34")
    def rollback(self, value: str) -> str: return self.code(value, "35")
    def bold(self, value: str) -> str: return self.code(value, "1")
    def header(self, value: str) -> str: return self.code(value, "1;7")


STYLE = Style()


def _clear() -> None:
    if operator_output.color_enabled(sys.stdout) and os.environ.get("TERM"):
        print("\033[2J\033[H", end="")


def _press_enter() -> None:
    input("\n" + STYLE.header(" Press [Enter] to return to the menu "))


class ReleaseChanged(RuntimeError):
    """The running presentation no longer belongs to the selected release."""


def _installed_context() -> bool:
    return RELEASE_ROOT.parent == install.RELEASES_DIR


def _ensure_selected() -> None:
    if not _installed_context():
        return
    try:
        selected = install.CURRENT_LINK.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise ReleaseChanged("installed release selection is unavailable") from exc
    if selected != RELEASE_ROOT:
        raise ReleaseChanged("installed release selection changed")


def _run(argv: Sequence[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    _ensure_selected()
    # Keep the canonical symlink unresolved: it may legitimately select the
    # supported update controller while ordinary commands use the predecessor.
    launcher = install.VWCTL_LINK if _installed_context() else VWCTL
    env = dict(os.environ)
    for name in ("PYTHONHOME", "PYTHONPATH", "PYTHONPYCACHEPREFIX"):
        env.pop(name, None)
    env.update(PYTHONDONTWRITEBYTECODE="1", PYTHONNOUSERSITE="1")
    env["PATH"] = "/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin"
    interrupted = False

    def child_owns_interrupt(signum: int, frame: object) -> None:
        nonlocal interrupted
        interrupted = True

    # The foreground child receives Ctrl-C too. Let its existing transaction
    # owner finish cleanup; subprocess.run otherwise kills it when the parent
    # raises KeyboardInterrupt. A caught handler resets on exec (SIG_IGN would
    # instead make the child ignore Ctrl-C as well).
    previous = signal.signal(signal.SIGINT, child_owns_interrupt) if not capture else None
    try:
        result = subprocess.run(
            [str(launcher), *argv], text=True, capture_output=capture,
            check=False, env=env, timeout=60 if capture else None,
        )
    finally:
        if not capture:
            signal.signal(signal.SIGINT, previous)
    _ensure_selected()
    if interrupted:
        raise KeyboardInterrupt
    return result


def _object(value: object) -> dict[str, object]:
    return value if isinstance(value, dict) else {}


def _status_problem(payload: object) -> str | None:
    """Check the presentation boundary, without reimplementing classification."""
    if not isinstance(payload, dict):
        return "status did not return an object"
    if payload.get("presentation_error"):
        return str(payload["presentation_error"])
    if type(payload.get("schema_version")) is not int or payload["schema_version"] != 1:
        return "status schema is unavailable or unsupported"
    for key in ("runtime", "doctor", "storage", "operational", "automation", "update", "edge", "crowdsec", "admin"):
        if not isinstance(payload.get(key), dict):
            return f"status section {key} is unavailable or malformed"
    for section, key in (("runtime", "overall"), ("doctor", "overall"), ("storage", "state"),
                         ("automation", "overall"), ("update", "check_state"),
                         ("edge", "overall"), ("crowdsec", "overall"), ("admin", "status")):
        if not isinstance(payload[section].get(key), str):
            return f"status evidence {section}.{key} is unavailable or malformed"
    if type(payload.get("reboot_required")) is not bool or any(
        type(payload["update"].get(key)) is not bool for key in ("available", "check_stale")
    ):
        return "host or update evidence is unavailable or malformed"
    operational = _object(payload.get("operational"))
    if not isinstance(operational.get("state"), str) or operational["state"] not in {
        "OPERATIONAL", "ATTENTION", "CRITICAL", "RECOVERY REQUIRED",
        "SETUP INCOMPLETE", "MAINTENANCE / STOPPED",
    } or not isinstance(operational.get("reason"), str):
        return "operational outcome is unavailable or malformed"
    for key in ("backup", "automation", "update_guard", "notification"):
        if not isinstance(operational.get(key), dict):
            return f"operational evidence {key} is unavailable or malformed"
    for kind in ("local", "offsite"):
        if not isinstance(_object(operational["backup"].get(kind)).get("state"), str):
            return f"{kind} recovery evidence is unavailable or malformed"
    for key in ("activation", "boot_persistence", "execution"):
        if not isinstance(operational["automation"].get(key), str):
            return f"automation evidence {key} is unavailable or malformed"
    if not isinstance(operational["update_guard"].get("state"), str):
        return "update recovery evidence is unavailable or malformed"
    mail = operational["notification"]
    if any(not isinstance(mail.get(key), str) for key in ("operational_route", "application_smtp")) or not isinstance(
        _object(mail.get("delivery_history")).get("state"), str
    ):
        return "notification evidence is unavailable or malformed"
    services = _object(payload.get("runtime")).get("services")
    if not isinstance(services, list) or any(
        not isinstance(row, dict) or any(not isinstance(row.get(key), str) for key in ("service", "state", "health"))
        for row in services
    ):
        return "runtime service evidence is unavailable or malformed"
    checks = _object(payload.get("doctor")).get("checks")
    if not isinstance(checks, list) or any(
        not isinstance(row, dict) or not isinstance(row.get("status"), str)
        or row["status"] not in {"PASS", "WARN", "FAIL", "SKIP"}
        for row in checks
    ):
        return "diagnostic evidence is unavailable or malformed"
    return None


def _status() -> dict[str, object]:
    try:
        result = _run(["status", "--json"], capture=True)
        if result.returncode not in {0, 1}:
            return {"presentation_error": f"status exited with code {result.returncode}"}
        payload = json.loads(result.stdout)
    except (OSError, UnicodeError, TypeError, ValueError, subprocess.TimeoutExpired):
        return {"presentation_error": "status data could not be read; verification is incomplete"}
    problem = _status_problem(payload)
    return {"presentation_error": problem} if problem else payload


def _state(text: object) -> str:
    value = str(text)
    lowered = value.lower()
    if lowered in {"pass", "ok", "running", "healthy", "success", "protected", "active"}:
        return STYLE.success(value)
    if lowered in {"fail", "failure", "failed", "degraded", "unhealthy", "unknown"}:
        return STYLE.failure(value)
    return STYLE.warning(value)


def _fmt_age(seconds: object) -> str:
    if type(seconds) is not int or seconds < 0:
        return "unknown"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h"
    return f"{seconds // 86400}d {seconds % 86400 // 3600}h"


def _service(payload: dict[str, object], name: str) -> str:
    runtime = payload.get("runtime", {})
    rows = runtime.get("services", []) if isinstance(runtime, dict) else []
    for row in rows if isinstance(rows, list) else []:
        if isinstance(row, dict) and row.get("service") == name:
            return f"{_state(row.get('state'))} / {_state(row.get('health'))}"
    return _state("unknown")


def _recovery_line(payload: dict[str, object], kind: str) -> str:
    operational = payload.get("operational")
    backup = operational.get("backup") if isinstance(operational, dict) else None
    row = backup.get(kind) if isinstance(backup, dict) else None
    if not isinstance(row, dict):
        return STYLE.warning("current evidence unavailable")
    state = str(row.get("state", "unknown"))
    if state == "local_only":
        return STYLE.warning("LOCAL-ONLY (offsite disabled)")
    history = row.get("historical_receipt") if kind == "offsite" else row
    age = history.get("age_seconds") if isinstance(history, dict) else None
    color = STYLE.success if state == "current" else STYLE.failure if state == "failed" else STYLE.warning
    detail = ""
    if kind == "offsite":
        destination = backup.get("destination_state", "not_established")
        if destination != "configured_locally":
            color = STYLE.warning
        detail = f"; destination {str(destination).replace('_', ' ')}; connectivity unverified"
    return color(f"{state.replace('_', ' ')} receipt age={_fmt_age(age)}{detail}")


def _doctor_check(payload: dict[str, object], check_id: str) -> str:
    doctor = payload.get("doctor", {})
    checks = doctor.get("checks", []) if isinstance(doctor, dict) else []
    for check in checks if isinstance(checks, list) else []:
        if isinstance(check, dict) and check.get("id") == check_id:
            return _state(check.get("status", "unknown"))
    return STYLE.failure("unknown")


def _admin_state(payload: dict[str, object]) -> str:
    admin = payload.get("admin", {})
    if not isinstance(admin, dict):
        return STYLE.failure("unknown")
    status = str(admin.get("status", "FAIL"))
    message = str(admin.get("message", ""))
    if status == "PASS" and "disabled" in message.lower():
        return STYLE.success("disabled (closed)")
    if status == "PASS":
        return STYLE.success("protected")
    return _state(status)


def draw_header(payload: dict[str, object]) -> None:
    update = payload.get("update", {})
    version = update.get("installed", "unknown") if isinstance(update, dict) else "unknown"
    print(STYLE.header(f" VaultWarden-OCI {version} — Operations Dashboard "))
    print(STYLE.info(DIVIDER))


def _action_for(check_id: str) -> str:
    if check_id.startswith(("config.", "secrets.")):
        return "Configuration: validate configuration and encrypted secrets."
    if check_id.startswith(("edge.", "crowdsec.")):
        return "Security and connectivity: inspect protection and the current Worker invocation."
    if check_id.startswith("recovery."):
        return "Backup and disaster recovery: inspect policy and verify a recovery point."
    if check_id.startswith("notification."):
        return "Automation and alerts: inspect the configured delivery route."
    return "Diagnose a problem: run Doctor and inspect the relevant journal."


def _exceptions(payload: dict[str, object], problem: str | None) -> None:
    operational = _object(payload.get("operational"))
    outcome = operational.get("state")
    if problem:
        print(STYLE.warning(f" WARN: {problem}"))
        print(STYLE.action(" ACTION: Diagnose a problem -> Doctor; use sudo vwctl status --json for details."))
    elif outcome == "RECOVERY REQUIRED":
        print(STYLE.failure(" FAIL: update recovery is required; ordinary start and update apply remain blocked."))
        print(STYLE.action(" ACTION: Advanced operations -> Recorded update recovery instructions."))
    elif outcome == "SETUP INCOMPLETE":
        print(STYLE.action(" ACTION: Setup and readiness -> Local readiness; complete the reported prerequisites."))
    elif outcome == "CRITICAL":
        print(STYLE.action(" ACTION: Diagnose a problem -> Doctor; resolve the reported failure before normal operation."))
    elif outcome == "MAINTENANCE / STOPPED":
        print(STYLE.warning(" WARN: services are stopped; confirm administrator intent before starting."))
    checks = _object(payload.get("doctor")).get("checks", [])
    failed = [row for row in checks if isinstance(row, dict) and row.get("status") == "FAIL"] if isinstance(checks, list) else []
    for row in failed[:4]:
        check_id = str(row.get("id", "unknown"))
        print(STYLE.failure(f" FAIL: {check_id} FAIL — {row.get('message', 'details unavailable')}"))
        print(STYLE.action(" ACTION: " + _action_for(check_id)))
    if len(failed) > 4:
        print(STYLE.warning(f" WARN: {len(failed) - 4} more failed checks; open Doctor for the complete report."))
    if not problem and outcome == "ATTENTION":
        # Reasons and state come from the accepted read model. These links only
        # help the human find the owner; they never change the classification.
        reason = str(operational.get("reason", ""))
        links = []
        for word, label in (("automation", "Automation and alerts"), ("execution", "Automation and alerts"),
                            ("backup", "Backup and disaster recovery"), ("offsite", "Backup and disaster recovery"),
                            ("update", "Updates and maintenance"), ("notifications", "Automation and alerts"),
                            ("CrowdSec", "Security and connectivity"), ("maintenance", "Updates and maintenance")):
            if word in reason and label not in links:
                links.append(label)
        print(STYLE.action(" ACTION: Review " + "; ".join(links or ["Setup and readiness", "Diagnose a problem"]) + "."))


def draw_status(payload: dict[str, object]) -> None:
    """Present the accepted read model; no health or mutation policy lives here."""
    payload = _object(payload)
    operational = _object(payload.get("operational"))
    problem = _status_problem(payload)
    outcome = "INCOMPLETE VERIFICATION" if problem else str(operational["state"])
    color = STYLE.success if outcome == "OPERATIONAL" else STYLE.failure if outcome in {"CRITICAL", "RECOVERY REQUIRED"} else STYLE.warning
    print(f" {STYLE.bold('Outcome:')} {color(outcome)}")
    if not problem:
        print(f" {operational['reason']}")
    _exceptions(payload, problem)
    print()
    print(f" {STYLE.bold('Availability:')} Vaultwarden {_service(payload, 'vaultwarden')} | Caddy {_service(payload, 'caddy')}")
    edge = _object(payload.get("edge"))
    crowdsec = _object(payload.get("crowdsec"))
    print(f" {STYLE.bold('Security:')} edge {_state(edge.get('overall', 'unknown'))} | CrowdSec {_state(crowdsec.get('overall', 'unknown'))} | admin {_admin_state(payload)}")
    print(f" {STYLE.bold('Recovery:')} local {_recovery_line(payload, 'local')} | offsite {_recovery_line(payload, 'offsite')}")
    auto = _object(operational.get("automation"))
    summary = _object(payload.get("automation"))
    print(f" {STYLE.bold('Automation:')} {_state(summary.get('overall', 'unknown'))}"
          f" | boot {str(auto.get('boot_persistence', 'unknown')).replace('_', ' ')}"
          f" | execution {str(auto.get('execution', 'unknown')).replace('_', ' ')}")
    mail = _object(operational.get("notification"))
    history = _object(mail.get("delivery_history"))
    history_state = str(history.get("state", "unknown"))
    if history_state == "success" and mail.get("history_provider_match") != "matches_configured_provider":
        history_state = "historical success (current provider not established)"
    print(f" {STYLE.bold('Alerts:')} {str(mail.get('operational_route', 'unknown')).replace('_', ' ')}"
          f" | delivery {history_state} | SMTP {str(mail.get('application_smtp', 'unknown')).replace('_', ' ')}")
    update = _object(payload.get("update"))
    if update.get("error"):
        update_text = STYLE.failure(f"check error: {update['error']}")
    elif update.get("check_stale") is not False or str(update.get("check_state")) in {"stale", "unknown", "failed"}:
        update_text = STYLE.warning("update check stale/missing/invalid")
    elif update.get("available") is True:
        update_text = STYLE.warning(f"update available -> {update.get('candidate', 'unknown')}")
    elif update.get("available") is False and update.get("availability_reason"):
        update_text = STYLE.info(str(update["availability_reason"]))
    elif update.get("check_state") == "current" and update.get("available") is False:
        update_text = STYLE.info("no update recorded at the last check")
    else:
        update_text = STYLE.warning("update evidence unknown")
    print(f" {STYLE.bold('Update:')} {update_text} (check age {_fmt_age(update.get('check_age_seconds'))})")
    storage = _object(payload.get("storage"))
    storage_text = _state(storage.get("state", "unknown"))
    used = storage.get("used_percent")
    if type(used) in (int, float):
        storage_text += f"; {used}% used"
    reboot = payload.get("reboot_required")
    reboot_text = "required" if reboot is True else "not required" if reboot is False else "unknown"
    print(f" {STYLE.bold('Host:')} storage {storage_text} | reboot {reboot_text}")
    print(STYLE.info(" INFO: observed local evidence; public ingress and off-host custody need separate verification."))
    print(STYLE.info(DIVIDER))


def _command_screen(label: str, args: Sequence[str]) -> None:
    _ensure_selected()
    print(STYLE.header(f" {label} "))
    print(STYLE.info(DIVIDER))
    print(STYLE.info(" INFO: the operation below owns its consent, progress and verification."))
    try:
        result = _run(args)
    except KeyboardInterrupt:
        print(STYLE.warning("\n WARN: operation interrupted; its final state is not verified."))
        print(STYLE.action(" ACTION: inspect sudo vwctl status and sudo vwctl doctor before retrying."))
        raise
    except (OSError, UnicodeError) as exc:
        print(STYLE.failure(f"FAIL: command could not be executed: {exc}"))
    else:
        print(STYLE.info(DIVIDER))
        if result.returncode == 0:
            print(STYLE.info("INFO: command returned (exit 0). Use its result above; a cancelled operation has not been applied."))
        elif result.returncode == 2:
            print(STYLE.warning("WARN: command returned exit 2; it may be cancelled, blocked or have invalid input. Read the result above."))
        elif result.returncode in {130, -2}:
            print(STYLE.warning("WARN: command interrupted; completion is not verified. Inspect status and Doctor before retrying."))
        else:
            print(STYLE.failure(f"FAIL: command returned exit {result.returncode}; follow its result above before retrying."))
    _press_enter()
    _ensure_selected()


JOURNALS = {
    "1": ("Health and DNS", ("vaultwarden-oci-health.service", "vaultwarden-oci-dns.service")),
    "2": ("Application lifecycle", ("vaultwarden-oci.service",)),
    "3": ("Backup jobs", ("vaultwarden-oci-backup.service",)),
    "4": ("Security and Worker boot", ("crowdsec.service", "crowdsec-firewall-bouncer.service",
                                      "crowdsec-cloudflare-worker-bouncer.service", "vaultwarden-oci-crowdsec-boot.service")),
    "5": ("Updates and maintenance", ("vaultwarden-oci-update-check.service", "vaultwarden-oci-maintenance.service")),
    "6": ("Operational alerts", ("vaultwarden-oci-notify@*",)),
}


def _journal_screen(group: str = "all") -> None:
    _ensure_selected()
    units = [unit for _, names in JOURNALS.values() for unit in names] if group == "all" else list(JOURNALS[group][1])
    _clear()
    print(STYLE.header(" VaultWarden-OCI systemd journal "))
    argv = ["/usr/bin/journalctl", "--no-pager", "--lines=200"]
    for unit in units:
        argv.extend(("-u", unit))
    try:
        result = subprocess.run(argv, check=False)
        if result.returncode != 0:
            print(STYLE.failure(f"FAIL: journalctl exited with status {result.returncode}"))
    except OSError as exc:
        print(STYLE.failure(f"FAIL: journal unavailable: {exc}"))
    _press_enter()
    _ensure_selected()


def journal_menu() -> None:
    _menu("Choose a journal", [(key, value[0]) for key, value in JOURNALS.items()] + [("all", "All supported services")], _journal_screen)


def _prompt(text: str) -> str:
    return input(text).strip()


def _cancelled() -> None:
    print(STYLE.info("CANCELLED: no command was started."))


def _confirm(text: str) -> bool:
    approved = _prompt(text + " [y/N]: ").lower() in {"y", "yes"}
    if not approved:
        _cancelled()
    return approved


def _menu(title: str, options: Sequence[tuple[str, str]], handler: Callable[[str], None]) -> None:
    _clear()
    while True:
        _ensure_selected()
        print(STYLE.header(f" {title} "))
        print()
        for key, label in options:
            print(f"  [ {STYLE.action(key)} ] {label}")
        print(f"\n  [ {STYLE.action('b')} ] Back   [ {STYLE.failure('e/q')} ] Exit")
        choice = _prompt("\n Select: ").lower()
        _ensure_selected()
        if choice == "b":
            return
        if choice in {"q", "e"}:
            raise SystemExit(0)
        if choice not in {key for key, _ in options}:
            print(STYLE.warning("WARN: invalid selection; choose a displayed option, b to go back, or q to exit."))
            continue
        handler(choice)


def stack_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1" and _confirm("Start the application after its storage and security checks?"):
            _command_screen("Start application", ["start"])
        elif choice == "2" and _confirm("Stop Vaultwarden and Caddy? Users will lose access"):
            _command_screen("Stop application", ["stop"])
        elif choice == "3" and _confirm("Restart Vaultwarden and Caddy? This briefly interrupts access"):
            _command_screen("Restart application", ["restart"])
        elif choice == "4": _command_screen("Application status", ["status"])
    _menu("Application lifecycle", (("1", "Start"), ("2", "Stop"), ("3", "Restart"), ("4", "Status")), handle)


def setup_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1": _command_screen("Local readiness and evidence limits", ["readiness"])
        elif choice == "2": _command_screen("Foundation diagnostics", ["doctor"])
        elif choice == "3": stack_menu()
        elif choice == "4":
            guide(["setup"], nested=True)
            _press_enter()
    _menu("Setup and readiness", (("1", "Local readiness"), ("2", "Check foundations (Doctor)"),
                                  ("3", "Application start, stop, restart and status"), ("4", "Continue first-run setup")), handle)


def diagnostics_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1": _command_screen("Doctor", ["doctor"])
        elif choice == "2": _command_screen("Vaultwarden logs", ["logs", "vaultwarden", "--tail", "200"])
        elif choice == "3": _command_screen("Caddy logs", ["logs", "caddy", "--tail", "200"])
        elif choice == "4": journal_menu()
        elif choice == "5":
            print("INFO: writes a protected, sanitized local support archive; review it before sharing.")
            _command_screen("Sanitized support bundle", ["support-bundle"])
        elif choice == "6": _command_screen("Exact installed versions", ["versions"])
    _menu("Diagnose a problem", (("1", "Doctor"), ("2", "Vaultwarden logs"), ("3", "Caddy logs"),
                                ("4", "Choose system journal"), ("5", "Create sanitized support bundle"), ("6", "Exact versions")), handle)


def recovery_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1": _command_screen("Current backup protection", ["recovery", "protection"])
        elif choice == "2": _command_screen("Existing systemd backup schedule", ["timers"])
        elif choice == "3": _guided_operation("backup")
        elif choice == "4": _command_screen("Backup now using saved policy", ["recovery", "backup"])
        elif choice == "5": _command_screen("Recovery inventory", ["recovery", "list"])
        elif choice == "6": _guided_operation("verify")
        elif choice == "7": _guided_operation("restore")
        elif choice == "8": recovery_kit_menu()
        elif choice == "9": _guided_operation("retention")
        elif choice in {"10", "11"}:
            remote = _prompt(" rclone REMOTE:folder (blank cancels): ")
            if not remote:
                _cancelled()
            elif choice == "11": _command_screen("Remote recovery inventory", ["recovery", "list", "--remote", remote])
            elif _confirm("Create and publish one backup to this alternate remote without changing the saved destination?"):
                _command_screen("One-time alternate backup", ["backup", "--remote", remote])
    _menu("Backup and disaster recovery", (("1", "Current protection and verification history"), ("2", "Existing backup schedule"),
          ("3", "Configure local-only or offsite backups"), ("4", "Backup now using saved policy"),
          ("5", "Recovery inventory"), ("6", "Verify a local/remote backup without restoring"),
          ("7", "Guided local/remote restore"), ("8", "Export separate credential recovery kit"),
          ("9", "Review retention and storage estimates"), ("10", "Backup once to an alternate remote"),
          ("11", "Inventory another remote folder")), handle)


def security_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1": _command_screen("Protection diagnostics (full Doctor)", ["doctor"])
        elif choice == "2": _command_screen("CrowdSec status", ["crowdsec", "status"])
        elif choice == "3": _command_screen("CrowdSec decisions", ["crowdsec", "decisions"])
        elif choice == "4":
            address = _prompt(" IP address to unban (blank cancels): ")
            if address and _confirm("Remove current CrowdSec decisions for this address?"):
                _command_screen("Unban IP", ["crowdsec", "unban", address])
            elif not address: _cancelled()
        elif choice == "5": _command_screen("Cloudflare DNS status (provider read)", ["dns", "status"])
        elif choice == "6": _command_screen("Cloudflare DNS dry run (provider read)", ["dns", "update", "--dry-run"])
        elif choice == "7" and _confirm("Synchronize the existing proxied Cloudflare A record to this host?"):
            _command_screen("Synchronize Cloudflare DNS", ["dns", "update"])
        elif choice == "8" and _confirm("Refresh validated Cloudflare ranges and apply the origin firewall policy?"):
            _command_screen("Refresh Cloudflare origin policy", ["edge", "refresh"])
        elif choice == "9" and _confirm("Start one Cloudflare Worker invocation? Its recreated Route needs Fail Open verification"):
            _command_screen("Start/re-arm Cloudflare remediation", ["crowdsec", "remediation-start"])
        elif choice == "10":
            print("INFO: first set every bouncer-created Worker Route to Fail Open in Cloudflare for the current invocation.")
            if _confirm("Have you verified all current bouncer-created Worker Routes are Fail Open?"):
                _command_screen("Record manual Worker Fail Open confirmation", ["crowdsec", "confirm-fail-open"])
        elif choice == "11" and _confirm("Stop the Cloudflare Worker and verify removal of its managed Route?"):
            _command_screen("Stop and verify Worker cleanup", ["crowdsec", "remediation-stop"])
        elif choice == "12":
            print("WARN: experimental provider API uses an undocumented field; missing readback remains a failure.")
            if _confirm("Set and independently read back Fail Open for the exact current managed Route?"):
                _command_screen("Verify current Worker Route Fail Open", ["crowdsec", "ensure-fail-open"])
    _menu("Security and connectivity", (("1", "Protection diagnostics"), ("2", "CrowdSec status"), ("3", "CrowdSec decisions"),
          ("4", "Unban IP"), ("5", "Cloudflare DNS status"), ("6", "Preview Cloudflare DNS update"),
          ("7", "Synchronize Cloudflare DNS"), ("8", "Refresh origin firewall policy"), ("9", "Start/re-arm Worker"),
          ("10", "Record manual Fail Open confirmation"), ("11", "Stop Worker with verified cleanup"),
          ("12", "Set and verify Fail Open through experimental API")), handle)


def config_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1": _command_screen("Validated config edit", ["config", "edit"])
        elif choice == "2": _command_screen("Validate config", ["config", "validate", "--file", "/etc/vaultwarden-oci/config.toml"])
        elif choice == "3": _command_screen("SOPS secrets edit", ["secrets", "edit"])
        elif choice == "4": _command_screen("Validate SOPS secrets", ["secrets", "validate"])
    _menu("Configuration", (("1", "Edit config (validate before commit)"), ("2", "Validate config"),
                            ("3", "Edit encrypted SOPS secrets"), ("4", "Validate encrypted secrets")), handle)


def recovery_kit_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1": _guided_operation("recovery-kit")
        elif choice == "2": _guided_operation("recovery-kit", local_only=True)
    _menu("Separate credential recovery kit", (("1", "Export; offer verified SMTP email"), ("2", "Export locally only")), handle)


def notification_menu() -> None:
    def handle(choice: str) -> None:
        if _confirm("Send a real test email using this route? Confirm receipt separately in the mailbox"):
            _command_screen("Operational notification route test" if choice == "1" else "Direct authenticated SMTP test",
                            ["notification", "test"] + (["--smtp"] if choice == "2" else []))
    _menu("Test alert and SMTP delivery", (("1", "Test configured operational route"), ("2", "Test direct SMTP path")), handle)


def update_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1":
            print("INFO: a manual check does not replace the scheduled-check history shown on the home screen.")
            _command_screen("Check recommended project update", ["update", "check"])
        elif choice == "2": _command_screen("Apply recommended project update; owner requests consent", ["update", "apply"])
        elif choice == "3" and _confirm("Refresh Ubuntu apt indexes and inspect proposed host package changes?"):
            _command_screen("Check Ubuntu host packages", ["host-upgrade", "check"])
        elif choice == "4":
            print("WARN: host packages are outside application rollback; the operation never auto-reboots.")
            _command_screen("Apply Ubuntu host packages; owner requests consent", ["host-upgrade", "apply"])
    _menu("Updates and maintenance", (("1", "Check recommended project update"), ("2", "Apply recommended project update"),
                                      ("3", "Check host packages (refreshes apt indexes)"), ("4", "Apply host packages (never auto-reboot)")), handle)


def automation_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1": _command_screen("Automation activation and execution", ["timers"])
        elif choice == "2": notification_menu()
        elif choice == "3":
            print("INFO: systemd owns schedules and boot persistence. Review readiness, backup policy and Worker Fail Open first.")
            print("ACTION: follow docs/OPERATIONS.md for explicit appliance-target and optional Worker boot-service activation.")
            print("INFO: no schedules or boot services have been enabled by this screen.")
            _press_enter()
    _menu("Automation and alerts", (("1", "Inspect scheduled work"), ("2", "Test notification or SMTP delivery"),
                                   ("3", "Scheduling and boot guidance")), handle)


def advanced_menu() -> None:
    def handle(choice: str) -> None:
        if choice in {"1", "2"}:
            print("WARN: use-latest explicitly resolves new upstream pins; use only for a separately approved maintenance task.")
            if _confirm("Use the explicit upstream-version override?"):
                _command_screen("Explicit use-latest snapshot", ["update", "check" if choice == "1" else "apply", "--use-latest"])
        elif choice == "3" and _confirm("Install/configure the supported CrowdSec security path? Host packages and policy may change"):
            _command_screen("CrowdSec setup", ["crowdsec", "setup"])
        elif choice == "4":
            print("WARN: experimental provider API uses an undocumented Fail Open field; independent readback is required.")
            if _confirm("Start one Worker invocation and opt in to its exact Route Fail Open API verification?"):
                _command_screen("Start Worker with API Fail Open", ["crowdsec", "remediation-start", "--auto-fail-open"])
        elif choice == "5":
            print("ACTION: use the exact previous/candidate versions and recovery artifact printed by the failed update.")
            print("WARN: rollback restores recorded application state. Retain the guard and follow docs/RECOVERY.md; do not guess bindings.")
            _command_screen("Recorded update recovery instructions", ["update", "rollback", "--help"])
        elif choice == "6":
            remote = _prompt(" Exact remote folder to inspect (blank cancels): ")
            keep = _prompt(" Recovery points to keep, at least 1 (blank cancels): ") if remote else ""
            if not remote or not keep: _cancelled()
            elif not keep.isascii() or not keep.isdecimal() or int(keep) < 1:
                print("WARN: retention must be a whole number of at least 1; no command was started.")
            else:
                print("INFO: preview only. Deletion remains a separate explicit CLI operation; review the remote and plan first.")
                _command_screen("Remote pruning preview", ["recovery", "prune", "--remote", remote, "--keep-last", keep])
        elif choice == "7": _command_screen("Low-level immutable install help", ["install", "--help"])
    _menu("Advanced operations", (("1", "Check explicit use-latest"), ("2", "Apply explicit use-latest"),
          ("3", "Set up CrowdSec"), ("4", "Start Worker with experimental API Fail Open"),
          ("5", "Recorded update recovery instructions"), ("6", "Preview remote pruning"), ("7", "Low-level install help")), handle)


def _guided_operation(workflow: str, *, local_only: bool = False) -> None:
    # Links to authoritative command owners, not another workflow implementation.
    if workflow == "restore":
        label, args = "Guided application restore", ["restore"]
        purpose = "Recover application data from one verified encrypted .vwrec recovery point."
        prerequisites = "Have your offline recovery identity or encrypted recovery kit and the selected recovery point."
        impact = "The existing guide verifies before RESTORE consent, replaces live state, and leaves the application stopped by default."
        verification = "Read the owner's verification result; after an applied restore, run readiness and explicitly start when ready."
    elif workflow == "offsite":
        label, args = "Configure offsite recovery publication", ["recovery", "offsite", "configure"]
        purpose = "Save a destination for subsequent manual and scheduled backups."
        prerequisites = "Configure the intended rclone remote as root and choose the destination folder."
        impact = "The existing guide probes/prepares the remote and saves policy only after its ENABLE confirmation."
        verification = "Inspect offsite status, then explicitly create and verify a backup; a saved destination alone is not off-host custody."
    elif workflow == "backup":
        label, args = "Configure backup protection", ["recovery", "configure"]
        purpose = "Choose local-only or offsite protection for the existing backup command and timer."
        prerequisites = "Have a healthy installed appliance; offsite uses root's supported rclone configuration."
        impact = "Choose an exact destination with ENABLE consent, or explicitly disable offsite; a first backup needs separate consent."
        verification = "Read back the saved policy and actual backup/readback results; secure the offline key separately."
    elif workflow == "verify":
        label, args = "Verify an encrypted recovery point", ["recovery", "verify"]
        purpose = "Select a local or remote backup and prove offline-key decryption without replacing live state."
        prerequisites = "Have the matching offline identity or encrypted credential kit and its separate passphrase."
        impact = "The existing picker downloads if needed, verifies cryptography and SOPS, records history, and cleans transient identity material."
        verification = "Read the selected object's cryptographic result; this does not demonstrate a populated-host restore."
    elif workflow == "retention":
        label, args = "Review backup retention", ["recovery", "retention"]
        purpose = "Inspect actual storage observations and preview consequences before changing retention days."
        prerequisites = "Review the exact saved destination; zero keeps recovery points indefinitely."
        impact = "No archive is deleted by this guide. Saving positive days authorizes the existing pipeline to prune after a future successful backup."
        verification = "Review the exact preview, explicit SAVE decision and policy readback; remote discovery does not broaden pruning scope."
    else:
        label, args = "Export separate encrypted credential kit", ["recovery-kit", "export"]
        if local_only: args.append("--no-email")
        purpose = "Export credentials and the offline identity in a separate AES-256 ZIP; this is not an application backup."
        prerequisites = "Have the correct offline identity and choose an independent passphrase; never put it in command arguments."
        impact = "The existing guide writes a protected kit, verifies it, and offers SMTP email only with separate consent." if not local_only else "The existing guide writes and verifies a protected local kit; no email is requested."
        verification = "Secure the kit off-host, confirm receipt/decryption independently, and retain the passphrase separately."
    print(STYLE.header(f" {label} "))
    print(f" Purpose: {purpose}\n Prerequisites: {prerequisites}\n Impact and consent: {impact}")
    print(f" Verification and next action: {verification}")
    if _confirm("Continue into the existing guided operation?"):
        _command_screen(label, args)


def _release_changed(exc: ReleaseChanged) -> int:
    print(STYLE.warning(f"\nWARN: {exc}; this console has stopped before further commands."))
    print(STYLE.action("ACTION: inspect the operation result, then reopen sudo vwctl menu from the selected release."))
    return 0


def guide(argv: Sequence[str] | None = None, *, nested: bool = False) -> int:
    args = list(argv or [])
    if args in (["--help"], ["-h"]):
        print("Usage: sudo vwctl guide [backup|verify|retention|restore|offsite|recovery-kit|setup]\nGuided access to existing operation owners.")
        return 0
    if len(args) > 1 or (args and args[0] not in {"restore", "offsite", "recovery-kit", "setup", "backup", "verify", "retention"}):
        print("FAIL: choose backup, verify, retention, restore, offsite, recovery-kit or setup", file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        print("FAIL: guide must run as root; use sudo vwctl guide", file=sys.stderr)
        return 1
    if args and (not sys.stdin.isatty() or not sys.stdout.isatty()):
        print("FAIL: guided operations require an interactive terminal; use the existing explicit CLI forms for automation.", file=sys.stderr)
        return 1
    try:
        _ensure_selected()
        if args == ["setup"]:
            from . import setup_guide

            if not _installed_context():
                print("HOLD: continue setup through the installed sudo vwctl guide setup after setup.sh installation.")
                return 2
            return setup_guide.main(run=_run, ensure_selected=_ensure_selected)
        if args:
            _guided_operation(args[0])
        else:
            _menu("Available guided operations", (("backup", "Configure backup protection"),
                  ("verify", "Verify backup without restoring"), ("retention", "Review retention and storage"), ("restore", "Restore application data"),
                  ("offsite", "Configure offsite publishing"), ("recovery-kit", "Export credential kit"), ("setup", "Continue first-run setup")),
                  lambda choice: guide([choice], nested=True))
        return 0
    except ReleaseChanged as exc:
        if nested:
            raise
        return _release_changed(exc)
    except (KeyboardInterrupt, EOFError):
        if nested:
            raise
        print("\nCANCELLED: guided interface closed; no further commands will run.")
        return 0


def draw_main_menu() -> None:
    print(STYLE.bold(" Administrator objectives"))
    for key, label in (("1/s", "Setup and readiness"), ("2/b", "Backup and disaster recovery"),
                       ("3/x", "Security and connectivity"), ("4/a", "Automation and alerts"),
                       ("5/u", "Updates and maintenance"), ("6/c", "Configuration"),
                       ("7/d", "Diagnose a problem"), ("8", "Advanced operations")):
        print(f"  [ {STYLE.action(key)} ] {label}")
    print(f"\n  [ {STYLE.action('g')} ] Guided operations   [ {STYLE.failure('e/q')} ] Exit")
    print(STYLE.info(" Shortcuts: k credential kit; n email tests. Submenus: b back. Ctrl-C/EOF closes the console."))


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args in (["--help"], ["-h"]):
        print("VaultWarden-OCI Operations Dashboard\n\nUsage: sudo vwctl menu\nLegacy: dashboard.sh\n\nAdministrator console; mutations are delegated to vwctl. Try sudo vwctl guide.")
        return 0
    if args:
        print("dashboard.sh: no positional arguments are supported", file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        print("FAIL: dashboard must run as root; use sudo vwctl menu", file=sys.stderr)
        return 1
    handlers = {
        "1": setup_menu, "s": setup_menu, "2": recovery_menu, "b": recovery_menu,
        "3": security_menu, "x": security_menu, "4": automation_menu, "a": automation_menu,
        "5": update_menu, "u": update_menu, "6": config_menu, "c": config_menu,
        "7": diagnostics_menu, "d": diagnostics_menu, "8": advanced_menu,
        "g": lambda: guide([], nested=True), "k": recovery_kit_menu, "n": notification_menu,
    }
    notice = ""
    try:
        while True:
            _ensure_selected()
            payload = _status()
            _clear()
            draw_header(payload)
            draw_status(payload)
            draw_main_menu()
            if notice: print(STYLE.warning(notice))
            choice = _prompt("\n Select: ").lower()
            _ensure_selected()
            if choice in {"q", "e"}:
                print("INFO: console closed.")
                return 0
            handler = handlers.get(choice)
            notice = "" if handler else "WARN: invalid selection; choose a displayed objective, g, or q."
            if handler: handler()
    except ReleaseChanged as exc:
        return _release_changed(exc)
    except (KeyboardInterrupt, EOFError):
        print("\nCANCELLED: console closed; no further commands will run.")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
