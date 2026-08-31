from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class SystemdRuntimeContractTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
