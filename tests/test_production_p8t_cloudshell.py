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
        self.assertEqual(calls.call_args.kwargs.get("stderr"),shell.subprocess.DEVNULL)

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
