#!/usr/bin/env python3
"""Gate A5: real Box pre-restore verification, but approval is HARDWIRED FALSE.

Uses the product's genuine AES-256 kit verification/extraction, offline Age
identity verification and restore_remote_once() preflight. The approval callback
ALWAYS returns False regardless of operator input: recovery.restore_recovery()
cannot be invoked by this harness. No setup, service start or restore.
"""
from __future__ import annotations

import getpass
import hashlib
import os
import pathlib
import stat
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from vaultwarden_oci import recovery_ux, runtime, storage  # noqa: E402

KIT = pathlib.Path("/root/vaultwarden-recovery/vaultwarden-recovery-kit-20261006T222828Z.zip")
SENSITIVE_ROOT = recovery_ux.SENSITIVE_RUN
BACKUP_DIR = pathlib.Path("/var/lib/vaultwarden-oci/backups")
TRACKED = (
    pathlib.Path("/etc/vaultwarden-oci/config.toml"),
    pathlib.Path("/etc/vaultwarden-oci/secrets.sops.yaml"),
    pathlib.Path("/etc/vaultwarden-oci/age-key.txt"),
    pathlib.Path("/var/lib/vaultwarden-oci/data"),
    pathlib.Path("/var/lib/vaultwarden-oci/caddy/data"),
    pathlib.Path("/var/lib/vaultwarden-oci/caddy/config"),
    pathlib.Path("/var/lib/vaultwarden-oci/state/recovery.json"),
)


def _digest_file(path: pathlib.Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def _snapshot() -> dict[str, tuple[object, ...]]:
    """Capture only digests and ownership, never secret plaintext."""
    result: dict[str, tuple[object, ...]] = {}
    for root in TRACKED:
        if not root.exists() and not root.is_symlink():
            result[str(root)] = ("absent",)
            continue
        paths = [root]
        if root.is_dir() and not root.is_symlink():
            paths += sorted(root.rglob("*"))
        for path in paths:
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise RuntimeError("unsafe symlink in protected appliance snapshot")
            if stat.S_ISDIR(info.st_mode):
                payload = ("directory", info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode))
            elif stat.S_ISREG(info.st_mode):
                payload = ("file", info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), info.st_size, _digest_file(path))
            else:
                raise RuntimeError("unexpected special file in protected appliance snapshot")
            result[str(path)] = payload
    return result


def _no_transients() -> bool:
    if SENSITIVE_ROOT.is_dir() and list(SENSITIVE_ROOT.glob("offline-identity-*")):
        return False
    if BACKUP_DIR.is_dir():
        for pattern in ("vwrec-remote-restore-*", "vwrec-remote-inspect-*", "vwrec-inspect-*", "vwrec-guided-remote-*"):
            if list(BACKUP_DIR.glob(pattern)):
                return False
    return True


def _main() -> int:
    if len(sys.argv) != 3:
        raise RuntimeError("expected original remote object and original SHA-256")
    remote, expected_sha = sys.argv[1:]
    if os.geteuid() != 0 or not sys.stdin.isatty() or not sys.stdout.isatty():
        raise RuntimeError("root and an interactive terminal are mandatory")
    if remote != "bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec":
        raise RuntimeError("unapproved remote object")
    if expected_sha != "ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060":
        raise RuntimeError("unapproved source checksum")
    if not KIT.is_file() or KIT.is_symlink():
        raise RuntimeError("private encrypted kit copy missing or unsafe")
    meta = KIT.lstat()
    if meta.st_uid != 0 or stat.S_IMODE(meta.st_mode) != 0o600:
        raise RuntimeError("private encrypted kit copy permissions differ")
    storage.verify()
    configured = runtime.load_config()
    prior = _snapshot()
    if not _no_transients():
        raise RuntimeError("unexpected private restore or identity staging already exists")
    print("PASS: Original appliance state captured by SHA-256/ownership comparison (hashes hidden)")
    print("Offline identity source: original AES-256 emailed kit, NOT pasted identity")
    print("Cancellation is enforced in code: RESTORE is never an allowed outcome.")
    passphrase = getpass.getpass("Original recovery-kit ZIP passphrase (hidden): ")
    if not passphrase or any(c in passphrase for c in "\n\r\0"):
        raise RuntimeError("empty or unsupported ZIP passphrase")

    requested = 0
    workspace = recovery_ux._new_identity_workspace(SENSITIVE_ROOT)
    try:
        # The installed product owns AES-256 ZIP validation and extraction;
        # temporary private key stays under root-owned /run/vaultwarden-oci.
        identity = recovery_ux._extract_recovery_kit_identity(KIT, passphrase, workspace)
        del passphrase
        identity = recovery_ux._validate_offline_identity(
            identity, configured.offline_recovery_recipient
        )
        print("PASS: Product decrypted emailed ZIP and its private Age identity matches configured public recipient")

        def refuse(verified) -> bool:
            nonlocal requested
            requested += 1
            if verified.sha256 != expected_sha or verified.size != 358680 or verified.created_at != "2026-10-29T22:32:01Z":
                raise RuntimeError("candidate does not match independently pinned backup SHA/size/timestamp")
            print("PASS: Restore preflight decrypted EXACT Box bytes and validated Age, manifest and SOPS")
            print("Candidate SHA-256=" + verified.sha256)
            print("Candidate size=" + str(verified.size))
            print("Candidate created=" + verified.created_at)
            print("This gate has no restore capability. Type CANCEL to prove the operator cancellation path.")
            answer = input("Cancellation authorization [CANCEL]: ").strip()
            if answer != "CANCEL":
                raise RuntimeError("CANCEL not entered; restore is still refused")
            print("PASS: Operator cancelled after full cryptographic preflight")
            return False

        outcome = recovery_ux.restore_remote_once(
            remote, identity, approve=refuse, start=False
        )
        if requested != 1 or outcome is not None:
            raise RuntimeError("restore refusal boundary did not return expected cancelled outcome")
    finally:
        recovery_ux._cleanup_identity_workspace(workspace)

    if _snapshot() != prior:
        raise RuntimeError("live configuration/data/Caddy/recovery metadata changed during cancelled restore")
    if not _no_transients():
        raise RuntimeError("temporary offline private identity or plaintext restore staging still exists")
    print("PASS: All protected live application files, data, Caddy and recovery.json are unchanged")
    print("PASS: All product temporary private-key and decrypted backup staging was removed")
    print("PASS: Product restore preflight reached approval boundary and returned without any restore")
    print("NOT RUN: Destructive restore, Vaultwarden start, DNS, timers or Box writes")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(_main())
    except (Exception, KeyboardInterrupt) as error:
        # Do not emit exception messages or traceback; encryption errors can
        # contain operator-specific data. Never reveal the ZIP passphrase.
        print("BLOCKED: A5 cancelled or failed: " + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
