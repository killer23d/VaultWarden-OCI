from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import operations, recovery, recovery_ux
from test_recovery_ux import config_text, paths_for


def isolated_automation() -> dict:
    timers = []
    for name in operations.TIMER_UNITS:
        timers.append({
            "unit": name, "load_state": "loaded", "active_state": "inactive", "enabled": "disabled",
            "trigger_load_state": "loaded", "trigger_active_state": "inactive",
            "auxiliary_units": [
                {"unit": unit, "load_state": "loaded", "active_state": "inactive"}
                for unit in operations.TIMER_AUXILIARY_UNITS.get(name, ())
            ],
        })
    return {
        "target": {"load_state": "loaded", "active_state": "inactive", "enabled": "disabled"},
        "timers": timers,
    }


class GuidedVerificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.output = io.StringIO()
        redirect = contextlib.redirect_stdout(self.output)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)
        for name in ("sys.stdin.isatty", "sys.stdout.isatty"):
            patch = mock.patch(name, return_value=True)
            patch.start()
            self.addCleanup(patch.stop)

    def test_local_picker_records_crypto_history_without_live_state_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = paths_for(root)
            paths.backups.mkdir()
            paths.config.parent.mkdir()
            paths.config.write_text(config_text(), encoding="utf-8")
            artifact = paths.backups / "recovery-20261125T120000Z-a.vwrec"
            artifact.write_bytes(b"encrypted application recovery fixture")
            paths.data.mkdir()
            live = paths.data / "db.sqlite3"
            live.write_bytes(b"unchanged live state")
            original_config = paths.config.read_bytes()
            with (
                mock.patch("builtins.input", side_effect=["1", "1"]),
                mock.patch.object(recovery_ux, "_offline_identity_for_command", return_value=contextlib.nullcontext(root / "offline.age")),
                mock.patch.object(recovery_ux.storage, "verify"),
                mock.patch.object(recovery, "_decrypt_and_validate", return_value={"created_at": "2026-11-25T12:00:00Z"}),
                mock.patch.object(recovery, "_validate_offline_sops"),
                mock.patch.object(recovery, "restore_recovery") as restore,
                mock.patch.object(recovery, "_stop_services") as stop,
            ):
                self.assertEqual(recovery_ux.guided_verify(paths=paths), 0)
            restore.assert_not_called()
            stop.assert_not_called()
            self.assertEqual(live.read_bytes(), b"unchanged live state")
            self.assertEqual(paths.config.read_bytes(), original_config)
            state = json.loads(paths.state_file.read_text())
            self.assertEqual(state["verified_objects"][str(artifact)]["sha256"], recovery._sha256(artifact))
            self.assertEqual(list(paths.backups.iterdir()), [artifact])
        self.assertIn("offline-key cryptographic recovery verified", self.output.getvalue())
        self.assertIn("Disposable-host recovery remains NOT ESTABLISHED", self.output.getvalue())

    def test_remote_picker_verifies_exact_nested_selection_and_cleans_download(self) -> None:
        remote = "cloud:parent"
        name = "recovery-20261125T120000Z-a.vwrec"
        entries = [
            {"Name": name, "Path": f"first/{name}", "Size": 9},
            {"Name": name, "Path": f"second/deep/{name}", "Size": 9},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = paths_for(root)
            paths.backups.mkdir()
            paths.config.parent.mkdir()
            paths.config.write_text(config_text() + '\n[backup]\nremote = "cloud:parent"\n', encoding="utf-8")
            selected = remote + "/second/deep/" + name

            def download(location, destination, *, runner):
                self.assertEqual(location, selected)
                destination.write_bytes(b"encrypted")
                return destination

            with (
                mock.patch("builtins.input", side_effect=["2", "", "1"]),
                mock.patch.object(recovery, "list_remote", return_value=entries) as listing,
                mock.patch.object(recovery, "download_remote", side_effect=download) as downloaded,
                mock.patch.object(recovery_ux, "_offline_identity_for_command", return_value=contextlib.nullcontext(root / "offline.age")),
                mock.patch.object(recovery_ux.storage, "verify"),
                mock.patch.object(recovery, "_decrypt_and_validate", return_value={"created_at": "2026-11-25T12:00:00Z"}),
                mock.patch.object(recovery, "_validate_offline_sops"),
                mock.patch.object(recovery, "restore_recovery") as restored,
            ):
                self.assertEqual(recovery_ux.guided_verify(paths=paths), 0)
            listing.assert_called_once_with(remote, recursive=True, runner=recovery.run_command)
            downloaded.assert_called_once()
            restored.assert_not_called()
            self.assertEqual(list(paths.backups.iterdir()), [])
            self.assertIn(selected, json.loads(paths.state_file.read_text())["verified_objects"])

    def test_picker_cancellation_does_not_acquire_identity_or_record_history(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = paths_for(Path(directory))
            with (
                mock.patch("builtins.input", return_value="q"),
                mock.patch.object(recovery_ux, "_offline_identity_for_command") as identity,
                mock.patch.object(recovery_ux.storage, "verify") as storage,
            ):
                self.assertEqual(recovery_ux.guided_verify(paths=paths), 0)
            identity.assert_not_called()
            storage.assert_not_called()
            self.assertFalse(paths.state_file.exists())
            self.assertFalse(paths.backups.exists())

    def test_saved_destination_cancellation_never_contacts_remote(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = paths_for(Path(directory))
            paths.config.parent.mkdir()
            paths.config.write_text(config_text() + '\n[backup]\nremote = "cloud:parent"\n')
            with (
                mock.patch("builtins.input", side_effect=["2", "q"]),
                mock.patch.object(recovery_ux, "list_remote_points") as listing,
                mock.patch.object(recovery_ux, "_offline_identity_for_command") as identity,
            ):
                self.assertEqual(recovery_ux.guided_verify(paths=paths), 0)
            listing.assert_not_called()
            identity.assert_not_called()

    def test_wrong_identity_or_crypto_failure_does_not_record_success(self) -> None:
        point = recovery_ux.RecoveryPoint("local", "a.vwrec", "/backups/a.vwrec", 9, "2026-11-25T12:00:00Z", "unknown")
        for error in (recovery.RecoveryError("wrong identity"), KeyboardInterrupt()):
            with (
                self.subTest(error=type(error).__name__),
                mock.patch("builtins.input", side_effect=["1", "1"]),
                mock.patch.object(recovery_ux, "list_local", return_value=[point]),
                mock.patch.object(recovery_ux, "_offline_identity_for_command", return_value=contextlib.nullcontext(Path("/volatile/offline.age"))),
                mock.patch.object(recovery_ux.storage, "verify"),
                mock.patch.object(recovery_ux, "verify_local", side_effect=error),
                mock.patch.object(recovery_ux, "_record_verification") as record,
                mock.patch.object(recovery, "restore_recovery") as restore,
                self.assertRaises(type(error)),
            ):
                recovery_ux.guided_verify()
            record.assert_not_called()
            restore.assert_not_called()
        self.assertNotIn("PASS", self.output.getvalue())

    def test_no_source_cli_routes_interactive_verification_to_picker(self) -> None:
        with mock.patch.object(recovery_ux, "guided_verify", return_value=0) as guided:
            self.assertEqual(recovery_ux.main(["recovery", "verify"]), 0)
        guided.assert_called_once()

    def test_no_source_unattended_invocation_retains_usage_error(self) -> None:
        for args in (["recovery", "verify"], ["recovery", "verify", "--identity", "/offline/key"]):
            with (
                self.subTest(args=args),
                mock.patch("sys.stdin.isatty", return_value=False),
                mock.patch("sys.stdout.isatty", return_value=False),
                mock.patch.object(recovery_ux, "guided_verify") as guided,
                contextlib.redirect_stderr(io.StringIO()),
                self.assertRaises(SystemExit) as error,
            ):
                recovery_ux.main(args)
            self.assertEqual(error.exception.code, 2)
            guided.assert_not_called()


class RestoreAutomationBoundaryTests(unittest.TestCase):
    def test_observed_isolation_passes_without_scheduling_mutation(self) -> None:
        with (
            mock.patch.object(operations, "automation_snapshot", return_value=isolated_automation()),
            mock.patch.object(operations, "_systemd_properties", return_value={"load_state": "loaded", "active_state": "inactive", "enabled": "disabled"}),
            mock.patch.object(operations.cli, "run_command") as command,
        ):
            recovery_ux._require_restore_isolation()
        command.assert_not_called()

    def test_active_enabled_unknown_or_missing_scheduled_evidence_blocks(self) -> None:
        cases = []
        for field, value in (("active_state", "active"), ("enabled", "enabled"), ("load_state", "unknown")):
            snapshot = isolated_automation()
            snapshot["target"][field] = value
            cases.append(snapshot)
        for field, value in (("active_state", "active"), ("enabled", "enabled-runtime"), ("trigger_active_state", "activating"), ("trigger_load_state", "unknown")):
            snapshot = isolated_automation()
            snapshot["timers"][1][field] = value
            cases.append(snapshot)
        missing = isolated_automation()
        missing["timers"].pop()
        cases.append(missing)
        dns_active = isolated_automation()
        dns_active["timers"][0]["auxiliary_units"][0]["active_state"] = "active"
        cases.append(dns_active)
        dns_missing = isolated_automation()
        dns_missing["timers"][0]["auxiliary_units"] = []
        cases.append(dns_missing)
        cases.extend(({}, {"target": None, "timers": None}))
        for snapshot in cases:
            with (
                self.subTest(snapshot=snapshot),
                mock.patch.object(operations, "automation_snapshot", return_value=snapshot),
                mock.patch.object(operations, "_systemd_properties", return_value={"load_state": "loaded", "active_state": "inactive", "enabled": "disabled"}),
                self.assertRaisesRegex(recovery_ux.RecoveryUXError, "guided restore is blocked"),
            ):
                recovery_ux._require_restore_isolation()

    def test_worker_boot_rearm_enabled_or_unknown_blocks(self) -> None:
        for boot in ({}, {"load_state": "loaded", "active_state": "inactive", "enabled": "enabled"}):
            with (
                self.subTest(boot=boot),
                mock.patch.object(operations, "automation_snapshot", return_value=isolated_automation()),
                mock.patch.object(operations, "_systemd_properties", return_value=boot),
                self.assertRaises(recovery_ux.RecoveryUXError),
            ):
                recovery_ux._require_restore_isolation()

    def test_automation_drift_after_consent_blocks_restore_owner(self) -> None:
        point = recovery_ux.RecoveryPoint("local", "a.vwrec", "/backups/a.vwrec", 9, "2026-11-25T12:00:00Z", "unknown")
        verified = recovery.VerifiedRecovery(Path(point.location), "a" * 64, 9, point.created_at)
        isolation = mock.Mock(side_effect=[None, recovery_ux.RecoveryUXError("automation changed")])
        with (
            contextlib.redirect_stdout(io.StringIO()),
            mock.patch("sys.stdin.isatty", return_value=True),
            mock.patch("sys.stdout.isatty", return_value=True),
            mock.patch("builtins.input", side_effect=["1", "1", "RESTORE"]),
            mock.patch.object(recovery_ux, "list_local", return_value=[point]),
            mock.patch.object(recovery_ux, "_offline_identity_for_command", return_value=contextlib.nullcontext(Path("/volatile/offline.age"))),
            mock.patch.object(recovery_ux.storage, "verify"),
            mock.patch.object(recovery_ux, "verify_local", return_value=verified),
            mock.patch.object(recovery, "restore_recovery") as restore,
            self.assertRaisesRegex(recovery_ux.RecoveryUXError, "automation changed"),
        ):
            recovery_ux.guided_restore(isolation_check=isolation)
        self.assertEqual(isolation.call_count, 2)
        restore.assert_not_called()

    def test_postrestore_local_policy_displays_retention_and_review_without_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = paths_for(Path(directory))
            paths.config.parent.mkdir()
            paths.config.write_text(config_text() + '\n[backup]\nremote = ""\nlocal_retention_days = 1\nremote_retention_days = 30\n')
            with (
                mock.patch.object(recovery_ux.runtime, "lifecycle") as lifecycle,
                mock.patch.object(operations.cli, "run_command") as command,
                contextlib.redirect_stdout(io.StringIO()) as output,
            ):
                recovery_ux._restored_offsite_policy_notice(recovery_ux.UI(color=False), paths=paths)
            self.assertIn("LOCAL-ONLY", output.getvalue())
            self.assertIn("local/remote=1/30", output.getvalue())
            self.assertIn("BEFORE resuming backup timers", output.getvalue())
            self.assertIn("No automation enablement or DNS publication", output.getvalue())
            lifecycle.assert_not_called()
            command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
