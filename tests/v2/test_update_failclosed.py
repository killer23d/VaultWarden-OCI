from __future__ import annotations

import contextlib
import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, install, recovery, update, update_appliance, update_recovery, update_versions


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


def result(argv, *, ok: bool = True, stderr: str = "") -> cli.CommandResult:
    return cli.CommandResult(
        tuple(argv),
        "success" if ok else "nonzero",
        0 if ok else 1,
        "",
        stderr,
    )


def failure(temp: Path, *, root: Path = Path("/")) -> update_appliance.PersistentStateFailure:
    artifact = temp / "pre.vwrec"
    artifact.write_bytes(b"verified")
    verified = recovery.VerifiedRecovery(
        artifact,
        hashlib.sha256(artifact.read_bytes()).hexdigest(),
        artifact.stat().st_size,
        "2026-08-23T00:00:00Z",
    )
    plan = update.UpdatePlan(
        temp / "candidate-source",
        root,
        Path("releases/1.0.0"),
        "1.0.0",
        "2.0.0",
        frozen(),
    )
    return update_appliance.PersistentStateFailure(
        "post-start failure",
        plan=plan,
        verified=verified,
        services_stopped=True,
    )


class RecoveryCommandTests(unittest.TestCase):
    def test_recovery_command_uses_exact_candidate_vwctl_and_both_release_ids(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            item = failure(Path(directory))
            command = update_appliance.recovery_command(item)
        self.assertTrue(command.startswith("/opt/vaultwarden-oci/releases/2.0.0/vwctl update rollback "))
        self.assertIn("--previous-release 1.0.0", command)
        self.assertIn("--candidate-release 2.0.0", command)
        self.assertIn("--recovery-sha256 ", command)
        self.assertIn("--identity /path/to/offline-age-identity.txt", command)
        self.assertTrue(command.endswith("--yes"))

    def test_explicit_rollback_reconstructs_when_current_is_quarantined(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "host"
            previous = root / "opt/vaultwarden-oci/releases/1.0.0"
            candidate = root / "opt/vaultwarden-oci/releases/2.0.0"
            previous.mkdir(parents=True)
            candidate.mkdir(parents=True)
            artifact = Path(directory) / "pre.vwrec"
            artifact.write_bytes(b"verified")
            sha = hashlib.sha256(artifact.read_bytes()).hexdigest()
            with (
                mock.patch.object(update_appliance.recovery, "_sha256", return_value=sha),
                mock.patch.object(update_appliance.update, "_current", side_effect=update_versions.UpdateError("quarantined current")),
                mock.patch.object(update_appliance, "resolve_pinned_file", return_value=frozen()),
            ):
                rebuilt = update_appliance.reconstruct_failure(
                    artifact,
                    sha,
                    "1.0.0",
                    "2.0.0",
                    root=root,
                )
        self.assertEqual(rebuilt.plan.current_release, "1.0.0")
        self.assertEqual(rebuilt.plan.target_release, "2.0.0")
        self.assertFalse(rebuilt.services_stopped)


class SystemdStopTruthTests(unittest.TestCase):
    def test_systemd_stop_is_proven_inactive_after_lock_safe_container_stop(self) -> None:
        calls: list[tuple[str, ...]] = []

        def runner(argv, **_kwargs):
            calls.append(tuple(argv))
            if argv[:3] == ["systemctl", "is-active", "--quiet"]:
                return result(argv, ok=False, stderr="inactive")
            return result(argv)

        self.assertTrue(update_appliance._settle_systemd_stopped(install.Layout(Path("/")), runner))
        self.assertEqual(
            calls,
            [
                ("systemctl", "stop", "vaultwarden-oci.service"),
                ("systemctl", "is-active", "--quiet", "vaultwarden-oci.service"),
            ],
        )

    def test_active_systemd_state_is_not_reported_as_safely_stopped(self) -> None:
        self.assertFalse(
            update_appliance._settle_systemd_stopped(
                install.Layout(Path("/")),
                lambda argv, **_kwargs: result(argv),
            )
        )


class PromotionProofTests(unittest.TestCase):
    def test_failed_promotion_restores_original_target_and_reports_proven_rollback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first_target = root / "one"
            second_target = root / "two"
            first_target.write_text("old-one", encoding="utf-8")
            second_target.write_text("old-two", encoding="utf-8")
            first_candidate = root / "new-one"
            second_candidate = root / "new-two"
            first_candidate.write_text("new-one", encoding="utf-8")
            second_candidate.write_text("new-two", encoding="utf-8")
            real_replace = update_recovery.os.replace

            def replace(source, target):
                if Path(source) == second_candidate and Path(target) == second_target:
                    raise OSError("injected promotion failure")
                return real_replace(source, target)

            with mock.patch.object(update_recovery.os, "replace", side_effect=replace):
                with self.assertRaises(update_recovery.PromotionError) as caught:
                    update_recovery._promote_with_proven_rollback(
                        [(first_candidate, first_target), (second_candidate, second_target)]
                    )
            self.assertTrue(caught.exception.rollback_complete)
            self.assertEqual(first_target.read_text(encoding="utf-8"), "old-one")
            self.assertEqual(second_target.read_text(encoding="utf-8"), "old-two")


class QuarantineTests(unittest.TestCase):
    def test_unproven_data_promotion_failure_quarantines_current_under_lock(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            root = temp / "host"
            old = root / "opt/vaultwarden-oci/releases/1.0.0"
            candidate = root / "opt/vaultwarden-oci/releases/2.0.0"
            old.mkdir(parents=True)
            candidate.mkdir(parents=True)
            item = failure(temp, root=root)
            lock_held = False
            switched: list[Path] = []

            @contextlib.contextmanager
            def mutation_lock(_path):
                nonlocal lock_held
                lock_held = True
                try:
                    yield
                finally:
                    lock_held = False

            class Prepared:
                def promote_locked(self, *, runner):
                    self_test.assertTrue(lock_held)
                    raise update_recovery.PromotionError(
                        "injected incomplete restore rollback",
                        rollback_complete=False,
                    )

            self_test = self

            @contextlib.contextmanager
            def prepared_restore(*_args, **_kwargs):
                yield Prepared()

            def switch(_layout, target):
                self.assertTrue(lock_held)
                switched.append(target)

            with (
                mock.patch.object(update_appliance.storage, "verify"),
                mock.patch.object(update_appliance.recovery, "_sha256", return_value=item.verified.sha256),
                mock.patch.object(
                    update_appliance.update,
                    "_current",
                    return_value=(Path("releases/2.0.0"), "2.0.0", candidate),
                ),
                mock.patch.object(update_appliance.update_recovery, "prepare_restore", prepared_restore),
                mock.patch.object(update_appliance.install, "ensure_lock_path", return_value=temp / "lock"),
                mock.patch.object(update_appliance.cli, "mutation_lock", mutation_lock),
                mock.patch.object(update_appliance, "_stop_candidate_locked", return_value=True),
                mock.patch.object(update_appliance.update_unit_migration, "install_units", return_value={}),
                mock.patch.object(update_appliance.update, "_switch", side_effect=switch),
                mock.patch.object(update_appliance.update, "_daemon_reload"),
                mock.patch.object(update_appliance, "_settle_systemd_stopped", return_value=True),
                mock.patch.object(update_appliance, "_start_previous_service") as start,
            ):
                with self.assertRaisesRegex(update_versions.UpdateError, "quarantined"):
                    update_appliance.coherent_rollback(
                        item,
                        temp / "identity",
                        runner=lambda argv, **_kwargs: result(argv),
                    )
            self.assertEqual(switched, [Path("releases/1.0.0"), Path("recovery-required")])
            start.assert_not_called()


if __name__ == "__main__":
    unittest.main()
