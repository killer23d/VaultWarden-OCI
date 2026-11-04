#!/usr/bin/env python3
"""P8M: batched VM-only source Age/manifest/SQLite proof, optional stopped restore.

Test DISPOSABLE NEW ARM64 VM only, immutable rc.12 installed. Uses original
independently pinned Box ciphertext (never auto-selects newer filenames).
Tests two newer same-parent candidates separately as UNTRUSTED observations.
All pre-restore ciphertext/decrypted material in /run tmpfs, no swap.
If --restore-disposable and supplied private identity work, optionally promotes
ONLY historical pinned backup via installed recovery.restore_recovery(start=False).
The existing product temporarily stages plaintext under dedicated ext4 during
promotion: test-only residual-at-rest risk; no automatic wipe is promised.

Never uploads/prunes Box, reads original VM, changes public DNS/Worker/ACME,
sends SMTP, starts Caddy/Vaultwarden/timers or publishes production service.
No repeated destructive consent prompt: exact --restore-disposable plus
operator's existing new-VM test authorization. OFFLINE secret requires the
installed product's hidden SSH input/ZIP chooser, never argv/chat/logs.
"""
from __future__ import annotations

import contextlib
import datetime as dt
import hashlib
import importlib.util
import json
import os
import platform
import pwd
import re
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

HOST = "vaultwarden-oci-7-vnic"
BRANCH = "audit/rc12-p8m-batched-crypto-restore-newvm"
VERSION = "0.1.0-rc.12"
SOURCE = Path(__file__).resolve().parents[2]
INSTALLED = Path("/opt/vaultwarden-oci/releases") / VERSION
CURRENT = Path("/opt/vaultwarden-oci/current")
STATE = Path("/var/lib/vaultwarden-oci")
CONFIG = Path("/etc/vaultwarden-oci/config.toml")
P1 = SOURCE / "tests/host-acceptance/production-recovery-source-preflight.py"
P8LR_SHA = "24e9c03cc177dda6464f936eed9a40b95b46a4e3"
P8LR_DIR = "p8l-box-source-20261104T231320Z-4952"
ATTEMPT = "p8m-one-shot-disposable-restore-attempt.json"
ORIGINAL_REMOTE = "bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec"
ORIGINAL_SHA = "ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060"
ORIGINAL_BYTES = 358680
RECIPIENT_SHA = "7d08721bcc02bbef7dae1f07bfde244852560c69d0b72f8dc0fcba0da30c6773"
VOLUME_UUID_FINGERPRINT = "2449f67320a1"
DOMAIN = "bw.lazymocha.com"
EMAIL = "bw@lazymocha.com"
SHA40 = re.compile(r"[0-9a-f]{40}\Z")
SHA64 = re.compile(r"[0-9a-f]{64}\Z")
SAFE_REMOTE = re.compile(r"bw-backup:bw-backup/(?:[A-Za-z0-9._/-]+/)?recovery-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\.vwrec\Z")
MAX_ARCHIVE = 16 * 1024**2
MAX_READ_SECONDS = 600
MIN_VOL_FREE = 5 * 1024**3


class Blocked(RuntimeError):
    pass


def hash12(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def root_environment() -> dict[str, str]:
    result = {k: v for k, v in os.environ.items() if not k.startswith("RCLONE_")}
    result["HOME"] = "/root"
    result["XDG_CONFIG_HOME"] = "/root/.config"
    return result


def command(argv: list[str], *, timeout: int = 15) -> tuple[int | None, str]:
    try:
        process = subprocess.run(
            argv, cwd="/", env=root_environment() if argv[0] == "rclone" else None,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    if len(process.stdout) > 1024 * 1024:
        return None, ""
    return process.returncode, process.stdout.decode("utf-8", "replace")


def pinned_checkout(sha: str) -> bool:
    if not SHA40.fullmatch(sha):
        return False
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat")
    results = []
    for args in (("rev-parse", "HEAD"), ("branch", "--show-current"),
                 ("status", "--porcelain", "--untracked-files=all")):
        try:
            process = subprocess.run(
                ["/usr/bin/git", *args], cwd=SOURCE, env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=20, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        if process.returncode != 0 or len(process.stdout) > 8192:
            return False
        results.append(process.stdout.decode("utf-8", "replace").strip())
    return results == [sha, BRANCH, ""]


def guest_ok() -> bool:
    if (platform.node().split(".", 1)[0] != HOST or
            platform.machine() not in ("aarch64", "arm64") or
            sys.version_info[:2] != (3, 14)):
        return False
    try:
        facts = {}
        for row in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
            if "=" in row:
                k, v = row.split("=", 1)
                facts[k] = v.strip('"')
        import tomllib
        with (SOURCE / "versions.toml").open("rb") as f:
            version = tomllib.load(f)["vaultwarden_oci"]["version"]
    except Exception:
        return False
    return (facts.get("ID") == "ubuntu" and facts.get("VERSION_ID") == "26.04"
            and facts.get("VERSION_CODENAME") == "resolute" and version == VERSION)


def private_dir(path: Path, *, owner: set[int]) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    return (stat.S_ISDIR(info.st_mode) and info.st_uid in owner
            and stat.S_IMODE(info.st_mode) == 0o700)


def private_read(path: Path, max_size: int = 128 * 1024) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    with os.fdopen(fd, "rb") as f:
        meta = os.fstat(f.fileno())
        if (not stat.S_ISREG(meta.st_mode) or meta.st_uid != 0
                or stat.S_IMODE(meta.st_mode) != 0o600
                or not 0 < meta.st_size <= max_size):
            raise Blocked("historical root-private acceptance evidence unsafe")
        return f.read(max_size + 1)


def evidence_root() -> Path:
    account = pwd.getpwnam("ubuntu")
    home = Path(account.pw_dir)
    if home.is_symlink() or not home.is_dir():
        raise Blocked("operator home unavailable")
    base = home / "vwoci-acceptance"
    if not private_dir(base, owner={0, account.pw_uid}):
        raise Blocked("original root-private evidence directory unavailable")
    return base


def source_candidates(base: Path) -> list[dict[str, object]]:
    prior = base / P8LR_DIR
    if not private_dir(prior, owner={0}):
        raise Blocked("accepted P8L-R private evidence missing")
    text = private_read(prior / "summary.txt").decode("utf-8", "replace").splitlines()
    markers = (
        "Gate P8L - batched remote encrypted recovery source integrity (READ-ONLY)",
        "PASS       Previous P8K Box readback and original independent historical SHA+358680 bytes",
        "PASS       Box recovery filenames=9, safe encrypted candidates=8, newer safe by filename date=2",
        "PENDING    Untrusted Box fixtures QUARANTINED=1: path=0 type=0 size_missing=0 tiny=1 oversize=0",
        "PASS       Candidate rank=3 name_date=20261029T223200Z",
        "PASS       Encrypted recovery object streams age-header and SHA reviewed=8/8",
        "HOLD       P8L READ-ONLY remote set survey",
    )
    if (not all(any(line.startswith(key) for line in text) for key in markers)
            or any(line.startswith("BLOCKED") for line in text)):
        raise Blocked("P8L-R accepted read-only HOLD absent or changed")
    raw = json.loads(private_read(prior / "candidates.private.json"))
    if (not isinstance(raw, dict) or raw.get("schema") != 1 or
            raw.get("source_sha") != P8LR_SHA or
            raw.get("purpose") != "UNTRUSTED_BOX_READ_ONLY_CIPHERTEXT_OBSERVATIONS" or
            raw.get("original_historical_pin") != ORIGINAL_REMOTE or
            raw.get("no_restore_consent") is not True):
        raise Blocked("P8L-R private candidate provenance inconsistent")
    rows = raw.get("records")
    if not isinstance(rows, list) or len(rows) != 8:
        raise Blocked("P8L-R safe candidate inventory changed")
    seen: set[str] = set()
    results: list[dict[str, object]] = []
    for entry in rows:
        if not isinstance(entry, dict):
            raise Blocked("P8L-R unsafe candidate structure")
        remote, sha = entry.get("remote"), entry.get("sha256")
        size, date = entry.get("streamed_bytes"), entry.get("name_date")
        status = entry.get("status")
        if (not isinstance(remote, str) or not SAFE_REMOTE.fullmatch(remote)
                or any(p in ("", ".", "..") for p in remote.removeprefix("bw-backup:bw-backup/").split("/"))
                or remote in seen or not isinstance(sha, str)
                or not SHA64.fullmatch(sha) or size != ORIGINAL_BYTES
                or not isinstance(date, str) or
                status not in ("PIN_MATCH", "NEW_OBSERVATION_ONLY")):
            raise Blocked("P8L-R validated candidate source safety mismatch")
        seen.add(remote)
        if remote == ORIGINAL_REMOTE:
            if sha != ORIGINAL_SHA or status != "PIN_MATCH":
                raise Blocked("original independently pinned ciphertext mismatch")
        elif status == "PIN_MATCH":
            raise Blocked("newer candidate falsely described as independently pinned")
        if entry.get("same_parent_as_historical") is True and remote != ORIGINAL_REMOTE:
            if date > "20261029T223200Z":
                results.append(entry)
    trusted = [e for e in rows if e.get("remote") == ORIGINAL_REMOTE]
    if len(trusted) != 1 or len(results) != 2:
        raise Blocked("original backup plus two newer same-parent candidates not found")
    results.sort(key=lambda obj: str(obj["name_date"]), reverse=True)
    return [trusted[0], *results]


def stopped_local() -> tuple[object, object]:
    if not CURRENT.is_symlink() or CURRENT.resolve(strict=True) != INSTALLED:
        raise Blocked("installed immutable rc.12 pointer changed")
    if str(INSTALLED) not in sys.path:
        sys.path.insert(0, str(INSTALLED))
    from vaultwarden_oci import install, runtime, secrets, storage
    p1_spec = importlib.util.spec_from_file_location("p8m_immutable_release_witness", P1)
    if not p1_spec or not p1_spec.loader:
        raise Blocked("original release-integrity owner unavailable")
    p1 = importlib.util.module_from_spec(p1_spec)
    p1_spec.loader.exec_module(p1)
    if not p1.release_integrity(SOURCE, INSTALLED)[0]:
        raise Blocked("installed immutable rc.12 bytes no longer match original release")
    if not p1.systemd_unit_integrity(INSTALLED)[0]:
        raise Blocked("12 installed systemd unit bytes/ownership differ")
    proof = storage.verify()
    storage.reject_boot_related(proof.source)
    if (proof.fs_type != "ext4" or hash12(proof.uuid) != VOLUME_UUID_FINGERPRINT
            or os.stat(STATE).st_dev == os.stat("/").st_dev):
        raise Blocked("original new-VM dedicated ext4 disk/markers changed")
    cfg = runtime.load_config()
    if (cfg.domain != DOMAIN or cfg.acme_email != EMAIL
            or hashlib.sha256(cfg.offline_recovery_recipient.encode()).hexdigest() != RECIPIENT_SHA
            or cfg.offsite_remote is not None or
            type(cfg.local_retention_days) is not int or
            type(cfg.remote_retention_days) is not int or
            cfg.local_retention_days or cfg.remote_retention_days):
        raise Blocked("configured original public recipient/test hostname/no-Box policy changed")
    secrets.validate_custody(cfg.offline_recovery_recipient)
    if len(install.SYSTEMD_UNITS) != 12 or "vaultwarden-oci-notify@.service" not in install.SYSTEMD_UNITS:
        raise Blocked("installed unit registry differs")
    for unit in install.SYSTEMD_UNITS:
        if unit == "vaultwarden-oci-notify@.service":
            continue
        code, raw = command(["/usr/bin/systemctl", "show", unit, "--no-pager",
                             "-p", "LoadState", "-p", "ActiveState", "-p", "UnitFileState"])
        data = dict(x.split("=", 1) for x in raw.splitlines() if "=" in x)
        if (code != 0 or data.get("LoadState") != "loaded"
                or data.get("ActiveState") != "inactive"
                or data.get("UnitFileState") in
                ("enabled", "enabled-runtime", "linked", "linked-runtime")):
            raise Blocked("application/timer service is unexpectedly active/enabled")
    code, raw = command(["/usr/bin/systemctl", "list-units", "--all", "--no-legend",
                         "--plain", "--no-pager", "--full", "vaultwarden-oci-notify@*.service"])
    if code != 0 or raw.strip():
        raise Blocked("unexpected instantiated notification unit")
    code, raw = command(["/usr/bin/systemctl", "list-unit-files", "--all",
                         "--no-legend", "--no-pager", "--plain",
                         "vaultwarden-oci-notify@*.service"])
    if code != 0 or [x.split()[:2] for x in raw.splitlines()] != [
        ["vaultwarden-oci-notify@.service", "static"]
    ]:
        raise Blocked("installed static notify template status changed")
    code, raw = command(["/usr/bin/ss", "-H", "-lnt"])
    if code != 0:
        raise Blocked("listener inventory unavailable")
    for line in raw.splitlines():
        columns = line.split()
        found = re.search(r":(\d{1,5})$", columns[3]) if len(columns) >= 5 else None
        if found is None or int(found.group(1)) in (80, 443, 2375, 2376):
            raise Blocked("untrusted public HTTP or Docker TCP listener")
    meta = Path("/var/lib/docker/containers")
    if meta.exists() or meta.is_symlink():
        if meta.is_symlink() or not meta.is_dir() or any(meta.iterdir()):
            raise Blocked("unexpected retained Docker container")
    for name in ("db.sqlite3", "db.sqlite3-wal", "db.sqlite3-shm"):
        candidate = STATE / "data" / name
        if candidate.exists() or candidate.is_symlink():
            raise Blocked("pre-restore SQLite database already present")
    if (STATE / "state/update-recovery-required.json").exists():
        raise Blocked("update-recovery-required guard exists")
    backups = STATE / "backups"
    if backups.exists() or backups.is_symlink():
        try:
            info = backups.lstat()
            if (not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or
                    stat.S_IMODE(info.st_mode) != 0o700 or
                    info.st_dev != os.stat(STATE).st_dev or any(backups.iterdir())):
                raise Blocked("dedicated backup staging path no longer pristine")
        except OSError as exc:
            raise Blocked("dedicated backup path inaccessible") from exc
    if shutil.disk_usage(STATE).free < MIN_VOL_FREE:
        raise Blocked("insufficient dedicated disk space for test restoration")
    code, kind = command(["/usr/bin/findmnt", "-n", "-o", "FSTYPE", "--target", "/run"])
    try:
        swaps = Path("/proc/swaps").read_text(encoding="ascii").splitlines()
    except OSError as exc:
        raise Blocked("swap inventory unreadable") from exc
    if code != 0 or kind.strip() != "tmpfs" or len(swaps) != 1 or not swaps[0].startswith("Filename"):
        raise Blocked("protected /run tmpfs or swap-free condition failed")
    if shutil.disk_usage("/run").free < 64 * 1024**2:
        raise Blocked("not enough volatile tmpfs capacity")
    try:
        info = Path("/root/.config/rclone/rclone.conf").lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) != 0o600):
            raise Blocked("root's existing rclone Box config not private")
    except OSError as exc:
        raise Blocked("root's existing rclone Box config unavailable") from exc
    code, raw = command(["rclone", "listremotes"], timeout=20)
    if code != 0 or "bw-backup:" not in raw.splitlines():
        raise Blocked("root's existing Box read-only remote unavailable")
    return cfg, proof


def stream_tmpfs(remote: str, dest: Path, expected_sha: str) -> int:
    """Read only the exact already-hashed ciphertext object into protected /run."""
    if (not SAFE_REMOTE.fullmatch(remote) or
            any(p in ("", ".", "..") for p in remote.removeprefix("bw-backup:bw-backup/").split("/"))
            or not SHA64.fullmatch(expected_sha)):
        raise Blocked("unsafe remote read request")
    if dest.exists() or dest.is_symlink() or not private_dir(dest.parent, owner={0}):
        raise Blocked("private volatile destination unsafe")
    filefd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                     getattr(os, "O_NOFOLLOW", 0), 0o600)
    process = None
    total = 0
    sha = hashlib.sha256()
    try:
        with os.fdopen(filefd, "wb") as file:
            process = subprocess.Popen(
                ["rclone", "cat", remote, "--retries", "1"],
                cwd="/", env=root_environment(), stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            )
            deadline = time.monotonic() + MAX_READ_SECONDS
            if process.stdout is None:
                raise Blocked("remote ciphertext pipe unavailable")
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise Blocked("Box ciphertext read exceeded timeout")
                readable, _, _ = select.select([process.stdout], [], min(remaining, 90))
                if not readable:
                    raise Blocked("Box ciphertext stream stalled")
                block = os.read(process.stdout.fileno(), 1024 * 1024)
                if not block:
                    break
                total += len(block)
                if total > MAX_ARCHIVE or total > ORIGINAL_BYTES:
                    raise Blocked("Box ciphertext beyond approved size")
                sha.update(block)
                file.write(block)
            if (process.wait(timeout=max(0.001, deadline - time.monotonic())) != 0
                    or total != ORIGINAL_BYTES or sha.hexdigest() != expected_sha):
                raise Blocked("Box ciphertext no longer matches pinned independent SHA/bytes")
            file.flush()
            os.fsync(file.fileno())
        return total
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


def sqlite_readonly(db: Path) -> tuple[bool, str]:
    try:
        info = db.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size < 100:
            return False, ""
        uri = "file:" + quote(str(db), safe="/") + "?mode=ro&immutable=1"
        conn = sqlite3.connect(uri, uri=True, timeout=5)
        try:
            integrity = conn.execute("PRAGMA integrity_check").fetchall()
            count = conn.execute("SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()
            if integrity != [("ok",)] or not count or count[0] < 1:
                return False, ""
        finally:
            conn.close()
        return True, hashlib.sha256(db.read_bytes()).hexdigest()
    except (OSError, sqlite3.Error, TypeError, ValueError):
        return False, ""


def docker_ready() -> bool:
    code, status = command(["/usr/bin/systemctl", "show", "docker.service",
                            "-p", "ActiveState", "-p", "LoadState", "--no-pager"])
    fields = dict(x.split("=", 1) for x in status.splitlines() if "=" in x)
    if code != 0 or fields.get("ActiveState") != "active" or fields.get("LoadState") != "loaded":
        return False
    code, running = command(["/usr/bin/docker", "ps", "--format", "{{.ID}}"], timeout=20)
    return code == 0 and not running.strip()


def private_write(path: Path, content: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                 getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "wb") as file:
        file.write(content)
        file.flush()
        os.fsync(file.fileno())


class Report:
    def __init__(self, folder: Path) -> None:
        self.folder = folder
        self.rows: list[tuple[str, str]] = []
        self.blocked = False
        self.restore_invoked = False
        self.restored = False
        self.postverified = False
        self.crypto_verified = False
        self.source = ""

    def row(self, status: str, line: str) -> None:
        if (status not in ("PASS", "PENDING", "NOT RUN", "BLOCKED")
                or len(line) > 260 or any(x in line for x in "\r\n\x00")):
            raise ValueError("unsafe summary output")
        self.rows.append((status, line))
        self.blocked |= status == "BLOCKED"

    def finish(self) -> int:
        if self.blocked or self.restore_invoked and not self.postverified:
            state, code = "BLOCKED", 2
        elif self.restore_invoked and self.restored and self.postverified:
            state, code = "RESTORED", 0
        elif self.crypto_verified:
            state, code = "VERIFIED", 0
        else:
            state, code = "HOLD", 0
        if self.restore_invoked and not self.postverified:
            self.rows.append(("BLOCKED", "Restore owner WAS INVOKED: uncertain partial state; preserve VM and never automatically retry"))
        self.rows.append((state, "P8M VM-only cryptographic candidate validation and bounded original restore; NO live/Box-write/production GO"))
        data = "Gate P8M - NEW VM batched crypto verification and optional stopped-only restore\n"
        data += "\n".join(f"{kind:<10} {message}" for kind, message in self.rows) + "\n"
        private_write(self.folder / "summary.txt", data.encode("utf-8"))
        print(data, end="")
        print("Private summary:", self.folder / "summary.txt")
        print("Paste sanitized summary and P8M_EXIT; no offline Age PRIVATE key, ZIP/passphrase, credentials or plaintext.")
        return code


def postrestore(expected_sha: str, expected_recipient: str) -> tuple[bool, str]:
    """Inspect recovered data without spawning application or external connections."""
    from vaultwarden_oci import runtime, secrets, storage
    try:
        proof = storage.verify()
        storage.reject_boot_related(proof.source)
        if hash12(proof.uuid) != VOLUME_UUID_FINGERPRINT:
            return False, "postrestore disk identity changed"
        cfg = runtime.load_config()
        if (cfg.domain != DOMAIN or cfg.acme_email != EMAIL
                or cfg.offline_recovery_recipient != expected_recipient
                or cfg.local_retention_days != 0 or cfg.remote_retention_days != 0):
            return False, "recovered hostname/offline recipient/backup retention unsafe"
        secrets.validate_custody(cfg.offline_recovery_recipient)
        secret_values = secrets.decrypt()
        del secret_values
        restored_db = STATE / "data/db.sqlite3"
        valid, digest = sqlite_readonly(restored_db)
        if not valid or digest != expected_sha:
            return False, "restored SQLite integrity or source digest mismatch"
        for name in ("vaultwarden-oci.target", "vaultwarden-oci.service",
                     "vaultwarden-oci-health.timer", "vaultwarden-oci-backup.timer",
                     "vaultwarden-oci-maintenance.timer", "vaultwarden-oci-update-check.timer",
                     "vaultwarden-oci-dns.service"):
            code, raw = command(["/usr/bin/systemctl", "show", name,
                                 "--no-pager", "-p", "ActiveState", "-p", "UnitFileState"])
            state = dict(x.split("=", 1) for x in raw.splitlines() if "=" in x)
            if (code != 0 or state.get("ActiveState") != "inactive"
                    or state.get("UnitFileState") in ("enabled", "enabled-runtime")):
                return False, "postrestore application/timers/DNS state unexpectedly active"
        code, ports = command(["/usr/bin/ss", "-H", "-lnt"])
        if code != 0:
            return False, "postrestore listener inventory unavailable"
        for line in ports.splitlines():
            words = line.split()
            match = re.search(r":(\d{1,5})$", words[3]) if len(words) >= 5 else None
            if match is None or int(match.group(1)) in (80, 443):
                return False, "postrestore HTTP listener unexpectedly activated"
        return True, f"Recovered SQLite full integrity/digest, operational SOPS, public recipient, stopped services/DNS/timers; offsite_configured={cfg.offsite_remote is not None}"
    except Exception:
        return False, "postrestore local custody or integrity verification failed (private details withheld)"


def main() -> int:
    arguments = sys.argv[1:]
    restore = False
    if len(arguments) == 3 and arguments[-1] == "--restore-disposable":
        restore = True
        arguments = arguments[:-1]
    if (len(arguments) != 2 or arguments[0] != "--expected-commit"
            or not SHA40.fullmatch(arguments[1]) or os.geteuid() != 0
            or os.environ.get("SUDO_USER") != "ubuntu"
            or platform.node().split(".", 1)[0] != HOST):
        print("BLOCKED: must sudo -n as ubuntu on exact new disposable host with pinned commit")
        return 2
    if not pinned_checkout(arguments[1]) or not guest_ok():
        print("BLOCKED: exact clean reviewed source, Ubuntu 26.04 ARM64/rc.12 mismatch")
        return 2
    try:
        base = evidence_root()
        folder = base / ("p8m-crypto-and-restore-" +
                         dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") +
                         f"-{os.getpid()}")
        folder.mkdir(mode=0o700)
    except Exception:
        print("BLOCKED: root-private acceptance evidence unavailable")
        return 2
    report = Report(folder)
    stage = "original P8L-R accepted evidence"
    saved_signals = {s: signal.getsignal(s) for s in
                     (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        selected = source_candidates(base)
        report.row("PASS", "Original P8L-R HOLD/8 safe ciphertext SHA streams, two newer same-parent observations and trusted historical pin intact")
        stage = "immutable rc.12, dedicated storage and stopped service proof"
        cfg, volume = stopped_local()
        report.row("PASS", "Exact immutable 52 product files/12 units, dedicated ext4 and original PUBLIC Age recipient verified; 11 units stopped")
        report.row("PASS", "No HTTP80/443, Docker containers, SQLite, swap, unexpected backup stage; /run tmpfs and backup publication disabled")
        report.row("PASS", "Root Box remote available; source is the trusted October 29 ciphertext, not newest filename")
        if restore and (base / ATTEMPT).exists():
            raise Blocked("an earlier P8M restore attempt marker already exists; never retry automatically")
        if not (sys.stdin.isatty() and sys.stdout.isatty()):
            report.row("PENDING", "A TTY is required for the hidden offline Age identity/ZIP chooser")
            report.row("NOT RUN", "No Box ciphertext transferred, private key entered, decrypted payload or restore")
            return report.finish()
        stage = "root-only tmpfs ciphertext and private offline Age identity"
        with tempfile.TemporaryDirectory(prefix="vwoci-p8m-", dir="/run") as volatile:
            private = Path(volatile)
            os.chmod(private, 0o700)
            if not private_dir(private, owner={0}):
                raise Blocked("tmpfs root-only workspace could not be secured")
            artifact = private / "historically-pinned.vwrec"
            stream_tmpfs(str(selected[0]["remote"]), artifact, str(selected[0]["sha256"]))
            report.row("PASS", "Original Box ciphertext read into protected /run tmpfs, full 358680-byte independently pinned SHA-256 matched")
            print("\n=== OFFLINE RECOVERY CUSTODY (SSH TTY ONLY) ===")
            print("No keys/passwords are shown or accepted in shell arguments/chat.")
            print("Use hidden private Age identity paste (choice 1), or encrypted ZIP already on this VM (choice 4).")
            print("If unavailable, type q: exit HOLD; no persistent application state is modified.")
            from vaultwarden_oci import recovery, recovery_ux, runtime, secrets
            stage = "interactive private Age identity and verification"
            with recovery_ux.acquire_offline_identity(
                cfg.offline_recovery_recipient, sensitive_root=private,
                ui=recovery_ux.UI(color=False),
            ) as identity:
                if identity is None:
                    report.row("PENDING", "Offline private Age identity/ZIP unavailable; ciphertext integrity verified but cryptographic payload NOT TESTED")
                    report.row("NOT RUN", "No decryption, manifest, SOPS, SQLite or restore")
                    return report.finish()
                if (not identity.resolve(strict=True).is_relative_to(private)
                        or not identity.is_file()
                        or identity.is_symlink()):
                    raise Blocked("private identity must be staged only within protected /run workspace")
                meta = identity.lstat()
                if (meta.st_uid != 0 or stat.S_IMODE(meta.st_mode) != 0o600):
                    raise Blocked("private Age identity root-only mode invalid")
                report.row("PASS", "Original OFFLINE PRIVATE Age identity cryptographically matches original public recipient (value withheld)")
                stage = "manifest/SOPS/SQLite for exact independently pinned original"
                extracted = private / "historical-verified"
                extracted.mkdir(mode=0o700)
                manifest = recovery._decrypt_and_validate(
                    artifact, identity, extracted, runner=recovery.run_command)
                recovered_cfg, recipient = recovery._validate_offline_sops(
                    extracted / "payload", identity, runner=recovery.run_command)
                if recipient != cfg.offline_recovery_recipient:
                    raise Blocked("restored offline PUBLIC Age recipient differs")
                valid, dbsha = sqlite_readonly(extracted / "payload/data/db.sqlite3")
                if not valid:
                    raise Blocked("original candidate SQLite fails read-only full integrity")
                if manifest.get("format_version") != 2:
                    raise Blocked("original candidate manifest format is not supported")
                if (recovered_cfg.domain != DOMAIN or recovered_cfg.acme_email != EMAIL
                        or recovered_cfg.local_retention_days != 0
                        or recovered_cfg.remote_retention_days != 0):
                    raise Blocked("original recovered hostname/backup pruning policy unsafe")
                recovery._preflight_targets(recovery.RecoveryPaths(), extracted)
                report.row("PASS", "Original historical Age decrypt, version-2 manifest/files, SOPS, SQLite full integrity and target capacity verified in tmpfs")
                report.row("PASS", "Recovered historical data SHA fingerprint=" + dbsha[:12] +
                           f"; offsite_configured={recovered_cfg.offsite_remote is not None}, both retention days=0")
                report.row("PENDING", "Other two newer Box ciphertext SHA observations still lack independent source pins; no automatic latest-object promotion")
                stage = "newer same-folder candidate cryptographic checks"
                for rank, candidate in enumerate(selected[1:], 1):
                    subdir = private / f"newer-{rank}"
                    subdir.mkdir(mode=0o700)
                    destination = subdir / "candidate.vwrec"
                    try:
                        stream_tmpfs(str(candidate["remote"]), destination, str(candidate["sha256"]))
                        output = subdir / "extracted"
                        output.mkdir(mode=0o700)
                        candidate_manifest = recovery._decrypt_and_validate(
                            destination, identity, output, runner=recovery.run_command)
                        newer_cfg, newer_recipient = recovery._validate_offline_sops(
                            output / "payload", identity, runner=recovery.run_command)
                        newvalid, newsha = sqlite_readonly(output / "payload/data/db.sqlite3")
                        if (candidate_manifest.get("format_version") != 2
                                or newer_recipient != recipient or not newvalid
                                or newer_cfg.domain != DOMAIN):
                            raise Blocked("newer untrusted candidate crypto or data not applicable")
                        report.row("PASS", f"Newer same-parent candidate {rank}: Age/manifest/SOPS/SQLite valid, db_sha_fp={newsha[:12]}, CIPHERTEXT SOURCE UNTRUSTED")
                    except Exception:
                        report.row("PENDING", f"Newer same-parent candidate {rank}: not independently restorable/compatible; details withheld; original pinned backup remains selected")
                    finally:
                        # All candidates and plaintext are in protected /run tmpfs.
                        pass
                report.crypto_verified = True
                if not restore:
                    report.row("NOT RUN", "No persistent application data restoration: verify-only mode")
                    return report.finish()
                stage = "stopped restore docker and local-state boundary"
                if not docker_ready():
                    report.row("PENDING", "Docker daemon not already available/empty; do not auto-start host networking; cryptographic verification PASS, restore NOT RUN")
                    return report.finish()
                # Recheck the exact pre-restore isolation before any persistent
                # state promotion; original installed product may update only
                # disposable guest application files and not remote Box.
                stopped_local()
                if (base / ATTEMPT).exists() or (base / ATTEMPT).is_symlink():
                    raise Blocked("P8M restore already attempted; no automatic retry")
                report.row("PENDING", "Restoring the original encrypted source will temporarily stage plaintext on NEW disposable UNENCRYPTED dedicated ext4; test data must be securely retired with this VM/disk")
                report.row("PASS", "NEW disposable VM-only restore requested by exact --restore-disposable; no interactive consent phrase required")
                # Exclusive marker precedes product mutation. SIGINT/HUP/TERM
                # deferred during promotion so a parent interrupt cannot
                # skip the owner's exception rollback/final verification.
                private_write(base / ATTEMPT, (json.dumps({
                    "schema": 1, "host": HOST, "reviewed_source": arguments[1],
                    "ciphertext_sha256": ORIGINAL_SHA,
                    "data_uuid_fingerprint": VOLUME_UUID_FINGERPRINT,
                    "attempted_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                }, sort_keys=True) + "\n").encode("utf-8"))
                deferred: list[int] = []
                def defer_interrupt(sig, frame):
                    deferred.append(sig)
                for sig in saved_signals:
                    signal.signal(sig, defer_interrupt)
                report.restore_invoked = True
                stage = "installed product stopped-only restoration (one-shot)"
                restored = recovery.restore_recovery(artifact, identity, start=False)
                report.restored = True
                if restored.get("format_version") != 2:
                    raise Blocked("installed recovery owner returned wrong manifest format")
                report.row("PASS", "Installed immutable rc.12 recovery owner restored exactly original pinned artifact, start=False (one-shot)")
                stage = "postrestore integrity, SOPS, dormant systemd and network"
                okay, note = postrestore(dbsha, recipient)
                report.row("PASS" if okay else "BLOCKED", note)
                if not okay:
                    return report.finish()
                report.row("PASS", "No Box writes/pruning, cloud DNS/Worker updates, SMTP, public app/Caddy start, timers or reboot performed by this acceptance wrapper")
                if deferred:
                    report.row("PENDING", "Operator interrupt deferred during promotion; review guest state before any later activation")
                report.row("PENDING", "Imported recovery configuration may reference historical Box; timers remain disabled and future isolation must be independently verified")
                report.row("PENDING", "Temporary plaintext-on-ext4 remnants are not guaranteed securely erased; securely retire disposable test volume after acceptance")
                report.postverified = True
                return report.finish()
    except KeyboardInterrupt:
        report.row("BLOCKED" if report.restore_invoked else "PENDING",
                   "Interrupted during " + stage + "; possible partial mutation only if restore was invoked")
        return report.finish()
    except Exception:
        report.row("BLOCKED", "P8M validation failure during " + stage +
                   "; private diagnostics withheld; no automatic restore retry")
        return report.finish()
    finally:
        for sig, old in saved_signals.items():
            signal.signal(sig, old)


if __name__ == "__main__":
    raise SystemExit(main())
