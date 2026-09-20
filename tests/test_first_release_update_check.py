from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from vaultwarden_oci import dashboard, update_appliance, update_cli, update_status
from vaultwarden_oci.update_versions import UpdateError


class ReleaseCatalogClassificationTests(unittest.TestCase):
    def test_empty_catalog_is_distinct_from_lookup_failure(self) -> None:
        with self.assertRaises(update_appliance.NoStableProjectRelease):
            update_appliance.latest_project_release(getter=lambda _url: [])

    def test_draft_and_prerelease_only_catalog_is_no_stable_release(self) -> None:
        payload = [
            {"tag_name": "v1.0.0", "draft": True, "prerelease": False},
            {"tag_name": "v1.0.0-rc1", "draft": False, "prerelease": True},
        ]
        with self.assertRaises(update_appliance.NoStableProjectRelease):
            update_appliance.latest_project_release(getter=lambda _url: payload)

    def test_malformed_stable_release_metadata_remains_failure(self) -> None:
        payload = [
            {
                "tag_name": "v1.0.0",
                "draft": False,
                "prerelease": False,
                "published_at": "2026-09-05T00:00:00Z",
                "tarball_url": "https://example.invalid/not-a-github-release",
            }
        ]
        with self.assertRaisesRegex(UpdateError, "invalid stable release metadata"):
            update_appliance.latest_project_release(getter=lambda _url: payload)

    def test_network_failure_remains_failure(self) -> None:
        def failed(_url: str):
            raise UpdateError("network unavailable")

        with self.assertRaisesRegex(UpdateError, "network unavailable") as raised:
            update_appliance.latest_project_release(getter=failed)
        self.assertNotIsInstance(raised.exception, update_appliance.NoStableProjectRelease)


class FirstReleaseCliTests(unittest.TestCase):
    def run_update(self, argv: list[str], *, current: str = "0.1.0-dev.23") -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch("vaultwarden_oci.update_cli._require_storage", return_value=True),
            mock.patch("vaultwarden_oci.update_cli.update._current", return_value=(Path("releases/current"), current, Path("/opt/current"))),
            mock.patch(
                "vaultwarden_oci.update_cli.update_appliance.candidate_source",
                side_effect=update_appliance.NoStableProjectRelease(
                    update_appliance.NO_STABLE_PROJECT_RELEASE_REASON
                ),
            ),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            code = update_cli._update_command(argv)
        return code, stdout.getvalue(), stderr.getvalue()

    def test_timer_check_is_healthy_and_records_no_candidate(self) -> None:
        with mock.patch("vaultwarden_oci.update_cli.update_appliance.record_check") as record:
            code, stdout, stderr = self.run_update(["check", "--timer", "--json"])
        self.assertEqual(code, 0)
        self.assertEqual(stderr, "")
        payload = json.loads(stdout)
        self.assertFalse(payload["available"])
        self.assertIsNone(payload["candidate"])
        self.assertEqual(payload["availability_reason"], update_appliance.NO_STABLE_PROJECT_RELEASE_REASON)
        record.assert_called_once_with(
            current="0.1.0-dev.23",
            candidate=None,
            available=False,
            availability_reason=update_appliance.NO_STABLE_PROJECT_RELEASE_REASON,
            error=None,
        )

    def test_manual_check_is_truthful_success(self) -> None:
        code, stdout, stderr = self.run_update(["check"])
        self.assertEqual(code, 0)
        self.assertEqual(stderr, "")
        self.assertIn("PASS", stdout)
        self.assertIn("no stable VaultWarden-OCI project release", stdout)

    def test_use_latest_still_fails_without_published_stable_release(self) -> None:
        code, stdout, stderr = self.run_update(["check", "--use-latest", "--json"])
        self.assertEqual(code, 1)
        self.assertEqual(stdout, "")
        payload = json.loads(stderr)
        self.assertIn("requires a published stable", payload["error"])

    def test_generic_lookup_failure_still_fails_timer(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch("vaultwarden_oci.update_cli._require_storage", return_value=True),
            mock.patch("vaultwarden_oci.update_cli.update._current", return_value=(Path("releases/current"), "0.1.0-dev.23", Path("/opt/current"))),
            mock.patch(
                "vaultwarden_oci.update_cli.update_appliance.candidate_source",
                side_effect=UpdateError("network unavailable"),
            ),
            mock.patch("vaultwarden_oci.update_cli.update_appliance.record_check") as record,
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            code = update_cli._update_command(["check", "--timer", "--json"])
        self.assertEqual(code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(json.loads(stderr.getvalue())["error"], "network unavailable")
        record.assert_called_once_with(
            current="0.1.0-dev.23",
            candidate=None,
            available=False,
            error="network unavailable",
        )


class UpdateReadModelTests(unittest.TestCase):
    def test_availability_reason_survives_persisted_status(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "update-check.json"
            path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "checked_at": 100,
                        "current": "0.1.0-dev.23",
                        "candidate": None,
                        "available": False,
                        "availability_reason": update_appliance.NO_STABLE_PROJECT_RELEASE_REASON,
                        "error": None,
                    }
                ),
                encoding="utf-8",
            )
            with mock.patch("vaultwarden_oci.update_status.cli.load_versions", return_value=mock.Mock(version="0.1.0-dev.23")):
                snapshot = update_status.snapshot(path=path, now=101)
        self.assertEqual(snapshot["availability_reason"], update_appliance.NO_STABLE_PROJECT_RELEASE_REASON)
        self.assertFalse(snapshot["available"])
        self.assertIsNone(snapshot["error"])

    def test_dashboard_displays_healthy_no_release_reason(self) -> None:
        payload = {
            "doctor": {"overall": "PASS", "checks": []},
            "storage": {"state": "ok", "mount": "/var/lib/vaultwarden-oci", "used_percent": 1, "warning": False},
            "recovery": [],
            "edge": {"overall": "PASS"},
            "admin": {"status": "PASS", "message": "disabled"},
            "automation": {"overall": "PASS", "healthy": 4, "expected": 4},
            "notification": {"state": "not configured"},
            "update": {
                "installed": "0.1.0-dev.23",
                "available": False,
                "availability_reason": update_appliance.NO_STABLE_PROJECT_RELEASE_REASON,
                "check_stale": False,
                "check_age_seconds": 1,
                "error": None,
            },
            "runtime": {"services": []},
            "reboot_required": False,
        }
        output = io.StringIO()
        with redirect_stdout(output):
            dashboard.draw_status(payload)
        text = output.getvalue()
        self.assertIn(update_appliance.NO_STABLE_PROJECT_RELEASE_REASON, text)
        self.assertNotIn("check error", text)


if __name__ == "__main__":
    unittest.main()
