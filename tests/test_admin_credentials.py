from __future__ import annotations

import io
import unittest
from contextlib import redirect_stdout
from unittest import mock

from vaultwarden_oci import admin


PHC = "$argon2id$v=19$m=65540,t=3,p=4$c2FsdA$YWJjZA"


def done(*, code: int = 0, stdout: str = "", stderr: str = ""):
    return mock.Mock(returncode=code, stdout=stdout, stderr=stderr)


class AdminCredentialTests(unittest.TestCase):
    def test_vaultwarden_phc_uses_tty_without_secret_in_argv_or_output(self) -> None:
        password = "correct-horse-battery-staple"
        image = "vaultwarden/server:1.37.1@sha256:" + "a" * 64
        hash_result = done(
            stdout=(
                "Generate an Argon2id PHC string using the 'bitwarden' preset:\r\n"
                "Password: \r\nConfirm Password: \r\n\r\n"
                f"ADMIN_TOKEN='{PHC}'\r\n"
            )
        )
        calls = []

        def runner(argv, **kwargs):
            calls.append((list(argv), kwargs))
            if argv[:3] == ["docker", "image", "inspect"]:
                return done()
            if argv[0] == "script":
                return hash_result
            raise AssertionError(argv)

        value = admin.derive_vaultwarden_admin_phc(password, image, runner=runner)

        self.assertEqual(value, PHC)
        argv, kwargs = calls[-1]
        self.assertNotIn(password, argv)
        self.assertIn("--echo", argv)
        self.assertIn("never", argv)
        self.assertIn("--command", argv)
        child = argv[argv.index("--command") + 1]
        self.assertNotIn(password, child)
        self.assertIn("--entrypoint /vaultwarden", child)
        self.assertIn(image, child)
        self.assertIn("hash --preset bitwarden", child)
        self.assertEqual(kwargs["input"], password + "\n" + password + "\n")
        self.assertFalse(kwargs["shell"])

    def test_missing_exact_image_pull_is_visible_and_not_captured(self) -> None:
        image = "vaultwarden/server:1.37.1@sha256:" + "a" * 64
        calls = []

        def runner(argv, **kwargs):
            calls.append((list(argv), kwargs))
            if argv[:3] == ["docker", "image", "inspect"]:
                return done(code=1)
            if argv[:2] == ["docker", "pull"]:
                return done()
            if argv[0] == "script":
                return done(stdout=f"ADMIN_TOKEN='{PHC}'\n")
            raise AssertionError(argv)

        output = io.StringIO()
        with redirect_stdout(output):
            admin.derive_vaultwarden_admin_phc("long-enough-secret", image, runner=runner)

        self.assertIn("pulling it before admin credential derivation", output.getvalue())
        pull_kwargs = next(kwargs for argv, kwargs in calls if argv[:2] == ["docker", "pull"])
        self.assertNotIn("capture_output", pull_kwargs)

    def test_hash_failure_never_repeats_child_output_or_source_secret(self) -> None:
        password = "super-secret-admin-password"

        def runner(argv, **kwargs):
            if argv[:3] == ["docker", "image", "inspect"]:
                return done()
            return done(code=1, stdout=password, stderr=password)

        with self.assertRaises(admin.AdminCredentialError) as caught:
            admin.derive_vaultwarden_admin_phc(password, "vaultwarden/server:1.37.1", runner=runner)
        self.assertNotIn(password, str(caught.exception))

    def test_rejects_invalid_phc(self) -> None:
        def runner(argv, **kwargs):
            if argv[:3] == ["docker", "image", "inspect"]:
                return done()
            return done(stdout="ADMIN_TOKEN='plaintext'\n")

        with self.assertRaisesRegex(admin.AdminCredentialError, "invalid Argon2id PHC"):
            admin.derive_vaultwarden_admin_phc("long-enough-secret", "vaultwarden/server:1.37.1", runner=runner)


if __name__ == "__main__":
    unittest.main()
