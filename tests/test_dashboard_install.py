from __future__ import annotations

import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import install

ROOT = Path(__file__).resolve().parents[1]


class InstalledDashboardTests(unittest.TestCase):
    def test_dashboard_runs_from_staged_immutable_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            release = Path(install.install_layout(ROOT, root=Path(directory), systemd_reload=False))
            dashboard = release / "vaultwarden_oci/dashboard.sh"
            self.assertTrue(dashboard.is_file())
            self.assertEqual(stat.S_IMODE(dashboard.stat().st_mode), 0o555)
            result = subprocess.run(
                ["bash", str(dashboard), "--help"],
                cwd=release,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Operations Dashboard", result.stdout)
            self.assertNotIn(str(ROOT), result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
