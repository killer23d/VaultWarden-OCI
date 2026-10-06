"""Read-only day-2 appliance summary, timer inspection, and sanitized support bundle."""
from __future__ import annotations

import json
import os
import re
import shutil
import tarfile
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence

from . import cli, durability, notification, recovery, runtime, secrets, storage, update_status

AUTOMATION_TARGET = "vaultwarden-oci.target"
TIMER_UNITS = (
    "vaultwarden-oci-health.timer",
    "vaultwarden-oci-backup.timer",
    "vaultwarden-oci-maintenance.timer",
    "vaultwarden-oci-update-check.timer",
)
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


class Day2Error(RuntimeError):
    """Raised for bounded read-model/support-bundle failures."""


def _now() -> float:
    return time.time()


def _age(iso_value: object) -> int | None:
    if not isinstance(iso_value, str) or not iso_value or iso_value == "-":
        return None
    try:
        when = datetime.fromisoformat(iso_value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return max(0, int(_now() - when.timestamp()))


def _systemd_properties(unit: str) -> dict[str, object]:
    result = cli.run_command(
        [
            "systemctl",
            "show",
            unit,
            "--no-pager",
            "--property=LoadState,ActiveState,SubState,Result,UnitFileState,NextElapseUSecRealtime,LastTriggerUSec",
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
        timer.update(
            {
                "trigger_unit": trigger_unit,
                "trigger_load_state": service.get("load_state"),
                "trigger_active_state": service.get("active_state"),
                "trigger_result": service.get("result"),
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


def _edge_status(checks: Sequence[cli.DoctorCheck]) -> dict[str, object]:
    edge_checks = [
        check
        for check in checks
        if check.check_id.startswith("edge.") or check.check_id.startswith("crowdsec.")
    ]
    return {
        "overall": cli.doctor_overall(edge_checks),
        "checks": [check.as_dict() for check in edge_checks],
    }


def _update_status() -> dict[str, object]:
    return update_status.snapshot(now=_now())


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
    return {
        "schema_version": 1,
        "runtime": {"overall": runtime_overall, "services": service_rows},
        "doctor": cli.doctor_payload(doctor_checks),
        "storage": storage_state,
        "recovery": _recovery_status(),
        "rclone": _check(doctor_checks, "recovery.rclone"),
        "edge": _edge_status(doctor_checks),
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


def status_command() -> int:
    payload = status_payload()
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 1 if payload["doctor"]["overall"] == "FAIL" or payload["automation"]["overall"] == "FAIL" else 0


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
        raise Day2Error(f"support runtime path must not be a symlink: {SUPPORT_ROOT}")
    SUPPORT_ROOT.mkdir(parents=True, exist_ok=True)
    os.chmod(SUPPORT_ROOT, 0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    if output is None:
        final = SUPPORT_ROOT / f"vaultwarden-oci-support-{stamp}.tar.gz"
    else:
        final = output if output.is_absolute() else Path.cwd() / output
        if final.parent.is_symlink() or not final.parent.is_dir():
            raise Day2Error(f"support-bundle output parent must be an existing directory: {final.parent}")
    if final.exists() or final.is_symlink():
        raise Day2Error(f"support-bundle output already exists; refusing overwrite: {final}")
    return final


def support_bundle(output: Path | None = None) -> Path:
    if os.geteuid() != 0:
        raise Day2Error("support-bundle must run as root")
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
                raise Day2Error(f"support-bundle output already exists; refusing overwrite: {final}") from exc
            except OSError as exc:
                raise Day2Error(f"cannot publish support bundle {final}: {exc}") from exc
            durability.fsync_file_and_parent(final)
        finally:
            temporary.unlink(missing_ok=True)
    print(f"PASS: sanitized support bundle created: {final}")
    return final
