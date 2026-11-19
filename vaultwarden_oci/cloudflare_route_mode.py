"""Bounded Cloudflare Free Workers Route Fail Open reconciliation.

The Cloudflare API currently accepts/returns request_limit_fail_open, but
the field is not part of the public Workers Routes OpenAPI schema.
This is deliberately opt-in and must never silently assert success.
The existing operator-confirmed path remains supported.
"""
from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Mapping

CLOUDFLARE_API = "https://api.cloudflare.com/client/v4"
BOUNCER_SCRIPT = "crowdsec-cloudflare-worker-bouncer"
MAX_RESPONSE_BYTES = 64 * 1024
ZONE_OR_ROUTE_ID = re.compile(r"[0-9a-f]{32}\Z")
DOMAIN = re.compile(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\Z")


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


# Do not send the remediation bearer token through ambient HTTP(S) proxies
# or along provider redirects. The only approved destination is CF's API.
_ROUTE_OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({}), _NoRedirects()
)


@dataclass(frozen=True)
class RouteProof:
    route_id: str
    pattern: str
    script: str
    invocation_id: str
    changed: bool


def _fail(message: str):
    from .edge import EdgeError

    raise EdgeError(message)


def _api_json(
    url: str, token: str, *, method: str = "GET", body: Mapping[str, object] | None = None
) -> Mapping[str, object]:
    """One bounded Cloudflare REST call. Never expose token or response body."""
    if method not in {"GET", "PUT"} or not url.startswith(CLOUDFLARE_API + "/zones/"):
        _fail("Cloudflare Route API method or destination is not approved")
    if not isinstance(token, str) or not token:
        _fail("Cloudflare remediation credential is missing")
    payload = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=payload,
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "VaultWarden-OCI crowdsec-route-mode",
        },
        method=method,
    )
    try:
        with _ROUTE_OPENER.open(request, timeout=10) as response:
            data = response.read(MAX_RESPONSE_BYTES + 1)
            status = response.status
    except (OSError, urllib.error.HTTPError, urllib.error.URLError) as exc:
        _fail("Cloudflare Worker Route API request failed; manual Fail Open remains required")
    if status != 200 or len(data) > MAX_RESPONSE_BYTES:
        _fail("Cloudflare Worker Route API returned unexpected status or size")
    try:
        document = json.loads(data)
    except (ValueError, UnicodeDecodeError):
        _fail("Cloudflare Worker Route API returned invalid JSON")
    if not isinstance(document, dict) or document.get("success") is not True:
        _fail("Cloudflare Worker Route API rejected the operation; manual Fail Open remains required")
    return document


def _matching_route(candidate: object, pattern: str) -> bool:
    return isinstance(candidate, dict) and candidate.get("pattern") == pattern


def _validate_route(route: object, *, pattern: str, route_id: str | None = None) -> dict:
    if not isinstance(route, dict):
        _fail("Cloudflare Worker Route response is not an object")
    rid = route.get("id")
    if not isinstance(rid, str) or not ZONE_OR_ROUTE_ID.fullmatch(rid):
        _fail("Cloudflare Worker Route ID is malformed")
    if route_id is not None and rid != route_id:
        _fail("Cloudflare Worker Route ID changed during verification")
    if route.get("pattern") != pattern or route.get("script") != BOUNCER_SCRIPT:
        _fail("Cloudflare Route pattern/script differs from the appliance-owned Worker")
    if "request_limit_fail_open" in route and type(route["request_limit_fail_open"]) is not bool:
        _fail("Cloudflare Route Fail Open field has an unexpected type")
    return route


def ensure_fail_open(*, paths=None, runner=None) -> RouteProof:
    """Only change the exact current bouncer Route, and confirm via fresh GET.

    This call is idempotent for already-Fail-Open Routes, yet never marks a
    new invocation confirmed until the actual returned API field is True.
    """
    from . import crowdsec_worker_policy, edge, runtime, secrets

    paths = edge.EdgePaths() if paths is None else paths
    runner = edge.run_command if runner is None else runner
    if os.geteuid() != 0 and paths == edge.EdgePaths():
        _fail("Cloudflare Worker Route mutation must run as root")
    if not edge._active(edge.BOUNCER_SERVICE, runner) or not edge._disabled(edge.BOUNCER_SERVICE, runner):
        _fail("Cloudflare Worker must be active and boot-disabled before Route reconciliation")
    invocation = edge._service_invocation_id(runner)
    if invocation is None or not crowdsec_worker_policy.runtime_policy_healthy(paths, runner):
        _fail("Current Worker invocation lacks a valid local-only decision-source attestation")

    config = runtime.load_config()
    domain = config.domain
    if not isinstance(domain, str) or len(domain) > 253 or not DOMAIN.fullmatch(domain):
        _fail("Configured Cloudflare application hostname is unsafe")
    values = secrets.load(config.offline_recovery_recipient)
    token = values.get("cloudflare_remediation_token")
    if not isinstance(token, str) or not token:
        _fail("Cloudflare remediation token missing from encrypted authority")
    _, zone_id = edge.resolve_cloudflare_zone(domain, token)
    if not isinstance(zone_id, str) or not ZONE_OR_ROUTE_ID.fullmatch(zone_id):
        _fail("Resolved Cloudflare zone ID is invalid")

    pattern = domain + "/*"
    base_url = f"{CLOUDFLARE_API}/zones/{zone_id}/workers/routes"
    # systemd Type=simple can become active before the upstream daemon has
    # finished creating its Cloudflare Route. Poll only read-only inventory;
    # never retry a PUT or silently accept multiple/foreign Route owners.
    selected = None
    for attempt in range(12):
        listed = _api_json(base_url + "?per_page=100", token)
        routes = listed.get("result")
        info = listed.get("result_info")
        if not isinstance(routes, list) or len(routes) >= 100:
            _fail("Cloudflare Worker Route inventory is incomplete or invalid")
        if isinstance(info, dict) and (info.get("total_pages", 1) != 1 or info.get("page", 1) != 1):
            _fail("Cloudflare Worker Route inventory requires pagination; refusing ambiguous update")
        candidates = [r for r in routes if _matching_route(r, pattern)]
        if len(candidates) > 1:
            _fail("Multiple Cloudflare Worker Routes match the configured hostname")
        if len(candidates) == 1:
            selected = _validate_route(candidates[0], pattern=pattern)
            break
        if attempt != 11:
            time.sleep(3)
    if selected is None:
        _fail("CrowdSec Worker Route not created before the bounded readiness deadline")
    route_id = selected["id"]
    route_url = base_url + "/" + route_id

    current = _validate_route(_api_json(route_url, token).get("result"),
                              pattern=pattern, route_id=route_id)
    changed = current.get("request_limit_fail_open") is not True
    if changed:
        # Cloudflare currently accepts this field even though the public
        # OpenAPI route schema does not document it. Never assume PUT worked.
        updated = _api_json(
            route_url, token, method="PUT",
            body={"pattern": pattern, "script": BOUNCER_SCRIPT, "request_limit_fail_open": True},
        )
        _validate_route(updated.get("result"), pattern=pattern, route_id=route_id)

    # Cloudflare can acknowledge the PUT but briefly return the old
    # request_limit_fail_open value on a fresh GET. The API readback
    # is an eventually consistent observation, not a reason to replay a
    # Cloudflare PUT or restart the daemon. Require two distinct GETs with
    # literal true and stable identity before persisting confirmation.
    stable_true = 0
    for attempt in range(12):
        verified = _validate_route(
            _api_json(route_url, token).get("result"),
            pattern=pattern, route_id=route_id,
        )
        stable_true = stable_true + 1 if verified.get("request_limit_fail_open") is True else 0
        if stable_true >= 2:
            break
        if attempt != 11:
            time.sleep(3)
    else:
        _fail("Cloudflare did not independently report Fail Open=true on two consecutive readbacks; operator dashboard confirmation required")

    if (edge._service_invocation_id(runner) != invocation
            or not edge._active(edge.BOUNCER_SERVICE, runner)
            or not edge._disabled(edge.BOUNCER_SERVICE, runner)
            or not crowdsec_worker_policy.runtime_policy_healthy(paths, runner)):
        _fail("Cloudflare Worker invocation or local-only source policy changed during Route update")

    # The existing immutable per-invocation confirmation stays the health gate.
    edge.confirm_fail_open(
        paths=paths, runner=runner,
        verified_route={"id": route_id, "pattern": pattern, "script": BOUNCER_SCRIPT},
    )
    return RouteProof(
        route_id=route_id,
        pattern=pattern,
        script=BOUNCER_SCRIPT,
        invocation_id=invocation,
        changed=changed,
    )


def _owned_route_context() -> tuple[str, str, str]:
    """Host-only Route inventory identity. Token never leaves local memory."""
    from . import edge, runtime, secrets

    cfg = runtime.load_config()
    domain = cfg.domain
    if not isinstance(domain, str) or len(domain) > 253 or not DOMAIN.fullmatch(domain):
        _fail("Configured Cloudflare application hostname is unsafe")
    token = secrets.load(cfg.offline_recovery_recipient).get("cloudflare_remediation_token")
    if not isinstance(token, str) or not token:
        _fail("Cloudflare remediation credential unavailable")
    _, zone = edge.resolve_cloudflare_zone(domain, token)
    if not isinstance(zone, str) or not ZONE_OR_ROUTE_ID.fullmatch(zone):
        _fail("Configured Cloudflare zone identity invalid")
    return domain, token, zone


def _owned_list(base_url: str, token: str) -> list[dict]:
    response = _api_json(base_url + "?per_page=100", token)
    routes = response.get("result")
    info = response.get("result_info")
    if not isinstance(routes, list) or len(routes) >= 100:
        _fail("Cloudflare Worker Route inventory is incomplete or malformed")
    if isinstance(info, dict) and (info.get("total_pages", 1) != 1 or info.get("page", 1) != 1):
        _fail("Cloudflare Worker Route inventory requires pagination")
    if not all(isinstance(route, dict) for route in routes):
        _fail("Cloudflare Worker Route listing contains malformed entries")
    return routes


def read_owned_route_id(*, require_fail_open: bool = True) -> str:
    """Independent read-only exact managed-Route proof before a controlled stop."""
    domain, token, zone = _owned_route_context()
    base = f"{CLOUDFLARE_API}/zones/{zone}/workers/routes"
    pattern = domain + "/*"
    matches = [route for route in _owned_list(base, token) if _matching_route(route, pattern)]
    if len(matches) != 1:
        _fail("Expected exactly one Cloudflare Worker Route before controlled stop")
    selected = _validate_route(matches[0], pattern=pattern)
    actual = _validate_route(
        _api_json(base + "/" + selected["id"], token).get("result"),
        pattern=pattern, route_id=selected["id"],
    )
    if require_fail_open and actual.get("request_limit_fail_open") is not True:
        _fail("Current CrowdSec Route is not independently confirmed Fail Open")
    return selected["id"]


def wait_owned_route_absent(route_id: str) -> None:
    """Bounded read-only cleanup proof. One requested stop, no API mutations."""
    if not isinstance(route_id, str) or not ZONE_OR_ROUTE_ID.fullmatch(route_id):
        _fail("Previous CrowdSec Route identity is invalid")
    domain, token, zone = _owned_route_context()
    base = f"{CLOUDFLARE_API}/zones/{zone}/workers/routes"
    pattern = domain + "/*"
    absent_streak = 0
    for attempt in range(12):
        rows = _owned_list(base, token)
        matches = [
            route for route in rows
            if route.get("id") == route_id or _matching_route(route, pattern)
        ]
        absent_streak = absent_streak + 1 if not matches else 0
        if absent_streak >= 2:
            return
        if attempt != 11:
            time.sleep(3)
    _fail("Previous CrowdSec Route not consistently absent after bounded shutdown cleanup verification")


def wait_owned_route_stable(route_id: str) -> None:
    """Two independent GET/list samples of the exact current route.

    Provider Route listings can briefly lag after daemon creates a Route.
    Poll only GET, never retry a Cloudflare PUT or silently accept another
    Route ID, ownership mismatch, or missing Fail Open field.
    """
    if not isinstance(route_id, str) or not ZONE_OR_ROUTE_ID.fullmatch(route_id):
        _fail("Expected CrowdSec Route identity is invalid")
    domain, token, zone = _owned_route_context()
    base = f"{CLOUDFLARE_API}/zones/{zone}/workers/routes"
    pattern = domain + "/*"
    stable = 0
    for attempt in range(12):
        rows = _owned_list(base, token)
        candidates = [route for route in rows if _matching_route(route, pattern)]
        if len(candidates) > 1:
            _fail("Cloudflare now reports multiple matching Worker Routes")
        if len(candidates) == 1:
            row = _validate_route(candidates[0], pattern=pattern, route_id=route_id)
            detail = _validate_route(
                _api_json(base + "/" + route_id, token).get("result"),
                pattern=pattern, route_id=route_id,
            )
            stable = stable + 1 if (
                row.get("request_limit_fail_open") is True
                and detail.get("request_limit_fail_open") is True
            ) else 0
        else:
            stable = 0
        if stable >= 2:
            return
        if attempt != 11:
            time.sleep(3)
    _fail("Cloudflare Worker Route did not remain uniquely present and Fail Open across two independent checks")
