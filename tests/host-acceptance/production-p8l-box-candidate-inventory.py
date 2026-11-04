#!/usr/bin/env python3
"""P8L: ONE-TURN read-only Box recovery set inventory + ciphertext SHA-256.

NEW isolated/stopped rc.12 host only. Revalidates P8K's independently pinned
historical readback, offline PUBLIC Age recipient and stopped runtime; requires
new typed consent before listing and streaming *up to* 12 encrypted objects.

No ciphertext is persisted, no decrypt/restore/private Age key/ZIP is read,
no Box write/prune, no Docker socket/service start, no system mutations.
Only new root-private sanitized summary and PRIVATE untrusted observations.
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
BRANCH = "audit/rc12-p8l-box-candidate-inventory"
VERSION = "0.1.0-rc.12"
P8K_SHA = "e446677fc2c846aa0ac4fb734f7b03729cefad4d"
P8K_EVIDENCE = "p8k-batched-recovery-20261104T225128Z-4717"
SOURCE = Path(__file__).resolve().parents[2]
STATE = Path("/var/lib/vaultwarden-oci")
INSTALLED = Path("/opt/vaultwarden-oci/releases") / VERSION
CURRENT = Path("/opt/vaultwarden-oci/current")
CONFIG = Path("/etc/vaultwarden-oci/config.toml")
RCLONE_CONFIG = Path("/root/.config/rclone/rclone.conf")
ORIGINAL_PIN = SOURCE / "tests/host-acceptance/production-recovery-source-preflight.py"
BOX_PARENT = "bw-backup:bw-backup"
SHA40_RE = re.compile(r"[a-f0-9]{40}\Z")
SHA64_RE = re.compile(r"[a-f0-9]{64}\Z")
RECOVERY_NAME_RE = re.compile(r"recovery-([0-9]{8}T[0-9]{6}Z)-([A-Za-z0-9]+)\.vwrec\Z")
REMOTE_RE = re.compile(r"bw-backup:bw-backup/(?:[A-Za-z0-9._/-]+/)?recovery-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\.vwrec\Z")
SAFE_PATH_RE = re.compile(r"[A-Za-z0-9._/-]{1,512}\Z")
NOTIFY_TEMPLATE = "vaultwarden-oci-notify@.service"
NOTIFY_GLOB = "vaultwarden-oci-notify@*.service"
MAX_OBJECTS = 12
MAX_LIST_BYTES = 4 * 1024 * 1024
MAX_OBJECT_BYTES = 4 * 1024**3
MAX_BATCH_BYTES = 8 * 1024**3


class Blocked(RuntimeError):
    """Fail closed while keeping underlying private/remote errors hidden."""


def safe_tag(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def rclone_root_env() -> dict[str, str]:
    environment = {
        key: value for key, value in os.environ.items()
        if not key.startswith("RCLONE_")
    }
    environment.update(HOME="/root", XDG_CONFIG_HOME="/root/.config")
    return environment


def read_command(args: list[str], timeout: int = 20, cap: int = MAX_LIST_BYTES) -> tuple[int | None, str]:
    try:
        p = subprocess.run(
            args, cwd="/", stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=timeout, check=False,
            env=rclone_root_env() if args and args[0] == "rclone" else None,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    if len(p.stdout) > cap:
        return None, ""
    return p.returncode, p.stdout.decode("utf-8", "replace")


def source_approved(pin: str) -> bool:
    if not SHA40_RE.fullmatch(pin):
        return False
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat")
    replies = []
    for args in (
        ("rev-parse", "HEAD"), ("branch", "--show-current"),
        ("status", "--porcelain", "--untracked-files=all"),
    ):
        try:
            p = subprocess.run(
                ["/usr/bin/git", *args], cwd=SOURCE, env=environment,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=20, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        if p.returncode != 0 or len(p.stdout) > 8192:
            return False
        replies.append(p.stdout.decode("utf-8", "replace").strip())
    return replies == [pin, BRANCH, ""]


def host_approved() -> bool:
    if (platform.node().split(".", 1)[0] != HOST or
            platform.machine() not in ("aarch64", "arm64") or
            sys.version_info[:2] != (3, 14)):
        return False
    try:
        props = {}
        for item in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
            if "=" in item:
                k, v = item.split("=", 1)
                props[k] = v.strip('"')
        with (SOURCE / "versions.toml").open("rb") as src:
            version = tomllib.load(src)["vaultwarden_oci"]["version"]
    except (OSError, ValueError, KeyError, TypeError, tomllib.TOMLDecodeError):
        return False
    return (props.get("ID") == "ubuntu" and
            props.get("VERSION_ID") == "26.04" and
            props.get("VERSION_CODENAME") == "resolute" and
            version == VERSION)


def protected_dir(path: Path, owner: set[int]) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    return (stat.S_ISDIR(info.st_mode) and
            info.st_uid in owner and stat.S_IMODE(info.st_mode) == 0o700)


def read_private(path: Path, max_size: int = 32768) -> bytes:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or
                stat.S_IMODE(info.st_mode) != 0o600 or
                not 0 < info.st_size <= max_size):
            raise Blocked("historical root-private evidence owner/size/mode invalid")
        return stream.read(max_size + 1)


def evidence_base() -> Path:
    operator = pwd.getpwnam("ubuntu")
    home = Path(operator.pw_dir)
    if home.is_symlink() or not home.is_dir():
        raise Blocked("operator home unsafe")
    base = home / "vwoci-acceptance"
    if not protected_dir(base, {0, operator.pw_uid}):
        raise Blocked("accepted root-private evidence base missing/unsafe")
    return base


def previous_box_proof(base: Path) -> dict[str, object]:
    folder = base / P8K_EVIDENCE
    if not protected_dir(folder, {0}):
        raise Blocked("previous accepted P8K Box witness absent")
    summary = read_private(folder / "summary.txt").decode("utf-8", "replace").splitlines()
    markers = (
        "Gate P8K - MULTI-CHECK recovery and safety batch (READ-ONLY)",
        "PASS       Original P8I-R stopped-host HOLD and P8J PRE-TRANSFER HOLD evidence intact",
        "PASS       Original historical ciphertext candidate SHA reference unchanged",
        "PASS       Original PUBLIC offline Age recipient hash matches installed config",
        "PASS       Immutable rc.12 release pointer and owned dedicated non-root ext4 dual identity",
        "PASS       All 11 concrete units stopped/unenabled, static notify template has NO instances",
        "PASS       /run tmpfs still present",
        "PASS       Kernel swap remains disabled",
        "PASS       Read-only recursive Box object inventory succeeded; .vwrec count=9, newer_than_pin=2",
        "PASS       Independent exact historical Box ciphertext SHA-256 matched original pin; streamed_bytes=358680, none saved",
        "HOLD       P8K batched read-only only",
    )
    if (not all(any(line.startswith(item) for line in summary) for item in markers)
            or any(line.startswith("BLOCKED") for line in summary)):
        raise Blocked("previous P8K readback HOLD or SHA evidence changed")
    private = json.loads(read_private(folder / "candidate.private.json"))
    if (not isinstance(private, dict) or private.get("schema") != 1
            or private.get("phase") != "PRE_RESTORE_BATCH_ONLY"
            or private.get("source_commit") != P8K_SHA):
        raise Blocked("P8K candidate file changed")
    proof = private.get("box_readback")
    if (not isinstance(proof, dict) or proof.get("status") != "MATCHED_ORIGINAL_PIN"
            or proof.get("bytes") != 358680 or
            not isinstance(proof.get("sha256"), str) or
            not SHA64_RE.fullmatch(proof["sha256"])):
        raise Blocked("previous Box ciphertext readback not independently matched")
    return private


def original_public_pins() -> dict[str, str]:
    """Extract literals from original-host source without running it."""
    if ORIGINAL_PIN.is_symlink() or not ORIGINAL_PIN.is_file():
        raise Blocked("original-host recovery metadata source unavailable")
    try:
        tree = ast.parse(ORIGINAL_PIN.read_text(encoding="utf-8"))
    except (OSError, SyntaxError, UnicodeError) as exc:
        raise Blocked("original historical recovery pin unreadable") from exc
    keys = {"HOST", "HISTORICAL_REMOTE", "HISTORICAL_SHA256", "OFFLINE_RECIPIENT_SHA256"}
    result: dict[str, str] = {}
    for node in tree.body:
        if (isinstance(node, ast.Assign) and len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name)
                and node.targets[0].id in keys):
            key = node.targets[0].id
            if (key in result or not isinstance(node.value, ast.Constant)
                    or not isinstance(node.value.value, str)):
                raise Blocked("original recovery source pin is not literal or unique")
            result[key] = node.value.value
    relative = result.get("HISTORICAL_REMOTE", "").removeprefix(BOX_PARENT + "/")
    if (set(result) != keys or result["HOST"] != "vaultwarden-oci-6-vnic"
            or not REMOTE_RE.fullmatch(result["HISTORICAL_REMOTE"])
            or not valid_relative_path(relative)
            or not SHA64_RE.fullmatch(result["HISTORICAL_SHA256"])
            or not SHA64_RE.fullmatch(result["OFFLINE_RECIPIENT_SHA256"])):
        raise Blocked("invalid original historical Box/recovery recipient pin")
    return result


def local_isolation(recipient_sha: str) -> int:
    """Do not read offline private material, decrypt, or start Docker."""
    if not CURRENT.is_symlink() or CURRENT.resolve(strict=True) != INSTALLED:
        raise Blocked("installed immutable rc.12 release pointer changed")
    try:
        info = CONFIG.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) != 0o600):
            raise Blocked("protected config file ownership/mode changed")
        with CONFIG.open("rb") as stream:
            cfg = tomllib.load(stream)
        recipient = cfg["secrets"]["offline_recovery_recipient"]
        bk = cfg["backup"]
        if (cfg["site"]["domain"] != "bw.lazymocha.com"
                or cfg["site"]["acme_email"] != "bw@lazymocha.com"
                or bk["remote"] != ""
                or type(bk["local_retention_days"]) is not int
                or type(bk["remote_retention_days"]) is not int
                or bk["local_retention_days"] != 0
                or bk["remote_retention_days"] != 0
                or not isinstance(recipient, str)
                or hashlib.sha256(recipient.encode()).hexdigest() != recipient_sha):
            raise Blocked("test-only config/disabled remote/offline public recipient changed")
    except (OSError, ValueError, KeyError, TypeError, tomllib.TOMLDecodeError) as exc:
        raise Blocked("root-only test config unavailable") from exc
    if str(SOURCE) not in sys.path:
        sys.path.insert(0, str(SOURCE))
    from vaultwarden_oci import install, storage
    disk = storage.verify()
    storage.reject_boot_related(disk.source)
    if (disk.fs_type != "ext4" or
            os.stat(STATE).st_dev == os.stat("/").st_dev):
        raise Blocked("dedicated ext4 data storage changed or became root-backed")
    if len(install.SYSTEMD_UNITS) != 12 or NOTIFY_TEMPLATE not in install.SYSTEMD_UNITS:
        raise Blocked("rc.12 unit set changed")
    for unit in install.SYSTEMD_UNITS:
        if unit == NOTIFY_TEMPLATE:
            continue
        code, body = read_command([
            "/usr/bin/systemctl", "show", unit, "--no-pager",
            "-p", "LoadState", "-p", "ActiveState", "-p", "UnitFileState",
        ], cap=8192)
        props = dict(row.split("=", 1) for row in body.splitlines() if "=" in row)
        if (code != 0 or props.get("LoadState") != "loaded"
                or props.get("ActiveState") != "inactive"
                or props.get("UnitFileState") in (
                    "enabled", "enabled-runtime", "linked", "linked-runtime",
                )):
            raise Blocked("concrete installed service or timer active, enabled, or uninspectable")
    code, body = read_command([
        "/usr/bin/systemctl", "list-unit-files", "--all", "--no-legend",
        "--no-pager", "--plain", NOTIFY_GLOB,
    ])
    files = [line.split() for line in body.splitlines() if line.strip()]
    if (code != 0 or len(files) != 1 or len(files[0]) < 2
            or files[0][0] != NOTIFY_TEMPLATE or files[0][1] != "static"):
        raise Blocked("static notification template or enabled instance changed")
    code, body = read_command([
        "/usr/bin/systemctl", "list-units", "--all", "--no-legend",
        "--no-pager", "--plain", "--full", NOTIFY_GLOB,
    ])
    if code != 0 or body.strip():
        raise Blocked("instantiated notification unit unexpectedly present")
    code, body = read_command(["/usr/bin/ss", "-H", "-lnt"])
    if code != 0:
        raise Blocked("local TCP inventory unavailable")
    for row in body.splitlines():
        words = row.split()
        port = re.search(r":([0-9]{1,5})$", words[3]) if len(words) >= 5 else None
        if port is None or int(port.group(1)) in (80, 443):
            raise Blocked("TCP 80/443 listener or invalid inventory")
    containers = Path("/var/lib/docker/containers")
    if containers.exists() or containers.is_symlink():
        if containers.is_symlink() or not containers.is_dir() or any(containers.iterdir()):
            raise Blocked("unexpected Docker containers")
    db = STATE / "data/db.sqlite3"
    if db.exists() or db.is_symlink():
        raise Blocked("Vaultwarden database exists before authorized restore")
    rc, fstype = read_command(["/usr/bin/findmnt", "-n", "-o", "FSTYPE", "--target", "/run"])
    if rc != 0 or fstype.strip() != "tmpfs":
        raise Blocked("transient key workspace is not tmpfs")
    try:
        swaps = Path("/proc/swaps").read_text(encoding="ascii").splitlines()
    except OSError as exc:
        raise Blocked("swap status not readable") from exc
    if len(swaps) != 1 or not swaps[0].startswith("Filename"):
        raise Blocked("active or uninspectable swap state")
    if shutil.disk_usage(STATE).free < 5 * 1024**3:
        raise Blocked("not enough dedicated backup scratch capacity")
    backups = STATE / "backups"
    if backups.exists() or backups.is_symlink():
        if backups.is_symlink() or not backups.is_dir():
            raise Blocked("backup staging folder unsafe")
        for item in backups.iterdir():
            if item.is_symlink() or item.suffix.lower() in (
                ".vwrec", ".zip", ".tar", ".db", ".sqlite3",
            ):
                raise Blocked("unapproved recovery plaintext/ciphertext already staged")
    return 11


def root_remote_configured() -> bool:
    try:
        info = RCLONE_CONFIG.lstat()
    except OSError:
        return False
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
            or stat.S_IMODE(info.st_mode) != 0o600):
        return False
    code, remote_names = read_command(["rclone", "listremotes"], timeout=20)
    return code == 0 and "bw-backup:" in remote_names.splitlines()


def valid_relative_path(path: str) -> bool:
    return (bool(SAFE_PATH_RE.fullmatch(path))
            and all(p not in ("", ".", "..") for p in path.split("/"))
            and bool(RECOVERY_NAME_RE.fullmatch(path.rsplit("/", 1)[-1])))


def bounded_objects(
    data: str, original: dict[str, str],
    *, diagnostics: dict[str, int] | None = None,
) -> tuple[list[dict[str, object]], int]:
    """Quarantine unsafe *unrelated* objects, never broaden an rclone read.

    Some acceptance folders can contain tiny or incomplete .vwrec test
    fixtures. A fail-closed parser used to block the ENTIRE Box survey on one
    such unrelated object. Only individually validated regular encrypted
    candidate files may be streamed. The independently pinned original MUST
    still be present with safe metadata, or the whole gate BLOCKS.
    """
    try:
        items = json.loads(data)
    except (json.JSONDecodeError, TypeError, ValueError) as exc:
        raise Blocked("BOX_LIST_JSON_INVALID") from exc
    if not isinstance(items, list) or len(items) > 10000:
        raise Blocked("BOX_LIST_NOT_BOUNDED_ARRAY")
    counts = {
        "named": 0, "quarantined": 0, "unsafe_path": 0,
        "not_file": 0, "missing_size": 0, "undersized": 0,
        "oversized": 0,
    }
    rows: list[dict[str, object]] = []
    seen: set[str] = set()
    historical = original["HISTORICAL_REMOTE"]
    for entry in items:
        if not isinstance(entry, dict):
            continue
        path, size = entry.get("Path"), entry.get("Size")
        if not isinstance(path, str):
            continue
        match = RECOVERY_NAME_RE.fullmatch(path.rsplit("/", 1)[-1])
        if match is None:
            continue
        counts["named"] += 1
        if path in seen:
            raise Blocked("BOX_DUPLICATE_RECOVERY_PATH")
        seen.add(path)
        reason: str | None = None
        if not valid_relative_path(path):
            reason = "unsafe_path"
        elif entry.get("IsDir") is not False:
            reason = "not_file"
        elif type(size) is not int:
            reason = "missing_size"
        elif size < 64:
            reason = "undersized"
        elif size > MAX_OBJECT_BYTES:
            reason = "oversized"
        if reason is not None:
            if BOX_PARENT + "/" + path == historical:
                raise Blocked("BOX_HISTORICAL_OBJECT_INVALID_METADATA")
            counts[reason] += 1
            counts["quarantined"] += 1
            continue
        remote = BOX_PARENT + "/" + path
        rows.append({
            "remote": remote, "path_fingerprint": safe_tag(remote),
            "name_date": match.group(1), "size": size,
            "same_parent_as_historical":
                path.rpartition("/")[0] ==
                historical.removeprefix(BOX_PARENT + "/").rpartition("/")[0],
        })
    if not rows:
        raise Blocked("BOX_NO_SAFE_RECOVERY_OBJECTS")
    if len(rows) > MAX_OBJECTS:
        raise Blocked("BOX_TOO_MANY_SAFE_RECOVERY_OBJECTS")
    rows.sort(key=lambda row: (row["name_date"], row["path_fingerprint"]), reverse=True)
    pinned = [row for row in rows if row["remote"] == historical]
    if len(pinned) != 1:
        raise Blocked("BOX_HISTORICAL_OBJECT_MISSING_FROM_LIST")
    newer = sum(row["name_date"] > pinned[0]["name_date"] for row in rows)
    if diagnostics is not None:
        diagnostics.update(counts)
    return rows, newer


def hash_age_stream(remote: str, *, size_limit: int, seconds: int = 600) -> tuple[str, int, bool]:
    """SHA256 and Age envelope version one HEADER test over stdout pipe; no local ciphertext file."""
    if (not remote.startswith(BOX_PARENT + "/")
            or not valid_relative_path(remote.removeprefix(BOX_PARENT + "/"))
            or not 64 <= size_limit <= MAX_OBJECT_BYTES or seconds < 1):
        raise ValueError("invalid bounded ciphertext readback")
    task = subprocess.Popen(
        ["rclone", "cat", remote, "--retries", "1"],
        cwd="/", stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=rclone_root_env(),
    )
    hasher = hashlib.sha256()
    total = 0
    header = b""
    deadline = time.monotonic() + seconds
    try:
        if task.stdout is None:
            raise Blocked("ciphertext pipe unavailable")
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("ciphertext readback time budget exceeded")
            ready, _, _ = select.select([task.stdout], [], [], min(remaining, 90))
            if not ready:
                raise TimeoutError("ciphertext stream stalled")
            chunk = os.read(task.stdout.fileno(), 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > size_limit:
                raise ValueError("ciphertext size exceeds listed size")
            if len(header) < 64:
                header += chunk[:64-len(header)]
            hasher.update(chunk)
        if total < 64 or task.wait(timeout=max(0.001, deadline - time.monotonic())) != 0:
            raise Blocked("ciphertext readback incomplete")
        return hasher.hexdigest(), total, header.startswith(b"age-encryption.org/v1")
    finally:
        if task.poll() is None:
            task.kill()
            try:
                task.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        if task.stdout is not None:
            task.stdout.close()


def write_private(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                 getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


class Report:
    def __init__(self, location: Path):
        self.location = location
        self.rows: list[tuple[str, str]] = []
        self.blocked = False

    def add(self, level: str, message: str) -> None:
        if (level not in ("PASS", "PENDING", "NOT RUN", "BLOCKED") or
                len(message) > 260 or any(x in message for x in "\r\n\x00")):
            raise ValueError("unsafe source/secret diagnostic output")
        self.rows.append((level, message))
        self.blocked |= level == "BLOCKED"

    def finish(self) -> int:
        result = "BLOCKED" if self.blocked else "HOLD"
        self.rows.append((
            result,
            "P8L READ-ONLY remote set survey; no ciphertext authenticity for newer pins, Age private key, decrypt, restore, or live startup",
        ))
        report = "Gate P8L - batched remote encrypted recovery source integrity (READ-ONLY)\n"
        report += "\n".join(f"{state:<10} {message}" for state, message in self.rows) + "\n"
        write_private(self.location / "summary.txt", report.encode("utf-8"))
        print(report, end="")
        print("Private summary:", self.location / "summary.txt")
        print("Private full candidate source details are NEVER pasted.")
        return 2 if self.blocked else 0


def main() -> int:
    args = sys.argv[1:]
    read_box = False
    if len(args) == 3 and args[-1] == "--read-only-box":
        read_box = True
        args = args[:-1]
    if (len(args) != 2 or args[0] != "--expected-commit" or
            not SHA40_RE.fullmatch(args[1]) or os.geteuid() != 0 or
            os.environ.get("SUDO_USER") != "ubuntu" or
            platform.node().split(".", 1)[0] != HOST):
        print("BLOCKED: only sudo -n from ubuntu on the NEW host and exact reviewed source")
        return 2
    if not source_approved(args[1]) or not host_approved():
        print("BLOCKED: clean reviewed P8L source / OS / host identity mismatch")
        return 2
    try:
        base = evidence_base()
        folder = base / ("p8l-box-source-" +
            dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{os.getpid()}")
        folder.mkdir(mode=0o700)
    except Exception:
        print("BLOCKED: private report root unavailable")
        return 2
    report = Report(folder)
    observations: list[dict[str, object]] = []
    stage = "original P8K independently pinned Box readback"
    original: dict[str, str] = {}
    try:
        previous = previous_box_proof(base)
        original = original_public_pins()
        old_proof = previous["box_readback"]
        if (previous.get("historical_remote_unverified") != original["HISTORICAL_REMOTE"]
                or previous.get("historical_expected_sha256") != original["HISTORICAL_SHA256"]
                or previous.get("offline_public_recipient_sha256") != original["OFFLINE_RECIPIENT_SHA256"]
                or old_proof["sha256"] != original["HISTORICAL_SHA256"]):
            raise Blocked("original independently pinned Box SHA or public recipient diverged")
        report.add("PASS", "Previous P8K Box readback and original independent historical SHA+358680 bytes match unchanged")
        stage = "new installed rc.12 isolation and key custody"
        unit_count = local_isolation(original["OFFLINE_RECIPIENT_SHA256"])
        report.add("PASS", f"Immutable rc.12, non-root ext4, public offline Age recipient and {unit_count} stopped units verified")
        report.add("PASS", "No active notify instance, TCP 80/443, Docker container, SQLite, swap or unapproved backup stage; /run tmpfs")
        stage = "root Box config and declared read-only Box scope"
        if not root_remote_configured():
            report.add("BLOCKED", "Root bw-backup: rclone remote is no longer available or secure")
        elif not read_box:
            report.add("NOT RUN", "Box inventory/hash not requested by --read-only-box; no Box object contacted")
        else:
            report.add("PASS", "Requested Box READ-only via --read-only-box; no additional TTY prompt, root config secured")
            stage = "bounded recursive Box encrypted-object listing"
            code, raw = read_command([
                "rclone", "lsjson", BOX_PARENT, "--recursive",
                "--files-only", "--retries", "1",
            ], timeout=180, cap=MAX_LIST_BYTES)
            if code is None:
                raise Blocked("BOX_LIST_TIMEOUT_OR_OUTPUT_CAP")
            if code != 0:
                raise Blocked("BOX_LIST_COMMAND_FAILED")
            diagnostic: dict[str, int] = {}
            entries, newer = bounded_objects(raw, original, diagnostics=diagnostic)
            report.add("PASS", f"Box recovery filenames={diagnostic['named']}, safe encrypted candidates={len(entries)}, newer safe by filename date={newer}")
            if diagnostic["quarantined"]:
                report.add("PENDING",
                    f"Untrusted Box fixtures QUARANTINED={diagnostic['quarantined']}: "
                    f"path={diagnostic['unsafe_path']} type={diagnostic['not_file']} "
                    f"size_missing={diagnostic['missing_size']} tiny={diagnostic['undersized']} "
                    f"oversize={diagnostic['oversized']}; none streamed")
            report.add("PENDING", "Filename dates, Box path and new SHA are not independent backup authenticity/restore validity proofs")
            if diagnostic["named"] != 9 or newer != 2:
                report.add("PENDING", "Box inventory count/date differs from previous P8K; no automatic point selection")
            stage = "read-only bounded SHA and Age header survey"
            # Reserve each listed object's maximum stream size BEFORE launch,
            # including failed/partial reads, so the cumulative 8 GiB limit
            # covers every attempted remote stream, not only completed ones.
            reserved_bytes = 0
            for rank, entry in enumerate(entries, 1):
                listed_size = entry["size"]
                if listed_size > MAX_BATCH_BYTES - reserved_bytes:
                    report.add("PENDING", f"Candidate rank={rank} exceeds cumulative 8 GiB stream bound; NOT READ")
                    observations.append({**entry, "status": "NOT_READ_CUMULATIVE_SIZE_BOUND"})
                    continue
                reserved_bytes += listed_size
                remote = entry["remote"]
                try:
                    sha, observed_bytes, age_header = hash_age_stream(remote, size_limit=listed_size)
                except (Blocked, TimeoutError, ValueError, OSError, subprocess.SubprocessError):
                    report.add("PENDING", f"Candidate rank={rank} read-only Box SHA stream unavailable; NOT VERIFIED")
                    observations.append({**entry, "status": "STREAM_UNAVAILABLE"})
                    continue
                if observed_bytes != listed_size:
                    pinned = remote == original["HISTORICAL_REMOTE"]
                    report.add("BLOCKED" if pinned else "PENDING",
                               f"Candidate rank={rank} stream SIZE MISMATCH; " +
                               ("historical pin INVALID" if pinned else "untrusted fixture quarantined"))
                    observations.append({**entry, "status": "SIZE_MISMATCH", "sha256": sha, "streamed_bytes": observed_bytes})
                    if pinned:
                        break
                    continue
                if not age_header:
                    pinned = remote == original["HISTORICAL_REMOTE"]
                    report.add("BLOCKED" if pinned else "PENDING",
                               f"Candidate rank={rank} not an Age encrypted envelope; " +
                               ("historical pin INVALID" if pinned else "untrusted fixture quarantined"))
                    observations.append({**entry, "status": "AGE_HEADER_MISMATCH", "sha256": sha, "streamed_bytes": observed_bytes})
                    if pinned:
                        break
                    continue
                if remote == original["HISTORICAL_REMOTE"] and sha != original["HISTORICAL_SHA256"]:
                    report.add("BLOCKED", f"Historical candidate rank={rank} SHA differs from independently pinned reference")
                    observations.append({**entry, "status": "INDEPENDENT_PIN_MISMATCH", "sha256": sha, "streamed_bytes": observed_bytes})
                    break
                independently_pinned = remote == original["HISTORICAL_REMOTE"]
                status = "PIN_MATCH" if independently_pinned else "NEW_OBSERVATION_ONLY"
                report.add("PASS", f"Candidate rank={rank} name_date={entry['name_date']} same_parent={entry['same_parent_as_historical']} ciphertext_bytes={observed_bytes} Age envelope version one=yes path_fp={entry['path_fingerprint']} sha_fp={sha[:12]} scope={status}")
                observations.append({**entry, "status": status, "sha256": sha, "streamed_bytes": observed_bytes})
            verified = sum(item.get("status") in ("PIN_MATCH", "NEW_OBSERVATION_ONLY") for item in observations)
            report.add("PASS" if verified == len(entries) else "PENDING", f"Encrypted recovery object streams age-header and SHA reviewed={verified}/{len(entries)}, without files on disk")
            report.add("PENDING", "Original off-host private Age key/ZIP/passphrase not checked; encrypted headers do NOT verify payload/manifest")
        report.add("NOT RUN", "No private Age key, ZIP/passphrase handling, decryption, plaintext, restore, Box object write/prune")
        report.add("NOT RUN", "No systemd/Docker start, cloud DNS/Worker/OCI change, ACME, SMTP, timer, format or reboot")
    except KeyboardInterrupt:
        report.add("BLOCKED", "Interrupted during " + stage + "; no destructive action performed")
    except Blocked as exc:
        code = str(exc)
        # Codes are authored literals, not provider error strings or paths.
        if stage == "bounded recursive Box encrypted-object listing" and code.startswith("BOX_"):
            report.add("BLOCKED", "Box listing validation reason_code=" + code + "; no ciphertext stream invoked")
        else:
            report.add("BLOCKED", "Read-only source/isolation failed during " + stage + "; details withheld")
    except Exception:
        report.add("BLOCKED", "Read-only P8L source isolation/inventory failed during " + stage + "; details withheld")
    private = {
        "schema": 1, "purpose": "UNTRUSTED_BOX_READ_ONLY_CIPHERTEXT_OBSERVATIONS",
        "source_sha": args[1], "original_historical_pin": original.get("HISTORICAL_REMOTE"),
        "records": observations,
        "no_restore_consent": True,
    }
    try:
        write_private(folder / "candidates.private.json", (json.dumps(private, sort_keys=True) + "\n").encode())
    except Exception:
        report.add("BLOCKED", "Private remote observations could not be durably saved")
    return report.finish()


if __name__ == "__main__":
    raise SystemExit(main())
