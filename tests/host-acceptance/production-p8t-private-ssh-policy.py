"""Offline P8T post-change SSH-list invariants; no OCI/SSH execution.

The historical P8T OCI-only Cloudflare source contract is deliberately unchanged.
Use this pure comparison only on independently obtained, separately protected
provider GET evidence. It does not prove live packet denial or authorize startup.
"""
from __future__ import annotations

import ipaddress
import json
from typing import Any


class EvidenceMismatch(ValueError):
    """A required immutable P8T network invariant was not proven."""


def require(ok: bool, reason: str) -> None:
    if not ok:
        raise EvidenceMismatch(reason)


def canonical(value: Any) -> Any:
    """Ignore OCI's null fields; retain all actual values and source ranges."""
    if isinstance(value, dict):
        return {k: canonical(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [canonical(x) for x in value]
    return value


def same_rules(a: Any, b: Any) -> bool:
    if not isinstance(a, list) or not isinstance(b, list):
        return False
    return sorted(json.dumps(canonical(x), sort_keys=True) for x in a) == sorted(
        json.dumps(canonical(x), sort_keys=True) for x in b)


def port(rule: dict[str, Any]) -> int | None:
    opts = rule.get('tcp-options')
    require(isinstance(opts, dict), 'TCP options missing')
    require(set(opts) <= {'destination-port-range', 'source-port-range'},
            'unexpected TCP options')
    require(opts.get('source-port-range') is None, 'restricted source port')
    rng = opts.get('destination-port-range')
    require(isinstance(rng, dict) and set(rng) == {'min', 'max'},
            'unexpected TCP destination range')
    lo, hi = rng['min'], rng['max']
    require(type(lo) is int and type(hi) is int and lo == hi, 'nonexact TCP port')
    return lo


def verify(original: dict[str, Any], dedicated: dict[str, Any],
           subnet: dict[str, Any], vcn: dict[str, Any],
           vnic: dict[str, Any], target: dict[str, Any]) -> dict[str, int]:
    """Compare live GET snapshots to the approved isolated subnet change.

    Inputs are OCI CLI's decoded `data` objects and the private target/rollback
    pin merged into `target`. No provider queries or mutations occur here.
    The caller must separately establish OCI API provenance, VNIC/instance
    identity and the post-change authenticated private SSH witness.
    """
    require(all(isinstance(x, dict) for x in
                (original, dedicated, subnet, vcn, vnic, target)),
            'missing structured provider input')
    try:
        network = ipaddress.ip_network(target['subnet'], strict=True)
        private = ipaddress.ip_address(target['private'])
        require(network.version == 4 and network.is_private and private in network,
                'private IPv4 subnet mismatch')
        oldid = target['old_list_id']
        newid = target['new_list_id']
        sid = target['subnet_id']
        vid = target['vnic_id']
        vcnid = target['vcn_id']
        require(all(isinstance(x, str) and x.startswith('ocid1.')
                    for x in (oldid, newid, sid, vid, vcnid)),
                'provider identity missing')
        require(oldid != newid, 'new list must differ from original')
        require(subnet.get('id') == sid and subnet.get('vcn-id') == vcnid
                and subnet.get('cidr-block') == str(network)
                and subnet.get('security-list-ids') == [newid],
                'dedicated list not sole subnet attachment')
        require(vcn.get('id') == vcnid
                and vcn.get('default-security-list-id') == oldid,
                'original VCN default list identity changed')
        require(vnic.get('id') == vid and vnic.get('subnet-id') == sid
                and vnic.get('nsg-ids') == []
                and vnic.get('private-ip') == str(private),
                'VNIC identity or additive NSG changed')
        require(original.get('id') == oldid and dedicated.get('id') == newid
                and original.get('vcn-id') == vcnid
                and dedicated.get('vcn-id') == vcnid,
                'security list identity mismatch')
        old_in = original['ingress-security-rules']
        new_in = dedicated['ingress-security-rules']
        old_out = original['egress-security-rules']
        new_out = dedicated['egress-security-rules']
        require(isinstance(old_in, list) and len(old_in) == 4,
                'unexpected historical ingress inventory size')
        require(isinstance(old_out, list) and len(old_out) == 1,
                'unexpected historical egress inventory size')
        transformed = []
        ssh = https = mtu = 0
        for rule in old_in:
            require(isinstance(rule, dict)
                    and rule.get('source-type', 'CIDR_BLOCK') == 'CIDR_BLOCK',
                    'unknown ingress rule/source')
            source = ipaddress.ip_network(rule['source'], strict=True)
            require(source.version == 4, 'IPv6 ingress not established as safe')
            protocol = str(rule.get('protocol'))
            updated = dict(rule)
            if source.prefixlen == 0:
                if protocol == '1' and canonical(rule.get('icmp-options')) == {'type': 3, 'code': 4}:
                    mtu += 1
                elif protocol == '6':
                    number = port(rule)
                    if number == 22:
                        ssh += 1
                        updated['source'] = str(network)
                        updated['description'] = 'P8T VM-subnet-only private SSH'
                    elif number == 443:
                        https += 1
                    else:
                        raise EvidenceMismatch('unexpected global TCP port')
                else:
                    raise EvidenceMismatch('unexpected globally sourced protocol')
            else:
                require(source.is_private and protocol == '1',
                        'unexpected nonprivate or non-ICMP ingress')
            transformed.append(updated)
        require((ssh, https, mtu) == (1, 1, 1),
                'original global SSH/HTTPS/MTU cardinality changed')
        require(same_rules(transformed, new_in),
                'dedicated ingress differs beyond approved SSH CIDR')
        require(same_rules(old_out, new_out), 'outbound rules changed')
        return {'ingress': len(new_in), 'egress': len(new_out),
                'ssh_private': 1, 'https_public': 1, 'http_public': 0}
    except (KeyError, TypeError, AttributeError, ipaddress.AddressValueError,
            ipaddress.NetmaskValueError) as exc:
        raise EvidenceMismatch('incomplete provider rule or identity schema') from exc
