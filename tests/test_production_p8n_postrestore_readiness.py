"""P8N postrestore read-only safety contract."""
import importlib.util
import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).parent / "host-acceptance/production-p8n-postrestore-readiness.py"
SPEC = importlib.util.spec_from_file_location("production_p8n", SCRIPT)
p8n = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p8n)


def good_doc(statuses=None):
    statuses = statuses or {}
    names = tuple(sorted(p8n.REQUIRED | p8n.SECURITY | {"runtime.paths"}))
    checks = [{"id": name, "status": statuses.get(name, "PASS")} for name in names]
    overall = "FAIL" if any(x["status"] == "FAIL" for x in checks) else "PASS"
    return json.dumps({"schema_version": 1, "checks": checks, "overall": overall}), names


class P8NTests(unittest.TestCase):
    def test_historical_pins_are_fixed(self):
        self.assertEqual(len(p8n.EXPECTED_DB), 64)
        self.assertEqual(len(p8n.EXPECTED_CIPHER), 64)
        self.assertEqual(len(p8n.EXPECTED_P8M_COMMIT), 40)
        self.assertEqual(p8n.HOST, "vaultwarden-oci-7-vnic")

    def test_doctor_normal(self):
        data, names = good_doc()
        self.assertTrue(all(v == "PASS" for v in p8n.classify_doctor(data, 0, names).values()))

    def test_doctor_fail_status_is_not_silent(self):
        data, names = good_doc({"runtime.paths": "FAIL"})
        self.assertEqual(p8n.classify_doctor(data, 1, names)["runtime.paths"], "FAIL")

    def test_doctor_rejects_inconsistent_exit(self):
        data, names = good_doc({"runtime.paths": "FAIL"})
        with self.assertRaises(p8n.Blocked):
            p8n.classify_doctor(data, 0, names)

    def test_doctor_rejects_missing_check(self):
        data, names = good_doc()
        with self.assertRaises(p8n.Blocked):
            p8n.classify_doctor(data, 0, names + ("missing",))

    def test_doctor_rejects_duplicates(self):
        data, names = good_doc()
        doc = json.loads(data)
        doc["checks"].append(doc["checks"][0])
        with self.assertRaises(p8n.Blocked):
            p8n.classify_doctor(json.dumps(doc), 0, names)

    def test_doctor_rejects_unknown_check(self):
        data, names = good_doc()
        doc = json.loads(data)
        doc["checks"][0]["id"] = "secret-do-not-echo"
        with self.assertRaises(p8n.Blocked):
            p8n.classify_doctor(json.dumps(doc), 0, names)

    def test_doctor_rejects_invalid_status(self):
        data, names = good_doc()
        doc = json.loads(data)
        doc["checks"][0]["status"] = "BROKEN"
        with self.assertRaises(p8n.Blocked):
            p8n.classify_doctor(json.dumps(doc), 0, names)

    def test_doctor_rejects_json_error(self):
        with self.assertRaises(p8n.Blocked):
            p8n.classify_doctor("{", 1, ("x",))

    def test_doctor_rejects_oversized_output(self):
        with self.assertRaises(p8n.Blocked):
            p8n.classify_doctor("x" * 262145, 0, ("x",))

    def test_sha(self):
        self.assertEqual(p8n.sha(b"abc"),
                         "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

    def test_wrong_invocation_fail_closed_no_host_changes(self):
        with mock.patch.object(sys, "argv", [str(SCRIPT)]):
            with mock.patch.object(p8n, "host_ok", return_value=False):
                output = io.StringIO()
                with redirect_stdout(output):
                    rc = p8n.main()
                self.assertEqual(rc, 2)
                self.assertIn("BLOCKED", output.getvalue())

    def test_source_requires_full_sha(self):
        self.assertFalse(p8n.clean_source("not-a-sha"))
        self.assertFalse(p8n.clean_source("a" * 39))

    def test_no_mutation_primitives_in_gate(self):
        src = SCRIPT.read_text()
        for forbidden in ("systemctl start", "systemctl enable", "systemctl reboot",
                          "rclone copy", "rclone sync", "rclone delete",
                          "restore_recovery(", "ensure_paths(", "subprocess.Popen("):
            self.assertNotIn(forbidden, src)

    def test_critical_ports(self):
        self.assertTrue({80, 443, 2375, 2376} <= p8n.CRITICAL_PORTS)


if __name__ == "__main__":
    unittest.main()
