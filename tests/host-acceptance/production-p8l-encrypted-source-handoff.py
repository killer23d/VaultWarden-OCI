#!/usr/bin/env python3
"""P8L: read-only encrypted ciphertext handoff after successful P8K batch.

Target NEW disposable OCI ARM64 guest only. Bound to unchanged P8K HOLD and
independently pinned ORIGINAL Box Age ciphertext SHA. Optionally rehash an
operator-copied encrypted .vwrec in an exact private inbox. Never downloads,
decrypts, imports recovery keys, opens a ZIP, mounts/formats, restores,
contacts Box/Cloudflare/OCI or starts/stops service/Docker.
"""
from __future__ import annotations

import ast
import datetime as dt
import hashlib
import json
import os
import platform
import pwd
import re
import stat
import subprocess
import sys
import tomllib
from pathlib import Path
import shutil

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-7-vnic"
BRANCH = "audit/rc12-p8l-encrypted-source-handoff"
VERSION = "0.1.0-rc.12"
P8K_EVIDENCE = "p8k-batched-recovery-20261104T222145Z-4474"
P8K_COMMIT = "e446677fc2c846aa0ac4fb734f7b03729cefad4d"
P8K_MODE = "REMOTE_UNAVAILABLE"
TEST_DOMAIN = "bw.lazymocha.com"
TEST_EMAIL = "bw@lazymocha.com"
SOURCE = Path(__file__).resolve().parents[2]
CURRENT = Path("/opt/vaultwarden-oci/current")
INSTALLED = Path("/opt/vaultwarden-oci/releases") / VERSION
CONFIG = Path("/etc/vaultwarden-oci/config.toml")
STATE = Path("/var/lib/vaultwarden-oci")
BASE_PATH = Path("/home/ubuntu/vwoci-acceptance")
INBOX = Path("/home/ubuntu/vwoci-encrypted-inbox")
ORIGINAL_PIN = SOURCE / "tests/host-acceptance/production-recovery-source-preflight.py"
SHA40 = re.compile(r"[0-9a-f]{40}\Z")
SHA64 = re.compile(r"[0-9a-f]{64}\Z")
REMOTE = re.compile(r"bw-backup:bw-backup/(?:[A-Za-z0-9._-]+/)*recovery-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\.vwrec\Z")
MAX_BYTES = 4 * 1024 ** 3
AGE_HEADER = b"age-encryption.org/v1"
NOTIFY_TEMPLATE = "vaultwarden-oci-notify@.service"
NOTIFY_PATTERN = "vaultwarden-oci-notify@*.service"


class Blocked(RuntimeError):
    pass


def safe_sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]


def run(argv: list[str], timeout: int = 12) -> tuple[int | None, str]:
    try:
        result = subprocess.run(
            argv, cwd="/", stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    if len(result.stdout) > 131072:
        return None, ""
    return result.returncode, result.stdout.decode("utf-8", "replace")


def pinned_checkout(sha: str) -> bool:
    if not SHA40.fullmatch(sha):
        return False
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat")
    results = []
    for args in (("rev-parse", "HEAD"), ("branch", "--show-current"),
                 ("status", "--porcelain", "--untracked-files=all")):
        try:
            proc = subprocess.run(
                ["/usr/bin/git", *args], cwd=SOURCE, env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=18, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        if proc.returncode != 0 or len(proc.stdout) > 8192:
            return False
        results.append(proc.stdout.decode("utf-8", "replace").strip())
    return results == [sha, BRANCH, ""]


def supported_guest() -> bool:
    if (platform.node().split(".", 1)[0] != HOST
            or platform.machine() not in ("aarch64", "arm64")
            or sys.version_info[:2] != (3, 14)):
        return False
    try:
        values = {}
        for row in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
            if "=" in row:
                key, value = row.split("=", 1)
                values[key] = value.strip('"')
        with (SOURCE / "versions.toml").open("rb") as stream:
            current = tomllib.load(stream)["vaultwarden_oci"]["version"]
    except (OSError, KeyError, ValueError, TypeError, tomllib.TOMLDecodeError):
        return False
    return (values.get("ID") == "ubuntu" and
            values.get("VERSION_ID") == "26.04" and
            values.get("VERSION_CODENAME") == "resolute" and
            current == VERSION)


def private_folder(path: Path, owners: set[int]) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    return stat.S_ISDIR(info.st_mode) and info.st_uid in owners and stat.S_IMODE(info.st_mode) == 0o700


def private_file(path: Path, cap: int = 32768) -> bytes:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as file:
        info = os.fstat(file.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) != 0o600
                or not 0 < info.st_size <= cap):
            raise Blocked("accepted P8K private source evidence is unsafe")
        return file.read(cap + 1)


def original_constants() -> dict[str, str]:
    if ORIGINAL_PIN.is_symlink() or not ORIGINAL_PIN.is_file():
        raise Blocked("original historical recovery source metadata unavailable")
    try:
        tree = ast.parse(ORIGINAL_PIN.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, SyntaxError) as exc:
        raise Blocked("original source metadata unparsable") from exc
    keys = {"HOST", "HISTORICAL_REMOTE", "HISTORICAL_SHA256", "OFFLINE_RECIPIENT_SHA256"}
    values: dict[str, str] = {}
    for node in tree.body:
        if (isinstance(node, ast.Assign) and len(node.targets) == 1 and
                isinstance(node.targets[0], ast.Name) and node.targets[0].id in keys):
            name = node.targets[0].id
            if name in values or not isinstance(node.value, ast.Constant) or not isinstance(node.value.value, str):
                raise Blocked("historical source pin duplicated or nonliteral")
            values[name] = node.value.value
    if (set(values) != keys or values["HOST"] != "vaultwarden-oci-6-vnic"
            or not REMOTE.fullmatch(values["HISTORICAL_REMOTE"])
            or any(p in ("", ".", "..") for p in values["HISTORICAL_REMOTE"].split(":", 1)[1].split("/"))
            or not SHA64.fullmatch(values["HISTORICAL_SHA256"])
            or not SHA64.fullmatch(values["OFFLINE_RECIPIENT_SHA256"])):
        raise Blocked("original source pin format/owner invalid")
    return values


def previous_p8k(base: Path, original: dict[str, str]) -> None:
    target = base / P8K_EVIDENCE
    if not private_folder(target, {0}):
        raise Blocked("original P8K acceptance evidence directory missing")
    rows = private_file(target / "summary.txt").decode("utf-8", "replace").splitlines()
    required = (
        "Gate P8K - MULTI-CHECK recovery and safety batch (READ-ONLY)",
        "PASS       Original P8I-R stopped-host HOLD and P8J PRE-TRANSFER HOLD evidence intact",
        "PASS       Original historical ciphertext candidate SHA reference unchanged",
        "PASS       Original PUBLIC offline Age recipient hash matches installed config",
        "PASS       Immutable rc.12 release pointer and owned dedicated non-root ext4 dual identity verified",
        "PASS       All 11 concrete units stopped/unenabled",
        "PASS       /run tmpfs still present",
        "PASS       Kernel swap remains disabled",
        "PASS       Dedicated recovery volume free GiB=46",
        "PENDING    Root rclone bw-backup: unavailable on NEW VM; no Box object accessed",
        "HOLD       P8K batched read-only only",
    )
    if (not all(any(row.startswith(item) for row in rows) for item in required)
            or any(row.startswith("BLOCKED") for row in rows)):
        raise Blocked("original P8K safety HOLD no longer matches observed report")
    manifest = json.loads(private_file(target / "candidate.private.json"))
    if (not isinstance(manifest, dict) or manifest.get("schema") != 1
            or manifest.get("phase") != "PRE_RESTORE_BATCH_ONLY"
            or manifest.get("source_commit") != P8K_COMMIT
            or manifest.get("historical_remote_unverified") != original["HISTORICAL_REMOTE"]
            or manifest.get("historical_expected_sha256") != original["HISTORICAL_SHA256"]
            or manifest.get("offline_public_recipient_sha256") != original["OFFLINE_RECIPIENT_SHA256"]
            or not isinstance(manifest.get("box_readback"), dict)
            or manifest["box_readback"].get("status") != P8K_MODE):
        raise Blocked("original P8K candidate metadata does not prove Box-unavailable boundary")


def check_config(public_hash: str) -> None:
    try:
        info = CONFIG.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or
                stat.S_IMODE(info.st_mode) != 0o600):
            raise Blocked("protected config permissions invalid")
        with CONFIG.open("rb") as stream:
            cfg = tomllib.load(stream)
        rec = cfg["secrets"]["offline_recovery_recipient"]
        backup = cfg["backup"]
        if (not isinstance(rec, str) or
                hashlib.sha256(rec.encode("utf-8")).hexdigest() != public_hash or
                cfg["site"]["domain"] != TEST_DOMAIN or cfg["site"]["acme_email"] != TEST_EMAIL or
                backup["remote"] != "" or
                type(backup["local_retention_days"]) is not int or
                type(backup["remote_retention_days"]) is not int or
                backup["local_retention_days"] != 0 or backup["remote_retention_days"] != 0):
            raise Blocked("public offline recipient or stopped-origin isolation config changed")
    except (OSError, ValueError, KeyError, TypeError, tomllib.TOMLDecodeError) as exc:
        raise Blocked("installed config cannot be safely verified") from exc


def check_stopped() -> tuple[str, int]:
    if not CURRENT.is_symlink() or CURRENT.resolve(strict=True) != INSTALLED:
        raise Blocked("current immutable rc.12 release pointer differs")
    if str(SOURCE) not in sys.path:
        sys.path.insert(0, str(SOURCE))
    from vaultwarden_oci import install, storage
    proof = storage.verify()
    storage.reject_boot_related(proof.source)
    if (proof.fs_type != "ext4" or os.stat(STATE).st_dev == os.stat("/").st_dev):
        raise Blocked("dedicated mounted non-root ext4 ownership invalid")
    for unit in install.SYSTEMD_UNITS:
        if unit == NOTIFY_TEMPLATE:
            continue
        rc, output = run([
            "/usr/bin/systemctl", "show", unit, "--no-pager",
            "-p", "LoadState", "-p", "ActiveState", "-p", "UnitFileState",
        ])
        properties = dict(row.split("=", 1) for row in output.splitlines() if "=" in row)
        if (rc != 0 or properties.get("LoadState") != "loaded" or
                properties.get("ActiveState") != "inactive" or
                properties.get("UnitFileState") in ("enabled", "enabled-runtime", "linked", "linked-runtime")):
            raise Blocked("concrete systemd service active/enabled/unclear")
    rc, files = run([
        "/usr/bin/systemctl", "list-unit-files", "--all", "--no-legend",
        "--no-pager", "--plain", NOTIFY_PATTERN,
    ])
    entries = [row.split() for row in files.splitlines() if row.strip()]
    if (rc != 0 or len(entries) != 1 or len(entries[0]) < 2 or
            entries[0][0] != NOTIFY_TEMPLATE or entries[0][1] != "static"):
        raise Blocked("notify template/enablement unsafe")
    rc, units = run([
        "/usr/bin/systemctl", "list-units", "--all", "--no-legend", "--no-pager",
        "--plain", "--full", NOTIFY_PATTERN,
    ])
    if rc != 0 or units.strip():
        raise Blocked("notification instances unexpectedly present")
    rc, sockets = run(["/usr/bin/ss", "-H", "-lnt"])
    if rc != 0:
        raise Blocked("read-only HTTP port inventory unavailable")
    for row in sockets.splitlines():
        fields = row.split()
        port = re.search(r":([0-9]{1,5})$", fields[3]) if len(fields) >= 5 else None
        if port is None or int(port.group(1)) in (80, 443):
            raise Blocked("HTTP listener present or socket inventory invalid")
    containers = Path("/var/lib/docker/containers")
    if containers.exists() or containers.is_symlink():
        if containers.is_symlink() or not containers.is_dir() or any(containers.iterdir()):
            raise Blocked("Docker container metadata unexpectedly retained")
    db = STATE / "data" / "db.sqlite3"
    if db.exists() or db.is_symlink():
        raise Blocked("SQLite database unexpectedly present before restore")
    return hashlib.sha256(proof.uuid.encode("ascii")).hexdigest()[:12], len(install.SYSTEMD_UNITS)


def encrypted_file(path: Path, name: str, expected: str) -> tuple[int, str]:
    """Return safe sha/size only; no Age decryption or file writes."""
    if path != INBOX / name or path.name != name:
        raise Blocked("ciphertext must use the exact original basename and private inbox path")
    ubuntu = pwd.getpwnam("ubuntu")
    if not private_folder(INBOX, {0, ubuntu.pw_uid}):
        raise Blocked("encrypted ciphertext inbox is not a private 0700 directory")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid not in {0, ubuntu.pw_uid} or
                stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1 or
                not 64 <= info.st_size <= MAX_BYTES):
            raise Blocked("encrypted source file unsafe type/owner/mode/hardlink/size")
        before = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
        digest = hashlib.sha256()
        header = b""
        size = 0
        while True:
            block = stream.read(1024 * 1024)
            if not block:
                break
            if not header:
                header = block[:64]
            size += len(block)
            if size > MAX_BYTES:
                raise Blocked("encrypted source exceeds maximum")
            digest.update(block)
        after = os.fstat(stream.fileno())
        if before != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise Blocked("encrypted source changed during verification")
    actual = digest.hexdigest()
    if (size < 64 or not header.startswith(AGE_HEADER)
            or actual != expected or size != before[2]):
        raise Blocked("encrypted Age ciphertext header/size/SHA differs from independent original pin")
    return size, actual


def scratch() -> tuple[int, bool, bool]:
    rc, fs = run(["/usr/bin/findmnt", "-n", "-o", "FSTYPE", "--target", "/run"])
    is_tmpfs = rc == 0 and fs.strip() == "tmpfs"
    swaps = Path("/proc/swaps").read_text(encoding="ascii").splitlines()
    if not swaps or not swaps[0].startswith("Filename"):
        raise Blocked("swap inventory unavailable")
    free = shutil.disk_usage(STATE).free // (1024 ** 3)
    backups = STATE / "backups"
    if backups.exists() or backups.is_symlink():
        if backups.is_symlink() or not backups.is_dir():
            raise Blocked("backup temporary-stage path unsafe")
        for entry in backups.iterdir():
            if entry.is_symlink() or entry.suffix.casefold() in (".zip", ".vwrec", ".tar", ".db"):
                raise Blocked("unexpected pre-restore data already staged under on-disk backups")
    return free, is_tmpfs, len(swaps) > 1


def write_private(path: Path, payload: bytes) -> None:
    fd = os.open(
        path, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
        getattr(os, "O_NOFOLLOW", 0), 0o600,
    )
    with os.fdopen(fd, "wb") as f:
        f.write(payload)
        f.flush()
        os.fsync(f.fileno())


class Report:
    def __init__(self, directory: Path):
        self.directory = directory
        self.rows: list[tuple[str, str]] = []
        self.blocked = False

    def add(self, level: str, detail: str) -> None:
        if (level not in {"PASS", "PENDING", "NOT RUN", "BLOCKED"}
                or len(detail) > 240 or any(ch in detail for ch in "\r\n\x00")):
            raise ValueError("unsafe report")
        self.rows.append((level, detail))
        self.blocked |= level == "BLOCKED"

    def finish(self) -> int:
        outcome = "BLOCKED" if self.blocked else "HOLD"
        self.rows.append((outcome, "P8L verified encrypted SOURCE ONLY; no private Age identity, plaintext, restore, Box write or public start"))
        body = "Gate P8L - encrypted-source handoff, local SHA and recovery safety (READ-ONLY)\n"
        body += "\n".join(f"{k:<10} {v}" for k, v in self.rows) + "\n"
        path = self.directory / "summary.txt"
        write_private(path, body.encode("utf-8"))
        print(body, end="")
        print("Private summary:", path)
        print("Paste sanitized output and P8L_EXIT only, never encrypted ZIP/key/passphrase/private metadata.")
        return 2 if self.blocked else 0


def main() -> int:
    args = sys.argv[1:]
    artifact = None
    if len(args) == 4 and args[2] == "--artifact":
        artifact = Path(args[3])
        args = args[:2]
    if (len(args) != 2 or args[0] != "--expected-commit"
            or not SHA40.fullmatch(args[1]) or os.geteuid() != 0
            or os.environ.get("SUDO_USER") != "ubuntu"
            or platform.node().split(".", 1)[0] != HOST):
        print("BLOCKED: exact source SHA and sudo -n ubuntu on NEW VM required")
        return 2
    if not pinned_checkout(args[1]) or not supported_guest():
        print("BLOCKED: candidate branch/source/host/OS/rc.12 identity differs")
        return 2
    try:
        operator = pwd.getpwnam("ubuntu")
        if not private_folder(BASE_PATH, {0, operator.pw_uid}):
            raise Blocked("original acceptance root-private folder unsafe")
        timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        directory = BASE_PATH / f"p8l-encrypted-handoff-{timestamp}-{os.getpid()}"
        directory.mkdir(mode=0o700)
    except Exception:
        print("BLOCKED: root-private acceptance evidence unavailable")
        return 2
    report = Report(directory)
    stage = "original source and P8K success evidence"
    private = {"schema": 1, "status": "NO_CIPHERTEXT_READ", "source_commit": args[1]}
    try:
        original = original_constants()
        previous_p8k(BASE_PATH, original)
        report.add("PASS", "Original P8K HOLD/root-unconfigured Box evidence intact; no old-host credentials imported")
        report.add("PASS", "Original accepted historical Age ciphertext SHA candidate fingerprint=" +
                   safe_sha(original["HISTORICAL_REMOTE"]))
        stage = "installed custody and stopped new-origin state"
        check_config(original["OFFLINE_RECIPIENT_SHA256"])
        volume_fp, count = check_stopped()
        report.add("PASS", f"Exact original PUBLIC Age recipient and disabled remote; rc.12/stopped units={count}, dedicated ext4 UUID fingerprint={volume_fp}")
        report.add("PASS", "No HTTP80/443, Docker containers or pre-restore SQLite; shared hostname still NOT publicly authorized")
        stage = "protected scratch and transient key-storage state"
        free, tmpfs, swap = scratch()
        report.add("PASS" if tmpfs else "BLOCKED", "/run tmpfs" if tmpfs else "/run is not tmpfs; no offline identity transfer")
        report.add("PASS" if not swap else "BLOCKED", "No active kernel swap" if not swap else "Active swap detected; private identity prohibited")
        report.add("PASS" if free >= 5 else "BLOCKED", f"Dedicated data disk free GiB={free}; actual plaintext/rollback expansion still unknown")
        stage = "optional already-staged encrypted Age file"
        if artifact is None:
            report.add("PENDING", "No --artifact chosen: historical ciphertext bytes NOT yet verified at NEW host")
        elif not report.blocked:
            name = Path(original["HISTORICAL_REMOTE"]).name
            size, sha = encrypted_file(artifact, name, original["HISTORICAL_SHA256"])
            private.update({
                "status": "ORIGINAL_CIPHERTEXT_BYTES_MATCHED",
                "encrypted_bytes": size,
                "encrypted_sha256": sha,
                "original_public_recipient_sha256": original["OFFLINE_RECIPIENT_SHA256"],
                "asset_fingerprint": safe_sha(name),
            })
            report.add("PASS", f"Exact original historical Age ciphertext SHA-256 and header matched independently; encrypted_bytes={size}; no decryption")
        else:
            report.add("NOT RUN", "Encrypted ciphertext hash omitted due to earlier safety blocker")
        report.add("PENDING", "Original offline AES ZIP/private Age identity/passphrase remain OFF-HOST; no decryption or identity matching proved")
        report.add("PENDING", "Encrypted source hash does NOT prove manifest/SQLite; plaintext-on-ext4 scratch/cleanup and rollback risks not approved")
        report.add("PENDING", "Both stopped hosts have bw.lazymocha.com configured; DNS/Worker/ACME/SMTP/Box isolation not an authorization")
        report.add("NOT RUN", "No Box/rclone/OAuth, ZIP/private key read, ciphertext download, SOPS decryption to disk, Age decrypt, manifest or restore")
        report.add("NOT RUN", "No service/Docker start, format, mount, Cloudflare/OCI modification, SMTP, timer, reboot or production cutover")
    except KeyboardInterrupt:
        report.add("BLOCKED", "Interrupted during " + stage + "; no recovery action taken")
    except Exception:
        report.add("BLOCKED", "Read-only check failed during " + stage + "; details withheld")
    try:
        write_private(directory / "ciphertext.private.json", (json.dumps(private, sort_keys=True) + "\n").encode())
    except Exception:
        report.add("BLOCKED", "Private source witness metadata unavailable")
    return report.finish()


if __name__ == "__main__":
    raise SystemExit(main())
