"""Focused tests for opt-in scheduled offsite backup and operator controls."""
from __future__ import annotations

import io
import os
import tempfile
import tomllib
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from vaultwarden_oci import offsite, recovery, runtime

OFFLINE = "age1" + "q" * 58


def sample_config() -> str:
    return f'''schema_version = 1
[site]
domain = "vault.example.net"
acme_email = "admin@example.net"
[secrets]
offline_recovery_recipient = "{OFFLINE}"
[vaultwarden]
signups_allowed = false
[smtp]
host = "smtp.example.net"
port = 587
security = "starttls"
from_email = "vaultwarden@example.net"
from_name = "Vaultwarden"
timeout_seconds = 15
'''


class OffsiteSettingsTests(unittest.TestCase):
    def test_backward_compatible_local_only_default_and_strict_destination_validation(self) -> None:
        cfg = runtime.parse_config(tomllib.loads(sample_config()))
        self.assertIsNone(cfg.offsite_remote)
        good = sample_config() + '\n[backup]\nremote = "cloud:Vaultwarden-OCI"\nlocal_retention_days = 30\nremote_retention_days = 90\n'
        parsed = runtime.parse_config(tomllib.loads(good))
        self.assertEqual(parsed.offsite_remote, "cloud:Vaultwarden-OCI")
        self.assertEqual(parsed.local_retention_days, 30)
        self.assertEqual(parsed.remote_retention_days, 90)
        defaults = runtime.parse_config(tomllib.loads(sample_config()))
        self.assertEqual(defaults.local_retention_days, 0)
        self.assertEqual(defaults.remote_retention_days, 0)
        for value in ("cloud:", "cloud:/absolute", "cloud:../outside", "cloud:a/../b",
                      "cloud:a//b", "cloud:a/./b", "cloud:a\\b", "../cloud:path",
                      "cloud:a\nb", "cloud:a\r", "cloud:a\x00b"):
            with self.subTest(destination=repr(value)):
                with self.assertRaises(runtime.RuntimeConfigError):
                    runtime.backup_remote_destination(value)
        with self.assertRaises(runtime.RuntimeConfigError):
            runtime.parse_config(tomllib.loads(sample_config() + "\n[backup]\nremote = 3\n"))
        with self.assertRaises(runtime.RuntimeConfigError):
            runtime.parse_config(tomllib.loads(sample_config() + "\n[backup]\nremote = \"x:folder\"\npassword = \"secret\"\n"))
        for value in (-1, 36501, True, "30"):
            with self.subTest(retention=value):
                raw = repr(value).lower() if isinstance(value, bool) else repr(value)
                with self.assertRaises(runtime.RuntimeConfigError):
                    runtime.parse_config(tomllib.loads(
                        sample_config() + f"\n[backup]\nlocal_retention_days = {raw}\n"
                    ))

    def test_atomic_config_write_preserves_unrelated_settings_and_disable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config.toml"
            lock = root / "lock"
            config.write_text(sample_config(), encoding="utf-8")
            runtime.set_backup_remote("offsite:Vaultwarden-OCI", path=config, lock_path=lock)
            self.assertEqual(runtime.load_config(config).offsite_remote, "offsite:Vaultwarden-OCI")
            self.assertIn('from_name = "Vaultwarden"', config.read_text(encoding="utf-8"))
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            runtime.set_backup_remote("another:backups", path=config, lock_path=lock)
            self.assertEqual(config.read_text(encoding="utf-8").count("[backup]"), 1)
            self.assertEqual(runtime.load_config(config).offsite_remote, "another:backups")
            runtime.set_backup_remote("", path=config, lock_path=lock)
            self.assertIsNone(runtime.load_config(config).offsite_remote)

    def test_invalid_destination_keeps_config_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config.toml"
            config.write_text(sample_config(), encoding="utf-8")
            original = config.read_bytes()
            with self.assertRaises(runtime.RuntimeConfigError):
                runtime.set_backup_remote("bad:../outside", path=config, lock_path=root / "lock")
            self.assertEqual(config.read_bytes(), original)


class OffsiteWorkflowTests(unittest.TestCase):
    def test_scheduled_and_manual_backup_reuse_owner_without_unsafe_sync(self) -> None:
        cfg = SimpleNamespace(offline_recovery_recipient=OFFLINE, offsite_remote="cloud:backups", local_retention_days=0, remote_retention_days=0)
        verified = SimpleNamespace(artifact=Path("/test/recovery.vwrec"), sha256="a" * 64)
        with (
            mock.patch.object(offsite.runtime, "load_config", return_value=cfg),
            mock.patch.object(offsite.recovery, "create_recovery", return_value=verified) as create,
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(offsite.backup(), 0)
            create.assert_called_once_with(OFFLINE, remote="cloud:backups")
            self.assertEqual(offsite.backup(override="other:folder"), 0)
            self.assertEqual(create.call_args.kwargs["remote"], "other:folder")

    def test_unconfigured_backup_keeps_local_only_behavior(self) -> None:
        cfg = SimpleNamespace(offline_recovery_recipient=OFFLINE, offsite_remote=None, local_retention_days=0, remote_retention_days=0)
        with (
            mock.patch.object(offsite.runtime, "load_config", return_value=cfg),
            mock.patch.object(offsite.recovery, "create_recovery", return_value=SimpleNamespace(artifact=Path("/tmp/test.vwrec"), sha256="a" * 64)) as create,
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(offsite.backup(), 0)
        create.assert_called_once_with(OFFLINE, remote=None)

    def test_failed_remote_publication_propagates_failure(self) -> None:
        cfg = SimpleNamespace(offline_recovery_recipient=OFFLINE, offsite_remote="cloud:backup", local_retention_days=30, remote_retention_days=90)
        with (
            mock.patch.object(offsite.runtime, "load_config", return_value=cfg),
            mock.patch.object(offsite.recovery, "create_recovery", side_effect=recovery.RecoveryError("rclone failed")),
        ):
            with self.assertRaisesRegex(recovery.RecoveryError, "rclone failed"):
                offsite.backup()

    def test_retention_runs_after_success_and_preserves_current_artifact(self) -> None:
        cfg = SimpleNamespace(
            offline_recovery_recipient=OFFLINE,
            offsite_remote="cloud:backups",
            local_retention_days=30,
            remote_retention_days=90,
        )
        verified = SimpleNamespace(artifact=Path("/test/current.vwrec"), sha256="a" * 64)
        with (
            mock.patch.object(offsite.runtime, "load_config", return_value=cfg),
            mock.patch.object(offsite.recovery, "create_recovery", return_value=verified),
            mock.patch.object(
                offsite.recovery,
                "apply_retention",
                return_value=(("old-local.vwrec",), ("old-remote.vwrec",)),
            ) as retention,
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(offsite.backup(), 0)
        retention.assert_called_once_with(
            30,
            remote="cloud:backups",
            remote_days=90,
            preserve=verified,
        )

    def test_one_time_remote_override_never_auto_prunes_alternate_remote(self) -> None:
        cfg = SimpleNamespace(
            offline_recovery_recipient=OFFLINE,
            offsite_remote="cloud:configured",
            local_retention_days=0,
            remote_retention_days=90,
        )
        verified = SimpleNamespace(artifact=Path("/test/current.vwrec"), sha256="a" * 64)
        with (
            mock.patch.object(offsite.runtime, "load_config", return_value=cfg),
            mock.patch.object(offsite.recovery, "create_recovery", return_value=verified),
            mock.patch.object(offsite.recovery, "apply_retention", return_value=((), ())) as retention,
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(offsite.backup(override="other:folder"), 0)
        retention.assert_called_once_with(
            0,
            remote=None,
            remote_days=90,
            preserve=verified,
        )

    def test_failed_publication_never_reaches_retention(self) -> None:
        cfg = SimpleNamespace(
            offline_recovery_recipient=OFFLINE,
            offsite_remote="cloud:backup",
            local_retention_days=30,
            remote_retention_days=90,
        )
        with (
            mock.patch.object(offsite.runtime, "load_config", return_value=cfg),
            mock.patch.object(offsite.recovery, "create_recovery", side_effect=recovery.RecoveryError("rclone failed")),
            mock.patch.object(offsite.recovery, "apply_retention") as retention,
        ):
            with self.assertRaisesRegex(recovery.RecoveryError, "rclone failed"):
                offsite.backup()
        retention.assert_not_called()

    def test_configure_refuses_unreachable_remote_without_persisting(self) -> None:
        with (
            mock.patch.object(offsite.os, "geteuid", return_value=0),
            mock.patch.object(offsite.recovery, "rclone_diagnostics", return_value=(False, "remote is unavailable")),
            mock.patch.object(offsite.runtime, "set_backup_remote") as save,
        ):
            with self.assertRaisesRegex(offsite.OffsiteError, "unavailable"):
                offsite.configure("cloud:backups", interactive=False)
        save.assert_not_called()

    def test_headless_enable_requires_explicit_remote_and_disable_requires_confirmation(self) -> None:
        with (
            mock.patch.object(offsite.os, "geteuid", return_value=0),
            mock.patch.object(offsite.runtime, "set_backup_remote") as save,
        ):
            with self.assertRaises(offsite.OffsiteError):
                offsite.configure(interactive=False)
            with self.assertRaisesRegex(offsite.OffsiteError, "requires --confirm"):
                offsite.disable(confirmed=False)
            save.assert_not_called()
            offsite.disable(confirmed=True)
            save.assert_called_once_with("")

    def test_explicit_configure_saves_only_after_connectivity_validation(self) -> None:
        with (
            mock.patch.object(offsite.os, "geteuid", return_value=0),
            mock.patch.object(offsite.recovery, "rclone_diagnostics", return_value=(True, "remote reachable")),
            mock.patch.object(offsite.recovery, "prepare_rclone_destination", return_value=(True, "destination ready")) as prepare,
            mock.patch.object(offsite.runtime, "set_backup_remote") as save,
            redirect_stdout(io.StringIO()),
        ):
            offsite.configure("cloud:backups", interactive=False)
        prepare.assert_called_once_with("cloud:backups")
        save.assert_called_once_with("cloud:backups")

    def test_interactive_cancel_does_not_prepare_or_mutate_remote(self) -> None:
        with (
            mock.patch.object(offsite.os, "geteuid", return_value=0),
            mock.patch.object(offsite.recovery, "rclone_diagnostics", return_value=(True, "reachable")),
            mock.patch.object(offsite.recovery, "prepare_rclone_destination") as prepare,
            mock.patch.object(offsite.runtime, "set_backup_remote") as save,
            mock.patch.object(offsite.sys.stdin, "isatty", return_value=True),
            mock.patch.object(offsite.sys.stdout, "isatty", return_value=True),
            mock.patch("builtins.input", return_value="CANCEL"),
            redirect_stdout(io.StringIO()),
        ):
            offsite.configure("cloud:backups", interactive=True)
        prepare.assert_not_called()
        save.assert_not_called()

    def test_status_distinguishes_optional_and_configured_failure(self) -> None:
        disabled = SimpleNamespace(offsite_remote=None, local_retention_days=0, remote_retention_days=0)
        configured = SimpleNamespace(offsite_remote="cloud:backups", local_retention_days=30, remote_retention_days=90)
        with (
            mock.patch.object(offsite.runtime, "load_config", return_value=disabled),
            redirect_stdout(io.StringIO()) as output,
        ):
            offsite.status()
        self.assertIn("disabled", output.getvalue())
        self.assertIn("keep indefinitely", output.getvalue())
        with (
            mock.patch.object(offsite.runtime, "load_config", return_value=configured),
            mock.patch.object(offsite.recovery, "rclone_destination_diagnostics", return_value=(False, "unreachable")),
            redirect_stdout(io.StringIO()) as output,
        ):
            with self.assertRaises(offsite.OffsiteError):
                offsite.status()
        self.assertIn("prune older than 30 days", output.getvalue())


if __name__ == "__main__":
    unittest.main()
