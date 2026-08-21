from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import install

ROOT = Path(__file__).resolve().parents[2]


class Phase6SystemdInstallTests(unittest.TestCase):
    def test_exact_legacy_target_is_migrated_but_arbitrary_drift_is_not(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release = root / "release"
            shutil.copytree(ROOT / "systemd-v2", release / "systemd-v2")
            layout = install.Layout(root / "target")
            target = layout.path(install.SYSTEMD_DIR / "vaultwarden-oci.target")
            target.parent.mkdir(parents=True)
            target.write_text(install.LEGACY_SYSTEMD_TARGET, encoding="utf-8")

            install._install_systemd_units(release, layout)
            self.assertEqual(
                target.read_text(encoding="utf-8"),
                (ROOT / "systemd-v2/vaultwarden-oci.target").read_text(encoding="utf-8"),
            )

            target.write_text("operator drift\n", encoding="utf-8")
            with self.assertRaisesRegex(install.InstallError, "differs from required content"):
                install._install_systemd_units(release, layout)


if __name__ == "__main__":
    unittest.main()
