from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import recovery_ux, setup, setup_frontend

OFFLINE = "age1" + "q" * 58


def install_args(*extra: str) -> list[str]:
    return [
        "install",
        "--domain",
        "example.net",
        "--url",
        "https://example.net",
        "--email",
        "admin@example.net",
        "--data-device",
        "/dev/vdb",
        "--confirm-format",
        "--auto",
        *extra,
    ]


class AutoOfflineRecoverySetupTests(unittest.TestCase):
    def test_auto_tty_without_recipient_uses_generated_custody_flow(self) -> None:
        with mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True):
            self.assertTrue(setup_frontend._should_generate(install_args()))

    def test_auto_tty_explicit_recipient_forms_do_not_generate(self) -> None:
        forms = (
            ["--offline-recipient", OFFLINE],
            [f"--offline-recipient={OFFLINE}"],
            [f"--offline-recip={OFFLINE}"],
        )
        for form in forms:
            with self.subTest(form=form), mock.patch.object(
                setup_frontend.sys.stdin, "isatty", return_value=True
            ):
                self.assertFalse(setup_frontend._should_generate(install_args(*form)))

    def test_explicit_recipient_reaches_setup_main_unchanged(self) -> None:
        forms = (
            ["--offline-recipient", OFFLINE],
            [f"--offline-recipient={OFFLINE}"],
        )
        for form in forms:
            args = install_args(*form)
            with self.subTest(form=form):
                with (
                    mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True),
                    mock.patch.object(setup_frontend, "_generate_offline_identity") as generate,
                    mock.patch.object(setup_frontend.setup, "main", return_value=0) as setup_main,
                ):
                    self.assertEqual(setup_frontend.main(args), 0)
                generate.assert_not_called()
                setup_main.assert_called_once_with(args)

    def test_headless_auto_without_recipient_fails_before_storage_mutation(self) -> None:
        host = mock.Mock(architecture="amd64")
        with (
            mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=False),
            mock.patch.object(setup_frontend, "_generate_offline_identity") as generate,
            mock.patch.object(setup.os, "geteuid", return_value=0),
            mock.patch.object(setup.install, "validate_host", return_value=host),
            mock.patch.object(setup, "_select_storage", return_value="/dev/vdb"),
            mock.patch.object(setup.storage, "provision") as provision,
        ):
            self.assertEqual(setup_frontend.main(install_args()), 1)
        generate.assert_not_called()
        provision.assert_not_called()

    def test_abbreviated_use_latest_still_gets_confirmation(self) -> None:
        args = [value for value in install_args() if value != "--auto"] + ["--use-lat"]
        with (
            mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True),
            mock.patch.object(setup_frontend.sys.stderr, "isatty", return_value=False),
            mock.patch("builtins.input", return_value="n") as prompt,
        ):
            self.assertFalse(setup_frontend._confirm_use_latest(args))
        prompt.assert_called_once()

    def test_blank_vm_preflights_then_bootstraps_age_before_generated_identity_and_storage(self) -> None:
        events: list[tuple[str, ...] | str] = []
        host = mock.Mock(architecture="amd64")
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            identity = workspace / "offline.age"
            identity.write_text("OFFLINE", encoding="utf-8")

            def fake_select(_args, _ui):
                events.append("preflight")
                return "/dev/vdb"

            def fake_must(argv, label, *, input_text=None, env=None):
                del label, input_text, env
                events.append(tuple(argv))
                return mock.Mock(returncode=0, stdout="", stderr="")

            def fake_generate():
                events.append("generate")
                return workspace, identity, OFFLINE

            def stop_at_provision(*_args, **_kwargs):
                events.append("provision")
                raise setup.storage.StorageError("stop after ordering proof")

            with (
                mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True),
                mock.patch.object(setup.os, "geteuid", return_value=0),
                mock.patch.object(setup.install, "validate_host", return_value=host),
                mock.patch.object(setup, "_select_storage", side_effect=fake_select),
                mock.patch.object(setup.shutil, "which", side_effect=[None, "/usr/bin/age-keygen"]),
                mock.patch.object(setup, "_must", side_effect=fake_must),
                mock.patch.object(setup_frontend, "_generate_offline_identity", side_effect=fake_generate),
                mock.patch.object(setup.storage, "provision", side_effect=stop_at_provision),
            ):
                self.assertEqual(setup_frontend.main(install_args()), 1)

        self.assertEqual(
            events,
            [
                "preflight",
                ("apt-get", "update"),
                ("apt-get", "install", "-y", "age"),
                ("/usr/bin/age-keygen", "--version"),
                "generate",
                "provision",
            ],
        )

    def test_age_bootstrap_failure_stops_after_preflight_before_private_identity_or_storage(self) -> None:
        host = mock.Mock(architecture="amd64")
        with (
            mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True),
            mock.patch.object(setup.os, "geteuid", return_value=0),
            mock.patch.object(setup.install, "validate_host", return_value=host),
            mock.patch.object(setup, "_select_storage", return_value="/dev/vdb") as select_storage,
            mock.patch.object(
                setup,
                "ensure_recovery_custody_tooling",
                side_effect=setup.SetupError("Age recovery tooling installation failed: apt unavailable"),
            ),
            mock.patch.object(setup_frontend, "_generate_offline_identity") as generate,
            mock.patch.object(setup.storage, "provision") as provision,
        ):
            self.assertEqual(setup_frontend.main(install_args()), 1)
        select_storage.assert_called_once()
        generate.assert_not_called()
        provision.assert_not_called()

    def test_auto_tty_generated_identity_enters_existing_recovery_kit_handoff(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / "workspace"
            workspace.mkdir()
            identity = workspace / "offline.age"
            identity.write_text("OFFLINE", encoding="utf-8")
            kit = root / "kit.zip"
            kit.write_bytes(b"encrypted")
            args = install_args()
            captured: dict[str, object] = {}

            def fake_setup_main(argv, *, offline_recipient_factory=None):
                captured["argv"] = list(argv)
                self.assertIsNotNone(offline_recipient_factory)
                captured["recipient"] = offline_recipient_factory()
                return 0

            with (
                mock.patch.object(setup_frontend.sys.stdin, "isatty", return_value=True),
                mock.patch.object(
                    setup_frontend,
                    "_generate_offline_identity",
                    return_value=(workspace, identity, OFFLINE),
                ),
                mock.patch.object(setup_frontend.setup, "main", side_effect=fake_setup_main),
                mock.patch.object(
                    setup_frontend.recovery_ux,
                    "export_recovery_kit",
                    return_value=recovery_ux.KitResult(kit, recovery_ux.KIT_MEMBERS, False),
                ) as export,
                mock.patch("builtins.input", return_value="SAVED"),
            ):
                self.assertEqual(setup_frontend.main(args), 0)
            self.assertEqual(captured["argv"], args)
            self.assertEqual(captured["recipient"], OFFLINE)
            export.assert_called_once_with(identity)
            self.assertFalse(workspace.exists())
            self.assertFalse(identity.exists())


if __name__ == "__main__":
    unittest.main()
