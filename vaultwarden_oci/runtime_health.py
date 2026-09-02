"""Shared bounded current-runtime health settling policy."""
from __future__ import annotations

import time
from typing import Callable

SETTLE_SECONDS = 65
POLL_SECONDS = 2


class RuntimeHealthError(RuntimeError):
    pass


Probe = Callable[[], tuple[bool, bool, str]]


def wait_until_ready(
    probe: Probe,
    *,
    settle_seconds: float = SETTLE_SECONDS,
    poll_seconds: float = POLL_SECONDS,
    sleep: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
) -> None:
    """Poll a current-runtime proof until ready, unsafe, or the bounded deadline."""
    deadline = monotonic() + settle_seconds
    while True:
        ready, retryable, detail = probe()
        if ready:
            return
        if not retryable:
            raise RuntimeHealthError(detail)
        if monotonic() >= deadline:
            raise RuntimeHealthError(f"timed out after {settle_seconds:g}s: {detail}")
        sleep(poll_seconds)
