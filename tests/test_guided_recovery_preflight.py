"""Safety of the read-only recovery baseline; no live-host claim."""
from __future__ import annotations

import copy
import importlib.util
import io
import json
import tempfile
import types
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("recovery_preflight", ROOT / "tests/host-acceptance/guided-recovery-preflight.py")
assert spec and spec.loader
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


def status():
    return {
        "schema_version": 1,
        "doctor": {"schema_version": 1, "overall": "WARN", "checks": [
            {"id": "storage.dedicated", "status": "PASS", "message": "withheld"},
            {"id": "recovery.offsite", "status": "WARN", "message": "private destination withheld"},
        ]},
        "runtime": {"overall": "running", "services": [
            {"service": name, "state": "running", "health": "healthy"}
            for name in ("vaultwarden", "caddy")
        ]},
        "automation": {"overall": "PASS", "healthy": 4, "expected": 4,
                       "target": {"enabled": "enabled", "active_state": "active", "health": "PASS"}},
        "timers": [{"unit": name, "active_state": "active", "health": "PASS"}
                   for name in sorted(preflight.TIMERS)],
    }


class RecoveryPreflightTests(unittest.TestCase):
    def test_moving_source_ref_refused_before_host_access(self):
        output = io.StringIO()
        with mock.patch.object(preflight, "console_helper") as helper, redirect_stdout(output):
            code = preflight.main([
                "--expected-host", "disposable", "--expected-sha", "moving-branch",
                "--source", "/tmp/source", "--expected-version", "0.1.0-rc.19",
                "--expected-os", "26.04", "--expected-files", "57", "--expected-units", "13",
                "--storage-uuid", "aaaa-bbbb", "--domain", "example.invalid",
            ])
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(output.getvalue())["verdict"], "HOLD")
        helper.assert_not_called()

    def test_changed_companion_is_not_executed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "companion.py"
            path.write_text("raise AssertionError('unreviewed code executed')\n", encoding="utf-8")
            with self.assertRaisesRegex(preflight.Hold, "checksum"):
                preflight.console_helper(path)
        self.assertTrue(callable(preflight.console_helper().verify_installation))

    def test_valid_status_preserves_warnings_without_disclosing_messages(self):
        result = preflight.summarize_status(status(), 0, ("storage.dedicated",))
        self.assertEqual(result["doctor_overall"], "WARN")
        self.assertEqual(result["doctor_warn_ids"], ["recovery.offsite"])
        self.assertEqual(result["required_checks_missing"], [])
        self.assertNotIn("withheld", json.dumps(result))
        self.assertEqual(result["automation_enabled"], "enabled")

    def test_missing_mandatory_foundation_is_reported(self):
        result = preflight.summarize_status(status(), 0, ("secrets.custody",))
        self.assertEqual(result["required_checks_missing"], ["secrets.custody"])

    def test_real_failure_and_disabled_automation_remain_visible(self):
        payload = status()
        payload["doctor"]["checks"][0]["status"] = "FAIL"
        payload["doctor"]["overall"] = "FAIL"
        payload["automation"]["overall"] = "FAIL"
        payload["automation"]["target"].update(enabled="disabled", active_state="inactive", health="FAIL")
        result = preflight.summarize_status(payload, 1, ("storage.dedicated",))
        self.assertEqual(result["doctor_fail_ids"], ["storage.dedicated"])
        self.assertEqual(result["automation_overall"], "FAIL")
        self.assertEqual(result["automation_enabled"], "disabled")

    def test_malformed_or_inconsistent_status_cannot_pass(self):
        modifications = [
            lambda p: p.update(schema_version=999),
            lambda p: p["doctor"].update(overall="PASS"),
            lambda p: p["doctor"]["checks"].append(copy.deepcopy(p["doctor"]["checks"][0])),
            lambda p: p["doctor"]["checks"][0].update(id="private\ntext"),
            lambda p: p["runtime"]["services"][0].update(health="unhealthy"),
            lambda p: p["timers"].pop(),
            lambda p: p["timers"][0].update(active_state="inactive"),
            lambda p: p["automation"]["target"].update(enabled="disabled"),
            lambda p: p["automation"].update(healthy=3),
        ]
        for change in modifications:
            payload = status()
            change(payload)
            with self.subTest(change=change), self.assertRaises(preflight.Hold):
                preflight.summarize_status(payload, 0, ("storage.dedicated",))
        with self.assertRaisesRegex(preflight.Hold, "exit code"):
            preflight.summarize_status(status(), 1, ("storage.dedicated",))

    def test_missing_or_wrong_object_shapes_are_holds_without_tracebacks(self):
        for key in ("schema_version", "doctor", "runtime", "automation", "timers"):
            payload = status()
            del payload[key]
            with self.subTest(missing=key), self.assertRaises(preflight.Hold):
                preflight.summarize_status(payload, 0, ("storage.dedicated",))
        for key in ("doctor", "runtime", "automation"):
            for malformed in (None, "untrusted", [], 1):
                payload = status()
                payload[key] = malformed
                with self.subTest(key=key, value=malformed), self.assertRaises(preflight.Hold):
                    preflight.summarize_status(payload, 0, ("storage.dedicated",))
        for key in ("unit", "health", "active_state"):
            payload = status()
            payload["timers"][0][key] = {"unexpected": "private"}
            with self.subTest(timer=key), self.assertRaises(preflight.Hold):
                preflight.summarize_status(payload, 0, ("storage.dedicated",))

    def test_artifact_inventory_never_opens_private_contents_and_refuses_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            artifact = root / "recovery.vwrec"
            artifact.write_bytes(b"private contents must not be opened")
            artifact.chmod(0o600)
            original = Path.lstat
            def root_owned(path):
                info = original(path)
                return types.SimpleNamespace(st_mode=info.st_mode, st_uid=0, st_gid=0, st_size=info.st_size)
            # Keep the real file types/modes and mock only UID/GID, so the
            # same filesystem fixture runs in ordinary unprivileged CI.
            with mock.patch.object(Path, "lstat", root_owned), mock.patch.object(Path, "read_bytes", side_effect=AssertionError("private bytes were read")):
                result = preflight.metadata_inventory(root, "*.vwrec")
            self.assertEqual(result, {"count": 1, "bytes": artifact.stat().st_size})
            (root / "linked.vwrec").symlink_to(artifact)
            with mock.patch.object(Path, "lstat", root_owned), self.assertRaises(preflight.Hold):
                preflight.metadata_inventory(root, "*.vwrec")

    def test_unprotected_artifact_is_refused(self):
        path = mock.Mock()
        path.lstat.return_value = types.SimpleNamespace(st_mode=0o100600, st_uid=1000, st_gid=0, st_size=3)
        with self.assertRaisesRegex(preflight.Hold, "private root-owned"):
            preflight.protected_files([path])
        path.lstat.return_value = types.SimpleNamespace(st_mode=0o100644, st_uid=0, st_gid=0, st_size=3)
        with self.assertRaisesRegex(preflight.Hold, "private root-owned"):
            preflight.protected_files([path])

    def test_all_custody_workspace_types_block_without_opening_or_removing_them(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            original = Path.lstat
            def root_owned(path):
                info = original(path)
                return types.SimpleNamespace(st_mode=info.st_mode, st_uid=0, st_gid=0, st_size=info.st_size)
            with mock.patch.object(Path, "lstat", root_owned):
                preflight.require_no_plaintext_workspaces(root)
                for prefix in ("offline-identity-", "setup-offline-recovery-", "recovery-kit-"):
                    workspace = root / (prefix + "fixture")
                    workspace.mkdir(mode=0o700)
                    material = workspace / "private.txt"
                    material.write_text("fixture remains untouched", encoding="utf-8")
                    before = material.stat()
                    with mock.patch.object(Path, "read_bytes", side_effect=AssertionError("custody read")), self.assertRaisesRegex(preflight.Hold, "not read or removed"):
                        preflight.require_no_plaintext_workspaces(root)
                    self.assertEqual(material.stat(), before)
                    material.unlink()
                    workspace.rmdir()


if __name__ == "__main__":
    unittest.main()
