from __future__ import annotations

import hashlib
import io
import json
import os
import re
import sqlite3
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import recovery, secrets
from vaultwarden_oci.cli import CommandResult

OFFLINE = "age1" + "q" * 58
OPERATIONAL = "age1" + "p" * 58
NEW_OPERATIONAL = "age1" + "n" * 58
AGE_HEADER = b"age-encryption.org/v1\n"
VALUES = {
    "cloudflare_api_token": "A" * 40,
    "smtp_username": "mailer@example.net",
    "smtp_password": "smtp-secret",
    "vaultwarden_admin_token": "admin-secret",
    "cloudflare_remediation_token": "B" * 40,
}


def result(argv, stdout="", stderr="", code=0):
    return CommandResult(tuple(argv), "success" if code == 0 else "nonzero", code, stdout, stderr)


def config_text(offline: str = OFFLINE) -> str:
    return f'''schema_version = 1
[site]
domain = "vault.example.net"
acme_email = "admin@example.net"
[secrets]
offline_recovery_recipient = "{offline}"
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


def sops_text(*recipients: str) -> str:
    return "sops:\n  age:\n" + "".join(f"    - recipient: {recipient}\n" for recipient in recipients)


def make_paths(root: Path) -> recovery.RecoveryPaths:
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


def seed(paths: recovery.RecoveryPaths) -> None:
    paths.config.parent.mkdir(parents=True)
    paths.config.write_text(config_text(), encoding="utf-8")
    os.chmod(paths.config, 0o600)
    paths.encrypted_secrets.write_text(sops_text(OPERATIONAL, OFFLINE), encoding="utf-8")
    os.chmod(paths.encrypted_secrets, 0o600)
    paths.operational_age_key.write_text("OPS", encoding="utf-8")
    os.chmod(paths.operational_age_key, 0o600)
    paths.data.mkdir(parents=True)
    db = sqlite3.connect(paths.data / "db.sqlite3")
    db.execute("create table items (name text)")
    db.execute("insert into items values ('before-backup')")
    db.commit()
    db.close()
    (paths.data / "attachments").mkdir()
    (paths.data / "attachments/a.txt").write_text("attachment-before", encoding="utf-8")
    paths.caddy_data.mkdir(parents=True)
    paths.caddy_config.mkdir(parents=True)
    (paths.caddy_data / "cert-state").write_text("cert", encoding="utf-8")
    (paths.caddy_config / "config-state").write_text("config", encoding="utf-8")
    paths.backups.mkdir(parents=True)
    paths.lock.parent.mkdir(parents=True)


def artifact_payload(artifact: Path, destination: Path) -> Path:
    raw = artifact.read_bytes()
    assert raw.startswith(AGE_HEADER)
    tar_path = destination / "artifact.tar"
    tar_path.write_bytes(raw[len(AGE_HEADER):])
    extracted = destination / "artifact"
    extracted.mkdir()
    with tarfile.open(tar_path, "r") as archive:
        archive.extractall(extracted)
    return extracted


class FakeRunner:
    def __init__(
        self,
        *,
        good_identity="GOOD",
        remote_download_fails=False,
        age_encrypt_fails=False,
        containers_running=False,
        on_first_unpause=None,
    ):
        self.good_identity = good_identity
        self.remote_download_fails = remote_download_fails
        self.age_encrypt_fails = age_encrypt_fails
        self.containers_running = containers_running
        self.on_first_unpause = on_first_unpause
        self.unpause_callback_ran = False
        self.paused: set[str] = set()
        self.calls: list[tuple[str, ...]] = []
        self.remote: dict[str, bytes] = {}
        self.remote_entries = [
            {"Name": "recovery-20260820T030000Z-c.vwrec"},
            {"Name": "recovery-20260820T020000Z-b.vwrec"},
            {"Name": "recovery-20260820T010000Z-a.vwrec"},
        ]

    @staticmethod
    def _recipient_for_identity(path: Path) -> str | None:
        try:
            value = path.read_text(encoding="utf-8")
        except OSError:
            return None
        return {
            "GOOD": OFFLINE,
            "OPS": OPERATIONAL,
            "NEW-OPS": NEW_OPERATIONAL,
        }.get(value)

    @staticmethod
    def _recipients(path: Path) -> set[str]:
        return set(re.findall(r"recipient:\s*(age1[0-9a-z]+)", path.read_text(encoding="utf-8")))

    def __call__(self, argv, *, env=None, cwd=None):
        call = tuple(argv)
        self.calls.append(call)
        if call[:2] == ("age-keygen", "-y"):
            recipient = self._recipient_for_identity(Path(call[2]))
            return result(argv, recipient + "\n") if recipient else result(argv, stderr="bad identity", code=1)
        if call[:2] == ("age-keygen", "-o"):
            output = Path(call[2])
            output.write_text("NEW-OPS", encoding="utf-8")
            os.chmod(output, 0o600)
            return result(argv)
        if call[:2] == ("age", "--encrypt"):
            if self.age_encrypt_fails:
                return result(argv, stderr="encryption failed", code=1)
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
        if call[:2] == ("sops", "--decrypt"):
            encrypted = Path(call[-1])
            identity = Path((env or {}).get("SOPS_AGE_KEY_FILE", ""))
            recipient = self._recipient_for_identity(identity)
            if recipient is None or recipient not in self._recipients(encrypted):
                return result(argv, stderr="cannot decrypt", code=1)
            return result(argv, json.dumps(VALUES))
        if call[:3] == ("sops", "rotate", "--in-place"):
            encrypted = Path(call[-1])
            current = self._recipients(encrypted)
            if "--add-age" in call:
                current.add(call[call.index("--add-age") + 1])
            if "--rm-age" in call:
                current -= set(call[call.index("--rm-age") + 1].split(","))
            encrypted.write_text(sops_text(*sorted(current)), encoding="utf-8")
            return result(argv)
        if call[:2] == ("docker", "version"):
            return result(argv, "28.0\n")
        if call[:4] == ("docker", "container", "inspect", "--format"):
            if not self.containers_running:
                return result(argv, stderr="Error: No such object", code=1)
            container = call[-1]
            return result(
                argv,
                json.dumps({"Status": "running", "Paused": container in self.paused}),
            )
        if call[:3] == ("docker", "container", "inspect"):
            return result(argv) if self.containers_running else result(argv, stderr="Error: No such object", code=1)
        if call[:2] == ("docker", "pause"):
            self.paused.add(call[2])
            return result(argv)
        if call[:2] == ("docker", "unpause"):
            self.paused.discard(call[2])
            if not self.unpause_callback_ran and self.on_first_unpause is not None:
                self.unpause_callback_ran = True
                self.on_first_unpause()
            return result(argv)
        if call[:2] in {("docker", "stop"), ("docker", "rm")}:
            self.containers_running = False
            return result(argv)
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
            paths.config.write_text(config_text() + "\n# mutated\n", encoding="utf-8")
            identity = Path(directory) / "offline.age"
            identity.write_text("GOOD", encoding="utf-8")

            manifest = recovery.restore_recovery(verified.artifact, identity, paths=paths, runner=runner)
            self.assertEqual(manifest["format_version"], 2)
            db = sqlite3.connect(paths.data / "db.sqlite3")
            self.assertEqual(db.execute("select name from items").fetchone(), ("before-backup",))
            db.close()
            self.assertEqual(paths.config.read_text(encoding="utf-8"), config_text())
            self.assertEqual((paths.caddy_data / "cert-state").read_text(encoding="utf-8"), "cert")

    def test_backup_rejects_sops_offline_recipient_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = make_paths(Path(directory))
            seed(paths)
            paths.encrypted_secrets.write_text(sops_text(OPERATIONAL), encoding="utf-8")
            os.chmod(paths.encrypted_secrets, 0o600)
            runner = FakeRunner()
            with self.assertRaisesRegex(recovery.RecoveryError, "offline recovery recipient"):
                recovery.create_recovery(OFFLINE, paths=paths, runner=runner)
            self.assertFalse(any(path.suffix == ".vwrec" for path in paths.backups.iterdir()))
            self.assertFalse(any(call[:2] == ("age", "--encrypt") for call in runner.calls))

    def test_fresh_host_restore_rekeys_sops_to_new_operational_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = make_paths(root)
            seed(paths)
            runner = FakeRunner()
            verified = recovery.create_recovery(OFFLINE, paths=paths, runner=runner)
            paths.operational_age_key.write_text("", encoding="utf-8")
            os.chmod(paths.operational_age_key, 0o600)
            identity = root / "offline.age"
            identity.write_text("GOOD", encoding="utf-8")

            recovery.restore_recovery(verified.artifact, identity, paths=paths, runner=runner)
            self.assertEqual(paths.operational_age_key.read_text(encoding="utf-8"), "NEW-OPS")
            self.assertEqual(
                secrets.encrypted_recipients(paths.encrypted_secrets),
                {OFFLINE, NEW_OPERATIONAL},
            )
            self.assertNotIn(OPERATIONAL, secrets.encrypted_recipients(paths.encrypted_secrets))
            rotate_calls = [call for call in runner.calls if call[:3] == ("sops", "rotate", "--in-place")]
            self.assertEqual(len(rotate_calls), 1)
            self.assertIn("--add-age", rotate_calls[0])
            self.assertIn("--rm-age", rotate_calls[0])

    def test_backup_quiesces_file_and_sqlite_state_as_one_stable_copy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = make_paths(root)
            seed(paths)

            def mutate_after_snapshot() -> None:
                (paths.data / "attachments/a.txt").write_text("attachment-after", encoding="utf-8")
                db = sqlite3.connect(paths.data / "db.sqlite3")
                db.execute("update items set name='after-backup'")
                db.commit()
                db.close()

            runner = FakeRunner(containers_running=True, on_first_unpause=mutate_after_snapshot)
            verified = recovery.create_recovery(OFFLINE, paths=paths, runner=runner)
            self.assertEqual((paths.data / "attachments/a.txt").read_text(encoding="utf-8"), "attachment-after")
            with tempfile.TemporaryDirectory() as extract_dir:
                payload = artifact_payload(verified.artifact, Path(extract_dir)) / "payload"
                self.assertEqual(
                    (payload / "data/attachments/a.txt").read_text(encoding="utf-8"),
                    "attachment-before",
                )
                db = sqlite3.connect(payload / "data/db.sqlite3")
                self.assertEqual(db.execute("select name from items").fetchone(), ("before-backup",))
                db.close()
            pause_calls = [call for call in runner.calls if call[:2] == ("docker", "pause")]
            unpause_calls = [call for call in runner.calls if call[:2] == ("docker", "unpause")]
            self.assertEqual(len(pause_calls), 2)
            self.assertEqual(len(unpause_calls), 2)
            self.assertFalse(runner.paused)

    def test_wrong_key_corruption_bad_checksum_incomplete_manifest_and_preflight_before_stop(self) -> None:
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

            with tempfile.TemporaryDirectory() as bad_dir:
                bad_root = Path(bad_dir)
                extracted = artifact_payload(verified.artifact, bad_root)
                (extracted / "payload/data/attachments/a.txt").write_text("tampered", encoding="utf-8")
                raw = io.BytesIO()
                with tarfile.open(fileobj=raw, mode="w") as archive:
                    archive.add(extracted / "manifest.json", arcname="manifest.json")
                    archive.add(extracted / "payload", arcname="payload")
                bad_checksum = root / "bad-checksum.vwrec"
                bad_checksum.write_bytes(AGE_HEADER + raw.getvalue())
            with self.assertRaisesRegex(recovery.RecoveryError, "checksum mismatch"):
                recovery.restore_recovery(bad_checksum, good, paths=paths, runner=runner)

            incomplete = root / "incomplete.vwrec"
            payload = root / "badpayload"
            (payload / "payload/etc").mkdir(parents=True)
            (payload / "payload/data").mkdir(parents=True)
            (payload / "payload/etc/config.toml").write_text("x", encoding="utf-8")
            manifest = {
                "format": "vaultwarden-oci-recovery",
                "format_version": 2,
                "created_at": "2026-08-20T00:00:00Z",
                "files": [
                    {
                        "path": "payload/etc/config.toml",
                        "sha256": hashlib.sha256(b"x").hexdigest(),
                        "size": 1,
                    }
                ],
            }
            (payload / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            raw = io.BytesIO()
            with tarfile.open(fileobj=raw, mode="w") as archive:
                archive.add(payload / "manifest.json", arcname="manifest.json")
                archive.add(payload / "payload", arcname="payload")
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
            self.assertFalse(any(call[:2] == ("docker", "stop") for call in restore_calls))

    def test_permission_failure_is_pre_promotion_and_pre_stop(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = make_paths(root)
            seed(paths)
            runner = FakeRunner()
            verified = recovery.create_recovery(OFFLINE, paths=paths, runner=runner)
            identity = root / "offline.age"
            identity.write_text("GOOD", encoding="utf-8")
            original_config = paths.config.read_text(encoding="utf-8")
            before = len(runner.calls)
            with mock.patch.object(recovery, "_apply_permissions", side_effect=OSError("forced chmod failure")):
                with self.assertRaisesRegex(OSError, "forced chmod failure"):
                    recovery.restore_recovery(verified.artifact, identity, paths=paths, runner=runner)
            self.assertEqual(paths.config.read_text(encoding="utf-8"), original_config)
            restore_calls = runner.calls[before:]
            self.assertFalse(any(call[:2] == ("docker", "stop") for call in restore_calls))

    def test_split_filesystem_free_space_preflight_checks_config_filesystem(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = make_paths(root)
            seed(paths)
            runner = FakeRunner()
            verified = recovery.create_recovery(OFFLINE, paths=paths, runner=runner)
            identity = root / "offline.age"
            identity.write_text("GOOD", encoding="utf-8")
            before = len(runner.calls)

            real_stat = Path.stat
            etc_device = 1001
            state_device = 1002

            def fake_stat(path_obj, *args, **kwargs):
                value = real_stat(path_obj, *args, **kwargs)
                fields = list(value)
                fields[2] = etc_device if str(path_obj).startswith(str(paths.config.parent)) else state_device
                return os.stat_result(fields)

            def fake_disk_usage(anchor):
                free = 0 if str(anchor).startswith(str(paths.config.parent)) else 10**9
                return mock.Mock(total=10**9, used=0, free=free)

            with mock.patch.object(Path, "stat", fake_stat), mock.patch.object(
                recovery.shutil, "disk_usage", side_effect=fake_disk_usage
            ):
                with self.assertRaisesRegex(recovery.RecoveryError, "insufficient free space"):
                    recovery.restore_recovery(verified.artifact, identity, paths=paths, runner=runner)
            restore_calls = runner.calls[before:]
            self.assertFalse(any(call[:2] == ("docker", "stop") for call in restore_calls))

    def test_failed_encryption_never_publishes_local_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = make_paths(Path(directory))
            seed(paths)
            with self.assertRaisesRegex(recovery.RecoveryError, "Age encryption"):
                recovery.create_recovery(OFFLINE, paths=paths, runner=FakeRunner(age_encrypt_fails=True))
            self.assertFalse(any(path.name.endswith(".vwrec") for path in paths.backups.iterdir()))
            self.assertFalse(paths.state_file.exists())

    def test_mid_promotion_failure_restores_original_targets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current_a, current_b = root / "a", root / "b"
            candidate_a, candidate_b = root / "new-a", root / "new-b"
            current_a.write_text("old-a", encoding="utf-8")
            current_b.write_text("old-b", encoding="utf-8")
            candidate_a.write_text("new-a", encoding="utf-8")
            candidate_b.write_text("new-b", encoding="utf-8")
            real_replace = os.replace
            promotion_count = 0

            def failing_replace(source, destination):
                nonlocal promotion_count
                if Path(source) in {candidate_a, candidate_b}:
                    promotion_count += 1
                    if promotion_count == 2:
                        raise OSError("forced promotion failure")
                return real_replace(source, destination)

            with mock.patch.object(recovery.os, "replace", side_effect=failing_replace):
                with self.assertRaisesRegex(recovery.RecoveryError, "rollback was attempted"):
                    recovery._promote(((candidate_a, current_a), (candidate_b, current_b)))
            self.assertEqual(current_a.read_text(encoding="utf-8"), "old-a")
            self.assertEqual(current_b.read_text(encoding="utf-8"), "old-b")


class RcloneTests(unittest.TestCase):
    def test_publish_is_copyto_then_remote_verify_and_never_sync(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = make_paths(root)
            paths.backups.mkdir(parents=True)
            artifact = paths.backups / "recovery-20260820T000000Z-a.vwrec"
            artifact.write_bytes(AGE_HEADER + b"x" * 128)
            verified = recovery.VerifiedRecovery(
                artifact,
                recovery._sha256(artifact),
                artifact.stat().st_size,
                "2026-08-20T00:00:00Z",
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

    def test_offsite_state_requires_remote_verification(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = make_paths(Path(directory))
            seed(paths)
            runner = FakeRunner(remote_download_fails=True)
            with self.assertRaisesRegex(recovery.RecoveryError, "remote verification"):
                recovery.create_recovery(OFFLINE, paths=paths, runner=runner, remote="offsite:recovery")
            state = json.loads(paths.state_file.read_text(encoding="utf-8"))
            self.assertIn("local", state)
            self.assertNotIn("offsite", state)

    def test_explicit_pruning_plan_and_delete_argv(self) -> None:
        runner = FakeRunner()
        plan = recovery.prune_remote("offsite:recovery", 2, confirm=False, runner=runner)
        self.assertEqual(
            plan.keep,
            ("recovery-20260820T030000Z-c.vwrec", "recovery-20260820T020000Z-b.vwrec"),
        )
        self.assertEqual(plan.delete, ("recovery-20260820T010000Z-a.vwrec",))
        self.assertFalse(any(call[:2] == ("rclone", "deletefile") for call in runner.calls))
        recovery.prune_remote("offsite:recovery", 2, confirm=True, runner=runner)
        deletes = [call for call in runner.calls if call[:2] == ("rclone", "deletefile")]
        self.assertEqual(
            deletes[-1],
            ("rclone", "deletefile", "offsite:recovery/recovery-20260820T010000Z-a.vwrec"),
        )
        self.assertFalse(any("sync" in call for call in runner.calls))


if __name__ == "__main__":
    unittest.main()