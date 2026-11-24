from __future__ import annotations

import io
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from vaultwarden_oci import setup, setup_frontend

OFFLINE = "age1" + "q" * 58
SITE = ["--domain=example.net", "--url=https://vault.example.net", "--email=admin@example.net"]


class GuidedSiteInputTests(unittest.TestCase):
    def test_all_missing_site_values_use_existing_owner(self):
        args = ["install", "--offline-recipient=" + OFFLINE]
        with (
            mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True),
            mock.patch("builtins.input", side_effect=["example.net", "https://vault.example.net", "admin@example.net"]),
            mock.patch.object(setup, "main", return_value=0) as owner,
            mock.patch.object(setup_frontend, "_generate_offline_identity") as generate,
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(setup_frontend.main(args), 0)
        owner.assert_called_once_with(args + SITE, defer_next_actions=True)
        generate.assert_not_called()
        parsed = setup._parser().parse_args(owner.call_args.args[0])
        self.assertFalse(parsed.confirm_format)
        self.assertFalse(parsed.accept_existing_filesystem)
        self.assertEqual(parsed.offline_recipient, OFFLINE)

    def test_partial_arguments_and_abbreviated_recipient_preserved(self):
        args = ["install", "--dom=example.net", "--offline-recip=" + OFFLINE,
                "--email", "admin@example.net", "--accept-existing-filesystem"]
        with (
            mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True),
            mock.patch("builtins.input", return_value="https://vault.example.net") as prompt,
            redirect_stdout(io.StringIO()),
        ):
            result = setup_frontend._collect_site_args(args)
        self.assertEqual(result, args + ["--url=https://vault.example.net"])
        prompt.assert_called_once()
        parsed = setup._parser().parse_args(result)
        self.assertEqual(parsed.offline_recipient, OFFLINE)
        self.assertTrue(parsed.accept_existing_filesystem)
        self.assertFalse(parsed.confirm_format)

    def test_complete_site_arguments_never_prompt(self):
        args = ["install", *SITE]
        with (
            mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True),
            mock.patch("builtins.input") as prompt,
        ):
            self.assertEqual(setup_frontend._collect_site_args(args), args)
        prompt.assert_not_called()

    def test_auto_dry_run_and_headless_keep_required_argument_contract(self):
        for tty, args in ((True, ["install", "--auto"]), (True, ["install", "--dry-run"]),
                          (False, ["install"]), (False, ["install", "--auto"])):
            with self.subTest(tty=tty, args=args), (
                mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=tty),
                mock.patch("builtins.input") as prompt,
                mock.patch.object(setup.storage, "provision") as provision,
                mock.patch.object(setup_frontend, "_generate_offline_identity") as generate,
                redirect_stderr(io.StringIO()),
            ):
                with self.assertRaises(SystemExit) as raised:
                    setup_frontend.main(args)
                self.assertEqual(raised.exception.code, 2)
                prompt.assert_not_called()
                provision.assert_not_called()
                generate.assert_not_called()

    def test_cancel_before_any_install_owner_call(self):
        for side_effect in ([""], EOFError, KeyboardInterrupt):
            with self.subTest(response=side_effect), (
                mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True),
                mock.patch("builtins.input", side_effect=side_effect),
                mock.patch.object(setup, "main") as owner,
                mock.patch.object(setup_frontend, "_generate_offline_identity") as generate,
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()),
            ):
                self.assertEqual(setup_frontend.main(["install"]), 2)
                owner.assert_not_called()
                generate.assert_not_called()

    def test_invalid_site_input_rejected_before_any_install_owner_call(self):
        for values in (["example.net", "http://vault.example.net", "admin@example.net"],
                       ["example.net", "https://other.example.net", "admin@example.net"],
                       ["example.net", "https://vault.example.net", "bad-email"],
                       ["example.net", "https://vault.example.net:invalid", "admin@example.net"]):
            with self.subTest(values=values), (
                mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True),
                mock.patch("builtins.input", side_effect=values),
                mock.patch.object(setup, "main") as owner,
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()),
            ):
                self.assertEqual(setup_frontend.main(["install"]), 1)
                owner.assert_not_called()

    def test_explicit_empty_site_value_is_not_replaced(self):
        args = ["install", "--domain=", "--url=https://vault.example.net"]
        with (
            mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True),
            mock.patch("builtins.input", return_value="admin@example.net") as prompt,
            mock.patch.object(setup, "main") as owner,
            redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(setup_frontend.main(args), 1)
        prompt.assert_called_once()
        owner.assert_not_called()

    def test_use_latest_confirmation_still_precedes_owner(self):
        with (
            mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True),
            mock.patch("builtins.input", side_effect=["example.net", "https://vault.example.net", "admin@example.net", "n"]),
            mock.patch.object(setup, "main") as owner,
            redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(setup_frontend.main(["install", "--use-lat"]), 2)
        owner.assert_not_called()

    def test_unknown_argument_does_not_trigger_prompt(self):
        with (
            mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True),
            mock.patch("builtins.input") as prompt,
            redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()),
        ):
            with self.assertRaises(SystemExit):
                setup_frontend.main(["install", "--not-a-real-option"])
        prompt.assert_not_called()


class GeneratedCustodyGuardTests(unittest.TestCase):
    def test_existing_or_uncertain_custody_blocks_before_setup_owner(self):
        for artifact in ("config", "encrypted", "workspace", "workspace-link", "config-link"):
            with self.subTest(artifact=artifact), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                config, encrypted, run = root / "config", root / "encrypted", root / "run"
                run.mkdir()
                if artifact == "config":
                    config.write_text("existing")
                elif artifact == "encrypted":
                    encrypted.write_text("existing")
                elif artifact == "workspace":
                    (run / "setup-offline-recovery-retained").mkdir()
                elif artifact == "workspace-link":
                    (run / "setup-offline-recovery-retained").symlink_to(root / "missing")
                else:
                    config.symlink_to(root / "missing")
                before = sorted(str(p) for p in root.rglob("*"))
                with (
                    mock.patch.object(setup, "CONFIG", config),
                    mock.patch.object(setup, "ENCRYPTED", encrypted),
                    mock.patch.object(setup_frontend, "SENSITIVE_RUN", run),
                    mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True),
                    mock.patch.object(setup, "main") as owner,
                    mock.patch.object(setup_frontend, "_generate_offline_identity") as generate,
                    redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()),
                ):
                    self.assertEqual(setup_frontend.main(["install", *SITE]), 1)
                owner.assert_not_called()
                generate.assert_not_called()
                self.assertEqual(before, sorted(str(p) for p in root.rglob("*")))

    def test_blank_custody_passes_guard_without_creating_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with (
                mock.patch.object(setup, "CONFIG", root / "config"),
                mock.patch.object(setup, "ENCRYPTED", root / "encrypted"),
                mock.patch.object(setup_frontend, "SENSITIVE_RUN", root / "run"),
            ):
                setup_frontend._require_new_custody()
            self.assertEqual(list(root.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
