"""Secure interactive 7-Zip subprocess boundary.

7-Zip deliberately reads a bare ``-p`` password from a terminal rather than a
normal stdin pipe.  This helper supplies that prompt through a pseudo-terminal
so the password never appears in argv, environment variables, or a file.
"""
from __future__ import annotations

import os
import pty
import select
import subprocess
import time
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
    master_fd, slave_fd = pty.openpty()
    process: subprocess.Popen[bytes] | None = None
    output = bytearray()
    prompts_answered = 0
    try:
        process = subprocess.Popen(
            tuple(argv),
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
            cwd=str(cwd) if cwd is not None else None,
        )
        os.close(slave_fd)
        slave_fd = -1
        deadline = time.monotonic() + timeout_seconds
        while True:
            if time.monotonic() > deadline:
                process.kill()
                process.wait()
                return subprocess.CompletedProcess(tuple(argv), 124, _redact(output, password_input), "")
            readable, _, _ = select.select([master_fd], [], [], 0.1)
            if readable:
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError:
                    chunk = b""
                if chunk:
                    output.extend(chunk)
                    lower = output.lower()
                    prompt_count = lower.count(b"enter password") + lower.count(b"verify password")
                    while prompts_answered < prompt_count:
                        response = "" if password_input is None else password_input
                        os.write(master_fd, response.encode("utf-8") + b"\n")
                        prompts_answered += 1
            returncode = process.poll()
            if returncode is not None:
                while True:
                    readable, _, _ = select.select([master_fd], [], [], 0)
                    if not readable:
                        break
                    try:
                        chunk = os.read(master_fd, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
                return subprocess.CompletedProcess(
                    tuple(argv),
                    returncode,
                    _redact(output, password_input),
                    "",
                )
    except OSError as exc:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        raise SevenZipError("7-Zip interactive execution failed") from exc
    finally:
        if slave_fd >= 0:
            os.close(slave_fd)
        try:
            os.close(master_fd)
        except OSError:
            pass


def _redact(output: bytes | bytearray, password: str | None) -> str:
    text = bytes(output).decode("utf-8", errors="replace")
    if password:
        text = text.replace(password, "<redacted>")
    return text
