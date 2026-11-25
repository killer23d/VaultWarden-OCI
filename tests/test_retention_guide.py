from __future__ import annotations

import hashlib
import io
import json
import os
import tempfile
import tomllib
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, recovery, retention_guide, runtime
from test_offsite import sample_config


OLD = "recovery-20260101T000000Z-old.vwrec"
CURRENT = "recovery-20261125T000000Z-current.vwrec"
NOW = datetime(2026, 11, 25, tzinfo=timezone.utc)


class Terminal(io.StringIO):
    def isatty(self):
        return True


class ReadOnlyRemote:
    def __init__(self):
        self.calls = []
        self.entries = [{"Name": OLD, "Path": OLD, "Size": 100}]
        self.unavailable = False

    def __call__(self, argv, **kwargs):
        self.calls.append(tuple(argv))
        if argv[:2] == ["rclone", "listremotes"]:
            output = "cloud:\n"
        elif argv[:2] == ["rclone", "lsjson"]:
            if self.unavailable:
                return cli.CommandResult(tuple(argv), "nonzero", 1, "", "provider unavailable")
            output = json.dumps(self.entries)
        elif argv[:2] in (["rclone", "version"], ["rclone", "config"], ["rclone", "lsf"]):
            output = "available"
        else:
            raise AssertionError("Unexpected command in read-only retention review: " + repr(argv))
        return cli.CommandResult(tuple(argv), "success", 0, output, "")


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.paths = recovery.RecoveryPaths(
            backups=self.root / "backups", config=self.root / "config.toml",
            lock=self.root / "lock", state_file=self.root / "recovery.json",
        )
        self.paths.config.write_text(sample_config(), encoding="utf-8")
        self.paths.config.chmod(0o600)
        self.paths.backups.mkdir()
        for name, size in ((OLD, 100), (CURRENT, 300)):
            (self.paths.backups / name).write_bytes(b"x" * size)
        self.remote = ReadOnlyRemote()

    def configure(self, remote="cloud:isolated", local=0, offsite=0):
        self.paths.config.write_text(
            sample_config() + f'\n[backup]\nremote = "{remote}"\nlocal_retention_days = {local}\nremote_retention_days = {offsite}\n',
            encoding="utf-8",
        )

    def run_guide(self, answers):
        output = Terminal()
        with (
            mock.patch.object(retention_guide.sys, "stdin", Terminal()),
            redirect_stdout(output),
            mock.patch("builtins.input", side_effect=answers),
        ):
            rc = retention_guide.main(paths=self.paths, runner=self.remote)
        return rc, output.getvalue()

    def snapshot(self):
        return {p.name: p.read_bytes() for p in self.paths.backups.iterdir()}

    def test_age_selection_zero_strict_cutoff_current_and_unrelated_points(self):
        entries = [{"Name": name} for name in (OLD, CURRENT, "notes.vwrec", "recovery-bad.vwrec")]
        zero = recovery.age_pruning_decision(entries, 0, now=NOW)
        self.assertEqual(zero.delete, ())
        self.assertEqual(set(zero.keep), {OLD, CURRENT})
        preserved = recovery.age_pruning_decision(entries, 1, preserve_name=OLD, now=NOW)
        self.assertEqual(preserved.delete, ())
        boundary = "recovery-20261124T000000Z-boundary.vwrec"
        plan = recovery.age_pruning_decision([*entries, {"Name": boundary}], 1, now=NOW)
        self.assertEqual(plan.delete, (OLD,))
        self.assertIn(boundary, plan.keep)

    def test_local_preview_matches_real_prune_and_keeps_protected_point(self):
        entries = recovery.local_retention_inventory(self.paths)
        expected = recovery.age_pruning_decision(entries, 30, preserve_name=CURRENT, now=NOW)
        deleted = recovery.prune_local_by_age(
            30, paths=self.paths, preserve=self.paths.backups / CURRENT, now=NOW,
        )
        self.assertEqual(deleted, expected.delete)
        self.assertEqual(set(self.snapshot()), {CURRENT})

    def test_unsafe_remote_entry_stops_before_any_deletion(self):
        entries = [{"Name": OLD}, {"Name": CURRENT, "Path": "nested/" + CURRENT}]
        self.remote.entries = entries
        with self.assertRaisesRegex(recovery.RecoveryError, "unsafe"):
            recovery.prune_remote_by_age("cloud:isolated", 1, runner=self.remote, now=NOW)
        self.assertFalse(any(call[:2] == ("rclone", "deletefile") for call in self.remote.calls))

    def test_local_symlink_or_empty_file_blocks_preview(self):
        for unsafe in ("empty", "symlink"):
            with self.subTest(unsafe=unsafe):
                path = self.paths.backups / OLD
                path.unlink()
                if unsafe == "empty":
                    path.touch()
                else:
                    path.symlink_to(self.paths.backups / CURRENT)
                with self.assertRaises(recovery.RecoveryError):
                    retention_guide.observe(paths=self.paths, runner=self.remote)
                path.unlink()
                path.write_bytes(b"valid")

    def test_default_review_is_local_only_zero_and_read_only(self):
        before = self.paths.config.read_bytes(), self.snapshot()
        rc, output = self.run_guide([""])
        self.assertEqual(rc, 0)
        self.assertEqual(before, (self.paths.config.read_bytes(), self.snapshot()))
        self.assertEqual(self.remote.calls, [])
        self.assertIn("LOCAL-ONLY", output)
        self.assertIn("0 days: keep indefinitely", output)
        self.assertIn("400 bytes", output)
        self.assertIn("6000 bytes before retention", output)
        self.assertIn("assuming the observed average", output)
        self.assertFalse(self.paths.lock.exists())

    def test_default_days_and_final_cancellation_preserve_everything(self):
        self.configure()
        before = self.paths.config.read_bytes(), self.snapshot()
        for answers in (["CHANGE", "", ""], ["CHANGE", "30", "90", "save"], ["CHANGE", "q"]):
            with self.subTest(answers=answers):
                rc, _ = self.run_guide(answers)
                self.assertEqual(rc, 0)
                self.assertEqual(before, (self.paths.config.read_bytes(), self.snapshot()))

    def test_interruption_before_save_preserves_everything(self):
        before = self.paths.config.read_bytes(), self.snapshot()
        for error in (EOFError, KeyboardInterrupt):
            rc, output = self.run_guide(error)
            self.assertEqual(rc, 0)
            self.assertIn("CANCELLED", output)
            self.assertEqual(before, (self.paths.config.read_bytes(), self.snapshot()))

    def test_save_updates_only_policy_without_backup_delete_or_schedule(self):
        self.configure()
        before = tomllib.loads(self.paths.config.read_text()), self.snapshot()
        rc, output = self.run_guide(["CHANGE", "30", "90", "SAVE"])
        self.assertEqual(rc, 0, output)
        after = tomllib.loads(self.paths.config.read_text())
        before[0]["backup"].update(local_retention_days=30, remote_retention_days=90)
        self.assertEqual(after, before[0])
        self.assertEqual(self.snapshot(), before[1])
        self.assertEqual(self.paths.config.stat().st_mode & 0o777, 0o600)
        listings = [call for call in self.remote.calls if call[:2] == ("rclone", "lsjson")]
        self.assertEqual(listings, [("rclone", "lsjson", "cloud:isolated", "--files-only")] * 2)
        self.assertIn(OLD, output)
        self.assertIn("No files deleted", output)

    def test_local_only_save_does_not_activate_remote_policy(self):
        rc, output = self.run_guide(["CHANGE", "30", "SAVE"])
        self.assertEqual(rc, 0, output)
        cfg = runtime.load_config(self.paths.config)
        self.assertEqual(cfg.local_retention_days, 30)
        self.assertEqual(cfg.remote_retention_days, 0)
        self.assertIsNone(cfg.offsite_remote)
        self.assertEqual(self.remote.calls, [])

    def test_dormant_remote_policy_can_be_disabled_without_remote_access(self):
        self.configure(remote="", offsite=90)
        rc, output = self.run_guide(["CHANGE", "", "0", "SAVE"])
        self.assertEqual(rc, 0, output)
        cfg = runtime.load_config(self.paths.config)
        self.assertIsNone(cfg.offsite_remote)
        self.assertEqual((cfg.local_retention_days, cfg.remote_retention_days), (0, 0))
        self.assertIn("would apply when an offsite destination is enabled", output)
        self.assertEqual(self.remote.calls, [])

    def test_dormant_remote_policy_cannot_change_to_new_nonzero_value(self):
        self.configure(remote="", offsite=90)
        before = self.paths.config.read_bytes()
        rc, output = self.run_guide(["CHANGE", "", "30"])
        self.assertEqual(rc, 2)
        self.assertIn("choose a saved offsite destination", output)
        self.assertEqual(before, self.paths.config.read_bytes())

    def test_remote_unavailable_or_unsafe_preview_never_saves(self):
        self.configure()
        before = self.paths.config.read_bytes()
        self.remote.unavailable = True
        rc, output = self.run_guide([])
        self.assertEqual(rc, 2)
        self.assertIn("HOLD", output)
        self.assertEqual(before, self.paths.config.read_bytes())
        self.remote.unavailable = False
        self.remote.entries[0]["Path"] = "nested/" + OLD
        rc, output = self.run_guide([])
        self.assertEqual(rc, 2)
        self.assertIn("unsafe", output)
        self.assertEqual(before, self.paths.config.read_bytes())

    def test_changed_inventory_after_consent_blocks_save(self):
        self.configure()
        before = self.paths.config.read_bytes()
        answers = iter(["CHANGE", "30", "90", "SAVE"])

        def answer(prompt):
            result = next(answers)
            if result == "SAVE":
                self.remote.entries.append({"Name": CURRENT, "Size": 200})
            return result

        rc, output = self.run_guide(answer)
        self.assertEqual(rc, 2)
        self.assertIn("inventory changed", output)
        self.assertEqual(before, self.paths.config.read_bytes())

    def test_changed_saved_destination_blocks_save(self):
        self.configure()
        answers = iter(["CHANGE", "30", "90", "SAVE"])

        def answer(prompt):
            result = next(answers)
            if result == "SAVE":
                self.configure(remote="cloud:different")
            return result

        rc, output = self.run_guide(answer)
        self.assertEqual(rc, 2)
        self.assertIn("config changed", output)
        cfg = runtime.load_config(self.paths.config)
        self.assertEqual((cfg.offsite_remote, cfg.local_retention_days, cfg.remote_retention_days), ("cloud:different", 0, 0))

    def test_age_cutoff_change_during_prompt_requires_new_preview(self):
        before = self.paths.config.read_bytes()
        with mock.patch.object(retention_guide, "datetime") as clock:
            clock.now.side_effect = [NOW, NOW + timedelta(days=31)]
            rc, output = self.run_guide(["CHANGE", "30", "SAVE"])
        self.assertEqual(rc, 2)
        self.assertIn("preview changed with time", output)
        self.assertEqual(before, self.paths.config.read_bytes())

    def test_busy_mutation_lock_refuses_policy_save(self):
        before = self.paths.config.read_bytes()
        with cli.mutation_lock(self.paths.lock):
            rc, output = self.run_guide(["CHANGE", "30", "SAVE"])
        self.assertEqual(rc, 2)
        self.assertIn("another mutating", output)
        self.assertEqual(before, self.paths.config.read_bytes())

    def test_noninteractive_and_nonroot_production_forms_fail_before_observing(self):
        with (
            mock.patch.object(retention_guide.sys, "stdin", io.StringIO()),
            redirect_stdout(io.StringIO()),
            mock.patch.object(retention_guide, "observe") as observe,
        ):
            self.assertEqual(retention_guide.main(paths=self.paths), 2)
            observe.assert_not_called()
        with (
            mock.patch.object(retention_guide.os, "geteuid", return_value=1000),
            redirect_stdout(io.StringIO()),
            mock.patch.object(retention_guide, "observe") as observe,
        ):
            self.assertEqual(retention_guide.main(), 2)
            observe.assert_not_called()

    def test_invalid_days_fail_without_save(self):
        before = self.paths.config.read_bytes()
        for value in ("-1", "36501", "1.2", "NaN"):
            rc, output = self.run_guide(["CHANGE", value])
            self.assertEqual(rc, 2, output)
            self.assertEqual(before, self.paths.config.read_bytes())

    def test_missing_remote_size_does_not_invent_projection(self):
        self.configure()
        self.remote.entries[0].pop("Size")
        rc, output = self.run_guide([""])
        self.assertEqual(rc, 0)
        self.assertIn("Projection for remote flat inventory: unavailable", output)

    def test_owner_checks_preview_under_lock_and_rejects_config_drift(self):
        original = self.paths.config.read_bytes()
        digest = hashlib.sha256(original).hexdigest()

        def verify_preview():
            with self.assertRaises(cli.LockBusyError):
                with cli.mutation_lock(self.paths.lock):
                    self.fail("owner did not hold the mutation lock")

        runtime.set_backup_retention(
            30, 0, expected_config_sha256=digest, verify_preview=verify_preview,
            path=self.paths.config, lock_path=self.paths.lock,
        )
        self.assertEqual(runtime.load_config(self.paths.config).local_retention_days, 30)
        with self.assertRaisesRegex(runtime.RuntimeConfigError, "config changed"):
            runtime.set_backup_retention(
                90, 0, expected_config_sha256=digest, verify_preview=verify_preview,
                path=self.paths.config, lock_path=self.paths.lock,
            )
        self.assertEqual(runtime.load_config(self.paths.config).local_retention_days, 30)

    def test_owner_failed_preview_and_unusual_toml_preserve_original(self):
        for kind in ("failed_preview", "quoted_keys"):
            with self.subTest(kind=kind):
                self.configure()
                if kind == "quoted_keys":
                    self.paths.config.write_text(self.paths.config.read_text().replace("local_retention_days =", '"local_retention_days" ='))
                original = self.paths.config.read_bytes()

                def verify_preview():
                    if kind == "failed_preview":
                        raise RetentionErrorForTest("unavailable")

                with self.assertRaises((RuntimeError, runtime.RuntimeConfigError)):
                    runtime.set_backup_retention(
                        30, 90, expected_config_sha256=hashlib.sha256(original).hexdigest(),
                        verify_preview=verify_preview, path=self.paths.config, lock_path=self.paths.lock,
                    )
                self.assertEqual(original, self.paths.config.read_bytes())


class RetentionErrorForTest(RuntimeError):
    pass


if __name__ == "__main__":
    unittest.main()
