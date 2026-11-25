"""Human backup policy and evidence views over the existing recovery owners."""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tomllib
from datetime import datetime, timezone

from . import cli, offsite, operations, recovery, recovery_ux, runtime, storage, update_guard


class Hold(RuntimeError):
    pass


def _interactive() -> None:
    if os.geteuid() != 0:
        raise Hold("use sudo vwctl for backup configuration and execution")
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        raise Hold("this guide requires a terminal; use the existing explicit backup/offsite commands for automation")


def _policy(config: runtime.RuntimeConfig) -> None:
    print(f"Saved destination: {config.offsite_remote or 'LOCAL-ONLY (no offsite publication)'}")
    for label, days in (("Local", config.local_retention_days), ("Remote", config.remote_retention_days)):
        print(f"{label} retention: {days} days" if days else f"{label} retention: 0 (keep indefinitely)")
    if config.local_retention_days or (config.offsite_remote and config.remote_retention_days):
        print("WARN: the saved policy permits deletion of expired backups after a successful backup.")
        print("ACTION: review exact current candidates with 'sudo vwctl recovery retention' before continuing.")


def _receipt(value: object) -> dict | None:
    if not isinstance(value, dict):
        return None
    try:
        when = datetime.fromisoformat(value["verified_at"].replace("Z", "+00:00"))
        valid = (when.tzinfo is not None and when <= datetime.now(timezone.utc)
                 and type(value.get("size")) is int and value["size"] > 0
                 and isinstance(value.get("sha256"), str)
                 and re.fullmatch(r"[0-9a-f]{64}", value["sha256"]))
    except (KeyError, AttributeError, ValueError, TypeError, OverflowError):
        return None
    return value if valid else None


def protection(*, paths: recovery.RecoveryPaths = recovery.RecoveryPaths()) -> int:
    """Report actual observations and historical receipts without provider access."""
    try:
        if paths == recovery.RecoveryPaths():
            storage.verify()
        config = runtime.load_config(paths.config)
        print("\n== Backup protection and verification history ==")
        _policy(config)
        points = recovery_ux.list_local(paths)
        print(f"Local inventory: {len(points)} regular .vwrec file(s), {sum(point.size for point in points)} bytes")
        state = recovery._load_state(paths.state_file)
        if type(state.get("schema_version")) is not int or state["schema_version"] != 1 or state.get("state_error"):
            state = {}
            print("WARN: recovery history is unreadable or invalid; no historical assurance is inferred.")
        evidence = recovery.backup_receipt_evidence(config.offsite_remote, paths, state=state)
        local = _receipt(state.get("local"))
        print("\nRecovery assurance (each level needs its own evidence):")
        print(f"1. Backup exists: {'OBSERVED locally' if points else 'NOT ESTABLISHED locally'}; inventory does not decrypt files.")
        if local:
            print(f"   Local creation history: {local['verified_at']}; recorded artifact state={evidence['local']['state']}")
        remote = _receipt(state.get("offsite"))
        if remote and evidence["offsite"].get("state") == "verified":
            print(f"2. Remote ciphertext readback verified: HISTORICAL at {remote['verified_at']}")
            print(f"   Exact object: {json.dumps(remote['remote_object'])}; sha256={remote['sha256']}")
            print(f"   Matches current saved destination: {'YES' if evidence['offsite'].get('matches_destination') else 'NO'}")
        else:
            print("2. Remote ciphertext readback verified: NOT ESTABLISHED by valid recorded evidence")
        records = state.get("verified_objects")
        valid = [(location, row) for location, value in (records.items() if isinstance(records, dict) else ())
                 if isinstance(location, str) and location and (row := _receipt(value)) is not None]
        print(f"3. Offline-key cryptographic recovery verified: {'HISTORICAL records below' if valid else 'NOT ESTABLISHED'}")
        for location, row in sorted(valid, key=lambda item: item[1]["verified_at"], reverse=True)[:5]:
            print(f"   {row['verified_at']} {json.dumps(location)} size={row['size']} sha256={row['sha256']}")
        if len(valid) > 5:
            print(f"   Showing latest 5 of {len(valid)} recorded object verifications; use recovery inventory for selection.")
        print("4. Disposable-host recovery demonstrated: NOT ESTABLISHED by this screen; requires a separate populated-data restore receipt.")
        print("INFO: history is evidence from its recorded time, not current remote presence or proof of off-host key custody.")
        print("INFO: this view does not contact the provider, decrypt an archive, or exercise a restore.")
        timer = operations._systemd_properties("vaultwarden-oci-backup.timer")
        print(f"\nExisting backup timer: load={timer['load_state']} active={timer['active_state']} unit-file={timer['enabled']}")
        print(f"Next scheduled event: {timer.get('next') or 'not established'}; last trigger: {timer.get('last_trigger') or 'not established'}")
        print("ACTION: 'sudo vwctl timers' shows the current systemd schedule and job results.")
        print("ACTION: 'sudo vwctl recovery verify' selects a local or remote archive for offline-key verification.")
        return 0
    except (runtime.RuntimeConfigError, recovery.RecoveryError, storage.StorageError, OSError) as exc:
        print(f"HOLD: backup evidence could not be established: {exc}", file=sys.stderr)
        return 2


def _fingerprint() -> str:
    return hashlib.sha256(runtime.CONFIG.read_bytes()).hexdigest()


def _reviewed_config() -> tuple[runtime.RuntimeConfig, str]:
    """Bind the displayed policy and consent witness to the same exact bytes."""
    try:
        raw = runtime.CONFIG.read_bytes()
        config = runtime.parse_config(tomllib.loads(raw.decode("utf-8")))
    except (UnicodeError, tomllib.TOMLDecodeError) as exc:
        raise runtime.RuntimeConfigError(f"cannot read the backup policy: {exc}") from exc
    return config, hashlib.sha256(raw).hexdigest()


def _backup_ready() -> None:
    storage.verify()
    if update_guard.status_snapshot()["state"] != "absent":
        raise Hold("resolve the recorded update recovery boundary before a guided backup")
    overall, services = runtime.status()
    if (overall != "running" or len(services) != 2
            or {row.get("service") for row in services} != {"vaultwarden", "caddy"}
            or any(row.get("state") != "running" or row.get("health") != "healthy" for row in services)):
        raise Hold("guided backup needs both application services running and healthy; inspect status and Doctor")


def backup_now() -> int:
    try:
        _interactive()
        _backup_ready()
        config, expected = _reviewed_config()
        print("\n== Backup now using saved policy ==")
        _policy(config)
        print("Impact: briefly pause containers for a consistent snapshot, then resume and verify health.")
        print("The existing pipeline encrypts locally, publishes to the saved destination if configured, and independently reads it back.")
        print("A publication failure preserves local and previous backups and skips retention.")
        if input("Type BACKUP to run this policy now (anything else cancels): ").strip() != "BACKUP":
            print("CANCELLED: no backup started.")
            return 0
        _backup_ready()
        if _fingerprint() != expected:
            raise Hold("configuration changed during consent; review the current policy and retry")
        print("INFO: creating and verifying through the existing backup pipeline...", flush=True)
        code = offsite.backup(reviewed_config=config)
        if code == 0:
            print("ACTION: use 'sudo vwctl recovery verify' for separate offline-key cryptographic verification.")
            print("INFO: this backup does not demonstrate a disposable-host restore or activate any timer.")
        return code
    except (KeyboardInterrupt, EOFError):
        print("CANCELLED: backup interaction interrupted; inspect status and recovery history before retrying.")
        return 130
    except (Hold, cli.LockBusyError) as exc:
        print(f"HOLD: {exc}", file=sys.stderr)
        return 2
    except (offsite.OffsiteError, recovery.RecoveryError, runtime.RuntimeConfigError,
            storage.StorageError, OSError) as exc:
        print(f"FAIL: {exc}; inspect status and recovery history before retrying", file=sys.stderr)
        return 1


def configure() -> int:
    try:
        _interactive()
        storage.verify()
        config = runtime.load_config()
        print("\n== Configure backup protection ==")
        _policy(config)
        print("One backup command and one existing backup timer use this policy.")
        print("  1) Local-only backups\n  2) Local plus offsite backups\n  q) Cancel")
        answer = input("Choose policy (anything else cancels): ").strip()
        if answer == "1":
            if config.offsite_remote:
                if not offsite.disable(confirmed=False):
                    return 0
            else:
                print("INFO: local-only policy is already selected; no configuration changed.")
        elif answer == "2":
            try:
                offsite._configured_names()
            except offsite.OffsiteError:
                print("Root rclone configuration is not ready. The supported provider setup is 'sudo rclone config'.")
                print("This opens rclone's own authentication workflow; saving credentials does not enable publication.")
                if input("Type RCLONE to open root's rclone config (anything else cancels): ").strip() != "RCLONE":
                    print("CANCELLED: saved backup policy is unchanged.")
                    return 0
                result = subprocess.run(["rclone", "config"], check=False)
                if result.returncode != 0:
                    raise Hold("rclone configuration did not complete; backup policy was not changed")
            if not offsite.configure():
                return 0
        else:
            print("CANCELLED: saved backup policy is unchanged.")
            return 0
        print("\nSaved policy readback:")
        _policy(runtime.load_config())
        print("INFO: saving a policy is not successful backup, remote readback, or offline-key verification.")
        if input("Review and optionally run a first backup now? [y/N]: ").strip().lower() in {"y", "yes"}:
            return backup_now()
        print("ACTION: run 'sudo vwctl recovery backup' when ready; existing timer activation is unchanged.")
        return 0
    except (KeyboardInterrupt, EOFError):
        print("CANCELLED: configuration interaction interrupted; inspect the saved policy before retrying.")
        return 130
    except (Hold, cli.LockBusyError) as exc:
        print(f"HOLD: {exc}", file=sys.stderr)
        return 2
    except (offsite.OffsiteError, runtime.RuntimeConfigError, storage.StorageError, OSError) as exc:
        print(f"FAIL: {exc}; inspect the saved policy before retrying", file=sys.stderr)
        return 1
