#!/usr/bin/env python3
"""Read-only installed baseline for a separately approved recovery rehearsal.

Run with sudo -n /usr/bin/python3 -B -I and an exact clean source checkout for
the currently installed release. This instrument does not install a candidate,
pause automation, create or restore a backup, extract an offline identity, or
contact backup providers. The installed status command performs its existing
local diagnostics. Only a private comparison tree under /run is written and
removed by the existing immutable-console verifier. Save the sanitized stdout
receipt from the invoking shell if evidence is required.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import types
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence

sys.dont_write_bytecode = True

# Reuse the accepted installed-source verifier without importing unverified
# companion code or bytecode. This is an acceptance instrument dependency,
# not another release or runtime configuration authority.
CONSOLE_SHA256 = "88114c4c411ff3ac916a477aaa10c7e50158dd6d3dca6a7655b2e4fa2f217ddd"
SAFE_ID = re.compile(r"[a-z][a-z0-9_.-]{0,80}\Z")
TIMERS = frozenset(
    f"vaultwarden-oci-{name}.timer"
    for name in ("health", "backup", "maintenance", "update-check")
)


class Hold(RuntimeError):
    """A fixed explanation safe to include in the returned receipt."""


def console_helper(path: Path | None = None) -> types.ModuleType:
    path = path or Path(__file__).with_name("dashboard-console.py")
    if path.is_symlink() or not path.is_file():
        raise Hold("the reviewed immutable-source verifier is unavailable")
    content = path.read_bytes()
    if hashlib.sha256(content).hexdigest() != CONSOLE_SHA256:
        raise Hold("immutable-source verifier checksum does not match the reviewed dependency")
    module = types.ModuleType("recovery_preflight_console")
    module.__file__ = str(path)
    exec(compile(content, str(path), "exec"), module.__dict__)
    return module


def object_value(value: object) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise Hold("installed status returned an incomplete object")
    return value


def summarize_status(payload: object, returncode: int, required_checks: Sequence[str]) -> dict[str, object]:
    """Validate the stable status contract and retain only bounded safe fields."""
    payload = object_value(payload)
    if payload.get("schema_version") != 1:
        raise Hold("installed status schema is unavailable or unsupported")
    doctor = object_value(payload.get("doctor"))
    if doctor.get("schema_version") != 1:
        raise Hold("installed doctor schema is unavailable or unsupported")
    checks = doctor.get("checks")
    if not isinstance(checks, list) or not checks:
        raise Hold("installed doctor evidence is missing")
    by_id: dict[str, str] = {}
    for row in checks:
        row = object_value(row)
        ident, state = row.get("id"), row.get("status")
        if (not isinstance(ident, str) or not SAFE_ID.fullmatch(ident)
                or ident in by_id or not isinstance(state, str)
                or state not in {"PASS", "WARN", "FAIL", "SKIP"}):
            raise Hold("installed doctor evidence is malformed")
        by_id[ident] = state
    overall = "FAIL" if "FAIL" in by_id.values() else "WARN" if "WARN" in by_id.values() else "SKIP" if set(by_id.values()) == {"SKIP"} else "PASS"
    if doctor.get("overall") != overall:
        raise Hold("installed doctor aggregate disagrees with its checks")
    runtime = object_value(payload.get("runtime"))
    rows = runtime.get("services")
    if not isinstance(rows, list) or len(rows) != 2:
        raise Hold("both required application service observations are missing")
    services = {}
    for row in rows:
        row = object_value(row)
        name = row.get("service")
        if not isinstance(name, str) or name not in {"vaultwarden", "caddy"} or name in services:
            raise Hold("application service observations are malformed")
        if row.get("state") != "running" or row.get("health") != "healthy":
            raise Hold("an application container is not running and healthy")
        services[name] = "running/healthy"
    if runtime.get("overall") != "running":
        raise Hold("the runtime is not running")
    automation = object_value(payload.get("automation"))
    automation_overall = automation.get("overall")
    if not isinstance(automation_overall, str) or automation_overall not in {"PASS", "FAIL"}:
        raise Hold("automation observation is unavailable")
    expected_code = int(overall == "FAIL" or automation_overall == "FAIL")
    if returncode != expected_code:
        raise Hold("installed status exit code disagrees with its observations")
    timers = payload.get("timers")
    if not isinstance(timers, list) or len(timers) != len(TIMERS):
        raise Hold("the required timer inventory is incomplete")
    timer_summary = {}
    for row in timers:
        row = object_value(row)
        name, health = row.get("unit"), row.get("health")
        active = row.get("active_state")
        if (not all(isinstance(item, str) for item in (name, health, active))
                or name not in TIMERS or name in timer_summary or health not in {"PASS", "FAIL"}
                or active not in {"active", "inactive", "failed", "activating", "deactivating"}):
            raise Hold("required timer observations are malformed")
        if health == "PASS" and active != "active":
            raise Hold("timer health disagrees with its activation state")
        timer_summary[name] = {"health": health, "active_state": active}
    target = object_value(automation.get("target"))
    enabled = target.get("enabled")
    if not isinstance(enabled, str) or enabled not in {"enabled", "enabled-runtime", "disabled", "static", "masked", "masked-runtime"}:
        raise Hold("automation boot-persistence observation is unavailable")
    target_health = target.get("health")
    if not isinstance(target_health, str) or target_health not in {"PASS", "FAIL"}:
        raise Hold("automation target health observation is unavailable")
    if target_health == "PASS" and (target.get("active_state") != "active" or enabled not in {"enabled", "enabled-runtime"}):
        raise Hold("automation target health disagrees with activation and persistence")
    healthy = sum(row["health"] == "PASS" for row in timer_summary.values())
    expected_overall = "PASS" if target_health == "PASS" and healthy == len(TIMERS) else "FAIL"
    if (automation_overall != expected_overall or automation.get("healthy") != healthy
            or automation.get("expected") != len(TIMERS)):
        raise Hold("automation aggregate disagrees with its observations")
    return {
        "runtime": services,
        "doctor_overall": overall,
        "doctor_fail_ids": sorted(name for name, state in by_id.items() if state == "FAIL"),
        "doctor_warn_ids": sorted(name for name, state in by_id.items() if state == "WARN"),
        "required_checks_missing": sorted(name for name in required_checks if by_id.get(name) != "PASS"),
        "automation_overall": automation_overall,
        "automation_enabled": enabled,
        "timers": timer_summary,
        "status_exit": returncode,
    }


def protected_files(paths: Sequence[Path]) -> None:
    for path in paths:
        info = path.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_gid != 0
                or stat.S_IMODE(info.st_mode) & 0o077 or info.st_size == 0):
            raise Hold("protected configuration or custody file is absent or not private root-owned state")


def metadata_inventory(directory: Path, pattern: str) -> dict[str, int]:
    if directory.is_symlink() or not directory.is_dir():
        raise Hold("the expected encrypted-artifact directory is absent or unsafe")
    info = directory.lstat()
    if info.st_uid != 0 or info.st_gid != 0 or stat.S_IMODE(info.st_mode) & 0o077:
        raise Hold("the encrypted-artifact directory is not private root-owned state")
    rows = list(directory.glob(pattern))
    if len(rows) > 10000:
        raise Hold("encrypted-artifact inventory exceeds the bounded preflight scope")
    sizes = []
    for path in rows:
        protected_files([path])
        sizes.append(path.stat().st_size)
    return {"count": len(sizes), "bytes": sum(sizes)}


def require_no_plaintext_workspaces(directory: Path) -> None:
    """Inspect names only; an interrupted custody workspace is never removed."""
    info = directory.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_gid != 0
            or stat.S_IMODE(info.st_mode) & 0o077):
        raise Hold("volatile custody root is absent or not a private root-owned directory")
    # The identity chooser, setup frontend and kit exporter respectively own
    # these three workspace names. Kit export contains both private identities
    # and plaintext credential values until its existing owner removes it.
    prefixes = ("offline-identity-", "setup-offline-recovery-", "recovery-kit-")
    with os.scandir(directory) as entries:
        if any(entry.name.startswith(prefixes) for entry in entries):
            raise Hold("an existing plaintext custody workspace requires review; it was not read or removed")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-host", required=True)
    parser.add_argument("--expected-sha", required=True, help="installed release's reviewed source SHA")
    parser.add_argument("--source", required=True, type=Path, help="clean operator-owned installed-source checkout")
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--expected-os", required=True, choices=("24.04", "26.04"))
    parser.add_argument("--expected-files", required=True, type=int)
    parser.add_argument("--expected-units", required=True, type=int)
    parser.add_argument("--storage-uuid", required=True)
    parser.add_argument("--domain", required=True)
    args = parser.parse_args(argv)
    receipt: dict[str, Any] = {
        "schema_version": 1, "scope": "read-only installed recovery baseline", "verdict": "HOLD",
        "observed_at": datetime.now(timezone.utc).isoformat(),
        "limits": "No candidate installation, recovery exercise, remote readback, off-host custody, provider policy, or production acceptance. Existing automation remains unchanged and may run during observation.",
    }
    helper = None
    try:
        if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,62}", args.expected_host)
                or not re.fullmatch(r"[0-9a-f]{40}", args.expected_sha)
                or not re.fullmatch(r"[0-9][A-Za-z0-9.+-]{2,60}", args.expected_version)
                or not re.fullmatch(r"[A-Fa-f0-9-]{4,128}", args.storage_uuid)
                or not 1 <= args.expected_files <= 1000 or not 1 <= args.expected_units <= 100):
            raise Hold("explicit host, exact source, release, storage and file-count expectations are required")
        helper = console_helper()
        account = helper.native_host(args.expected_host)
        helper.verified_source(args.source, args.expected_sha, account)
        sys.path.insert(0, str(args.source))
        from vaultwarden_oci import install, operations, runtime, storage, update_versions
        if Path(install.__file__).resolve().parents[1] != args.source:
            raise Hold("verifier import did not come from the reviewed installed-source checkout")
        if install.load_versions(args.source / "versions.toml").version != args.expected_version:
            raise Hold("source release identity differs from the approved installed release")
        if install.read_os_release(install.OS_RELEASE_PATH).get("VERSION_ID") != args.expected_os:
            raise Hold("Ubuntu release differs from the approved host scope")
        selected, manifest, installed_paths = helper.verify_installation(args.source, install, update_versions)
        file_count = sum(1 for path in selected.rglob("*") if path.is_file())
        if file_count != args.expected_files or len(install.SYSTEMD_UNITS) != args.expected_units:
            raise Hold("immutable file or installed unit count differs from the approved baseline")
        receipt.update(host=args.expected_host, source_sha=args.expected_sha, installed_release=args.expected_version,
                       immutable_files=file_count, installed_units=len(install.SYSTEMD_UNITS), manifest=manifest)
        def storage_read(command: Sequence[str]) -> Any:
            result = helper.read_command(command)
            return storage.CommandResult(tuple(command), result.returncode, result.stdout, "")
        identity = storage.verify(runner=storage_read)
        if identity.uuid != args.storage_uuid or identity.fs_type != "ext4":
            raise Hold("dedicated storage identity differs from the approved baseline")
        receipt["dedicated_storage"] = "PASS"
        guard = install.STATE_DIR / "update-recovery-required.json"
        if guard.exists() or guard.is_symlink():
            raise Hold("an update-recovery guard is present; preserve it and review recovery instructions")
        protected = [install.CONFIG_PATH, install.SECRETS_PATH, install.AGE_KEY_PATH, storage.HOST_IDENTITY_FILE]
        protected_files(protected)
        before = helper.snapshot([*installed_paths, *protected])
        try:
            config = runtime.load_config()
            if config.domain != args.domain:
                raise Hold("configured hostname differs from the approved disposable site")
            if config.offsite_remote is not None or (config.local_retention_days, config.remote_retention_days) != (0, 0):
                raise Hold("backup policy differs from the accepted local-only, zero-retention baseline")
            receipt["backup_policy"] = {"mode": "local-only", "local_retention_days": 0, "remote_retention_days": 0}
            receipt["local_encrypted_archives"] = metadata_inventory(install.STATE_ROOT / "backups", "*.vwrec")
            receipt["local_encrypted_kits"] = metadata_inventory(Path("/root/vaultwarden-recovery"), "vaultwarden-recovery-kit-*.zip")
            if not receipt["local_encrypted_archives"]["count"] or not receipt["local_encrypted_kits"]["count"]:
                raise Hold("the accepted backup or encrypted recovery kit is not present")
            require_no_plaintext_workspaces(install.RUNTIME_ROOT)
            receipt["known_plaintext_custody_workspaces"] = "absent"
            result = helper.read_command([str(install.VWCTL_LINK), "status", "--json"], timeout=120)
            observation = summarize_status(json.loads(result.stdout), result.returncode, operations._REQUIRED_FOUNDATIONS)
            receipt.update(observation)
            if observation["doctor_fail_ids"] or observation["required_checks_missing"]:
                raise Hold("installed doctor or required security/custody foundations need review")
            if observation["automation_overall"] != "PASS" or observation["automation_enabled"] != "enabled":
                raise Hold("accepted persistent automation is no longer established; no scheduling changes were made")
        finally:
            unchanged = helper.snapshot([*installed_paths, *protected]) == before
            receipt["immutable_and_custody_unchanged"] = unchanged
            if not unchanged:
                raise Hold("installed release, units, launcher or protected custody changed during observation")
        helper.verified_source(args.source, args.expected_sha, account)
        if guard.exists() or guard.is_symlink():
            raise Hold("an update-recovery guard appeared during observation")
        receipt.update(verdict="PASS", recovery_guard="absent")
    except Hold as exc:
        receipt["reason"] = str(exc)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError, ImportError) as exc:
        if helper is not None and isinstance(exc, helper.Hold):
            receipt["reason"] = str(exc)
        else:
            receipt["reason"] = f"required verification failed ({type(exc).__name__}); details withheld"
    except KeyboardInterrupt:
        receipt["reason"] = "read-only preflight interrupted; no PASS receipt issued"
    print(json.dumps(receipt, indent=2, sort_keys=True))
    return 0 if receipt["verdict"] == "PASS" else 2


if __name__ == "__main__":
    os.umask(0o077)
    raise SystemExit(main())
