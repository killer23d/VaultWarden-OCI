from __future__ import annotations

import io
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from vaultwarden_oci import recovery_ux, setup, setup_frontend


class SetupFrontendColorTests(unittest.TestCase):
    def test_use_latest_warning_uses_shared_colored_ui(self) -> None:
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
            "--use-latest",
            "--auto",
        ]
        stderr = io.StringIO()
        with (
            mock.patch.object(setup_frontend, "_ui", return_value=setup.UI(color=True)),
            redirect_stderr(stderr),
        ):
            self.assertTrue(setup_frontend._confirm_use_latest(args))
        self.assertIn("\x1b[33mWARN\x1b[0m", stderr.getvalue())

    def test_local_handoff_action_and_info_labels_are_colored(self) -> None:
        result = recovery_ux.KitResult(Path("/tmp/recovery-kit.zip"), recovery_ux.KIT_MEMBERS, False)
        stdout = io.StringIO()
        with (
            mock.patch.object(setup_frontend, "_ui", return_value=setup.UI(color=True)),
            mock.patch("builtins.input", return_value="SAVED"),
            redirect_stdout(stdout),
        ):
            setup_frontend._confirm_local_handoff(result)
        text = stdout.getvalue()
        self.assertIn("\x1b[34mACTION\x1b[0m", text)
        self.assertIn("\x1b[36mINFO\x1b[0m", text)


if __name__ == "__main__":
    unittest.main()
