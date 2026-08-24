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
    update_candidate,
    update_recovery,
    update_unit_migration,
    update_versions,
)


def digest(char: str) -> str:
    return "sha256:" + char * 64


def frozen(project: str = "2.0.0") -> update_versions.FrozenVersions:
    return update_versions.FrozenVersions(
        "pinned",
        "amd64",
        project,
        "1.40.0",
        "2.12.0",
        "v0.3.0",
        update_versions.ImagePin("vaultwarden", "vaultwarden/server", "1.40.0", digest("a")),
        update_versions.ImagePin("caddy_builder", "caddy", "2.12.0-builder-alpine", digest("b")),
        update_versions.ImagePin("caddy_runtime", "caddy", "2.12.0-alpine", digest("c")),
        caddy_cloudflare_ip="d" * 40,
        caddy_combine_ip_ranges="v0.0.2",
        caddy_ratelimit="v0.2.0",
    )


def result(argv, returncode: int, *, stdout: str = "", stderr: str = "") -> cli.CommandResult:
    return cli.CommandResult(
        tuple(argv),
        "success" if returncode == 0 else "nonzero",
        returncode,
        stdout,
        stderr,
    )


class CandidateExitClassificationTests(unittest.TestCase):
    def test_only_explicit_prestart_exit_is_safe_for_old_code_rollback(self) -> None:
        release = Path("/candidate")
        render = Path("/render")

        with self.assertRaises(update.RuntimeActivationError) as caught:
            update_appliance._activate_candidate_release(
                release,
                render,
                lambda argv, **_kwargs: result(argv, update_candidate.PRESTART_FAILURE),
            )
        self.assertFalse(caught.exception.state_change_possible)

        for abnormal_exit in (update_candidate.POSTSTART_FAILURE, 1, 130, 137, -9):
            with self.subTest(returncode=abnormal_exit):
                with self.assertRaises(update.RuntimeActivationError) as caught:
                    update_appliance._activate_candidate_release(
                        release,
                        render,
                        lambda argv, **_kwargs: result(argv, abnormal_exit),
                    )
                self.assertTrue(caught.exception.state_change_possible)


class InterruptedApplyTests(unittest.TestCase):
    def test_keyboard_interrupt_during_candidate_activation_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            source = temp / "source"
            exact = temp / "exact"
            old = temp / "old"
            new = temp / "new"
            for path in (source, exact, old, new):
                path.mkdir()
            root = temp / "host"
            prepared = update_appliance.PreparedPlan(
                update.UpdatePlan(
                    source,
                    root,
                    Path("releases/1.0.0"),
                    "1.0.0",
                    "2.0.0",
                    frozen(),
                ),
                None,
                False,
            )
            artifact = temp / "pre.vwrec"
            artifact.write_bytes(b"age-encryption.org/v1 interrupt-regression")
            verified = recovery.VerifiedRecovery(
                artifact,
                hashlib.sha256(artifact.read_bytes()).hexdigest(),
                artifact.stat().st_size,
                "2026-08-24T00:00:00Z",
            )
            switches: list[Path] = []

            @contextlib.contextmanager
            def exact_source(*_args, **_kwargs):
                yield exact

            def runner(argv, **_kwargs):
                return result(argv, 0)

            def interrupting_activator(*_args):
                raise KeyboardInterrupt()

            with (
                mock.patch.object(install, "_frozen_source", exact_source),
                mock.patch.object(update, "_validate_source"),
                mock.patch.object(
                    update_appliance,
                    "_preflight",
                    return_value=mock.Mock(offline_recovery_recipient="age1" + "a" * 58),
                ),
                mock.patch.object(
                    update,
                    "_current",
                    return_value=(Path("releases/1.0.0"), "1.0.0", old),
                ),
                mock.patch.object(update, "_gate_current"),
                mock.patch.object(install, "ensure_lock_path", return_value=temp / "lock"),
                mock.patch.object(install, "stage_release", return_value=new),
                mock.patch.object(update, "_verify_coherent"),
                mock.patch.object(update_appliance.update_unit_migration, "install_units", return_value={}),
                mock.patch.object(
                    update,
                    "_switch",
                    side_effect=lambda _layout, target: switches.append(target),
                ),
                mock.patch.object(update, "_daemon_reload"),
                mock.patch.object(update_appliance, "_stop_candidate_locked", return_value=True),
                mock.patch.object(update_appliance.update_guard, "engage") as guard,
            ):
                with self.assertRaises(update_appliance.PersistentStateFailure) as caught:
                    update_appliance.apply_prepared(
                        prepared,
                        runner=runner,
                        activator=interrupting_activator,
                        recovery_creator=lambda *_args, **_kwargs: verified,
                    )

            self.assertTrue(caught.exception.services_stopped)
            guard.assert_called_once()
            self.assertEqual(switches, [Path("releases/2.0.0")])


class InterruptedPromotionTests(unittest.TestCase):
    def test_keyboard_interrupt_mid_promotion_restores_original_live_targets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate_one = root / "candidate-one"
            candidate_two = root / "candidate-two"
            target_one = root / "target-one"
            target_two = root / "target-two"
            candidate_one.write_text("new-one", encoding="utf-8")
            candidate_two.write_text("new-two", encoding="utf-8")
            target_one.write_text("old-one", encoding="utf-8")
            target_two.write_text("old-two", encoding="utf-8")

            real_replace = update_recovery.os.replace
            calls = 0

            def interrupt_fourth_replace(source, destination):
                nonlocal calls
                calls += 1
                if calls == 4:
                    raise KeyboardInterrupt()
                return real_replace(source, destination)

            with mock.patch.object(
                update_recovery.os,
                "replace",
                side_effect=interrupt_fourth_replace,
            ):
                with self.assertRaises(update_recovery.PromotionError) as caught:
                    update_recovery._promote_with_proven_rollback(
                        ((candidate_one, target_one), (candidate_two, target_two))
                    )

            self.assertTrue(caught.exception.rollback_complete)
            self.assertEqual(target_one.read_text(encoding="utf-8"), "old-one")
            self.assertEqual(target_two.read_text(encoding="utf-8"), "old-two")


class InterruptedUnitMigrationTests(unittest.TestCase):
    UNITS = ("one.service", "two.service")

    @staticmethod
    def _unit_tree(root: Path, values: tuple[bytes, bytes]) -> None:
        systemd = root / install.SYSTEMD_SOURCE_DIR
        systemd.mkdir(parents=True)
        for unit, value in zip(InterruptedUnitMigrationTests.UNITS, values):
            (systemd / unit).write_bytes(value)

    @staticmethod
    def _installed(layout: install.Layout, values: tuple[bytes, bytes]) -> tuple[Path, Path]:
        paths = tuple(layout.path(install.SYSTEMD_DIR / unit) for unit in InterruptedUnitMigrationTests.UNITS)
        for path, value in zip(paths, values):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(value)
        return paths  # type: ignore[return-value]

    def _interrupt_second_atomic_write(self):
        real_write = update_unit_migration.update._atomic_write
        calls = 0

        def write(path, content, mode):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise KeyboardInterrupt()
            return real_write(path, content, mode)

        return write

    def test_install_units_interrupt_restores_exact_preupdate_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            layout = install.Layout(temp / "host")
            previous = temp / "previous"
            candidate = temp / "candidate"
            old_values = (b"old-one\n", b"old-two\n")
            new_values = (b"new-one\n", b"new-two\n")
            self._unit_tree(previous, old_values)
            self._unit_tree(candidate, new_values)
            installed = self._installed(layout, old_values)

            with (
                mock.patch.object(install, "SYSTEMD_UNITS", self.UNITS),
                mock.patch.object(
                    update_unit_migration.update,
                    "_atomic_write",
                    side_effect=self._interrupt_second_atomic_write(),
                ),
            ):
                with self.assertRaises(KeyboardInterrupt):
                    update_unit_migration.install_units(candidate, previous, layout)

            self.assertEqual(tuple(path.read_bytes() for path in installed), old_values)

    def test_converge_units_interrupt_restores_exact_candidate_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            layout = install.Layout(temp / "host")
            previous = temp / "previous"
            candidate = temp / "candidate"
            old_values = (b"old-one\n", b"old-two\n")
            candidate_values = (b"candidate-one\n", b"candidate-two\n")
            self._unit_tree(previous, old_values)
            self._unit_tree(candidate, candidate_values)
            installed = self._installed(layout, candidate_values)

            with (
                mock.patch.object(install, "SYSTEMD_UNITS", self.UNITS),
                mock.patch.object(
                    update_unit_migration.update,
                    "_atomic_write",
                    side_effect=self._interrupt_second_atomic_write(),
                ),
            ):
                with self.assertRaises(KeyboardInterrupt):
                    update_unit_migration.converge_units(
                        previous,
                        (candidate, previous),
                        layout,
                    )

            self.assertEqual(tuple(path.read_bytes() for path in installed), candidate_values)


if __name__ == "__main__":
    unittest.main()
