from __future__ import annotations

import unittest
from unittest import mock

from vaultwarden_oci import admin


PHC = "$argon2id$v=19$m=65540,t=3,p=4$c2FsdA$YWJjZA"


class AdminCredentialTests(unittest.TestCase):
    def test_vaultwarden_phc_uses_tty_without_secret_in_argv_or_output(self) -> None:
        password = "correct-horse-battery-staple"
        completed = mock.Mock(
            returncode=0,
            stdout=(
                "Generate an Argon2id PHC string using the 'bitwarden' preset:\r\n"
                "Password: \r\nConfirm Password: \r\n\r\n"
                f"ADMIN_TOKEN='{PHC}'\r\n"
            ),
            stderr="",
        )
        runner = mock.Mock(return_value=completed)

        value = admin.derive_vaultwarden_admin_phc(
            password,
            "vaultwarden/server:1.37.1@sha256:" + "a" * 64,
            runner=runner,
        )

        self.assertEqual(value, PHC)
        argv = runner.call_args.args[0]
        self.assertNotIn(password, argv)
        self.assertIn("--echo", argv)
        self.assertIn("never", argv)
        self.assertIn("--entrypoint", argv)
        self.assertIn("/vaultwarden", argv)
        self.assertEqual(runner.call_args.kwargs["input"], password + "\n" + password + "\n")
        self.assertFalse(runner.call_args.kwargs["shell"])

    def test_hash_failure_never_repeats_child_output_or_source_secret(self) -> None:
        password = "super-secret-admin-password"
        runner = mock.Mock(return_value=mock.Mock(returncode=1, stdout=password, stderr=password))
        with self.assertRaises(admin.AdminCredentialError) as caught:
            admin.derive_vaultwarden_admin_phc(password, "vaultwarden/server:1.37.1", runner=runner)
        self.assertNotIn(password, str(caught.exception))

    def test_rejects_invalid_phc(self) -> None:
        runner = mock.Mock(return_value=mock.Mock(returncode=0, stdout="ADMIN_TOKEN='plaintext'\n", stderr=""))
        with self.assertRaisesRegex(admin.AdminCredentialError, "invalid Argon2id PHC"):
            admin.derive_vaultwarden_admin_phc("long-enough-secret", "vaultwarden/server:1.37.1", runner=runner)


if __name__ == "__main__":
    unittest.main()
