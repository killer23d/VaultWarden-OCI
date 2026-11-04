#!/usr/bin/env python3
"""P8L trusted OFF-HOST ciphertext + encrypted recovery-kit metadata witness.

Only an operator-controlled workstation; NEVER run on either OCI appliance.
Box mode: explicit TTY consent to read one original encrypted object and
store a mode-0600 ciphertext copy locally. Local mode: read an existing
operator-downloaded encrypted file. No Age private key, ZIP passphrase,
decryption, Box writes, SSH transfer or remote destructive operation.
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import secrets
import socket
import stat
import struct
import subprocess
import sys
import time
import zipfile

REMOTE = "bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec"
EXPECTED_SHA256 = "ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060"
NAME = "recovery-20261029T223200Z-1d319a79.vwrec"
AGE_HEADER = b"age-encryption.org/v1"
MAX_CIPHERTEXT = 4 * 1024**3
MAX_KIT = 16 * 1024**2
CONSENT = "P8L DOWNLOAD HISTORICAL ENCRYPTED CIPHERTEXT ONLY"
KIT_MEMBERS = {
    "README.txt", "config.toml", "credentials.txt",
    "operational-age-identity.txt", "offline-recovery-identity.txt",
}


class Blocked(RuntimeError):
    pass


def workstation_only() -> None:
    guest = socket.gethostname().split(".", 1)[0]
    if guest in ("vaultwarden-oci-6-vnic", "vaultwarden-oci-7-vnic"):
        raise Blocked("do not run off-host source helper on either appliance")
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        raise Blocked("run off-host source helper as an unprivileged workstation user")


def safe_directory(path: Path) -> None:
    meta = path.lstat()
    if (not stat.S_ISDIR(meta.st_mode) or meta.st_uid != os.getuid() or
            stat.S_IMODE(meta.st_mode) != 0o700):
        raise Blocked("encrypted ciphertext folder must be a private 0700 directory")


def check_regular(path: Path, limit: int) -> tuple[int, int]:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    info = os.fstat(fd)
    if (not stat.S_ISREG(info.st_mode) or
            info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or
            not 64 <= info.st_size <= limit):
        os.close(fd)
        raise Blocked("encrypted file is not a private 0600 regular file within bounds")
    return fd, info.st_size


def stream_sha(handle, limit: int) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    header = b""
    while True:
        block = handle.read(1024 * 1024)
        if not block:
            break
        if not header:
            header = block[:64]
        total += len(block)
        if total > limit:
            raise Blocked("encrypted ciphertext exceeds maximum size")
        digest.update(block)
    if total < 64 or not header.startswith(AGE_HEADER):
        raise Blocked("encrypted recovery does not have the supported Age v1 header")
    return digest.hexdigest(), total


def verify_local(path: Path) -> tuple[str, int]:
    if path.name != NAME or path.is_symlink():
        raise Blocked("only exact pinned historical ciphertext filename may be verified")
    fd, _ = check_regular(path, MAX_CIPHERTEXT)
    with os.fdopen(fd, "rb", closefd=True) as stream:
        actual, count = stream_sha(stream, MAX_CIPHERTEXT)
    if actual != EXPECTED_SHA256:
        raise Blocked("historical ciphertext SHA-256 MISMATCH; do not transfer or restore")
    return actual, count


def aes_256(entry: zipfile.ZipInfo) -> bool:
    if entry.compress_type != 99 or not (entry.flag_bits & 1):
        return False
    raw = entry.extra
    index = 0
    while index + 4 <= len(raw):
        code, size = struct.unpack_from("<HH", raw, index)
        index += 4
        if index + size > len(raw):
            return False
        if code == 0x9901:
            return size >= 7 and raw[index + 4] == 3
        index += size
    return False


def kit_metadata(path: Path) -> tuple[int, int]:
    fd, size = check_regular(path, MAX_KIT)
    try:
        with os.fdopen(fd, "rb", closefd=True) as file:
            with zipfile.ZipFile(file, "r") as archive:
                entries = archive.infolist()
                if len(entries) != 5 or {entry.filename for entry in entries} != KIT_MEMBERS:
                    raise Blocked("encrypted recovery-kit ZIP member names/count do not match expected schema")
                if not all(
                    not entry.is_dir() and not entry.filename.startswith("/") and
                    aes_256(entry) and entry.file_size > 0 and
                    entry.file_size <= 8 * 1024 * 1024
                    for entry in entries
                ):
                    raise Blocked("recovery-kit ZIP does not show AES-256 protection for every expected member")
    except (OSError, zipfile.BadZipFile, RuntimeError, ValueError, struct.error) as exc:
        raise Blocked("encrypted recovery ZIP metadata invalid or unavailable") from exc
    return size, len(KIT_MEMBERS)


def box_to_private_folder(directory: Path) -> tuple[str, int]:
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        raise Blocked("Box ciphertext download requires live interactive terminal")
    print("SOURCE BOUNDARY: read ONE original Age ciphertext via your workstation's Box remote.")
    print("This writes only encrypted bytes to your private workstation folder; no Box writes.")
    print("Your workstation rclone OAuth token may refresh locally. No private Age key or ZIP is opened.")
    print("To authorize exactly this encrypted download, type:", CONSENT)
    if input("Consent (anything else cancels): ") != CONSENT:
        raise Blocked("operator did not approve encrypted remote download")
    if directory.exists() or directory.is_symlink():
        if directory.is_symlink():
            raise Blocked("encrypted source folder cannot be a symlink")
        safe_directory(directory)
    else:
        directory.mkdir(mode=0o700, parents=False)
        safe_directory(directory)
    final = directory / NAME
    if final.exists() or final.is_symlink():
        raise Blocked("encrypted historical ciphertext destination exists; no overwrite permitted")
    try:
        listing = subprocess.run(
            ["rclone", "listremotes"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=20, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Blocked("workstation rclone Box remote unavailable") from exc
    if listing.returncode != 0 or b"bw-backup:" not in listing.stdout.splitlines():
        raise Blocked("workstation has no bw-backup: remote; use --local after Box UI download")
    tmp = directory / (".partial-" + secrets.token_hex(12))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    process = None
    digest = hashlib.sha256()
    total = 0
    header = b""
    try:
        process = subprocess.Popen(
            ["rclone", "cat", REMOTE, "--retries", "1"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 600
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Blocked("Box encrypted download timed out")
            if process.stdout is None:
                raise Blocked("Box encrypted download stream unavailable")
            import select
            ready, _, _ = select.select([process.stdout], [], [], min(remaining, 60))
            if not ready:
                raise Blocked("Box ciphertext stream stalled")
            block = os.read(process.stdout.fileno(), 1024 * 1024)
            if not block:
                break
            if not header:
                header = block[:64]
            total += len(block)
            if total > MAX_CIPHERTEXT:
                raise Blocked("encrypted ciphertext exceeds 4 GiB")
            digest.update(block)
            view = memoryview(block)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise Blocked("encrypted local write did not complete")
                view = view[written:]
        if process.wait(timeout=max(0.01, deadline - time.monotonic())) != 0:
            raise Blocked("Box read did not finish successfully")
        if total < 64 or not header.startswith(AGE_HEADER):
            raise Blocked("Box ciphertext header invalid")
        actual = digest.hexdigest()
        if actual != EXPECTED_SHA256:
            raise Blocked("Box encrypted bytes differ from independently pinned SHA")
        os.fsync(fd)
        os.close(fd)
        fd = -1
        # Link rather than rename: refuse to clobber an object created in a race.
        os.link(tmp, final)
        tmp.unlink()
        return actual, total
    finally:
        if process is not None:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            if process.stdout is not None:
                process.stdout.close()
        if fd >= 0:
            os.close(fd)
        tmp.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Trusted off-host Age ciphertext + encrypted ZIP metadata check")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--local", type=Path, help="Operator-downloaded existing Age ciphertext, mode 0600")
    mode.add_argument("--box", action="store_true", help="Consent to read/download exact historical Box ciphertext")
    parser.add_argument("--folder", type=Path, default=Path.home() / "vwoci-encrypted-handoff")
    parser.add_argument("--kit", type=Path, help="Optional off-host recovery-kit ZIP metadata only; never decrypt")
    args = parser.parse_args()
    try:
        workstation_only()
        if args.local:
            actual, size = verify_local(args.local)
        else:
            actual, size = box_to_private_folder(args.folder)
        print(f"PASS original historical Age-encrypted ciphertext sha256={actual} encrypted_bytes={size}")
        if args.kit:
            zip_size, count = kit_metadata(args.kit)
            print(f"PASS off-host recovery-kit ZIP members={count} encrypted_aes256=true bytes={zip_size} (no passphrase/contents read)")
        else:
            print("PENDING original offline recovery-kit AES-256 ZIP metadata not inspected")
        print("HOLD encrypted SOURCE only; no private key, plaintext, on-host transfer or restore.")
        return 0
    except (Blocked, OSError, EOFError, KeyboardInterrupt) as exc:
        # No exception details or cloud object paths are emitted.
        print("BLOCKED encrypted off-host source witness failed/cancelled; no transfer/restore authorized")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
