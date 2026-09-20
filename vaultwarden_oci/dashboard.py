"""Interactive operations dashboard for the authoritative ``vwctl`` surface."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Callable, Sequence

RELEASE_ROOT = Path(__file__).resolve().parents[1]
VWCTL = RELEASE_ROOT / "vwctl"
DIVIDER = "------------------------------------------------------------"


class Style:
    def __init__(self, *, stream=None) -> None:
        stream = stream or sys.stdout
        self.enabled = bool(getattr(stream, "isatty", lambda: False)()) and not os.environ.get("NO_COLOR")

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
    if sys.stdout.isatty() and os.environ.get("TERM") not in {None, "", "dumb"}:
        print("\033[2J\033[H", end="")


def _press_enter() -> None:
    input("\n" + STYLE.header(" Press [Enter] to return to the menu "))


def _run(argv: Sequence[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(VWCTL), *argv],
        text=True,
        capture_output=capture,
        check=False,
    )


def _status() -> dict[str, object]:
    result = _run(["status", "--json"], capture=True)
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {
            "schema_version": 1,
            "runtime": {"overall": "unknown", "services": []},
            "doctor": {"overall": "FAIL", "checks": []},
            "storage": {"state": "failure", "warning": True, "error": "status JSON unavailable"},
            "recovery": [],
            "edge": {"overall": "FAIL", "checks": []},
            "admin": {"id": "edge.admin.protection", "status": "FAIL", "message": "status unavailable"},
            "automation": {"overall": "FAIL", "healthy": 0, "expected": 4},
            "timers": [],
            "notification": {"state": "unknown"},
            "update": {"installed": "unknown", "available": False, "check_stale": True},
            "reboot_required": False,
        }
    return payload if isinstance(payload, dict) else {}


def _state(text: object) -> str:
    value = str(text)
    lowered = value.lower()
    if lowered in {"pass", "ok", "running", "healthy", "success", "protected", "active"}:
        return STYLE.success(value)
    if lowered in {"fail", "failure", "failed", "degraded", "unhealthy", "unknown"}:
        return STYLE.failure(value)
    return STYLE.warning(value)


def _fmt_age(seconds: object) -> str:
    if not isinstance(seconds, int):
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
    rows = payload.get("recovery", [])
    for row in rows if isinstance(rows, list) else []:
        if isinstance(row, dict) and row.get("kind") == kind:
            stale = " STALE" if row.get("stale") else ""
            color = STYLE.warning if stale else STYLE.success
            return color(f"{row.get('state', 'unknown')} age={_fmt_age(row.get('age_seconds'))}{stale}")
    return STYLE.warning("not recorded")


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


def draw_status(payload: dict[str, object]) -> None:
    doctor = payload.get("doctor", {})
    storage = payload.get("storage", {})
    update = payload.get("update", {})
    notification = payload.get("notification", {})
    edge = payload.get("edge", {})
    automation = payload.get("automation", {})
    print(f" {STYLE.bold('Stack:')} Vaultwarden {_service(payload, 'vaultwarden')} | Caddy {_service(payload, 'caddy')}")
    print(f" {STYLE.bold('Doctor:')} {_state(doctor.get('overall', 'unknown') if isinstance(doctor, dict) else 'unknown')}")
    if isinstance(storage, dict) and storage.get("state") != "failure":
        used = storage.get("used_percent", "?")
        suffix = STYLE.warning(" DISK WARNING") if storage.get("warning") else ""
        print(f" {STYLE.bold('Storage:')} {_state(storage.get('state'))} {storage.get('mount')} {used}% used{suffix}")
    else:
        print(f" {STYLE.bold('Storage:')} {STYLE.failure('MISSING/INVALID')} {storage.get('error', '') if isinstance(storage, dict) else ''}")
    print(f" {STYLE.bold('Recovery:')} local {_recovery_line(payload, 'local')} | offsite {_recovery_line(payload, 'offsite')}")
    print(f" {STYLE.bold('Rclone:')} {_doctor_check(payload, 'recovery.rclone')}")
    print(
        f" {STYLE.bold('Security:')} edge {_state(edge.get('overall', 'unknown') if isinstance(edge, dict) else 'unknown')} "
        f"| CrowdSec {_doctor_check(payload, 'crowdsec.engine')}/{_doctor_check(payload, 'crowdsec.cloudflare')} "
        f"| admin {_admin_state(payload)}"
    )
    if isinstance(automation, dict):
        healthy = automation.get("healthy", 0)
        expected = automation.get("expected", 4)
        if automation.get("overall") == "PASS":
            timer_text = STYLE.success(f"{healthy}/{expected} healthy")
        else:
            timer_text = STYLE.failure(f"{healthy}/{expected} healthy — ATTENTION")
    else:
        timer_text = STYLE.failure("unknown")
    print(f" {STYLE.bold('Automation:')} {timer_text}")
    print(f" {STYLE.bold('Notifications:')} {_state(notification.get('state', 'unknown') if isinstance(notification, dict) else 'unknown')}")
    if isinstance(update, dict):
        if update.get("error"):
            update_text = STYLE.failure(f"check error: {update.get('error')}")
        elif update.get("available"):
            update_text = STYLE.warning(f"update available -> {update.get('candidate')}")
        elif update.get("availability_reason"):
            update_text = STYLE.success(str(update.get("availability_reason")))
        elif update.get("check_stale"):
            update_text = STYLE.warning("update check stale/missing")
        else:
            update_text = STYLE.success("up to date")
        print(f" {STYLE.bold('Update:')} {update_text} (last check {_fmt_age(update.get('check_age_seconds'))} ago)")
    print(f" {STYLE.bold('Reboot:')} {STYLE.warning('required') if payload.get('reboot_required') else STYLE.success('not required')}")
    print(STYLE.info(DIVIDER))


def _command_screen(label: str, args: Sequence[str]) -> None:
    _clear()
    print(STYLE.header(f" {label} "))
    print(STYLE.info(DIVIDER))
    result = _run(args)
    print(STYLE.info(DIVIDER))
    if result.returncode == 0:
        print(STYLE.success("PASS: command completed successfully"))
    else:
        print(STYLE.failure(f"FAIL: command exited with status {result.returncode}"))
    _press_enter()


def _journal_screen() -> None:
    _clear()
    print(STYLE.header(" VaultWarden-OCI systemd journal "))
    print(STYLE.info(DIVIDER))
    subprocess.run(
        [
            "journalctl", "--no-pager", "--lines=200",
            "-u", "vaultwarden-oci.service",
            "-u", "vaultwarden-oci-health.service",
            "-u", "vaultwarden-oci-backup.service",
            "-u", "vaultwarden-oci-maintenance.service",
            "-u", "vaultwarden-oci-update-check.service",
        ],
        check=False,
    )
    _press_enter()


def _prompt(text: str) -> str:
    return input(text).strip()


def _confirm(text: str) -> bool:
    return _prompt(text + " [y/N]: ").lower() in {"y", "yes"}


def _menu(title: str, options: Sequence[tuple[str, str]], handler: Callable[[str], None]) -> None:
    while True:
        _clear()
        print(STYLE.header(f" {title} "))
        print()
        for key, label in options:
            print(f"  [ {STYLE.action(key)} ] {label}")
        print(f"\n  [ {STYLE.action('b')} ] Back   [ {STYLE.failure('e/q')} ] Exit")
        choice = _prompt("\n Select: ").lower()
        if choice == "b":
            return
        if choice in {"q", "e"}:
            raise SystemExit(0)
        handler(choice)


def stack_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1": _command_screen("Start stack", ["start"])
        elif choice == "2" and _confirm("Stop Vaultwarden and Caddy?"): _command_screen("Stop stack", ["stop"])
        elif choice == "3": _command_screen("Restart stack", ["restart"])
        elif choice == "4": _command_screen("Stack status", ["status"])
    _menu("Stack", (("1", "Start"), ("2", "Stop"), ("3", "Restart"), ("4", "Status")), handle)


def diagnostics_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1": _command_screen("Doctor", ["doctor"])
        elif choice == "2": _command_screen("Vaultwarden logs", ["logs", "vaultwarden", "--tail", "200"])
        elif choice == "3": _command_screen("Caddy logs", ["logs", "caddy", "--tail", "200"])
        elif choice == "4": _journal_screen()
        elif choice == "5": _command_screen("Sanitized support bundle", ["support-bundle"])
    _menu("Diagnostics", (("1", "Doctor"), ("2", "Vaultwarden logs"), ("3", "Caddy logs"), ("4", "systemd journal"), ("5", "Create sanitized support bundle")), handle)


def recovery_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1": _command_screen("Verified local backup", ["backup"])
        elif choice == "2":
            remote = _prompt(" rclone REMOTE:path: ")
            if remote: _command_screen("Verified offsite backup", ["backup", "--remote", remote])
        elif choice == "3":
            remote = _prompt(" Optional rclone REMOTE:path (blank for local only): ")
            args = ["recovery", "list"] + (["--remote", remote] if remote else [])
            _command_screen("Recovery inventory", args)
        elif choice == "4":
            location = _prompt(" Local .vwrec path: ")
            identity = _prompt(" Offline Age identity path: ")
            if location and identity: _command_screen("Verify local recovery", ["recovery", "verify", "--file", location, "--identity", identity])
        elif choice == "5":
            remote = _prompt(" Remote .vwrec REMOTE:path: ")
            identity = _prompt(" Offline Age identity path: ")
            if remote and identity: _command_screen("Verify remote recovery", ["recovery", "verify", "--from-remote", remote, "--identity", identity])
        elif choice == "6": _command_screen("Guided restore", ["restore"])
    _menu("Backup & Recovery", (("1", "Backup now"), ("2", "Backup + verified offsite publication"), ("3", "Recovery inventory"), ("4", "Verify local recovery"), ("5", "Verify remote recovery"), ("6", "Guided local/remote restore")), handle)


def security_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1": _command_screen("CrowdSec status", ["crowdsec", "status"])
        elif choice == "2": _command_screen("CrowdSec decisions", ["crowdsec", "decisions"])
        elif choice == "3":
            address = _prompt(" IP address to unban: ")
            if address: _command_screen("Unban IP", ["crowdsec", "unban", address])
        elif choice == "4": _command_screen("Edge/admin diagnostic status", ["doctor"])
        elif choice == "5": _command_screen("Refresh Cloudflare origin policy", ["edge", "refresh"])
    _menu("Security", (("1", "CrowdSec status"), ("2", "CrowdSec decisions"), ("3", "Unban IP"), ("4", "Edge + admin protection status"), ("5", "Refresh Cloudflare edge policy")), handle)


def config_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1": _command_screen("Validated config edit", ["config", "edit"])
        elif choice == "2": _command_screen("Validate config", ["config", "validate", "--file", "/etc/vaultwarden-oci/config.toml"])
        elif choice == "3": _command_screen("SOPS secrets edit", ["secrets", "edit"])
        elif choice == "4": _command_screen("Validate SOPS secrets", ["secrets", "validate"])
    _menu("Config & Secrets", (("1", "Edit config (validate before commit)"), ("2", "Validate config"), ("3", "Edit encrypted SOPS secrets"), ("4", "Validate encrypted secrets")), handle)


def recovery_kit_menu() -> None:
    def handle(choice: str) -> None:
        if choice in {"1", "2"}:
            identity = _prompt(" Matching offline Age identity path: ")
            if not identity: return
            args = ["recovery-kit", "export", "--offline-identity", identity]
            if choice == "2": args.append("--no-email")
            _command_screen("Verified encrypted recovery kit", args)
    _menu("Recovery Kit", (("1", "Export; offer verified SMTP email"), ("2", "Export locally only")), handle)


def notification_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1": _command_screen("Operational notification route test", ["notification", "test"])
        elif choice == "2": _command_screen("Direct authenticated SMTP test", ["notification", "test", "--smtp"])
    _menu("Email & Notifications", (("1", "Test configured operational route"), ("2", "Test direct SMTP path")), handle)


def update_menu() -> None:
    def handle(choice: str) -> None:
        if choice == "1": _command_screen("Check recommended project update", ["update", "check"])
        elif choice == "2": _command_screen("Apply recommended project update", ["update", "apply"])
        elif choice == "3": _command_screen("Check explicit use-latest snapshot", ["update", "check", "--use-latest"])
        elif choice == "4": _command_screen("Apply explicit use-latest snapshot", ["update", "apply", "--use-latest"])
        elif choice == "5": _command_screen("Check Ubuntu host packages", ["host-upgrade", "check"])
        elif choice == "6": _command_screen("Apply Ubuntu host packages", ["host-upgrade", "apply"])
    _menu("Updates & Host", (("1", "Check recommended project update"), ("2", "Apply recommended project update"), ("3", "Check explicit use-latest"), ("4", "Apply explicit use-latest"), ("5", "Check host packages"), ("6", "Apply host packages (never auto-reboot)")), handle)


def automation_menu() -> None:
    _command_screen("systemd automation timers", ["timers"])


def draw_main_menu() -> None:
    print(STYLE.bold(" Main Menu"))
    print()
    options = (
        ("1/s", "Stack"), ("2/d", "Diagnostics"), ("3/b", "Backup & Recovery"),
        ("4/x", "Security"), ("5/c", "Config & Secrets"), ("6/k", "Recovery Kit"),
        ("7/n", "Email & Notifications"), ("8/u", "Updates & Host"), ("9/a", "Automation"),
    )
    for key, label in options:
        print(f"  [ {STYLE.action(key)} ] {label}")
    print(f"\n  [ {STYLE.failure('e/q')} ] Exit")
    print(f"\n {STYLE.info('Tip:')} Number keys or s/d/b/x/c/k/n/u/a shortcuts; e/q exits; Ctrl-C exits safely.")


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args in (["--help"], ["-h"]):
        print("VaultWarden-OCI Operations Dashboard\n\nUsage: dashboard.sh\n\nThin day-2 interface; mutations are delegated to vwctl.")
        return 0
    if args:
        print("dashboard.sh: no positional arguments are supported", file=sys.stderr)
        return 2
    handlers = {
        "1": stack_menu, "s": stack_menu,
        "2": diagnostics_menu, "d": diagnostics_menu,
        "3": recovery_menu, "b": recovery_menu,
        "4": security_menu, "x": security_menu,
        "5": config_menu, "c": config_menu,
        "6": recovery_kit_menu, "k": recovery_kit_menu,
        "7": notification_menu, "n": notification_menu,
        "8": update_menu, "u": update_menu,
        "9": automation_menu, "a": automation_menu,
    }
    try:
        while True:
            payload = _status()
            _clear()
            draw_header(payload)
            draw_status(payload)
            draw_main_menu()
            choice = _prompt("\n Select: ").lower()
            if choice in {"q", "e"}:
                print(STYLE.success("Goodbye."))
                return 0
            handler = handlers.get(choice)
            if handler:
                handler()
    except (KeyboardInterrupt, EOFError):
        print("\n" + STYLE.success("Goodbye."))
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
