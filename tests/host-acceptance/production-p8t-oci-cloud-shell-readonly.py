#!/usr/bin/env python3
"""P8T OCI Cloud Shell independent network proof; read-only, sanitized.

Run ONLY in pre-authenticated OCI Cloud Shell against a privately selected
disposable instance OCID and region. No packages or IAM changes; no VNIC,
NSG, subnet, serial console, DNS or application mutations. No identifiers
or provider response bodies printed. This does not authorize a live canary.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True
os.umask(0o077)
SOURCE = Path(__file__).resolve().parents[2]
P8T = Path(__file__).with_name("production-p8t-external-boundary-readonly.py")
REGION_RE = re.compile(r"[a-z]{2}-[a-z0-9-]+-[0-9]+\Z")
OCID_RE = re.compile(r"ocid1\.[a-z][a-z0-9_-]*\.oc[0-9]+\.[a-z0-9.-]+\Z")
ALLOWED = frozenset({
    ("compute", "instance", "get"),
    ("compute", "vnic-attachment", "list"),
    ("network", "vnic", "get"),
    ("network", "subnet", "get"),
    ("network", "security-list", "get"),
    ("network", "nsg", "rules", "list"),
    ("network", "ipv6", "list"),
})


def module():
    spec = importlib.util.spec_from_file_location("p8t_shared_network_rules", P8T)
    if spec is None or spec.loader is None:
        raise RuntimeError("pinned P8T shared rule file missing")
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


def data_only(command: tuple[str, ...], key: str, value: str,
              region: str, *, extra: tuple[str, ...] = (),
              instance_filter: str | None = None,
              cli: str = "oci") -> Any | None:
    # Only hardcoded exact OCI GET/list commands and validated OCIDs; never
    # accept user-supplied CLI flags, URL, query filter or a shell string.
    if (command not in ALLOWED or not OCID_RE.fullmatch(value)
            or not REGION_RE.fullmatch(region)
            or not key.startswith("--") or extra not in ((), ("--all",))):
        return None
    is_attachment_list = command == ("compute", "vnic-attachment", "list")
    if is_attachment_list:
        if (key != "--compartment-id" or not instance_filter
                or not OCID_RE.fullmatch(instance_filter)
                or not instance_filter.startswith("ocid1.instance.")
                or extra != ("--all",)):
            return None
    elif instance_filter is not None:
        return None
    args = [cli, *command, key, value]
    if is_attachment_list:
        args.extend(["--instance-id", instance_filter])
    args.extend([*extra, "--region", region, "--output", "json", "--max-retries", "0",
                 "--connection-timeout", "4", "--read-timeout", "10"])
    try:
        proc = subprocess.run(
            args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, check=False, timeout=35,
            env=dict(os.environ, OCI_CLI_AUTO_PROMPT="false", PAGER="cat"))
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0 or len(proc.stdout) > 1024 * 1024:
        return None
    try:
        doc = json.loads(proc.stdout)
        return doc.get("data") if isinstance(doc, dict) else None
    except (UnicodeError, ValueError):
        return None


def obvious_public_ingress(rule: dict[str, Any], p8t) -> bool:
    """Block manifest broad TCP/80 or TCP/443, even without current CIDRs."""
    if not isinstance(rule, dict):
        return False
    if rule.get("direction", "INGRESS") != "INGRESS":
        return False
    if str(rule.get("protocol", "")).lower() not in ("6", "all", "-1"):
        return False
    if rule.get("source-type", "CIDR_BLOCK") != "CIDR_BLOCK":
        return False
    source = rule.get("source")
    if source not in ("0.0.0.0/0", "::/0"):
        return False
    options = rule.get("tcp-options") if str(rule.get("protocol", "")).lower() == "6" else None
    return p8t.port_intersects(options, 80) is True or p8t.port_intersects(options, 443) is True


def verify(argv=None) -> int:
    parser = argparse.ArgumentParser(description="OCI Cloud Shell P8T read-only provider inventory")
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--instance-id", required=True, help="Private instance OCID; never paste into chat")
    parser.add_argument("--region", required=True)
    args = parser.parse_args(argv)

    if (not re.fullmatch(r"[0-9a-f]{40}", args.expected_commit)
            or not OCID_RE.fullmatch(args.instance_id)
            or not args.instance_id.startswith("ocid1.instance.")
            or not REGION_RE.fullmatch(args.region)
            or shutil.which("oci") is None):
        print("BLOCKED: invalid pinned source, Cloud Shell CLI, region or private instance identifier")
        return 2
    p8t = module()
    if not p8t.source_clean(args.expected_commit):
        print("BLOCKED: P8T Cloud Shell requires exact clean reviewed branch")
        return 2

    rows: list[tuple[str, str]] = []
    try:
        instance = data_only(("compute", "instance", "get"), "--instance-id",
                             args.instance_id, args.region)
        if not isinstance(instance, dict):
            rows.append(("PENDING", "oci.cloudshell-instance-read-permission-or-region-unavailable"))
            return p8t.emit(None, rows, "HOLD")
        if instance.get("id") != args.instance_id:
            rows.append(("BLOCKED", "oci.cloudshell-provider-instance-id-mismatch"))
            return p8t.emit(None, rows, "BLOCKED")
        compartment = instance.get("compartment-id")
        if not isinstance(compartment, str) or not OCID_RE.fullmatch(compartment):
            rows.append(("PENDING", "oci.cloudshell-instance-compartment-unverified"))
            return p8t.emit(None, rows, "HOLD")
        rows.append(("PASS", "oci.cloudshell-authoritative-instance-get"))
        if instance.get("display-name") == p8t.HOST:
            rows.append(("PASS", "oci.cloudshell-selected-instance-friendly-name-matches-host"))
        else:
            rows.append(("PENDING", "oci.cloudshell-selected-instance-needs-identity-crosscheck"))

        attached = data_only(("compute", "vnic-attachment", "list"), "--compartment-id",
                             compartment, args.region, extra=("--all",),
                             instance_filter=args.instance_id)
        if not isinstance(attached, list):
            rows.append(("PENDING", "oci.cloudshell-attached-vnic-list-unavailable"))
            return p8t.emit(None, rows, "HOLD")
        vnics = [row.get("vnic-id") for row in attached
                 if isinstance(row, dict) and row.get("lifecycle-state") == "ATTACHED"]
        if (not 1 <= len(vnics) <= 8 or len(vnics) != len(set(vnics))
                or any(not isinstance(v, str) or not OCID_RE.fullmatch(v) for v in vnics)):
            rows.append(("PENDING", "oci.cloudshell-vnic-attachment-identity-incomplete"))
            return p8t.emit(None, rows, "HOLD")
        rows.append(("PASS", "oci.cloudshell-attached-vnics-identified"))

        trusted, cf_rows = p8t.official_cidr_observations()
        rows.extend(cf_rows)
        if set(trusted) != {4, 6}:
            rows.append(("PENDING", "oci.cloudshell-current-cloudflare-cidrs-unavailable"))

        all_known = True
        for vnic_id in vnics:
            vnic = data_only(("network", "vnic", "get"), "--vnic-id", vnic_id, args.region)
            if not isinstance(vnic, dict) or vnic.get("id") != vnic_id:
                all_known = False
                rows.append(("PENDING", "oci.cloudshell-vnic-details-unavailable"))
                continue
            subnet_id = vnic.get("subnet-id")
            nsgs = vnic.get("nsg-ids", [])
            if (not isinstance(subnet_id, str) or not OCID_RE.fullmatch(subnet_id)
                    or not isinstance(nsgs, list) or len(nsgs) > 12
                    or any(not isinstance(x, str) or not OCID_RE.fullmatch(x) for x in nsgs)):
                all_known = False
                rows.append(("PENDING", "oci.cloudshell-vnic-network-attachments-invalid"))
                continue
            subnet = data_only(("network", "subnet", "get"), "--subnet-id",
                               subnet_id, args.region)
            lists = subnet.get("security-list-ids") if isinstance(subnet, dict) else None
            if (not isinstance(subnet, dict) or subnet.get("id") != subnet_id
                    or not isinstance(lists, list) or len(lists) > 12
                    or any(not isinstance(x, str) or not OCID_RE.fullmatch(x) for x in lists)):
                all_known = False
                rows.append(("PENDING", "oci.cloudshell-subnet-security-list-inventory-incomplete"))
                continue

            rules = []
            complete = True
            for list_id in lists:
                security = data_only(("network", "security-list", "get"),
                                     "--security-list-id", list_id, args.region)
                ingress = security.get("ingress-security-rules") if isinstance(security, dict) else None
                if not isinstance(ingress, list) or len(ingress) > 1024:
                    complete = False
                    break
                rules.extend(ingress)
            if complete:
                for group_id in nsgs:
                    ingress = data_only(("network", "nsg", "rules", "list"),
                                        "--nsg-id", group_id, args.region, extra=("--all",))
                    if not isinstance(ingress, list) or len(ingress) > 1024:
                        complete = False
                        break
                    rules.extend(ingress)
            if not complete or len(rules) > 2048:
                all_known = False
                rows.append(("PENDING", "oci.cloudshell-effective-rule-inventory-incomplete"))
                continue

            if any(obvious_public_ingress(rule, p8t) for rule in rules):
                rows.append(("BLOCKED", "oci.cloudshell-manifest-global-public-http-https-ingress"))
                return p8t.emit(None, rows, "BLOCKED")
            if set(trusted) == {4, 6}:
                judgment = p8t.review_oci_rules(rules, trusted)
                rows.append((judgment, "oci.cloudshell-nsg-plus-subnet-rule-union"))
                if judgment == "BLOCKED":
                    return p8t.emit(None, rows, "BLOCKED")
            else:
                rows.append(("PENDING", "oci.cloudshell-current-allowed-source-comparison-pending"))

            if vnic.get("public-ip"):
                rows.append(("PASS", "oci.cloudshell-public-ipv4-field-present"))
            else:
                rows.append(("PENDING", "oci.cloudshell-public-ipv4-field-unverified"))
            ipv6 = data_only(("network", "ipv6", "list"), "--vnic-id",
                             vnic_id, args.region, extra=("--all",))
            if not isinstance(ipv6, list):
                rows.append(("PENDING", "oci.cloudshell-vnic-ipv6-inventory-unavailable"))
            elif ipv6:
                rows.append(("PENDING", "oci.cloudshell-ipv6-assigned-requires-route-proof"))
            else:
                rows.append(("PASS", "oci.cloudshell-no-ipv6-assigned-on-vnic"))
        if all_known:
            rows.append(("PASS", "oci.cloudshell-all-attached-vnics-visited"))
        else:
            rows.append(("PENDING", "oci.cloudshell-at-least-one-vnic-inventory-incomplete"))
    except Exception:
        rows.append(("PENDING", "oci.cloudshell-readonly-audit-incomplete"))
    rows.extend([
        ("PENDING", "oci.cloudshell-original-production-vm-separation-needs-second-identity"),
        ("PENDING", "oci.cloudshell-console-recovery-not-tested"),
        ("NOT RUN", "oci.cloudshell-no-provider-iam-network-or-service-mutations"),
    ])
    return p8t.emit(None, rows, "HOLD")


if __name__ == "__main__":
    raise SystemExit(verify())
