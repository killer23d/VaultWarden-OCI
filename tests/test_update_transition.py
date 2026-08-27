from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import install, update, update_unit_migration
from vaultwarden_oci.update_versions import UpdateError


class UpdateTransitionTests(unittest.TestCase):
    def _historical_predecessor(self, root: Path) -> tuple[Path, Path]:
        previous = root / update_unit_migration.SUPPORTED_PREDECESSOR_RELEASE
        historical_name = "systemd-" + "v" + "2"
        historical = previous / historical_name
        historical.mkdir(parents=True)
        for unit in install.SYSTEMD_UNITS:
            (historical / unit).write_text(unit + "\n", encoding="utf-8")
        return previous, historical

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

    def test_supported_predecessor_historical_layout_is_read_for_rollback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            layout = install.Layout(root / "host")
            previous, previous_units = self._historical_predecessor(root)
            candidate = root / "0.1.0-dev.16"
            candidate_units = candidate / install.SYSTEMD_SOURCE_DIR
            candidate_units.mkdir(parents=True)
            installed_units = layout.path(install.SYSTEMD_DIR)
            installed_units.mkdir(parents=True)

            for unit in install.SYSTEMD_UNITS:
                (previous_units / unit).write_text(f"previous {unit}\n", encoding="utf-8")
                (candidate_units / unit).write_text(f"candidate {unit}\n", encoding="utf-8")
                (installed_units / unit).write_bytes((candidate_units / unit).read_bytes())

            update_unit_migration.converge_units(previous, (candidate, previous), layout)
            for unit in install.SYSTEMD_UNITS:
                self.assertEqual((installed_units / unit).read_bytes(), (previous_units / unit).read_bytes())

    def test_supported_predecessor_refuses_symlinked_canonical_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            previous, historical = self._historical_predecessor(root)
            canonical = previous / install.SYSTEMD_SOURCE_DIR
            canonical.symlink_to(historical, target_is_directory=True)

            with self.assertRaisesRegex(UpdateError, "systemd source is unsafe"):
                update_unit_migration._systemd_source(
                    previous,
                    allow_supported_predecessor=True,
                )

    def test_supported_predecessor_refuses_regular_file_canonical_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            previous, _historical = self._historical_predecessor(root)
            canonical = previous / install.SYSTEMD_SOURCE_DIR
            canonical.write_text("not a directory\n", encoding="utf-8")

            with self.assertRaisesRegex(UpdateError, "systemd source is unsafe"):
                update_unit_migration._systemd_source(
                    previous,
                    allow_supported_predecessor=True,
                )

    def test_historical_layout_reader_is_limited_to_supported_predecessor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unsupported = root / "0.1.0-dev.14"
            historical_name = "systemd-" + "v" + "2"
            historical = unsupported / historical_name
            historical.mkdir(parents=True)
            for unit in install.SYSTEMD_UNITS:
                (historical / unit).write_text(unit + "\n", encoding="utf-8")
            with self.assertRaisesRegex(UpdateError, "systemd source is missing or unsafe"):
                update_unit_migration._systemd_source(
                    unsupported,
                    allow_supported_predecessor=True,
                )

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
