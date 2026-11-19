"""Cloudflare Free Worker Route Fail Open reconciliation: no live provider calls."""
from __future__ import annotations

import io
import json
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from vaultwarden_oci import cli, cloudflare_route_mode as routes, crowdsec_worker_policy, edge, runtime, secrets

ZONE = "a" * 32
ROUTE = "b" * 32
INVOCATION = "c" * 32
TOKEN = "top-secret-remediation-token"
PATTERN = "vault.example.net/*"
SCRIPT = routes.BOUNCER_SCRIPT


class RouteAPI:
    def __init__(self, fail_open=False, script=SCRIPT, pattern=PATTERN):
        self.open = fail_open
        self.script = script
        self.pattern = pattern
        self.calls = []
        self.update_sticks = True
        self.with_field = True
        self.duplicates = False
        self.info_pages = 1

    def object(self):
        row = {"id": ROUTE, "pattern": self.pattern, "script": self.script}
        if self.with_field:
            row["request_limit_fail_open"] = self.open
        return row

    def __call__(self, url, token, *, method="GET", body=None):
        self.calls.append((method, url, body, token))
        if not url.startswith(routes.CLOUDFLARE_API + "/zones/" + ZONE + "/workers/routes"):
            raise AssertionError("unapproved endpoint")
        assert token == TOKEN
        if url.endswith("?per_page=100"):
            rows = [self.object()]
            if self.duplicates:
                rows.append(self.object())
            return {"success": True, "result": rows, "result_info": {"total_pages": self.info_pages}}
        if not url.endswith("/" + ROUTE):
            raise AssertionError("unexpected route id")
        if method == "PUT":
            assert body == {"pattern": PATTERN, "script": SCRIPT, "request_limit_fail_open": True}
            if self.update_sticks:
                self.open = True
            return {"success": True, "result": self.object()}
        assert method == "GET"
        return {"success": True, "result": self.object()}


class AutoFailOpenTests(unittest.TestCase):
    def setUp(self):
        self.api = RouteAPI()
        self.confirm = mock.patch.object(edge, "confirm_fail_open").start()
        self.addCleanup(mock.patch.stopall)
        self.patches = [
            mock.patch.object(routes, "_api_json", side_effect=self.api),
            mock.patch.object(routes.os, "geteuid", return_value=0),
            mock.patch.object(edge, "_active", return_value=True),
            mock.patch.object(edge, "_disabled", return_value=True),
            mock.patch.object(edge, "_service_invocation_id", return_value=INVOCATION),
            mock.patch.object(crowdsec_worker_policy, "runtime_policy_healthy", return_value=True),
            mock.patch.object(runtime, "load_config", return_value=SimpleNamespace(
                domain="vault.example.net", offline_recovery_recipient="age1test"
            )),
            mock.patch.object(secrets, "load", return_value={"cloudflare_remediation_token": TOKEN}),
            mock.patch.object(edge, "resolve_cloudflare_zone", return_value=("d" * 32, ZONE)),
        ]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)

    def call(self):
        with tempfile.TemporaryDirectory() as folder:
            p = edge.EdgePaths(
                remediation_config=Path(folder) / "worker.yaml",
                fail_open_confirmation=Path(folder) / "fail-open.json",
            )
            return routes.ensure_fail_open(paths=p)

    def test_existing_true_is_verified_without_mutation(self):
        self.api.open = True
        proof = self.call()
        self.assertFalse(proof.changed)
        self.assertEqual(proof.invocation_id, INVOCATION)
        self.assertEqual([x[0] for x in self.api.calls], ["GET", "GET", "GET"])
        self.confirm.assert_called_once()
        self.assertEqual(self.confirm.call_args.kwargs["verified_route"]["id"], ROUTE)
        self.assertNotIn(TOKEN, str(proof))

    def test_false_is_set_then_independently_read_back(self):
        proof = self.call()
        self.assertTrue(proof.changed)
        self.assertTrue(self.api.open)
        self.assertEqual([x[0] for x in self.api.calls], ["GET", "GET", "PUT", "GET"])
        self.confirm.assert_called_once()

    def test_undocumented_field_not_echoed_is_hold_not_pass(self):
        self.api.with_field = False
        with self.assertRaisesRegex(edge.EdgeError, "independently report"):
            self.call()
        self.confirm.assert_not_called()

    def test_put_ignored_is_hold_without_confirmation(self):
        self.api.update_sticks = False
        with self.assertRaisesRegex(edge.EdgeError, "independently report"):
            self.call()
        self.confirm.assert_not_called()

    def test_other_worker_script_is_never_modified(self):
        self.api.script = "not-the-crowdsec-worker"
        with self.assertRaisesRegex(edge.EdgeError, "pattern/script"):
            self.call()
        self.assertFalse(any(x[0] == "PUT" for x in self.api.calls))
        self.confirm.assert_not_called()

    def test_wrong_route_pattern_is_not_picked(self):
        self.api.pattern = "other.example.net/*"
        with self.assertRaisesRegex(edge.EdgeError, "exactly one"):
            self.call()
        self.assertFalse(any(x[0] == "PUT" for x in self.api.calls))
        self.confirm.assert_not_called()

    def test_multiple_routes_is_hold(self):
        self.api.duplicates = True
        with self.assertRaisesRegex(edge.EdgeError, "exactly one"):
            self.call()
        self.confirm.assert_not_called()

    def test_paginated_inventory_refused(self):
        self.api.info_pages = 2
        with self.assertRaisesRegex(edge.EdgeError, "pagination"):
            self.call()
        self.confirm.assert_not_called()

    def test_invocation_race_prevents_confirmation(self):
        with mock.patch.object(edge, "_service_invocation_id", side_effect=[INVOCATION, "e" * 32]):
            with self.assertRaisesRegex(edge.EdgeError, "changed during"):
                self.call()
        self.confirm.assert_not_called()

    def test_failed_local_source_policy_prevents_any_api_access(self):
        with mock.patch.object(crowdsec_worker_policy, "runtime_policy_healthy", return_value=False):
            with self.assertRaisesRegex(edge.EdgeError, "local-only"):
                self.call()
        self.assertEqual(self.api.calls, [])
        self.confirm.assert_not_called()

    def test_no_admin_rights_prevents_default_path(self):
        with mock.patch.object(routes.os, "geteuid", return_value=1000):
            with self.assertRaisesRegex(edge.EdgeError, "root"):
                routes.ensure_fail_open()
        self.assertEqual(self.api.calls, [])

    def test_api_failure_never_records_confirmed(self):
        with mock.patch.object(routes, "_api_json", side_effect=edge.EdgeError("Cloudflare outage")):
            with self.assertRaises(edge.EdgeError):
                self.call()
        self.confirm.assert_not_called()

    def test_root_confirmation_records_provenance_without_secret(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fail-open.json"
            p = edge.EdgePaths(fail_open_confirmation=path)
            with mock.patch.object(edge, "_service_invocation_id", return_value=INVOCATION):
                edge.confirm_fail_open(
                    paths=p,
                    verified_route={"id": ROUTE, "pattern": PATTERN, "script": SCRIPT},
                    now=20,
                )
            data = json.loads(path.read_text())
            self.assertEqual(data["verification"], "cloudflare-api-readback")
            self.assertEqual(data["route"]["id"], ROUTE)
            self.assertEqual(data["invocation_id"], INVOCATION)
            self.assertNotIn(TOKEN, path.read_text())
            self.assertTrue(edge._fail_open_confirmed(path, INVOCATION))
            self.assertFalse(edge._fail_open_confirmed(path, "e" * 32))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_original_operator_confirmation_remains_compatible(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fail-open.json"
            p = edge.EdgePaths(fail_open_confirmation=path)
            with mock.patch.object(edge, "_service_invocation_id", return_value=INVOCATION):
                edge.confirm_fail_open(paths=p, now=20)
            data = json.loads(path.read_text())
            self.assertNotIn("route", data)
            self.assertTrue(edge._fail_open_confirmed(path, INVOCATION))

    def test_cli_has_explicit_opt_in_and_existing_worker_command(self):
        parser = cli._parser()
        a = parser.parse_args(["crowdsec", "remediation-start"])
        self.assertFalse(a.auto_fail_open)
        b = parser.parse_args(["crowdsec", "remediation-start", "--auto-fail-open"])
        self.assertTrue(b.auto_fail_open)
        c = parser.parse_args(["crowdsec", "ensure-fail-open"])
        self.assertEqual(c.crowdsec_command, "ensure-fail-open")


class TestBoundedHttp(unittest.TestCase):
    def test_raw_transport_redacts_token_and_verifies_body(self):
        class Response:
            status = 200

            def __init__(self, response):
                self.payload = json.dumps(response).encode()

            def __enter__(self): return self
            def __exit__(self, exc_type, exc, tb): return False
            def read(self, size): return self.payload[:size]

        requests = []

        def fake(request, timeout=10):
            requests.append(request)
            self.assertEqual(timeout, 10)
            self.assertEqual(request.get_method(), "PUT")
            return Response({"success": True, "result": {"ok": 1}})

        url = routes.CLOUDFLARE_API + "/zones/" + ZONE + "/workers/routes/" + ROUTE
        with mock.patch.object(routes.urllib.request, "urlopen", side_effect=fake):
            doc = routes._api_json(
                url, TOKEN, method="PUT",
                body={"pattern": PATTERN, "script": SCRIPT, "request_limit_fail_open": True},
            )
        self.assertTrue(doc["success"])
        self.assertEqual(len(requests), 1)
        self.assertEqual(json.loads(requests[0].data)["request_limit_fail_open"], True)

    def test_http_error_hides_sensitive_exception_body(self):
        url = routes.CLOUDFLARE_API + "/zones/" + ZONE + "/workers/routes"
        error = urllib.error.URLError("sensitive:" + TOKEN)
        with mock.patch.object(routes.urllib.request, "urlopen", side_effect=error):
            with self.assertRaises(edge.EdgeError) as out:
                routes._api_json(url, TOKEN)
        self.assertNotIn(TOKEN, str(out.exception))


if __name__ == "__main__":
    unittest.main()
