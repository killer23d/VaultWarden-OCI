#!/usr/bin/env python3
"""P8K: batched read-only rc.12 recovery readiness on NEW disposable OCI host.

One execution: prior P8I-R/P8J evidence, original source/recipient continuity,
disk/install integrity, stopped runtime, scratch/custody and optional explicit
read-only Box inventory+bounded SHA-256 ciphertext stream.

NEVER formats, installs, decrypts, restores, starts/stops systemd/Docker,
mounts, alters DNS/OCI/Cloudflare/Worker, writes Box, reads a private Age key
or extracts the recovery ZIP. Root-private new report/metadata only. An
opted-in rclone read may refresh LOCAL OAuth token; it never writes to Box.
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
import select
import shutil
import stat
import subprocess
import sys
import time
import tomllib
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-7-vnic"
BRANCH = "audit/rc12-p8k-batched-recovery-readiness"
VERSION = "0.1.0-rc.12"
P8IR_SHA = "50b85b6bfd2940193f471f665f53ff50f8345848"
P8J_SHA = "d9f686f38fc279de5d9da1ae7fd4f9c6e8604d92"
P8IR_EVIDENCE = "p8i-postinstall-20261104T220057Z-4259"
P8J_EVIDENCE = "p8j-recovery-readiness-20261104T221022Z-4373"
P8G_EVIDENCE = "p8g-disk-network-witness-20261104T205546Z-2275"
SOURCE = Path(__file__).resolve().parents[2]
INSTALLED = Path("/opt/vaultwarden-oci/releases") / VERSION
CURRENT = Path("/opt/vaultwarden-oci/current")
STATE = Path("/var/lib/vaultwarden-oci")
CONFIG = Path("/etc/vaultwarden-oci/config.toml")
ORIGINAL_PIN_FILE = SOURCE / "tests/host-acceptance/production-recovery-source-preflight.py"
TEST_DOMAIN = "bw.lazymocha.com"
TEST_EMAIL = "bw@lazymocha.com"
NOTIFY_TEMPLATE = "vaultwarden-oci-notify@.service"
NOTIFY_GLOB = "vaultwarden-oci-notify@*.service"
SHA40_RE = re.compile(r"[a-f0-9]{40}\Z")
SHA64_RE = re.compile(r"[a-f0-9]{64}\Z")
REMOTE_RE = re.compile(r"bw-backup:bw-backup/(?:[A-Za-z0-9._/-]+/)?recovery-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\.vwrec\Z")
RECOVERY_NAME_RE = re.compile(r"recovery-([0-9]{8}T[0-9]{6}Z)-[A-Za-z0-9]+\.vwrec\Z")
BOX_PHRASE = "P8K READ ORIGINAL BOX CIPHERTEXT ONLY"
BOX_PARENT = "bw-backup:bw-backup"
MAX_CIPHERTEXT = 4 * 1024 ** 3
MAX_REMOTE_JSON = 4 * 1024 ** 2


class Blocked(RuntimeError):
    """Sanitized violation; never print the originating exception/path."""


def fp(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]


def run(args: list[str], timeout: int = 15) -> tuple[int | None, str]:
    try:
        result = subprocess.run(
            args, cwd="/", stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    if len(result.stdout) > MAX_REMOTE_JSON:
        return None, ""
    return result.returncode, result.stdout.decode("utf-8", "replace")


def source_ok(sha: str) -> bool:
    if not SHA40_RE.fullmatch(sha):
        return False
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat")
    parts = []
    for argv in (
        ("rev-parse", "HEAD"), ("branch", "--show-current"),
        ("status", "--porcelain", "--untracked-files=all"),
    ):
        try:
            p = subprocess.run(
                ["/usr/bin/git", *argv], cwd=SOURCE, env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=20, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        if p.returncode != 0 or len(p.stdout) > 8192:
            return False
        parts.append(p.stdout.decode("utf-8", "replace").strip())
    return parts == [sha, BRANCH, ""]


def host_ok() -> bool:
    if (platform.node().split(".", 1)[0] != HOST or
            platform.machine() not in ("aarch64", "arm64") or
            sys.version_info[:2] != (3, 14)):
        return False
    try:
        properties = {}
        for row in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
            if "=" in row:
                key, value = row.split("=", 1)
                properties[key] = value.strip('"')
        with (SOURCE / "versions.toml").open("rb") as f:
            version = tomllib.load(f)["vaultwarden_oci"]["version"]
    except (KeyError, OSError, TypeError, ValueError, tomllib.TOMLDecodeError):
        return False
    return (properties.get("ID") == "ubuntu" and
            properties.get("VERSION_ID") == "26.04" and
            properties.get("VERSION_CODENAME") == "resolute" and
            version == VERSION)


def private_directory(path: Path, owners: set[int]) -> bool:
    try:
        meta = path.lstat()
    except OSError:
        return False
    return (stat.S_ISDIR(meta.st_mode) and meta.st_uid in owners
            and stat.S_IMODE(meta.st_mode) == 0o700)


def private_bytes(path: Path, cap: int = 32768) -> bytes:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or
                stat.S_IMODE(info.st_mode) != 0o600 or
                not 0 < info.st_size <= cap):
            raise Blocked("historical evidence type/owner/mode/size unsafe")
        return stream.read(cap + 1)


def evidence_base() -> Path:
    operator = pwd.getpwnam("ubuntu")
    home = Path(operator.pw_dir)
    if home.is_symlink() or not home.is_dir():
        raise Blocked("operator home unsafe")
    base = home / "vwoci-acceptance"
    if not private_directory(base, {0, operator.pw_uid}):
        raise Blocked("root-private evidence base unavailable")
    return base


def check_markers(lines: list[str], markers: tuple[str, ...]) -> None:
    if (not all(any(line.startswith(marker) for line in lines) for marker in markers)
            or any(line.startswith("BLOCKED") for line in lines)):
        raise Blocked("original acceptance evidence incomplete or changed")


def historical_evidence(base: Path) -> dict[str, str]:
    i = base / P8IR_EVIDENCE
    j = base / P8J_EVIDENCE
    if not private_directory(i, {0}) or not private_directory(j, {0}):
        raise Blocked("accepted P8I-R/P8J evidence folder missing")
    older = private_bytes(i / "summary.txt").decode("utf-8", "replace").splitlines()
    recent = private_bytes(j / "summary.txt").decode("utf-8", "replace").splitlines()
    check_markers(older, (
        "Gate P8I corrected - NEW isolated installed-but-stopped template-aware witness (READ-ONLY)",
        "PASS       Original one-shot P8H install attempt/checkpoint",
        "PASS       Full installed product files=52, systemd units=12",
        "PASS       Mounted dedicated non-root ext4 and dual ownership markers",
        "PASS       Locked hostname/email, zero-prune/disabled Box config",
        "PASS       Concrete appliance units=11 inactive/unenabled; static notify template verified with zero instances",
        "PASS       No TCP 80/443 listeners or retained Docker containers=0",
        "PASS       No Vaultwarden database present",
        "HOLD       P8I post-install read-only witness only",
    ))
    check_markers(recent, (
        "Gate P8J - off-host recovery source and isolation planning (READ-ONLY)",
        "PASS       Accepted original P8I-R HOLD evidence unchanged",
        "PASS       Installed OFFLINE public Age recipient matches original restored-host independent pin",
        "PASS       Original Box historical .vwrec candidate metadata pinned from original source",
        "PASS       Installed rc.12 and 12 unit-file inventory",
        "PASS       No TCP 80/443 listeners",
        "PASS       No encrypted .vwrec/kit staged in known new-host recovery paths",
        "PASS       /run is tmpfs",
        "PASS       No active kernel swap",
        "HOLD       P8J original recovery provenance PRE-TRANSFER only",
    ))
    candidate = json.loads(private_bytes(j / "candidate.private.json"))
    if (not isinstance(candidate, dict) or
            candidate.get("schema") != 1 or
            candidate.get("verified_source_sha") != P8J_SHA or
            candidate.get("status") != "UNVERIFIED_HISTORICAL_CANDIDATE_ONLY" or
            candidate.get("permissions") != "NO_BOX_READ_TRANSFER_DECRYPT_RESTORE" or
            candidate.get("new_host") != HOST or
            candidate.get("accepted_p8ir_summary_fingerprint") !=
            hashlib.sha256(private_bytes(i / "summary.txt")).hexdigest()[:12]):
        raise Blocked("previous P8J private historical candidate inconsistent")
    return candidate


def original_source_pin() -> dict[str, str]:
    if ORIGINAL_PIN_FILE.is_symlink() or not ORIGINAL_PIN_FILE.is_file():
        raise Blocked("original recovery source pin unavailable")
    try:
        tree = ast.parse(ORIGINAL_PIN_FILE.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, SyntaxError) as exc:
        raise Blocked("original recovery source pin could not be parsed") from exc
    names = {"HOST", "HISTORICAL_REMOTE", "HISTORICAL_SHA256", "OFFLINE_RECIPIENT_SHA256"}
    result: dict[str, str] = {}
    for node in tree.body:
        if (isinstance(node, ast.Assign) and len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name)
                and node.targets[0].id in names):
            key = node.targets[0].id
            if key in result or not isinstance(node.value, ast.Constant) or not isinstance(node.value.value, str):
                raise Blocked("original historical pin changed or duplicated")
            result[key] = node.value.value
    if (set(result) != names or result["HOST"] != "vaultwarden-oci-6-vnic" or
            not REMOTE_RE.fullmatch(result["HISTORICAL_REMOTE"]) or
            not SHA64_RE.fullmatch(result["HISTORICAL_SHA256"]) or
            not SHA64_RE.fullmatch(result["OFFLINE_RECIPIENT_SHA256"])):
        raise Blocked("original external recovery pin unsafe")
    return result


def installed_config(recipient_sha: str) -> None:
    try:
        info = CONFIG.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or
                stat.S_IMODE(info.st_mode) != 0o600):
            raise Blocked("protected test config permissions changed")
        with CONFIG.open("rb") as stream:
            cfg = tomllib.load(stream)
        offsite = cfg["backup"]
        recipient = cfg["secrets"]["offline_recovery_recipient"]
        if (cfg["site"]["domain"] != TEST_DOMAIN or
                cfg["site"]["acme_email"] != TEST_EMAIL or
                offsite["remote"] != "" or
                type(offsite["local_retention_days"]) is not int or
                type(offsite["remote_retention_days"]) is not int or
                offsite["local_retention_days"] != 0 or
                offsite["remote_retention_days"] != 0 or
                not isinstance(recipient, str) or
                hashlib.sha256(recipient.encode()).hexdigest() != recipient_sha):
            raise Blocked("original offline recipient/config/backup isolation changed")
    except (OSError, ValueError, KeyError, TypeError, tomllib.TOMLDecodeError) as exc:
        raise Blocked("installed protected config unavailable") from exc


def storage_identity() -> str:
    if not CURRENT.is_symlink() or CURRENT.resolve(strict=True) != INSTALLED:
        raise Blocked("installed immutable rc.12 release pointer changed")
    if str(SOURCE) not in sys.path:
        sys.path.insert(0, str(SOURCE))
    from vaultwarden_oci import storage
    proof = storage.verify()
    storage.reject_boot_related(proof.source)
    if (proof.fs_type != "ext4" or
            os.stat(STATE).st_dev == os.stat("/").st_dev):
        raise Blocked("dedicated data volume or boot separation invalid")
    return fp(proof.uuid)


def stopped_safety() -> tuple[int, int]:
    from vaultwarden_oci import install
    if len(install.SYSTEMD_UNITS) != 12 or NOTIFY_TEMPLATE not in install.SYSTEMD_UNITS:
        raise Blocked("rc.12 systemd unit set changed")
    for unit in install.SYSTEMD_UNITS:
        if unit == NOTIFY_TEMPLATE:
            continue
        code, raw = run([
            "/usr/bin/systemctl", "show", unit, "--no-pager",
            "-p", "LoadState", "-p", "ActiveState", "-p", "UnitFileState",
        ])
        values = dict(row.split("=", 1) for row in raw.splitlines() if "=" in row)
        if (code != 0 or values.get("LoadState") != "loaded" or
                values.get("ActiveState") != "inactive" or
                values.get("UnitFileState") in {
                    "enabled", "enabled-runtime", "linked", "linked-runtime",
                }):
            raise Blocked("unexpected active/enabled/unverifiable appliance service")
    code, raw = run([
        "/usr/bin/systemctl", "list-unit-files", "--all", "--no-legend",
        "--no-pager", "--plain", NOTIFY_GLOB,
    ])
    files = [x.split() for x in raw.splitlines() if x.strip()]
    if (code != 0 or len(files) != 1 or len(files[0]) < 2 or
            files[0][0] != NOTIFY_TEMPLATE or files[0][1] != "static"):
        raise Blocked("unexpected static notify unit file/instance")
    code, raw = run([
        "/usr/bin/systemctl", "list-units", "--all", "--no-legend",
        "--no-pager", "--plain", "--full", NOTIFY_GLOB,
    ])
    if code != 0 or raw.strip():
        raise Blocked("notify service instance unexpectedly loaded")
    code, output = run(["/usr/bin/ss", "-H", "-lnt"])
    if code != 0:
        raise Blocked("socket read-only inventory unavailable")
    for row in output.splitlines():
        cells = row.split()
        match = re.search(r":([0-9]{1,5})$", cells[3]) if len(cells) >= 5 else None
        if match is None or int(match.group(1)) in (80, 443):
            raise Blocked("unexpected TCP 80/443 listener or unsafe socket format")
    meta = Path("/var/lib/docker/containers")
    if meta.exists() or meta.is_symlink():
        if meta.is_symlink() or not meta.is_dir() or any(meta.iterdir()):
            raise Blocked("Docker containers unexpectedly retained")
    db = STATE / "data/db.sqlite3"
    if db.exists() or db.is_symlink():
        raise Blocked("pre-restore Vaultwarden database unexpectedly present")
    return 11, 0


def scratch_readiness() -> tuple[bool, bool, int, bool]:
    code, fstype = run(["/usr/bin/findmnt", "-n", "-o", "FSTYPE", "--target", "/run"])
    volatile = code == 0 and fstype.strip() == "tmpfs"
    try:
        swap_lines = Path("/proc/swaps").read_text(encoding="ascii").splitlines()
    except OSError as exc:
        raise Blocked("swap state cannot be read") from exc
    if not swap_lines or not swap_lines[0].startswith("Filename"):
        raise Blocked("swap inventory unsafe")
    swap = len(swap_lines) > 1
    available_gib = shutil.disk_usage(STATE).free // (1024 ** 3)
    backups = STATE / "backups"
    staged = False
    if backups.exists() or backups.is_symlink():
        if backups.is_symlink() or not backups.is_dir():
            raise Blocked("backup staging path unsafe")
        for item in backups.iterdir():
            if item.is_symlink() or item.suffix.casefold() in (".vwrec", ".zip", ".tar", ".db"):
                staged = True
    if staged:
        raise Blocked("unapproved encrypted or plaintext recovery artifact already staged")
    return volatile, swap, available_gib, staged


def bounded_ciphertext_digest(args: list[str], *, seconds: int = 600,
                              max_bytes: int = MAX_CIPHERTEXT) -> tuple[str, int]:
    """Do not save a single byte of ciphertext, recover plaintext or print errors."""
    if seconds < 1 or max_bytes < 1 or not args or args[0] != "rclone":
        raise ValueError("invalid readback command")
    process = subprocess.Popen(
        args, cwd="/", stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    digest = hashlib.sha256()
    total = 0
    until = time.monotonic() + seconds
    try:
        if process.stdout is None:
            raise Blocked("ciphertext stream unavailable")
        while True:
            remaining = until - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("readback time limit")
            ready, _, _ = select.select([process.stdout], [], [], min(remaining, 90))
            if not ready:
                raise TimeoutError("readback stalled")
            block = os.read(process.stdout.fileno(), 1024 * 1024)
            if not block:
                break
            total += len(block)
            if total > max_bytes:
                raise ValueError("ciphertext exceeds size limit")
            digest.update(block)
        if process.wait(timeout=max(0.001, until - time.monotonic())) != 0 or total == 0:
            raise Blocked("ciphertext readback unavailable or empty")
        return digest.hexdigest(), total
    finally:
        if process.poll() is None:
            process.kill()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        if process.stdout is not None:
            process.stdout.close()


def listing_summary(data: str, older_name: str) -> tuple[int, int]:
    """Never output original or discovered path names."""
    obj = json.loads(data)
    if not isinstance(obj, list) or len(obj) > 10000:
        raise ValueError("Box listing too large/invalid")
    match = RECOVERY_NAME_RE.fullmatch(Path(older_name).name)
    if match is None:
        raise ValueError("historical timestamp missing")
    origin = match.group(1)
    count = newer = 0
    for entry in obj:
        if not isinstance(entry, dict):
            raise ValueError("invalid Box listing entry")
        path = entry.get("Path")
        if not isinstance(path, str):
            continue
        candidate = RECOVERY_NAME_RE.fullmatch(Path(path).name)
        if candidate:
            count += 1
            newer += candidate.group(1) > origin
    return count, newer


def interactive_box_permission() -> bool:
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        return False
    print("OPTIONAL EXTERNAL BOX READ: stream and hash one historical Age ciphertext only.")
    print("This can refresh ROOT's local rclone OAuth token. No Box uploads/deletes or disk artifact.")
    print("To approve, type exactly:", BOX_PHRASE)
    try:
        return input("Box readback consent (anything else skips): ").strip() == BOX_PHRASE
    except (EOFError, KeyboardInterrupt):
        return False


def box_readback(original: dict[str, str], report: "Report") -> dict[str, object]:
    """Called ONLY after all local safety checks and exact interactive consent."""
    code, remotes = run(["rclone", "listremotes"], timeout=20)
    if code != 0 or "bw-backup:" not in remotes.splitlines():
        report.add("PENDING", "Root rclone bw-backup: unavailable on NEW VM; no Box object accessed")
        return {"status": "REMOTE_UNAVAILABLE"}
    report.add("PASS", "Root's bw-backup: configured (name only; no credential content exposed)")
    code, raw = run([
        "rclone", "lsjson", BOX_PARENT, "--recursive",
        "--files-only", "--retries", "1",
    ], timeout=180)
    if code == 0:
        try:
            count, newer = listing_summary(raw, original["HISTORICAL_REMOTE"])
            report.add("PASS", f"Read-only recursive Box object inventory succeeded; .vwrec count={count}, newer_than_pin={newer}")
            if newer:
                report.add("PENDING", "Newer Box recovery points exist; historical ciphertext is NOT automatically selected")
        except (ValueError, TypeError, json.JSONDecodeError):
            report.add("PENDING", "Read-only Box listing unreadable/too large; candidate selection remains unresolved")
    else:
        report.add("PENDING", "Read-only Box listing unavailable; candidate selection remains unresolved")

    try:
        actual, count = bounded_ciphertext_digest([
            "rclone", "cat", original["HISTORICAL_REMOTE"], "--retries", "1",
        ])
    except (Blocked, OSError, TimeoutError, ValueError, subprocess.SubprocessError):
        report.add("PENDING", "Historical Box ciphertext stream unavailable/timed out; NO readback proof")
        return {"status": "CIPHERTEXT_UNAVAILABLE"}
    if actual != original["HISTORICAL_SHA256"]:
        report.add("BLOCKED", "Historical Box ciphertext SHA-256 MISMATCH; do NOT transfer/decrypt/restore")
        return {"status": "HASH_MISMATCH", "bytes": count, "observed_sha256": actual}
    report.add("PASS", f"Independent exact historical Box ciphertext SHA-256 matched original pin; streamed_bytes={count}, none saved")
    return {"status": "MATCHED_ORIGINAL_PIN", "bytes": count, "sha256": actual}


def write_private(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY |
                 getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())


class Report:
    def __init__(self, folder: Path):
        self.folder = folder
        self.rows: list[tuple[str, str]] = []
        self.blocked = False

    def add(self, label: str, message: str) -> None:
        if (label not in ("PASS", "PENDING", "NOT RUN", "BLOCKED") or
                len(message) > 240 or any(c in message for c in "\r\n\x00")):
            raise ValueError("invalid private/sanitized report")
        self.rows.append((label, message))
        self.blocked |= label == "BLOCKED"

    def finish(self) -> int:
        result = "BLOCKED" if self.blocked else "HOLD"
        self.rows.append((result, "P8K batched read-only only; no Age PRIVATE key, decryption, restore, live startup or production GO"))
        report = "Gate P8K - MULTI-CHECK recovery and safety batch (READ-ONLY)\n"
        report += "\n".join(f"{name:<10} {line}" for name, line in self.rows) + "\n"
        write_private(self.folder / "summary.txt", report.encode("utf-8"))
        print(report, end="")
        print("Private summary:", self.folder / "summary.txt")
        print("Paste sanitized summary and P8K_EXIT; do NOT paste private candidate/remote metadata.")
        return 2 if self.blocked else 0


def main() -> int:
    args = sys.argv[1:]
    offer = False
    if len(args) == 3 and args[-1] == "--offer-box-readback":
        offer = True
        args = args[:-1]
    if (len(args) != 2 or args[0] != "--expected-commit" or
            not SHA40_RE.fullmatch(args[1]) or os.geteuid() != 0 or
            os.environ.get("SUDO_USER") != "ubuntu" or
            platform.node().split(".", 1)[0] != HOST):
        print("BLOCKED: exact source SHA/sudo -n ubuntu/NEW ARM64 host required")
        return 2
    if not source_ok(args[1]) or not host_ok():
        print("BLOCKED: source/OS/release/branch/host mismatch; nothing accessed")
        return 2
    try:
        base = evidence_base()
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        folder = base / f"p8k-batched-recovery-{stamp}-{os.getpid()}"
        folder.mkdir(mode=0o700)
    except Exception:
        print("BLOCKED: private acceptance evidence unavailable")
        return 2
    report = Report(folder)
    stage = "historical P8I-R/P8J evidence"
    private_candidate: dict[str, object] = {
        "schema": 1, "phase": "PRE_RESTORE_BATCH_ONLY",
        "source_commit": args[1], "box_readback": "NOT_REQUESTED",
    }
    try:
        older = historical_evidence(base)
        report.add("PASS", "Original P8I-R stopped-host HOLD and P8J PRE-TRANSFER HOLD evidence intact")
        stage = "original historical encrypted recovery reference"
        original = original_source_pin()
        if (older.get("original_candidate_remote") != original["HISTORICAL_REMOTE"] or
                older.get("original_candidate_ciphertext_sha256") != original["HISTORICAL_SHA256"] or
                older.get("original_offline_public_recipient_sha256") != original["OFFLINE_RECIPIENT_SHA256"]):
            raise Blocked("original prior unverified candidate/recipient reference diverged")
        report.add("PASS", "Original historical ciphertext candidate SHA reference unchanged, object fingerprint=" +
                   fp(original["HISTORICAL_REMOTE"]))
        private_candidate.update({
            "historical_remote_unverified": original["HISTORICAL_REMOTE"],
            "historical_expected_sha256": original["HISTORICAL_SHA256"],
            "offline_public_recipient_sha256": original["OFFLINE_RECIPIENT_SHA256"],
        })
        stage = "new installed offline Age public recipient/isolated config"
        installed_config(original["OFFLINE_RECIPIENT_SHA256"])
        report.add("PASS", "Original PUBLIC offline Age recipient hash matches installed config; Box remote disabled, retention 0/0, locked test hostname")
        stage = "dedicated disk and immutable release"
        uuid = storage_identity()
        report.add("PASS", "Immutable rc.12 release pointer and owned dedicated non-root ext4 dual identity verified; UUID fingerprint=" + uuid)
        stage = "runtime, Docker metadata and network"
        units, containers = stopped_safety()
        report.add("PASS", f"All {units} concrete units stopped/unenabled, static notify template has NO instances; TCP 80/443=0, Docker containers={containers}, DB absent")
        stage = "scratch, swap and no accidental recovery stage"
        is_tmpfs, swap_active, free_gib, _ = scratch_readiness()
        report.add("PASS" if is_tmpfs else "BLOCKED", "/run tmpfs still present (offline key must remain off-host unless separately authorized)" if is_tmpfs else
                   "/run is NOT tmpfs; private key must not be staged")
        report.add("PASS" if not swap_active else "BLOCKED", "Kernel swap remains disabled" if not swap_active else
                   "Active swap found; no private key/decryption approved")
        report.add("PASS" if free_gib >= 5 else "BLOCKED", f"Dedicated recovery volume free GiB={free_gib}; no pre-approved encrypted/plaintext archive staged")
        report.add("PENDING", "No exact recovery plaintext expansion size, trusted verified manifest or rollback capacity proof yet")
        report.add("PENDING", "Recovery engine currently stages decrypted tar/payload on dedicated ext4; explicit at-rest cleanup risk consent required")
        report.add("PENDING", "Original offline AES-256 ZIP, private Age key and independent passphrase remain OFF-HOST and untested")
        report.add("PENDING", "Shared bw.lazymocha.com configured on both stopped origins; live DNS/Worker/TLS must be separately controlled")
        stage = "optional exact Box ciphertext read-only stream"
        if offer and not report.blocked and interactive_box_permission():
            private_candidate["box_readback"] = box_readback(original, report)
        else:
            report.add("NOT RUN", "Box rclone/object listing/SHA stream not approved, not requested or preflight BLOCKED")
            private_candidate["box_readback"] = "NOT_RUN"
        report.add("NOT RUN", "No private Age identity/ZIP/passphrase transfer, decrypted payload, recovery manifest or restore")
        report.add("NOT RUN", "No Box write/prune, cloud DNS/Worker/OCI mutations, Docker socket, Caddy/app, SMTP, timers, mount/format or reboot")
    except KeyboardInterrupt:
        report.add("BLOCKED", "Interrupted during " + stage + "; no destructive action performed")
    except Exception:
        report.add("BLOCKED", "Read-only batch verification failed during " + stage + "; details withheld")
    try:
        write_private(folder / "candidate.private.json",
                      (json.dumps(private_candidate, sort_keys=True) + "\n").encode("utf-8"))
    except Exception:
        report.add("BLOCKED", "Private candidate report could not be durably saved")
    return report.finish()


if __name__ == "__main__":
    raise SystemExit(main())
