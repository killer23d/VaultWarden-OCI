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


BASELINE_VERSION = "0.1.0-dev"
CANDIDATE_VERSION = "0.1.0-dev.7"


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


def baseline_versions_text(version: str = BASELINE_VERSION) -> str:
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
            (root / "versions.toml").write_text(versions_text(CANDIDATE_VERSION), encoding="utf-8")
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

            def latest_ref(self, component: str) -> str:
                return {
                    "caddy_cloudflare_ip": "a" * 40,
                    "caddy_combine_ip_ranges": "v0.0.2",
                    "caddy_ratelimit": "v0.2.0",
                }[component]

            def image_digest(self, repository: str, tag: str, architecture: str) -> str:
                self.image_calls.append((repository, tag, architecture))
                return digest(str(len(self.image_calls)))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "versions.toml").write_text(versions_text(CANDIDATE_VERSION), encoding="utf-8")
            lookup = FakeLookup()
            frozen = update_versions.resolve_latest(root, machine="x86_64", lookup=lookup)
            snapshot = update_versions.frozen_versions_toml(frozen)
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
            def __init__(self, ratelimit: str):
                self.ratelimit = ratelimit

            def latest_release(self, component: str) -> str:
                return {
                    "vaultwarden": "v1.40.0",
                    "caddy": "v2.12.0",
                    "caddy_dns_cloudflare": "v0.3.0",
                }[component]

            def latest_ref(self, component: str) -> str:
                return {
                    "caddy_cloudflare_ip": "a" * 40,
                    "caddy_combine_ip_ranges": "v0.0.2",
                    "caddy_ratelimit": self.ratelimit,
                }[component]

            def image_digest(self, repository: str, tag: str, architecture: str) -> str:
                return digest({
                    "vaultwarden/server": "1",
                    "caddy": "2" if "builder" in tag else "3",
                }[repository])

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "versions.toml").write_text(versions_text(CANDIDATE_VERSION), encoding="utf-8")
            one = update_versions.resolve_latest(root, machine="amd64", lookup=FakeLookup("v0.2.0"))
            two = update_versions.resolve_latest(root, machine="amd64", lookup=FakeLookup("v0.2.1"))
        self.assertNotEqual(one.project_version, two.project_version)
        self.assertEqual(one.caddy_ratelimit, "v0.2.0")
        self.assertEqual(two.caddy_ratelimit, "v0.2.1")

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
    def _source(self, parent: Path, name: str, version: str, *, baseline_manifest: bool = False) -> Path:
        source = parent / name
        source.mkdir()
        (source / "vwctl").write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        os.chmod(source / "vwctl", 0o755)
        text = baseline_versions_text(version) if baseline_manifest else versions_text(version)
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

    def test_update_cli_storage_failure_precedes_candidate_download(self) -> None:
        stderr = io.StringIO()
        with (
            mock.patch.object(update_cli.storage, "verify", side_effect=update_cli.storage.StorageError("missing mount")),
            mock.patch.object(update_cli.update_appliance, "candidate_source") as candidate_source,
            mock.patch("sys.stderr", stderr),
        ):
            code = update_cli.main(["update", "apply", "--source", ".", "--yes"])
        self.assertEqual(code, 1)
        candidate_source.assert_not_called()
        self.assertIn("dedicated production storage is not ready: missing mount", stderr.getvalue())

    def test_actual_baseline_manifest_to_candidate_transition_is_not_noop(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            old = self._source(temp, "old-source", BASELINE_VERSION, baseline_manifest=True)
            candidate = self._source(temp, "candidate", CANDIDATE_VERSION)
            root = self._installed(temp, old, BASELINE_VERSION)
            runner, _ = self._runner(root)
            plan = update.plan_update(candidate, root=root, machine="amd64", runner=runner)
        self.assertEqual(plan.current_release, BASELINE_VERSION)
        self.assertEqual(plan.target_release, CANDIDATE_VERSION)
        self.assertFalse(plan.already_active)

    def test_same_release_name_with_different_content_requires_version_bump(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            candidate = self._source(temp, "candidate", CANDIDATE_VERSION)
            root = self._installed(temp, candidate, CANDIDATE_VERSION)
            (candidate / "email-providers.toml").write_text("# changed without version bump\n", encoding="utf-8")
            runner, _ = self._runner(root)
            with self.assertRaisesRegex(update.UpdateError, "bump vaultwarden_oci.version"):
                update.plan_update(candidate, root=root, machine="amd64", runner=runner)

if __name__ == "__main__":
    unittest.main()
