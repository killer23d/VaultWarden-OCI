"""P8H isolated first-install: read-only preparation and exclusive typed consent."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8h-isolated-install-consent.py"
spec = importlib.util.spec_from_file_location("rc12_p8h_consent", SCRIPT)
assert spec and spec.loader
p8 = importlib.util.module_from_spec(spec)
import sys
sys.modules[spec.name] = p8
spec.loader.exec_module(p8)


class TTY(io.StringIO):
    def isatty(self):
        return True


def proof():
    return p8.DiskWitness(
        "/dev/placeholder-disk", 50 * 1024**3,
        ("/dev/disk/by-id/scsi-first", "/dev/disk/by-id/scsi-second"),
        hashlib.sha256(b"original-p8g").hexdigest(),
    )


def accepted_p8g_summary():
    return "\n".join((
        "Gate P8G - fresh OCI disk identity and external network proof (READ-ONLY)",
        "PASS       Original P8F HOLD evidence intact; A1 Flex and one blank disk witnessed on target",
        "PASS       Still no appliance, Docker state or TCP 80/443 listeners",
        "PASS       one unmounted unsigned non-root disk; capacity_GiB=50 alias_fingerprint=b7cd04a730c8 alias_count=2",
        "PASS       P8F OCI A1 Flex instance and VNIC identities unchanged (fingerprint binding)",
        "HOLD       P8G disk and network WITNESS only; no install, restore, public service or production GO",
    )) + "\n"


def accepted_p8g_disk():
    return "\n".join((
        "Private OCI attachment comparison ONLY (do not paste)",
        "resolved_block_path=/dev/placeholder-disk",
        "capacity_bytes=53687091200",
        "stable_by_id=/dev/disk/by-id/scsi-first",
        "stable_by_id=/dev/disk/by-id/scsi-second",
        "filesystem_signature_count=0",
        "mountpoint_count=0",
        "boot_ancestry=excluded_by_product_storage",
        "OCI_volume_OCID=NOT_AVAILABLE_FROM_GUEST",
        "OCI_attachment_verified=NO_PENDING_OPERATOR_CONSOLE_REVIEW",
        "NOT_AUTHORIZED_TO_FORMAT_OR_INSTALL",
    )) + "\n"


class P8HTests(unittest.TestCase):
    def test_new_instance_only_and_exact_clean_source(self):
        pin = "a" * 40
        valid = [
            SimpleNamespace(returncode=0, stdout=(pin + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=(p8.BRANCH + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=b""),
        ]
        with mock.patch.object(p8.subprocess, "run", side_effect=valid):
            self.assertTrue(p8.exact_source(pin))
        with mock.patch.object(p8.subprocess, "run", side_effect=valid[:-1] + [
            SimpleNamespace(returncode=0, stdout=b" M some-file")
        ]):
            self.assertFalse(p8.exact_source(pin))
        with mock.patch.object(p8.subprocess, "run") as sp:
            self.assertFalse(p8.exact_source("bad"))
            sp.assert_not_called()
        with mock.patch.object(p8.platform, "node", return_value="vaultwarden-oci-6-vnic"):
            self.assertFalse(p8.host_ok())

    def test_p8g_only_one_exact_accepted_summary_and_disk_detail(self):
        details = accepted_p8g_disk()
        summary = accepted_p8g_summary()
        with tempfile.TemporaryDirectory() as t:
            base = Path(t)
            with mock.patch.object(p8, "private_directory", return_value=True), \
                 mock.patch.object(p8, "private_bytes", side_effect=lambda p: (
                     details.encode() if p.name == "disk-details.txt" else summary.encode()
                 )), mock.patch.object(p8, "tag", side_effect=lambda s: (
                     p8.ALIAS_FINGERPRINT if s.endswith("scsi-first") else "whatever"
                 )):
                witness = p8.read_p8g_proof(base)
                self.assertEqual(witness.size_bytes, 50 * 1024**3)
                self.assertEqual(len(witness.aliases), 2)
                self.assertEqual(witness.resolved, "/dev/placeholder-disk")
            altered = details.replace("filesystem_signature_count=0", "filesystem_signature_count=1")
            with mock.patch.object(p8, "private_directory", return_value=True), \
                 mock.patch.object(p8, "private_bytes", side_effect=lambda p: (
                     altered.encode() if p.name == "disk-details.txt" else summary.encode()
                 )):
                with self.assertRaises(p8.Blocked):
                    p8.read_p8g_proof(base)
            with mock.patch.object(p8, "private_directory", return_value=True), \
                 mock.patch.object(p8, "private_bytes", side_effect=lambda p: (
                     details.encode() if p.name == "disk-details.txt" else
                     (summary.replace("HOLD       P8G", "BLOCKED    P8G")).encode()
                 )):
                with self.assertRaises(p8.Blocked):
                    p8.read_p8g_proof(base)

    def test_blank_disk_must_match_p8g_byid_and_exact_block_tree(self):
        witness = proof()
        row = {
            "path": "/dev/placeholder-disk", "type": "disk",
            "size": witness.size_bytes, "fstype": "", "uuid": "", "mountpoints": (),
        }
        tree = {"blockdevices": [{
            "path": witness.resolved, "type": "disk", "size": witness.size_bytes,
            "fstype": None, "pttype": None, "uuid": None, "mountpoints": [],
        }]}
        storage = SimpleNamespace(
            root_source=lambda: "/dev/boot",
            inventory=lambda: [row],
            reject_boot_related=lambda path: None,
        )
        with mock.patch.object(p8.Path, "resolve", return_value=Path(witness.resolved)), \
             mock.patch.object(p8.Path, "is_block_device", return_value=True), \
             mock.patch.object(p8.Path, "iterdir", return_value=[
                Path(witness.aliases[0]), Path(witness.aliases[1]),
             ]), mock.patch.object(p8.Path, "is_symlink", return_value=True), \
             mock.patch.object(p8, "execute", side_effect=[
                (0, json.dumps(tree)), (0, "")
             ]):
            self.assertEqual(p8.current_disk(storage, witness), witness)
        with mock.patch.object(p8.Path, "resolve", return_value=Path(witness.resolved)), \
             mock.patch.object(p8.Path, "is_block_device", return_value=True), \
             mock.patch.object(p8.Path, "iterdir", return_value=[]), \
             mock.patch.object(p8, "execute", side_effect=[(0, json.dumps(tree)), (0, "")]):
            with self.assertRaises(p8.Blocked):
                p8.current_disk(storage, witness)

    def test_partitions_mounts_signatures_size_or_root_are_blocked(self):
        witness = proof()
        valid = {
            "path": witness.resolved, "type": "disk", "size": witness.size_bytes,
            "fstype": None, "pttype": None, "uuid": None, "mountpoints": [],
        }
        storage = SimpleNamespace(
            root_source=lambda: "/dev/boot",
            inventory=lambda: [{
                "path": witness.resolved, "type": "disk", "size": witness.size_bytes,
                "fstype": "", "uuid": "", "mountpoints": (),
            }],
            reject_boot_related=lambda p: None,
        )
        with mock.patch.object(p8.Path, "resolve", return_value=Path(witness.resolved)), \
             mock.patch.object(p8.Path, "is_block_device", return_value=True), \
             mock.patch.object(p8.Path, "iterdir", return_value=[]):
            for change in (
                {"children": [{"type": "part"}]},
                {"fstype": "ext4"},
                {"pttype": "gpt"},
                {"mountpoints": ["/mnt/test"]},
                {"size": witness.size_bytes + 4096},
            ):
                with self.subTest(change=change):
                    x = dict(valid, **change)
                    with mock.patch.object(p8, "execute", return_value=(
                        0, json.dumps({"blockdevices": [x]})
                    )):
                        with self.assertRaises(p8.Blocked):
                            p8.current_disk(storage, witness)
            with mock.patch.object(p8, "execute", side_effect=[
                (0, json.dumps({"blockdevices": [valid]})), (0, "ext4\n"),
            ]):
                with self.assertRaises(p8.Blocked):
                    p8.current_disk(storage, witness)
        storage.reject_boot_related = mock.Mock(side_effect=RuntimeError("root disk"))
        with mock.patch.object(p8.Path, "resolve", return_value=Path(witness.resolved)), \
             mock.patch.object(p8.Path, "is_block_device", return_value=True):
            with self.assertRaises(RuntimeError):
                p8.current_disk(storage, witness)

    def test_oci_link_local_identity_without_disclosing_raw_data(self):
        iid = "ocid1.instance.oc1.fixture"
        vid = "ocid1.vnic.oc1.fixture"
        inst = {
            "id": iid, "shape": "VM.Standard.A1.Flex",
            "metadata": {"ssh_authorized_keys": "DO_NOT_PRINT_PRIVATE"},
        }
        vnics = [{"vnicId": vid, "privateIp": "10.2.4.6"}]
        def fixture_tag(s):
            return (p8.INSTANCE_FINGERPRINT if s == iid else
                    p8.VNIC_FINGERPRINT if s == vid else "mismatch")
        with mock.patch.object(p8, "tag", side_effect=fixture_tag):
            self.assertTrue(p8.same_oci(inst, vnics))
            self.assertFalse(p8.same_oci({**inst, "shape": "VM.Standard.E5.Flex"}, vnics))
            self.assertFalse(p8.same_oci(inst, [{"vnicId": vid, "privateIp": "8.8.8.8"}]))
            self.assertFalse(p8.same_oci({**inst, "id": "ocid1.instance.oc1.different"}, vnics))
        class FakeResponse:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def geturl(self): return p8.IMDS_ORIGIN + "/instance/"
            def read(self, n): return json.dumps(inst).encode()
        class FakeOpener:
            def open(self, req, *, timeout):
                self.req = req
                self.timeout = timeout
                return FakeResponse()
        opener = FakeOpener()
        self.assertEqual(p8.oci_metadata("instance", opener=opener)["id"], iid)
        self.assertEqual(opener.req.get_method(), "GET")
        self.assertEqual(opener.req.get_header("Authorization"), "Bearer Oracle")
        self.assertEqual(opener.req.full_url, p8.IMDS_ORIGIN + "/instance/")
        self.assertEqual(opener.timeout, 6)
        with self.assertRaises(ValueError):
            p8.oci_metadata("not-approved", opener=opener)

    def test_prepared_checkpoint_stale_boot_or_evidence_fails_closed(self):
        with tempfile.TemporaryDirectory() as name:
            base = Path(name)
            folder = base / "p8h-prepare-20261104T211200Z-456"
            folder.mkdir(mode=0o700)
            checkpoint = folder / "checkpoint.json"
            expected = {
                "schema": 1, "phase": "prepared-only", "commit": "a"*40,
                "host": p8.HOST, "boot_id": "7d63a452-e619-4d31-8bcc-894b47621745",
                "p8g_evidence_sha256": proof().source_evidence_sha256,
                "instance_fingerprint": p8.INSTANCE_FINGERPRINT,
                "vnic_fingerprint": p8.VNIC_FINGERPRINT,
                "disk_alias_fingerprint": p8.ALIAS_FINGERPRINT,
                "disk_size_bytes": proof().size_bytes,
            }
            good_summary = "\n".join((
                "Gate P8H - isolated first-install PREPARE only (READ-ONLY)",
                "HOLD       Prepared-only; no format/install/restore authorization created by this invocation",
            ))
            def read_file(path, **kw):
                return (good_summary.encode() if path.name == "summary.txt" else
                        json.dumps(expected).encode())
            with mock.patch.object(p8, "private_directory", return_value=True), \
                 mock.patch.object(p8, "private_bytes", side_effect=read_file), \
                 mock.patch.object(p8, "current_boot", return_value=expected["boot_id"]):
                self.assertEqual(p8.prepared_checkpoint(checkpoint, base, "a"*40, proof()), expected)
                (folder / "install-attempted.json").write_text("{}")
                with self.assertRaises(p8.Blocked):
                    p8.prepared_checkpoint(checkpoint, base, "a"*40, proof())
                (folder / "install-attempted.json").unlink()
                expected["boot_id"] = "7d63a452-e619-4d31-8bcc-894b47621746"
                with self.assertRaises(p8.Blocked):
                    p8.prepared_checkpoint(checkpoint, base, "a"*40, proof())

    def test_prepare_writes_checkpoint_but_never_runs_installer(self):
        with tempfile.TemporaryDirectory() as name:
            base = Path(name)
            with mock.patch.object(p8, "validation_state", return_value=(base, proof())), \
                 mock.patch.object(p8, "current_boot", return_value="7d63a452-e619-4d31-8bcc-894b47621745"), \
                 mock.patch.object(p8, "installer_call") as install_call:
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(p8.prepare("a"*40), 0)
                install_call.assert_not_called()
            folder = next(base.glob("p8h-prepare-*"))
            self.assertEqual(stat.S_IMODE(folder.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE((folder / "checkpoint.json").stat().st_mode), 0o600)
            self.assertFalse((folder / "install-attempted.json").exists())
            self.assertIn("HOLD", (folder / "summary.txt").read_text())
            self.assertEqual(json.loads((folder / "checkpoint.json").read_text())["phase"], "prepared-only")

    def test_tty_consent_requires_distinct_hostname_public_recipient_and_full_phrase(self):
        phrase = (f"P8H FORMAT {p8.HOST} 50GiB {p8.ALIAS_FINGERPRINT} "
                  "OCI CONSOLE AND TEST DNS VERIFIED")
        entries = (
            "1\nacceptance.test.example\noperator@example.com\n"
            + phrase + "\n"
        )
        io_in, io_out = TTY(entries), TTY()
        with mock.patch.object(p8.sys, "stdin", io_in), \
             mock.patch.object(p8.sys, "stdout", io_out), \
             mock.patch.object(p8.getpass, "getpass", return_value="age1"+"a"*58):
            choice = p8.read_consent(proof())
        self.assertEqual(choice[0], proof().aliases[0])
        self.assertEqual(choice[1], "acceptance.test.example")
        self.assertNotIn("age1"+"a"*58, io_out.getvalue())
        # The original restored public hostname cannot be chosen.
        wrong = TTY("1\nbw.lazymocha.com\noperator@example.com\n")
        with mock.patch.object(p8.sys, "stdin", wrong), \
             mock.patch.object(p8.sys, "stdout", TTY()), \
             mock.patch.object(p8.getpass, "getpass", return_value="age1"+"a"*58):
            self.assertIsNone(p8.read_consent(proof()))
        # A TTY is mandatory. No headless --auto can bypass typed consent.
        with mock.patch.object(p8.sys, "stdin", io.StringIO()), \
             mock.patch.object(p8.sys, "stdout", TTY()):
            self.assertIsNone(p8.read_consent(proof()))

    def test_supported_dryrun_is_checked_before_installer_mutation(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            calls = []
            def fake_run(argv, **kwargs):
                calls.append(list(argv))
                if "--dry-run" in argv:
                    kwargs["stdout"].write(
                        b"dry run: no filesystem, package, config, secret, or systemd changes were made\n"
                    )
                return SimpleNamespace(returncode=0)
            recipient = "age1" + "a" * 58
            with mock.patch.object(p8.subprocess, "run", side_effect=fake_run):
                self.assertTrue(p8.installer_call(
                    proof().aliases[0], "test.example", "admin@example.com", recipient,
                    folder, dry_run=True,
                ))
                self.assertTrue(p8.installer_call(
                    proof().aliases[0], "test.example", "admin@example.com", recipient,
                    folder, dry_run=False,
                ))
            self.assertIn("--dry-run", calls[0])
            self.assertNotIn("--confirm-format", calls[0])
            self.assertIn("--confirm-format", calls[1])
            self.assertNotIn("--dry-run", calls[1])
            self.assertNotIn("--use-latest", calls[1])
            self.assertEqual(calls[0][1], str(p8.SOURCE / "setup.sh"))
            self.assertEqual(stat.S_IMODE((folder / "setup-install.private.log").stat().st_mode), 0o600)
            self.assertFalse((folder / "install-attempted.json").exists())

    def test_dryrun_missing_positive_safety_confirmation_is_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            with mock.patch.object(p8.subprocess, "run", return_value=SimpleNamespace(returncode=0)):
                self.assertFalse(p8.installer_call(
                    proof().aliases[0], "test.example", "admin@example.com",
                    "age1" + "a" * 58, Path(name), dry_run=True,
                ))

    def test_install_cancellation_leaves_no_attempt_marker(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d) / "p8h-prepare-20261104T211200Z-456"
            folder.mkdir()
            with mock.patch.object(p8.sys, "stdin", TTY()), \
                 mock.patch.object(p8.sys, "stdout", TTY()), \
                 mock.patch.object(p8, "validation_state", return_value=(Path(d), proof())), \
                 mock.patch.object(p8, "prepared_checkpoint", return_value={}), \
                 mock.patch.object(p8, "read_consent", return_value=None), \
                 mock.patch.object(p8, "installer_call") as install_call:
                self.assertEqual(p8.install("a"*40, folder / "checkpoint.json"), 2)
                install_call.assert_not_called()
                self.assertFalse((folder / "install-attempted.json").exists())

    def test_install_exclusive_attempt_precedes_only_real_setup(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d) / "p8h-prepare-20261104T211200Z-456"
            folder.mkdir()
            calls = []
            def fake_installer(*args, **kwargs):
                if kwargs["dry_run"]:
                    self.assertFalse((folder / "install-attempted.json").exists())
                else:
                    self.assertTrue((folder / "install-attempted.json").exists())
                calls.append(kwargs["dry_run"])
                return True
            with mock.patch.object(p8.sys, "stdin", TTY()), \
                 mock.patch.object(p8.sys, "stdout", TTY()), \
                 mock.patch.object(p8, "validation_state", return_value=(Path(d), proof())), \
                 mock.patch.object(p8, "prepared_checkpoint", return_value={}), \
                 mock.patch.object(p8, "read_consent", return_value=(
                     proof().aliases[0], "test.example", "admin@example.com", "age1"+"a"*58
                 )), mock.patch.object(p8, "installer_call", side_effect=fake_installer), \
                 mock.patch.object(p8, "verified_installed", return_value=True), \
                 mock.patch.object(p8, "current_boot", return_value="7d63a452-e619-4d31-8bcc-894b47621745"):
                self.assertEqual(p8.install("a"*40, folder / "checkpoint.json"), 0)
            self.assertEqual(calls, [True, False])
            self.assertIn("HOLD", (folder / "install.summary.txt").read_text())
            marker = json.loads((folder / "install-attempted.json").read_text())
            self.assertEqual(marker["mode"], "one-shot-format-and-install")
            self.assertEqual(marker["disk_fingerprint"], p8.ALIAS_FINGERPRINT)

    def test_failed_installer_preserves_marker_and_refuses_automatic_retry(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d) / "p8h-prepare-20261104T211200Z-456"
            folder.mkdir()
            with mock.patch.object(p8.sys, "stdin", TTY()), \
                 mock.patch.object(p8.sys, "stdout", TTY()), \
                 mock.patch.object(p8, "validation_state", return_value=(Path(d), proof())), \
                 mock.patch.object(p8, "prepared_checkpoint", return_value={}), \
                 mock.patch.object(p8, "read_consent", return_value=(
                     proof().aliases[0], "test.example", "admin@example.com", "age1"+"a"*58
                 )), mock.patch.object(p8, "installer_call", side_effect=[True, False]), \
                 mock.patch.object(p8, "current_boot", return_value="7d63a452-e619-4d31-8bcc-894b47621745"):
                self.assertEqual(p8.install("a"*40, folder / "checkpoint.json"), 2)
            self.assertTrue((folder / "install-attempted.json").exists())
            self.assertFalse((folder / "install.summary.txt").exists())

    def test_source_has_no_direct_format_cloud_or_restoration_operation(self):
        content = SCRIPT.read_text(encoding="utf-8")
        for forbidden in (
            '["mkfs.ext4"', '["mount",', '["docker", "compose", "up"',
            '["vwctl", "start"', '["vwctl", "restore"',
            '["rclone", "copy"', '["systemctl", "reboot"',
            '["oci",', "requests.post(", "urllib.request.urlopen(",
        ):
            self.assertNotIn(forbidden, content)
        self.assertIn('"--confirm-format"', content)
        self.assertIn('"--dry-run"', content)
        self.assertIn("install-attempted.json", content)


    def test_exclusive_attempt_marker_is_private_and_nonretryable(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "install-attempted.json"
            p8.write_exclusive(path, b'{"attempt":1}\n')
            self.assertEqual(path.read_bytes(), b'{"attempt":1}\n')
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            with self.assertRaises(FileExistsError):
                p8.write_exclusive(path, b'{"attempt":2}\n')
            self.assertEqual(path.read_bytes(), b'{"attempt":1}\n')

    def test_private_evidence_symlink_refused_before_read(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            target = root / "original"
            target.write_text("sensitive")
            link = root / "redirect"
            link.symlink_to(target)
            with self.assertRaises(OSError):
                p8.private_bytes(link)

    def test_clean_host_rejects_already_existing_appliance_before_systemd(self):
        with mock.patch.object(p8.Path, "exists", return_value=True), \
             mock.patch.object(p8, "execute") as subprocess_stub:
            with self.assertRaises(p8.Blocked):
                p8.clean_host()
            subprocess_stub.assert_not_called()

    def test_main_bad_invocation_refuses_before_host(self):
        with mock.patch.object(p8.sys, "argv", [
            "p8h", "--expected-commit", "a" * 40, "prepare",
        ]), mock.patch.object(p8.os, "geteuid", return_value=1000), \
             mock.patch.object(p8, "prepare") as prepare, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(p8.main(), 2)
            prepare.assert_not_called()


if __name__ == "__main__":
    unittest.main()
