from __future__ import annotations

import contextlib
import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import (
    cli,
    install,
    recovery,
    update,
    update_appliance,
    update_unit_migration,
    update_versions,
)


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

    def test_coherent_rollback_uses_recorded_artifact_and_switches_old_code_inside_same_lock(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            failure = self._failure(temp)
            previous = Path("/opt/vaultwarden-oci/releases/1.0.0")
            candidate = Path("/opt/vaultwarden-oci/releases/2.0.0")
            identity = temp / "offline.age"
            identity.write_text("AGE-SECRET-KEY-test\n", encoding="utf-8")
            events: list[str] = []
            lock_held = False

            @contextlib.contextmanager
            def prepared_restore(artifact, key, *, runner):
                self.assertEqual(artifact, failure.verified.artifact)
                self.assertEqual(key, identity)
                events.append("prepared")

                class Prepared:
                    def promote_locked(inner_self, *, runner):
                        self.assertTrue(lock_held)
                        events.append("promoted")

                yield Prepared()

            @contextlib.contextmanager
            def mutation_lock(_path):
                nonlocal lock_held
                lock_held = True
                events.append("lock-enter")
                try:
                    yield
                finally:
                    events.append("lock-exit")
                    lock_held = False

            def stop_locked(release, _runner):
                self.assertTrue(lock_held)
                self.assertEqual(release, candidate)
                events.append("stopped")
                return True

            def install_units(old_release, failed_release, _layout):
                self.assertTrue(lock_held)
                self.assertEqual(old_release, previous)
                self.assertEqual(failed_release, candidate)
                events.append("units")
                return {}

            def switch(_layout, target):
                self.assertTrue(lock_held)
                self.assertEqual(target, failure.plan.current_target)
                events.append("switch")

            with (
                mock.patch.object(update_appliance.storage, "verify"),
                mock.patch.object(update_appliance.recovery, "_sha256", return_value=failure.verified.sha256),
                mock.patch.object(Path, "is_dir", return_value=True),
                mock.patch.object(Path, "is_symlink", return_value=False),
                mock.patch.object(
                    update_appliance.update,
                    "_current",
                    return_value=(Path("releases/2.0.0"), "2.0.0", candidate),
                ),
                mock.patch.object(update_appliance.update_recovery, "prepare_restore", prepared_restore),
                mock.patch.object(update_appliance.install, "ensure_lock_path", return_value=temp / "lock"),
                mock.patch.object(update_appliance.cli, "mutation_lock", mutation_lock),
                mock.patch.object(update_appliance, "_stop_candidate_locked", side_effect=stop_locked),
                mock.patch.object(update_appliance.update_unit_migration, "install_units", side_effect=install_units),
                mock.patch.object(update_appliance.update, "_switch", side_effect=switch),
                mock.patch.object(update_appliance.update, "_daemon_reload"),
                mock.patch.object(update_appliance, "_prove_previous"),
            ):
                update_appliance.coherent_rollback(
                    failure,
                    identity,
                    runner=lambda argv, **_kwargs: command(argv),
                )

            self.assertLess(events.index("prepared"), events.index("lock-enter"))
            for item in ("stopped", "promoted", "units", "switch"):
                self.assertLess(events.index("lock-enter"), events.index(item))
                self.assertLess(events.index(item), events.index("lock-exit"))
            self.assertLess(events.index("promoted"), events.index("switch"))

    def test_storage_failure_blocks_recovery_preparation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            failure = self._failure(temp)
            prepare = mock.Mock()
            with (
                mock.patch.object(
                    update_appliance.storage,
                    "verify",
                    side_effect=update_appliance.storage.StorageError("missing dedicated storage"),
                ),
                mock.patch.object(update_appliance.update_recovery, "prepare_restore", prepare),
            ):
                with self.assertRaisesRegex(update_appliance.storage.StorageError, "missing dedicated storage"):
                    update_appliance.coherent_rollback(
                        failure,
                        temp / "identity",
                        runner=lambda argv, **_kwargs: command(argv),
                    )
            prepare.assert_not_called()


if __name__ == "__main__":
    unittest.main()
