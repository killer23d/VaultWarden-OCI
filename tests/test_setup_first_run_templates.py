from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import setup


class FirstRunCredentialTemplateTests(unittest.TestCase):
    def test_generated_config_explains_every_required_smtp_field(self) -> None:
        text = setup._config_text(
            "vault.example.com",
            "admin@example.com",
            "age1" + "q" * 58,
        )
        setup._validate_config_text(text)
        self.assertIn('host = "smtp.invalid"', text)
        self.assertIn('port = 587', text)
        self.assertIn('security = "starttls"', text)
        self.assertIn('from_email = "vaultwarden@vault.example.com"', text)
        self.assertIn('from_name = "Vaultwarden"', text)
        self.assertIn('timeout_seconds = 15', text)
        self.assertIn("smtp_username and smtp_password", text)
        self.assertIn("Allowed values", text)

    def test_initial_sops_plaintext_prepopulates_required_external_keys_as_empty(self) -> None:
        offline = "age1" + "q" * 58
        operational = "age1" + "p" * 58
        captured: dict[str, str] = {}

        with tempfile.TemporaryDirectory() as directory:
            encrypted = Path(directory) / "secrets.sops.yaml"

            def fake_must(argv, label, *, input_text=None, env=None):
                del argv, label, env
                captured["plaintext"] = input_text or ""

                class Done:
                    stdout = "sops:\n  age: []\n"

                return Done()

            with (
                mock.patch.object(setup, "ENCRYPTED", encrypted),
                mock.patch.object(setup, "_must", side_effect=fake_must),
                mock.patch.object(setup, "_validate_existing_secrets"),
            ):
                setup._ensure_secret_start(operational, offline)

        values = json.loads(captured["plaintext"])
        self.assertEqual(values["cloudflare_api_token"], "")
        self.assertEqual(values["smtp_username"], "")
        self.assertEqual(values["smtp_password"], "")
        self.assertTrue(values["vaultwarden_admin_token"])
        self.assertTrue(values["admin_basic_auth_password"])


if __name__ == "__main__":
    unittest.main()
