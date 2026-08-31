from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import update_controller_handoff


class UpdateControllerSourceCheckoutTests(unittest.TestCase):
    def test_source_checkout_without_installed_launcher_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.object(update_controller_handoff.os, "execv") as execv:
                self.assertFalse(
                    update_controller_handoff.delegate_non_update_if_handoff(
                        ["doctor", "--json"],
                        root=root,
                        controller_vwctl=root / "source" / "vwctl",
                    )
                )
                execv.assert_not_called()


if __name__ == "__main__":
    unittest.main()
