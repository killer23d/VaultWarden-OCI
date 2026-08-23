from __future__ import annotations

import contextlib
import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, install, recovery, update, update_appliance, update_cli, update_versions


def digest(char: str) -> str:
    return "sha256:" + char * 64


def command(argv, *, ok: bool = True, stdout: str = "") -> cli.CommandResult:
    return cli.CommandResult(tuple(argv), "success" if ok else "nonzero", 0 if ok else 1, stdout, "" if ok else "failed")


def frozen(project: str = "2.0.0") -> update_versions.FrozenVersions:
    return update_versions.FrozenVersions(
        source="pinned",
        architecture="amd64",
        project_version=project,
        vaultwarden="1.40.0",
        caddy="2.12.0",
        caddy_dns_cloudflare="v0.3.0",
        vaultwarden_image=update_versions.ImagePin("vaultwarden", "vaultwarden/server", "1.40.0", digest("a")),
        caddy_builder_image=update_versions.ImagePin("caddy_builder", "caddy", "2.12.0-builder-alpine", digest("b")),
        caddy_runtime_image=update_versions.ImagePin("caddy_runtime", "caddy", "2.12.0-alpine", digest("c")),
        caddy_cloudflare_ip="d" * 40,
        caddy_combine_ip_ranges="v0.0.2",
        caddy_ratelimit="v0.2.0",
    )


class ProjectReleaseTests(unittest.TestCase):
    def test_stable_selection_ignores_draft_and_prerelease(self) -> None:
        payload = [
            {"tag_name": "v9.0.0-rc1", "draft": False, "prerelease": True, "tarball_url": "https://api.github.com/repos/killer23d/VaultWarden-OCI/tarball/v9.0.0-rc1"},
            {"tag_name": "v8.0.0", "draft": True, "prerelease": False, "tarball_url": "https://api.github.com/repos/killer23d/VaultWarden-OCI/tarball/v8.0.0"},
            {"tag_name": "v7.0.0", "draft": False, "prerelease": False, "published_at": "2026-08-20T00:00:00Z", "tarball_url": "https://api.github.com/repos/killer23d/VaultWarden-OCI/tarball/v7.0.0"},
        ]
        selected = update_appliance.select_stable_release(payload)
        self.assertEqual(selected.tag, "v7.0.0")

    def test_no_stable_release_is_truthful_failure(self) -> None:
        with self.assertRaisesRegex(update_versions.UpdateError, "no stable"):
            update_appliance.select_stable_release([{"draft": True}, {"prerelease": True}])

    def test_network_failure_is_not_reported_as_no_update(self) -> None:
        def failed(_url: str):
            raise update_versions.UpdateError("network unavailable")
        with self.assertRaisesRegex(update_versions.UpdateError, "network unavailable"):
            update_appliance.latest_project_release(getter=failed)


class LatestSnapshotTests(unittest.TestCase):
    def test_supported_latest_resolves_every_boundary_once_and_freezes(self) -> None:
        class Lookup:
            def __init__(self) -> None:
                self.releases: list[str] = []
                self.refs: list[str] = []
                self.images: list[tuple[str, str, str]] = []

            def latest_release(self, name: str) -> str:
                self.releases.append(name)
                return {
                    "vaultwarden": "v1.40.0",
                    "caddy": "v2.12.0",
                    "caddy_dns_cloudflare": "v0.3.0",
                }[name]

            def latest_ref(self, name: str) -> str:
                self.refs.append(name)
                return {
                    "caddy_cloudflare_ip": "e" * 40,
                    "caddy_combine_ip_ranges": "v0.0.2",
                    "caddy_ratelimit": "v0.2.0",
                }[name]

            def image_digest(self, repository: str, tag: str, architecture: str) -> str:
                self.images.append((repository, tag, architecture))
                return digest(str(len(self.images)))

        text = '''schema_version = 1
[vaultwarden_oci]
version = "1.0.0"
[components]
vaultwarden = "1.37.1"
caddy = "2.11.4"
caddy_dns_cloudflare = "v0.2.4"
caddy_cloudflare_ip = "f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5"
caddy_combine_ip_ranges = "v0.0.1"
caddy_ratelimit = "v0.1.0"
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "versions.toml").write_text(text, encoding="utf-8")
            lookup = Lookup()
            result = update_versions.resolve_latest_supported(root, machine="amd64", lookup=lookup)
            snapshot = update_versions.frozen_versions_toml(result)
        self.assertEqual(lookup.releases, ["vaultwarden", "caddy", "caddy_dns_cloudflare"])
        self.assertEqual(lookup.refs, ["caddy_cloudflare_ip", "caddy_combine_ip_ranges", "caddy_ratelimit"])
        self.assertEqual(len(lookup.images), 3)
        self.assertEqual(result.caddy_cloudflare_ip, "e" * 40)
        self.assertIn('caddy_ratelimit = "v0.2.0"', snapshot)
        self.assertNotIn('"latest"', snapshot)


class TransactionOrderTests(unittest.TestCase):
    def _prepared(self, temp: Path) -> update_appliance.PreparedPlan:
        source = temp / "source"
        source.mkdir()
        return update_appliance.PreparedPlan(
            update.UpdatePlan(source, temp / "host", Path("releases/1.0.0"), "1.0.0", "2.0.0", frozen()),
            None,
            False,
        )

    def _verified(self, temp: Path) -> recovery.VerifiedRecovery:
        artifact = temp / "pre-update.vwrec"
        artifact.write_bytes(b"age-encryption.org/v1 test artifact")
        return recovery.VerifiedRecovery(artifact, hashlib.sha256(artifact.read_bytes()).hexdigest(), artifact.stat().st_size, "2026-08-23T00:00:00Z")

    def test_expensive_prestage_and_verified_recovery_precede_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            prepared = self._prepared(temp)
            exact = temp / "exact"; exact.mkdir()
            events: list[str] = []

            @contextlib.contextmanager
            def exact_source(*_args, **_kwargs):
                yield exact

            def current(_layout):
                return Path("releases/1.0.0"), "1.0.0", temp / "old"

            def create_recovery(*_args, **_kwargs):
                events.append("recovery")
                return self._verified(temp)

            def stage(*_args, **_kwargs):
                events.append("stage")
                release = temp / "new"; release.mkdir(exist_ok=True)
                return release

            with (
                mock.patch.object(install, "_frozen_source", exact_source),
                mock.patch.object(update, "_validate_source"),
                mock.patch.object(update_appliance, "_preflight", side_effect=lambda *_a, **_k: events.append("prestage") or mock.Mock(offline_recovery_recipient="age1" + "a" * 58)),
                mock.patch.object(update, "_current", side_effect=current),
                mock.patch.object(install, "ensure_lock_path", return_value=temp / "lock"),
                mock.patch.object(cli, "mutation_lock", return_value=contextlib.nullcontext()),
                mock.patch.object(install, "stage_release", side_effect=stage),
                mock.patch.object(update, "_verify_coherent"),
                mock.patch.object(update_appliance.update_unit_migration, "install_units", return_value={}),
                mock.patch.object(update, "_switch"),
                mock.patch.object(update, "_daemon_reload"),
                mock.patch.object(update, "_gate_activated"),
                mock.patch.object(update_appliance, "record_frozen"),
            ):
                update_appliance.apply_prepared(
                    prepared,
                    runner=lambda argv, **_kwargs: command(argv),
                    activator=lambda *_args: events.append("activate"),
                    recovery_creator=create_recovery,
                )
        self.assertLess(events.index("prestage"), events.index("recovery"))
        self.assertLess(events.index("recovery"), events.index("stage"))
        self.assertLess(events.index("stage"), events.index("activate"))

    def test_failed_recovery_gates_staging(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            prepared = self._prepared(temp)
            exact = temp / "exact"; exact.mkdir()

            @contextlib.contextmanager
            def exact_source(*_args, **_kwargs):
                yield exact

            with (
                mock.patch.object(install, "_frozen_source", exact_source),
                mock.patch.object(update, "_validate_source"),
                mock.patch.object(update_appliance, "_preflight", return_value=mock.Mock(offline_recovery_recipient="age1" + "a" * 58)),
                mock.patch.object(update, "_current", return_value=(Path("releases/1.0.0"), "1.0.0", temp / "old")),
                mock.patch.object(install, "stage_release") as stage,
            ):
                with self.assertRaises(recovery.RecoveryError):
                    update_appliance.apply_prepared(
                        prepared,
                        runner=lambda argv, **_kwargs: command(argv),
                        activator=lambda *_args: None,
                        recovery_creator=lambda *_args, **_kwargs: (_ for _ in ()).throw(recovery.RecoveryError("backup failed")),
                    )
            stage.assert_not_called()

    def test_poststart_failure_never_switches_old_code_back(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            prepared = self._prepared(temp)
            exact = temp / "exact"; exact.mkdir()

            @contextlib.contextmanager
            def exact_source(*_args, **_kwargs):
                yield exact

            switches: list[Path] = []
            with (
                mock.patch.object(install, "_frozen_source", exact_source),
                mock.patch.object(update, "_validate_source"),
                mock.patch.object(update_appliance, "_preflight", return_value=mock.Mock(offline_recovery_recipient="age1" + "a" * 58)),
                mock.patch.object(update, "_current", return_value=(Path("releases/1.0.0"), "1.0.0", temp / "old")),
                mock.patch.object(install, "ensure_lock_path", return_value=temp / "lock"),
                mock.patch.object(cli, "mutation_lock", return_value=contextlib.nullcontext()),
                mock.patch.object(install, "stage_release", return_value=temp / "new"),
                mock.patch.object(update, "_verify_coherent"),
                mock.patch.object(update_appliance.update_unit_migration, "install_units", return_value={}),
                mock.patch.object(update, "_switch", side_effect=lambda _layout, target: switches.append(target)),
                mock.patch.object(update, "_daemon_reload"),
                mock.patch.object(update_appliance, "_stop_candidate_locked", return_value=True),
            ):
                with self.assertRaises(update_appliance.PersistentStateFailure):
                    update_appliance.apply_prepared(
                        prepared,
                        runner=lambda argv, **_kwargs: command(argv),
                        activator=lambda *_args: (_ for _ in ()).throw(update.RuntimeActivationError("started", state_change_possible=True)),
                        recovery_creator=lambda *_args, **_kwargs: self._verified(temp),
                    )
        self.assertEqual(switches, [Path("releases/2.0.0")])


class SchedulerAndHostTests(unittest.TestCase):
    def test_update_check_timer_can_never_apply(self) -> None:
        root = Path(__file__).resolve().parents[2]
        service = (root / "systemd-v2/vaultwarden-oci-update-check.service").read_text(encoding="utf-8")
        timer = (root / "systemd-v2/vaultwarden-oci-update-check.timer").read_text(encoding="utf-8")
        self.assertIn("update check --timer --json", service)
        self.assertNotIn("update apply", service)
        self.assertNotIn("update apply", timer)

    def test_host_upgrade_never_reboots_and_does_not_claim_os_rollback(self) -> None:
        calls: list[tuple[str, ...]] = []
        verified = recovery.VerifiedRecovery(Path("/tmp/recovery.vwrec"), "a" * 64, 123, "2026-08-23T00:00:00Z")

        def runner(argv, **_kwargs):
            calls.append(tuple(argv))
            return command(argv)

        with (
            mock.patch.object(update_appliance.os, "geteuid", return_value=0),
            mock.patch.object(update_appliance.storage, "verify"),
            mock.patch.object(update_appliance.runtime, "load_config", return_value=mock.Mock(offline_recovery_recipient="age1" + "a" * 58)),
            mock.patch.object(update_appliance.recovery, "create_recovery", return_value=verified),
            mock.patch.object(update_appliance, "_host_lock", return_value=Path("/tmp/test-lock")),
            mock.patch.object(update_appliance.cli, "mutation_lock", return_value=contextlib.nullcontext()),
            mock.patch.object(update_appliance.Path, "exists", return_value=False),
        ):
            result, reboot = update_appliance.host_upgrade_apply(runner=runner)
        self.assertEqual(result, verified)
        self.assertFalse(reboot)
        self.assertIn(("apt-get", "update"), calls)
        self.assertIn(("apt-get", "-y", "upgrade"), calls)
        self.assertFalse(any("reboot" in item for call in calls for item in call))

    def test_noninteractive_poststart_failure_never_silently_restores_data(self) -> None:
        plan = update.UpdatePlan(Path("/tmp/source"), Path("/"), Path("releases/1.0.0"), "1.0.0", "2.0.0", frozen())
        verified = recovery.VerifiedRecovery(Path("/tmp/pre.vwrec"), "a" * 64, 1, "2026-08-23T00:00:00Z")
        failure = update_appliance.PersistentStateFailure("failed", plan=plan, verified=verified, services_stopped=True)
        ui = update_cli.UI(color=False)
        with (
            mock.patch.object(update_cli.sys.stdin, "isatty", return_value=False),
            mock.patch.object(update_appliance, "coherent_rollback") as rollback,
            mock.patch("sys.stderr", io.StringIO()),
        ):
            code = update_cli._handle_persistent_failure(failure, identity=None, ui=ui)
        self.assertEqual(code, 1)
        rollback.assert_not_called()


if __name__ == "__main__":
    unittest.main()
