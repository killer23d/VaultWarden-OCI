"""P8T OCI Cloud Shell read-only witness negative cases."""
from __future__ import annotations

import importlib.util
import io
import json
import unittest
from pathlib import Path
from unittest import mock

SCRIPT=Path(__file__).parent / "host-acceptance/production-p8t-oci-cloud-shell-readonly.py"
SPEC=importlib.util.spec_from_file_location("p8t_oci_shell", SCRIPT)
assert SPEC and SPEC.loader
shell=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(shell)
gate=shell.module()
REGION="us-ashburn-1"
INSTANCE="ocid1.instance.oc1.iad.aaaabbbccc"
VNIC="ocid1.vnic.oc1.iad.aaaabbbccc"


class CloudShellReadOnlyTests(unittest.TestCase):
    def test_broad_public_http_https_detected_without_cloudflare_cidrs(self):
        def ingress(port, source, protocol="6"):
            return {"direction":"INGRESS", "protocol":protocol, "source":source,
                    "tcp-options":{"destination-port-range":{"min":port,"max":port}}}
        self.assertTrue(shell.obvious_public_ingress(ingress(80,"0.0.0.0/0"), gate))
        self.assertTrue(shell.obvious_public_ingress(ingress(443,"::/0"), gate))
        self.assertFalse(shell.obvious_public_ingress(ingress(22,"0.0.0.0/0"), gate))
        self.assertFalse(shell.obvious_public_ingress(ingress(443,"173.245.48.0/20"), gate))

    def test_only_approved_oci_cli_read_commands_allowed(self):
        with mock.patch.object(shell.subprocess, "run") as calls:
            value=shell.data_only(("network","nsg","rules","add"), "--nsg-id",
                    VNIC, REGION)
            self.assertIsNone(value)
            value=shell.data_only(("network","vnic","get"), "--vnic-id",
                    "untrusted-ocid", REGION)
            self.assertIsNone(value)
            value=shell.data_only(("compute","instance","get"), "--instance-id",
                    INSTANCE, "wrong-region")
            self.assertIsNone(value)
            calls.assert_not_called()

    def test_attachment_query_must_filter_exact_disposable_instance(self):
        from subprocess import CompletedProcess
        compartment="ocid1.tenancy.oc1..abcdefgh"
        payload={"data":[{"vnic-id":VNIC, "lifecycle-state":"ATTACHED"}]}
        with mock.patch.object(shell.subprocess, "run", return_value=
                CompletedProcess(["oci"], 0, json.dumps(payload).encode(), b"")) as run:
            absent=shell.data_only(("compute","vnic-attachment","list"),
                    "--compartment-id", compartment, REGION, extra=("--all",))
            self.assertIsNone(absent)
            run.assert_not_called()
            unrelated=shell.data_only(("compute","vnic-attachment","list"),
                    "--compartment-id", compartment, REGION, extra=("--all",),
                    instance_filter="ocid1.vnic.oc1.iad.not-instance")
            self.assertIsNone(unrelated)
            run.assert_not_called()
            actual=shell.data_only(("compute","vnic-attachment","list"),
                    "--compartment-id", compartment, REGION, extra=("--all",),
                    instance_filter=INSTANCE)
            self.assertEqual(actual, payload["data"])
            called=run.call_args.args[0]
            self.assertIn("--instance-id",called)
            self.assertEqual(called[called.index("--instance-id")+1], INSTANCE)
            self.assertIn("--all",called)

    def test_cli_get_sanitizes_raw_failures(self):
        from subprocess import CompletedProcess
        with mock.patch.object(shell.subprocess, "run", return_value=
                CompletedProcess(["oci"], 1, b"secret-nsg-ocid", b"secret-auth-detail")):
            result=shell.data_only(("compute","instance","get"),
                    "--instance-id", INSTANCE, REGION)
        self.assertIsNone(result)

    def test_valid_json_comes_from_bounded_single_get(self):
        from subprocess import CompletedProcess
        result={"data":{"id":INSTANCE, "compartment-id":"ocid1.tenancy.oc1..abcd"}}
        with mock.patch.object(shell.subprocess, "run", return_value=
                CompletedProcess(["oci"], 0, json.dumps(result).encode(), b"")) as calls:
            data=shell.data_only(("compute","instance","get"),
                   "--instance-id", INSTANCE, REGION)
        self.assertEqual(data["id"], INSTANCE)
        self.assertIn("--region", calls.call_args.args[0])
        self.assertEqual(calls.call_args.kwargs.get("stderr"), shell.subprocess.PIPE)
        self.assertNotIn("env", calls.call_args.kwargs)  # inherit delegated CLI auth
        self.assertEqual(calls.call_args.kwargs["timeout"], 75)
        self.assertEqual(calls.call_args.args[0][-8:],
                         ["--output", "json", "--max-retries", "0",
                          "--connection-timeout", "4", "--read-timeout", "10"])

    def test_exact_region_and_instance_cli_matches_successful_shell_probe(self):
        from subprocess import CompletedProcess
        from unittest.mock import patch
        instance = "ocid1.instance.oc1.us-sanjose-1.aaabbbcccddd"
        payload = {"data": {"id": instance, "compartment-id": "ocid1.compartment.oc1..abcd"}}
        with patch.dict(shell.os.environ, {
                "OCI_CLI_AUTH": "instance_obo_user",
                "OCI_CLI_CONFIG_FILE": "/etc/oci/config",
                "OCI_CLI_PROFILE": "us-sanjose-1"}), \
             mock.patch.object(shell.subprocess, "run",
                 return_value=CompletedProcess(["oci"], 0, json.dumps(payload).encode(), b"")) as run:
            failure_codes = []
            data = shell.data_only(("compute", "instance", "get"), "--instance-id",
                                   instance, "us-sanjose-1", diagnostic=failure_codes)
            self.assertEqual(data, payload["data"])
            self.assertEqual(failure_codes, [])
            self.assertEqual(run.call_args.args[0],
                ["oci", "compute", "instance", "get", "--instance-id", instance,
                 "--region", "us-sanjose-1", "--output", "json",
                 "--max-retries", "0", "--connection-timeout", "4",
                 "--read-timeout", "10"])
            self.assertNotIn("env", run.call_args.kwargs)


    def test_exact_broad_rule_classifies_security_list_nsg_family_and_ports(self):
        trusted={
            4: gate.cidr_set("173.245.48.0/20\n103.21.244.0/22\n", 4),
            6: gate.cidr_set("2400:cb00::/32\n", 6),
        }
        def r(source, low=443, high=443, protocol="6"):
            return {"direction":"INGRESS","protocol":protocol,"source":source,
                "tcp-options":{"destination-port-range":{"min":low,"max":high}}}
        cases=[
            (r("0.0.0.0/0",80,80),"security-list",
             ("oci.cloudshell.security-list.ipv4.global-tcp80",)),
            (r("::/0"),"nsg",
             ("oci.cloudshell.nsg.ipv6.global-tcp443",)),
            (r("0.0.0.0/0",protocol="all"),"nsg",
             ("oci.cloudshell.nsg.ipv4.global-tcp80",
              "oci.cloudshell.nsg.ipv4.global-tcp443")),
            (r("0.0.0.0/0",22,22),"security-list",()),
            (r("173.245.48.0/20"),"nsg",()),
            (r("173.245.48.0/20",80,80),"nsg",
             ("oci.cloudshell.nsg.ipv4.public-tcp80",)),
            (r("203.0.113.0/24"),"nsg",
             ("oci.cloudshell.nsg.ipv4.outside-cloudflare-tcp443",)),
        ]
        for rule,kind,expected in cases:
            with self.subTest(source=rule["source"],kind=kind):
                self.assertEqual(shell.categorized_http_exposure(rule,kind,gate,trusted),expected)
                self.assertNotIn(rule["source"],str(expected))

    def test_complete_provider_gate_reports_all_rule_sources_in_one_run(self):
        from types import SimpleNamespace
        compartment="ocid1.compartment.oc1..abcd"
        subnet="ocid1.subnet.oc1.iad.aaaabc"
        slist="ocid1.securitylist.oc1.iad.aaaabc"
        nsg="ocid1.networksecuritygroup.oc1.iad.aaaabc"
        seen=[]
        trusted={
            4:gate.cidr_set("173.245.48.0/20\n103.21.244.0/22\n",4),
            6:gate.cidr_set("2400:cb00::/32\n",6),
        }
        def rule(source,port):
            return {"direction":"INGRESS","protocol":"6","source":source,
                    "tcp-options":{"destination-port-range":{"min":port,"max":port}}}
        def provider(cmd,key,value,region,**kwargs):
            operations={
                ("compute","instance","get"):
                    {"id":INSTANCE,"compartment-id":compartment,"display-name":gate.HOST},
                ("compute","vnic-attachment","list"):
                    [{"vnic-id":VNIC,"lifecycle-state":"ATTACHED"}],
                ("network","vnic","get"):
                    {"id":VNIC,"subnet-id":subnet,"nsg-ids":[nsg],"public-ip":"203.0.113.8"},
                ("network","subnet","get"):
                    {"id":subnet,"security-list-ids":[slist]},
                ("network","security-list","get"):
                    {"ingress-security-rules":[rule("0.0.0.0/0",80),
                                               rule("203.0.113.0/24",443)]},
                ("network","nsg","rules","list"):
                    [rule("::/0",443)],
                ("network","ipv6","list"): [],
            }
            if cmd==("compute","vnic-attachment","list"):
                self.assertEqual(kwargs["instance_filter"],INSTANCE)
            return operations[cmd]
        def emit(_folder,rows,outcome):
            seen.extend(rows)
            return 2 if outcome=="BLOCKED" else 0
        p8t=SimpleNamespace(
            HOST=gate.HOST,source_clean=lambda _:True,
            official_cidr_observations=lambda: (trusted,[("PASS","cloudflare.official-api-dualstack-cidrs-validated")]),
            port_intersects=gate.port_intersects,rule_risk=gate.rule_risk,
            review_oci_rules=gate.review_oci_rules,emit=emit)
        with mock.patch.object(shell.shutil,"which",return_value="/home/oci/bin/oci"), \
             mock.patch.object(shell,"module",return_value=p8t), \
             mock.patch.object(shell,"data_only",side_effect=provider):
            code=shell.verify(["--expected-commit","a"*40,"--instance-id",INSTANCE,"--region",REGION])
        self.assertEqual(code,2)
        self.assertEqual({key for state,key in seen if state=="BLOCKED"},{
            "oci.cloudshell.security-list.ipv4.global-tcp80",
            "oci.cloudshell.security-list.ipv4.outside-cloudflare-tcp443",
            "oci.cloudshell.nsg.ipv6.global-tcp443",
        })
        self.assertIn(("NOT RUN","oci.cloudshell-no-provider-iam-network-or-service-mutations"),seen)
        self.assertFalse(any("ocid1." in key or "203.0.113." in key for _,key in seen))

    def test_cli_failure_categorization_redacts_provider_stderr(self):
        from subprocess import CompletedProcess
        cases = [
            (b"ServiceError: NotAuthorizedOrNotFound ... secretOCID", "not-authorized-or-not-found"),
            (b"ConfigFileNotFound secretPath", "config-file-unavailable"),
            (b"Error: No such option: --example secretInfo", "cli-argument-unsupported"),
            (b"NotAuthenticated token-should-not-leak", "authentication-rejected"),
            (b"random-auth-private-error", "cli-nonzero-unclassified"),
        ]
        for stderr, reason in cases:
            with self.subTest(reason=reason), \
                 mock.patch.object(shell.subprocess, "run",
                     return_value=CompletedProcess(["oci"], 1, b"secret-output", stderr)):
                diagnostics = []
                data = shell.data_only(("compute", "instance", "get"),
                    "--instance-id", INSTANCE, REGION, diagnostic=diagnostics)
                self.assertIsNone(data)
                self.assertEqual(diagnostics, [reason])
                self.assertNotIn("secret", str(diagnostics))
                self.assertEqual(shell.cli_failure_code(stderr), reason)

    def test_missing_data_and_malformed_json_have_specific_safe_codes(self):
        from subprocess import CompletedProcess
        for payload, reason in [
            (b"untrusted private output", "cli-response-json-invalid"),
            (b'{"other":"private"}', "cli-response-data-missing"),
            (b"", "cli-response-empty-or-oversized"),
        ]:
            with self.subTest(reason=reason), \
                 mock.patch.object(shell.subprocess, "run",
                     return_value=CompletedProcess(["oci"], 0, payload, b"")):
                diagnostics = []
                self.assertIsNone(shell.data_only(
                    ("compute", "instance", "get"), "--instance-id", INSTANCE,
                    REGION, diagnostic=diagnostics))
                self.assertEqual(diagnostics, [reason])

    def test_verify_initial_instance_failure_emits_sanitized_reason(self):
        from types import SimpleNamespace
        recorder = []
        def emit(_folder, rows, outcome):
            recorder.extend(rows)
            return 0 if outcome == "HOLD" else 2
        def unavailable(*args, **kwargs):
            kwargs["diagnostic"].append("cli-argument-unsupported")
            return None
        stub = SimpleNamespace(source_clean=lambda *_: True, emit=emit)
        with mock.patch.object(shell.shutil, "which", return_value="/home/oci/bin/oci"), \
             mock.patch.object(shell, "module", return_value=stub), \
             mock.patch.object(shell, "data_only", side_effect=unavailable), \
             mock.patch("sys.stdout", new_callable=io.StringIO):
            rc = shell.verify(["--expected-commit", "a" * 40,
                               "--instance-id", INSTANCE, "--region", REGION])
        self.assertEqual(rc, 0)
        self.assertEqual(recorder, [
            ("PENDING", "oci.cloudshell-instance-get-cli-argument-unsupported")
        ])

    def test_bad_instance_is_rejected_before_provider_access(self):
        with mock.patch.object(shell.shutil,"which",return_value="/usr/bin/oci"), \
             mock.patch.object(shell, "module") as import_gate, \
             mock.patch("sys.stdout", new_callable=io.StringIO) as printed:
            rc=shell.verify(["--expected-commit","a"*40,
                             "--instance-id","production-id-untrusted",
                             "--region",REGION])
        self.assertEqual(rc,2)
        import_gate.assert_not_called()
        self.assertNotIn("production-id-untrusted", printed.getvalue())

    def test_no_provider_mutation_in_accepted_command_inventory(self):
        self.assertEqual(shell.ALLOWED, frozenset({
            ("compute","instance","get"),
            ("compute","vnic-attachment","list"),
            ("network","vnic","get"),
            ("network","subnet","get"),
            ("network","security-list","get"),
            ("network","nsg","rules","list"),
            ("network","ipv6","list"),
        }))
        src=SCRIPT.read_text()
        self.assertNotIn("shell=True",src)
        self.assertNotIn('"--force"',src)


if __name__=="__main__":
    unittest.main()
