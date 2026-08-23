"""Secure 7-Zip password transport carried forward from the proven V1 path.

Creation/update keeps a standalone ``-p`` switch and sends the confirmed
passphrase twice on stdin. Read/test/list operations remove standalone ``-p``;
encrypted content then causes 7-Zip to consume one password line from stdin.
Inline ``-pPASSWORD`` is rejected so secrets never enter argv.
"""
from __future__ import annotations

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

    password = "" if password_input is None else password_input
    if "\n" in password or "\r" in password or "\0" in password:
        raise SevenZipError("7-Zip password contains unsupported control characters")
    input_text = f"{password}\n{password}\n" if action in {"a", "u"} else f"{password}\n"
    try:
        # Deliberately keep this a simple subprocess.run seam: tests patch the
        # shared stdlib subprocess module to prove the secret never reaches argv.
        result = subprocess.run(
            tuple(safe),
            input=input_text,
            text=True,
            capture_output=True,
            check=False,
            cwd=str(cwd) if cwd is not None else None,
        )
    except OSError as exc:
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
