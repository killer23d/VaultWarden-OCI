from __future__ import annotations

import os
import stat
import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import install

ROOT = Path(__file__).resolve().parents[2]


class Phase2FoundationRegressionTests(unittest.TestCase):
    def test_host_validation_keeps_noble_arch_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory) / "os-release"
            release.write_text('ID="ubuntu"\nVERSION_ID="24.04"\n', encoding="utf-8")
            self.assertEqual(install.validate_host(os_release=release, machine="x86_64").architecture, "amd64")
            self.assertEqual(install.validate_host(os_release=release, machine="aarch64").architecture, "arm64")
            with self.assertRaises(install.InstallError):
                install.validate_host(os_release=release, machine="ppc64le")

    def test_installed_layout_remains_immutable_and_root_private(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release_dir = Path(install.install_layout(ROOT, root=root, systemd_reload=False))
            self.assertEqual(release_dir.name, "0.2.0-dev")
            current = root / "opt/vaultwarden-oci/current"
            self.assertTrue(current.is_symlink())
            self.assertEqual(os.readlink(current), "releases/0.2.0-dev")
            vwctl = root / "usr/local/bin/vwctl"
            self.assertTrue(vwctl.is_symlink())
            expected_modes = {
                "etc/vaultwarden-oci": 0o700,
                "etc/vaultwarden-oci/config.toml": 0o600,
                "etc/vaultwarden-oci/secrets.sops.yaml": 0o600,
                "etc/vaultwarden-oci/age-key.txt": 0o600,
                "var/lib/vaultwarden-oci": 0o700,
                "run/vaultwarden-oci": 0o700,
                "run/vaultwarden-oci/secrets": 0o700,
                "run/vaultwarden-oci/transient": 0o700,
                "run/vaultwarden-oci/lock": 0o600,
            }
            for relative, expected in expected_modes.items():
                self.assertEqual(stat.S_IMODE((root / relative).stat().st_mode), expected, relative)
            self.assertEqual(stat.S_IMODE(release_dir.stat().st_mode), 0o555)
            self.assertEqual(stat.S_IMODE((release_dir / "versions.toml").stat().st_mode), 0o444)
            self.assertEqual(stat.S_IMODE((release_dir / "vwctl").stat().st_mode), 0o555)

    def test_operator_config_is_preserved_on_reinstall(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install.install_layout(ROOT, root=root, systemd_reload=False)
            config = root / "etc/vaultwarden-oci/config.toml"
            config.write_text('operator_owned = "preserved"\n', encoding="utf-8")
            install.install_layout(ROOT, root=root, systemd_reload=False)
            self.assertEqual(config.read_text(encoding="utf-8"), 'operator_owned = "preserved"\n')

    def test_same_release_content_or_mode_drift_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release = Path(install.install_layout(ROOT, root=root, systemd_reload=False))
            installed = release / "versions.toml"
            os.chmod(release, 0o755); os.chmod(installed, 0o644)
            installed.write_text('changed\n', encoding="utf-8")
            os.chmod(installed, 0o444); os.chmod(release, 0o555)
            with self.assertRaisesRegex(install.InstallError, "different content"):
                install.install_layout(ROOT, root=root, systemd_reload=False)

    def test_incompatible_managed_path_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            conflict = root / "var/lib/vaultwarden-oci"
            conflict.parent.mkdir(parents=True)
            conflict.write_text("not a directory", encoding="utf-8")
            with self.assertRaisesRegex(install.InstallError, "expected directory"):
                install.install_layout(ROOT, root=root, systemd_reload=False)


if __name__ == "__main__":
    unittest.main()
