#!/usr/bin/env python3
"""Recover the PUBLIC Age recipient from the emailed encrypted recovery kit.

WORKSTATION-ONLY. Run on a trusted local Mac/Linux computer, NOT on the new
disposable OCI host. Does not change the ZIP or contact cloud services.
Temporarily extracts ONLY config.toml and offline-recovery-identity.txt into
a private temporary directory, then removes them automatically.

Dependencies: Python >= 3.9, age-keygen, and 7zz (or 7z).
Passphrase is entered using getpass; never in argv or environment variables.
"""
from __future__ import annotations

import getpass
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

MEMBERS = {
    "README.txt",
    "config.toml",
    "credentials.txt",
    "operational-age-identity.txt",
    "offline-recovery-identity.txt",
}
PUBLIC_RECIPIENT = re.compile(r"^age1[0-9a-z]{50,70}$")
TOML_RECIPIENT = re.compile(
    r'(?m)^[ \t]*offline_recovery_recipient[ \t]*=[ \t]*"(age1[0-9a-z]{50,70})"[ \t]*(?:#.*)?$'
)


def fail(message: str) -> int:
    print("BLOCKED: " + message, file=sys.stderr)
    return 1


def parse_kit_config(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    matches = TOML_RECIPIENT.findall(text)
    if len(matches) != 1:
        raise ValueError("kit config does not contain exactly one valid offline public recipient")
    return matches[0]


def check_members(archive: Path) -> None:
    with zipfile.ZipFile(archive, "r") as zf:
        items = zf.infolist()
        names = [item.filename for item in items]
        if len(names) != len(MEMBERS) or set(names) != MEMBERS:
            raise ValueError("archive does not match the five-member VaultWarden recovery-kit format")
        if any(item.is_dir() or not item.flag_bits & 1 for item in items):
            raise ValueError("recovery-kit member is not a password-encrypted regular ZIP entry")
        if sum(item.file_size for item in items) > 4 * 1024 * 1024:
            raise ValueError("archive contents exceed the bounded recovery-kit size")


def command(argv: list[str], *, input_text: str | None = None, timeout: int = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        input=input_text,
        text=True,
        capture_output=True,
        check=False,
        timeout=timeout,
    )


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        return fail("Usage: python3 05-kit-public-recipient.py /path/to/emailed-recovery-kit.zip")
    if not sys.stdin.isatty():
        return fail("run this only in your trusted computer's interactive terminal")
    if sys.version_info < (3, 9):
        return fail("Python 3.9+ is required")
    sevenzip = shutil.which("7zz") or shutil.which("7z")
    keygen = shutil.which("age-keygen")
    if not sevenzip or not keygen:
        return fail("need 7zz/7z and age-keygen on your TRUSTED WORKSTATION (on macOS: brew install sevenzip age)")

    archive = Path(argv[1]).expanduser()
    try:
        if not archive.is_file() or archive.is_symlink() or archive.stat().st_size == 0:
            return fail("encrypted recovery-kit ZIP not found or unsafe")
        check_members(archive)
    except (OSError, ValueError, zipfile.BadZipFile, zipfile.LargeZipFile) as exc:
        return fail("cannot validate encrypted recovery-kit ZIP: " + type(exc).__name__)

    print("Recovery kit: " + archive.name)
    print("Only its two required custody files will be extracted TEMPORARILY.")
    print("The ZIP, private identity, passphrase and credentials will NOT be uploaded or printed.")
    print("Do not enter an unrelated password or your account login.")
    password = getpass.getpass("Encrypted recovery-kit ZIP passphrase: ")
    if not password or any(c in password for c in "\r\n\0"):
        return fail("ZIP passphrase is missing or contains unsupported control characters")

    try:
        with tempfile.TemporaryDirectory(prefix="vwoci-private-kit-") as private_dir:
            private = Path(private_dir)
            # The original project uses one password line over 7-Zip stdin for
            # reading encrypted ZIP contents, never an inline -pPASSWORD.
            extract = command(
                [
                    sevenzip, "x", "-y", "-bd",
                    "-o" + str(private),
                    str(archive.resolve(strict=True)),
                    "config.toml",
                    "offline-recovery-identity.txt",
                ],
                input_text=password + "\n",
            )
            password = ""  # Do not retain an additional reference beyond use.
            if extract.returncode != 0:
                return fail("archive extraction/password verification failed; ZIP remains unchanged")

            config = private / "config.toml"
            identity = private / "offline-recovery-identity.txt"
            for entry in (config, identity):
                info = entry.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_size == 0 or info.st_size > 1_000_000:
                    return fail("archive yielded missing, unsafe or oversized custody member")
                entry.chmod(0o600)

            expected = parse_kit_config(config)
            result = command([keygen, "-y", str(identity)], timeout=15)
            if result.returncode != 0:
                return fail("offline recovery identity in ZIP is invalid")
            public = result.stdout.strip()
            if not PUBLIC_RECIPIENT.fullmatch(public):
                return fail("derived Age public recipient is invalid")
            if public != expected:
                return fail("offline Age private identity does not match the public recipient in kit config")

        # Only now that the private temp dir was cleaned, expose public data.
        print()
        print("PASS: Offline private Age identity matches the kit's configured public recipient.")
        print("PASS: Temporary plaintext custody extraction removed.")
        print()
        print("PUBLIC Age recipient (safe to paste into Gate A2):")
        print(public)
        print()
        print("NOT RUN: The existing Box .vwrec has not yet been independently decrypted.")
        print("Keep your original encrypted ZIP and its separate passphrase safely off the OCI server.")
        return 0
    except (OSError, ValueError, subprocess.TimeoutExpired, RuntimeError) as exc:
        # Never display subprocess stdout/stderr or private file contents.
        return fail("kit identity validation could not complete (" + type(exc).__name__ + ")")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
