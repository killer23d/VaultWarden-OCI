#!/usr/bin/env python3
"""P8S-A: one-shot read-only NEW-VM protected stopped-host acceptance.

Never restores, starts containers, refreshes policy, changes DNS/Worker,
prunes or publishes to Box, enables timers, or replays P8P/P8R markers.
Uses already reviewed P8P/P8Q/P8R helpers and private host evidence.
"""
from __future__ import annotations

import datetime as dt
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

HOST = "vaultwarden-oci-7-vnic"
BRANCH = "audit/rc12-p8s-a-stopped-state-preflight"
SOURCE = Path(__file__).resolve().parents[2]
P8P = Path("/home/ubuntu/VaultWarden-OCI-p8p-f17df88")
P8Q = Path("/home/ubuntu/VaultWarden-OCI-p8q-25a2c86")
P8R = Path("/home/ubuntu/VaultWarden-OCI-p8r-corrected-d28e257")
P8P_SHA = "f17df88f0c0720be062efcc13cb35080cd0d7ac9"
P8Q_SHA = "25a2c864d260b29fcd89da88654d5987c1b87a17"
P8R_SHA = "d28e2573fbe76dec00f9641d8c923074d0ce6b6d"
P8P_BRANCH = "audit/rc12-p8p-batched-reboot-persistence-newvm"
P8Q_BRANCH = "audit/rc12-p8q-postboot-blocker-readonly"
P8R_BRANCH = "audit/rc12-p8r-postboot-origin-rearm-batch-newvm"
EVIDENCE = Path("/home/ubuntu/vwoci-acceptance")
R_SUMMARY = EVIDENCE / "p8r-origin-rearm-20261105T210337Z-2487/summary.txt"
R_ATTEMPT = EVIDENCE / "p8r-one-shot-postboot-origin-rearm-attempt.json"
SHA40 = re.compile(r"[0-9a-f]{40}\Z")
R_HEADING = "Gate P8R - NEW disposable VM stopped-only postboot origin firewall rearm"
R_FINAL = f"{'REARMED':<10} P8R host-local firewall only; no public/Box/Worker/production GO"


class Blocked(RuntimeError):
    """Fail closed without echoing protected input."""


def source_clean(folder: Path, branch: str, commit: str) -> bool:
    if (not SHA40.fullmatch(commit) or folder.is_symlink() or
            not (folder / ".git").is_dir()):
        return False
    results = []
    for command in (("rev-parse", "HEAD"),
                    ("symbolic-ref", "--quiet", "--short", "HEAD"),
                    ("status", "--porcelain", "--untracked-files=all")):
        try:
            proc = subprocess.run(
                ["/usr/bin/git", *command], cwd=folder, check=False,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=20,
                env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat"))
        except (OSError, subprocess.TimeoutExpired):
            return False
        if proc.returncode or len(proc.stdout) > 8192:
            return False
        results.append(proc.stdout.decode("utf-8", "replace").strip())
    return results == [commit, branch, ""]


def host_ok() -> bool:
    if (os.geteuid() != 0 or os.getenv("SUDO_USER") != "ubuntu" or
            platform.node().split(".")[0] != HOST or
            platform.machine() not in ("aarch64", "arm64") or
            sys.version_info[:2] != (3, 14)):
        return False
    try:
        lines = Path("/etc/os-release").read_text(encoding="utf-8").splitlines()
        fields = dict(line.split("=", 1) for line in lines if "=" in line)
        return (fields.get("ID", "").strip('"') == "ubuntu" and
                fields.get("VERSION_ID", "").strip('"') == "26.04")
    except (OSError, ValueError):
        return False


def import_checked(folder: Path, filename: str, module_name: str):
    path = folder / "tests/host-acceptance" / filename
    if path.is_symlink() or not path.is_file():
        raise Blocked("pinned prior acceptance file missing")
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise Blocked("pinned prior acceptance module unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def accepted_r_summary(text: str) -> None:
    rows = text.splitlines()
    if (not rows or rows[0] != R_HEADING or rows[-1] != R_FINAL or
            len(rows) < 16):
        raise Blocked("accepted P8R summary heading/outcome mismatch")
    required = (
        "Original P8O FOUNDATION and P8Q read-only results pinned",
        "Installed rc.12 owner performed exactly one Cloudflare-only Docker 443 filter refresh",
        "All five local origin/CrowdSec doctor controls now PASS",
        "Entire original restored data/crypto/dedicated disk/52 files/12 units",
        "Docker-origin 443 filter did NOT persist unaided across cold reboot",
        "Original P8P BLOCKED checkpoint intentionally preserved",
        "No additional reboot, Caddy/Vaultwarden, Worker/DNS/SMTP, Box write/prune or timer operation",
    )
    if any(sum(fragment in row for row in rows) != 1 for fragment in required):
        raise Blocked("accepted P8R protected coverage or outcome missing")
    if any(row.startswith(("BLOCKED", "HOLD", "REARMED")) for row in rows[1:-1]):
        raise Blocked("P8R summary contains unexpected terminal/blocked row")
    if not any(row.startswith("NOT RUN") and "No additional reboot, Caddy/Vaultwarden" in row for row in rows[1:-1]):
        raise Blocked("P8R expected negative operations record altered")
    if not any(row.startswith("PASS") and "All five local origin/CrowdSec doctor controls now PASS" in row for row in rows[1:-1]):
        raise Blocked("P8R accepted five-control result altered")


def boot_time() -> int:
    for row in Path("/proc/stat").read_text(encoding="ascii").splitlines():
        if row.startswith("btime "):
            return int(row.split()[1])
    raise Blocked("kernel boot timestamp unavailable")


def read_preflight(p8p, p8r, enter=lambda _phase: None) -> dict[str, object]:
    enter("prior.evidence-metadata")
    p8p.private_dir(EVIDENCE, {0, pwd.getpwnam("ubuntu").pw_uid})
    p8p.private_dir(R_SUMMARY.parent, {0})
    p8p.private_dir(p8r.P8Q_REPORT.parent, {0})
    if (R_SUMMARY.is_symlink() or R_ATTEMPT.is_symlink() or
            p8r.P8Q_REPORT.is_symlink()):
        raise Blocked("prior evidence symlink not authorized")
    enter("prior.p8r-accepted-summary")
    summary = p8p.private_read(R_SUMMARY).decode("utf-8", "strict")
    accepted_r_summary(summary)
    enter("prior.p8q-accepted-summary")
    p8r.p8q_statuses(p8p.private_read(p8r.P8Q_REPORT).decode("utf-8", "strict"))
    enter("prior.p8p-original-checkpoint")
    original = p8p.checkpoint_read()
    enter("prior.p8r-durable-attempt")
    marker = json.loads(p8p.private_read(R_ATTEMPT, limit=8192))
    if (not isinstance(marker, dict) or marker.get("schema") != 1 or
            marker.get("gate") != "p8r" or marker.get("host") != HOST or
            marker.get("reviewed_source") != P8R_SHA or
            marker.get("prior_p8p_source") != P8P_SHA or
            marker.get("prior_p8q_source") != P8Q_SHA or
            original.get("phase") != "requested" or
            original.get("reviewed_commit") != P8P_SHA or
            original.get("original_boot_id") == p8p.boot_id() or
            marker.get("postboot_id") != p8p.boot_id() or
            marker.get("preboot_id") != original.get("original_boot_id")):
        raise Blocked("accepted pre/postboot one-shot continuity invalid")
    enter("prior.p8r-current-kernel")
    if R_SUMMARY.lstat().st_mtime < boot_time():
        raise Blocked("unreviewed reboot after accepted P8R")
    enter("prior.p8o-foundation")
    p8p.accepted_p8o()
    return original


def folder_private() -> Path:
    name = "p8s-a-readonly-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + str(os.getpid())
    output = EVIDENCE / name
    output.mkdir(mode=0o700)
    info = output.lstat()
    if info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        raise Blocked("private report location ownership invalid")
    return output


def write_report(folder: Path, rows: list[tuple[str, str]], state: str) -> int:
    if state not in ("HOLD", "BLOCKED"):
        raise Blocked("unrecognized outcome")
    lines = ["Gate P8S-A - NEW disposable VM protected stopped-host READ-ONLY"]
    for status, message in rows:
        if (status not in ("PASS", "PENDING", "BLOCKED", "NOT RUN") or
                len(message) > 180 or any(c in message for c in "\r\n\x00")):
            raise Blocked("unsafe report content")
        lines.append(f"{status:<10} {message}")
    lines.append(f"{state:<10} P8S-A stopped-only; no live/Box/Worker/DNS/timer authorization")
    text = "\n".join(lines) + "\n"
    fd = os.open(folder / "summary.txt", os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as report:
        report.write(text)
        report.flush()
        os.fsync(report.fileno())
    print(text, end="")
    print("Private summary:", folder / "summary.txt")
    print("Share only sanitized summary and P8S_A_EXIT, not raw doctor or config.")
    return 0 if state == "HOLD" else 2


# Exact source-owned static messages only: never interpolate unknown exception
# strings, raw doctor details, paths, network identities, or SOPS plaintext.
REASON_CODES = {
    "private acceptance evidence directory unsafe": "history.private-directory",
    "root-private acceptance evidence metadata invalid": "history.private-file",
    "accepted P8R summary heading/outcome mismatch": "history.p8r-summary-outcome",
    "accepted P8R protected coverage or outcome missing": "history.p8r-summary-coverage",
    "P8R summary contains unexpected terminal/blocked row": "history.p8r-summary-status",
    "P8R expected negative operations record altered": "history.p8r-no-mutation-row",
    "P8R accepted five-control result altered": "history.p8r-foundation-row",
    "P8Q accepted summary identity mismatch": "history.p8q-summary",
    "P8Q status format mismatch": "history.p8q-status-format",
    "P8Q accepted security/recovery diagnosis changed": "history.p8q-baseline",
    "P8O one-shot host-security marker does not match accepted run": "history.p8o-marker",
    "P8O actual FOUNDATION private summary unavailable": "history.p8o-summary",
    "reboot checkpoint identity or JSON schema invalid": "history.p8p-checkpoint",
    "accepted pre/postboot one-shot continuity invalid": "history.boot-marker-continuity",
    "unreviewed reboot after accepted P8R": "history.reboot-after-rearm",
    "immutable source, Age/SOPS, restored SQLite or P8O evidence changed after reboot": "state.protected-hashes",
    "installed immutable rc.12 release pointer changed": "state.release-pointer",
    "52 original installed product files changed": "state.release-integrity",
    "12 installed systemd unit bytes changed": "state.systemd-integrity",
    "original isolated ext4 disk/source markers changed": "state.storage-device",
    "restored hostname/offline identity/SMTP/Box no-prune configuration changed": "state.config-and-retention",
    "restored SOPS/admin/remediation authority changed": "state.secrets-authority",
    "recovered SQLite integrity or pinned historical digest changed": "state.sqlite",
    "app/DNS/timer enabled or active across reboot": "state.service-activation",
    "retained Docker container could auto-start on reboot": "state.docker-container",
    "unexpected public HTTP or Docker TCP listener": "state.network-listener",
    "CrowdSec engine or host INPUT bouncer lost boot-enabled/active state": "state.crowdsec-host",
    "Cloudflare Worker must remain boot-disabled/inactive": "state.cloudflare-worker",
    "installed 27-check product doctor failed contract validation": "doctor.schema",
    "unexpected installed security/runtime doctor FAIL ID": "doctor.unexpected-failure",
    "CrowdSec or validated Cloudflare CIDR policy regressed": "doctor.local-foundation",
    "unsafe postreboot generated/volatile runtime path metadata": "doctor.unsafe-generated-path",
    "product runtime.paths and independent metadata disagree": "doctor.runtime-path-parity",
    "protected stopped-host doctor or origin guard mismatch": "doctor.origin-filter-or-schema",
}


def reason_code(error: Exception) -> str:
    # Keys are pinned constant messages that cannot contain unknown user data.
    # Discard every other exception string to avoid accidental secret exfiltration.
    fixed = REASON_CODES.get(str(error))
    if fixed is not None:
        return fixed
    for exception_type, code in (
        (FileNotFoundError, "os.missing-file"),
        (PermissionError, "os.permission-denied"),
        (NotADirectoryError, "os.invalid-parent"),
        (json.JSONDecodeError, "json.invalid-evidence"),
        (UnicodeError, "text.invalid-encoding"),
        (KeyError, "schema.missing-key"),
        (TypeError, "schema.invalid-type"),
        (ValueError, "schema.invalid-value"),
        (OSError, "os.unclassified"),
    ):
        if isinstance(error, exception_type):
            return code
    return "unclassified-safe-stop"


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if (len(argv) != 2 or argv[0] != "--expected-commit" or
            not SHA40.fullmatch(argv[1]) or not host_ok() or
            not source_clean(SOURCE, BRANCH, argv[1]) or
            not source_clean(P8P, P8P_BRANCH, P8P_SHA) or
            not source_clean(P8Q, P8Q_BRANCH, P8Q_SHA) or
            not source_clean(P8R, P8R_BRANCH, P8R_SHA)):
        print("BLOCKED: P8S requires exact clean reviewed branches, NEW Ubuntu 26.04 ARM64 VM and sudo -n")
        return 2

    report = None
    rows: list[tuple[str, str]] = []
    phase = ["prior.helper-import"]

    def enter(label: str) -> None:
        # Labels are authored constants only. Never include raw exception text,
        # private report content, path values, identities or host command output.
        if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{3,64}", label):
            raise Blocked("unsafe diagnostic phase")
        phase[0] = label

    try:
        p8p = import_checked(P8P, "production-p8p-batched-reboot-persistence-newvm.py", "p8s_a_prior_p8p")
        p8r = import_checked(P8R, "production-p8r-postboot-origin-rearm-batch.py", "p8s_a_prior_p8r")
        enter("prior.evidence-root-ownership")
        p8p.private_dir(EVIDENCE, {0, pwd.getpwnam("ubuntu").pw_uid})
        # Create a fresh private diagnostics directory *before* replaying all
        # historical evidence, so any failure remains actionable after one run.
        # P8S-A is observational; it has no one-shot mutation marker.
        enter("private.report-creation")
        report = folder_private()
        enter("prior.evidence-metadata")
        original = read_preflight(p8p, p8r, enter)
        rows.append(("PASS", "P8O/P8P/P8Q/P8R immutable historical evidence and original one-shot continuity validated"))

        enter("protected.snapshot")
        snapshot_dir = report / "snapshot"
        snapshot_dir.mkdir(mode=0o700)
        record = p8p.Report(snapshot_dir, "p8s-a")
        protected = p8p.snapshot(record, snapshot_dir, after_boot=True)
        enter("protected.hash-parity")
        p8p.compare_paths(original, protected)
        rows.append(("PASS", "Original dedicated ext4, historic restored SQLite/SOPS/Age and immutable product/units unchanged"))

        enter("doctor.helper-import")
        p5 = p8p.load_helper(p8p.P5_FILE, "p8s_a_doctor")
        enter("doctor.27-checks-and-security")
        checks, path_state, edge_ready = p8p.doctor(p5, snapshot_dir, after_boot=True)
        if (len(checks) != 27 or not edge_ready or
                checks.get("crowdsec.cloudflare") != "FAIL" or
                path_state not in ("PASS", "PENDING")):
            raise Blocked("protected stopped-host doctor or origin guard mismatch")

        enter("postflight.kernel-continuity")
        if R_SUMMARY.lstat().st_mtime < boot_time():
            raise Blocked("kernel changed during read-only preflight")

        rows.extend([
            ("PASS", "Original P8P BLOCKED outcome retained and P8R REARMED evidence verified"),
            ("PASS", "No app, DNS, timers, notifications, retained Docker containers or HTTP 80/443 listeners"),
            ("PASS", "CrowdSec engine/INPUT bouncer active; Worker disabled and inactive"),
            ("PASS", "Validated Cloudflare CIDRs and both-family effective DOCKER-USER 443 source policy"),
            ("PASS", "27-ID installed doctor schema and mandatory security/host/storage checks"),
            ("PASS" if path_state == "PASS" else "PENDING",
             "Stopped generated runtime paths " + path_state + "; no automatic repair"),
            ("PENDING", "External OCI/Cloudflare isolation remains unverified; controlled live phase on HOLD"),
            ("PENDING", "Original imported Box destination remains forbidden for writes, pruning and timer runs"),
            ("NOT RUN", "No replay, reboot, firewall mutation, Docker start, DNS/Worker, SMTP or Box operations"),
        ])
        return write_report(report, rows, "HOLD")
    except Exception as exc:
        # A previous P8S-A returned only a generic BLOCKED before a report
        # existed. Preserve private details; publish only authored phase and
        # exact allowlisted failure code so one operator run gives useful proof.
        message = ("Read-only acceptance failed at " + phase[0] + " reason=" +
                   reason_code(exc) + "; preserve VM and original markers")
        print("BLOCKED: " + message)
        if report is not None:
            try:
                rows.append(("BLOCKED", message))
                return write_report(report, rows, "BLOCKED")
            except Exception:
                print("BLOCKED: private diagnostic summary unavailable; no host repair attempted")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
