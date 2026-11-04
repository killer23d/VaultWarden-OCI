"""P7R one-shot post-boot origin refresh safety/authorization regression tests."""
from __future__ import annotations

import contextlib
import importlib.util
import inspect
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

from vaultwarden_oci import runtime

SCRIPT = Path(__file__).parent / "host-acceptance" / "production-postboot-origin-rearm-consent.py"
spec = importlib.util.spec_from_file_location("rc12_p7r_postboot", SCRIPT)
assert spec and spec.loader
p7r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p7r)


class InteractiveOutput(io.StringIO):
    def isatty(self):
        return True


class PostbootOriginRearmTests(unittest.TestCase):
    def test_consent_exact_only(self):
        self.assertTrue(p7r.consented(p7r.CONSENT))
        for candidate in ("", "yes", "P7R REARM", p7r.CONSENT.lower(),
                          p7r.CONSENT + "\n", " " + p7r.CONSENT, p7r.CONSENT + " now"):
            self.assertFalse(p7r.consented(candidate))

    def test_one_shot_attempt_marker_never_overwrites_or_follows_symlink(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "p7r.json"
            p7r.record_attempt_once(path, "before", "after")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(json.loads(path.read_text())["gate"], "p7r-origin-rearm")
            with self.assertRaises(FileExistsError):
                p7r.record_attempt_once(path, "before", "again")
            other = Path(d) / "other"
            other.write_text("SAFE")
            link = Path(d) / "link"
            link.symlink_to(other)
            with self.assertRaises(OSError):
                p7r.record_attempt_once(link, "before", "after")
            self.assertEqual(other.read_text(), "SAFE")

    def test_product_start_explicitly_guards_before_compose_and_caddy_never_auto_restarts(self):
        start = inspect.getsource(runtime.lifecycle)
        compose = inspect.getsource(runtime.render)
        self.assertIn("edge.refresh_origin_policy(runner=runner)", start)
        self.assertLess(start.index("edge.refresh_origin_policy(runner=runner)"),
                        start.index('args = ["up", "-d", "--build", "--wait"'))
        self.assertLess(start.index("edge.refresh_origin_policy(runner=runner)"),
                        start.index('if not _compose(args, paths, runner).ok:'))
        self.assertIn('restart: "no"', compose)
        self.assertIn('ports: ["443:443/tcp"]', compose)

    def test_original_checkpoint_preflight_requires_different_boot_and_complete_hashes(self):
        checkpoint = {"phase": "reboot-requested", "boot_id": "before"}
        original = {"file": "sha"}
        all_checks = {
            "storage.dedicated": "PASS", "edge.cloudflare.cidrs": "PASS",
            "edge.cloudflare.iptables": "FAIL", "crowdsec.cloudflare": "FAIL",
            "runtime.paths": "FAIL",
        }
        for i in range(22):
            all_checks["test-key-" + str(i)] = "PASS"
        self.assertEqual(len(all_checks), 27)
        p5 = SimpleNamespace(
            diagnose_doctor=lambda *a, **k: ("valid", all_checks, "not_needed"),
        )
        def checked_helper(path, label):
            return p5
        p7 = SimpleNamespace(
            safe_base=lambda: Path("/private"),
            read_checkpoint=lambda path: checkpoint,
            checkpoint_path=lambda base: base / "marker",
            read_boot_id=lambda: "after",
            host_snapshot=lambda inner, after_boot: ((Path("/file"),), original),
            verified_hashes=lambda cp, paths, hashes: None,
            Report=lambda dest, mode: SimpleNamespace(rows=[
                ("PASS", "Original data/units intact"),
                ("PENDING", "Cloudflare Docker 443 ingress policy not persistent across cold boot; NO listener and NO automatic repair"),
            ]),
            helper=checked_helper,
            P5_FILE=Path("p5"),
            Blocked=RuntimeError,
        )
        with tempfile.TemporaryDirectory() as d:
            report = p7r.Report(Path(d), "diagnose")
            p7r.preflight(p7, report)
            self.assertTrue(any("exactly" in msg.lower() or "exact" in msg.lower()
                                for _, msg in report.rows))
            p7.read_boot_id = lambda: "before"
            with self.assertRaises(RuntimeError):
                p7r.preflight(p7, report)

    def test_unexpected_pre_rearm_failure_ids_refuse_mutation(self):
        original = {"phase": "reboot-requested", "boot_id": "old"}
        checks = {name: "FAIL" for name in p7r.EXPECTED_STOPPED_FAILURE_IDS}
        checks.update({"storage.dedicated": "PASS", "edge.cloudflare.cidrs": "PASS", "secrets.decrypt": "FAIL"})
        for i in range(21):
            checks["mock" + str(i)] = "PASS"
        p5 = SimpleNamespace(diagnose_doctor=lambda *a, **k: ("valid", checks, "not_needed"))
        fake = SimpleNamespace(
            safe_base=lambda: Path("/private"),
            checkpoint_path=lambda base: base / "checkpoint",
            read_checkpoint=lambda path: original,
            read_boot_id=lambda: "new",
            host_snapshot=lambda inner, after_boot: ((), {}),
            verified_hashes=lambda *a: None,
            Report=lambda out, mode: SimpleNamespace(rows=[
                ("PENDING", "Cloudflare Docker 443 ingress policy not persistent across cold boot"),
            ]),
            helper=lambda *a: p5,
            P5_FILE=Path("p5"),
            Blocked=RuntimeError,
        )
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(RuntimeError):
                p7r.preflight(fake, p7r.Report(Path(d), "diagnose"))

    def test_postflight_requires_all_foundation_checks_and_no_unexpected_failures(self):
        from vaultwarden_oci import cli
        with tempfile.TemporaryDirectory() as d:
            output = Path(d)
            paths = (Path("/original/source"),)
            hashes = {str(paths[0]): "unchanged"}
            current = dict.fromkeys((
                "edge.cloudflare.cidrs", "edge.cloudflare.iptables",
                "crowdsec.engine", "crowdsec.hub", "crowdsec.firewall",
                "storage.dedicated", "crowdsec.cloudflare", "runtime.paths",
                "secrets.decrypt",
            ), "PASS")
            current["crowdsec.cloudflare"] = "FAIL"
            current["runtime.paths"] = "FAIL"
            for i in range(18):
                current["approved-test-key-" + str(i)] = "PASS"
            self.assertEqual(len(current), 27)
            fake_p5 = SimpleNamespace(
                REQUIRED_DOCTOR=(
                    "edge.cloudflare.cidrs", "edge.cloudflare.iptables",
                    "crowdsec.engine", "crowdsec.hub", "crowdsec.firewall",
                ),
                diagnose_doctor=lambda *a, **k: ("valid", current, "not_needed"),
            )
            fake_p7 = SimpleNamespace(
                Report=lambda *a: SimpleNamespace(rows=[("PASS", "Runtime is still dormant")]),
                host_snapshot=lambda *a, **k: (paths, hashes),
                verified_hashes=lambda *a: None,
                Blocked=RuntimeError,
            )
            gate = p7r.Report(output, "rearm")
            p7r.postflight(fake_p7, fake_p5, gate, {"sha256": hashes}, paths)
            self.assertTrue(any("re-established" in msg for _, msg in gate.rows))
            self.assertTrue(any("Original P7 HOLD" in msg for _, msg in gate.rows))
            current["edge.cloudflare.iptables"] = "FAIL"
            with self.assertRaises(RuntimeError):
                p7r.postflight(fake_p7, fake_p5, gate, {"sha256": hashes}, paths)
            current["edge.cloudflare.iptables"] = "PASS"
            current["secrets.decrypt"] = "FAIL"
            with self.assertRaises(RuntimeError):
                p7r.postflight(fake_p7, fake_p5, gate, {"sha256": hashes}, paths)

    def _run_main(self, mode: str, *, consent: str | None = None, result: int = 0,
                  prior_attempt: bool = False):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            evidence = root / "evidence"
            evidence.mkdir()
            if prior_attempt:
                (root / p7r.ATTEMPT_FILE).write_text("prior")
            events = []
            checkpoint = {"phase": "reboot-requested", "boot_id": "before"}
            p7 = SimpleNamespace(
                safe_base=lambda: root,
                read_boot_id=lambda: "after",
                INSTALLED=Path("/opt/vaultwarden-oci/releases/0.1.0-rc.12"),
                Blocked=RuntimeError,
            )
            def fake_preflight(*a):
                events.append("preflight")
                return SimpleNamespace(
                    run_private=lambda *args, **kwargs: fake_run_private(),
                ), checkpoint, (), {}, {}
            def fake_run_private():
                events.append(("product-edge-refresh", (root / p7r.ATTEMPT_FILE).exists()))
                return result
            def fake_postflight(*a):
                events.append("postflight")
            outs = InteractiveOutput()
            with mock.patch.object(p7r.sys, "argv", [str(SCRIPT), mode]), \
                 mock.patch.object(p7r.sys, "stdin", SimpleNamespace(isatty=lambda: True)), \
                 mock.patch.object(p7r.sys, "stdout", outs), \
                 mock.patch.object(p7r.os, "geteuid", return_value=0), \
                 mock.patch.dict(p7r.os.environ, {"SUDO_USER": "ubuntu"}), \
                 mock.patch.object(p7r, "original_p7", return_value=p7), \
                 mock.patch.object(p7r, "new_private_evidence", return_value=evidence), \
                 mock.patch.object(p7r, "preflight", side_effect=fake_preflight), \
                 mock.patch.object(p7r, "postflight", side_effect=fake_postflight), \
                 mock.patch("builtins.input", return_value=consent, create=True) as prompt:
                status = p7r.main()
                if mode == "--diagnose-only":
                    prompt.assert_not_called()
            return status, events, outs.getvalue(), (evidence / "summary.txt").read_text(), (
                (root / p7r.ATTEMPT_FILE).exists()
            )

    def test_diagnose_only_does_not_ask_or_start_firewall(self):
        status, events, output, summary, attempt = self._run_main("--diagnose-only")
        self.assertEqual(status, 0)
        self.assertEqual(events, ["preflight"])
        self.assertFalse(attempt)
        self.assertIn("HOLD", summary)

    def test_cancel_before_any_marker_or_mutation(self):
        status, events, output, summary, attempt = self._run_main("--rearm", consent="CANCEL")
        self.assertEqual(status, 0)
        self.assertEqual(events, ["preflight"])
        self.assertFalse(attempt)
        self.assertIn("Cancelled", summary)

    def test_exact_consent_ensures_barrier_exists_before_installed_product(self):
        status, events, output, summary, attempt = self._run_main(
            "--rearm", consent=p7r.CONSENT,
        )
        self.assertEqual(status, 0)
        self.assertEqual(events, ["preflight", "preflight", ("product-edge-refresh", True), "postflight"])
        self.assertTrue(attempt)
        self.assertIn("REARMED", summary)
        self.assertIn("reboot firewall persistence and production GO NOT PROVEN", summary)

    def test_failure_after_one_shot_marker_is_blocked_no_retry(self):
        status, events, _, summary, attempt = self._run_main(
            "--rearm", consent=p7r.CONSENT, result=1,
        )
        self.assertEqual(status, 2)
        self.assertTrue(attempt)
        self.assertNotIn("postflight", events)
        self.assertIn("Possible partial firewall mutation", summary)

    def test_existing_marker_denies_rearm_but_diagnose_still_allowed(self):
        status, events, output, summary, attempt = self._run_main(
            "--rearm", consent=p7r.CONSENT, prior_attempt=True,
        )
        self.assertEqual(status, 2)
        self.assertEqual(events, ["preflight"])
        self.assertIn("BLOCKED", summary)
        status, events, _, summary, attempt = self._run_main(
            "--diagnose-only", prior_attempt=True,
        )
        self.assertEqual(status, 0)
        self.assertEqual(events, ["preflight"])
        self.assertIn("Prior rearm attempt marker", summary)


if __name__ == "__main__":
    unittest.main()
