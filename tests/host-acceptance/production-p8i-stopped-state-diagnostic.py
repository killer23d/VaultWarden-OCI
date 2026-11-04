#!/usr/bin/env python3
"""P8I-D: classify one previously BLOCKED stopped-state check (READ-ONLY).

Target: NEW disposable rc.12 A1 Flex guest vaultwarden-oci-7-vnic only.
Requires the exact original P8I BLOCKED root-private summary. It never calls
Docker, starts/stops services, modifies systemd, touches cloud APIs/Box/DNS,
reads secrets, mounts/formats/restores storage or reruns P8H installation.
Only a NEW root-private sanitized report is written.
"""
from __future__ import annotations

import datetime as dt
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
BRANCH = "audit/rc12-p8i-stopped-state-diagnostic"
VERSION = "0.1.0-rc.12"
SOURCE = Path(__file__).resolve().parents[2]
P8I_EVIDENCE = "p8i-postinstall-20261104T214222Z-4058"
SHA_RE = re.compile(r"[a-f0-9]{40}\Z")
UNITS = (
    "vaultwarden-oci.target",
    "vaultwarden-oci.service",
    "vaultwarden-oci-health.service",
    "vaultwarden-oci-health.timer",
    "vaultwarden-oci-dns.service",
    "vaultwarden-oci-backup.service",
    "vaultwarden-oci-backup.timer",
    "vaultwarden-oci-maintenance.service",
    "vaultwarden-oci-maintenance.timer",
    "vaultwarden-oci-update-check.service",
    "vaultwarden-oci-update-check.timer",
    "vaultwarden-oci-notify@.service",
)
BAD_UNIT_FILES = frozenset(("enabled", "enabled-runtime", "linked", "linked-runtime"))
SAFE_LOADS = frozenset(("loaded", "not-found", "masked", "error", "bad-setting"))
SAFE_ACTIVES = frozenset(("inactive", "active", "failed", "activating", "deactivating", "reloading", "maintenance"))
SAFE_FILE_STATES = frozenset((
    "disabled", "static", "indirect", "enabled", "enabled-runtime",
    "linked", "linked-runtime", "masked", "masked-runtime", "generated",
    "transient", "alias", "bad", "unknown",
))


class Refusal(RuntimeError):
    pass


def source_pin_ok(sha: str) -> bool:
    if not SHA_RE.fullmatch(sha):
        return False
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat")
    rows = []
    for args in (("rev-parse", "HEAD"), ("branch", "--show-current"),
                 ("status", "--porcelain", "--untracked-files=all")):
        try:
            run = subprocess.run(
                ["/usr/bin/git", *args], cwd=SOURCE, env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=18, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        if run.returncode != 0 or len(run.stdout) > 8192:
            return False
        rows.append(run.stdout.decode("utf-8", "replace").strip())
    return rows == [sha, BRANCH, ""]


def guest_ok() -> bool:
    if (platform.node().split(".", 1)[0] != HOST or
            platform.machine() not in ("arm64", "aarch64") or
            sys.version_info[:2] != (3, 14)):
        return False
    try:
        release = {}
        for row in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
            if "=" in row:
                k, value = row.split("=", 1)
                release[k] = value.strip('"')
        with (SOURCE / "versions.toml").open("rb") as fd:
            version = tomllib.load(fd)["vaultwarden_oci"]["version"]
    except (OSError, KeyError, ValueError, TypeError, tomllib.TOMLDecodeError):
        return False
    return (
        release.get("ID") == "ubuntu" and
        release.get("VERSION_ID") == "26.04" and
        release.get("VERSION_CODENAME") == "resolute" and
        version == VERSION
    )


def protected_dir(path: Path, owners: set[int]) -> bool:
    try:
        meta = path.lstat()
    except OSError:
        return False
    return (stat.S_ISDIR(meta.st_mode) and meta.st_uid in owners
            and stat.S_IMODE(meta.st_mode) == 0o700)


def read_private_summary(path: Path) -> str:
    handle = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(handle, "rb") as stream:
        meta = os.fstat(stream.fileno())
        if (not stat.S_ISREG(meta.st_mode) or meta.st_uid != 0
                or stat.S_IMODE(meta.st_mode) != 0o600
                or not 256 <= meta.st_size <= 16384):
            raise Refusal("previous P8I summary has unsafe file type/mode/size")
        content = stream.read(16385)
        if len(content) > 16384:
            raise Refusal("previous P8I summary too large")
        return content.decode("utf-8", "replace")


def accepted_blocked_p8i(base: Path) -> None:
    folder = base / P8I_EVIDENCE
    if not protected_dir(folder, {0}):
        raise Refusal("previous P8I evidence directory missing or unsafe")
    raw = read_private_summary(folder / "summary.txt")
    rows = raw.splitlines()
    expected = (
        "Gate P8I - NEW isolated test VM installed-but-stopped witness (READ-ONLY)",
        "PASS       Original one-shot P8H install attempt/checkpoint",
        "PASS       Full installed product files=52, systemd units=12",
        "PASS       Mounted dedicated non-root ext4 and dual ownership markers",
        "PASS       Locked hostname/email, zero-prune/disabled Box config",
        "BLOCKED    Read-only check failed during stopped app and restore absence",
        "BLOCKED    P8I post-install read-only witness only",
    )
    if not all(any(row.startswith(value) for row in rows) for value in expected):
        raise Refusal("previous P8I blocked report no longer matches the accepted failure")


def run_readonly(args: list[str], seconds: int = 12) -> tuple[int | None, str]:
    try:
        p = subprocess.run(
            args, cwd="/", stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=seconds, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    if len(p.stdout) > 131072:
        return None, ""
    return p.returncode, p.stdout.decode("utf-8", "replace")


def category(value: str | None, allowed: frozenset[str]) -> str:
    if value is None or value == "":
        return "absent"
    return value if value in allowed else "unrecognized"


def systemd_classification(unit: str, code: int | None, output: str) -> tuple[bool, str]:
    """Mirror original P8I's strict stopped/unit semantics, but show safe category."""
    if unit not in UNITS:
        raise ValueError("unknown systemd unit name")
    fields: dict[str, str] = {}
    for line in output.splitlines():
        if "=" in line:
            k, value = line.split("=", 1)
            if k in {"LoadState", "ActiveState", "UnitFileState"}:
                if k in fields:
                    return False, f"{unit} duplicate-property"
                fields[k] = value
    load = category(fields.get("LoadState"), SAFE_LOADS)
    active = category(fields.get("ActiveState"), SAFE_ACTIVES)
    enabled = category(fields.get("UnitFileState"), SAFE_FILE_STATES)
    # The original P8I condition was intentionally exact, including templated
    # notify@.service. Do not relax it before observing a real unit status.
    passed = (
        code == 0 and fields.get("LoadState") == "loaded" and
        fields.get("ActiveState") == "inactive" and
        fields.get("UnitFileState") not in BAD_UNIT_FILES
    )
    rc = "ok" if code == 0 else "unavailable"
    return passed, f"{unit} query={rc} load={load} active={active} unitfile={enabled}"


def inspect_units(report: "Report") -> None:
    for unit in UNITS:
        rc, raw = run_readonly([
            "/usr/bin/systemctl", "show", unit, "--no-pager",
            "-p", "LoadState", "-p", "ActiveState", "-p", "UnitFileState",
        ])
        success, safe = systemd_classification(unit, rc, raw)
        report.add("PASS" if success else "BLOCKED", "Systemd " + safe)


def socket_classification(code: int | None, output: str) -> tuple[bool, str]:
    if code != 0 or len(output) > 131072:
        return False, "TCP listener read-only command failed"
    tcp_80 = tcp_443 = 0
    malformed = 0
    for line in output.splitlines():
        cols = line.split()
        match = re.search(r":([0-9]{1,5})$", cols[3]) if len(cols) >= 5 else None
        if match is None:
            malformed += 1
            continue
        port = int(match.group(1))
        if port == 80:
            tcp_80 += 1
        elif port == 443:
            tcp_443 += 1
    passed = not (tcp_80 or tcp_443 or malformed)
    return passed, (
        f"TCP listener counts port80={tcp_80} port443={tcp_443} "
        f"unparseable_rows={malformed} (no addresses exposed)"
    )


def inspect_tcp(report: "Report") -> None:
    rc, raw = run_readonly(["/usr/bin/ss", "-H", "-lnt"], seconds=15)
    passed, description = socket_classification(rc, raw)
    report.add("PASS" if passed else "BLOCKED", description)


def docker_classification(path: Path) -> tuple[bool, str]:
    """No docker CLI/socket; names and contents of Docker dirs NEVER printed."""
    try:
        meta = path.lstat()
    except FileNotFoundError:
        return True, "Docker container metadata directory absent"
    except OSError:
        return False, "Docker container metadata directory cannot be inspected"
    if not stat.S_ISDIR(meta.st_mode):
        return False, "Docker container metadata is symlink or unsafe non-directory"
    try:
        with os.scandir(path) as iterator:
            count = sum(1 for _ in iterator)
    except OSError:
        return False, "Docker container metadata count unavailable"
    if count > 100000:
        return False, "Docker container metadata count exceeded safe bound"
    return count == 0, f"Docker container metadata entries={count} (names withheld)"


def inspect_docker(report: "Report") -> None:
    passed, description = docker_classification(Path("/var/lib/docker/containers"))
    report.add("PASS" if passed else "BLOCKED", description)


def sqlite_classification(path: Path) -> tuple[bool, str]:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return True, "Pre-restore SQLite database ABSENT"
    except OSError:
        return False, "Pre-restore SQLite database status uninspectable"
    if stat.S_ISREG(mode):
        return False, "Pre-restore SQLite database PRESENT as regular file (contents withheld)"
    if stat.S_ISLNK(mode):
        return False, "Pre-restore SQLite database PRESENT as symlink (not followed)"
    return False, "Pre-restore SQLite database PRESENT as unexpected filesystem object"


def inspect_sqlite(report: "Report") -> None:
    passed, description = sqlite_classification(
        Path("/var/lib/vaultwarden-oci/data/db.sqlite3")
    )
    report.add("PASS" if passed else "BLOCKED", description)


class Report:
    def __init__(self, folder: Path):
        self.folder = folder
        self.rows: list[tuple[str, str]] = []
        self.blocked = False

    def add(self, level: str, message: str) -> None:
        if (level not in {"PASS", "BLOCKED", "PENDING", "NOT RUN"}
                or any(c in message for c in "\r\n\x00")
                or len(message) > 250):
            raise ValueError("unsafe diagnostic report")
        self.blocked |= level == "BLOCKED"
        self.rows.append((level, message))

    def finish(self) -> int:
        outcome = "BLOCKED" if self.blocked else "HOLD"
        self.rows.append((outcome, "P8I diagnostic ONLY; original P8I BLOCKED remains open for review"))
        content = "Gate P8I-D - NEW host stopped-state classification (READ-ONLY)\n"
        content += "\n".join(f"{level:<10} {message}" for level, message in self.rows) + "\n"
        destination = self.folder / "summary.txt"
        fd = os.open(
            destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
            getattr(os, "O_NOFOLLOW", 0), 0o600,
        )
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        print(content, end="")
        print("Private summary:", destination)
        print("Paste summary and P8ID_EXIT only; no raw systemd/disk/secret/journal output.")
        return 2 if self.blocked else 0


def private_new_folder() -> Path:
    operator = pwd.getpwnam("ubuntu")
    home = Path(operator.pw_dir)
    if home.is_symlink() or not home.is_dir():
        raise Refusal("ubuntu home unsafe")
    base = home / "vwoci-acceptance"
    if not protected_dir(base, {0, operator.pw_uid}):
        raise Refusal("root-private evidence parent unsafe")
    accepted_blocked_p8i(base)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder = base / f"p8id-stopped-state-{stamp}-{os.getpid()}"
    folder.mkdir(mode=0o700)
    return folder


def main() -> int:
    if (len(sys.argv) != 3 or sys.argv[1] != "--expected-commit"
            or not SHA_RE.fullmatch(sys.argv[2]) or os.geteuid() != 0
            or os.environ.get("SUDO_USER") != "ubuntu"
            or platform.node().split(".", 1)[0] != HOST):
        print("BLOCKED: run only via sudo -n from ubuntu on NEW host with exact SHA")
        return 2
    if not source_pin_ok(sys.argv[2]) or not guest_ok():
        print("BLOCKED: source branch/commit or OS/release identity unverified")
        return 2
    try:
        folder = private_new_folder()
    except Exception:
        print("BLOCKED: previous P8I evidence unavailable or private output unsafe")
        return 2
    report = Report(folder)
    try:
        report.add("PASS", "Original exact P8I BLOCKED evidence privately verified; originals unchanged")
        inspect_units(report)
        inspect_tcp(report)
        inspect_docker(report)
        inspect_sqlite(report)
        report.add("NOT RUN", "No docker/socket queries, systemd/service changes, Vaultwarden data reads, Box or cloud APIs")
        report.add("NOT RUN", "No restore, filesystem mount/format, package update, SMTP, DNS/ACME, Worker, timer or reboot")
    except KeyboardInterrupt:
        report.add("BLOCKED", "Diagnostic interrupted; no remedial action permitted")
    except Exception:
        report.add("BLOCKED", "Read-only stopped-state classification could not finish; details withheld")
    return report.finish()


if __name__ == "__main__":
    raise SystemExit(main())
