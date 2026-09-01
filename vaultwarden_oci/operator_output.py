"""TTY-only presentation for the supported human vwctl surface."""
from __future__ import annotations

import os
import re
from typing import TextIO

_LABEL_COLORS = {
    "PASS": "32",
    "INFO": "36",
    "WARN": "33",
    "FAIL": "31",
    "ACTION": "34",
    "SKIP": "36",
}
_PREFIX = re.compile(r"(?m)^(PASS|INFO|WARN|FAIL|ACTION)(?=:)|^\[(PASS|WARN|FAIL|SKIP)\]")
_ROOT_SAFE_GUIDANCE = {
    "run 'vwctl crowdsec remediation-start'": "run 'sudo vwctl crowdsec remediation-start'",
    "then run 'vwctl crowdsec confirm-fail-open'": "then run 'sudo vwctl crowdsec confirm-fail-open'",
}


def color_enabled(stream: TextIO) -> bool:
    """Honor terminal capability and the standard NO_COLOR opt-out."""
    return bool(stream.isatty() and not os.environ.get("NO_COLOR"))


def colorize(text: str) -> str:
    """Color only stable human-status labels, never arbitrary message bodies."""
    def replace(match: re.Match[str]) -> str:
        label = match.group(1) or match.group(2)
        colored = f"\033[{_LABEL_COLORS[label]}m{label}\033[0m"
        return colored if match.group(1) else f"[{colored}]"

    return _PREFIX.sub(replace, text)


def root_safe_guidance(text: str) -> str:
    """Keep displayed root-only CrowdSec follow-ups directly executable."""
    rendered = text
    for unsafe, safe in _ROOT_SAFE_GUIDANCE.items():
        rendered = rendered.replace(unsafe, safe)
    return rendered


class ColorizingWriter:
    """Minimal transparent TextIO proxy used only on interactive human output."""

    def __init__(self, stream: TextIO, *, enabled: bool | None = None) -> None:
        self._stream = stream
        self._enabled = color_enabled(stream) if enabled is None else enabled

    def write(self, text: str) -> int:
        safe = root_safe_guidance(text)
        rendered = colorize(safe) if self._enabled else safe
        self._stream.write(rendered)
        return len(text)

    def flush(self) -> None:
        self._stream.flush()

    def isatty(self) -> bool:
        return self._stream.isatty()

    def fileno(self) -> int:
        return self._stream.fileno()

    @property
    def encoding(self):
        return self._stream.encoding

    @property
    def errors(self):
        return self._stream.errors

    def __getattr__(self, name: str):
        return getattr(self._stream, name)
