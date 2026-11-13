"""P8V OCI independent union and fail-closed protocol regressions (offline)."""
import importlib.util
import unittest
from pathlib import Path

FILE = Path(__file__).parent / 'host-acceptance/production-p8v-oci-layered-readonly.py'
spec = importlib.util.spec_from_file_location('p8v_oci', FILE)
p8v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p8v)


def tcp(src='0.0.0.0/0', port=443, *, source_type='CIDR_BLOCK'):
    return {'protocol': '6', 'source': src, 'source-type': source_type,
            'tcp-options': None if port is None else {
                'destination-port-range': {'min': port, 'max': port},
                'source-port-range': None}}


class OCIUnionTests(unittest.TestCase):
    def test_expected_public_443_is_transport_only(self):
        self.assertEqual(p8v.review_rule(tcp(), '10.1.0.0/24'),
                         ('PENDING', 'public-443-expected-transport-only'))

    def test_global_80_ssh_and_unknown_ports_block(self):
        for port in (80, 22, 444, None):
            with self.subTest(port=port):
                self.assertEqual(p8v.review_rule(tcp(port=port), '10.1.0.0/24')[0], 'BLOCKED')

    def test_port_ranges_cover_http_even_if_not_exact(self):
        for lo, hi in ((20, 65535), (80, 443), (1, 80)):
            rule = tcp()
            rule['tcp-options']['destination-port-range'] = {'min': lo, 'max': hi}
            self.assertEqual(p8v.review_rule(rule, '10.1.0.0/24'),
                             ('BLOCKED', 'public-tcp80'))

    def test_null_destination_tcp_options_are_any_port_not_ignored(self):
        for value in (None, {'source-port-range': None},
                      {'source-port-range': None, 'destination-port-range': None}):
            rule = tcp()
            rule['tcp-options'] = value
            self.assertEqual(p8v.review_rule(rule, '10.1.0.0/24')[0], 'BLOCKED')

    def test_partial_public_source_still_blocks_unapproved_port(self):
        self.assertEqual(p8v.review_rule(tcp('8.8.8.0/24', 80), '10.1.0.0/24')[0], 'BLOCKED')

    def test_unrecognized_schema_rejected_without_pass(self):
        for bad in (
            {'protocol': '6', 'source': '0.0.0.0/0', 'source-type': 'SERVICE_CIDR_BLOCK'},
            {'protocol': '6', 'source': '0.0.0.0', 'source-type': 'CIDR_BLOCK'},
            {'protocol': '6', 'source': None},
            {'protocol': '6', 'source': '0.0.0.0/0', 'tcp-options': {
                'destination-port-range': {'min': True, 'max': 443}}},
            {'protocol': '6', 'source': '0.0.0.0/0', 'tcp-options': {
                'source-port-range': {'min': 1, 'max': 9999}}},
        ):
            with self.subTest(rule=bad):
                self.assertNotEqual(p8v.review_rule(bad, '10.1.0.0/24')[0], 'PASS')

    def test_public_ipv6_and_all_protocol_block(self):
        self.assertEqual(p8v.review_rule(tcp('::/0'), '10.1.0.0/24')[0], 'BLOCKED')
        self.assertEqual(p8v.review_rule({'protocol': 'all', 'source': '0.0.0.0/0'},
                                         '10.1.0.0/24')[0], 'BLOCKED')

    def test_private_ssh_only_expected_source(self):
        self.assertEqual(p8v.review_rule(tcp('10.1.0.0/24', 22), '10.1.0.0/24')[0], 'PASS')
        self.assertNotEqual(p8v.review_rule(tcp('10.2.0.0/24', 22), '10.1.0.0/24')[0], 'PASS')

    def test_null_subnet_ipv6_output_cannot_prove_absence(self):
        v4 = tcp()
        default = {'ingress-security-rules': [tcp(port=22), v4,
                   {'protocol': '1', 'source': '0.0.0.0/0', 'icmp-options': {'type': 3, 'code': 4}},
                   {'protocol': '1', 'source': '10.1.0.0/24'}], 'egress-security-rules': []}
        dedicated = {'id': 'dedicated', 'ingress-security-rules': [tcp('10.1.0.0/24', 22), v4,
                   {'protocol': '1', 'source': '0.0.0.0/0', 'icmp-options': {'type': 3, 'code': 4}},
                   {'protocol': '1', 'source': '10.1.0.0/24'}], 'egress-security-rules': []}
        dedicated['ingress-security-rules'][0]['description'] = 'P8T VM-subnet-only private SSH'
        record = {'subnet': {'cidr-block': '10.1.0.0/24', 'security-list-ids': ['dedicated'],
                             'id': 'subnet'},
                  'vcn': {'default-security-list-id': 'default'},
                  'vnic': {'nsg-ids': []}, 'security_lists': [dedicated], 'default': default,
                  'nsg_rules': [], 'private_ips': [{'vnic-id': 'vnic'}],
                  'approved_vnics': ['vnic'], 'subnets': [], 'ipv6': []}
        rows = p8v.evaluate({'vnics': [record]})
        self.assertIn(('PENDING', 'public-ipv6-absence-not-independently-proven'), rows)
        self.assertIn(('PENDING', 'public-443-expected-transport-only'), rows)
        record['subnet']['ipv6-cidr-blocks'] = []
        record['vcn']['ipv6-cidr-blocks'] = []
        self.assertIn(('PASS', 'scoped-ipv6-assignment-and-cidr-empty'),
                      p8v.evaluate({'vnics': [record]}))
        record['security_lists'][0]['ingress-security-rules'].append(tcp(port=80))
        self.assertIn(('BLOCKED', 'public-tcp80'), p8v.evaluate({'vnics': [record]}))

    def test_bad_effective_rule_and_missing_union_never_pass(self):
        with self.assertRaises(p8v.Incomplete):
            p8v.evaluate({'vnics': []})
        with self.assertRaises(p8v.Incomplete):
            p8v.evaluate({'vnics': [{'security_lists': None}]})


if __name__ == '__main__':
    unittest.main()