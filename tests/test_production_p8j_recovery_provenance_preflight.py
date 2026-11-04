"""P8J offline provenance planning: read-only and no credential/remote interaction."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8j-recovery-provenance-preflight.py"
spec = importlib.util.spec_from_file_location("rc12_p8j_provenance", SCRIPT)
assert spec and spec.loader
gate = importlib.util.module_from_spec(spec)
import sys
sys.modules[spec.name] = gate
spec.loader.exec_module(gate)

PIN = "a" * 40
RECIPIENT = "age1" + "a" * 58
PUBLIC_HASH = hashlib.sha256(RECIPIENT.encode()).hexdigest()
REMOTE = "bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec"
CIPHER_SHA = "e" * 64


def source_fixture(remote=REMOTE, sha=CIPHER_SHA, rec_sha=PUBLIC_HASH):
    return "\n".join((
        "HOST = 'vaultwarden-oci-6-vnic'",
        f"HISTORICAL_REMOTE = {remote!r}",
        f"HISTORICAL_SHA256 = {sha!r}",
        f"OFFLINE_RECIPIENT_SHA256 = {rec_sha!r}",
    )) + "\n"


def p8ir_summary():
    return "\n".join((
        "Gate P8I corrected - NEW isolated installed-but-stopped template-aware witness (READ-ONLY)",
        "PASS       Original one-shot P8H install attempt/checkpoint and successful HOLD evidence intact",
        "PASS       Original P8I BLOCKED and P8I-D template-only diagnosis intact; no original evidence changed",
        "PASS       Full installed product files=52, systemd units=12 match immutable reviewed rc.12",
        "PASS       Mounted dedicated non-root ext4 and dual ownership markers match P8G disk",
        "PASS       Locked hostname/email, zero-prune/disabled Box config, operational SOPS",
        "PASS       Concrete appliance units=11 inactive/unenabled; static notify template verified with zero instances",
        "PASS       No TCP 80/443 listeners or retained Docker containers=0",
        "PASS       No Vaultwarden database present",
        "HOLD       P8I post-install read-only witness only; no restore/live-start/production GO",
    )) + "\n"


class P8JReadOnlyTests(unittest.TestCase):
    def test_wrong_host_dirty_checkout_and_invalid_pin_refused(self):
        sha = PIN
        good = [
            SimpleNamespace(returncode=0, stdout=(sha + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=(gate.BRANCH + "\n").encode()),
            SimpleNamespace(returncode=0, stdout=b""),
        ]
        with mock.patch.object(gate.subprocess, "run", side_effect=good):
            self.assertTrue(gate.checked_checkout(sha))
        bad = good[:-1] + [SimpleNamespace(returncode=0, stdout=b"?? modified")]
        with mock.patch.object(gate.subprocess, "run", side_effect=bad):
            self.assertFalse(gate.checked_checkout(sha))
        with mock.patch.object(gate.subprocess, "run") as proc:
            self.assertFalse(gate.checked_checkout("incorrect"))
            proc.assert_not_called()
        with mock.patch.object(gate.platform, "node", return_value="vaultwarden-oci-6-vnic"):
            self.assertFalse(gate.guest_release())

    def test_original_p8ir_historical_hold_is_mandatory(self):
        s = p8ir_summary()
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            with mock.patch.object(gate, "private_dir", return_value=True), \
                 mock.patch.object(gate, "private_regular", return_value=s.encode()):
                self.assertEqual(gate.accepted_p8ir(base), hashlib.sha256(s.encode()).hexdigest()[:12])
            with mock.patch.object(gate, "private_dir", return_value=True), \
                 mock.patch.object(gate, "private_regular", return_value=s.replace("HOLD       P8I", "BLOCKED    P8I").encode()):
                with self.assertRaises(gate.Blocked):
                    gate.accepted_p8ir(base)
            with mock.patch.object(gate, "private_dir", return_value=False):
                with self.assertRaises(gate.Blocked):
                    gate.accepted_p8ir(base)

    def test_historical_original_source_literals_read_without_execution(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "original-pin.py"
            path.write_text(source_fixture())
            original = gate.original_pin_contract(path)
            self.assertEqual(original["HOST"], "vaultwarden-oci-6-vnic")
            self.assertEqual(original["HISTORICAL_REMOTE"], REMOTE)
            self.assertEqual(original["HISTORICAL_SHA256"], CIPHER_SHA)
            path.write_text(source_fixture().replace(
                f"HISTORICAL_SHA256 = {CIPHER_SHA!r}",
                "HISTORICAL_SHA256 = dangerous_call()",
            ))
            with self.assertRaises(gate.Blocked):
                gate.original_pin_contract(path)
            path.write_text(source_fixture(remote="otherremote:anything"))
            with self.assertRaises(gate.Blocked):
                gate.original_pin_contract(path)
            path.write_text(source_fixture(remote="bw-backup:bw-backup/../../evil.vwrec"))
            with self.assertRaises(gate.Blocked):
                gate.original_pin_contract(path)

    def test_installed_public_recipient_must_match_original_sha_without_print(self):
        cfg = f"""
[site]
domain = "{gate.TEST_DOMAIN}"
acme_email = "{gate.TEST_EMAIL}"
[backup]
remote = ""
local_retention_days = 0
remote_retention_days = 0
[secrets]
offline_recovery_recipient = "{RECIPIENT}"
"""
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "config.toml"
            path.write_text(cfg)
            path.chmod(0o600)
            def fake_lstat(self_path):
                if self_path == path:
                    return SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=0)
                return self_path.stat(follow_symlinks=False)
            with mock.patch.object(gate, "CONFIG", path), \
                 mock.patch.object(gate.Path, "lstat", autospec=True, side_effect=fake_lstat):
                self.assertEqual(gate.root_config(PUBLIC_HASH), gate.tag(RECIPIENT))
                with self.assertRaises(gate.Blocked):
                    gate.root_config("f" * 64)
            path.write_text(cfg.replace('remote = ""', 'remote = "historical:old"'))
            with mock.patch.object(gate, "CONFIG", path), \
                 mock.patch.object(gate.Path, "lstat", autospec=True, side_effect=fake_lstat):
                with self.assertRaises(gate.Blocked):
                    gate.root_config(PUBLIC_HASH)

    def test_new_vm_no_unapproved_kit_or_encrypted_artifact_staged(self):
        with tempfile.TemporaryDirectory() as name:
            state = Path(name) / "state"
            home = Path(name) / "home"
            state.mkdir()
            home.mkdir()
            backups = state / "backups"
            with mock.patch.object(gate, "STATE", state), \
                 mock.patch.object(gate.pwd, "getpwnam", return_value=SimpleNamespace(pw_dir=str(home))):
                gate.no_local_recovery_payloads()
                backups.mkdir()
                gate.no_local_recovery_payloads()
                artifact = backups / "some.vwrec"
                artifact.write_bytes(b"encrypted test bytes")
                with self.assertRaises(gate.Blocked):
                    gate.no_local_recovery_payloads()
                artifact.unlink()
                zip_path = home / "vaultwarden-recovery-kit-20261006T222828Z.zip"
                zip_path.write_bytes(b"sample ZIP")
                with self.assertRaises(gate.Blocked):
                    gate.no_local_recovery_payloads()

    def test_stopped_units_and_no_notification_instances(self):
        def safe_output(argv, **kw):
            if "show" in argv:
                return 0, "LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled\n"
            if "list-unit-files" in argv:
                return 0, f"{gate.NOTIFY_TEMPLATE} static -\n"
            if "list-units" in argv:
                return 0, ""
            return 0, ""
        def is_symlink(self_path):
            return self_path == gate.CURRENT
        with mock.patch.object(gate.Path, "resolve", return_value=gate.INSTALLED), \
             mock.patch.object(gate, "command", side_effect=safe_output), \
             mock.patch.object(gate.Path, "exists", return_value=False), \
             mock.patch.object(gate.Path, "is_symlink", autospec=True, side_effect=is_symlink):
            self.assertEqual(gate.current_stopped(), 12)

    def test_listener_or_active_unit_forces_refusal(self):
        def active_output(argv, **kw):
            if "show" in argv:
                return 0, "LoadState=loaded\nActiveState=active\nUnitFileState=disabled\n"
            return 0, ""
        with mock.patch.object(gate.Path, "is_symlink", return_value=True), \
             mock.patch.object(gate.Path, "resolve", return_value=gate.INSTALLED), \
             mock.patch.object(gate.Path, "exists", return_value=False), \
             mock.patch.object(gate, "command", side_effect=active_output):
            with self.assertRaises(gate.Blocked):
                gate.current_stopped()

    def test_tmpfs_and_swap_are_classified_without_mounting(self):
        with mock.patch.object(gate, "command", return_value=(0, "tmpfs\n")), \
             mock.patch.object(gate.Path, "read_text", return_value="Filename Type Size Used Priority\n"):
            self.assertEqual(gate.volatile_path(), (True, False))
        with mock.patch.object(gate, "command", return_value=(0, "ext4\n")), \
             mock.patch.object(gate.Path, "read_text", return_value="Filename Type Size Used Priority\n/dev/zram0 partition 100 1 1\n"):
            self.assertEqual(gate.volatile_path(), (False, True))

    def test_report_private_and_pending_not_mistaken_for_go(self):
        with tempfile.TemporaryDirectory() as name:
            r = gate.Report(Path(name))
            r.add("PASS", "Original evidence intact")
            r.add("PENDING", "Source custody needs off-host readback")
            with self.assertRaises(ValueError):
                r.add("PASS", "secret\nfrom file")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(r.finish(), 0)
            data = (Path(name) / "summary.txt").read_text()
            self.assertIn("HOLD", data)
            self.assertIn("no ciphertext/identity/restore/live service authorization", data)
            self.assertEqual(stat.S_IMODE((Path(name) / "summary.txt").stat().st_mode), 0o600)

    def test_no_rclone_box_age_or_mutation_api_in_script(self):
        content = SCRIPT.read_text(encoding="utf-8")
        for forbidden in (
            '["rclone"', '["oci"', '["docker"', '["systemctl", "start"',
            '["systemctl", "enable"', '["mkfs.ext4"', '["mount"',
            '["vwctl", "restore"', '["sops", "--decrypt"',
            'urllib.request.urlopen(', 'subprocess.Popen(', 'requests.post(',
        ):
            self.assertNotIn(forbidden, content)
        self.assertIn("UNVERIFIED_HISTORICAL_CANDIDATE_ONLY", content)
        self.assertIn("NO_BOX_READ_TRANSFER_DECRYPT_RESTORE", content)

    def test_invalid_host_invocation_no_new_private_report(self):
        with mock.patch.object(gate.sys, "argv", [
            "p8j", "--expected-commit", PIN,
        ]), mock.patch.object(gate.os, "geteuid", return_value=1000), \
             mock.patch.object(gate, "evidence_base") as evidence, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate.main(), 2)
            evidence.assert_not_called()

    def test_main_mocked_hold_and_private_candidate_has_no_key_material(self):
        with tempfile.TemporaryDirectory() as name:
            base = Path(name)
            values = {
                "HOST": "vaultwarden-oci-6-vnic",
                "HISTORICAL_REMOTE": REMOTE,
                "HISTORICAL_SHA256": CIPHER_SHA,
                "OFFLINE_RECIPIENT_SHA256": PUBLIC_HASH,
            }
            with mock.patch.object(gate.sys, "argv", ["p8j", "--expected-commit", PIN]), \
                 mock.patch.object(gate.os, "geteuid", return_value=0), \
                 mock.patch.dict(gate.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(gate.platform, "node", return_value=gate.HOST), \
                 mock.patch.object(gate, "checked_checkout", return_value=True), \
                 mock.patch.object(gate, "guest_release", return_value=True), \
                 mock.patch.object(gate, "evidence_base", return_value=base), \
                 mock.patch.object(gate, "accepted_p8ir", return_value="a" * 12), \
                 mock.patch.object(gate, "original_pin_contract", return_value=values), \
                 mock.patch.object(gate, "root_config", return_value="c" * 12), \
                 mock.patch.object(gate, "current_stopped", return_value=12), \
                 mock.patch.object(gate, "no_local_recovery_payloads") as no_payload, \
                 mock.patch.object(gate, "volatile_path", return_value=(True, False)):
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    self.assertEqual(gate.main(), 0)
                no_payload.assert_called_once()
                self.assertIn("PENDING", stdout.getvalue())
                self.assertNotIn(REMOTE, stdout.getvalue())
                folder = next(base.glob("p8j-recovery-readiness-*"))
                candidate = json.loads((folder / "candidate.private.json").read_text())
                self.assertEqual(candidate["status"], "UNVERIFIED_HISTORICAL_CANDIDATE_ONLY")
                self.assertEqual(candidate["original_candidate_ciphertext_sha256"], CIPHER_SHA)
                self.assertNotIn(RECIPIENT, json.dumps(candidate))
                self.assertEqual(stat.S_IMODE((folder / "candidate.private.json").stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
