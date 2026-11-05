"""P8S-A read-only acceptance parser and fail-closed regression tests."""
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8s-a-stopped-state-preflight.py"
SPEC = importlib.util.spec_from_file_location("production_p8s_a", SCRIPT)
assert SPEC and SPEC.loader
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def accepted_report():
    return "\n".join([
        gate.R_HEADING,
        "PASS       Original P8O FOUNDATION and P8Q read-only results pinned; real reboot proven",
        "PASS       Immutable 52 files/12 units, ext4, restored SQLite full integrity/SHA and SOPS/Age match original checkpoint",
        "PASS       CrowdSec engine+INPUT boot active, Worker/app/DNS/timers inactive; no Docker containers or HTTP80/443",
        "PENDING    Stopped runtime path metadata=PENDING (no automatic generated-path repair)",
        "PENDING    Historical Box destination configured; original remote writes/pruning and timers forbidden",
        "PENDING    Docker 443 origin filtering lost after reboot; one product-owned local re-arm permitted",
        "PASS       Installed rc.12 owner performed exactly one Cloudflare-only Docker 443 filter refresh",
        "PASS       All five local origin/CrowdSec doctor controls now PASS",
        "PASS       Entire original restored data/crypto/dedicated disk/52 files/12 units and application isolation revalidated",
        "PASS       CrowdSec engine/host INPUT remain boot-active; Worker and all app/DNS/timer units remain inactive",
        "PENDING    Docker-origin 443 filter did NOT persist unaided across cold reboot; explicit re-arm was required",
        "PENDING    Original P8P BLOCKED checkpoint intentionally preserved; no false reboot-persistence claim",
        "PENDING    Public origin/Worker Route Fail Open and test-only backup/SMTP still require separate proof",
        "PENDING    Disposable unencrypted ext4 may retain restored plaintext remnants; securely retire after acceptance",
        "NOT RUN    No additional reboot, Caddy/Vaultwarden, Worker/DNS/SMTP, Box write/prune or timer operation",
        gate.R_FINAL, "",
    ])


class P8SATests(unittest.TestCase):
    def test_corrected_real_outcome_is_recognized(self):
        gate.accepted_r_summary(accepted_report())

    def test_missing_or_forged_pass_is_blocked(self):
        for old, replacement in [
            ("exactly one", "zero"),
            ("All five", "Only four"),
            ("P8P BLOCKED", "P8P ACCEPTED"),
            ("NOT RUN", "PASS   "),
            ("REARMED", "BLOCKED"),
        ]:
            with self.subTest(old=old):
                with self.assertRaises(gate.Blocked):
                    gate.accepted_r_summary(accepted_report().replace(old, replacement))

    def test_duplicate_security_row_blocks(self):
        changed = accepted_report().replace(
            "PASS       All five local origin/CrowdSec doctor controls now PASS\n",
            "PASS       All five local origin/CrowdSec doctor controls now PASS\n" * 2)
        with self.assertRaises(gate.Blocked):
            gate.accepted_r_summary(changed)

    def test_wrong_source_commit_blocks_before_git(self):
        with mock.patch.object(gate.subprocess, "run") as run:
            self.assertFalse(gate.source_clean(Path("/tmp/not-a-real-repo"), gate.BRANCH, "bad"))
            run.assert_not_called()

    def test_wrong_host_never_imports_prior_helpers(self):
        with mock.patch.object(gate, "host_ok", return_value=False), \
             mock.patch.object(gate, "import_checked") as importer, \
             mock.patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(gate.main(["--expected-commit", "a" * 40]), 2)
            importer.assert_not_called()

    def test_report_private_and_bounded(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            with mock.patch("sys.stdout", new_callable=io.StringIO):
                self.assertEqual(gate.write_report(folder, [
                    ("PASS", "All protected reads completed"),
                    ("PENDING", "External isolation not independently verified"),
                ], "HOLD"), 0)
            body = (folder / "summary.txt").read_text()
            self.assertIn("HOLD", body)
            self.assertIn("PENDING", body)
            self.assertEqual((folder / "summary.txt").stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                with mock.patch("sys.stdout", new_callable=io.StringIO):
                    gate.write_report(folder, [], "HOLD")

    def test_unsafe_report_row_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(gate.Blocked):
                gate.write_report(Path(tmp), [("PASS", "unexpected\nraw line")], "HOLD")

    def test_no_service_mutations_in_gate(self):
        source = SCRIPT.read_text()
        self.assertNotIn('"edge", "refresh"', source)
        self.assertNotIn('"docker", "compose", "up"', source)
        self.assertNotIn('"systemctl", "start"', source)
        self.assertNotIn('"rclone", "copy"', source)


if __name__ == "__main__":
    unittest.main()
