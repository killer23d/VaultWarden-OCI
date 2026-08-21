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
        shutil.copytree(ROOT / "systemd-v2", source / "systemd-v2")
        shutil.copy2(ROOT / "email-providers.toml", source / "email-providers.toml")
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

    def test_bootstrap_anchors_python_to_repository(self) -> None:
        try:
            install.validate_host()
        except install.InstallError as exc:
            self.skipTest(f"bootstrap host preflight is not supported here: {exc}")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            trusted = root / "trusted"
            foreign = root / "foreign"
            trusted_package = trusted / "vaultwarden_oci"
            shadow_package = foreign / "vaultwarden_oci"
            trusted_package.mkdir(parents=True)
            shadow_package.mkdir(parents=True)

            shutil.copy2(ROOT / "bootstrap-v2.sh", trusted / "bootstrap-v2.sh")
            (trusted_package / "__init__.py").write_text("", encoding="utf-8")
            (trusted_package / "install.py").write_text(
                "import os\n"
                "if 'PYTHONPATH' in os.environ:\n"
                "    raise SystemExit('inherited PYTHONPATH reached trusted Python')\n"
                "print('trusted-repository-package')\n",
                encoding="utf-8",
            )
            (shadow_package / "__init__.py").write_text("", encoding="utf-8")
            (shadow_package / "install.py").write_text(
                "raise SystemExit('shadow-package-executed')\n",
                encoding="utf-8",
            )

            env = os.environ.copy()
            env["PYTHONPATH"] = str(foreign)
            command = ["/bin/bash", str(trusted / "bootstrap-v2.sh")]
            if os.geteuid() != 0:
                sudo = shutil.which("sudo")
                if sudo is None:
                    self.skipTest("root bootstrap regression requires root or passwordless sudo")
                probe = subprocess.run(
                    [sudo, "-n", "/usr/bin/true"],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if probe.returncode != 0:
                    self.skipTest("passwordless sudo is unavailable for bootstrap regression")
                command = [
                    sudo,
                    "-n",
                    "/usr/bin/env",
                    f"PYTHONPATH={foreign}",
                    "/bin/bash",
                    str(trusted / "bootstrap-v2.sh"),
                ]
                env.pop("PYTHONPATH", None)

            result = subprocess.run(
                command,
                cwd=foreign,
                env=env,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            self.assertEqual(result.stdout.strip(), "trusted-repository-package")
            self.assertNotIn("shadow-package-executed", result.stderr)

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
            self.assertEqual(stat.S_IMODE((release_dir / "systemd-v2").stat().st_mode), 0o555)
            self.assertTrue((release_dir / "vaultwarden_oci/install.py").is_file())

            config = root / "etc/vaultwarden-oci/config.toml"
            config.write_text('site_name = "preserved"\n', encoding="utf-8")
            install.install_layout(ROOT, root=root, systemd_reload=False)
            self.assertEqual(config.read_text(encoding="utf-8"), 'site_name = "preserved"\n')

    def test_same_release_with_different_content_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install.install_layout(ROOT, root=root, systemd_reload=False)
            release_dir = root / "opt/vaultwarden-oci/releases/0.1.0-dev"
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
            installed = root / "opt/vaultwarden-oci/releases/0.1.0-dev/versions.toml"
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
                (root / "opt/vaultwarden-oci/releases/0.1.0-dev").exists()
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
