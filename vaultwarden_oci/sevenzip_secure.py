"""Secure 7-Zip password transport for recovery-kit operations.

Creation/update keeps a standalone ``-p`` switch and sends the confirmed
passphrase twice on stdin. Read/test/list operations remove standalone ``-p``;
encrypted content then causes 7-Zip to consume one password line from stdin.
``password_input=None`` means no password input at all and connects stdin to
``/dev/null``. Inline ``-pPASSWORD`` is rejected so secrets never enter argv.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from typing import Sequence


class SevenZipError(RuntimeError):
    pass


def run(
    argv: Sequence[str],
    *,
    password_input: str | None,
    cwd: Path | None = None,
    timeout_seconds: float = 30.0,
) -> subprocess.CompletedProcess[str]:
    if not argv:
        raise SevenZipError("7-Zip command is empty")
    command = list(argv)
    if len(command) < 2:
        raise SevenZipError("7-Zip command name is missing")
    if command[0] == "7zz" and shutil.which("7zz") is None:
        fallback = shutil.which("7z")
        if fallback is not None:
            command[0] = fallback
    action = command[1]
    safe: list[str] = []
    prompt_switch = False
    for index, arg in enumerate(command):
        if index < 2:
            safe.append(arg)
            continue
        if arg == "-p":
            if action in {"a", "u"}:
                prompt_switch = True
                safe.append(arg)
            continue
        if arg.startswith("-p") and len(arg) > 2:
            raise SevenZipError("inline 7-Zip passwords are forbidden")
        safe.append(arg)
    if action in {"a", "u"} and not prompt_switch:
        safe.insert(2, "-p")

    if password_input is None:
        if action in {"a", "u"}:
            raise SevenZipError("7-Zip archive creation requires explicit password input")
        input_text = None
    else:
        if "\n" in password_input or "\r" in password_input or "\0" in password_input:
            raise SevenZipError("7-Zip password contains unsupported control characters")
        input_text = (
            f"{password_input}\n{password_input}\n"
            if action in {"a", "u"}
            else f"{password_input}\n"
        )
    try:
        if input_text is None:
            result = subprocess.run(
                tuple(safe),
                stdin=subprocess.DEVNULL,
                text=True,
                capture_output=True,
                check=False,
                cwd=str(cwd) if cwd is not None else None,
                timeout=timeout_seconds,
            )
        else:
            result = subprocess.run(
                tuple(safe),
                input=input_text,
                text=True,
                capture_output=True,
                check=False,
                cwd=str(cwd) if cwd is not None else None,
                timeout=timeout_seconds,
            )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SevenZipError("7-Zip secure execution failed") from exc
    return subprocess.CompletedProcess(
        tuple(safe),
        result.returncode,
        _redact(result.stdout, password_input),
        _redact(result.stderr, password_input),
    )


def _redact(text: str, password: str | None) -> str:
    if password:
        return text.replace(password, "<redacted>")
    return text
