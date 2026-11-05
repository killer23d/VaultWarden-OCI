#!/usr/bin/env python3
"""P8P: one-shot NEW-VM rc.12 reboot persistence and optional postboot origin re-arm.

Modes:
  --mode reboot --oci-console-ready: full preboot snapshot, durable one-shot
      checkpoint, then ONLY local systemctl reboot (SSH disconnects).
  --mode verify: read-only different-boot integrity/security proof; HOLD if
      Docker's Cloudflare-origin ingress rule was lost across reboot.
  --mode verify-and-rearm --oci-console-ready: same postboot proof plus ONE
      product-owned local edge refresh only IF the 443 filter is absent.
Never starts Caddy/Vaultwarden, Worker, DNS, SMTP, Box writes or backup timers.
All raw doctor/service details and protected hashes remain on the remote VM.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import importlib.util
import json
import os
import platform
import pwd
import re
import signal
import sqlite3
import stat
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-7-vnic"
BRANCH = "audit/rc12-p8p-batched-reboot-persistence-newvm"
RELEASE = "0.1.0-rc.12"
SRC = Path(__file__).resolve().parents[2]
INSTALLED = Path("/opt/vaultwarden-oci/releases") / RELEASE
CURRENT = Path("/opt/vaultwarden-oci/current")
STATE = Path("/var/lib/vaultwarden-oci")
EVIDENCE = Path("/home/ubuntu/vwoci-acceptance")
P1_FILE = SRC / "tests/host-acceptance/production-recovery-source-preflight.py"
P5_FILE = SRC / "tests/host-acceptance/production-security-foundation-consent.py"
P8O_MARKER = EVIDENCE / "p8o-security-foundation-one-shot-attempt.json"
P8O_SUMMARY = EVIDENCE / "p8o-security-batch-20261105T193844Z-16901/summary.txt"
P8O_COMMIT = "f989f2c91a1276501aab126443b96d593261e54e"
CHECKPOINT = EVIDENCE / "p8p-one-shot-reboot-checkpoint.json"
REARM_MARKER = EVIDENCE / "p8p-one-shot-origin-rearm-attempt.json"
BOOT_ID = Path("/proc/sys/kernel/random/boot_id")
DB_SHA = "075163445a045cf274f7b1bf52ecb4f8f90b460cf13de418664c1c60cbfe9a35"
RECIPIENT_SHA = "7d08721bcc02bbef7dae1f07bfde244852560c69d0b72f8dc0fcba0da30c6773"
VOLUME_FP = "2449f67320a1"
DOMAIN = "bw.lazymocha.com"
EMAIL = "bw@lazymocha.com"
REMOTE = "bw-backup:bw-backup"
SHA40 = re.compile(r"[0-9a-f]{40}\Z")
FOUNDATION = (
    "edge.cloudflare.cidrs", "edge.cloudflare.iptables", "crowdsec.engine",
    "crowdsec.hub", "crowdsec.firewall",
)
MANDATORY = {"host.os", "host.architecture", "storage.dedicated",
             "secrets.custody", "secrets.decrypt"}
EXPECTED_FAILURE = {"crowdsec.cloudflare", "runtime.paths"}


class Blocked(RuntimeError):
    """Sensitive details intentionally withheld from public evidence."""


def sha_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def run(argv: list[str], *, timeout: int = 25) -> tuple[int | None, str]:
    try:
        result = subprocess.run(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, cwd="/", timeout=timeout, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    if len(result.stdout) > 262144:
        return None, ""
    return result.returncode, result.stdout.decode("utf-8", "replace")


def source_clean(pin: str) -> bool:
    if not SHA40.fullmatch(pin):
        return False
    observed: list[str] = []
    for args in (("rev-parse", "HEAD"), ("branch", "--show-current"),
                 ("status", "--porcelain", "--untracked-files=all")):
        try:
            proc = subprocess.run(
                ["/usr/bin/git", *args], cwd=SRC, check=False, timeout=20,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat"),
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        if proc.returncode or len(proc.stdout) > 8192:
            return False
        observed.append(proc.stdout.decode("utf-8", "replace").strip())
    return observed == [pin, BRANCH, ""]


def authorized_host() -> bool:
    if (os.geteuid() != 0 or os.getenv("SUDO_USER") != "ubuntu"
            or platform.node().split(".")[0] != HOST
            or platform.machine() not in ("aarch64", "arm64")
            or sys.version_info[:2] != (3, 14)):
        return False
    try:
        import tomllib
        osinfo = dict(line.split("=", 1) for line in
                      Path("/etc/os-release").read_text(encoding="utf-8").splitlines()
                      if "=" in line)
        with (SRC / "versions.toml").open("rb") as inp:
            ver = tomllib.load(inp)["vaultwarden_oci"]["version"]
        return (osinfo.get("ID", "").strip('"') == "ubuntu"
                and osinfo.get("VERSION_ID", "").strip('"') == "26.04"
                and osinfo.get("VERSION_CODENAME", "").strip('"') == "resolute"
                and ver == RELEASE)
    except (OSError, ValueError, KeyError, TypeError):
        return False


def private_dir(path: Path, owners: set[int]) -> None:
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in owners
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise Blocked("private acceptance evidence directory unsafe")


def private_read(path: Path, limit: int = 131072) -> bytes:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as inp:
        info = os.fstat(inp.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) != 0o600
                or not 0 < info.st_size <= limit):
            raise Blocked("root-private acceptance evidence metadata invalid")
        return inp.read(limit + 1)


def accepted_p8o() -> None:
    private_dir(EVIDENCE, {0, pwd.getpwnam("ubuntu").pw_uid})
    private_dir(P8O_SUMMARY.parent, {0})
    marker = json.loads(private_read(P8O_MARKER))
    if (marker.get("schema") != 1 or marker.get("host") != HOST
            or marker.get("reviewed_commit") != P8O_COMMIT
            or marker.get("db_sha256") != DB_SHA
            or marker.get("volume_fingerprint") != VOLUME_FP):
        raise Blocked("P8O one-shot host-security marker does not match accepted run")
    summary = private_read(P8O_SUMMARY).decode("utf-8", "strict")
    required = (
        "Gate P8O - NEW disposable host batched security foundation",
        "PASS       Installed product established Cloudflare-only Docker 443 filter",
        "PASS       Installed product configured CrowdSec/Hub and INPUT-only host firewall",
        "PASS       Five required foundation doctor IDs PASS",
        "FOUNDATION P8O batched local security only",
    )
    if not all(phrase in summary for phrase in required):
        raise Blocked("P8O actual FOUNDATION private summary unavailable")


def load_helper(path: Path, module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, path)
    if not spec or not spec.loader:
        raise Blocked("reviewed helper unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def boot_id() -> str:
    text = BOOT_ID.read_text(encoding="ascii").strip().lower()
    if not re.fullmatch(r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}", text):
        raise Blocked("kernel boot ID invalid")
    return text


def file_sha(path: Path) -> str:
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 16 * 1024**2):
        raise Blocked("tracked protected file absent/unsafe/oversized")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    sha = hashlib.sha256()
    fd = os.open(path, flags)
    with os.fdopen(fd, "rb") as stream:
        while True:
            data = stream.read(1024**2)
            if not data:
                break
            sha.update(data)
    return sha.hexdigest()


def sqlite_ok(db: Path) -> bool:
    try:
        meta = db.lstat()
        if not stat.S_ISREG(meta.st_mode) or meta.st_size < 100:
            return False
        conn = sqlite3.connect(
            "file:" + quote(str(db), safe="/") + "?mode=ro&immutable=1",
            uri=True, timeout=5,
        )
        try:
            integrity = conn.execute("PRAGMA integrity_check").fetchall()
            count = conn.execute("SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()
        finally:
            conn.close()
        return integrity == [("ok",)] and bool(count and count[0] > 0) and file_sha(db) == DB_SHA
    except (sqlite3.Error, OSError, ValueError, Blocked):
        return False


def tracked_paths(secrets, storage) -> tuple[Path, ...]:
    return (
        Path("/etc/vaultwarden-oci/config.toml"),
        secrets.ENCRYPTED,
        secrets.AGE_KEY,
        storage.HOST_IDENTITY_FILE,
        storage.VOLUME_MARKER,
        STATE / "data/db.sqlite3",
        P8O_MARKER,
        P8O_SUMMARY,
        Path(__file__).resolve(),
    )


def digest_paths(paths: tuple[Path, ...]) -> dict[str, str]:
    return {str(path): file_sha(path) for path in paths}


def compare_paths(checkpoint: dict[str, object], current: dict[str, str]) -> None:
    old = checkpoint.get("hashes")
    if (not isinstance(old, dict) or set(old) != set(current)
            or any(old[key] != digest for key, digest in current.items())):
        raise Blocked("immutable source, Age/SOPS, restored SQLite or P8O evidence changed after reboot")


def systemd_state(name: str) -> dict[str, str]:
    code, value = run(["/usr/bin/systemctl", "show", name, "--no-pager",
                       "-p", "LoadState", "-p", "ActiveState", "-p", "UnitFileState"])
    if code != 0:
        raise Blocked("systemd unit inventory unavailable")
    return dict(row.split("=", 1) for row in value.splitlines() if "=" in row)


def stopped_install(units: tuple[str, ...]) -> None:
    if len(units) != 12 or "vaultwarden-oci-notify@.service" not in units:
        raise Blocked("installed unit registry differs")
    for unit in units:
        if unit.endswith("@.service"):
            continue
        state = systemd_state(unit)
        if (state.get("LoadState") != "loaded"
                or state.get("ActiveState") != "inactive"
                or state.get("UnitFileState") in {"enabled", "enabled-runtime", "linked", "linked-runtime"}):
            raise Blocked("app/DNS/timer enabled or active across reboot")
    code, notify = run([
        "/usr/bin/systemctl", "list-units", "--all", "--no-legend",
        "--plain", "--full", "vaultwarden-oci-notify@*.service",
    ])
    if code != 0 or notify.strip():
        raise Blocked("unexpected notification unit instance")
    code, notify_files = run([
        "/usr/bin/systemctl", "list-unit-files", "--all", "--no-legend",
        "--plain", "vaultwarden-oci-notify@*.service",
    ])
    if code != 0 or [line.split()[:2] for line in notify_files.splitlines()] != [
        ["vaultwarden-oci-notify@.service", "static"]
    ]:
        raise Blocked("static notification unit changed")
    code, listeners = run(["/usr/bin/ss", "-H", "-lnt"])
    if code != 0:
        raise Blocked("TCP listener inventory unavailable")
    for raw in listeners.splitlines():
        words = raw.split()
        found = re.search(r":([0-9]{1,5})$", words[3]) if len(words) >= 5 else None
        if found is None or int(found.group(1)) in {80, 443, 2375, 2376}:
            raise Blocked("unexpected public HTTP or Docker TCP listener")
    code, containers = run(["/usr/bin/docker", "ps", "-a", "--format", "{{.ID}}"], timeout=35)
    if code != 0 or containers.strip():
        raise Blocked("retained Docker container could auto-start on reboot")
    meta = Path("/var/lib/docker/containers")
    if meta.exists() or meta.is_symlink():
        if meta.is_symlink() or not meta.is_dir() or any(meta.iterdir()):
            raise Blocked("unexpected Docker metadata after reboot")
    guard = STATE / "state/update-recovery-required.json"
    if guard.exists() or guard.is_symlink():
        raise Blocked("unresolved update-recovery guard")


def foundation_services() -> None:
    if not Path("/usr/bin/cscli").is_file():
        raise Blocked("CrowdSec package missing")
    for name in ("crowdsec.service", "crowdsec-firewall-bouncer.service"):
        state = systemd_state(name)
        if (state.get("LoadState") != "loaded" or state.get("ActiveState") != "active"
                or state.get("UnitFileState") != "enabled"):
            raise Blocked("CrowdSec engine or host INPUT bouncer lost boot-enabled/active state")
    worker = systemd_state("crowdsec-cloudflare-worker-bouncer.service")
    if (worker.get("LoadState") != "loaded" or worker.get("ActiveState") != "inactive"
            or worker.get("UnitFileState") != "disabled"):
        raise Blocked("Cloudflare Worker must remain boot-disabled/inactive")


def package_baseline() -> tuple[bool, bool]:
    code, dpkg = run(["/usr/bin/dpkg", "--audit"], timeout=45)
    if code != 0 or dpkg.strip():
        raise Blocked("dpkg partial package state after reboot")
    code, kind = run(["/usr/bin/findmnt", "-n", "-o", "FSTYPE", "--target", "/run"])
    if code != 0 or kind.strip() != "tmpfs":
        raise Blocked("volatile /run not tmpfs")
    try:
        swap = Path("/proc/swaps").read_text(encoding="ascii").splitlines()
    except OSError as exc:
        raise Blocked("swap state cannot be inspected") from exc
    if len(swap) != 1 or not swap[0].startswith("Filename"):
        raise Blocked("active swap forbidden on accepted security host")
    code, ntp = run(["/usr/bin/timedatectl", "show", "-p", "NTPSynchronized", "--value"])
    synced = code == 0 and ntp.strip().lower() in ("yes", "true", "1")
    return synced, Path("/run/reboot-required").exists()


def doctor(p5, folder: Path, *, after_boot: bool) -> tuple[dict[str, str], str, bool]:
    label = "p8p-postboot" if after_boot else "p8p-preboot"
    classification, checks, _ = p5.diagnose_doctor(folder, label, seconds=180)
    if classification != "valid" or len(checks) != 27:
        raise Blocked("installed 27-check product doctor failed contract validation")
    ids = p5.product_doctor_ids()
    if len(ids) != 27 or set(checks) != set(ids):
        raise Blocked("complete installed product doctor ID set changed")
    if any(checks.get(name) != "PASS" for name in MANDATORY):
        raise Blocked("mandatory host/storage/Age/SOPS doctor check not PASS")
    if checks.get("crowdsec.cloudflare") != "FAIL":
        raise Blocked("Cloudflare Worker doctor must remain unarmed before public start")
    expected = EXPECTED_FAILURE | ({"edge.cloudflare.iptables"} if after_boot else set())
    failures = {name for name, status in checks.items() if status == "FAIL"}
    if not failures <= expected:
        raise Blocked("unexpected installed security/runtime doctor FAIL ID")
    for name in FOUNDATION:
        if name == "edge.cloudflare.iptables" and after_boot:
            if checks[name] not in ("PASS", "FAIL"):
                raise Blocked("postboot Docker firewall status not definite")
        elif checks[name] != "PASS":
            raise Blocked("CrowdSec or validated Cloudflare CIDR policy regressed")
    from vaultwarden_oci import runtime, secrets
    path_state, description = p5.inspect_stopped_runtime_paths(runtime, secrets)
    if path_state == "BLOCKED":
        raise Blocked("unsafe postreboot generated/volatile runtime path metadata")
    if (checks.get("runtime.paths") == "PASS") != (path_state == "PASS"):
        raise Blocked("product runtime.paths and independent metadata disagree")
    return checks, path_state, checks["edge.cloudflare.iptables"] == "PASS"


def snapshot(report, folder: Path, *, after_boot: bool) -> dict[str, str]:
    accepted_p8o()
    if not CURRENT.is_symlink() or CURRENT.resolve(strict=True) != INSTALLED:
        raise Blocked("installed immutable rc.12 release pointer changed")
    sys.path.insert(0, str(INSTALLED))
    from vaultwarden_oci import install, runtime, secrets, storage
    p1 = load_helper(P1_FILE, "p8p_immutable_release")
    p5 = load_helper(P5_FILE, "p8p_stopped_paths_doctor")
    if p1.release_integrity(SRC, INSTALLED) != (True, 52):
        raise Blocked("52 original installed product files changed")
    if p1.systemd_unit_integrity(INSTALLED) != (True, 12):
        raise Blocked("12 installed systemd unit bytes changed")
    proof = storage.verify()
    storage.reject_boot_related(proof.source)
    if (proof.fs_type != "ext4" or sha_bytes(proof.uuid.encode())[:12] != VOLUME_FP
            or os.stat(STATE).st_dev == os.stat("/").st_dev):
        raise Blocked("original isolated ext4 disk/source markers changed")
    cfg = runtime.load_config()
    if (cfg.domain != DOMAIN or cfg.acme_email != EMAIL
            or sha_bytes(cfg.offline_recovery_recipient.encode()) != RECIPIENT_SHA
            or cfg.offsite_remote != REMOTE
            or type(cfg.local_retention_days) is not int or type(cfg.remote_retention_days) is not int
            or cfg.local_retention_days != 0 or cfg.remote_retention_days != 0
            or cfg.smtp_accept_invalid_certs or cfg.smtp_accept_invalid_hostnames):
        raise Blocked("restored hostname/offline identity/SMTP/Box no-prune configuration changed")
    secrets.validate_custody(cfg.offline_recovery_recipient)
    values = secrets.validate_encrypted(cfg.offline_recovery_recipient)
    if not isinstance(values, dict) or not secrets.admin_enabled(values) or not values.get("cloudflare_remediation_token"):
        raise Blocked("restored SOPS/admin/remediation authority changed")
    del values
    if not sqlite_ok(STATE / "data/db.sqlite3"):
        raise Blocked("recovered SQLite integrity or pinned historical digest changed")
    stopped_install(tuple(install.SYSTEMD_UNITS))
    foundation_services()
    synced, reboot_required = package_baseline()
    checks, path_status, edge_ready = doctor(p5, folder, after_boot=after_boot)
    report.add("PASS", "Original P8O FOUNDATION provenance, immutable 52 files/12 units and dedicated ext4 unchanged")
    report.add("PASS", "Restored SQLite full integrity/source SHA, operational SOPS/Age/admin/SMTP and Box retention0/0")
    report.add("PASS", "No app/DNS/timer/notify activation, Docker container or TCP 80/443/2375/2376 listeners")
    report.add("PASS", "CrowdSec engine and host INPUT bouncer active+enabled, Worker inactive+disabled")
    report.add("PASS", "Complete 27-ID product doctor and mandatory host/storage/secret checks valid")
    report.add("PASS" if edge_ready else "PENDING",
               "Cloudflare Docker 443 filter PASS" if edge_ready else
               "Postboot Cloudflare Docker 443 filter missing; explicit stopped-only rearm needed")
    report.add("PASS" if path_status == "PASS" else "PENDING",
               "Generated/volatile runtime paths independently classified " + path_status)
    report.add("PASS" if synced else "PENDING",
               "NTP synchronized" if synced else "NTP resynchronization unconfirmed")
    report.add("PENDING" if reboot_required else "PASS",
               "OS reboot-required marker still present" if reboot_required else "No OS reboot-required marker")
    return digest_paths(tracked_paths(secrets, storage))


def checkpoint_read() -> dict[str, object]:
    checkpoint = json.loads(private_read(CHECKPOINT, limit=8192))
    if (not isinstance(checkpoint, dict) or checkpoint.get("schema") != 1
            or checkpoint.get("host") != HOST or checkpoint.get("phase") not in ("requested", "verified")
            or checkpoint.get("release") != RELEASE
            or checkpoint.get("p8o_commit") != P8O_COMMIT
            or not SHA40.fullmatch(str(checkpoint.get("reviewed_commit", "")))
            or not isinstance(checkpoint.get("hashes"), dict)
            or not isinstance(checkpoint.get("original_boot_id"), str)):
        raise Blocked("reboot checkpoint identity or JSON schema invalid")
    return checkpoint


def exclusive_file(path: Path, payload: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(payload)
        output.flush()
        os.fsync(output.fileno())
    dirfd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(dirfd)
    finally:
        os.close(dirfd)


def checkpoint_finish(value: dict[str, object]) -> None:
    # Only advance requested -> verified, never allow checkpoint reset/replay.
    old = checkpoint_read()
    if old.get("phase") != "requested":
        raise Blocked("reboot checkpoint not in requested state")
    if any(old.get(key) != value.get(key) for key in
           ("host", "release", "p8o_commit", "reviewed_commit", "hashes", "original_boot_id")):
        raise Blocked("postboot checkpoint changes protected evidence")
    staged = CHECKPOINT.with_name(CHECKPOINT.name + ".new-" + str(os.getpid()))
    exclusive_file(staged, (json.dumps(value, sort_keys=True) + "\n").encode("utf-8"))
    try:
        os.replace(staged, CHECKPOINT)
        fd = os.open(CHECKPOINT.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        staged.unlink(missing_ok=True)


def private_log(folder: Path, name: str, argv: list[str], timeout: int) -> int | None:
    if name not in {"edge-rearm"}:
        raise Blocked("unexpected mutable program log target")
    fd = os.open(folder / (name + ".private.log"),
                 os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as log:
        try:
            result = subprocess.run(
                argv, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                cwd="/", timeout=timeout, check=False,
                env=dict(os.environ, HOME="/root", LC_ALL="C"),
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        return result.returncode


class Report:
    def __init__(self, output: Path, mode: str):
        self.output = output
        self.mode = mode
        self.rows: list[tuple[str, str]] = []
        self.mutation_started = False
        self.rearm_verified = False

    def add(self, status: str, content: str) -> None:
        if status not in ("PASS", "PENDING", "BLOCKED", "NOT RUN") or (
            len(content) > 250 or any(x in content for x in "\r\n\x00")
        ):
            raise ValueError("unsafe acceptance summary text")
        self.rows.append((status, content))

    def finish(self, outcome: str) -> int:
        if self.mutation_started and not self.rearm_verified:
            self.add("BLOCKED", "Local origin re-arm may be partial; preserve VM and never automatically retry")
        if any(level == "BLOCKED" for level, _ in self.rows):
            outcome = "BLOCKED"
        if outcome not in {"BLOCKED", "HOLD", "REBOOT_REQUESTED", "VERIFIED", "REARMED"}:
            outcome = "BLOCKED"
        self.rows.append((outcome, "P8P stopped-only reboot/persistence; public Caddy/Worker/DNS/Box and production GO forbidden"))
        body = "Gate P8P - new disposable host reboot and postboot security (" + self.mode + ")\n"
        body += "\n".join(f"{kind:<17}{message}" for kind, message in self.rows) + "\n"
        try:
            exclusive_file(self.output / "summary.txt", body.encode("utf-8"))
        except OSError:
            print("BLOCKED: root-private summary write failed")
            return 2
        print(body, end="")
        print("Private summary:", self.output / "summary.txt")
        print("Paste sanitized summary only; NO key, checkpoint, private logs, IP details or credentials.")
        return 2 if outcome == "BLOCKED" else 0


def reboot_once() -> bool:
    try:
        proc = subprocess.run(
            ["/usr/bin/systemctl", "reboot"], cwd="/",
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=30, check=False,
        )
        return proc.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def main() -> int:
    args = sys.argv[1:]
    mode = ""
    pin = ""
    if len(args) >= 4 and args[:1] == ["--expected-commit"] and args[2] == "--mode":
        pin, mode = args[1], args[3]
    console = args[4:] == ["--oci-console-ready"]
    if (not SHA40.fullmatch(pin) or not mode in {"reboot", "verify", "verify-and-rearm"}
            or args[4:] not in ([], ["--oci-console-ready"])
            or ((mode in {"reboot", "verify-and-rearm"}) != console)
            or not authorized_host() or not source_clean(pin)
            or (console and not (sys.stdin.isatty() and sys.stdout.isatty()))):
        print("BLOCKED: exact reviewed source/host required, reboot or rearm requires --oci-console-ready and SSH TTY")
        return 2
    try:
        accepted_p8o()
        if mode == "reboot":
            if CHECKPOINT.exists() or CHECKPOINT.is_symlink():
                raise Blocked("reboot one-shot checkpoint already exists; never reboot twice")
        else:
            saved = checkpoint_read()
            if saved.get("phase") != "requested" or saved.get("reviewed_commit") != pin:
                raise Blocked("original requested reboot checkpoint not eligible for verification")
            # A prior origin rearm attempt is never silently promoted to
            # VERIFIED even if the firewall appears healthy after a crash.
            if REARM_MARKER.exists() or REARM_MARKER.is_symlink():
                raise Blocked("prior P8P firewall rearm attempted; require separate partial-state review")
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        folder = EVIDENCE / ("p8p-" + mode + "-" + stamp + "-" + str(os.getpid()))
        folder.mkdir(mode=0o700)
    except Exception:
        print("BLOCKED: P8O authority, private checkpoint or one-shot replay boundary invalid")
        return 2
    report = Report(folder, mode)
    phase = "pre/postboot protected state snapshot"
    started_rearm = False
    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    original_handlers = {name: signal.getsignal(name) for name in signals}
    deferred: list[int] = []

    def interrupt(sig, frame):
        raise KeyboardInterrupt()

    def defer(sig, frame):
        deferred.append(sig)

    for signum in signals:
        signal.signal(signum, interrupt)
    try:
        now_boot = boot_id()
        if mode != "reboot":
            if saved.get("original_boot_id") == now_boot:
                raise Blocked("kernel boot ID unchanged; reboot did NOT occur")
            report.add("PASS", "Different kernel boot ID proves NEW VM really rebooted")
        before = snapshot(report, folder, after_boot=mode != "reboot")
        if mode == "reboot":
            if boot_id() != now_boot:
                raise Blocked("unexpected boot change during preflight")
            # Entire preboot snapshot and supporting private summaries MUST be
            # durably recorded before any reboot request can be issued.
            phase = "durable one-shot cold reboot checkpoint"
            checkpoint = {
                "schema": 1, "host": HOST, "release": RELEASE,
                "phase": "requested", "reviewed_commit": pin,
                "p8o_commit": P8O_COMMIT, "original_boot_id": now_boot,
                "hashes": before, "requested_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            }
            exclusive_file(CHECKPOINT, (json.dumps(checkpoint, sort_keys=True) + "\n").encode("utf-8"))
            report.add("PASS", "One-shot preboot kernel ID and protected config/SQLite/Age/SOPS/volume/security hashes durably pinned")
            report.add("PENDING", "Local reboot will disconnect SSH; OCI serial console recovery access required")
            report.add("NOT RUN", "No app, Caddy, DNS, Worker, SMTP, Box backup/prune, timer, restore or disk wipe")
            if report.finish("REBOOT_REQUESTED") != 0:
                print("BLOCKED: preboot evidence could not be safely recorded; no reboot request")
                return 2
            print("P8P: requesting exactly ONE disposable new-VM reboot; SSH may disconnect now.")
            sys.stdout.flush()
            if not reboot_once():
                print("BLOCKED: systemctl reboot request failed or timed out; DO NOT retry; inspect OCI console/checkpoint")
                return 2
            return 0

        phase = "postboot protected file digest comparison"
        compare_paths(saved, before)
        report.add("PASS", "Exact original config, Age/SOPS, volume markers, DB digest and source hashes survived cold reboot")
        sys.path.insert(0, str(INSTALLED))
        p5 = load_helper(P5_FILE, "p8p_postboot_doctor")
        checks, path_state, firewall_persisted = doctor(p5, folder, after_boot=True)
        if firewall_persisted:
            report.add("PASS", "Cloudflare-only Docker 443 filter already persisted; no local firewall mutation necessary")
        else:
            report.add("PENDING", "Docker origin policy not persistent after reboot; explicit installed-owner rearm is needed")
        if mode == "verify" and not firewall_persisted:
            report.add("NOT RUN", "Verification-only: no automatic firewall re-arm or public activation")
            return report.finish("HOLD")

        if mode == "verify-and-rearm" and not firewall_persisted:
            phase = "one-shot local Cloudflare origin filter rearm"
            if REARM_MARKER.exists() or REARM_MARKER.is_symlink():
                raise Blocked("earlier P8P origin re-arm attempt exists; cannot repeat")
            if boot_id() != now_boot:
                raise Blocked("boot changed during postboot pre-rearm inspection")
            # Revalidate all protected state immediately before mutation.
            confirm = snapshot(Report(folder, "rearm-preflight"), folder, after_boot=True)
            compare_paths(saved, confirm)
            report.add("PASS", "Immediate second stopped-host safety check before ONE origin rearm")
            exclusive_file(REARM_MARKER, (json.dumps({
                "schema": 1, "host": HOST, "reviewed_commit": pin,
                "original_boot_id": saved["original_boot_id"], "new_boot_id": now_boot,
            }, sort_keys=True) + "\n").encode("utf-8"))
            report.mutation_started = True
            started_rearm = True
            for sig in signals:
                signal.signal(sig, defer)
            print("P8P: Docker 443 origin rule was lost on cold boot; rearming ONLY local product-owned edge filter.")
            code = private_log(folder, "edge-rearm",
                               [sys.executable, "-B", "-E", str(INSTALLED / "vwctl"),
                                "edge", "refresh"], 180)
            if code != 0:
                raise Blocked("installed rc.12 edge refresh failed; preserve partial-state VM and private logs")
            phase = "postrearm full stopped-host readback"
            after = snapshot(report, folder, after_boot=True)
            compare_paths(saved, after)
            final_checks, _, restored_filter = doctor(p5, folder, after_boot=True)
            if not restored_filter or any(final_checks.get(key) != "PASS" for key in FOUNDATION):
                raise Blocked("postrearm product doctor and Cloudflare filter did not fully PASS")
            if deferred:
                raise Blocked("interrupt deferred during local firewall change; preserve VM")
            report.rearm_verified = True
            report.add("PASS", "Installed product origin filter rearmed; all five foundation doctors now PASS")
            report.add("PENDING", "Original Docker 443 policy did NOT persist across cold boot; rearm was needed")
        else:
            report.add("PASS", "All five required local security doctor checks PASS without rearm")
        if boot_id() != now_boot:
            raise Blocked("unexpected extra reboot during verification")
        phase = "final durable checkpoint"
        completed = dict(saved, phase="verified", verified_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                         verified_boot_id=now_boot, rearmed=started_rearm)
        checkpoint_finish(completed)
        report.add("PASS", "Reboot checkpoint verified and advanced exactly once; source/data/security invariants preserved")
        report.add("PENDING", "Worker Route Fail Open and shared public hostname isolation still need separate external attestation")
        report.add("PENDING", "Original Box destination remains configured; timers/backup writes still prohibited")
        report.add("PENDING", "Disposable unencrypted ext4 has possible deleted plaintext residuals; securely retire after testing")
        report.add("NOT RUN", "No live app, Worker/DNS/Cloudflare API, SMTP, Box publication/pruning, timers or restore")
        return report.finish("REARMED" if started_rearm else "VERIFIED")
    except KeyboardInterrupt:
        report.add("BLOCKED", "Interrupted during " + phase + "; no automatic reboot/rearm retry")
        return report.finish("BLOCKED")
    except Exception:
        report.add("BLOCKED", "Integrity or safety failure during " + phase +
                   "; private details withheld, preserve original disk and evidence")
        return report.finish("BLOCKED")
    finally:
        for signum, original in original_handlers.items():
            signal.signal(signum, original)


if __name__ == "__main__":
    raise SystemExit(main())
