from __future__ import annotations

import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from vaultwarden_oci import admin, secrets


PHC = "$argon2id$v=19$m=65540,t=3,p=4$c2FsdA$YWJjZA"


def done(*, code: int = 0, stdout: str = "", stderr: str = ""):
    return mock.Mock(returncode=code, stdout=stdout, stderr=stderr)


def admin_values(token: str) -> dict[str, str]:
    return {
        "cloudflare_api_token": "A" * 40,
        "smtp_username": "smtp-user",
        "smtp_password": "smtp-password",
        "vaultwarden_admin_token": token,
        "admin_basic_auth_password": "outer-admin-password",
    }


class AdminCredentialTests(unittest.TestCase):
    def test_source_validator_rejects_unsafe_pty_values_and_excessive_length(self) -> None:
        self.assertEqual(
            admin.validate_vaultwarden_admin_source("valid-admin-password"),
            "valid-admin-password",
        )
        invalid = (
            "short",
            "valid-admin\x03password",
            "valid-admin\x04password",
            "valid-admin\x7fpassword",
            "valid-admin\x85password",
            "x" * 257,
        )
        for value in invalid:
            with self.subTest(repr=repr(value)):
                with self.assertRaisesRegex(
                    admin.AdminCredentialError,
                    "8-256 printable characters with no control characters",
                ):
                    admin.validate_vaultwarden_admin_source(value)

    def test_runtime_hash_rejects_invalid_source_before_any_image_or_pty_command(self) -> None:
        runner = mock.Mock(side_effect=AssertionError("runner must not be called"))
        with self.assertRaisesRegex(admin.AdminCredentialError, "8-256 printable characters"):
            admin.derive_vaultwarden_admin_phc(
                "unsafe\x04admin-password",
                "vaultwarden/server:1.37.1",
                runner=runner,
            )
        runner.assert_not_called()

    def test_sops_validation_uses_same_admin_source_policy(self) -> None:
        with mock.patch(
            "vaultwarden_oci.secrets.load",
            return_value=admin_values("abc"),
        ):
            with self.assertRaisesRegex(secrets.SecretsError, "8-256 printable characters"):
                secrets.validate_encrypted("age1" + "a" * 58)

    def test_sops_edit_does_not_commit_admin_source_rejected_by_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            encrypted = root / "secrets.sops.yaml"
            age_key = root / "age-key.txt"
            encrypted.write_text("stable-encrypted", encoding="utf-8")
            age_key.write_text("AGE-SECRET-KEY-TEST", encoding="utf-8")
            paths = secrets.SecretPaths(
                encrypted=encrypted,
                age_key=age_key,
                root=root / "run",
                vaultwarden=root / "run/vaultwarden",
                caddy=root / "run/caddy",
            )

            def editor(argv, check=False, env=None):
                Path(argv[-1]).write_text("candidate-encrypted", encoding="utf-8")
                return mock.Mock(returncode=0)

            with (
                mock.patch("vaultwarden_oci.secrets.subprocess.run", side_effect=editor),
                mock.patch(
                    "vaultwarden_oci.secrets.load",
                    return_value=admin_values("unsafe\x04admin-password"),
                ),
            ):
                with self.assertRaisesRegex(secrets.SecretsError, "8-256 printable characters"):
                    secrets.edit_encrypted(
                        "age1" + "a" * 58,
                        paths=paths,
                        editor=("sops",),
                        lock_path=root / "lock",
                    )

            self.assertEqual(encrypted.read_text(encoding="utf-8"), "stable-encrypted")

    def test_vaultwarden_phc_uses_constrained_tty_without_secret_in_argv(self) -> None:
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
        self.assertIn("--network none", child)
        self.assertIn("--read-only", child)
        self.assertIn("--cap-drop ALL", child)
        self.assertIn("--security-opt no-new-privileges:true", child)
        self.assertIn("--pids-limit 50", child)
        self.assertIn("--memory 256m", child)
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
