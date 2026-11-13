"""Synthetic regression coverage for the accepted P8T private-SSH boundary."""
from __future__ import annotations

from copy import deepcopy
import importlib.util
from pathlib import Path
import unittest

SOURCE = Path(__file__).parent / 'host-acceptance/production-p8t-private-ssh-policy.py'
SPEC = importlib.util.spec_from_file_location('p8t_private_policy', SOURCE)
assert SPEC and SPEC.loader
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)

ROOT = 'ocid1.tenancy.oc1..synthetic'
OLD = 'ocid1.securitylist.oc1.synthetic.old'
NEW = 'ocid1.securitylist.oc1.synthetic.new'
SUBNET = 'ocid1.subnet.oc1.synthetic.target'
VCN = 'ocid1.vcn.oc1.synthetic.target'
VNIC = 'ocid1.vnic.oc1.synthetic.target'


def tcp(source, dest, source_ports=None):
    return {'protocol': '6', 'source': source, 'source-type': 'CIDR_BLOCK',
            'is-stateless': False,
            'tcp-options': {'destination-port-range': {'min': dest, 'max': dest},
                            'source-port-range': source_ports}}


def fixture():
    old = {'id': OLD, 'vcn-id': VCN, 'ingress-security-rules': [
        tcp('0.0.0.0/0', 22), tcp('0.0.0.0/0', 443),
        {'protocol': '1', 'source': '0.0.0.0/0', 'source-type': 'CIDR_BLOCK',
         'icmp-options': {'type': 3, 'code': 4}, 'is-stateless': False},
        {'protocol': '1', 'source': '10.1.0.0/16', 'source-type': 'CIDR_BLOCK',
         'icmp-options': {'type': 3}, 'is-stateless': False},
    ], 'egress-security-rules': [
        {'protocol': 'all', 'destination': '0.0.0.0/0',
         'destination-type': 'CIDR_BLOCK', 'is-stateless': False},
    ]}
    new = deepcopy(old)
    new['id'] = NEW
    new['ingress-security-rules'][0]['source'] = '10.1.2.0/24'
    new['ingress-security-rules'][0]['description'] = 'P8T VM-subnet-only private SSH'
    subnet = {'id': SUBNET, 'vcn-id': VCN, 'cidr-block': '10.1.2.0/24',
              'security-list-ids': [NEW]}
    vcn = {'id': VCN, 'default-security-list-id': OLD,
           'compartment-id': ROOT}
    vnic = {'id': VNIC, 'subnet-id': SUBNET, 'nsg-ids': [], 'private-ip': '10.1.2.3'}
    target = {'old_list_id': OLD, 'new_list_id': NEW, 'subnet_id': SUBNET,
              'vcn_id': VCN, 'vnic_id': VNIC, 'subnet': '10.1.2.0/24',
              'private': '10.1.2.3'}
    return [old, new, subnet, vcn, vnic, target]


class P8TPrivateSSHEvidenceTests(unittest.TestCase):
    def test_approved_oci_provider_snapshot(self):
        result = policy.verify(*fixture())
        self.assertEqual(result, {'ingress': 4, 'egress': 1,
                                  'ssh_private': 1, 'https_public': 1, 'http_public': 0})

    def test_oci_null_source_port_not_a_source_restriction(self):
        old, new, *tail = fixture()
        self.assertIn('source-port-range', old['ingress-security-rules'][0]['tcp-options'])
        new['ingress-security-rules'][0]['tcp-options'].pop('source-port-range')
        self.assertEqual(policy.verify(old, new, *tail)['ssh_private'], 1)

    def test_non_null_ssh_source_port_is_not_silently_allowed(self):
        old, new, *tail = fixture()
        old['ingress-security-rules'][0]['tcp-options']['source-port-range'] = {'min': 1024, 'max': 65535}
        with self.assertRaises(policy.EvidenceMismatch):
            policy.verify(old, new, *tail)

    def test_broad_ssh_still_allowed_is_not_a_pass(self):
        values = fixture()
        values[1]['ingress-security-rules'][0]['source'] = '0.0.0.0/0'
        with self.assertRaises(policy.EvidenceMismatch):
            policy.verify(*values)

    def test_open_http_or_unexpected_public_port_is_not_a_pass(self):
        for port in (80, 8080):
            with self.subTest(port=port):
                values = fixture()
                values[0]['ingress-security-rules'][1] = tcp('0.0.0.0/0', port)
                with self.assertRaises(policy.EvidenceMismatch):
                    policy.verify(*values)

    def test_new_public_ingress_or_changed_egress_is_not_a_pass(self):
        for mutate in (
            lambda v: v[1]['ingress-security-rules'].append(tcp('0.0.0.0/0', 80)),
            lambda v: v[1]['egress-security-rules'].clear(),
            lambda v: v[1]['ingress-security-rules'][1].update(source='10.1.2.0/24'),
        ):
            with self.subTest(mutation=str(mutate)):
                values = fixture()
                mutate(values)
                with self.assertRaises(policy.EvidenceMismatch):
                    policy.verify(*values)

    def test_wrong_subnet_vcn_or_nsg_attachment_is_not_a_pass(self):
        for mutate in (
            lambda v: v[2].update(**{'security-list-ids': [OLD, NEW]}),
            lambda v: v[3].update(**{'default-security-list-id': NEW}),
            lambda v: v[4].update(**{'nsg-ids': ['ocid1.networksecuritygroup.oc1.synthetic.extra']}),
            lambda v: v[4].update(**{'private-ip': '10.1.3.3'}),
        ):
            values = fixture()
            mutate(values)
            with self.assertRaises(policy.EvidenceMismatch):
                policy.verify(*values)

    def test_ipv6_or_broad_private_other_protocol_is_not_a_pass(self):
        for source, protocol in (('::/0', '1'), ('10.2.0.0/16', '6')):
            values = fixture()
            rule = values[0]['ingress-security-rules'][3]
            rule['source'] = source
            rule['protocol'] = protocol
            with self.assertRaises(policy.EvidenceMismatch):
                policy.verify(*values)

    def test_no_live_oci_ssh_firewall_or_file_side_effects(self):
        source = SOURCE.read_text(encoding='utf-8')
        for forbidden in ('subprocess', 'import socket', 'import os', 'from pathlib import Path',
                          'network subnet update', 'network security-list create', 'shell=True'):
            self.assertNotIn(forbidden, source)


if __name__ == '__main__':
    unittest.main()
