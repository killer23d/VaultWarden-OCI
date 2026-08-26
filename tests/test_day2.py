from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from vaultwarden_oci import cli, dashboard, day2, edge, runtime, secrets, update_status


def valid_config(domain: str = "vault.invalid") -> str:
    recipient = "age1" + "a" * 58
    return f'''schema_version = 1
[site]
domain = "{domain}"
acme_email = "admin@invalid.test"
[secrets]
offline_recovery_recipient = "{recipient}"
[vaultwarden]
signups_allowed = false
[smtp]
host = "smtp.invalid.test"
port = 587
security = "starttls"
from_email = "vault@invalid.test"
from_name = "Vaultwarden"
timeout_seconds = 15
'''


class Day2TimerTests(unittest.TestCase):
    def timer_properties(self, unit: str, *, service_result: str = "success", timer_enabled: str = "enabled") -> dict[str, object]:
        if unit.endswith(".timer"):
            return {
                "unit": unit,
                "load_state": "loaded",
                "active_state": "active",
                "sub_state": "waiting",
                "result": "success",
                "enabled": timer_enabled,
                "next": "tomorrow",
                "last_trigger": "today",
            }
        return {
            "unit": unit,
            "load_state": "loaded",
            "active_state": "inactive" if service_result == "success" else "failed",
            "sub_state": "dead" if service_result == "success" else "failed",
            "result": service_result,
            "enabled": "static",
            "next": None,
            "last_trigger": None,
        }

    def test_real_systemd_failure_results_are_failures(self) -> None:
        for result in ("exit-code", "signal", "timeout"):
            with self.subTest(result=result), mock.patch(
                "vaultwarden_oci.day2._systemd_properties",
                side_effect=lambda unit, result=result: self.timer_properties(unit, service_result=result),
            ):
                rows = day2.timer_rows()
            self.assertTrue(all(row["health"] == "FAIL" for row in rows))
            self.assertTrue(all(row["failed"] for row in rows))
            self.assertTrue(all(f"trigger result={result}" in row["problems"] for row in rows))

    def test_missing_or_disabled_timer_can_never_be_green(self) -> None:
        def properties(unit: str) -> dict[str, object]:
            if unit.endswith(".timer"):
                return {
                    "unit": unit,
                    "load_state": "not-found",
                    "active_state": "inactive",
                    "sub_state": "dead",
                    "result": "unknown",
                    "enabled": "disabled",
                    "next": None,
                    "last_trigger": None,
                }
            return {
                "unit": unit,
                "load_state": "unknown",
                "active_state": "unknown",
                "sub_state": "unknown",
                "result": "unknown",
                "enabled": "unknown",
                "next": None,
                "last_trigger": None,
            }

        with mock.patch("vaultwarden_oci.day2._systemd_properties", side_effect=properties):
            rows = day2.timer_rows()
        self.assertEqual(len(rows), len(day2.TIMER_UNITS))
        self.assertTrue(all(row["health"] == "FAIL" for row in rows))

    def test_healthy_waiting_timer_accepts_successful_inactive_trigger(self) -> None:
        with mock.patch(
            "vaultwarden_oci.day2._systemd_properties",
            side_effect=lambda unit: self.timer_properties(unit),
        ):
            rows = day2.timer_rows()
        self.assertTrue(all(row["health"] == "PASS" for row in rows))


class Day2StatusTests(unittest.TestCase):
    def base_checks(self, admin_status: str, admin_message: str) -> list[cli.DoctorCheck]:
        return [
            cli.DoctorCheck("recovery.rclone", "PASS", "rclone ready"),
            cli.DoctorCheck("edge.admin.protection", admin_status, admin_message),
            cli.DoctorCheck("edge.cloudflare.cidrs", "PASS", "current"),
            cli.DoctorCheck("crowdsec.engine", "PASS", "active"),
            cli.DoctorCheck("crowdsec.cloudflare", "PASS", "active"),
        ]

    def status_with_admin(self, admin_status: str, admin_message: str) -> dict[str, object]:
        runtime_rows = [
            {"service": "vaultwarden", "state": "running", "health": "healthy"},
            {"service": "caddy", "state": "running", "health": "healthy"},
        ]
        recovery_rows = [
            {"kind": "local", "state": "verified", "verified_at": "2026-08-20T00:00:00Z"},
            {"kind": "offsite", "state": "none", "verified_at": "-"},
        ]
        storage_ok = {"state": "ok", "mount": "/var/lib/vaultwarden-oci", "warning": False, "used_percent": 25}
        timer_rows = [{"unit": unit, "health": "PASS", "active_state": "active"} for unit in day2.TIMER_UNITS]
        with (
            mock.patch("vaultwarden_oci.day2.runtime.status", return_value=("running", runtime_rows)),
            mock.patch("vaultwarden_oci.day2.cli.doctor_checks", return_value=self.base_checks(admin_status, admin_message)),
            mock.patch("vaultwarden_oci.day2._storage_status", return_value=storage_ok),
            mock.patch("vaultwarden_oci.day2.recovery.status_rows", return_value=recovery_rows),
            mock.patch("vaultwarden_oci.day2.notification.status_row", return_value={"state": "success"}),
            mock.patch("vaultwarden_oci.day2.update_status.snapshot", return_value={"installed": "1.0.0", "check_stale": False, "available": False}),
            mock.patch("vaultwarden_oci.day2.timer_rows", return_value=timer_rows),
            mock.patch("vaultwarden_oci.day2._now", return_value=2_000_000_000.0),
            mock.patch("vaultwarden_oci.day2.Path.exists", return_value=False),
        ):
            return day2.status_payload()

    def test_admin_disabled_is_authoritative_pass_not_red_failure(self) -> None:
        payload = self.status_with_admin("PASS", "Vaultwarden admin route is disabled at Caddy")
        self.assertEqual(payload["admin"]["status"], "PASS")
        self.assertIn("disabled", payload["admin"]["message"])

    def test_admin_protected_is_authoritative_pass(self) -> None:
        payload = self.status_with_admin("PASS", "admin token capability, per-client rate limit, and outer Basic Auth gate are active")
        self.assertEqual(payload["admin"]["status"], "PASS")

    def test_broken_caddy_admin_gate_remains_fail_even_if_secrets_exist(self) -> None:
        with mock.patch("vaultwarden_oci.day2.secrets.load") as secret_load:
            payload = self.status_with_admin("FAIL", "admin route is missing rate limit or outer Basic Auth gate")
        self.assertEqual(payload["admin"]["status"], "FAIL")
        secret_load.assert_not_called()

    def test_status_json_is_uncolored_and_automation_failure_affects_exit(self) -> None:
        payload = {
            "schema_version": 1,
            "doctor": {"overall": "PASS"},
            "automation": {"overall": "FAIL"},
        }
        output = io.StringIO()
        with mock.patch("vaultwarden_oci.day2.status_payload", return_value=payload), redirect_stdout(output):
            code = day2.status_command()
        self.assertEqual(code, 1)
        self.assertNotIn("\x1b[", output.getvalue())
        self.assertEqual(json.loads(output.getvalue())["schema_version"], 1)


class OwnerBoundaryTests(unittest.TestCase):
    def test_crowdsec_unban_is_owned_by_edge(self) -> None:
        successful = cli.CommandResult(("cscli",), "success", 0, "", "")
        with (
            mock.patch("vaultwarden_oci.edge.os.geteuid", return_value=0),
            mock.patch("vaultwarden_oci.cli.mutation_lock") as lock,
            mock.patch("vaultwarden_oci.edge._command") as command,
        ):
            address = edge.crowdsec_unban("203.0.113.7", runner=lambda argv: successful)
        self.assertEqual(address, "203.0.113.7")
        lock.assert_called_once_with()
        command.assert_called_once()
        self.assertEqual(command.call_args.args[1], ["cscli", "decisions", "delete", "--ip", "203.0.113.7"])

    def test_invalid_unban_fails_before_root_or_cscli(self) -> None:
        with mock.patch("vaultwarden_oci.edge.os.geteuid") as geteuid:
            with self.assertRaises(edge.EdgeError):
                edge.crowdsec_unban("not-an-ip")
        geteuid.assert_not_called()

    def test_cli_delegates_new_mutations_to_existing_owners(self) -> None:
        config = mock.Mock(offline_recovery_recipient="age1" + "a" * 58)
        with mock.patch("vaultwarden_oci.runtime.edit_config") as edit:
            self.assertEqual(cli.main(["config", "edit"]), 0)
        edit.assert_called_once_with()

        with (
            mock.patch("vaultwarden_oci.runtime.load_config", return_value=config),
            mock.patch("vaultwarden_oci.runtime.Paths.secret_paths", return_value=secrets.SecretPaths()),
            mock.patch("vaultwarden_oci.secrets.edit_encrypted") as secret_edit,
        ):
            self.assertEqual(cli.main(["secrets", "edit"]), 0)
        secret_edit.assert_called_once()

        with mock.patch("vaultwarden_oci.edge.crowdsec_unban", return_value="203.0.113.8") as unban:
            self.assertEqual(cli.main(["crowdsec", "unban", "203.0.113.8"]), 0)
        unban.assert_called_once_with("203.0.113.8")

    def test_day2_module_has_no_mutation_owners(self) -> None:
        for name in ("crowdsec_unban", "crowdsec_decisions", "config_edit", "secrets_edit", "secrets_validate", "notification_test"):
            self.assertFalse(hasattr(day2, name), name)


class ValidatedEditTests(unittest.TestCase):
    def test_config_edit_commits_valid_candidate_and_rejects_invalid_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "config.toml"
            lock = root / "lock"
            original = valid_config("old.invalid.test")
            path.write_text(original, encoding="utf-8")

            def valid_editor(argv, check=False):
                Path(argv[-1]).write_text(valid_config("new.invalid.test"), encoding="utf-8")
                return mock.Mock(returncode=0)

            with mock.patch("vaultwarden_oci.runtime.subprocess.run", side_effect=valid_editor):
                runtime.edit_config(path, editor=("editor",), lock_path=lock)
            self.assertIn('domain = "new.invalid.test"', path.read_text(encoding="utf-8"))

            committed = path.read_text(encoding="utf-8")

            def invalid_editor(argv, check=False):
                Path(argv[-1]).write_text("not valid toml = [", encoding="utf-8")
                return mock.Mock(returncode=0)

            with mock.patch("vaultwarden_oci.runtime.subprocess.run", side_effect=invalid_editor):
                with self.assertRaises(runtime.RuntimeConfigError):
                    runtime.edit_config(path, editor=("editor",), lock_path=lock)
            self.assertEqual(path.read_text(encoding="utf-8"), committed)

    def test_sops_edit_commits_only_after_secrets_owner_validation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            encrypted = root / "secrets.sops.yaml"
            age_key = root / "age-key.txt"
            encrypted.write_text("original-encrypted", encoding="utf-8")
            age_key.write_text("AGE-SECRET-KEY-TEST", encoding="utf-8")
            paths = secrets.SecretPaths(encrypted=encrypted, age_key=age_key, root=root / "run", vaultwarden=root / "run/vw", caddy=root / "run/caddy")

            def editor(argv, check=False, env=None):
                Path(argv[-1]).write_text("candidate-encrypted", encoding="utf-8")
                return mock.Mock(returncode=0)

            with (
                mock.patch("vaultwarden_oci.secrets.subprocess.run", side_effect=editor),
                mock.patch("vaultwarden_oci.secrets.validate_encrypted", return_value={}) as validate,
            ):
                secrets.edit_encrypted("age1" + "a" * 58, paths=paths, editor=("sops",), lock_path=root / "lock")
            self.assertEqual(encrypted.read_text(encoding="utf-8"), "candidate-encrypted")
            validate.assert_called_once()

            encrypted.write_text("stable-encrypted", encoding="utf-8")
            with (
                mock.patch("vaultwarden_oci.secrets.subprocess.run", side_effect=editor),
                mock.patch("vaultwarden_oci.secrets.validate_encrypted", side_effect=secrets.SecretsError("invalid")),
            ):
                with self.assertRaises(secrets.SecretsError):
                    secrets.edit_encrypted("age1" + "a" * 58, paths=paths, editor=("sops",), lock_path=root / "lock2")
            self.assertEqual(encrypted.read_text(encoding="utf-8"), "stable-encrypted")


class SupportBundleTests(unittest.TestCase):
    def command_result(self, argv) -> cli.CommandResult:
        return cli.CommandResult(tuple(argv), "success", 0, "safe output\n", "")

    def base_status(self) -> dict[str, object]:
        return {
            "schema_version": 1,
            "doctor": {"overall": "PASS", "checks": []},
            "timers": [],
        }

    def test_real_archive_redacts_and_excludes_secret_material(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            support_root = root / "support"
            output = root / "bundle.tar.gz"
            secret = "canonical-super-secret"
            with (
                mock.patch("vaultwarden_oci.day2.SUPPORT_ROOT", support_root),
                mock.patch("vaultwarden_oci.day2.os.geteuid", return_value=0),
                mock.patch("vaultwarden_oci.day2._known_secret_values", return_value=([secret], None)),
                mock.patch("vaultwarden_oci.day2.status_payload", return_value=self.base_status()),
                mock.patch("vaultwarden_oci.day2._versions_text", return_value="versions safe\n"),
                mock.patch("vaultwarden_oci.day2._bounded_journal", return_value=f"token={secret}\nAuthorization: Bearer abc.def.ghi\nordinary log\n"),
                mock.patch("vaultwarden_oci.day2.cli.run_command", side_effect=lambda argv: self.command_result(argv)),
                redirect_stdout(io.StringIO()),
            ):
                day2.support_bundle(output)
            with tarfile.open(output, "r:gz") as archive:
                names = set(archive.getnames())
                content = "\n".join(
                    archive.extractfile(name).read().decode("utf-8")
                    for name in names
                    if archive.extractfile(name) is not None
                )
            self.assertEqual(names, {"status.json", "doctor.json", "timers.json", "versions.txt", "systemd-failed.txt", "disk.txt", "journal.txt"})
            self.assertNotIn(secret, content)
            self.assertNotIn("abc.def.ghi", content)
            for forbidden in ("secrets.sops.yaml", "age-key.txt", ".vwrec", "recovery-kit", "AGE-SECRET-KEY-"):
                self.assertNotIn(forbidden, content)

    def test_journal_is_omitted_when_exact_secret_values_cannot_be_loaded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "bundle.tar.gz"
            with (
                mock.patch("vaultwarden_oci.day2.SUPPORT_ROOT", root / "support"),
                mock.patch("vaultwarden_oci.day2.os.geteuid", return_value=0),
                mock.patch("vaultwarden_oci.day2._known_secret_values", return_value=([], "secret load failed")),
                mock.patch("vaultwarden_oci.day2.status_payload", return_value=self.base_status()),
                mock.patch("vaultwarden_oci.day2._versions_text", return_value="versions safe\n"),
                mock.patch("vaultwarden_oci.day2._bounded_journal") as journal,
                mock.patch("vaultwarden_oci.day2.cli.run_command", side_effect=lambda argv: self.command_result(argv)),
                redirect_stdout(io.StringIO()),
            ):
                day2.support_bundle(output)
            journal.assert_not_called()
            with tarfile.open(output, "r:gz") as archive:
                names = set(archive.getnames())
            self.assertIn("journal-omitted.txt", names)
            self.assertNotIn("journal.txt", names)

    def test_custom_output_never_overwrites_existing_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            existing = root / "existing.tar.gz"
            existing.write_text("do-not-touch", encoding="utf-8")
            with (
                mock.patch("vaultwarden_oci.day2.SUPPORT_ROOT", root / "support"),
                mock.patch("vaultwarden_oci.day2.os.geteuid", return_value=0),
            ):
                with self.assertRaises(day2.Day2Error):
                    day2.support_bundle(existing)
            self.assertEqual(existing.read_text(encoding="utf-8"), "do-not-touch")


class DashboardBoundaryTests(unittest.TestCase):
    def minimal_status(self) -> dict[str, object]:
        return {
            "runtime": {"services": []},
            "doctor": {"overall": "PASS", "checks": []},
            "storage": {"state": "failure", "error": "test"},
            "recovery": [],
            "edge": {"overall": "PASS"},
            "admin": {"status": "PASS", "message": "Vaultwarden admin route is disabled at Caddy"},
            "automation": {"overall": "PASS", "healthy": 4, "expected": 4},
            "notification": {"state": "success"},
            "update": {"installed": "test", "available": False, "check_stale": False, "check_age_seconds": 0},
            "reboot_required": False,
        }

    def test_color_only_for_tty_and_no_color_disables_it(self) -> None:
        tty = mock.Mock()
        tty.isatty.return_value = True
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertTrue(dashboard.Style(stream=tty).enabled)
        with mock.patch.dict(os.environ, {"NO_COLOR": "1"}, clear=True):
            self.assertFalse(dashboard.Style(stream=tty).enabled)
        non_tty = mock.Mock()
        non_tty.isatty.return_value = False
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertFalse(dashboard.Style(stream=non_tty).enabled)

    def test_dashboard_mutations_delegate_to_vwctl(self) -> None:
        calls: list[list[str]] = []
        with (
            mock.patch("vaultwarden_oci.dashboard._menu", side_effect=lambda _title, _opts, handler: handler("3")),
            mock.patch("vaultwarden_oci.dashboard._command_screen", side_effect=lambda _label, args: calls.append(list(args))),
        ):
            dashboard.stack_menu()
        self.assertEqual(calls, [["restart"]])

    def test_dashboard_cancel_does_not_invoke_mutation(self) -> None:
        with (
            mock.patch("vaultwarden_oci.dashboard._prompt", return_value=""),
            mock.patch("vaultwarden_oci.dashboard._command_screen") as command,
            mock.patch("vaultwarden_oci.dashboard._menu", side_effect=lambda _title, _opts, handler: handler("2")),
        ):
            dashboard.recovery_menu()
        command.assert_not_called()

    def test_eof_exits_main_instead_of_redrawing_forever(self) -> None:
        with (
            mock.patch("vaultwarden_oci.dashboard._status", return_value=self.minimal_status()) as status,
            mock.patch("builtins.input", side_effect=EOFError),
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(dashboard.main([]), 0)
        status.assert_called_once_with()

    def test_v1_e_shortcut_exits_and_email_uses_n(self) -> None:
        with (
            mock.patch("vaultwarden_oci.dashboard._status", return_value=self.minimal_status()),
            mock.patch("builtins.input", return_value="e"),
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(dashboard.main([]), 0)
        output = io.StringIO()
        with redirect_stdout(output):
            dashboard.draw_main_menu()
        self.assertIn("7/n", output.getvalue())
        self.assertIn("e/q", output.getvalue())

    def test_dashboard_sources_exclude_legacy_backend_orchestration(self) -> None:
        sources = "\n".join(
            (ROOT / path).read_text(encoding="utf-8")
            for path in ("dashboard.sh", "vaultwarden_oci/dashboard.sh", "vaultwarden_oci/dashboard.py")
        ).lower()
        for forbidden in ("make -c", "postfix", "email-queue", "backup tier", "docker prune", "docker compose"):
            self.assertNotIn(forbidden, sources)

    def test_source_and_installed_dashboard_wrappers_parse_and_help(self) -> None:
        for path in (ROOT / "dashboard.sh", ROOT / "vaultwarden_oci/dashboard.sh"):
            parsed = subprocess.run(["bash", "-n", str(path)], text=True, capture_output=True, check=False)
            self.assertEqual(parsed.returncode, 0, parsed.stderr)
            help_result = subprocess.run(["bash", str(path), "--help"], cwd=ROOT, text=True, capture_output=True, check=False)
            self.assertEqual(help_result.returncode, 0, help_result.stderr)
            self.assertIn("Operations Dashboard", help_result.stdout)


class PublicCliTests(unittest.TestCase):
    def run_vwctl(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(ROOT / "vwctl"), *args], cwd=ROOT, text=True, capture_output=True, check=False)

    def test_help_tree_exposes_day2_commands_normally(self) -> None:
        result = self.run_vwctl("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        for surface in ("config", "secrets", "notification", "support-bundle", "timers", "crowdsec"):
            self.assertIn(surface, result.stdout)
        crowdsec = self.run_vwctl("crowdsec", "--help")
        self.assertEqual(crowdsec.returncode, 0, crowdsec.stderr)
        self.assertIn("decisions", crowdsec.stdout)
        self.assertIn("unban", crowdsec.stdout)
        config = self.run_vwctl("config", "--help")
        self.assertEqual(config.returncode, 0, config.stderr)
        self.assertIn("edit", config.stdout)

    def test_invalid_unban_fails_before_cscli(self) -> None:
        result = self.run_vwctl("crowdsec", "unban", "not-an-ip")
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid IP address", result.stderr)


class UpdateStatusTests(unittest.TestCase):
    def test_public_update_status_snapshot_has_no_private_update_dependency(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "update-check.json"
            path.write_text(json.dumps({"checked_at": 100, "candidate": "2.0", "available": True, "error": None}), encoding="utf-8")
            with mock.patch("vaultwarden_oci.update_status.cli.load_versions", return_value=mock.Mock(version="1.0")):
                payload = update_status.snapshot(path=path, now=200)
        self.assertEqual(payload["installed"], "1.0")
        self.assertEqual(payload["check_age_seconds"], 100)
        self.assertTrue(payload["available"])
        self.assertFalse(payload["check_stale"])


if __name__ == "__main__":
    unittest.main()
