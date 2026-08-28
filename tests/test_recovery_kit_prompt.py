from __future__ import annotations

import contextlib
import io
import json
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import recovery_ux


class RecoveryKitPassphrasePromptTests(unittest.TestCase):
    def test_invalid_passphrases_reprompt_until_valid_pair(self) -> None:
        short = "too-short"
        mismatch_first = "a" * 16
        mismatch_second = "b" * 16
        valid = "correct horse battery staple"
        answers = [short, short, mismatch_first, mismatch_second, valid, valid]
        output = io.StringIO()

        with (
            mock.patch.object(recovery_ux.getpass, "getpass", side_effect=answers) as prompt,
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(recovery_ux._prompt_passphrase(), (valid, valid))

        self.assertEqual(prompt.call_count, 6)
        text = output.getvalue()
        self.assertIn(
            "WARN recovery-kit ZIP passphrase must be at least 16 characters; try again or press Ctrl+C to cancel",
            text,
        )
        self.assertIn(
            "WARN recovery-kit ZIP passphrases do not match; try again or press Ctrl+C to cancel",
            text,
        )

    def test_ctrl_c_remains_explicit_cancel(self) -> None:
        with (
            mock.patch.object(recovery_ux.getpass, "getpass", side_effect=KeyboardInterrupt),
            self.assertRaises(KeyboardInterrupt),
        ):
            recovery_ux._prompt_passphrase()


class RecoveryKitOptionalSecretTests(unittest.TestCase):
    def test_known_optional_empty_fields_are_omitted(self) -> None:
        payload = {
            "cloudflare_api_token": "cfut_" + "a" * 32,
            "cloudflare_remediation_token": "",
            "smtp_username": "smtp-user",
            "smtp_password": "smtp-pass",
            "email_api_token": "",
            "vaultwarden_admin_token": "",
            "admin_basic_auth_password": "",
        }

        def runner(argv, *, env=None):
            del argv, env
            return mock.Mock(ok=True, stdout=json.dumps(payload))

        values = recovery_ux._decrypt_all_sops(
            Path("/tmp/secrets.sops.yaml"),
            Path("/tmp/offline.age"),
            runner=runner,
        )

        self.assertEqual(
            values,
            {
                "cloudflare_api_token": payload["cloudflare_api_token"],
                "smtp_username": "smtp-user",
                "smtp_password": "smtp-pass",
            },
        )


if __name__ == "__main__":
    unittest.main()
