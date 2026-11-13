#!/usr/bin/env python3
"""P8V-A OCI GET/list-only transport audit. Not a public packet-path proof.

All observations are scoped to the selected disposable VM and queried VCN
compartments. No Cloudflare CIDR maintenance, OCI writes, or stdout identifiers.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import ipaddress
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)
ROOT = Path(__file__).resolve().parents[2]
BRANCH = "audit/rc13-p8v-hold-diagnostics-20261113"
HOST = "vaultwarden-oci-7-vnic"
REGION = "us-sanjose-1"
OCID = re.compile(r"ocid1\.[a-z][a-z0-9_-]*\.oc[0-9]+\.[a-z0-9.-]+\Z")
SHA = re.compile(r"[0-9a-f]{40}\Z")
ALLOW = {
    ("compute", "instance", "get"): "--instance-id",
    ("compute", "vnic-attachment", "list"): "--compartment-id",
    ("network", "vnic", "get"): "--vnic-id",
    ("network", "subnet", "get"): "--subnet-id",
    ("network", "vcn", "get"): "--vcn-id",
    ("network", "security-list", "get"): "--security-list-id",
    ("network", "nsg", "rules", "list"): "--nsg-id",
    ("network", "ipv6", "list"): "--vnic-id",
    ("network", "private-ip", "list"): "--subnet-id",
    ("network", "subnet", "list"): "--compartment-id",
}


class Incomplete(ValueError):
    """Sanitized, source-owned reason; do not append provider detail."""


def require(ok: bool, reason: str) -> None:
    if not ok:
        raise Incomplete(reason)


def pin_ok(commit: str) -> bool:
    if not SHA.fullmatch(commit) or ROOT.is_symlink() or not (ROOT / ".git").is_dir():
        return False
    found = []
    for args in (("rev-parse", "HEAD"), ("symbolic-ref", "--quiet", "--short", "HEAD"),
                 ("status", "--porcelain", "--untracked-files=all")):
        try:
            p = subprocess.run(["git", *args], cwd=ROOT, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               timeout=20, check=False,
                               env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat"))
        except (OSError, subprocess.TimeoutExpired):
            return False
        if p.returncode != 0 or len(p.stdout) > 8192:
            return False
        found.append(p.stdout.decode("utf-8", "replace").strip())
    return found == [commit, BRANCH, ""]


class Provider:
    """Only predeclared read calls can reach OCI; CLI diagnostics are discarded."""

    def __init__(self, region: str):
        self.region = region

    def read(self, command: tuple[str, ...], identity: str, *, instance: str | None = None,
             vcn: str | None = None):
        require(command in ALLOW and isinstance(identity, str) and OCID.fullmatch(identity),
                "provider-query-arguments")
        args = ["oci", *command, ALLOW[command], identity]
        if command == ("compute", "vnic-attachment", "list"):
            require(isinstance(instance, str) and OCID.fullmatch(instance), "vnic-filter")
            args += ["--instance-id", instance, "--all"]
        elif command == ("network", "subnet", "list"):
            require(isinstance(vcn, str) and OCID.fullmatch(vcn), "vcn-filter")
            args += ["--vcn-id", vcn, "--all"]
        elif command in (("network", "nsg", "rules", "list"),
                         ("network", "ipv6", "list"), ("network", "private-ip", "list")):
            args += ["--all"]
        else:
            require(instance is None and vcn is None, "unexpected-provider-filter")
        args += ["--region", self.region, "--output", "json", "--max-retries", "0",
                 "--connection-timeout", "4", "--read-timeout", "10"]
        try:
            proc = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, timeout=75, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise Incomplete("provider-unavailable-or-timeout") from exc
        require(proc.returncode == 0, "provider-get-failed")
        require(0 < len(proc.stdout) <= 1048576, "provider-empty-or-oversized")
        try:
            doc = json.loads(proc.stdout)
        except (ValueError, UnicodeError) as exc:
            raise Incomplete("provider-invalid-json") from exc
        require(isinstance(doc, dict) and "data" in doc, "provider-data-missing")
        return doc["data"]


def cidr(value: object):
    require(isinstance(value, str), "cidr-not-string")
    try:
        result = ipaddress.ip_network(value, strict=True)
    except ValueError as exc:
        raise Incomplete("cidr-invalid") from exc
    require(str(result) == value, "cidr-not-canonical")
    return result


def ports(opts: object) -> tuple[int, int]:
    """OCI null TCP options/port range means ANY port, never no ports."""
    if opts is None:
        return (1, 65535)
    require(isinstance(opts, dict) and set(opts) <= {"destination-port-range", "source-port-range"},
            "tcp-options-unknown")
    require(opts.get("source-port-range") is None, "restricted-source-port-unapproved")
    rng = opts.get("destination-port-range")
    if rng is None:
        return (1, 65535)
    require(isinstance(rng, dict) and set(rng) == {"min", "max"}, "tcp-range-unknown")
    lo, hi = rng["min"], rng["max"]
    require(type(lo) is int and type(hi) is int and 1 <= lo <= hi <= 65535,
            "tcp-range-invalid")
    return lo, hi


def public_source(network) -> bool:
    # Treat ambiguous/reserved sources as public-capable; do not infer safety.
    return not (network.is_private and network.prefixlen > 0)


def review_rule(rule: object, private_subnet: str) -> tuple[str, str]:
    """Classify every effective rule; no source or addresses in outcomes."""
    try:
        require(isinstance(rule, dict), "ingress-rule-schema")
        require(rule.get("direction", "INGRESS") == "INGRESS", "ingress-direction")
        require(rule.get("source-type", "CIDR_BLOCK") == "CIDR_BLOCK", "ingress-source-type")
        source = cidr(rule.get("source"))
        proto = str(rule.get("protocol", ""))
        external = public_source(source)
        if proto == "6":
            lo, hi = ports(rule.get("tcp-options"))
            if external:
                if lo == hi == 443 and str(source) == "0.0.0.0/0":
                    return "PENDING", "public-443-expected-transport-only"
                if lo <= 80 <= hi:
                    return "BLOCKED", "public-tcp80"
                if lo <= 22 <= hi:
                    return "BLOCKED", "public-ssh22"
                return "BLOCKED", "unexpected-public-tcp"
            if source.version == 4 and str(source) == private_subnet and lo == hi == 22:
                return "PASS", "private-subnet-ssh22"
            return "PENDING", "unapproved-private-tcp"
        if proto == "1" and source.version == 4:
            opts = rule.get("icmp-options")
            if external and isinstance(opts, dict) and set(opts) == {"type", "code"} \
                    and type(opts["type"]) is int and type(opts["code"]) is int \
                    and opts == {"type": 3, "code": 4}:
                return "PASS", "path-mtu-icmp"
            if not external:
                return "PASS", "private-icmp"
            return "BLOCKED", "unexpected-public-icmp"
        if external:
            return "BLOCKED", "unexpected-public-protocol"
        return "PENDING", "unknown-private-protocol"
    except Incomplete as exc:
        return "PENDING", str(exc)


def same_rules(a: object, b: object) -> bool:
    def normalized(value):
        if isinstance(value, dict):
            return {k: normalized(v) for k, v in value.items() if v is not None}
        if isinstance(value, list):
            return [normalized(v) for v in value]
        return value
    return isinstance(a, list) and isinstance(b, list) and sorted(
        json.dumps(normalized(x), sort_keys=True) for x in a) == sorted(
        json.dumps(normalized(x), sort_keys=True) for x in b)


def approved_separation(default: dict, dedicated: dict, subnet_cidr: str) -> bool:
    """Strong local shape comparison, not time-travel proof of unchanged baseline."""
    original = default.get("ingress-security-rules")
    live = dedicated.get("ingress-security-rules")
    if not isinstance(original, list) or len(original) != 4 or not isinstance(live, list):
        return False
    altered = []
    changed = 0
    for rule in original:
        if not isinstance(rule, dict):
            return False
        new = dict(rule)
        status, reason = review_rule(rule, subnet_cidr)
        if status == "BLOCKED" and reason == "public-ssh22":
            try:
                if (str(rule.get("protocol")) != "6" or ports(rule.get("tcp-options")) != (22, 22)
                        or cidr(rule.get("source")).version != 4):
                    return False
            except Incomplete:
                return False
            new["source"] = subnet_cidr
            new["description"] = "P8T VM-subnet-only private SSH"
            changed += 1
        altered.append(new)
    return (changed == 1 and same_rules(altered, live)
            and same_rules(default.get("egress-security-rules"), dedicated.get("egress-security-rules")))


def evaluate(snapshot: dict) -> list[tuple[str, str]]:
    """Pure union audit: caller provides independently fetched complete GET results."""
    rows = []
    def add(status, reason):
        rows.append((status, reason))
    vnics = snapshot.get("vnics")
    require(isinstance(vnics, list) and 1 <= len(vnics) <= 8, "vnic-union-missing")
    for item in vnics:
        require(isinstance(item, dict), "vnic-item-missing")
        subnet, vcn, vnic = (item.get(x) for x in ("subnet", "vcn", "vnic"))
        require(all(isinstance(x, dict) for x in (subnet, vcn, vnic)), "vnic-network-incomplete")
        private = cidr(subnet.get("cidr-block"))
        require(private.version == 4 and private.is_private, "subnet-not-private-ipv4")
        sls = item.get("security_lists")
        nsgs = item.get("nsg_rules")
        require(isinstance(sls, list) and sls and isinstance(nsgs, list), "union-incomplete")
        ids = subnet.get("security-list-ids")
        require(isinstance(ids, list) and len(ids) == len(sls), "list-identity-incomplete")
        require(isinstance(vnic.get("nsg-ids"), list)
                and len(vnic["nsg-ids"]) == len(nsgs), "nsg-identity-incomplete")
        if nsgs:
            add("PENDING", "unexpected-nsg-attachment")
        default_id = vcn.get("default-security-list-id")
        require(isinstance(default_id, str) and default_id not in ids, "shared-default-list-attached")
        require(len(sls) == 1 and sls[0].get("id") == ids[0], "dedicated-list-not-sole")
        require(item.get("default") is not None, "default-list-read-missing")
        if approved_separation(item["default"], sls[0], str(private)):
            add("PASS", "dedicated-versus-default-approved-shape")
        else:
            add("PENDING", "default-list-comparison-not-proven")
        observed = []
        for group in sls + nsgs:
            ingress = group.get("ingress-security-rules") if group in sls else group.get("rules")
            require(isinstance(ingress, list) and len(ingress) <= 1024, "rules-incomplete")
            for rule in ingress:
                result = review_rule(rule, str(private))
                observed.append(result)
                add(*result)
        if sum(status == "PASS" and reason == "private-subnet-ssh22"
               for status, reason in observed) != 1:
            add("PENDING", "private-ssh-rule-cardinality-not-proven")
        if sum(status == "PENDING" and reason == "public-443-expected-transport-only"
               for status, reason in observed) != 1:
            add("PENDING", "public443-rule-cardinality-not-proven")
        if isinstance(item.get("private_ips"), list) and item["private_ips"]:
            if all(isinstance(p, dict) and p.get("vnic-id") in item.get("approved_vnics", [])
                   for p in item["private_ips"]):
                add("PASS", "no-other-vnics-in-target-subnet")
            else:
                add("PENDING", "other-or-unknown-vnics-in-subnet")
        else:
            add("PENDING", "private-ip-subnet-inventory-unavailable")
        if isinstance(item.get("subnets"), list):
            if any(isinstance(s, dict) and s.get("id") != subnet.get("id")
                   and ids[0] in s.get("security-list-ids", []) for s in item["subnets"]):
                add("PENDING", "dedicated-list-shared-in-scanned-vcn")
            else:
                add("PASS", "dedicated-list-not-shared-in-scanned-vcn")
        else:
            add("PENDING", "vcn-other-subnet-scan-unavailable")
        add("PENDING", "other-compartments-unscanned")
        ipv6 = item.get("ipv6")
        if (ipv6 == [] and subnet.get("ipv6-cidr-blocks") == []
                and vcn.get("ipv6-cidr-blocks") == []):
            add("PASS", "scoped-ipv6-assignment-and-cidr-empty")
        else:
            add("PENDING", "public-ipv6-absence-not-independently-proven")
        if isinstance(ipv6, list) and ipv6:
            add("PENDING", "ipv6-assignment-route-analysis-required")
    return rows


def protected_target_inventory(path: Path, selected_id: str) -> frozenset[str]:
    """Bind provider reads to the exact private P8T target, not a regex-picked OCID.

    The historical security-list attachments are intentionally NOT compared:
    P8T independently changed them after this inventory was recorded.
    """
    try:
        parent = path.parent.lstat()
        meta = path.lstat()
        require(stat.S_ISDIR(parent.st_mode) and parent.st_uid == os.geteuid()
                and stat.S_IMODE(parent.st_mode) == 0o700,
                "p8t-evidence-directory-invalid")
        require(stat.S_ISREG(meta.st_mode) and not path.is_symlink()
                and meta.st_uid == os.geteuid() and stat.S_IMODE(meta.st_mode) == 0o600
                and 0 < meta.st_size <= 262144, "p8t-evidence-file-invalid")
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as stream:
            raw = stream.read(262145)
        require(len(raw) <= 262144, "p8t-evidence-oversized")
        doc = json.loads(raw)
        require(isinstance(doc, dict) and doc.get("instance_id") == selected_id,
                "p8t-instance-not-equal-selected")
        items = doc.get("subnets")
        require(isinstance(items, list) and 1 <= len(items) <= 8,
                "p8t-previous-subnet-map-incomplete")
        ids = [item.get("subnet_id") for item in items if isinstance(item, dict)]
        require(len(ids) == len(items) and len(set(ids)) == len(ids)
                and all(isinstance(x, str) and OCID.fullmatch(x) for x in ids),
                "p8t-previous-subnet-map-invalid")
        return frozenset(ids)
    except Incomplete:
        raise
    except (OSError, UnicodeError, ValueError, TypeError) as exc:
        raise Incomplete("p8t-protected-inventory-unavailable") from exc


def instance_identity_rows(inst: object, selected_id: str) -> list[tuple[str, str]]:
    """OCI display names are mutable labels, not authoritative VM identities."""
    require(isinstance(inst, dict) and inst.get("id") == selected_id,
            "provider-instance-id-not-equal-selected")
    rows = [("PASS", "provider-instance-id-matches-protected-selection")]
    if inst.get("display-name") == HOST:
        rows.append(("PASS", "provider-friendly-name-matches-host"))
    else:
        rows.append(("PENDING", "provider-friendly-name-differs-from-host"))
    return rows


def inspect(provider: Provider, instance_id: str,
            expected_subnets: frozenset[str]) -> list[tuple[str, str]]:
    inst = provider.read(("compute", "instance", "get"), instance_id)
    rows = instance_identity_rows(inst, instance_id)
    comp = inst.get("compartment-id")
    require(isinstance(comp, str) and OCID.fullmatch(comp), "instance-compartment-unverified")
    raw = provider.read(("compute", "vnic-attachment", "list"), comp, instance=instance_id)
    require(isinstance(raw, list) and 1 <= len(raw) <= 64, "attachment-inventory-invalid")
    attached = [x for x in raw if isinstance(x, dict) and x.get("lifecycle-state") == "ATTACHED"]
    ids = [x.get("vnic-id") for x in attached]
    require(1 <= len(ids) <= 8 and len(ids) == len(set(ids))
            and all(isinstance(x, str) and OCID.fullmatch(x) for x in ids),
            "attached-vnic-incomplete")
    require(all(isinstance(x, dict) and x.get("lifecycle-state") in
                ("ATTACHED", "DETACHED") for x in raw),
            "vnic-attachment-lifecycle-unknown")
    snapshot = {"vnics": []}
    for vnic_id in ids:
        vnic = provider.read(("network", "vnic", "get"), vnic_id)
        require(isinstance(vnic, dict) and vnic.get("id") == vnic_id,
                "vnic-identity-mismatch")
        sid = vnic.get("subnet-id")
        require(isinstance(sid, str) and OCID.fullmatch(sid), "vnic-subnet-missing")
        subnet = provider.read(("network", "subnet", "get"), sid)
        require(isinstance(subnet, dict) and subnet.get("id") == sid, "subnet-identity-mismatch")
        require(sid in expected_subnets, "live-subnet-not-in-private-p8t-target-map")
        vid = subnet.get("vcn-id")
        require(isinstance(vid, str) and OCID.fullmatch(vid), "vcn-identity-unverified")
        vcn = provider.read(("network", "vcn", "get"), vid)
        require(isinstance(vcn, dict) and vcn.get("id") == vid, "vcn-identity-mismatch")
        lists = subnet.get("security-list-ids")
        nsgs = vnic.get("nsg-ids")
        require(isinstance(lists, list) and 1 <= len(lists) <= 12
                and isinstance(nsgs, list) and len(nsgs) <= 12
                and all(isinstance(x, str) and OCID.fullmatch(x) for x in lists+nsgs),
                "network-attachment-schema-invalid")
        sls = [provider.read(("network", "security-list", "get"), x) for x in lists]
        default_id = vcn.get("default-security-list-id")
        require(isinstance(default_id, str) and OCID.fullmatch(default_id), "vcn-default-unknown")
        default = provider.read(("network", "security-list", "get"), default_id)
        groups = []
        for ng in nsgs:
            ng_rules = provider.read(("network", "nsg", "rules", "list"), ng)
            require(isinstance(ng_rules, list) and len(ng_rules) <= 1024, "nsg-rules-schema")
            groups.append({"rules": ng_rules})
        # These supplementary inventory reads may be unavailable in Cloud
        # Shell. Keep evaluating the *complete security-rule union* while
        # independently reporting the missing IPv6/private-IP evidence.
        try:
            ipv6 = provider.read(("network", "ipv6", "list"), vnic_id)
        except Incomplete:
            ipv6 = None
            rows.append(("PENDING", "oci-ipv6-assignment-read-unavailable"))
        try:
            priv = provider.read(("network", "private-ip", "list"), sid)
        except Incomplete:
            priv = None
            rows.append(("PENDING", "oci-private-ip-read-unavailable"))
        if not isinstance(priv, list):
            priv = None
        scope = subnet.get("compartment-id")
        subnets = None
        if isinstance(scope, str) and OCID.fullmatch(scope):
            try:
                subnets = provider.read(("network", "subnet", "list"), scope, vcn=vid)
            except Incomplete:
                rows.append(("PENDING", "oci-other-subnet-read-unavailable"))
        snapshot["vnics"].append({"vnic": vnic, "subnet": subnet, "vcn": vcn,
                                  "security_lists": sls, "default": default,
                                  "nsg_rules": groups, "ipv6": ipv6, "private_ips": priv,
                                  "approved_vnics": ids, "subnets": subnets})
    return rows + evaluate(snapshot)


def private_write(rows: list[tuple[str, str]], commit: str, outcome: str) -> Path:
    folder = Path.home() / "vwoci-acceptance"
    folder.mkdir(mode=0o700, exist_ok=True)
    st = folder.lstat()
    require(stat.S_ISDIR(st.st_mode) and st.st_uid == os.geteuid()
            and stat.S_IMODE(st.st_mode) == 0o700, "private-evidence-dir-unsafe")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = folder / f"p8v-oci-{stamp}-{os.getpid()}.json"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump({"version": 1, "commit": commit, "outcome": outcome,
                   "created_utc": stamp, "sanitized_rows": rows}, stream,
                  sort_keys=True, indent=2)
        stream.write("\n")
    return path


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="P8V-A read-only OCI transport acceptance")
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--p8t-private-inventory", type=Path, required=True)
    parser.add_argument("--region", default=REGION)
    args = parser.parse_args(argv)
    if (args.region != REGION or not isinstance(args.instance_id, str)
            or not args.instance_id.startswith("ocid1.instance.")
            or not OCID.fullmatch(args.instance_id) or shutil.which("oci") is None
            or not pin_ok(args.expected_sha)):
        print("P8V OCI: BLOCKED/2 - invalid source, environment or target pin")
        return 2
    rows: list[tuple[str, str]] = []
    try:
        expected_subnets = protected_target_inventory(args.p8t_private_inventory, args.instance_id)
        rows = inspect(Provider(args.region), args.instance_id, expected_subnets)
    except Incomplete as exc:
        rows.append(("PENDING", str(exc)))
    except Exception:
        rows.append(("PENDING", "unexpected-readonly-inventory-error"))
    rows.append(("PENDING", "host-443-packet-path-not-proven"))
    rows.append(("NOT RUN", "no-provider-mutation-or-canary"))
    outcome = "BLOCKED" if any(x == "BLOCKED" for x, _ in rows) else "HOLD"
    try:
        path = private_write(rows, args.expected_sha, outcome)
    except (OSError, Incomplete):
        print("P8V OCI: HOLD/1 - private evidence could not be persisted")
        return 1
    counts = {status: sum(x == status for x, _ in rows)
              for status in ("PASS", "PENDING", "BLOCKED", "NOT RUN")}
    print("P8V OCI: " + ("BLOCKED/2" if outcome == "BLOCKED" else "HOLD/1")
          + " - public TCP443 is transport only, NOT origin proof")
    for status, reason in rows:
        print(f"{status}: {reason}")
    print("Sanitized result counts:", counts)
    print("Owner-private evidence path:", path)
    print("Do not paste provider IDs, IPs, rollback record or CLI debug output.")
    return 2 if outcome == "BLOCKED" else 1


if __name__ == "__main__":
    raise SystemExit(main())