"""P8L trusted workstation and new-host ciphertext-source safety regression tests."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).parent
OFFHOST = ROOT.parent / "tools/p8l-offhost-encrypted-source.py"
TARGET = ROOT / "host-acceptance/production-p8l-encrypted-source-handoff.py"


def import_script(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


offhost = import_script("rc12_p8l_offhost", OFFHOST)
target = import_script("rc12_p8l_target", TARGET)

SAMPLE = b"age-encryption.org/v1\n-> X25519 abc\n" + b"e" * 140
SAMPLE_SHA = hashlib.sha256(SAMPLE).hexdigest()
AGE_RECIPIENT = "age1" + "a" * 58
PUBLIC_HASH = hashlib.sha256(AGE_RECIPIENT.encode()).hexdigest()
BOX_OBJECT = "bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec"
PIN = "a" * 40


def original():
    return {
        "HOST": "vaultwarden-oci-6-vnic",
        "HISTORICAL_REMOTE": BOX_OBJECT,
        "HISTORICAL_SHA256": SAMPLE_SHA,
        "OFFLINE_RECIPIENT_SHA256": PUBLIC_HASH,
    }


def p8k_rows():
    return "\n".join((
        "Gate P8K - MULTI-CHECK recovery and safety batch (READ-ONLY)",
        "PASS       Original P8I-R stopped-host HOLD and P8J PRE-TRANSFER HOLD evidence intact",
        "PASS       Original historical ciphertext candidate SHA reference unchanged, object fingerprint=b9b058145bc7",
        "PASS       Original PUBLIC offline Age recipient hash matches installed config",
        "PASS       Immutable rc.12 release pointer and owned dedicated non-root ext4 dual identity verified",
        "PASS       All 11 concrete units stopped/unenabled, static notify template has NO instances",
        "PASS       /run tmpfs still present",
        "PASS       Kernel swap remains disabled",
        "PASS       Dedicated recovery volume free GiB=46; no pre-approved encrypted/plaintext archive staged",
        "PENDING    Root rclone bw-backup: unavailable on NEW VM; no Box object accessed",
        "HOLD       P8K batched read-only only; no Age PRIVATE key, decryption, restore, live startup or production GO",
    )) + "\n"


def p8k_meta():
    return {
        "schema": 1,
        "phase": "PRE_RESTORE_BATCH_ONLY",
        "source_commit": target.P8K_COMMIT,
        "historical_remote_unverified": BOX_OBJECT,
        "historical_expected_sha256": SAMPLE_SHA,
        "offline_public_recipient_sha256": PUBLIC_HASH,
        "box_readback": {"status": "REMOTE_UNAVAILABLE"},
    }


class OffHostTests(unittest.TestCase):
    def test_refuses_both_appliance_guests_and_root_user(self):
        with mock.patch.object(offhost.socket, "gethostname", return_value="vaultwarden-oci-6-vnic"), \
             mock.patch.object(offhost.os, "geteuid", return_value=1000):
            with self.assertRaises(offhost.Blocked):
                offhost.workstation_only()
        with mock.patch.object(offhost.socket, "gethostname", return_value="vaultwarden-oci-7-vnic"), \
             mock.patch.object(offhost.os, "geteuid", return_value=1000):
            with self.assertRaises(offhost.Blocked):
                offhost.workstation_only()
        with mock.patch.object(offhost.socket, "gethostname", return_value="mac-workstation"), \
             mock.patch.object(offhost.os, "geteuid", return_value=0):
            with self.assertRaises(offhost.Blocked):
                offhost.workstation_only()

    def test_age_header_and_full_sha_without_decrypting(self):
        digest, count = offhost.stream_sha(io.BytesIO(SAMPLE), 2048)
        self.assertEqual(digest, SAMPLE_SHA)
        self.assertEqual(count, len(SAMPLE))
        with self.assertRaises(offhost.Blocked):
            offhost.stream_sha(io.BytesIO(b"not age!" * 15), 2048)
        with self.assertRaises(offhost.Blocked):
            offhost.stream_sha(io.BytesIO(SAMPLE), 65)

    def test_existing_private_ciphertext_local_match_and_tamper(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / offhost.NAME
            path.write_bytes(SAMPLE)
            path.chmod(0o600)
            with mock.patch.object(offhost, "EXPECTED_SHA256", SAMPLE_SHA):
                self.assertEqual(offhost.verify_local(path), (SAMPLE_SHA, len(SAMPLE)))
            with self.assertRaises(offhost.Blocked):
                offhost.verify_local(path)
            path.unlink()
            path.symlink_to("nonexistent")
            with self.assertRaises(offhost.Blocked):
                offhost.verify_local(path)

    def test_aes256_extra_field_detects_true_256_not_zipcrypto(self):
        aes = struct.pack("<HH", 0x9901, 7) + struct.pack("<H", 2) + b"AE" + bytes([3]) + struct.pack("<H", 8)
        entry = SimpleNamespace(compress_type=99, flag_bits=1, extra=aes)
        self.assertTrue(offhost.aes_256(entry))
        self.assertFalse(offhost.aes_256(SimpleNamespace(compress_type=8, flag_bits=1, extra=aes)))
        self.assertFalse(offhost.aes_256(SimpleNamespace(compress_type=99, flag_bits=0, extra=aes)))
        self.assertFalse(offhost.aes_256(SimpleNamespace(compress_type=99, flag_bits=1, extra=aes[:-3])))
        weak = struct.pack("<HH", 0x9901, 7) + struct.pack("<H", 2) + b"AE" + bytes([1]) + struct.pack("<H", 8)
        self.assertFalse(offhost.aes_256(SimpleNamespace(compress_type=99, flag_bits=1, extra=weak)))

    def test_kit_metadata_only_checks_expected_encrypted_members(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "kit.zip"
            path.write_bytes(b"x" * 200)
            path.chmod(0o600)
            good = []
            aes = struct.pack("<HH", 0x9901, 7) + struct.pack("<H", 2) + b"AE" + bytes([3]) + struct.pack("<H", 8)
            for item in offhost.KIT_MEMBERS:
                good.append(SimpleNamespace(
                    filename=item, compress_type=99, flag_bits=1,
                    extra=aes, file_size=123, is_dir=lambda: False,
                ))
            fake = mock.MagicMock()
            fake.__enter__.return_value.infolist.return_value = good
            with mock.patch.object(offhost.zipfile, "ZipFile", return_value=fake):
                self.assertEqual(offhost.kit_metadata(path), (200, 5))
            fake.__enter__.return_value.infolist.return_value = good[:-1]
            with mock.patch.object(offhost.zipfile, "ZipFile", return_value=fake):
                with self.assertRaises(offhost.Blocked):
                    offhost.kit_metadata(path)

    def test_box_read_only_requires_exact_tty_phrase(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "new-folder"
            with mock.patch.object(offhost.sys, "stdin", io.StringIO()), \
                 mock.patch.object(offhost.sys, "stdout", io.StringIO()), \
                 mock.patch("builtins.input") as prompt, \
                 mock.patch.object(offhost.subprocess, "run") as cloud:
                with self.assertRaises(offhost.Blocked):
                    offhost.box_to_private_folder(path)
                prompt.assert_not_called()
                cloud.assert_not_called()

    def test_offhost_script_contains_no_decrypt_restore_box_write(self):
        text = OFFHOST.read_text()
        for unsafe in ("rclone copyto", "rclone delete", "age --decrypt",
                       "ssh ", "scp ", "systemctl start", "vwctl restore"):
            self.assertNotIn(unsafe, text)


class TargetTests(unittest.TestCase):
    def test_exact_git_and_wrong_guest_refused(self):
        sha = PIN
        replies = [
            SimpleNamespace(returncode=0, stdout=(sha + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=(target.BRANCH + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=b""),
        ]
        with mock.patch.object(target.subprocess, "run", side_effect=replies):
            self.assertTrue(target.pinned_checkout(sha))
        with mock.patch.object(target.subprocess, "run", side_effect=replies[:-1] + [
            SimpleNamespace(returncode=0, stdout=b"?? changed"),
        ]):
            self.assertFalse(target.pinned_checkout(sha))
        with mock.patch.object(target.platform, "node", return_value="vaultwarden-oci-6-vnic"):
            self.assertFalse(target.supported_guest())

    def test_original_source_pin_rejects_traversal_or_executable_constant(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "original.py"
            def script(remote=BOX_OBJECT, sha=SAMPLE_SHA):
                return "\n".join((
                    "HOST = 'vaultwarden-oci-6-vnic'",
                    f"HISTORICAL_REMOTE = {remote!r}",
                    f"HISTORICAL_SHA256 = {sha!r}",
                    f"OFFLINE_RECIPIENT_SHA256 = {PUBLIC_HASH!r}",
                ))
            with mock.patch.object(target, "ORIGINAL_PIN", path):
                path.write_text(script())
                self.assertEqual(target.original_constants()["HISTORICAL_SHA256"], SAMPLE_SHA)
                path.write_text(script(remote="bw-backup:bw-backup/../recovery-20261029T223200Z-xx.vwrec"))
                with self.assertRaises(target.Blocked):
                    target.original_constants()
                path.write_text(script().replace(f"HISTORICAL_SHA256 = {SAMPLE_SHA!r}", "HISTORICAL_SHA256 = do_not_run()"))
                with self.assertRaises(target.Blocked):
                    target.original_constants()

    def test_original_p8k_root_historical_hold_and_remote_unavailable_required(self):
        with tempfile.TemporaryDirectory() as location:
            base = Path(location)
            blobs = {"summary.txt": p8k_rows().encode(),
                     "candidate.private.json": json.dumps(p8k_meta()).encode()}
            with mock.patch.object(target, "private_folder", return_value=True), \
                 mock.patch.object(target, "private_file", side_effect=lambda p: blobs[p.name]):
                target.previous_p8k(base, original())
                altered = p8k_meta()
                altered["box_readback"] = {"status": "MATCHED_ORIGINAL_PIN"}
                blobs["candidate.private.json"] = json.dumps(altered).encode()
                with self.assertRaises(target.Blocked):
                    target.previous_p8k(base, original())
                blobs["candidate.private.json"] = json.dumps(p8k_meta()).encode()
                blobs["summary.txt"] = p8k_rows().replace("HOLD       P8K", "BLOCKED    P8K").encode()
                with self.assertRaises(target.Blocked):
                    target.previous_p8k(base, original())

    def test_private_0700_inbox_and_0600_ciphertext_sha(self):
        with tempfile.TemporaryDirectory() as name:
            inbox = Path(name) / "inbox"
            inbox.mkdir(mode=0o700)
            sample = inbox / Path(BOX_OBJECT).name
            sample.write_bytes(SAMPLE)
            sample.chmod(0o600)
            with mock.patch.object(target, "INBOX", inbox), \
                 mock.patch.object(target.pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=os.getuid())):
                n, sha = target.encrypted_file(sample, sample.name, SAMPLE_SHA)
                self.assertEqual((n, sha), (len(SAMPLE), SAMPLE_SHA))
                with self.assertRaises(target.Blocked):
                    target.encrypted_file(sample, sample.name, "f" * 64)
                sample.chmod(0o644)
                with self.assertRaises(target.Blocked):
                    target.encrypted_file(sample, sample.name, SAMPLE_SHA)
                sample.chmod(0o600)
                sample.unlink()
                sample.symlink_to("/etc/passwd")
                with self.assertRaises((target.Blocked, OSError)):
                    target.encrypted_file(sample, sample.name, SAMPLE_SHA)

    def test_rejects_ciphertext_path_outside_exact_user_inbox(self):
        with tempfile.TemporaryDirectory() as name:
            with mock.patch.object(target, "INBOX", Path(name)):
                with self.assertRaises(target.Blocked):
                    target.encrypted_file(Path(name) / "other.vwrec", "correct.vwrec", SAMPLE_SHA)

    def test_sanitized_report_never_contains_private_metadata(self):
        with tempfile.TemporaryDirectory() as name:
            report = target.Report(Path(name))
            report.add("PASS", "Original accepted source unchanged")
            report.add("PENDING", "No private Age identity imported")
            with self.assertRaises(ValueError):
                report.add("PASS", "private\nraw")
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                self.assertEqual(report.finish(), 0)
            self.assertIn("HOLD", buffer.getvalue())
            summary = Path(name) / "summary.txt"
            self.assertEqual(stat.S_IMODE(summary.stat().st_mode), 0o600)
        with tempfile.TemporaryDirectory() as name:
            report = target.Report(Path(name))
            report.add("BLOCKED", "ciphertext SHA mismatch")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 2)

    def test_target_full_preflight_without_artifact_is_historical_pending_only(self):
        with tempfile.TemporaryDirectory() as name:
            base = Path(name)
            with mock.patch.object(target.sys, "argv", ["p8l", "--expected-commit", PIN]), \
                 mock.patch.object(target.os, "geteuid", return_value=0), \
                 mock.patch.dict(target.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(target.platform, "node", return_value=target.HOST), \
                 mock.patch.object(target, "pinned_checkout", return_value=True), \
                 mock.patch.object(target, "supported_guest", return_value=True), \
                 mock.patch.object(target, "BASE_PATH", base), \
                 mock.patch.object(target.pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=os.getuid())), \
                 mock.patch.object(target, "private_folder", return_value=True), \
                 mock.patch.object(target, "original_constants", return_value=original()), \
                 mock.patch.object(target, "previous_p8k"), \
                 mock.patch.object(target, "check_config"), \
                 mock.patch.object(target, "check_stopped", return_value=("f" * 12, 12)), \
                 mock.patch.object(target, "scratch", return_value=(38, True, False)), \
                 mock.patch.object(target, "encrypted_file") as verify, \
                 contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(target.main(), 0)
                verify.assert_not_called()
                self.assertIn("PENDING", output.getvalue())
                record = next(base.glob("p8l-encrypted-handoff-*/ciphertext.private.json"))
                self.assertEqual(json.loads(record.read_text())["status"], "NO_CIPHERTEXT_READ")

    def test_target_pinned_ciphertext_verify_and_private_status(self):
        with tempfile.TemporaryDirectory() as name:
            base = Path(name)
            artifact = target.INBOX / Path(BOX_OBJECT).name
            with mock.patch.object(target.sys, "argv", ["p8l", "--expected-commit", PIN, "--artifact", str(artifact)]), \
                 mock.patch.object(target.os, "geteuid", return_value=0), \
                 mock.patch.dict(target.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(target.platform, "node", return_value=target.HOST), \
                 mock.patch.object(target, "pinned_checkout", return_value=True), \
                 mock.patch.object(target, "supported_guest", return_value=True), \
                 mock.patch.object(target, "BASE_PATH", base), \
                 mock.patch.object(target.pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=os.getuid())), \
                 mock.patch.object(target, "private_folder", return_value=True), \
                 mock.patch.object(target, "original_constants", return_value=original()), \
                 mock.patch.object(target, "previous_p8k"), \
                 mock.patch.object(target, "check_config"), \
                 mock.patch.object(target, "check_stopped", return_value=("f" * 12, 12)), \
                 mock.patch.object(target, "scratch", return_value=(38, True, False)), \
                 mock.patch.object(target, "encrypted_file", return_value=(len(SAMPLE), SAMPLE_SHA)), \
                 contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(target.main(), 0)
                self.assertIn("ciphertext SHA-256", output.getvalue())
                record = next(base.glob("p8l-encrypted-handoff-*/ciphertext.private.json"))
                self.assertEqual(json.loads(record.read_text())["status"], "ORIGINAL_CIPHERTEXT_BYTES_MATCHED")

    def test_fail_closed_without_p8k_safety_and_never_contact_box(self):
        with tempfile.TemporaryDirectory() as name:
            base = Path(name)
            with mock.patch.object(target.sys, "argv", ["p8l", "--expected-commit", PIN]), \
                 mock.patch.object(target.os, "geteuid", return_value=0), \
                 mock.patch.dict(target.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(target.platform, "node", return_value=target.HOST), \
                 mock.patch.object(target, "pinned_checkout", return_value=True), \
                 mock.patch.object(target, "supported_guest", return_value=True), \
                 mock.patch.object(target, "BASE_PATH", base), \
                 mock.patch.object(target.pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=os.getuid())), \
                 mock.patch.object(target, "private_folder", return_value=True), \
                 mock.patch.object(target, "original_constants", return_value=original()), \
                 mock.patch.object(target, "previous_p8k", side_effect=target.Blocked()), \
                 mock.patch.object(target, "encrypted_file") as verify, \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(target.main(), 2)
                verify.assert_not_called()

    def test_no_cloud_or_destructive_call_in_target(self):
        code = TARGET.read_text(encoding="utf-8")
        for banned in (
            '"rclone"', '"age", "--decrypt"', '"docker"', '"systemctl", "start"',
            '"mkfs.ext4"', '"mount"', '"vwctl", "restore"',
            "subprocess.Popen(", "urllib.request.urlopen(",
        ):
            self.assertNotIn(banned, code)


if __name__ == "__main__":
    unittest.main()
