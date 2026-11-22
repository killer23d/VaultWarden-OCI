#!/usr/bin/env python3
"""Bounded, read-only Caddy HTTPS readiness after an authorized first start.

Use the exact configured hostname with loopback resolution and system CA
verification. This is an acceptance probe, not a lifecycle or repair action.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import time
from dataclasses import dataclass
from typing import Callable

_ENDPOINTS = (("/", "200"), ("/api/config", "200"), ("/admin/", "401"))
_PENDING_CURL_EXITS = frozenset({7, 28, 35, 52, 56, 60})
_HOSTNAME = re.compile(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\Z")


@dataclass(frozen=True)
class Result:
    outcome: str
    reason: str
    attempts: int


def validate_hostname(hostname: str) -> str:
    if len(hostname) > 253 or not _HOSTNAME.fullmatch(hostname):
        raise ValueError("expected a lowercase DNS hostname, not a URL or shell expression")
    return hostname


def _probe_once(hostname: str, runner: Callable[..., subprocess.CompletedProcess[str]]) -> tuple[str, str]:
    for path, expected in _ENDPOINTS:
        argv = [
            "curl", "-q", "--noproxy", "*", "--proto", "=https",
            "--resolve", f"{hostname}:443:127.0.0.1",
            "--silent", "--output", "/dev/null", "--write-out", "%{http_code}",
            "--connect-timeout", "4", "--max-time", "12",
            f"https://{hostname}{path}",
        ]
        try:
            response = runner(
                argv, stdin=subprocess.DEVNULL, capture_output=True,
                text=True, check=False, timeout=15,
            )
        except subprocess.TimeoutExpired:
            return "pending", "TLS_CONNECTION_TIMEOUT"
        except OSError:
            return "hold", "CURL_UNAVAILABLE"
        if response.returncode:
            if response.returncode in _PENDING_CURL_EXITS:
                return "pending", f"HTTPS_NOT_READY_CURL_{response.returncode}"
            return "hold", f"UNEXPECTED_CURL_EXIT_{response.returncode}"
        actual = response.stdout.strip()
        if actual != expected:
            return "hold", f"UNEXPECTED_HTTP_STATUS_{path}_{actual[:3]}"
    return "pass", "HTTPS_ENDPOINTS_VERIFIED"


def wait_for_https(
    hostname: str, *, timeout_seconds: int = 180, interval_seconds: int = 5,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    clock: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
) -> Result:
    hostname = validate_hostname(hostname)
    if not 1 <= timeout_seconds <= 600 or not 1 <= interval_seconds <= 30:
        raise ValueError("timeout must be 1-600 seconds and poll interval 1-30 seconds")
    deadline = clock() + timeout_seconds
    attempts = 0
    while True:
        attempts += 1
        outcome, reason = _probe_once(hostname, runner)
        if outcome != "pending":
            return Result(outcome, reason, attempts)
        remaining = deadline - clock()
        if remaining <= 0:
            return Result("hold", f"TIMEOUT_LAST_{reason}", attempts)
        sleeper(min(interval_seconds, remaining))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hostname", required=True, help="configured site hostname (not a URL)")
    parser.add_argument("--timeout-seconds", type=int, default=180)
    parser.add_argument("--interval-seconds", type=int, default=5)
    args = parser.parse_args()
    try:
        result = wait_for_https(
            args.hostname, timeout_seconds=args.timeout_seconds,
            interval_seconds=args.interval_seconds,
        )
    except ValueError as exc:
        parser.error(str(exc))
    if result.outcome != "pass":
        print(f"HOLD: Verified HTTPS readiness unproven ({result.reason}); attempts={result.attempts}")
        print("HTTPS_READINESS_EXIT=2")
        return 2
    for path, status in _ENDPOINTS:
        print(f"PASS: Verified loopback HTTPS {path} -> {status}")
    print(f"HTTPS_READINESS_EXIT=0 attempts={result.attempts}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
