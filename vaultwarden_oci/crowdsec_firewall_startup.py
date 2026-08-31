"""Bounded startup proof for the CrowdSec host-INPUT firewall bouncer."""
from __future__ import annotations

import json
import time
from typing import Callable, Literal, Sequence

from .cli import CommandResult

FIREWALL_LIVE_SETTLE_SECONDS = 10.0
FIREWALL_LIVE_POLL_SECONDS = 0.25

Runner = Callable[..., CommandResult]
Sleeper = Callable[[float], None]
Clock = Callable[[], float]
State = Literal["pending", "ready", "unsafe"]


class FirewallStartupError(RuntimeError):
    """Raised when live firewall ownership cannot safely settle to INPUT-only."""


def _missing_table(result: CommandResult) -> bool:
    detail = (result.stdout + "\n" + result.stderr).lower()
    return any(
        marker in detail
        for marker in (
            "no such file or directory",
            "no such file",
            "does not exist",
        )
    )


def _family_state(
    runner: Runner,
    *,
    family: str,
    table: str,
    chain_base: str,
) -> tuple[State, str]:
    result = runner(["nft", "--json", "list", "table", family, table])
    if not result.ok:
        if _missing_table(result):
            return "pending", f"{family} table {table} is not materialized yet"
        return "unsafe", f"cannot inspect live {family} table {table}"

    try:
        payload = json.loads(result.stdout)
    except (json.JSONDecodeError, TypeError):
        return "unsafe", f"live {family} table {table} returned invalid JSON"
    entries = payload.get("nftables") if isinstance(payload, dict) else None
    if not isinstance(entries, list):
        return "unsafe", f"live {family} table {table} has an invalid nftables payload"

    hooked: list[tuple[str, str]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        chain = entry.get("chain")
        if not isinstance(chain, dict):
            continue
        if chain.get("family") != family or chain.get("table") != table:
            continue
        hook = chain.get("hook")
        if hook is None:
            continue
        name = chain.get("name")
        if not isinstance(name, str) or not isinstance(hook, str):
            return "unsafe", f"live {family} table {table} has a malformed hooked chain"
        hooked.append((name, hook))

    expected = [(f"{chain_base}-input", "input")]
    if not hooked:
        return "pending", f"{family} INPUT hook is not materialized yet"
    if sorted(hooked) == expected:
        return "ready", f"{family} INPUT hook is ready"
    rendered = ", ".join(f"{name}:{hook}" for name, hook in sorted(hooked))
    return "unsafe", f"unexpected live {family} CrowdSec hook ownership: {rendered}"


def wait_for_input_only(
    runner: Runner,
    *,
    service: str,
    config_input_only: Callable[[], bool],
    timeout: float = FIREWALL_LIVE_SETTLE_SECONDS,
    poll: float = FIREWALL_LIVE_POLL_SECONDS,
    sleeper: Sleeper = time.sleep,
    clock: Clock = time.monotonic,
) -> None:
    """Wait only for safe INPUT-only nftables materialization after service start.

    A missing table/chain may be a normal Type=simple startup window. Any
    unexpected live hook, malformed nftables state, effective-config drift, or
    service exit is not transient and fails immediately.
    """
    if timeout < 0 or poll <= 0:
        raise ValueError("invalid firewall startup settle bounds")
    deadline = clock() + timeout
    pending: Sequence[str] = ()

    while True:
        if not runner(["systemctl", "is-active", "--quiet", service]).ok:
            raise FirewallStartupError(
                "CrowdSec firewall bouncer exited before INPUT-only nftables ownership was established"
            )
        if not config_input_only():
            raise FirewallStartupError(
                "CrowdSec firewall bouncer effective configuration stopped being exactly INPUT-only during startup"
            )

        ipv4_state, ipv4_detail = _family_state(
            runner,
            family="ip",
            table="crowdsec",
            chain_base="crowdsec-chain",
        )
        ipv6_state, ipv6_detail = _family_state(
            runner,
            family="ip6",
            table="crowdsec6",
            chain_base="crowdsec6-chain",
        )
        for state, detail in (
            (ipv4_state, ipv4_detail),
            (ipv6_state, ipv6_detail),
        ):
            if state == "unsafe":
                raise FirewallStartupError(detail)
        if ipv4_state == "ready" and ipv6_state == "ready":
            return

        pending = tuple(
            detail
            for state, detail in (
                (ipv4_state, ipv4_detail),
                (ipv6_state, ipv6_detail),
            )
            if state == "pending"
        )
        now = clock()
        if now >= deadline:
            detail = "; ".join(pending) or "live nftables ownership is incomplete"
            raise FirewallStartupError(
                "CrowdSec firewall bouncer did not materialize exact host INPUT ownership "
                f"within {timeout:g}s: {detail}"
            )
        sleeper(min(poll, deadline - now))
