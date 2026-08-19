from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from vaultwarden_oci import cli


class Phase1UnitTests(unittest.TestCase):
    def test_versions_manifest_valid_and_invalid(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            valid = root / "valid.toml"
            valid.write_text(
                'schema_version = 1\n[vaultwarden_oci]\nversion = "0.1.0-dev"\n',
                encoding="utf-8",
            )
            manifest = cli.load_versions(valid)
            self.assertEqual(manifest.schema_version, 1)
            self.assertEqual(manifest.version, "0.1.0-dev")

            invalid = root / "invalid.toml"
            invalid.write_text(
                'schema_version = 1\n[vaultwarden_oci]\nname = "missing-version"\n',
                encoding="utf-8",
            )
            with self.assertRaises(cli.VersionsError):
                cli.load_versions(invalid)

    def test_architecture_normalization_and_unsupported(self) -> None:
        aliases = {
            "amd64": "amd64",
            "x86_64": "amd64",
            "arm64": "arm64",
            "aarch64": "arm64",
        }
        for source, expected in aliases.items():
            with self.subTest(source=source):
                self.assertEqual(cli.normalize_architecture(source), expected)

        with self.assertRaises(cli.UnsupportedArchitecture):
            cli.normalize_architecture("ppc64le")

    def test_subprocess_success_nonzero_and_not_found(self) -> None:
        success = cli.run_command([sys.executable, "-c", "print('ok')"])
        self.assertTrue(success.ok)
        self.assertEqual(success.kind, "success")
        self.assertEqual(success.returncode, 0)
        self.assertEqual(success.stdout.strip(), "ok")

        nonzero = cli.run_command(
            [sys.executable, "-c", "import sys; print('bad', file=sys.stderr); sys.exit(7)"]
        )
        self.assertFalse(nonzero.ok)
        self.assertEqual(nonzero.kind, "nonzero")
        self.assertEqual(nonzero.returncode, 7)
        self.assertEqual(nonzero.stderr.strip(), "bad")

        missing = cli.run_command(["vwctl-command-that-does-not-exist-phase1"])
        self.assertFalse(missing.ok)
        self.assertEqual(missing.kind, "not_found")
        self.assertIsNone(missing.returncode)


class Phase1IntegrationTests(unittest.TestCase):
    def run_vwctl(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(ROOT / "vwctl"), *args],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_config_validate_valid_and_invalid_toml(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            valid = root / "config.toml"
            valid.write_text('site_name = "example"\n', encoding="utf-8")
            result = self.run_vwctl("config", "validate", "--file", str(valid))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS", result.stdout)

            invalid = root / "broken.toml"
            invalid.write_text('site_name = "unterminated\n', encoding="utf-8")
            result = self.run_vwctl("config", "validate", "--file", str(invalid))
            self.assertEqual(result.returncode, 1)
            self.assertIn("FAIL", result.stderr)

    def test_real_temp_lock_contention(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            lock_path = Path(directory) / "vwctl.lock"
            holder_code = textwrap.dedent(
                """
                import sys
                import time
                from pathlib import Path
                from vaultwarden_oci.cli import mutation_lock

                with mutation_lock(Path(sys.argv[1])):
                    print("locked", flush=True)
                    time.sleep(30)
                """
            )
            env = os.environ.copy()
            env["PYTHONPATH"] = str(ROOT)
            holder = subprocess.Popen(
                [sys.executable, "-c", holder_code, str(lock_path)],
                cwd=ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                self.assertIsNotNone(holder.stdout)
                ready = holder.stdout.readline().strip()
                self.assertEqual(ready, "locked")
                with self.assertRaises(cli.LockBusyError):
                    with cli.mutation_lock(lock_path):
                        self.fail("contended mutation lock unexpectedly acquired")
            finally:
                holder.terminate()
                try:
                    holder.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    holder.kill()
                    holder.wait(timeout=5)
                if holder.stdout is not None:
                    holder.stdout.close()
                if holder.stderr is not None:
                    holder.stderr.close()

    def test_doctor_json_shape_and_stable_check_ids(self) -> None:
        result = self.run_vwctl("doctor", "--json")
        self.assertIn(result.returncode, {0, 1}, result.stderr)
        payload = json.loads(result.stdout)

        self.assertEqual(payload["schema_version"], 1)
        self.assertIn(payload["overall"], cli.DOCTOR_STATUSES)
        self.assertIsInstance(payload["checks"], list)
        self.assertEqual(
            [check["id"] for check in payload["checks"]],
            list(cli.DOCTOR_CHECK_IDS),
        )
        for check in payload["checks"]:
            self.assertEqual(set(check), {"id", "status", "message"})
            self.assertIn(check["status"], cli.DOCTOR_STATUSES)

    def test_public_help_version_and_versions(self) -> None:
        help_result = self.run_vwctl("--help")
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("doctor", help_result.stdout)
        self.assertIn("versions", help_result.stdout)

        version_result = self.run_vwctl("--version")
        self.assertEqual(version_result.returncode, 0, version_result.stderr)
        self.assertEqual(version_result.stdout.strip(), "vwctl 0.1.0-dev")

        versions_result = self.run_vwctl("versions")
        self.assertEqual(versions_result.returncode, 0, versions_result.stderr)
        self.assertEqual(versions_result.stdout.strip(), "vaultwarden-oci 0.1.0-dev")


if __name__ == "__main__":
    unittest.main()
