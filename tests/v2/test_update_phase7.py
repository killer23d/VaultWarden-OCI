from __future__ import annotations

import io
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, install, update, update_cli, update_versions


PHASE6_VERSION = "0.1.0-dev"
PHASE7_VERSION = "0.1.0-dev.7"


def digest(char: str) -> str:
    return "sha256:" + char * 64


def versions_text(version: str, *, amd64: str = "a", arm64: str = "b") -> str:
    return f'''schema_version = 1

[vaultwarden_oci]
version = "{version}"

[components]
vaultwarden = "1.37.1"
caddy = "2.11.4"
caddy_dns_cloudflare = "v0.2.4"
caddy_cloudflare_ip = "f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5"
caddy_combine_ip_ranges = "v0.0.1"
caddy_ratelimit = "v0.1.0"

[image_digests.vaultwarden]
amd64 = "{digest(amd64)}"
arm64 = "{digest(arm64)}"

[image_digests.caddy_builder]
amd64 = "{digest('c')}"
arm64 = "{digest('d')}"

[image_digests.caddy_runtime]
amd64 = "{digest('e')}"
arm64 = "{digest('f')}"
'''


def phase6_versions_text(version: str = PHASE6_VERSION) -> str:
    return f'''schema_version = 1
[vaultwarden_oci]
version = "{version}"
[components]
vaultwarden = "1.37.1"
caddy = "2.11.4"
caddy_dns_cloudflare = "v0.2.4"
caddy_cloudflare_ip = "f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5"
caddy_combine_ip_ranges = "v0.0.1"
caddy_ratelimit = "v0.1.0"
'''


def command(argv: list[str] | tuple[str, ...], *, ok: bool = True, stdout: str = "") -> cli.CommandResult:
    return cli.CommandResult(
        tuple(argv),
        "success" if ok else "nonzero",
        0 if ok else 1,
        stdout,
        "" if ok else "simulated failure",
    )


class VersionResolutionTests(unittest.TestCase):
    def test_pinned_architecture_mapping_and_exact_image_refs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "versions.toml").write_text(versions_text(PHASE7_VERSION), encoding="utf-8")
            amd64 = update_versions.resolve_pinned(root, machine="x86_64")
            arm64 = update_versions.resolve_pinned(root, machine="aarch64")
        self.assertEqual(amd64.architecture, "amd64")
        self.assertEqual(arm64.architecture, "arm64")
        self.assertEqual(amd64.vaultwarden_image.digest, digest("a"))
        self.assertEqual(arm64.vaultwarden_image.digest, digest("b"))
        self.assertEqual(
            amd64.vaultwarden_image.reference,
            f"vaultwarden/server:1.37.1@{digest('a')}",
        )
        self.assertEqual(amd64.caddy_builder_image.tag, "2.11.4-builder-alpine")
        self.assertEqual(amd64.caddy_runtime_image.tag, "2.11.4-alpine")

    def test_latest_resolves_once_and_freezes_exact_values(self) -> None:
        class FakeLookup:
            def __init__(self) -> None:
                self.release_calls: list[str] = []
                self.image_calls: list[tuple[str, str, str]] = []

            def latest_release(self, component: str) -> str:
                self.release_calls.append(component)
                return {
                    "vaultwarden": "v1.40.0",
                    "caddy": "v2.12.0",
                    "caddy_dns_cloudflare": "v0.3.0",
                }[component]

            def image_digest(self, repository: str, tag: str, architecture: str) -> str:
                self.image_calls.append((repository, tag, architecture))
                return digest(str(len(self.image_calls)))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "versions.toml").write_text(versions_text(PHASE7_VERSION), encoding="utf-8")
            lookup = FakeLookup()
            with mock.patch.dict(os.environ, {update_versions.DEVELOPMENT_ENV: "1"}, clear=False):
                frozen = update_versions.resolve_latest(root, machine="x86_64", lookup=lookup)
            snapshot = update.frozen_versions_toml(frozen)
        self.assertEqual(
            lookup.release_calls,
            ["vaultwarden", "caddy", "caddy_dns_cloudflare"],
        )
        self.assertEqual(len(lookup.image_calls), 3)
        self.assertEqual(frozen.vaultwarden, "1.40.0")
        self.assertEqual(frozen.caddy, "2.12.0")
        self.assertEqual(frozen.caddy_dns_cloudflare, "v0.3.0")
        self.assertIn('vaultwarden = "1.40.0"', snapshot)
        self.assertIn(f'amd64 = "{digest("1")}"', snapshot)
        self.assertNotIn('vaultwarden = "latest"', snapshot)
        self.assertNotIn('caddy = "latest"', snapshot)

    def test_latest_snapshot_identity_includes_fixed_edge_addon_pins(self) -> None:
        class FakeLookup:
            def latest_release(self, component: str) -> str:
                return {
                    "vaultwarden": "v1.40.0",
                    "caddy": "v2.12.0",
                    "caddy_dns_cloudflare": "v0.3.0",
                }[component]

            def image_digest(self, repository: str, tag: str, architecture: str) -> str:
                return digest({
                    "vaultwarden/server": "1",
                    "caddy": "2" if "builder" in tag else "3",
                }[repository])

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = versions_text(PHASE7_VERSION)
            (root / "versions.toml").write_text(first, encoding="utf-8")
            with mock.patch.dict(os.environ, {update_versions.DEVELOPMENT_ENV: "1"}, clear=False):
                one = update_versions.resolve_latest(root, machine="amd64", lookup=FakeLookup())
            second = first.replace('caddy_ratelimit = "v0.1.0"', 'caddy_ratelimit = "v0.1.1"')
            (root / "versions.toml").write_text(second, encoding="utf-8")
            with mock.patch.dict(os.environ, {update_versions.DEVELOPMENT_ENV: "1"}, clear=False):
                two = update_versions.resolve_latest(root, machine="amd64", lookup=FakeLookup())
        self.assertNotEqual(one.project_version, two.project_version)
        self.assertEqual(one.caddy_ratelimit, "v0.1.0")
        self.assertEqual(two.caddy_ratelimit, "v0.1.1")

    def test_use_latest_requires_explicit_development_gate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "versions.toml").write_text(versions_text(PHASE7_VERSION), encoding="utf-8")
            with mock.patch.dict(os.environ, {}, clear=True):
                with self.assertRaisesRegex(update.UpdateError, "development/testing-only"):
                    update_versions.resolve_latest(root, machine="amd64", lookup=mock.Mock())

    def test_use_latest_cannot_target_production_root(self) -> None:
        with mock.patch.dict(os.environ, {update_versions.DEVELOPMENT_ENV: "1"}, clear=False):
            with self.assertRaisesRegex(update.UpdateError, "may not target the production root"):
                update_versions.require_development_target(Path("/"))

    def test_small_remote_lookup_boundary_normalizes_official_image_namespace(self) -> None:
        calls: list[tuple[str, dict[str, str]]] = []

        def get_json(url: str, headers=None):
            calls.append((url, dict(headers or {})))
            if "releases/latest" in url:
                return {"tag_name": "v9.9.9"}
            if "auth.docker.io" in url:
                return {"token": "token"}
            return {
                "manifests": [
                    {"digest": digest("a"), "platform": {"os": "linux", "architecture": "amd64"}},
                    {"digest": digest("b"), "platform": {"os": "linux", "architecture": "arm64"}},
                ]
            }

        lookup = update_versions.RemoteLookup(get_json=get_json)
        self.assertEqual(lookup.latest_release("caddy"), "v9.9.9")
        self.assertEqual(lookup.image_digest("caddy", "9.9.9-alpine", "aarch64"), digest("b"))
        self.assertEqual(len(calls), 3)
        self.assertIn("api.github.com/repos/caddyserver/caddy/releases/latest", calls[0][0])
        self.assertIn("scope=repository:library/caddy:pull", calls[1][0])
        self.assertIn("registry-1.docker.io/v2/library/caddy/manifests/9.9.9-alpine", calls[2][0])
        self.assertIn("Authorization", calls[2][1])


class UpdateTransactionTests(unittest.TestCase):
    def _source(self, parent: Path, name: str, version: str, *, phase6: bool = False) -> Path:
        source = parent / name
        source.mkdir()
        (source / "vwctl").write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        os.chmod(source / "vwctl", 0o755)
        text = phase6_versions_text(version) if phase6 else versions_text(version)
        (source / "versions.toml").write_text(text, encoding="utf-8")
        (source / "email-providers.toml").write_text(f"# catalog {version}\n", encoding="utf-8")
        package = source / "vaultwarden_oci"
        package.mkdir()
        (package / "__init__.py").write_text("", encoding="utf-8")
        (package / "notification.py").write_text(f"# notification {version}\n", encoding="utf-8")
        (package / "update.py").write_text(f"# update {version}\n", encoding="utf-8")
        (package / "update_versions.py").write_text(f"# versions {version}\n", encoding="utf-8")
        (package / "update_cli.py").write_text(f"# cli {version}\n", encoding="utf-8")
        systemd = source / install.SYSTEMD_SOURCE_DIR
        systemd.mkdir()
        for unit in install.SYSTEMD_UNITS:
            (systemd / unit).write_text(f"{unit} {version}\n", encoding="utf-8")
        return source

    def _installed(self, temp: Path, current_source: Path, version: str) -> Path:
        root = temp / "host"
        layout = install.Layout(root)
        releases = layout.path(install.RELEASES_DIR)
        releases.mkdir(parents=True)
        current_release = releases / version
        shutil.copytree(current_source, current_release)
        current = layout.path(install.CURRENT_LINK)
        current.parent.mkdir(parents=True, exist_ok=True)
        current.symlink_to(Path("releases") / version)
        systemd_root = layout.path(install.SYSTEMD_DIR)
        systemd_root.mkdir(parents=True)
        for unit in install.SYSTEMD_UNITS:
            shutil.copy2(current_source / install.SYSTEMD_SOURCE_DIR / unit, systemd_root / unit)
        return root

    def _runner(self, root: Path):
        calls: list[tuple[str, ...]] = []

        def run(argv, **_kwargs):
            args = tuple(argv)
            calls.append(args)
            return command(args)

        return run, calls

    def test_update_cli_reports_installer_failure_without_traceback(self) -> None:
        plan = mock.Mock(already_active=False)
        stderr = io.StringIO()
        with (
            mock.patch.object(update_cli.update, "plan_update", return_value=plan),
            mock.patch.object(update_cli, "_print_plan"),
            mock.patch.object(
                update_cli.update,
                "apply_update",
                side_effect=install.InstallError(
                    "expected regular file at /run/vaultwarden-oci/lock"
                ),
            ),
            mock.patch("sys.stderr", stderr),
        ):
            code = update_cli.main(["update", "apply", "--source", "."])
        self.assertEqual(code, 1)
        self.assertEqual(
            stderr.getvalue(),
            "FAIL: expected regular file at /run/vaultwarden-oci/lock\n",
        )

    def test_nonproduction_update_root_requires_injected_io_boundaries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            old = self._source(temp, "old-source", PHASE6_VERSION, phase6=True)
            candidate = self._source(temp, "candidate", PHASE7_VERSION)
            root = self._installed(temp, old, PHASE6_VERSION)
            with self.assertRaisesRegex(update.UpdateError, "non-production update roots are test-only"):
                update.plan_update(candidate, root=root, machine="amd64")
            runner, calls = self._runner(root)
            plan = update.plan_update(candidate, root=root, machine="amd64", runner=runner)
            with self.assertRaisesRegex(update.UpdateError, "inject both a test runner and test activator"):
                update.apply_update(plan, runner=runner)
            self.assertFalse(any(call[-1:] == ("backup",) for call in calls))

    def test_actual_phase6_to_phase7_transition_is_not_noop(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            old = self._source(temp, "old-source", PHASE6_VERSION, phase6=True)
            candidate = self._source(temp, "candidate", PHASE7_VERSION)
            root = self._installed(temp, old, PHASE6_VERSION)
            runner, _ = self._runner(root)
            plan = update.plan_update(candidate, root=root, machine="amd64", runner=runner)
        self.assertEqual(plan.current_release, PHASE6_VERSION)
        self.assertEqual(plan.target_release, PHASE7_VERSION)
        self.assertFalse(plan.already_active)

    def test_same_release_name_with_different_content_requires_version_bump(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            candidate = self._source(temp, "candidate", PHASE7_VERSION)
            root = self._installed(temp, candidate, PHASE7_VERSION)
            (candidate / "email-providers.toml").write_text("# changed without version bump\n", encoding="utf-8")
            runner, _ = self._runner(root)
            with self.assertRaisesRegex(update.UpdateError, "bump vaultwarden_oci.version"):
                update.plan_update(candidate, root=root, machine="amd64", runner=runner)

    def test_apply_stages_coherent_release_and_activates_exact_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            old = self._source(temp, "old-source", PHASE6_VERSION, phase6=True)
            candidate = self._source(temp, "candidate", PHASE7_VERSION)
            root = self._installed(temp, old, PHASE6_VERSION)
            runner, calls = self._runner(root)
            plan = update.plan_update(candidate, root=root, machine="amd64", runner=runner)
            record = temp / "resolved.json"
            activations: list[str] = []

            def activate(frozen, _versions_path, _runner):
                activations.append(frozen.project_version)

            release = update.apply_update(
                plan, runner=runner, activator=activate, record_path=record
            )
            current = root / "opt/vaultwarden-oci/current"
            self.assertEqual(os.readlink(current), f"releases/{PHASE7_VERSION}")
            self.assertEqual(
                (release / "email-providers.toml").read_bytes(),
                (candidate / "email-providers.toml").read_bytes(),
            )
            self.assertEqual(
                (release / "vaultwarden_oci/notification.py").read_bytes(),
                (candidate / "vaultwarden_oci/notification.py").read_bytes(),
            )
            payload = json.loads(record.read_text(encoding="utf-8"))
            self.assertEqual(payload["project_version"], PHASE7_VERSION)
            pulls = [call for call in calls if call[:2] == ("docker", "pull")]
            self.assertEqual(len(pulls), 3)
            self.assertTrue(all("@sha256:" in call[2] for call in pulls))
            self.assertTrue(any(call[:2] == ("docker", "build") for call in calls))
            self.assertEqual(activations, [PHASE7_VERSION])

    def test_prestart_activation_failure_restores_phase6_application_and_units(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            old = self._source(temp, "old-source", PHASE6_VERSION, phase6=True)
            candidate = self._source(temp, "candidate", PHASE7_VERSION)
            root = self._installed(temp, old, PHASE6_VERSION)
            runner, _calls = self._runner(root)
            plan = update.plan_update(candidate, root=root, machine="amd64", runner=runner)

            def activate(_frozen, _versions_path, _runner):
                raise update.RuntimeActivationError(
                    "prestart validation failed", state_change_possible=False
                )

            with self.assertRaisesRegex(update.UpdateError, "restored before candidate runtime start"):
                update.apply_update(
                    plan, runner=runner, activator=activate, record_path=temp / "resolved.json"
                )
            current = root / "opt/vaultwarden-oci/current"
            self.assertEqual(os.readlink(current), f"releases/{PHASE6_VERSION}")
            for unit in install.SYSTEMD_UNITS:
                self.assertEqual(
                    (root / "etc/systemd/system" / unit).read_text(encoding="utf-8"),
                    f"{unit} {PHASE6_VERSION}\n",
                )
            self.assertFalse((temp / "resolved.json").exists())

    def test_poststart_failure_refuses_automatic_downgrade(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            old = self._source(temp, "old-source", PHASE6_VERSION, phase6=True)
            candidate = self._source(temp, "candidate", PHASE7_VERSION)
            root = self._installed(temp, old, PHASE6_VERSION)
            runner, _calls = self._runner(root)
            plan = update.plan_update(candidate, root=root, machine="amd64", runner=runner)

            def activate(_frozen, _versions_path, _runner):
                raise update.RuntimeActivationError(
                    "compose may have started candidate", state_change_possible=True
                )

            with self.assertRaisesRegex(update.UpdateError, "automatic rollback refused"):
                update.apply_update(
                    plan, runner=runner, activator=activate, record_path=temp / "resolved.json"
                )
            current = root / "opt/vaultwarden-oci/current"
            self.assertEqual(os.readlink(current), f"releases/{PHASE7_VERSION}")
            for unit in install.SYSTEMD_UNITS:
                self.assertEqual(
                    (root / "etc/systemd/system" / unit).read_text(encoding="utf-8"),
                    f"{unit} {PHASE7_VERSION}\n",
                )
            self.assertFalse((temp / "resolved.json").exists())

    def test_poststart_health_gate_failure_keeps_candidate_application_coherent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            old = self._source(temp, "old-source", PHASE6_VERSION, phase6=True)
            candidate = self._source(temp, "candidate", PHASE7_VERSION)
            root = self._installed(temp, old, PHASE6_VERSION)
            base_runner, _calls = self._runner(root)
            candidate_status_seen = False
            activated = False

            def runner(argv, **kwargs):
                nonlocal candidate_status_seen
                args = tuple(argv)
                if activated and args[0].endswith("/current/vwctl") and args[-1:] == ("status",):
                    candidate_status_seen = True
                    return command(args, ok=False)
                return base_runner(argv, **kwargs)

            plan = update.plan_update(candidate, root=root, machine="amd64", runner=runner)

            def activate(_frozen, _versions_path, _runner):
                nonlocal activated
                activated = True

            with self.assertRaisesRegex(update.UpdateError, "automatic rollback refused"):
                update.apply_update(plan, runner=runner, activator=activate)
            self.assertTrue(candidate_status_seen)
            self.assertEqual(
                os.readlink(root / "opt/vaultwarden-oci/current"),
                f"releases/{PHASE7_VERSION}",
            )

    def test_candidate_pin_drift_blocks_recovery_and_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            old = self._source(temp, "old-source", PHASE6_VERSION, phase6=True)
            candidate = self._source(temp, "candidate", PHASE7_VERSION)
            root = self._installed(temp, old, PHASE6_VERSION)
            runner, calls = self._runner(root)
            plan = update.plan_update(candidate, root=root, machine="amd64", runner=runner)
            (candidate / "versions.toml").write_text(
                versions_text(PHASE7_VERSION, amd64="7"), encoding="utf-8"
            )
            with self.assertRaisesRegex(update.UpdateError, "changed since update check"):
                update.apply_update(plan, runner=runner, activator=lambda *_: None)
            self.assertFalse(any(call[-1:] == ("backup",) for call in calls))
            self.assertFalse(any(call[:2] == ("docker", "pull") for call in calls))

    def test_failed_recovery_blocks_staging_and_activation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            old = self._source(temp, "old-source", PHASE6_VERSION, phase6=True)
            candidate = self._source(temp, "candidate", PHASE7_VERSION)
            root = self._installed(temp, old, PHASE6_VERSION)
            base_runner, calls = self._runner(root)

            def runner(argv, **kwargs):
                if tuple(argv)[-1:] == ("backup",):
                    return command(argv, ok=False)
                return base_runner(argv, **kwargs)

            plan = update.plan_update(candidate, root=root, machine="amd64", runner=runner)
            with self.assertRaisesRegex(update.UpdateError, "pre-update recovery failed"):
                update.apply_update(plan, runner=runner, activator=lambda *_: None)
            self.assertEqual(
                os.readlink(root / "opt/vaultwarden-oci/current"),
                f"releases/{PHASE6_VERSION}",
            )
            self.assertFalse((root / f"opt/vaultwarden-oci/releases/{PHASE7_VERSION}").exists())
            self.assertFalse(any(call[:2] == ("docker", "pull") for call in calls))


if __name__ == "__main__":
    unittest.main()
