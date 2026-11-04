#!/usr/bin/env python3
"""P8F: isolated disposable *NEW* Ubuntu 26.04 ARM64 origin preflight.

No host provisioning, filesystem modification, install, secrets, recovery,
Cloudflare/OCI control-plane requests, DNS/Worker action, Docker startup,
network change or existing appliance access. Read-only OCI IMDSv2 GET only.
Only a new root-private, sanitized operator summary is written.

Gate P8F is NOT a live start or an authorization to provision/format storage.
The original restored vaultwarden-oci-6-vnic must NEVER run this script.
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

SRC = Path(__file__).resolve().parents[2]
BRANCH = "audit/rc12-p8f-isolated-origin-preflight"
RELEASE = "0.1.0-rc.12"
ORIGINAL = "vaultwarden-oci-6-vnic"
HOST_PATTERN = re.compile(r"vaultwarden-oci-([0-9]{1,3})-vnic")
SHA_PATTERN = re.compile(r"[a-f0-9]{40}")
IMDS = "http://169.254.169.254/opc/v2"
IMDS_MAX = 65536
PRIVATE_NETS = tuple(ipaddress.ip_network(s) for s in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
))
APPLIANCE_PATHS = tuple(Path(p) for p in (
    "/opt/vaultwarden-oci", "/etc/vaultwarden-oci",
    "/var/lib/vaultwarden-oci", "/run/vaultwarden-oci",
))
UNITS = (
    "vaultwarden-oci.target", "vaultwarden-oci.service",
    "vaultwarden-oci-dns.service", "vaultwarden-oci-health.timer",
    "vaultwarden-oci-backup.timer", "vaultwarden-oci-maintenance.timer",
    "vaultwarden-oci-update-check.timer",
)


class Blocked(RuntimeError):
    """Expected safe refusal; do not print untrusted exception messages."""


class MetadataBlocked(Blocked):
    """Allowlisted metadata-contract failure; no OCI response content included."""
    CODES = frozenset({
        "redirect", "oversize", "invalid_json", "instance_schema",
        "shape", "instance_id", "vnic_schema", "vnic_id",
        "vnic_private_ip", "duplicate_vnic_id",
    })

    def __init__(self, code: str):
        if code not in self.CODES:
            raise ValueError("unsafe metadata error code")
        self.code = code
        super().__init__("OCI metadata contract " + code)


def eligible_host(actual: str, expected: str) -> bool:
    match = HOST_PATTERN.fullmatch(expected)
    return (
        bool(match) and int(match.group(1)) >= 7
        and actual == expected and actual != ORIGINAL
    )


def source_checkout_ok(pin: str) -> bool:
    if not SHA_PATTERN.fullmatch(pin):
        return False
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat")
    answers: list[str] = []
    for args in (("rev-parse", "HEAD"), ("branch", "--show-current"), ("status", "--porcelain")):
        try:
            result = subprocess.run(
                ["/usr/bin/git", *args],
                cwd=SRC, env=env, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=20, check=False,
            )
            if result.returncode != 0 or len(result.stdout) > 8192:
                return False
            answers.append(result.stdout.decode("utf-8", "replace").strip())
        except (OSError, subprocess.TimeoutExpired):
            return False
    return answers == [pin, BRANCH, ""]


def os_supported() -> bool:
    try:
        raw = Path("/etc/os-release").read_text(encoding="utf-8")
        fields = dict(
            line.split("=", 1) for line in raw.splitlines() if "=" in line
        )
        with (SRC / "versions.toml").open("rb") as stream:
            version = tomllib.load(stream)["vaultwarden_oci"]["version"]
    except (OSError, ValueError, TypeError, KeyError, tomllib.TOMLDecodeError):
        return False
    return (
        fields.get("ID", "").strip('"') == "ubuntu"
        and fields.get("VERSION_ID", "").strip('"') == "26.04"
        and fields.get("VERSION_CODENAME", "").strip('"') == "resolute"
        and platform.machine() in {"aarch64", "arm64"}
        and sys.version_info[:2] == (3, 14)
        and version == RELEASE
    )


def command(argv: list[str], *, seconds: int = 20) -> tuple[int | None, str]:
    """No shell, no stderr, bounded output; only known read-only callers."""
    try:
        run = subprocess.run(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=seconds, check=False, cwd="/",
        )
        if len(run.stdout) > 128 * 1024:
            return None, ""
        return run.returncode, run.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return None, ""


def units_are_absent() -> bool:
    for unit in UNITS:
        code, out = command(["systemctl", "show", unit, "--no-pager",
                             "-p", "LoadState", "-p", "ActiveState",
                             "-p", "UnitFileState"])
        if code != 0:
            return False
        props = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
        if props.get("LoadState") != "not-found":
            return False
        if props.get("ActiveState") not in {"inactive", "failed"}:
            return False
        if props.get("UnitFileState") in {"enabled", "enabled-runtime", "linked", "linked-runtime"}:
            return False
    return True


def listening_80_443() -> tuple[bool, bool]:
    code, out = command(["ss", "-H", "-lnt"], seconds=12)
    if code != 0:
        raise Blocked("cannot inspect local TCP listeners")
    found: set[int] = set()
    for line in out.splitlines():
        cols = line.split()
        if len(cols) < 5:
            raise Blocked("cannot parse local TCP listener inventory")
        match = re.search(r":([0-9]{1,5})$", cols[3])
        if not match:
            raise Blocked("cannot parse local TCP listener port")
        found.add(int(match.group(1)))
    return (80 in found, 443 in found)


def fp(value: str) -> str:
    return hashlib.sha256(value.encode("ascii")).hexdigest()[:12]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def imds_json(which: str, *, opener=None):
    """Only fixed OCI link-local metadata endpoints; no proxy or redirect."""
    if which not in {"instance", "vnics"}:
        raise ValueError("unsupported metadata endpoint")
    url = IMDS + "/" + which + "/"
    req = urllib.request.Request(
        url, headers={"Authorization": "Bearer Oracle"}, method="GET",
    )
    if opener is None:
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect(),
        )
    with opener.open(req, timeout=6) as response:
        if response.geturl() != url:
            raise MetadataBlocked("redirect")
        body = response.read(IMDS_MAX + 1)
    if len(body) > IMDS_MAX:
        raise MetadataBlocked("oversize")
    try:
        return json.loads(body)
    except (ValueError, UnicodeDecodeError) as exc:
        raise MetadataBlocked("invalid_json") from exc


def classify_oci(instance: object, vnics: object, expected_host: str) -> tuple[str, str, bool]:
    """OCI shape & OCID contract; never reveal raw addresses, names or OCIDs."""
    if not isinstance(instance, dict):
        raise MetadataBlocked("instance_schema")
    instance_id = instance.get("id")
    if not isinstance(instance_id, str) or not instance_id.isascii() or not instance_id.startswith("ocid1.instance."):
        raise MetadataBlocked("instance_id")
    if instance.get("shape") != "VM.Standard.A1.Flex":
        raise MetadataBlocked("shape")
    if not isinstance(vnics, list) or not 1 <= len(vnics) <= 16:
        raise MetadataBlocked("vnic_schema")
    fingerprints = []
    for item in vnics:
        if not isinstance(item, dict):
            raise MetadataBlocked("vnic_schema")
        vid = item.get("vnicId")
        if not isinstance(vid, str) or not vid.isascii() or not vid.startswith("ocid1.vnic."):
            raise MetadataBlocked("vnic_id")
        try:
            ip = ipaddress.ip_address(item.get("privateIp"))
        except (TypeError, ValueError) as exc:
            raise MetadataBlocked("vnic_private_ip") from exc
        if ip.version != 4 or not any(ip in net for net in PRIVATE_NETS):
            raise MetadataBlocked("vnic_private_ip")
        fingerprints.append(fp(vid))
    if len(set(fingerprints)) != len(fingerprints):
        raise MetadataBlocked("duplicate_vnic_id")
    display = instance.get("displayName")
    hostname = instance.get("hostname")
    name_ok = display == expected_host or (
        isinstance(hostname, str) and hostname.split(".", 1)[0] == expected_host
    )
    return (
        f"OCI A1 Flex instance fingerprint={fp(instance_id)} VNIC_count={len(vnics)}",
        "VNIC fingerprints=" + ",".join(fingerprints) + " (address and OCID values withheld)",
        name_ok,
    )


def disk_summary(storage) -> tuple[int, int, list[str]]:
    """Use the product's root-ancestry logic, and list no device paths."""
    storage.root_source()
    candidates = storage.inventory()
    if len(candidates) > 64:
        raise Blocked("unexpected block device inventory size")
    approved = 0
    seen = 0
    labels: list[str] = []
    for entry in candidates:
        if entry["type"] != "disk":
            continue
        seen += 1
        path = str(entry["path"])
        if not path.startswith("/dev/") or not Path(path).is_block_device():
            labels.append("unsafe-device")
            continue
        mounted = bool(entry["mountpoints"])
        fs = str(entry["fstype"])
        size = int(entry["size"])
        code, raw = command(["wipefs", "--noheadings", "--output", "TYPE", path], seconds=15)
        safe = (code == 0 and not raw.strip() and not mounted and not fs
                and size >= 20 * 1024 ** 3)
        stable = False
        try:
            actual = Path(path).resolve(strict=True)
            directory = Path("/dev/disk/by-id")
            for candidate in directory.iterdir():
                if not candidate.is_symlink() or not candidate.name.startswith(
                    ("scsi-", "wwn-", "nvme-", "virtio-")
                ):
                    continue
                try:
                    if candidate.resolve(strict=True) == actual:
                        stable = True
                        break
                except OSError:
                    continue
        except OSError:
            pass
        if safe and stable:
            approved += 1
            labels.append("blank-candidate")
        elif mounted:
            labels.append("mounted-not-approved")
        elif fs or (code == 0 and raw.strip()):
            labels.append("contains-signatures-not-approved")
        else:
            labels.append("identity-or-signature-unproven")
    return approved, seen, sorted(labels)


def private_evidence() -> Path:
    operator = pwd.getpwnam("ubuntu")
    home = Path(operator.pw_dir)
    if home.is_symlink() or not home.is_dir():
        raise Blocked("operator home unsafe")
    base = home / "vwoci-acceptance"
    if not base.exists() and not base.is_symlink():
        base.mkdir(mode=0o700)
    if base.is_symlink():
        raise Blocked("evidence base symlink")
    info = base.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in {0, operator.pw_uid}
            or stat.S_IMODE(info.st_mode) & 0o077):
        raise Blocked("evidence base unsafe")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder = base / f"p8f-new-origin-{stamp}-{os.getpid()}"
    folder.mkdir(mode=0o700)
    return folder


class Report:
    def __init__(self, directory: Path):
        self.directory = directory
        self.rows: list[tuple[str, str]] = []
        self.blocked = False

    def add(self, level: str, message: str):
        if (level not in {"PASS", "PENDING", "BLOCKED", "NOT RUN"}
                or any(c in message for c in "\r\n\x00") or len(message) > 1024):
            raise ValueError("unsafe evidence row")
        self.rows.append((level, message))
        self.blocked |= level == "BLOCKED"

    def finish(self) -> int:
        result = "BLOCKED" if self.blocked else "HOLD"
        self.rows.append((result, "P8F fresh-origin inventory only; install, restore and live startup NOT AUTHORIZED"))
        out = "Gate P8F - new isolated OCI ARM64 host preflight (READ-ONLY)\n"
        out += "\n".join(f"{level:<10} {label}" for level, label in self.rows) + "\n"
        path = self.directory / "summary.txt"
        with path.open("x", encoding="utf-8") as stream:
            stream.write(out)
            stream.flush()
            os.fsync(stream.fileno())
        print(out, end="")
        print("Private summary:", path)
        print("Share summary and exit code only; never upload instance metadata, disks or credentials.")
        return 2 if self.blocked else 0


def main() -> int:
    if (len(sys.argv) != 5 or sys.argv[1] != "--expected-commit"
            or not SHA_PATTERN.fullmatch(sys.argv[2])
            or sys.argv[3] != "--expected-host"):
        print("BLOCKED: usage P8F --expected-commit <reviewed SHA> --expected-host <new VM>", file=sys.stderr)
        return 2
    expected_host = sys.argv[4]
    if (os.geteuid() != 0 or os.environ.get("SUDO_USER") != "ubuntu"
            or not eligible_host(platform.node().split(".")[0], expected_host)):
        print("BLOCKED: run via sudo -n from ubuntu on a NEW named OCI acceptance VM; original host forbidden", file=sys.stderr)
        return 2
    if not source_checkout_ok(sys.argv[2]) or not os_supported():
        print("BLOCKED: exact clean source or native Ubuntu 26.04 ARM64 Python 3.14 missing", file=sys.stderr)
        return 2
    try:
        out = private_evidence()
    except Exception:
        print("BLOCKED: private evidence base unavailable; no host changes attempted", file=sys.stderr)
        return 2
    report = Report(out)
    stage = "fresh-host inspection"
    try:
        report.add("PASS", "New operator-specified guest identity, exact clean candidate and Ubuntu 26.04 ARM64 rc.12 source")
        if any(p.exists() or p.is_symlink() for p in APPLIANCE_PATHS):
            raise Blocked("existing/partial appliance paths on new host")
        if not units_are_absent():
            raise Blocked("appliance systemd unit is present, active, or cannot be checked")
        if Path("/var/lib/docker").exists() or Path("/var/lib/docker").is_symlink():
            raise Blocked("preexisting Docker state; do not use host as disposable")
        report.add("PASS", "No appliance install/data/units or preexisting Docker state")
        tcp80, tcp443 = listening_80_443()
        if tcp80 or tcp443:
            raise Blocked("unexpected local TCP 80 or 443 listener on allegedly fresh host")
        report.add("PASS", "No local TCP 80/443 listener; this does NOT verify OCI ingress")
        stage = "root device lineage and candidate data volumes"
        sys.path.insert(0, str(SRC))
        from vaultwarden_oci import storage
        eligible, count, classes = disk_summary(storage)
        report.add("PASS" if eligible == 1 and count == 1 else "PENDING",
                   f"Non-boot disks={count} blank-stable candidates={eligible}; classes={','.join(classes) or 'none'}")
        report.add("PENDING", "No volume selected, attached-volume OCID proven, filesystem adopted or formatting consent granted")
        stage = "OCI link-local identity"
        try:
            instance = imds_json("instance")
            stage = "OCI link-local VNICs"
            vnics = imds_json("vnics")
        except urllib.error.HTTPError as exc:
            status = exc.code if type(exc.code) is int and 100 <= exc.code <= 599 else 0
            report.add("PENDING", "OCI IMDSv2 read-only endpoint unavailable; status=" + str(status or "unknown"))
        except (OSError, urllib.error.URLError, TimeoutError):
            report.add("PENDING", "OCI IMDSv2 unavailable; no IMDSv1 or OCI control-plane fallback")
        else:
            a, b, name_ok = classify_oci(instance, vnics, expected_host)
            report.add("PASS", a)
            report.add("PASS", b)
            report.add("PASS" if name_ok else "PENDING",
                       "OCI metadata hostname agrees with new guest" if name_ok else
                       "OCI metadata name differs; require authoritative Console VNIC/instance mapping")
        code, result = command(["timedatectl", "show", "-p", "NTPSynchronized", "--value"], seconds=12)
        report.add("PASS" if code == 0 and result.strip() == "yes" else "PENDING",
                   "NTP synchronized" if code == 0 and result.strip() == "yes" else "NTP not yet confirmed")
        report.add("PENDING", "New VNIC NSGs AND subnet security lists must be reviewed together; no Internet-wide TCP 80/443")
        report.add("PENDING", "For new host: TCP 80 closed; TCP 443 Cloudflare CIDRs only; verify IPv4/IPv6 and routing from OCI Console")
        report.add("PENDING", "Separate test hostname, Cloudflare DNS-01 ownership and Worker Route scope require authoritative review")
        report.add("PENDING", "Operator has attested off-host key/kit availability and Box test prefix; no credentials or Box objects read here")
        report.add("NOT RUN", "No OCI/Cloudflare API, firewall/NSG, DNS, Worker, certificate, Docker, app or SMTP change")
        report.add("NOT RUN", "No disk formatting/mount/install, remote backup, restore, timer, reboot or production cutover")
        return report.finish()
    except KeyboardInterrupt:
        report.add("BLOCKED", "Interrupted during " + stage + "; no retry or host repair")
    except MetadataBlocked as exc:
        report.add("BLOCKED", "OCI metadata failed allowlisted contract at " + stage + ": " + exc.code)
    except Exception:
        report.add("BLOCKED", "Read-only fresh-origin preflight failed during " + stage + "; details withheld")
    return report.finish()


if __name__ == "__main__":
    raise SystemExit(main())
