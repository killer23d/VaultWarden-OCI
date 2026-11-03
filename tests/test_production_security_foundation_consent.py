"""Safety and mocked full-path acceptance tests for P5 CrowdSec foundation."""
from __future__ import annotations

import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

SCRIPT=Path(__file__).parent/"host-acceptance"/"production-security-foundation-consent.py"
spec=importlib.util.spec_from_file_location("rc12_p5_security_foundation", SCRIPT)
assert spec and spec.loader
p5=importlib.util.module_from_spec(spec)
spec.loader.exec_module(p5)


class SecurityFoundationTests(unittest.TestCase):
    def test_consent_exact_only(self):
        self.assertTrue(p5.check_consent(p5.CONSENT))
        for candidate in ("", "yes", "SECURITY FOUNDATION", p5.CONSENT.lower(),
                          p5.CONSENT+" now", " "+p5.CONSENT, p5.CONSENT+"\nCANCEL"):
            self.assertFalse(p5.check_consent(candidate))

    def test_allowlisted_doctor_is_sanitized_and_strict(self):
        keys=("edge.cloudflare.cidrs","crowdsec.engine")
        good=json.dumps({"schema_version":1,"overall":"FAIL","checks":[
            {"id":keys[0],"status":"PASS","message":"PRIVATE-TOKEN"},
            {"id":keys[1],"status":"FAIL","message":"SECRET-CREDENTIAL"}]})
        self.assertEqual(p5.class_doctor(good,1,keys),("valid",{
            "edge.cloudflare.cidrs":"PASS","crowdsec.engine":"FAIL"}))
        self.assertEqual(p5.class_doctor(good,0,keys)[0],"inconsistent_overall_or_exit")
        self.assertEqual(p5.class_doctor(good.replace("crowdsec.engine","unknown.id"),1,keys)[0],
                         "unexpected_or_duplicate_check_id")
        self.assertEqual(p5.class_doctor(good.replace("crowdsec.engine","edge.cloudflare.cidrs"),1,keys)[0],
                         "unexpected_or_duplicate_check_id")
        self.assertEqual(p5.class_doctor("",1,keys)[0],"empty_stdout")
        self.assertEqual(p5.class_doctor("not json",1,keys)[0],"non_json_stdout")
        self.assertEqual(p5.class_doctor("{}",1,keys)[0],"invalid_schema")
        self.assertEqual(p5.class_doctor(good,None,keys)[0],"command_unavailable_or_timeout")
        invalid=json.dumps({"schema_version":1,"overall":"FAIL","checks":[{"id":[],"status":"FAIL"}]})
        self.assertEqual(p5.class_doctor(invalid,1,keys)[0],"unexpected_or_duplicate_check_id")

    def test_safe_doctor_shape_counts_unknown_duplicate_and_missing_without_raw_ids(self):
        allowed = ("runtime.docker", "crowdsec.engine", "edge.cloudflare.cidrs")
        dangerous = "PRIVATE-TOKEN-DO-NOT-EMIT@domain.example"
        raw = json.dumps({
            "schema_version": 1, "overall": "FAIL",
            "checks": [
                {"id": "runtime.docker", "status": "PASS", "message": "SECRET-VALUE"},
                {"id": "runtime.docker", "status": "FAIL", "message": "SECRET-VALUE"},
                {"id": dangerous, "status": "FAIL", "message": "SECRET-VALUE"},
                {"id": "crowdsec.engine", "status": "INVALID-SECRET-STATUS", "message": "SECRET-VALUE"},
            ],
        })
        classification, parsed = p5.class_doctor(raw, 1, allowed)
        self.assertEqual(classification, "unexpected_or_duplicate_check_id")
        self.assertEqual(parsed, {})
        safe = p5.safe_doctor_shape(raw, allowed)
        for expected in (
            "observed_checks=4", "expected_checks=3", "unknown_id_count=1",
            "duplicate_expected_ids=runtime.docker",
            "missing_expected_ids=edge.cloudflare.cidrs",
            "invalid_status_count=1",
            "invalid_status_expected_ids=crowdsec.engine",
        ):
            self.assertIn(expected, safe)
        for forbidden in (dangerous, "SECRET-VALUE", "INVALID-SECRET-STATUS"):
            self.assertNotIn(forbidden, safe)

    def test_safe_doctor_shape_malformed_and_empty_are_categorized(self):
        self.assertEqual(p5.safe_doctor_shape("not json", ("host.os",)), "doctor_output_not_json")
        self.assertEqual(p5.safe_doctor_shape("{}", ("host.os",)), "doctor_output_invalid_schema")
        self.assertEqual(p5.safe_doctor_shape("{}", ("host.os", "host.os")), "invalid_approved_registry")
        unknown = json.dumps({"checks": [{"id": ["SECRET"], "status": "PASS"}]})
        safe = p5.safe_doctor_shape(unknown, ("host.os",))
        self.assertIn("invalid_id_type_count=1", safe)
        self.assertNotIn("SECRET", safe)

    def test_installed_product_registry_contract_accepts_26_unique_ids(self):
        from vaultwarden_oci import cli
        expected = tuple(cli.DOCTOR_CHECK_IDS)
        self.assertEqual(len(expected), 26)
        self.assertEqual(len(set(expected)), 26)
        fixture = json.dumps({
            "schema_version": 1,
            "overall": "FAIL",
            "checks": [
                {"id": name, "status": ("FAIL" if name == "crowdsec.engine" else "PASS"),
                 "message": "never include doctor messages in the summary"}
                for name in expected
            ],
        })
        classification, observed = p5.class_doctor(fixture, 1, expected)
        self.assertEqual(classification, "valid")
        self.assertEqual(len(observed), 26)
        self.assertEqual(p5.safe_doctor_shape(fixture, expected).split()[0], "observed_checks=26")

    def test_gate_requires_real_foundation_and_warns_on_partial_state(self):
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp)
            with contextlib.redirect_stdout(io.StringIO()):
                empty=p5.Gate(folder)
                self.assertEqual(empty.finish(),0)
                self.assertIn("HOLD", (folder/"summary.txt").read_text())
                cancelled=p5.Gate(folder)
                cancelled.cancelled=True
                self.assertEqual(cancelled.finish(),0)
                self.assertIn("CANCELLED", (folder/"summary.txt").read_text())
                partial=p5.Gate(folder)
                partial.mutation_started=True
                self.assertEqual(partial.finish(),2)
                self.assertIn("Partial host security state possible", (folder/"summary.txt").read_text())
                passed=p5.Gate(folder)
                passed.mutation_started=True
                passed.verified=True
                self.assertEqual(passed.finish(),0)
                self.assertIn("FOUNDATION", (folder/"summary.txt").read_text())

    def test_private_command_protects_logs_and_redacts_external_stdout(self):
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp)
            self.assertEqual(p5.run_private(
                [sys.executable,"-c","print('SECRET-TOKEN-DO-NOT-DISPLAY')"],
                directory,"probe-command",8),0)
            log=directory/"probe-command.private.log"
            self.assertEqual(log.stat().st_mode&0o777,0o600)
            self.assertIn("SECRET-TOKEN",log.read_text())
            with self.assertRaises(FileExistsError):
                p5.run_private([sys.executable,"-c","pass"],directory,"probe-command",8)
            with self.assertRaises(ValueError):
                p5.run_private([sys.executable,"-c","pass"],directory,"../escape",8)

    def test_original_state_requires_no_unexpected_worker_or_client(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            disk=root/"disk"
            disk.write_bytes(b"fixture")
            alias=root/"byid"
            alias.symlink_to(disk)
            release=root/"release"
            release.mkdir()
            current=root/"current"
            current.symlink_to(release,target_is_directory=True)
            data=root/"data"
            data.mkdir()
            db=data/"db.sqlite3"
            db.write_bytes(b"fictional SQLite data")
            p4=SimpleNamespace(
                CRITICAL_UNITS=("vaultwarden-oci.service","vaultwarden-oci-dns.service"),
                effective_unstarted=lambda *args,**kw: True)
            def properties(unit):
                if unit=="docker.service":return {"LoadState":"loaded","ActiveState":"active"}
                if unit.startswith("crowdsec"):return {"LoadState":"not-found","ActiveState":"inactive",
                                                       "UnitFileState":"disabled"}
                return {"LoadState":"loaded","ActiveState":"inactive","UnitFileState":"disabled"}
            p1=SimpleNamespace(
                EXPECTED_VOLUME_UUID="test-volume",
                EXPECTED_BYID=alias,
                service_properties=properties,
                run_readonly=lambda *a,**kw:(0,""),
                listening_ports=lambda:set(),
                daemon_running=lambda props:props.get("ActiveState")=="active")
            storage=SimpleNamespace(verify=lambda:SimpleNamespace(uuid="test-volume",source=str(disk)))
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(p5,"CURRENT",current))
                stack.enter_context(mock.patch.object(p5,"INSTALLED",release))
                stack.enter_context(mock.patch.object(p5,"STATE",root))
                stack.enter_context(mock.patch.object(p5,"DB_SHA","fake-hash"))
                stack.enter_context(mock.patch.object(p5,"sha256_file",return_value="fake-hash"))
                stack.enter_context(mock.patch.object(p5.Path,"exists",autospec=True,
                    side_effect=lambda path: str(path)==str(db) if str(path)==str(db) else False))
                self.assertTrue(p5.exact_isolation(p1,p4,storage,expect_security_installed=False))
                p1.listening_ports=lambda:{443}
                self.assertFalse(p5.exact_isolation(p1,p4,storage,expect_security_installed=False))

    def mocked_main(self, *, doctor: str, consent: str, post_valid: bool = True) -> tuple[int,str,int]:
        from vaultwarden_oci import runtime, secrets
        class Tty(io.StringIO):
            def isatty(self):return True
        with tempfile.TemporaryDirectory() as tmp:
            directory=Path(tmp)
            release=directory/"release"
            release.mkdir()
            current=directory/"current"
            current.symlink_to(release,target_is_directory=True)
            evidence=directory/"evidence"
            evidence.mkdir()
            p1=SimpleNamespace(
                release_integrity=lambda *a:(True,52),
                systemd_unit_integrity=lambda *a:(True,12),
                matches_offline_recipient=lambda *a:True)
            p4=SimpleNamespace()
            config=SimpleNamespace(offline_recovery_recipient="age1-fixture",offsite_remote=p5.EXPECTED_REMOTE,
                local_retention_days=0,remote_retention_days=0)
            calls=[]
            tty=Tty()
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(p5.os,"geteuid",return_value=0))
                stack.enter_context(mock.patch.object(p5.sys,"argv",["p5.py"]))
                stack.enter_context(mock.patch.object(p5.sys,"stdin",tty))
                stack.enter_context(mock.patch.object(p5.sys,"path",list(sys.path)))
                stack.enter_context(mock.patch.object(p5.sys,"version_info",(3,14,0)))
                stack.enter_context(mock.patch.object(p5.platform,"node",return_value=p5.HOST))
                stack.enter_context(mock.patch.object(p5.platform,"machine",return_value="aarch64"))
                stack.enter_context(mock.patch.object(p5,"CURRENT",current))
                stack.enter_context(mock.patch.object(p5,"INSTALLED",release))
                stack.enter_context(mock.patch.object(p5,"evidence_root",return_value=evidence))
                stack.enter_context(mock.patch.object(p5,"module",side_effect=[p1,p4]))
                stack.enter_context(mock.patch.object(p5,"exact_isolation",return_value=True))
                stack.enter_context(mock.patch.object(runtime,"load_config",return_value=config))
                stack.enter_context(mock.patch.object(secrets,"validate_encrypted",
                    return_value={"cloudflare_remediation_token":"secret-fixture"}))
                stack.enter_context(mock.patch.object(p5,"diagnose_doctor",side_effect=[
                    (doctor,{}, "observed_checks=27 expected_checks=26 unknown_id_count=1")] +
                    ([("valid",{name:"PASS" for name in p5.REQUIRED_DOCTOR},"not_needed")]
                     if post_valid else [])))
                runner=stack.enter_context(mock.patch.object(p5,"run_private",return_value=0))
                stack.enter_context(mock.patch("builtins.input",return_value=consent))
                stack.enter_context(mock.patch.object(p5.signal,"signal"))
                stack.enter_context(contextlib.redirect_stdout(tty))
                result=p5.main()
            summary=(evidence/"summary.txt").read_text()
            return result,summary,runner.call_count

    def test_unparseable_product_doctor_blocks_before_mutation_or_prompt(self):
        code,report,calls=self.mocked_main(doctor="non_json_stdout",consent=p5.CONSENT)
        self.assertEqual(code,0)
        self.assertEqual(calls,0)
        self.assertIn("Doctor structural diagnostic unresolved",report)
        self.assertNotIn("FOUNDATION",report)

    def test_cancel_does_not_run_firewall_or_packages(self):
        code,report,calls=self.mocked_main(doctor="valid",consent="CANCEL")
        self.assertEqual(code,0)
        self.assertEqual(calls,0)
        self.assertIn("CANCELLED",report)

    def test_exact_consent_calls_both_product_owner_commands_and_sanitizes(self):
        code,report,calls=self.mocked_main(doctor="valid",consent=p5.CONSENT)
        self.assertEqual(code,0)
        self.assertEqual(calls,2)
        self.assertIn("FOUNDATION",report)
        self.assertIn("CrowdSec engine/Hub/host INPUT firewall doctor checks all PASS",report)
        self.assertNotIn("secret-fixture",report)

if __name__=="__main__":
    unittest.main()
