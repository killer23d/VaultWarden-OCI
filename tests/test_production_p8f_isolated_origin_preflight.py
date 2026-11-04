"""P8F new-host isolated origin safety gate: no data, service or cloud mutation."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8f-isolated-origin-preflight.py"
spec = importlib.util.spec_from_file_location("rc12_p8f_new_origin", SCRIPT)
assert spec and spec.loader
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def instance():
    return {
        "id": "ocid1.instance.oc1.fixture123456",
        "shape": "VM.Standard.A1.Flex",
        "displayName": "vaultwarden-oci-7-vnic",
        "metadata": {"ssh_authorized_keys": "VERY_PRIVATE_KEY_MATERIAL"},
    }


def vnics():
    return [{"vnicId": "ocid1.vnic.oc1.fixture123", "privateIp": "10.23.45.67"}]


class FakeResponse:
    def __init__(self, body, url=""):
        self.data = body if isinstance(body, bytes) else __import__("json").dumps(body).encode()
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
    def __init__(self, response):
        self.response = response
        self.requests = []

    def open(self, req, *, timeout):
        self.requests.append((req, timeout))
        return self.response


class P8FTests(unittest.TestCase):
    def test_new_host_required_and_original_prohibited(self):
        self.assertTrue(gate.eligible_host("vaultwarden-oci-7-vnic", "vaultwarden-oci-7-vnic"))
        self.assertTrue(gate.eligible_host("vaultwarden-oci-12-vnic", "vaultwarden-oci-12-vnic"))
        for current, expected in (
            ("vaultwarden-oci-6-vnic", "vaultwarden-oci-6-vnic"),
            ("vaultwarden-oci-6-vnic", "vaultwarden-oci-7-vnic"),
            ("vaultwarden-oci-7-vnic", "vaultwarden-oci-6-vnic"),
            ("production-db", "production-db"),
            ("vaultwarden-oci-7-vnic", "vaultwarden-oci-8-vnic"),
        ):
            self.assertFalse(gate.eligible_host(current, expected))

    def test_exact_source_sha_branch_and_cleanliness(self):
        sha = "a" * 40
        good = [
            SimpleNamespace(returncode=0, stdout=(sha + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=(gate.BRANCH + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=b""),
        ]
        with mock.patch.object(gate.subprocess, "run", side_effect=good):
            self.assertTrue(gate.source_checkout_ok(sha))
        dirty = list(good)
        dirty[-1] = SimpleNamespace(returncode=0, stdout=b" M file")
        with mock.patch.object(gate.subprocess, "run", side_effect=dirty):
            self.assertFalse(gate.source_checkout_ok(sha))
        with mock.patch.object(gate.subprocess, "run") as invocation:
            self.assertFalse(gate.source_checkout_ok("bad-sha"))
            invocation.assert_not_called()

    def test_unit_absence_is_fail_closed(self):
        with mock.patch.object(gate, "command", return_value=(
            0, "LoadState=not-found\nActiveState=inactive\nUnitFileState=\n",
        )):
            self.assertTrue(gate.units_are_absent())
        with mock.patch.object(gate, "command", return_value=(
            0, "LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled\n",
        )):
            self.assertFalse(gate.units_are_absent())
        with mock.patch.object(gate, "command", return_value=(None, "")):
            self.assertFalse(gate.units_are_absent())

    def test_local_tcp_listeners_are_distinct_from_oci_rules(self):
        with mock.patch.object(gate, "command", return_value=(0,
            "LISTEN 0 128 127.0.0.1:22 0.0.0.0:*\n"
            "LISTEN 0 512 [::]:443 [::]:*\n")):
            self.assertEqual(gate.listening_80_443(), (False, True))
        with mock.patch.object(gate, "command", return_value=(0,
            "LISTEN 0 128 0.0.0.0:80 0.0.0.0:*\n")):
            self.assertEqual(gate.listening_80_443(), (True, False))
        with mock.patch.object(gate, "command", return_value=(0, "")):
            self.assertEqual(gate.listening_80_443(), (False, False))
        with mock.patch.object(gate, "command", return_value=(None, "")):
            with self.assertRaises(gate.Blocked):
                gate.listening_80_443()

    def test_imds_second_version_bounded_link_local_get(self):
        url = gate.IMDS + "/instance/"
        opener = FakeOpener(FakeResponse(instance(), url))
        result = gate.imds_json("instance", opener=opener)
        self.assertEqual(result["shape"], "VM.Standard.A1.Flex")
        req, timeout = opener.requests[0]
        self.assertEqual(req.get_method(), "GET")
        self.assertEqual(req.full_url, url)
        self.assertEqual(req.get_header("Authorization"), "Bearer Oracle")
        self.assertLessEqual(timeout, 6)
        with self.assertRaises(ValueError):
            gate.imds_json("cloudflare", opener=opener)
        for resp, expected in (
            (FakeResponse(instance(), "http://redirect.example/"), "redirect"),
            (FakeResponse(b"x" * (gate.IMDS_MAX + 1), url), "oversize"),
            (FakeResponse(b"no json here", url), "invalid_json"),
        ):
            with self.subTest(expected=expected):
                with self.assertRaises(gate.MetadataBlocked) as raised:
                    gate.imds_json("instance", opener=FakeOpener(resp))
                self.assertEqual(raised.exception.code, expected)

    def test_oci_sanitized_fingerprints_and_name_not_authoritative(self):
        a, b, match = gate.classify_oci(instance(), vnics(), "vaultwarden-oci-7-vnic")
        self.assertTrue(match)
        self.assertIn("VNIC_count=1", a)
        self.assertIn("fingerprints=", b)
        for sensitive in ("ocid1.", "10.23.45.67", "VERY_PRIVATE_KEY_MATERIAL"):
            self.assertNotIn(sensitive, a + b)
        changed = instance()
        changed["displayName"] = "a-different-name"
        _, _, match = gate.classify_oci(changed, vnics(), "vaultwarden-oci-7-vnic")
        self.assertFalse(match)

    def test_oci_structural_errors_refuse_without_leaking_values(self):
        wrong = instance()
        wrong["shape"] = "VM.Standard.E5.Flex"
        with self.assertRaises(gate.MetadataBlocked) as raised:
            gate.classify_oci(wrong, vnics(), "vaultwarden-oci-7-vnic")
        self.assertEqual(raised.exception.code, "shape")
        for bad, label in (
            ([{**vnics()[0], "privateIp": "8.8.8.8"}], "vnic_private_ip"),
            ([{**vnics()[0], "vnicId": "secret-invalid-id"}], "vnic_id"),
            (vnics() * 2, "duplicate_vnic_id"),
            ([], "vnic_schema"),
        ):
            with self.subTest(label=label):
                with self.assertRaises(gate.MetadataBlocked) as raised:
                    gate.classify_oci(instance(), bad, "vaultwarden-oci-7-vnic")
                self.assertEqual(raised.exception.code, label)
                self.assertNotIn("8.8.8.8", str(raised.exception))
                self.assertNotIn("secret-invalid-id", str(raised.exception))
        with self.assertRaises(ValueError):
            gate.MetadataBlocked("cloud-returned-private-secret")

    def test_nonboot_disks_are_never_selected_by_guessing(self):
        fake_storage = SimpleNamespace(
            root_source=lambda: "/dev/mockroot",
            inventory=lambda: [],
        )
        self.assertEqual(gate.disk_summary(fake_storage), (0, 0, []))
        fake_storage.inventory = lambda: [{
            "path": "/dev/testdisk", "type": "disk", "size": 50 * 1024 ** 3,
            "fstype": "", "mountpoints": (),
        }]
        with mock.patch.object(gate.Path, "is_block_device", return_value=True), \
             mock.patch.object(gate.Path, "resolve", return_value=Path("/dev/testdisk")), \
             mock.patch.object(gate.Path, "iterdir", return_value=[Path("/dev/disk/by-id/scsi-fixture")]), \
             mock.patch.object(gate.Path, "is_symlink", return_value=True), \
             mock.patch.object(gate, "command", return_value=(0, "")):
            blank, disks, names = gate.disk_summary(fake_storage)
        self.assertEqual((blank, disks, names), (1, 1, ["blank-candidate"]))
        fake_storage.inventory = lambda: [{
            "path": "/dev/testdisk", "type": "disk", "size": 50 * 1024 ** 3,
            "fstype": "ext4", "mountpoints": (),
        }]
        with mock.patch.object(gate.Path, "is_block_device", return_value=True), \
             mock.patch.object(gate.Path, "resolve", return_value=Path("/dev/testdisk")), \
             mock.patch.object(gate.Path, "iterdir", return_value=[]), \
             mock.patch.object(gate, "command", return_value=(0, "ext4")):
            blank, _, names = gate.disk_summary(fake_storage)
        self.assertEqual(blank, 0)
        self.assertIn("contains-signatures-not-approved", names)

    def test_private_summary_uses_hold_for_safe_pending_not_go(self):
        with tempfile.TemporaryDirectory() as name:
            report = gate.Report(Path(name))
            report.add("PASS", "Clean host")
            report.add("PENDING", "External ingress not independently proven")
            with self.assertRaises(ValueError):
                report.add("PASS", "unsafe\nprivate")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 0)
            txt = (Path(name) / "summary.txt").read_text()
            self.assertIn("HOLD", txt)
            self.assertIn("NOT AUTHORIZED", txt)
        with tempfile.TemporaryDirectory() as name:
            report = gate.Report(Path(name))
            report.add("BLOCKED", "Old host")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 2)

    def test_original_host_rejected_before_evidence_or_imds(self):
        with mock.patch.object(gate.sys, "argv", [
            "p8f", "--expected-commit", "a" * 40,
            "--expected-host", gate.ORIGINAL,
        ]), mock.patch.object(gate.os, "geteuid", return_value=0), \
             mock.patch.dict(gate.os.environ, {"SUDO_USER": "ubuntu"}), \
             mock.patch.object(gate.platform, "node", return_value=gate.ORIGINAL), \
             mock.patch.object(gate, "private_evidence") as output, \
             mock.patch.object(gate, "imds_json") as imds, \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(gate.main(), 2)
            output.assert_not_called()
            imds.assert_not_called()

    def test_safe_main_never_grants_live_start(self):
        with tempfile.TemporaryDirectory() as name:
            with mock.patch.object(gate.sys, "argv", [
                "p8f", "--expected-commit", "a" * 40,
                "--expected-host", "vaultwarden-oci-7-vnic",
            ]), mock.patch.object(gate.os, "geteuid", return_value=0), \
                 mock.patch.dict(gate.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(gate.platform, "node", return_value="vaultwarden-oci-7-vnic"), \
                 mock.patch.object(gate, "source_checkout_ok", return_value=True), \
                 mock.patch.object(gate, "os_supported", return_value=True), \
                 mock.patch.object(gate, "private_evidence", return_value=Path(name)), \
                 mock.patch.object(gate, "units_are_absent", return_value=True), \
                 mock.patch.object(gate, "listening_80_443", return_value=(False, False)), \
                 mock.patch.object(gate, "disk_summary", return_value=(0, 0, [])), \
                 mock.patch.object(gate, "imds_json", side_effect=[instance(), vnics()]), \
                 mock.patch.object(gate.Path, "exists", return_value=False), \
                 mock.patch.object(gate.Path, "is_symlink", return_value=False), \
                 mock.patch.object(gate, "command", return_value=(0, "yes")):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(gate.main(), 0)
                self.assertIn("HOLD", output.getvalue())
                self.assertIn("blank-stable candidates=0", output.getvalue())
                self.assertIn("OCI A1 Flex instance", output.getvalue())
                self.assertIn("PENDING", output.getvalue())
                self.assertNotIn("10.23.45.67", output.getvalue())

    def test_acceptance_code_contains_no_mutating_invocations(self):
        text = SCRIPT.read_text(encoding="utf-8")
        for action in (
            '["systemctl", "start"', '["systemctl", "reboot"',
            '["vwctl", "start"', '["vwctl", "backup"',
            '["docker", "compose", "up"', '["rclone", "copy"',
            '["mkfs.ext4"', '["mount",', '["apt-get"',
            "urllib.request.urlopen(", "requests.post(", "subprocess.Popen(",
        ):
            self.assertNotIn(action, text)
        self.assertIn("urllib.request.ProxyHandler({})", text)
        self.assertIn("NoRedirect()", text)


if __name__ == "__main__":
    unittest.main()
