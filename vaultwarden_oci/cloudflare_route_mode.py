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
    listed = _api_json(base_url + "?per_page=100", token)
    routes = listed.get("result")
    info = listed.get("result_info")
    if not isinstance(routes, list) or len(routes) >= 100:
        _fail("Cloudflare Worker Route inventory is incomplete or invalid")
    if isinstance(info, dict) and (info.get("total_pages", 1) != 1 or info.get("page", 1) != 1):
        _fail("Cloudflare Worker Route inventory requires pagination; refusing ambiguous update")
    candidates = [r for r in routes if _matching_route(r, pattern)]
    if len(candidates) != 1:
        _fail("Expected exactly one Cloudflare Worker Route for the configured hostname")
    selected = _validate_route(candidates[0], pattern=pattern)
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

    verified = _validate_route(_api_json(route_url, token).get("result"),
                               pattern=pattern, route_id=route_id)
    if verified.get("request_limit_fail_open") is not True:
        _fail("Cloudflare did not independently report Fail Open=true; operator dashboard confirmation required")

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
