"""Cloudflare-only origin ingress and CrowdSec Cloudflare remediation for V2."""
from __future__ import annotations

import ipaddress
import json
import os
import stat
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Mapping, Sequence

from . import secrets
from .cli import CommandResult, DoctorCheck, run_command

CLOUDFLARE_IPV4_URL = "https://www.cloudflare.com/ips-v4"
CLOUDFLARE_IPV6_URL = "https://www.cloudflare.com/ips-v6"
CLOUDFLARE_API = "https://api.cloudflare.com/client/v4"
CROWDSEC_REPO_INSTALLER = "https://install.crowdsec.net"
MAX_RESPONSE_BYTES = 64 * 1024
MAX_INSTALLER_BYTES = 512 * 1024
LKG_MAX_AGE_SECONDS = 72 * 60 * 60
CLOCK_SKEW_SECONDS = 5 * 60
CHAIN = "VWOCI-CF-HTTPS"
RULE_COMMENT = "vaultwarden-oci:cloudflare-https"
GUARD_COMMENT = "vaultwarden-oci:cloudflare-guard"
BOUNCER_ID = "vaultwarden-oci-cloudflare"
BOUNCER_SERVICE = "crowdsec-cloudflare-worker-bouncer.service"
BOUNCER_BINARY = "/usr/bin/crowdsec-cloudflare-worker-bouncer"
CROWDSEC_SERVICE = "crowdsec.service"
STATE_ROOT = Path("/var/lib/vaultwarden-oci/state")
LKG_PATH = STATE_ROOT / "cloudflare-ranges.json"
CADDY_LOG = Path("/var/lib/vaultwarden-oci/caddy/log/access.log")
ACQUIS_PATH = Path("/etc/crowdsec/acquis.d/vaultwarden-oci.yaml")
BOUNCER_DROPIN = Path(
    "/etc/systemd/system/crowdsec-cloudflare-worker-bouncer.service.d/vaultwarden-oci.conf"
)
RUNTIME_CONFIG = Path("/run/vaultwarden-oci/transient/crowdsec-cloudflare-worker-bouncer.yaml")

Runner = Callable[..., CommandResult]
Fetcher = Callable[[str, int], str]


class EdgeError(RuntimeError):
    """Raised when no safe supported edge policy can be established."""


@dataclass(frozen=True)
class CloudflarePolicy:
    ipv4: tuple[ipaddress.IPv4Network, ...]
    ipv6: tuple[ipaddress.IPv6Network, ...]
    fetched_at: int
    source: str

    @property
    def cidrs(self) -> tuple[str, ...]:
        return tuple(str(network) for network in (*self.ipv4, *self.ipv6))


@dataclass(frozen=True)
class EdgePaths:
    lkg: Path = LKG_PATH
    acquisition: Path = ACQUIS_PATH
    bouncer_dropin: Path = BOUNCER_DROPIN
    remediation_config: Path = RUNTIME_CONFIG
    caddy_log: Path = CADDY_LOG


def _safe_network(network: ipaddress._BaseNetwork) -> bool:
    return not (
        network.is_private
        or network.is_loopback
        or network.is_link_local
        or network.is_multicast
        or network.is_reserved
        or network.is_unspecified
    )


def parse_cidrs(text: str, family: int) -> tuple[ipaddress._BaseNetwork, ...]:
    """Strictly parse one Cloudflare CIDR per line for the requested IP family."""
    if family not in {4, 6}:
        raise ValueError(family)
    if not isinstance(text, str) or not text or "\x00" in text:
        raise EdgeError(f"Cloudflare IPv{family} response is empty or invalid")
    networks: list[ipaddress._BaseNetwork] = []
    seen: set[str] = set()
    for raw in text.splitlines():
        if not raw or raw != raw.strip() or raw.startswith("#"):
            raise EdgeError(f"Cloudflare IPv{family} response contains a malformed line")
        try:
            network = ipaddress.ip_network(raw, strict=True)
        except ValueError as exc:
            raise EdgeError(f"Cloudflare IPv{family} response contains an invalid CIDR") from exc
        if network.version != family or not _safe_network(network):
            raise EdgeError(f"Cloudflare IPv{family} response contains an unsafe CIDR")
        canonical = str(network)
        if canonical in seen:
            raise EdgeError(f"Cloudflare IPv{family} response contains duplicate CIDRs")
        seen.add(canonical)
        networks.append(network)
    minimum = 2 if family == 4 else 1
    if not minimum <= len(networks) <= 64:
        raise EdgeError(f"Cloudflare IPv{family} response has an implausible CIDR count")
    ordered = sorted(networks, key=lambda item: (int(item.network_address), item.prefixlen))
    for left, right in zip(ordered, ordered[1:]):
        if left.overlaps(right):
            raise EdgeError(f"Cloudflare IPv{family} response contains overlapping CIDRs")
    return tuple(ordered)


def validate_policy(ipv4_text: str, ipv6_text: str, *, fetched_at: int, source: str) -> CloudflarePolicy:
    return CloudflarePolicy(
        ipv4=tuple(parse_cidrs(ipv4_text, 4)),
        ipv6=tuple(parse_cidrs(ipv6_text, 6)),
        fetched_at=fetched_at,
        source=source,
    )


def _http_text(url: str, maximum: int = MAX_RESPONSE_BYTES) -> str:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "VaultWarden-OCI/2 cloudflare-edge-policy"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            if response.status != 200:
                raise EdgeError(f"HTTPS fetch failed with status {response.status}")
            body = response.read(maximum + 1)
    except (OSError, urllib.error.URLError, urllib.error.HTTPError) as exc:
        raise EdgeError("HTTPS fetch failed") from exc
    if len(body) > maximum:
        raise EdgeError("HTTPS response exceeds the allowed size")
    try:
        return body.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise EdgeError("HTTPS response is not UTF-8") from exc


def fetch_cloudflare_policy(*, now: int | None = None, fetcher: Fetcher = _http_text) -> CloudflarePolicy:
    timestamp = int(time.time()) if now is None else int(now)
    return validate_policy(
        fetcher(CLOUDFLARE_IPV4_URL, MAX_RESPONSE_BYTES),
        fetcher(CLOUDFLARE_IPV6_URL, MAX_RESPONSE_BYTES),
        fetched_at=timestamp,
        source="current",
    )


def _atomic_write(path: Path, text: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    tmp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), mode)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        os.chmod(path, mode)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def persist_lkg(policy: CloudflarePolicy, path: Path = LKG_PATH) -> None:
    payload = {
        "schema_version": 1,
        "fetched_at": policy.fetched_at,
        "ipv4": [str(item) for item in policy.ipv4],
        "ipv6": [str(item) for item in policy.ipv6],
    }
    try:
        _atomic_write(path, json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
    except OSError as exc:
        raise EdgeError(f"cannot persist Cloudflare last-known-good policy: {exc}") from exc


def load_lkg(path: Path = LKG_PATH, *, now: int | None = None) -> CloudflarePolicy:
    timestamp = int(time.time()) if now is None else int(now)
    try:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise EdgeError("Cloudflare last-known-good path is not a regular file")
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise EdgeError("no Cloudflare last-known-good policy exists") from exc
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise EdgeError("Cloudflare last-known-good policy is unreadable") from exc
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise EdgeError("Cloudflare last-known-good policy schema is invalid")
    fetched_at = payload.get("fetched_at")
    ipv4 = payload.get("ipv4")
    ipv6 = payload.get("ipv6")
    if (
        not isinstance(fetched_at, int)
        or isinstance(fetched_at, bool)
        or not isinstance(ipv4, list)
        or not all(isinstance(item, str) for item in ipv4)
        or not isinstance(ipv6, list)
        or not all(isinstance(item, str) for item in ipv6)
    ):
        raise EdgeError("Cloudflare last-known-good policy fields are invalid")
    age = timestamp - fetched_at
    if age < -CLOCK_SKEW_SECONDS:
        raise EdgeError("Cloudflare last-known-good policy timestamp is in the future")
    if age > LKG_MAX_AGE_SECONDS:
        raise EdgeError("Cloudflare last-known-good policy is stale")
    return validate_policy(
        "\n".join(ipv4),
        "\n".join(ipv6),
        fetched_at=fetched_at,
        source="last-known-good",
    )


def select_policy(
    *,
    path: Path = LKG_PATH,
    now: int | None = None,
    fetcher: Fetcher = _http_text,
) -> CloudflarePolicy:
    timestamp = int(time.time()) if now is None else int(now)
    try:
        policy = fetch_cloudflare_policy(now=timestamp, fetcher=fetcher)
        persist_lkg(policy, path)
        return policy
    except EdgeError as current_error:
        try:
            return load_lkg(path, now=timestamp)
        except EdgeError as cached_error:
            raise EdgeError(
                f"no safe Cloudflare CIDR policy exists: current fetch invalid; {cached_error}"
            ) from current_error


def _command(runner: Runner, argv: Sequence[str], label: str) -> None:
    result = runner(argv)
    if not result.ok:
        detail = result.kind if result.returncode is None else f"exit {result.returncode}"
        raise EdgeError(f"{label} failed ({detail})")


def _rule(binary: str, comment: str, target: str) -> list[str]:
    return [
        binary,
        "-w",
        "-p",
        "tcp",
        "-m",
        "conntrack",
        "--ctorigdstport",
        "443",
        "-m",
        "comment",
        "--comment",
        comment,
        "-j",
        target,
    ]


def _ensure_guard(binary: str, runner: Runner) -> None:
    _command(runner, [binary, "-w", "-n", "-L", "DOCKER-USER"], f"{binary} Docker hook check")
    guard = _rule(binary, GUARD_COMMENT, "DROP")
    if not runner([binary, "-w", "-C", "DOCKER-USER", *guard[2:]]).ok:
        _command(
            runner,
            [binary, "-w", "-I", "DOCKER-USER", "1", *guard[2:]],
            f"{binary} fail-closed guard install",
        )


def install_fail_closed_guard(*, runner: Runner = run_command) -> None:
    errors: list[str] = []
    for binary in ("iptables", "ip6tables"):
        try:
            _ensure_guard(binary, runner)
        except EdgeError as exc:
            errors.append(str(exc))
    if errors:
        raise EdgeError("; ".join(errors))


def _rebuild_family(
    binary: str,
    networks: Iterable[ipaddress._BaseNetwork],
    runner: Runner,
) -> None:
    if not runner([binary, "-w", "-n", "-L", CHAIN]).ok:
        _command(runner, [binary, "-w", "-N", CHAIN], f"{binary} chain creation")
    _command(runner, [binary, "-w", "-F", CHAIN], f"{binary} chain flush")
    for network in networks:
        _command(
            runner,
            [binary, "-w", "-A", CHAIN, "-s", str(network), "-j", "RETURN"],
            f"{binary} Cloudflare allow rule",
        )
    _command(runner, [binary, "-w", "-A", CHAIN, "-j", "DROP"], f"{binary} default deny rule")

    jump = _rule(binary, RULE_COMMENT, CHAIN)
    while runner([binary, "-w", "-C", "DOCKER-USER", *jump[2:]]).ok:
        _command(
            runner,
            [binary, "-w", "-D", "DOCKER-USER", *jump[2:]],
            f"{binary} stale edge jump removal",
        )
    _command(
        runner,
        [binary, "-w", "-I", "DOCKER-USER", "2", *jump[2:]],
        f"{binary} edge jump install",
    )
    guard = _rule(binary, GUARD_COMMENT, "DROP")
    _command(
        runner,
        [binary, "-w", "-D", "DOCKER-USER", *guard[2:]],
        f"{binary} fail-closed guard removal",
    )


def apply_origin_policy(policy: CloudflarePolicy, *, runner: Runner = run_command) -> None:
    """Apply both families while a temporary top-of-chain guard blocks published 443."""
    install_fail_closed_guard(runner=runner)
    _rebuild_family("iptables", policy.ipv4, runner)
    _rebuild_family("ip6tables", policy.ipv6, runner)


def refresh_origin_policy(
    *,
    path: Path = LKG_PATH,
    now: int | None = None,
    fetcher: Fetcher = _http_text,
    runner: Runner = run_command,
) -> CloudflarePolicy:
    # Guard first. A failed fetch/cache validation therefore leaves the origin closed.
    install_fail_closed_guard(runner=runner)
    policy = select_policy(path=path, now=now, fetcher=fetcher)
    apply_origin_policy(policy, runner=runner)
    return policy


def caddy_trusted_proxy_block(policy: CloudflarePolicy) -> str:
    cidrs = " ".join(policy.cidrs)
    return (
        " servers {\n"
        f"  trusted_proxies static {cidrs}\n"
        "  trusted_proxies_strict\n"
        "  client_ip_headers CF-Connecting-IP\n"
        " }\n"
    )


def _write_root_file(path: Path, content: str, mode: int) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        _atomic_write(path, content, mode)
    except OSError as exc:
        raise EdgeError(f"cannot write {path}: {exc}") from exc


def acquisition_text(caddy_log: Path = CADDY_LOG) -> str:
    return f'''# Managed by VaultWarden-OCI V2 Phase 4.\nfilenames:\n  - {caddy_log}\nlabels:\n  type: caddy\n'''


def bouncer_dropin_text(config: Path = RUNTIME_CONFIG) -> str:
    return f'''# Managed by VaultWarden-OCI V2 Phase 4.\n[Service]\nExecStart=\nExecStartPre=\nExecStartPre=/usr/local/bin/vwctl crowdsec prepare-remediation\nExecStartPre={BOUNCER_BINARY} -c {config} -t\nExecStart={BOUNCER_BINARY} -c {config}\n'''


def _download_installer() -> Path:
    text = _http_text(CROWDSEC_REPO_INSTALLER, MAX_INSTALLER_BYTES)
    runtime = Path("/run/vaultwarden-oci/transient")
    runtime.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix="crowdsec-repo-", suffix=".sh", dir=runtime)
    path = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(path, 0o700)
        return path
    except Exception:
        path.unlink(missing_ok=True)
        raise


def setup_crowdsec(*, paths: EdgePaths = EdgePaths(), runner: Runner = run_command) -> None:
    if os.geteuid() != 0 and paths == EdgePaths():
        raise EdgeError("vwctl crowdsec setup must run as root")
    installer: Path | None = None
    try:
        installer = _download_installer()
        _command(runner, ["/bin/sh", str(installer)], "CrowdSec repository setup")
    finally:
        if installer is not None:
            installer.unlink(missing_ok=True)
    _command(runner, ["apt-get", "update"], "apt metadata refresh")
    _command(
        runner,
        ["apt-get", "install", "-y", "crowdsec", "crowdsec-cloudflare-worker-bouncer"],
        "CrowdSec package installation",
    )
    _command(
        runner,
        ["cscli", "collections", "install", "crowdsecurity/caddy"],
        "CrowdSec Caddy collection installation",
    )
    _write_root_file(paths.acquisition, acquisition_text(paths.caddy_log), 0o600)
    _write_root_file(paths.bouncer_dropin, bouncer_dropin_text(paths.remediation_config), 0o644)
    _command(runner, ["systemctl", "daemon-reload"], "systemd reload")
    _command(runner, ["systemctl", "enable", "--now", CROWDSEC_SERVICE], "CrowdSec enable/start")
    _command(runner, ["systemctl", "restart", CROWDSEC_SERVICE], "CrowdSec restart")
    _command(runner, ["systemctl", "enable", "--now", BOUNCER_SERVICE], "Cloudflare bouncer enable/start")


def _cloudflare_json(url: str, token: str) -> Mapping[str, object]:
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "User-Agent": "VaultWarden-OCI/2 crowdsec-cloudflare",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
            if response.status != 200 or len(raw) > MAX_RESPONSE_BYTES:
                raise EdgeError("Cloudflare API request failed")
    except (OSError, urllib.error.URLError, urllib.error.HTTPError) as exc:
        raise EdgeError("Cloudflare API request failed") from exc
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise EdgeError("Cloudflare API returned invalid JSON") from exc
    if not isinstance(payload, dict) or payload.get("success") is not True:
        raise EdgeError("Cloudflare API rejected the remediation credential")
    return payload


def resolve_cloudflare_zone(domain: str, token: str) -> tuple[str, str]:
    labels = domain.rstrip(".").lower().split(".")
    if len(labels) < 2:
        raise EdgeError("site domain is not a valid Cloudflare hostname")
    for index in range(0, len(labels) - 1):
        candidate = ".".join(labels[index:])
        query = urllib.parse.urlencode({"name": candidate, "status": "active", "per_page": "1"})
        payload = _cloudflare_json(f"{CLOUDFLARE_API}/zones?{query}", token)
        result = payload.get("result")
        if not isinstance(result, list) or not result:
            continue
        zone = result[0]
        if not isinstance(zone, dict) or zone.get("name") != candidate:
            continue
        zone_id = zone.get("id")
        account = zone.get("account")
        account_id = account.get("id") if isinstance(account, dict) else None
        if isinstance(zone_id, str) and zone_id and isinstance(account_id, str) and account_id:
            return account_id, zone_id
    raise EdgeError("Cloudflare remediation token cannot resolve the configured site zone")


def remediation_config_text(
    *,
    lapi_key: str,
    token: str,
    account_id: str,
    zone_id: str,
    domain: str,
) -> str:
    q = json.dumps
    return f'''crowdsec_config:\n  lapi_key: {q(lapi_key)}\n  lapi_url: "http://127.0.0.1:8080"\n  update_frequency: 10s\n  include_scenarios_containing: []\n  exclude_scenarios_containing: []\n  only_include_decisions_from: []\n  insecure_skip_verify: false\n  key_path: ""\n  cert_path: ""\n  ca_cert_path: ""\ncloudflare_config:\n  accounts:\n    - id: {q(account_id)}\n      zones:\n        - zone_id: {q(zone_id)}\n          actions:\n            - ban\n          default_action: ban\n          routes_to_protect:\n            - {q(domain + "/*")}\n          turnstile:\n            enabled: false\n            rotate_secret_key: false\n            rotate_secret_key_every: 168h0m0s\n            mode: managed\n      token: {q(token)}\n      account_name: "vaultwarden-oci"\nlog_level: info\nlog_media: "stdout"\nlog_dir: "/var/log/"\nban_template_path: ""\nprometheus:\n  enabled: true\n  listen_addr: 127.0.0.1\n  listen_port: "2112"\n'''


def prepare_remediation(
    *,
    config_path: Path,
    secret_paths: secrets.SecretPaths = secrets.SecretPaths(),
    output: Path = RUNTIME_CONFIG,
    runner: Runner = run_command,
) -> None:
    from .runtime import load_config

    config = load_config(config_path)
    values = secrets.load(
        config.offline_recovery_recipient,
        paths=secret_paths,
        runner=runner,
        uid=0 if output == RUNTIME_CONFIG else os.geteuid(),
    )
    token = values.get("cloudflare_remediation_token")
    if not token:
        raise EdgeError("SOPS secrets require cloudflare_remediation_token for CrowdSec Cloudflare remediation")
    runner(["cscli", "bouncers", "delete", BOUNCER_ID])
    created = runner(["cscli", "-oraw", "bouncers", "add", BOUNCER_ID])
    if not created.ok or not created.stdout.strip() or any(c.isspace() for c in created.stdout.strip()):
        raise EdgeError("cannot create CrowdSec LAPI credential for Cloudflare remediation")
    lapi_key = created.stdout.strip()
    account_id, zone_id = resolve_cloudflare_zone(config.domain, token)
    try:
        _atomic_write(
            output,
            remediation_config_text(
                lapi_key=lapi_key,
                token=token,
                account_id=account_id,
                zone_id=zone_id,
                domain=config.domain,
            ),
            0o600,
        )
    except OSError as exc:
        raise EdgeError(f"cannot materialize CrowdSec Cloudflare remediation config: {exc}") from exc


def _active(service: str, runner: Runner) -> bool:
    return runner(["systemctl", "is-active", "--quiet", service]).ok


def _iptables_healthy(binary: str, runner: Runner) -> bool:
    jump = _rule(binary, RULE_COMMENT, CHAIN)
    return (
        runner([binary, "-w", "-C", "DOCKER-USER", *jump[2:]]).ok
        and runner([binary, "-w", "-n", "-L", CHAIN]).ok
    )


def doctor_checks(
    *,
    paths: EdgePaths = EdgePaths(),
    runner: Runner = run_command,
    now: int | None = None,
) -> list[DoctorCheck]:
    checks: list[DoctorCheck] = []
    try:
        policy = load_lkg(paths.lkg, now=now)
    except EdgeError as exc:
        checks.append(DoctorCheck("edge.cloudflare.cidrs", "FAIL", str(exc)))
    else:
        age = (int(time.time()) if now is None else int(now)) - policy.fetched_at
        checks.append(
            DoctorCheck(
                "edge.cloudflare.cidrs",
                "PASS",
                f"validated Cloudflare last-known-good policy age={max(0, age)}s",
            )
        )
    if _iptables_healthy("iptables", runner) and _iptables_healthy("ip6tables", runner):
        checks.append(DoctorCheck("edge.cloudflare.iptables", "PASS", "Cloudflare-only Docker 443 policy is installed"))
    else:
        checks.append(DoctorCheck("edge.cloudflare.iptables", "FAIL", "Cloudflare-only Docker 443 policy is incomplete"))

    if _active(CROWDSEC_SERVICE, runner):
        checks.append(DoctorCheck("crowdsec.engine", "PASS", "CrowdSec Security Engine is active"))
    else:
        checks.append(DoctorCheck("crowdsec.engine", "FAIL", "CrowdSec Security Engine is not active"))

    config_test = runner([BOUNCER_BINARY, "-c", str(paths.remediation_config), "-t"])
    bouncer = runner(["cscli", "bouncers", "inspect", BOUNCER_ID, "-o", "json"])
    if _active(BOUNCER_SERVICE, runner) and config_test.ok and bouncer.ok:
        checks.append(
            DoctorCheck(
                "crowdsec.cloudflare",
                "PASS",
                "CrowdSec Cloudflare Worker bouncer is active with valid local configuration",
            )
        )
    else:
        checks.append(
            DoctorCheck(
                "crowdsec.cloudflare",
                "FAIL",
                "CrowdSec Cloudflare Worker bouncer configuration/service/LAPI registration is unhealthy",
            )
        )
    return checks
