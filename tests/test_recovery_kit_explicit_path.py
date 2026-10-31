"""Acceptance regression: import an existing encrypted recovery kit by an explicit path."""
from __future__ import annotations

import contextlib
import io
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import recovery_ux

RECIPIENT = "age1" + "q" * 58


class ExplicitRecoveryKitIdentityTests(unittest.TestCase):
    def test_encrypted_zip_outside_root_publication_directory_is_staged_and_cleaned(self) -> None:
        secret_passphrase = "separately-held-kit-passphrase"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "ubuntu-home" / "original-email-handoff.zip"
            source.parent.mkdir()
            source.write_bytes(b"ENCRYPTED-ZIP-FOR-TEST-ONLY")
            source.chmod(0o600)
            sensitive = root / "run"
            output = io.StringIO()
            selected: list[Path] = []

            def fake_verify(archive, passphrase, *, expected_members):
                self.assertNotEqual(Path(archive), source)
                self.assertEqual(Path(archive).read_bytes(), source.read_bytes())
                self.assertEqual(stat.S_IMODE(Path(archive).stat().st_mode), 0o600)
                self.assertEqual(passphrase, secret_passphrase)
                self.assertEqual(tuple(expected_members), recovery_ux.KIT_MEMBERS)
                self.assertEqual(Path(archive).parent.parent, sensitive)
                selected.append(Path(archive))

            def fake_seven(argv, *, password_input, cwd=None):
                del cwd
                self.assertEqual(password_input, secret_passphrase)
                self.assertNotIn(secret_passphrase, " ".join(argv))
                workspace = Path(next(x[2:] for x in argv if x.startswith("-o")))
                (workspace / recovery_ux.OFFLINE_IDENTITY_MEMBER).write_text(
                    "AGE-SECRET-KEY-1EXPLICIT\n", encoding="utf-8",
                )
                return mock.Mock(returncode=0, stdout="", stderr="")

            answers = iter(["3", "4", str(source)])
            with (
                mock.patch("builtins.input", side_effect=lambda _="": next(answers)),
                mock.patch.object(recovery_ux.getpass, "getpass", return_value=secret_passphrase),
                mock.patch.object(recovery_ux, "_interactive_tty", return_value=True),
                mock.patch.object(recovery_ux, "verify_zip", side_effect=fake_verify),
                mock.patch.object(recovery_ux, "_seven", side_effect=fake_seven),
                mock.patch.object(recovery_ux.secrets, "derive_recipient", return_value=RECIPIENT),
                contextlib.redirect_stdout(output),
            ):
                with recovery_ux.acquire_offline_identity(
                    RECIPIENT,
                    publication_dir=root / "empty-kit-index",
                    sensitive_root=sensitive,
                    ui=recovery_ux.UI(color=False),
                ) as identity:
                    self.assertIsNotNone(identity)
                    assert identity is not None
                    self.assertEqual(stat.S_IMODE(identity.stat().st_mode), 0o600)
                    self.assertTrue(identity.exists())
            self.assertEqual(len(selected), 1)
            self.assertFalse(selected[0].exists())
            self.assertFalse(list(sensitive.glob("offline-identity-*")))
            self.assertTrue(source.exists())
            self.assertEqual(source.read_bytes(), b"ENCRYPTED-ZIP-FOR-TEST-ONLY")
            self.assertIn("choose 4 to enter a ZIP path", output.getvalue())
            self.assertNotIn(secret_passphrase, output.getvalue())

    def test_missing_or_insecure_explicit_source_refused_without_cryptographic_prompt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            secure = root / "secure.zip"
            secure.write_bytes(b"encrypted")
            secure.chmod(0o600)
            loose = root / "loose.zip"
            loose.write_bytes(b"not private")
            loose.chmod(0o644)
            symlink = root / "link.zip"
            symlink.symlink_to(secure)
            huge = root / "too-large.zip"
            with huge.open("wb") as f:
                f.truncate(16 * 1024 * 1024 + 1)
            huge.chmod(0o600)
            invalid = ("relative.zip", str(root / "missing.zip"), str(loose), str(symlink), str(huge))
            for choice in invalid:
                with self.subTest(source=choice):
                    answers = iter(["4", choice])
                    with (
                        mock.patch("builtins.input", side_effect=lambda _="": next(answers)),
                        mock.patch.object(recovery_ux, "_interactive_tty", return_value=True),
                        mock.patch.object(recovery_ux.getpass, "getpass") as prompt,
                        self.assertRaises((recovery_ux.RecoveryUXError, OSError)),
                    ):
                        with recovery_ux.acquire_offline_identity(
                            RECIPIENT,
                            sensitive_root=root / "run",
                            ui=recovery_ux.UI(color=False),
                        ):
                            self.fail("untrusted ZIP must never yield a private identity")
                    prompt.assert_not_called()
                    self.assertEqual(list((root / "run").glob("offline-identity-*")), [])
            self.assertTrue(secure.exists())

    def test_explicit_zip_path_cancel_does_not_write_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            answers = iter(["4", "q"])
            with (
                mock.patch("builtins.input", side_effect=lambda _="": next(answers)),
                mock.patch.object(recovery_ux, "_interactive_tty", return_value=True),
                mock.patch.object(recovery_ux.getpass, "getpass") as prompt,
            ):
                with recovery_ux.acquire_offline_identity(
                    RECIPIENT,
                    sensitive_root=root / "run",
                    ui=recovery_ux.UI(color=False),
                ) as identity:
                    self.assertIsNone(identity)
            prompt.assert_not_called()
            self.assertFalse((root / "run").exists())


if __name__ == "__main__":
    unittest.main()
