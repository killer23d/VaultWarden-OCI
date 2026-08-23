from __future__ import annotations

import contextlib
import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, recovery, update, update_appliance, update_versions


def digest(char: str) -> str:
    return "sha256:" + char * 64


def frozen() -> update_versions.FrozenVersions:
    return update_versions.FrozenVersions(
        "pinned",
        "amd64",
        "2.0.0",
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


def command(argv, **_kwargs) -> cli.CommandResult:
    return cli.CommandResult(tuple(argv), "success", 0, "", "")


class RollbackCrashSafetyTests(unittest.TestCase):
    def test_old_selection_retry_uses_guard_aware_candidate_until_data_is_restored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            root = temp / "host"
            install_root = root / "opt/vaultwarden-oci"
            previous = install_root / "releases/1.0.0"
            candidate = install_root / "releases/2.0.0"
            previous.mkdir(parents=True)
            candidate.mkdir(parents=True)
            (install_root / "current").symlink_to("releases/1.0.0")

            artifact = temp / "pre.vwrec"
            artifact.write_bytes(b"verified")
            verified = recovery.VerifiedRecovery(
                artifact,
                hashlib.sha256(artifact.read_bytes()).hexdigest(),
                artifact.stat().st_size,
                "2026-08-23T00:00:00Z",
            )
            failure = update_appliance.PersistentStateFailure(
                "retry coherent rollback",
                plan=update.UpdatePlan(
                    candidate,
                    root,
                    Path("releases/1.0.0"),
                    "1.0.0",
                    "2.0.0",
                    frozen(),
                ),
                verified=verified,
                services_stopped=True,
            )

            events: list[str] = []
            lock_held = False

            @contextlib.contextmanager
            def held_lock(_path):
                nonlocal lock_held
                lock_held = True
                events.append("lock-enter")
                try:
                    yield
                finally:
                    events.append("lock-exit")
                    lock_held = False

            class Prepared:
                def promote_locked(self, *, runner):
                    self_test.assertTrue(lock_held)
                    events.append("promote-data")

            self_test = self

            @contextlib.contextmanager
            def prepared_restore(*_args, **_kwargs):
                events.append("prepare-data")
                yield Prepared()

            def engage(**_kwargs):
                self.assertTrue(lock_held)
                events.append("guard")

            def switch(_layout, target):
                self.assertTrue(lock_held)
                if target == Path("releases/2.0.0"):
                    events.append("switch-candidate")
                elif target == Path("releases/1.0.0"):
                    events.append("switch-old")
                else:
                    self.fail(f"unexpected switch target {target}")

            def stop_locked(release, _runner):
                self.assertTrue(lock_held)
                self.assertEqual(release, candidate)
                events.append("stop")
                return True

            def converge(*_args, **_kwargs):
                self.assertTrue(lock_held)
                events.append("units-old")
                return {}

            with (
                mock.patch.object(update_appliance.storage, "verify"),
                mock.patch.object(update_appliance.recovery, "_sha256", return_value=verified.sha256),
                mock.patch.object(update_appliance.update_recovery, "prepare_restore", prepared_restore),
                mock.patch.object(update_appliance.install, "ensure_lock_path", return_value=temp / "lock"),
                mock.patch.object(update_appliance.cli, "mutation_lock", held_lock),
                mock.patch.object(update_appliance.update_guard, "engage", side_effect=engage),
                mock.patch.object(update_appliance.update_guard, "clear", side_effect=lambda **_kwargs: events.append("guard-clear")),
                mock.patch.object(update_appliance, "_stop_candidate_locked", side_effect=stop_locked),
                mock.patch.object(update_appliance.update_unit_migration, "converge_units", side_effect=converge),
                mock.patch.object(update_appliance.update, "_switch", side_effect=switch),
                mock.patch.object(update_appliance.update, "_daemon_reload"),
                mock.patch.object(update_appliance, "_start_previous_service", side_effect=lambda *_args: events.append("start-old")),
                mock.patch.object(update_appliance, "_prove_previous"),
            ):
                update_appliance.coherent_rollback(
                    failure,
                    temp / "identity",
                    runner=command,
                )

            self.assertLess(events.index("guard"), events.index("switch-candidate"))
            self.assertLess(events.index("switch-candidate"), events.index("promote-data"))
            self.assertLess(events.index("promote-data"), events.index("units-old"))
            self.assertLess(events.index("units-old"), events.index("switch-old"))
            self.assertLess(events.index("switch-old"), events.index("lock-exit"))
            self.assertLess(events.index("lock-exit"), events.index("guard-clear"))
            self.assertLess(events.index("guard-clear"), events.index("start-old"))


if __name__ == "__main__":
    unittest.main()
