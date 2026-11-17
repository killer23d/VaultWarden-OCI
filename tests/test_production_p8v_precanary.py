"""Negative-path unit tests for read-only P8V pre-canary evidence classification."""
from __future__ import annotations

from collections import Counter
from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

PATH = Path(__file__).parent / "host-acceptance" / "production-p8v-precanary-readonly.py"
spec = importlib.util.spec_from_file_location("p8v_precanary", PATH)
assert spec is not None and spec.loader is not None
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class PrecanaryTests(unittest.TestCase):
    def test_distinct_test_fqdn_and_zone_are_required(self):
        self.assertEqual(gate.fqdn_status("lazymocha.com", "canary.lazymocha.com")[0], "PASS")
        bad = (
            ("lazymocha.com", "bw.lazymocha.com"),
            ("lazymocha.com", "test.bw.lazymocha.com"),
            ("lazymocha.com", "lazymocha.com"),
            ("lazymocha.com", "bad.example.org"),
            ("example.com", "bad..example.com"),
            ("lazymocha.com", "BAD.lazymocha.com"),
        )
        for zone, fqdn in bad:
            with self.subTest(zone=zone, fqdn=fqdn):
                self.assertEqual(gate.fqdn_status(zone, fqdn)[0], "BLOCKED")
        self.assertEqual(gate.fqdn_status(None, None)[0], "PENDING")

    def test_data_path_fails_closed_on_protected_ancestors_and_traversal(self):
        self.assertEqual(gate.data_path_status("/mnt/canary-data/blank-db")[0], "PASS")
        for path in ("/var/lib", "/var/lib/vaultwarden-oci", "/var/lib/vaultwarden-oci/test",
                     "/root", "/root/vaultwarden-recovery/x", "/mnt/../var/lib/vaultwarden-oci",
                     "//mnt/blank", "/mnt//blank", "/"):
            with self.subTest(path=path):
                self.assertEqual(gate.data_path_status(path)[0], "BLOCKED")
        self.assertEqual(gate.data_path_status(None)[0], "PENDING")

    def test_backup_alias_cannot_be_production_or_relative_traversal(self):
        self.assertEqual(gate.backup_status("canary-backup:test-only/vwrec")[0], "PASS")
        for dest in ("bw-backup:bw-backup", "bw-backup:other", "BW-BACKUP:canary",
                     "canary-backup:bw-backup", "other:test/../secret",
                     "other:/tmp/test", "other:test//test", "other:"):
            with self.subTest(dest=dest):
                self.assertEqual(gate.backup_status(dest)[0], "BLOCKED")
        self.assertEqual(gate.backup_status(None)[0], "PENDING")

    def test_manual_attestation_must_be_fresh_and_independent(self):
        now = datetime(2026, 11, 17, 22, tzinfo=timezone.utc)
        item = {"observed_utc": now.isoformat().replace("+00:00", "Z"),
                "operator": "operator-one", "independent_reviewer": "reviewer-two",
                "method": "dashboard-two-person"}
        self.assertEqual(gate.fresh_review(item, now=now)[0], "PASS")
        for change in (
            {"observed_utc": (now - timedelta(days=2)).isoformat().replace("+00:00", "Z")},
            {"observed_utc": (now + timedelta(minutes=10)).isoformat().replace("+00:00", "Z")},
            {"operator": "same", "independent_reviewer": "same"},
            {"method": "self-attested"},
            {"observed_utc": ""},
        ):
            with self.subTest(change=change):
                self.assertEqual(gate.fresh_review({**item, **change}, now=now)[0], "PENDING")
        self.assertEqual(gate.fresh_review(None, now=now)[0], "PENDING")

    def test_false_and_missing_attestation_never_pass(self):
        flags = ("a", "b", "c")
        rows = []
        gate.attest_flags(rows, {"a": True, "b": False}, flags, "manual")
        self.assertEqual(rows, [
            ("PASS", "manual-a"), ("BLOCKED", "manual-b"), ("PENDING", "manual-c")])

    def test_unsupported_positive_claim_remains_pending_without_reviewer(self):
        sample = json.loads(json.dumps(gate.TEMPLATE))
        sample["cloudflare"]["dns_no_wildcards"] = True
        rows = []
        gate.validate_attestation(rows, sample)
        self.assertIn(("PENDING", "cloudflare-dns-no-wildcards"), rows)
        self.assertNotIn(("PASS", "cloudflare-dns-no-wildcards"), rows)

    def test_blank_template_cannot_pretend_approval(self):
        rows = []
        gate.validate_attestation(rows, gate.TEMPLATE)
        self.assertNotIn("PASS", [s for s, _ in rows])
        self.assertEqual(Counter(s for s, _ in rows)["PENDING"], len(rows))

    def test_past_provider_source_and_expected_counts_are_required(self):
        doc = {"schema": 1, "source": gate.PROVIDER_SHA, "outcome": "HOLD",
               "sanitized_rows": (
                   [["PASS", "x"]] * 16 + [["PENDING", "y"]] * 12
                   + [["NOT RUN", "z"]]
               )}
        rows = []
        gate.validate_provider(rows, doc)
        self.assertEqual(rows[0][0], "PASS")
        self.assertEqual(rows[1][0], "PENDING")
        for bad in (
            {**doc, "source": "0" * 40},
            {**doc, "sanitized_rows": []},
            {**doc, "sanitized_rows": [["PASS", "test"]] * 29},
            {**doc, "outcome": "PASS"},
        ):
            rows = []
            gate.validate_provider(rows, bad)
            self.assertEqual(rows[0][0], "PENDING")

    def test_private_files_require_owner_only_and_reject_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            target = folder / "attestation.json"
            target.write_text(json.dumps(gate.TEMPLATE), encoding="utf-8")
            target.chmod(0o600)
            self.assertEqual(gate.safe_read(target, folder)["schema_version"], 1)
            target.chmod(0o644)
            with self.assertRaises(gate.PrivateEvidenceError):
                gate.safe_read(target, folder)
            target.chmod(0o600)
            link = folder / "linked.json"
            link.symlink_to(target)
            with self.assertRaises(gate.PrivateEvidenceError):
                gate.safe_read(link, folder)
            target.write_text("x" * (gate.MAX_INPUT + 1), encoding="utf-8")
            with self.assertRaises(gate.PrivateEvidenceError):
                gate.safe_read(target, folder)

    def test_no_unreviewed_external_ops_in_gate(self):
        src = PATH.read_text("utf-8")
        for forbidden in ("os.system(", "shell=True", "requests.get(",
                          "urllib.request.urlopen(", "rclone ls", "oci network",
                          "docker compose up", "systemctl start", "edge.refresh"):
            self.assertNotIn(forbidden, src)
        self.assertIn('stdin=subprocess.DEVNULL', src)


if __name__ == "__main__":
    unittest.main()
