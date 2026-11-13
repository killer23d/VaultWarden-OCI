"""P8V-B bounded offline firewall and source-pin negative-path tests."""
import importlib.util
import unittest
from pathlib import Path
from unittest import mock

PATH = Path(__file__).parent / 'host-acceptance/production-p8v-host-layered-readonly.py'
spec = importlib.util.spec_from_file_location('p8v_host', PATH)
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)

HOOK = '-N DOCKER-USER\n-A DOCKER-USER -p tcp -o vwoci0 -m conntrack --ctdir ORIGINAL --ctorigdstport 443 -m comment --comment vaultwarden-oci:cloudflare-https -j VWOCI-CF-HTTPS\n'
CHAIN = '-N VWOCI-CF-HTTPS\n-A VWOCI-CF-HTTPS -s 173.245.48.0/20 -j RETURN\n-A VWOCI-CF-HTTPS -s 103.21.244.0/22 -j RETURN\n-A VWOCI-CF-HTTPS -j DROP\n'
CIDRS = ('173.245.48.0/20', '103.21.244.0/22')


class HostPolicyTests(unittest.TestCase):
    def test_exact_dual_stack_style_family_policy(self):
        self.assertTrue(host.check_filter(HOOK, CHAIN, CIDRS))

    def test_no_final_drop_denied(self):
        self.assertFalse(host.check_filter(HOOK, CHAIN.rsplit('\n', 2)[0] + '\n', CIDRS))

    def test_preceding_accept_bypass_denied(self):
        self.assertFalse(host.check_filter(HOOK + '-A DOCKER-USER -j ACCEPT\n', CHAIN, CIDRS))

    def test_duplicate_jump_denied(self):
        self.assertFalse(host.check_filter(HOOK + HOOK.split('\n')[1] + '\n', CHAIN, CIDRS))

    def test_missing_ipv6_or_ipv4_allow_denied(self):
        self.assertFalse(host.check_filter(HOOK, CHAIN, CIDRS + ('2400:cb00::/32',)))

    def test_cidr_reorder_denied(self):
        self.assertFalse(host.check_filter(HOOK, CHAIN, tuple(reversed(CIDRS))))

    def test_bridge_or_original_direction_mismatch_denied(self):
        self.assertFalse(host.check_filter(HOOK.replace('vwoci0', 'docker0'), CHAIN, CIDRS))
        self.assertFalse(host.check_filter(HOOK.replace('ORIGINAL', 'REPLY'), CHAIN, CIDRS))

    def test_interrupted_transition_guard_not_mistaken_for_finished_policy(self):
        guard = '-A DOCKER-USER -p tcp -o vwoci0 -m conntrack --ctdir ORIGINAL --ctorigdstport 443 -m comment --comment vaultwarden-oci:cloudflare-guard -j DROP\n'
        self.assertFalse(host.check_filter(HOOK + guard, CHAIN, CIDRS))

    def test_missing_git_checkout_is_not_source_pinned(self):
        with mock.patch.object(host, 'ROOT', Path('/nonexistent/p8v-source')):
            self.assertFalse(host.pinned('a' * 40))


    def test_template_uses_readonly_unit_file_and_instance_inventory(self):
        calls = []
        def read(args, seconds=20):
            calls.append(tuple(args))
            if 'list-unit-files' in args:
                return 'vaultwarden-oci-notify@.service static\n'
            if 'list-units' in args:
                return ''
            self.fail('unexpected command')
        with mock.patch.object(host, 'UNITS', ('vaultwarden-oci-notify@.service',)), \
                mock.patch.object(host, 'command', side_effect=read):
            host.product_units_dormant()
        self.assertEqual(len(calls), 2)
        self.assertNotIn('start', ' '.join(' '.join(c) for c in calls))

    def test_dormant_unit_check_separates_real_enabled_service(self):
        unit = 'vaultwarden-oci-backup.timer'
        with mock.patch.object(host, 'UNITS', (unit,)), \
                mock.patch.object(host, 'command', return_value=
                    'LoadState=loaded\nActiveState=inactive\nUnitFileState=enabled\n'):
            with self.assertRaisesRegex(host.HostGap, 'product-service-or-timer-not-dormant'):
                host.product_units_dormant()

    def test_live_listener_is_explicitly_blocked(self):
        with mock.patch.object(host, 'command', return_value=
                'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'):
            with self.assertRaisesRegex(host.HostGap, 'live-application-listener'):
                host.listeners_closed()

    def test_stopped_host_absent_bridge_remains_unverified(self):
        with mock.patch.object(host, 'command', return_value='bridge\nhost\nnone\n'):
            with self.assertRaisesRegex(host.HostGap,
                    'bridge-not-instantiated-on-stopped-host'):
                host.docker_bridge()

if __name__ == '__main__':
    unittest.main()
