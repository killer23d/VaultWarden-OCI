"""Backup guide consent, truthfulness and authoritative-owner boundaries."""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import subprocess
import tempfile
import tomllib
import unittest
from dataclasses import replace
from pathlib import Path
from unittest import mock

from vaultwarden_oci import backup_guide, offsite, recovery, runtime
from test_recovery_ux import config_text, paths_for


class BackupProtectionTests(unittest.TestCase):
    def test_receipt_details_and_destination_match_use_one_history_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = paths_for(Path(directory))
            paths.config.parent.mkdir(parents=True)
            paths.config.write_text(config_text() + '\n[backup]\nremote = "cloud:new"\n')
            receipt = {"verified_at": "2026-11-20T01:05:00Z", "sha256": "a" * 64, "size": 128}
            first = {"schema_version": 1, "offsite": {**receipt, "remote_object": "cloud:old/recovery-20261120T010000Z-a.vwrec"}}
            second = {"schema_version": 1, "offsite": {**receipt, "remote_object": "cloud:new/recovery-20261120T020000Z-b.vwrec"}}
            with (mock.patch.object(recovery, "_load_state", side_effect=[first, second]) as read,
                  mock.patch.object(backup_guide.operations, "_systemd_properties", return_value={
                      "load_state": "loaded", "active_state": "active", "enabled": "disabled"}),
                  contextlib.redirect_stdout(io.StringIO()) as output):
                self.assertEqual(backup_guide.protection(paths=paths), 0)
            self.assertEqual(read.call_count, 1)
            self.assertIn("cloud:old/recovery-20261120T010000Z-a.vwrec", output.getvalue())
            self.assertIn("Matches current saved destination: NO", output.getvalue())

    def test_four_assurance_levels_keep_receipts_historical_and_destination_specific(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = paths_for(Path(directory))
            paths.config.parent.mkdir(parents=True)
            paths.config.write_text(config_text() + '\n[backup]\nremote = "cloud:new"\n')
            paths.backups.mkdir()
            archive = paths.backups / "recovery-20261120T010000Z-abc.vwrec"
            archive.write_bytes(b"observed ciphertext")
            receipt = {"verified_at": "2026-11-20T01:05:00Z", "sha256": "a" * 64, "size": archive.stat().st_size}
            paths.state_file.parent.mkdir()
            paths.state_file.write_text(json.dumps({
                "schema_version": 1,
                "local": {**receipt, "artifact": str(archive)},
                "offsite": {**receipt, "remote_object": "cloud:old/" + archive.name},
                "verified_objects": {"cloud:old/" + archive.name: receipt},
            }))
            before = {path: path.read_bytes() for path in (paths.config, paths.state_file, archive)}
            with (mock.patch.object(backup_guide.operations, "_systemd_properties", return_value={
                    "load_state": "loaded", "active_state": "active", "enabled": "disabled", "next": "next observed event"}),
                  mock.patch.object(recovery, "list_remote") as listing,
                  mock.patch.object(backup_guide.recovery_ux, "verify_local") as verify,
                  contextlib.redirect_stdout(io.StringIO()) as output):
                self.assertEqual(backup_guide.protection(paths=paths), 0)
            text = output.getvalue()
            self.assertIn("Saved destination: cloud:new", text)
            self.assertIn("Matches current saved destination: NO", text)
            self.assertIn("3. Offline-key cryptographic recovery verified: HISTORICAL", text)
            self.assertIn("4. Disposable-host recovery demonstrated: NOT ESTABLISHED", text)
            self.assertIn("next observed event", text)
            listing.assert_not_called()
            verify.assert_not_called()
            self.assertEqual({path: path.read_bytes() for path in before}, before)

    def test_missing_malformed_and_future_history_never_becomes_verification(self):
        for state in ({"schema_version": True}, {"schema_version": 1, "state_error": "unreadable"},
                      {"schema_version": 1, "verified_objects": {"object": {"size": True, "sha256": "a" * 64, "verified_at": "2026-01-01T00:00:00Z"}}},
                      {"schema_version": 1, "verified_objects": {"object": {"size": 20, "sha256": "a" * 64, "verified_at": "9999-01-01T00:00:00Z"}}}):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                paths = paths_for(Path(directory))
                paths.config.parent.mkdir(parents=True)
                paths.config.write_text(config_text())
                with (mock.patch.object(recovery, "_load_state", return_value=state),
                      mock.patch.object(backup_guide.operations, "_systemd_properties", return_value={
                          "load_state": "unknown", "active_state": "unknown", "enabled": "unknown"}),
                      contextlib.redirect_stdout(io.StringIO()) as output):
                    self.assertEqual(backup_guide.protection(paths=paths), 0)
                self.assertIn("3. Offline-key cryptographic recovery verified: NOT ESTABLISHED", output.getvalue())
                self.assertFalse(paths.backups.exists())


class BackupConsentTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
        self.stack.enter_context(mock.patch.object(backup_guide, "_interactive"))
        self.stack.enter_context(mock.patch.object(backup_guide.storage, "verify"))
        self.config = runtime.parse_config(tomllib.loads(config_text()))
        self.stack.enter_context(mock.patch.object(runtime, "load_config", return_value=self.config))
        self.stack.enter_context(mock.patch.object(backup_guide, "_reviewed_config", return_value=(self.config, "same")))

    def test_choose_local_only_needs_no_remote_mutation_and_default_no_runs_no_backup(self):
        with (mock.patch("builtins.input", side_effect=["1", ""]),
              mock.patch.object(offsite, "disable") as disable,
              mock.patch.object(offsite, "configure") as configure,
              mock.patch.object(backup_guide, "backup_now") as backup):
            self.assertEqual(backup_guide.configure(), 0)
        disable.assert_not_called()
        configure.assert_not_called()
        backup.assert_not_called()

    def test_offsite_cancel_does_not_fall_through_to_first_backup(self):
        with (mock.patch("builtins.input", return_value="2") as prompt,
              mock.patch.object(offsite, "_configured_names", return_value=["cloud"]),
              mock.patch.object(offsite, "configure", return_value=False),
              mock.patch.object(backup_guide, "backup_now") as backup):
            self.assertEqual(backup_guide.configure(), 0)
        self.assertEqual(prompt.call_count, 1)
        backup.assert_not_called()

    def test_disable_cancel_stops_without_another_action(self):
        cfg = replace(self.config, offsite_remote="cloud:folder")
        with (mock.patch.object(runtime, "load_config", return_value=cfg),
              mock.patch("builtins.input", return_value="1") as prompt,
              mock.patch.object(offsite, "disable", return_value=False) as disable,
              mock.patch.object(backup_guide, "backup_now") as backup):
            self.assertEqual(backup_guide.configure(), 0)
        disable.assert_called_once_with(confirmed=False)
        self.assertEqual(prompt.call_count, 1)
        backup.assert_not_called()

    def test_missing_root_remote_offers_supported_rclone_but_defaults_to_cancel(self):
        with (mock.patch("builtins.input", side_effect=["2", ""]),
              mock.patch.object(offsite, "_configured_names", side_effect=offsite.OffsiteError("missing")),
              mock.patch.object(backup_guide.subprocess, "run") as launch,
              mock.patch.object(offsite, "configure") as configure):
            self.assertEqual(backup_guide.configure(), 0)
        launch.assert_not_called()
        configure.assert_not_called()

    def test_root_rclone_uses_provider_cli_then_existing_enable_owner(self):
        with (mock.patch("builtins.input", side_effect=["2", "RCLONE", ""]),
              mock.patch.object(offsite, "_configured_names", side_effect=offsite.OffsiteError("missing")),
              mock.patch.object(backup_guide.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as launch,
              mock.patch.object(offsite, "configure", return_value=True) as configure):
            self.assertEqual(backup_guide.configure(), 0)
        launch.assert_called_once_with(["rclone", "config"], check=False)
        configure.assert_called_once_with()

    def test_provider_setup_failure_never_saves_destination(self):
        with (mock.patch("builtins.input", side_effect=["2", "RCLONE"]),
              mock.patch.object(offsite, "_configured_names", side_effect=offsite.OffsiteError("missing")),
              mock.patch.object(backup_guide.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)),
              mock.patch.object(offsite, "configure") as configure):
            self.assertEqual(backup_guide.configure(), 2)
        configure.assert_not_called()

    def test_immediate_backup_requires_separate_opt_in(self):
        with (mock.patch("builtins.input", side_effect=["2", "yes"]),
              mock.patch.object(offsite, "_configured_names", return_value=["cloud"]),
              mock.patch.object(offsite, "configure", return_value=True),
              mock.patch.object(backup_guide, "backup_now", return_value=0) as backup):
            self.assertEqual(backup_guide.configure(), 0)
        backup.assert_called_once_with()

    def test_backup_default_no_never_dispatches(self):
        with (mock.patch.object(backup_guide, "_backup_ready"),
              mock.patch.object(backup_guide, "_fingerprint", return_value="same"),
              mock.patch("builtins.input", return_value=""),
              mock.patch.object(offsite, "backup") as backup):
            self.assertEqual(backup_guide.backup_now(), 0)
        backup.assert_not_called()

    def test_policy_drift_after_consent_blocks_backup(self):
        with (mock.patch.object(backup_guide, "_backup_ready"),
              mock.patch.object(backup_guide, "_fingerprint", return_value="changed"),
              mock.patch("builtins.input", return_value="BACKUP"),
              mock.patch.object(offsite, "backup") as backup):
            self.assertEqual(backup_guide.backup_now(), 2)
        backup.assert_not_called()

    def test_backup_uses_same_pipeline_and_keeps_publication_failure_visible(self):
        with (mock.patch.object(backup_guide, "_backup_ready"),
              mock.patch.object(backup_guide, "_fingerprint", return_value="same"),
              mock.patch("builtins.input", return_value="BACKUP"),
              mock.patch.object(offsite, "backup", side_effect=recovery.RecoveryError("upload failed")) as backup):
            self.assertEqual(backup_guide.backup_now(), 1)
        backup.assert_called_once_with(reviewed_config=self.config)

    def test_interrupt_reports_incomplete_without_starting_backup(self):
        with (mock.patch.object(backup_guide, "_backup_ready"),
              mock.patch.object(backup_guide, "_fingerprint", return_value="same"),
              mock.patch("builtins.input", side_effect=KeyboardInterrupt),
              mock.patch.object(offsite, "backup") as backup):
            self.assertEqual(backup_guide.backup_now(), 130)
        backup.assert_not_called()


class ReviewedBackupPolicyTests(unittest.TestCase):
    def test_reviewed_config_and_hash_come_from_the_same_raw_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            raw = (config_text() + '\n[backup]\nremote = "cloud:reviewed"\nlocal_retention_days = 0\n').encode()
            path.write_bytes(raw)
            with mock.patch.object(runtime, "CONFIG", path):
                reviewed, witness = backup_guide._reviewed_config()
            self.assertEqual(reviewed.offsite_remote, "cloud:reviewed")
            self.assertEqual(reviewed.local_retention_days, 0)
            self.assertEqual(witness, hashlib.sha256(raw).hexdigest())

    def test_handoff_edit_after_last_fingerprint_refuses_unreviewed_publication_and_pruning(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            before = config_text() + '\n[backup]\nremote = ""\nlocal_retention_days = 0\nremote_retention_days = 0\n'
            after = config_text() + '\n[backup]\nremote = "cloud:unreviewed"\nlocal_retention_days = 1\nremote_retention_days = 1\n'
            path.write_text(before)
            loader = runtime.load_config

            def last_fingerprint_then_concurrent_edit():
                fingerprint = hashlib.sha256(path.read_bytes()).hexdigest()
                path.write_text(after)
                return fingerprint

            with (
                mock.patch.object(runtime, "CONFIG", path),
                mock.patch.object(runtime, "load_config", side_effect=lambda: loader(path)),
                mock.patch.object(backup_guide, "_interactive"),
                mock.patch.object(backup_guide, "_backup_ready"),
                mock.patch.object(backup_guide, "_fingerprint", side_effect=last_fingerprint_then_concurrent_edit),
                mock.patch("builtins.input", return_value="BACKUP"),
                mock.patch.object(recovery, "create_recovery") as create,
                mock.patch.object(recovery, "apply_retention") as prune,
                contextlib.redirect_stdout(io.StringIO()) as output,
                contextlib.redirect_stderr(io.StringIO()) as errors,
            ):
                self.assertEqual(backup_guide.backup_now(), 1)
            self.assertIn("Saved destination: LOCAL-ONLY", output.getvalue())
            self.assertIn("changed after backup review", errors.getvalue())
            create.assert_not_called()
            prune.assert_not_called()
            self.assertEqual(path.read_text(), after)

    def test_reviewed_owner_keeps_destination_and_retention_bound_to_review(self):
        config = runtime.parse_config(__import__("tomllib").loads(
            config_text() + '\n[backup]\nremote = "cloud:reviewed"\nlocal_retention_days = 30\nremote_retention_days = 60\n'
        ))
        verified = recovery.VerifiedRecovery(Path("/backups/recovery-20261125T120000Z-a.vwrec"), "a" * 64, 50, "2026-11-25T12:00:00Z")
        with (
            mock.patch.object(runtime, "load_config", return_value=config),
            mock.patch.object(recovery, "create_recovery", return_value=verified) as create,
            mock.patch.object(recovery, "apply_retention", return_value=((), ())) as retention,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(offsite.backup(reviewed_config=config), 0)
        create.assert_called_once_with(config.offline_recovery_recipient, remote="cloud:reviewed", require_current_remote=True)
        retention.assert_called_once_with(
            30, remote="cloud:reviewed", remote_days=60, preserve=verified,
            expected_backup_policy=("cloud:reviewed", 30, 60),
        )


class BackupPreconditionTests(unittest.TestCase):
    def test_nonterminal_refused_before_configuration_or_backup(self):
        for action in (backup_guide.configure, backup_guide.backup_now):
            with (self.subTest(action=action), mock.patch.object(backup_guide.os, "geteuid", return_value=0),
                  mock.patch.object(backup_guide.sys.stdin, "isatty", return_value=False),
                  mock.patch.object(runtime, "load_config") as config,
                  mock.patch.object(offsite, "backup") as backup,
                  contextlib.redirect_stderr(io.StringIO())):
                self.assertEqual(action(), 2)
            config.assert_not_called()
            backup.assert_not_called()

    def test_active_guard_or_unhealthy_runtime_block_guided_backup(self):
        with (mock.patch.object(backup_guide.storage, "verify"),
              mock.patch.object(backup_guide.update_guard, "status_snapshot", return_value={"state": "active"}),
              self.assertRaises(backup_guide.Hold)):
            backup_guide._backup_ready()
        with (mock.patch.object(backup_guide.storage, "verify"),
              mock.patch.object(backup_guide.update_guard, "status_snapshot", return_value={"state": "absent"}),
              mock.patch.object(runtime, "status", return_value=("running", [{"service": "vaultwarden", "state": "running", "health": "unhealthy"}])),
              self.assertRaises(backup_guide.Hold)):
            backup_guide._backup_ready()


if __name__ == "__main__":
    unittest.main()
