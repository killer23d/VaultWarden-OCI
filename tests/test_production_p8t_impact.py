"""Read-only OCI P8T-L shared security-list impact and redaction regressions."""
from __future__ import annotations
import importlib.util
import io
import json
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

SRC=Path(__file__).parent/"host-acceptance/production-p8t-oci-security-list-impact-readonly.py"
SP=importlib.util.spec_from_file_location("p8t_impact",SRC)
assert SP and SP.loader
impact=importlib.util.module_from_spec(SP)
SP.loader.exec_module(impact)
cloud=impact.load("production-p8t-oci-cloud-shell-readonly.py")
gate=cloud.module()

INST="ocid1.instance.oc1.iad.abc123"
COMP="ocid1.compartment.oc1..abc123"
VNIC="ocid1.vnic.oc1.iad.abc123"
SUBNET="ocid1.subnet.oc1.iad.abc123"
VCN="ocid1.vcn.oc1.iad.abc123"
LIST="ocid1.securitylist.oc1.iad.abc123"
REGION="us-ashburn-1"

def rule(source,low=80,high=80):
    return {"source":source,"protocol":"6",
            "tcp-options":{"destination-port-range":{"min":low,"max":high}}}

class Tests(unittest.TestCase):
    def test_invalid_or_unscoped_supplementary_oci_calls_cannot_run(self):
        with mock.patch.object(impact.subprocess,"run") as run:
            self.assertIsNone(impact.extra_get("delete",SUBNET,REGION))
            self.assertIsNone(impact.extra_get("subnets",COMP,REGION))
            self.assertIsNone(impact.extra_get("ips","untrusted",REGION))
            run.assert_not_called()

    def test_private_ip_and_vcn_scoped_gets_are_cli_read_only(self):
        result=subprocess.CompletedProcess(["oci"],0,b'{"data":[]}',b"")
        with mock.patch.object(impact.subprocess,"run",return_value=result) as run:
            self.assertEqual(impact.extra_get("subnets",COMP,REGION,vcn=VCN),[])
            args=run.call_args.args[0]
            self.assertEqual(args[:8],["oci","network","subnet","list",
                         "--compartment-id",COMP,"--vcn-id",VCN])
            self.assertIn("--all",args)
            self.assertNotIn("env",run.call_args.kwargs)
            self.assertEqual(run.call_args.kwargs["stderr"],subprocess.DEVNULL)
            self.assertEqual(impact.extra_get("ips",SUBNET,REGION),[])
            self.assertEqual(run.call_args.args[0][:5],
                ["oci","network","private-ip","list","--subnet-id"])

    def test_inherited_cloud_shell_oci_get_failure_is_pending_without_provider_body(self):
        result=subprocess.CompletedProcess(["oci"],1,b"private-ids",
                                           b"Access forbidden secret-content")
        with mock.patch.object(impact.subprocess,"run",return_value=result):
            self.assertIsNone(impact.extra_get("subnets",COMP,REGION,vcn=VCN))

    def test_oci_subnet_security_list_impact_ipv4_ipv6_and_scope(self):
        captured=[]
        def read(cmd,key,value,region,**kwargs):
            data={
                ("compute","instance","get"):
                    {"id":INST,"compartment-id":COMP},
                ("compute","vnic-attachment","list"):
                    [{"vnic-id":VNIC,"lifecycle-state":"ATTACHED"}],
                ("network","vnic","get"):{"id":VNIC,"subnet-id":SUBNET},
                ("network","subnet","get"):
                    {"id":SUBNET,"vcn-id":VCN,"compartment-id":COMP,
                     "security-list-ids":[LIST]},
                ("network","security-list","get"):
                    {"display-name":"disposable-net","ingress-security-rules":[
                        rule("0.0.0.0/0",80,443),rule("::/0",443,443),
                        rule("0.0.0.0/0",22,22)]},
            }
            return data[cmd]
        def supplement(kind,identity,region,**kwargs):
            if kind=="vcn":
                return {"id":VCN,"compartment-id":COMP,"default-security-list-id":LIST}
            if kind=="subnets":
                self.assertEqual(kwargs["vcn"],VCN)
                return [{"id":SUBNET,"security-list-ids":[LIST]},
                        {"id":"ocid1.subnet.oc1.iad.other","security-list-ids":[LIST]}]
            if kind=="ips":
                return [{"vnic-id":VNIC},{"vnic-id":"ocid1.vnic.oc1.iad.other"}]
            self.fail("Unexpected query")
        fakecloud=SimpleNamespace(module=lambda:gate,
            data_only=read,REGION_RE=cloud.REGION_RE,
            categorized_http_exposure=cloud.categorized_http_exposure)
        with mock.patch.object(gate,"source_clean",return_value=True), \
             mock.patch.object(impact,"load",return_value=fakecloud), \
             mock.patch.object(impact,"extra_get",side_effect=supplement), \
             mock.patch.object(impact,"put_private",side_effect=lambda m:(
                 captured.append(m) or Path("/private/report.json"))), \
             mock.patch.object(impact.shutil,"which",return_value="/home/oci/bin/oci"), \
             mock.patch("sys.stdout",new_callable=io.StringIO) as printed:
            code=impact.scan("a"*40,INST,REGION)
        self.assertEqual(code,2)
        output=printed.getvalue()
        for key in ("oci.list-01.ipv4.global-tcp80",
                    "oci.list-01.ipv4.global-tcp443",
                    "oci.list-01.ipv6.global-tcp443",
                    "oci.offending-list-is-vcn-default",
                    "oci.offending-list-shared-with-other-subnets",
                    "oci.target-subnet-has-other-vnics"):
            self.assertIn(key,output)
        self.assertNotIn(INST,output)
        self.assertNotIn(LIST,output)
        self.assertEqual(len(captured),1)
        self.assertEqual(captured[0]["security_lists"][0]["security_list_id"],LIST)
        self.assertEqual(captured[0]["subnets"][0]["other_vnic_count_in_subnet"],1)

    def test_real_private_mapping_has_0700_container_and_0600_file(self):
        with tempfile.TemporaryDirectory() as root, \
             mock.patch.object(impact.Path,"home",return_value=Path(root)):
            path=impact.put_private({"security_lists":[{"ref":"list-01"}]})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode),0o700)
            self.assertIn("list-01",path.read_text())

    def test_no_provider_write_command_appears_in_helper(self):
        source=SRC.read_text()
        self.assertNotIn('"network","security-list","update"',source)
        self.assertNotIn('"network","subnet","update"',source)
        self.assertNotIn('shell=True',source)

if __name__=="__main__":
    unittest.main()
