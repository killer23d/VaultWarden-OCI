from __future__ import annotations

import io
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

from vaultwarden_oci import cli, operator_entrypoint, runtime, update_cli
from vaultwarden_oci.cli import CommandResult, DoctorCheck


class TTY(io.StringIO):
    def isatty(self) -> bool:
        return True


class OperatorEntrypointTests(unittest.TestCase):
    def tearDown(self) -> None:
        operator_entrypoint._COMPOSE_LIFECYCLE_STARTED = False
        cli.run_command = operator_entrypoint._BASE_RUN_COMMAND

    def test_compose_up_streams_output(self) -> None:
        completed = mock.Mock(returncode=0)
        argv = [
            "docker", "compose", "-f", "/run/vaultwarden-oci/transient/compose.yaml",
            "up", "-d", "--build", "--wait", "--wait-timeout", "120",
        ]
        output = io.StringIO()
        with mock.patch.object(operator_entrypoint.subprocess, "run", return_value=completed) as run:
            with redirect_stdout(output):
                result = operator_entrypoint.lifecycle_run_command(argv)
        self.assertTrue(result.ok)
        self.assertTrue(operator_entrypoint._COMPOSE_LIFECYCLE_STARTED)
        self.assertIn("Docker Compose build/start output follows", output.getvalue())
        self.assertNotIn("capture_output", run.call_args.kwargs)

    def test_other_commands_use_base_runner(self) -> None:
        expected = CommandResult(("docker", "version"), "success", 0, "ok", "")
        with mock.patch.object(operator_entrypoint, "_BASE_RUN_COMMAND", return_value=expected) as base:
            result = operator_entrypoint.lifecycle_run_command(["docker", "version"])
        self.assertIs(result, expected)
        base.assert_called_once()

    def test_active_compose_interrupt_cleanup_uses_runtime_stop(self) -> None:
        operator_entrypoint._COMPOSE_LIFECYCLE_STARTED = True
        with mock.patch.object(runtime, "lifecycle") as lifecycle:
            self.assertTrue(operator_entrypoint._cleanup_interrupted_lifecycle("start"))
        lifecycle.assert_called_once_with("stop", runner=operator_entrypoint._BASE_RUN_COMMAND)

    def test_preflight_interrupt_does_not_stop_stack(self) -> None:
        with mock.patch.object(runtime, "lifecycle") as lifecycle:
            self.assertTrue(operator_entrypoint._cleanup_interrupted_lifecycle("restart"))
        lifecycle.assert_not_called()

    def test_doctor_failure_guides_crowdsec_without_changing_json(self) -> None:
        output = TTY()
        checks = [DoctorCheck("crowdsec.engine", "FAIL", "inactive")]
        with mock.patch.object(cli, "doctor_checks", return_value=checks) as doctor:
            with redirect_stdout(output):
                operator_entrypoint._completion_guidance(["doctor"], 1)
        self.assertIn("sudo vwctl crowdsec setup", output.getvalue())
        doctor.assert_called_once()

        output = TTY()
        with mock.patch.object(cli, "doctor_checks") as doctor:
            with redirect_stdout(output):
                operator_entrypoint._completion_guidance(["doctor", "--json"], 1)
        self.assertEqual(output.getvalue(), "")
        doctor.assert_not_called()

    def test_first_healthy_start_guides_automation_only_when_needed(self) -> None:
        output = TTY()
        with mock.patch.object(
            operator_entrypoint,
            "_automation_enable_action",
            return_value="ACTION: enable persistent appliance automation",
        ):
            with redirect_stdout(output):
                operator_entrypoint._completion_guidance(["start"], 0)
        self.assertIn("enable persistent appliance automation", output.getvalue())

    def test_main_returns_130_and_restores_runner(self) -> None:
        original = cli.run_command
        stderr = io.StringIO()
        with mock.patch.object(update_cli, "main", side_effect=KeyboardInterrupt):
            with redirect_stderr(stderr):
                code = operator_entrypoint.main(["start"])
        self.assertEqual(code, 130)
        self.assertIs(cli.run_command, original)
        self.assertIn("FAIL: start interrupted", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
