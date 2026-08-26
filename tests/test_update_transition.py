from __future__ import annotations

import os
import shutil
import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import install, update, update_unit_migration

ROOT = Path(__file__).resolve().parents[1]


class PreviousUpdaterTransitionTests(unittest.TestCase):
    def test_previous_updater_source_contract_is_preserved_but_not_new_release_owned(self) -> None:
        canonical = ROOT / install.SYSTEMD_SOURCE_DIR
        bridge = ROOT / install.PREVIOUS_SYSTEMD_SOURCE_DIR
        self.assertTrue(canonical.is_dir())
        self.assertTrue(bridge.is_dir())
        self.assertIn(install.SYSTEMD_SOURCE_DIR, install.RELEASE_DIRS)
        self.assertNotIn(install.PREVIOUS_SYSTEMD_SOURCE_DIR, install.RELEASE_DIRS)
        for unit in install.SYSTEMD_UNITS:
            self.assertEqual((canonical / unit).read_bytes(), (bridge / unit).read_bytes(), unit)
        # This is the immediately preceding updater's source preflight contract.
        for name in install.RELEASE_FILES:
            self.assertTrue((ROOT / name).is_file(), name)
        self.assertTrue((ROOT / "vaultwarden_oci").is_dir())
        self.assertTrue(bridge.is_dir())

    def test_new_unit_migration_accepts_previous_release_historical_layout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            layout = install.Layout(root / "host")
            previous = root / "previous"
            candidate = root / "candidate"
            previous_units = previous / install.PREVIOUS_SYSTEMD_SOURCE_DIR
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

    def test_same_release_content_normalizes_previous_systemd_layout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            canonical = root / "canonical"
            previous = root / "previous"
            canonical.mkdir()
            previous.mkdir()
            for name in install.RELEASE_FILES:
                (canonical / name).write_text(name + "\n", encoding="utf-8")
                (previous / name).write_text(name + "\n", encoding="utf-8")
            (canonical / "vaultwarden_oci").mkdir()
            (previous / "vaultwarden_oci").mkdir()
            (canonical / "vaultwarden_oci/marker").write_text("same\n", encoding="utf-8")
            (previous / "vaultwarden_oci/marker").write_text("same\n", encoding="utf-8")
            canonical_units = canonical / install.SYSTEMD_SOURCE_DIR
            previous_units = previous / install.PREVIOUS_SYSTEMD_SOURCE_DIR
            canonical_units.mkdir()
            previous_units.mkdir()
            for unit in install.SYSTEMD_UNITS:
                payload = f"{unit}\n".encode()
                (canonical_units / unit).write_bytes(payload)
                (previous_units / unit).write_bytes(payload)
            self.assertEqual(
                update._selected_release_content(canonical),
                update._selected_release_content(previous),
            )


if __name__ == "__main__":
    unittest.main()
