#!/usr/bin/env python3
"""P8N: read-only postrestore safety inventory on disposable rc.12 ARM64 VM.

No app, firewall, network, Box, Docker, timers, backups, or reboot mutations.
Private P8M evidence is checked locally and never printed verbatim.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import importlib.util
import json
import os
import platform
import re
import sqlite3
import stat
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-7-vnic"
BRANCH = "audit/rc12-p8n-postrestore-safety-readiness"
VERSION = "0.1.0-rc.12"
SOURCE = Path(__file__).resolve().parents[2]
RELEASE = Path("/opt/vaultwarden-oci/releases") / VERSION
STATE = Path("/var/lib/vaultwarden-oci")
EVIDENCE = Path("/home/ubuntu/vwoci-acceptance")
P8M_FOLDER = EVIDENCE / "p8m-crypto-and-restore-20261104T232842Z-5127"
P8M_MARKER = EVIDENCE / "p8m-one-shot-disposable-restore-attempt.json"
EXPECTED_DB = "075163445a045cf274f7b1bf52ecb4f8f90b460cf13de418664c1c60cbfe9a35"
EXPECTED_CIPHER = "ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060"
EXPECTED_RECIPIENT_SHA = "7d08721bcc02bbef7dae1f07bfde244852560c69d0b72f8dc0fcba0da30c6773"
EXPECTED_DISK_FP = "2449f67320a1"
EXPECTED_P8M_COMMIT = "44d078113a67215cacd34df674a07c8f42afb219"
REQUIRED = {"host.os", "host.architecture", "storage.dedicated", "secrets.custody", "secrets.decrypt"}
SECURITY = {"edge.cloudflare.cidrs", "edge.cloudflare.iptables", "crowdsec.engine",
            "crowdsec.hub", "crowdsec.firewall", "crowdsec.cloudflare"}
CRITICAL_PORTS = {80, 443, 2375, 2376}
SHA40 = re.compile(r"[0-9a-f]{40}\\Z")


class Blocked(Exception):
    pass


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def private_file(path: Path, *, max_bytes: int = 131072) -> bytes:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as handle:
        s = os.fstat(handle.fileno())
        if (not stat.S_ISREG(s.st_mode) or s.st_uid != 0 or
                stat.S_IMODE(s.st_mode) != 0o600 or not 0 < s.st_size <= max_bytes):
            raise Blocked("private source evidence metadata differs")
        return handle.read(max_bytes + 1)


def evidence_proof() -> None:
    for path in (EVIDENCE, P8M_FOLDER):
        s = path.lstat()
        if not stat.S_ISDIR(s.st_mode) or stat.S_IMODE(s.st_mode) != 0o700 or s.st_uid not in (0, 1000):
            raise Blocked("private evidence directory unsafe")
    marker = json.loads(private_file(P8M_MARKER))
    if (marker.get("schema") != 1 or marker.get("host") != HOST or
            marker.get("reviewed_source") != EXPECTED_P8M_COMMIT or
            marker.get("ciphertext_sha256") != EXPECTED_CIPHER or
            marker.get("data_uuid_fingerprint") != EXPECTED_DISK_FP):
        raise Blocked("one-shot historical recovery marker mismatch")
    summary = private_file(P8M_FOLDER / "summary.txt").decode("utf-8", "strict")
    required_lines = (
        "RESTORED   P8M VM-only cryptographic candidate validation",
        "PASS       Installed immutable rc.12 recovery owner restored exactly original pinned artifact",
        "PASS       Recovered SQLite full integrity/digest",
    )
    if not all(token in summary for token in required_lines):
        raise Blocked("P8M acceptance summary does not prove completed restore")


def run(argv: list[str], timeout: int = 30) -> tuple[int | None, str]:
    try:
        proc = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, check=False, cwd="/", timeout=timeout)
        if len(proc.stdout) > 262144:
            return None, ""
        return proc.returncode, proc.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return None, ""


def clean_source(pin: str) -> bool:
    if not SHA40.fullmatch(pin):
        return False
    results = []
    for args in (("rev-parse", "HEAD"), ("branch", "--show-current"),
                 ("status", "--porcelain", "--untracked-files=all")):
        try:
            p = subprocess.run(["/usr/bin/git", *args], cwd=SOURCE, check=False,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=15,
                               env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
            if p.returncode or len(p.stdout) > 8192:
                return False
            results.append(p.stdout.decode().strip())
        except (OSError, subprocess.TimeoutExpired, UnicodeError):
            return False
    return results == [pin, BRANCH, ""]


def host_ok() -> bool:
    if (os.geteuid() != 0 or os.getenv("SUDO_USER") != "ubuntu" or
            platform.node().split(".")[0] != HOST or
            platform.machine() not in ("aarch64", "arm64") or
            sys.version_info[:2] != (3, 14)):
        return False
    try:
        lines = Path("/etc/os-release").read_text().splitlines()
        facts = dict(x.split("=", 1) for x in lines if "=" in x)
        return facts.get("ID", "").strip('"') == "ubuntu" and facts.get("VERSION_ID", "").strip('"') == "26.04"
    except OSError:
        return False


def sqlite_integrity(path: Path) -> bool:
    try:
        s = path.lstat()
        if not stat.S_ISREG(s.st_mode) or s.st_size < 100:
            return False
        db = sqlite3.connect("file:" + quote(str(path), safe="/") + "?mode=ro&immutable=1", uri=True, timeout=5)
        try:
            ok = db.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
            count = db.execute("SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()
            return ok and bool(count and count[0] > 0) and sha(path.read_bytes()) == EXPECTED_DB
        finally:
            db.close()
    except (OSError, sqlite3.Error, ValueError):
        return False


def classify_doctor(raw: str, code: int | None, allowed: tuple[str, ...]) -> dict[str, str]:
    """Fail closed on an incomplete or inconsistent doctor registry."""
    if code not in (0, 1) or len(raw) > 262144:
        raise Blocked("installed doctor unavailable")
    try:
        doc = json.loads(raw)
        if doc.get("schema_version") != 1 or not isinstance(doc.get("checks"), list):
            raise Blocked("doctor schema differs")
        result: dict[str, str] = {}
        for item in doc["checks"]:
            name, status = item["id"], item["status"]
            if name in result or name not in allowed or status not in ("PASS", "WARN", "FAIL", "SKIP"):
                raise Blocked("unexpected doctor check")
            result[name] = status
        if set(result) != set(allowed):
            raise Blocked("doctor check inventory incomplete")
        overall = ("FAIL" if "FAIL" in result.values() else
                   "WARN" if "WARN" in result.values() else
                   "SKIP" if set(result.values()) == {"SKIP"} else "PASS")
        if doc.get("overall") != overall or (code == 0) != (overall != "FAIL"):
            raise Blocked("doctor overall/exit mismatch")
        return result
    except (TypeError, KeyError, ValueError, AttributeError) as exc:
        raise Blocked("untrusted doctor data") from exc


def check_units(units: tuple[str, ...]) -> None:
    if len(units) != 12 or "vaultwarden-oci-notify@.service" not in units:
        raise Blocked("unit registry changed")
    for unit in units:
        if unit.endswith("@.service"):
            continue
        code, raw = run(["/usr/bin/systemctl", "show", unit,
                         "-p", "ActiveState", "-p", "UnitFileState", "-p", "LoadState"])
        fields = dict(x.split("=", 1) for x in raw.splitlines() if "=" in x)
        if (code != 0 or fields.get("LoadState") != "loaded" or
                fields.get("ActiveState") != "inactive" or
                fields.get("UnitFileState") in ("enabled", "enabled-runtime", "linked", "linked-runtime")):
            raise Blocked("unexpected installed application/DNS/timer activation")
    code, raw = run(["/usr/bin/systemctl", "list-units", "--all", "--no-legend",
                     "--plain", "--full", "vaultwarden-oci-notify@*.service"])
    if code != 0 or raw.strip():
        raise Blocked("instantiated notification unit detected")


def check_ports() -> None:
    code, raw = run(["/usr/bin/ss", "-H", "-lnt"])
    if code != 0:
        raise Blocked("TCP socket inventory unavailable")
    for row in raw.splitlines():
        cells = row.split()
        match = re.search(r":([0-9]{1,5})$", cells[3]) if len(cells) >= 5 else None
        if not match or int(match.group(1)) in CRITICAL_PORTS:
            raise Blocked("HTTP or Docker TCP exposure detected")
    code, running = run(["/usr/bin/docker", "ps", "--format", "{{.ID}}"])
    if code != 0 or running.strip():
        raise Blocked("Docker unavailable or unexpected running container")


def main() -> int:
    args = sys.argv[1:]
    if (len(args) != 2 or args[0] != "--expected-commit" or not SHA40.fullmatch(args[1]) or
            not host_ok() or not clean_source(args[1])):
        print("BLOCKED: wrong host, invalid exact-commit checkout or unsafe invocation")
        return 2
    rows: list[tuple[str, str]] = []
    def row(level: str, message: str) -> None:
        rows.append((level, message))
    try:
        evidence_proof()
        row("PASS", "Original P8M RESTORED evidence, reviewed SHA and durable one-shot marker intact")
        if (not (Path("/opt/vaultwarden-oci/current").is_symlink()) or
                Path("/opt/vaultwarden-oci/current").resolve(strict=True) != RELEASE):
            raise Blocked("immutable release link differs")
        sys.path.insert(0, str(RELEASE))
        from vaultwarden_oci import install, runtime, secrets, storage, cli, update_cli
        witness_path = SOURCE / "tests/host-acceptance/production-recovery-source-preflight.py"
        spec = importlib.util.spec_from_file_location("p8n_witness", witness_path)
        if not spec or not spec.loader:
            raise Blocked("reviewed release witness missing")
        witness = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(witness)
        if witness.release_integrity(SOURCE, RELEASE) != (True, 52) or witness.systemd_unit_integrity(RELEASE) != (True, 12):
            raise Blocked("installed release/product units modified")
        proof = storage.verify()
        storage.reject_boot_related(proof.source)
        if (proof.fs_type != "ext4" or sha(proof.uuid.encode())[:12] != EXPECTED_DISK_FP or
                os.stat(STATE).st_dev == os.stat("/").st_dev):
            raise Blocked("dedicated ext4 identity changed or boot-device fallback")
        if not sqlite_integrity(STATE / "data/db.sqlite3"):
            raise Blocked("restored SQLite full integrity/digest mismatch")
        row("PASS", "52 immutable product files, 12 installed units, dedicated ext4 and pinned restored SQLite integrity")
        cfg = runtime.load_config()
        if (cfg.domain != "bw.lazymocha.com" or cfg.acme_email != "bw@lazymocha.com" or
                sha(cfg.offline_recovery_recipient.encode()) != EXPECTED_RECIPIENT_SHA or
                cfg.local_retention_days != 0 or cfg.remote_retention_days != 0):
            raise Blocked("historical recovery hostname/recipient/retention changed")
        secrets.validate_custody(cfg.offline_recovery_recipient)
        unused = secrets.decrypt()
        del unused
        row("PASS", "Original public Age recipient, SOPS decrypt and no-prune retention=0/0")
        check_units(tuple(install.SYSTEMD_UNITS))
        check_ports()
        row("PASS", "All application/DNS/timers stopped, no active notifications, HTTP80/443 or Docker containers")
        guard = STATE / "state/update-recovery-required.json"
        if guard.exists() or guard.is_symlink():
            raise Blocked("update recovery guard present")
        row("PASS", "No unresolved update-recovery guard")
        if cfg.offsite_remote is not None:
            row("PENDING", "Recovered historical offsite destination is configured; prohibit backup publication/timers until isolated test prefix validated")
        else:
            row("PASS", "No recovered offsite destination configured")
        from vaultwarden_oci import cli as product_cli
        names = tuple(product_cli.DOCTOR_CHECK_IDS)
        if len(names) != 27 or len(set(names)) != 27 or not REQUIRED | SECURITY <= set(names):
            raise Blocked("27-ID product doctor registry changed")
        rc, raw = run([sys.executable, "-B", "-E", str(RELEASE / "vwctl"), "doctor", "--json"], 120)
        checks = classify_doctor(raw, rc, names)
        if any(checks[k] != "PASS" for k in REQUIRED):
            raise Blocked("mandatory OS/storage/secrets doctor controls failed")
        row("PASS", "Installed product 27-ID doctor validated; required host/storage/SOPS checks PASS")
        for item in sorted(SECURITY):
            row("PASS" if checks[item] == "PASS" else "PENDING",
                "Doctor security check " + item + "=" + checks[item] +
                (" (read-only evidence only)" if checks[item] == "PASS" else "; foundation not yet accepted"))
        for item in sorted(set(names) - REQUIRED - SECURITY):
            if checks[item] == "FAIL":
                row("PENDING", "Other installed doctor check " + item + "=FAIL; diagnose before activation")
        row("PENDING", "Independent OCI/Cloudflare current live-origin and Worker-route proof absent; shared hostname prohibits public start")
        row("PENDING", "Encrypted backup confidentiality: restore staged plaintext on disposable unencrypted ext4; retire volume after testing")
        row("NOT RUN", "No firewall/CrowdSec/DNS/Worker/Box/SMTP changes, timers, app/Caddy start, restore or reboot")
        state, exit_code = "HOLD", 0
    except Exception:
        row("BLOCKED", "P8N postrestore local audit failed; preserve stopped VM and private evidence; no automatic repair")
        state, exit_code = "BLOCKED", 2
    rows.append((state, "P8N stopped-only postrestore readiness; public service/Box write/production GO not authorized"))
    text = "Gate P8N - postrestore security/readiness inventory (READ-ONLY)\n"
    text += "".join(f"{status:<10} {message}\n" for status, message in rows)
    print(text, end="")
    try:
        if not EVIDENCE.is_dir():
            raise OSError("missing evidence root")
        dest = EVIDENCE / ("p8n-postrestore-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + str(os.getpid()))
        dest.mkdir(mode=0o700)
        fd = os.open(dest / "summary.txt", os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        print("Private summary:", dest / "summary.txt")
    except OSError:
        print("BLOCKED: could not persist root-private sanitized evidence")
        return 2
    print("Paste only P8N summary and P8N_EXIT. Never share keys, private marker, full doctor JSON or Box paths.")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
