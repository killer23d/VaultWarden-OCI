from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from vaultwarden_oci import cli

COMPONENTS = '''
[components]
vaultwarden = "1.37.1"
caddy = "2.11.4"
caddy_dns_cloudflare = "v0.2.4"
'''


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
        missing = cli.run_command(["vwctl-command-that-does-not-exist-phase3"])
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

    def test_status_notification_warning_does_not_fail_runtime_health(self) -> None:
        from vaultwarden_oci import notification, recovery, runtime

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
        version = self.run_vwctl("--version")
        self.assertEqual(version.stdout.strip(), "vwctl 0.1.0-dev")
        versions = self.run_vwctl("versions")
        self.assertEqual(versions.returncode, 0, versions.stderr)
        self.assertIn("vaultwarden 1.37.1", versions.stdout)
        self.assertIn("caddy 2.11.4", versions.stdout)

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

    def test_doctor_json_has_phase3_stable_ids(self) -> None:
        result = self.run_vwctl("doctor", "--json")
        self.assertIn(result.returncode, {0, 1}, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual([item["id"] for item in payload["checks"]], list(cli.DOCTOR_CHECK_IDS))


if __name__ == "__main__":
    unittest.main()