"""P8A isolation readiness: immutable evidence, isolation and no-mutation contract."""
from __future__ import annotations

import contextlib
import importlib.util
import inspect
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8-isolation-preflight.py"
spec = importlib.util.spec_from_file_location("rc12_p8a", SCRIPT)
assert spec and spec.loader
p8 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p8)


class IsolationPreflightTests(unittest.TestCase):
    def test_external_isolation_does_not_infer_a_pass(self):
        self.assertEqual(p8.isolation_conflicts(None, p8.SHARED_HOSTNAME, ()), ())
        self.assertIn(
            "shared_hostname_collision",
            p8.isolation_conflicts("bw.lazymocha.com", p8.SHARED_HOSTNAME, ()),
        )
        self.assertIn(
            "worker_route_overlap",
            p8.isolation_conflicts("p8.lazymocha.com", p8.SHARED_HOSTNAME, ("*.lazymocha.com/*",)),
        )
        self.assertIn(
            "worker_route_overlap",
            p8.isolation_conflicts("p8.lazymocha.com", p8.SHARED_HOSTNAME, ("p8.lazymocha.com/*",)),
        )
        self.assertIn(
            "invalid_candidate_hostname",
            p8.isolation_conflicts("test/route", p8.SHARED_HOSTNAME, ()),
        )
        self.assertIn(
            "unverifiable_worker_route_format",
            p8.isolation_conflicts("p8.lazymocha.com", p8.SHARED_HOSTNAME, ("bad route",)),
        )

    def test_source_contract_requires_firewall_order_and_caddy_no_restart(self):
        lifecycle = "edge.refresh_origin_policy(runner=runner)\n_compose(args, paths, runner)"
        render = 'restart: unless-stopped\nrestart: "no"\nports: ["443:443/tcp"]'
        self.assertTrue(p8.source_contract(lifecycle, render))
        self.assertFalse(p8.source_contract(lifecycle[::-1], render))
        self.assertFalse(p8.source_contract(lifecycle, render.replace('restart: "no"', 'restart: always')))
        self.assertFalse(p8.source_contract(lifecycle, render.replace('443:443/tcp', '80:80/tcp')))

    def test_source_contract_matches_actual_runtime_source(self):
        from vaultwarden_oci import runtime
        self.assertTrue(p8.source_contract(inspect.getsource(runtime.lifecycle), inspect.getsource(runtime.render)))

    def test_checkout_pin_rejects_dirty_wrong_branch_and_sha(self):
        pin = "a" * 40
        self.assertFalse(p8.source_checkout_ok("not-a-sha"))
        good = [(0, pin), (0, p8.BRANCH), (0, "")]
        with mock.patch.object(p8, "git_readonly", side_effect=good):
            self.assertTrue(p8.source_checkout_ok(pin))
        with mock.patch.object(p8, "git_readonly", side_effect=[(0, pin), (0, "v2")]):
            self.assertFalse(p8.source_checkout_ok(pin))
        with mock.patch.object(p8, "git_readonly", side_effect=[(0, pin), (0, p8.BRANCH), (0, " M file")]):
            self.assertFalse(p8.source_checkout_ok(pin))
        with mock.patch.object(p8, "git_readonly", side_effect=[(0, "b" * 40)]):
            self.assertFalse(p8.source_checkout_ok(pin))

    def test_original_checkpoint_cross_checkout_content_matching(self):
        old = "/home/ubuntu/VaultWarden-OCI-p7-87be10b/tests/host-acceptance/"
        files = [
            Path("/etc/vaultwarden-oci/config.toml"),
            Path("/var/lib/vaultwarden-oci/secrets/secrets.enc"),
            Path("/var/lib/vaultwarden-oci/secrets/identity.txt"),
            Path("/var/lib/vaultwarden-oci/state/host-id.json"),
            Path("/var/lib/vaultwarden-oci/state/volume.json"),
            Path("/var/lib/vaultwarden-oci/data/db.sqlite3"),
            *[p8.ACCEPTANCE / name for name in (p8.P7_NAME, p8.P5_NAME, p8.P6_NAME)],
        ]
        paths = tuple(files)
        hashes = {str(path): f"{i:064x}" for i, path in enumerate(paths)}
        checkpoint = {"sha256": {
            (old + path.name if path.parent == p8.ACCEPTANCE else str(path)): hashes[str(path)]
            for path in paths
        }}
        self.assertTrue(p8.checkpoint_content_matches(checkpoint, paths, hashes))
        altered = dict(checkpoint["sha256"])
        altered[old + p8.P5_NAME] = "f" * 64
        self.assertFalse(p8.checkpoint_content_matches({"sha256": altered}, paths, hashes))
        self.assertFalse(p8.checkpoint_content_matches({"sha256": {}}, paths, hashes))
        extra = dict(checkpoint["sha256"])
        extra[old + p8.P5_NAME + ".copy"] = "a" * 64
        self.assertFalse(p8.checkpoint_content_matches({"sha256": extra}, paths, hashes))

    def test_private_evidence_never_follows_symlinks_or_loose_permissions(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            source = root / "protected"
            source.write_text('{"schema":1}', encoding="utf-8")
            os.chmod(source, 0o600)
            with mock.patch.object(p8.os, "geteuid", return_value=0):
                # Current test user is usually not root; a fake root-owned
                # stat is deliberately not supplied, so it must fail closed.
                if source.stat().st_uid == 0:
                    self.assertEqual(p8.private_read(source), b'{"schema":1}')
            target = root / "symlink"
            target.symlink_to(source)
            with self.assertRaises((p8.Blocked, OSError)):
                p8.private_read(target)
            os.chmod(source, 0o644)
            with self.assertRaises(p8.Blocked):
                p8.private_read(source)

    def test_report_sanitized_and_blocked_exit_code(self):
        with tempfile.TemporaryDirectory() as d:
            report = p8.Report(Path(d))
            report.add("PASS", "Safe integrity gate")
            with self.assertRaises(ValueError):
                report.add("PASS", "secret\nsensitive")
            with self.assertRaises(ValueError):
                report.add("REARMED", "Never rearm from P8")
            report.add("PENDING", "Authoritative OCI state unknown")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.finish(), 0)
            summary = (Path(d) / "summary.txt").read_text()
            self.assertIn("HOLD", summary)
            report2 = p8.Report(Path(d) / "second")
            (Path(d) / "second").mkdir()
            report2.add("BLOCKED", "Source mismatch")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report2.finish(), 2)

    def test_rejects_invalid_arguments_without_private_evidence(self):
        with mock.patch.object(p8.sys, "argv", ["p8a"]), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(p8.main(), 2)
        with mock.patch.object(p8.sys, "argv", ["p8a", "--expected-commit", "a"*40]), \
             mock.patch.object(p8.os, "geteuid", return_value=1000), \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(p8.main(), 2)
        with mock.patch.object(p8.sys, "argv", ["p8a", "--expected-commit", "a"*40]), \
             mock.patch.object(p8.os, "geteuid", return_value=0), \
             mock.patch.dict(p8.os.environ, {"SUDO_USER": "ubuntu"}), \
             mock.patch.object(p8, "host_identity_ok", return_value=False), \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(p8.main(), 2)

    def test_all_live_operations_forbidden_by_script_source(self):
        source = SCRIPT.read_text(encoding="utf-8")
        forbidden = (
            "edge.refresh_origin_policy(runner=runner)",
            '["systemctl", "start"',
            '["systemctl", "reboot"',
            '["vwctl", "start"',
            '["vwctl", "backup"',
            '["rclone", "copy"',
            '["docker", "compose", "up"',
            '["vwctl", "dns", "update"',
            '["vwctl", "crowdsec", "remediation-start"',
        )
        # The source_contract string intentionally names the refresh method;
        # nothing in P8 actually CALLS the refresh method.
        self.assertEqual(source.count("edge.refresh_origin_policy(runner=runner)"), 1)
        for action in forbidden[1:]:
            self.assertNotIn(action, source)
        self.assertNotIn("requests.post(", source)
        self.assertNotIn("urllib.request.urlopen(", source)
        self.assertNotIn("subprocess.Popen(", source)


if __name__ == "__main__":
    unittest.main()
