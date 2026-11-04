#!/usr/bin/env python3
"""P8A: read-only isolation readiness of the already restored rc.12 appliance.

Host: the ORIGINAL disposable Ubuntu 26.04 ARM64 VM only. The script never
starts a service, changes the Cloudflare origin firewall, queries Cloudflare/OCI
APIs, writes Box objects, sends mail, changes DNS, or reboots. It writes only a
root-private sanitized summary. External isolation is always PENDING until
independently verified in a later, separately authorized gate.

The historical P7 checkpoint contains ABSOLUTE paths to its original checkout.
P8 deliberately compares the SAME bytes by reviewed script basename, without
reading arbitrary checkpoint-controlled paths or changing the old checkpoint.
"""
from __future__ import annotations

import datetime as dt
import fnmatch
import importlib.util
import inspect
import json
import os
import platform
import re
import stat
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-6-vnic"
RELEASE = "0.1.0-rc.12"
BRANCH = "audit/rc12-p8-isolation-preflight"
BASE = Path(__file__).resolve().parents[2]
ACCEPTANCE = Path(__file__).resolve().parent
P7_FILE = ACCEPTANCE / "production-reboot-persistence-consent.py"
P5_NAME = "production-security-foundation-consent.py"
P6_NAME = "production-postfoundation-isolation-readiness.py"
P7_NAME = P7_FILE.name
PROTECTED_SOURCE_NAMES = frozenset((P5_NAME, P6_NAME, P7_NAME))
P7R_MARKER = "p7r-origin-rearm-attempted.json"
P7R_ACCEPTED = "p7r-origin-rearm-20261104T181146Z-5615"
SHARED_HOSTNAME = "bw.lazymocha.com"
EXPECTED_REMOTE = "bw-backup:bw-backup"
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")


class Blocked(RuntimeError):
    """An untrusted or changed local acceptance prerequisite."""


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise Blocked("reviewed source module is missing")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def host_identity_ok() -> bool:
    """No host mutation or network lookup. Python 3.14 is native on the VM."""
    if (platform.node().split(".")[0] != HOST
            or platform.machine() not in {"aarch64", "arm64"}
            or sys.version_info[:2] != (3, 14)):
        return False
    try:
        pairs = dict(
            line.split("=", 1) for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines()
            if "=" in line
        )
    except OSError:
        return False
    return pairs.get("ID", "").strip('"') == "ubuntu" and pairs.get("VERSION_ID", "").strip('"') == "26.04"


def git_readonly(*args: str) -> tuple[int, str]:
    env = dict(os.environ)
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["GIT_PAGER"] = "cat"
    try:
        run = subprocess.run(
            ["/usr/bin/git", *args], cwd=BASE, env=env,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=25, check=False,
        )
        return run.returncode, run.stdout[:8192].decode("utf-8", "replace").strip()
    except (OSError, subprocess.TimeoutExpired):
        return -1, ""


def source_checkout_ok(expected: str) -> bool:
    """Verify the exact PR HEAD, branch and cleanliness without writing git locks."""
    if not SHA_PATTERN.fullmatch(expected):
        return False
    code, head = git_readonly("rev-parse", "--verify", "HEAD")
    if code != 0 or head != expected:
        return False
    code, branch = git_readonly("branch", "--show-current")
    if code != 0 or branch != BRANCH:
        return False
    code, dirty = git_readonly("status", "--porcelain", "--untracked-files=all")
    return code == 0 and not dirty


def source_contract(lifecycle_text: str, render_text: str) -> bool:
    """Assert the accepted product source's critical fail-closed start ordering."""
    refresh = lifecycle_text.find("edge.refresh_origin_policy(runner=runner)")
    compose = lifecycle_text.find('_compose(args, paths, runner)')
    return (
        refresh >= 0 and compose > refresh
        and 'restart: "no"' in render_text
        and 'ports: ["443:443/tcp"]' in render_text
        and "restart: unless-stopped" in render_text
    )


def private_read(path: Path, *, maximum: int = 32768) -> bytes:
    """Read only a root-owned, 0600, bounded regular file; refuse symlinks."""
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        meta = os.fstat(stream.fileno())
        if (not stat.S_ISREG(meta.st_mode) or meta.st_uid != 0
                or stat.S_IMODE(meta.st_mode) != 0o600
                or not 0 < meta.st_size <= maximum):
            raise Blocked("protected private evidence has unsafe ownership or size")
        return stream.read(maximum + 1)


def evidence_proof(p7, base: Path) -> tuple[dict[str, object], str]:
    """Validate, never modify, P7 checkpoint and exclusive P7R attempt record."""
    checkpoint = p7.read_checkpoint(p7.checkpoint_path(base))
    if checkpoint.get("phase") != "reboot-requested":
        raise Blocked("original P7 HOLD checkpoint is absent or changed")
    now = p7.read_boot_id()
    if now == checkpoint.get("boot_id"):
        raise Blocked("P7 did not prove a different actual boot")
    original_dir = p7.evidence_dir(base, "verify", checkpoint)
    old_summary = private_read(original_dir / "verify.summary.txt").decode("utf-8", "replace")
    if not any(line.startswith("HOLD") for line in old_summary.splitlines()):
        raise Blocked("original P7 stopped reboot HOLD evidence is missing")

    marker = json.loads(private_read(base / P7R_MARKER, maximum=4096))
    if (not isinstance(marker, dict) or set(marker) !=
            {"schema", "gate", "original_boot", "current_boot"}
            or marker["schema"] != 1 or marker["gate"] != "p7r-origin-rearm"
            or marker["original_boot"] != checkpoint["boot_id"]
            or marker["current_boot"] != now):
        raise Blocked("P7R one-shot attempt marker differs from original reboot")
    rearm_dir = base / P7R_ACCEPTED
    info = rearm_dir.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != 0
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise Blocked("accepted P7R private evidence directory is missing or unsafe")
    rearm_summary = private_read(rearm_dir / "summary.txt").decode("utf-8", "replace")
    if not any(line.startswith("REARMED") for line in rearm_summary.splitlines()):
        raise Blocked("original P7R accepted re-arm summary is missing")
    return checkpoint, now


def checkpoint_content_matches(
    checkpoint: dict[str, object],
    paths: tuple[Path, ...],
    digests: dict[str, str],
) -> bool:
    """Compare P7 content digests across checkouts without following old paths."""
    prior = checkpoint.get("sha256")
    if not isinstance(prior, dict) or len(prior) != 9 or len(paths) != 9:
        return False
    if set(digests) != {str(p) for p in paths}:
        return False
    source_parent = BASE / "tests/host-acceptance"
    used: set[str] = set()
    old_source_parent: str | None = None
    for path in paths:
        path_key = str(path)
        if path.parent == source_parent and path.name in PROTECTED_SOURCE_NAMES:
            candidates = [
                key for key in prior
                if isinstance(key, str)
                and re.fullmatch(
                    r"/home/ubuntu/[A-Za-z0-9._-]+/tests/host-acceptance/"
                    + re.escape(path.name), key,
                )
            ]
            if len(candidates) != 1:
                return False
            original = candidates[0]
            parent = str(Path(original).parent)
            if old_source_parent is not None and old_source_parent != parent:
                return False
            old_source_parent = parent
        else:
            original = path_key
        if original in used or prior.get(original) != digests[path_key]:
            return False
        used.add(original)
    return set(prior) == used


def isolation_conflicts(
    candidate: str | None,
    shared: str,
    worker_routes: tuple[str, ...],
) -> tuple[str, ...]:
    """Evaluate a HYPOTHETICAL plan, not evidence that any live route is safe.

    Unknown route formats fail closed. A distinct name is necessary but never
    sufficient; OCI ingress, CF zone authority, DNS and custody remain external.
    """
    if candidate is None:
        return ()
    if not re.fullmatch(r"[a-z0-9-]+(?:\.[a-z0-9-]+)+", candidate):
        return ("invalid_candidate_hostname",)
    findings: list[str] = []
    if candidate == shared:
        findings.append("shared_hostname_collision")
    for route in worker_routes:
        pattern = route.split("/", 1)[0].lower()
        if not re.fullmatch(r"[a-z0-9*.-]+", pattern) or not pattern:
            findings.append("unverifiable_worker_route_format")
        elif fnmatch.fnmatchcase(candidate, pattern):
            findings.append("worker_route_overlap")
    return tuple(sorted(set(findings)))


class Report:
    def __init__(self, private_dir: Path):
        self.private_dir = private_dir
        self.rows: list[tuple[str, str]] = []
        self.blocked = False

    def add(self, status: str, message: str) -> None:
        if (status not in {"PASS", "PENDING", "BLOCKED", "NOT RUN"}
                or len(message) > 1800 or any(ch in message for ch in "\r\n\x00")):
            raise ValueError("untrusted report row")
        self.rows.append((status, message))
        self.blocked |= status == "BLOCKED"

    def finish(self) -> int:
        result = "BLOCKED" if self.blocked else "HOLD"
        self.rows.append((result, "P8A local assessment only; no isolated live start or production GO authorized"))
        body = "Gate P8A - rc.12 original disposable host, READ-ONLY isolation preflight\n"
        body += "\n".join(f"{level:<10} {message}" for level, message in self.rows) + "\n"
        summary = self.private_dir / "summary.txt"
        with summary.open("x", encoding="utf-8") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        print(body, end="")
        print("Private summary:", summary)
        print("Paste only the summary and exit status; never post private evidence or doctor output.")
        return 2 if self.blocked else 0


def main() -> int:
    if (len(sys.argv) != 3 or sys.argv[1] != "--expected-commit"
            or not SHA_PATTERN.fullmatch(sys.argv[2])):
        print("BLOCKED: usage: P8A --expected-commit <40-character reviewed PR HEAD>", file=sys.stderr)
        return 2
    if os.geteuid() != 0 or os.environ.get("SUDO_USER") != "ubuntu":
        print("BLOCKED: use passwordless sudo -n from ubuntu", file=sys.stderr)
        return 2
    if not host_identity_ok():
        print("BLOCKED: not the approved Ubuntu 26.04 ARM64 Python 3.14 host", file=sys.stderr)
        return 2
    try:
        p7 = load_module(P7_FILE, "p8_readonly_original_p7")
        base = p7.safe_base()
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        out = base / f"p8-isolation-preflight-{stamp}-{os.getpid()}"
        out.mkdir(mode=0o700)
    except Exception:
        print("BLOCKED: cannot initialize private P8 evidence; no appliance mutation attempted", file=sys.stderr)
        return 2
    report = Report(out)
    stage = "exact reviewed source"
    try:
        if not source_checkout_ok(sys.argv[2]):
            raise Blocked("candidate SHA, branch or clean checkout does not match operator pin")
        report.add("PASS", "Exact reviewed PR HEAD and clean P8 acceptance branch verified")
        stage = "immutable host evidence"
        checkpoint, now = evidence_proof(p7, base)
        report.add("PASS", "Original P7 reboot HOLD checkpoint and P7R REARMED/one-shot marker intact; different boot verified")
        stage = "installed product and stopped host"
        host_report = p7.Report(out, "p8-readonly-snapshot")
        paths, digests = p7.host_snapshot(host_report, after_boot=True)
        if not checkpoint_content_matches(checkpoint, paths, digests):
            raise Blocked("protected P7 source, SQLite, volume or SOPS/Age hashes changed")
        if any(
            status == "PENDING" and "not persistent across cold boot" in message
            for status, message in host_report.rows
        ):
            raise Blocked("Cloudflare Docker TCP/443 origin policy regressed after the accepted P7R re-arm")
        if not any(
            status == "PASS" and "All five local origin/CrowdSec" in message
            for status, message in host_report.rows
        ):
            raise Blocked("P7R origin security or product doctor controls were not proven healthy")
        for status, message in host_report.rows:
            report.add(status, message)
        report.add("PASS", "Original protected data/source digests verified across independent Git checkouts without changing P7 checkpoint")
        stage = "startup side-effect contract"
        from vaultwarden_oci import runtime
        if not source_contract(inspect.getsource(runtime.lifecycle), inspect.getsource(runtime.render)):
            raise Blocked("fail-closed installed first-start ordering or Caddy no-restart contract changed")
        cfg = runtime.load_config()
        if cfg.domain != SHARED_HOSTNAME or cfg.offsite_remote != EXPECTED_REMOTE:
            raise Blocked("historical shared hostname or backup destination changed")
        report.add("PASS", "Installed start source refreshes Cloudflare ingress before Compose; Caddy restart=no")
        report.add("PENDING", "Restored configuration still targets shared public hostname; no isolated Caddy/TLS startup allowed")
        report.add("PENDING", "OCI NSG/security lists, public IPv4/IPv6 and separate ingress boundary need independent authoritative read-only proof")
        report.add("PENDING", "Distinct test-only DNS authority and Cloudflare-proxied routing need independent read-only proof")
        report.add("PENDING", "Existing Cloudflare Worker Routes and current-invocation Fail Open need separate verified scope/approval")
        report.add("PENDING", "Off-host original encrypted recovery kit, private Age identity and separate ZIP passphrase custody need independent attestation")
        report.add("PENDING", "A separate test-only remote Box prefix and rollback/stop plan must be approved before live operations")
        report.add("NOT RUN", "No OCI/Cloudflare API, DNS mutation, Worker action, ACME DNS-01, app/Caddy or Docker container startup")
        report.add("NOT RUN", "No SMTP, notification, Box read/write/prune, timer, package/firewall modification, restore, reboot or rollback")
        return report.finish()
    except KeyboardInterrupt:
        report.add("BLOCKED", "Interrupted during " + stage + "; local state has not been repaired or re-armed")
    except Exception:
        report.add("BLOCKED", "Read-only security/integrity preflight failed during " + stage + "; details withheld")
    return report.finish()


if __name__ == "__main__":
    raise SystemExit(main())
