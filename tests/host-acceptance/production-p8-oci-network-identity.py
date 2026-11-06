#!/usr/bin/env python3
"""P8E: strictly read-only OCI network-identity inventory; NO live activation.

The original disposable rc.12 VM remains stopped. OCI IMDSv2 returns guest
instance/VNIC metadata, NOT OCI NSG/security-list rules, Cloudflare DNS/Worker
Routes, or authorization to serve the shared hostname. Never treat IMDS data
as proof of external isolation. Only a new root-private summary is written.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import importlib.util
import ipaddress
import json
import os
import platform
import re
import stat
import subprocess
import sys
from pathlib import Path
import urllib.error
import urllib.request

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-6-vnic"
BRANCH = "audit/rc12-p8e-oci-network-identity"
BASE = Path(__file__).resolve().parents[2]
P7_SOURCE = Path(__file__).resolve().with_name("production-reboot-persistence-consent.py")
P8A_EVIDENCE = "p8-isolation-preflight-20261104T194232Z-6906"
IMDS_ORIGIN = "http://169.254.169.254/opc/v2"
IMDS_MAX_BYTES = 65536
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")


class Blocked(RuntimeError):
    """Local security or source integrity failure; never print raw exceptions."""


class MetadataContractError(Blocked):
    """Report ONLY a fixed, non-sensitive OCI metadata validation category."""

    CATEGORIES = frozenset({
        "redirect_or_wrong_endpoint", "oversized_response", "invalid_json",
        "instance_not_object", "vnics_not_expected_array",
        "instance_ocid_invalid", "instance_shape_unexpected",
        "vnic_not_object", "vnic_ocid_invalid",
        "vnic_private_ipv4_malformed", "vnic_private_ipv4_unexpected",
        "vnic_public_ipv4_malformed", "duplicate_vnic_ocid",
    })

    def __init__(self, category: str) -> None:
        if category not in self.CATEGORIES:
            raise ValueError("invalid metadata diagnostic category")
        self.category = category
        super().__init__("OCI metadata contract: " + category)


def reviewed_source(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise Blocked("accepted read-only source unavailable")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def exact_checkout(expected: str) -> bool:
    if not SHA_PATTERN.fullmatch(expected):
        return False
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat")
    answers = []
    for args in (["rev-parse", "HEAD"], ["branch", "--show-current"], ["status", "--porcelain"]):
        try:
            result = subprocess.run(
                ["/usr/bin/git", *args], cwd=BASE, env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=20, check=False,
            )
            if result.returncode != 0 or len(result.stdout) > 8192:
                return False
            answers.append(result.stdout.decode("utf-8", "replace").strip())
        except (OSError, subprocess.TimeoutExpired):
            return False
    return answers == [expected, BRANCH, ""]


def accepted_p8a_summary(base: Path) -> bool:
    """Validate a specific recorded local acceptance; never follow a symlink."""
    directory = base / P8A_EVIDENCE
    try:
        info = directory.lstat()
    except (FileNotFoundError, NotADirectoryError):
        return False
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != 0
            or stat.S_IMODE(info.st_mode) != 0o700):
        return False
    path = directory / "summary.txt"
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0
                or stat.S_IMODE(metadata.st_mode) != 0o600
                or not 100 < metadata.st_size < 16384):
            return False
        raw = stream.read(16384).decode("utf-8", "replace")
    lines = raw.splitlines()
    required = (
        "Gate P8A - rc.12 original disposable host, READ-ONLY isolation preflight",
        "PASS       Original P7 reboot HOLD checkpoint and P7R REARMED/one-shot marker intact",
        "PASS       All five local origin/CrowdSec security doctor IDs and storage.dedicated PASS",
        "PASS       Original protected data/source digests verified across independent Git checkouts",
        "HOLD       P8A local assessment only; no isolated live start or production GO authorized",
    )
    return (all(any(line.startswith(marker) for line in lines) for marker in required)
            and "unsafe_count=0" in raw
            and not any(line.startswith("BLOCKED") for line in lines))


def fingerprint(value: str) -> str:
    """Stable comparison handle; never print the OCID, IP or private CIDR."""
    return hashlib.sha256(value.encode("ascii")).hexdigest()[:12]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def metadata_json(kind: str, *, opener=None):
    """Only two fixed link-local GET endpoints, no proxy, redirect or credentials."""
    if kind not in {"instance", "vnics"}:
        raise ValueError("unsupported metadata endpoint")
    target = IMDS_ORIGIN + "/" + kind + "/"
    request = urllib.request.Request(
        target, headers={"Authorization": "Bearer Oracle"}, method="GET",
    )
    if opener is None:
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect(),
        )
    with opener.open(request, timeout=6) as response:
        if response.geturl() != target:
            raise MetadataContractError("redirect_or_wrong_endpoint")
        size = response.read(IMDS_MAX_BYTES + 1)
        if len(size) > IMDS_MAX_BYTES:
            raise MetadataContractError("oversized_response")
    try:
        return json.loads(size)
    except (UnicodeDecodeError, ValueError) as exc:
        raise MetadataContractError("invalid_json") from exc


def guest_name_matches(instance: object) -> bool:
    """Display names are user-editable; a mismatch requires Console review."""
    if not isinstance(instance, dict):
        return False
    display = instance.get("displayName")
    hostname = instance.get("hostname")
    return (display == HOST or
            isinstance(hostname, str) and hostname.split(".", 1)[0] == HOST)


def summarize_metadata(instance: object, vnics: object) -> tuple[str, str]:
    """Validate Oracle identity shape; disclose fingerprints and counts only.

    OCI displayName and hostname are separate independently editable fields.
    A name mismatch is NOT proof of wrong instance; flag it for external
    OCI Console review without weakening the OCID/shape/VNIC checks.
    """
    if not isinstance(instance, dict):
        raise MetadataContractError("instance_not_object")
    if not isinstance(vnics, list) or not 1 <= len(vnics) <= 16:
        raise MetadataContractError("vnics_not_expected_array")
    instance_id = instance.get("id")
    if (not isinstance(instance_id, str) or not instance_id.isascii()
            or not instance_id.startswith("ocid1.instance.")):
        raise MetadataContractError("instance_ocid_invalid")
    if instance.get("shape") != "VM.Standard.A1.Flex":
        raise MetadataContractError("instance_shape_unexpected")
    hashes: list[str] = []
    ipv6_subnet_count = 0
    ipv4_public_indications = 0
    for vnic in vnics:
        if not isinstance(vnic, dict):
            raise MetadataContractError("vnic_not_object")
        vnic_id, private = vnic.get("vnicId"), vnic.get("privateIp")
        if (not isinstance(vnic_id, str) or not vnic_id.isascii()
                or not vnic_id.startswith("ocid1.vnic.")):
            raise MetadataContractError("vnic_ocid_invalid")
        try:
            ip = ipaddress.ip_address(private)
        except (ValueError, TypeError) as exc:
            raise MetadataContractError("vnic_private_ipv4_malformed") from exc
        if ip.version != 4 or not ip.is_private:
            raise MetadataContractError("vnic_private_ipv4_unexpected")
        hashes.append(fingerprint(vnic_id))
        if (isinstance(vnic.get("ipv6SubnetCidrBlocks"), list)
                and bool(vnic["ipv6SubnetCidrBlocks"])
                or isinstance(vnic.get("ipv6SubnetCidrBlock"), str)
                and vnic["ipv6SubnetCidrBlock"] not in {"", "null"}
                or isinstance(vnic.get("ipv6Addresses"), list)
                and bool(vnic["ipv6Addresses"])):
            ipv6_subnet_count += 1
        # An absent publicIp key is never evidence of absent public ingress.
        public = vnic.get("publicIp")
        if isinstance(public, str) and public:
            try:
                parsed = ipaddress.ip_address(public)
            except ValueError as exc:
                raise MetadataContractError("vnic_public_ipv4_malformed") from exc
            if parsed.version != 4:
                raise MetadataContractError("vnic_public_ipv4_malformed")
            ipv4_public_indications += 1
    if len(set(hashes)) != len(hashes):
        raise MetadataContractError("duplicate_vnic_ocid")
    return (
        f"Oracle IMDSv2 instance fingerprint={fingerprint(instance_id)} "
        f"shape=A1.Flex VNICs={len(vnics)}",
        f"VNIC fingerprints={','.join(hashes)} IPv6_subnet_indications={ipv6_subnet_count} "
        f"reported_public_IPv4={ipv4_public_indications} (absence is NOT proof of no public IP)",
    )

class Report:
    def __init__(self, output: Path) -> None:
        self.output = output
        self.rows: list[tuple[str, str]] = []
        self.blocked = False

    def add(self, status: str, message: str) -> None:
        if status not in {"PASS", "PENDING", "BLOCKED", "NOT RUN"}:
            raise ValueError("unsafe status")
        if any(c in message for c in "\r\n\x00") or len(message) > 1000:
            raise ValueError("unsafe report content")
        self.rows.append((status, message))
        self.blocked |= status == "BLOCKED"

    def finish(self) -> int:
        decision = "BLOCKED" if self.blocked else "HOLD"
        self.rows.append((decision, "P8E read-only network identity only; isolated live startup NOT authorized"))
        body = "Gate P8E - Oracle network identity and isolation prerequisites (READ-ONLY)\n"
        body += "\n".join(f"{status:<10} {message}" for status, message in self.rows) + "\n"
        out = self.output / "summary.txt"
        with out.open("x", encoding="utf-8") as file:
            file.write(body)
            file.flush()
            os.fsync(file.fileno())
        print(body, end="")
        print("Private summary:", out)
        print("Paste only sanitized summary and exit code; no private metadata, OCIDs, IPs, keys or raw doctor.")
        return 2 if self.blocked else 0


def main() -> int:
    if (len(sys.argv) != 3 or sys.argv[1] != "--expected-commit"
            or not SHA_PATTERN.fullmatch(sys.argv[2])
            or os.geteuid() != 0 or os.environ.get("SUDO_USER") != "ubuntu"):
        print("BLOCKED: sudo -n from ubuntu with --expected-commit <PR HEAD>", file=sys.stderr)
        return 2
    if platform.node().split(".")[0] != HOST or platform.machine() not in {"aarch64", "arm64"}:
        print("BLOCKED: not the original OCI ARM64 acceptance host", file=sys.stderr)
        return 2
    try:
        p7 = reviewed_source(P7_SOURCE, "p8e_original_p7")
        private_base = p7.safe_base()
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        out = private_base / f"p8e-network-identity-{stamp}-{os.getpid()}"
        out.mkdir(mode=0o700)
    except Exception:
        print("BLOCKED: no safe private operator evidence base; nothing changed", file=sys.stderr)
        return 2
    report = Report(out)
    stage = "source checkout"
    try:
        if not exact_checkout(sys.argv[2]):
            raise Blocked("reviewed source commit, branch or checkout cleanliness differs")
        report.add("PASS", "Exact branch/commit and clean source verified")
        stage = "accepted prior evidence"
        if not accepted_p8a_summary(private_base):
            raise Blocked("accepted original P8A evidence missing or unsafe")
        report.add("PASS", "Original P8A read-only HOLD evidence unchanged and readable privately")
        stage = "local stopped-host continuity"
        host_report = p7.Report(out, "p8e-snapshot")
        p7.host_snapshot(host_report, after_boot=True)
        if any(level == "BLOCKED" for level, _ in host_report.rows) or any(
            level == "PENDING" and "not persistent across cold boot" in row
            for level, row in host_report.rows
        ):
            raise Blocked("local stopped-host security/Cloudflare policy regression")
        if not any(
            level == "PASS" and "All five local origin/CrowdSec" in row
            for level, row in host_report.rows
        ):
            raise Blocked("local Cloudflare origin or CrowdSec doctor proof missing")
        report.add("PASS", "Original rc.12/disk/SQLite/SOPS, 27-ID doctor, origin/CrowdSec, disabled Worker and stopped app/timers stable")
        stage = "read-only Oracle instance metadata"
        try:
            instance = metadata_json("instance")
            stage = "read-only Oracle VNIC metadata"
            vnics = metadata_json("vnics")
        except urllib.error.HTTPError as exc:
            # Codes are safe numeric metadata; never include response body,
            # error reason, URL, headers or request/instance contents.
            code = exc.code if type(exc.code) is int and 100 <= exc.code <= 599 else 0
            report.add("PENDING", "OCI IMDSv2 request unavailable at " + stage
                       + "; HTTP status=" + str(code or "unknown"))
        except (OSError, urllib.error.URLError, TimeoutError):
            report.add("PENDING", "OCI IMDSv2 request unavailable at " + stage
                       + "; no legacy IMDS fallback or retry")
        else:
            stage = "read-only Oracle instance/VNIC validation"
            line1, line2 = summarize_metadata(instance, vnics)
            report.add("PASS", line1)
            report.add("PASS", line2)
            if guest_name_matches(instance):
                report.add("PASS", "OCI metadata display name or hostname agrees with known guest name; Console authority still PENDING")
            else:
                report.add("PENDING", "OCI metadata display name/hostname differs from Linux short hostname; require Console mapping, not automatic rejection")
        report.add("PENDING", "IMDS does NOT expose effective OCI subnet security lists, NSG ingress rules, public IPv6 or edge routing; verify in OCI Console/API")
        report.add("PENDING", "Configured shared hostname is not a test endpoint; select an independently isolated disposable target before any live start")
        report.add("PENDING", "Cloudflare DNS, proxied test route, Worker Route overlap/Fail Open and DNS-01 authority require independent read-only Cloudflare proof")
        report.add("PENDING", "Off-host recovery ZIP/private Age/passphrase custody and isolated Box test prefix remain operator prerequisites")
        report.add("NOT RUN", "No Cloudflare/OCI control-plane API, DNS/Worker update, certificate issuance, Box, SMTP, timers, application start or reboot")
        report.add("NOT RUN", "No firewall rule change, package install, recovery identity change, restore or change to original P7/P8A evidence")
        return report.finish()
    except KeyboardInterrupt:
        report.add("BLOCKED", "Interrupted during " + stage + "; no operation retried")
    except MetadataContractError as exc:
        report.add("BLOCKED", "Oracle IMDSv2 validation failed at " + stage
                   + "; category=" + exc.category + " (no raw metadata disclosed)")
    except Exception:
        report.add("BLOCKED", "Read-only verification failure during " + stage + "; details withheld")
    return report.finish()


if __name__ == "__main__":
    raise SystemExit(main())
