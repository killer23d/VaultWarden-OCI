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
) -> dict[str, object]:
    state = load(path)
    checked = state.get("checked_at")
    current_time = time.time() if now is None else float(now)
    age = max(0, int(current_time - checked)) if isinstance(checked, int) and not isinstance(checked, bool) else None
    try:
        installed = cli.load_versions().version
    except cli.VersionsError:
        installed = "unknown"
    return {
        "installed": installed,
        "checked_at": checked if isinstance(checked, int) and not isinstance(checked, bool) else None,
        "check_age_seconds": age,
        "check_stale": age is None or age > MAX_AGE_SECONDS,
        "candidate": state.get("candidate"),
        "available": state.get("available") is True,
        "error": state.get("error"),
    }
