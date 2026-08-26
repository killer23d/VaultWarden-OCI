"""Cloudflare-only origin ingress and CrowdSec Cloudflare remediation."""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Mapping, Sequence

from .cli import (
    CommandResult,
    LockBusyError,
    ProcessFailure,
    failure_text,
    mutation_lock,
    normalize_architecture,
    require_root,
    run_command,
)
from .storage import ensure_storage_ready

CLOUDFLARE_V4_URL = "https://www.cloudflare.com/ips-v4"
CLOUDFLARE_V6_URL = "https://www.cloudflare.com/ips-v6"
CACHE_PATH = Path("/var/lib/vaultwarden-oci/edge/cloudflare-ranges.json")
EDGE_STATE_PATH = Path("/var/lib/vaultwarden-oci/edge/origin-policy.json")
CROWDSEC_STATE_PATH = Path("/var/lib/vaultwarden-oci/crowdsec/remediation.json")
CROWDSEC_ENV_PATH = Path("/run/vaultwarden-oci/crowdsec-cloudflare.env")
CADDY_LOG_PATH = Path("/var/log/vaultwarden-oci/caddy/access.json")
CROWDSEC_ACQUISITION_PATH = Path("/etc/crowdsec/acquis.d/vaultwarden-oci.yaml")
CROWDSEC_COLLECTION = "crowdsecurity/caddy"
CROWDSEC_BOUNCER_UNIT = "crowdsec-cloudflare-bouncer.service"
PROJECT_CHAIN = "VWOCI-CLOUDFLARE"
CACHE_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
MAX_RANGE_BYTES = 1024 * 1024
MAX_RESPONSE_BYTES = 1024 * 1024
_SUPPORTED_PORT = 443


class EdgeError(RuntimeError):
    pass


@dataclass(frozen=True)
class CloudflareRanges:
    ipv4: tuple[str, ...]
    ipv6: tuple[str, ...]
    fetched_at: int
    source: str

    @property
    def all(self) -> tuple[str, ...]:
        return self.ipv4 + self.ipv6


@dataclass(frozen=True)
class EdgePaths:
    cache: Path = CACHE_PATH
    state: Path = EDGE_STATE_PATH


def _atomic_write(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, raw = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    temporary = Path(raw)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _strict_cidrs(text: str, version: int) -> tuple[str, ...]:
    if len(text.encode()) > MAX_RANGE_BYTES:
        raise EdgeError("Cloudflare range response is too large")
    values: list[str] = []
    for raw in text.splitlines():
        value = raw.strip()
        if not value:
            continue
        try:
            network = ipaddress.ip_network(value, strict=True)
        except ValueError as exc:
            raise EdgeError(f"invalid Cloudflare CIDR: {value}") from exc
        if network.version != version:
            raise EdgeError(f"Cloudflare IPv{version} response contains IPv{network.version} CIDR")
        values.append(str(network))
    if not values:
        raise EdgeError(f"Cloudflare IPv{version} response is empty")
    return tuple(sorted(set(values)))


def _fetch_text(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "VaultWarden-OCI"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            raw = response.read(MAX_RANGE_BYTES + 1)
    except (urllib.error.URLError, TimeoutError, socket.timeout) as exc:
        raise EdgeError(f"Cloudflare range fetch failed: {exc}") from exc
    if len(raw) > MAX_RANGE_BYTES:
        raise EdgeError("Cloudflare range response is too large")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise EdgeError("Cloudflare range response is not valid UTF-8") from exc


def _cache_payload(ranges: CloudflareRanges) -> str:
    return json.dumps(
        {
            "schema_version": 1,
            "fetched_at": ranges.fetched_at,
            "ipv4": list(ranges.ipv4),
            "ipv6": list(ranges.ipv6),
        },
        sort_keys=True,
        separators=(",", ":"),
    ) + "\n"


def _load_cache(path: Path, *, now: int) -> CloudflareRanges:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise EdgeError("Cloudflare cached range policy is missing or invalid") from exc
    if data.get("schema_version") != 1:
        raise EdgeError("Cloudflare cached range policy has unsupported schema")
    fetched_at = data.get("fetched_at")
    if not isinstance(fetched_at, int) or fetched_at <= 0 or fetched_at > now + 300:
        raise EdgeError("Cloudflare cached range timestamp is invalid")
    if now - fetched_at > CACHE_MAX_AGE_SECONDS:
        raise EdgeError("Cloudflare cached range policy is stale")
    try:
        ipv4 = _strict_cidrs("\n".join(data["ipv4"]), 4)
        ipv6 = _strict_cidrs("\n".join(data["ipv6"]), 6)
    except (KeyError, TypeError) as exc:
        raise EdgeError("Cloudflare cached range policy is incomplete") from exc
    return CloudflareRanges(ipv4, ipv6, fetched_at, "cache")


def cloudflare_ranges(
    *,
    paths: EdgePaths = EdgePaths(),
    now: int | None = None,
    fetch: Callable[[str], str] = _fetch_text,
) -> CloudflareRanges:
    current = int(time.time() if now is None else now)
    try:
        ipv4 = _strict_cidrs(fetch(CLOUDFLARE_V4_URL), 4)
        ipv6 = _strict_cidrs(fetch(CLOUDFLARE_V6_URL), 6)
        ranges = CloudflareRanges(ipv4, ipv6, current, "network")
        _atomic_write(paths.cache, _cache_payload(ranges))
        return ranges
    except EdgeError as network_error:
        try:
            return _load_cache(paths.cache, now=current)
        except EdgeError as cache_error:
            raise EdgeError(
                f"no safe Cloudflare range policy is available: {network_error}; {cache_error}"
            ) from network_error


def caddy_trusted_proxies(ranges: CloudflareRanges) -> str:
    quoted = " ".join(ranges.all)
    return f"trusted_proxies static {quoted}"


def caddy_log_config() -> str:
    return f'''log {{
    output file {CADDY_LOG_PATH}
    format json
}}
'''


def _comment_rule(version: int, cidr: str) -> str:
    normalized = str(ipaddress.ip_network(cidr, strict=True))
    family = "v4" if version == 4 else "v6"
    return f"vwoci-cloudflare-{family}-{hashlib.sha256(normalized.encode()).hexdigest()[:16]}"


def _iptables_binary(version: int) -> str:
    return "iptables" if version == 4 else "ip6tables"


def _run(argv: Sequence[str], *, check: bool = True) -> CommandResult:
    result = run_command(argv)
    if check and not result.ok:
        raise EdgeError(failure_text(result, fallback=f"command failed: {' '.join(argv)}"))
    return result


def _ensure_chain(binary: str) -> None:
    if not _run([binary, "-w", "5", "-n", "-L", PROJECT_CHAIN], check=False).ok:
        _run([binary, "-w", "5", "-N", PROJECT_CHAIN])
    _run([binary, "-w", "5", "-F", PROJECT_CHAIN])


def _ensure_jump(binary: str) -> None:
    rule = [
        binary,
        "-w",
        "5",
        "-C",
        "DOCKER-USER",
        "-m",
        "conntrack",
        "--ctstate",
        "NEW",
        "-p",
        "tcp",
        "--dport",
        str(_SUPPORTED_PORT),
        "-j",
        PROJECT_CHAIN,
    ]
    if _run(rule, check=False).ok:
        return
    insert = rule.copy()
    insert[3] = "-I"
    _run(insert)


def _render_family(version: int, cidrs: Iterable[str]) -> None:
    binary = _iptables_binary(version)
    _ensure_chain(binary)
    for cidr in cidrs:
        _run(
            [
                binary,
                "-w",
                "5",
                "-A",
                PROJECT_CHAIN,
                "-p",
                "tcp",
                "--dport",
                str(_SUPPORTED_PORT),
                "-s",
                cidr,
                "-m",
                "comment",
                "--comment",
                _comment_rule(version, cidr),
                "-j",
                "ACCEPT",
            ]
        )
    _run(
        [
            binary,
            "-w",
            "5",
            "-A",
            PROJECT_CHAIN,
            "-p",
            "tcp",
            "--dport",
            str(_SUPPORTED_PORT),
            "-j",
            "DROP",
        ]
    )
    _ensure_jump(binary)


def _state_payload(ranges: CloudflareRanges) -> str:
    return json.dumps(
        {
            "schema_version": 1,
            "applied_at": int(time.time()),
            "source": ranges.source,
            "fetched_at": ranges.fetched_at,
            "ipv4": list(ranges.ipv4),
            "ipv6": list(ranges.ipv6),
        },
        sort_keys=True,
        separators=(",", ":"),
    ) + "\n"


def refresh_origin_policy(*, paths: EdgePaths = EdgePaths()) -> CloudflareRanges:
    require_root()
    _render_family(4, ())
    _render_family(6, ())
    ranges = cloudflare_ranges(paths=paths)
    _render_family(4, ranges.ipv4)
    _render_family(6, ranges.ipv6)
    _atomic_write(paths.state, _state_payload(ranges))
    return ranges


def _chain_lines(binary: str) -> list[str]:
    result = _run([binary, "-w", "5", "-S", PROJECT_CHAIN], check=False)
    return result.stdout.splitlines() if result.ok else []


def _jump_lines(binary: str) -> list[str]:
    result = _run([binary, "-w", "5", "-S", "DOCKER-USER"], check=False)
    return result.stdout.splitlines() if result.ok else []


def doctor_origin_policy(*, paths: EdgePaths = EdgePaths()) -> tuple[bool, str]:
    try:
        _load_cache(paths.cache, now=int(time.time()))
    except EdgeError as exc:
        return False, str(exc)
    for version in (4, 6):
        binary = _iptables_binary(version)
        chain = _chain_lines(binary)
        jumps = _jump_lines(binary)
        if not chain:
            return False, f"{PROJECT_CHAIN} is missing from {binary}"
        if not chain[-1].endswith(f"-p tcp --dport {_SUPPORTED_PORT} -j DROP"):
            return False, f"{PROJECT_CHAIN} does not fail closed for IPv{version}"
        if not any(
            "-m conntrack --ctstate NEW" in line
            and f"-p tcp --dport {_SUPPORTED_PORT}" in line
            and f"-j {PROJECT_CHAIN}" in line
            for line in jumps
        ):
            return False, f"DOCKER-USER jump is missing for IPv{version}"
    return True, "Cloudflare-only origin policy is present and fail closed"


def crowdsec_acquisition() -> str:
    return f'''filenames:
  - {CADDY_LOG_PATH}
labels:
  type: caddy
'''


def _crowdsec_env(token: str, zone_id: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_-]{20,200}", token):
        raise EdgeError("Cloudflare API token format is invalid")
    if not re.fullmatch(r"[0-9a-fA-F]{32}", zone_id):
        raise EdgeError("Cloudflare zone ID format is invalid")
    return f"CLOUDFLARE_API_TOKEN={token}\nCLOUDFLARE_ZONE_ID={zone_id}\n"


def prepare_crowdsec_remediation(*, token: str, zone_id: str) -> None:
    require_root()
    _atomic_write(CROWDSEC_ENV_PATH, _crowdsec_env(token, zone_id))
    CROWDSEC_ACQUISITION_PATH.parent.mkdir(parents=True, exist_ok=True)
    _atomic_write(CROWDSEC_ACQUISITION_PATH, crowdsec_acquisition(), mode=0o644)


def _cloudflare_json(url: str, token: str) -> Mapping[str, object]:
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "User-Agent": "VaultWarden-OCI crowdsec-cloudflare",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
    except (urllib.error.URLError, TimeoutError, socket.timeout) as exc:
        raise EdgeError(f"Cloudflare API request failed: {exc}") from exc
    if len(raw) > MAX_RESPONSE_BYTES:
        raise EdgeError("Cloudflare API response is too large")
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise EdgeError("Cloudflare API response is invalid") from exc
    if not isinstance(data, dict):
        raise EdgeError("Cloudflare API response is not an object")
    return data


def crowdsec_status() -> Mapping[str, object]:
    engine = _run(["systemctl", "is-active", "crowdsec"], check=False)
    bouncer = _run(["systemctl", "is-active", CROWDSEC_BOUNCER_UNIT], check=False)
    return {
        "engine_active": engine.ok and engine.stdout.strip() == "active",
        "bouncer_active": bouncer.ok and bouncer.stdout.strip() == "active",
    }


def crowdsec_decisions() -> list[Mapping[str, object]]:
    result = _run(["cscli", "decisions", "list", "-o", "json"], check=False)
    if not result.ok:
        raise EdgeError(failure_text(result, fallback="CrowdSec decisions query failed"))
    try:
        data = json.loads(result.stdout or "[]")
    except json.JSONDecodeError as exc:
        raise EdgeError("CrowdSec decisions output is invalid JSON") from exc
    if not isinstance(data, list):
        raise EdgeError("CrowdSec decisions output is not a list")
    return [item for item in data if isinstance(item, dict)]


def crowdsec_unban(ip: str) -> None:
    try:
        normalized = str(ipaddress.ip_address(ip))
    except ValueError as exc:
        raise EdgeError("invalid IP address") from exc
    result = _run(["cscli", "decisions", "delete", "--ip", normalized], check=False)
    if not result.ok:
        raise EdgeError(failure_text(result, fallback=f"failed to remove CrowdSec decision for {normalized}"))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="VaultWarden-OCI edge and CrowdSec owner")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("refresh")
    sub.add_parser("doctor")
    sub.add_parser("crowdsec-status")
    sub.add_parser("crowdsec-decisions")
    unban = sub.add_parser("crowdsec-unban")
    unban.add_argument("ip")
    args = parser.parse_args(argv)
    try:
        if args.command == "refresh":
            ranges = refresh_origin_policy()
            print(f"PASS: Cloudflare origin policy applied from {ranges.source}")
        elif args.command == "doctor":
            ok, message = doctor_origin_policy()
            print(("PASS: " if ok else "FAIL: ") + message)
            return 0 if ok else 1
        elif args.command == "crowdsec-status":
            print(json.dumps(crowdsec_status(), sort_keys=True))
        elif args.command == "crowdsec-decisions":
            print(json.dumps(crowdsec_decisions(), sort_keys=True))
        elif args.command == "crowdsec-unban":
            crowdsec_unban(args.ip)
            print(f"PASS: removed CrowdSec decisions for {args.ip}")
        return 0
    except (EdgeError, ProcessFailure, LockBusyError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
