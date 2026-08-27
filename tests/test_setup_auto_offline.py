from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import recovery_ux, setup_frontend

OFFLINE = "age1" + "q" * 58


class AutoOfflineRecoverySetupTests(unittest.TestCase):
    def test_auto_tty_without_recipient_uses_generated_custody_flow(self) -> None:
        args = [
            "install",
            "--domain",
            "example.net",
            "--url",
            "https://example.net",
            "--email",
            "admin@example.net",
            "--data-device",
            "/dev/vdb",
            "--confirm-format",
            "--auto",
        ]
        with mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True):
            self.assertTrue(setup_frontend._should_generate(args))

    def test_headless_auto_without_recipient_does_not_generate_private_key(self) -> None:
        args = [
            "install",
            "--domain",
            "example.net",
            "--url",
            "https://example.net",
            "--email",
            "admin@example.net",
            "--data-device",
            "/dev/vdb",
            "--confirm-format",
            "--auto",
        ]
        with mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=False):
            self.assertFalse(setup_frontend._should_generate(args))

    def test_auto_tty_generated_identity_enters_existing_recovery_kit_handoff(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / "workspace"
            workspace.mkdir()
            identity = workspace / "offline.age"
            identity.write_text("OFFLINE", encoding="utf-8")
            kit = root / "kit.zip"
            kit.write_bytes(b"encrypted")
            args = [
                "install",
                "--domain",
                "example.net",
                "--url",
                "https://example.net",
                "--email",
                "admin@example.net",
                "--data-device",
                "/dev/vdb",
                "--confirm-format",
                "--auto",
            ]
            with (
                mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True),
                mock.patch.object(
                    setup_frontend,
                    "_generate_offline_identity",
                    return_value=(workspace, identity, OFFLINE),
                ),
                mock.patch.object(setup_frontend.setup, "main", return_value=0) as setup_main,
                mock.patch.object(
                    setup_frontend.recovery_ux,
                    "export_recovery_kit",
                    return_value=recovery_ux.KitResult(kit, recovery_ux.KIT_MEMBERS, False),
                ) as export,
                mock.patch("builtins.input", return_value="SAVED"),
            ):
                self.assertEqual(setup_frontend.main(args), 0)
            setup_main.assert_called_once_with([*args, "--offline-recipient", OFFLINE])
            export.assert_called_once_with(identity)
            self.assertFalse(workspace.exists())
            self.assertFalse(identity.exists())


if __name__ == "__main__":
    unittest.main()
