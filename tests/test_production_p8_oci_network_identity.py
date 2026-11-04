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
            self.assertFalse(p8e.guest_name_matches(data))
            self.assertIn("VNICs=1", p8e.summarize_metadata(data, good_vnics())[0])
        data = good_instance()
        data["displayName"] = "another-label"
        data["hostname"] = p8e.HOST + ".oraclevcn.com"
        self.assertTrue(p8e.guest_name_matches(data))
        data = good_instance()
        data["shape"] = "VM.Standard.E5.Flex"
        with self.assertRaises(p8e.MetadataContractError) as ctx:
            p8e.summarize_metadata(data, good_vnics())
        self.assertEqual(ctx.exception.category, "instance_shape_unexpected")
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

    def test_only_fixed_imds_metadata_paths_with_authorization_header(self):
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
        with self.assertRaises(p8e.MetadataContractError) as ctx:
            p8e.metadata_json("instance", opener=redirected)
        self.assertEqual(ctx.exception.category, "redirect_or_wrong_endpoint")

    def test_payload_size_and_json_fail_closed(self):
        response = FakeResponse(good_instance())
        response.data = b"{" + b"a" * (p8e.IMDS_MAX_BYTES + 1)
        with self.assertRaises(p8e.MetadataContractError) as ctx:
            p8e.metadata_json("instance", opener=SimpleNamespace(open=lambda *a, **k: response))
        self.assertEqual(ctx.exception.category, "oversized_response")
        response.data = b"secrets-not-json"
        with self.assertRaises(p8e.MetadataContractError) as ctx:
            p8e.metadata_json("instance", opener=SimpleNamespace(open=lambda *a, **k: response))
        self.assertEqual(ctx.exception.category, "invalid_json")

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


    def test_metadata_schema_classification_does_not_leak_raw_values(self):
        cases = [
            ([], good_vnics(), "instance_not_object"),
            (good_instance(), {}, "vnics_not_expected_array"),
            ({**good_instance(), "id": "unsafe"}, good_vnics(), "instance_ocid_invalid"),
            (good_instance(), [None], "vnic_not_object"),
            (good_instance(), [{**good_vnics()[0], "vnicId": "bad"}], "vnic_ocid_invalid"),
            (good_instance(), [{**good_vnics()[0], "privateIp": None}], "vnic_private_ipv4_malformed"),
            (good_instance(), [{**good_vnics()[0], "privateIp": "1.1.1.1"}], "vnic_private_ipv4_unexpected"),
            (good_instance(), [{**good_vnics()[0], "publicIp": "sensitive-invalid-ip"}], "vnic_public_ipv4_malformed"),
            (good_instance(), good_vnics() * 2, "duplicate_vnic_ocid"),
        ]
        for instance, vnics, code in cases:
            with self.subTest(code=code):
                with self.assertRaises(p8e.MetadataContractError) as raised:
                    p8e.summarize_metadata(instance, vnics)
                self.assertEqual(raised.exception.category, code)
                self.assertNotIn("1.1.1.1", str(raised.exception))
                self.assertNotIn("sensitive-invalid-ip", str(raised.exception))
        with self.assertRaises(ValueError):
            p8e.MetadataContractError("private_value_from_cloud")

    def test_metadata_diagnostic_failure_exits_blocked_without_dumping_values(self):
        class FakeHostReport:
            def __init__(self, *args):
                self.rows = [("PASS", "All five local origin/CrowdSec security doctor IDs and storage.dedicated PASS")]

        with tempfile.TemporaryDirectory() as name:
            p7 = SimpleNamespace(
                safe_base=lambda: Path(name), Report=FakeHostReport,
                host_snapshot=lambda *args, **kwargs: None,
            )
            bad_vnic = [{**good_vnics()[0], "vnicId": "secret-id-value"}]
            with mock.patch.object(p8e.sys, "argv", ["p8e", "--expected-commit", "a" * 40]), \
                 mock.patch.object(p8e.os, "geteuid", return_value=0), \
                 mock.patch.dict(p8e.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(p8e.platform, "node", return_value=p8e.HOST), \
                 mock.patch.object(p8e.platform, "machine", return_value="aarch64"), \
                 mock.patch.object(p8e, "reviewed_source", return_value=p7), \
                 mock.patch.object(p8e, "exact_checkout", return_value=True), \
                 mock.patch.object(p8e, "accepted_p8a_summary", return_value=True), \
                 mock.patch.object(p8e, "metadata_json", side_effect=[good_instance(), bad_vnic]) as fetch:
                printed = io.StringIO()
                with contextlib.redirect_stdout(printed):
                    self.assertEqual(p8e.main(), 2)
                self.assertEqual(fetch.call_count, 2)
                self.assertIn("category=vnic_ocid_invalid", printed.getvalue())
                self.assertNotIn("secret-id-value", printed.getvalue())
                self.assertNotIn("ocid1.instance.", printed.getvalue())
                self.assertIn("BLOCKED", printed.getvalue())

    def test_display_name_mismatch_is_pending_without_weakening_identity_proof(self):
        class FakeHostReport:
            def __init__(self, *args):
                self.rows = [("PASS", "All five local origin/CrowdSec security doctor IDs and storage.dedicated PASS")]

        with tempfile.TemporaryDirectory() as name:
            p7 = SimpleNamespace(
                safe_base=lambda: Path(name), Report=FakeHostReport,
                host_snapshot=lambda *args, **kwargs: None,
            )
            inst = good_instance()
            inst["displayName"] = "some-other-instance-label"
            with mock.patch.object(p8e.sys, "argv", ["p8e", "--expected-commit", "a" * 40]), \
                 mock.patch.object(p8e.os, "geteuid", return_value=0), \
                 mock.patch.dict(p8e.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(p8e.platform, "node", return_value=p8e.HOST), \
                 mock.patch.object(p8e.platform, "machine", return_value="aarch64"), \
                 mock.patch.object(p8e, "reviewed_source", return_value=p7), \
                 mock.patch.object(p8e, "exact_checkout", return_value=True), \
                 mock.patch.object(p8e, "accepted_p8a_summary", return_value=True), \
                 mock.patch.object(p8e, "metadata_json", side_effect=[inst, good_vnics()]):
                printed = io.StringIO()
                with contextlib.redirect_stdout(printed):
                    self.assertEqual(p8e.main(), 0)
                self.assertIn("display name/hostname differs", printed.getvalue())
                self.assertIn("PENDING", printed.getvalue())
                self.assertIn("HOLD", printed.getvalue())
                self.assertNotIn("some-other-instance-label", printed.getvalue())

    def test_metadata_http_errors_report_numeric_status_only(self):
        import urllib.error

        class FakeHostReport:
            def __init__(self, *args):
                self.rows = [("PASS", "All five local origin/CrowdSec security doctor IDs and storage.dedicated PASS")]

        with tempfile.TemporaryDirectory() as name:
            p7 = SimpleNamespace(
                safe_base=lambda: Path(name), Report=FakeHostReport,
                host_snapshot=lambda *args, **kwargs: None,
            )
            failure = urllib.error.HTTPError(
                "http://private/path", 429, "sensitive reason", {}, None
            )
            with mock.patch.object(p8e.sys, "argv", ["p8e", "--expected-commit", "a" * 40]), \
                 mock.patch.object(p8e.os, "geteuid", return_value=0), \
                 mock.patch.dict(p8e.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(p8e.platform, "node", return_value=p8e.HOST), \
                 mock.patch.object(p8e.platform, "machine", return_value="aarch64"), \
                 mock.patch.object(p8e, "reviewed_source", return_value=p7), \
                 mock.patch.object(p8e, "exact_checkout", return_value=True), \
                 mock.patch.object(p8e, "accepted_p8a_summary", return_value=True), \
                 mock.patch.object(p8e, "metadata_json", side_effect=failure):
                printed = io.StringIO()
                with contextlib.redirect_stdout(printed):
                    self.assertEqual(p8e.main(), 0)
                self.assertIn("HTTP status=429", printed.getvalue())
                self.assertNotIn("sensitive reason", printed.getvalue())
                self.assertNotIn("private/path", printed.getvalue())
                self.assertIn("PENDING", printed.getvalue())
                self.assertIn("HOLD", printed.getvalue())

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
