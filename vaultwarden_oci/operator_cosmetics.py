"""Proven human presentation without changing machine/read-model owners."""
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


def _status_exit_code(payload: Mapping[str, object]) -> int:
    """Preserve the established human status health boundary."""
    runtime_state = payload.get("runtime")
    if not isinstance(runtime_state, dict):
        return 1
    overall = runtime_state.get("overall")
    if overall not in {"running", "stopped"}:
        return 1

    notification_state = payload.get("notification")
    if not isinstance(notification_state, dict):
        return 1
    if notification_state.get("state") == "failure":
        return 1

    edge_state = payload.get("edge")
    if not isinstance(edge_state, dict):
        return 1
    checks = edge_state.get("checks")
    if not isinstance(checks, list):
        return 1
    if any(isinstance(check, dict) and check.get("status") == "FAIL" for check in checks):
        return 1
    return 0


def status() -> int:
    """Render the authoritative day-2 model through the proven dashboard view."""
    payload = day2.status_payload()
    dashboard.draw_header(payload)
    dashboard.draw_status(payload)
    return _status_exit_code(payload)


def timers() -> int:
    """Render timer ownership clearly while preserving the authoritative day-2 snapshot."""
    snapshot = day2.automation_snapshot()
    target = snapshot["target"]
    rows = snapshot["timers"]
    assert isinstance(target, dict)
    assert isinstance(rows, list)

    target_problems = "; ".join(str(item) for item in target.get("problems", [])) or "healthy"
    print(
        f"[{target.get('health')}] {day2.AUTOMATION_TARGET}: "
        f"{target.get('active_state')} enabled={target.get('enabled')} ({target_problems})"
    )
    for row in rows:
        if not isinstance(row, dict):
            continue
        problems = "; ".join(str(item) for item in row.get("problems", [])) or "healthy"
        next_value = row.get("next")
        if not next_value and row.get("active_state") == "active" and row.get("sub_state") == "waiting":
            next_value = "monotonic/systemd-managed"
        print(
            f"[{row.get('health')}] {row.get('unit')}: "
            f"{row.get('active_state')}/{row.get('sub_state')} activation=target-managed "
            f"unit-file={row.get('enabled')} next={next_value or '-'} "
            f"last={row.get('last_trigger') or '-'} "
            f"trigger={row.get('trigger_active_state')}/{row.get('trigger_result')} ({problems})"
        )
    return 0 if snapshot["overall"] == "PASS" else 1


def _load_mail() -> tuple[object, Mapping[str, str]]:
    storage.verify()
    config = runtime.load_config()
    values = secrets.load(config.offline_recovery_recipient)
    return config, values


def _deliver_with_transport_context(
    *,
    config: object,
    values: Mapping[str, str],
    event_id: str,
    subject: str,
    service: str,
    event: str,
    summary: str,
    checks: tuple[str, ...] = (),
) -> notification.DeliveryResult:
    """Keep routing in notification.deliver while making the delivered body truthful."""
    provider_name = getattr(config, "notification_provider", None)
    if not provider_name:
        raise notification.NotificationError("operational notifications are not configured")
    provider = notification.load_catalog().resolve(provider_name)

    def body(transport: str) -> str:
        return _notification_body(
            service=service,
            event=event,
            transport=transport,
            summary=summary,
            checks=checks,
        )

    api_transport = f"HTTPS API ({provider.display_name})"
    fallback_transport = f"authenticated SMTP fallback (after {provider.display_name} API transient failure)"

    def smtp_fallback_sender(
        *,
        config: object,
        secrets: Mapping[str, str],
        context: Mapping[str, str],
    ) -> notification.AttemptResult:
        fallback_context = dict(context)
        fallback_context["text"] = body(fallback_transport)
        return notification.send_smtp(config=config, secrets=secrets, context=fallback_context)

    return notification.deliver(
        event_id=event_id,
        config=config,
        secrets=values,
        subject=subject,
        text=body(api_transport),
        smtp_sender=smtp_fallback_sender,
    )


def notification_test(*, smtp_only: bool) -> int:
    """Run the existing notification transports with a rich diagnostic body."""
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

        result = _deliver_with_transport_context(
            event_id="operator-test",
            config=config,
            values=values,
            subject=subject,
            service="VaultWarden-OCI notification",
            event="operator-test",
            summary="This diagnostic confirms the configured operational notification route accepted a test message.",
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
    """Send the existing systemd failure notification with useful operator context."""
    if not cli._EVENT.fullmatch(event):
        print("FAIL: --event must be a bounded systemd event identifier", file=sys.stderr)
        return 2
    try:
        config, values = _load_mail()
        host = _host()
        result = _deliver_with_transport_context(
            event_id=event,
            config=config,
            values=values,
            subject=f"FAILURE: {event} on {host}",
            service=event,
            event="systemd OnFailure",
            summary=f"VaultWarden-OCI systemd unit {event} entered a failed state.",
            checks=(
                f"systemctl status '{event}'",
                f"journalctl -xeu '{event}'",
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
