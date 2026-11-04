#!/usr/bin/env python3
"""P8I: read-only post-install evidence on NEW disposable rc.12 ARM64 VM.

The ONLY persistent write is a NEW root-private sanitized summary.  Never
restore, decrypt to a file, start an app/daemon, contact public DNS/Cloudflare/
Box, publish or enable a timer, format/mount storage, or retry setup.  Original
restored -6-vnic and historical P8H attempt/checkpoint are immutable inputs.

Result HOLD/exit 0 means an installed and still-stopped appliance only.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import ipaddress
import json
import os
import platform
import pwd
import re
import stat
import subprocess
import sys
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-7-vnic"
BRANCH = "audit/rc12-p8i-postinstall-stop-witness"
P8H_SHA = "f75e5b85d465abf328353b1bb94eaee1f7d66eff"
P8H_CHECKPOINT = "p8h-prepare-20261104T213043Z-2771"
P8G_EVIDENCE = "p8g-disk-network-witness-20261104T205546Z-2275"
PREVIOUS_DISK_FP = "b7cd04a730c8"
ORIGINAL_INSTANCE_FP = "0dccfd58cbbd"
ORIGINAL_VNIC_FP = "36862e16cc9f"
VERSION = "0.1.0-rc.12"
TEST_DOMAIN = "bw.lazymocha.com"
TEST_EMAIL = "bw@lazymocha.com"
SOURCE = Path(__file__).resolve().parents[2]
INSTALLED = Path("/opt/vaultwarden-oci/releases") / VERSION
CURRENT = Path("/opt/vaultwarden-oci/current")
STATE = Path("/var/lib/vaultwarden-oci")
ETC = Path("/etc/vaultwarden-oci")
SHA_RE = re.compile(r"[a-f0-9]{40}\Z")
UUID_RE = re.compile(r"[a-f0-9-]{36}\Z")
IMDS_ORIGIN = "http://169.254.169.254/opc/v2"
PRIVATE_NETS = tuple(ipaddress.ip_network(item) for item in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
))


class Blocked(RuntimeError):
    """Safe violation, never expose an underlying exception or secret."""


def tag(value: str) -> str:
    return hashlib.sha256(value.encode("ascii")).hexdigest()[:12]


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(data)
    return hasher.hexdigest()


def command(argv: list[str], *, seconds: int = 20, env=None) -> tuple[int | None, str]:
    """No shell; read-only fixed command callers; stderr always withheld."""
    try:
        task = subprocess.run(
            argv, cwd="/", env=env,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=seconds, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    if len(task.stdout) > 131072:
        return None, ""
    return task.returncode, task.stdout.decode("utf-8", "replace")


def exact_checkout(pin: str) -> bool:
    if not SHA_RE.fullmatch(pin):
        return False
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat")
    answers: list[str] = []
    for parts in (("rev-parse", "HEAD"), ("branch", "--show-current"),
                  ("status", "--porcelain")):
        try:
            task = subprocess.run(
                ["/usr/bin/git", *parts], cwd=SOURCE, env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=20, check=False,
            )
            if task.returncode != 0 or len(task.stdout) > 8192:
                return False
            answers.append(task.stdout.decode("utf-8", "replace").strip())
        except (OSError, subprocess.TimeoutExpired):
            return False
    return answers == [pin, BRANCH, ""]


def host_release() -> bool:
    if (platform.node().split(".", 1)[0] != HOST or
            platform.machine() not in {"arm64", "aarch64"} or
            sys.version_info[:2] != (3, 14)):
        return False
    try:
        fields = {}
        for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
            if "=" in line:
                k, value = line.split("=", 1)
                fields[k] = value.strip('"')
        with (SOURCE / "versions.toml").open("rb") as f:
            version = tomllib.load(f)["vaultwarden_oci"]["version"]
    except (OSError, TypeError, ValueError, KeyError, tomllib.TOMLDecodeError):
        return False
    return (
        fields.get("ID") == "ubuntu" and
        fields.get("VERSION_ID") == "26.04" and
        fields.get("VERSION_CODENAME") == "resolute" and
        version == VERSION
    )


def private_dir(path: Path) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    return stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o700


def private_read(path: Path, maximum: int = 32768) -> bytes:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) != 0o600
                or not 0 < info.st_size <= maximum):
            raise Blocked("protected evidence file invalid")
        return stream.read(maximum + 1)


def root_private_base() -> Path:
    operator = pwd.getpwnam("ubuntu")
    home = Path(operator.pw_dir)
    if home.is_symlink() or not home.is_dir():
        raise Blocked("operator home invalid")
    base = home / "vwoci-acceptance"
    try:
        info = base.lstat()
    except OSError as exc:
        raise Blocked("original acceptance evidence unavailable") from exc
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, operator.pw_uid)
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise Blocked("acceptance evidence parent unsafe")
    return base


def expected_install_evidence(base: Path) -> tuple[str, str]:
    """Require exact prior operator-approved P8H, not guessed install state."""
    p8h = base / P8H_CHECKPOINT
    p8g = base / P8G_EVIDENCE
    if not private_dir(p8h) or not private_dir(p8g):
        raise Blocked("accepted P8H/P8G evidence directory unavailable")
    checkpoint = json.loads(private_read(p8h / "checkpoint.json"))
    attempt = json.loads(private_read(p8h / "install-attempted.json"))
    summary = private_read(p8h / "install.summary.txt").decode("utf-8", "replace")
    g = private_read(p8g / "disk-details.txt").decode("utf-8", "replace")
    if (not isinstance(checkpoint, dict) or
            checkpoint.get("schema") != 1 or checkpoint.get("phase") != "prepared-only" or
            checkpoint.get("host") != HOST or checkpoint.get("commit") != P8H_SHA or
            checkpoint.get("instance_fingerprint") != ORIGINAL_INSTANCE_FP or
            checkpoint.get("vnic_fingerprint") != ORIGINAL_VNIC_FP or
            checkpoint.get("disk_alias_fingerprint") != PREVIOUS_DISK_FP or
            checkpoint.get("disk_size_bytes") != 50 * 1024 ** 3 or
            checkpoint.get("p8g_evidence_sha256") != hashlib.sha256(
                private_read(p8g / "summary.txt") + b"\0" +
                private_read(p8g / "disk-details.txt")).hexdigest()):
        raise Blocked("P8H installation checkpoint/source/disk binding changed")
    if (not isinstance(attempt, dict) or
            attempt.get("schema") != 1 or attempt.get("mode") != "one-shot-format-and-install" or
            attempt.get("host") != HOST or attempt.get("commit") != P8H_SHA or
            attempt.get("disk_fingerprint") != PREVIOUS_DISK_FP or
            attempt.get("source_checkpoint") != "checkpoint.json" or
            attempt.get("target_hostname_sha256") != hashlib.sha256(TEST_DOMAIN.encode()).hexdigest() or
            attempt.get("boot_id") != checkpoint.get("boot_id")):
        raise Blocked("exclusive installation attempt marker not bound to the accepted checkpoint")
    current_boot = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
    if not UUID_RE.fullmatch(current_boot) or checkpoint.get("boot_id") != current_boot:
        raise Blocked("unexpected reboot since accepted P8H first installation")
    needed = (
        "Gate P8H - consented isolated FIRST INSTALL",
        "PASS       Exact single format/install attempt completed",
        "PASS       Dedicated ext4 identity/marker, immutable rc.12 source",
        "PASS       LOCKED install-only hostname bw.lazymocha.com and bw@lazymocha.com",
        "PASS       Backup remote disabled and retention zero",
        "HOLD       Installed but stopped; SHARED test hostname does NOT authorize DNS",
    )
    rows = summary.splitlines()
    if not all(any(row.startswith(marker) for row in rows) for marker in needed):
        raise Blocked("accepted P8H installer HOLD summary incomplete")
    if any(row.startswith("BLOCKED") for row in rows):
        raise Blocked("accepted P8H installer summary contains blocker")
    # Logs remain PRIVATE, but require evidence that each original owner call ran.
    for name in ("setup-dryrun.private.log", "setup-install.private.log"):
        private_read(p8h / name, maximum=4 * 1024 * 1024)
    source_path = None
    size_bytes = None
    aliases: list[str] = []
    for line in g.splitlines():
        if line.startswith("resolved_block_path="):
            source_path = line.partition("=")[2]
        elif line.startswith("capacity_bytes="):
            try:
                size_bytes = int(line.partition("=")[2])
            except ValueError as exc:
                raise Blocked("P8G capacity record malformed") from exc
        elif line.startswith("stable_by_id="):
            aliases.append(line.partition("=")[2])
    if (not isinstance(source_path, str) or
            not re.fullmatch(r"/dev/[A-Za-z0-9._/+:-]+", source_path) or
            size_bytes != 50 * 1024 ** 3 or
            len(aliases) != 2 or len(set(aliases)) != 2 or
            not all(a.startswith("/dev/disk/by-id/") for a in aliases) or
            tag(sorted(aliases)[0]) != PREVIOUS_DISK_FP):
        raise Blocked("private disk ownership record changed")
    return source_path, checkpoint["boot_id"]


def compare_release(source: Path, installed: Path) -> tuple[int, int]:
    """Hash each product-owned file; check immutable installed modes and units."""
    roots = ("vwctl", "versions.toml", "email-providers.toml")
    directories = ("vaultwarden_oci", "systemd")
    selected: set[str] = set()
    for name in roots:
        selected.add(name)
    for directory in directories:
        if not (source / directory).is_dir():
            raise Blocked("reviewed product files unavailable")
        for item in (source / directory).rglob("*"):
            if item.is_symlink():
                raise Blocked("unexpected symlink in product source")
            if item.is_file():
                selected.add(item.relative_to(source).as_posix())
            elif not item.is_dir():
                raise Blocked("unexpected product source object")
    if len(selected) < 40:
        raise Blocked("incomplete immutable source inventory")
    for directory in directories:
        if not (installed / directory).is_dir() or (installed / directory).is_symlink():
            raise Blocked("installed product directory not canonical")
    actual: set[str] = set()
    for item in roots:
        actual.add(item)
    for directory in directories:
        for item in (installed / directory).rglob("*"):
            if item.is_symlink():
                raise Blocked("symlink in installed release")
            info = item.lstat()
            if info.st_uid != 0 or stat.S_IMODE(info.st_mode) not in ({0o555} if stat.S_ISDIR(info.st_mode) else {0o444, 0o555}):
                raise Blocked("installed immutable file ownership/mode changed")
            if stat.S_ISREG(info.st_mode):
                actual.add(item.relative_to(installed).as_posix())
            elif not stat.S_ISDIR(info.st_mode):
                raise Blocked("unexpected release object")
    if actual != selected:
        raise Blocked("installed product file inventory diverges from reviewed source")
    for name in selected:
        file = installed / name
        src = source / name
        if (not file.is_file() or file.is_symlink()
                or file.lstat().st_uid != 0
                or stat.S_IMODE(file.lstat().st_mode) not in {0o444, 0o555}
                or digest(src) != digest(file)):
            raise Blocked("immutable release content/mode changed")
    sys.path.insert(0, str(source))
    from vaultwarden_oci import install
    for unit in install.SYSTEMD_UNITS:
        path = Path("/etc/systemd/system") / unit
        info = path.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or
                stat.S_IMODE(info.st_mode) != 0o644 or
                digest(installed / "systemd" / unit) != digest(path)):
            raise Blocked("installed systemd unit differs from immutable release")
    return len(selected), len(install.SYSTEMD_UNITS)


def verify_storage(source_path: str) -> str:
    sys.path.insert(0, str(SOURCE))
    from vaultwarden_oci import storage
    identity = storage.verify()
    storage.reject_boot_related(identity.source)
    if (identity.fs_type != "ext4" or
            Path(identity.source).resolve(strict=True) !=
            Path(source_path).resolve(strict=True) or
            os.stat(STATE).st_dev == os.stat("/").st_dev):
        raise Blocked("installed disk/root separation/ownership changed")
    return tag(identity.uuid)


def safe_root_file(path: Path) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    return (stat.S_ISREG(info.st_mode) and info.st_uid == 0 and
            stat.S_IMODE(info.st_mode) == 0o600 and info.st_size > 0)


def config_and_secrets() -> None:
    if not (safe_root_file(ETC / "config.toml") and
            safe_root_file(ETC / "age-key.txt") and
            safe_root_file(ETC / "secrets.sops.yaml")):
        raise Blocked("protected config/SOPS/Age file state incorrect")
    with (ETC / "config.toml").open("rb") as f:
        config = tomllib.load(f)
    if (config.get("site", {}).get("domain") != TEST_DOMAIN or
            config["site"].get("acme_email") != TEST_EMAIL or
            config["backup"].get("remote") != "" or
            type(config["backup"].get("local_retention_days")) is not int or
            config["backup"]["local_retention_days"] != 0 or
            type(config["backup"].get("remote_retention_days")) is not int or
            config["backup"]["remote_retention_days"] != 0):
        raise Blocked("locked test hostname/backup no-prune policy changed")
    sys.path.insert(0, str(SOURCE))
    from vaultwarden_oci import cli, secrets
    cli.validate_config(ETC / "config.toml")
    secrets.validate_custody(config["secrets"]["offline_recovery_recipient"])
    env = dict(os.environ, SOPS_AGE_KEY_FILE=str(ETC / "age-key.txt"))
    code, _ = command([
        "/usr/local/bin/sops", "--decrypt", "--output", "/dev/null",
        str(ETC / "secrets.sops.yaml"),
    ], seconds=40, env=env)
    if code != 0:
        raise Blocked("SOPS encrypted custody or operational decryption failed")


def service_state() -> tuple[int, int]:
    from vaultwarden_oci import install
    for unit in install.SYSTEMD_UNITS:
        rc, output = command([
            "/usr/bin/systemctl", "show", unit, "--no-pager",
            "-p", "LoadState", "-p", "ActiveState", "-p", "UnitFileState",
        ])
        props = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
        if (rc != 0 or props.get("LoadState") != "loaded" or
                props.get("ActiveState") != "inactive" or
                props.get("UnitFileState") in {
                    "enabled", "enabled-runtime", "linked", "linked-runtime",
                }):
            raise Blocked("installed appliance unit enabled, active or unverifiable")
    code, sockets = command(["/usr/bin/ss", "-H", "-lnt"], seconds=12)
    if code != 0:
        raise Blocked("local port inventory unavailable")
    for line in sockets.splitlines():
        cols = line.split()
        port = re.search(r":([0-9]{1,5})$", cols[3]) if len(cols) >= 5 else None
        if port is None:
            raise Blocked("unexpected local port inventory shape")
        if int(port.group(1)) in (80, 443):
            raise Blocked("live HTTP listener detected on stopped acceptance VM")
    # Read Docker's on-disk container metadata only; querying docker/socket can
    # activate a daemon. Any retained container means runtime isolation differs.
    containers = Path("/var/lib/docker/containers")
    if containers.exists() or containers.is_symlink():
        if containers.is_symlink() or not containers.is_dir() or any(containers.iterdir()):
            raise Blocked("retained Docker container metadata is unexpected")
    db = STATE / "data" / "db.sqlite3"
    if db.exists() or db.is_symlink():
        raise Blocked("Vaultwarden database present before separately consented restore")
    return len(install.SYSTEMD_UNITS), 0


class Report:
    def __init__(self, directory: Path):
        self.directory = directory
        self.rows: list[tuple[str, str]] = []
        self.blocked = False

    def add(self, status: str, message: str) -> None:
        if (status not in {"PASS", "PENDING", "NOT RUN", "BLOCKED"} or
                any(c in message for c in "\r\n\x00") or len(message) > 1024):
            raise ValueError("unsafe report row")
        self.rows.append((status, message))
        self.blocked |= status == "BLOCKED"

    def finish(self) -> int:
        decision = "BLOCKED" if self.blocked else "HOLD"
        self.rows.append((decision, "P8I post-install read-only witness only; no restore/live-start/production GO"))
        text = "Gate P8I - NEW isolated test VM installed-but-stopped witness (READ-ONLY)\n"
        text += "\n".join(f"{level:<10} {message}" for level, message in self.rows) + "\n"
        out = self.directory / "summary.txt"
        fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        print(text, end="")
        print("Private summary:", out)
        print("Paste sanitized summary/P8I_EXIT only; never share installed secrets, P8H logs or original kit.")
        return 2 if self.blocked else 0


def main() -> int:
    if (len(sys.argv) != 3 or sys.argv[1] != "--expected-commit" or
            not SHA_RE.fullmatch(sys.argv[2]) or os.geteuid() != 0 or
            os.environ.get("SUDO_USER") != "ubuntu" or
            platform.node().split(".", 1)[0] != HOST):
        print("BLOCKED: run via sudo -n from ubuntu on NEW host with exact P8I PR commit")
        return 2
    if not exact_checkout(sys.argv[2]) or not host_release():
        print("BLOCKED: source/branch/OS/release identity differs; no host action")
        return 2
    try:
        base = root_private_base()
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        out = base / f"p8i-postinstall-{stamp}-{os.getpid()}"
        out.mkdir(mode=0o700)
    except Exception:
        print("BLOCKED: private acceptance evidence unavailable")
        return 2
    report = Report(out)
    stage = "original P8H attempt and HOLD"
    try:
        disk, _boot = expected_install_evidence(base)
        report.add("PASS", "Original one-shot P8H install attempt/checkpoint and successful HOLD evidence intact")
        stage = "immutable installed release"
        if not CURRENT.is_symlink() or CURRENT.resolve(strict=True) != INSTALLED:
            raise Blocked("installed release pointer changed")
        files, units = compare_release(SOURCE, INSTALLED)
        report.add("PASS", f"Full installed product files={files}, systemd units={units} match immutable reviewed rc.12")
        stage = "dedicated storage"
        identity_fp = verify_storage(disk)
        report.add("PASS", f"Mounted dedicated non-root ext4 and dual ownership markers match P8G disk; UUID fingerprint={identity_fp}")
        stage = "protected config and encrypted secret custody"
        config_and_secrets()
        report.add("PASS", "Locked hostname/email, zero-prune/disabled Box config, operational SOPS and ORIGINAL public Age recipient")
        stage = "stopped app and restore absence"
        unit_count, container_count = service_state()
        report.add("PASS", f"Installed systemd units={unit_count} inactive/not enabled, no HTTP listeners or retained containers={container_count}")
        report.add("PASS", "No Vaultwarden database present; original encrypted recovery has NOT been restored")
        report.add("PENDING", "Shared configured hostname does NOT prove unique Cloudflare/DNS/Worker/ACME routing")
        report.add("PENDING", "Offline private Age key/ZIP and exact remote ciphertext require a separate read-only recovery-source consent")
        report.add("PENDING", "OCI NSG/security-list effective rules and new volume ownership remain operator attestations, not API readback")
        report.add("NOT RUN", "No recovery artifact/ZIP/Box read, decryption to disk, restore, Docker socket, DNS update or Caddy start")
        report.add("NOT RUN", "No firewall/OCI/Cloudflare change, package install, timer, SMTP delivery, ACME issuance, reboot or cutover")
        return report.finish()
    except KeyboardInterrupt:
        report.add("BLOCKED", "Interrupted during " + stage + "; no repair or retry")
    except Exception:
        report.add("BLOCKED", "Read-only check failed during " + stage + "; details withheld")
    return report.finish()


if __name__ == "__main__":
    raise SystemExit(main())
