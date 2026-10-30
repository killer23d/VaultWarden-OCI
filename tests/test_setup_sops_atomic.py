"""Regression coverage for SOPS publication across a tmpfs/root filesystem split."""
from __future__ import annotations

import hashlib
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import setup


class AtomicSopsPublicationTests(unittest.TestCase):
    def test_publication_copies_to_destination_filesystem_before_replace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download = root / "download" / "sops"
            destination = root / "bin" / "sops"
            download.parent.mkdir()
            destination.parent.mkdir()
            payload = b"verified test SOPS executable\n"
            download.write_bytes(payload)
            destination.write_bytes(b"previous version")
            checksum = hashlib.sha256(payload).hexdigest()
            original_replace = os.replace
            calls: list[tuple[Path, Path]] = []

            def enforce_same_destination_tree(source: str | os.PathLike[str], target: str | os.PathLike[str]) -> None:
                """Model an EXDEV host: only destination-local staging may rename."""
                source_path, target_path = Path(source), Path(target)
                self.assertEqual(target_path, destination)
                self.assertEqual(source_path.parent.parent, destination.parent)
                calls.append((source_path, target_path))
                original_replace(source, target)

            with mock.patch.object(setup.os, "replace", side_effect=enforce_same_destination_tree):
                setup._publish_verified_sops(download, checksum, destination=destination)

            self.assertEqual(len(calls), 1)
            self.assertEqual(destination.read_bytes(), payload)
            self.assertEqual(download.read_bytes(), payload)
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o755)
            self.assertEqual({child.name for child in destination.parent.iterdir()}, {"sops"})

    def test_invalid_download_checksum_never_overwrites_existing_binary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download, destination = root / "download", root / "sops"
            download.write_bytes(b"corrupt")
            destination.write_bytes(b"known-good-installed-binary")
            with self.assertRaisesRegex(setup.SetupError, "SHA-256 verification failed"):
                setup._publish_verified_sops(
                    download, hashlib.sha256(b"different").hexdigest(), destination=destination
                )
            self.assertEqual(destination.read_bytes(), b"known-good-installed-binary")
            self.assertEqual({p.name for p in root.iterdir()}, {"download", "sops"})

    def test_corruption_after_copy_preserves_previous_binary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download, destination = root / "download", root / "sops"
            download.write_bytes(b"source")
            destination.write_bytes(b"existing")
            original_sha = setup._sha256
            reads = 0

            def staged_digest(path: Path) -> str:
                nonlocal reads
                reads += 1
                if reads == 2:
                    return hashlib.sha256(b"modified").hexdigest()
                return original_sha(path)

            with mock.patch.object(setup, "_sha256", side_effect=staged_digest):
                with self.assertRaisesRegex(setup.SetupError, "after staging"):
                    setup._publish_verified_sops(
                        download, hashlib.sha256(b"source").hexdigest(), destination=destination
                    )
            self.assertEqual(destination.read_bytes(), b"existing")
            self.assertEqual({p.name for p in root.iterdir()}, {"download", "sops"})


if __name__ == "__main__":
    unittest.main()
