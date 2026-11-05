#!/usr/bin/env python3
"""P8T: batched READ-ONLY external OCI/Cloudflare isolation discovery.

No product startup, firewall refresh, SOPS publication, DNS/Worker changes,
Box use, SMTP, timers, reboot, OCI mutation, or historical one-shot replay.
Provider GET failures are PENDING, never inferred PASS. No secret/IP/OCID in
sanitized output. No test hostname is ever created or published by this gate.
"""
from __future__ import annotations

import datetime as dt
import ipaddress
import json
import os
import platform
import pwd
import re
import socket
import stat
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-7-vnic"
BRANCH = "audit/rc12-p8t-external-boundary-batched-readonly"
REPO = Path(__file__).resolve().parents[2]
EVIDENCE = Path("/home/ubuntu/vwoci-acceptance")
P8S_REPORT = EVIDENCE / "p8s-a-readonly-20261105T214536Z-3811/summary.txt"
HISTORICAL_DOMAIN = "bw.lazymocha.com"
HISTORICAL_REMOTE = "bw-backup:bw-backup"
ZONE = "lazymocha.com"
RELEASE = Path("/opt/vaultwarden-oci/releases/0.1.0-rc.12")
SHA40 = re.compile(r"[a-f0-9]{40}\Z")
OCID = re.compile(r"ocid1\.[a-z][a-z0-9_-]*\.oc[0-9]+(?:\.[a-z0-9-]+)?\.[a-z0-9.]+\Z")
FQDN = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\Z")
P8S_FINAL = f"{'HOLD':<10} P8S-A stopped-only; no live/Box/Worker/DNS/timer authorization"
P8S_REQUIRED = (
    "P8O/P8P/P8Q/P8R immutable historical evidence and original one-shot continuity validated",
    "Original dedicated ext4, historic restored SQLite/SOPS/Age and immutable product/units unchanged",
    "Original P8P BLOCKED outcome retained and P8R REARMED evidence verified",
    "No app, DNS, timers, notifications, retained Docker containers or HTTP 80/443 listeners",
    "CrowdSec engine/INPUT bouncer active; Worker disabled and inactive",
    "Validated Cloudflare CIDRs and both-family effective DOCKER-USER 443 source policy",
    "27-ID installed doctor schema and mandatory security/host/storage checks",
)
ALLOWED_ROWS = {"PASS", "PENDING", "BLOCKED", "NOT RUN"}
OCI_COMMANDS = {
    ("network", "vnic", "get"),
    ("network", "subnet", "get"),
    ("network", "security-list", "get"),
    ("network", "nsg", "rules", "list"),
    ("network", "ipv6", "list"),
}


class Blocked(RuntimeError):
    """No private details enter sanitized reports."""


def source_clean(expected: str) -> bool:
    if not SHA40.fullmatch(expected) or REPO.is_symlink() or not (REPO / ".git").is_dir():
        return False
    observed = []
    for args in (("rev-parse", "HEAD"), ("symbolic-ref", "--short", "HEAD"),
                 ("status", "--porcelain", "--untracked-files=all")):
        try:
            proc = subprocess.run(["/usr/bin/git", *args], cwd=REPO, timeout=20,
                                  stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, check=False,
                                  env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat"))
        except (OSError, subprocess.TimeoutExpired):
            return False
        if proc.returncode or len(proc.stdout) > 8192:
            return False
        observed.append(proc.stdout.decode("utf-8", "replace").strip())
    return observed == [expected, BRANCH, ""]


def host_ok() -> bool:
    if (os.geteuid() != 0 or os.getenv("SUDO_USER") != "ubuntu"
            or platform.node().split(".")[0] != HOST
            or platform.machine() not in ("aarch64", "arm64")
            or sys.version_info[:2] != (3, 14)):
        return False
    try:
        fields = dict(line.split("=", 1) for line in
                      Path("/etc/os-release").read_text(encoding="utf-8").splitlines()
                      if "=" in line)
        return fields.get("ID", "").strip('"') == "ubuntu" and fields.get("VERSION_ID", "").strip('"') == "26.04"
    except (OSError, ValueError):
        return False


def private_report(path: Path) -> bytes:
    parent = path.parent.lstat()
    if (not stat.S_ISDIR(parent.st_mode) or parent.st_uid != 0
            or stat.S_IMODE(parent.st_mode) != 0o700 or path.is_symlink()):
        raise Blocked("accepted P8S report container metadata mismatch")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as src:
        st = os.fstat(src.fileno())
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != 0
                or stat.S_IMODE(st.st_mode) != 0o600 or not 0 < st.st_size <= 65536):
            raise Blocked("accepted P8S report metadata mismatch")
        return src.read(65537)


def boot_time() -> int:
    for row in Path("/proc/stat").read_text(encoding="ascii").splitlines():
        if row.startswith("btime "):
            return int(row.split()[1])
    raise Blocked("kernel boot time unavailable")


def accept_p8s(text: str) -> None:
    rows = text.splitlines()
    if (len(rows) != 13 or rows[0] != "Gate P8S-A - NEW disposable VM protected stopped-host READ-ONLY"
            or rows[-1] != P8S_FINAL):
        raise Blocked("accepted P8S exact report framing or final HOLD differs")
    for phrase in P8S_REQUIRED:
        if sum(row.startswith("PASS") and phrase in row for row in rows[1:-1]) != 1:
            raise Blocked("accepted P8S mandatory PASS missing or duplicated")
    if (sum(row.startswith("PENDING") for row in rows[1:-1]) != 3
            or sum(row.startswith("NOT RUN") for row in rows[1:-1]) != 1
            or any(row.startswith(("BLOCKED", "HOLD")) for row in rows[1:-1])):
        raise Blocked("accepted P8S protected statuses differ")
    if "External OCI/Cloudflare isolation remains unverified" not in text:
        raise Blocked("accepted P8S external HOLD missing")


def run_local(argv: list[str], timeout: int = 12) -> tuple[bool, str]:
    try:
        proc = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=timeout, check=False)
        if proc.returncode or len(proc.stdout) > 131072:
            return False, ""
        return True, proc.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return False, ""


def local_dormant() -> bool:
    # An updated check for intervening activation, not a replay of P8S.
    for unit in ("vaultwarden-oci.service", "vaultwarden-oci.target",
                 "vaultwarden-oci-dns.service", "vaultwarden-oci-backup.timer",
                 "vaultwarden-oci-health.timer", "vaultwarden-oci-update-check.timer",
                 "vaultwarden-oci-maintenance.timer",
                 "crowdsec-cloudflare-worker-bouncer.service"):
        ok, result = run_local(["/usr/bin/systemctl", "show", unit, "--no-pager",
                                "-p", "ActiveState", "-p", "UnitFileState"])
        if not ok:
            return False
        props = dict(line.split("=", 1) for line in result.splitlines() if "=" in line)
        if (props.get("ActiveState") != "inactive"
                or props.get("UnitFileState") in ("enabled", "enabled-runtime", "linked", "linked-runtime")):
            return False
    ok, listeners = run_local(["/usr/bin/ss", "-H", "-lnt"])
    if not ok:
        return False
    for raw in listeners.splitlines():
        words = raw.split()
        if len(words) < 5:
            return False
        match = re.search(r":([0-9]{1,5})$", words[3])
        if match is None or int(match.group(1)) in (80, 443, 2375, 2376):
            return False
    ok, containers = run_local(["/usr/bin/docker", "ps", "-a", "--format", "{{.ID}}"], 30)
    return ok and not containers.strip()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Blocked("unexpected metadata/provider redirect")


def request_bytes(url: str, headers: dict[str, str], maximum: int = 131072, timeout: int = 7) -> bytes:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect)
    with opener.open(urllib.request.Request(url, headers=headers, method="GET"), timeout=timeout) as response:
        if response.status != 200:
            raise Blocked("read-only endpoint returned non-200")
        data = response.read(maximum + 1)
    if not 0 < len(data) <= maximum:
        raise Blocked("read-only endpoint content missing/oversized")
    return data


def load_json_bytes(data: bytes) -> Any:
    return json.loads(data.decode("utf-8", "strict"))


def imds() -> tuple[dict[str, Any], list[dict[str, Any]]]:
    root = "http://169.254.169.254/opc/v2/"
    header = {"Authorization": "Bearer Oracle", "Accept": "application/json"}
    instance = load_json_bytes(request_bytes(root + "instance/", header))
    vnics = load_json_bytes(request_bytes(root + "vnics/", header))
    if (not isinstance(instance, dict) or not isinstance(vnics, list)
            or not 1 <= len(vnics) <= 8 or
            not isinstance(instance.get("id"), str)
            or not OCID.fullmatch(instance["id"]) or
            not instance["id"].startswith("ocid1.instance.")
            or any(not isinstance(v, dict) or not OCID.fullmatch(str(v.get("vnicId", "")))
                   or not str(v["vnicId"]).startswith("ocid1.vnic.") for v in vnics)):
        raise Blocked("OCI IMDSv2 instance or attached VNIC schema invalid")
    return instance, vnics


def cidr_set(raw: str, family: int) -> tuple[ipaddress._BaseNetwork, ...]:
    items = []
    for line in raw.splitlines():
        if not line or line.strip() != line:
            raise Blocked("official Cloudflare CIDR list malformed")
        net = ipaddress.ip_network(line, strict=True)
        if net.version != family or net.is_private or net.is_loopback or net.is_reserved:
            raise Blocked("official Cloudflare CIDR list contains nonpublic network")
        items.append(net)
    if not (2 <= len(items) <= 64) if family == 4 else not (1 <= len(items) <= 64):
        raise Blocked("official Cloudflare CIDR list size implausible")
    if len(set(items)) != len(items):
        raise Blocked("official Cloudflare CIDRs duplicated")
    return tuple(items)


def official_cloudflare_ranges() -> dict[int, tuple[ipaddress._BaseNetwork, ...]]:
    four = request_bytes("https://www.cloudflare.com/ips-v4", {}, maximum=8192).decode("ascii")
    six = request_bytes("https://www.cloudflare.com/ips-v6", {}, maximum=8192).decode("ascii")
    return {4: cidr_set(four, 4), 6: cidr_set(six, 6)}


def find_oci_cli() -> Path | None:
    for path in (Path("/usr/bin/oci"), Path("/usr/local/bin/oci"), Path("/home/ubuntu/bin/oci")):
        if path.is_file() and os.access(path, os.X_OK):
            return path
    return None


def oci_call(command: tuple[str, ...], key: str, value: str, *, auth: str,
             executable: Path, extra: tuple[str, ...] = ()) -> Any:
    if command not in OCI_COMMANDS or not OCID.fullmatch(value) or
       not key.startswith("--") or extra not in ((), ("--all",)):
        raise Blocked("unreviewed OCI read-only query rejected")
    # CLI runs as the unprivileged ubuntu user, never as root.
    account = pwd.getpwnam("ubuntu")
    argv = [str(executable), *command, key, value, *extra, "--output", "json",
            "--max-retries", "0", "--connection-timeout", "4", "--read-timeout", "8"]
    if auth == "instance":
        argv.extend(["--auth", "instance_principal"])
    elif auth != "config":
        raise Blocked("invalid OCI read-only authentication mode")
    environment = {
        "HOME": "/home/ubuntu", "PATH": "/usr/local/bin:/usr/bin:/bin",
        "LANG": "C.UTF-8", "LC_ALL": "C", "OCI_CLI_AUTO_PROMPT": "false",
    }
    try:
        proc = subprocess.run(argv, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              timeout=30, check=False, cwd="/home/ubuntu",
                              user=account.pw_uid, group=account.pw_gid,
                              env=environment)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode or len(proc.stdout) > 262144:
        return None
    try:
        return load_json_bytes(proc.stdout)
    except (UnicodeError, ValueError):
        return None


def oci_probe(vnic_id: str, *, executable: Path) -> tuple[Any, str] | tuple[None, None]:
    for mode in ("config", "instance"):
        if mode == "config" and not Path("/home/ubuntu/.oci/config").is_file():
            continue
        result = oci_call(("network", "vnic", "get"), "--vnic-id", vnic_id,
                          auth=mode, executable=executable)
        if isinstance(result, dict) and isinstance(result.get("data"), dict):
            return result["data"], mode
    return None, None


def port_intersects(options: Any, port: int) -> bool | None:
    if options is None:
        return True
    if not isinstance(options, dict):
        return None
    value = options.get("destination-port-range")
    if value is None:
        return True
    if not isinstance(value, dict):
        return None
    try:
        start = int(value["min"])
        end = int(value["max"])
    except (KeyError, ValueError, TypeError):
        return None
    if not 1 <= start <= end <= 65535:
        return None
    return start <= port <= end


def rule_risk(rule: dict[str, Any], trusted: dict[int, tuple[ipaddress._BaseNetwork, ...]]) -> str:
    """Return safe/overexposed/unknown/not-http for one OCI ingress rule."""
    if not isinstance(rule, dict):
        return "unknown"
    if str(rule.get("direction", "INGRESS")).upper() != "INGRESS":
        return "not-http"
    protocol = str(rule.get("protocol", "")).lower()
    if protocol not in ("6", "all", "-1"):
        return "not-http" if protocol.isdigit() else "unknown"
    option = rule.get("tcp-options") if protocol == "6" else None
    port80 = port_intersects(option, 80)
    port443 = port_intersects(option, 443)
    if port80 is None or port443 is None:
        return "unknown"
    if not (port80 or port443):
        return "not-http"
    if str(rule.get("source-type", "CIDR_BLOCK")).upper() != "CIDR_BLOCK":
        return "unknown"
    try:
        source = ipaddress.ip_network(rule["source"], strict=True)
    except (KeyError, ValueError, TypeError):
        return "unknown"
    if source.is_private or source.is_loopback or source.is_link_local:
        return "not-http"
    if port80:
        return "overexposed"
    if port443 and not any(source.subnet_of(allowed) for allowed in trusted[source.version]):
        return "overexposed"
    return "safe"


def review_oci_rules(rules: list[dict[str, Any]], trusted: dict[int, tuple[ipaddress._BaseNetwork, ...]]) -> str:
    if not isinstance(rules, list) or len(rules) > 1024:
        return "PENDING"
    judgments = [rule_risk(rule, trusted) for rule in rules]
    if "overexposed" in judgments:
        return "BLOCKED"
    if "unknown" in judgments:
        return "PENDING"
    if "safe" not in judgments:
        return "PENDING"
    return "PASS"


def cf_api(token: str, path: str) -> dict[str, Any]:
    if (not token or len(token) > 512 or not re.fullmatch(r"/(?:zones|accounts)/[a-zA-Z0-9/?=&._%-]+", path)):
        raise Blocked("unapproved Cloudflare read-only endpoint")
    blob = request_bytes("https://api.cloudflare.com/client/v4" + path,
                         {"Authorization": "Bearer " + token,
                          "Accept": "application/json"}, maximum=262144, timeout=10)
    value = load_json_bytes(blob)
    if not isinstance(value, dict) or value.get("success") is not True or not isinstance(value.get("result"), list):
        raise Blocked("Cloudflare read-only query failed")
    return value


def cf_paginate(token: str, prefix: str, *, limit: int = 10) -> list[dict[str, Any]]:
    found: list[dict[str, Any]] = []
    for page in range(1, limit + 1):
        sep = "&" if "?" in prefix else "?"
        doc = cf_api(token, f"{prefix}{sep}page={page}&per_page=100")
        results = doc["result"]
        if any(not isinstance(x, dict) for x in results):
            raise Blocked("Cloudflare list schema invalid")
        found.extend(results)
        if len(found) > limit * 100:
            raise Blocked("Cloudflare list exceeds bounded audit")
        meta = doc.get("result_info")
        if isinstance(meta, dict) and isinstance(meta.get("total_pages"), int):
            if meta["total_pages"] < 1 or meta["total_pages"] > limit:
                raise Blocked("Cloudflare pagination exceeds safe cap")
            if page >= meta["total_pages"]:
                return found
        elif len(results) < 100:
            return found
    raise Blocked("Cloudflare pagination incomplete")


def route_collides(pattern: str, fqdn: str) -> bool:
    if not isinstance(pattern, str) or not 0 < len(pattern) <= 512:
        return True
    host_pattern = pattern.split("/", 1)[0].lower()
    if host_pattern in ("*", "*." + ZONE):
        return True
    from fnmatch import fnmatchcase
    return fnmatchcase(fqdn, host_pattern)


def review_cf_candidate(fqdn: str, zone: str, records: list[dict[str, Any]],
                        routes: list[dict[str, Any]], domains: list[dict[str, Any]] | None,
                        expected_ip: str | None) -> str:
    if not fqdn or not fqdn.endswith("." + zone) or fqdn == HISTORICAL_DOMAIN:
        return "PENDING"
    if any(route_collides(str(r.get("pattern", "*")), fqdn) for r in routes):
        return "BLOCKED"
    if domains is None:
        return "PENDING"
    if any(d.get("hostname", "").lower() == fqdn and (d.get("enabled") or d.get("previews_enabled"))
           for d in domains):
        return "BLOCKED"
    matching = [r for r in records if r.get("name", "").lower() == fqdn]
    wildcard = [r for r in records if r.get("name", "").lower().startswith("*.") and
                fqdn.endswith(r.get("name", "").lower()[1:])]
    if wildcard:
        return "BLOCKED"
    if not matching:
        return "PENDING"
    if any(r.get("type") not in ("A", "AAAA", "CNAME") or r.get("proxied") is not True
           for r in matching):
        return "PENDING"
    if expected_ip is None:
        return "PENDING"
    if any(r.get("type") != "A" or r.get("content") != expected_ip for r in matching):
        return "BLOCKED"
    return "PASS"


def private_output() -> Path:
    dirname = ("p8t-readonly-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
               + "-" + str(os.getpid()))
    folder = EVIDENCE / dirname
    folder.mkdir(mode=0o700)
    meta = folder.lstat()
    if meta.st_uid != 0 or stat.S_IMODE(meta.st_mode) != 0o700:
        raise Blocked("private P8T directory metadata invalid")
    return folder


def emit(folder: Path | None, rows: list[tuple[str, str]], outcome: str) -> int:
    if outcome not in ("HOLD", "BLOCKED"):
        raise Blocked("invalid P8T outcome")
    summary = ["Gate P8T - NEW VM external isolation READ-ONLY batch"]
    for state, key in rows:
        if state not in ALLOWED_ROWS or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{2,100}", key):
            raise Blocked("unsafe P8T sanitized diagnostic row")
        summary.append(f"{state:<10} {key}")
    summary.append(f"{outcome:<10} P8T no live/public/production GO; no service/provider mutation")
    content = "\n".join(summary) + "\n"
    if folder is not None:
        fd = os.open(folder / "summary.txt", os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                     getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(content)
            out.flush()
            os.fsync(out.fileno())
    print(content, end="")
    if folder is not None:
        print("Private summary:", folder / "summary.txt")
    print("Share summary and P8T_EXIT only; do not paste IPs, OCIDs, API responses, tokens or logs.")
    return 2 if outcome == "BLOCKED" else 0


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if (len(args) not in (2, 4) or args[:1] != ["--expected-commit"]
            or not SHA40.fullmatch(args[1]) or
            (len(args) == 4 and args[2] != "--test-fqdn") or
            not host_ok() or not source_clean(args[1])):
        print("BLOCKED: P8T requires pinned clean source, sudo -n and the NEW Ubuntu 26.04 ARM64 host")
        return 2
    candidate = args[3].lower().rstrip(".") if len(args) == 4 else ""
    if candidate and (not FQDN.fullmatch(candidate) or not candidate.endswith("." + ZONE)
                      or candidate == HISTORICAL_DOMAIN):
        print("BLOCKED: candidate hostname must be a distinct valid subdomain of the owned zone")
        return 2
    folder: Path | None = None
    rows: list[tuple[str, str]] = []
    phase = "initial"
    try:
        root = EVIDENCE.lstat()
        if not stat.S_ISDIR(root.st_mode) or stat.S_IMODE(root.st_mode) != 0o700 or root.st_uid not in (0, pwd.getpwnam("ubuntu").pw_uid):
            raise Blocked("acceptance evidence root ownership changed")
        folder = private_output()
        phase = "p8s.archived-evidence"
        accept_p8s(private_report(P8S_REPORT).decode("utf-8", "strict"))
        if P8S_REPORT.lstat().st_mtime < boot_time():
            raise Blocked("kernel rebooted since accepted P8S HOLD")
        rows.append(("PASS", "prior.p8s-exact-hold-evidence-and-current-boot"))

        phase = "local.stopped-state"
        if not local_dormant():
            raise Blocked("host services/listeners changed since P8S stopped state")
        rows.append(("PASS", "host.no-public-listeners-no-containers-no-app-timers"))

        phase = "oci.imdsv2"
        try:
            instance, vnics = imds()
            if instance.get("displayName") != HOST:
                raise Blocked("IMDSv2 instance identity differs from expected disposable host")
            rows.append(("PASS", "oci.imdsv2-instance-and-vnic-inventory"))
        except Blocked:
            raise
        except Exception:
            instance, vnics = {}, []
            rows.append(("PENDING", "oci.imdsv2-provider-identity-unavailable"))

        phase = "cloudflare.official-cidrs"
        try:
            trusted = official_cloudflare_ranges()
            rows.append(("PASS", "cloudflare.official-dual-stack-cidr-read"))
        except Exception:
            trusted = {}
            rows.append(("PENDING", "cloudflare.official-cidr-read-unavailable"))

        phase = "oci.authoritative-security"
        oci_ip: str | None = None
        cli = find_oci_cli()
        if not vnics or cli is None or not trusted:
            rows.append(("PENDING", "oci.authoritative-nsg-and-security-list-unavailable"))
        else:
            vnic_id = str(vnics[0]["vnicId"])
            vnic, auth = oci_probe(vnic_id, executable=cli)
            if not isinstance(vnic, dict):
                rows.append(("PENDING", "oci.provider-read-permission-or-cli-unavailable"))
            elif vnic.get("id") != vnic_id:
                raise Blocked("OCI API VNIC does not match local IMDSv2 VNIC")
            else:
                sub_id = str(vnic.get("subnet-id", ""))
                ip = vnic.get("public-ip")
                if isinstance(ip, str) and ip and ipaddress.ip_address(ip).version == 4:
                    oci_ip = ip
                    rows.append(("PASS", "oci.public-ipv4-from-authoritative-vnic"))
                else:
                    rows.append(("PENDING", "oci.public-ipv4-unverified"))
                if len(vnics) != 1:
                    rows.append(("PENDING", "oci.additional-attached-vnics-require-review"))
                if not OCID.fullmatch(sub_id):
                    rows.append(("PENDING", "oci.subnet-id-unverified"))
                else:
                    get = lambda cmd, key, val, extra=(): oci_call(cmd, key, val, auth=auth,
                                                             executable=cli, extra=extra)
                    subnet_doc = get(("network", "subnet", "get"), "--subnet-id", sub_id)
                    subnet = subnet_doc.get("data") if isinstance(subnet_doc, dict) else None
                    nsgs = vnic.get("nsg-ids", [])
                    slists = subnet.get("security-list-ids") if isinstance(subnet, dict) else None
                    if (not isinstance(subnet, dict) or subnet.get("id") != sub_id
                            or not isinstance(nsgs, list) or not isinstance(slists, list)
                            or len(nsgs) > 10 or len(slists) > 10):
                        rows.append(("PENDING", "oci.effective-rule-attachments-incomplete"))
                    else:
                        ingress: list[dict[str, Any]] = []
                        complete = True
                        for target in slists:
                            if not isinstance(target, str) or not OCID.fullmatch(target):
                                complete = False
                                break
                            doc = get(("network", "security-list", "get"), "--security-list-id", target)
                            data = doc.get("data") if isinstance(doc, dict) else None
                            rules = data.get("ingress-security-rules") if isinstance(data, dict) else None
                            if not isinstance(rules, list):
                                complete = False
                                break
                            ingress.extend(rules)
                        if complete:
                            for target in nsgs:
                                if not isinstance(target, str) or not OCID.fullmatch(target):
                                    complete = False
                                    break
                                doc = get(("network", "nsg", "rules", "list"), "--nsg-id", target, ("--all",))
                                rules = doc.get("data") if isinstance(doc, dict) else None
                                if not isinstance(rules, list):
                                    complete = False
                                    break
                                ingress.extend(rules)
                        if not complete:
                            rows.append(("PENDING", "oci.provider-ingress-inventory-incomplete"))
                        else:
                            judgment = review_oci_rules(ingress, trusted)
                            rows.append((judgment, "oci.effective-union-of-nsg-and-security-list-ingress"))
                            if judgment == "BLOCKED":
                                raise Blocked("OCI effective ingress permits unsafe public HTTP/HTTPS source")
                    v6doc = get(("network", "ipv6", "list"), "--vnic-id", vnic_id, ("--all",))
                    ipv6 = v6doc.get("data") if isinstance(v6doc, dict) else None
                    if not isinstance(ipv6, list):
                        rows.append(("PENDING", "oci.public-ipv6-allocation-unverified"))
                    elif ipv6:
                        rows.append(("PENDING", "oci.ipv6-assigned-requires-external-route-review"))
                    else:
                        rows.append(("PASS", "oci.no-ipv6-assignment-on-primary-vnic"))

        phase = "cloudflare.authoritative-routes"
        rows.append(("PASS" if candidate else "PENDING", "cloudflare.distinct-test-fqdn-specified" if candidate else "cloudflare.distinct-test-fqdn-unprovided"))
        try:
            if not RELEASE.is_dir():
                raise Blocked("immutable rc12 release missing")
            sys.path.insert(0, str(RELEASE))
            from vaultwarden_oci import runtime, secrets
            cfg = runtime.load_config()
            if cfg.domain != HISTORICAL_DOMAIN or cfg.offsite_remote != HISTORICAL_REMOTE:
                raise Blocked("original recovered application config changed before isolation gate")
            values = secrets.validate_encrypted(cfg.offline_recovery_recipient)
            token = values.get("cloudflare_api_token", "") if isinstance(values, dict) else ""
            if not isinstance(token, str) or not token:
                raise Blocked("installed Cloudflare credentials unavailable")
            zone = cf_paginate(token, "/zones?name=" + ZONE + "&", limit=2)
            hits = [z for z in zone if z.get("name") == ZONE]
            if len(hits) != 1 or not re.fullmatch(r"[a-f0-9]{32}", str(hits[0].get("id", ""))):
                raise Blocked("Cloudflare authoritative zone identity ambiguous")
            zid = hits[0]["id"]
            records = cf_paginate(token, f"/zones/{zid}/dns_records", limit=10)
            routes_doc = cf_api(token, f"/zones/{zid}/workers/routes")
            routes = routes_doc["result"]
            if len(routes) > 1000 or any(not isinstance(x, dict) for x in routes):
                raise Blocked("Cloudflare Worker route list malformed")
            account = hits[0].get("account")
            accountid = account.get("id") if isinstance(account, dict) else None
            custom = None
            if isinstance(accountid, str) and re.fullmatch(r"[a-f0-9]{32}", accountid):
                try:
                    custom = cf_paginate(token, f"/accounts/{accountid}/workers/domains", limit=10)
                except Exception:
                    pass
            rows.append(("PASS", "cloudflare.authoritative-zone-dns-and-worker-routes-read"))
            review = review_cf_candidate(candidate, ZONE, records, routes, custom, oci_ip)
            rows.append((review, "cloudflare.test-host-dns-worker-and-origin-isolation"))
            if review == "BLOCKED":
                raise Blocked("Cloudflare test hostname collides with DNS/Worker or expected origin")
            if custom is None:
                rows.append(("PENDING", "cloudflare.worker-custom-domains-scope-unverified"))
        except Blocked as exc:
            if "changed before isolation gate" in str(exc) or "collides" in str(exc):
                raise
            rows.append(("PENDING", "cloudflare.readonly-api-credentials-or-permissions-incomplete"))
        except Exception:
            rows.append(("PENDING", "cloudflare.readonly-api-unavailable"))

        rows.extend([
            ("PENDING", "oci.console-recovery-and-original-vm-isolation-independent-attestation"),
            ("PENDING", "canary.separate-blank-dataset-and-test-only-backup-destination-not-proven"),
            ("PENDING", "canary.live-caddy-vaultwarden-tls-start-and-rollback-not-run"),
            ("NOT RUN", "no-oci-cloudflare-dns-worker-box-smtp-firewall-service-or-timer-mutations"),
        ])
        return emit(folder, rows, "HOLD")
    except Exception:
        rows.append(("BLOCKED", "safety-or-integrity-drift-at-" + phase.replace(".", "-")))
        return emit(folder, rows, "BLOCKED")


if __name__ == "__main__":
    raise SystemExit(main())
