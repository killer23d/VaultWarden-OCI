#!/usr/bin/env python3
"""P2: real Box -> Age -> manifest/SOPS/SQLite non-promoting recovery rehearsal.

Host-pinned acceptance only: disposable rc.12 VM. No persistent .vwrec, no
restore, no production access, no Box writes, no service activation.
Private encrypted archive and decrypted payload are staged ONLY in /run tmpfs.
The operator supplies an offline identity with the existing secure UX.
"""
from __future__ import annotations

import contextlib
import datetime as dt
import hashlib
import importlib.util
import os
import platform
import pwd
import select
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import quote

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-6-vnic"
VERSION = "0.1.0-rc.12"
SOURCE = Path(__file__).resolve().parents[2]
P1_SOURCE = Path(__file__).resolve().with_name("production-recovery-source-preflight.py")
INSTALLED = Path("/opt/vaultwarden-oci/releases") / VERSION
CURRENT = Path("/opt/vaultwarden-oci/current")
STATE = Path("/var/lib/vaultwarden-oci")
MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_READ_SECONDS = 600
EXPECTED_ARCHIVE_SHA = "ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060"
EXACT_REMOTE = "bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec"
EXPECTED_RECIPIENT_HASH = "7d08721bcc02bbef7dae1f07bfde244852560c69d0b72f8dc0fcba0da30c6773"


def p1_model():
    spec = importlib.util.spec_from_file_location("p1_source_owner", P1_SOURCE)
    if not spec or not spec.loader:
        raise RuntimeError("installed acceptance preflight unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def verified_tmpfs() -> bool:
    """Protect plaintext by requiring memory-backed /run and no active swap."""
    try:
        rc = subprocess.run(
            ["findmnt", "-n", "-o", "FSTYPE", "--target", "/run"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, check=False, text=True, timeout=10,
        )
        swaps = Path("/proc/swaps").read_text(encoding="ascii").splitlines()
    except (OSError, subprocess.TimeoutExpired, UnicodeError):
        return False
    return rc.returncode == 0 and rc.stdout.strip() == "tmpfs" and len(swaps) == 1


def filename_guard(directory: Path) -> bool:
    try:
        info = directory.lstat()
        return (stat.S_ISDIR(info.st_mode) and info.st_uid == 0
                and stat.S_IMODE(info.st_mode) == 0o700)
    except OSError:
        return False


def root_private_evidence() -> Path:
    user = os.environ.get("SUDO_USER")
    if user != "ubuntu":
        raise RuntimeError("P2 is limited to the original ubuntu operator")
    home = Path(pwd.getpwnam(user).pw_dir)
    if home.is_symlink() or not home.is_dir():
        raise RuntimeError("unsafe user home")
    base = home / "vwoci-acceptance"
    if base.is_symlink():
        raise RuntimeError("evidence symlink refused")
    if not base.exists():
        base.mkdir(mode=0o700)
    mode = base.lstat()
    if not stat.S_ISDIR(mode.st_mode) or stat.S_IMODE(mode.st_mode) & 0o077:
        raise RuntimeError("evidence directory is not private")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    destination = base / f"p2-cryptographic-readiness-{stamp}-{os.getpid()}"
    destination.mkdir(mode=0o700)
    return destination


class Gate:
    def __init__(self, evidence: Path) -> None:
        self.rows: list[tuple[str, str]] = []
        self.evidence = evidence
        self.blocked = False
        self.crypto_verified = False

    def record(self, state: str, message: str) -> None:
        if state not in {"PASS", "BLOCKED", "PENDING", "NOT RUN"}:
            raise ValueError("invalid gate status")
        if "\n" in message or "\r" in message:
            raise ValueError("multiline message not allowed")
        self.rows.append((state, message))
        self.blocked = self.blocked or state == "BLOCKED"

    def finish(self) -> int:
        status = "BLOCKED" if self.blocked else "VERIFIED" if self.crypto_verified else "PENDING"
        self.rows.append((status, "P2 cryptographic rehearsal; no live restore was attempted"))
        summary = "Gate P2 — original Box .vwrec independent decryption (no restore)\n" + "\n".join(
            f"{state:<8} {message}" for state, message in self.rows) + "\n"
        )
        (self.evidence / "summary.txt").write_text(summary, encoding="utf-8")
        print(summary, end="")
        print("Private evidence:", self.evidence)
        print("Paste only this summary. Never paste raw errors, vault contents, key, ZIP passphrase or secrets.")
        return 2 if self.blocked else 0


def stream_exact_ciphertext(
    destination: Path, *,
    argv: tuple[str, ...] = ("rclone", "cat", EXACT_REMOTE, "--retries", "1"),
    env: dict[str, str] | None = None,
    max_bytes: int = MAX_ARCHIVE_BYTES,
    timeout_seconds: int = MAX_READ_SECONDS,
) -> tuple[str, int]:
    """Bounded Box read to tmpfs; no streaming to a persistent filesystem."""
    if max_bytes <= 0 or timeout_seconds <= 0 or destination.exists() or destination.is_symlink():
        raise ValueError("invalid private download destination or limits")
    if not filename_guard(destination.parent):
        raise ValueError("private download destination is not a safe root directory")
    fd = os.open(
        destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    process: subprocess.Popen[bytes] | None = None
    digest = hashlib.sha256()
    size = 0
    try:
        with os.fdopen(fd, "wb") as output:
            process = subprocess.Popen(
                list(argv), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, cwd="/", env=env,
            )
            deadline = time.monotonic() + timeout_seconds
            if process.stdout is None:
                raise RuntimeError("missing ciphertext stream")
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("remote ciphertext timeout")
                readable, _, _ = select.select([process.stdout], [], [], remaining)
                if not readable:
                    raise TimeoutError("remote ciphertext timeout")
                piece = os.read(process.stdout.fileno(), 1024 * 1024)
                if not piece:
                    break
                size += len(piece)
                if size > max_bytes:
                    raise ValueError("remote archive is outside the approved size limit")
                digest.update(piece)
                output.write(piece)
            remaining = deadline - time.monotonic()
            if remaining <= 0 or process.wait(timeout=remaining) != 0:
                raise RuntimeError("ciphertext readback failed")
        if size == 0:
            raise ValueError("remote object is empty")
        return digest.hexdigest(), size
    finally:
        if process is not None:
            if process.poll() is None:
                process.kill()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
            if process.stdout is not None:
                process.stdout.close()
        # Failed partial files are removed by the caller's tmpfs context as well.


def sqlite_snapshot_integrity(db: Path) -> bool:
    """Read only, no WAL/journal creation, and never expose database rows."""
    try:
        info = db.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size < 100:
            return False
        uri = "file:" + quote(str(db), safe="/") + "?mode=ro&immutable=1"
        con = sqlite3.connect(uri, uri=True, timeout=5)
        try:
            check = con.execute("PRAGMA integrity_check").fetchall()
            count = con.execute("SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()
            return check == [("ok",)] and isinstance(count, tuple) and count[0] > 0
        finally:
            con.close()
    except (OSError, sqlite3.Error, ValueError, TypeError):
        return False


def preview_policy(config: object) -> tuple[bool, bool, int, int]:
    """Report booleans/numerics only; never print domains, tokens or contacts."""
    remote = getattr(config, "offsite_remote", None)
    local = getattr(config, "local_retention_days", None)
    offsite = getattr(config, "remote_retention_days", None)
    if not (remote is None or isinstance(remote, str)):
        raise ValueError("invalid recovered remote policy")
    if type(local) is not int or type(offsite) is not int or local < 0 or offsite < 0:
        raise ValueError("invalid recovered retention")
    return bool(remote), bool(local or offsite), local, offsite


def main() -> int:
    if os.geteuid() != 0 or sys.argv[1:]:
        print("BLOCKED: use sudo -n as ubuntu, no script arguments", file=sys.stderr)
        return 2
    try:
        evidence = root_private_evidence()
    except (OSError, KeyError, RuntimeError):
        print("BLOCKED: private P2 evidence directory cannot be created", file=sys.stderr)
        return 2
    gate = Gate(evidence)
    try:
        if platform.node().split(".")[0] != HOST or platform.machine() not in {"aarch64", "arm64"}:
            gate.record("BLOCKED", "Unexpected host/architecture")
            return gate.finish()
        gate.record("PASS", "Approved disposable Ubuntu ARM64 acceptance host")

        if not CURRENT.is_symlink() or CURRENT.resolve(strict=True) != INSTALLED:
            gate.record("BLOCKED", "Unexpected installed release selection; no recovery attempted")
            return gate.finish()
        p1 = p1_model()
        if not p1.release_integrity(SOURCE, INSTALLED)[0] or not p1.systemd_unit_integrity(INSTALLED)[0]:
            gate.record("BLOCKED", "Immutable release or installed systemd definitions diverge")
            return gate.finish()
        gate.record("PASS", "Exact rc.12 release and systemd integrity match source")

        # Import product owner only from immutable installed release.
        sys.path.insert(0, str(INSTALLED))
        from vaultwarden_oci import recovery, recovery_ux, runtime, secrets, storage
        info = storage.verify()
        if info.uuid != p1.EXPECTED_VOLUME_UUID or p1.EXPECTED_BYID.resolve(strict=True) != Path(info.source).resolve(strict=True):
            gate.record("BLOCKED", "Original independent data volume or dual markers mismatched")
            return gate.finish()
        gate.record("PASS", "Original mounted volume, UUID, by-id and dual markers verified")

        statuses = {unit: p1.service_properties(unit) for unit in p1.UNITS}
        if any(state is None for state in statuses.values()) or not p1.stopped_units(statuses):
            gate.record("BLOCKED", "Application/DNS/timer isolation changed; preserve host")
            return gate.finish()
        if (STATE / "state/update-recovery-required.json").exists():
            gate.record("BLOCKED", "Recovery-required update guard present")
            return gate.finish()
        if p1.daemon_running(p1.service_properties("docker.service")):
            rc, ids = p1.run_readonly([
                "docker", "ps", "--filter", "name=^vaultwarden-oci-",
                "--format", "{{.ID}}"], timeout=20,
            )
            if rc != 0 or bool(ids.strip()):
                gate.record("BLOCKED", "Docker appliance containers are running or cannot be inspected")
                return gate.finish()
        gate.record("PASS", "No active application/timers/DNS or unexpected running appliance containers")

        config = runtime.load_config()
        if not p1.matches_offline_recipient(config.offline_recovery_recipient):
            gate.record("BLOCKED", "Offline public recipient differs from historical accepted recovery custody")
            return gate.finish()
        secrets.validate_custody(config.offline_recovery_recipient)
        if not p1.backup_policy_safe(config.offsite_remote, config.local_retention_days, config.remote_retention_days):
            gate.record("BLOCKED", "Pre-restore publication/retention unexpectedly enabled")
            return gate.finish()
        gate.record("PASS", "Source offline public recipient, SOPS custody, and no-publish/no-prune policy match")
        rc, remotes = p1.run_readonly(["rclone", "listremotes"], timeout=15)
        if not p1.remote_available(remotes, rc):
            gate.record("PENDING", "Root's Box remote unavailable; configure without sharing credentials")
            return gate.finish()
        gate.record("PASS", "Root's Box remote configured; existing remote object will only be read")

        if not verified_tmpfs():
            gate.record("BLOCKED", "No safe swap-free /run tmpfs confirmed; refuse to stage vault plaintext")
            return gate.finish()
        gate.record("PASS", "Swap-free memory-backed /run confirmed before protected plaintext staging")

        if not sys.stdin.isatty() or not sys.stdout.isatty():
            gate.record("PENDING", "Interactive TTY required for protected Age identity chooser")
            return gate.finish()
        # Abort/cancel paths unwind both the product identity context and tmpfs.
        def on_terminate(signum, frame):
            raise KeyboardInterrupt()
        signal.signal(signal.SIGTERM, on_terminate)

        with tempfile.TemporaryDirectory(prefix="vwoci-p2-", dir="/run") as transient:
            private = Path(transient)
            os.chmod(private, 0o700)
            if not filename_guard(private):
                gate.record("BLOCKED", "Temporary root-only memory workspace failed validation")
                return gate.finish()
            artifact = private / "original-encrypted.vwrec"
            try:
                sha, size = stream_exact_ciphertext(
                    artifact, env=p1.root_command_env()
                )
            except (OSError, RuntimeError, ValueError, subprocess.SubprocessError, TimeoutError):
                gate.record("PENDING", "Box ciphertext transfer failed or timed out (private errors withheld)")
                return gate.finish()
            if sha != EXPECTED_ARCHIVE_SHA:
                gate.record("BLOCKED", "Box object checksum differs from independently pinned A3/A4 archive")
                return gate.finish()
            gate.record("PASS", f"Remote Box .vwrec independently downloaded to tmpfs and SHA-256 matched ({size} bytes)")
            if size > MAX_ARCHIVE_BYTES:
                gate.record("BLOCKED", "Unexpected archive size")
                return gate.finish()

            if shutil.which("7zz") is None:
                gate.record("PENDING", "7zz not installed: encrypted ZIP chooser unavailable; secure paste/file selection remains supported")
            print("\nOFFLINE IDENTITY: choose 1 for hidden AGE-SECRET-KEY paste, 2 for a protected identity file,")
            print("or 4 for an encrypted ZIP at an absolute path (if available on this VM).")
            print("To skip decryption safely choose q. Never paste private material back into chat.")
            try:
                with recovery_ux.acquire_offline_identity(
                    config.offline_recovery_recipient,
                    sensitive_root=private,
                    ui=recovery_ux.UI(color=False),
                ) as identity:
                    if identity is None:
                        gate.record("PENDING", "Offline Age identity not supplied; encrypted backup bytes validated only")
                        return gate.finish()
                    gate.record("PASS", "Offline private Age identity matches historical public recipient (private value withheld)")
                    extracted = private / "decrypted"
                    extracted.mkdir(mode=0o700)
                    try:
                        manifest = recovery._decrypt_and_validate(
                            artifact, identity, extracted, runner=recovery.run_command,
                        )
                        recovered_config, recipient = recovery._validate_offline_sops(
                            extracted / "payload", identity, runner=recovery.run_command,
                        )
                        if recipient != config.offline_recovery_recipient:
                            raise ValueError("recovered recipient mismatch")
                    except (recovery.RecoveryError, OSError, ValueError):
                        gate.record("BLOCKED", "Age decryption, manifest/checksums or recovered SOPS custody failed (details withheld)")
                        return gate.finish()
                    gate.record("PASS", "Offline Age decryption, manifest format 2, payload hashes and recovered SOPS custody verified")

                    if not sqlite_snapshot_integrity(extracted / "payload/data/db.sqlite3"):
                        gate.record("BLOCKED", "Recovered SQLite snapshot fails read-only integrity check")
                        return gate.finish()
                    gate.record("PASS", "Recovered SQLite database passed full PRAGMA integrity_check")

                    try:
                        enabled, pruning, local_days, remote_days = preview_policy(recovered_config)
                        recovery._preflight_targets(recovery.RecoveryPaths(), extracted)
                    except (recovery.RecoveryError, OSError, ValueError):
                        gate.record("BLOCKED", "Restore target/capacity or recovered backup policy preflight failed")
                        return gate.finish()
                    gate.record("PASS", "Product restore-target paths and free-space preflight accepted (no promotion)")
                    gate.record("PENDING", f"Recovered backup policy: offsite_configured={enabled} retention_local_days={local_days} retention_remote_days={remote_days}; review before starting timers")
                    if pruning:
                        gate.record("PENDING", "Positive recovered retention: future backup could prune old files; keep timers disabled")
                    gate.record("NOT RUN", "No persistent .vwrec/state write, RESTORE promotion, service start, Cloudflare/DNS, mail, timer or reboot")
                    gate.record("PENDING", "Original encrypted ZIP/private key and passphrase must still be retained in independent off-host custody")
                    gate.crypto_verified = True
            except KeyboardInterrupt:
                gate.record("PENDING", "Operator interrupted secure identity/verification workflow; cleaned temporary memory staging")
            except Exception:
                gate.record("BLOCKED", "Offline identity or recovery verification failed; private exception details withheld")
        return gate.finish()
    except KeyboardInterrupt:
        gate.record("PENDING", "Operator interrupted; no persistent recovery staging authorized")
        return gate.finish()
    except Exception:
        gate.record("BLOCKED", "Host/recovery preflight raised an exception; details withheld")
        return gate.finish()


if __name__ == "__main__":
    raise SystemExit(main())
