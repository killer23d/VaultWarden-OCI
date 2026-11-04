#!/usr/bin/env python3
"""P8H: isolated NEW-host prepare and separately consented rc.12 installation.

First invocation --prepare is READ ONLY except for new root-private evidence.
--install is a distinct, explicitly typed destructive disk-format/install action.
This script NEVER restores previous application data, contacts Cloudflare/Box,
starts Vaultwarden/Caddy, publishes DNS, sends mail or enables timers.
The original restored -6-vnic MUST NEVER run either phase.

Only the supported setup.sh install path may provision the approved blank disk,
with its existing --confirm-format and --offline-recipient contracts.
An exclusive attempt marker precedes any mutable setup invocation: never
automatically retry a partial or uncertain installation.
"""
from __future__ import annotations

import argparse
import datetime as dt
import getpass
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
import urllib.request
from dataclasses import dataclass
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-7-vnic"
BRANCH = "audit/rc12-p8h-testhostname-install-consent"
VERSION = "0.1.0-rc.12"
# This is an INSTALL-ONLY hostname approved by the operator. It is ALSO used
# by the earlier stopped restored VM; that is NOT proof of a unique live origin.
# Public startup, Cloudflare DNS/ACME and Worker use remain separately blocked.
TEST_HOSTNAME = "bw.lazymocha.com"
TEST_ACME_EMAIL = "bw@lazymocha.com"
SOURCE = Path(__file__).resolve().parents[2]
P8G_NAME = "p8g-disk-network-witness-20261104T205546Z-2275"
P8G_COMMIT = "a98a58d02160ac01e9e9ce7bc8ba683a33929915"
INSTANCE_FINGERPRINT = "0dccfd58cbbd"
VNIC_FINGERPRINT = "36862e16cc9f"
ALIAS_FINGERPRINT = "b7cd04a730c8"
EXPECTED_GIB = 50
IMDS_ORIGIN = "http://169.254.169.254/opc/v2"
SHA_RE = re.compile(r"[a-f0-9]{40}\Z")
RECIPIENT_RE = re.compile(r"age1[0-9a-z]{50,70}\Z")
DOMAIN_RE = re.compile(r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}\Z")
MAIL_RE = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}\Z")
BYID_PREFIX = ("scsi-", "wwn-", "nvme-", "virtio-")
PROTECTED = tuple(map(Path, (
    "/opt/vaultwarden-oci", "/etc/vaultwarden-oci",
    "/var/lib/vaultwarden-oci", "/run/vaultwarden-oci",
)))
UNITS = (
    "vaultwarden-oci.target", "vaultwarden-oci.service",
    "vaultwarden-oci-dns.service", "vaultwarden-oci-health.timer",
    "vaultwarden-oci-backup.timer", "vaultwarden-oci-maintenance.timer",
    "vaultwarden-oci-update-check.timer",
)
PRIVATE_NETS = tuple(map(ipaddress.ip_network, (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
)))


class Blocked(RuntimeError):
    """Never print exception text from underlying system commands."""


@dataclass(frozen=True)
class DiskWitness:
    resolved: str
    size_bytes: int
    aliases: tuple[str, ...]
    source_evidence_sha256: str


def tag(value: str) -> str:
    return hashlib.sha256(value.encode("ascii")).hexdigest()[:12]


def execute(argv: list[str], *, timeout: int = 20) -> tuple[int | None, str]:
    try:
        p = subprocess.run(argv, cwd="/", stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    if len(p.stdout) > 131072:
        return None, ""
    return p.returncode, p.stdout.decode("utf-8", "replace")


def exact_source(expected: str) -> bool:
    if not SHA_RE.fullmatch(expected):
        return False
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat")
    answers: list[str] = []
    for cmd in (("rev-parse", "HEAD"), ("branch", "--show-current"), ("status", "--porcelain")):
        try:
            p = subprocess.run(
                ["/usr/bin/git", *cmd], cwd=SOURCE, env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=25, check=False,
            )
            if p.returncode or len(p.stdout) > 8192:
                return False
            answers.append(p.stdout.decode("utf-8", "replace").strip())
        except (OSError, subprocess.TimeoutExpired):
            return False
    return answers == [expected, BRANCH, ""]


def host_ok() -> bool:
    if (platform.node().split(".")[0] != HOST or
            platform.machine() not in ("aarch64", "arm64") or
            sys.version_info[:2] != (3, 14)):
        return False
    try:
        release = {}
        for item in Path("/etc/os-release").read_text().splitlines():
            if "=" in item:
                k, v = item.split("=", 1)
                release[k] = v.strip('"')
        with (SOURCE / "versions.toml").open("rb") as handle:
            manifest = tomllib.load(handle)["vaultwarden_oci"]["version"]
    except (OSError, KeyError, TypeError, ValueError, tomllib.TOMLDecodeError):
        return False
    return (release.get("ID") == "ubuntu"
            and release.get("VERSION_ID") == "26.04"
            and release.get("VERSION_CODENAME") == "resolute"
            and manifest == VERSION)


def accepted_base() -> Path:
    home = Path(pwd.getpwnam("ubuntu").pw_dir)
    if home.is_symlink() or not home.is_dir():
        raise Blocked("operator home unsafe")
    base = home / "vwoci-acceptance"
    try:
        st = base.lstat()
    except OSError as exc:
        raise Blocked("original acceptance directory absent") from exc
    if (not stat.S_ISDIR(st.st_mode)
            or st.st_uid not in {0, pwd.getpwnam("ubuntu").pw_uid}
            or stat.S_IMODE(st.st_mode) != 0o700):
        raise Blocked("original acceptance evidence ownership unsafe")
    return base


def reject_historical_install_attempts(base: Path) -> None:
    """A new checkpoint must never bypass an attempted P8H install.

    Prior checkpoints are historical, even when created at a different SHA.
    Inspect only names inside the root-private acceptance evidence directory.
    An exclusive marker or symlink is a permanent stop for automatic retries.
    """
    try:
        folders = list(base.glob("p8h-prepare-*"))
    except OSError as exc:
        raise Blocked("historical install attempts cannot be inventoried") from exc
    if len(folders) > 128:
        raise Blocked("unreasonable previous preparation directory count")
    for folder in folders:
        if folder.is_symlink() or not private_directory(folder):
            raise Blocked("previous preparation directory is unsafe")
        marker = folder / "install-attempted.json"
        if marker.exists() or marker.is_symlink():
            raise Blocked("historical P8H installation attempt exists; no new prepare or retry")


def private_directory(path: Path) -> bool:
    try:
        st = path.lstat()
    except OSError:
        return False
    return stat.S_ISDIR(st.st_mode) and st.st_uid == 0 and stat.S_IMODE(st.st_mode) == 0o700


def private_bytes(path: Path, *, maximum: int = 32768) -> bytes:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        st = os.fstat(stream.fileno())
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or
                stat.S_IMODE(st.st_mode) != 0o600 or
                not 0 < st.st_size <= maximum):
            raise Blocked("protected evidence file has unexpected owner/mode/size")
        return stream.read(maximum + 1)


def read_p8g_proof(base: Path) -> DiskWitness:
    directory = base / P8G_NAME
    if not private_directory(directory):
        raise Blocked("accepted P8G private evidence directory not present")
    summary = private_bytes(directory / "summary.txt").decode("utf-8", "replace")
    details = private_bytes(directory / "disk-details.txt").decode("utf-8", "replace")
    required = (
        "Gate P8G - fresh OCI disk identity and external network proof (READ-ONLY)",
        "PASS       Original P8F HOLD evidence intact",
        "PASS       Still no appliance, Docker state or TCP 80/443 listeners",
        "PASS       one unmounted unsigned non-root disk; capacity_GiB=50 alias_fingerprint=" + ALIAS_FINGERPRINT,
        "PASS       P8F OCI A1 Flex instance and VNIC identities unchanged",
        "HOLD       P8G disk and network WITNESS only",
    )
    rows = summary.splitlines()
    if not all(any(row.startswith(item) for row in rows) for item in required):
        raise Blocked("accepted P8G HOLD markers mismatch")
    if any(row.startswith("BLOCKED") for row in rows):
        raise Blocked("accepted P8G included BLOCKED")
    expected = {
        "filesystem_signature_count": "0",
        "mountpoint_count": "0",
        "boot_ancestry": "excluded_by_product_storage",
        "OCI_volume_OCID": "NOT_AVAILABLE_FROM_GUEST",
        "OCI_attachment_verified": "NO_PENDING_OPERATOR_CONSOLE_REVIEW",
    }
    data: dict[str, str] = {}
    aliases: list[str] = []
    for line in details.splitlines():
        if line.startswith("stable_by_id="):
            aliases.append(line.split("=", 1)[1])
        elif "=" in line:
            k, v = line.split("=", 1)
            if k in data:
                raise Blocked("duplicated protected disk metadata")
            data[k] = v
    if (any(data.get(k) != v for k, v in expected.items()) or
            not details.endswith("NOT_AUTHORIZED_TO_FORMAT_OR_INSTALL\n") or
            len(aliases) != 2 or len(set(aliases)) != 2):
        raise Blocked("protected P8G disk evidence fields altered")
    try:
        size = int(data["capacity_bytes"])
    except (KeyError, ValueError) as exc:
        raise Blocked("protected P8G disk capacity missing") from exc
    if size != EXPECTED_GIB * 1024**3:
        raise Blocked("P8G disk size differs from observed size")
    raw = data.get("resolved_block_path", "")
    if not re.fullmatch(r"/dev/[A-Za-z0-9._/+:-]+", raw):
        raise Blocked("P8G resolved disk path invalid")
    for path in aliases:
        if (not path.startswith("/dev/disk/by-id/")
                or not Path(path).name.startswith(BYID_PREFIX)
                or not re.fullmatch(r"/dev/disk/by-id/[A-Za-z0-9._:+-]+", path)):
            raise Blocked("P8G by-id alias invalid")
    aliases_tuple = tuple(sorted(aliases))
    if tag(aliases_tuple[0]) != ALIAS_FINGERPRINT:
        raise Blocked("P8G original alias fingerprint differs")
    digest = hashlib.sha256(summary.encode() + b"\0" + details.encode()).hexdigest()
    return DiskWitness(raw, size, aliases_tuple, digest)


def current_boot() -> str:
    value = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    if not re.fullmatch(r"[a-f0-9-]{36}", value):
        raise Blocked("Linux boot marker missing")
    return value


def clean_host() -> None:
    if any(p.exists() or p.is_symlink() for p in PROTECTED):
        raise Blocked("preexisting or partial appliance detected")
    docker = Path("/var/lib/docker")
    if docker.exists() or docker.is_symlink():
        raise Blocked("preexisting Docker data detected")
    for unit in UNITS:
        rc, text = execute([
            "/usr/bin/systemctl", "show", unit, "--no-pager",
            "-p", "LoadState", "-p", "ActiveState", "-p", "UnitFileState"
        ])
        props = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
        if (rc != 0 or props.get("LoadState") != "not-found" or
                props.get("ActiveState") != "inactive" or
                props.get("UnitFileState") in ("enabled", "enabled-runtime", "linked", "linked-runtime")):
            raise Blocked("preexisting or uninspectable appliance systemd unit")
    rc, text = execute(["/usr/bin/ss", "-H", "-lnt"], timeout=12)
    if rc != 0:
        raise Blocked("cannot audit local TCP listeners")
    for line in text.splitlines():
        items = line.split()
        if len(items) < 5:
            raise Blocked("local socket listing malformed")
        match = re.search(r":([0-9]{1,5})$", items[3])
        if match is None:
            raise Blocked("local socket port could not be parsed")
        if int(match.group(1)) in (80, 443):
            raise Blocked("HTTP listener already active on unused test VM")


def current_disk(storage, proof: DiskWitness) -> DiskWitness:
    """Require P8G's *same* still-blank disk; never pick by disk size alone."""
    storage.root_source()
    rows = storage.inventory()
    if len(rows) > 64:
        raise Blocked("unreasonable block inventory")
    disks = [item for item in rows if item.get("type") == "disk"]
    if len(disks) != 1:
        raise Blocked("ambiguous non-root whole-disk inventory")
    row = disks[0]
    path = row.get("path")
    if not isinstance(path, str) or not path.startswith("/dev/"):
        raise Blocked("whole-disk path invalid")
    real = Path(path).resolve(strict=True)
    if not real.is_block_device():
        raise Blocked("candidate is not block device")
    storage.reject_boot_related(str(real))
    if (str(real) != proof.resolved or
            int(row.get("size") or 0) != proof.size_bytes or
            row.get("fstype") or row.get("uuid") or row.get("mountpoints")):
        raise Blocked("disk changed since P8G")
    rc, text = execute([
        "/usr/bin/lsblk", "-J", "-b", "-p", "-o",
        "PATH,TYPE,SIZE,FSTYPE,PTTYPE,UUID,MOUNTPOINTS", str(real),
    ])
    if rc != 0:
        raise Blocked("whole-disk topology unavailable")
    try:
        disks_tree = json.loads(text)["blockdevices"]
        disk = disks_tree[0]
    except (ValueError, KeyError, IndexError, TypeError) as exc:
        raise Blocked("whole-disk topology malformed") from exc
    if (len(disks_tree) != 1 or disk.get("type") != "disk" or
            disk.get("children") or disk.get("fstype") or disk.get("pttype")
            or disk.get("uuid") or any(disk.get("mountpoints") or []) or
            int(disk.get("size") or 0) != proof.size_bytes):
        raise Blocked("disk acquired partitions/filesystem/mount or changed size")
    rc, sig = execute([
        "/usr/sbin/wipefs", "--noheadings", "--output", "TYPE", str(real)
    ])
    if rc != 0 or sig.strip():
        raise Blocked("disk gained a signature or signature check unavailable")
    current_aliases = []
    for candidate in Path("/dev/disk/by-id").iterdir():
        if not candidate.name.startswith(BYID_PREFIX):
            continue
        try:
            if (candidate.is_symlink()
                    and candidate.resolve(strict=True) == real):
                current_aliases.append(str(candidate))
        except OSError:
            continue
    if tuple(sorted(set(current_aliases))) != proof.aliases:
        raise Blocked("stable device aliases changed since P8G")
    return proof


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def oci_metadata(which: str, *, opener=None):
    if which not in ("instance", "vnics"):
        raise ValueError("unsupported OCI metadata endpoint")
    url = IMDS_ORIGIN + "/" + which + "/"
    request = urllib.request.Request(
        url, headers={"Authorization": "Bearer Oracle"}, method="GET"
    )
    if opener is None:
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect(),
        )
    with opener.open(request, timeout=6) as response:
        if response.geturl() != url:
            raise Blocked("OCI metadata redirected")
        data = response.read(65537)
    if len(data) > 65536:
        raise Blocked("OCI metadata oversized")
    try:
        return json.loads(data)
    except (ValueError, UnicodeDecodeError) as exc:
        raise Blocked("OCI metadata invalid") from exc


def same_oci(instance: object, vnics: object) -> bool:
    if (not isinstance(instance, dict) or
            not isinstance(vnics, list) or len(vnics) != 1 or
            not isinstance(vnics[0], dict)):
        return False
    iid, vid = instance.get("id"), vnics[0].get("vnicId")
    if not all(isinstance(v, str) and v.isascii() for v in (iid, vid)):
        return False
    if (not iid.startswith("ocid1.instance.") or
            not vid.startswith("ocid1.vnic.") or
            tag(iid) != INSTANCE_FINGERPRINT or
            tag(vid) != VNIC_FINGERPRINT or
            instance.get("shape") != "VM.Standard.A1.Flex"):
        return False
    try:
        private = ipaddress.ip_address(vnics[0].get("privateIp"))
    except (TypeError, ValueError):
        return False
    return (private.version == 4 and
            any(private in subnet for subnet in PRIVATE_NETS))


def write_exclusive(path: Path, data: bytes) -> None:
    """Create once and fsync both file AND directory before any mutation."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                 getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    dirfd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) |
                    getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(dirfd)
    finally:
        os.close(dirfd)


def prepared_checkpoint(path: Path, base: Path, pin: str, proof: DiskWitness) -> dict[str, object]:
    if (not path.is_absolute() or path.name != "checkpoint.json"
            or not re.fullmatch(r"p8h-prepare-[0-9]{8}T[0-9]{6}Z-[0-9]+", path.parent.name)
            or path.parent.parent != base or not private_directory(path.parent)):
        raise Blocked("checkpoint location is not one accepted P8H preparation")
    data = json.loads(private_bytes(path))
    expected = {
        "schema": 1, "phase": "prepared-only", "commit": pin,
        "host": HOST, "boot_id": current_boot(),
        "p8g_evidence_sha256": proof.source_evidence_sha256,
        "instance_fingerprint": INSTANCE_FINGERPRINT,
        "vnic_fingerprint": VNIC_FINGERPRINT,
        "disk_alias_fingerprint": ALIAS_FINGERPRINT,
        "disk_size_bytes": proof.size_bytes,
    }
    if not isinstance(data, dict) or data != expected:
        raise Blocked("prepared evidence identity, boot, disk, or source changed")
    lines = private_bytes(path.parent / "summary.txt").decode("utf-8", "replace").splitlines()
    if (not any(row.startswith("Gate P8H - isolated first-install PREPARE only") for row in lines)
            or not any(row.startswith("HOLD       Prepared-only; no format/install/restore authorization") for row in lines)
            or any(row.startswith("BLOCKED") for row in lines)):
        raise Blocked("prepared read-only HOLD summary is missing or altered")
    if (path.parent / "install-attempted.json").exists() or (path.parent / "install-attempted.json").is_symlink():
        raise Blocked("P8H installation was already attempted; never automatically retry")
    return data


def validation_state(pin: str) -> tuple[Path, DiskWitness]:
    if not host_ok() or not exact_source(pin):
        raise Blocked("host/version/clean reviewed source differs")
    base = accepted_base()
    reject_historical_install_attempts(base)
    proof = read_p8g_proof(base)
    clean_host()
    sys.path.insert(0, str(SOURCE))
    from vaultwarden_oci import storage
    current_disk(storage, proof)
    try:
        instance, vnics = oci_metadata("instance"), oci_metadata("vnics")
    except (OSError, TimeoutError) as exc:
        raise Blocked("OCI link-local instance identity unavailable") from exc
    if not same_oci(instance, vnics):
        raise Blocked("OCI instance/VNIC identity changed since P8F/P8G")
    return base, proof


def prepare(pin: str) -> int:
    try:
        base, proof = validation_state(pin)
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        folder = base / f"p8h-prepare-{stamp}-{os.getpid()}"
        folder.mkdir(mode=0o700)
        checkpoint = {
            "schema": 1, "phase": "prepared-only", "commit": pin,
            "host": HOST, "boot_id": current_boot(),
            "p8g_evidence_sha256": proof.source_evidence_sha256,
            "instance_fingerprint": INSTANCE_FINGERPRINT,
            "vnic_fingerprint": VNIC_FINGERPRINT,
            "disk_alias_fingerprint": ALIAS_FINGERPRINT,
            "disk_size_bytes": proof.size_bytes,
        }
        write_exclusive(folder / "checkpoint.json", (json.dumps(checkpoint, sort_keys=True) + "\n").encode())
        report = (
            "Gate P8H - isolated first-install PREPARE only (READ-ONLY)\n"
            "PASS       Exact reviewed release candidate, native Ubuntu 26.04 ARM64 and original new host\n"
            "PASS       P8G original private HOLD, 50 GiB disk witness, two aliases and evidence digest unchanged\n"
            "PASS       Same A1 Flex instance and VNIC fingerprints as P8F/P8G\n"
            "PASS       One whole non-boot block disk remains completely blank, without partitions, mounts or signatures\n"
            "PASS       No appliance, Docker state, enabled units or local TCP 80/443 listeners\n"
            "PENDING    External OCI ingress, attachment and test DNS were operator-attested, NOT queried from OCI/Cloudflare control plane\n"
            "PENDING    Install-only hostname/email are LOCKED; original off-host Age PUBLIC recipient, selected alias and typed format consent required\n"
            "PENDING    Existing hostname also appears in original stopped VM; no DNS/ACME/Caddy/public start consent\n"
            "NOT RUN    No disk format, package install, mount, SOPS, DNS/ACME, Worker, SMTP, Box, app or timer startup\n"
            "HOLD       Prepared-only; no format/install/restore authorization created by this invocation\n"
        )
        write_exclusive(folder / "summary.txt", report.encode())
        print(report, end="")
        print("Private P8H checkpoint:", folder / "checkpoint.json")
        print("Paste summary and P8H_EXIT only. Do not paste private checkpoint, by-id aliases or credentials.")
        return 0
    except Exception:
        print("BLOCKED: read-only P8H preparation integrity/identity precondition failed; no installer invoked")
        return 2


def read_consent(proof: DiskWitness) -> tuple[str, str, str, str] | None:
    """Install-only, TTY, operator-bound domain and email, typed disk consent.

    The operator explicitly approved this existing TEST hostname for setup.
    It is NOT an independently unique hostname: do not infer DNS/TLS/public
    service activation permission or silently change the original VM.
    """
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        return None
    print("P8H INSTALL ONLY. This will FORMAT the selected NEW disposable 50 GiB volume.")
    print("Hostname locked to " + TEST_HOSTNAME + " (also used in the original STOPPED host configuration).")
    print("ACME contact email locked to " + TEST_ACME_EMAIL + ".")
    print("NO Caddy/Vaultwarden startup, DNS publication, ACME challenge, Cloudflare Worker or Box action is authorized.")
    print("Inspect the root-private P8G disk-details.txt and NEW VM OCI attachment now.")
    print("Choose one of the two *already witnessed* aliases by number (no device path output).")
    for index, alias in enumerate(proof.aliases, 1):
        print(f"  choice {index}: alias fingerprint={tag(alias)}")
    try:
        selected = input("Approved alias choice [1/2] (anything else cancels): ").strip()
        if selected not in ("1", "2"):
            return None
        recipient = getpass.getpass("Existing OFF-HOST Age PUBLIC recipient age1... (hidden input): ").strip()
        if (not DOMAIN_RE.fullmatch(TEST_HOSTNAME) or
                not MAIL_RE.fullmatch(TEST_ACME_EMAIL) or
                not RECIPIENT_RE.fullmatch(recipient)):
            return None
        phrase = (
            f"P8H FORMAT {HOST} {EXPECTED_GIB}GiB {ALIAS_FINGERPRINT} "
            f"FOR {TEST_HOSTNAME} INSTALL ONLY"
        )
        print("Required exact typed format consent (NOT public service authorization):")
        print(phrase)
        typed = input("Type the phrase exactly to permit ONE format/install: ").strip()
        if typed != phrase:
            return None
        return proof.aliases[int(selected) - 1], TEST_HOSTNAME, TEST_ACME_EMAIL, recipient
    except (EOFError, KeyboardInterrupt):
        return None


def installer_call(alias: str, domain: str, email: str, recipient: str,
                   folder: Path, *, dry_run: bool) -> bool:
    """Supported product installer only; preserve full logs as private evidence."""
    if (domain != TEST_HOSTNAME or email != TEST_ACME_EMAIL
            or not RECIPIENT_RE.fullmatch(recipient)):
        return False
    command = [
        "/usr/bin/bash", str(SOURCE / "setup.sh"), "install",
        "--domain", domain, "--url", "https://" + domain,
        "--email", email, "--data-device", alias,
        "--offline-recipient", recipient, "--auto",
    ]
    if dry_run:
        command.append("--dry-run")
    else:
        command.append("--confirm-format")
    env = dict(os.environ)
    env.pop("PYTHONPATH", None)
    env["NO_COLOR"] = "1"
    env["TMPDIR"] = "/run"
    logfile = folder / ("setup-dryrun.private.log" if dry_run else "setup-install.private.log")
    fd = os.open(logfile, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                 getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "wb") as log:
        try:
            run = subprocess.run(
                command, env=env, cwd=SOURCE, stdin=subprocess.DEVNULL,
                stdout=log, stderr=subprocess.STDOUT,
                timeout=1800, check=False,
            )
            log.flush()
            os.fsync(log.fileno())
            if run.returncode != 0:
                return False
            if dry_run:
                # Require explicit owner confirmation that it did not mutate.
                message = logfile.read_text(encoding="utf-8", errors="replace")
                return "dry run: no filesystem, package, config, secret, or systemd changes were made" in message
            return True
        except (OSError, subprocess.TimeoutExpired):
            return False


def verified_installed(proof: DiskWitness, domain: str, recipient: str) -> bool:
    """No remote APIs or application start. Return false without revealing data."""
    if domain != TEST_HOSTNAME or not RECIPIENT_RE.fullmatch(recipient):
        return False
    sys.path.insert(0, str(SOURCE))
    from vaultwarden_oci import storage, secrets
    current = Path("/opt/vaultwarden-oci/current")
    expected = Path("/opt/vaultwarden-oci/releases") / VERSION
    if not current.is_symlink() or current.resolve(strict=True) != expected:
        return False
    for path in ("vwctl", "versions.toml", "vaultwarden_oci/setup.py",
                 "vaultwarden_oci/runtime.py", "vaultwarden_oci/storage.py"):
        if (SOURCE / path).read_bytes() != (expected / path).read_bytes():
            return False
    actual = storage.verify()
    if (Path(actual.source).resolve(strict=True) != Path(proof.resolved)
            or actual.fs_type != "ext4"):
        return False
    with Path("/etc/vaultwarden-oci/config.toml").open("rb") as f:
        cfg = tomllib.load(f)
    if (cfg["site"]["domain"] != TEST_HOSTNAME or
            cfg["site"]["acme_email"] != TEST_ACME_EMAIL or
            cfg["secrets"]["offline_recovery_recipient"] != recipient):
        return False
    backup = cfg["backup"]
    if (backup["remote"] != "" or
            backup["local_retention_days"] != 0 or backup["remote_retention_days"] != 0):
        return False
    secrets.validate_custody(recipient)
    env = dict(os.environ, SOPS_AGE_KEY_FILE="/etc/vaultwarden-oci/age-key.txt")
    p = subprocess.run(
        ["/usr/local/bin/sops", "--decrypt", "--output", "/dev/null",
         "/etc/vaultwarden-oci/secrets.sops.yaml"],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, timeout=35, env=env, check=False,
    )
    if p.returncode != 0:
        return False
    for unit in UNITS:
        rc, output = execute([
            "/usr/bin/systemctl", "show", unit, "--no-pager",
            "-p", "ActiveState", "-p", "UnitFileState",
        ])
        fields = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
        if (rc != 0 or fields.get("ActiveState") != "inactive"
                or fields.get("UnitFileState") in ("enabled", "enabled-runtime")):
            return False
    rc, sockets = execute(["/usr/bin/ss", "-H", "-lnt"], timeout=12)
    if rc != 0:
        return False
    for line in sockets.splitlines():
        items = line.split()
        match = re.search(r":([0-9]{1,5})$", items[3]) if len(items) >= 5 else None
        if match is None or int(match.group(1)) in (80, 443):
            return False
    return True


def install(pin: str, checkpoint: Path) -> int:
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        print("BLOCKED: destructive stage requires live interactive terminal")
        return 2
    try:
        base, proof = validation_state(pin)
        prepared_checkpoint(checkpoint, base, pin, proof)
        values = read_consent(proof)
        if values is None:
            print("CANCELLED: no format/install invoked; no destructive attempt marker created")
            return 2
        alias, domain, email, recipient = values
        # Last source, disk, P8G, OCI, OS and clean-host revalidation.
        again_base, again = validation_state(pin)
        if again_base != base or again != proof:
            raise Blocked("identity or storage changed during consent")
        prepared_checkpoint(checkpoint, base, pin, proof)
        if not installer_call(alias, domain, email, recipient, checkpoint.parent, dry_run=True):
            raise Blocked("supported installer dry-run rejected selected inputs; no format attempted")
        # The dry-run MUST be the final pre-destructive product action.
        _, last = validation_state(pin)
        if last != proof:
            raise Blocked("disk/OCI identity changed after product dry-run")
        prepared_checkpoint(checkpoint, base, pin, proof)
        write_exclusive(
            checkpoint.parent / "install-attempted.json",
            (json.dumps({
                "schema": 1, "mode": "one-shot-format-and-install",
                "host": HOST, "commit": pin,
                "boot_id": current_boot(), "disk_fingerprint": ALIAS_FINGERPRINT,
                "target_hostname_sha256": hashlib.sha256(domain.encode()).hexdigest(),
                "source_checkpoint": checkpoint.name,
            }, sort_keys=True) + "\n").encode(),
        )
        print("P8H: exact disk/setup/consent checked; one installer invocation now authorized.")
        ok = installer_call(alias, domain, email, recipient, checkpoint.parent, dry_run=False)
        if not ok:
            print("BLOCKED: setup was attempted and did not complete successfully.")
            print("Do NOT rerun install. Preserve private installer log and attempt marker for read-only triage.")
            return 2
        if not verified_installed(proof, domain, recipient):
            print("BLOCKED: setup returned success but post-install security/state verification failed.")
            print("Do NOT start services or rerun formatting. Preserve private installer evidence.")
            return 2
        result = (
            "Gate P8H - consented isolated FIRST INSTALL\n"
            "PASS       Exact single format/install attempt completed on selected approved disposable volume\n"
            "PASS       Dedicated ext4 identity/marker, immutable rc.12 source and encrypted SOPS/Age custody verified\n"
            "PASS       LOCKED install-only hostname bw.lazymocha.com and bw@lazymocha.com, original offline public Age recipient retained\n"
            "PASS       Backup remote disabled and retention zero; no application/timer or TCP 80/443 listener activated\n"
            "NOT RUN    No original .vwrec restore, test DNS/Cloudflare Worker, ACME, SMTP, Box or live service start\n"
            "HOLD       Installed but stopped; SHARED test hostname does NOT authorize DNS, ACME, Caddy or public activation\n"
        )
        write_exclusive(checkpoint.parent / "install.summary.txt", result.encode())
        print(result, end="")
        print("Private install log:", checkpoint.parent / "setup-install.private.log")
        print("Paste only sanitized summary and P8H_EXIT; never paste private installation logs.")
        return 0
    except Exception:
        print("BLOCKED: P8H pre-install safety/identity or input validation failed.")
        print("If an install-attempted marker exists, do NOT automatically retry or repair.")
        return 2


def main() -> int:
    parser = argparse.ArgumentParser(prog="P8H", description="Isolated rc.12 installer consent gate")
    parser.add_argument("--expected-commit", required=True)
    sub = parser.add_subparsers(dest="phase", required=True)
    sub.add_parser("prepare", help="read-only; writes a root-private checkpoint")
    action = sub.add_parser("install", help="format/install only after interactive typed approval")
    action.add_argument("--checkpoint", required=True, type=Path)
    args = parser.parse_args()
    if (not SHA_RE.fullmatch(args.expected_commit) or os.geteuid() != 0 or
            os.environ.get("SUDO_USER") != "ubuntu" or
            platform.node().split(".")[0] != HOST):
        print("BLOCKED: exact SHA and sudo -n from ubuntu on NEW host required; original VM prohibited")
        return 2
    if args.phase == "prepare":
        return prepare(args.expected_commit)
    return install(args.expected_commit, args.checkpoint)


if __name__ == "__main__":
    raise SystemExit(main())
