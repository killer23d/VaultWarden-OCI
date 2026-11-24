from __future__ import annotations

import os
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

    def test_canonical_installed_console_help_preserves_immutable_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release = Path(install.install_layout(ROOT, root=root, systemd_reload=False))
            launcher = root / "usr/local/bin/vwctl"
            self.assertTrue(launcher.is_symlink())
            self.assertEqual(launcher.resolve(), release / "vwctl")

            def snapshot():
                return {
                    path.relative_to(release): (
                        stat.S_IMODE(path.stat().st_mode),
                        path.read_bytes() if path.is_file() else None,
                    )
                    for path in release.rglob("*")
                }

            before = snapshot()
            env = dict(os.environ)
            env.pop("PYTHONDONTWRITEBYTECODE", None)
            env.pop("PYTHONPYCACHEPREFIX", None)
            for command in ("menu", "guide"):
                with self.subTest(command=command):
                    result = subprocess.run(
                        [str(launcher), command, "--help"],
                        cwd=root, env=env, text=True, capture_output=True, check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(f"usage: vwctl {command}", result.stdout)
                    self.assertNotIn(str(ROOT), result.stdout + result.stderr)
            result = subprocess.run(
                [str(launcher), "guide", "restore"],
                cwd=root, env=env, input="", text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertTrue("terminal" in result.stderr or "root" in result.stderr, result.stderr)
            self.assertEqual(before, snapshot())
            self.assertFalse(any(release.rglob("*.pyc")))
            self.assertFalse(any(path.name == "__pycache__" for path in release.rglob("*")))


if __name__ == "__main__":
    unittest.main()
