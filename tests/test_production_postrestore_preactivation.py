"""Pure and full-path mocked P4 tests; no real account, network or host mutations."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance" / "production-postrestore-preactivation.py"
spec = importlib.util.spec_from_file_location("production_p4", SCRIPT)
assert spec and spec.loader
p4 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p4)


class PostrestoreReadinessTests(unittest.TestCase):
    def test_unit_inactivity_checks_fail_closed_on_dropins_and_partial_inventory(self):
        states = {
            name: {"LoadState": "loaded", "ActiveState": "inactive",
                   "UnitFileState": "static" if name.endswith("-dns.service") else "disabled"}
            for name in p4.CRITICAL_UNITS
        }
        drops = {name: "" for name in p4.CRITICAL_UNITS}
        self.assertTrue(p4.effective_unstarted(states, dropins=drops))
        drops["vaultwarden-oci-backup.timer"] = "/etc/systemd/system/malicious.conf"
        self.assertFalse(p4.effective_unstarted(states, dropins=drops))
        drops["vaultwarden-oci-backup.timer"] = ""
        states["vaultwarden-oci-backup.timer"]["ActiveState"] = "active"
        self.assertFalse(p4.effective_unstarted(states, dropins=drops))
        states["vaultwarden-oci-backup.timer"]["ActiveState"] = "inactive"
        del drops["vaultwarden-oci-health.timer"]
        self.assertFalse(p4.effective_unstarted(states, dropins=drops))

    def test_doctor_ids_are_strictly_allowlisted_and_exit_codes_consistent(self):
        import json
        ids=("runtime.docker","secrets.decrypt","crowdsec.engine")
        good=json.dumps({"schema_version":1,"overall":"FAIL","checks":[
            {"id":"runtime.docker","status":"PASS","message":"private data"},
            {"id":"secrets.decrypt","status":"PASS","message":"SECRET"},
            {"id":"crowdsec.engine","status":"FAIL","message":"secret"}]})
        self.assertEqual(p4.doctor_statuses(good,1,ids),{
            "runtime.docker":"PASS","secrets.decrypt":"PASS","crowdsec.engine":"FAIL"})
        self.assertIsNone(p4.doctor_statuses(good,0,ids))
        self.assertIsNone(p4.doctor_statuses(good.replace("crowdsec.engine","malicious.check"),1,ids))
        self.assertIsNone(p4.doctor_statuses(good.replace("crowdsec.engine","runtime.docker"),1,ids))
        self.assertIsNone(p4.doctor_statuses(good.replace("crowdsec.engine","unknown\nkey"),1,ids))
        self.assertIsNone(p4.doctor_statuses("not-json",0,ids))

    def test_complete_installed_doctor_storage_registry_and_extra_id_refusal(self):
        from vaultwarden_oci import cli, update_cli
        registry = tuple(cli.DOCTOR_CHECK_IDS)
        self.assertEqual(len(registry), 27)
        self.assertEqual(len(set(registry)), 27)
        self.assertEqual(
            registry[registry.index("runtime.paths") + 1],
            update_cli._STORAGE_DOCTOR_ID,
        )
        doctor = {
            "schema_version": 1, "overall": "FAIL",
            "checks": [
                {"id": name, "status": "FAIL" if name == "crowdsec.engine" else "PASS",
                 "message": "private doctor details are not copied to reports"}
                for name in registry
            ],
        }
        import json
        safe = p4.doctor_statuses(json.dumps(doctor), 1, registry)
        self.assertEqual(len(safe), 27)
        self.assertEqual(safe["storage.dedicated"], "PASS")
        doctor["checks"].append({"id": "unreviewed.extra", "status": "FAIL"})
        self.assertIsNone(p4.doctor_statuses(json.dumps(doctor), 1, registry))

    def test_strict_metadata_does_not_follow_symlinks_or_permit_extra_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            nested=root/"data"
            nested.mkdir(mode=0o700)
            db=nested/"db.sqlite3"
            db.write_bytes(b"SQLite bytes and opaque original vault rows"*8)
            db.chmod(0o600)
            dev=root.stat().st_dev
            user=os.getuid()
            self.assertTrue(p4.private_directory(nested,user,dev))
            self.assertTrue(p4.private_sqlite(db,user,dev))
            db.chmod(0o644)
            self.assertFalse(p4.private_sqlite(db,user,dev))
            db.chmod(0o600)
            link=root/"db-link"
            link.symlink_to(db)
            self.assertFalse(p4.private_sqlite(link,user,dev))
            nested.chmod(0o755)
            self.assertFalse(p4.private_directory(nested,user,dev))

    def test_missing_security_unit_only_affects_its_readiness(self):
        services={"crowdsec.service":{"LoadState":"loaded","ActiveState":"active"},
                  "crowdsec-firewall-bouncer.service":{"LoadState":"not-found","ActiveState":"inactive"}}
        self.assertEqual(p4.missing_required_service_dependencies(services),
                         ("crowdsec-firewall-bouncer.service",))

    def test_gate_cannot_approve_production_start_from_empty_report(self):
        with tempfile.TemporaryDirectory() as folder:
            gate=p4.Gate(Path(folder))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gate.finish(),0)
            text=(Path(folder)/"summary.txt").read_text()
            self.assertIn("HOLD",text)
            self.assertIn("production cutover",text)
            gate2=p4.Gate(Path(folder))
            gate2.record("BLOCKED","Restored state differs")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gate2.finish(),2)
            self.assertIn("BLOCKED", (Path(folder)/"summary.txt").read_text())

    def test_complete_mocked_postrestore_surveys_without_activation(self):
        from vaultwarden_oci import runtime, storage, secrets, cli
        class Config:
            offline_recovery_recipient="age1FIXTURE-not-a-real-key"
            smtp_accept_invalid_certs=False
            smtp_accept_invalid_hostnames=False
            offsite_remote=p4.EXPECTED_REMOTE
            local_retention_days=0
            remote_retention_days=0
            notification_provider="fixture"
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            release=root/"release"
            release.mkdir()
            current=root/"current"
            current.symlink_to(release,target_is_directory=True)
            state=root/"state"
            (state/"data").mkdir(parents=True)
            (state/"data/db.sqlite3").write_bytes(b"mocked test only; no actual vault data")
            evidence=root/"evidence"
            evidence.mkdir()
            disk=root/"disk"
            disk.write_bytes(b"fake-volume")
            byid=root/"byid"
            byid.symlink_to(disk)
            states={
                u:{"LoadState":"loaded","ActiveState":"inactive",
                   "UnitFileState":"static" if u.endswith("-dns.service") else "disabled"}
                for u in p4.CRITICAL_UNITS
            }
            def service(unit):
                if unit in states: return states[unit]
                if unit=="docker.service":
                    return {"LoadState":"loaded","ActiveState":"inactive","UnitFileState":"enabled"}
                return {"LoadState":"not-found","ActiveState":"inactive","UnitFileState":"disabled"}
            def readonly(args,timeout=15):
                if args[:2]==["rclone","listremotes"]:return 0,"bw-backup:\n"
                if args[:2]==["dpkg","--audit"]:return 0,""
                if args[0]=="timedatectl":return 0,"yes\n"
                if args[0]=="systemctl":return 0,""
                raise AssertionError("unexpected external command "+repr(args))
            p1=SimpleNamespace(
                EXPECTED_BYID=byid,
                release_integrity=lambda *a:(True,52),
                systemd_unit_integrity=lambda *a:(True,12),
                matches_offline_recipient=lambda *a:True,
                service_properties=service,
                listening_ports=lambda:set(),
                daemon_running=lambda *a:False,
                run_readonly=readonly,
                remote_available=lambda *a:True,
                local_recovery_inventory=lambda *a:("NOT RUN","none"),
            )
            p2=SimpleNamespace(sqlite_snapshot_integrity=lambda *a:True)
            values={"cloudflare_api_token":"TEST", "smtp_username":"USER",
                    "smtp_password":"SECRET", "cloudflare_remediation_token":"TEST"}
            output=io.StringIO()
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(p4.os,"geteuid",return_value=0))
                stack.enter_context(mock.patch.object(p4.sys,"argv",["p4.py"]))
                stack.enter_context(mock.patch.object(p4.sys,"path",list(sys.path)))
                stack.enter_context(mock.patch.object(p4.sys,"version_info",(3,14,0)))
                stack.enter_context(mock.patch.object(p4.platform,"node",return_value=p4.HOST))
                stack.enter_context(mock.patch.object(p4.platform,"machine",return_value="aarch64"))
                stack.enter_context(mock.patch.object(p4,"CURRENT",current))
                stack.enter_context(mock.patch.object(p4,"INSTALLED",release))
                stack.enter_context(mock.patch.object(p4,"STATE",state))
                stack.enter_context(mock.patch.object(p4,"EXPECTED_UUID","fixture-uuid"))
                stack.enter_context(mock.patch.object(p4,"private_evidence",return_value=evidence))
                stack.enter_context(mock.patch.object(p4,"private_directory",return_value=True))
                stack.enter_context(mock.patch.object(p4,"private_sqlite",return_value=True))
                stack.enter_context(mock.patch.object(p4,"source_module",side_effect=[p1,p2]))
                stack.enter_context(mock.patch.object(runtime,"load_config",return_value=Config()))
                stack.enter_context(mock.patch.object(secrets,"validate_encrypted",return_value=values))
                stack.enter_context(mock.patch.object(secrets,"admin_enabled",return_value=False))
                stack.enter_context(mock.patch.object(storage,"verify",return_value=SimpleNamespace(
                    uuid="fixture-uuid", fs_type="ext4",source=str(disk))))
                stack.enter_context(mock.patch.object(storage,"reject_boot_related",return_value=None))
                stack.enter_context(contextlib.redirect_stdout(output))
                result=p4.main()
            self.assertEqual(result,0)
            report=(evidence/"summary.txt").read_text()
            self.assertIn("HOLD",report)
            self.assertIn("Restored Vaultwarden SQLite full integrity verified",report)
            self.assertIn("No TCP/80 or TCP/443 listeners",report)
            self.assertNotIn("SECRET",report)
            self.assertNotIn("age1FIXTURE",report)
            self.assertNotIn("mocked test only",report)
            self.assertIn("no live startup",report.lower())


if __name__=="__main__":
    unittest.main()
