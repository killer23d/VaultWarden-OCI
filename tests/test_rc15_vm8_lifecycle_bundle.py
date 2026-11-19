"""Integrity/syntax and phase ownership of temporary RC15 VM8 lifecycle one-shots."""
from __future__ import annotations

import ast
import re
import subprocess
import unittest
from pathlib import Path

BASE = Path(__file__).resolve().parents[1] / "tests/host-acceptance/rc14-vm8"
BLOBS = {
    "09-rc15-preboot-reboot.sh": "02c08302e57bf5d562cd5d8d15897f67f40199c3",
    "10-rc15-postboot-verify.sh": "2ac8662168bad82a2f16e2ee82e384d94af0f5e5",
    "11-rc15-scheduled-operations.sh": "19620161143eb26197c13f5b51865bcdf8825906",
    "12-rc15-safe-cleanup.sh": "77d366a279742cee02e56349be9fa864c31eeb6b",
}
HEREDOC = re.compile(r"<<'(PY_[A-Z0-9_]+)'\s*\n([\s\S]*?)^\1\s*$", re.MULTILINE)


class RC15LifecycleBundleTests(unittest.TestCase):
    def test_pins_and_syntax(self):
        expected_blocks = [4, 1, 3, 4]
        for (name, blob), block_count in zip(BLOBS.items(), expected_blocks, strict=True):
            with self.subTest(file=name):
                path = BASE / name
                body = path.read_text(encoding="utf-8")
                digest = subprocess.run(["git", "hash-object", str(path)], capture_output=True, text=True, check=True)
                self.assertEqual(digest.stdout.strip(), blob)
                check = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True, check=False)
                self.assertEqual(check.returncode, 0, check.stderr)
                blocks = HEREDOC.findall(body)
                self.assertEqual(len(blocks), block_count)
                for label, block in blocks:
                    ast.parse(block, filename=f"{name}:{label}")
                self.assertIn("32beec5bc905cdecdfdc4a359147c3f1d45d8444", body)
                self.assertIn("0.1.0-rc.15", body)
                self.assertNotIn("92b9300f9612", body)
                self.assertNotIn("0.1.0-rc.14", body)

    def test_boundary_and_phase_ownership(self):
        pre, post, schedule, cleanup = tuple((BASE / p).read_text() for p in BLOBS)
        self.assertIn("AUTHORIZE_RC15_VM8_REBOOT", pre)
        self.assertIn("rc15-b-${PIN:0:12}/after.json", pre)
        self.assertIn("ConditionPathExists=", pre)
        self.assertEqual(pre.count("systemctl reboot --no-wall"), 1)
        self.assertIn("PREBOOT_ARMED", pre)
        self.assertIn("POSTBOOT_PASS", post)
        self.assertIn('if ! SOURCE_STATUS=', post)
        self.assertIn('GIT_OPTIONAL_LOCKS=0 /usr/bin/git -c safe.directory=', post)
        self.assertIn("Pinned candidate Git index/status unreadable", post)
        self.assertNotIn('[ -z "$(git -C "$WORK" status --porcelain)" ]', post)
        self.assertIn("new_worker_route_id", post)
        self.assertIn("source_commit", schedule)
        self.assertIn("SCHEDULE_PASS", schedule)
        self.assertIn("CLEANUP_COMPLETE", cleanup)
        self.assertIn("systemctl disable --now vaultwarden-oci.target", cleanup)
        for body in (post, schedule, cleanup):
            self.assertNotIn("systemctl reboot", body)
        for body in (pre, post, schedule, cleanup):
            self.assertNotIn("vwctl update apply", body)
            self.assertNotIn("vwctl host-upgrade apply", body)


if __name__ == "__main__":
    unittest.main()
