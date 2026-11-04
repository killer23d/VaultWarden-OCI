"""P8E isolated-network identity inventory: fail-closed, no-cloud-mutation tests."""
from __future__ import annotations

import contextlib
import importlib.util
import inspect
import io
import json
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8-oci-network-identity.py"
spec = importlib.util.spec_from_file_location("rc12_p8e_network", SCRIPT)
assert spec and spec.loader
p8e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p8e)


class FakeResponse:
    def __init__(self, payload, *, url=None):
        self.data = json.dumps(payload).encode("utf-8")
        self.url = url

    def geturl(self):
        return self.url

    def read(self, maximum):
        return self.data[:maximum]

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class FakeOpener:
    def __init__(self, payload, *, url=None):
        self.payload, self.url = payload, url
        self.requests = []

    def open(self, req, *, timeout):
        self.requests.append((req, timeout))
        return FakeResponse(self.payload, url=self.url or req.full_url)


def good_instance():
    return {
        "id": "ocid1.instance.oc1.fakeexample12345",
        "displayName": p8e.HOST, "shape": "VM.Standard.A1.Flex",
        "metadata": {"ssh_authorized_keys": "DO_NOT_PRINT_ME"},
    }


def good_vnics():
    return [{"vnicId": "ocid1.vnic.oc1.fakeexample12345", "privateIp": "10.0.0.15"}]


class NetworkIdentityTests(unittest.TestCase):
    def test_identity_fingerprints_never_expose_ocids_or_ssh_keys(self):
        a, b = p8e.summarize_metadata(good_instance(), good_vnics())
        for sensitive in ("ocid1.", "DO_NOT_PRINT_ME", "10.0.0.15"):
            self.assertNotIn(sensitive, a + b)
        self.assertIn("VNICs=1", a)
        self.assertIn("reported_public_IPv4=0", b)
        self.assertIn("absence is NOT proof", b)
        self.assertEqual(len(p8e.fingerprint("ocid1.example")), 12)

    def test_strict_wrong_host_shape_invalid_ips_and_duplicate_vnics(self):
        for name in ("different-host", "unexpected"):
            data = good_instance()
            data["displayName"] = name
            with self.assertRaises(p8e.Blocked):
                p8e.summarize_metadata(data, good_vnics())
        data = good_instance()
        data["shape"] = "VM.Standard.E5.Flex"
        with self.assertRaises(p8e.Blocked):
            p8e.summarize_metadata(data, good_vnics())
        for ip in ("not_an_ip", "8.8.8.8", "2001:db8::1", None):
            bad = good_vnics()
            bad[0]["privateIp"] = ip
            with self.assertRaises(p8e.Blocked):
                p8e.summarize_metadata(good_instance(), bad)
        with self.assertRaises(p8e.Blocked):
            p8e.summarize_metadata(good_instance(), good_vnics() * 2)

    def test_vnic_readback_does_not_infer_ipv6_public_routing(self):
        vnics = good_vnics()
        vnics[0]["ipv6SubnetCidrBlocks"] = ["2001:db8::/64"]
        vnics[0]["publicIp"] = "198.51.100.4"
        _, line = p8e.summarize_metadata(good_instance(), vnics)
        self.assertIn("IPv6_subnet_indications=1", line)
        self.assertIn("reported_public_IPv4=1", line)
        self.assertNotIn("198.51.100.4", line)
        self.assertNotIn("2001:db8", line)

    def test_only_fixed_v2_metadata_paths_with_authorization_header(self):
        opener = FakeOpener(good_instance())
        data = p8e.metadata_json("instance", opener=opener)
        self.assertEqual(data["displayName"], p8e.HOST)
        req, timeout = opener.requests[0]
        self.assertEqual(req.get_method(), "GET")
        self.assertEqual(req.full_url, "http://169.254.169.254/opc/v2/instance/")
        self.assertEqual(req.get_header("Authorization"), "Bearer Oracle")
        self.assertLessEqual(timeout, 6)
        with self.assertRaises(ValueError):
            p8e.metadata_json("cloudflare", opener=opener)
        redirected = FakeOpener(good_instance(), url="https://attacker.example/path")
        with self.assertRaises(p8e.Blocked):
            p8e.metadata_json("instance", opener=redirected)

    def test_payload_size_and_json_fail_closed(self):
        response = FakeResponse(good_instance())
        response.data = b"{" + b"a" * (p8e.IMDS_MAX_BYTES + 1)
        with self.assertRaises(p8e.Blocked):
            p8e.metadata_json("instance", opener=SimpleNamespace(open=lambda *a, **k: response))
        response.data = b"secrets-not-json"
        with self.assertRaises(p8e.Blocked):
            p8e.metadata_json("instance", opener=SimpleNamespace(open=lambda *a, **k: response))

    def test_checkout_pin_and_dirty_refusal(self):
        sha = "a" * 40
        with mock.patch.object(p8e.subprocess, "run", side_effect=[
            SimpleNamespace(returncode=0, stdout=(sha + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=(p8e.BRANCH + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=b""),
        ]):
            self.assertTrue(p8e.exact_checkout(sha))
        with mock.patch.object(p8e.subprocess, "run", side_effect=[
            SimpleNamespace(returncode=0, stdout=(sha + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=(p8e.BRANCH + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=b" M README.md"),
        ]):
            self.assertFalse(p8e.exact_checkout(sha))
        self.assertFalse(p8e.exact_checkout("not-sha"))

    def test_no_prior_accepted_p8a_evidence_never_false_passes(self):
        with tempfile.TemporaryDirectory() as name:
            self.assertFalse(p8e.accepted_p8a_summary(Path(name) / "not-existing"))

    def test_report_is_sanitized_and_hold_is_not_pass(self):
        with tempfile.TemporaryDirectory() as name:
            report = p8e.Report(Path(name))
            report.add("PASS", "Instance inventory is structurally valid")
            report.add("PENDING", "OCI authoritative rules unknown")
            with self.assertRaises(ValueError):
                report.add("PASS", "bad\nsecret")
            with self.assertRaises(ValueError):
                report.add("REARMED", "not a consent gate")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 0)
            summary = (Path(name) / "summary.txt").read_text()
            self.assertIn("HOLD", summary)
            self.assertIn("PENDING", summary)
        with tempfile.TemporaryDirectory() as name:
            report = p8e.Report(Path(name))
            report.add("BLOCKED", "unexpected VNIC ID")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 2)

    def test_no_mutation_call_in_reviewed_acceptance_script(self):
        source = SCRIPT.read_text(encoding="utf-8")
        forbidden = [
            "systemctl start", "systemctl reboot", "vwctl start",
            "docker compose up", "rclone copy", "cloudflare_api_token",
            "mutation_lock(", "requests.post(", "urllib.request.urlopen(",
        ]
        for term in forbidden:
            self.assertNotIn(term, source)
        self.assertIn("urllib.request.ProxyHandler({})", source)
        self.assertIn("NoRedirect()", source)

    def test_invalid_invocation_never_queries_imds(self):
        with mock.patch.object(p8e.sys, "argv", ["p8e"]), \
             mock.patch.object(p8e, "metadata_json") as imds, \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(p8e.main(), 2)
            imds.assert_not_called()
        with mock.patch.object(p8e.sys, "argv", ["p8e", "--expected-commit", "a"*40]), \
             mock.patch.object(p8e.os, "geteuid", return_value=1001), \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(p8e.main(), 2)


if __name__ == "__main__":
    unittest.main()
