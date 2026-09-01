"""V1-inspired human presentation without changing machine/read-model owners."""
from __future__ import annotations

import socket
import sys
from datetime import datetime
from typing import Mapping

from . import cli, dashboard, day2, notification, runtime, secrets, storage


def _host() -> str:
    try:
        value = socket.getfqdn().strip()
    except OSError:
        value = ""
    if value and value != "localhost":
        return value
    try:
        return socket.gethostname().strip() or "unknown"
    except OSError:
        return "unknown"


def _sent_at() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _notification_body(
    *,
    service: str,
    event: str,
    transport: str,
    summary: str,
    checks: tuple[str, ...] = (),
) -> str:
    lines = [
        "VaultWarden-OCI operational notification",
        "",
        f"Service: {service}",
        f"Event: {event}",
        f"Transport: {transport}",
        f"Date/Time: {_sent_at()}",
        f"Host: {_host()}",
        "",
        summary,
    ]
    if checks:
        lines.extend(("", "Suggested checks:", *(f"  {item}" for item in checks)))
    return "\n".join(lines) + "\n"


def status() -> int:
    """Render the authoritative day-2 JSON model through the V1-style dashboard view."""
    payload = day2.status_payload()
    dashboard.draw_header(payload)
    dashboard.draw_status(payload)
    doctor = payload.get("doctor", {})
    automation = payload.get("automation", {})
    doctor_failed = isinstance(doctor, dict) and doctor.get("overall") == "FAIL"
    automation_failed = isinstance(automation, dict) and automation.get("overall") == "FAIL"
    return 1 if doctor_failed or automation_failed else 0


def _load_mail() -> tuple[object, Mapping[str, str]]:
    storage.verify()
    config = runtime.load_config()
    values = secrets.load(config.offline_recovery_recipient)
    return config, values


def notification_test(*, smtp_only: bool) -> int:
    """Run the existing notification transports with a V1-style diagnostic body."""
    try:
        config, values = _load_mail()
        recipient = config.notification_to_email or config.acme_email
        subject = "[VaultWarden-OCI] notification test"
        if smtp_only:
            text = _notification_body(
                service="VaultWarden-OCI notification",
                event="operator-test",
                transport="direct authenticated SMTP",
                summary="This diagnostic confirms the appliance direct SMTP path accepted a test message.",
            )
            context = notification.message_context(
                from_email=config.smtp_from_email,
                from_name=config.smtp_from_name,
                to_email=recipient,
                subject=subject + " (direct SMTP)",
                text=text,
            )
            result = notification.send_smtp(config=config, secrets=values, context=context)
            print(f"{'PASS' if result.ok else 'FAIL'}: direct SMTP category={result.category} reason={result.reason}")
            return 0 if result.ok else 1

        text = _notification_body(
            service="VaultWarden-OCI notification",
            event="operator-test",
            transport="configured operational route",
            summary="This diagnostic confirms the configured operational notification route accepted a test message.",
        )
        result = notification.deliver(
            event_id="operator-test",
            config=config,
            secrets=values,
            subject=subject,
            text=text,
        )
        print(f"{'PASS' if result.outcome == 'success' else 'FAIL'}: route={result.transport} category={result.category}")
        return 0 if result.outcome == "success" else 1
    except (
        storage.StorageError,
        runtime.RuntimeConfigError,
        secrets.SecretsError,
        notification.NotificationError,
        OSError,
    ) as exc:
        print(f"FAIL: notification test failed: {exc}", file=sys.stderr)
        return 1


def notify_failure(event: str) -> int:
    """Send the existing systemd failure notification with useful V1-era context."""
    if not cli._EVENT.fullmatch(event):
        print("FAIL: --event must be a bounded systemd event identifier", file=sys.stderr)
        return 2
    try:
        config, values = _load_mail()
        host = _host()
        result = notification.deliver(
            event_id=event,
            config=config,
            secrets=values,
            subject=f"FAILURE: {event} on {host}",
            text=_notification_body(
                service=event,
                event="systemd OnFailure",
                transport="configured operational route",
                summary=f"VaultWarden-OCI systemd unit {event} entered a failed state.",
                checks=(
                    f"systemctl status '{event}'",
                    f"journalctl -xeu '{event}'",
                ),
            ),
        )
    except (
        storage.StorageError,
        runtime.RuntimeConfigError,
        secrets.SecretsError,
        notification.NotificationError,
        OSError,
    ) as exc:
        print(f"FAIL: operational notification could not be delivered: {exc}", file=sys.stderr)
        return 1
    print(
        f"{'PASS' if result.outcome == 'success' else 'FAIL'}: operational notification "
        f"provider={result.provider} transport={result.transport} category={result.category}"
    )
    return 0 if result.outcome == "success" else 1
