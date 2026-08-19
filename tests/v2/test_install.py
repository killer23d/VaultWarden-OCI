from __future__ import annotations

import os
import shutil
import stat
import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import install

ROOT = Path(__file__).resolve().parents[2]


class Phase2InstallTests(unittest.TestCase):
    def write_os_release(self, root: Path, *, distro: str = "ubuntu", version: str = "24.04") -> Path:
        path = root / "os-release"
        path.write_text(f'ID="{distro}"\nVERSION_ID="{version}"\n', encoding="utf-8")
        return path

    def write_release_source(self, root: Path, version: str) -> Path:
        source = root / "source"
        source.mkdir()
        shutil.copy2(ROOT / "vwctl", source / "vwctl")
        shutil.copytree(ROOT / "vaultwarden_oci", source / "vaultwarden_oci")
        (source / "versions.toml").write_text(
            f'schema_version = 1\n[vaultwarden_oci]\nversion = "{version}"\n',
            encoding="utf-8",
        )
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
            self.assertEqual(release_dir.name, "0.1.0-dev")

            current = root / "opt/vaultwarden-oci/current"
            self.assertTrue(current.is_symlink())
            self.assertEqual(os.readlink(current), "releases/0.1.0-dev")

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
            }
            for relative, expected in expected_modes.items():
                with self.subTest(path=relative):
                    actual = stat.S_IMODE((root / relative).stat().st_mode)
                    self.assertEqual(actual, expected)

            self.assertEqual(stat.S_IMODE(release_dir.stat().st_mode), 0o555)
            self.assertEqual(stat.S_IMODE((release_dir / "versions.toml").stat().st_mode), 0o444)
            self.assertEqual(stat.S_IMODE((release_dir / "vwctl").stat().st_mode), 0o555)
            self.assertTrue((release_dir / "vaultwarden_oci/install.py").is_file())

            config = root / "etc/vaultwarden-oci/config.toml"
            config.write_text('site_name = "preserved"\n', encoding="utf-8")
            install.install_layout(ROOT, root=root, systemd_reload=False)
            self.assertEqual(config.read_text(encoding="utf-8"), 'site_name = "preserved"\n')

    def test_same_release_with_different_content_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install.install_layout(ROOT, root=root, systemd_reload=False)
            installed = root / "opt/vaultwarden-oci/releases/0.1.0-dev/versions.toml"
            os.chmod(installed.parent, 0o755)
            os.chmod(installed, 0o644)
            installed.write_text('schema_version = 1\n[vaultwarden_oci]\nversion = "changed"\n', encoding="utf-8")
            with self.assertRaises(install.InstallError):
                install.install_layout(ROOT, root=root, systemd_reload=False)

    def test_incompatible_path_type_fails_clearly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            conflict = root / "var/lib/vaultwarden-oci"
            conflict.parent.mkdir(parents=True)
            conflict.write_text("not a directory", encoding="utf-8")
            with self.assertRaisesRegex(install.InstallError, "expected directory"):
                install.install_layout(ROOT, root=root, systemd_reload=False)

    def test_unsafe_release_name_cannot_escape_releases(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.write_release_source(root, "../../escape")
            with self.assertRaisesRegex(install.InstallError, "unsafe release version"):
                install.install_layout(source, root=root / "target", systemd_reload=False)
            self.assertFalse((root / "escape").exists())

    def test_existing_current_symlink_is_not_retargeted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = root / "opt/vaultwarden-oci/current"
            current.parent.mkdir(parents=True)
            current.symlink_to("releases/older")
            with self.assertRaisesRegex(install.InstallError, "existing symlink"):
                install.install_layout(ROOT, root=root, systemd_reload=False)
            self.assertEqual(os.readlink(current), "releases/older")


if __name__ == "__main__":
    unittest.main()
