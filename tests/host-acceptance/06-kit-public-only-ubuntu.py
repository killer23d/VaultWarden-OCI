#!/usr/bin/env python3
"""Read ONLY the PUBLIC offline Age recipient from an emailed AES-256 recovery kit.

Ubuntu 26.04 ARM64 compatible. The encrypted kit can already be on the test VM,
but this program NEVER extracts or decrypts the private Age identity, tokens,
credentials.txt, or any other recovery-kit member. It streams ONLY config.toml
into memory, requests the ZIP passphrase without echo, and prints only the
public age1... recipient and classification. No plaintext files are created.

This does NOT prove the private identity can decrypt an existing .vwrec backup.
That requires an independent post-install backup verification gate.
"""
from __future__ import annotations

import getpass
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys
import tomllib
import zipfile

REQUIRED_MEMBERS = {
    "README.txt",
    "config.toml",
    "credentials.txt",
    "operational-age-identity.txt",
    "offline-recovery-identity.txt",
}
RECIPIENT_PATTERN = re.compile(r"age1[0-9a-z]{50,70}\Z")
MAX_KIT_BYTES = 16 * 1024 * 1024
MAX_CONFIG_BYTES = 128 * 1024


def block(message: str) -> int:
    print("BLOCKED: " + message, file=sys.stderr)
    return 1


def aes256(entry: zipfile.ZipInfo) -> bool:
    """Confirm the AES-256 WinZip ZIP metadata without decrypting the entry."""
    if entry.compress_type != 99 or not (entry.flag_bits & 1):
        return False
    extra = entry.extra
    offset = 0
    while offset + 4 <= len(extra):
        field, length = struct.unpack_from("<HH", extra, offset)
        offset += 4
        if offset + length > len(extra):
            return False
        value = extra[offset : offset + length]
        offset += length
        if field == 0x9901:
            return len(value) >= 7 and value[2:4] == b"AE" and value[4] == 3
    return False


def validate_archive(path: Path) -> None:
    if path.is_symlink():
        raise ValueError("recovery-kit archive must not be a symbolic link")
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError("recovery-kit archive must be a regular file")
    if not 0 < metadata.st_size <= MAX_KIT_BYTES:
        raise ValueError("recovery-kit ZIP has an unexpected size")
    with zipfile.ZipFile(path) as archive:
        members = archive.infolist()
        if len(members) != len(REQUIRED_MEMBERS):
            raise ValueError("unexpected recovery-kit member count")
        if {member.filename for member in members} != REQUIRED_MEMBERS:
            raise ValueError("unexpected recovery-kit member names")
        if any(member.is_dir() or not aes256(member) for member in members):
            raise ValueError("ZIP members are not all AES-256 encrypted")
        config_entry = next(m for m in members if m.filename == "config.toml")
        if not 0 < config_entry.file_size <= MAX_CONFIG_BYTES:
            raise ValueError("the encrypted configuration is unexpectedly large")


def main(args: list[str]) -> int:
    if len(args) != 2:
        return block("Usage: python3 06-kit-public-only-ubuntu.py /path/to/recovery-kit.zip")
    if sys.version_info < (3, 11):
        return block("Python 3.11+ is required to parse the kit configuration")
    if not sys.stdin.isatty():
        return block("Run interactively: ZIP passphrase is requested through your terminal")
    sevenzip = shutil.which("7zz") or shutil.which("7z")
    if not sevenzip:
        return block("7-Zip missing; on Ubuntu 26.04 run: sudo apt-get install -y 7zip")

    path = Path(args[1]).expanduser()
    try:
        validate_archive(path)
    except (ValueError, OSError, zipfile.BadZipFile, zipfile.LargeZipFile):
        return block("Encrypted recovery-kit ZIP cannot be validated; no files extracted")

    print("PASS: Exact five-member AES-256 encrypted recovery-kit structure")
    print("Only config.toml (non-secret public recipient) will be read in memory.")
    print("No private identity or credential file will be extracted.")
    password = getpass.getpass("Enter emailed recovery-kit ZIP passphrase: ")
    if not password or any(c in password for c in "\n\r\0"):
        return block("Invalid or empty ZIP passphrase")

    try:
        # The source project's sevenzip_secure wrapper also supplies the ZIP
        # passphrase over stdin when reading, never as -pPASSWORD or in env.
        result = subprocess.run(
            [sevenzip, "x", "-so", "-bd", str(path.resolve(strict=True)), "config.toml"],
            input=password + "\n",
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
        password = ""
    except (OSError, subprocess.TimeoutExpired):
        return block("7-Zip could not read encrypted config; no files extracted")

    if result.returncode != 0 or not result.stdout:
        return block("ZIP passphrase incorrect or encrypted config cannot be read")
    if len(result.stdout.encode("utf-8", errors="replace")) > MAX_CONFIG_BYTES:
        return block("Decrypted configuration exceeds the allowed size")
    try:
        config = tomllib.loads(result.stdout)
        recipient = config["secrets"]["offline_recovery_recipient"]
    except (tomllib.TOMLDecodeError, KeyError, TypeError):
        return block("ZIP config.toml does not contain a supported offline recovery recipient")
    if not isinstance(recipient, str) or not RECIPIENT_PATTERN.fullmatch(recipient):
        return block("Kit configuration contains an invalid offline public recipient")

    print("PASS: Encrypted config.toml decrypted in memory; private identity never opened")
    print("PUBLIC Age recipient for Gate A2:")
    print(recipient)
    print("NOT RUN: Matching private key / Box .vwrec decryption; separately verify in recovery gate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
