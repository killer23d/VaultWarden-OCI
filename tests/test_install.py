from __future__ import annotations

import os
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, install

ROOT = Path(__file__).resolve().parents[1]
CURRENT_RELEASE_VERSION = cli.load_versions(ROOT / "versions.toml").version


def exact_versions(version: str) -> str:
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
amd64 = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
arm64 = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
[image_digests.caddy_builder]
amd64 = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
arm64 = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
[image_digests.caddy_runtime]
amd64 = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
arm64 = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
'''


class InstallLayoutTests(unittest.TestCase):
    def write_os_release(self, root: Path, *, distro: str = "ubuntu", version: str = "24.04") -> Path:
        path = root / "os-release"
        path.write_text(f'ID="{distro}"\nVERSION_ID="{version}"\n', encoding="utf-8")
        return path

    def write_release_source(self, root: Path, version: str) -> Path:
        source = root / "source"
        source.mkdir()
        shutil.copy2(ROOT / "vwctl", source / "vwctl")
        shutil.copytree(ROOT / "vaultwarden_oci", source / "vaultwarden_oci")
        shutil.copytree(ROOT / "systemd", source / "systemd")
        shutil.copy2(ROOT / "email-providers.toml", source / "email-providers.toml")
        (source / "versions.toml").write_text(exact_versions(version), encoding="utf-8")
        return source

    def test_host_validation_accepts_noble_supported_architectures(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            os_release = self.write_os_release(Path(directory))
            self.assertEqual(install.validate_host(os_release=os_release, machine="x86_64").architecture, "amd64")
            self.assertEqual(install.validate_host(os_release=os_release, machine="aarch64").architecture, "arm64")

    def test_host_validation_rejects_wrong_release_and_architecture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrong_release = self.write_os_release(root, version="22.04")
            with self.assertRaises(install.InstallError):
                install.validate_host(os_release=wrong_release, machine="x86_64")

            noble = self.write_os_release(root, version="24.04")
            with self.assertRaises(install.InstallError):
                install.validate_host(os_release=noble, machine="ppc64le")

    def test_temp_root_install_layout_permissions_and_idempotency(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release_dir = Path(
                install.install_layout(ROOT, root=root, systemd_reload=False)
            )
            self.assertTrue(release_dir.is_dir())
            self.assertEqual(release_dir.name, CURRENT_RELEASE_VERSION)

            current = root / "opt/vaultwarden-oci/current"
            self.assertTrue(current.is_symlink())
            self.assertEqual(os.readlink(current), f"releases/{CURRENT_RELEASE_VERSION}")

            vwctl = root / "usr/local/bin/vwctl"
            self.assertTrue(vwctl.is_symlink())
            self.assertEqual(
                os.readlink(vwctl),
                str(root / "opt/vaultwarden-oci/current/vwctl"),
            )

            expected_modes = {
                "etc/vaultwarden-oci": 0o700,
                "etc/vaultwarden-oci/config.toml": 0o600,
                "etc/vaultwarden-oci/secrets.sops.yaml": 0o600,
                "etc/vaultwarden-oci/age-key.txt": 0o600,
                "var/lib/vaultwarden-oci": 0o700,
                "var/lib/vaultwarden-oci/state": 0o700,
                "run/vaultwarden-oci": 0o700,
                "run/vaultwarden-oci/secrets": 0o700,
                "run/vaultwarden-oci/transient": 0o700,
                "run/vaultwarden-oci/lock": 0o600,
                "etc/systemd/system/vaultwarden-oci.target": 0o644,
                "etc/systemd/system/vaultwarden-oci.service": 0o644,
                "etc/systemd/system/vaultwarden-oci-health.timer": 0o644,
                "etc/systemd/system/vaultwarden-oci-backup.timer": 0o644,
                "etc/systemd/system/vaultwarden-oci-maintenance.timer": 0o644,
                "etc/systemd/system/vaultwarden-oci-notify@.service": 0o644,
            }
            for relative, expected in expected_modes.items():
                with self.subTest(path=relative):
                    actual = stat.S_IMODE((root / relative).stat().st_mode)
                    self.assertEqual(actual, expected)

            self.assertEqual(stat.S_IMODE(release_dir.stat().st_mode), 0o555)
            self.assertEqual(stat.S_IMODE((release_dir / "versions.toml").stat().st_mode), 0o444)
            self.assertEqual(stat.S_IMODE((release_dir / "email-providers.toml").stat().st_mode), 0o444)
            self.assertEqual(stat.S_IMODE((release_dir / "vwctl").stat().st_mode), 0o555)
            self.assertEqual(stat.S_IMODE((release_dir / "systemd").stat().st_mode), 0o555)
            self.assertTrue((release_dir / "vaultwarden_oci/install.py").is_file())
            installed_versions = (release_dir / "versions.toml").read_text(encoding="utf-8")
            self.assertIn("[image_digests.vaultwarden]", installed_versions)
            self.assertIn("[image_digests.caddy_builder]", installed_versions)
            self.assertIn("[image_digests.caddy_runtime]", installed_versions)

            config = root / "etc/vaultwarden-oci/config.toml"
            config.write_text('site_name = "preserved"\n', encoding="utf-8")
            install.install_layout(ROOT, root=root, systemd_reload=False)
            self.assertEqual(config.read_text(encoding="utf-8"), 'site_name = "preserved"\n')

    def test_install_rejects_missing_exact_image_pins(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.write_release_source(root, "0.1.0-missing-digests")
            (source / "versions.toml").write_text(
                'schema_version = 1\n[vaultwarden_oci]\nversion = "0.1.0-missing-digests"\n'
                '[components]\nvaultwarden = "1.37.1"\ncaddy = "2.11.4"\n'
                'caddy_dns_cloudflare = "v0.2.4"\n'
                'caddy_cloudflare_ip = "f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5"\n'
                'caddy_combine_ip_ranges = "v0.0.1"\n'
                'caddy_ratelimit = "v0.1.0"\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(install.InstallError, "image_digests"):
                install.install_layout(source, root=root / "target", systemd_reload=False)

    def test_same_release_with_different_content_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install.install_layout(ROOT, root=root, systemd_reload=False)
            release_dir = root / f"opt/vaultwarden-oci/releases/{CURRENT_RELEASE_VERSION}"
            installed = release_dir / "versions.toml"

            os.chmod(release_dir, 0o755)
            os.chmod(installed, 0o644)
            installed.write_text(
                'schema_version = 1\n[vaultwarden_oci]\nversion = "changed"\n',
                encoding="utf-8",
            )
            os.chmod(installed, 0o444)
            os.chmod(release_dir, 0o555)

            with self.assertRaisesRegex(install.InstallError, "different content"):
                install.install_layout(ROOT, root=root, systemd_reload=False)

    def test_same_release_with_mode_drift_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install.install_layout(ROOT, root=root, systemd_reload=False)
            installed = root / f"opt/vaultwarden-oci/releases/{CURRENT_RELEASE_VERSION}/versions.toml"
            os.chmod(installed, 0o644)
            with self.assertRaisesRegex(install.InstallError, "incompatible mode"):
                install.install_layout(ROOT, root=root, systemd_reload=False)

    def test_immutable_release_resource_stays_out_of_operator_config(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.write_release_source(root, "0.1.0-resource-test")
            catalog = source / "email-providers.toml"
            catalog.write_text('schema_version = 1\n', encoding="utf-8")

            release_dir = Path(
                install.install_layout(source, root=root / "target", systemd_reload=False)
            )
            installed_catalog = release_dir / "email-providers.toml"
            self.assertEqual(installed_catalog.read_text(encoding="utf-8"), 'schema_version = 1\n')
            self.assertEqual(stat.S_IMODE(installed_catalog.stat().st_mode), 0o444)
            self.assertFalse(
                (root / "target/etc/vaultwarden-oci/email-providers.toml").exists()
            )

    def test_missing_provider_catalog_fails_before_release_promotion(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.write_release_source(root, "0.1.0-missing-catalog")
            (source / "email-providers.toml").unlink()
            with self.assertRaisesRegex(install.InstallError, "required release file is missing"):
                install.install_layout(source, root=root / "target", systemd_reload=False)
            self.assertFalse((root / "target/opt/vaultwarden-oci/releases/0.1.0-missing-catalog").exists())

    def test_incompatible_path_type_fails_clearly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            conflict = root / "var/lib/vaultwarden-oci"
            conflict.parent.mkdir(parents=True)
            conflict.write_text("not a directory", encoding="utf-8")
            with self.assertRaisesRegex(install.InstallError, "expected directory"):
                install.install_layout(ROOT, root=root, systemd_reload=False)

    def test_incompatible_managed_ownership_fails_clearly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime_root = root / "run/vaultwarden-oci"
            runtime_root.mkdir(parents=True, mode=0o700)
            fake_uid = os.geteuid() + 1
            with mock.patch.object(install.os, "geteuid", return_value=fake_uid):
                with self.assertRaisesRegex(install.InstallError, "incompatible ownership"):
                    install.install_layout(ROOT, root=root, systemd_reload=False)

    def test_unsafe_release_name_cannot_escape_releases(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.write_release_source(root, "../../escape")
            with self.assertRaisesRegex(install.InstallError, "unsafe release version"):
                install.install_layout(source, root=root / "target", systemd_reload=False)
            self.assertFalse((root / "escape").exists())

    def test_existing_current_symlink_is_not_retargeted_or_promoted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = root / "opt/vaultwarden-oci/current"
            current.parent.mkdir(parents=True)
            current.symlink_to("releases/older")
            with self.assertRaisesRegex(install.InstallError, "existing symlink"):
                install.install_layout(ROOT, root=root, systemd_reload=False)
            self.assertEqual(os.readlink(current), "releases/older")
            self.assertFalse(
                (root / f"opt/vaultwarden-oci/releases/{CURRENT_RELEASE_VERSION}").exists()
            )

    def test_existing_systemd_unit_drift_fails_clearly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install.install_layout(ROOT, root=root, systemd_reload=False)
            unit = root / "etc/systemd/system/vaultwarden-oci-health.service"
            unit.write_text("drift\n", encoding="utf-8")
            with self.assertRaisesRegex(install.InstallError, "differs from required content"):
                install.install_layout(ROOT, root=root, systemd_reload=False)

    def test_install_refuses_when_global_mutation_lock_is_held(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock_path = root / "run/vaultwarden-oci/lock"
            lock_path.parent.mkdir(parents=True, mode=0o700)
            lock_path.touch(mode=0o600)

            holder_code = textwrap.dedent(
                """
                import sys
                import time
                from pathlib import Path
                from vaultwarden_oci.cli import mutation_lock

                with mutation_lock(Path(sys.argv[1])):
                    print("locked", flush=True)
                    time.sleep(30)
                """
            )
            env = os.environ.copy()
            env["PYTHONPATH"] = str(ROOT)
            holder = subprocess.Popen(
                [sys.executable, "-c", holder_code, str(lock_path)],
                cwd=ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                self.assertIsNotNone(holder.stdout)
                self.assertEqual(holder.stdout.readline().strip(), "locked")
                with self.assertRaises(install.LockBusyError):
                    install.install_layout(ROOT, root=root, systemd_reload=False)
                self.assertFalse((root / "opt/vaultwarden-oci").exists())
            finally:
                holder.terminate()
                try:
                    holder.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    holder.kill()
                    holder.wait(timeout=5)
                if holder.stdout is not None:
                    holder.stdout.close()
                if holder.stderr is not None:
                    holder.stderr.close()


if __name__ == "__main__":
    unittest.main()
