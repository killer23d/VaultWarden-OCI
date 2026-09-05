from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import install


ROOT = Path(__file__).resolve().parents[1]
RUNTIME_ROOT = "/run/vaultwarden-oci"
RUNTIME_CONTRACT = {
    "RuntimeDirectory": "vaultwarden-oci",
    "RuntimeDirectoryMode": "0700",
    "RuntimeDirectoryPreserve": "yes",
}


def service_directives(unit_path: Path) -> dict[str, list[str]]:
    directives: dict[str, list[str]] = {}
    section = ""
    for raw_line in unit_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if section != "Service" or "=" not in line:
            continue
        key, value = line.split("=", 1)
        directives.setdefault(key.strip(), []).append(value.strip())
    return directives


def units_requiring_runtime_root(systemd_dir: Path) -> list[Path]:
    required: list[Path] = []
    for unit_path in sorted(systemd_dir.glob("*.service")):
        directives = service_directives(unit_path)
        for value in directives.get("ReadWritePaths", []):
            paths = value.split()
            if any(path.lstrip("-+~") == RUNTIME_ROOT for path in paths):
                required.append(unit_path)
                break
    return required


class SystemdRuntimeContractTests(unittest.TestCase):
    def assert_runtime_directory_contract(self, unit_path: Path) -> None:
        directives = service_directives(unit_path)
        for key, expected in RUNTIME_CONTRACT.items():
            self.assertEqual(
                directives.get(key),
                [expected],
                f"{unit_path.name}: expected exactly one active {key}={expected}",
            )
        for key in ("User", "Group"):
            values = directives.get(key, [])
            self.assertTrue(
                all(value == "root" for value in values),
                f"{unit_path.name}: shared {RUNTIME_ROOT} owner must remain root; {key}={values}",
            )

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
