"""P8G read-only new-host storage/OCI continuity and fail-closed evidence tests."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8g-storage-network-witness.py"
spec = importlib.util.spec_from_file_location("rc12_p8g_witness", SCRIPT)
assert spec and spec.loader
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class FakeResponse:
    def __init__(self, body: object, url: str):
        self.body = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.url = url

    def geturl(self):
        return self.url

    def read(self, max_size: int):
        return self.body[:max_size]

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class FakeOpener:
    def __init__(self, response: FakeResponse):
        self.response = response
        self.requests = []

    def open(self, request, *, timeout):
        self.requests.append((request, timeout))
        return self.response


def instance():
    return {
        "id": "ocid1.instance.oc1.testfake",
        "shape": "VM.Standard.A1.Flex",
        "displayName": gate.HOST,
        "metadata": {"ssh_authorized_keys": "HIDDEN_PRIVATE_KEY"},
    }


def vnics():
    return [{"vnicId": "ocid1.vnic.oc1.testfake", "privateIp": "10.0.4.8"}]


def fake_storage(*, fstype="", mounted=(), size=50 * 1024 ** 3, uuid=""):
    return SimpleNamespace(
        root_source=lambda: "/dev/mockboot",
        reject_boot_related=lambda p: None,
        inventory=lambda: [{
            "path": "/dev/testdisk",
            "type": "disk",
            "size": size,
            "fstype": fstype,
            "mountpoints": mounted,
            "uuid": uuid,
        }],
    )


class P8GWitnessTests(unittest.TestCase):
    def test_original_host_and_branch_checkout_cannot_be_used(self):
        self.assertEqual(gate.HOST, "vaultwarden-oci-7-vnic")
        pin = "a" * 40
        good = [
            SimpleNamespace(returncode=0, stdout=(pin + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=(gate.BRANCH + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=b""),
        ]
        with mock.patch.object(gate.subprocess, "run", side_effect=good):
            self.assertTrue(gate.clean_pin(pin))
        with mock.patch.object(gate.subprocess, "run", side_effect=good[:-1] + [
            SimpleNamespace(returncode=0, stdout=b" M altered")
        ]):
            self.assertFalse(gate.clean_pin(pin))
        with mock.patch.object(gate.subprocess, "run") as subprocess_stub:
            self.assertFalse(gate.clean_pin("incorrect"))
            subprocess_stub.assert_not_called()
        with mock.patch.object(gate.platform, "node", return_value="vaultwarden-oci-6-vnic"):
            self.assertFalse(gate.target_os())

    def test_original_p8f_read_only_hold_required(self):
        text = "\n".join([
            "Gate P8F - new isolated OCI ARM64 host preflight (READ-ONLY)",
            "PASS       New operator-specified guest identity, exact clean candidate and Ubuntu 26.04 ARM64 rc.12 source",
            "PASS       No appliance install/data/units or preexisting Docker state",
            "PASS       No local TCP 80/443 listener; this does NOT verify OCI ingress",
            "PASS       Non-boot disks=1 blank-stable candidates=1; classes=blank-candidate",
            "PASS       OCI A1 Flex instance fingerprint=0dccfd58cbbd VNIC_count=1",
            "PASS       VNIC fingerprints=36862e16cc9f (address and OCID values withheld)",
            "PASS       NTP synchronized",
            "HOLD       P8F fresh-origin inventory only; install, restore and live startup NOT AUTHORIZED",
        ])
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            self.assertFalse(gate.p8f_evidence(base))
            with mock.patch.object(gate, "safe_directory", return_value=True), \
                 mock.patch.object(gate, "read_private_file", return_value=text):
                self.assertTrue(gate.p8f_evidence(base))
            with mock.patch.object(gate, "safe_directory", return_value=True), \
                 mock.patch.object(gate, "read_private_file", return_value=text + "\nBLOCKED something"):
                self.assertFalse(gate.p8f_evidence(base))
            with mock.patch.object(gate, "safe_directory", return_value=True), \
                 mock.patch.object(gate, "read_private_file", return_value=text.replace(
                    "blank-stable candidates=1", "blank-stable candidates=0"
                 )):
                self.assertFalse(gate.p8f_evidence(base))

    def test_still_no_installed_appliance_or_443_listener(self):
        no_units = (
            0, "LoadState=not-found\nActiveState=inactive\nUnitFileState=\n"
        )
        with mock.patch.object(gate.Path, "exists", return_value=False), \
             mock.patch.object(gate.Path, "is_symlink", return_value=False), \
             mock.patch.object(gate, "command", side_effect=lambda args, **kwargs:
                  no_units if args[0] == "systemctl" else (0, "")):
            self.assertTrue(gate.fresh_appliance_state())
        with mock.patch.object(gate.Path, "exists", return_value=False), \
             mock.patch.object(gate.Path, "is_symlink", return_value=False), \
             mock.patch.object(gate, "command", side_effect=lambda args, **kwargs:
                  no_units if args[0] == "systemctl" else
                  (0, "LISTEN 0 512 [::]:443 [::]:*\n")):
            self.assertFalse(gate.fresh_appliance_state())
        with mock.patch.object(gate.Path, "exists", return_value=False), \
             mock.patch.object(gate.Path, "is_symlink", return_value=False), \
             mock.patch.object(gate, "command", return_value=(
                 0, "LoadState=loaded\nActiveState=active\nUnitFileState=enabled\n"
             )):
            self.assertFalse(gate.fresh_appliance_state())

    def test_bounded_link_local_oci_metadata_get(self):
        url = gate.IMDS_ORIGIN + "/instance/"
        opener = FakeOpener(FakeResponse(instance(), url))
        self.assertEqual(gate.metadata("instance", opener=opener)["shape"], "VM.Standard.A1.Flex")
        req, timeout = opener.requests[0]
        self.assertEqual(req.get_method(), "GET")
        self.assertEqual(req.full_url, url)
        self.assertEqual(req.get_header("Authorization"), "Bearer Oracle")
        self.assertLessEqual(timeout, 6)
        with self.assertRaises(ValueError):
            gate.metadata("cloudflare", opener=opener)
        for body, response_url, code in (
            (instance(), "https://example.invalid/external", "response_redirect"),
            (b"x" * (gate.MAX_METADATA + 1), url, "response_oversize"),
            (b"malformed secret json", url, "response_invalid_json"),
        ):
            with self.subTest(code=code):
                with self.assertRaises(gate.MetadataRefusal) as caught:
                    gate.metadata("instance", opener=FakeOpener(FakeResponse(body, response_url)))
                self.assertEqual(caught.exception.code, code)
                self.assertNotIn("malformed secret", str(caught.exception))

    def test_oci_fingerprint_must_match_original_instance_and_vnic(self):
        tags = {
            "ocid1.instance.oc1.testfake": gate.INSTANCE_FP,
            "ocid1.vnic.oc1.testfake": gate.VNIC_FP,
        }
        with mock.patch.object(gate, "sha_tag", side_effect=lambda s: tags.get(s, "unexpected")):
            self.assertTrue(gate.fingerprint_oci(instance(), vnics()))
            other = instance()
            other["displayName"] = "custom-console-label"
            self.assertFalse(gate.fingerprint_oci(other, vnics()))
            changed = instance()
            changed["id"] = "ocid1.instance.oc1.someother"
            with self.assertRaises(gate.MetadataRefusal) as caught:
                gate.fingerprint_oci(changed, vnics())
            self.assertEqual(caught.exception.code, "instance_identity_changed")
            different_vnic = [{**vnics()[0], "vnicId": "ocid1.vnic.oc1.new"}]
            with self.assertRaises(gate.MetadataRefusal) as caught:
                gate.fingerprint_oci(instance(), different_vnic)
            self.assertEqual(caught.exception.code, "vnic_identity_changed")
            bad = instance()
            bad["shape"] = "VM.Standard.E4.Flex"
            with self.assertRaises(gate.MetadataRefusal) as caught:
                gate.fingerprint_oci(bad, vnics())
            self.assertEqual(caught.exception.code, "shape_mismatch")

    def test_disk_blank_and_alias_proof_with_local_private_details(self):
        fs = fake_storage()
        with mock.patch.object(gate.Path, "resolve", return_value=Path("/dev/approved-disk")), \
             mock.patch.object(gate.Path, "is_block_device", return_value=True), \
             mock.patch.object(gate, "stable_disk_aliases", return_value=("/dev/disk/by-id/scsi-test",)), \
             mock.patch.object(gate, "command", side_effect=[
                (0, "disk\n"), (0, ""),
             ]):
            public, private = gate.blank_disk_witness(fs)
        self.assertIn("capacity_GiB=50", public)
        self.assertIn("alias_fingerprint=", public)
        self.assertNotIn("/dev/approved-disk", public)
        self.assertNotIn("scsi-test", public)
        self.assertIn("resolved_block_path=", private)
        self.assertIn("stable_by_id=/dev/disk/by-id/scsi-test", private)
        self.assertIn("NOT_AUTHORIZED_TO_FORMAT_OR_INSTALL", private)

    def test_disk_with_partitions_or_filesystem_refused(self):
        with mock.patch.object(gate.Path, "resolve", return_value=Path("/dev/approved-disk")), \
             mock.patch.object(gate.Path, "is_block_device", return_value=True), \
             mock.patch.object(gate, "stable_disk_aliases", return_value=("/dev/disk/by-id/scsi-test",)):
            for disk in (fake_storage(fstype="ext4"), fake_storage(mounted=("/mnt",)),
                         fake_storage(uuid="some-uuid")):
                with self.assertRaises(gate.Refusal):
                    gate.blank_disk_witness(disk)
            with mock.patch.object(gate, "command", return_value=(0, "disk\npart\n")):
                with self.assertRaises(gate.Refusal):
                    gate.blank_disk_witness(fake_storage())
            with mock.patch.object(gate, "command", side_effect=[(0, "disk\n"), (0, "ext4\n")]):
                with self.assertRaises(gate.Refusal):
                    gate.blank_disk_witness(fake_storage())
            with mock.patch.object(gate, "command", side_effect=[(0, "disk\n"), (None, "")]):
                with self.assertRaises(gate.Refusal):
                    gate.blank_disk_witness(fake_storage())

    def test_incomplete_disk_or_missing_stable_alias_refused(self):
        disk = fake_storage()
        disk.inventory = lambda: []
        with self.assertRaises(gate.Refusal):
            gate.blank_disk_witness(disk)
        with mock.patch.object(gate.Path, "resolve", return_value=Path("/dev/approved-disk")), \
             mock.patch.object(gate.Path, "is_block_device", return_value=True), \
             mock.patch.object(gate, "stable_disk_aliases", return_value=()), \
             mock.patch.object(gate, "command", side_effect=[(0, "disk\n"), (0, "")]):
            with self.assertRaises(gate.Refusal):
                gate.blank_disk_witness(fake_storage())

    def test_private_report_hold_and_blocked_without_external_pass(self):
        with tempfile.TemporaryDirectory() as name:
            report = gate.Report(Path(name))
            report.add("PASS", "Blank disk read-only witnessed")
            report.add("PENDING", "OCI authoritative routing unknown")
            with self.assertRaises(ValueError):
                report.add("PASS", "sensitive\nraw")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 0)
            text = (Path(name) / "summary.txt").read_text()
            self.assertIn("HOLD", text)
            self.assertIn("NOT RUN", "NOT RUN")
            self.assertIn("no install, restore", text)
        with tempfile.TemporaryDirectory() as name:
            report = gate.Report(Path(name))
            report.add("BLOCKED", "Disk has partitions")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 2)

    def test_wrong_host_refuses_before_writing_or_probing(self):
        with mock.patch.object(gate.sys, "argv", ["p8g", "--expected-commit", "a" * 40]), \
             mock.patch.object(gate.os, "geteuid", return_value=0), \
             mock.patch.dict(gate.os.environ, {"SUDO_USER": "ubuntu"}), \
             mock.patch.object(gate.platform, "node", return_value="vaultwarden-oci-6-vnic"), \
             mock.patch.object(gate, "private_base") as base, \
             mock.patch.object(gate, "metadata") as remote, \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(gate.main(), 2)
            base.assert_not_called()
            remote.assert_not_called()

    def test_no_mutation_path_in_source(self):
        source = SCRIPT.read_text(encoding="utf-8")
        for command in (
            '["mkfs.ext4"', '["mount",', '["docker", "compose", "up"',
            '["systemctl", "start"', '["systemctl", "reboot"',
            '["vwctl", "start"', '["vwctl", "restore"',
            '["rclone", "copy"', '["oci",', '["curl",',
            "requests.post(", "urllib.request.urlopen(", "subprocess.Popen(",
        ):
            self.assertNotIn(command, source)
        self.assertIn("ProxyHandler({})", source)
        self.assertIn("NoRedirect()", source)


if __name__ == "__main__":
    unittest.main()
