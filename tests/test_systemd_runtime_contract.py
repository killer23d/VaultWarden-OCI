from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import install


ROOT = Path(__file__).resolve().parents[1]
RUNTIME_ROOT = "/run/vaultwarden-oci"
RUNTIME_CONTRACT = (
    "RuntimeDirectory=vaultwarden-oci\n",
    "RuntimeDirectoryMode=0700\n",
    "RuntimeDirectoryPreserve=yes\n",
)


def units_requiring_runtime_root(systemd_dir: Path) -> list[Path]:
    required: list[Path] = []
    for unit_path in sorted(systemd_dir.glob("*.service")):
        unit = unit_path.read_text(encoding="utf-8")
        for line in unit.splitlines():
            if not line.startswith("ReadWritePaths="):
                continue
            paths = line.partition("=")[2].split()
            if any(path.lstrip("-+~") == RUNTIME_ROOT for path in paths):
                required.append(unit_path)
                break
    return required


class SystemdRuntimeContractTests(unittest.TestCase):
    def assert_runtime_directory_contract(self, unit_path: Path) -> None:
        unit = unit_path.read_text(encoding="utf-8")
        for directive in RUNTIME_CONTRACT:
            self.assertIn(directive, unit, unit_path.name)

    def test_lifecycle_docker_client_state_stays_in_managed_runtime_root(self) -> None:
        unit = (ROOT / "systemd/vaultwarden-oci.service").read_text(encoding="utf-8")

        self.assertIn(
            "Environment=DOCKER_CONFIG=/run/vaultwarden-oci/docker-client\n",
            unit,
        )
        self.assertIn("ProtectHome=yes\n", unit)
        self.assertIn("ProtectSystem=strict\n", unit)
        self.assertIn(
            "ReadWritePaths=/var/lib/vaultwarden-oci /run/vaultwarden-oci\n",
            unit,
        )
        self.assertNotIn("ReadWritePaths=/root", unit)

    def test_diagnostic_units_limit_crowdsec_database_write_boundary(self) -> None:
        expected = (
            "ReadWritePaths=/var/lib/vaultwarden-oci /run/vaultwarden-oci "
            "/var/lib/crowdsec/data\n"
        )
        for name in (
            "vaultwarden-oci-health.service",
            "vaultwarden-oci-maintenance.service",
        ):
            with self.subTest(unit=name):
                unit = (ROOT / "systemd" / name).read_text(encoding="utf-8")
                self.assertIn("ProtectSystem=strict\n", unit)
                self.assertIn(expected, unit)
                self.assertNotIn("ReadWritePaths=/etc/crowdsec", unit)
                self.assertNotIn("ReadWritePaths=/var/lib/crowdsec\n", unit)

    def test_every_service_with_runtime_readwrite_path_has_boot_safe_owner(self) -> None:
        applicable = units_requiring_runtime_root(ROOT / "systemd")
        self.assertTrue(applicable, "expected at least one service using the shared runtime root")
        for unit_path in applicable:
            with self.subTest(unit=unit_path.name):
                self.assert_runtime_directory_contract(unit_path)

    def test_installed_units_do_not_depend_on_installer_runtime_copy_surviving(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install.install_layout(ROOT, root=root, systemd_reload=False)
            runtime_root = root / "run/vaultwarden-oci"
            self.assertTrue(runtime_root.is_dir())
            shutil.rmtree(runtime_root)
            self.assertFalse(runtime_root.exists())

            installed_systemd = root / "etc/systemd/system"
            applicable = units_requiring_runtime_root(installed_systemd)
            self.assertTrue(applicable)
            for unit_path in applicable:
                with self.subTest(unit=unit_path.name):
                    self.assert_runtime_directory_contract(unit_path)


if __name__ == "__main__":
    unittest.main()
