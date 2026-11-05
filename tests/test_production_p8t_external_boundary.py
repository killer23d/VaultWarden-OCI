"""P8T pure, source-pinned regression coverage (no provider credentials/network)."""
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8t-external-boundary-readonly.py"
SPEC = importlib.util.spec_from_file_location("production_p8t_readonly", SCRIPT)
assert SPEC and SPEC.loader
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)

# Independent transcription from actual P8S console, not gate constants.
ACCEPTED_P8S = "\n".join([
    "Gate P8S-A - NEW disposable VM protected stopped-host READ-ONLY",
    "PASS       P8O/P8P/P8Q/P8R immutable historical evidence and original one-shot continuity validated",
    "PASS       Original dedicated ext4, historic restored SQLite/SOPS/Age and immutable product/units unchanged",
    "PASS       Original P8P BLOCKED outcome retained and P8R REARMED evidence verified",
    "PASS       No app, DNS, timers, notifications, retained Docker containers or HTTP 80/443 listeners",
    "PASS       CrowdSec engine/INPUT bouncer active; Worker disabled and inactive",
    "PASS       Validated Cloudflare CIDRs and both-family effective DOCKER-USER 443 source policy",
    "PASS       27-ID installed doctor schema and mandatory security/host/storage checks",
    "PENDING    Stopped generated runtime paths PENDING; no automatic repair",
    "PENDING    External OCI/Cloudflare isolation remains unverified; controlled live phase on HOLD",
    "PENDING    Original imported Box destination remains forbidden for writes, pruning and timer runs",
    "NOT RUN    No replay, reboot, firewall mutation, Docker start, DNS/Worker, SMTP or Box operations",
    "HOLD       P8S-A stopped-only; no live/Box/Worker/DNS/timer authorization",
    "",
])
TRUSTED = {
    4: gate.cidr_set("173.245.48.0/20\n103.21.244.0/22\n", 4),
    6: gate.cidr_set("2400:cb00::/32\n", 6),
}


def rule(source, port=443, **other):
    entry = {
        "direction": "INGRESS", "protocol": "6",
        "source": source,
        "tcp-options": {"destination-port-range": {"min": port, "max": port}},
    }
    entry.update(other)
    return entry


def record(host, address, proxied=True):
    return {"name": host, "type": "A", "content": address, "proxied": proxied}


class P8TReadOnlyTests(unittest.TestCase):
    def test_exact_real_accepted_p8s_historical_summary(self):
        gate.accept_p8s(ACCEPTED_P8S)
        self.assertEqual(gate.P8S_FINAL, "HOLD       P8S-A stopped-only; no live/Box/Worker/DNS/timer authorization")

    def test_historical_outcome_is_not_implicitly_upgraded(self):
        for old, new in [
            ("HOLD       P8S-A stopped-only", "READY      P8S-A stopped-only"),
            ("PASS       CrowdSec engine/INPUT", "BLOCKED    CrowdSec engine/INPUT"),
            ("PENDING    External OCI/Cloudflare", "PASS       External OCI/Cloudflare"),
            ("Original P8P BLOCKED", "Original P8P ACCEPTED"),
            ("NOT RUN    No replay", "PASS       No replay"),
        ]:
            with self.subTest(text=old), self.assertRaises(gate.Blocked):
                gate.accept_p8s(ACCEPTED_P8S.replace(old, new))

    def test_duplicates_and_missing_p8s_pass_rejected(self):
        original = "PASS       27-ID installed doctor schema and mandatory security/host/storage checks"
        with self.assertRaises(gate.Blocked):
            gate.accept_p8s(ACCEPTED_P8S.replace(original, original + "\n" + original))
        with self.assertRaises(gate.Blocked):
            gate.accept_p8s(ACCEPTED_P8S.replace(original, ""))

    def test_cloudflare_ranges_reject_private_and_duplicates(self):
        for text in ("10.0.0.0/8\n173.245.48.0/20\n",
                     "173.245.48.0/20\n173.245.48.0/20\n",
                     "173.245.48.0/20\nbad-cidr\n"):
            with self.subTest(text=text), self.assertRaises((gate.Blocked, ValueError)):
                gate.cidr_set(text, 4)

    def test_broad_443_and_public_80_are_blocked_even_with_cloudflare_nsg(self):
        cloudflare = rule("173.245.48.0/20")
        broad = rule("0.0.0.0/0")
        http = rule("0.0.0.0/0", port=80)
        self.assertEqual(gate.review_oci_rules([cloudflare], TRUSTED), "PASS")
        self.assertEqual(gate.review_oci_rules([cloudflare, broad], TRUSTED), "BLOCKED")
        self.assertEqual(gate.review_oci_rules([cloudflare, http], TRUSTED), "BLOCKED")

    def test_ipv6_and_ssh_distinctions(self):
        self.assertEqual(gate.rule_risk(rule("::/0"), TRUSTED), "overexposed")
        self.assertEqual(gate.rule_risk(rule("2400:cb00::/32"), TRUSTED), "safe")
        self.assertEqual(gate.rule_risk(rule("0.0.0.0/0", port=22), TRUSTED), "not-http")
        self.assertEqual(gate.rule_risk({"protocol":"1", "source": "0.0.0.0/0"}, TRUSTED), "not-http")
        self.assertEqual(gate.rule_risk(rule("0.0.0.0/0", **{"source-type":"NETWORK_SECURITY_GROUP"}), TRUSTED), "unknown")

    def test_all_protocol_rules_cannot_bypass_tcp_check(self):
        broad = {"direction": "INGRESS", "protocol": "all", "source": "0.0.0.0/0"}
        self.assertEqual(gate.review_oci_rules([broad], TRUSTED), "BLOCKED")

    def test_unknown_provider_shape_is_pending_never_pass(self):
        self.assertEqual(gate.review_oci_rules([{"direction":"INGRESS", "protocol":"6"}], TRUSTED), "PENDING")
        self.assertEqual(gate.review_oci_rules([], TRUSTED), "PENDING")
        self.assertEqual(gate.port_intersects({"destination-port-range": {"min": 500, "max": 499}}, 443), None)

    def test_cloudflare_routes_and_worker_custom_domain_collision(self):
        name = "vwoci-lab.lazymocha.com"
        matches = [record(name, "203.0.113.7")]
        self.assertEqual(gate.review_cf_candidate(name, gate.ZONE, matches,
            [], [], "203.0.113.7"), "PASS")
        self.assertEqual(gate.review_cf_candidate(name, gate.ZONE, matches,
            [{"pattern":"*.lazymocha.com/*", "script":"my-worker"}], [], "203.0.113.7"), "BLOCKED")
        self.assertEqual(gate.review_cf_candidate(name, gate.ZONE, matches,
            [], [{"hostname":name, "enabled":True}], "203.0.113.7"), "BLOCKED")
        self.assertTrue(gate.route_collides("*lazymocha.com/*", name))
        self.assertFalse(gate.route_collides("bw.lazymocha.com/*", name))

    def test_production_hostname_wildcard_and_wrong_origin_fail_closed(self):
        fqdn="vwoci-lab.lazymocha.com"
        self.assertEqual(gate.review_cf_candidate(gate.HISTORICAL_DOMAIN, gate.ZONE, [],
            [], [], "203.0.113.7"), "PENDING")
        self.assertEqual(gate.review_cf_candidate(fqdn, gate.ZONE, [record(fqdn, "198.51.100.5")],
            [], [], "203.0.113.7"), "BLOCKED")
        self.assertEqual(gate.review_cf_candidate(fqdn, gate.ZONE, [record("*.lazymocha.com", "198.51.100.5")],
            [], [], "203.0.113.7"), "BLOCKED")
        self.assertEqual(gate.review_cf_candidate(fqdn, gate.ZONE, [record(fqdn, "203.0.113.7", False)],
            [], [], "203.0.113.7"), "PENDING")
        self.assertEqual(gate.review_cf_candidate(fqdn, gate.ZONE, [record(fqdn, "203.0.113.7")],
            [], None, "203.0.113.7"), "PENDING")

    def test_cloudflare_pagination_must_be_complete(self):
        def first_page(_token, _path):
            return {"result": [{"name": "a"}], "result_info": {"total_pages": 2}}
        with mock.patch.object(gate, "cf_api", side_effect=first_page), \
             self.assertRaises(gate.Blocked):
            gate.cf_paginate("dummy", "/zones/candidate/dns_records", limit=1)
        def pages(_token, path):
            p = 1 if "page=1" in path else 2
            return {"result": [{"name": f"r{p}"}], "result_info": {"total_pages": 2}}
        with mock.patch.object(gate, "cf_api", side_effect=pages):
            found = gate.cf_paginate("dummy", "/zones/candidate/dns_records", limit=3)
        self.assertEqual([x["name"] for x in found], ["r1","r2"])

    def test_oci_cli_rejects_mutation_before_subprocess(self):
        with mock.patch.object(gate.subprocess, "run") as mockrun:
            with self.assertRaises(gate.Blocked):
                gate.oci_call(("network", "vnic", "update"), "--vnic-id",
                              "ocid1.vnic.oc1.xx.a", auth="config", executable=Path("/bin/false"))
            mockrun.assert_not_called()

    def test_host_mismatch_blocks_before_cloud_access(self):
        with mock.patch.object(gate, "host_ok", return_value=False), \
             mock.patch.object(gate, "imds") as imds, \
             mock.patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(gate.main(["--expected-commit", "a" * 40]), 2)
            imds.assert_not_called()

    def test_private_sanitized_report_and_no_leaked_tokens(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest=Path(tmp)
            with mock.patch("sys.stdout", new_callable=io.StringIO) as printed:
                self.assertEqual(gate.emit(dest, [("PASS", "oci.imdsv2-instance-and-vnic-inventory"),
                                 ("PENDING", "cloudflare.worker-custom-domains-scope-unverified"),
                                 ("NOT RUN", "no-provider-writes")], "HOLD"), 0)
            data=(dest/"summary.txt").read_text()
            self.assertIn("HOLD", data)
            self.assertEqual((dest/"summary.txt").stat().st_mode & 0o777, 0o600)
            self.assertNotIn("token", printed.getvalue().split("Gate P8T")[1].split("Share summary")[0])
            with self.assertRaises(FileExistsError):
                with mock.patch("sys.stdout", new_callable=io.StringIO):
                    gate.emit(dest, [], "HOLD")

    def test_no_write_operation_code_paths(self):
        source=SCRIPT.read_text()
        for item in ('"network", "nsg", "rules", "update"', '"dns_records" ,"post"',
                     '"edge", "refresh"', '"docker", "compose", "up"',
                     '"systemctl", "start"', '"rclone", "copy"', '"POST"'):
            self.assertNotIn(item, source)


if __name__ == "__main__":
    unittest.main()
