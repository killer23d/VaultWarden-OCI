from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import install, update, update_unit_migration
from vaultwarden_oci.update_versions import UpdateError


class UpdateTransitionTests(unittest.TestCase):
    def test_release_manifest_uses_canonical_systemd_source(self) -> None:
        self.assertEqual(install.SYSTEMD_SOURCE_DIR, "systemd")
        self.assertIn(install.SYSTEMD_SOURCE_DIR, install.RELEASE_DIRS)

    def test_unit_migration_accepts_canonical_predecessor_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            layout = install.Layout(root / "host")
            previous = root / "previous"
            candidate = root / "candidate"
            previous_units = previous / install.SYSTEMD_SOURCE_DIR
            candidate_units = candidate / install.SYSTEMD_SOURCE_DIR
            previous_units.mkdir(parents=True)
            candidate_units.mkdir(parents=True)
            installed_units = layout.path(install.SYSTEMD_DIR)
            installed_units.mkdir(parents=True)
            for unit in install.SYSTEMD_UNITS:
                old = f"old {unit}\n".encode()
                new = f"new {unit}\n".encode()
                (previous_units / unit).write_bytes(old)
                (candidate_units / unit).write_bytes(new)
                (installed_units / unit).write_bytes(old)
            snapshot = update_unit_migration.install_units(candidate, previous, layout)
            self.assertEqual(len(snapshot), len(install.SYSTEMD_UNITS))
            for unit in install.SYSTEMD_UNITS:
                self.assertEqual((installed_units / unit).read_bytes(), f"new {unit}\n".encode())

    def test_release_content_requires_canonical_systemd_layout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in install.RELEASE_FILES:
                (root / name).write_text(name + "\n", encoding="utf-8")
            (root / "vaultwarden_oci").mkdir()
            (root / "vaultwarden_oci/marker").write_text("same\n", encoding="utf-8")
            with self.assertRaises(UpdateError):
                update._selected_release_content(root)
            units = root / install.SYSTEMD_SOURCE_DIR
            units.mkdir()
            for unit in install.SYSTEMD_UNITS:
                (units / unit).write_text(unit + "\n", encoding="utf-8")
            selected = update._selected_release_content(root)
            self.assertIn("systemd/", selected)


if __name__ == "__main__":
    unittest.main()
