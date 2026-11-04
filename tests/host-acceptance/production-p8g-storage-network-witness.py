#!/usr/bin/env python3
"""P8G: READ-ONLY disk identity and external isolation evidence on new OCI VM.

P8F accepted one blank disk, but it did NOT approve its OCI attachment or
formatting. Only inspect and record host-local facts; provider-side NSG, subnet
security lists, IPv4/IPv6 routing and the block-volume OCID require independent
OCI Console comparison. Never turn a guest inventory into authorization.

Explicitly banned: appliance install/format/mount/restore, Cloudflare/OCI
control-plane operations, service start, certificates, SMTP, Box or reboot.
Only a NEW root-private sanitized summary and locally reviewable device details
are written. NEVER run on the original restored vaultwarden-oci-6-vnic.
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
BRANCH = "audit/rc12-p8g-storage-and-network-witness"
ROOT = Path(__file__).resolve().parents[2]
P8F_DIR = "p8f-new-origin-20261104T204839Z-2178"
P8F_SOURCE = "6e7e84904f9044d55b26fe2118b5f2d32e3295cc"
INSTANCE_FP = "0dccfd58cbbd"
VNIC_FP = "36862e16cc9f"
RELEASE = "0.1.0-rc.12"
IMDS_ORIGIN = "http://169.254.169.254/opc/v2"
MAX_METADATA = 65536
SHA_RE = re.compile(r"[a-f0-9]{40}")
APP_PATHS = tuple(Path(p) for p in (
    "/opt/vaultwarden-oci", "/etc/vaultwarden-oci",
    "/var/lib/vaultwarden-oci", "/run/vaultwarden-oci",
))
APP_UNITS = (
    "vaultwarden-oci.target", "vaultwarden-oci.service",
    "vaultwarden-oci-dns.service", "vaultwarden-oci-health.timer",
    "vaultwarden-oci-backup.timer", "vaultwarden-oci-maintenance.timer",
    "vaultwarden-oci-update-check.timer",
)
STABLE_PREFIXES = ("scsi-", "wwn-", "nvme-", "virtio-")


class Refusal(RuntimeError):
    """No untrusted error text should ever be emitted in the summary."""


class MetadataRefusal(Refusal):
    """Allowlisted metadata error; never disclose received fields or OCIDs."""

    CODES = frozenset({
        "response_redirect", "response_oversize", "response_invalid_json",
        "instance_invalid", "shape_mismatch", "instance_identity_changed",
        "vnics_invalid", "vnic_identity_changed", "vnic_private_ip_invalid",
    })

    def __init__(self, code: str):
        if code not in self.CODES:
            raise ValueError("invalid metadata error category")
        self.code = code
        super().__init__(code)


def sha_tag(value: str) -> str:
    return hashlib.sha256(value.encode("ascii")).hexdigest()[:12]


def command(argv: list[str], seconds: int = 20) -> tuple[int | None, str]:
    """Only fixed, reviewed read-only callers; drop stderr and bound output."""
    try:
        run = subprocess.run(
            argv, cwd="/", stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=seconds, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    if len(run.stdout) > 131072:
        return None, ""
    return run.returncode, run.stdout.decode("utf-8", "replace")


def clean_pin(expected: str) -> bool:
    if not SHA_RE.fullmatch(expected):
        return False
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat")
    answers = []
    for args in (("rev-parse", "HEAD"), ("branch", "--show-current"), ("status", "--porcelain")):
        try:
            p = subprocess.run(
                ["/usr/bin/git", *args], cwd=ROOT, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL, timeout=20, check=False,
            )
            if p.returncode or len(p.stdout) > 8192:
                return False
            answers.append(p.stdout.decode("utf-8", "replace").strip())
        except (OSError, subprocess.TimeoutExpired):
            return False
    return answers == [expected, BRANCH, ""]


def target_os() -> bool:
    try:
        fields = dict(
            line.split("=", 1) for line in Path("/etc/os-release").read_text(
                encoding="utf-8"
            ).splitlines() if "=" in line
        )
        with (ROOT / "versions.toml").open("rb") as stream:
            version = tomllib.load(stream)["vaultwarden_oci"]["version"]
    except (OSError, ValueError, KeyError, TypeError, tomllib.TOMLDecodeError):
        return False
    return (
        platform.node().split(".")[0] == HOST
        and platform.machine() in {"aarch64", "arm64"}
        and fields.get("ID", "").strip('"') == "ubuntu"
        and fields.get("VERSION_ID", "").strip('"') == "26.04"
        and fields.get("VERSION_CODENAME", "").strip('"') == "resolute"
        and sys.version_info[:2] == (3, 14)
        and version == RELEASE
    )


def safe_directory(path: Path, *, owner: int = 0) -> bool:
    try:
        meta = path.lstat()
    except OSError:
        return False
    return (
        stat.S_ISDIR(meta.st_mode)
        and meta.st_uid == owner
        and stat.S_IMODE(meta.st_mode) == 0o700
    )


def read_private_file(path: Path, *, maximum: int = 16384) -> str:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        meta = os.fstat(stream.fileno())
        if (not stat.S_ISREG(meta.st_mode) or meta.st_uid != 0
                or stat.S_IMODE(meta.st_mode) != 0o600
                or not 64 < meta.st_size <= maximum):
            raise Refusal("private P8F record permissions or length changed")
        raw = stream.read(maximum + 1)
        if len(raw) > maximum:
            raise Refusal("private P8F record size changed")
        return raw.decode("utf-8", "replace")


def p8f_evidence(base: Path) -> bool:
    """Validate only the exact accepted P8F summary; never alter past evidence."""
    folder = base / P8F_DIR
    if not safe_directory(folder):
        return False
    try:
        rows = read_private_file(folder / "summary.txt").splitlines()
    except (OSError, ValueError, Refusal):
        return False
    markers = (
        "Gate P8F - new isolated OCI ARM64 host preflight (READ-ONLY)",
        "PASS       New operator-specified guest identity, exact clean candidate",
        "PASS       No appliance install/data/units or preexisting Docker state",
        "PASS       No local TCP 80/443 listener",
        "PASS       Non-boot disks=1 blank-stable candidates=1",
        "PASS       OCI A1 Flex instance fingerprint=" + INSTANCE_FP,
        "PASS       VNIC fingerprints=" + VNIC_FP,
        "PASS       NTP synchronized",
        "HOLD       P8F fresh-origin inventory only",
    )
    return (
        all(any(row.startswith(needle) for row in rows) for needle in markers)
        and not any(row.startswith("BLOCKED") for row in rows)
    )


def fresh_appliance_state() -> bool:
    if any(path.exists() or path.is_symlink() for path in APP_PATHS):
        return False
    docker = Path("/var/lib/docker")
    if docker.exists() or docker.is_symlink():
        return False
    for unit in APP_UNITS:
        code, raw = command([
            "systemctl", "show", unit, "--no-pager",
            "-p", "LoadState", "-p", "ActiveState", "-p", "UnitFileState",
        ])
        if code != 0:
            return False
        fields = dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)
        if fields.get("LoadState") != "not-found" or fields.get("ActiveState") != "inactive":
            return False
        if fields.get("UnitFileState") in ("enabled", "enabled-runtime", "linked", "linked-runtime"):
            return False
    code, lines = command(["ss", "-H", "-lnt"], seconds=12)
    if code != 0:
        return False
    for line in lines.splitlines():
        cols = line.split()
        if len(cols) < 5:
            return False
        port = re.search(r":([0-9]{1,5})$", cols[3])
        if port is None:
            return False
        if int(port.group(1)) in (80, 443):
            return False
    return True


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def metadata(which: str, *, opener=None) -> object:
    if which not in {"instance", "vnics"}:
        raise ValueError("unsupported metadata resource")
    url = IMDS_ORIGIN + "/" + which + "/"
    req = urllib.request.Request(
        url, headers={"Authorization": "Bearer Oracle"}, method="GET"
    )
    if opener is None:
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect(),
        )
    with opener.open(req, timeout=6) as response:
        if response.geturl() != url:
            raise MetadataRefusal("response_redirect")
        raw = response.read(MAX_METADATA + 1)
    if len(raw) > MAX_METADATA:
        raise MetadataRefusal("response_oversize")
    try:
        return json.loads(raw)
    except (ValueError, UnicodeDecodeError) as exc:
        raise MetadataRefusal("response_invalid_json") from exc


def fingerprint_oci(instance: object, vnics: object) -> bool:
    """Binding to original accepted P8F IMDS identities, not to public IPs."""
    if not isinstance(instance, dict):
        raise MetadataRefusal("instance_invalid")
    instance_id = instance.get("id")
    if (not isinstance(instance_id, str) or not instance_id.isascii()
            or not instance_id.startswith("ocid1.instance.")):
        raise MetadataRefusal("instance_invalid")
    if instance.get("shape") != "VM.Standard.A1.Flex":
        raise MetadataRefusal("shape_mismatch")
    if sha_tag(instance_id) != INSTANCE_FP:
        raise MetadataRefusal("instance_identity_changed")
    if not isinstance(vnics, list) or len(vnics) != 1 or not isinstance(vnics[0], dict):
        raise MetadataRefusal("vnics_invalid")
    vnic_id = vnics[0].get("vnicId")
    if (not isinstance(vnic_id, str) or not vnic_id.isascii()
            or not vnic_id.startswith("ocid1.vnic.")
            or sha_tag(vnic_id) != VNIC_FP):
        raise MetadataRefusal("vnic_identity_changed")
    try:
        ip = ipaddress.ip_address(vnics[0].get("privateIp"))
    except (ValueError, TypeError) as exc:
        raise MetadataRefusal("vnic_private_ip_invalid") from exc
    if ip.version != 4 or not ip.is_private:
        raise MetadataRefusal("vnic_private_ip_invalid")
    display = instance.get("displayName")
    hostname = instance.get("hostname")
    return (
        display == HOST or
        isinstance(hostname, str) and hostname.split(".", 1)[0] == HOST
    )


def stable_disk_aliases(real: Path) -> tuple[str, ...]:
    """Only symbolic aliases targeting the exact reviewed block disk."""
    directory = Path("/dev/disk/by-id")
    results: list[str] = []
    for link in directory.iterdir():
        if not link.name.startswith(STABLE_PREFIXES):
            continue
        try:
            if stat.S_ISLNK(link.lstat().st_mode) and link.resolve(strict=True) == real:
                results.append(str(link))
        except OSError:
            continue
    return tuple(sorted(set(results)))


def blank_disk_witness(storage) -> tuple[str, str]:
    """Read-only physical-disk check; never select it for a destructive action.

    The PRIVATE detail is for operator-to-OCI-console comparison only. Disk
    aliases, raw device paths and UUIDs never appear in the public summary.
    """
    storage.root_source()
    candidates = storage.inventory()
    if len(candidates) > 64:
        raise Refusal("unexpected block inventory count")
    disks = [row for row in candidates if row.get("type") == "disk"]
    if len(disks) != 1:
        raise Refusal("not exactly one non-boot disk")
    row = disks[0]
    raw_path = row.get("path")
    if not isinstance(raw_path, str) or not raw_path.startswith("/dev/"):
        raise Refusal("disk path not supported")
    real = Path(raw_path).resolve(strict=True)
    if not real.is_block_device():
        raise Refusal("candidate is not a block device")
    storage.reject_boot_related(str(real))
    if row.get("mountpoints") or row.get("fstype") or row.get("uuid"):
        raise Refusal("candidate disk has prior filesystem or active mount state")
    size = int(row.get("size") or 0)
    if not 20 * 1024 ** 3 <= size <= 64 * 1024 ** 4:
        raise Refusal("candidate capacity outside supported review bounds")
    code, types = command(["lsblk", "-n", "-o", "TYPE", str(real)], seconds=15)
    if code != 0 or types.split() != ["disk"]:
        raise Refusal("candidate has child partitions or unsupported topology")
    code, signatures = command(
        ["wipefs", "--noheadings", "--output", "TYPE", str(real)], seconds=20
    )
    if code != 0 or signatures.strip():
        raise Refusal("candidate has signatures or signature probe failed")
    aliases = stable_disk_aliases(real)
    if not aliases:
        raise Refusal("candidate lacks a stable by-id mapping")
    label = (
        f"one unmounted unsigned non-root disk; capacity_GiB={size // (1024 ** 3)} "
        f"alias_fingerprint={sha_tag(aliases[0])} alias_count={len(aliases)}"
    )
    private = (
        "Private OCI attachment comparison ONLY (do not paste)\n"
        f"resolved_block_path={real}\n"
        f"capacity_bytes={size}\n"
        + "".join(f"stable_by_id={alias}\n" for alias in aliases)
        + "filesystem_signature_count=0\n"
        + "mountpoint_count=0\n"
        + "boot_ancestry=excluded_by_product_storage\n"
        + "OCI_volume_OCID=NOT_AVAILABLE_FROM_GUEST\n"
        + "OCI_attachment_verified=NO_PENDING_OPERATOR_CONSOLE_REVIEW\n"
        + "NOT_AUTHORIZED_TO_FORMAT_OR_INSTALL\n"
    )
    return label, private


def private_base() -> Path:
    user = pwd.getpwnam("ubuntu")
    home = Path(user.pw_dir)
    if home.is_symlink() or not home.is_dir():
        raise Refusal("operator home missing or unsafe")
    base = home / "vwoci-acceptance"
    meta = base.lstat()
    if (not stat.S_ISDIR(meta.st_mode)
            or meta.st_uid not in {0, user.pw_uid}
            or stat.S_IMODE(meta.st_mode) != 0o700):
        raise Refusal("existing acceptance evidence parent not privately protected")
    return base


def write_new_private(path: Path, data: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                 getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


class Report:
    def __init__(self, directory: Path):
        self.directory = directory
        self.rows: list[tuple[str, str]] = []
        self.blocked = False

    def add(self, status: str, message: str) -> None:
        if (status not in {"PASS", "PENDING", "NOT RUN", "BLOCKED"}
                or any(c in message for c in "\r\n\x00") or len(message) > 1024):
            raise ValueError("unsafe evidence text")
        self.rows.append((status, message))
        self.blocked |= status == "BLOCKED"

    def finish(self) -> int:
        result = "BLOCKED" if self.blocked else "HOLD"
        self.rows.append((result, "P8G disk and network WITNESS only; no install, restore, public service or production GO"))
        text = "Gate P8G - fresh OCI disk identity and external network proof (READ-ONLY)\n"
        text += "\n".join(f"{status:<10} {message}" for status, message in self.rows) + "\n"
        write_new_private(self.directory / "summary.txt", text)
        print(text, end="")
        print("Private summary:", self.directory / "summary.txt")
        print("Do not paste private disk-details or OCI records; paste summary and exit status only.")
        return 2 if self.blocked else 0


def main() -> int:
    if (len(sys.argv) != 3 or sys.argv[1] != "--expected-commit"
            or not SHA_RE.fullmatch(sys.argv[2])
            or os.geteuid() != 0 or os.environ.get("SUDO_USER") != "ubuntu"):
        print("BLOCKED: run as ubuntu via sudo -n with --expected-commit <reviewed SHA>", file=sys.stderr)
        return 2
    if not target_os() or not clean_pin(sys.argv[2]):
        print("BLOCKED: wrong host, native OS or exact clean pinned source; original host prohibited", file=sys.stderr)
        return 2
    try:
        base = private_base()
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        output = base / f"p8g-disk-network-witness-{stamp}-{os.getpid()}"
        output.mkdir(mode=0o700)
    except Exception:
        print("BLOCKED: root-private acceptance evidence cannot be initialized", file=sys.stderr)
        return 2
    report = Report(output)
    stage = "accepted P8F evidence"
    try:
        if not p8f_evidence(base):
            raise Refusal("original P8F HOLD proof changed or missing")
        report.add("PASS", "Original P8F HOLD evidence intact; A1 Flex and one blank disk witnessed on target")
        stage = "new-host clean and inert state"
        if not fresh_appliance_state():
            raise Refusal("appliance or HTTP service is present or unit state unavailable")
        report.add("PASS", "Still no appliance, Docker state or TCP 80/443 listeners")
        stage = "disk physical identity and signatures"
        sys.path.insert(0, str(ROOT))
        from vaultwarden_oci import storage
        label, details = blank_disk_witness(storage)
        write_new_private(output / "disk-details.txt", details)
        report.add("PASS", label)
        report.add("PENDING", "Operator must inspect PRIVATE disk-details locally and match exact device attachment in OCI Console; never paste raw IDs")
        stage = "original instance and VNIC continuity"
        try:
            instance = metadata("instance")
            vnics = metadata("vnics")
        except urllib.error.HTTPError as exc:
            status = exc.code if type(exc.code) is int and 100 <= exc.code <= 599 else 0
            raise Refusal("OCI metadata unavailable status=" + str(status or "unknown")) from None
        except (OSError, urllib.error.URLError, TimeoutError) as exc:
            raise Refusal("OCI link-local metadata not available for continuity") from None
        name_ok = fingerprint_oci(instance, vnics)
        report.add("PASS", "P8F OCI A1 Flex instance and VNIC identities unchanged (fingerprint binding)")
        report.add("PASS" if name_ok else "PENDING",
                   "OCI metadata guest name consistent" if name_ok else
                   "OCI metadata name differs; authoritative OCI Console identity review required")
        report.add("PENDING", "External OCI proof: NEW VNIC public IPv4/IPv6, routes, every NSG AND subnet security list, TCP 80 Internet closed")
        report.add("PENDING", "External OCI proof: effective TCP 443 restricted to CURRENT Cloudflare CIDRs; no permissive additive rule")
        report.add("PENDING", "Cloudflare TEST-ONLY hostname, proxied DNS/ACME authority and Worker exact/wildcard routes not independently verified")
        report.add("PENDING", "Original off-host recovery kit/private Age/passphrase and separate Box test prefix are operator attestations, not exercised")
        report.add("NOT RUN", "No device mount, filesystem formatting, install, restore, Cloudflare DNS-01/Worker/SMTP, Box, startup or timers")
        report.add("NOT RUN", "No OCI/Cloudflare control-plane operation, NSG/security-list modification, firewall repair or reboot")
        return report.finish()
    except KeyboardInterrupt:
        report.add("BLOCKED", "Interrupted during " + stage + "; no repair or retry authorized")
    except MetadataRefusal as exc:
        report.add("BLOCKED", "OCI identity metadata contract changed at " + stage + " category=" + exc.code)
    except Exception:
        report.add("BLOCKED", "Read-only disk/network witness failed during " + stage + "; details withheld")
    return report.finish()


if __name__ == "__main__":
    raise SystemExit(main())
