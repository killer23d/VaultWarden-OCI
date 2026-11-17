"""Merged primary-branch source-pin and reported Cloudflare conflict regressions.

Source-only tests: no provider access, host mutation, or external calls.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).parent / "host-acceptance"
MODULES = (
    ("production-p8v-host-layered-readonly.py", "pinned"),
    ("production-p8v-oci-layered-readonly.py", "pin_ok"),
    ("production-p8v-oci-provider-batch-readonly.py", "pinned"),
    ("production-p8v-precanary-readonly.py", "git_pinned"),
)
EXPECTED = "a" * 40


def load(path: str):
    spec = importlib.util.spec_from_file_location("integration_branch_test_" + path.replace("-", "_"), HERE / path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MergedV2PinTests(unittest.TestCase):
    def assert_pin(self, module, fn, branch: str, clean: bool, want: bool):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / ".git").mkdir()
            outputs = [EXPECTED, branch, "" if clean else " M file"]
            calls = []

            def git_run(argv, **kwargs):
                self.assertEqual(argv[0], "git")
                self.assertEqual(str(kwargs["cwd"]), str(root))
                self.assertEqual(kwargs["stdin"], module.subprocess.DEVNULL)
                calls.append(argv)
                return SimpleNamespace(returncode=0, stdout=(outputs[len(calls) - 1] + "\n").encode())

            with mock.patch.object(module, "ROOT", root), mock.patch.object(
                module.subprocess, "run", side_effect=git_run
            ):
                self.assertEqual(getattr(module, fn)(EXPECTED), want)
            self.assertEqual(len(calls), 3)

    def test_all_gates_allow_primary_and_historical_review_branch(self):
        for file, func in MODULES:
            module = load(file)
            with self.subTest(file=file):
                self.assert_pin(module, func, "v2", True, True)
                self.assert_pin(module, func, module.BRANCH, True, True)
                self.assert_pin(module, func, "main", True, False)
                self.assert_pin(module, func, "v2", False, False)

    def test_reported_cloudflare_route_collisions_are_blocked(self):
        gate = load("production-p8v-precanary-readonly.py")
        import json
        evidence = json.loads(json.dumps(gate.TEMPLATE))
        evidence["cloudflare"]["zone"] = "lazymocha.com"
        evidence["cloudflare"]["test_fqdn"] = "vwoci-rc13-canary.lazymocha.com"
        for field in ("dns_no_wildcards", "worker_routes_no_overlap",
                      "worker_custom_domains_no_overlap"):
            evidence["cloudflare"][field] = False
        rows = []
        gate.validate_attestation(rows, evidence)
        self.assertIn(("BLOCKED", "cloudflare-dns-no-wildcards"), rows)
        self.assertIn(("BLOCKED", "cloudflare-worker-routes-no-overlap"), rows)
        self.assertIn(("BLOCKED", "cloudflare-worker-custom-domains-no-overlap"), rows)
        self.assertIn(("PENDING", "independent-review-corroboration-missing"), rows)


if __name__ == "__main__":
    unittest.main()
