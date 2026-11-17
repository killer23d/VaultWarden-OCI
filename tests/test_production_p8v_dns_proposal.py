"""P8V-D negative-path tests for read-only public DNS evidence only."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest
from unittest import mock

HERE = Path(__file__).parent / "host-acceptance"
spec = importlib.util.spec_from_file_location(
    "p8v_dns_proposal", HERE / "production-p8v-dns-proposal-readonly.py"
)
assert spec is not None and spec.loader is not None
dns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dns)

gate_spec = importlib.util.spec_from_file_location(
    "p8v_c_guard", HERE / "production-p8v-precanary-readonly.py"
)
assert gate_spec is not None and gate_spec.loader is not None
gate = importlib.util.module_from_spec(gate_spec)
gate_spec.loader.exec_module(gate)


def response(name="test.example.net", kind="A", status=0, answer=None, tc=False):
    doc = {
        "Status": status,
        "TC": tc,
        "Question": [{"name": name + ".", "type": dns.TYPES[kind]}],
    }
    if answer is not None:
        doc["Answer"] = answer
    return doc


class DnsReadOnlyTests(unittest.TestCase):
    def test_parse_proven_empty_only_for_explicit_dns_schema(self):
        doc = response()
        self.assertEqual(dns.dns_result(doc, "test.example.net", "A"), "ABSENT")
        self.assertEqual(dns.dns_result(response(status=3), "test.example.net", "A"), "ABSENT")
        self.assertEqual(dns.dns_result(response(answer=[
            {"name": "test.example.net.", "type": 1, "data": "192.0.2.1"}
        ]), "test.example.net", "A"), "ANSWER")
        for bad in (
            None, "", [], {}, response(tc=True), response(status=2),
            response(status=False), response(status=3, answer=[
                {"name": "test.example.net.", "type": 1, "data": "192.0.2.1"}]),
            {**doc, "Question": []},
            {**doc, "Question": [{"name": "other.example.net.", "type": 1}]},
            {**doc, "Answer": None},
            {**doc, "Answer": [{"name": "test.example.net.", "type": 1}]},
        ):
            with self.subTest(bad=bad):
                self.assertEqual(dns.dns_result(bad, "test.example.net", "A"), "UNAVAILABLE")

    def test_dns_missing_and_positive_probe_never_clear_manual_review(self):
        self.assertEqual(dns.combine(["ABSENT"] * 6, "candidate"), (
            "PASS", "candidate-no-visible-public-dns-answer-only"))
        for values in (
            ["ABSENT"] * 5 + ["ANSWER"],
            ["ABSENT"] * 5 + ["UNAVAILABLE"],
            ["ABSENT"] * 5,
            ["ABSENT"] * 5 + ["junk"],
            [],
        ):
            with self.subTest(values=values):
                self.assertEqual(dns.combine(values, "candidate")[0], "PENDING")

    def test_survey_has_unconditional_dashboard_and_canary_hold(self):
        def empty_query(resolver, name, kind):
            if kind == "NS":
                return "ANSWER"
            return "ABSENT"
        rows = dns.survey(
            gate, "lazymocha.com", "vwoci-rc13-canary.lazymocha.com", empty_query,
        )
        self.assertIn(("PASS", "candidate-no-visible-public-dns-answer-only"), rows)
        self.assertIn(("PASS", "wildcard-probe-no-visible-public-dns-answer-only"), rows)
        self.assertIn(("PASS", "zone-public-ns-answers-observed-only"), rows)
        self.assertIn(("PENDING", "cloudflare-account-zone-and-dns-dashboard-unverified"), rows)
        self.assertIn(("PENDING", "cloudflare-worker-routes-and-custom-domains-dashboard-unverified"), rows)
        self.assertIn(("NOT RUN", "no-provider-guest-backup-or-dns-mutation"), rows)
        self.assertNotIn(("PASS", "cloudflare-zone-owned"), rows)

    def test_survey_rejects_production_host_before_any_external_request(self):
        hits = []
        def query(*args):
            hits.append(args)
            raise AssertionError("must not issue DNS requests")
        rows = dns.survey(gate, "lazymocha.com", "bw.lazymocha.com", query)
        self.assertEqual(rows[0][0], "BLOCKED")
        self.assertEqual(hits, [])

    def test_all_dns_failures_are_pending_not_empty_success(self):
        def unavailable(*args):
            raise OSError("network error")
        rows = dns.survey(gate, "lazymocha.com", "vwoci-rc13-canary.lazymocha.com", unavailable)
        self.assertIn(("PENDING", "candidate-resolver-unavailable"), rows)
        self.assertIn(("PENDING", "wildcard-probe-resolver-unavailable"), rows)

    def test_external_endpoint_whitelist_and_no_mutations(self):
        self.assertEqual(sorted(dns.DOH_URLS), ["cloudflare", "google"])
        self.assertEqual({kind: val for kind, val in dns.TYPES.items()}, {
            "A": 1, "AAAA": 28, "CNAME": 5, "NS": 2,
        })
        script = (HERE / "production-p8v-dns-proposal-readonly.py").read_text()
        self.assertIn('method="GET"', script)
        self.assertIn("NoRedirect", script)
        for forbidden in ("os.system(", "shell=True", "oci network ", "rclone ",
                          "subprocess.Popen(", "systemctl start", "docker start",
                          "api.cloudflare.com/client/v4", "urllib.request.urlopen("):
            self.assertNotIn(forbidden, script)


if __name__ == "__main__":
    unittest.main()
