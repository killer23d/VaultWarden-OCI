from __future__ import annotations

import contextlib
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import recovery, recovery_ux, sevenzip_secure, setup_frontend
from vaultwarden_oci.cli import CommandResult

OFFLINE = "age1" + "q" * 58
OPERATIONAL = "age1" + "p" * 58


def command_result(argv, stdout="", code=0):
    return CommandResult(tuple(argv), "success" if code == 0 else "nonzero", code, stdout, "")


def config_text() -> str:
    return f'''schema_version = 1
[site]
domain = "vault.example.net"
acme_email = "admin@example.net"
[secrets]
offline_recovery_recipient = "{OFFLINE}"
[vaultwarden]
signups_allowed = false
[smtp]
host = "smtp.example.net"
port = 587
security = "starttls"
from_email = "vaultwarden@example.net"
from_name = "Vaultwarden"
timeout_seconds = 15
'''


def paths_for(root: Path) -> recovery.RecoveryPaths:
    return recovery.RecoveryPaths(
        backups=root / "backups",
        state_file=root / "state/recovery.json",
        config=root / "etc/config.toml",
        encrypted_secrets=root / "etc/secrets.sops.yaml",
        operational_age_key=root / "etc/age-key.txt",
        data=root / "data",
        caddy_data=root / "caddy/data",
        caddy_config=root / "caddy/config",
        lock=root / "run/lock",
    )


def zip_listing(archive: Path, members: list[str]) -> str:
    sections = [
        f"Path = {archive}\nType = zip\nPhysical Size = 123\n",
    ]
    for member in members:
        sections.append(
            f"Path = {member}\n"
            "Size = 10\n"
            "Packed Size = 20\n"
            "Encrypted = +\n"
            "Method = AES-256 Deflate\n"
        )
    return "\n".join(sections)


class RecoveryInventoryTests(unittest.TestCase):
    def test_local_inventory_newest_first_and_known_verification(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = paths_for(root)
            paths.backups.mkdir(parents=True)
            old = paths.backups / "recovery-20260820T010000Z-aaaa.vwrec"
            new = paths.backups / "recovery-20260820T030000Z-bbbb.vwrec"
            old.write_bytes(b"old")
            new.write_bytes(b"newer")
            paths.state_file.parent.mkdir(parents=True)
            paths.state_file.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "verified_objects": {
                            str(old): {
                                "verified_at": "2026-08-20T02:00:00Z",
                                "size": 3,
                                "sha256": "a" * 64,
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            points = recovery_ux.list_local(paths)
            self.assertEqual([point.name for point in points], [new.name, old.name])
            self.assertEqual(points[0].verification, "unknown")
            self.assertEqual(points[1].verification, "previously-verified")

    def test_same_size_post_verification_change_is_not_claimed_currently_verified(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = paths_for(root)
            paths.backups.mkdir(parents=True)
            artifact = paths.backups / "recovery-20260820T010000Z-aaaa.vwrec"
            artifact.write_bytes(b"good")
            paths.state_file.parent.mkdir(parents=True)
            paths.state_file.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "verified_objects": {
                            str(artifact): {
                                "verified_at": "2026-08-20T02:00:00Z",
                                "size": 4,
                                "sha256": recovery._sha256(artifact),
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            artifact.write_bytes(b"evil")
            point = recovery_ux.list_local(paths)[0]
            self.assertEqual(point.verification, "previously-verified")

    def test_size_change_is_reported_changed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = paths_for(root)
            paths.backups.mkdir(parents=True)
            artifact = paths.backups / "recovery-20260820T010000Z-aaaa.vwrec"
            artifact.write_bytes(b"changed")
            paths.state_file.parent.mkdir(parents=True)
            paths.state_file.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "verified_objects": {
                            str(artifact): {"verified_at": "2026-08-20T02:00:00Z", "size": 3}
                        },
                    }
                ),
                encoding="utf-8",
            )
            self.assertEqual(recovery_ux.list_local(paths)[0].verification, "changed")

    def test_mocked_remote_inventory_newest_first_and_size(self) -> None:
        entries = [
            {"Name": "recovery-20260820T010000Z-a.vwrec", "Size": 100},
            {"Name": "ignore.txt", "Size": 2},
            {"Name": "recovery-20260820T030000Z-c.vwrec", "Size": 300},
        ]
        with tempfile.TemporaryDirectory() as directory:
            paths = paths_for(Path(directory))
            with mock.patch.object(recovery, "list_remote", return_value=entries):
                points = recovery_ux.list_remote_points("offsite:recovery", paths=paths)
        self.assertEqual([point.name for point in points], [entries[2]["Name"], entries[0]["Name"]])
        self.assertEqual([point.size for point in points], [300, 100])
        self.assertTrue(all(point.source == "remote" for point in points))

    def test_verify_is_nondestructive_and_records_existing_recovery_state_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = paths_for(root)
            paths.backups.mkdir(parents=True)
            artifact = paths.backups / "recovery-20260820T030000Z-c.vwrec"
            artifact.write_bytes(b"encrypted")
            identity = root / "offline.age"
            identity.write_text("identity", encoding="utf-8")
            manifest = {"created_at": "2026-08-20T03:00:00Z"}
            with (
                mock.patch.object(recovery, "_ensure_regular"),
                mock.patch.object(recovery, "_decrypt_and_validate", return_value=manifest),
                mock.patch.object(recovery, "_validate_offline_sops"),
                mock.patch.object(recovery, "_sha256", return_value="a" * 64),
            ):
                verified = recovery_ux.verify_local(artifact, identity, paths=paths)
            self.assertEqual(verified.created_at, manifest["created_at"])
            state = json.loads(paths.state_file.read_text(encoding="utf-8"))
            self.assertIn(str(artifact), state["verified_objects"])


class OfflineIdentityAcquisitionTests(unittest.TestCase):
    def test_default_secure_paste_is_hidden_validated_0600_and_removed(self) -> None:
        secret = "AGE-SECRET-KEY-1TEST-PASTE"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sensitive = root / "run"
            output = io.StringIO()
            with (
                mock.patch("builtins.input", return_value=""),
                mock.patch.object(recovery_ux.getpass, "getpass", return_value=secret) as hidden_prompt,
                mock.patch.object(recovery_ux, "_interactive_tty", return_value=True),
                mock.patch.object(recovery_ux.secrets, "derive_recipient", return_value=OFFLINE),
                contextlib.redirect_stdout(output),
            ):
                with recovery_ux.acquire_offline_identity(
                    OFFLINE,
                    publication_dir=root / "published",
                    sensitive_root=sensitive,
                    ui=recovery_ux.UI(color=False),
                ) as identity:
                    self.assertIsNotNone(identity)
                    assert identity is not None
                    temporary_identity = identity
                    temporary_workspace = identity.parent
                    self.assertEqual(stat.S_IMODE(identity.stat().st_mode), 0o600)
                    self.assertEqual(stat.S_IMODE(identity.parent.stat().st_mode), 0o700)
                    self.assertEqual(identity.read_text(encoding="utf-8"), secret + "\n")
            hidden_prompt.assert_called_once()
            self.assertNotIn(secret, output.getvalue())
            self.assertFalse(temporary_identity.exists())
            self.assertFalse(temporary_workspace.exists())

    def test_interrupt_after_secure_paste_removes_temporary_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sensitive = root / "run"
            with (
                mock.patch("builtins.input", return_value=""),
                mock.patch.object(
                    recovery_ux.getpass,
                    "getpass",
                    return_value="AGE-SECRET-KEY-1INTERRUPT",
                ),
                mock.patch.object(recovery_ux, "_interactive_tty", return_value=True),
                mock.patch.object(recovery_ux.secrets, "derive_recipient", return_value=OFFLINE),
                self.assertRaises(KeyboardInterrupt),
            ):
                with recovery_ux.acquire_offline_identity(
                    OFFLINE,
                    publication_dir=root / "published",
                    sensitive_root=sensitive,
                    ui=recovery_ux.UI(color=False),
                ) as identity:
                    self.assertIsNotNone(identity)
                    assert identity is not None
                    temporary_identity = identity
                    temporary_workspace = identity.parent
                    raise KeyboardInterrupt
            self.assertFalse(temporary_identity.exists())
            self.assertFalse(temporary_workspace.exists())


    def test_mismatched_paste_fails_and_removes_temporary_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sensitive = root / "run"
            with (
                mock.patch("builtins.input", return_value=""),
                mock.patch.object(recovery_ux.getpass, "getpass", return_value="AGE-SECRET-KEY-1WRONG"),
                mock.patch("sys.stdin.isatty", return_value=True),
                mock.patch("sys.stdout.isatty", return_value=True),
                mock.patch.object(recovery_ux.secrets, "derive_recipient", return_value="age1" + "z" * 58),
                self.assertRaisesRegex(recovery_ux.RecoveryUXError, "does not match"),
            ):
                with recovery_ux.acquire_offline_identity(
                    OFFLINE,
                    publication_dir=root / "published",
                    sensitive_root=sensitive,
                    ui=recovery_ux.UI(color=False),
                ):
                    self.fail("mismatched identity must not be yielded")
            self.assertFalse(any(sensitive.glob("offline-identity-*")))

    def test_identity_file_is_validated_and_external_file_is_not_removed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            identity = root / "offline.age"
            identity.write_text("identity\n", encoding="utf-8")
            answers = iter(["2", str(identity)])
            with (
                mock.patch("builtins.input", side_effect=lambda _="": next(answers)),
                mock.patch("sys.stdin.isatty", return_value=True),
                mock.patch("sys.stdout.isatty", return_value=True),
                mock.patch.object(recovery_ux.secrets, "derive_recipient", return_value=OFFLINE),
            ):
                with recovery_ux.acquire_offline_identity(
                    OFFLINE,
                    publication_dir=root / "published",
                    sensitive_root=root / "run",
                    ui=recovery_ux.UI(color=False),
                ) as selected:
                    self.assertEqual(selected, identity)
            self.assertTrue(identity.exists())

    def test_identity_file_rejects_missing_symlink_and_wrong_recipient(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            missing = root / "missing.age"
            target = root / "target.age"
            target.write_text("identity\n", encoding="utf-8")
            symlink = root / "link.age"
            symlink.symlink_to(target)

            for supplied in (missing, symlink):
                answers = iter(["2", str(supplied)])
                with (
                    mock.patch("builtins.input", side_effect=lambda _="": next(answers)),
                    mock.patch("sys.stdin.isatty", return_value=True),
                    mock.patch("sys.stdout.isatty", return_value=True),
                    self.assertRaises(recovery.RecoveryError),
                ):
                    with recovery_ux.acquire_offline_identity(
                        OFFLINE,
                        publication_dir=root / "published",
                        sensitive_root=root / "run",
                        ui=recovery_ux.UI(color=False),
                    ):
                        self.fail("unsafe identity path must not be yielded")

            answers = iter(["2", str(target)])
            with (
                mock.patch("builtins.input", side_effect=lambda _="": next(answers)),
                mock.patch("sys.stdin.isatty", return_value=True),
                mock.patch("sys.stdout.isatty", return_value=True),
                mock.patch.object(recovery_ux.secrets, "derive_recipient", return_value="age1" + "z" * 58),
                self.assertRaisesRegex(recovery_ux.RecoveryUXError, "does not match"),
            ):
                with recovery_ux.acquire_offline_identity(
                    OFFLINE,
                    publication_dir=root / "published",
                    sensitive_root=root / "run",
                    ui=recovery_ux.UI(color=False),
                ):
                    self.fail("wrong identity must not be yielded")

    def test_local_recovery_kit_is_newest_first_extracted_temporarily_and_passphrase_not_in_argv(self) -> None:
        passphrase = "kit-passphrase-hidden"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            publication = root / "published"
            publication.mkdir()
            old = publication / "vaultwarden-recovery-kit-20260820T010000Z.zip"
            new = publication / "vaultwarden-recovery-kit-20260820T030000Z.zip"
            old.write_bytes(b"old")
            new.write_bytes(b"new")
            os.utime(old, (1, 1))
            os.utime(new, (2, 2))
            ignored = publication / "not-a-recovery-kit.zip"
            ignored.write_bytes(b"ignore")
            symlink = publication / "vaultwarden-recovery-kit-20260820T040000Z.zip"
            symlink.symlink_to(new)
            self.assertEqual(recovery_ux._local_recovery_kits(publication), [new, old])

            events: list[str] = []
            seen_argv: list[tuple[str, ...]] = []

            def fake_verify(archive, supplied_passphrase, *, expected_members):
                self.assertEqual(archive, new)
                self.assertEqual(supplied_passphrase, passphrase)
                self.assertEqual(tuple(expected_members), recovery_ux.KIT_MEMBERS)
                events.append("verified")

            def fake_seven(argv, *, password_input, cwd=None):
                del cwd
                seen_argv.append(tuple(argv))
                self.assertEqual(password_input, passphrase)
                self.assertEqual(events, ["verified"])
                output_dir = Path(next(arg[2:] for arg in argv if arg.startswith("-o")))
                (output_dir / recovery_ux.OFFLINE_IDENTITY_MEMBER).write_text(
                    "AGE-SECRET-KEY-1FROMKIT\n",
                    encoding="utf-8",
                )
                events.append("extracted")
                return mock.Mock(returncode=0, stdout="", stderr="")

            answers = iter(["3", "1"])
            output = io.StringIO()
            with (
                mock.patch("builtins.input", side_effect=lambda _="": next(answers)),
                mock.patch.object(recovery_ux.getpass, "getpass", return_value=passphrase),
                mock.patch.object(recovery_ux, "_interactive_tty", return_value=True),
                mock.patch.object(recovery_ux, "verify_zip", side_effect=fake_verify),
                mock.patch.object(recovery_ux, "_seven", side_effect=fake_seven),
                mock.patch.object(recovery_ux.secrets, "derive_recipient", return_value=OFFLINE),
                contextlib.redirect_stdout(output),
            ):
                with recovery_ux.acquire_offline_identity(
                    OFFLINE,
                    publication_dir=publication,
                    sensitive_root=root / "run",
                    ui=recovery_ux.UI(color=False),
                ) as identity:
                    self.assertIsNotNone(identity)
                    assert identity is not None
                    extracted = identity
                    workspace = identity.parent
                    self.assertEqual(stat.S_IMODE(identity.stat().st_mode), 0o600)
                    self.assertEqual(events, ["verified", "extracted"])
            self.assertFalse(extracted.exists())
            self.assertFalse(workspace.exists())
            self.assertTrue(seen_argv)
            self.assertFalse(any(passphrase in arg for argv in seen_argv for arg in argv))
            self.assertNotIn(passphrase, output.getvalue())

    def test_no_local_recovery_kit_reports_directory_and_allows_cancel(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            publication = root / "published"
            publication.mkdir()
            answers = iter(["3", "q"])
            output = io.StringIO()
            with (
                mock.patch("builtins.input", side_effect=lambda _="": next(answers)),
                mock.patch.object(recovery_ux, "_interactive_tty", return_value=True),
                contextlib.redirect_stdout(output),
            ):
                with recovery_ux.acquire_offline_identity(
                    OFFLINE,
                    publication_dir=publication,
                    sensitive_root=root / "run",
                    ui=recovery_ux.UI(color=False),
                ) as identity:
                    self.assertIsNone(identity)
            self.assertIn(f"no local recovery-kit ZIPs found under {publication}", output.getvalue())


class IdentityCommandRoutingTests(unittest.TestCase):
    def test_non_tty_omission_fails_with_explicit_identity_guidance(self) -> None:
        cases = (
            (["restore", "--file", "/tmp/a.vwrec"], "--identity"),
            (["recovery", "verify", "--file", "/tmp/a.vwrec"], "--identity"),
            (["recovery-kit", "export", "--no-email"], "--offline-identity"),
        )
        for argv, option in cases:
            stderr = io.StringIO()
            with (
                self.subTest(argv=argv),
                mock.patch("sys.stdin.isatty", return_value=False),
                mock.patch("sys.stdout.isatty", return_value=False),
                contextlib.redirect_stderr(stderr),
            ):
                self.assertEqual(recovery_ux.main(argv), 1)
                self.assertIn(option, stderr.getvalue())

    def test_explicit_restore_identity_remains_noninteractive_and_skips_chooser(self) -> None:
        identity = Path("/tmp/offline.age")
        artifact = Path("/tmp/a.vwrec")
        verified = recovery.VerifiedRecovery(artifact, "a" * 64, 1, "2026-08-20T03:00:00Z")
        with (
            mock.patch("sys.stdin.isatty", return_value=False),
            mock.patch("sys.stdout.isatty", return_value=False),
            mock.patch.object(recovery_ux, "acquire_offline_identity") as chooser,
            mock.patch.object(recovery_ux.storage, "verify"),
            mock.patch.object(recovery_ux, "verify_local", return_value=verified),
            mock.patch.object(
                recovery_ux.recovery,
                "restore_recovery",
                return_value={"created_at": "2026-08-20T03:00:00Z"},
            ),
        ):
            self.assertEqual(
                recovery_ux.main(
                    ["restore", "--file", str(artifact), "--identity", str(identity)]
                ),
                0,
            )
        chooser.assert_not_called()

    def test_interactive_omission_routes_restore_verify_and_kit_export_through_identity_owner(self) -> None:
        identity = Path("/tmp/offline.age")
        artifact = Path("/tmp/a.vwrec")
        verified = recovery.VerifiedRecovery(artifact, "a" * 64, 1, "2026-08-20T03:00:00Z")
        kit_result = recovery_ux.KitResult(Path("/tmp/kit.zip"), recovery_ux.KIT_MEMBERS, False)

        with (
            mock.patch("sys.stdin.isatty", return_value=True),
            mock.patch("sys.stdout.isatty", return_value=True),
            mock.patch.object(
                recovery_ux,
                "_offline_identity_for_command",
                side_effect=lambda *args, **kwargs: contextlib.nullcontext(identity),
            ) as owner,
            mock.patch.object(recovery_ux.storage, "verify"),
            mock.patch.object(recovery_ux, "verify_local", return_value=verified),
            mock.patch.object(
                recovery_ux.recovery,
                "restore_recovery",
                return_value={"created_at": verified.created_at},
            ),
            mock.patch.object(recovery_ux, "export_recovery_kit", return_value=kit_result),
        ):
            self.assertEqual(recovery_ux.main(["restore", "--file", str(artifact)]), 0)
            self.assertEqual(recovery_ux.main(["recovery", "verify", "--file", str(artifact)]), 0)
            self.assertEqual(recovery_ux.main(["recovery-kit", "export", "--no-email"]), 0)
        self.assertEqual(owner.call_count, 3)


class GuidedRestoreTests(unittest.TestCase):
    def test_guided_selection_restores_selected_point_only_after_confirmation(self) -> None:
        points = [
            recovery_ux.RecoveryPoint("local", "new.vwrec", "/backups/new.vwrec", 2, "2026-08-20T03:00:00Z", "unknown"),
            recovery_ux.RecoveryPoint("local", "old.vwrec", "/backups/old.vwrec", 1, "2026-08-20T01:00:00Z", "previously-verified"),
        ]
        verified = recovery.VerifiedRecovery(Path(points[1].location), "a" * 64, 1, points[1].created_at)
        answers = iter(["1", "2", "RESTORE"])
        with (
            mock.patch("builtins.input", side_effect=lambda _="": next(answers)),
            mock.patch("sys.stdin.isatty", return_value=True),
            mock.patch("sys.stdout.isatty", return_value=True),
            mock.patch.object(recovery_ux, "list_local", return_value=points),
            mock.patch.object(
                recovery_ux,
                "_offline_identity_for_command",
                side_effect=lambda *args, **kwargs: contextlib.nullcontext(Path("/tmp/offline.age")),
            ),
            mock.patch.object(recovery_ux.storage, "verify"),
            mock.patch.object(recovery_ux, "verify_local", return_value=verified),
            mock.patch.object(recovery, "restore_recovery", return_value={"created_at": points[1].created_at}) as restore,
        ):
            self.assertEqual(recovery_ux.guided_restore(ui=recovery_ux.UI(color=False)), 0)
        restore.assert_called_once()
        self.assertEqual(restore.call_args.args[0], Path(points[1].location))

    def test_guided_cancellation_after_preflight_never_mutates(self) -> None:
        point = recovery_ux.RecoveryPoint("local", "one.vwrec", "/backups/one.vwrec", 1, "2026-08-20T01:00:00Z", "previously-verified")
        verified = recovery.VerifiedRecovery(Path(point.location), "a" * 64, 1, point.created_at)
        answers = iter(["1", "1", "NO"])
        with (
            mock.patch("builtins.input", side_effect=lambda _="": next(answers)),
            mock.patch("sys.stdin.isatty", return_value=True),
            mock.patch("sys.stdout.isatty", return_value=True),
            mock.patch.object(recovery_ux, "list_local", return_value=[point]),
            mock.patch.object(
                recovery_ux,
                "_offline_identity_for_command",
                side_effect=lambda *args, **kwargs: contextlib.nullcontext(Path("/tmp/offline.age")),
            ),
            mock.patch.object(recovery_ux.storage, "verify"),
            mock.patch.object(recovery_ux, "verify_local", return_value=verified),
            mock.patch.object(recovery, "restore_recovery") as restore,
        ):
            self.assertEqual(recovery_ux.guided_restore(ui=recovery_ux.UI(color=False)), 0)
        restore.assert_not_called()

    def test_dedicated_storage_preflight_blocks_before_recovery_verification(self) -> None:
        with (
            mock.patch.object(recovery_ux.storage, "verify", side_effect=recovery_ux.storage.StorageError("wrong mount")),
            mock.patch.object(recovery_ux, "verify_local") as verify,
        ):
            code = recovery_ux.main(["restore", "--file", "/tmp/a.vwrec", "--identity", "/tmp/id"])
        self.assertEqual(code, 1)
        verify.assert_not_called()

    def test_explicit_remote_restore_verifies_and_restores_same_download(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = paths_for(root)
            paths.backups.mkdir(parents=True)
            identity = root / "offline.age"
            identity.write_text("identity", encoding="utf-8")
            downloaded: list[Path] = []

            def fake_download(remote_object, destination, *, runner=None):
                destination.write_bytes(b"one immutable download")
                downloaded.append(destination)
                return destination

            def fake_verify(artifact, supplied_identity, **kwargs):
                self.assertEqual(artifact.read_bytes(), b"one immutable download")
                self.assertEqual(supplied_identity, identity)
                return recovery.VerifiedRecovery(artifact, "a" * 64, artifact.stat().st_size, "2026-08-20T03:00:00Z")

            def fake_restore(artifact, supplied_identity, **kwargs):
                self.assertEqual(artifact, downloaded[0])
                self.assertEqual(artifact.read_bytes(), b"one immutable download")
                self.assertEqual(supplied_identity, identity)
                return {"created_at": "2026-08-20T03:00:00Z"}

            with (
                mock.patch.object(recovery, "download_remote", side_effect=fake_download) as download,
                mock.patch.object(recovery_ux, "verify_local", side_effect=fake_verify) as verify,
                mock.patch.object(recovery, "restore_recovery", side_effect=fake_restore) as restore,
            ):
                manifest = recovery_ux.restore_remote_once(
                    "offsite:recovery/object.vwrec", identity, paths=paths
                )
            self.assertEqual(manifest["created_at"], "2026-08-20T03:00:00Z")
            download.assert_called_once()
            verify.assert_called_once()
            restore.assert_called_once()


class RecoveryKitTests(unittest.TestCase):
    def _seed(self, root: Path) -> recovery.RecoveryPaths:
        paths = paths_for(root)
        paths.config.parent.mkdir(parents=True)
        paths.config.write_text(config_text(), encoding="utf-8")
        paths.encrypted_secrets.write_text(
            f"sops:\n  age:\n    - recipient: {OPERATIONAL}\n    - recipient: {OFFLINE}\n",
            encoding="utf-8",
        )
        paths.operational_age_key.write_text("OPS-PRIVATE", encoding="utf-8")
        os.chmod(paths.operational_age_key, 0o600)
        return paths

    def test_complete_kit_has_required_labels_and_email_only_after_verification(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = self._seed(root)
            offline = root / "offline.age"
            offline.write_text("OFFLINE-PRIVATE", encoding="utf-8")
            publication = root / "published"
            sensitive = root / "run"
            values = {
                "vaultwarden_admin_token": "vw-admin-secret",
                "admin_basic_auth_password": "caddy-admin-secret",
                "cloudflare_api_token": "cfut_" + "a" * 32,
                "smtp_username": "smtp-user",
                "smtp_password": "smtp-pass",
            }
            calls: list[str] = []

            def fake_runner(argv, *, env=None, cwd=None):
                if tuple(argv[:2]) == ("age-keygen", "-y"):
                    return command_result(argv, (OPERATIONAL if Path(argv[2]) == paths.operational_age_key else OFFLINE) + "\n")
                if tuple(argv[:3]) == ("sops", "--decrypt", "--output-type"):
                    return command_result(argv, json.dumps(values))
                raise AssertionError(argv)

            def fake_seven(argv, *, password_input, cwd=None):
                if argv[1] == "a":
                    Path(argv[5]).write_bytes(b"fake-zip")
                return mock.Mock(returncode=0, stdout="")

            def fake_verify(archive, passphrase, *, expected_members):
                calls.append("verified")
                credentials = list(sensitive.glob("recovery-kit-*/credentials.txt"))
                self.assertEqual(len(credentials), 1)
                text = credentials[0].read_text(encoding="utf-8")
                self.assertIn("[Vaultwarden admin token]", text)
                self.assertIn("[Caddy admin Basic Auth password]", text)
                self.assertIn("vw-admin-secret", text)
                self.assertIn("caddy-admin-secret", text)
                self.assertEqual(tuple(expected_members), recovery_ux.KIT_MEMBERS)

            def fake_smtp(**kwargs):
                self.assertEqual(calls, ["verified"])
                calls.append("email")

            with (
                mock.patch.object(recovery_ux.secrets, "derive_recipient", side_effect=[OPERATIONAL, OFFLINE]),
                mock.patch.object(recovery_ux, "_seven", side_effect=fake_seven),
                mock.patch.object(recovery_ux, "verify_zip", side_effect=fake_verify),
                mock.patch("sys.stdin.isatty", return_value=True),
            ):
                result = recovery_ux.export_recovery_kit(
                    offline,
                    publication_dir=publication,
                    sensitive_root=sensitive,
                    paths=paths,
                    runner=fake_runner,
                    passphrase_provider=lambda: ("correct horse battery staple", "correct horse battery staple"),
                    email_prompt=lambda _: "yes",
                    smtp_sender=fake_smtp,
                )
            self.assertTrue(result.archive.exists())
            self.assertEqual(calls, ["verified", "email"])
            self.assertFalse(any(sensitive.glob("recovery-kit-*")))

    def test_complete_kit_refuses_missing_required_credentials_before_passphrase(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = self._seed(root)
            offline = root / "offline.age"
            offline.write_text("OFFLINE-PRIVATE", encoding="utf-8")
            values = {
                "vaultwarden_admin_token": "vw-admin-secret",
                "admin_basic_auth_password": "caddy-admin-secret",
            }

            def fake_runner(argv, *, env=None, cwd=None):
                del env, cwd
                if tuple(argv[:3]) == ("sops", "--decrypt", "--output-type"):
                    return command_result(argv, json.dumps(values))
                raise AssertionError(argv)

            passphrase = mock.Mock(return_value=("correct horse battery staple", "correct horse battery staple"))
            with (
                mock.patch.object(recovery_ux.secrets, "derive_recipient", side_effect=[OPERATIONAL, OFFLINE]),
                self.assertRaisesRegex(recovery_ux.RecoveryUXError, "requires required SOPS credential"),
            ):
                recovery_ux.export_recovery_kit(
                    offline,
                    publication_dir=root / "published",
                    sensitive_root=root / "run",
                    paths=paths,
                    runner=fake_runner,
                    passphrase_provider=passphrase,
                    offer_email=False,
                )
            passphrase.assert_not_called()

    def test_later_complete_export_refuses_mismatched_offline_identity_before_zip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = self._seed(root)
            offline = root / "wrong.age"
            offline.write_text("WRONG", encoding="utf-8")
            with (
                mock.patch.object(recovery_ux.secrets, "derive_recipient", side_effect=[OPERATIONAL, "age1" + "z" * 58]),
                mock.patch.object(recovery_ux, "_seven") as seven,
                self.assertRaisesRegex(recovery_ux.RecoveryUXError, "does not match"),
            ):
                recovery_ux.export_recovery_kit(
                    offline,
                    publication_dir=root / "published",
                    sensitive_root=root / "run",
                    paths=paths,
                    passphrase_provider=lambda: ("a" * 16, "a" * 16),
                    offer_email=False,
                )
            seven.assert_not_called()

    def test_zip_membership_rejects_extra_ordinary_file(self) -> None:
        archive = Path("/tmp/kit.zip")
        listing = zip_listing(archive, [*recovery_ux.KIT_MEMBERS, "unexpected.txt"])
        with (
            mock.patch.object(recovery_ux, "_seven", return_value=mock.Mock(returncode=0, stdout=listing)),
            self.assertRaisesRegex(recovery_ux.RecoveryUXError, "exactly match"),
        ):
            recovery_ux.verify_zip(archive, "correct horse battery staple")

    def test_zip_membership_rejects_extra_zip_member(self) -> None:
        archive = Path("/tmp/kit.zip")
        listing = zip_listing(archive, [*recovery_ux.KIT_MEMBERS, "unexpected.zip"])
        with (
            mock.patch.object(recovery_ux, "_seven", return_value=mock.Mock(returncode=0, stdout=listing)),
            self.assertRaisesRegex(recovery_ux.RecoveryUXError, "exactly match"),
        ):
            recovery_ux.verify_zip(archive, "correct horse battery staple")

    def test_zip_membership_rejects_duplicate_expected_member(self) -> None:
        archive = Path("/tmp/kit.zip")
        listing = zip_listing(archive, [*recovery_ux.KIT_MEMBERS, recovery_ux.KIT_MEMBERS[0]])
        with (
            mock.patch.object(recovery_ux, "_seven", return_value=mock.Mock(returncode=0, stdout=listing)),
            self.assertRaisesRegex(recovery_ux.RecoveryUXError, "exactly match"),
        ):
            recovery_ux.verify_zip(archive, "correct horse battery staple")

    def test_empty_password_and_no_password_use_distinct_subprocess_modes(self) -> None:
        seen: list[dict[str, object]] = []

        def fake_run(argv, **kwargs):
            seen.append(kwargs)
            return mock.Mock(returncode=2, stdout="", stderr="")

        with (
            mock.patch.object(sevenzip_secure.shutil, "which", return_value="/usr/bin/7zz"),
            mock.patch.object(sevenzip_secure.subprocess, "run", side_effect=fake_run),
        ):
            sevenzip_secure.run(["7zz", "t", "-p", "/tmp/kit.zip"], password_input="")
            sevenzip_secure.run(["7zz", "t", "/tmp/kit.zip"], password_input=None)
        self.assertEqual(seen[0].get("input"), "\n")
        self.assertNotIn("stdin", seen[0])
        self.assertEqual(seen[1].get("stdin"), subprocess.DEVNULL)
        self.assertNotIn("input", seen[1])

    def test_passphrase_never_enters_7zz_argv(self) -> None:
        secret = "passphrase-never-in-argv"
        seen: list[tuple[str, ...]] = []

        def fake_run(argv, **kwargs):
            seen.append(tuple(argv))
            return mock.Mock(returncode=1, stdout="", stderr="")

        with (
            mock.patch.object(sevenzip_secure.shutil, "which", return_value="/usr/bin/7zz"),
            mock.patch.object(sevenzip_secure.subprocess, "run", side_effect=fake_run),
        ):
            recovery_ux._seven(["7zz", "t", "-p", "/tmp/kit.zip"], password_input=secret)
        self.assertTrue(seen)
        self.assertFalse(any(secret in argument for argv in seen for argument in argv))


class SetupRecoveryCustodyTests(unittest.TestCase):
    @staticmethod
    def _successful_generated_setup(
        argv,
        *,
        offline_recipient_factory=None,
        defer_next_actions=False,
    ):
        del argv
        if offline_recipient_factory is None:
            raise AssertionError("generated custody callback was not supplied")
        if not defer_next_actions:
            raise AssertionError("generated custody must defer setup next-actions until handoff")
        offline_recipient_factory()
        return 0

    def test_setup_frontend_preserves_setup_must_input_and_env_contract(self) -> None:
        env = os.environ.copy()
        env["VWOCI_SETUP_FRONTEND_TEST"] = "yes"
        script = (
            "import os,sys; "
            "data=sys.stdin.read(); "
            "raise SystemExit(0 if data == 'payload' and os.environ.get('VWOCI_SETUP_FRONTEND_TEST') == 'yes' else 9)"
        )
        result = setup_frontend.setup._must(
            [sys.executable, "-c", script],
            "setup frontend runner compatibility",
            input_text="payload",
            env=env,
        )
        self.assertEqual(result.returncode, 0)

    def test_generated_offline_identity_is_removed_after_successful_handoff(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / "workspace"
            workspace.mkdir()
            identity = workspace / "offline.age"
            identity.write_text("OFFLINE", encoding="utf-8")
            with (
                mock.patch.object(setup_frontend, "_should_generate", return_value=True),
                mock.patch.object(setup_frontend, "_generate_offline_identity", return_value=(workspace, identity, OFFLINE)),
                mock.patch.object(setup_frontend.setup, "main", side_effect=self._successful_generated_setup),
                mock.patch.object(setup_frontend, "_complete_external_credentials_before_handoff"),
                mock.patch.object(
                    setup_frontend.recovery_ux,
                    "export_recovery_kit",
                    return_value=recovery_ux.KitResult(root / "kit.zip", recovery_ux.KIT_MEMBERS, False),
                ),
                mock.patch("builtins.input", return_value="SAVED"),
            ):
                code = setup_frontend.main(["install", "--domain", "example.net"])
            self.assertEqual(code, 0)
            self.assertFalse(workspace.exists())
            self.assertFalse(identity.exists())

    def test_failed_kit_export_retains_transient_offline_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / "workspace"
            workspace.mkdir()
            identity = workspace / "offline.age"
            identity.write_text("OFFLINE", encoding="utf-8")
            with (
                mock.patch.object(setup_frontend, "_should_generate", return_value=True),
                mock.patch.object(setup_frontend, "_generate_offline_identity", return_value=(workspace, identity, OFFLINE)),
                mock.patch.object(setup_frontend.setup, "main", side_effect=self._successful_generated_setup),
                mock.patch.object(setup_frontend, "_complete_external_credentials_before_handoff"),
                mock.patch.object(
                    setup_frontend.recovery_ux,
                    "export_recovery_kit",
                    side_effect=recovery_ux.RecoveryUXError("ZIP verification failed"),
                ),
            ):
                code = setup_frontend.main(["install", "--domain", "example.net"])
            self.assertEqual(code, 1)
            self.assertTrue(workspace.exists())
            self.assertTrue(identity.exists())

    def test_unacknowledged_local_handoff_retains_transient_offline_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / "workspace"
            workspace.mkdir()
            identity = workspace / "offline.age"
            identity.write_text("OFFLINE", encoding="utf-8")
            with (
                mock.patch.object(setup_frontend, "_should_generate", return_value=True),
                mock.patch.object(setup_frontend, "_generate_offline_identity", return_value=(workspace, identity, OFFLINE)),
                mock.patch.object(setup_frontend.setup, "main", side_effect=self._successful_generated_setup),
                mock.patch.object(setup_frontend, "_complete_external_credentials_before_handoff"),
                mock.patch.object(
                    setup_frontend.recovery_ux,
                    "export_recovery_kit",
                    return_value=recovery_ux.KitResult(root / "kit.zip", recovery_ux.KIT_MEMBERS, False),
                ),
                mock.patch("builtins.input", return_value="NOT YET"),
            ):
                code = setup_frontend.main(["install", "--domain", "example.net"])
            self.assertEqual(code, 1)
            self.assertTrue(workspace.exists())
            self.assertTrue(identity.exists())


class RecoveryCLIContentionTests(unittest.TestCase):
    def test_confirmed_prune_reports_lock_contention_without_traceback(self) -> None:
        with (
            mock.patch.object(
                recovery_ux.recovery,
                "prune_remote",
                side_effect=RuntimeError("another mutating vwctl operation holds the lock"),
            ),
            contextlib.redirect_stderr(io.StringIO()) as errors,
        ):
            code = recovery_ux.main(
                ["recovery", "prune", "--remote", "cloud:backups", "--keep-last", "1", "--confirm"]
            )
        self.assertEqual(code, 1)
        self.assertIn("FAIL: another mutating vwctl operation", errors.getvalue())
        self.assertNotIn("Traceback", errors.getvalue())

    def test_offsite_configure_reports_lock_contention_without_traceback(self) -> None:
        with (
            mock.patch.object(
                recovery_ux.offsite,
                "configure",
                side_effect=RuntimeError("another mutating vwctl operation holds the lock"),
            ),
            contextlib.redirect_stderr(io.StringIO()) as errors,
        ):
            code = recovery_ux.main(
                ["recovery", "offsite", "configure", "--remote", "cloud:backups"]
            )
        self.assertEqual(code, 1)
        self.assertIn("FAIL: another mutating vwctl operation", errors.getvalue())
        self.assertNotIn("Traceback", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
