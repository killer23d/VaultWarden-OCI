"""Read-only appliance operations summary, timer inspection, and sanitized support bundle."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence

from . import cli, durability, edge, notification, recovery, runtime, secrets, storage, update_guard, update_status

AUTOMATION_TARGET = "vaultwarden-oci.target"
TIMER_UNITS = (
    "vaultwarden-oci-health.timer",
    "vaultwarden-oci-backup.timer",
    "vaultwarden-oci-maintenance.timer",
    "vaultwarden-oci-update-check.timer",
)
TIMER_AUXILIARY_UNITS = {
    "vaultwarden-oci-health.timer": ("vaultwarden-oci-dns.service",),
}
SUPPORT_ROOT = runtime.RUN / "support"
_RECOVERY_WARN_AGE = 36 * 60 * 60
_DISK_WARN_PERCENT = 85
_MIN_EXACT_SECRET_LENGTH = 6
_REDACTIONS = (
    re.compile(r"(?i)(authorization)([ \t]*[:=][ \t]*)[^\r\n]*"),
    re.compile(r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"),
    re.compile(r"(?i)(password|passphrase|secret|token|api[_-]?key)(\s*[:=]\s*)[^\s,;]+"),
    re.compile(r"AGE-SECRET-KEY-[A-Z0-9]+"),
)


class OperationsError(RuntimeError):
    """Raised for bounded read-model/support-bundle failures."""


def _now() -> float:
    return time.time()


def _age(iso_value: object) -> int | None:
    if not isinstance(iso_value, str) or not iso_value or iso_value == "-":
        return None
    try:
        when = datetime.fromisoformat(iso_value.replace("Z", "+00:00"))
        if when.tzinfo is None:
            return None
        age = _now() - when.timestamp()
    except (ValueError, OSError, OverflowError):
        return None
    return int(age) if age >= 0 else None


def _systemd_properties(unit: str) -> dict[str, object]:
    result = cli.run_command(
        [
            "systemctl",
            "show",
            unit,
            "--no-pager",
            "--property=LoadState,ActiveState,SubState,Result,UnitFileState,NextElapseUSecRealtime,LastTriggerUSec,ExecMainStartTimestamp,ExecMainExitTimestamp",
        ]
    )
    if not result.ok:
        return {
            "unit": unit,
            "load_state": "unknown",
            "active_state": "unknown",
            "sub_state": "unknown",
            "result": "unknown",
            "enabled": "unknown",
            "next": None,
            "last_trigger": None,
            "last_started": None,
            "last_exited": None,
        }
    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return {
        "unit": unit,
        "load_state": values.get("LoadState", "unknown"),
        "active_state": values.get("ActiveState", "unknown"),
        "sub_state": values.get("SubState", "unknown"),
        "result": values.get("Result", "unknown"),
        "enabled": values.get("UnitFileState", "unknown"),
        "next": values.get("NextElapseUSecRealtime") or None,
        "last_trigger": values.get("LastTriggerUSec") or None,
        "last_started": values.get("ExecMainStartTimestamp") or None,
        "last_exited": values.get("ExecMainExitTimestamp") or None,
    }


def _timer_health(timer: dict[str, object], service: dict[str, object]) -> tuple[bool, list[str]]:
    problems: list[str] = []
    if timer.get("load_state") != "loaded":
        problems.append(f"timer load={timer.get('load_state')}")
    if timer.get("active_state") != "active":
        problems.append(f"timer active={timer.get('active_state')}")
    if service.get("load_state") != "loaded":
        problems.append(f"trigger load={service.get('load_state')}")
    if service.get("active_state") == "failed":
        problems.append("trigger active=failed")
    result = service.get("result")
    if result not in {"success", ""}:
        problems.append(f"trigger result={result}")
    return not problems, problems


def _automation_target() -> dict[str, object]:
    target = _systemd_properties(AUTOMATION_TARGET)
    problems: list[str] = []
    if target.get("load_state") != "loaded":
        problems.append(f"target load={target.get('load_state')}")
    if target.get("active_state") != "active":
        problems.append(f"target active={target.get('active_state')}")
    if target.get("enabled") not in {"enabled", "enabled-runtime"}:
        problems.append(f"target enabled={target.get('enabled')}")
    target["health"] = "PASS" if not problems else "FAIL"
    target["problems"] = problems
    return target


def timer_rows() -> list[dict[str, object]]:
    """Return required timers with truthful triggered-service health."""
    rows: list[dict[str, object]] = []
    for unit in TIMER_UNITS:
        timer = _systemd_properties(unit)
        trigger_unit = unit.removesuffix(".timer") + ".service"
        service = _systemd_properties(trigger_unit)
        healthy, problems = _timer_health(timer, service)
        auxiliaries: list[dict[str, object]] = []
        for auxiliary_unit in TIMER_AUXILIARY_UNITS.get(unit, ()):
            auxiliary = _systemd_properties(auxiliary_unit)
            auxiliaries.append(auxiliary)
            if auxiliary.get("load_state") != "loaded":
                problems.append(
                    f"auxiliary {auxiliary_unit} load={auxiliary.get('load_state')}"
                )
            if auxiliary.get("active_state") == "failed":
                problems.append(f"auxiliary {auxiliary_unit} active=failed")
            auxiliary_result = auxiliary.get("result")
            if auxiliary_result not in {"success", ""}:
                problems.append(
                    f"auxiliary {auxiliary_unit} result={auxiliary_result}"
                )
        healthy = not problems
        timer.update(
            {
                "trigger_unit": trigger_unit,
                "trigger_load_state": service.get("load_state"),
                "trigger_active_state": service.get("active_state"),
                "trigger_result": service.get("result"),
                "trigger_last_started": service.get("last_started"),
                "trigger_last_exited": service.get("last_exited"),
                "auxiliary_units": auxiliaries,
                "health": "PASS" if healthy else "FAIL",
                "failed": not healthy,
                "problems": problems,
            }
        )
        rows.append(timer)
    return rows


def automation_snapshot() -> dict[str, object]:
    target = _automation_target()
    timers = timer_rows()
    healthy_timers = sum(1 for row in timers if row.get("health") == "PASS")
    overall = (
        "PASS"
        if target.get("health") == "PASS"
        and len(timers) == len(TIMER_UNITS)
        and healthy_timers == len(TIMER_UNITS)
        else "FAIL"
    )
    return {
        "overall": overall,
        "target": target,
        "healthy": healthy_timers,
        "expected": len(TIMER_UNITS),
        "timers": timers,
    }


def timers_command(*, machine: bool = False) -> int:
    snapshot = automation_snapshot()
    target = snapshot["target"]
    assert isinstance(target, dict)
    rows = snapshot["timers"]
    assert isinstance(rows, list)
    if machine:
        print(json.dumps({"schema_version": 1, **snapshot}, indent=2, sort_keys=True))
    else:
        target_problems = "; ".join(str(item) for item in target.get("problems", [])) or "healthy"
        print(
            f"[{target.get('health')}] {AUTOMATION_TARGET}: "
            f"{target.get('active_state')} enabled={target.get('enabled')} ({target_problems})"
        )
        for row in rows:
            problems = "; ".join(str(item) for item in row.get("problems", [])) or "healthy"
            print(
                f"[{row['health']}] {row['unit']}: "
                f"{row.get('active_state')}/{row.get('sub_state')} unit-file={row.get('enabled')} "
                f"next={row.get('next') or '-'} last={row.get('last_trigger') or '-'} "
                f"trigger={row.get('trigger_active_state')}/{row.get('trigger_result')} ({problems})"
            )
    return 0 if snapshot["overall"] == "PASS" else 1


def _storage_status() -> dict[str, object]:
    try:
        identity = storage.verify()
        usage = shutil.disk_usage(storage.STATE_ROOT)
        used_percent = int(round((usage.used / usage.total) * 100)) if usage.total else 100
        warning = used_percent >= _DISK_WARN_PERCENT
        return {
            "state": "warning" if warning else "ok",
            "mount": identity.mount,
            "source": identity.source,
            "fs_type": identity.fs_type,
            "uuid": identity.uuid,
            "total_bytes": usage.total,
            "used_bytes": usage.used,
            "free_bytes": usage.free,
            "used_percent": used_percent,
            "warning": warning,
        }
    except (storage.StorageError, OSError) as exc:
        return {
            "state": "failure",
            "mount": str(storage.STATE_ROOT),
            "warning": True,
            "error": str(exc),
        }


def _recovery_status() -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for raw in recovery.status_rows():
        row: dict[str, object] = dict(raw)
        seconds = _age(raw.get("verified_at"))
        row["age_seconds"] = seconds
        row["stale"] = seconds is None or seconds > _RECOVERY_WARN_AGE
        rows.append(row)
    return rows


def _check(checks: Sequence[cli.DoctorCheck], check_id: str) -> dict[str, str]:
    for check in checks:
        if check.check_id == check_id:
            return check.as_dict()
    return {
        "id": check_id,
        "status": "FAIL",
        "message": f"required doctor check {check_id} is unavailable",
    }


def _doctor_group(checks: Sequence[cli.DoctorCheck], prefix: str) -> dict[str, object]:
    grouped = [check for check in checks if check.check_id.startswith(prefix)]
    return {
        "overall": cli.doctor_overall(grouped) if grouped else "FAIL",
        "checks": [check.as_dict() for check in grouped],
    }


def _update_status() -> dict[str, object]:
    return update_status.snapshot(now=_now())


def _object(value: object) -> dict[str, object]:
    return value if isinstance(value, dict) else {}


def _check_status(payload: dict[str, object], check_id: str) -> str:
    checks = _object(payload.get("doctor")).get("checks")
    for row in checks if isinstance(checks, list) else []:
        if isinstance(row, dict) and row.get("id") == check_id:
            return str(row.get("status", "UNKNOWN"))
    return "UNKNOWN"


def _config_snapshot() -> runtime.RuntimeConfig | None:
    try:
        return runtime.load_config()
    except (runtime.RuntimeConfigError, OSError):
        return None


def _receipt_status(receipt: dict[str, object]) -> dict[str, object]:
    row = dict(receipt)
    age = _age(row.get("verified_at"))
    row["age_seconds"] = age
    if row.get("state") == "verified":
        row["state"] = "unknown" if age is None else "stale" if age > _RECOVERY_WARN_AGE else "current"
    return row


def _job_result(unit: dict[str, object]) -> str:
    if unit.get("load_state") != "loaded":
        return "unknown"
    result, active = unit.get("result"), unit.get("active_state")
    if active == "failed" or result not in {"success", "", None, "unknown"}:
        return "failed"
    if active in {"activating", "active", "deactivating"}:
        return "running_or_active"
    if active != "inactive" or result != "success":
        return "unknown"
    if unit.get("last_exited") in {None, "", "n/a", "0", "-"}:
        return "not_recorded"
    return "success_recorded"


def _job_evidence(payload: dict[str, object]) -> dict[str, object]:
    jobs: dict[str, object] = {}
    timers = payload.get("timers")
    for timer in timers if isinstance(timers, list) else []:
        if not isinstance(timer, dict) or not isinstance(timer.get("unit"), str):
            continue
        trigger = {
            "load_state": timer.get("trigger_load_state"),
            "active_state": timer.get("trigger_active_state"),
            "result": timer.get("trigger_result"),
            "last_exited": timer.get("trigger_last_exited"),
        }
        trigger_name = timer.get("trigger_unit")
        if isinstance(trigger_name, str):
            jobs[trigger_name] = {"state": _job_result(trigger), **trigger}
        auxiliaries = timer.get("auxiliary_units")
        for unit in auxiliaries if isinstance(auxiliaries, list) else []:
            if isinstance(unit, dict) and isinstance(unit.get("unit"), str):
                jobs[unit["unit"]] = {**unit, "state": _job_result(unit)}
    return jobs


def _backup_evidence(
    config: runtime.RuntimeConfig | None, storage_ok: bool, jobs: dict[str, object],
) -> dict[str, object]:
    remote = config.offsite_remote if config is not None else None
    policy = "unknown" if config is None else "offsite_enabled" if remote else "local_only"
    unknown = {"state": "unknown", "verified_at": None}
    receipts = recovery.backup_receipt_evidence(remote) if storage_ok else {"local": unknown, "offsite": unknown}
    local = _receipt_status(receipts["local"])
    offsite_history = _receipt_status(receipts["offsite"])
    if config is None or not storage_ok:
        offsite_state = "unknown"
    elif remote is None:
        offsite_state = "local_only"
    elif offsite_history.get("state") == "never_verified":
        offsite_state = "never_verified"
    elif offsite_history.get("matches_destination") is True:
        offsite_state = str(offsite_history["state"])
    elif offsite_history.get("state") in {"current", "stale"}:
        offsite_state = "never_verified"
    else:
        offsite_state = "unknown"
    job = _object(jobs.get("vaultwarden-oci-backup.service"))
    return {
        "policy": policy,
        "destination": remote,
        "local": local,
        "offsite": {"state": offsite_state, "historical_receipt": offsite_history},
        "scheduled_job": job.get("state", "unknown"),
        "freshness_seconds": _RECOVERY_WARN_AGE,
        "remote_current_presence": "not_established",
        "offline_decryption": "not_established",
    }


def _notification_evidence(
    config: runtime.RuntimeConfig | None, payload: dict[str, object], storage_ok: bool,
) -> dict[str, object]:
    history = dict(_object(payload.get("notification"))) if storage_ok else {"state": "unknown"}
    if config is None:
        route = "unknown"
    elif config.notification_provider is None:
        route = "not_configured"
    elif all(_check_status(payload, check) == "PASS" for check in ("notification.provider", "notification.api_secret")):
        route = "configured"
    else:
        route = "attention"
    smtp = (
        "configured"
        if config is not None and _check_status(payload, "secrets.decrypt") == "PASS"
        else "not_established"
    )
    return {
        "application_smtp": smtp,
        "smtp_delivery": "not_established",
        "operational_route": route,
        "delivery_history": history,
    }


def _operational_classification(
    payload: dict[str, object], backup: dict[str, object], guard: dict[str, str],
    mail: dict[str, object], config: runtime.RuntimeConfig | None,
) -> dict[str, object]:
    storage_state = _object(payload.get("storage")).get("state")
    runtime_state = _object(payload.get("runtime")).get("overall")
    doctor_state = _object(payload.get("doctor")).get("overall")
    if storage_state not in {"ok", "warning"}:
        return {"state": "CRITICAL", "reason": "dedicated storage is not verified; persistent evidence cannot be trusted"}
    if guard["state"] != "absent":
        return {"state": "RECOVERY REQUIRED", "reason": guard["detail"]}
    if doctor_state == "FAIL" or runtime_state not in {"running", "stopped"}:
        return {"state": "CRITICAL", "reason": "doctor or runtime reports failure or unavailable state"}
    if config is None:
        return {"state": "SETUP INCOMPLETE", "reason": "valid operator configuration is not established"}
    if runtime_state == "stopped":
        return {"state": "MAINTENANCE / STOPPED", "reason": "services are stopped; administrator intent is unknown"}
    attention: list[str] = []
    if _object(payload.get("automation")).get("overall") != "PASS":
        attention.append("required automation is not healthy")
    if _object(backup.get("local")).get("state") != "current":
        attention.append("current verified local backup receipt is not established")
    if backup.get("scheduled_job") == "failed":
        attention.append("scheduled backup service reported failure")
    if backup.get("policy") == "offsite_enabled" and (
        _object(backup.get("offsite")).get("state") != "current"
        or _check_status(payload, "recovery.rclone") != "PASS"
    ):
        attention.append("configured offsite protection needs attention")
    update = _object(payload.get("update"))
    if update.get("check_state") != "current" or update.get("available"):
        attention.append("update check needs attention")
    if mail.get("operational_route") == "attention" or (
        mail.get("operational_route") == "configured"
        and _object(mail.get("delivery_history")).get("state") in {"warning", "failure", "unknown"}
    ):
        attention.append("operational notifications need attention")
    if payload.get("reboot_required") or storage_state == "warning":
        attention.append("host maintenance or disk usage needs attention")
    return {
        "state": "ATTENTION" if attention else "OPERATIONAL",
        "reason": "; ".join(attention) if attention else "required observed operations are healthy; external evidence is separate",
    }


def operational_snapshot(payload: dict[str, object]) -> dict[str, object]:
    """Add policy-aware, read-only evidence; never change the legacy status exit."""
    storage_ok = _object(payload.get("storage")).get("state") in {"ok", "warning"}
    config = _config_snapshot()
    jobs = _job_evidence(payload)
    backup = _backup_evidence(config, storage_ok, jobs)
    guard = (
        update_guard.status_snapshot()
        if storage_ok else {"state": "unknown", "detail": "dedicated storage is not verified"}
    )
    mail = _notification_evidence(config, payload, storage_ok)
    boot = _systemd_properties("vaultwarden-oci-crowdsec-boot.service")
    return {
        **_operational_classification(payload, backup, guard, mail, config),
        "backup": backup,
        "update_guard": guard,
        "notification": mail,
        "jobs": jobs,
        "crowdsec": {
            "boot_reconciliation": {**boot, "state": _job_result(boot)},
            "worker": edge.worker_invocation_snapshot(),
        },
        "maintenance_intent": "unknown",
    }


def status_payload() -> dict[str, object]:
    runtime_overall, service_rows = runtime.status()
    doctor_checks = cli.doctor_checks()
    storage_state = _storage_status()
    if not any(check.check_id == "storage.dedicated" for check in doctor_checks):
        storage_check = cli.DoctorCheck(
            "storage.dedicated",
            "PASS" if storage_state.get("state") != "failure" else "FAIL",
            "dedicated production storage is mounted and verified"
            if storage_state.get("state") != "failure"
            else str(storage_state.get("error", "dedicated storage is not ready")),
        )
        insert_at = next(
            (i + 1 for i, check in enumerate(doctor_checks) if check.check_id == "runtime.paths"),
            len(doctor_checks),
        )
        doctor_checks.insert(insert_at, storage_check)
    automation = automation_snapshot()
    timers = automation["timers"]
    assert isinstance(timers, list)
    failed_timers = [str(row["unit"]) for row in timers if isinstance(row, dict) and row.get("health") != "PASS"]
    payload = {
        "schema_version": 1,
        "runtime": {"overall": runtime_overall, "services": service_rows},
        "doctor": cli.doctor_payload(doctor_checks),
        "storage": storage_state,
        "recovery": _recovery_status(),
        "rclone": _check(doctor_checks, "recovery.rclone"),
        "edge": _doctor_group(doctor_checks, "edge."),
        "crowdsec": _doctor_group(doctor_checks, "crowdsec."),
        "admin": _check(doctor_checks, "edge.admin.protection"),
        "timers": timers,
        "automation": {
            "overall": automation["overall"],
            "target": automation["target"],
            "healthy": automation["healthy"],
            "expected": automation["expected"],
        },
        "failed_timers": failed_timers,
        "notification": dict(notification.status_row()),
        "update": _update_status(),
        "reboot_required": Path("/var/run/reboot-required").exists(),
    }
    payload["operational"] = operational_snapshot(payload)
    return payload


def status_command() -> int:
    payload = status_payload()
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 1 if payload["doctor"]["overall"] == "FAIL" or payload["automation"]["overall"] == "FAIL" else 0


# Explicit readiness only: never add TLS requests to the periodic health service.
_REQUIRED_FOUNDATIONS = (
    "host.os", "host.architecture", "config.toml", "versions.toml",
    "runtime.docker", "runtime.compose", "runtime.paths", "storage.dedicated",
    "secrets.custody", "secrets.decrypt", "notification.catalog",
    "edge.caddy.trusted_proxy", "edge.admin.protection", "edge.caddy.health",
    "edge.cloudflare.cidrs", "edge.cloudflare.iptables",
    "crowdsec.engine", "crowdsec.hub", "crowdsec.firewall", "crowdsec.cloudflare",
)


def _local_https(config: runtime.RuntimeConfig, admin: dict[str, object]) -> dict[str, str]:
    """One bounded, unauthenticated loopback HTTPS probe; not ingress proof."""
    if admin.get("status") != "PASS":
        return {"status": "UNKNOWN", "message": "admin policy is not established"}
    host = config.domain
    if not re.fullmatch(r"[A-Za-z0-9.-]+", host):
        return {"status": "UNKNOWN", "message": "configured hostname is invalid"}
    admin_code = "404" if "disabled" in str(admin.get("message", "")).lower() else "401"
    for endpoint, expected in (("/", "200"), ("/api/config", "200"), ("/admin/", admin_code)):
        argv = [
            "curl", "-q", "--noproxy", "*", "--proto", "=https",
            "--cacert", "/etc/ssl/certs/ca-certificates.crt",
            "--resolve", f"{host}:443:127.0.0.1",
            "--connect-timeout", "3", "--max-time", "5",
            "--silent", "--output", "/dev/null", "--write-out", "%{http_code}",
            f"https://{host}{endpoint}",
        ]
        try:
            response = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False, timeout=8)
        except (OSError, subprocess.TimeoutExpired):
            return {"status": "UNKNOWN", "message": "bounded loopback HTTPS probe unavailable or timed out"}
        if response.returncode != 0:
            return {"status": "UNKNOWN", "message": f"loopback TLS/HTTPS not verified ({endpoint})"}
        if response.stdout.strip() != expected:
            return {"status": "FAIL", "message": f"unexpected local HTTPS response ({endpoint})"}
    return {"status": "PASS", "message": "loopback HTTPS root, API and unauthenticated admin boundary verified"}


def readiness_payload() -> dict[str, object]:
    """Assess local foundations without applying configuration or testing providers."""
    payload = status_payload()
    operational = _object(payload.get("operational"))
    storage_ok = _object(payload.get("storage")).get("state") in {"ok", "warning"}
    checks = _object(payload.get("doctor")).get("checks")
    by_id = {
        row["id"]: row for row in checks if isinstance(row, dict) and isinstance(row.get("id"), str)
    } if isinstance(checks, list) else {}
    required = [
        dict(by_id.get(check_id, {"id": check_id, "status": "UNKNOWN", "message": "required check unavailable"}))
        for check_id in _REQUIRED_FOUNDATIONS
    ]
    runtime_ok = _object(payload.get("runtime")).get("overall") == "running"
    guard = _object(operational.get("update_guard"))
    backup = _object(operational.get("backup"))
    local = _object(backup.get("local"))
    auto = _object(payload.get("automation")).get("overall")
    config = _config_snapshot() if storage_ok and runtime_ok else None
    tls = (
        _local_https(config, _object(payload.get("admin")))
        if config is not None else {"status": "UNKNOWN", "message": "verified storage, valid config and running stack required"}
    )
    required.extend((
        {"id": "runtime.running", "status": "PASS" if runtime_ok else "FAIL", "message": "running stack required"},
        {"id": "update.guard", "status": "PASS" if guard.get("state") == "absent" else "FAIL", "message": guard.get("detail", "guard not established")},
        {"id": "automation.required", "status": "PASS" if auto == "PASS" else "FAIL", "message": "enabled target and active healthy required timers"},
        {"id": "recovery.local_receipt", "status": "PASS" if local.get("state") == "current" else "WARN", "message": "current local receipt and recorded file size; no fresh cryptographic verification"},
        {"id": "https.loopback", **tls},
    ))
    # Include every real doctor failure even if it belongs to an optional feature.
    required.extend(dict(row) for key, row in by_id.items() if key not in _REQUIRED_FOUNDATIONS and row.get("status") == "FAIL")
    mail = _object(operational.get("notification"))
    recommended = [
        {"id": "recovery.offsite", "state": _object(backup.get("offsite")).get("state", "unknown")},
        {"id": "notification.operational", "state": mail.get("operational_route", "unknown")},
        {"id": "update.check", "state": _object(payload.get("update")).get("check_state", "unknown")},
        {"id": "crowdsec.boot_reconciliation", "state": _object(_object(operational.get("crowdsec")).get("boot_reconciliation")).get("enabled", "unknown")},
    ]
    statuses = {row.get("status") for row in required}
    return {
        "schema_version": 1,
        "overall": "FAIL" if "FAIL" in statuses else "PASS" if statuses == {"PASS"} else "HOLD",
        "scope": "local_machine_foundations_only",
        "operational": operational,
        "required": required,
        "recommended": recommended,
        "administrator_attestations": [
            {"id": item, "state": "not_established"} for item in (
                "offline_identity_custody", "off_host_recovery_kit", "smtp_mailbox_receipt", "restore_drill",
            )
        ],
        "external_verification": [
            {"id": item, "state": "not_established"} for item in (
                "public_https", "non_cloudflare_origin_denial", "provider_network_policy", "current_remote_object", "current_provider_fail_open",
            )
        ],
        "deployment_approval": "not_established",
    }


def readiness_command(*, machine: bool = False) -> int:
    payload = readiness_payload()
    if machine:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"Local machine readiness: {payload['overall']} (not deployment approval)")
        for row in payload["required"]:
            print(f"[{row['status']}] {row['id']}: {row['message']}")
        for row in payload["recommended"]:
            print(f"RECOMMENDED: {row['id']}: {row['state']}")
        for key in ("administrator_attestations", "external_verification"):
            for row in payload[key]:
                print(f"NOT ESTABLISHED: {row['id']}")
    return 0 if payload["overall"] == "PASS" else 1


def _known_secret_values() -> tuple[list[str], str | None]:
    try:
        config = runtime.load_config()
        values = secrets.load(config.offline_recovery_recipient)
    except (runtime.RuntimeConfigError, secrets.SecretsError, OSError) as exc:
        return [], str(exc)
    known = sorted(
        (value for value in values.values() if len(value) >= _MIN_EXACT_SECRET_LENGTH),
        key=len,
        reverse=True,
    )
    if any(len(value) < _MIN_EXACT_SECRET_LENGTH for value in values.values()):
        return known, (
            "one or more configured secret values are too short for safe exact-value journal redaction; "
            "journal collection is disabled for this support bundle"
        )
    return known, None


def redact(text: str, known: Sequence[str] = ()) -> str:
    redacted = text
    for value in known:
        redacted = redacted.replace(value, "[REDACTED]")
    for pattern in _REDACTIONS:
        if pattern.groups >= 2:
            redacted = pattern.sub(
                lambda match: f"{match.group(1)}{match.group(2)}[REDACTED]",
                redacted,
            )
        else:
            redacted = pattern.sub("[REDACTED]", redacted)
    return redacted


def _bounded_journal() -> str:
    result = cli.run_command(
        [
            "journalctl",
            "--no-pager",
            "--since=-24 hours",
            "--lines=500",
            "-u",
            "vaultwarden-oci.service",
            "-u",
            "vaultwarden-oci-health.service",
            "-u",
            "vaultwarden-oci-backup.service",
            "-u",
            "vaultwarden-oci-maintenance.service",
            "-u",
            "vaultwarden-oci-update-check.service",
        ]
    )
    return (result.stdout + ("\n" + result.stderr if result.stderr else ""))[:512_000]


def _versions_text() -> str:
    vwctl = Path(__file__).resolve().parents[1] / "vwctl"
    result = cli.run_command([str(vwctl), "versions"])
    return result.stdout if result.ok else f"versions unavailable: {result.kind}\n"


def _support_output(output: Path | None) -> Path:
    if SUPPORT_ROOT.is_symlink():
        raise OperationsError(f"support runtime path must not be a symlink: {SUPPORT_ROOT}")
    SUPPORT_ROOT.mkdir(parents=True, exist_ok=True)
    os.chmod(SUPPORT_ROOT, 0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    if output is None:
        final = SUPPORT_ROOT / f"vaultwarden-oci-support-{stamp}.tar.gz"
    else:
        final = output if output.is_absolute() else Path.cwd() / output
        if final.parent.is_symlink() or not final.parent.is_dir():
            raise OperationsError(f"support-bundle output parent must be an existing directory: {final.parent}")
    if final.exists() or final.is_symlink():
        raise OperationsError(f"support-bundle output already exists; refusing overwrite: {final}")
    return final


def support_bundle(output: Path | None = None) -> Path:
    if os.geteuid() != 0:
        raise OperationsError("support-bundle must run as root")
    final = _support_output(output)
    known, secret_error = _known_secret_values()
    with tempfile.TemporaryDirectory(prefix="vwoci-support-", dir=str(SUPPORT_ROOT)) as directory:
        root = Path(directory)
        status = status_payload()
        payloads: dict[str, str] = {
            "status.json": json.dumps(status, indent=2, sort_keys=True) + "\n",
            "doctor.json": json.dumps(status["doctor"], indent=2, sort_keys=True) + "\n",
            "timers.json": json.dumps(status["timers"], indent=2, sort_keys=True) + "\n",
            "versions.txt": _versions_text(),
            "systemd-failed.txt": cli.run_command(["systemctl", "--failed", "--no-pager"]).stdout,
            "disk.txt": cli.run_command(["df", "-h", str(storage.STATE_ROOT)]).stdout,
        }
        if secret_error is None:
            payloads["journal.txt"] = _bounded_journal()
        else:
            payloads["journal-omitted.txt"] = (
                "Recent journal output was omitted because configured secret values could not be safely prepared "
                "for exact-value redaction. Structured diagnostics remain included.\n"
            )
        for name, content in payloads.items():
            path = root / name
            path.write_text(redact(content, known), encoding="utf-8")
            os.chmod(path, 0o600)

        descriptor, temp_name = tempfile.mkstemp(
            prefix=f".{final.name}.", suffix=".tmp", dir=str(final.parent)
        )
        os.close(descriptor)
        temporary = Path(temp_name)
        try:
            with tarfile.open(temporary, "w:gz") as archive:
                for path in sorted(root.iterdir()):
                    archive.add(path, arcname=path.name, recursive=False)
            os.chmod(temporary, 0o600)
            durability.fsync_file(temporary)
            try:
                os.link(temporary, final, follow_symlinks=False)
            except FileExistsError as exc:
                raise OperationsError(f"support-bundle output already exists; refusing overwrite: {final}") from exc
            except OSError as exc:
                raise OperationsError(f"cannot publish support bundle {final}: {exc}") from exc
            durability.fsync_file_and_parent(final)
        finally:
            temporary.unlink(missing_ok=True)
    print(f"PASS: sanitized support bundle created: {final}")
    return final
