"""Offline negative-path tests for the P8V OCI batched read-only provider witness."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import unittest
from unittest import mock

HERE = Path(__file__).parent / "host-acceptance"
spec = importlib.util.spec_from_file_location(
    "p8v_batch", HERE / "production-p8v-oci-provider-batch-readonly.py")
batch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(batch)


class BatchedProviderTests(unittest.TestCase):
    def test_explicit_empty_vnic_ipv6_is_proven_only_when_list(self):
        self.assertEqual(batch.ipv6_vnic_field([])[0], "PASS")
        for value in (None, "null", {}, ["2001:db8::1"]):
            with self.subTest(value=value):
                self.assertEqual(batch.ipv6_vnic_field(value)[0], "PENDING")

    def test_null_or_absent_vcn_and_subnet_fields_do_not_prove_absence(self):
        for doc in ({"ipv6-cidr-blocks": None}, {}, {"ipv6-cidr-blocks": ""}):
            self.assertEqual(batch.ipv6_prefix_fields(doc, "subnet")[0], "PENDING")
        self.assertEqual(batch.ipv6_prefix_fields(
            {"ipv6-cidr-blocks": [], "ipv6-cidr-block": None}, "subnet")[0], "PASS")
        self.assertEqual(batch.ipv6_prefix_fields(
            {"ipv6-cidr-blocks": [], "ipv6-private-cidr-blocks": []}, "vcn")[0], "PASS")
        self.assertEqual(batch.ipv6_prefix_fields(
            {"ipv6-cidr-blocks": None, "ipv6-private-cidr-blocks": []}, "vcn")[0], "PENDING")
        self.assertEqual(batch.ipv6_prefix_fields(
            {"ipv6-cidr-blocks": ["2001:db8::/56"], "ipv6-private-cidr-blocks": []},
            "vcn")[0], "PENDING")

    def test_route_table_needs_parsable_complete_destination_inventory(self):
        self.assertEqual(batch.route_ipv6_evidence([])[0], "PASS")
        self.assertEqual(batch.route_ipv6_evidence([
            {"destination": "0.0.0.0/0", "destination-type": "CIDR_BLOCK"}])[0], "PASS")
        for rules in (
            None, [None], [{"destination": "::/0", "destination-type": "CIDR_BLOCK"}],
            [{"destination": "2001:4860::/32", "destination-type": "CIDR_BLOCK"}],
            [{"destination": "service", "destination-type": "SERVICE_CIDR_BLOCK"}],
            [{"destination": "invalid", "destination-type": "CIDR_BLOCK"}],
        ):
            with self.subTest(rules=rules):
                self.assertEqual(batch.route_ipv6_evidence(rules)[0], "PENDING")

    def test_ipv6_cli_blank_success_is_not_verified_empty(self):
        for raw in (b"", b" ", b"null", b"{}", b"[]",
                    b'{"data":null}', b'{"data":{}}', b"not-json"):
            with self.subTest(raw=raw):
                self.assertNotEqual(batch.classify_ipv6_response(0, raw, b"")[0], "PASS")

    def test_ipv6_cli_explicit_empty_and_nonempty(self):
        self.assertEqual(batch.classify_ipv6_response(
            0, b'{"data":[]}', b""), ("PASS", "ipv6-provider-explicit-empty-list"))
        self.assertEqual(batch.classify_ipv6_response(
            0, b'{"data":[{"id":"not-printed"}]}', b"")[0], "PENDING")
        self.assertEqual(batch.classify_ipv6_response(
            1, b"", b"NotAuthorizedOrNotFound")[0], "PENDING")

    def test_raw_get_requires_200_headers_and_no_pagination(self):
        def record(status="200 OK", headers=None, data=None):
            return json.dumps({"status": status,
                               "headers": headers if headers is not None else {},
                               "data": data if data is not None else []}).encode()
        self.assertEqual(batch.classify_ipv6_response(
            0, record(), b"", raw_request=True)[0], "PASS")
        for raw in (
            record(status="206 Partial Content"),
            record(headers={"opc-next-page": "never-print-this"}),
            record(data=[{"address": "private"}]),
            b'{"status":"200 OK","data":[]}',
        ):
            with self.subTest(raw=raw):
                self.assertEqual(batch.classify_ipv6_response(
                    0, raw, b"", raw_request=True)[0], "PENDING")

    def test_both_api_commands_are_explicitly_read_only(self):
        identity = "ocid1.vnic.oc1.us-sanjose-1.test"
        observed = []
        def fake_call(argv, *, raw_request=False):
            observed.append((argv, raw_request))
            return "PENDING", "ipv6-cli-stdout-empty-or-oversized"
        with mock.patch.object(batch, "invoke", side_effect=fake_call):
            rows = batch.probes(identity)
        self.assertEqual(len(rows), 2)
        self.assertEqual(observed[0][0][:4],
                         ["oci", "network", "ipv6", "list"])
        self.assertIn("--vnic-id", observed[0][0])
        self.assertEqual(observed[1][0][:3], ["oci", "raw-request", "--http-method"])
        self.assertEqual(observed[1][0][3], "GET")
        self.assertTrue(observed[1][1])
        self.assertNotIn("--request-body", observed[1][0])

    def test_missing_git_checkout_does_not_pass_pin(self):
        with mock.patch.object(batch, "ROOT", Path("/unlikely/p8v-absent")):
            self.assertFalse(batch.pinned("a" * 40))


if __name__ == "__main__":
    unittest.main()
