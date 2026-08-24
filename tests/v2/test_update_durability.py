from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import durability, install, update, update_guard, update_recovery


class DurabilityPrimitiveTests(unittest.TestCase):
    def test_atomic_write_fsyncs_parent_after_replace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "state.json"
            real_sync = durability.fsync_directory
            events: list[Path] = []

            def sync(path: Path) -> None:
                events.append(path)
                real_sync(path)

            with mock.patch.object(durability, "fsync_directory", side_effect=sync):
                durability.atomic_write(destination, b"durable\n", 0o600)

            self.assertEqual(destination.read_bytes(), b"durable\n")
            self.assertIn(root, events)
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)

    def test_atomic_symlink_fsyncs_parent_after_replace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = root / "current"
            real_sync = durability.fsync_directory
            events: list[Path] = []

            def sync(path: Path) -> None:
                events.append(path)
                real_sync(path)

            with mock.patch.object(durability, "fsync_directory", side_effect=sync):
                durability.atomic_symlink(current, Path("releases/2.0.0"))

            self.assertTrue(current.is_symlink())
            self.assertEqual(Path(os.readlink(current)), Path("releases/2.0.0"))
            self.assertIn(root, events)

    def test_unlink_fsyncs_parent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "guard"
            path.write_text("guard", encoding="utf-8")
            real_sync = durability.fsync_directory
            events: list[Path] = []

            def sync(parent: Path) -> None:
                events.append(parent)
                real_sync(parent)

            with mock.patch.object(durability, "fsync_directory", side_effect=sync):
                durability.unlink(path)

            self.assertFalse(path.exists())
            self.assertIn(root, events)


class GuardDurabilityTests(unittest.TestCase):
    def test_recovery_artifact_is_durable_before_guard_publication(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "pre.vwrec"
            artifact.write_bytes(b"verified")
            guard = root / "state" / "guard.json"
            events: list[str] = []
            real_artifact_sync = durability.fsync_file_and_parent
            real_replace = durability.replace

            def artifact_sync(path: Path) -> None:
                self.assertEqual(path, artifact)
                events.append("artifact")
                real_artifact_sync(path)

            def replace(source: Path, destination: Path) -> None:
                if destination == guard:
                    events.append("guard")
                real_replace(source, destination)

            with (
                mock.patch.object(durability, "fsync_file_and_parent", side_effect=artifact_sync),
                mock.patch.object(durability, "replace", side_effect=replace),
            ):
                update_guard.engage(
                    candidate_release="2.0.0",
                    previous_release="1.0.0",
                    recovery_artifact=str(artifact),
                    recovery_sha256="a" * 64,
                    path=guard,
                )

            self.assertLess(events.index("artifact"), events.index("guard"))
            self.assertIsNotNone(update_guard.load(path=guard))


class ReleasePublicationTests(unittest.TestCase):
    def test_release_tree_is_synced_before_canonical_rename(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            layout = install.Layout(root / "host")
            events: list[str] = []
            real_sync_tree = durability.fsync_tree
            real_replace = durability.replace

            def copy_tree(_source: Path, staging: Path) -> None:
                (staging / "payload").write_text("release", encoding="utf-8")

            def make_immutable(staging: Path) -> None:
                os.chmod(staging / "payload", 0o444)
                os.chmod(staging, 0o555)

            def sync_tree(path: Path) -> None:
                events.append("tree-fsync")
                real_sync_tree(path)

            def replace(source_path: Path, destination: Path) -> None:
                events.append("publish")
                real_replace(source_path, destination)

            with (
                mock.patch.object(install, "_copy_release_tree", side_effect=copy_tree),
                mock.patch.object(install, "_make_release_immutable", side_effect=make_immutable),
                mock.patch.object(durability, "fsync_tree", side_effect=sync_tree),
                mock.patch.object(durability, "replace", side_effect=replace),
            ):
                release = install._install_release(source, layout, "2.0.0")

            self.assertTrue(release.is_dir())
            self.assertLess(events.index("tree-fsync"), events.index("publish"))


class CurrentPublicationTests(unittest.TestCase):
    def test_shared_switch_uses_durable_symlink_owner(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            layout = install.Layout(Path(directory))
            expected = layout.path(install.CURRENT_LINK)
            with mock.patch.object(durability, "atomic_symlink") as publish:
                update._switch(layout, Path("releases/2.0.0"))
            publish.assert_called_once_with(expected, Path("releases/2.0.0"))


class RecoveryPromotionDurabilityTests(unittest.TestCase):
    def test_all_staged_objects_are_synced_before_first_live_rename(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate_one = root / "candidate-one"
            candidate_two = root / "candidate-two"
            target_one = root / "target-one"
            target_two = root / "target-two"
            candidate_one.write_text("new-one", encoding="utf-8")
            candidate_two.write_text("new-two", encoding="utf-8")
            target_one.write_text("old-one", encoding="utf-8")
            target_two.write_text("old-two", encoding="utf-8")
            events: list[str] = []
            real_tree = durability.fsync_tree
            real_replace = durability.replace
            real_dirs = durability.fsync_directories

            def tree(path: Path) -> None:
                events.append(f"sync:{path.name}")
                real_tree(path)

            def replace(source: Path, destination: Path) -> None:
                events.append(f"replace:{source.name}->{destination.name}")
                real_replace(source, destination)

            def directories(paths) -> None:
                materialized = tuple(paths)
                events.append("target-barrier")
                real_dirs(materialized)

            with (
                mock.patch.object(durability, "fsync_tree", side_effect=tree),
                mock.patch.object(durability, "replace", side_effect=replace),
                mock.patch.object(durability, "fsync_directories", side_effect=directories),
            ):
                update_recovery._promote_with_proven_rollback(
                    ((candidate_one, target_one), (candidate_two, target_two))
                )

            first_replace = min(index for index, event in enumerate(events) if event.startswith("replace:"))
            self.assertLess(events.index("sync:candidate-one"), first_replace)
            self.assertLess(events.index("sync:candidate-two"), first_replace)
            self.assertEqual(target_one.read_text(encoding="utf-8"), "new-one")
            self.assertEqual(target_two.read_text(encoding="utf-8"), "new-two")
            self.assertIn("target-barrier", events)


if __name__ == "__main__":
    unittest.main()
