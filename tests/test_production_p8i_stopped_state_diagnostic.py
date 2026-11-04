"""Regression tests for P8I-D strictly read-only stopped-state classifications."""
from __future__ import annotations

import contextlib
import importlib.util
import io
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8i-stopped-state-diagnostic.py"
spec = importlib.util.spec_from_file_location("rc12_p8id_readonly", SCRIPT)
assert spec and spec.loader
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class DiagnosticTests(unittest.TestCase):
    def test_exact_sha_branch_clean_and_old_host_refused(self):
        sha = "f" * 40
        good = [
            mock.Mock(returncode=0, stdout=(sha + "\n").encode()),
            mock.Mock(returncode=0, stdout=(gate.BRANCH + "\n").encode()),
            mock.Mock(returncode=0, stdout=b""),
        ]
        with mock.patch.object(gate.subprocess, "run", side_effect=good):
            self.assertTrue(gate.source_pin_ok(sha))
        changed = list(good)
        changed[-1] = mock.Mock(returncode=0, stdout=b"?? unexpected.txt")
        with mock.patch.object(gate.subprocess, "run", side_effect=changed):
            self.assertFalse(gate.source_pin_ok(sha))
        with mock.patch.object(gate.subprocess, "run") as run:
            self.assertFalse(gate.source_pin_ok("unreviewed"))
            run.assert_not_called()
        with mock.patch.object(gate.platform, "node", return_value="vaultwarden-oci-6-vnic"):
            self.assertFalse(gate.guest_ok())

    def test_original_p8i_blocked_evidence_requires_exact_failure_stage(self):
        contents = "\n".join((
            "Gate P8I - NEW isolated test VM installed-but-stopped witness (READ-ONLY)",
            "PASS       Original one-shot P8H install attempt/checkpoint and successful HOLD evidence intact",
            "PASS       Full installed product files=52, systemd units=12 match immutable reviewed rc.12",
            "PASS       Mounted dedicated non-root ext4 and dual ownership markers match P8G disk",
            "PASS       Locked hostname/email, zero-prune/disabled Box config, operational SOPS",
            "BLOCKED    Read-only check failed during stopped app and restore absence; details withheld",
            "BLOCKED    P8I post-install read-only witness only; no restore/live-start/production GO",
        ))
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            with mock.patch.object(gate, "protected_dir", return_value=True), \
                 mock.patch.object(gate, "read_private_summary", return_value=contents):
                gate.accepted_blocked_p8i(base)
            with mock.patch.object(gate, "protected_dir", return_value=True), \
                 mock.patch.object(gate, "read_private_summary", return_value=contents.replace(
                     "stopped app and restore absence", "unrelated disk stage"
                 )):
                with self.assertRaises(gate.Refusal):
                    gate.accepted_blocked_p8i(base)

    def test_unit_labels_are_allowlisted_and_loaded_inactive_pass(self):
        unit = gate.UNITS[0]
        good = "LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled\n"
        ok, safe = gate.systemd_classification(unit, 0, good)
        self.assertTrue(ok)
        self.assertIn("load=loaded active=inactive unitfile=disabled", safe)
        good = "LoadState=loaded\nActiveState=inactive\nUnitFileState=static\n"
        self.assertTrue(gate.systemd_classification(unit, 0, good)[0])
        with self.assertRaises(ValueError):
            gate.systemd_classification("systemd-resolved.service", 0, good)

    def test_static_template_missing_load_distinguishes_false_positive(self):
        unit = "vaultwarden-oci-notify@.service"
        missing = "LoadState=not-found\nActiveState=inactive\nUnitFileState=static\n"
        ok, safe = gate.systemd_classification(unit, 0, missing)
        self.assertFalse(ok)
        self.assertIn("load=not-found", safe)
        self.assertIn("unitfile=static", safe)

    def test_unit_active_or_enabled_are_blocked_even_if_loaded(self):
        unit = "vaultwarden-oci-backup.timer"
        for payload in (
            "LoadState=loaded\nActiveState=active\nUnitFileState=disabled\n",
            "LoadState=loaded\nActiveState=inactive\nUnitFileState=enabled\n",
            "LoadState=loaded\nActiveState=inactive\nUnitFileState=linked-runtime\n",
        ):
            with self.subTest(payload=payload):
                self.assertFalse(gate.systemd_classification(unit, 0, payload)[0])

    def test_unknown_unit_properties_do_not_leak_raw_text(self):
        unit = gate.UNITS[0]
        payload = (
            "LoadState=secret-private-value\nActiveState=inactive\n"
            "UnitFileState=secret-path\n"
        )
        valid, safe = gate.systemd_classification(unit, 0, payload)
        self.assertFalse(valid)
        self.assertIn("load=unrecognized", safe)
        self.assertNotIn("secret-", safe)
        code, safe = gate.systemd_classification(unit, None, "")
        self.assertFalse(code)
        self.assertIn("query=unavailable", safe)

    def test_listeners_80_and_443_are_reported_without_addresses(self):
        ok, summary = gate.socket_classification(0,
            "LISTEN 0 128 127.0.0.1:22 0.0.0.0:*\n"
            "LISTEN 0 4096 [::]:443 [::]:*\n"
            "LISTEN 0 4096 10.1.2.3:80 0.0.0.0:*\n")
        self.assertFalse(ok)
        self.assertIn("port80=1 port443=1", summary)
        self.assertNotIn("10.1.2.3", summary)
        self.assertNotIn("127.0.0.1", summary)
        self.assertEqual(gate.socket_classification(0, "LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n")[0], True)
        self.assertFalse(gate.socket_classification(None, "")[0])
        self.assertFalse(gate.socket_classification(0, "malformed-private-content\n")[0])

    def test_docker_metadata_count_only_no_socket_or_ids(self):
        with tempfile.TemporaryDirectory() as dir:
            root = Path(dir)
            path = root / "containers"
            self.assertEqual(gate.docker_classification(path), (
                True, "Docker container metadata directory absent",
            ))
            path.mkdir()
            self.assertTrue(gate.docker_classification(path)[0])
            (path / "sensitive-container-id").mkdir()
            good, message = gate.docker_classification(path)
            self.assertFalse(good)
            self.assertIn("entries=1", message)
            self.assertNotIn("sensitive-container-id", message)
            (root / "link").symlink_to(path)
            self.assertFalse(gate.docker_classification(root / "link")[0])

    def test_database_presence_is_reported_without_content(self):
        with tempfile.TemporaryDirectory() as dir:
            path = Path(dir) / "db.sqlite3"
            self.assertTrue(gate.sqlite_classification(path)[0])
            path.write_bytes(b"secret sqlite contents")
            good, description = gate.sqlite_classification(path)
            self.assertFalse(good)
            self.assertIn("PRESENT as regular file", description)
            self.assertNotIn("secret sqlite", description)
            path.unlink()
            path.symlink_to("/tmp/sensitive-link")
            self.assertFalse(gate.sqlite_classification(path)[0])

    def test_readonly_report_private_and_still_blocked(self):
        with tempfile.TemporaryDirectory() as path:
            report = gate.Report(Path(path))
            report.add("PASS", "Original source evidence intact")
            report.add("BLOCKED", "Systemd load=not-found")
            with self.assertRaises(ValueError):
                report.add("PASS", "private\nsecret")
            data = io.StringIO()
            with contextlib.redirect_stdout(data):
                self.assertEqual(report.finish(), 2)
            summary = Path(path) / "summary.txt"
            self.assertEqual(stat.S_IMODE(summary.stat().st_mode), 0o600)
            self.assertIn("original P8I BLOCKED remains open", summary.read_text())
        with tempfile.TemporaryDirectory() as path:
            report = gate.Report(Path(path))
            report.add("PASS", "All diagnostic checks confirmed stopped")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 0)

    def test_main_requires_pinned_new_host_before_reading_evidence(self):
        with mock.patch.object(gate.sys, "argv", [
            "p8id", "--expected-commit", "f" * 40,
        ]), mock.patch.object(gate.os, "geteuid", return_value=1000), \
             mock.patch.object(gate, "private_new_folder") as private, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate.main(), 2)
            private.assert_not_called()

    def test_mock_diagnostic_reports_all_categories_without_mutation(self):
        with tempfile.TemporaryDirectory() as path:
            folder = Path(path)
            with mock.patch.object(gate.sys, "argv", ["p8id", "--expected-commit", "f" * 40]), \
                 mock.patch.object(gate.os, "geteuid", return_value=0), \
                 mock.patch.dict(gate.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(gate.platform, "node", return_value=gate.HOST), \
                 mock.patch.object(gate, "source_pin_ok", return_value=True), \
                 mock.patch.object(gate, "guest_ok", return_value=True), \
                 mock.patch.object(gate, "private_new_folder", return_value=folder), \
                 mock.patch.object(gate, "run_readonly", side_effect=lambda args, **kwargs: (
                     (0, "LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled\n")
                     if args[0].endswith("systemctl") else (0, "")
                 )), mock.patch.object(gate, "docker_classification", return_value=(True, "Docker container metadata directory absent")), \
                 mock.patch.object(gate, "sqlite_classification", return_value=(True, "Pre-restore SQLite database ABSENT")):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(gate.main(), 0)
                self.assertIn("Gate P8I-D", output.getvalue())
                self.assertIn("HOLD", output.getvalue())
                self.assertIn("Pre-restore SQLite database ABSENT", output.getvalue())

    def test_script_does_not_invoke_mutating_processes(self):
        source = SCRIPT.read_text(encoding="utf-8")
        for denied in (
            '["mount",', '["mkfs.ext4"', '["docker",',
            '["systemctl", "start"', '["systemctl", "stop"',
            '["systemctl", "enable"', '["systemctl", "daemon-reload"',
            '["vwctl", "restore"', '["vwctl", "start"',
            '["rclone",', '["oci",', "requests.post(", "urllib.request.urlopen(",
            "subprocess.Popen(",
        ):
            self.assertNotIn(denied, source)


if __name__ == "__main__":
    unittest.main()
