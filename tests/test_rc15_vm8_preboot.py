"""RC15 VM8 one-shot integrity and reboot authorization boundary."""
from __future__ import annotations

import ast
import re
import subprocess
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "tests/host-acceptance/rc14-vm8/09-rc15-preboot-reboot.sh"
EXPECTED_GIT_BLOB = "02c08302e57bf5d562cd5d8d15897f67f40199c3"
PY_BLOCK = re.compile(r"<<'(PY_[A-Z0-9_]+)'\s*\n([\s\S]*?)^\1\s*$", re.MULTILINE)


class RC15PrebootTests(unittest.TestCase):
    def test_pinned_script_and_all_python_blocks(self):
        text = SCRIPT.read_text(encoding="utf-8")
        digest = subprocess.run(["git", "hash-object", str(SCRIPT)], capture_output=True, text=True, check=True)
        self.assertEqual(digest.stdout.strip(), EXPECTED_GIT_BLOB)
        shell = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True, check=False)
        self.assertEqual(shell.returncode, 0, shell.stderr)
        blocks = PY_BLOCK.findall(text)
        self.assertEqual([key for key, _ in blocks], ["PY_PRE", "PY_DOCTOR", "PY_DNS", "PY_SAVE"])
        for key, block in blocks:
            ast.parse(block, filename=key)

    def test_correct_source_and_nonreplay_boundaries(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("32beec5bc905cdecdfdc4a359147c3f1d45d8444", text)
        self.assertIn("rc15-b-${PIN:0:12}/after.json", text)
        self.assertIn("0.1.0-rc.15", text)
        self.assertIn("cloudflare_route_fail_open", text)
        self.assertIn("original_cipher_sha256", text)
        self.assertIn("AUTHORIZE_RC15_VM8_REBOOT", text)
        self.assertIn("ConditionPathExists=", text)
        self.assertIn("vwoci-rc15-acceptance-dns-permit", text)
        self.assertIn("PREBOOT_ARMED", text)
        self.assertEqual(text.count("systemctl reboot --no-wall"), 1)
        self.assertEqual(text.count("systemctl enable"), 2)
        self.assertLess(text.index("AUTHORIZE_RC15_VM8_REBOOT"), text.index("mkdir -m 700 \"$EVID\""))
        self.assertLess(text.index("PY_DOCTOR"), text.index("printf '\\n=== RC15-C stage reversible DNS"))
        self.assertNotIn("vwctl dns update", text)
        self.assertNotIn("vwctl host-upgrade apply", text)
        self.assertNotIn("remediation-stop", text)
        self.assertNotIn("remediation-start", text)
        self.assertNotIn("0.1.0-rc.14", text)
        self.assertNotIn("rc14-e", text)


if __name__ == "__main__":
    unittest.main()
