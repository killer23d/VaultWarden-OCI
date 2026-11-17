#!/usr/bin/env python3
"""P8V-D public DNS proposal-only preflight. No provider credentials or writes.

Public DNS is a clue, NOT proof of Cloudflare zone ownership, absent
wildcards, Worker routes, custom domains, or ownership of an original VM.
Only hard-coded HTTPS GET DNS-over-HTTPS resolvers are accessed; response
bodies and network identifiers are never printed or saved.
"""
from __future__ import annotations

from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True
os.umask(0o077)

ROOT = Path(__file__).resolve().parents[2]
BASE = Path(__file__).with_name("production-p8v-precanary-readonly.py")
DOH_URLS = {
    "cloudflare": "https://cloudflare-dns.com/dns-query",
    "google": "https://dns.google/resolve",
}
TYPES = {"A": 1, "AAAA": 28, "CNAME": 5, "NS": 2}
MAX_DNS_BYTES = 16384


def load_gate():
    spec = importlib.util.spec_from_file_location("p8v_c_checked", BASE)
    if spec is None or spec.loader is None:
        raise ValueError("source-guard-missing")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def dns_result(doc: object, name: str, kind: str) -> str:
    """Only validate an explicitly complete single-question JSON DoH result."""
    if not isinstance(doc, dict):
        return "UNAVAILABLE"
    status, truncated = doc.get("Status"), doc.get("TC")
    if type(status) is not int or status not in (0, 3) or truncated is not False:
        return "UNAVAILABLE"
    question = doc.get("Question")
    if not isinstance(question, list) or len(question) != 1:
        return "UNAVAILABLE"
    query = question[0]
    if (not isinstance(query, dict)
            or query.get("name") != name + "."
            or type(query.get("type")) is not int
            or query["type"] != TYPES[kind]):
        return "UNAVAILABLE"
    answers = doc.get("Answer", [])
    if not isinstance(answers, list):
        return "UNAVAILABLE"
    for item in answers:
        if (not isinstance(item, dict)
                or not isinstance(item.get("name"), str)
                or type(item.get("type")) is not int
                or not isinstance(item.get("data"), str)):
            return "UNAVAILABLE"
    if status == 3:
        return "ABSENT" if len(answers) == 0 else "UNAVAILABLE"
    return "ANSWER" if answers else "ABSENT"


def fetch_dns(resolver: str, name: str, kind: str) -> str:
    if resolver not in DOH_URLS or kind not in TYPES:
        return "UNAVAILABLE"
    url = DOH_URLS[resolver] + "?" + urllib.parse.urlencode({
        "name": name, "type": kind,
    })
    request = urllib.request.Request(
        url, headers={"Accept": "application/dns-json", "User-Agent": "vwoci-p8vd-precanary-readonly"},
        method="GET",
    )
    try:
        opener = urllib.request.build_opener(NoRedirect())
        with opener.open(request, timeout=6) as response:
            if response.status != 200:
                return "UNAVAILABLE"
            raw = response.read(MAX_DNS_BYTES + 1)
            if not raw or len(raw) > MAX_DNS_BYTES:
                return "UNAVAILABLE"
        doc = json.loads(raw)
        return dns_result(doc, name, kind)
    except (OSError, urllib.error.URLError, urllib.error.HTTPError,
            TimeoutError, UnicodeError, json.JSONDecodeError, ValueError):
        return "UNAVAILABLE"


def combine(group: list[str], label: str) -> tuple[str, str]:
    """Never claim provider-zone absence from recursive public DNS alone."""
    if any(v == "ANSWER" for v in group):
        return "PENDING", label + "-public-answer-manual-review"
    if any(v not in ("ANSWER", "ABSENT", "UNAVAILABLE") for v in group):
        return "PENDING", label + "-invalid-probe-evidence"
    if any(v == "UNAVAILABLE" for v in group):
        return "PENDING", label + "-resolver-unavailable"
    if not group or len(group) != 6:
        return "PENDING", label + "-query-coverage-incomplete"
    return "PASS", label + "-no-visible-public-dns-answer-only"


def survey(gate, zone: str, fqdn: str,
           fetcher=fetch_dns) -> list[tuple[str, str]]:
    rows: list[tuple[str, str]] = []
    status, reason = gate.fqdn_status(zone, fqdn)
    gate.add(rows, status, reason)
    if status != "PASS":
        return rows

    # Probe a deterministic non-existent name of the SAME suffix. A public
    # wildcard response is a review flag; a negative answer is NOT proof
    # the provider account is free of unlisted DNS/Worker mappings.
    wildcard = "p8vd-probe-" + hashlib.sha256(fqdn.encode()).hexdigest()[:14] + "." + zone
    queries = [
        (resolver, subject, kind, label)
        for label, subject in (("candidate", fqdn), ("wildcard-probe", wildcard))
        for resolver in ("cloudflare", "google")
        for kind in ("A", "AAAA", "CNAME")
    ]
    queries.extend(
        (resolver, zone, "NS", "zone-ns")
        for resolver in ("cloudflare", "google")
    )

    def run(record):
        resolver, name, kind, label = record
        try:
            found = fetcher(resolver, name, kind)
        except Exception:
            found = "UNAVAILABLE"
        return label, found

    observed: dict[str, list[str]] = {"candidate": [], "wildcard-probe": [], "zone-ns": []}
    with ThreadPoolExecutor(max_workers=6) as pool:
        for label, outcome in pool.map(run, queries):
            observed[label].append(outcome)

    for group in ("candidate", "wildcard-probe"):
        gate.add(rows, *combine(observed[group], group))
    ns = observed["zone-ns"]
    if len(ns) == 2 and all(item == "ANSWER" for item in ns):
        gate.add(rows, "PASS", "zone-public-ns-answers-observed-only")
    else:
        gate.add(rows, "PENDING", "zone-public-ns-incomplete-or-unavailable")
    gate.add(rows, "PENDING", "cloudflare-account-zone-and-dns-dashboard-unverified")
    gate.add(rows, "PENDING", "cloudflare-worker-routes-and-custom-domains-dashboard-unverified")
    gate.add(rows, "PENDING", "blank-test-data-backup-credentials-unverified")
    gate.add(rows, "PENDING", "private-ssh-console-and-rollback-not-revalidated")
    gate.add(rows, "NOT RUN", "no-provider-guest-backup-or-dns-mutation")
    return rows


def private_report(gate, sha: str, rows: list[tuple[str, str]]) -> Path:
    folder = gate.private_dir()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    dest = folder / ("p8v-dns-proposal-" + stamp + "-" + str(os.getpid()) + ".json")
    fd = os.open(
        dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600,
    )
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump({
            "schema_version": 1,
            "source": sha,
            "observed_utc": stamp,
            "scope": "public-recursive-dns-proposal-only",
            "sanitized_rows": rows,
        }, out, indent=2)
        out.write("\n")
    return dest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="P8V-D public DNS proposal-only read-only survey")
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--zone", required=True)
    parser.add_argument("--test-fqdn", required=True)
    args = parser.parse_args(argv)
    try:
        gate = load_gate()
    except (OSError, ValueError):
        print("P8V DNS: BLOCKED/2 - source-guard-unavailable")
        return 2
    if (platform.system() != "Linux" or os.geteuid() == 0
            or sys.version_info < (3, 12)
            or not gate.git_pinned(args.expected_sha)):
        print("P8V DNS: BLOCKED/2 - source-environment-or-pin-invalid")
        return 2
    rows = survey(gate, args.zone, args.test_fqdn)
    status = "BLOCKED" if any(s == "BLOCKED" for s, _ in rows) else "HOLD"
    try:
        path = private_report(gate, args.expected_sha, rows)
    except (OSError, gate.PrivateEvidenceError):
        print("P8V DNS: HOLD/1 - private-evidence-unavailable")
        return 1
    counts = Counter(s for s, _ in rows)
    print("P8V DNS PROPOSAL: " + ("BLOCKED/2" if status == "BLOCKED" else "HOLD/1"))
    for state, reason in rows:
        print(state + ": " + reason)
    print("Sanitized counts:", {k: counts.get(k, 0) for k in
                                ("PASS", "PENDING", "BLOCKED", "NOT RUN")})
    print("Private report:", path)
    print("Proposed hostname not reserved/approved; zero changes to DNS, Cloudflare or OCI.")
    return 2 if status == "BLOCKED" else 1


if __name__ == "__main__":
    raise SystemExit(main())
