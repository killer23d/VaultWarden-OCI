#!/usr/bin/env python3
"""P8R: one-shot stopped-only LOCAL origin-filter rearm after accepted P8Q.

Target: NEW disposable vaultwarden-oci-7-vnic, original rc.12 release only.
P8P's earlier generic BLOCKED is not rewritten or retried. P8R has its own
exclusive attempt marker and a complete independent data/security postflight.
No public app/Cloudflare Worker/Box/timer/DNS/SMTP activation or reboot.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import platform
import pwd
import re
import signal
import stat
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-7-vnic"
BRANCH = "audit/rc12-p8r-postboot-origin-rearm-batch-newvm"
SOURCE = Path(__file__).resolve().parents[2]
P8P = Path("/home/ubuntu/VaultWarden-OCI-p8p-f17df88")
P8P_BRANCH = "audit/rc12-p8p-batched-reboot-persistence-newvm"
P8P_COMMIT = "f17df88f0c0720be062efcc13cb35080cd0d7ac9"
P8P_SCRIPT = P8P / "tests/host-acceptance/production-p8p-batched-reboot-persistence-newvm.py"
P8Q = Path("/home/ubuntu/VaultWarden-OCI-p8q-25a2c86")
P8Q_BRANCH = "audit/rc12-p8q-postboot-blocker-readonly"
P8Q_COMMIT = "25a2c864d260b29fcd89da88654d5987c1b87a17"
P8Q_SCRIPT = P8Q / "tests/host-acceptance/production-p8q-postboot-readonly-diagnostic.py"
EVIDENCE = Path("/home/ubuntu/vwoci-acceptance")
P8Q_REPORT = EVIDENCE / "p8q-postboot-readonly-20261105T201612Z-1802/summary.txt"
ATTEMPT = EVIDENCE / "p8r-one-shot-postboot-origin-rearm-attempt.json"
REQUIRED_P8Q = {
    "source.exact-reviewed-p8p": "PASS",
    "prior.p8o-foundation-evidence": "PASS",
    "reboot.root-private-checkpoint": "PASS",
    "reboot.changed-kernel-boot-id": "PASS",
    "release.52-immutable-product-files": "PASS",
    "release.12-installed-systemd-definitions": "PASS",
    "storage.dedicated-original-ext4": "PASS",
    "config.historical-domain-recipient-smtp-box-no-prune": "PASS",
    "secrets.offline-custody-sops-admin-remediation": "PASS",
    "sqlite.readonly-integrity-and-historical-sha": "PASS",
    "services.app-dns-timers-disabled-inactive": "PASS",
    "network.no-http-or-docker-tcp-listeners": "PASS",
    "docker.no-retained-or-running-containers": "PASS",
    "security.crowdsec-engine-active-enabled": "PASS",
    "security.crowdsec-input-bouncer-active-enabled": "PASS",
    "security.cloudflare-worker-disabled-inactive": "PASS",
    "doctor.27-id-schema": "PASS",
    "doctor.edge.cloudflare.iptables": "PENDING",
    "doctor.crowdsec.engine": "PASS",
    "doctor.crowdsec.hub": "PASS",
    "doctor.crowdsec.firewall": "PASS",
    "checkpoint.original-file-hashes-match": "PASS",
    "original-p8p.snapshot-parity": "PASS",
}
SHA40 = re.compile(r"[a-f0-9]{40}\Z")


class Blocked(RuntimeError):
    pass


def source_clean(pin: str, repository: Path, branch: str) -> bool:
    if not SHA40.fullmatch(pin) or not repository.is_dir() or repository.is_symlink():
        return False
    outputs = []
    for args in (("rev-parse", "HEAD"), ("symbolic-ref", "--quiet", "--short", "HEAD"),
                 ("status", "--porcelain", "--untracked-files=all")):
        try:
            result = subprocess.run(
                ["/usr/bin/git", *args], cwd=repository,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=20, check=False,
                env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat"),
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        if result.returncode or len(result.stdout) > 8192:
            return False
        outputs.append(result.stdout.decode("utf-8", "replace").strip())
    return outputs == [pin, branch, ""]


def host_ok() -> bool:
    if (os.geteuid() != 0 or os.getenv("SUDO_USER") != "ubuntu"
            or platform.node().split(".")[0] != HOST
            or platform.machine() not in ("aarch64", "arm64")
            or sys.version_info[:2] != (3, 14)):
        return False
    try:
        release = dict(line.split("=", 1) for line in
                       Path("/etc/os-release").read_text(encoding="utf-8").splitlines()
                       if "=" in line)
        return release.get("ID", "").strip('"') == "ubuntu" and release.get(
            "VERSION_ID", "").strip('"') == "26.04"
    except (OSError, ValueError):
        return False


def module(path: Path, name: str):
    if path.is_symlink() or not path.is_file():
        raise Blocked("exact reviewed prior acceptance source missing")
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise Blocked("prior source helper not importable")
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def p8q_statuses(text: str) -> dict[str, str]:
    if not text.startswith("Gate P8Q - NEW disposable VM independent P8P postboot blocker diagnosis (READ-ONLY)\n"):
        raise Blocked("P8Q accepted summary identity mismatch")
    statuses: dict[str, str] = {}
    final = ""
    for row in text.splitlines()[1:]:
        parts = row.split()
        if len(parts) != 2 or parts[0] not in ("PASS", "PENDING", "BLOCKED", "NOT RUN", "READONLY"):
            raise Blocked("P8Q status format mismatch")
        state, key = parts
        if key in statuses or not re.fullmatch(r"[a-z0-9_.-]{3,82}", key):
            raise Blocked("P8Q status id duplicate/unsafe")
        statuses[key] = state
        if state == "READONLY":
            final = key
    if final != "p8q.no-mutation.no-reboot.no-rearm.no-box.no-live-go":
        raise Blocked("P8Q prior diagnostic was not a READONLY result")
    if any(value == "BLOCKED" for value in statuses.values()):
        raise Blocked("P8Q contains a blocked safety group")
    for key, value in REQUIRED_P8Q.items():
        if statuses.get(key) != value:
            raise Blocked("P8Q accepted security/recovery diagnosis changed")
    if len(statuses) < 48:
        raise Blocked("P8Q diagnostic coverage incomplete")
    return statuses


def historical_evidence(p8p, p8q) -> dict[str, object]:
    p8p.private_dir(EVIDENCE, {0, pwd.getpwnam("ubuntu").pw_uid})
    p8p.private_dir(P8Q_REPORT.parent, {0})
    report_info = P8Q_REPORT.lstat()
    data = p8p.private_read(P8Q_REPORT).decode("utf-8", "strict")
    p8q_statuses(data)

    # Reject a second reboot since P8Q: its own accepted report must have
    # been produced in this kernel boot, not an earlier one.
    btime = next(int(x.split()[1]) for x in Path("/proc/stat").read_text(encoding="ascii").splitlines()
                 if x.startswith("btime "))
    if report_info.st_mtime < btime:
        raise Blocked("host has rebooted since accepted P8Q diagnosis")

    p8p.accepted_p8o()
    checkpoint = p8p.checkpoint_read()
    if (checkpoint.get("phase") != "requested"
            or checkpoint.get("reviewed_commit") != P8P_COMMIT
            or checkpoint.get("p8o_commit") != p8p.P8O_COMMIT
            or checkpoint.get("original_boot_id") == p8p.boot_id()):
        raise Blocked("unchanged one-shot P8P checkpoint and changed boot not proven")
    if (p8p.REARM_MARKER.exists() or p8p.REARM_MARKER.is_symlink()
            or ATTEMPT.exists() or ATTEMPT.is_symlink()):
        raise Blocked("prior firewall rearm attempt exists; no automatic second attempt")
    return checkpoint


def phase_dir(folder: Path, name: str) -> Path:
    child = folder / name
    child.mkdir(mode=0o700)
    return child


def new_private_folder() -> Path:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder = EVIDENCE / ("p8r-origin-rearm-" + stamp + "-" + str(os.getpid()))
    folder.mkdir(mode=0o700)
    if folder.lstat().st_uid != 0 or stat.S_IMODE(folder.lstat().st_mode) != 0o700:
        raise Blocked("root-private P8R evidence metadata mismatch")
    return folder


def postboot_audit(p8p, folder: Path, checkpoint, label: str) -> tuple[bool, str]:
    snapshot_folder = phase_dir(folder, label + "-snapshot")
    doctor_folder = phase_dir(folder, label + "-doctor")
    report = p8p.Report(snapshot_folder, label)
    protected = p8p.snapshot(report, snapshot_folder, after_boot=True)
    p8p.compare_paths(checkpoint, protected)
    p5 = p8p.load_helper(p8p.P5_FILE, "p8r_reviewed_" + label.replace("-", "_"))
    checks, runtime_paths, effective_filter = p8p.doctor(p5, doctor_folder, after_boot=True)
    if len(checks) != 27 or any(checks.get(name) != "PASS" for name in (
        *p8p.MANDATORY, "edge.cloudflare.cidrs",
        "crowdsec.engine", "crowdsec.hub", "crowdsec.firewall",
    )):
        raise Blocked("local protected/security doctor baseline drift")
    if checks.get("crowdsec.cloudflare") != "FAIL":
        raise Blocked("Cloudflare Worker improperly armed")
    if (runtime_paths not in ("PASS", "PENDING")
            or (checks.get("runtime.paths") == "PASS") != (runtime_paths == "PASS")):
        raise Blocked("unsafe or inconsistent stopped runtime paths")
    return effective_filter, runtime_paths


def private_summary(folder: Path, entries: list[tuple[str, str]], state: str) -> int:
    if state not in ("REARMED", "HOLD", "BLOCKED"):
        state = "BLOCKED"
    body = "Gate P8R - NEW disposable VM stopped-only postboot origin firewall rearm\n"
    for status, message in entries:
        if (status not in ("PASS", "PENDING", "BLOCKED", "NOT RUN")
                or len(message) > 210 or any(ch in message for ch in "\r\n\x00")):
            raise Blocked("unsafe P8R report row")
        body += f"{status:<10} {message}\n"
    body += f"{state:<10} P8R host-local firewall only; no public/Box/Worker/production GO\n"
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(folder / "summary.txt", flags, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
    except OSError:
        print("BLOCKED: root-private P8R summary durability failure")
        return 2
    print(body, end="")
    print("Private summary:", folder / "summary.txt")
    print("Share sanitized summary and P8R_EXIT only; no prior markers, raw doctor, secrets, IPs or private logs.")
    return 0 if state in ("HOLD", "REARMED") else 2


def main() -> int:
    args = sys.argv[1:]
    if (len(args) != 4 or args[0] != "--expected-commit"
            or not SHA40.fullmatch(args[1]) or args[2:] !=
            ["--apply-disposable", "--oci-console-ready"]
            or not host_ok() or not (sys.stdin.isatty() and sys.stdout.isatty())
            or not source_clean(args[1], SOURCE, BRANCH)
            or not source_clean(P8P_COMMIT, P8P, P8P_BRANCH)
            or not source_clean(P8Q_COMMIT, P8Q, P8Q_BRANCH)):
        print("BLOCKED: exact reviewed source/NEW-VM/SSH-TTY/OCI console attestation is required")
        return 2

    try:
        p8p = module(P8P_SCRIPT, "p8r_reviewed_original_p8p")
        p8q = module(P8Q_SCRIPT, "p8r_reviewed_original_p8q")
        if (p8p.SRC != P8P or p8p.HOST != HOST or p8q.SRC != P8Q
                or p8q.HOST != HOST or p8q.PRIOR_SHA != P8P_COMMIT
                or p8p.P8O_COMMIT != "f989f2c91a1276501aab126443b96d593261e54e"):
            raise Blocked("exact source identity differs")
        checkpoint = historical_evidence(p8p, p8q)
        folder = new_private_folder()
    except Exception:
        print("BLOCKED: P8P/P8Q evidence, source or one-shot marker invalid; no host change")
        return 2

    entries: list[tuple[str, str]] = []
    started = False
    verified = False
    phase = "postboot protected state preflight"
    original_handlers = {}
    pending_signals: list[int] = []
    watched = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)

    def interrupt(signum, frame):
        raise KeyboardInterrupt()

    def deferred(signum, frame):
        pending_signals.append(signum)

    for signum in watched:
        original_handlers[signum] = signal.getsignal(signum)
        signal.signal(signum, interrupt)
    try:
        before_boot = p8p.boot_id()
        baseline_filter, paths = postboot_audit(p8p, folder, checkpoint, "before")
        entries.append(("PASS", "Original P8O FOUNDATION and P8Q read-only results pinned; real reboot proven"))
        entries.append(("PASS", "Immutable 52 files/12 units, ext4, restored SQLite full integrity/SHA and SOPS/Age match original checkpoint"))
        entries.append(("PASS", "CrowdSec engine+INPUT boot active, Worker/app/DNS/timers inactive; no Docker containers or HTTP80/443"))
        entries.append(("PASS" if paths == "PASS" else "PENDING",
                        "Stopped runtime path metadata=" + paths + " (no automatic generated-path repair)"))
        entries.append(("PENDING", "Historical Box destination configured; original remote writes/pruning and timers forbidden"))

        if baseline_filter:
            entries.append(("PASS", "Cloudflare Docker 443 origin guard already effective; no local mutation warranted"))
            entries.append(("NOT RUN", "No firewall refresh, reboot, Worker, DNS, app/SMTP or Box operation"))
            return private_summary(folder, entries, "HOLD")

        entries.append(("PENDING", "Docker 443 origin filtering lost after reboot; one product-owned local re-arm permitted"))
        phase = "second complete stopped-host preflight"
        second_filter, second_paths = postboot_audit(p8p, folder, checkpoint, "repeat")
        if second_filter or p8p.boot_id() != before_boot:
            raise Blocked("origin status or kernel boot changed between preflight and mutation")
        if second_paths != paths:
            raise Blocked("runtime path classification changed before mutation")
        if (ATTEMPT.exists() or ATTEMPT.is_symlink()
                or p8p.REARM_MARKER.exists() or p8p.REARM_MARKER.is_symlink()):
            raise Blocked("original or new firewall attempt marker appeared during preflight")

        phase = "durable one-shot local firewall mutation"
        print("P8R: OCI serial console must be accessible. One LOCAL installed rc.12 origin-filter refresh only.")
        print("P8R: no production VM, public DNS/Worker, original Box or app/timer actions permitted.")
        payload = {
            "schema": 1, "gate": "p8r", "host": HOST,
            "reviewed_source": args[1], "prior_p8p_source": P8P_COMMIT,
            "prior_p8q_source": P8Q_COMMIT,
            "preboot_id": checkpoint["original_boot_id"],
            "postboot_id": before_boot,
            "attempt_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        }
        p8p.exclusive_file(ATTEMPT, (json.dumps(payload, sort_keys=True) + "\n").encode("utf-8"))
        for signum in watched:
            signal.signal(signum, deferred)
        started = True

        private_log_folder = phase_dir(folder, "mutation")
        code = p8p.private_log(
            private_log_folder, "edge-rearm",
            [sys.executable, "-B", "-E", str(p8p.INSTALLED / "vwctl"), "edge", "refresh"],
            180,
        )
        if code != 0:
            raise Blocked("one-shot installed origin refresh failed; preserve VM, no retry")
        phase = "immediate full postrefresh protected state verification"
        after_filter, after_paths = postboot_audit(p8p, folder, checkpoint, "after")
        if not after_filter or p8p.boot_id() != before_boot or after_paths != paths:
            raise Blocked("postrefresh firewall, boot or runtime path state differs")
        if pending_signals:
            raise Blocked("signal received during firewall operation; preserve VM for independent inspection")
        verified = True
        entries.append(("PASS", "Installed rc.12 owner performed exactly one Cloudflare-only Docker 443 filter refresh"))
        entries.append(("PASS", "All five local origin/CrowdSec doctor controls now PASS"))
        entries.append(("PASS", "Entire original restored data/crypto/dedicated disk/52 files/12 units and application isolation revalidated"))
        entries.append(("PASS", "CrowdSec engine/host INPUT remain boot-active; Worker and all app/DNS/timer units remain inactive"))
        entries.append(("PENDING", "Docker-origin 443 filter did NOT persist unaided across cold reboot; explicit re-arm was required"))
        entries.append(("PENDING", "Original P8P BLOCKED checkpoint intentionally preserved; no false reboot-persistence claim"))
        entries.append(("PENDING", "Public origin/Worker Route Fail Open and test-only backup/SMTP still require separate proof"))
        entries.append(("PENDING", "Disposable unencrypted ext4 may retain restored plaintext remnants; securely retire after acceptance"))
        entries.append(("NOT RUN", "No additional reboot, Caddy/Vaultwarden, Worker/DNS/SMTP, Box write/prune or timer operation"))
        return private_summary(folder, entries, "REARMED")
    except KeyboardInterrupt:
        entries.append(("BLOCKED", "Interrupted during " + phase + "; no automatic retry or remediation"))
        return private_summary(folder, entries, "BLOCKED")
    except Exception:
        entries.append(("BLOCKED", "Safety/integrity failure during " + phase +
                        "; private details suppressed; preserve VM and root-private logs"))
        if started and not verified:
            entries.append(("BLOCKED", "Possible partial local firewall mutation; do not delete P8R marker or rerun"))
        return private_summary(folder, entries, "BLOCKED")
    finally:
        for signum, handler in original_handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    raise SystemExit(main())
