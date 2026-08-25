from __future__ import annotations

import unittest
from unittest import mock

from vaultwarden_oci import update_cli


class Day2HelpRoutingTests(unittest.TestCase):
    def test_public_help_never_requires_storage_or_update_recovery_clearance(self) -> None:
        for argv in (
            ["start", "--help"],
            ["edge", "--help"],
            ["crowdsec", "--help"],
            ["notification", "--help"],
            ["config", "--help"],
            ["secrets", "--help"],
            ["timers", "--help"],
            ["support-bundle", "--help"],
        ):
            with self.subTest(argv=argv):
                with (
                    mock.patch("vaultwarden_oci.update_cli._require_storage") as storage,
                    mock.patch("vaultwarden_oci.update_cli._guard_error") as guard,
                    mock.patch("vaultwarden_oci.update_cli.cli.main", return_value=0) as routed,
                ):
                    self.assertEqual(update_cli.main(argv), 0)
                storage.assert_not_called()
                guard.assert_not_called()
                routed.assert_called_once_with(argv)


if __name__ == "__main__":
    unittest.main()
