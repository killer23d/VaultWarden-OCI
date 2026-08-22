from __future__ import annotations

import json
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, setup, storage, update_cli


def result(argv, stdout="", rc=0, stderr=""):
    return storage.CommandResult(tuple(argv), rc, stdout, stderr)


class StorageContractTests(unittest.TestCase):
    def test_boot_device_and_parent_are_rejected(self) -> None:
        def runner(argv):
            command = list(argv)
            if command[:4] == ["findmnt", "-n", "-o", "SOURCE"]: return result(argv, "/dev/vda1\n")
            if command[0] == "lsblk" and "-s" in command:
                dev = command[-1]; return result(argv, f"{dev}\n/dev/vda\n" if dev == "/dev/vda1" else f"{dev}\n")
            if command[0] == "lsblk" and "-r" in command:
                dev = command[-1]; return result(argv, "/dev/vda\n/dev/vda1\n" if dev == "/dev/vda" else f"{dev}\n")
            raise AssertionError(command)
        with mock.patch.object(storage, "_real_device", side_effect=lambda value: value):
            with self.assertRaisesRegex(storage.StorageError, "boot/root"): storage.reject_boot_related("/dev/vda", runner=runner)

    def test_separate_device_is_accepted_by_boot_lineage_gate(self) -> None:
        def runner(argv):
            command = list(argv)
            if command[0] == "findmnt": return result(argv, "/dev/vda1\n")
            if command[0] == "lsblk":
                dev = command[-1]
                if dev == "/dev/vda1": return result(argv, "/dev/vda1\n/dev/vda\n")
                if dev == "/dev/vda": return result(argv, "/dev/vda\n/dev/vda1\n")
                return result(argv, f"{dev}\n")
            raise AssertionError(command)
        with mock.patch.object(storage, "_real_device", side_effect=lambda value: value): storage.reject_boot_related("/dev/vdb", runner=runner)

    def test_missing_mount_and_host_side_wrong_identity_fail_closed(self) -> None:
        with mock.patch.object(storage.Path, "is_mount", return_value=False):
            with self.assertRaisesRegex(storage.StorageError, "mount is absent"): storage.verify()
        actual = storage.StorageIdentity("aaaa-bbbb", "ext4", "/dev/vdb")
        expected = storage.StorageIdentity("cccc-dddd", "ext4", "/dev/vdc")
        with mock.patch.object(storage, "_identity_from_mount", return_value=actual), mock.patch.object(storage, "load_identity", return_value=expected), mock.patch.object(storage, "load_volume_marker", return_value=actual):
            with self.assertRaisesRegex(storage.StorageError, "wrong filesystem"): storage.verify()

    def test_volume_marker_cannot_self_authenticate_against_host_identity(self) -> None:
        actual = storage.StorageIdentity("aaaa-bbbb", "ext4", "/dev/vdb")
        expected = storage.StorageIdentity("cccc-dddd", "ext4", "/dev/vdc")
        with mock.patch.object(storage, "_identity_from_mount", return_value=actual), mock.patch.object(storage, "load_identity", return_value=expected), mock.patch.object(storage, "load_volume_marker", return_value=actual):
            with self.assertRaises(storage.StorageError): storage.verify()

    def test_conflicting_rerun_fails_before_fstab_or_identity_mutation(self) -> None:
        mounted = storage.StorageIdentity("aaaa-bbbb", "ext4", "/dev/vdb")
        selected = storage.StorageIdentity("cccc-dddd", "ext4", "/dev/vdc")
        with mock.patch.object(storage, "_real_device", return_value="/dev/vdc"), mock.patch.object(storage, "reject_boot_related"), mock.patch.object(storage, "_blkid", return_value="ext4"), mock.patch.object(storage, "_signature_types", return_value={"ext4"}), mock.patch.object(storage, "_selected_identity", return_value=selected), mock.patch.object(storage.Path, "is_mount", return_value=True), mock.patch.object(storage, "_identity_from_mount", return_value=mounted), mock.patch.object(storage, "ensure_fstab") as fstab, mock.patch.object(storage, "write_identity") as identity:
            with self.assertRaisesRegex(storage.StorageError, "refusing to rewrite"):
                storage.provision("/dev/vdc", acknowledge_existing=True, runner=lambda argv: result(argv, "disk\n"))
        fstab.assert_not_called(); identity.assert_not_called()

    def test_existing_and_blank_require_separate_acknowledgements(self) -> None:
        with mock.patch.object(storage, "_real_device", return_value="/dev/vdb"), mock.patch.object(storage, "reject_boot_related"), mock.patch.object(storage, "_blkid", return_value="ext4"), mock.patch.object(storage, "_signature_types", return_value={"ext4"}):
            with self.assertRaisesRegex(storage.StorageError, "acknowledgement"):
                storage.provision("/dev/vdb", runner=lambda argv: result(argv, "disk\n"))
        with mock.patch.object(storage, "_real_device", return_value="/dev/vdb"), mock.patch.object(storage, "reject_boot_related"), mock.patch.object(storage, "_blkid", return_value=""), mock.patch.object(storage, "_signature_types", return_value=set()):
            with self.assertRaisesRegex(storage.StorageError, "acknowledgement"):
                storage.provision("/dev/vdb", runner=lambda argv: result(argv, "disk\n"))

    def test_mixed_signatures_fail_closed(self) -> None:
        with mock.patch.object(storage, "_real_device", return_value="/dev/vdb"), mock.patch.object(storage, "reject_boot_related"), mock.patch.object(storage, "_blkid", return_value="ext4"), mock.patch.object(storage, "_signature_types", return_value={"ext4", "crypto_LUKS"}):
            with self.assertRaisesRegex(storage.StorageError, "mixed/unknown"):
                storage.provision("/dev/vdb", acknowledge_existing=True, runner=lambda argv: result(argv, "disk\n"))

    def test_auto_does_not_guess_storage(self) -> None:
        args = Namespace(data_mount=str(storage.STATE_ROOT), data_device=None, auto=True)
        with self.assertRaisesRegex(setup.SetupError, "requires --data-device"): setup._select_storage(args, setup.UI(color=False))

    def test_docker_guard_requires_canonical_mount(self) -> None:
        identity = storage.StorageIdentity("abcd-1234", "ext4", "/dev/vdb")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "guard.conf"; storage.ensure_docker_guard(identity, path=path); text = path.read_text()
            self.assertIn(f"RequiresMountsFor={storage.STATE_ROOT}", text); self.assertIn(f"ConditionPathIsMountPoint={storage.STATE_ROOT}", text)


class SetupContractTests(unittest.TestCase):
    def test_domain_url_email_normalization_has_one_url_authority(self) -> None:
        host, url, email = setup._normalize("Example.COM.", "https://vault.example.com/", "admin@example.com")
        self.assertEqual((host, url, email), ("vault.example.com", "https://vault.example.com", "admin@example.com"))
        text = setup._config_text(host, email, "age1" + "q" * 58)
        self.assertIn('domain = "vault.example.com"', text); self.assertNotIn("https://vault.example.com", text)

    def test_malformed_email_cannot_generate_invalid_toml(self) -> None:
        with self.assertRaisesRegex(setup.SetupError, "email"):
            setup._normalize("example.com", "https://vault.example.com", 'admin"@example.com')

    def test_generated_config_is_parsed_by_canonical_runtime_owner(self) -> None:
        text = setup._config_text("vault.example.com", "admin@example.com", "age1" + "q" * 58)
        setup._validate_config_text(text)

    def test_config_rerun_is_idempotent_and_does_not_overwrite_operator_changes(self) -> None:
        offline = "age1" + "q" * 58
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"; desired = setup._config_text("vault.example.com", "admin@example.com", offline); path.write_text(desired)
            with mock.patch.object(setup, "CONFIG", path):
                setup._ensure_config("vault.example.com", "admin@example.com", offline)
                path.write_text(desired.replace("signups_allowed = false", "signups_allowed = true"))
                with self.assertRaisesRegex(setup.SetupError, "differs"): setup._ensure_config("vault.example.com", "admin@example.com", offline)

    def test_corrupt_existing_secrets_fail_rerun(self) -> None:
        offline = "age1" + "q" * 58; operational = "age1" + "p" * 58
        with tempfile.TemporaryDirectory() as directory:
            encrypted = Path(directory) / "secrets.sops.yaml"; encrypted.write_text("broken\n")
            with mock.patch.object(setup, "ENCRYPTED", encrypted), mock.patch.object(setup.secret_owner, "encrypted_recipients", side_effect=setup.secret_owner.SecretsError("bad metadata")):
                with self.assertRaises(setup.secret_owner.SecretsError): setup._ensure_secret_start(operational, offline)

    def test_secret_plaintext_is_stdin_only_not_argv_or_failure_text(self) -> None:
        offline = "age1" + "q" * 58; operational = "age1" + "p" * 58; captured = {}
        with tempfile.TemporaryDirectory() as directory:
            encrypted = Path(directory) / "secrets.sops.yaml"
            def fake_must(argv, label, input_text=None, env=None):
                captured["argv"] = tuple(argv); captured["input"] = input_text
                class Done: stdout = "sops:\n  age: []\n"
                return Done()
            with mock.patch.object(setup, "ENCRYPTED", encrypted), mock.patch.object(setup, "_must", side_effect=fake_must), mock.patch.object(setup, "_validate_existing_secrets"):
                setup._ensure_secret_start(operational, offline)
            token = json.loads(captured["input"])["vaultwarden_admin_token"]
            self.assertNotIn(token, " ".join(captured["argv"]))

    def test_use_latest_freezes_once_before_install(self) -> None:
        frozen = mock.Mock(); context = mock.MagicMock(); context.__enter__.return_value = Path("/tmp/frozen"); context.__exit__.return_value = False
        with mock.patch.object(setup, "resolve_latest", return_value=frozen) as latest, mock.patch.object(setup, "frozen_versions_toml", return_value="schema_version = 1\n"), mock.patch.object(setup.install, "_frozen_source", return_value=context), mock.patch.object(setup.install, "install_layout", return_value="/opt/vaultwarden-oci/releases/frozen") as installer, mock.patch.object(setup, "record_frozen"):
            self.assertEqual(setup._install_release(Path("/source"), use_latest=True), "/opt/vaultwarden-oci/releases/frozen")
        latest.assert_called_once(); installer.assert_called_once_with(Path("/tmp/frozen"), require_all_architectures=False)

    def test_all_persistent_state_commands_fail_before_cli_when_storage_missing(self) -> None:
        for command in ("start", "backup", "restore", "recovery", "edge", "crowdsec", "notify"):
            with self.subTest(command=command), mock.patch.object(update_cli.storage, "verify", side_effect=storage.StorageError("missing mount")), mock.patch.object(update_cli.cli, "main") as delegated:
                code = update_cli.main([command]); self.assertEqual(code, 1); delegated.assert_not_called()

    def test_doctor_storage_id_is_in_canonical_order_without_ansi(self) -> None:
        base = [cli.DoctorCheck(check_id, "PASS", "ok") for check_id in cli.DOCTOR_CHECK_IDS if check_id != "storage.dedicated"]
        with mock.patch.object(update_cli.cli, "doctor_checks", return_value=base), mock.patch.object(update_cli.storage, "verify", side_effect=storage.StorageError("missing mount")), mock.patch("builtins.print") as printer:
            code = update_cli.main(["doctor"])
        self.assertEqual(code, 1)
        rendered = "\n".join(" ".join(str(value) for value in call.args) for call in printer.call_args_list)
        self.assertIn("storage.dedicated", rendered); self.assertNotIn("\x1b[", rendered)


if __name__ == "__main__": unittest.main()
