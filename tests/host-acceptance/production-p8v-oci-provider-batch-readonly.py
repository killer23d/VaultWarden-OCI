#!/usr/bin/env python3
"""P8V-A batched OCI GET-only evidence (no OCI/VM/firewall/DNS mutations).

A single source-pinned read-only pass: protected P8T identity, full effective
security-list/NSG union, VNIC/VCN/subnet IPv6, IPv4, route-table, CLI ListIpv6s,
and alternate authenticated raw GET ListIpv6s. Neither blank CLI output nor
null provider fields mean an empty IPv6 inventory. No private values printed.
"""
from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
from urllib.parse import quote

sys.dont_write_bytecode = True
os.umask(0o077)

ROOT = Path(__file__).resolve().parents[2]
BRANCH = "audit/rc13-p8v-batched-provider-readonly-20261113"
REGION = "us-sanjose-1"
SHA = re.compile(r"[a-f0-9]{40}\Z")
P8V_PATH = Path(__file__).with_name("production-p8v-oci-layered-readonly.py")


class Gap(ValueError):
    """Sanitized, reviewed diagnostic code; raw provider content never appears."""


def require(value: bool, reason: str) -> None:
    if not value:
        raise Gap(reason)


def load_base():
    spec = importlib.util.spec_from_file_location("p8v_prior", P8V_PATH)
    require(spec is not None and spec.loader is not None, "reviewed-base-missing")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pinned(pin: str) -> bool:
    if not SHA.fullmatch(pin) or ROOT.is_symlink() or not (ROOT / ".git").is_dir():
        return False
    observed = []
    for args in (("rev-parse", "HEAD"), ("symbolic-ref", "--quiet", "--short", "HEAD"),
                 ("status", "--porcelain", "--untracked-files=all")):
        try:
            proc = subprocess.run(["git", *args], cwd=ROOT, stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  check=False, timeout=20,
                                  env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat"))
        except (OSError, subprocess.TimeoutExpired):
            return False
        if proc.returncode or len(proc.stdout) > 8192:
            return False
        observed.append(proc.stdout.decode("utf-8", "replace").strip())
    return observed == [pin, BRANCH, ""]


def ipv6_vnic_field(value: object) -> tuple[str, str]:
    if value == []:
        return "PASS", "vnic-provider-ipv6-addresses-explicitly-empty"
    if isinstance(value, list):
        return "PENDING", "vnic-provider-ipv6-addresses-present"
    return "PENDING", "vnic-provider-ipv6-addresses-null-or-unknown"


def ipv6_prefix_fields(document: dict, scope: str) -> tuple[str, str]:
    """Null != [], including legitimate legacy absent fields."""
    keys = ("ipv6-cidr-blocks", "ipv6-private-cidr-blocks") if scope == "vcn" else (
        "ipv6-cidr-blocks",)
    if any(isinstance(document.get(k), list) and document[k] for k in keys):
        return "PENDING", scope + "-ipv6-prefixes-configured"
    singular = ("ipv6-cidr-block", "ipv6-public-cidr-block") if scope == "vcn" else (
        "ipv6-cidr-block",)
    if any(isinstance(document.get(k), str) and document[k] for k in singular):
        return "PENDING", scope + "-ipv6-prefix-configured"
    if all(document.get(k, "MISSING") == [] for k in keys):
        return "PASS", scope + "-ipv6-prefixes-explicitly-empty"
    return "PENDING", scope + "-ipv6-prefixes-null-or-missing"


def route_ipv6_evidence(value: object) -> tuple[str, str]:
    if not isinstance(value, list) or len(value) > 256:
        return "PENDING", "route-rules-missing-or-oversized"
    for entry in value:
        if not isinstance(entry, dict):
            return "PENDING", "route-rule-schema-incomplete"
        dest = entry.get("destination")
        kind = entry.get("destination-type", "CIDR_BLOCK")
        if not isinstance(dest, str) or kind != "CIDR_BLOCK":
            return "PENDING", "route-destination-unrecognized"
        try:
            prefix = ipaddress.ip_network(dest, strict=True)
        except ValueError:
            return "PENDING", "route-destination-invalid"
        if prefix.version == 6:
            return "PENDING", "ipv6-route-present-needs-route-analysis"
    return "PASS", "no-ipv6-destination-in-read-route-table"


def classify_ipv6_response(code: int, raw: bytes, stderr: bytes,
                           *, raw_request: bool = False) -> tuple[str, str]:
    """Only explicit authenticated JSON [] is acceptable; never trust blank stdout."""
    if code != 0:
        err = stderr[:8192].decode("utf-8", "replace").lower()
        if "notauthorizedornotfound" in err or "403" in err:
            return "PENDING", "ipv6-provider-authorization-unverified"
        if "no such option" in err or "no such command" in err:
            return "PENDING", "ipv6-cli-operation-unsupported"
        if "timeout" in err or "timed out" in err:
            return "PENDING", "ipv6-provider-timeout"
        return "PENDING", "ipv6-provider-command-failed"
    if not 0 < len(raw) <= 1048576:
        return "PENDING", "ipv6-cli-stdout-empty-or-oversized"
    try:
        doc = json.loads(raw)
    except (UnicodeError, ValueError):
        return "PENDING", "ipv6-cli-json-invalid"
    if not isinstance(doc, dict):
        return "PENDING", "ipv6-cli-schema-invalid"
    if raw_request:
        status = doc.get("status")
        if not isinstance(status, str) or not status.startswith("200 "):
            return "PENDING", "ipv6-raw-http-status-unverified"
        headers = doc.get("headers")
        if not isinstance(headers, dict):
            return "PENDING", "ipv6-raw-headers-unverified"
        if any(str(k).lower() == "opc-next-page" and v for k, v in headers.items()):
            return "PENDING", "ipv6-raw-result-paginated"
    records = doc.get("data")
    if not isinstance(records, list):
        return "PENDING", "ipv6-response-data-not-list"
    if records:
        return "PENDING", "ipv6-objects-present"
    return "PASS", "ipv6-provider-explicit-empty-list"


def invoke(args: list[str], *, raw_request: bool = False) -> tuple[str, str]:
    """Bounded, no-shell, GET-only OCI calls. No stderr/stdout echoed."""
    try:
        proc = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, check=False, timeout=75)
    except (OSError, subprocess.TimeoutExpired):
        return "PENDING", "ipv6-query-process-unavailable"
    return classify_ipv6_response(proc.returncode, proc.stdout, proc.stderr,
                                  raw_request=raw_request)


def probes(identity: str, *, subnet: bool = False) -> list[tuple[str, str]]:
    """Try normal ListIpv6s and a separate authenticated raw HTTP GET."""
    require(isinstance(identity, str) and identity.startswith("ocid1."),
            "ipv6-identity-invalid")
    mode = "subnet" if subnet else "vnic"
    option = "--subnet-id" if subnet else "--vnic-id"
    args = ["oci", "network", "ipv6", "list", option, identity, "--all",
            "--region", REGION, "--output", "json", "--max-retries", "0",
            "--connection-timeout", "4", "--read-timeout", "10"]
    status, reason = invoke(args)
    rows = [(status, mode + "-listipv6-" + reason)]
    uri = ("https://iaas." + REGION + ".oraclecloud.com/20160918/ipv6?"
           + ("subnetId=" if subnet else "vnicId=") + quote(identity, safe=""))
    args = ["oci", "raw-request", "--http-method", "GET", "--target-uri", uri,
            "--region", REGION, "--output", "json", "--max-retries", "0",
            "--connection-timeout", "4", "--read-timeout", "10"]
    status, reason = invoke(args, raw_request=True)
    rows.append((status, mode + "-signed-get-" + reason))
    return rows


def provider_aux(provider, target: str, expected_subnets: frozenset[str], core):
    """Fresh authoritative provider reads; no public identifiers in results."""
    rows: list[tuple[str, str]] = []
    inst = provider.read(("compute", "instance", "get"), target)
    require(isinstance(inst, dict) and inst.get("id") == target,
            "authoritative-instance-id-drift")
    comp = inst.get("compartment-id")
    require(isinstance(comp, str) and core.OCID.fullmatch(comp),
            "instance-compartment-missing")
    attachments = provider.read(("compute", "vnic-attachment", "list"), comp,
                                instance=target)
    require(isinstance(attachments, list) and 1 <= len(attachments) <= 64,
            "attachment-inventory-invalid")
    attached = [x for x in attachments if isinstance(x, dict)
                and x.get("lifecycle-state") == "ATTACHED"]
    ids = [x.get("vnic-id") for x in attached]
    require(1 <= len(ids) <= 8 and len(ids) == len(set(ids))
            and all(isinstance(x, str) and core.OCID.fullmatch(x) for x in ids),
            "attached-vnic-identity-invalid")
    rows.append(("PASS", "fresh-authoritative-attached-vnic-identity"))
    observed_subnets = set()
    cached = {}
    for vid in ids:
        vnic = provider.read(("network", "vnic", "get"), vid)
        require(isinstance(vnic, dict) and vnic.get("id") == vid,
                "vnic-provider-id-drift")
        sid = vnic.get("subnet-id")
        require(isinstance(sid, str) and sid in expected_subnets,
                "vnic-subnet-not-in-protected-p8t-inventory")
        observed_subnets.add(sid)
        rows.append(ipv6_vnic_field(vnic.get("ipv6-addresses")))
        rows.append(("PASS" if isinstance(vnic.get("public-ip"), str)
                     and vnic["public-ip"] else "PENDING",
                     "vnic-public-ipv4-provider-field"))
        rows.append(("PASS" if vnic.get("nsg-ids") == [] else "PENDING",
                     "vnic-no-additive-nsg-attachments"))
        rows.append(("PASS" if vnic.get("skip-source-dest-check") is False else "PENDING",
                     "vnic-source-destination-check-enabled"))
        rows.extend(probes(vid))
        subnet = cached.get(sid)
        if subnet is None:
            subnet = provider.read(("network", "subnet", "get"), sid)
            require(isinstance(subnet, dict) and subnet.get("id") == sid,
                    "subnet-provider-id-drift")
            cached[sid] = subnet
        rows.append(ipv6_prefix_fields(subnet, "subnet"))
        rows.extend(probes(sid, subnet=True))

        vcn_id = subnet.get("vcn-id")
        require(isinstance(vcn_id, str) and core.OCID.fullmatch(vcn_id),
                "vcn-identity-incomplete")
        vcn = provider.read(("network", "vcn", "get"), vcn_id)
        require(isinstance(vcn, dict) and vcn.get("id") == vcn_id,
                "vcn-provider-id-drift")
        rows.append(ipv6_prefix_fields(vcn, "vcn"))

        # VNIC-specific route-table overrides and the subnet route table can
        # differ; read both when present. No route-table update or probe traffic.
        route_ids = [x for x in (subnet.get("route-table-id"),
                                vnic.get("route-table-id")) if isinstance(x, str)]
        if not route_ids:
            rows.append(("PENDING", "routing-table-references-missing"))
        for rid in sorted(set(route_ids)):
            if not core.OCID.fullmatch(rid):
                rows.append(("PENDING", "routing-table-reference-invalid"))
                continue
            args = ["oci", "network", "route-table", "get", "--rt-id", rid,
                    "--region", REGION, "--output", "json", "--max-retries", "0",
                    "--connection-timeout", "4", "--read-timeout", "10"]
            try:
                proc = subprocess.run(args, stdin=subprocess.DEVNULL,
                                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                      check=False, timeout=75)
                if proc.returncode or not 0 < len(proc.stdout) <= 1048576:
                    rows.append(("PENDING", "route-provider-read-unavailable"))
                    continue
                doc = json.loads(proc.stdout)
                data = doc.get("data") if isinstance(doc, dict) else None
                if not isinstance(data, dict) or data.get("id") != rid or data.get("vcn-id") != vcn_id:
                    rows.append(("PENDING", "route-provider-identity-incomplete"))
                    continue
                rows.append(route_ipv6_evidence(data.get("route-rules")))
            except (OSError, subprocess.TimeoutExpired, UnicodeError, ValueError):
                rows.append(("PENDING", "route-provider-read-unavailable"))
    require(observed_subnets == expected_subnets,
            "historical-subnets-not-completely-enumerated")
    rows.append(("PASS", "protected-p8t-vnic-subnet-coverage"))
    return rows


def private_summary(commit: str, rows: list[tuple[str, str]], verdict: str) -> Path:
    folder = Path.home() / "vwoci-acceptance"
    st = folder.lstat()
    require(stat.S_ISDIR(st.st_mode) and st.st_uid == os.geteuid()
            and stat.S_IMODE(st.st_mode) == 0o700, "private-evidence-folder-invalid")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    file = folder / ("p8v-provider-batch-" + stamp + "-" + str(os.getpid()) + ".json")
    fd = os.open(file, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                 getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump({"schema": 1, "source": commit, "outcome": verdict,
                   "utc": stamp, "sanitized_rows": rows}, out, indent=2)
        out.write("\n")
    return file


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Read-only grouped P8V OCI provider acceptance")
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--p8t-private-inventory", type=Path, required=True)
    args = parser.parse_args(argv)
    if not pinned(args.expected_sha) or shutil.which("oci") is None:
        print("BLOCKED: exact clean reviewed source and OCI CLI required")
        return 2
    rows: list[tuple[str, str]] = []
    core = load_base()
    try:
        path = args.p8t_private_inventory
        st = path.lstat()
        require(stat.S_ISREG(st.st_mode) and not path.is_symlink()
                and st.st_uid == os.geteuid() and stat.S_IMODE(st.st_mode) == 0o600
                and 0 < st.st_size <= 262144, "p8t-inventory-metadata-invalid")
        doc = json.loads(path.read_bytes())
        target = doc.get("instance_id")
        require(isinstance(target, str) and target.startswith("ocid1.instance.")
                and core.OCID.fullmatch(target), "p8t-target-identity-invalid")
        expected = core.protected_target_inventory(path, target)
        provider = core.Provider(REGION)
        # Full ingress union from the reviewed earlier P8V-A implementation.
        rows.extend(core.inspect(provider, target, expected))
        rows.append(("PASS" if not any(x == "BLOCKED" or "cardinality-not-proven" in y
                                   for x, y in rows) else "PENDING",
                     "current-provider-ingress-union-reviewed"))
        # Supplementary independent checks are isolated; a provider error
        # must not erase the already collected ingress results.
        try:
            rows.extend(provider_aux(provider, target, expected, core))
        except (Gap, core.Incomplete) as exc:
            reason = str(exc)
            rows.append(("PENDING", reason if re.fullmatch(r"[a-z][a-z0-9-]{1,96}", reason)
                         else "supplementary-provider-check-unavailable"))
    except (Gap, core.Incomplete) as exc:
        reason = str(exc)
        rows.append(("PENDING", reason if re.fullmatch(r"[a-z][a-z0-9-]{1,96}", reason)
                     else "provider-read-incomplete"))
    except Exception:
        rows.append(("PENDING", "provider-inventory-unclassified"))
    rows.extend([("PENDING", "provider-ipv6-and-routing-scope-is-not-external-packet-proof"),
                 ("PENDING", "host-cloudflare-filter-external-path-not-proven"),
                 ("NOT RUN", "no-provider-mutation-host-connection-or-canary")])
    state = "BLOCKED" if any(s == "BLOCKED" for s, _ in rows) else "HOLD"
    try:
        saved = private_summary(args.expected_sha, rows, state)
    except (OSError, Gap):
        print("HOLD/1: unable to write owner-private summary")
        return 1
    print("P8V OCI BATCH: " + ("BLOCKED/2" if state == "BLOCKED" else "HOLD/1"))
    for status, reason in rows:
        print(status + ": " + reason)
    print("Sanitized counts:", {x: sum(status == x for status, _ in rows)
                                for x in ("PASS", "PENDING", "BLOCKED", "NOT RUN")})
    print("Private evidence:", saved)
    print("No raw OCI response, IP/OCID, firewall change or production GO.")
    return 2 if state == "BLOCKED" else 1


if __name__ == "__main__":
    raise SystemExit(main())
