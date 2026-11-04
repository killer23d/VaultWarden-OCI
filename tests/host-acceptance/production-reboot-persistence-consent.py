#!/usr/bin/env python3
"""P7: explicit-consent, three-command reboot persistence acceptance on disposable rc.12.

prepare: strictly read-only host/security preflight, root-private checkpoint.
reboot: reverify same-boot checkpoint and require exact typed OCI-console consent.
verify: on a DIFFERENT boot, verify original encrypted state, security and isolation.

The ONLY non-evidence mutation is "systemctl reboot" in the consented reboot mode.
No Vaultwarden start, Docker/Caddy container, Cloudflare/Worker/DNS or Box write.
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
import stat
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-6-vnic"
RELEASE = "0.1.0-rc.12"
SRC = Path(__file__).resolve().parents[2]
INSTALLED = Path("/opt/vaultwarden-oci/releases") / RELEASE
CURRENT = Path("/opt/vaultwarden-oci/current")
P5_FILE = Path(__file__).resolve().with_name("production-security-foundation-consent.py")
P6_FILE = Path(__file__).resolve().with_name("production-postfoundation-isolation-readiness.py")
BOOT_ID = Path("/proc/sys/kernel/random/boot_id")
CHECKPOINT_NAME = "p7-reboot-checkpoint.json"
CONSENT = "P7 REBOOT vaultwarden-oci-6-vnic OCI CONSOLE READY"
PHASES = ("prepare", "reboot", "verify")


class Blocked(RuntimeError):
    """Expected security failure; message is static or allowlisted metadata."""


def helper(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise Blocked("approved acceptance helper unavailable")
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def read_boot_id() -> str:
    raw = BOOT_ID.read_text(encoding="ascii").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", raw):
        raise Blocked("kernel boot ID is unavailable or malformed")
    return raw


def sha(path: Path) -> str:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size == 0 or info.st_size > 16 * 1024 * 1024:
        raise Blocked("protected file is absent, unsafe or oversized")
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def safe_base() -> Path:
    if os.geteuid() != 0 or os.environ.get("SUDO_USER") != "ubuntu":
        raise Blocked("sudo -n from the original ubuntu operator is required")
    person = pwd.getpwnam("ubuntu")
    home = Path(person.pw_dir)
    base = home / "vwoci-acceptance"
    if home.is_symlink() or not home.is_dir() or base.is_symlink():
        raise Blocked("unsafe evidence directory parent")
    info = base.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid not in {0, person.pw_uid} or stat.S_IMODE(info.st_mode) & 0o077:
        raise Blocked("acceptance evidence directory is not private")
    return base


def checkpoint_path(base: Path) -> Path:
    return base / CHECKPOINT_NAME


def read_checkpoint(path: Path) -> dict[str, object]:
    # Never follow a pointer/symlink to a file outside the accepted root.
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_size < 10 or info.st_size > 8192):
            raise Blocked("P7 checkpoint metadata is unsafe")
        data = json.loads(source.read(8193))
    if (not isinstance(data, dict) or data.get("schema") != 1
            or data.get("host") != HOST or data.get("release") != RELEASE
            or data.get("phase") not in {"prepared", "reboot-requested", "verified"}
            or not isinstance(data.get("evidence_dir"), str)
            or not isinstance(data.get("boot_id"), str)
            or not isinstance(data.get("sha256"), dict)):
        raise Blocked("P7 checkpoint structure differs from reviewed contract")
    return data


def write_checkpoint(path: Path, payload: dict[str, object], *, create: bool) -> None:
    # Root-owned, mode 0600; no symlinks, no silent checkpoint replacement.
    raw = (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    if len(raw) > 8192:
        raise Blocked("checkpoint exceeds approved size")
    if create:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags, 0o600)
        with os.fdopen(fd, "wb") as out:
            out.write(raw)
            out.flush()
            os.fsync(out.fileno())
        return
    # Refuse changes to anything other than an existing root-private checkpoint.
    read_checkpoint(path)
    staged = path.with_name(path.name + ".next-" + str(os.getpid()))
    fd = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(raw)
            out.flush()
            os.fsync(out.fileno())
        os.replace(staged, path)
    finally:
        staged.unlink(missing_ok=True)


def evidence_dir(base: Path, mode: str, checkpoint: dict[str, object] | None) -> Path:
    if checkpoint is None:
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        dest = base / f"p7-reboot-persistence-{stamp}-{os.getpid()}"
        dest.mkdir(mode=0o700)
        return dest
    name = checkpoint.get("evidence_dir")
    if (not isinstance(name, str)
            or not re.fullmatch(r"p7-reboot-persistence-[0-9]{8}T[0-9]{6}Z-[0-9]{1,10}", name)):
        raise Blocked("checkpoint evidence name is invalid")
    dest = base / name
    info = dest.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        raise Blocked("checkpoint evidence directory is not root-private")
    if mode == "reboot" and not (dest / "prepare.summary.txt").is_file():
        raise Blocked("pre-reboot evidence summary missing")
    return dest


class Report:
    def __init__(self, dest: Path, mode: str):
        self.dest, self.mode = dest, mode
        self.rows: list[tuple[str, str]] = []
        self.blocked = False

    def add(self, level: str, msg: str) -> None:
        if level not in {"PASS", "PENDING", "BLOCKED", "NOT RUN"} or "\r" in msg or "\n" in msg:
            raise ValueError("unsafe P7 evidence row")
        self.rows.append((level, msg))
        self.blocked |= level == "BLOCKED"

    def finish(self, state: str = "HOLD") -> int:
        outcome = "BLOCKED" if self.blocked else state
        self.rows.append((outcome, "P7 disposable reboot only; live Vaultwarden and production cutover NOT AUTHORIZED"))
        summary = f"Gate P7 - rc.12 cold reboot persistence ({self.mode})\n"
        summary += "\n".join(f"{key:<18}{msg}" for key, msg in self.rows) + "\n"
        (self.dest / (self.mode + ".summary.txt")).write_text(summary, encoding="utf-8")
        print(summary, end="")
        print("Private summary:", self.dest / (self.mode + ".summary.txt"))
        print("Share summary only; never share checkpoint, secrets, raw doctor or private logs.")
        return 2 if self.blocked else 0


def tracked_paths(secrets, storage, p5) -> tuple[Path, ...]:
    return (
        Path("/etc/vaultwarden-oci/config.toml"),
        secrets.ENCRYPTED,
        secrets.AGE_KEY,
        storage.HOST_IDENTITY_FILE,
        storage.VOLUME_MARKER,
        p5.STATE / "data/db.sqlite3",
        Path(__file__).resolve(),
        P5_FILE,
        P6_FILE,
    )


def hash_protected(paths: tuple[Path, ...]) -> dict[str, str]:
    result: dict[str, str] = {}
    for path in paths:
        # Expected file names are static; no checkpoint-controlled file reads.
        result[str(path)] = sha(path)
    return result


def verified_hashes(checkpoint: dict[str, object], paths: tuple[Path, ...], current: dict[str, str]) -> None:
    old = checkpoint.get("sha256")
    if not isinstance(old, dict) or set(old) != {str(p) for p in paths}:
        raise Blocked("checkpoint tracked-file set differs")
    for path in paths:
        if old.get(str(path)) != current[str(path)]:
            raise Blocked("protected source, SQLite or encrypted authority changed across gate")


def validate_doctor(p5, p6, runtime, secrets, evidence: Path, report: Report, *, after_boot: bool) -> None:
    classification, checks, shape = p5.diagnose_doctor(evidence, "p7-check")
    if classification != "valid" or len(checks) != 27:
        raise Blocked("installed 27-ID doctor cannot be safely validated: " + classification)
    paths_state, summary = p5.inspect_stopped_runtime_paths(runtime, secrets)
    report.add(paths_state, "Stopped runtime path metadata: " + summary)
    if paths_state == "BLOCKED":
        raise Blocked("unsafe runtime metadata after reboot inspection")
    if after_boot and checks.get("edge.cloudflare.iptables") == "FAIL":
        # Docker may recreate DOCKER-USER. Never auto-repair it here; the
        # product's supported start refreshes the policy before publishing 443.
        sanitized = dict(checks)
        sanitized["edge.cloudflare.iptables"] = "PASS"
        good, label = p6.evaluate_stopped_doctor(sanitized, paths_state)
        if not good:
            raise Blocked("post-boot doctor has other unexpected failures: " + label)
        report.add("PENDING", "Cloudflare Docker 443 ingress policy not persistent across cold boot; NO listener and NO automatic repair")
        report.add("PENDING", "Must prove product-owned fail-closed edge refresh before any separately authorized app startup")
    else:
        good, label = p6.evaluate_stopped_doctor(checks, paths_state)
        if not good:
            raise Blocked("post-foundation doctor inconsistency: " + label)
        report.add("PASS", "All five local origin/CrowdSec security doctor IDs and storage.dedicated PASS")
    if checks.get("crowdsec.cloudflare") != "FAIL":
        raise Blocked("boot-disabled Worker doctor must remain unarmed")
    report.add("PASS", "Cloudflare Worker still requires a NEW invocation-specific Fail Open attestation")


def empty_docker_restart_surface(p1) -> bool:
    """A stopped restart-policy container can resurrect after Docker reboots."""
    code, output = p1.run_readonly(
        ["docker", "ps", "-a", "--format", "{{.ID}}"], timeout=20,
    )
    return code == 0 and not output.strip()


def host_snapshot(report: Report, *, after_boot: bool) -> tuple[tuple[Path, ...], dict[str, str]]:
    phase = "immutable release"
    p5 = helper(P5_FILE, "p7_p5")
    p6 = helper(P6_FILE, "p7_p6")
    p1 = p5.module(p5.P1, "p7_p1")
    p4 = p5.module(p5.P4, "p7_p4")
    try:
        if (platform.node().split(".")[0] != HOST or platform.machine() not in {"aarch64", "arm64"}
                or sys.version_info[:2] != (3, 14)):
            raise Blocked("not the original Ubuntu 26.04 ARM64 Python 3.14 disposable host")
        if not CURRENT.is_symlink() or CURRENT.resolve(strict=True) != INSTALLED:
            raise Blocked("installed immutable rc.12 release pointer changed")
        verified, files = p1.release_integrity(SRC, INSTALLED)
        if not verified or files != 52:
            raise Blocked("installed 52-file rc.12 source integrity changed")
        sys.path.insert(0, str(INSTALLED))
        installed_ok, count = p1.systemd_unit_integrity(INSTALLED)
        if not installed_ok or count != 12:
            raise Blocked("installed 12 systemd unit definitions changed")
        from vaultwarden_oci import runtime, secrets, storage
        report.add("PASS", "Original Ubuntu ARM64 host; 52 immutable rc.12 files and 12 installed systemd units")
        phase = "isolation"
        if not p5.exact_isolation(p1, p4, storage, expect_security_installed=True):
            raise Blocked("original volume, SQLite, inactive app/ports/timers, Docker or Worker isolation changed")
        if not empty_docker_restart_surface(p1):
            raise Blocked("Docker has a retained container or cannot inspect full inventory; cold reboot could resurrect listeners")
        report.add("PASS", "Original ext4 disk/SQLite SHA, disabled app/DNS/four timers, no HTTP listeners or retained Docker containers")
        cfg = runtime.load_config()
        if (cfg.domain != p6.EXPECTED_SHARED_DOMAIN
                or not p1.matches_offline_recipient(cfg.offline_recovery_recipient)
                or cfg.offsite_remote != p5.EXPECTED_REMOTE
                or cfg.local_retention_days != 0 or cfg.remote_retention_days != 0
                or cfg.smtp_accept_invalid_certs or cfg.smtp_accept_invalid_hostnames):
            raise Blocked("restored domain/recipient/Box no-prune/SMTP TLS boundary changed")
        values = secrets.validate_encrypted(cfg.offline_recovery_recipient)
        allowed = secrets.admin_enabled(values) and bool(values.get("cloudflare_remediation_token"))
        del values
        if not allowed:
            raise Blocked("restored SOPS/admin/remediation credentials invalid")
        report.add("PASS", "SOPS/Age custody, admin protection, SMTP TLS and Box no-prune config unchanged")
        phase = "security"
        if not p6.expected_security_units(p1):
            raise Blocked("CrowdSec engine or host INPUT bouncer not enabled+active, or Worker not disabled+inactive")
        report.add("PASS", "CrowdSec engine and host INPUT bouncer active+enabled; Worker inactive+disabled")
        validate_doctor(p5, p6, runtime, secrets, report.dest, report, after_boot=after_boot)
        phase = "package and tracked authority"
        rc, audit = p1.run_readonly(["dpkg", "--audit"], timeout=30)
        if rc != 0 or audit.strip():
            raise Blocked("post-P5 dpkg database reports partial package changes")
        report.add("PASS", "dpkg package audit clean")
        rc, value = p1.run_readonly(
            ["timedatectl", "show", "-p", "NTPSynchronized", "--value"], timeout=12,
        )
        report.add("PASS" if rc == 0 and value.strip() == "yes" else "PENDING",
                   "NTP synchronized" if rc == 0 and value.strip() == "yes" else "NTP not confirmed")
        reboot_marker = Path("/var/run/reboot-required").exists()
        report.add("PENDING" if reboot_marker else "PASS",
                   "Ubuntu reboot-required marker present; classify after approved boot"
                   if reboot_marker else "No Ubuntu reboot-required marker")
        paths = tracked_paths(secrets, storage, p5)
        protected = hash_protected(paths)
        if protected[str(p5.STATE / "data/db.sqlite3")] != p5.DB_SHA:
            raise Blocked("restored SQLite digest differs from original P3 accepted hash")
        report.add("PASS", "Protected encrypted authority, storage markers, SQLite and acceptance source digests captured privately")
        return paths, protected
    except Blocked:
        raise
    except Exception as exc:
        # No raw exception detail can be placed into an operator report.
        raise Blocked("unclassified host snapshot error during " + phase) from exc


def check_consent(value: str) -> bool:
    return value == CONSENT


def run_reboot() -> bool:
    # This is the only deliberately mutating OS command in P7. Never retry it
    # automatically, and never run it from prepare or verify.
    try:
        result = subprocess.run(
            ["systemctl", "reboot"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=30, check=False, cwd="/",
        )
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in PHASES:
        print("BLOCKED: usage: P7 {prepare|reboot|verify}", file=sys.stderr)
        return 2
    mode = sys.argv[1]
    if os.geteuid() != 0 or os.environ.get("SUDO_USER") != "ubuntu":
        print("BLOCKED: sudo -n from original ubuntu required", file=sys.stderr)
        return 2
    if mode == "reboot" and not (sys.stdin.isatty() and sys.stdout.isatty()):
        print("BLOCKED: interactive terminal required for explicit reboot consent", file=sys.stderr)
        return 2
    try:
        base = safe_base()
        marker = checkpoint_path(base)
        if mode == "prepare":
            if marker.exists() or marker.is_symlink():
                print("BLOCKED: P7 checkpoint already exists; do not start another reboot cycle", file=sys.stderr)
                return 2
            checkpoint = None
        else:
            checkpoint = read_checkpoint(marker)
        dest = evidence_dir(base, mode, checkpoint)
    except (OSError, ValueError, KeyError, Blocked, json.JSONDecodeError):
        print("BLOCKED: private P7 checkpoint or evidence preflight failed", file=sys.stderr)
        return 2
    report = Report(dest, mode)
    stage = "post-foundation preflight"
    try:
        now_boot_id = read_boot_id()
        if mode == "verify":
            if checkpoint is None or checkpoint.get("phase") != "reboot-requested":
                raise Blocked("no previously authorized reboot checkpoint")
            if now_boot_id == checkpoint.get("boot_id"):
                raise Blocked("kernel boot ID unchanged; actual reboot not proven")
            report.add("PASS", "A different kernel boot ID proves an actual reboot occurred")
            paths, protected = host_snapshot(report, after_boot=True)
            verified_hashes(checkpoint, paths, protected)
            report.add("PASS", "Original protected configuration/Age/SOPS/volume/SQLite and acceptance source hashes survived reboot")
            # Only a full local firewall persistence PASS qualifies as P7 VERIFIED.
            if any(row[0] == "PENDING" and "not persistent across cold boot" in row[1] for row in report.rows):
                report.add("PENDING", "Reboot data/service safety confirmed; Docker-origin policy requires separate corrective acceptance")
                return report.finish("HOLD")
            checkpoint["phase"] = "verified"
            write_checkpoint(marker, checkpoint, create=False)
            report.add("NOT RUN", "No app start, DNS/Cloudflare/Worker calls, Box writes, timers, package changes or restore")
            return report.finish("VERIFIED")

        if mode == "reboot":
            if checkpoint is None or checkpoint.get("phase") != "prepared":
                raise Blocked("P7 preflight checkpoint not in prepared state")
            if checkpoint.get("boot_id") != now_boot_id:
                raise Blocked("preflight boot ID changed without P7 authorization")
        paths, protected = host_snapshot(report, after_boot=False)
        if mode == "prepare":
            stage = "checkpoint creation"
            checkpoint = {
                "schema": 1,
                "host": HOST,
                "release": RELEASE,
                "phase": "prepared",
                "boot_id": now_boot_id,
                "evidence_dir": dest.name,
                "sha256": protected,
            }
            write_checkpoint(marker, checkpoint, create=True)
            report.add("PENDING", "Reboot is not authorized by prepare; review checkpoint summary before separately consenting")
            report.add("PENDING", "OCI serial console recovery access must be independently verified before reboot")
            report.add("NOT RUN", "No reboot, app/Worker/Caddy/DNS, Box, SMTP or timer mutation")
            return report.finish("PREPARED")
        verified_hashes(checkpoint, paths, protected)
        report.add("PASS", "Prepared boot ID and all protected source/state digests match just before reboot")
        report.add("PENDING", "P7 WILL reboot only this disposable VM, terminate SSH and interrupt networking")
        print("\nP7: DISPOSABLE-HOST REBOOT AUTHORIZATION")
        print("Verify an ACTIVE OCI serial console recovery session, not just SSH.")
        print("This will disconnect SSH and reboot vaultwarden-oci-6-vnic.")
        print("The app, DNS, four timers and Worker MUST remain disabled after reboot.")
        print("No live origin hostname, Cloudflare Worker/DNS/Box writes or SMTP authorized.")
        print("Do not repeat reboot after interruption; use P7 verify or inspect console.")
        print("Type the exact phrase ONLY after personally verifying the OCI console:")
        print(CONSENT)
        stage = "typed operator reboot consent"
        answer = input("Authorization [CANCEL]: ")
        if not check_consent(answer):
            report.add("PENDING", "Operator cancelled; no reboot command executed")
            return report.finish("CANCELLED")
        checkpoint["phase"] = "reboot-requested"
        write_checkpoint(marker, checkpoint, create=False)
        report.add("PASS", "Operator authorized reboot with active OCI console attestation; checkpoint persisted")
        report.add("PENDING", "Reboot command is next; only a different kernel boot ID can prove success")
        report.add("NOT RUN", "No app, Cloudflare/Worker/DNS, Box, SMTP, restore or timer activation")
        report.finish("REBOOT REQUESTED")
        sys.stdout.flush()
        if not run_reboot():
            print("BLOCKED: reboot request failed or timed out; preserve VM; do not rerun automatically")
            return 2
        return 0
    except (Blocked, OSError, ValueError, KeyError, json.JSONDecodeError, KeyboardInterrupt):
        report.add("BLOCKED", "Safety precondition failed during " + stage + "; inspect private evidence and preserve VM")
        return report.finish()
    except Exception:
        report.add("BLOCKED", "Unclassified P7 error during " + stage + "; raw exception withheld")
        return report.finish()


if __name__ == "__main__":
    raise SystemExit(main())
