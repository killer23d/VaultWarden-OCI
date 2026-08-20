from __future__ import annotations

import hashlib
import io
import json
import os
import shutil
import sqlite3
import tarfile
import tempfile
import unittest
from pathlib import Path

from vaultwarden_oci import recovery
from vaultwarden_oci.cli import CommandResult

OFFLINE = "age1" + "q" * 58
AGE_HEADER = b"age-encryption.org/v1\n"


def result(argv, stdout="", stderr="", code=0):
    return CommandResult(tuple(argv), "success" if code == 0 else "nonzero", code, stdout, stderr)


def make_paths(root: Path) -> recovery.RecoveryPaths:
    return recovery.RecoveryPaths(
        backups=root / "backups",
        state_file=root / "state/recovery.json",
        config=root / "etc/config.toml",
        encrypted_secrets=root / "etc/secrets.sops.yaml",
        data=root / "data",
        caddy_data=root / "caddy/data",
        caddy_config=root / "caddy/config",
        lock=root / "run/lock",
    )


def seed(paths: recovery.RecoveryPaths) -> None:
    paths.config.parent.mkdir(parents=True)
    paths.config.write_text("schema_version = 1\n", encoding="utf-8")
    paths.encrypted_secrets.write_text("sops: encrypted\n", encoding="utf-8")
    paths.data.mkdir(parents=True)
    db = sqlite3.connect(paths.data / "db.sqlite3")
    db.execute("create table items (name text)")
    db.execute("insert into items values ('before-backup')")
    db.commit()
    db.close()
    (paths.data / "attachments").mkdir()
    (paths.data / "attachments/a.txt").write_text("attachment", encoding="utf-8")
    paths.caddy_data.mkdir(parents=True)
    paths.caddy_config.mkdir(parents=True)
    (paths.caddy_data / "cert-state").write_text("cert", encoding="utf-8")
    (paths.caddy_config / "config-state").write_text("config", encoding="utf-8")
    paths.backups.mkdir(parents=True)
    paths.lock.parent.mkdir(parents=True)


class FakeRunner:
    def __init__(self, *, good_identity="GOOD", remote_download_fails=False):
        self.good_identity = good_identity
        self.remote_download_fails = remote_download_fails
        self.calls: list[tuple[str, ...]] = []
        self.remote: dict[str, bytes] = {}
        self.remote_entries = [
            {"Name": "recovery-20260820T030000Z-c.vwrec"},
            {"Name": "recovery-20260820T020000Z-b.vwrec"},
            {"Name": "recovery-20260820T010000Z-a.vwrec"},
        ]

    def __call__(self, argv, *, env=None, cwd=None):
        call = tuple(argv)
        self.calls.append(call)
        if call[:2] == ("age", "--encrypt"):
            output = Path(call[call.index("--output") + 1])
            source = Path(call[-1])
            output.write_bytes(AGE_HEADER + source.read_bytes())
            return result(argv)
        if call[:2] == ("age", "--decrypt"):
            identity = Path(call[call.index("--identity") + 1])
            if identity.read_text(encoding="utf-8") != self.good_identity:
                return result(argv, stderr="wrong identity", code=1)
            output = Path(call[call.index("--output") + 1])
            payload = Path(call[-1]).read_bytes()
            if not payload.startswith(AGE_HEADER):
                return result(argv, stderr="corrupt", code=1)
            output.write_bytes(payload[len(AGE_HEADER):])
            return result(argv)
        if call[:2] == ("docker", "version"):
            return result(argv, "28.0\n")
        if call[:3] == ("docker", "container", "inspect"):
            return result(argv, stderr="Error: No such object", code=1)
        if call == ("rclone", "version"):
            return result(argv, "rclone v1.70\n")
        if call == ("rclone", "config", "file"):
            return result(argv, "Configuration file is at /root/.config/rclone/rclone.conf\n")
        if call == ("rclone", "listremotes"):
            return result(argv, "offsite:\n")
        if call[:3] == ("rclone", "lsf", "offsite:"):
            return result(argv)
        if call[:2] == ("rclone", "copyto"):
            source, destination = call[2], call[3]
            if ":" not in source and destination.startswith("offsite:"):
                self.remote[destination] = Path(source).read_bytes()
                return result(argv)
            if source.startswith("offsite:") and ":" not in destination:
                if self.remote_download_fails:
                    return result(argv, stderr="download failed", code=1)
                Path(destination).write_bytes(self.remote[source])
                return result(argv)
        if call[:3] == ("rclone", "lsjson", "offsite:recovery"):
            return result(argv, json.dumps(self.remote_entries))
        if call[:2] == ("rclone", "deletefile"):
            return result(argv)
        raise AssertionError(call)


class RecoveryIntegrationTests(unittest.TestCase):
    def test_real_temp_sqlite_backup_restore_and_age_key_exclusion(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = make_paths(Path(directory))
            seed(paths)
            runner = FakeRunner()
            verified = recovery.create_recovery(OFFLINE, paths=paths, runner=runner)
            self.assertTrue(verified.artifact.name.endswith(".vwrec"))
            self.assertFalse(any(path.name.endswith(".partial") for path in paths.backups.iterdir()))
            self.assertNotIn(b"age-key.txt", verified.artifact.read_bytes())

            db = sqlite3.connect(paths.data / "db.sqlite3")
            db.execute("delete from items")
            db.execute("insert into items values ('after-backup')")
            db.commit()
            db.close()
            paths.config.write_text("mutated = true\n", encoding="utf-8")
            identity = Path(directory) / "offline.age"
            identity.write_text("GOOD", encoding="utf-8")

            manifest = recovery.restore_recovery(verified.artifact, identity, paths=paths, runner=runner)
            self.assertEqual(manifest["format_version"], 2)
            db = sqlite3.connect(paths.data / "db.sqlite3")
            self.assertEqual(db.execute("select name from items").fetchone(), ("before-backup",))
            db.close()
            self.assertEqual(paths.config.read_text(encoding="utf-8"), "schema_version = 1\n")
            self.assertEqual((paths.caddy_data / "cert-state").read_text(encoding="utf-8"), "cert")

    def test_wrong_key_corruption_incomplete_manifest_and_preflight_fail_before_stop(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = make_paths(root)
            seed(paths)
            runner = FakeRunner()
            verified = recovery.create_recovery(OFFLINE, paths=paths, runner=runner)
            wrong = root / "wrong.age"
            wrong.write_text("WRONG", encoding="utf-8")
            with self.assertRaisesRegex(recovery.RecoveryError, "Age decryption"):
                recovery.restore_recovery(verified.artifact, wrong, paths=paths, runner=runner)

            good = root / "good.age"
            good.write_text("GOOD", encoding="utf-8")
            corrupt = root / "corrupt.vwrec"
            corrupt.write_bytes(AGE_HEADER + b"not a tar archive" * 8)
            with self.assertRaises(recovery.RecoveryError):
                recovery.restore_recovery(corrupt, good, paths=paths, runner=runner)

            incomplete = root / "incomplete.vwrec"
            payload = root / "badpayload"
            (payload / "payload/etc").mkdir(parents=True)
            (payload / "payload/data").mkdir(parents=True)
            (payload / "payload/etc/config.toml").write_text("x", encoding="utf-8")
            manifest = {
                "format": "vaultwarden-oci-recovery",
                "format_version": 2,
                "created_at": "2026-08-20T00:00:00Z",
                "files": [{
                    "path": "payload/etc/config.toml",
                    "sha256": hashlib.sha256(b"x").hexdigest(),
                    "size": 1,
                }],
            }
            (payload / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            raw = io.BytesIO()
            with tarfile.open(fileobj=raw, mode="w") as tar:
                tar.add(payload / "manifest.json", arcname="manifest.json")
                tar.add(payload / "payload", arcname="payload")
            incomplete.write_bytes(AGE_HEADER + raw.getvalue())
            with self.assertRaisesRegex(recovery.RecoveryError, "incomplete"):
                recovery.restore_recovery(incomplete, good, paths=paths, runner=runner)

            symlink_target = root / "unsafe-config"
            symlink_target.write_text("unsafe", encoding="utf-8")
            paths.config.unlink()
            paths.config.symlink_to(symlink_target)
            before = len(runner.calls)
            with self.assertRaisesRegex(recovery.RecoveryError, "regular file"):
                recovery.restore_recovery(verified.artifact, good, paths=paths, runner=runner)
            restore_calls = runner.calls[before:]
            self.assertFalse(any(call[:2] == ("docker", "version") for call in restore_calls))


class RcloneTests(unittest.TestCase):
    def test_publish_is_copyto_then_remote_verify_and_never_sync(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = make_paths(root)
            paths.backups.mkdir(parents=True)
            artifact = paths.backups / "recovery-20260820T000000Z-a.vwrec"
            artifact.write_bytes(AGE_HEADER + b"x" * 128)
            verified = recovery.VerifiedRecovery(
                artifact, recovery._sha256(artifact), artifact.stat().st_size, "2026-08-20T00:00:00Z"
            )
            runner = FakeRunner()
            destination = recovery.publish_offsite(verified, "offsite:recovery", paths=paths, runner=runner)
            self.assertEqual(destination, "offsite:recovery/" + artifact.name)
            copy_calls = [call for call in runner.calls if call[:2] == ("rclone", "copyto")]
            self.assertEqual(len(copy_calls), 2)
            self.assertEqual(copy_calls[0][2], str(artifact))
            self.assertEqual(copy_calls[1][2], destination)
            self.assertFalse(any("sync" in call for call in runner.calls))

            bad_runner = FakeRunner(remote_download_fails=True)
            with self.assertRaisesRegex(recovery.RecoveryError, "remote verification"):
                recovery.publish_offsite(verified, "offsite:recovery", paths=paths, runner=bad_runner)

    def test_explicit_pruning_plan_and_delete_argv(self) -> None:
        runner = FakeRunner()
        plan = recovery.prune_remote("offsite:recovery", 2, confirm=False, runner=runner)
        self.assertEqual(plan.keep, ("recovery-20260820T030000Z-c.vwrec", "recovery-20260820T020000Z-b.vwrec"))
        self.assertEqual(plan.delete, ("recovery-20260820T010000Z-a.vwrec",))
        self.assertFalse(any(call[:2] == ("rclone", "deletefile") for call in runner.calls))
        recovery.prune_remote("offsite:recovery", 2, confirm=True, runner=runner)
        deletes = [call for call in runner.calls if call[:2] == ("rclone", "deletefile")]
        self.assertEqual(deletes[-1], ("rclone", "deletefile", "offsite:recovery/recovery-20260820T010000Z-a.vwrec"))
        self.assertFalse(any("sync" in call for call in runner.calls))


if __name__ == "__main__":
    unittest.main()
