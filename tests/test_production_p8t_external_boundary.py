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
    def test_real_oracle_metadata_field_roles_not_identical(self):
        # Oracle defines displayName as a friendly name, independent of
        # hostname. The original test incorrectly equated the two.
        source = {
            "id": "ocid1.instance.oc1.phx.abc123def456",
            "displayName": "my-friendly-disposable-name",
            "hostname": gate.HOST,
        }
        vnics = [{"vnicId": "ocid1.vnic.oc1.phx.abc123def456",
                  "privateIp": "10.0.0.2", "nicIndex": 0}]
        actual_instance, actual_vnics = gate.validate_imds(source, vnics)
        self.assertEqual(actual_vnics, vnics)
        self.assertEqual(actual_instance, source)
        self.assertEqual(gate.imds_name_status(source),
            ("PASS", "oci.imdsv2-hostname-corresponds-to-linux-host"))

    def test_instance_display_name_matches_but_hostname_is_independent(self):
        instance = {"displayName": gate.HOST, "hostname": "vnic-host.label.internal"}
        self.assertEqual(gate.imds_name_status(instance),
            ("PASS", "oci.imdsv2-displayname-corresponds-to-linux-host"))

    def test_unrelated_friendly_name_is_pending_not_blocked(self):
        # OCI API/host correlation is not proven by Linux hostname alone.
        unrelated = {"displayName": "other-friendly-name", "hostname": "other-host"}
        self.assertEqual(gate.imds_name_status(unrelated),
            ("PENDING", "oci.imdsv2-provider-name-needs-independent-confirmation"))
        self.assertEqual(gate.imds_name_status({}),
            ("PENDING", "oci.imdsv2-provider-name-needs-independent-confirmation"))

    def test_metadata_schema_gaps_are_bounded_not_forged_acceptance(self):
        base = {"id": "ocid1.instance.oc1.phx.abc123def456",
                "displayName": "unrelated"}
        primary = {"vnicId": "ocid1.vnic.oc1.phx.abc123def456"}
        for instance, vnics, expected in [
            ([], [primary], "oci.imdsv2-instance-response-unrecognized"),
            ({"id": "not-an-ocid"}, [primary], "oci.imdsv2-instance-ocid-unrecognized"),
            (base, {}, "oci.imdsv2-vnics-response-unrecognized"),
            (base, [{"vnicId": "bad"}], "oci.imdsv2-vnic-ocid-unrecognized"),
            (base, [primary, primary], "oci.imdsv2-vnic-ocids-not-unique"),
        ]:
            with self.subTest(reason=expected):
                with self.assertRaises(gate.ProviderObservationIncomplete) as raised:
                    gate.validate_imds(instance, vnics)
                self.assertEqual(str(raised.exception), expected)
                self.assertIn(expected, gate.IMDS_OBSERVATIONS)

    def test_metadata_gets_only_fixed_imdsv2_paths_and_bearer_oracle(self):
        import json
        instance = {"id": "ocid1.instance.oc1.phx.abc123def456",
                    "displayName": "separate-friendly-name",
                    "hostname": gate.HOST}
        vnics = [{"vnicId": "ocid1.vnic.oc1.phx.abc123def456"}]
        with mock.patch.object(gate, "request_bytes", side_effect=[
                json.dumps(instance).encode(), json.dumps(vnics).encode()]) as read:
            self.assertEqual(gate.imds(), (instance, vnics))
        self.assertEqual(read.call_count, 2)
        self.assertEqual(
            [call.args[0] for call in read.call_args_list], [
                "http://169.254.169.254/opc/v2/instance/",
                "http://169.254.169.254/opc/v2/vnics/"])
        self.assertTrue(all(
            call.args[1].get("Authorization") == "Bearer Oracle"
            for call in read.call_args_list))

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

    def test_safe_network_codes_no_exception_text_or_provider_body(self):
        import socket
        import ssl
        from urllib.error import HTTPError, URLError
        errors = [
            (HTTPError("https://www.cloudflare.com/ips-v4", 403,
                       "private-token-should-not-leak", {}, None),
             "http-authorization-denied"),
            (HTTPError("https://www.cloudflare.com/ips-v6", 429,
                       "private-identifier-should-not-leak", {}, None),
             "http-rate-limited"),
            (HTTPError("https://www.cloudflare.com/ips-v4", 503,
                       "private-source-should-not-leak", {}, None),
             "http-server-unavailable"),
            (URLError(socket.gaierror("secret-address")), "dns-unavailable"),
            (URLError(ssl.SSLError("secret-certificate")), "tls-unavailable"),
            (URLError(TimeoutError("secret-timeout")), "timeout"),
            (ConnectionRefusedError("secret-origin"), "connection-unavailable"),
            (gate.Blocked("secret-http-body"), "response-unexpected"),
            (RuntimeError("secret-key-token"), "unclassified-unavailable"),
        ]
        for exc, code in errors:
            with self.subTest(code=code):
                result = gate.safe_read_failure(exc)
                self.assertEqual(result, code)
                self.assertNotIn("secret", result)

    def test_cloudflare_official_families_are_independently_classified(self):
        from urllib.error import URLError
        import socket
        with mock.patch.object(gate, "request_bytes", side_effect=[
                b"173.245.48.0/20\n103.21.244.0/22\n",
                b"2400:cb00::/32\n"]) as request:
            trusted, rows = gate.official_cidr_observations()
        self.assertEqual(set(trusted), {4, 6})
        self.assertEqual(rows, [
            ("PASS", "cloudflare.official-ipv4-cidr-fetched"),
            ("PASS", "cloudflare.official-ipv6-cidr-fetched"),
        ])
        self.assertEqual(request.call_count, 2)
        self.assertTrue(all(call.kwargs.get("maximum") == 8192
                            for call in request.call_args_list))

        with mock.patch.object(gate, "request_bytes", side_effect=[
                URLError(socket.gaierror("private-dns-error")),
                b"2400:cb00::/32\n"]):
            partial, diagnostics = gate.official_cidr_observations()
        self.assertEqual(set(partial), {6})
        self.assertEqual(diagnostics[0],
                         ("PENDING", "cloudflare.official-ipv4-dns-unavailable"))
        self.assertEqual(diagnostics[1],
                         ("PASS", "cloudflare.official-ipv6-cidr-fetched"))
        self.assertNotIn("private-dns-error", str(diagnostics))

    def test_no_oci_cli_reports_tool_absence_independently_of_cidrs(self):
        with mock.patch.object(gate.Path, "is_file", return_value=False):
            self.assertIsNone(gate.find_oci_cli())

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
        self.assertTrue(gate.route_collides("https://*.lazymocha.com/*", name))
        self.assertEqual(gate.review_cf_candidate(name, gate.ZONE, matches,
            [], [{"hostname":"lazymocha.com", "previews_enabled":True}], "203.0.113.7"), "BLOCKED")
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
            p = 1 if "&page=1&" in path or "?page=1&" in path else 2
            return {"result": [{"name": f"r{p}"}], "result_info": {"total_pages": 2}}
        with mock.patch.object(gate, "cf_api", side_effect=pages):
            found = gate.cf_paginate("dummy", "/zones/candidate/dns_records", limit=3)
        self.assertEqual([x["name"] for x in found], ["r1","r2"])

    def test_cloudflare_get_only_endpoint_allowlist(self):
        doc={"success":True, "result":[], "result_info":{"total_pages":1}}
        with mock.patch.object(gate, "request_bytes", return_value=__import__("json").dumps(doc).encode()) as req:
            zone=gate.cf_api("test-token", "/zones?name=lazymocha.com&page=1&per_page=100")
            self.assertEqual(zone["result"], [])
            req.assert_called_once()
            self.assertEqual(req.call_args.args[0],
                "https://api.cloudflare.com/client/v4/zones?name=lazymocha.com&page=1&per_page=100")
        for url in ("/zones?name=lazymocha.com&foo=write",
                    "/zones/"+"a"*32+"/dns_records?type=A&method=POST",
                    "/accounts/"+"a"*32+"/workers/domains?update=1"):
            with self.subTest(url=url), mock.patch.object(gate, "request_bytes") as req:
                with self.assertRaises(gate.Blocked):
                    gate.cf_api("test-token", url)
                req.assert_not_called()

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
