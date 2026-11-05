#!/usr/bin/env python3
"""P8O: one-shot isolated NEW-VM host security foundation plus post-change audit.

This acceptance-only command binds accepted P8M/P8N recovery data, validates
the stopped state and 27-ID doctor, and may make TWO bounded LOCAL changes:
installed vwctl edge refresh; installed vwctl crowdsec setup. The option
--apply-disposable --oci-console-ready is required for those changes.
No application/Worker start, Box write, DNS/Cloudflare API or reboot.
A durable attempt marker prevents silent retry after partial mutation.
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
BRANCH = "audit/rc12-p8o-batched-local-security-foundation"
SRC = Path(__file__).resolve().parents[2]
VERSION = "0.1.0-rc.12"
INSTALLED = Path("/opt/vaultwarden-oci/releases") / VERSION
CURRENT = Path("/opt/vaultwarden-oci/current")
STATE = Path("/var/lib/vaultwarden-oci")
CONFIG = Path("/etc/vaultwarden-oci/config.toml")
EVIDENCE = Path(pwd.getpwnam("ubuntu").pw_dir) / "vwoci-acceptance"
P8M_ATTEMPT = EVIDENCE / "p8m-one-shot-disposable-restore-attempt.json"
P8N_SUMMARY = EVIDENCE / "p8n-postrestore-20261105T192801Z-16689/summary.txt"
ATTEMPT = EVIDENCE / "p8o-security-foundation-one-shot-attempt.json"
P1 = SRC / "tests/host-acceptance/production-recovery-source-preflight.py"
P5 = SRC / "tests/host-acceptance/production-security-foundation-consent.py"
P8M_COMMIT = "44d078113a67215cacd34df674a07c8f42afb219"
DB_SHA = "075163445a045cf274f7b1bf52ecb4f8f90b460cf13de418664c1c60cbfe9a35"
CIPHER_SHA = "ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060"
RECIPIENT_SHA = "7d08721bcc02bbef7dae1f07bfde244852560c69d0b72f8dc0fcba0da30c6773"
VOLUME_FP = "2449f67320a1"
DOMAIN = "bw.lazymocha.com"
EMAIL = "bw@lazymocha.com"
REMOTE = "bw-backup:bw-backup"
FOUNDATION = (
    "edge.cloudflare.cidrs", "edge.cloudflare.iptables", "crowdsec.engine",
    "crowdsec.hub", "crowdsec.firewall",
)
UNCONFIGURED = set(FOUNDATION) | {"crowdsec.cloudflare", "runtime.paths"}
MANDATORY = {"host.os", "host.architecture", "storage.dedicated",
             "secrets.custody", "secrets.decrypt"}
SHA40 = re.compile(r"[0-9a-f]{40}\Z")


class Blocked(RuntimeError):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run(args: list[str], *, seconds: int = 30) -> tuple[int | None, str]:
    try:
        result = subprocess.run(
            args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, cwd="/", timeout=seconds, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    if len(result.stdout) > 262144:
        return None, ""
    return result.returncode, result.stdout.decode("utf-8", "replace")


def source_clean(pin: str) -> bool:
    if not SHA40.fullmatch(pin):
        return False
    results: list[str] = []
    for args in (("rev-parse", "HEAD"), ("branch", "--show-current"),
                 ("status", "--porcelain", "--untracked-files=all")):
        try:
            p = subprocess.run(["/usr/bin/git", *args], cwd=SRC, check=False,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=20,
                               env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
        except (OSError, subprocess.TimeoutExpired):
            return False
        if p.returncode != 0 or len(p.stdout) > 8192:
            return False
        results.append(p.stdout.decode("utf-8", "replace").strip())
    return results == [pin, BRANCH, ""]


def authorized_host() -> bool:
    if (os.geteuid() != 0 or os.environ.get("SUDO_USER") != "ubuntu"
            or platform.node().split(".")[0] != HOST
            or platform.machine() not in ("aarch64", "arm64")
            or sys.version_info[:2] != (3, 14)):
        return False
    try:
        os_release = dict(line.split("=", 1) for line in
                          Path("/etc/os-release").read_text(encoding="utf-8").splitlines()
                          if "=" in line)
        import tomllib
        with (SRC / "versions.toml").open("rb") as handle:
            release = tomllib.load(handle)["vaultwarden_oci"]["version"]
        return (os_release.get("ID", "").strip('"') == "ubuntu"
                and os_release.get("VERSION_ID", "").strip('"') == "26.04"
                and os_release.get("VERSION_CODENAME", "").strip('"') == "resolute"
                and release == VERSION)
    except (OSError, ValueError, KeyError, TypeError):
        return False


def private_directory(path: Path, uid: set[int]) -> None:
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in uid
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise Blocked("root-private evidence directory metadata changed")


def private_bytes(path: Path, maximum: int = 131072) -> bytes:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) != 0o600
                or not 0 < info.st_size <= maximum):
            raise Blocked("root-private historical evidence unsafe")
        return handle.read(maximum + 1)


def historical_recovery() -> None:
    private_directory(EVIDENCE, {0, pwd.getpwnam("ubuntu").pw_uid})
    private_directory(P8N_SUMMARY.parent, {0})
    attempt = json.loads(private_bytes(P8M_ATTEMPT))
    if (attempt.get("schema") != 1 or attempt.get("host") != HOST
            or attempt.get("reviewed_source") != P8M_COMMIT
            or attempt.get("ciphertext_sha256") != CIPHER_SHA
            or attempt.get("data_uuid_fingerprint") != VOLUME_FP):
        raise Blocked("P8M one-shot marker changed")
    summary = private_bytes(P8N_SUMMARY).decode("utf-8", "strict")
    expected = (
        "Gate P8N - postrestore security/readiness inventory (READ-ONLY)",
        "PASS       Original P8M RESTORED evidence",
        "PASS       52 immutable product files, 12 installed units",
        "PASS       Installed product 27-ID doctor validated",
        "HOLD       P8N stopped-only postrestore readiness",
    )
    if any(part not in summary for part in expected):
        raise Blocked("accepted original P8N HOLD evidence missing")


def imported_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise Blocked("reviewed source helper absent")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sqlite_sha_integrity(db: Path) -> bool:
    try:
        info = db.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size < 100:
            return False
        link = "file:" + quote(str(db), safe="/") + "?mode=ro&immutable=1"
        conn = sqlite3.connect(link, timeout=5, uri=True)
        try:
            verified = conn.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
            count = conn.execute(
                "SELECT count(*) FROM sqlite_master WHERE type='table'"
            ).fetchone()
        finally:
            conn.close()
        return verified and bool(count and count[0] > 0) and digest(db.read_bytes()) == DB_SHA
    except (sqlite3.Error, OSError, TypeError, ValueError):
        return False


def unit_state(name: str) -> dict[str, str]:
    code, data = run(["/usr/bin/systemctl", "show", name, "--no-pager",
                      "-p", "LoadState", "-p", "ActiveState", "-p", "UnitFileState"])
    if code != 0:
        raise Blocked("systemd state unavailable")
    return dict(line.split("=", 1) for line in data.splitlines() if "=" in line)


def stopped_appliance(units: tuple[str, ...]) -> None:
    if len(units) != 12 or "vaultwarden-oci-notify@.service" not in units:
        raise Blocked("installed systemd unit contract differs")
    for name in units:
        if name == "vaultwarden-oci-notify@.service":
            continue
        state = unit_state(name)
        if (state.get("LoadState") != "loaded"
                or state.get("ActiveState") != "inactive"
                or state.get("UnitFileState") in
                {"enabled", "enabled-runtime", "linked", "linked-runtime"}):
            raise Blocked("application or timers unexpectedly active/enabled")
    code, text = run(["/usr/bin/systemctl", "list-units", "--all", "--no-legend",
                      "--plain", "--full", "vaultwarden-oci-notify@*.service"])
    if code != 0 or text.strip():
        raise Blocked("unexpected notification instance")
    code, text = run(["/usr/bin/systemctl", "list-unit-files", "--all",
                      "--no-legend", "--plain", "vaultwarden-oci-notify@*.service"])
    if code != 0 or [x.split()[:2] for x in text.splitlines()] != [
        ["vaultwarden-oci-notify@.service", "static"]
    ]:
        raise Blocked("notification template changed")
    code, text = run(["/usr/bin/ss", "-H", "-lnt"])
    if code != 0:
        raise Blocked("TCP listener inventory missing")
    for line in text.splitlines():
        columns = line.split()
        found = re.search(r":([0-9]{1,5})$", columns[3]) if len(columns) >= 5 else None
        if found is None or int(found.group(1)) in (80, 443, 2375, 2376):
            raise Blocked("unexpected HTTP or Docker TCP listener")
    code, text = run(["/usr/bin/docker", "ps", "--format", "{{.ID}}"], seconds=25)
    if code != 0 or text.strip():
        raise Blocked("Docker inaccessible or container running")
    meta = Path("/var/lib/docker/containers")
    if meta.exists() or meta.is_symlink():
        if meta.is_symlink() or not meta.is_dir() or any(meta.iterdir()):
            raise Blocked("Docker retained container unexpected")
    guard = STATE / "state/update-recovery-required.json"
    if guard.exists() or guard.is_symlink():
        raise Blocked("update recovery-required guard present")
    worker = unit_state("crowdsec-cloudflare-worker-bouncer.service")
    if worker.get("ActiveState") not in ("inactive", "failed") or worker.get("UnitFileState") in (
        "enabled", "enabled-runtime", "linked", "linked-runtime"
    ):
        raise Blocked("Cloudflare Worker is active or boot-enabled")
    if worker.get("ActiveState") == "failed":
        raise Blocked("Cloudflare Worker failed/partial state")


def security_state(*, installed: bool) -> None:
    worker = unit_state("crowdsec-cloudflare-worker-bouncer.service")
    if installed and (worker.get("LoadState") != "loaded"
                      or worker.get("ActiveState") != "inactive"
                      or worker.get("UnitFileState") != "disabled"):
        raise Blocked("Worker must remain present, disabled and inactive")
    if not installed:
        if Path("/usr/bin/cscli").exists():
            raise Blocked("partial preexisting CrowdSec package")
        for service in ("crowdsec.service", "crowdsec-firewall-bouncer.service",
                        "crowdsec-cloudflare-worker-bouncer.service"):
            state = unit_state(service)
            if state.get("LoadState") == "loaded":
                raise Blocked("unexpected preexisting CrowdSec partial installation")
    else:
        if not Path("/usr/bin/cscli").is_file():
            raise Blocked("CrowdSec executable missing after setup")
        for service in ("crowdsec.service", "crowdsec-firewall-bouncer.service"):
            state = unit_state(service)
            if (state.get("LoadState") != "loaded"
                    or state.get("ActiveState") != "active"
                    or state.get("UnitFileState") != "enabled"):
                raise Blocked("CrowdSec engine/INPUT bouncer not active and boot-enabled")


def host_operational() -> tuple[bool, bool]:
    code, audit = run(["/usr/bin/dpkg", "--audit"], seconds=45)
    if code != 0 or audit.strip():
        raise Blocked("dpkg package audit not clean")
    code, ntp = run(["/usr/bin/timedatectl", "show", "-p", "NTPSynchronized", "--value"])
    if code != 0 or ntp.strip().lower() not in ("yes", "true", "1"):
        raise Blocked("NTP not synchronized")
    code, mount = run(["/usr/bin/findmnt", "-n", "-o", "FSTYPE", "--target", "/run"])
    if code != 0 or mount.strip() != "tmpfs":
        raise Blocked("/run volatile memory not tmpfs")
    try:
        swap = Path("/proc/swaps").read_text(encoding="ascii").splitlines()
    except OSError as exc:
        raise Blocked("swap status unreadable") from exc
    if len(swap) != 1 or not swap[0].startswith("Filename"):
        raise Blocked("active swap present")
    return Path("/run/reboot-required").exists(), True


def protected_state(p1, install, runtime, secrets, storage) -> bytes:
    if not CURRENT.is_symlink() or CURRENT.resolve(strict=True) != INSTALLED:
        raise Blocked("immutable installed current pointer differs")
    if p1.release_integrity(SRC, INSTALLED) != (True, 52):
        raise Blocked("52 installed product file digests differ")
    if p1.systemd_unit_integrity(INSTALLED) != (True, 12):
        raise Blocked("12 installed unit definitions differ")
    proof = storage.verify()
    storage.reject_boot_related(proof.source)
    if (proof.fs_type != "ext4" or digest(proof.uuid.encode())[:12] != VOLUME_FP
            or os.stat(STATE).st_dev == os.stat("/").st_dev):
        raise Blocked("dedicated original recovery volume changed")
    cfg = runtime.load_config()
    if (cfg.domain != DOMAIN or cfg.acme_email != EMAIL
            or digest(cfg.offline_recovery_recipient.encode()) != RECIPIENT_SHA
            or cfg.offsite_remote != REMOTE
            or type(cfg.local_retention_days) is not int
            or type(cfg.remote_retention_days) is not int
            or cfg.local_retention_days != 0 or cfg.remote_retention_days != 0):
        raise Blocked("restored public recipient/backup retention or hostname differs")
    secrets.validate_custody(cfg.offline_recovery_recipient)
    values = secrets.validate_encrypted(cfg.offline_recovery_recipient)
    if not isinstance(values, dict) or not values.get("cloudflare_remediation_token"):
        raise Blocked("operational original SOPS/Cloudflare remediation custody unavailable")
    del values
    if not sqlite_sha_integrity(STATE / "data/db.sqlite3"):
        raise Blocked("restored SQLite integrity/digest changed")
    stopped_appliance(tuple(install.SYSTEMD_UNITS))
    return digest(CONFIG.read_bytes()).encode("ascii")


def check_doctor(p5, folder: Path, label: str, *, after: bool) -> tuple[dict[str, str], str]:
    decision, checks, detail = p5.diagnose_doctor(folder, label, seconds=180)
    if decision != "valid":
        raise Blocked("27-ID product doctor invalid: " + decision)
    names = p5.product_doctor_ids()
    if set(checks) != set(names):
        raise Blocked("product doctor registry unexpectedly changed")
    if any(checks.get(item) != "PASS" for item in MANDATORY):
        raise Blocked("mandatory OS/dedicated storage/SOPS doctor control failed")
    failures = {name for name, status in checks.items() if status == "FAIL"}
    if not failures <= UNCONFIGURED:
        raise Blocked("unexpected failing product doctor ID")
    for key in FOUNDATION:
        if after and checks.get(key) != "PASS":
            raise Blocked("required postfoundation doctor control failed: " + key)
        if not after and checks.get(key) != "FAIL":
            raise Blocked("prechange foundation state unexpected: " + key)
    if checks.get("crowdsec.cloudflare") == "PASS":
        raise Blocked("Cloudflare Worker must not claim current remediation PASS")
    from vaultwarden_oci import runtime, secrets
    path_state, safe_summary = p5.inspect_stopped_runtime_paths(runtime, secrets)
    if path_state == "BLOCKED":
        raise Blocked("unsafe stopped runtime paths: " + safe_summary)
    if ((checks.get("runtime.paths") == "PASS") != (path_state == "PASS")):
        raise Blocked("installed runtime.paths and independent path inventory disagree")
    return checks, path_state


def private_log(folder: Path, filename: str, argv: list[str], seconds: int) -> int | None:
    output = folder / (filename + ".private.log")
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        try:
            task = subprocess.run(
                argv, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
                cwd="/", timeout=seconds, check=False,
                env=dict(os.environ, HOME="/root", LC_ALL="C"),
            )
            return task.returncode
        except (OSError, subprocess.TimeoutExpired):
            return None


def write_exclusive(path: Path, contents: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(contents)
        handle.flush()
        os.fsync(handle.fileno())
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


class Report:
    def __init__(self, folder: Path, apply: bool) -> None:
        self.folder = folder
        self.apply = apply
        self.rows: list[tuple[str, str]] = []
        self.mutation_started = False
        self.verified = False

    def record(self, kind: str, message: str) -> None:
        if kind not in {"PASS", "PENDING", "BLOCKED", "NOT RUN"} or any(
            c in message for c in "\r\n\x00"
        ) or len(message) > 240:
            raise ValueError("unsafe status row")
        self.rows.append((kind, message))

    def finish(self) -> int:
        failed = any(row[0] == "BLOCKED" for row in self.rows)
        if failed or (self.mutation_started and not self.verified):
            status, code = "BLOCKED", 2
            if self.mutation_started and not self.verified:
                self.record("BLOCKED", "VM-local security mutation started: possible partial host state; preserve VM, do not rerun")
        elif self.mutation_started and self.verified:
            status, code = "FOUNDATION", 0
        else:
            status, code = "HOLD", 0
        self.rows.append((status, "P8O batched local security only; NO live hostname/Box write/production GO"))
        body = "Gate P8O - NEW disposable host batched security foundation and postverification\n"
        body += "\n".join(f"{k:<10} {v}" for k, v in self.rows) + "\n"
        try:
            write_exclusive(self.folder / "summary.txt", body.encode("utf-8"))
        except OSError:
            print("BLOCKED: root-private P8O summary durability failure")
            return 2
        print(body, end="")
        print("Private summary:", self.folder / "summary.txt")
        print("Paste ONLY sanitized summary and P8O_EXIT; never private logs, credentials, doctor output or marker.")
        return code


def main() -> int:
    args = sys.argv[1:]
    apply = len(args) == 4 and args[2:] == ["--apply-disposable", "--oci-console-ready"]
    if ((len(args) != 2 and not apply) or args[0] != "--expected-commit"
            or not SHA40.fullmatch(args[1]) or not authorized_host()
            or not source_clean(args[1]) or (apply and
            not (sys.stdin.isatty() and sys.stdout.isatty()))):
        print("BLOCKED: use exact reviewed commit on NEW ARM64 Ubuntu SSH host; apply requires console-ready flag and TTY")
        return 2
    try:
        historical_recovery()
        if ATTEMPT.exists() or ATTEMPT.is_symlink():
            raise Blocked("P8O security mutation was already attempted; cannot safely repeat")
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        folder = EVIDENCE / f"p8o-security-batch-{stamp}-{os.getpid()}"
        folder.mkdir(mode=0o700)
    except Exception:
        print("BLOCKED: previous recovery evidence or exclusive P8O attempt marker unsafe")
        return 2
    report = Report(folder, apply)
    phase = "source, restored data and stopped state"
    seen_interrupts: list[int] = []
    watched = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    old_handlers = {s: signal.getsignal(s) for s in watched}

    def interrupt(signum, frame):
        raise KeyboardInterrupt()

    def defer_interrupt(signum, frame):
        seen_interrupts.append(signum)

    for sig in watched:
        signal.signal(sig, interrupt)
    try:
        if str(INSTALLED) not in sys.path:
            sys.path.insert(0, str(INSTALLED))
        from vaultwarden_oci import install, runtime, secrets, storage
        p1 = imported_module(P1, "p8o_release_witness")
        p5 = imported_module(P5, "p8o_security_metadata_witness")
        config_pin = protected_state(p1, install, runtime, secrets, storage)
        report.record("PASS", "Original P8M restore and P8N HOLD, source and immutable 52 files/12 units verified")
        report.record("PASS", "Dedicated ext4, SQLite full integrity/exact historical digest, SOPS/Age custody and zero retention")
        report.record("PASS", "11 application/DNS/timers inactive, no HTTP80/443, Docker container or pending update guard")
        report.record("PENDING", "Recovered ORIGINAL Box destination remains configured; backups/timers MUST stay disabled")

        phase = "current host and security foundation preflight"
        security_state(installed=False)
        reboot_pre, _ = host_operational()
        statuses, paths = check_doctor(p5, folder, "before", after=False)
        report.record("PASS", "Full 27-ID installed doctor, mandatory host/storage/secrets PASS; exactly five foundation checks FAIL before setup")
        report.record("PASS" if paths == "PASS" else "PENDING",
                      "Independent stopped runtime.paths classification=" + paths + " (unsafe paths are BLOCKED)")
        report.record("PASS", "No prior CrowdSec engine/INPUT bouncer/Worker installation; dpkg/NTP/tmpfs/no-swap checks PASS")
        if reboot_pre:
            report.record("PENDING", "Pre-existing OS reboot-required marker; NO reboot included in this batch")
        if not apply:
            report.record("NOT RUN", "Read-only mode: no local firewall/CrowdSec change, cloud write, app start, SMTP or backup")
            return report.finish()

        phase = "one-shot VM-local security setup"
        # The operator already approved disposable VM tests. In this one-shot
        # command the explicit flags attest they have working OCI serial
        # console access at the time of the firewall-changing invocation.
        # No separate typed approval; no external-host changes authorized.
        if ATTEMPT.exists() or ATTEMPT.is_symlink():
            raise Blocked("prior security foundation attempt marker exists")
        protected_state(p1, install, runtime, secrets, storage)
        security_state(installed=False)
        report.record("PASS", "NEW disposable VM scope and explicit --apply-disposable --oci-console-ready flags verified")
        print("P8O: applying host-local firewall/CrowdSec to NEW disposable host ONLY.")
        print("OCI serial console must be accessible; no cloud/DNS/Box/Worker/Vaultwarden start.")
        write_exclusive(ATTEMPT, (json.dumps({
            "schema": 1, "host": HOST, "reviewed_commit": args[1],
            "db_sha256": DB_SHA, "volume_fingerprint": VOLUME_FP,
            "attempt_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        }, sort_keys=True) + "\n").encode("utf-8"))
        for sig in watched:
            signal.signal(sig, defer_interrupt)
        report.mutation_started = True

        print("P8O: stage 1/2 — installed Cloudflare origin filter.")
        phase = "Cloudflare-only origin filter"
        edge = private_log(folder, "edge-refresh",
                           [sys.executable, "-B", "-E", str(INSTALLED / "vwctl"), "edge", "refresh"], 180)
        if edge != 0:
            raise Blocked("installed edge refresh failed or timed out; private log retained")
        report.record("PASS", "Installed product established Cloudflare-only Docker 443 filter")

        print("P8O: stage 2/2 — installed CrowdSec engine and host INPUT bouncer.")
        phase = "CrowdSec package, Hub and INPUT-only firewall setup"
        crowdsec = private_log(folder, "crowdsec-setup",
                              [sys.executable, "-B", "-E", str(INSTALLED / "vwctl"), "crowdsec", "setup"], 2400)
        if crowdsec != 0:
            raise Blocked("installed CrowdSec package/engine/INPUT setup failed; private log retained")
        report.record("PASS", "Installed product configured CrowdSec/Hub and INPUT-only host firewall")

        phase = "immediate postfoundation audit"
        after_config = protected_state(p1, install, runtime, secrets, storage)
        if config_pin != after_config:
            raise Blocked("restored protected config changed during security setup")
        security_state(installed=True)
        _, after_paths = check_doctor(p5, folder, "after", after=True)
        reboot_after, _ = host_operational()
        report.record("PASS", "Five required foundation doctor IDs PASS: CIDR/iptables, CrowdSec engine/Hub/INPUT")
        report.record("PASS", "CrowdSec engine/host bouncer active+enabled, Worker installed but inactive+disabled")
        report.record("PASS", "Immutable rc.12, restored database/SOPS, stopped app/DNS/timers and original Box no-prune config intact")
        report.record("PASS" if after_paths == "PASS" else "PENDING",
                      "Postfoundation stopped runtime.paths classification=" + after_paths + " (generated paths need live-start gate)")
        if reboot_after:
            report.record("PENDING", "OS reboot-required marker present after security packages; reboot must be separately gated")
        if seen_interrupts:
            raise Blocked("operator signal deferred during apt/firewall mutation; review partial state before next gate")
        report.record("PENDING", "Cloudflare Worker remediation remains disabled; current-invocation Fail Open not attested")
        report.record("PENDING", "Shared bw.lazymocha.com is NOT a distinct live origin; independent OCI/Cloudflare proof required")
        report.record("PENDING", "Prior restored plaintext staged on unencrypted disposable ext4; securely retire volume later")
        report.record("NOT RUN", "No Caddy/Vaultwarden/DNS/Worker/SMTP, Box read/write/prune, timers, backup, restore or reboot")
        report.verified = True
        return report.finish()
    except KeyboardInterrupt:
        report.record("BLOCKED" if report.mutation_started else "PENDING",
                      "Interrupted during " + phase + "; do not retry after any host mutation")
        return report.finish()
    except Exception:
        report.record("BLOCKED", "Safety or integrity failure during " + phase +
                      "; private details withheld; no automatic repair/retry")
        return report.finish()
    finally:
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    raise SystemExit(main())
