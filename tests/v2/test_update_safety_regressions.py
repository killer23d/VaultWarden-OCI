from __future__ import annotations

import contextlib
import hashlib
import os
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
    update_cli,
    update_recovery,
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


def command(argv, *, ok: bool = True, stdout: str = "", stderr: str = "") -> cli.CommandResult:
    return cli.CommandResult(
        tuple(argv),
        "success" if ok else "nonzero",
        0 if ok else 1,
        stdout,
        stderr if not ok else "",
    )


class ReleaseOrderingTests(unittest.TestCase):
    def test_latest_snapshot_to_same_stable_release_is_not_an_update(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            source.mkdir()
            base = update.UpdatePlan(
                source,
                Path("/"),
                Path("releases/2.0.0.latest.abcdef123456"),
                "2.0.0.latest.abcdef123456",
                "2.0.0",
                frozen("2.0.0"),
            )
            release = update_appliance.ProjectRelease(
                "v2.0.0",
                "https://api.github.com/repos/killer23d/VaultWarden-OCI/tarball/v2.0.0",
                "2026-08-23T00:00:00Z",
            )
            with (
                mock.patch.object(update_appliance.update, "plan_update", return_value=base),
                mock.patch.object(update_appliance.update, "resolve_pinned", return_value=frozen("2.0.0")),
            ):
                prepared = update_appliance.prepare_plan(source, project_release=release)
        self.assertFalse(prepared.available)
        self.assertIn("implicit component downgrade", prepared.availability_reason)

    def test_older_stable_release_is_never_recommended(self) -> None:
        available, reason = update_appliance._recommended_availability("3.0.0", "2.9.9")
        self.assertFalse(available)
        self.assertIn("downgrade refused", reason)

    def test_semver_prerelease_ordering_is_explicit(self) -> None:
        self.assertGreater(update_appliance.compare_project_versions("2.0.0", "2.0.0-rc.1"), 0)
        self.assertGreater(update_appliance.compare_project_versions("2.0.0-rc.2", "2.0.0-rc.1"), 0)

    def test_release_discovery_pages_past_one_hundred_prereleases(self) -> None:
        prereleases = [
            {
                "tag_name": f"v9.0.0-rc.{index}",
                "draft": False,
                "prerelease": True,
                "tarball_url": f"https://api.github.com/repos/killer23d/VaultWarden-OCI/tarball/v9.0.0-rc.{index}",
            }
            for index in range(100)
        ]
        stable = [
            {
                "tag_name": "v8.0.0",
                "draft": False,
                "prerelease": False,
                "published_at": "2026-08-01T00:00:00Z",
                "tarball_url": "https://api.github.com/repos/killer23d/VaultWarden-OCI/tarball/v8.0.0",
            }
        ]
        calls: list[str] = []

        def getter(url: str):
            calls.append(url)
            return prereleases if "page=1" in url else stable

        selected = update_appliance.latest_project_release(getter=getter)
        self.assertEqual(selected.tag, "v8.0.0")
        self.assertEqual(len(calls), 2)

    def test_source_override_requires_explicit_development_gate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            with mock.patch.dict(os.environ, {}, clear=True):
                with self.assertRaisesRegex(update_versions.UpdateError, "developer/testing-only"):
                    with update_appliance.candidate_source(source):
                        self.fail("development-gated source override unexpectedly opened")


class CandidateOwnershipTests(unittest.TestCase):
    def test_prestage_executes_candidate_vwctl_not_installed_runtime_renderer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "candidate"
            source.mkdir()
            calls: list[tuple[tuple[str, ...], Path | None]] = []

            def runner(argv, **kwargs):
                calls.append((tuple(argv), kwargs.get("cwd")))
                return command(argv, stdout='{"ok":true}')

            update_appliance._prepare_candidate_release(source, root / "render", runner=runner)
        self.assertEqual(len(calls), 1)
        argv, cwd = calls[0]
        self.assertEqual(argv[0], str(source / "vwctl"))
        self.assertEqual(argv[1:3], ("__update-candidate", "prepare"))
        self.assertEqual(cwd, source)

    def test_activation_executes_staged_candidate_vwctl(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release = root / "release"
            release.mkdir()
            calls = []

            def runner(argv, **kwargs):
                calls.append((tuple(argv), kwargs.get("cwd")))
                return command(argv, stdout='{"ok":true}')

            update_appliance._activate_candidate_release(release, root / "render", runner)
        argv, cwd = calls[0]
        self.assertEqual(argv[0], str(release / "vwctl"))
        self.assertEqual(argv[1:3], ("__update-candidate", "activate"))
        self.assertEqual(cwd, release)


class LockedFailureStopTests(unittest.TestCase):
    def _prepared(self, temp: Path) -> update_appliance.PreparedPlan:
        source = temp / "source"
        source.mkdir()
        return update_appliance.PreparedPlan(
            update.UpdatePlan(
                source,
                temp / "host",
                Path("releases/1.0.0"),
                "1.0.0",
                "2.0.0",
                frozen(),
            ),
            None,
            False,
        )

    def _verified(self, temp: Path) -> recovery.VerifiedRecovery:
        artifact = temp / "pre.vwrec"
        artifact.write_bytes(b"age-encryption.org/v1 regression")
        return recovery.VerifiedRecovery(
            artifact,
            hashlib.sha256(artifact.read_bytes()).hexdigest(),
            artifact.stat().st_size,
            "2026-08-23T00:00:00Z",
        )

    def _run_late_failure(self, *, crowdsec_failure: bool) -> tuple[bool, list[str]]:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            prepared = self._prepared(temp)
            exact = temp / "exact"
            exact.mkdir()
            old = temp / "old"
            old.mkdir()
            new = temp / "new"
            new.mkdir()
            events: list[str] = []
            lock_held = False

            @contextlib.contextmanager
            def exact_source(*_args, **_kwargs):
                yield exact

            @contextlib.contextmanager
            def held_lock(*_args, **_kwargs):
                nonlocal lock_held
                self.assertFalse(lock_held)
                lock_held = True
                events.append("lock-enter")
                try:
                    yield
                finally:
                    events.append("lock-exit")
                    lock_held = False

            def stop_locked(_release, _runner):
                self.assertTrue(lock_held)
                events.append("candidate-stop")
                return True

            def runner(argv, **_kwargs):
                args = tuple(argv)
                if crowdsec_failure and args[-2:] == ("crowdsec", "status"):
                    return command(args, ok=False, stderr="crowdsec failed")
                return command(args)

            with (
                mock.patch.object(install, "_frozen_source", exact_source),
                mock.patch.object(update, "_validate_source"),
                mock.patch.object(
                    update_appliance,
                    "_preflight",
                    return_value=mock.Mock(offline_recovery_recipient="age1" + "a" * 58),
                ),
                mock.patch.object(update, "_current", return_value=(Path("releases/1.0.0"), "1.0.0", old)),
                mock.patch.object(install, "ensure_lock_path", return_value=temp / "lock"),
                mock.patch.object(cli, "mutation_lock", held_lock),
                mock.patch.object(install, "stage_release", return_value=new),
                mock.patch.object(update, "_verify_coherent"),
                mock.patch.object(update_appliance.update_unit_migration, "install_units", return_value={}),
                mock.patch.object(update, "_switch"),
                mock.patch.object(update, "_daemon_reload"),
                mock.patch.object(update_appliance, "_stop_candidate_locked", side_effect=stop_locked),
                mock.patch.object(update_appliance, "_start_update_timer"),
            ):
                if crowdsec_failure:
                    gate = mock.patch.object(update, "_gate_activated")
                else:
                    gate = mock.patch.object(update, "_gate_activated", side_effect=update_versions.UpdateError("doctor failed"))
                with gate:
                    with self.assertRaises(update_appliance.PersistentStateFailure) as caught:
                        update_appliance.apply_prepared(
                            prepared,
                            runner=runner,
                            activator=lambda *_args: events.append("activated"),
                            recovery_creator=lambda *_args, **_kwargs: self._verified(temp),
                        )
            return caught.exception.services_stopped, events

    def test_final_status_doctor_failure_stops_candidate_while_parent_lock_is_held(self) -> None:
        stopped, events = self._run_late_failure(crowdsec_failure=False)
        self.assertTrue(stopped)
        self.assertLess(events.index("candidate-stop"), events.index("lock-exit"))

    def test_final_crowdsec_failure_stops_candidate_while_parent_lock_is_held(self) -> None:
        stopped, events = self._run_late_failure(crowdsec_failure=True)
        self.assertTrue(stopped)
        self.assertLess(events.index("candidate-stop"), events.index("lock-exit"))


class CoherentRollbackLockTests(unittest.TestCase):
    def test_data_promotion_and_previous_code_switch_share_one_lock(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            host = temp / "host"
            previous = host / "opt/vaultwarden-oci/releases/1.0.0"
            candidate = host / "opt/vaultwarden-oci/releases/2.0.0"
            previous.mkdir(parents=True)
            candidate.mkdir(parents=True)
            artifact = temp / "pre.vwrec"
            artifact.write_bytes(b"verified")
            verified = recovery.VerifiedRecovery(
                artifact,
                hashlib.sha256(artifact.read_bytes()).hexdigest(),
                artifact.stat().st_size,
                "2026-08-23T00:00:00Z",
            )
            plan = update.UpdatePlan(
                candidate,
                host,
                Path("releases/1.0.0"),
                "1.0.0",
                "2.0.0",
                frozen(),
            )
            failure = update_appliance.PersistentStateFailure(
                "failed after start",
                plan=plan,
                verified=verified,
                services_stopped=True,
            )
            lock_held = False
            events: list[str] = []

            @contextlib.contextmanager
            def held_lock(*_args, **_kwargs):
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

            def stop_locked(_release, _runner):
                self.assertTrue(lock_held)
                events.append("stop-candidate")
                return True

            def install_units(*_args):
                self.assertTrue(lock_held)
                events.append("install-old-units")
                return {}

            def switch(*_args):
                self.assertTrue(lock_held)
                events.append("switch-old-code")

            with (
                mock.patch.object(update_appliance.storage, "verify"),
                mock.patch.object(update_appliance.recovery, "_sha256", return_value=verified.sha256),
                mock.patch.object(
                    update_appliance.update,
                    "_current",
                    return_value=(Path("releases/2.0.0"), "2.0.0", candidate),
                ),
                mock.patch.object(update_appliance.update_recovery, "prepare_restore", prepared_restore),
                mock.patch.object(update_appliance.install, "ensure_lock_path", return_value=temp / "lock"),
                mock.patch.object(update_appliance.cli, "mutation_lock", held_lock),
                mock.patch.object(update_appliance, "_stop_candidate_locked", side_effect=stop_locked),
                mock.patch.object(update_appliance.update_unit_migration, "install_units", side_effect=install_units),
                mock.patch.object(update_appliance.update, "_switch", side_effect=switch),
                mock.patch.object(update_appliance.update, "_daemon_reload"),
                mock.patch.object(update_appliance, "_prove_previous"),
            ):
                update_appliance.coherent_rollback(
                    failure,
                    temp / "identity",
                    runner=lambda argv, **_kwargs: command(argv),
                )

        self.assertLess(events.index("prepare-data"), events.index("lock-enter"))
        for name in ("stop-candidate", "promote-data", "install-old-units", "switch-old-code"):
            self.assertLess(events.index("lock-enter"), events.index(name))
            self.assertLess(events.index(name), events.index("lock-exit"))
        self.assertLess(events.index("promote-data"), events.index("switch-old-code"))


class TimerAndHostSerializationTests(unittest.TestCase):
    def test_upgrade_explicitly_starts_and_proves_new_timer_active(self) -> None:
        calls: list[tuple[str, ...]] = []

        def runner(argv, **_kwargs):
            calls.append(tuple(argv))
            return command(argv)

        update_appliance._start_update_timer(install.Layout(Path("/")), runner)
        self.assertEqual(
            calls,
            [
                ("systemctl", "start", "vaultwarden-oci-update-check.timer"),
                ("systemctl", "is-active", "--quiet", "vaultwarden-oci-update-check.timer"),
            ],
        )

    def test_host_upgrade_apply_serializes_apt_mutation_after_recovery(self) -> None:
        verified = recovery.VerifiedRecovery(Path("/tmp/pre.vwrec"), "a" * 64, 10, "2026-08-23T00:00:00Z")
        lock_held = False
        events: list[str] = []

        @contextlib.contextmanager
        def held_lock(*_args, **_kwargs):
            nonlocal lock_held
            lock_held = True
            events.append("lock-enter")
            try:
                yield
            finally:
                events.append("lock-exit")
                lock_held = False

        def create_recovery(*_args, **_kwargs):
            self.assertFalse(lock_held)
            events.append("recovery")
            return verified

        def runner(argv, **_kwargs):
            if argv[0] == "apt-get":
                self.assertTrue(lock_held)
                events.append(" ".join(argv))
            return command(argv)

        with (
            mock.patch.object(update_appliance.os, "geteuid", return_value=0),
            mock.patch.object(update_appliance.storage, "verify"),
            mock.patch.object(
                update_appliance.runtime,
                "load_config",
                return_value=mock.Mock(offline_recovery_recipient="age1" + "a" * 58),
            ),
            mock.patch.object(update_appliance.recovery, "create_recovery", side_effect=create_recovery),
            mock.patch.object(update_appliance, "_host_lock", return_value=Path("/tmp/test-lock")),
            mock.patch.object(update_appliance.cli, "mutation_lock", held_lock),
            mock.patch.object(update_appliance.Path, "exists", return_value=False),
        ):
            result, reboot = update_appliance.host_upgrade_apply(runner=runner)
        self.assertEqual(result, verified)
        self.assertFalse(reboot)
        self.assertLess(events.index("recovery"), events.index("lock-enter"))
        self.assertLess(events.index("apt-get update"), events.index("lock-exit"))
        self.assertLess(events.index("apt-get -y upgrade"), events.index("lock-exit"))

    def test_host_upgrade_check_refreshes_indexes_under_same_serialization_lock(self) -> None:
        lock_held = False
        calls: list[tuple[str, ...]] = []

        @contextlib.contextmanager
        def held_lock(*_args, **_kwargs):
            nonlocal lock_held
            lock_held = True
            try:
                yield
            finally:
                lock_held = False

        def runner(argv, **_kwargs):
            self.assertTrue(lock_held)
            calls.append(tuple(argv))
            stdout = "Inst package [1] (2 Ubuntu)\n" if argv[1:3] == ["-s", "upgrade"] else ""
            return command(argv, stdout=stdout)

        with (
            mock.patch.object(update_appliance.os, "geteuid", return_value=0),
            mock.patch.object(update_appliance, "_host_lock", return_value=Path("/tmp/test-lock")),
            mock.patch.object(update_appliance.cli, "mutation_lock", held_lock),
            mock.patch.object(update_appliance.Path, "exists", return_value=False),
        ):
            count, reboot, _ = update_appliance.host_upgrade_check(runner=runner)
        self.assertEqual(count, 1)
        self.assertFalse(reboot)
        self.assertEqual(calls[0], ("apt-get", "update"))
        self.assertEqual(calls[1], ("apt-get", "-s", "upgrade"))

    def test_json_host_apply_without_yes_is_json_only(self) -> None:
        stderr = mock.MagicMock()
        with (
            mock.patch.object(update_cli, "_require_storage", return_value=True),
            mock.patch("sys.stderr", stderr),
        ):
            code = update_cli._host_upgrade_command(["apply", "--json"])
        self.assertEqual(code, 2)
        written = "".join(str(call.args[0]) for call in stderr.write.call_args_list if call.args)
        self.assertIn('"error"', written)
        self.assertNotIn("FAIL:", written)


if __name__ == "__main__":
    unittest.main()
