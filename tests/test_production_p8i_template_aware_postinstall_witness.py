"""P8I post-install read-only verification and original one-shot evidence contract."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import stat
from types import SimpleNamespace
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).parent / "host-acceptance/production-p8i-template-aware-postinstall-witness.py"
spec = importlib.util.spec_from_file_location("rc12_p8i_template_aware", SOURCE)
assert spec and spec.loader
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

BOOT = "92ea3387-5917-4776-99ce-a88812190233"
EXPECTED_SHA = "a" * 40
DETAILS = "\n".join([
    "Private OCI attachment comparison ONLY (do not paste)",
    "resolved_block_path=/dev/test-disk",
    "capacity_bytes=53687091200",
    "stable_by_id=/dev/disk/by-id/scsi-test",
    "stable_by_id=/dev/disk/by-id/wwn-test",
    "filesystem_signature_count=0",
    "mountpoint_count=0",
]) + "\n"


def checkpoint(evidence_sha: str) -> dict:
    return {
        "schema": 1, "phase": "prepared-only", "commit": gate.P8H_SHA,
        "host": gate.HOST, "boot_id": BOOT, "p8g_evidence_sha256": evidence_sha,
        "instance_fingerprint": gate.ORIGINAL_INSTANCE_FP,
        "vnic_fingerprint": gate.ORIGINAL_VNIC_FP,
        "disk_alias_fingerprint": gate.PREVIOUS_DISK_FP,
        "disk_size_bytes": 50 * 1024 ** 3,
    }


def attempt() -> dict:
    return {
        "schema": 1, "mode": "one-shot-format-and-install", "host": gate.HOST,
        "commit": gate.P8H_SHA, "disk_fingerprint": gate.PREVIOUS_DISK_FP,
        "source_checkpoint": "checkpoint.json", "boot_id": BOOT,
        "target_hostname_sha256":
            __import__("hashlib").sha256(gate.TEST_DOMAIN.encode()).hexdigest(),
    }


def install_summary() -> str:
    return "\n".join([
        "Gate P8H - consented isolated FIRST INSTALL",
        "PASS       Exact single format/install attempt completed on selected approved disposable volume",
        "PASS       Dedicated ext4 identity/marker, immutable rc.12 source and encrypted SOPS/Age custody verified",
        "PASS       LOCKED install-only hostname bw.lazymocha.com and bw@lazymocha.com, original offline public Age recipient retained",
        "PASS       Backup remote disabled and retention zero; no application/timer or TCP 80/443 listener activated",
        "NOT RUN    No original .vwrec restore, test DNS/Cloudflare Worker, ACME, SMTP, Box or live service start",
        "HOLD       Installed but stopped; SHARED test hostname does NOT authorize DNS, ACME, Caddy or public activation",
    ]) + "\n"


class P8IPostInstallTests(unittest.TestCase):
    def test_wrong_guest_or_dirty_checkout_denied(self):
        sha = "a" * 40
        response = [
            mock.Mock(returncode=0, stdout=(sha + "\n").encode()),
            mock.Mock(returncode=0, stdout=(gate.BRANCH + "\n").encode()),
            mock.Mock(returncode=0, stdout=b""),
        ]
        with mock.patch.object(gate.subprocess, "run", side_effect=response):
            self.assertTrue(gate.exact_checkout(sha))
        response[-1] = mock.Mock(returncode=0, stdout=b" M changed")
        with mock.patch.object(gate.subprocess, "run", side_effect=response):
            self.assertFalse(gate.exact_checkout(sha))
        self.assertFalse(gate.exact_checkout("not-sha"))
        with mock.patch.object(gate.platform, "node", return_value="vaultwarden-oci-6-vnic"):
            self.assertFalse(gate.host_release())

    def test_read_only_evidence_requires_p8h_checkpoint_attempt_and_hold(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            import hashlib
            evidence_sha = hashlib.sha256(b"p8g hold" + b"\0" + DETAILS.encode()).hexdigest()
            values = {
                "checkpoint.json": json.dumps(checkpoint(evidence_sha)).encode(),
                "install-attempted.json": json.dumps(attempt()).encode(),
                "install.summary.txt": install_summary().encode(),
                "summary.txt": b"p8g hold",
                "disk-details.txt": DETAILS.encode(),
                "setup-dryrun.private.log": b"dry-run summary",
                "setup-install.private.log": b"private installer output",
            }
            def fake_read(path, maximum=32768):
                return values[path.name]
            with mock.patch.object(gate, "private_dir", return_value=True), \
                 mock.patch.object(gate, "private_read", side_effect=fake_read), \
                 mock.patch.object(gate.Path, "read_text", return_value=BOOT), \
                 mock.patch.object(gate, "tag", return_value=gate.PREVIOUS_DISK_FP):
                disk, boot = gate.expected_install_evidence(base)
                self.assertEqual((disk, boot), ("/dev/test-disk", BOOT))
                original = values["install-attempted.json"]
                values["install-attempted.json"] = json.dumps({
                    **attempt(), "commit": "b" * 40,
                }).encode()
                with self.assertRaises(gate.Blocked):
                    gate.expected_install_evidence(base)
                values["install-attempted.json"] = original
                values["install.summary.txt"] = install_summary().replace(
                    "HOLD       Installed but stopped", "BLOCKED    Installed but stopped"
                ).encode()
                with self.assertRaises(gate.Blocked):
                    gate.expected_install_evidence(base)

    def test_private_symlink_is_never_followed(self):
        with tempfile.TemporaryDirectory() as name:
            base = Path(name)
            source = base / "private.txt"
            source.write_text("secret")
            link = base / "link"
            link.symlink_to(source)
            with self.assertRaises(OSError):
                gate.private_read(link)

    def test_root_private_report_sanitizes_and_marks_hold(self):
        with tempfile.TemporaryDirectory() as name:
            report = gate.Report(Path(name))
            report.add("PASS", "Installed-but-stopped state observed")
            report.add("PENDING", "Original recovery source not verified")
            with self.assertRaises(ValueError):
                report.add("PASS", "private\nmaterial")
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                self.assertEqual(report.finish(), 0)
            summary = (Path(name) / "summary.txt").read_text()
            self.assertIn("HOLD", summary)
            self.assertIn("no restore/live-start/production GO", summary)
        with tempfile.TemporaryDirectory() as name:
            report = gate.Report(Path(name))
            report.add("BLOCKED", "unexpected listener")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 2)

    def test_release_proof_fails_if_immutable_source_incomplete(self):
        with tempfile.TemporaryDirectory() as directory:
            a = Path(directory) / "source"
            b = Path(directory) / "installed"
            a.mkdir()
            b.mkdir()
            with self.assertRaises(gate.Blocked):
                gate.compare_release(a, b)

    def test_config_file_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / "target"
            p.write_text("sealed data")
            link = Path(folder) / "link"
            link.symlink_to(p)
            self.assertFalse(gate.safe_root_file(link))

    def test_systemd_units_cannot_be_enabled_or_running(self):
        correct = (0, "LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled\n")
        def fake_call(argv, **kw):
            return (0, "") if argv[0].endswith("ss") else correct
        with mock.patch.object(gate, "command", side_effect=fake_call), \
             mock.patch.object(gate, "template_safe") as template, \
             mock.patch.object(gate.Path, "exists", return_value=False), \
             mock.patch.object(gate.Path, "is_symlink", return_value=False):
            count, containers = gate.service_state()
            self.assertEqual(containers, 0)
            self.assertEqual(count, 12)
            template.assert_called_once()
        with mock.patch.object(gate, "command", side_effect=lambda argv, **kw: (
                (0, "") if argv[0].endswith("ss") else
                (0, "LoadState=loaded\nActiveState=inactive\nUnitFileState=enabled\n"))), \
             mock.patch.object(gate, "template_safe"), \
             mock.patch.object(gate.Path, "exists", return_value=False), \
             mock.patch.object(gate.Path, "is_symlink", return_value=False):
            with self.assertRaises(gate.Blocked):
                gate.service_state()

    def test_http_listener_prevents_readonly_acceptance(self):
        with mock.patch.object(gate, "command", side_effect=lambda argv, **kw: (
                (0, "LISTEN 0 256 0.0.0.0:443 0.0.0.0:*\n")
                if argv[0].endswith("ss") else
                (0, "LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled\n"))), \
             mock.patch.object(gate, "template_safe"), \
             mock.patch.object(gate.Path, "exists", return_value=False), \
             mock.patch.object(gate.Path, "is_symlink", return_value=False):
            with self.assertRaises(gate.Blocked):
                gate.service_state()

    def test_historical_p8i_and_diagnostic_evidence_proves_only_template_blocked(self):
        from vaultwarden_oci import install
        first = "\n".join((
            "Gate P8I - NEW isolated test VM installed-but-stopped witness (READ-ONLY)",
            "PASS       Original one-shot P8H install attempt/checkpoint and successful HOLD evidence intact",
            "PASS       Full installed product files=52, systemd units=12 match immutable reviewed rc.12",
            "PASS       Mounted dedicated non-root ext4 and dual ownership markers match P8G disk",
            "PASS       Locked hostname/email, zero-prune/disabled Box config, operational SOPS",
            "BLOCKED    Read-only check failed during stopped app and restore absence; details withheld",
            "BLOCKED    P8I post-install read-only witness only; no restore/live-start/production GO",
        ))
        ordinary = [
            f"PASS       Systemd {unit} query=ok load=loaded active=inactive unitfile=static"
            for unit in install.SYSTEMD_UNITS if unit != gate.NOTIFY_TEMPLATE
        ]
        diag = "\n".join((
            "Gate P8I-D - NEW host stopped-state classification (READ-ONLY)",
            "PASS       Original exact P8I BLOCKED evidence privately verified; originals unchanged",
            *ordinary,
            "BLOCKED    Systemd vaultwarden-oci-notify@.service query=unavailable load=absent active=absent unitfile=absent",
            "PASS       TCP listener counts port80=0 port443=0 unparseable_rows=0 (no addresses exposed)",
            "PASS       Docker container metadata entries=0 (names withheld)",
            "PASS       Pre-restore SQLite database ABSENT",
            "BLOCKED    P8I diagnostic ONLY; original P8I BLOCKED remains open for review",
        ))
        rows = {"first": first, "diag": diag}
        def fake_read(path):
            return (rows["first"] if path.parent.name == gate.P8I_FIRST_EVIDENCE
                    else rows["diag"]).encode()
        with tempfile.TemporaryDirectory() as location, \
             mock.patch.object(gate, "private_dir", return_value=True), \
             mock.patch.object(gate, "private_read", side_effect=fake_read):
            gate.classified_prior_blocker(Path(location))
            rows["diag"] += "\nBLOCKED    Systemd vaultwarden-oci.service query=ok load=loaded active=active unitfile=disabled"
            with self.assertRaises(gate.Blocked):
                gate.classified_prior_blocker(Path(location))
            rows["diag"] = diag.replace(
                "PASS       TCP listener counts port80=0 port443=0",
                "BLOCKED    TCP listener counts port80=0 port443=1",
            )
            with self.assertRaises(gate.Blocked):
                gate.classified_prior_blocker(Path(location))

    def test_template_static_and_no_instances_is_accepted_without_show(self):
        def output(argv, **kwargs):
            self.assertNotIn("show", argv)
            if "list-unit-files" in argv:
                return (0, f"{gate.NOTIFY_TEMPLATE} static -\n")
            if "list-units" in argv:
                return (0, "")
            self.fail("unexpected read-only command")
        def metadata(self_path):
            if str(self_path).startswith("/etc/systemd/system/"):
                return SimpleNamespace(st_mode=stat.S_IFREG | 0o644, st_uid=0)
            return SimpleNamespace(st_mode=stat.S_IFREG | 0o444, st_uid=0)
        with mock.patch.object(gate, "command", side_effect=output), \
             mock.patch.object(gate.Path, "lstat", autospec=True, side_effect=metadata), \
             mock.patch.object(gate, "digest", return_value="identical"):
            gate.template_safe()

    def test_template_enabled_alias_or_instance_remains_blocked(self):
        cases = (
            ((0, f"{gate.NOTIFY_TEMPLATE} static -\n"
                   "vaultwarden-oci-notify@danger.service enabled -\n"), (0, "")),
            ((0, f"{gate.NOTIFY_TEMPLATE} enabled -\n"), (0, "")),
            ((0, f"{gate.NOTIFY_TEMPLATE} static -\n"),
             (0, "vaultwarden-oci-notify@event.service loaded active running\n")),
            ((None, ""), (0, "")),
            ((0, f"{gate.NOTIFY_TEMPLATE} static -\n"), (None, "")),
            ((0, ""), (0, "")),
        )
        def metadata(self_path):
            if str(self_path).startswith("/etc/systemd/system/"):
                return SimpleNamespace(st_mode=stat.S_IFREG | 0o644, st_uid=0)
            return SimpleNamespace(st_mode=stat.S_IFREG | 0o444, st_uid=0)
        for unitfiles, instances in cases:
            with self.subTest(unitfiles=unitfiles, instances=instances), \
                 mock.patch.object(gate, "command", side_effect=[unitfiles, instances]), \
                 mock.patch.object(gate.Path, "lstat", autospec=True, side_effect=metadata), \
                 mock.patch.object(gate, "digest", return_value="identical"):
                with self.assertRaises(gate.Blocked):
                    gate.template_safe()

    def test_template_changed_file_bytes_or_owner_is_blocked(self):
        with mock.patch.object(gate.Path, "lstat", autospec=True, side_effect=lambda p: (
                SimpleNamespace(st_mode=stat.S_IFREG | 0o644, st_uid=0)
                if str(p).startswith("/etc/systemd/system/")
                else SimpleNamespace(st_mode=stat.S_IFREG | 0o444, st_uid=0)
             )), mock.patch.object(gate, "digest", side_effect=["installed-hash", "changed-hash"]), \
             mock.patch.object(gate, "command") as commands:
            with self.assertRaises(gate.Blocked):
                gate.template_safe()
            commands.assert_not_called()

    def test_active_non_template_unit_still_fails_closed(self):
        with mock.patch.object(gate, "command", return_value=(
            0, "LoadState=loaded\nActiveState=active\nUnitFileState=disabled\n"
        )), mock.patch.object(gate, "template_safe") as template:
            with self.assertRaises(gate.Blocked):
                gate.service_state()
            template.assert_not_called()

    def test_full_script_only_invokes_readonly_commands(self):
        text = SOURCE.read_text()
        for banned in (
            '["mkfs.ext4"', '["mount",', '["docker",', '["rclone",',
            '["systemctl", "start"', '["systemctl", "reboot"',
            '["vwctl", "start"', '["vwctl", "restore"',
            '["oci",', "requests.post(", "urllib.request.urlopen(",
        ):
            self.assertNotIn(banned, text)
        self.assertIn('"--decrypt"', text)
        self.assertIn('"--output", "/dev/null"', text)
        self.assertNotIn('subprocess.Popen(', text)

    def test_bad_invocation_denied_before_private_evidence(self):
        with mock.patch.object(gate.sys, "argv", [
            "p8i", "--expected-commit", "a" * 40,
        ]), mock.patch.object(gate.os, "geteuid", return_value=1000), \
             mock.patch.object(gate, "root_private_base") as private, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate.main(), 2)
            private.assert_not_called()

    def test_happy_mocked_main_writes_hold_never_calls_mutations(self):
        with tempfile.TemporaryDirectory() as location:
            base = Path(location)
            with mock.patch.object(gate.sys, "argv", ["p8i", "--expected-commit", "a" * 40]), \
                 mock.patch.object(gate.os, "geteuid", return_value=0), \
                 mock.patch.dict(gate.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(gate.platform, "node", return_value=gate.HOST), \
                 mock.patch.object(gate, "exact_checkout", return_value=True), \
                 mock.patch.object(gate, "host_release", return_value=True), \
                 mock.patch.object(gate, "root_private_base", return_value=base), \
                 mock.patch.object(gate, "expected_install_evidence", return_value=("/dev/test-disk", BOOT)), \
                 mock.patch.object(gate, "classified_prior_blocker") as old_blocker, \
                 mock.patch.object(gate, "compare_release", return_value=(52, 12)), \
                 mock.patch.object(gate, "verify_storage", return_value="f" * 12), \
                 mock.patch.object(gate, "config_and_secrets") as custody, \
                 mock.patch.object(gate, "service_state", return_value=(12, 0)), \
                 mock.patch.object(gate.Path, "is_symlink", return_value=True), \
                 mock.patch.object(gate.Path, "resolve", return_value=gate.INSTALLED):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(gate.main(), 0)
                self.assertIn("P8I corrected", output.getvalue())
                old_blocker.assert_called_once_with(base)
                self.assertIn("HOLD", output.getvalue())
                self.assertIn("NOT RUN", output.getvalue())
                custody.assert_called_once()

if __name__ == "__main__":
    unittest.main()
