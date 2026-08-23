from __future__ import annotations

import hashlib
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, install, recovery, update, update_appliance, update_unit_migration, update_versions


def digest(char: str) -> str:
    return "sha256:" + char * 64


def frozen() -> update_versions.FrozenVersions:
    return update_versions.FrozenVersions(
        "pinned", "amd64", "2.0.0", "1.40.0", "2.12.0", "v0.3.0",
        update_versions.ImagePin("vaultwarden", "vaultwarden/server", "1.40.0", digest("a")),
        update_versions.ImagePin("caddy_builder", "caddy", "2.12.0-builder-alpine", digest("b")),
        update_versions.ImagePin("caddy_runtime", "caddy", "2.12.0-alpine", digest("c")),
        caddy_cloudflare_ip="d" * 40,
        caddy_combine_ip_ranges="v0.0.2",
        caddy_ratelimit="v0.2.0",
    )


def command(argv, *, ok: bool = True) -> cli.CommandResult:
    return cli.CommandResult(tuple(argv), "success" if ok else "nonzero", 0 if ok else 1, "", "")


class UnitMigrationTests(unittest.TestCase):
    def test_new_owned_units_are_removed_when_rolling_back_to_older_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            layout = install.Layout(root / "host")
            old = root / "old"
            candidate = root / "candidate"
            old_units = old / install.SYSTEMD_SOURCE_DIR
            candidate_units = candidate / install.SYSTEMD_SOURCE_DIR
            old_units.mkdir(parents=True)
            candidate_units.mkdir(parents=True)
            installed = layout.path(install.SYSTEMD_DIR)
            installed.mkdir(parents=True)

            update_units = set(update_unit_migration.install.SYSTEMD_UNITS)
            for name in update_units:
                if name.startswith("vaultwarden-oci-update-check"):
                    (candidate_units / name).write_text("candidate\n", encoding="utf-8")
                    (installed / name).write_text("candidate\n", encoding="utf-8")
                else:
                    (old_units / name).write_text("old\n", encoding="utf-8")
                    (candidate_units / name).write_text("candidate\n", encoding="utf-8")
                    (installed / name).write_text("candidate\n", encoding="utf-8")

            update_unit_migration.install_units(old, candidate, layout)
            for name in update_units:
                path = installed / name
                if name.startswith("vaultwarden-oci-update-check"):
                    self.assertFalse(path.exists())
                else:
                    self.assertEqual(path.read_text(encoding="utf-8"), "old\n")


class CoherentRollbackTests(unittest.TestCase):
    def _failure(self, temp: Path) -> update_appliance.PersistentStateFailure:
        artifact = temp / "pre-update.vwrec"
        artifact.write_bytes(b"verified recovery bytes")
        verified = recovery.VerifiedRecovery(
            artifact,
            hashlib.sha256(artifact.read_bytes()).hexdigest(),
            artifact.stat().st_size,
            "2026-08-23T00:00:00Z",
        )
        plan = update.UpdatePlan(
            temp / "source",
            Path("/"),
            Path("releases/1.0.0"),
            "1.0.0",
            "2.0.0",
            frozen(),
        )
        return update_appliance.PersistentStateFailure(
            "candidate failed after start",
            plan=plan,
            verified=verified,
            services_stopped=True,
        )

    def test_coherent_rollback_uses_recorded_artifact_then_previous_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            failure = self._failure(temp)
            previous = Path("/opt/vaultwarden-oci/releases/1.0.0")
            identity = temp / "offline.age"
            identity.write_text("AGE-SECRET-KEY-test\n", encoding="utf-8")
            restore_calls: list[tuple[Path, Path, bool]] = []
            switches: list[Path] = []

            def restore(artifact, key, *, start, runner):
                restore_calls.append((artifact, key, start))
                return {"created_at": "2026-08-23T00:00:00Z"}

            with (
                mock.patch.object(update_appliance.storage, "verify"),
                mock.patch.object(update_appliance.recovery, "restore_recovery", side_effect=restore),
                mock.patch.object(update_appliance.recovery, "_sha256", return_value=failure.verified.sha256),
                mock.patch.object(update_appliance.install, "ensure_lock_path", return_value=temp / "lock"),
                mock.patch.object(update_appliance.cli, "mutation_lock", return_value=mock.MagicMock(__enter__=mock.Mock(return_value=None), __exit__=mock.Mock(return_value=False))),
                mock.patch.object(update_appliance.update, "_current", return_value=(Path("releases/2.0.0"), "2.0.0", Path("/opt/vaultwarden-oci/releases/1.0.0"))),
                mock.patch.object(Path, "is_dir", return_value=True),
                mock.patch.object(Path, "is_symlink", return_value=False),
                mock.patch.object(update_appliance.update, "_install_units", return_value={}) as install_units,
                mock.patch.object(update_appliance.update, "_switch", side_effect=lambda _layout, target: switches.append(target)),
                mock.patch.object(update_appliance.update, "_daemon_reload"),
                mock.patch.object(update_appliance, "_prove_previous"),
            ):
                update_appliance.coherent_rollback(
                    failure,
                    identity,
                    runner=lambda argv, **_kwargs: command(argv),
                )

            self.assertEqual(restore_calls, [(failure.verified.artifact, identity, False)])
            self.assertEqual(switches, [failure.plan.current_target])
            self.assertEqual(install_units.call_args.args[0], previous)

    def test_storage_failure_blocks_data_restore(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            failure = self._failure(temp)
            restore = mock.Mock()
            with (
                mock.patch.object(update_appliance.storage, "verify", side_effect=update_appliance.storage.StorageError("missing dedicated storage")),
                mock.patch.object(update_appliance.recovery, "restore_recovery", restore),
            ):
                with self.assertRaisesRegex(update_appliance.storage.StorageError, "missing dedicated storage"):
                    update_appliance.coherent_rollback(
                        failure,
                        temp / "identity",
                        runner=lambda argv, **_kwargs: command(argv),
                    )
            restore.assert_not_called()


if __name__ == "__main__":
    unittest.main()
