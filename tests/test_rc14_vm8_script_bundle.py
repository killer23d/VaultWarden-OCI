"""Temporary VM8 host-acceptance bundle integrity and syntax, never production release code."""
from __future__ import annotations

import ast
import hashlib
import re
import subprocess
import unittest
from pathlib import Path

BASE = Path(__file__).resolve().parents[1] / "tests/host-acceptance/rc14-vm8"
PIN = "92b9300f96125d19105cc1d4865024cb49612b28"
HASHES = {
    "01-upgrade.sh": "cefff1ffbc0dbccaadf82e260966eb44911bfde1ea4a3952ba54d51d16889910",
    "02-controlled-stop-rearm.sh": "6ddae31ffe39ce20d264afdbc7bd31c08d1996ce57ba0ac074d6190677aab4e9",
    "03-preboot-reboot.sh": "47979fd2f28307d845ae555fde2d4ec5257c8be9be8a8e69743e7096c3bc26f3",
    "04-postboot-verify.sh": "e3c0717120e7183c757984b4f82759819b0fd3a396e7f4c639bf9fd00a432309",
    "05-scheduled-operations.sh": "1c9379bfdc717875f1e38832f5a5d1a13225332d60eec411e50b23cb715916e2",
    "06-safe-cleanup.sh": "0b4109de96ca46e262f67922d2a88b771f2b735808b780b960f61d010f8e2967",
}
HEREDOC = re.compile(
    r"<<'(PY_[A-Z0-9_]+)'\s*\n([\s\S]*?)^\1\s*$",
    flags=re.MULTILINE,
)


class RC14TemporaryHostBundleTests(unittest.TestCase):
    def test_exact_bytes_and_manifest(self) -> None:
        expected_manifest = "".join(f"{digest}  {name}\n" for name, digest in HASHES.items())
        self.assertEqual((BASE / "SHA256SUMS.txt").read_text(), expected_manifest)
        for name, expected in HASHES.items():
            with self.subTest(name=name):
                p = BASE / name
                self.assertTrue(p.is_file() and not p.is_symlink())
                data = p.read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), expected)
                self.assertTrue(data.startswith(b"#!/usr/bin/env bash\n"))
                self.assertTrue(data.endswith(b"\n"))
                self.assertIn(PIN.encode(), data)

    def test_syntax_and_all_embedded_python(self) -> None:
        for name in HASHES:
            with self.subTest(name=name):
                path = BASE / name
                parsed = subprocess.run(
                    ["bash", "-n", str(path)], capture_output=True,
                    text=True, timeout=15, check=False,
                )
                self.assertEqual(parsed.returncode, 0, parsed.stderr)
                pairs = HEREDOC.findall(path.read_text())
                self.assertTrue(pairs, f"no embedded Python found in {name}")
                for label, body in pairs:
                    with self.subTest(name=name, python=label):
                        ast.parse(body, filename=name + ":" + label)

    def test_handoff_readme_lists_all_phases_and_temporary_scope(self) -> None:
        readme = (BASE / "README.md").read_text()
        self.assertIn("Isolated VM8 test harness", readme)
        self.assertIn("not part of the production release", readme)
        for name in HASHES:
            self.assertIn(name, readme)

    def test_post_upgrade_reconciliation_is_nonmutating_and_parses(self) -> None:
        path = BASE / "01b-reconcile-installed-upgrade.sh"
        content = path.read_text()
        syntax = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True, check=False, timeout=15)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        blocks = HEREDOC.findall(content)
        self.assertEqual(len(blocks), 1)
        for label, body in blocks:
            ast.parse(body, filename=path.name + ":" + label)
        self.assertIn("frozen_versions_toml", content)
        self.assertIn("safe.directory=", content)
        self.assertNotIn("update apply", content)
        self.assertNotIn("systemctl reboot", content)
        self.assertNotIn("remediation-stop", content)

    def test_failed_rearm_diagnostic_is_read_only_and_parses(self) -> None:
        path = BASE / "02b-diagnose-rearm-readonly.sh"
        content = path.read_text()
        syntax = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True, check=False, timeout=15)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        blocks = HEREDOC.findall(content)
        self.assertEqual(len(blocks), 1)
        for label, body in blocks:
            ast.parse(body, filename=path.name + ":" + label)
        self.assertIn("CF_SAMPLE_", content)
        self.assertIn("REARM_FAILURE_CATEGORY=", content)
        self.assertIn("CONTROLLED_STOP_UPSTREAM_EXIT=", content)
        self.assertNotIn("systemctl', 'start'", content)
        self.assertNotIn("systemctl', 'stop'", content)
        self.assertNotIn("remediation-start --auto-fail-open", content)
        self.assertNotIn('method="PUT"', content)
        self.assertNotIn("systemctl reboot", content)

    def test_active_route_reconciliation_is_one_shot_and_preserves_failed_rearm(self) -> None:
        path = BASE / "02c-reconcile-active-route.sh"
        content = path.read_text()
        result = subprocess.run(
            ["bash", "-n", str(path)], capture_output=True, text=True,
            check=False, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        blocks = HEREDOC.findall(content)
        self.assertEqual(len(blocks), 2)
        for name, body in blocks:
            ast.parse(body, filename=path.name + ":" + name)
        self.assertIn("RC14_D_02C_EXIT=0 CURRENT_WORKER_ROUTE_RECONCILED", content)
        self.assertIn("ORIGINAL_SINGLE_COMMAND_REARM=FAILED", content)
        self.assertIn("updated=no", content)
        self.assertIn("vwctl crowdsec ensure-fail-open", content)
        # Explicit command-line detection: explanatory safety messages may
        # mention forbidden actions without actually invoking them.
        self.assertIsNone(re.search(
            r"(?m)^\s*(?:sudo(?: -n)?\s+)?systemctl\s+(?:stop|start|reboot)\b",
            content,
        ))
        self.assertNotIn("method=\"PUT\"", content)
        self.assertNotIn("evid/'after.json'", content)

    def test_rc15_upgrade_is_pinned_one_shot_with_frozen_manifest_and_private_receipt(self) -> None:
        path = BASE / "07-rc15-upgrade.sh"
        content = path.read_text()
        parsed = subprocess.run(["bash", "-n", str(path)], capture_output=True,
                                text=True, check=False, timeout=15)
        self.assertEqual(parsed.returncode, 0, parsed.stderr)
        blocks = HEREDOC.findall(content)
        self.assertEqual(len(blocks), 5)
        for label, body in blocks:
            with self.subTest(block=label):
                ast.parse(body, filename=path.name + ":" + label)
        self.assertIn("32beec5bc905cdecdfdc4a359147c3f1d45d8444", content)
        self.assertIn("0.1.0-rc.14", content)
        self.assertIn("0.1.0-rc.15", content)
        self.assertIn("VWOCI_SOURCE_OVERRIDE=1", content)
        self.assertIn("frozen_versions_toml", content)
        self.assertIn("INSTALLED_RC15_UPGRADE_PASS", content)
        self.assertIn("original_cipher_sha256", content)
        self.assertEqual(content.count("vwctl update apply"), 1)
        self.assertNotIn("systemctl reboot", content)
        self.assertNotIn("remediation-start", content)
        self.assertNotIn("systemctl enable", content)
        self.assertNotIn("Cloudflare Route PUT", content)

    def test_phase_ownership_and_mutation_scopes(self) -> None:
        scripts = {n: (BASE / n).read_text() for n in HASHES}
        self.assertIn("vwctl update apply", scripts["01-upgrade.sh"])
        self.assertIn("remediation-stop", scripts["02-controlled-stop-rearm.sh"])
        self.assertIn("systemctl reboot --no-wall", scripts["03-preboot-reboot.sh"])
        self.assertIn("POSTBOOT_PASS", scripts["04-postboot-verify.sh"])
        self.assertIn("ConditionPathExists", scripts["03-preboot-reboot.sh"])
        self.assertIn("vaultwarden-oci-dns.service", scripts["05-scheduled-operations.sh"])
        self.assertIn("systemctl disable --now vaultwarden-oci.target", scripts["06-safe-cleanup.sh"])
        for name in ("04-postboot-verify.sh", "05-scheduled-operations.sh", "06-safe-cleanup.sh"):
            self.assertNotIn("systemctl reboot", scripts[name])


if __name__ == "__main__":
    unittest.main()
