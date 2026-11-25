"""Guided review of the existing successful-backup retention policy."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import tomllib
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable

from . import recovery, runtime
from .cli import run_command


class RetentionReviewError(RuntimeError):
    pass


@dataclass(frozen=True)
class Observation:
    config_sha256: str
    remote: str | None
    local_days: int
    remote_days: int
    local: tuple[dict[str, object], ...]
    offsite: tuple[dict[str, object], ...]


def observe(
    *, paths: recovery.RecoveryPaths = recovery.RecoveryPaths(),
    runner: recovery.Runner = run_command,
) -> Observation:
    """Read the sole config authority and exact flat retention inventories."""
    if (paths.config.is_symlink() or not paths.config.is_file()
            or paths.config.lstat().st_uid != os.geteuid()):
        raise RetentionReviewError("operator config must be a regular owned file")
    raw = paths.config.read_bytes()
    config = runtime.parse_config(tomllib.loads(raw.decode("utf-8")))
    local = tuple(recovery.local_retention_inventory(paths))
    offsite = tuple(sorted(
        recovery.list_remote(config.offsite_remote, runner=runner),
        key=lambda item: str(item["Name"]),
    )) if config.offsite_remote else ()
    # Validate unsafe provider names even when the current policy is disabled.
    # The exact same selector later supplies the proposed policy preview.
    recovery.age_pruning_decision(local, 0)
    recovery.age_pruning_decision(offsite, 0)
    if paths.config.is_symlink() or paths.config.read_bytes() != raw:
        raise RetentionReviewError("operator config changed while reading the inventory; review again")
    return Observation(
        hashlib.sha256(raw).hexdigest(), config.offsite_remote,
        config.local_retention_days, config.remote_retention_days, local, offsite,
    )


def _policy(days: int) -> str:
    return "0 days: keep indefinitely" if days == 0 else f"remove recovery points older than {days} days"


def _storage(label: str, entries: tuple[dict[str, object], ...]) -> None:
    generated = set(recovery.age_pruning_decision(entries, 0).keep)
    entries = tuple(item for item in entries if item["Name"] in generated)
    sizes = [item["Size"] for item in entries
             if type(item.get("Size")) is int and item["Size"] >= 0]
    total = sum(sizes)
    print(f"Observed {label}: {len(entries)} file(s); {total} bytes with known sizes ({len(sizes)}/{len(entries)}).")
    if sizes and len(sizes) == len(entries):
        average = total / len(sizes)
        print(f"Projection for {label}: 30 additional backups would add about {round(average * 30)} bytes before retention,")
        print(f"  assuming the observed average of {round(average)} bytes stays constant. This is not measured future growth or a schedule.")
    else:
        print(f"Projection for {label}: unavailable; a complete nonempty size sample is required.")


def _show_policy(observation: Observation, paths: recovery.RecoveryPaths) -> None:
    print(f"Local recovery folder: {paths.backups}")
    print(f"Saved destination: {observation.remote or 'LOCAL-ONLY (offsite publication disabled)'}")
    print(f"Saved local retention: {_policy(observation.local_days)}")
    print(f"Saved remote retention: {_policy(observation.remote_days)}")
    if observation.remote is None:
        print("Remote retention is inactive without a saved destination.")
        if observation.remote_days:
            print("ATTENTION: the saved nonzero remote policy would apply when an offsite destination is enabled.")
            print("Set it to zero to keep future remote backups until a destination-specific review.")
    print("Scope: generated recovery-*.vwrec files in the local folder and the exact saved remote folder only.")
    print("Remote subfolders are excluded from retention, even when recovery discovery lists them recursively.")
    print("Sizes and counts are observed metadata; they do not establish cryptographic recoverability.")
    _storage("local retention scope", observation.local)
    if observation.remote:
        _storage("remote flat inventory", observation.offsite)
    try:
        space = shutil.disk_usage(paths.backups)
    except OSError:
        print("Local filesystem free space: unavailable.")
    else:
        print(f"Observed local filesystem free space: {space.free} bytes. Backup staging also needs free space.")


def _preview(observation: Observation, local_days: int, remote_days: int, now: datetime) -> None:
    print(f"Retention preview at {now.isoformat()} (UTC); no files will be deleted by this review.")
    print(f"Proposed local retention: {_policy(local_days)}")
    print(f"Proposed remote retention: {_policy(remote_days)}")
    scopes = [("local", observation.local, local_days)]
    if observation.remote:
        scopes.append((observation.remote, observation.offsite, remote_days))
    else:
        print("Remote deletion preview: unavailable because no destination is saved; remote retention is inactive.")
        if remote_days:
            print("The unchanged dormant remote policy would take effect when a destination is enabled.")
    for label, entries, days in scopes:
        decision = recovery.age_pruning_decision(entries, days, now=now)
        print(f"{label}: {len(decision.delete)} existing point(s) currently eligible for removal after a later successful backup.")
        for name in decision.delete:
            print("  ELIGIBLE " + json.dumps(name, ensure_ascii=True))
        print(f"  {len(decision.keep)} generated point(s) currently outside the deletion plan.")
    print("The new verified recovery point from that later backup is always protected.")
    print("Older points, including today's newest existing point, can expire later; this is an ongoing age policy.")
    print("Publication/readback failure does not run retention. A one-time alternate remote is never automatically pruned.")
    print("Manual keep-last pruning is separate and unchanged. Neither zero policy value enables deletion.")


def _days(label: str, current: int) -> int:
    answer = input(f"{label} retention days [Enter keeps {current}; 0 keeps indefinitely; q cancels]: ").strip()
    if answer.casefold() in {"q", "quit"}:
        raise EOFError
    if not answer:
        return current
    try:
        return runtime._retention_days(int(answer), label)
    except (ValueError, runtime.RuntimeConfigError) as exc:
        raise RetentionReviewError("retention must be a whole number from 0 to 36500 days") from exc


def main(
    *,
    ensure_selected: Callable[[], None] = lambda: None,
    paths: recovery.RecoveryPaths = recovery.RecoveryPaths(),
    runner: recovery.Runner = run_command,
) -> int:
    """Review, preview, consent, recheck, then delegate a config-only save."""
    saving = False
    try:
        if paths.config == runtime.CONFIG and os.geteuid() != 0:
            raise RetentionReviewError("retention review requires sudo/root")
        if not (sys.stdin.isatty() and sys.stdout.isatty()):
            raise RetentionReviewError("guided retention requires an interactive terminal; no policy was changed")
        print("Purpose: review backup storage and automatic age retention; zero keeps backups indefinitely.")
        print("Prerequisites: selected installed appliance and readable local/offsite inventories.")
        print("Impact: SAVE changes only the two retention settings for future successful backups.")
        print("This review does not run a backup, prune files, change the saved destination, or change automation.")
        ensure_selected()
        observation = observe(paths=paths, runner=runner)
        _show_policy(observation, paths)
        now = datetime.now(timezone.utc)
        _preview(observation, observation.local_days, observation.remote_days, now)
        if input("Review a different retention policy? Type CHANGE (Enter leaves everything unchanged): ").strip() != "CHANGE":
            print("REVIEW COMPLETE: existing policy retained; no files deleted.")
            return 0
        local_days = _days("Local", observation.local_days)
        if observation.remote or observation.remote_days:
            label = "Remote" if observation.remote else "Remote (inactive; only 0 or the unchanged value is permitted)"
            remote_days = _days(label, observation.remote_days)
        else:
            remote_days = 0
            print("Remote retention remains 0; choose a saved destination before a nonzero remote policy can be reviewed.")
        if not observation.remote and remote_days not in {0, observation.remote_days}:
            raise RetentionReviewError("choose a saved offsite destination before a new nonzero remote retention policy")
        if (local_days, remote_days) == (observation.local_days, observation.remote_days):
            print("REVIEW COMPLETE: proposed policy matches the saved policy; nothing changed.")
            return 0
        _preview(observation, local_days, remote_days, now)
        print("Positive values authorize automatic removal of expired points after future successful backups.")
        if input("Save this ongoing retention policy? Type SAVE (anything else cancels): ").strip() != "SAVE":
            print("CANCELLED: retention policy unchanged; no files deleted.")
            return 0

        def verify_preview() -> None:
            ensure_selected()
            current = observe(paths=paths, runner=runner)
            if current != observation:
                raise RetentionReviewError("backup policy or inventory changed since preview; nothing saved, review again")
            # A long prompt or changed clock must not silently widen the preview.
            # Saving still enables the stated ongoing policy after this review.
            checked_at = datetime.now(timezone.utc)
            for entries, days in ((current.local, local_days), (current.offsite, remote_days)):
                if recovery.age_pruning_decision(entries, days, now=now) != recovery.age_pruning_decision(entries, days, now=checked_at):
                    raise RetentionReviewError("the age-based deletion preview changed with time; review again")

        ensure_selected()
        saving = True
        runtime.set_backup_retention(
            local_days, remote_days, expected_config_sha256=observation.config_sha256,
            verify_preview=verify_preview, path=paths.config, lock_path=paths.lock,
        )
        ensure_selected()
        saved = runtime.load_config(paths.config)
        if (saved.offsite_remote, saved.local_retention_days, saved.remote_retention_days) != (observation.remote, local_days, remote_days):
            raise RetentionReviewError("saved policy verification did not match; inspect current config before another backup")
        print(f"PASS: saved local retention={local_days} days, remote retention={remote_days} days; verified the unchanged destination.")
        print("No files deleted by this review. The existing backup pipeline applies the policy after successful verification.")
        print("Next action: review the existing backup schedule and recovery assurance before the next backup.")
        return 0
    except (EOFError, KeyboardInterrupt):
        if saving:
            print("HOLD: save interrupted; inspect current retention settings before retrying. No deletion was requested.")
            return 2
        print("CANCELLED: retention review interrupted; policy unchanged and no files deleted.")
        return 0
    except (RuntimeError, OSError, ValueError) as exc:
        print(f"HOLD: {exc}")
        if saving:
            print("Review current retention settings before retrying; a completed config save is not automatically rolled back.")
        return 2
