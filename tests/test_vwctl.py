from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from vaultwarden_oci import cli, install, update_cli, update_versions

CURRENT_RELEASE_VERSION = cli.load_versions(ROOT / "versions.toml").version
COMPONENTS = '''
[components]
vaultwarden = "1.37.1"
caddy = "2.11.4"
caddy_dns_cloudflare = "v0.2.4"
caddy_cloudflare_ip = "f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5"
caddy_combine_ip_ranges = "v0.0.1"
caddy_ratelimit = "v0.1.0"
'''


def digest(char: str) -> str:
    return "sha256:" + char * 64


def latest_frozen() -> update_versions.FrozenVersions:
    return update_versions.FrozenVersions(
        "latest",
        "amd64",
        "0.1.0-dev.7.latest.test",
        "1.40.0",
        "2.12.0",
        "v0.3.0",
        update_versions.ImagePin("vaultwarden", "vaultwarden/server", "1.40.0", digest("a")),
        update_versions.ImagePin("caddy_builder", "caddy", "2.12.0-builder-alpine", digest("b")),
        update_versions.ImagePin("caddy_runtime", "caddy", "2.12.0-alpine", digest("c")),
        caddy_cloudflare_ip="f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5",
        caddy_combine_ip_ranges="v0.0.1",
        caddy_ratelimit="v0.1.0",
    )


class VwctlUnitTests(unittest.TestCase):
    def test_versions_manifest_exact_pins(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            valid = Path(directory) / "versions.toml"
            valid.write_text(
                'schema_version = 1\n[vaultwarden_oci]\nversion = "0.1.0-dev"\n' + COMPONENTS,
                encoding="utf-8",
            )
            manifest = cli.load_versions(valid, require_components=True)
            self.assertEqual(manifest.version, "0.1.0-dev")
            self.assertEqual(manifest.vaultwarden, "1.37.1")
            invalid = Path(directory) / "invalid.toml"
            invalid.write_text(
                'schema_version = 1\n[vaultwarden_oci]\nversion = "0.1.0-dev"\n'
                '[components]\nvaultwarden = "latest"\ncaddy = "2.11.4"\n'
                'caddy_dns_cloudflare = "v0.2.4"\n',
                encoding="utf-8",
            )
            with self.assertRaises(cli.VersionsError):
                cli.load_versions(invalid, require_components=True)

    def test_architecture_and_subprocess_boundary(self) -> None:
        self.assertEqual(cli.normalize_architecture("x86_64"), "amd64")
        self.assertEqual(cli.normalize_architecture("aarch64"), "arm64")
        with self.assertRaises(cli.UnsupportedArchitecture):
            cli.normalize_architecture("ppc64le")
        success = cli.run_command([sys.executable, "-c", "print('ok')"])
        self.assertTrue(success.ok)
        self.assertEqual(success.stdout.strip(), "ok")
        missing = cli.run_command(["vwctl-command-that-does-not-exist"])
        self.assertEqual(missing.kind, "not_found")

    def test_real_temp_lock_contention(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            lock_path = Path(directory) / "vwctl.lock"
            code = textwrap.dedent(
                '''
                import sys, time
                from pathlib import Path
                from vaultwarden_oci.cli import mutation_lock
                with mutation_lock(Path(sys.argv[1])):
                    print("locked", flush=True)
                    time.sleep(30)
                '''
            )
            env = os.environ.copy()
            env["PYTHONPATH"] = str(ROOT)
            holder = subprocess.Popen(
                [sys.executable, "-c", code, str(lock_path)],
                cwd=ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                self.assertIsNotNone(holder.stdout)
                self.assertEqual(holder.stdout.readline().strip(), "locked")
                with self.assertRaises(cli.LockBusyError):
                    with cli.mutation_lock(lock_path):
                        self.fail("contended lock acquired")
            finally:
                holder.terminate()
                holder.wait(timeout=5)
                if holder.stdout is not None:
                    holder.stdout.close()
                if holder.stderr is not None:
                    holder.stderr.close()

    def test_update_commands_support_explicit_use_latest(self) -> None:
        for action in ("check", "apply"):
            with self.subTest(action=action):
                args = update_cli._update_parser().parse_args([action, "--use-latest"])
                self.assertEqual(args.update_command, action)
                self.assertTrue(args.use_latest)

    def test_latest_install_stays_on_isolated_install_boundary(self) -> None:
        from vaultwarden_oci import recovery, runtime

        frozen = latest_frozen()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "isolated-root"
            output = io.StringIO()
            with (
                mock.patch.object(update_versions, "resolve_latest", return_value=frozen),
                mock.patch.object(
                    install,
                    "install_layout",
                    return_value=str(root / "opt/vaultwarden-oci/releases" / frozen.project_version),
                ) as install_layout,
                mock.patch.object(update_versions, "record_frozen") as record_frozen,
                mock.patch.object(runtime, "lifecycle") as lifecycle,
                mock.patch.object(recovery, "create_recovery") as create_recovery,
                redirect_stdout(output),
            ):
                code = install.main(
                    [
                        "--source",
                        str(ROOT),
                        "--use-latest",
                        "--root",
                        str(root),
                        "--skip-host-check",
                        "--skip-systemd-reload",
                    ]
                )
            self.assertEqual(code, 0)
            install_layout.assert_called_once()
            self.assertEqual(install_layout.call_args.kwargs["root"], root.resolve())
            self.assertFalse(install_layout.call_args.kwargs["require_all_architectures"])
            record_frozen.assert_called_once()
            lifecycle.assert_not_called()
            create_recovery.assert_not_called()

    def test_single_arch_latest_snapshot_is_readable_but_not_a_production_manifest(self) -> None:
        frozen = latest_frozen()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "versions.toml"
            manifest.write_text(update_versions.frozen_versions_toml(frozen), encoding="utf-8")
            reread = update_versions.resolve_pinned_file(manifest, machine="amd64")
            self.assertEqual(reread.vaultwarden_image.reference, frozen.vaultwarden_image.reference)
            self.assertEqual(reread.caddy_builder_image.reference, frozen.caddy_builder_image.reference)
            self.assertEqual(reread.caddy_runtime_image.reference, frozen.caddy_runtime_image.reference)
            with self.assertRaisesRegex(update_versions.UpdateError, "image_digests.vaultwarden.arm64"):
                update_versions.resolve_pinned(root, machine="amd64")

    def test_versions_command_reads_single_arch_latest_snapshot(self) -> None:
        frozen = latest_frozen()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "vaultwarden_oci"
            package.mkdir()
            (root / "versions.toml").write_text(
                update_versions.frozen_versions_toml(frozen), encoding="utf-8"
            )
            output = io.StringIO()
            with (
                mock.patch.object(update_cli, "__file__", str(package / "update_cli.py")),
                mock.patch.object(cli, "main", return_value=0),
                redirect_stdout(output),
            ):
                code = update_cli._versions_command(["versions"])
            self.assertEqual(code, 0)
            self.assertIn(f"vaultwarden_image {frozen.vaultwarden_image.reference}", output.getvalue())
            self.assertIn(f"caddy_builder {frozen.caddy_builder_image.reference}", output.getvalue())
            self.assertIn(f"caddy_runtime {frozen.caddy_runtime_image.reference}", output.getvalue())

    def test_status_notification_warning_does_not_fail_runtime_health(self) -> None:
        from vaultwarden_oci import edge, notification, recovery, runtime

        rows = [
            {"service": "vaultwarden", "state": "running", "health": "healthy"},
            {"service": "caddy", "state": "running", "health": "healthy"},
        ]
        notification_row = {
            "kind": "notification",
            "state": "warning",
            "transport": "https",
            "detail": "provider_rejected at 2026-08-21T06:00:00Z",
        }
        output = io.StringIO()
        with (
            mock.patch.object(runtime, "status", return_value=("running", rows)),
            mock.patch.object(recovery, "status_rows", return_value=[]),
            mock.patch.object(notification, "status_row", return_value=notification_row),
            mock.patch.object(edge, "doctor_checks", return_value=[]),
            redirect_stdout(output),
        ):
            code = cli.main(["status"])
        self.assertEqual(code, 0)
        self.assertIn("notification: warning", output.getvalue())
        self.assertIn("Overall: running", output.getvalue())

    def _notification_doctor_checks(self, notifications_toml: str) -> dict[str, cli.DoctorCheck]:
        from vaultwarden_oci import edge, recovery, runtime

        recipient = "age1" + "q" * 58
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config.toml"
            versions = root / "versions.toml"
            os_release = root / "os-release"
            config.write_text(
                f'''schema_version = 1
[site]
domain = "vault.example.net"
acme_email = "admin@example.net"
[secrets]
offline_recovery_recipient = "{recipient}"
[vaultwarden]
signups_allowed = false
[smtp]
host = "smtp.example.net"
port = 587
security = "starttls"
from_email = "vaultwarden@example.net"
from_name = "Vaultwarden"
timeout_seconds = 15
{notifications_toml}
''',
                encoding="utf-8",
            )
            versions.write_text(
                'schema_version = 1\n[vaultwarden_oci]\nversion = "0.1.0-dev"\n' + COMPONENTS,
                encoding="utf-8",
            )
            os_release.write_text('ID=ubuntu\nVERSION_ID="24.04"\n', encoding="utf-8")
            with (
                mock.patch.object(runtime, "doctor_checks", return_value=[]),
                mock.patch.object(edge, "doctor_checks", return_value=[]),
                mock.patch.object(recovery, "doctor_checks", return_value=[]),
            ):
                checks = cli.doctor_checks(
                    config_path=config,
                    versions_path=versions,
                    os_release_path=os_release,
                    machine="x86_64",
                )
        return {check.check_id: check for check in checks}

    def test_doctor_invalid_notification_provider_is_fail_not_not_configured(self) -> None:
        checks = self._notification_doctor_checks(
            '''[notifications]
provider = "unsupported-provider"
to_email = "ops@example.net"'''
        )
        self.assertEqual(checks["config.toml"].status, "FAIL")
        self.assertEqual(checks["notification.provider"].status, "FAIL")
        self.assertIn("unsupported operational email provider", checks["notification.provider"].message)
        self.assertNotIn("not configured", checks["notification.provider"].message)
        for check_id in ("notification.api_secret", "notification.smtp_fallback"):
            self.assertEqual(checks[check_id].status, "SKIP")
            self.assertEqual(checks[check_id].message, "valid provider configuration is required")

    def test_doctor_invalid_notification_option_is_fail_not_not_configured(self) -> None:
        checks = self._notification_doctor_checks(
            '''[notifications]
provider = "mailgun"
to_email = "ops@example.net"
[notifications.options]
region = "ap"
domain = "mg.example.net"'''
        )
        self.assertEqual(checks["config.toml"].status, "FAIL")
        self.assertEqual(checks["notification.provider"].status, "FAIL")
        self.assertIn("notification provider option region", checks["notification.provider"].message)
        self.assertNotIn("not configured", checks["notification.provider"].message)
        for check_id in ("notification.api_secret", "notification.smtp_fallback"):
            self.assertEqual(checks[check_id].status, "SKIP")
            self.assertEqual(checks[check_id].message, "valid provider configuration is required")


class VwctlIntegrationTests(unittest.TestCase):
    def run_vwctl(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(ROOT / "vwctl"), *args],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_public_commands_and_versions(self) -> None:
        help_result = self.run_vwctl("--help")
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        for command in ("start", "stop", "restart", "status", "logs", "doctor", "versions"):
            self.assertIn(command, help_result.stdout)
        self.assertIn("update check", help_result.stdout)
        self.assertIn("host-upgrade {check,apply}", help_result.stdout)
        version = self.run_vwctl("--version")
        self.assertEqual(version.stdout.strip(), f"vwctl {CURRENT_RELEASE_VERSION}")
        versions = self.run_vwctl("versions")
        self.assertEqual(versions.returncode, 0, versions.stderr)
        self.assertIn("vaultwarden 1.37.1", versions.stdout)
        self.assertIn("caddy 2.11.4", versions.stdout)
        self.assertIn("vaultwarden_image vaultwarden/server:1.37.1@sha256:", versions.stdout)

    def test_update_cli_has_supported_latest_mode(self) -> None:
        for action in ("check", "apply"):
            with self.subTest(action=action):
                result = self.run_vwctl("update", action, "--help")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("--use-latest", result.stdout)

    def test_config_validate_rejects_plaintext_secret_fields(self) -> None:
        recipient = "age1" + "q" * 58
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.toml"
            config.write_text(
                f'''schema_version = 1
[site]
domain = "vault.example.net"
acme_email = "admin@example.net"
[secrets]
offline_recovery_recipient = "{recipient}"
[vaultwarden]
signups_allowed = false
[smtp]
host = "smtp.example.net"
port = 587
security = "starttls"
from_email = "vaultwarden@example.net"
from_name = "Vaultwarden"
timeout_seconds = 15
''',
                encoding="utf-8",
            )
            good = self.run_vwctl("config", "validate", "--file", str(config))
            self.assertEqual(good.returncode, 0, good.stderr)
            config.write_text(
                config.read_text(encoding="utf-8") + 'password = "plaintext"\n',
                encoding="utf-8",
            )
            bad = self.run_vwctl("config", "validate", "--file", str(config))
            self.assertEqual(bad.returncode, 1)
            self.assertIn("FAIL", bad.stderr)

    def test_doctor_json_has_stable_ids(self) -> None:
        result = self.run_vwctl("doctor", "--json")
        self.assertIn(result.returncode, {0, 1}, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual([item["id"] for item in payload["checks"]], list(cli.DOCTOR_CHECK_IDS))


if __name__ == "__main__":
    unittest.main()
