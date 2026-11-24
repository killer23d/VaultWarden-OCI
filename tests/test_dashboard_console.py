from __future__ import annotations

import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import ExitStack, contextmanager, redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from vaultwarden_oci import dashboard, install

ROOT = Path(__file__).resolve().parents[1]


def status_fixture(state: str = "OPERATIONAL") -> dict[str, object]:
    """Synthetic read-model evidence; never a live-host acceptance receipt."""
    return {
        "schema_version": 1,
        "runtime": {"overall": "running", "services": [
            {"service": name, "state": "running", "health": "healthy"}
            for name in ("vaultwarden", "caddy")
        ]},
        "doctor": {"overall": "PASS", "checks": []},
        "storage": {"state": "ok", "mount": "/var/lib/vaultwarden-oci", "used_percent": 10, "warning": False},
        "recovery": [],
        "edge": {"overall": "PASS", "checks": []},
        "crowdsec": {"overall": "PASS", "checks": []},
        "admin": {"status": "PASS", "message": "protected"},
        "automation": {"overall": "PASS", "healthy": 4, "expected": 4,
                       "target": {"enabled": "enabled", "active_state": "active"}},
        "timers": [], "notification": {"state": "unknown"},
        "update": {"installed": "test", "available": False, "candidate": None,
                   "check_state": "current", "check_stale": False, "check_age_seconds": 0},
        "reboot_required": False,
        "operational": {
            "state": state, "reason": "Authoritative evidence from the operation owner.",
            "update_guard": {"state": "absent", "detail": "no recovery guard"},
            "backup": {"policy": "local_only", "destination_state": "not_configured",
                       "local": {"state": "current", "age_seconds": 120},
                       "offsite": {"state": "local_only"}, "scheduled_job": "success_recorded"},
            "automation": {"activation": "PASS", "boot_persistence": "persistent",
                           "execution": "success_recorded", "failed_jobs": [], "unverified_jobs": []},
            "notification": {"operational_route": "not_configured", "application_smtp": "configured",
                             "delivery_history": {"state": "unknown"}},
            "jobs": {},
            "crowdsec": {"boot_reconciliation": {"state": "not_established"},
                         "worker": {"invocation_observed": True, "fail_open_confirmation": "current"}},
        },
    }


class Terminal(io.StringIO):
    def isatty(self) -> bool:
        return True


@contextmanager
def installed_console():
    """A real disposable selected release and canonical launcher boundary."""
    with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
        root = Path(directory)
        releases = root / "releases"
        selected, candidate = releases / "selected", releases / "candidate"
        selected.mkdir(parents=True)
        candidate.mkdir()
        current = root / "current"
        current.symlink_to(selected)
        launcher = root / "bin" / "vwctl"
        launcher.parent.mkdir()
        for release, name in ((selected, "selected"), (candidate, "controller")):
            command = release / "vwctl"
            command.write_text(
                "#!/usr/bin/env python3\nimport json, sys\n"
                f"print(json.dumps({{'owner': {name!r}, 'args': sys.argv[1:]}}))\n",
                encoding="utf-8",
            )
            command.chmod(0o755)
        launcher.symlink_to(selected / "vwctl")
        for owner, name, value in (
            (dashboard, "RELEASE_ROOT", selected), (dashboard, "VWCTL", selected / "vwctl"),
            (install, "RELEASES_DIR", releases), (install, "CURRENT_LINK", current),
            (install, "VWCTL_LINK", launcher),
        ):
            stack.enter_context(mock.patch.object(owner, name, value))
        yield SimpleNamespace(root=root, selected=selected, candidate=candidate,
                              current=current, launcher=launcher)


class DashboardDispatchTests(unittest.TestCase):
    def test_installed_update_uses_current_canonical_handoff_launcher(self) -> None:
        with installed_console() as host:
            host.launcher.unlink()
            host.launcher.symlink_to(host.candidate / "vwctl")
            result = dashboard._run(["update", "check"], capture=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {"owner": "controller", "args": ["update", "check"]})
            self.assertEqual(host.current.resolve(), host.selected)

    def test_launcher_is_not_cached_between_update_attempts(self) -> None:
        with installed_console() as host:
            first = dashboard._run(["update", "check"], capture=True)
            host.launcher.unlink()
            host.launcher.symlink_to(host.candidate / "vwctl")
            second = dashboard._run(["update", "check"], capture=True)
            self.assertEqual(json.loads(first.stdout)["owner"], "selected")
            self.assertEqual(json.loads(second.stdout)["owner"], "controller")

    def test_source_checkout_keeps_its_own_command_owner(self) -> None:
        with installed_console() as host:
            checkout = host.root / "checkout"
            checkout.mkdir()
            command = checkout / "vwctl"
            command.write_text("#!/usr/bin/env python3\nprint('checkout command')\n", encoding="utf-8")
            command.chmod(0o755)
            with mock.patch.object(dashboard, "RELEASE_ROOT", checkout), mock.patch.object(dashboard, "VWCTL", command):
                result = dashboard._run(["status", "--json"], capture=True)
            self.assertEqual(result.stdout.strip(), "checkout command")

    def test_old_selected_session_cannot_dispatch_another_command(self) -> None:
        with installed_console() as host:
            host.current.unlink()
            host.current.symlink_to(host.candidate)
            with mock.patch.object(dashboard.subprocess, "run") as child:
                with self.assertRaises(dashboard.ReleaseChanged):
                    dashboard._run(["restart"])
            child.assert_not_called()

    def test_release_switch_during_child_stops_old_session(self) -> None:
        with installed_console() as host:
            command = host.selected / "vwctl"
            marker = host.root / "child-ran"
            command.write_text(
                "#!/usr/bin/env python3\nfrom pathlib import Path\n"
                f"current = Path({str(host.current)!r})\n"
                "current.unlink()\n"
                f"current.symlink_to({str(host.candidate)!r})\n"
                f"Path({str(marker)!r}).write_text('one invocation')\n",
                encoding="utf-8",
            )
            with self.assertRaises(dashboard.ReleaseChanged):
                dashboard._run(["update", "apply"], capture=True)
            self.assertEqual(marker.read_text(), "one invocation")
            with mock.patch.object(dashboard.subprocess, "run") as child:
                with self.assertRaises(dashboard.ReleaseChanged):
                    dashboard._run(["restart"])
            child.assert_not_called()

    def test_dangling_selected_release_refuses_command(self) -> None:
        with installed_console() as host:
            host.current.unlink()
            host.current.symlink_to(host.root / "missing-release")
            with mock.patch.object(dashboard.subprocess, "run") as child:
                with self.assertRaises(dashboard.ReleaseChanged):
                    dashboard._run(["backup"])
            child.assert_not_called()

    def test_missing_installed_launcher_never_falls_back_to_old_release(self) -> None:
        with installed_console() as host:
            host.launcher.unlink()
            payload = dashboard._status()
            self.assertIn("presentation_error", payload)


class DashboardEvidenceTests(unittest.TestCase):
    def test_nonzero_status_preserves_valid_failure_evidence(self) -> None:
        payload = status_fixture("CRITICAL")
        payload["doctor"]["overall"] = "FAIL"
        result = subprocess.CompletedProcess([], 1, json.dumps(payload), "")
        with mock.patch.object(dashboard, "_run", return_value=result):
            self.assertEqual(dashboard._status(), payload)

    def test_missing_malformed_and_wrong_shaped_status_are_not_success(self) -> None:
        wrong_services = status_fixture()
        wrong_services["runtime"]["services"] = "unavailable"
        wrong_service_row = status_fixture()
        wrong_service_row["runtime"]["services"] = [None]
        wrong_schema = status_fixture()
        wrong_schema["schema_version"] = 100
        wrong_doctor = status_fixture()
        wrong_doctor["doctor"] = []
        for raw in ("{", "null", "[]", "{}", json.dumps(wrong_schema),
                    json.dumps(wrong_doctor), json.dumps(wrong_services), json.dumps(wrong_service_row)):
            with self.subTest(raw=raw):
                with mock.patch.object(
                    dashboard, "_run", return_value=subprocess.CompletedProcess([], 0, raw, "")
                ):
                    payload = dashboard._status()
                self.assertIn("presentation_error", payload)
                output = io.StringIO()
                with redirect_stdout(output):
                    dashboard.draw_status(payload)
                self.assertNotIn("up to date", output.getvalue().lower())
                self.assertNotIn("not required", output.getvalue().lower())
                self.assertNotIn("OPERATIONAL", output.getvalue())

    def test_unavailable_launcher_becomes_unavailable_evidence(self) -> None:
        with mock.patch.object(dashboard, "_run", side_effect=FileNotFoundError("launcher missing")):
            payload = dashboard._status()
        self.assertIn("presentation_error", payload)

    def test_render_uses_authoritative_outcome_without_reclassifying(self) -> None:
        for state in ("OPERATIONAL", "ATTENTION", "RECOVERY REQUIRED", "CRITICAL",
                      "SETUP INCOMPLETE", "MAINTENANCE / STOPPED"):
            output = io.StringIO()
            with self.subTest(state=state), redirect_stdout(output):
                dashboard.draw_status(status_fixture(state))
            self.assertIn(state, output.getvalue())
            self.assertIn("Authoritative evidence", output.getvalue())


class DashboardInteractionTests(unittest.TestCase):
    def test_ctrl_c_waits_for_command_owner_cleanup_before_console_exit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready, cleaned = root / "ready", root / "cleaned"
            command = root / "vwctl"
            command.write_text(
                "#!/usr/bin/env python3\n"
                "import signal, time\nfrom pathlib import Path\n"
                "def interrupted(_signal, _frame):\n"
                "    time.sleep(0.7)\n"
                f"    Path({str(cleaned)!r}).write_text('owner cleanup completed')\n"
                "    raise SystemExit(130)\n"
                "signal.signal(signal.SIGINT, interrupted)\n"
                f"Path({str(ready)!r}).write_text('ready')\n"
                "while True:\n    signal.pause()\n",
                encoding="utf-8",
            )
            command.chmod(0o755)
            driver = (
                "import sys\nfrom pathlib import Path\n"
                f"sys.path.insert(0, {str(ROOT)!r})\n"
                "from vaultwarden_oci import dashboard\n"
                f"dashboard.RELEASE_ROOT = Path({str(root)!r})\n"
                f"dashboard.VWCTL = Path({str(command)!r})\n"
                "dashboard.os.geteuid = lambda: 0\n"
                f"dashboard._status = lambda: {status_fixture()!r}\n"
                "choices = iter(('u', '2'))\n"
                "dashboard._prompt = lambda _text: next(choices)\n"
                "raise SystemExit(dashboard.main([]))\n"
            )
            process = subprocess.Popen(
                [sys.executable, "-B", "-u", "-c", driver], cwd=ROOT,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists(), "test child did not reach its interrupt boundary")
                # Never send a signal to the test runner's own process group.
                self.assertEqual(os.getpgid(process.pid), process.pid)
                self.assertNotEqual(os.getpgrp(), process.pid)
                os.killpg(process.pid, signal.SIGINT)
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertTrue(cleaned.exists(), "dashboard killed the owner before interrupt cleanup completed")
                self.assertEqual(cleaned.read_text(), "owner cleanup completed")
                self.assertIn("not verified", stdout)
                self.assertIn("no further commands", stdout)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=5)

    def test_cancelled_zero_result_does_not_claim_completed_mutation(self) -> None:
        def cancelled(_args, **_kwargs):
            print("INFO: restore cancelled; no live state was changed")
            return subprocess.CompletedProcess([], 0)

        output = io.StringIO()
        with mock.patch.object(dashboard, "_run", side_effect=cancelled), \
             mock.patch.object(dashboard, "_press_enter"), redirect_stdout(output):
            dashboard._command_screen("Restore", ["restore"])
        self.assertIn("cancelled", output.getvalue())
        self.assertNotIn("PASS", output.getvalue())

    def test_cancelled_status_two_is_not_invented_failure_or_success(self) -> None:
        def cancelled(_args, **_kwargs):
            print("ACTION: update cancelled before mutation")
            return subprocess.CompletedProcess([], 2)

        output = io.StringIO()
        with mock.patch.object(dashboard, "_run", side_effect=cancelled), \
             mock.patch.object(dashboard, "_press_enter"), redirect_stdout(output):
            dashboard._command_screen("Apply update", ["update", "apply"])
        self.assertIn("cancelled", output.getvalue())
        self.assertNotIn("PASS", output.getvalue())
        self.assertNotIn("FAIL", output.getvalue())

    def test_invalid_menu_input_never_invokes_handler(self) -> None:
        handler = mock.Mock()
        output = io.StringIO()
        with mock.patch("builtins.input", side_effect=["not-an-option", "b"]), redirect_stdout(output):
            dashboard._menu("Choose an operation", (("1", "Supported operation"),), handler)
        handler.assert_not_called()
        self.assertIn("invalid", output.getvalue().lower())

    def test_direct_guide_refuses_nonterminal_before_dispatch(self) -> None:
        output = io.StringIO()
        with mock.patch.object(dashboard.os, "geteuid", return_value=0), \
             mock.patch.object(dashboard.sys.stdin, "isatty", return_value=False), \
             mock.patch.object(dashboard, "_run") as command, \
             redirect_stdout(output), redirect_stderr(output):
            code = dashboard.guide(["restore"])
        self.assertEqual(code, 1)
        command.assert_not_called()

    def test_guides_delegate_existing_workflows_with_explicit_context(self) -> None:
        for name, expected in (
            ("restore", ["restore"]),
            ("offsite", ["recovery", "offsite", "configure"]),
            ("recovery-kit", ["recovery-kit", "export"]),
        ):
            output = Terminal()
            with self.subTest(workflow=name), \
                 mock.patch.object(dashboard.os, "geteuid", return_value=0), \
                 mock.patch.object(dashboard.sys.stdin, "isatty", return_value=True), \
                 mock.patch.object(dashboard, "_run", return_value=subprocess.CompletedProcess([], 0)) as command, \
                 mock.patch.object(dashboard, "_press_enter"), \
                 mock.patch("builtins.input", return_value="yes"), redirect_stdout(output):
                self.assertEqual(dashboard.guide([name]), 0)
            command.assert_called_once_with(expected)
            for context in ("Purpose:", "Prerequisites:", "Impact and consent:", "Verification and next action:"):
                self.assertIn(context, output.getvalue())

    def test_guides_default_no_never_dispatch(self) -> None:
        for name in ("restore", "offsite", "recovery-kit"):
            output = Terminal()
            with self.subTest(workflow=name), \
                 mock.patch.object(dashboard.os, "geteuid", return_value=0), \
                 mock.patch.object(dashboard.sys.stdin, "isatty", return_value=True), \
                 mock.patch.object(dashboard, "_run") as command, \
                 mock.patch("builtins.input", return_value=""), redirect_stdout(output):
                self.assertEqual(dashboard.guide([name]), 0)
            command.assert_not_called()
            self.assertIn("CANCELLED", output.getvalue())

    def test_changed_release_exits_main_before_status_or_prompt(self) -> None:
        with installed_console() as host:
            host.current.unlink()
            host.current.symlink_to(host.candidate)
            output = io.StringIO()
            with mock.patch.object(dashboard.os, "geteuid", return_value=0), \
                 mock.patch.object(dashboard, "_status") as status, \
                 mock.patch("builtins.input") as prompt, redirect_stdout(output):
                self.assertEqual(dashboard.main([]), 0)
            status.assert_not_called()
            prompt.assert_not_called()
            self.assertIn("sudo vwctl menu", output.getvalue())

    def test_selection_change_while_menu_is_open_prevents_next_action(self) -> None:
        with installed_console() as host:
            def select_after_change(_prompt):
                host.current.unlink()
                host.current.symlink_to(host.candidate)
                return "3"

            output = io.StringIO()
            with mock.patch.object(dashboard.os, "geteuid", return_value=0), \
                 mock.patch.object(dashboard, "_status", return_value=status_fixture()), \
                 mock.patch.object(dashboard, "security_menu") as security, \
                 mock.patch("builtins.input", side_effect=select_after_change), redirect_stdout(output):
                self.assertEqual(dashboard.main([]), 0)
            security.assert_not_called()
            self.assertIn("sudo vwctl menu", output.getvalue())

    def test_release_change_after_guided_child_exits_without_another_prompt(self) -> None:
        output = Terminal()
        with mock.patch.object(dashboard.os, "geteuid", return_value=0), \
             mock.patch.object(dashboard.sys.stdin, "isatty", return_value=True), \
             mock.patch.object(dashboard, "_run", side_effect=dashboard.ReleaseChanged("selected release changed")), \
             mock.patch.object(dashboard, "_press_enter") as pause, \
             mock.patch("builtins.input", return_value="yes"), redirect_stdout(output):
            self.assertEqual(dashboard.guide(["restore"]), 0)
        pause.assert_not_called()
        self.assertIn("sudo vwctl menu", output.getvalue())

    def test_all_journals_include_dns_and_worker_boot_with_bounded_output(self) -> None:
        with mock.patch.object(dashboard.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as command, \
             mock.patch.object(dashboard, "_press_enter"), redirect_stdout(io.StringIO()):
            dashboard._journal_screen()
        argv = command.call_args.args[0]
        self.assertIn("vaultwarden-oci-dns.service", argv)
        self.assertIn("vaultwarden-oci-crowdsec-boot.service", argv)
        self.assertIn("--no-pager", argv)
        self.assertIn("--lines=200", argv)
        self.assertNotIn("--follow", argv)

    def test_navigation_eof_and_interrupt_exit_without_command(self) -> None:
        for interrupt in (EOFError, KeyboardInterrupt):
            output = io.StringIO()
            with self.subTest(interrupt=interrupt), \
                 mock.patch.object(dashboard.os, "geteuid", return_value=0), \
                 mock.patch.object(dashboard, "_status", return_value=status_fixture()), \
                 mock.patch.object(dashboard, "_run") as command, \
                 mock.patch("builtins.input", side_effect=interrupt), redirect_stdout(output):
                code = dashboard.main([])
            self.assertEqual(code, 0)
            command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
