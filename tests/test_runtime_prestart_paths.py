"""Regression coverage for stopped-to-start runtime-path diagnostics.

No host services, real /run paths, secrets, or Docker are touched. The fixture
uses a private temporary tree and the existing runtime implementation owner.
"""
from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import runtime, secrets


class PrestartRuntimePathsTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.paths = runtime.Paths(
            config=root / "config.toml",
            data=root / "data",
            caddy_data=root / "caddy/data",
            caddy_config=root / "caddy/config",
            caddy_log=root / "caddy/log",
            vaultwarden_log=root / "vaultwarden/log",
            run=root / "run",
            transient=root / "run/transient",
            lock=root / "run/lock",
            secret_root=root / "run/secrets",
        )
        self.uid = os.geteuid()
        self.gid = os.getegid()

    def check(self):
        return runtime.runtime_paths_check(
            self.paths,
            uid=self.uid,
            gid=self.gid,
            vaultwarden_uid=self.uid,
            vaultwarden_gid=self.gid,
            caddy_uid=self.uid,
            caddy_gid=self.gid,
            check_service_identities=False,
        )

    def base(self) -> None:
        self.paths.run.mkdir(mode=0o700)
        self.paths.transient.mkdir(mode=0o700)
        self.paths.secret_root.mkdir(mode=0o700)
        self.paths.lock.touch(mode=0o600)
        os.chmod(self.paths.run, 0o700)
        os.chmod(self.paths.transient, 0o700)
        os.chmod(self.paths.secret_root, 0o700)
        os.chmod(self.paths.lock, 0o600)

    def materialize(self) -> None:
        runtime.ensure_paths(
            self.paths,
            uid=self.uid,
            gid=self.gid,
            vaultwarden_uid=self.uid,
            vaultwarden_gid=self.gid,
            caddy_uid=self.uid,
            caddy_gid=self.gid,
        )

    def test_missing_base_is_fail_closed_without_creating_it(self) -> None:
        result = self.check()
        self.assertEqual((result.check_id, result.status), ("runtime.paths", "FAIL"))
        self.assertIn("missing directory", result.message)
        self.assertFalse(self.paths.run.exists())

    def test_worker_transient_file_does_not_count_as_application_start(self) -> None:
        self.base()
        worker_config = self.paths.transient / "crowdsec-cloudflare-worker-bouncer.yaml"
        worker_config.write_text("# test fixture only\n", encoding="utf-8")
        before = self.check()
        self.assertEqual(before.status, "SKIP")
        self.assertEqual(before.message, "runtime paths are not materialized yet")
        self.assertFalse(self.paths.data.exists())
        self.materialize()
        after = self.check()
        self.assertEqual(after.status, "PASS")
        self.assertEqual(worker_config.read_text(encoding="utf-8"), "# test fixture only\n")

    def test_real_crowdsec_log_precedes_application_directory_materialization(self) -> None:
        """CrowdSec legitimately owns its log before the supported first start."""
        from vaultwarden_oci import edge

        self.base()
        edge._prepare_vaultwarden_log(self.paths.vaultwarden_log_file)
        self.assertTrue(self.paths.vaultwarden_log_path.is_dir())
        self.assertTrue(self.paths.vaultwarden_log_file.is_file())
        self.assertFalse(self.paths.data.exists())
        self.assertFalse(self.paths.caddy_data.exists())
        self.assertFalse(self.paths.secret_paths().vaultwarden.exists())

        before = self.check()
        self.assertEqual(before.status, "FAIL")
        self.assertEqual(
            before.message,
            "runtime paths are only partially materialized",
        )

        self.materialize()
        after = self.check()
        self.assertEqual(after.status, "PASS")
        self.assertEqual(
            self.paths.vaultwarden_log_file.stat().st_mode & 0o777,
            0o600,
        )

    def test_worker_partial_base_is_not_hidden_by_stopped_state(self) -> None:
        self.paths.run.mkdir(mode=0o700)
        self.paths.transient.mkdir(mode=0o700)
        (self.paths.transient / "crowdsec-cloudflare-worker-bouncer.yaml").touch()
        result = self.check()
        self.assertEqual(result.status, "FAIL")
        self.assertIn(str(self.paths.secret_root), result.message)
        self.assertIn(str(self.paths.lock), result.message)
        self.assertFalse(self.paths.secret_root.exists())
        self.assertFalse(self.paths.lock.exists())

    def test_partial_persistent_application_paths_remain_fail_closed(self) -> None:
        self.base()
        self.paths.data.mkdir(mode=0o700)
        result = self.check()
        self.assertEqual(result.status, "FAIL")
        self.assertEqual(result.message, "runtime paths are only partially materialized")
        self.assertFalse(self.paths.caddy_data.exists())

    def test_wrong_lock_mode_is_reported_but_not_repaired(self) -> None:
        self.base()
        os.chmod(self.paths.lock, 0o644)
        result = self.check()
        self.assertEqual(result.status, "FAIL")
        self.assertIn("incompatible ownership/mode", result.message)
        self.assertEqual(self.paths.lock.stat().st_mode & 0o777, 0o644)

    def test_symlinked_transient_directory_is_rejected_without_following(self) -> None:
        self.base()
        elsewhere = Path(self._tmp.name) / "elsewhere"
        elsewhere.mkdir()
        self.paths.transient.rmdir()
        self.paths.transient.symlink_to(elsewhere, target_is_directory=True)
        result = self.check()
        self.assertEqual(result.status, "FAIL")
        self.assertIn("expected directory", result.message)
        self.assertTrue(self.paths.transient.is_symlink())

    def test_partial_rendered_files_fail_after_path_initialization(self) -> None:
        self.base()
        self.materialize()
        self.paths.compose.write_text("# incomplete render\n", encoding="utf-8")
        result = self.check()
        self.assertEqual(result.status, "FAIL")
        self.assertIn("rendered runtime files are only partially materialized", result.message)
        self.assertFalse(self.paths.caddyfile.exists())

    def test_partial_volatile_secrets_fail_without_reading_secret_values(self) -> None:
        self.base()
        self.materialize()
        secret = self.paths.secret_paths().file(secrets.REQUIRED[0])
        secret.touch()
        result = self.check()
        self.assertEqual(result.status, "FAIL")
        self.assertIn("required volatile secret files are only partially materialized", result.message)
        self.assertNotIn(secret.name, result.message)


if __name__ == "__main__":
    unittest.main()
