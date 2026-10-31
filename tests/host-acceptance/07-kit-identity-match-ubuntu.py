#!/usr/bin/env python3
"""Check that the old emailed recovery kit contains the matching Age private key.

No install, disk mutation, Box access, or cloud access. Only config.toml and
offline-recovery-identity.txt are decrypted, in memory; no plaintext files are
created. Passphrase travels via 7-Zip stdin, never argv/environment. Age
receives the private key via stdin, never disk. Only public/non-secret
pass/fail status is printed. This is NOT a .vwrec recovery verification.
"""
from __future__ import annotations

import getpass
from pathlib import Path
import re
import resource
import shutil
import stat
import struct
import subprocess
import sys
import tomllib
import zipfile

MEMBERS = {
    "README.txt", "config.toml", "credentials.txt",
    "operational-age-identity.txt", "offline-recovery-identity.txt",
}
RECIPIENT = re.compile(r"age1[0-9a-z]{50,70}\Z")
MAX_ZIP = 16 * 1024 * 1024
MAX_CONFIG = 128 * 1024
MAX_IDENTITY = 8192


def blocked(message: str) -> int:
    print("BLOCKED: " + message, file=sys.stderr)
    return 1


def is_aes256(info: zipfile.ZipInfo) -> bool:
    if info.compress_type != 99 or not (info.flag_bits & 1):
        return False
    extra = info.extra
    index = 0
    while index + 4 <= len(extra):
        field_id, field_size = struct.unpack_from("<HH", extra, index)
        index += 4
        if index + field_size > len(extra):
            return False
        field = extra[index:index + field_size]
        index += field_size
        if field_id == 0x9901:
            return len(field) >= 7 and field[2:4] == b"AE" and field[4] == 3
    return False


def check_zip(archive: Path) -> None:
    if archive.is_symlink():
        raise ValueError("kit is a symlink")
    info = archive.stat()
    if not stat.S_ISREG(info.st_mode) or not (0 < info.st_size <= MAX_ZIP):
        raise ValueError("kit is not a regular, size-bounded file")
    with zipfile.ZipFile(archive) as kit:
        members = kit.infolist()
        if len(members) != len(MEMBERS) or {m.filename for m in members} != MEMBERS:
            raise ValueError("kit has an unexpected file structure")
        if any(m.is_dir() or not is_aes256(m) for m in members):
            raise ValueError("kit does not have the expected AES-256 member encryption")
        sizes = {m.filename: m.file_size for m in members}
        if not 0 < sizes["config.toml"] <= MAX_CONFIG:
            raise ValueError("kit config size is outside safe bounds")
        if not 0 < sizes["offline-recovery-identity.txt"] <= MAX_IDENTITY:
            raise ValueError("kit private identity size is outside safe bounds")


def read_one(sevenzip: str, archive: Path, member: str, password: str, max_bytes: int) -> str:
    result = subprocess.run(
        [sevenzip, "x", "-so", "-bd", str(archive), member],
        input=password + "\n",
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    # Deliberately do not log result.stderr, stdout or the password.
    if result.returncode != 0 or not result.stdout:
        raise ValueError("could not open encrypted recovery-kit member")
    if len(result.stdout.encode("utf-8")) > max_bytes:
        raise ValueError("decrypted member exceeds size bound")
    return result.stdout


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        return blocked("Usage: python3 07-kit-identity-match-ubuntu.py /path/to/kit.zip age1PUBLIC_RECIPIENT")
    if not sys.stdin.isatty():
        return blocked("an interactive terminal is required for the ZIP passphrase")
    if sys.version_info < (3, 11):
        return blocked("Python 3.11+ is required")
    archive = Path(argv[1]).expanduser()
    expected = argv[2]
    if not RECIPIENT.fullmatch(expected):
        return blocked("the expected public Age recipient is malformed")

    sevenzip = shutil.which("7zz") or shutil.which("7z")
    keygen = shutil.which("age-keygen")
    if not sevenzip or not keygen:
        return blocked("7-Zip and Ubuntu age-keygen must both be installed")
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        check_zip(archive)
    except (OSError, ValueError, zipfile.BadZipFile, zipfile.LargeZipFile):
        return blocked("unexpected or unsafe recovery-kit archive")

    print("PASS: Recovery-kit ZIP has the expected AES-256 encrypted members")
    print("Verifying original offline private identity strictly in volatile process memory.")
    print("No private identity file or credentials will be written to disk or printed.")
    password = getpass.getpass("Recovery-kit ZIP passphrase (hidden): ")
    if not password or any(char in password for char in "\r\n\0"):
        return blocked("invalid ZIP passphrase input")

    try:
        config_text = read_one(sevenzip, archive, "config.toml", password, MAX_CONFIG)
        config = tomllib.loads(config_text)
        stored = config["secrets"]["offline_recovery_recipient"]
        if not isinstance(stored, str) or stored != expected:
            return blocked("expected public recipient differs from the kit's config")
        identity_text = read_one(
            sevenzip, archive, "offline-recovery-identity.txt", password, MAX_IDENTITY
        )
        password = ""
        # Official age-keygen -y reads an identity from standard input.
        result = subprocess.run(
            [keygen, "-y"],
            input=identity_text,
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        )
        identity_text = ""
        if result.returncode != 0:
            return blocked("kit's offline private identity is not readable by age-keygen")
        derived = result.stdout.strip()
        if derived != expected:
            return blocked("kit's offline private identity does not match expected public recipient")
        print("PASS: Kit config's public recipient matches expected recipient")
        print("PASS: Private offline Age identity derives the SAME public recipient")
        print("PASS: No plaintext credential or private-key files were created")
        print("NOT RUN: Actual Box .vwrec decryption and restore")
        return 0
    except (KeyError, TypeError, ValueError, OSError, UnicodeError,
            tomllib.TOMLDecodeError, subprocess.TimeoutExpired):
        return blocked("offline identity verification could not complete; original kit is unchanged")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
