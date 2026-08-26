from __future__ import annotations

import io
import tarfile
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, day2


class SupportBundleRedactionRegressionTests(unittest.TestCase):
    @staticmethod
    def command_result(argv) -> cli.CommandResult:
        return cli.CommandResult(tuple(argv), "success", 0, "safe output\n", "")

    @staticmethod
    def base_status() -> dict[str, object]:
        return {
            "doctor": {"overall": "PASS", "checks": []},
            "timers": [],
        }

    @staticmethod
    def archive_text(path: Path) -> tuple[set[str], str]:
        with tarfile.open(path, "r:gz") as archive:
            names = set(archive.getnames())
            chunks: list[str] = []
            for name in sorted(names):
                extracted = archive.extractfile(name)
                if extracted is not None:
                    chunks.append(extracted.read().decode("utf-8"))
        return names, "\n".join(chunks)

    def test_archive_redacts_entire_bearer_and_basic_authorization_values(self) -> None:
        bearer = "abc.def.ghi"
        basic = "YWRtaW46c2VjcmV0"
        configured = "configured-secret-value"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "bundle.tar.gz"
            with (
                mock.patch("vaultwarden_oci.day2.SUPPORT_ROOT", root / "support"),
                mock.patch("vaultwarden_oci.day2.os.geteuid", return_value=0),
                mock.patch("vaultwarden_oci.day2._known_secret_values", return_value=([configured], None)),
                mock.patch("vaultwarden_oci.day2.status_payload", return_value=self.base_status()),
                mock.patch("vaultwarden_oci.day2._versions_text", return_value="versions safe\n"),
                mock.patch(
                    "vaultwarden_oci.day2._bounded_journal",
                    return_value=(
                        f"Authorization: Bearer {bearer}\n"
                        f"Authorization: Basic {basic}\n"
                        f"token={configured}\n"
                        "ordinary log line\n"
                    ),
                ),
                mock.patch(
                    "vaultwarden_oci.day2.cli.run_command",
                    side_effect=lambda argv: self.command_result(argv),
                ),
                redirect_stdout(io.StringIO()),
            ):
                day2.support_bundle(output)

            names, content = self.archive_text(output)
            self.assertIn("journal.txt", names)
            self.assertNotIn(bearer, content)
            self.assertNotIn(basic, content)
            self.assertNotIn(configured, content)
            self.assertGreaterEqual(content.count("Authorization: [REDACTED]"), 2)

    def test_short_canonical_secret_omits_journal_end_to_end(self) -> None:
        short_secret = "tok"
        loaded = {
            "cloudflare_api_token": "A" * 35,
            "smtp_username": "mailer",
            "smtp_password": "long-smtp-password",
            "email_api_token": short_secret,
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "bundle.tar.gz"
            journal = mock.Mock(return_value=f"unlabeled secret value {short_secret}\n")
            with (
                mock.patch("vaultwarden_oci.day2.SUPPORT_ROOT", root / "support"),
                mock.patch("vaultwarden_oci.day2.os.geteuid", return_value=0),
                mock.patch(
                    "vaultwarden_oci.day2.runtime.load_config",
                    return_value=mock.Mock(offline_recovery_recipient="age1" + "q" * 58),
                ),
                mock.patch("vaultwarden_oci.day2.secrets.load", return_value=loaded),
                mock.patch("vaultwarden_oci.day2.status_payload", return_value=self.base_status()),
                mock.patch("vaultwarden_oci.day2._versions_text", return_value="versions safe\n"),
                mock.patch("vaultwarden_oci.day2._bounded_journal", journal),
                mock.patch(
                    "vaultwarden_oci.day2.cli.run_command",
                    side_effect=lambda argv: self.command_result(argv),
                ),
                redirect_stdout(io.StringIO()),
            ):
                day2.support_bundle(output)

            journal.assert_not_called()
            names, content = self.archive_text(output)
            self.assertIn("journal-omitted.txt", names)
            self.assertNotIn("journal.txt", names)
            self.assertNotIn(short_secret, content)
            self.assertIn("could not be safely prepared", content)


if __name__ == "__main__":
    unittest.main()
