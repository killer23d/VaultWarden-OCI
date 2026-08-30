from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from vaultwarden_oci import cli, update_candidate


def result(argv) -> cli.CommandResult:
    return cli.CommandResult(tuple(argv), "success", 0, "", "")


def frozen_versions():
    def pin(name: str, reference: str):
        return SimpleNamespace(name=name, reference=reference)

    return SimpleNamespace(
        vaultwarden_image=pin("vaultwarden", "vaultwarden:test"),
        caddy_builder_image=pin("caddy_builder", "caddy-builder:test"),
        caddy_runtime_image=pin("caddy_runtime", "caddy-runtime:test"),
        caddy_image="vaultwarden-oci-caddy:test",
        project_version="0.1.0-test",
    )


class CandidateCaddyValidationTests(unittest.TestCase):
    def test_prepare_uses_shared_nonsecret_caddy_validation_sentinels(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            versions = root / "versions.toml"
            versions.write_text("candidate\n", encoding="utf-8")
            render_root = root / "render"
            secret_token = "operator-cloudflare-token-must-not-enter-validation-argv"
            calls: list[tuple[str, ...]] = []
            frozen = frozen_versions()
            config = SimpleNamespace(
                domain="vault.example.net",
                acme_email="admin@example.net",
                offline_recovery_recipient="age1" + "q" * 58,
            )

            def runner(argv, **_kwargs):
                calls.append(tuple(argv))
                return result(argv)

            with (
                mock.patch.object(update_candidate, "resolve_pinned_file", return_value=frozen),
                mock.patch.object(update_candidate, "_ensure_compose_features"),
                mock.patch.object(update_candidate.runtime, "load_config", return_value=config),
                mock.patch.object(
                    update_candidate.secrets,
                    "load",
                    return_value={
                        "cloudflare_api_token": secret_token,
                        "vaultwarden_admin_token": "valid-admin-password",
                        "admin_basic_auth_password": "valid-basic-password",
                    },
                ),
                mock.patch.object(update_candidate.secrets, "admin_enabled", return_value=True),
                mock.patch.object(update_candidate.runtime, "render"),
                mock.patch.object(update_candidate, "_bundle_digest", return_value="d" * 64),
            ):
                update_candidate.prepare(versions, render_root, runner=runner)

        caddy_call = next(
            call for call in calls
            if call[:3] == ("docker", "run", "--rm") and "validate" in call
        )
        self.assertIn(
            f"CLOUDFLARE_API_TOKEN={update_candidate.CADDY_VALIDATION_API_TOKEN}",
            caddy_call,
        )
        self.assertIn(
            f"ADMIN_BASIC_AUTH_HASH={update_candidate.CADDY_VALIDATION_BASIC_AUTH_HASH}",
            caddy_call,
        )
        self.assertNotIn(secret_token, "\n".join(caddy_call))
        self.assertEqual(len(update_candidate.CADDY_VALIDATION_API_TOKEN), 40)
        self.assertTrue(
            all(
                char.isascii() and (char.isalnum() or char in "_-")
                for char in update_candidate.CADDY_VALIDATION_API_TOKEN
            )
        )
        self.assertEqual(len(update_candidate.CADDY_VALIDATION_BASIC_AUTH_HASH), 60)
        self.assertTrue(update_candidate.CADDY_VALIDATION_BASIC_AUTH_HASH.startswith("$2a$14$"))

    def test_activate_materializes_admin_phc_without_mutating_sops_source_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            versions = root / "versions.toml"
            versions.write_text("candidate\n", encoding="utf-8")
            render_root = root / "render"
            render_root.mkdir()
            frozen = frozen_versions()
            config = SimpleNamespace(
                domain="vault.example.net",
                offline_recovery_recipient="age1" + "q" * 58,
            )
            source_token = "retained-source-admin-password"
            source_values = {
                "cloudflare_api_token": "cloudflare-token",
                "vaultwarden_admin_token": source_token,
                "admin_basic_auth_password": "basic-password",
            }
            source_snapshot = dict(source_values)
            derived_phc = "$argon2id$v=19$m=65540,t=3,p=4$YWJjZA$ZWZnaA"
            captured: dict[str, object] = {}

            def runner(argv, **_kwargs):
                return result(argv)

            def capture_materialize(values, *, derived, paths, **_kwargs):
                captured["values"] = dict(values)
                captured["derived"] = dict(derived)
                captured["paths"] = paths

            manifest = {
                "schema_version": 1,
                "project_version": frozen.project_version,
                "caddy_image": frozen.caddy_image,
                "admin_enabled": True,
                "render_sha256": "d" * 64,
            }

            with (
                mock.patch.object(update_candidate, "resolve_pinned_file", return_value=frozen),
                mock.patch.object(update_candidate, "_load_manifest", return_value=manifest),
                mock.patch.object(update_candidate, "_ensure_compose_features"),
                mock.patch.object(update_candidate.runtime, "validate_service_identities"),
                mock.patch.object(update_candidate.runtime, "ensure_paths"),
                mock.patch.object(update_candidate.runtime, "load_config", return_value=config),
                mock.patch.object(update_candidate.edge, "refresh_origin_policy"),
                mock.patch.object(update_candidate.secrets, "load", return_value=source_values),
                mock.patch.object(update_candidate.secrets, "admin_enabled", return_value=True),
                mock.patch.object(update_candidate.runtime, "render"),
                mock.patch.object(update_candidate, "_bundle_digest", return_value="d" * 64),
                mock.patch.object(update_candidate, "_bundle_files", return_value=()),
                mock.patch.object(
                    update_candidate.secrets,
                    "derive_admin_basic_auth_hash",
                    return_value="$2a$14$derived-basic-auth-hash",
                ) as basic_hash,
                mock.patch.object(
                    update_candidate.admin,
                    "derive_vaultwarden_admin_phc",
                    return_value=derived_phc,
                ) as admin_hash,
                mock.patch.object(
                    update_candidate.secrets,
                    "materialize",
                    side_effect=capture_materialize,
                ),
            ):
                update_candidate.activate(versions, render_root, runner=runner)

        self.assertEqual(source_values, source_snapshot)
        self.assertEqual(captured["values"]["vaultwarden_admin_token"], derived_phc)
        self.assertNotEqual(captured["values"]["vaultwarden_admin_token"], source_token)
        self.assertEqual(captured["derived"]["admin_basic_auth_hash"], "$2a$14$derived-basic-auth-hash")
        admin_hash.assert_called_once_with(source_token, frozen.vaultwarden_image.reference)
        basic_hash.assert_called_once_with(
            source_values["admin_basic_auth_password"],
            frozen.caddy_runtime_image.reference,
        )


if __name__ == "__main__":
    unittest.main()
