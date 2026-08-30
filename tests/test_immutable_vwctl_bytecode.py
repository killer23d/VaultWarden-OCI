from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import install


class ImmutableVwctlBytecodeTests(unittest.TestCase):
    def test_installed_entrypoint_never_writes_python_bytecode_into_release_tree(self) -> None:
        source = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory) / "release"
            release.mkdir()
            install._copy_release_tree(source, release)

            # Make the copied tree writable so this test catches bytecode writes
            # even without uid 0. The production failure was stronger because
            # root can bypass immutable 0555/0444 mode bits.
            for path in release.rglob("*"):
                if path.is_dir():
                    path.chmod(0o755)
                elif path.is_file():
                    path.chmod(0o755 if path.stat().st_mode & os.X_OK else 0o644)

            self.assertFalse(any(release.rglob("*.pyc")))
            self.assertFalse(any(path.name == "__pycache__" for path in release.rglob("*")))

            env = dict(os.environ)
            env.pop("PYTHONDONTWRITEBYTECODE", None)
            completed = subprocess.run(
                [str(release / "vwctl"), "--help"],
                cwd=release,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertFalse(any(release.rglob("*.pyc")))
            self.assertFalse(any(path.name == "__pycache__" for path in release.rglob("*")))


if __name__ == "__main__":
    unittest.main()
