#!/usr/bin/env python3
"""P8J recovery-source provenance PRE-TRANSFER READ-ONLY gate for NEW rc.12 VM.

No off-host artifact/ZIP/private Age identity is required or read. No rclone
configuration, network/Cloudflare/Box APIs, remote metadata, restore, decrypt,
mount, format, Docker socket, service start, systemd mutation, or reboot.
Only new root-private sanitized summary and candidate metadata are written.
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

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-7-vnic"
BRANCH = "audit/rc12-p8j-recovery-provenance-preflight"
VERSION = "0.1.0-rc.12"
TEST_DOMAIN = "bw.lazymocha.com"
TEST_EMAIL = "bw@lazymocha.com"
SOURCE = Path(__file__).resolve().parents[2]
INSTALLED = Path("/opt/vaultwarden-oci/releases") / VERSION
CURRENT = Path("/opt/vaultwarden-oci/current")
CONFIG = Path("/etc/vaultwarden-oci/config.toml")
STATE = Path("/var/lib/vaultwarden-oci")
P8IR_EVIDENCE = "p8i-postinstall-20261104T220057Z-4259"
ORIGINAL_PIN_FILE = SOURCE / "tests/host-acceptance/production-recovery-source-preflight.py"
HISTORICAL_KEYS = (
    "HOST", "HISTORICAL_REMOTE", "HISTORICAL_SHA256", "OFFLINE_RECIPIENT_SHA256",
)
SHA40_RE = re.compile(r"[a-f0-9]{40}\Z")
SHA64_RE = re.compile(r"[a-f0-9]{64}\Z")
RECOVERY_REMOTE_RE = re.compile(
    r"bw-backup:bw-backup/(?:[A-Za-z0-9._/-]+/)?recovery-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\.vwrec\Z"
)
NOTIFY_TEMPLATE = "vaultwarden-oci-notify@.service"
NOTIFY_GLOB = "vaultwarden-oci-notify@*.service"


class Blocked(RuntimeError):
    """Do not print the underlying exception text or private values."""


def tag(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def command(argv: list[str], *, timeout: int = 15) -> tuple[int | None, str]:
    try:
        process = subprocess.run(
            argv, cwd="/", stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    if len(process.stdout) > 131072:
        return None, ""
    return process.returncode, process.stdout.decode("utf-8", "replace")


def checked_checkout(pin: str) -> bool:
    if not SHA40_RE.fullmatch(pin):
        return False
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat")
    result = []
    for args in (
        ("rev-parse", "HEAD"), ("branch", "--show-current"),
        ("status", "--porcelain", "--untracked-files=all"),
    ):
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
        result.append(process.stdout.decode("utf-8", "replace").strip())
    return result == [pin, BRANCH, ""]


def guest_release() -> bool:
    if (platform.node().split(".", 1)[0] != HOST or
            platform.machine() not in ("aarch64", "arm64") or
            sys.version_info[:2] != (3, 14)):
        return False
    try:
        release = {}
        for row in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
            if "=" in row:
                key, val = row.split("=", 1)
                release[key] = val.strip('"')
        with (SOURCE / "versions.toml").open("rb") as stream:
            version = tomllib.load(stream)["vaultwarden_oci"]["version"]
    except (KeyError, TypeError, ValueError, OSError, tomllib.TOMLDecodeError):
        return False
    return (
        release.get("ID") == "ubuntu" and
        release.get("VERSION_ID") == "26.04" and
        release.get("VERSION_CODENAME") == "resolute" and
        version == VERSION
    )


def private_dir(path: Path, owners: set[int]) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    return (stat.S_ISDIR(info.st_mode) and info.st_uid in owners and
            stat.S_IMODE(info.st_mode) == 0o700)


def private_regular(path: Path, maximum: int = 32768) -> bytes:
    handle = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(handle, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or
                stat.S_IMODE(info.st_mode) != 0o600 or
                not 0 < info.st_size <= maximum):
            raise Blocked("private evidence file owner/mode/size unsafe")
        return stream.read(maximum + 1)


def evidence_base() -> Path:
    operator = pwd.getpwnam("ubuntu")
    home = Path(operator.pw_dir)
    if not home.is_dir() or home.is_symlink():
        raise Blocked("operator home invalid")
    base = home / "vwoci-acceptance"
    if not private_dir(base, {0, operator.pw_uid}):
        raise Blocked("root-private acceptance evidence directory missing/unsafe")
    return base


def accepted_p8ir(base: Path) -> str:
    folder = base / P8IR_EVIDENCE
    if not private_dir(folder, {0}):
        raise Blocked("accepted P8I-R evidence directory missing")
    source = private_regular(folder / "summary.txt")
    rows = source.decode("utf-8", "replace").splitlines()
    required = (
        "Gate P8I corrected - NEW isolated installed-but-stopped template-aware witness (READ-ONLY)",
        "PASS       Original one-shot P8H install attempt/checkpoint",
        "PASS       Original P8I BLOCKED and P8I-D template-only diagnosis intact",
        "PASS       Full installed product files=52, systemd units=12",
        "PASS       Mounted dedicated non-root ext4 and dual ownership markers",
        "PASS       Locked hostname/email, zero-prune/disabled Box config",
        "PASS       Concrete appliance units=11 inactive/unenabled; static notify template verified with zero instances",
        "PASS       No TCP 80/443 listeners or retained Docker containers=0",
        "PASS       No Vaultwarden database present",
        "HOLD       P8I post-install read-only witness only",
    )
    if (not all(any(row.startswith(marker) for row in rows) for marker in required)
            or any(row.startswith("BLOCKED") for row in rows)):
        raise Blocked("P8I-R accepted HOLD markers not intact")
    return hashlib.sha256(source).hexdigest()[:12]


def original_pin_contract(path: Path = ORIGINAL_PIN_FILE) -> dict[str, str]:
    """Parse literal-only original-VM candidate pins. Never import/execute it."""
    if path.is_symlink() or not path.is_file():
        raise Blocked("historical recovery source pin unavailable")
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename="historical-source")
    except (OSError, SyntaxError, UnicodeError) as exc:
        raise Blocked("original recovery source metadata unreadable") from exc
    values = {}
    for node in tree.body:
        if not isinstance(node, ast.Assign) or len(node.targets) != 1 or not isinstance(node.targets[0], ast.Name):
            continue
        name = node.targets[0].id
        if name in HISTORICAL_KEYS:
            if name in values:
                raise Blocked("duplicate historical recovery pin")
            if not isinstance(node.value, ast.Constant) or not isinstance(node.value.value, str):
                raise Blocked("historical recovery pin is not a literal string")
            values[name] = node.value.value
    if (set(values) != set(HISTORICAL_KEYS) or
            values["HOST"] != "vaultwarden-oci-6-vnic" or
            not RECOVERY_REMOTE_RE.fullmatch(values["HISTORICAL_REMOTE"]) or
            not SHA64_RE.fullmatch(values["HISTORICAL_SHA256"]) or
            not SHA64_RE.fullmatch(values["OFFLINE_RECIPIENT_SHA256"])):
        raise Blocked("historical original-VM recovery pin not independently identified")
    return values


def root_config(public_recipient_hash: str) -> str:
    """Do not print public recipient; require original -6-vnic custody pin."""
    try:
        info = CONFIG.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or
                stat.S_IMODE(info.st_mode) != 0o600):
            raise Blocked("installed config ownership/permissions changed")
        with CONFIG.open("rb") as f:
            config = tomllib.load(f)
        recipient = config["secrets"]["offline_recovery_recipient"]
        if not isinstance(recipient, str):
            raise Blocked("original public recovery recipient unavailable")
        backups = config["backup"]
        if (config["site"]["domain"] != TEST_DOMAIN or
                config["site"]["acme_email"] != TEST_EMAIL or
                backups["remote"] != "" or
                type(backups["local_retention_days"]) is not int or
                type(backups["remote_retention_days"]) is not int or
                backups["local_retention_days"] != 0 or
                backups["remote_retention_days"] != 0):
            raise Blocked("isolation/remote-pruning configuration changed")
        if hashlib.sha256(recipient.encode("utf-8")).hexdigest() != public_recipient_hash:
            raise Blocked("installed offline recipient does not match original recovery source pin")
    except (OSError, KeyError, ValueError, TypeError, tomllib.TOMLDecodeError) as exc:
        raise Blocked("cannot read installed test configuration safely") from exc
    return tag(recipient)


def current_stopped() -> int:
    """Never query the Docker socket or activate the notify template."""
    if not CURRENT.is_symlink() or CURRENT.resolve(strict=True) != INSTALLED:
        raise Blocked("installed rc.12 release symlink changed")
    if (STATE / "data/db.sqlite3").exists() or (STATE / "data/db.sqlite3").is_symlink():
        raise Blocked("Vaultwarden database unexpectedly present before approved restore")
    sys.path.insert(0, str(SOURCE))
    from vaultwarden_oci import install
    if len(install.SYSTEMD_UNITS) != 12 or NOTIFY_TEMPLATE not in install.SYSTEMD_UNITS:
        raise Blocked("installed systemd inventory changed")
    for unit in install.SYSTEMD_UNITS:
        if unit == NOTIFY_TEMPLATE:
            continue
        rc, raw = command([
            "/usr/bin/systemctl", "show", unit, "--no-pager",
            "-p", "LoadState", "-p", "ActiveState", "-p", "UnitFileState",
        ])
        fields = dict(s.split("=", 1) for s in raw.splitlines() if "=" in s)
        if (rc != 0 or fields.get("LoadState") != "loaded" or
                fields.get("ActiveState") != "inactive" or
                fields.get("UnitFileState") in {
                    "enabled", "enabled-runtime", "linked", "linked-runtime",
                }):
            raise Blocked("an installed concrete service/timer is running/enabled/unverifiable")
    code, output = command([
        "/usr/bin/systemctl", "list-unit-files", "--all",
        "--no-legend", "--no-pager", "--plain", NOTIFY_GLOB,
    ])
    files = [line.split() for line in output.splitlines() if line.strip()]
    if (code != 0 or len(files) != 1 or len(files[0]) < 2 or
            files[0][0] != NOTIFY_TEMPLATE or files[0][1] != "static"):
        raise Blocked("notify template or enabled instances are unsafe")
    code, output = command([
        "/usr/bin/systemctl", "list-units", "--all", "--no-legend",
        "--no-pager", "--plain", "--full", NOTIFY_GLOB,
    ])
    if code != 0 or output.strip():
        raise Blocked("instantiated notification unit unexpectedly present")
    code, sockets = command(["/usr/bin/ss", "-H", "-lnt"])
    if code != 0:
        raise Blocked("TCP listener inventory unavailable")
    for line in sockets.splitlines():
        cols = line.split()
        match = re.search(r":([0-9]{1,5})$", cols[3]) if len(cols) >= 5 else None
        if match is None or int(match.group(1)) in (80, 443):
            raise Blocked("pre-restore HTTP listener or unreadable port state")
    containers = Path("/var/lib/docker/containers")
    if containers.exists() or containers.is_symlink():
        if containers.is_symlink() or not containers.is_dir() or any(containers.iterdir()):
            raise Blocked("retained Docker container state unexpectedly present")
    return 12


def no_local_recovery_payloads() -> None:
    """Inventory only expected local paths; does not claim global key absence."""
    backups = STATE / "backups"
    if backups.is_symlink():
        raise Blocked("installed backup staging directory is a symlink")
    if backups.exists():
        if not backups.is_dir():
            raise Blocked("installed backup staging path has an unsafe type")
        for item in backups.iterdir():
            if item.is_symlink() or item.suffix.casefold() in (".vwrec", ".zip"):
                raise Blocked("local encrypted recovery/kit or symlink already staged without approval")
    home = Path(pwd.getpwnam("ubuntu").pw_dir)
    for parent in (home, Path("/root/vaultwarden-recovery")):
        if parent.exists() or parent.is_symlink():
            if parent.is_symlink() or not parent.is_dir():
                raise Blocked("known recovery kit staging folder unsafe")
            if any(parent.glob("vaultwarden-recovery-kit-*.zip")):
                raise Blocked("encrypted recovery ZIP unexpectedly staged on NEW host")
    # This is NOT an exhaustive search for private keys in arbitrary paths.


def volatile_path() -> tuple[bool, bool]:
    """Classify /run mount and active swaps, without mounting or changing any."""
    rc, text = command(["/usr/bin/findmnt", "-n", "-o", "FSTYPE", "--target", "/run"])
    run_tmpfs = rc == 0 and text.strip() == "tmpfs"
    try:
        swap_lines = Path("/proc/swaps").read_text(encoding="ascii").splitlines()
    except OSError as exc:
        raise Blocked("cannot inspect swap status") from exc
    if not swap_lines or not swap_lines[0].startswith("Filename"):
        raise Blocked("swap inventory malformed")
    return run_tmpfs, len(swap_lines) > 1


def write_once(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY |
                 getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "wb") as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())


class Report:
    def __init__(self, folder: Path):
        self.folder = folder
        self.lines: list[tuple[str, str]] = []
        self.blocked = False

    def add(self, level: str, message: str) -> None:
        if (level not in {"PASS", "PENDING", "NOT RUN", "BLOCKED"} or
                any(c in message for c in "\r\n\x00") or len(message) > 260):
            raise ValueError("invalid sanitized report row")
        self.blocked |= level == "BLOCKED"
        self.lines.append((level, message))

    def finish(self) -> int:
        self.lines.append((
            "BLOCKED" if self.blocked else "HOLD",
            "P8J original recovery provenance PRE-TRANSFER only; no ciphertext/identity/restore/live service authorization",
        ))
        text = "Gate P8J - off-host recovery source and isolation planning (READ-ONLY)\n"
        text += "\n".join(f"{level:<10} {line}" for level, line in self.lines) + "\n"
        write_once(self.folder / "summary.txt", text.encode("utf-8"))
        print(text, end="")
        print("Private summary:", self.folder / "summary.txt")
        print("Paste sanitized P8J status and P8J_EXIT only; keep candidate.private.json private.")
        return 2 if self.blocked else 0


def main() -> int:
    if (len(sys.argv) != 3 or sys.argv[1] != "--expected-commit" or
            not SHA40_RE.fullmatch(sys.argv[2]) or os.geteuid() != 0 or
            os.environ.get("SUDO_USER") != "ubuntu" or
            platform.node().split(".", 1)[0] != HOST):
        print("BLOCKED: exact SHA and sudo -n from ubuntu on NEW host required")
        return 2
    if not checked_checkout(sys.argv[2]) or not guest_release():
        print("BLOCKED: candidate/source/OS/host identity invalid")
        return 2
    try:
        base = evidence_base()
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        folder = base / f"p8j-recovery-readiness-{stamp}-{os.getpid()}"
        folder.mkdir(mode=0o700)
    except Exception:
        print("BLOCKED: private acceptance evidence unavailable")
        return 2

    report = Report(folder)
    stage = "accepted P8I-R evidence"
    try:
        witness = accepted_p8ir(base)
        report.add("PASS", "Accepted original P8I-R HOLD evidence unchanged; summary fingerprint=" + witness)
        stage = "historical ciphertext and original public-recipient pins"
        original = original_pin_contract()
        recipient_fp = root_config(original["OFFLINE_RECIPIENT_SHA256"])
        report.add("PASS", "Installed OFFLINE public Age recipient matches original restored-host independent pin; fingerprint=" + recipient_fp)
        report.add("PASS", "Original Box historical .vwrec candidate metadata pinned from original source; object fingerprint=" +
                   tag(original["HISTORICAL_REMOTE"]) + " ciphertext SHA-256 prefix=" + original["HISTORICAL_SHA256"][:12])
        stage = "installed/stopped test host"
        count = current_stopped()
        report.add("PASS", f"Installed rc.12 and {count} unit-file inventory; 11 concrete units stopped, static notification template has no instances")
        report.add("PASS", "No TCP 80/443 listeners, Docker container metadata or pre-restore Vaultwarden database")
        stage = "known local artifact staging paths"
        no_local_recovery_payloads()
        report.add("PASS", "No encrypted .vwrec/kit staged in known new-host recovery paths (limited inventory only)")
        stage = "volatile key staging/swap state"
        volatile, swap = volatile_path()
        report.add("PASS" if volatile else "PENDING", "/run is tmpfs for future transient OFFLINE Age identity" if volatile else
                   "/run is not proven tmpfs; no private identity may be introduced")
        report.add("PENDING" if swap else "PASS", "Active swap detected; do NOT stage offline identity until independently secured" if swap else
                   "No active kernel swap reported at this read-only observation")
        # Save historical candidate metadata privately; neither selection nor
        # authorization to contact Box, copy ZIPs, decrypt, or restore.
        candidate = {
            "schema": 1,
            "status": "UNVERIFIED_HISTORICAL_CANDIDATE_ONLY",
            "new_host": HOST,
            "verified_source_sha": sys.argv[2],
            "accepted_p8ir_summary_fingerprint": witness,
            "original_candidate_remote": original["HISTORICAL_REMOTE"],
            "original_candidate_ciphertext_sha256": original["HISTORICAL_SHA256"],
            "original_offline_public_recipient_sha256": original["OFFLINE_RECIPIENT_SHA256"],
            "permissions": "NO_BOX_READ_TRANSFER_DECRYPT_RESTORE",
        }
        write_once(folder / "candidate.private.json", (json.dumps(candidate, sort_keys=True) + "\n").encode())
        report.add("PENDING", "Exact original .vwrec source SHA/size and whether a newer approved point exists require independent OFF-HOST readback")
        report.add("PENDING", "Original AES-256 ZIP, private OFFLINE Age identity and independent passphrase remain off-host; no material was tested")
        report.add("PENDING", "Product restore/verification stages decrypted payload under dedicated on-disk backups, not entirely tmpfs: require explicit scratch/cleanup/at-rest risk approval")
        report.add("PENDING", "Both stopped VMs configure bw.lazymocha.com; ensure future restored config/remote cannot activate shared DNS/Worker/SMTP/Box")
        report.add("NOT RUN", "No rclone/Box/Cloudflare/OCI API, OAuth refresh, original ZIP/identity/ciphertext read or archive verification")
        report.add("NOT RUN", "No decryption, plaintext staging, restore, systemd/Docker start, filesystem mount/format, DNS/ACME/SMTP/timer/reboot")
        return report.finish()
    except KeyboardInterrupt:
        report.add("BLOCKED", "Interrupted during " + stage + "; no recovery action taken")
    except Exception:
        report.add("BLOCKED", "Read-only recovery-source prerequisite failed during " + stage + "; details withheld")
    return report.finish()


if __name__ == "__main__":
    raise SystemExit(main())
