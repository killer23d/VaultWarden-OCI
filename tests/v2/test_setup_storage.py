from __future__ import annotations

import json
import os
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest import mock

from vaultwarden_oci import setup, storage, update_cli


class FakeResult(storage.CommandResult):
    pass


def result(argv, stdout="", rc=0, stderr=""):
    return storage.CommandResult(tuple(argv), rc, stdout, stderr)


class StorageContractTests(unittest.TestCase):
    def test_boot_device_and_parent_are_rejected(self) -> None:
        def runner(argv):
            command = list(argv)
            if command[:4] == ["findmnt", "-n", "-o", "SOURCE"]:
                return result(argv, "/dev/vda1\n")
            if command[0] == "lsblk" and "-s" in command:
                dev = command[-1]
                return result(argv, f"{dev}\n/dev/vda\n" if dev == "/dev/vda1" else f"{dev}\n")
            if command[0] == "lsblk" and "-r" in command:
                dev = command[-1]
                return result(argv, "/dev/vda\n/dev/vda1\n" if dev == "/dev/vda" else f"{dev}\n")
            raise AssertionError(command)
        with mock.patch.object(storage, "_real_device", side_effect=lambda value: value):
            with self.assertRaisesRegex(storage.StorageError, "boot/root"):
                storage.reject_boot_related("/dev/vda", runner=runner)

    def test_separate_device_is_accepted_by_boot_lineage_gate(self) -> None:
        def runner(argv):
            command = list(argv)
            if command[0] == "findmnt":
                return result(argv, "/dev/vda1\n")
            if command[0] == "lsblk":
                dev = command[-1]
                if dev == "/dev/vda1":
                    return result(argv, "/dev/vda1\n/dev/vda\n")
                if dev == "/dev/vda":
                    return result(argv, "/dev/vda\n/dev/vda1\n")
                return result(argv, f"{dev}\n")
            raise AssertionError(command)
        with mock.patch.object(storage, "_real_device", side_effect=lambda value: value):
            storage.reject_boot_related("/dev/vdb", runner=runner)

    def test_missing_mount_and_wrong_identity_fail_closed(self) -> None:
        with mock.patch.object(storage.Path, "is_mount", return_value=False):
            with self.assertRaisesRegex(storage.StorageError, "mount is absent"):
                storage.verify()
        actual = storage.StorageIdentity("aaaa-bbbb", "ext4", "/dev/vdb")
        expected = storage.StorageIdentity("cccc-dddd", "ext4", "/dev/vdb")
        with mock.patch.object(storage, "_identity_from_mount", return_value=actual), mock.patch.object(storage, "load_identity", return_value=expected):
            with self.assertRaisesRegex(storage.StorageError, "wrong filesystem"):
                storage.verify()

    def test_existing_filesystem_and_blank_format_need_separate_acknowledgements(self) -> None:
        with mock.patch.object(storage, "_real_device", side_effect=lambda value: value), mock.patch.object(storage, "reject_boot_related"), mock.patch.object(storage, "_blkid", side_effect=["ext4", "abcd-1234"]):
            def existing_runner(argv):
                if argv[0] == "lsblk": return result(argv, "disk\n")
                return result(argv)
            with self.assertRaisesRegex(storage.StorageError, "acknowledgement"):
                storage.provision("/dev/vdb", interactive=False, runner=existing_runner)

        with mock.patch.object(storage, "_real_device", side_effect=lambda value: value), mock.patch.object(storage, "reject_boot_related"), mock.patch.object(storage, "_blkid", return_value=""):
            def blank_runner(argv):
                if argv[0] == "lsblk": return result(argv, "disk\n")
                if argv[0] == "wipefs": return result(argv, "")
                return result(argv)
            with self.assertRaisesRegex(storage.StorageError, "acknowledgement"):
                storage.provision("/dev/vdb", interactive=False, runner=blank_runner)

    def test_auto_does_not_guess_storage(self) -> None:
        args = Namespace(data_mount=str(storage.STATE_ROOT), data_device=None, auto=True)
        with self.assertRaisesRegex(setup.SetupError, "requires --data-device"):
            setup._select_storage(args, setup.UI(color=False))

    def test_docker_guard_requires_canonical_mount(self) -> None:
        identity = storage.StorageIdentity("abcd-1234", "ext4", "/dev/vdb")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "guard.conf"
            storage.ensure_docker_guard(identity, path=path)
            text = path.read_text(encoding="utf-8")
            self.assertIn(f"RequiresMountsFor={storage.STATE_ROOT}", text)
            self.assertIn(f"ConditionPathIsMountPoint={storage.STATE_ROOT}", text)


class SetupContractTests(unittest.TestCase):
    def test_domain_url_email_normalization_has_one_url_authority(self) -> None:
        host, url, email = setup._normalize("Example.COM.", "https://vault.example.com/", "admin@example.com")
        self.assertEqual(host, "vault.example.com")
        self.assertEqual(url, "https://vault.example.com")
        self.assertEqual(email, "admin@example.com")
        text = setup._config_text(host, email, "age1" + "q" * 58)
        self.assertIn('domain = "vault.example.com"', text)
        self.assertNotIn("https://vault.example.com", text)

    def test_mismatched_url_is_rejected(self) -> None:
        with self.assertRaisesRegex(setup.SetupError, "hostname must equal"):
            setup._normalize("example.com", "https://other.example.net", "admin@example.com")

    def test_config_rerun_is_idempotent_and_does_not_overwrite_operator_changes(self) -> None:
        offline = "age1" + "q" * 58
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            desired = setup._config_text("vault.example.com", "admin@example.com", offline)
            path.write_text(desired, encoding="utf-8")
            with mock.patch.object(setup, "CONFIG", path):
                setup._ensure_config("vault.example.com", "admin@example.com", offline)
                path.write_text(desired.replace("signups_allowed = false", "signups_allowed = true"), encoding="utf-8")
                with self.assertRaisesRegex(setup.SetupError, "differs"):
                    setup._ensure_config("vault.example.com", "admin@example.com", offline)

    def test_secret_plaintext_is_stdin_only_not_argv(self) -> None:
        offline = "age1" + "q" * 58
        operational = "age1" + "p" * 58
        with tempfile.TemporaryDirectory() as directory:
            encrypted = Path(directory) / "secrets.sops.yaml"
            captured = {}
            def fake_must(argv, label, input_text=None):
                captured["argv"] = tuple(argv)
                captured["input"] = input_text
                class Done:
                    stdout = "sops:\n  age: []\n"
                return Done()
            with mock.patch.object(setup, "ENCRYPTED", encrypted), mock.patch.object(setup, "_must", side_effect=fake_must):
                setup._ensure_secret_start(operational, offline)
            self.assertIn("vaultwarden_admin_token", captured["input"])
            self.assertNotIn("vaultwarden_admin_token", " ".join(captured["argv"]))
            self.assertNotIn(json.loads(captured["input"])["vaultwarden_admin_token"], " ".join(captured["argv"]))

    def test_use_latest_freezes_once_before_install(self) -> None:
        frozen = mock.Mock()
        frozen_versions = "schema_version = 1\n"
        context = mock.MagicMock()
        context.__enter__.return_value = Path("/tmp/frozen")
        context.__exit__.return_value = False
        with mock.patch.object(setup, "resolve_latest", return_value=frozen) as latest, mock.patch.object(setup, "frozen_versions_toml", return_value=frozen_versions), mock.patch.object(setup.install, "_frozen_source", return_value=context), mock.patch.object(setup.install, "install_layout", return_value="/opt/vaultwarden-oci/releases/frozen") as installer, mock.patch.object(setup, "record_frozen"):
            release = setup._install_release(Path("/source"), use_latest=True)
        self.assertEqual(release, "/opt/vaultwarden-oci/releases/frozen")
        latest.assert_called_once()
        installer.assert_called_once_with(Path("/tmp/frozen"), require_all_architectures=False)

    def test_runtime_commands_fail_before_cli_when_storage_is_missing(self) -> None:
        with mock.patch.object(update_cli.storage, "verify", side_effect=storage.StorageError("missing mount")), mock.patch.object(update_cli.cli, "main") as delegated:
            code = update_cli.main(["start"])
        self.assertEqual(code, 1)
        delegated.assert_not_called()

    def test_doctor_reports_storage_check_without_color_or_escape_sequences(self) -> None:
        with mock.patch.object(update_cli.cli, "doctor_checks", return_value=[]), mock.patch.object(update_cli.storage, "verify", side_effect=storage.StorageError("missing mount")):
            with mock.patch("builtins.print") as printer:
                code = update_cli.main(["doctor"])
        self.assertEqual(code, 1)
        rendered = "\n".join(" ".join(str(value) for value in call.args) for call in printer.call_args_list)
        self.assertIn("storage.dedicated", rendered)
        self.assertNotIn("\x1b[", rendered)


if __name__ == "__main__":
    unittest.main()
