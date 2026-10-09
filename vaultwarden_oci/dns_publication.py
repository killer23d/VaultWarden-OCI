"""Cloudflare proxied-A DNS publication for the configured Vaultwarden hostname."""
from __future__ import annotations

import ipaddress
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Callable, Mapping

from . import cli, durability, edge, runtime, secrets

_MAX_RESPONSE_BYTES = 64 * 1024
_HTTP_ATTEMPTS = 3
_HTTP_TIMEOUT_SECONDS = 8
_HTTP_RETRY_DELAYS = (1, 2)
_TRANSIENT_FAILURE_THRESHOLD = 3
TIMER_STATE_PATH = runtime.STATE / "state/dns-sync.json"
_PUBLIC_IPV4_ENDPOINTS = (
    "https://www.cloudflare.com/cdn-cgi/trace",
    "https://checkip.amazonaws.com",
    "https://api4.ipify.org",
)

TextFetcher = Callable[[str, int], str]
Requester = Callable[[urllib.request.Request, int], bytes]


class DNSError(RuntimeError):
    """Raised when public DNS state cannot be safely inspected or synchronized."""


class DNSTransientError(DNSError):
    """Raised for bounded external-network failures that may recover without operator action."""


@dataclass(frozen=True)
class DNSState:
    domain: str
    public_ipv4: str
    record_ipv4: str
    proxied: bool
    record_id: str

    @property
    def in_sync(self) -> bool:
        return self.proxied and self.record_ipv4 == self.public_ipv4


@dataclass(frozen=True)
class DNSUpdateResult:
    before: DNSState
    after: DNSState
    changed: bool
    applied: bool


@dataclass(frozen=True)
class DNSTimerResult:
    update: DNSUpdateResult | None
    consecutive_transient_failures: int
    transient_error: str | None


def _transient_http_status(code: int) -> bool:
    return code in {408, 425, 429} or 500 <= code <= 599


def _read_url(request: urllib.request.Request, maximum: int) -> bytes:
    last_error: BaseException | None = None
    for attempt in range(_HTTP_ATTEMPTS):
        try:
            with urllib.request.urlopen(request, timeout=_HTTP_TIMEOUT_SECONDS) as response:
                data = response.read(maximum + 1)
        except urllib.error.HTTPError as exc:
            if not _transient_http_status(exc.code):
                raise DNSError(f"HTTPS request rejected with HTTP {exc.code}") from exc
            last_error = exc
        except (OSError, urllib.error.URLError) as exc:
            last_error = exc
        else:
            if len(data) > maximum:
                raise DNSError("HTTPS response exceeds the bounded response size")
            return data
        if attempt < _HTTP_ATTEMPTS - 1:
            time.sleep(_HTTP_RETRY_DELAYS[attempt])
    raise DNSTransientError(
        f"HTTPS request failed after {_HTTP_ATTEMPTS} attempts"
    ) from last_error


def _http_text(url: str, maximum: int = _MAX_RESPONSE_BYTES) -> str:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "VaultWarden-OCI dns-publication"},
        method="GET",
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=_HTTP_TIMEOUT_SECONDS) as response:
            data = response.read(maximum + 1)
    except (OSError, urllib.error.URLError) as exc:
        raise DNSTransientError("public IPv4 discovery request failed") from exc
    if len(data) > maximum:
        raise DNSError("public IPv4 discovery response exceeds the bounded response size")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise DNSError("public IPv4 discovery response is not UTF-8") from exc


def _parse_public_ipv4(url: str, text: str) -> str | None:
    candidate = ""
    if url.endswith("/cdn-cgi/trace"):
        for line in text.splitlines():
            if line.startswith("ip="):
                candidate = line[3:].strip()
                break
    else:
        candidate = text.strip()
    if not candidate or any(char.isspace() for char in candidate):
        return None
    try:
        address = ipaddress.ip_address(candidate)
    except ValueError:
        return None
    if address.version != 4 or not address.is_global:
        return None
    return str(address)


def discover_public_ipv4(*, fetcher: TextFetcher = _http_text) -> str:
    """Return the first validated public IPv4 from a bounded HTTPS fallback set."""
    for url in _PUBLIC_IPV4_ENDPOINTS:
        try:
            value = _parse_public_ipv4(url, fetcher(url, _MAX_RESPONSE_BYTES))
        except (DNSError, OSError):
            continue
        if value is not None:
            return value
    raise DNSTransientError("cannot determine this host's globally routable public IPv4")


def _api_request(
    token: str,
    method: str,
    path: str,
    *,
    query: Mapping[str, str] | None = None,
    payload: Mapping[str, object] | None = None,
    requester: Requester = _read_url,
) -> object:
    url = edge.CLOUDFLARE_API + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    body = None if payload is None else json.dumps(dict(payload), separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "VaultWarden-OCI dns-publication",
        },
    )
    try:
        raw = requester(request, _MAX_RESPONSE_BYTES)
        response = json.loads(raw)
    except DNSError:
        raise
    except json.JSONDecodeError as exc:
        raise DNSTransientError("Cloudflare DNS API returned invalid JSON") from exc
    except OSError as exc:
        raise DNSError("Cloudflare DNS API request failed") from exc
    if not isinstance(response, dict) or response.get("success") is not True:
        errors = response.get("errors") if isinstance(response, dict) else None
        codes = []
        if isinstance(errors, list):
            codes = [
                str(item.get("code"))
                for item in errors
                if isinstance(item, dict) and isinstance(item.get("code"), int)
            ]
        suffix = f" (codes={','.join(codes)})" if codes else ""
        raise DNSError("Cloudflare DNS API returned failure" + suffix)
    return response.get("result")


def _records(
    *,
    token: str,
    zone_id: str,
    domain: str,
    record_type: str,
    requester: Requester,
) -> list[dict[str, object]]:
    result = _api_request(
        token,
        "GET",
        f"/zones/{zone_id}/dns_records",
        query={"type": record_type, "name": domain, "per_page": "100"},
        requester=requester,
    )
    if not isinstance(result, list) or not all(isinstance(item, dict) for item in result):
        raise DNSError(f"Cloudflare returned an invalid {record_type} record list")
    return result


def inspect_state(
    *,
    domain: str,
    public_ipv4: str,
    token: str,
    zone_id: str,
    requester: Requester = _read_url,
) -> DNSState:
    """Inspect the one supported DNS shape: exactly one proxied IPv4 A and no AAAA."""
    aaaa = _records(
        token=token,
        zone_id=zone_id,
        domain=domain,
        record_type="AAAA",
        requester=requester,
    )
    if aaaa:
        raise DNSError(
            f"{domain} has {len(aaaa)} explicit AAAA record(s); "
            "IPv6 publication is not owned by this command"
        )

    records = _records(
        token=token,
        zone_id=zone_id,
        domain=domain,
        record_type="A",
        requester=requester,
    )
    if len(records) != 1:
        raise DNSError(
            f"expected exactly one existing Cloudflare A record for {domain}; found {len(records)}"
        )
    record = records[0]
    record_id = record.get("id")
    name = record.get("name")
    record_type = record.get("type")
    content = record.get("content")
    proxied = record.get("proxied")

    if not isinstance(record_id, str) or not record_id:
        raise DNSError("Cloudflare A record has no record ID")
    if name != domain or record_type != "A":
        raise DNSError("Cloudflare returned a DNS record outside the requested hostname/type")
    if not isinstance(content, str):
        raise DNSError("Cloudflare A record content is invalid")
    try:
        address = ipaddress.ip_address(content)
    except ValueError as exc:
        raise DNSError("Cloudflare A record content is not an IPv4 address") from exc
    if address.version != 4 or not address.is_global:
        raise DNSError("Cloudflare A record content is not a globally routable IPv4 address")
    if not isinstance(proxied, bool):
        raise DNSError("Cloudflare A record proxy state is invalid")

    return DNSState(
        domain=domain,
        public_ipv4=public_ipv4,
        record_ipv4=str(address),
        proxied=proxied,
        record_id=record_id,
    )


def _context(
    *,
    fetcher: TextFetcher,
) -> tuple[str, str, str, str]:
    if os.geteuid() != 0:
        raise DNSError("vwctl dns must run as root")
    config = runtime.load_config()
    values = secrets.load(config.offline_recovery_recipient)
    token = values.get("cloudflare_api_token")
    if not token:
        raise DNSError("cloudflare_api_token is absent from the encrypted secret authority")
    try:
        _, zone_id = edge.resolve_cloudflare_zone(config.domain, token)
    except edge.EdgeError as exc:
        detail = str(exc)
        if detail in {"Cloudflare API request failed", "Cloudflare API returned invalid JSON"}:
            raise DNSTransientError(detail) from exc
        raise DNSError(detail) from exc
    public_ipv4 = discover_public_ipv4(fetcher=fetcher)
    return config.domain, public_ipv4, token, zone_id


def status(
    *,
    fetcher: TextFetcher = _http_text,
    requester: Requester = _read_url,
) -> DNSState:
    domain, public_ipv4, token, zone_id = _context(fetcher=fetcher)
    return inspect_state(
        domain=domain,
        public_ipv4=public_ipv4,
        token=token,
        zone_id=zone_id,
        requester=requester,
    )


def update(
    *,
    dry_run: bool = False,
    fetcher: TextFetcher = _http_text,
    requester: Requester = _read_url,
) -> DNSUpdateResult:
    """Synchronize only the content of the existing proxied A record."""
    with cli.mutation_lock(runtime.LOCK):
        domain, public_ipv4, token, zone_id = _context(fetcher=fetcher)
        before = inspect_state(
            domain=domain,
            public_ipv4=public_ipv4,
            token=token,
            zone_id=zone_id,
            requester=requester,
        )
        if not before.proxied:
            raise DNSError(
                f"{domain} A record is DNS-only; set it to Proxied in Cloudflare before DNS automation"
            )
        if before.in_sync:
            return DNSUpdateResult(before=before, after=before, changed=False, applied=False)
        if dry_run:
            return DNSUpdateResult(before=before, after=before, changed=True, applied=False)

        result = _api_request(
            token,
            "PATCH",
            f"/zones/{zone_id}/dns_records/{before.record_id}",
            payload={"content": public_ipv4},
            requester=requester,
        )
        if not isinstance(result, dict):
            raise DNSError("Cloudflare DNS update returned an invalid record")
        if (
            result.get("id") != before.record_id
            or result.get("name") != domain
            or result.get("type") != "A"
            or result.get("content") != public_ipv4
            or result.get("proxied") is not True
        ):
            raise DNSError("Cloudflare DNS update response did not preserve the expected record boundary")

        after = inspect_state(
            domain=domain,
            public_ipv4=public_ipv4,
            token=token,
            zone_id=zone_id,
            requester=requester,
        )
        if not after.in_sync or after.record_id != before.record_id:
            raise DNSError("Cloudflare DNS authoritative read-back does not match the requested public IPv4")
        return DNSUpdateResult(before=before, after=after, changed=True, applied=True)


def _load_timer_failure_count(path: Path) -> int:
    if not (path.exists() or path.is_symlink()):
        return 0
    if path.is_symlink() or not path.is_file():
        raise DNSError(f"DNS timer state path is unsafe: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise DNSError("DNS timer state is unreadable") from exc
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise DNSError("DNS timer state schema is invalid")
    count = payload.get("consecutive_transient_failures")
    if not isinstance(count, int) or isinstance(count, bool) or count < 1:
        raise DNSError("DNS timer state failure count is invalid")
    return count


def _write_timer_failure_count(path: Path, count: int) -> None:
    payload = {"schema_version": 1, "consecutive_transient_failures": count}
    durability.atomic_write(
        path,
        (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"),
        0o600,
    )


def _clear_timer_failure_count(path: Path) -> None:
    if path.is_symlink():
        raise DNSError(f"DNS timer state path is unsafe: {path}")
    if path.exists():
        if not path.is_file():
            raise DNSError(f"DNS timer state path is unsafe: {path}")
        durability.unlink(path)


def update_for_timer(
    *,
    state_path: Path | None = None,
    updater: Callable[..., DNSUpdateResult] = update,
) -> DNSTimerResult:
    """Run timer DNS sync with consecutive transient-failure debouncing."""
    state_path = TIMER_STATE_PATH if state_path is None else state_path
    try:
        result = updater()
    except cli.LockBusyError:
        raise
    except DNSTransientError as exc:
        count = _load_timer_failure_count(state_path) + 1
        _write_timer_failure_count(state_path, count)
        if count < _TRANSIENT_FAILURE_THRESHOLD:
            return DNSTimerResult(None, count, str(exc))
        raise DNSTransientError(
            f"{exc}; consecutive timer failures={count} "
            f"(notification threshold={_TRANSIENT_FAILURE_THRESHOLD})"
        ) from exc
    except DNSError:
        _clear_timer_failure_count(state_path)
        raise
    else:
        _clear_timer_failure_count(state_path)
        return DNSTimerResult(result, 0, None)
