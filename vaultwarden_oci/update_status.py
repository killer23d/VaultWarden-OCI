"""Public read-only view of persisted appliance update-check state."""
from __future__ import annotations

import json
import time
from pathlib import Path

from . import cli, update_appliance

MAX_AGE_SECONDS = 48 * 60 * 60


def load(path: Path = update_appliance.UPDATE_STATE) -> dict[str, object]:
    """Load persisted update-check state without mutating or performing network I/O."""
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, UnicodeError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def snapshot(
    *,
    path: Path = update_appliance.UPDATE_STATE,
    now: float | None = None,
    state_verified: bool = True,
) -> dict[str, object]:
    state = load(path) if state_verified else {}
    checked = state.get("checked_at")
    current_time = time.time() if now is None else float(now)
    age = (
        int(current_time - checked)
        if isinstance(checked, int) and not isinstance(checked, bool) and 0 <= checked <= current_time
        else None
    )
    try:
        installed = cli.load_versions().version
    except cli.VersionsError:
        installed = "unknown"
    reason = state.get("availability_reason")
    stale = age is None or age > MAX_AGE_SECONDS
    recorded_current = state.get("current")
    valid = (
        type(state.get("schema_version")) is int and state["schema_version"] == 1
        and {"checked_at", "current", "candidate", "available", "error"} <= state.keys()
        and isinstance(recorded_current, str) and bool(recorded_current)
        and isinstance(state.get("available"), bool)
        and (state.get("candidate") is None or isinstance(state.get("candidate"), str) and bool(state["candidate"].strip()))
        and (state.get("error") is None or isinstance(state.get("error"), str) and bool(state["error"].strip()))
        and (reason is None or isinstance(reason, str) and bool(reason.strip()))
        and (state.get("candidate") is not None or bool(state.get("error")) or bool(reason))
        and (state.get("available") is not True or (
            bool(state.get("candidate")) and state.get("candidate") != recorded_current and not state.get("error")
        ))
        and installed != "unknown"
    )
    if not valid or age is None:
        check_state = "unknown"
    elif state.get("error"):
        check_state = "failed"
    elif stale or recorded_current != installed:
        check_state = "stale"
    else:
        check_state = "current"
    return {
        "installed": installed,
        "checked_at": checked if isinstance(checked, int) and not isinstance(checked, bool) else None,
        "check_age_seconds": age,
        "check_stale": not valid or stale or recorded_current != installed,
        "state_verified": state_verified,
        "check_state": check_state,
        "candidate": state.get("candidate"),
        "available": state.get("available") is True,
        "availability_reason": reason if isinstance(reason, str) and reason else None,
        "error": state.get("error"),
    }
