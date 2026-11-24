from __future__ import annotations

import io
import subprocess
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from vaultwarden_oci import dashboard, update_cli


ROOT = Path(__file__).resolve().parents[1]


class Terminal(io.StringIO):
    def isatty(self) -> bool:
        return True


class MenuEntrypointTests(unittest.TestCase):
    def test_console_dispatch_does_not_require_storage_or_clear_guard(self) -> None:
        cases = (
            (["menu"], "main", []),
            (["guide"], "guide", []),
            (["guide", "restore"], "guide", ["restore"]),
            (["guide", "offsite"], "guide", ["offsite"]),
            (["guide", "recovery-kit"], "guide", ["recovery-kit"]),
        )
        for argv, function, forwarded in cases:
            for code in (0, 1, 2, 130):
                with (
                    self.subTest(argv=argv, code=code),
                    mock.patch.object(dashboard, function, return_value=code) as entry,
                    mock.patch.object(update_cli, "_require_storage") as storage,
                    mock.patch.object(update_cli, "_guard_error") as guard,
                ):
                    self.assertEqual(update_cli.main(argv), code)
                entry.assert_called_once_with(forwarded)
                storage.assert_not_called()
                guard.assert_not_called()

    def test_help_works_before_host_checks_or_interactive_dispatch(self) -> None:
        for argv in (["menu", "--help"], ["guide", "--help"], ["guide", "restore", "--help"]):
            output = io.StringIO()
            with (
                self.subTest(argv=argv),
                mock.patch.object(dashboard, "main") as menu,
                mock.patch.object(dashboard, "guide") as guide,
                mock.patch.object(update_cli, "_require_storage") as storage,
                mock.patch.object(update_cli, "_guard_error") as guard,
                redirect_stdout(output),
                self.assertRaises(SystemExit) as raised,
            ):
                update_cli.main(argv)
            self.assertEqual(raised.exception.code, 0)
            self.assertIn("usage: vwctl", output.getvalue())
            menu.assert_not_called()
            guide.assert_not_called()
            storage.assert_not_called()
            guard.assert_not_called()

    def test_invalid_workflows_and_options_never_enter_console(self) -> None:
        for argv in (
            ["guide", "setup"], ["guide", "repair"], ["guide", "restore", "--yes"],
            ["guide", "--json"], ["menu", "start"], ["menu", "--yes"],
        ):
            with (
                self.subTest(argv=argv),
                mock.patch.object(dashboard, "main") as menu,
                mock.patch.object(dashboard, "guide") as guide,
                mock.patch.object(update_cli, "_require_storage") as storage,
                mock.patch.object(update_cli, "_guard_error") as guard,
                redirect_stderr(io.StringIO()),
                self.assertRaises(SystemExit) as raised,
            ):
                update_cli.main(argv)
            self.assertEqual(raised.exception.code, 2)
            menu.assert_not_called()
            guide.assert_not_called()
            storage.assert_not_called()
            guard.assert_not_called()

    def test_supported_mutations_still_require_existing_host_gates(self) -> None:
        with (
            mock.patch.object(update_cli, "_guard_error", return_value=True) as guard,
            mock.patch.object(update_cli, "_require_storage") as storage,
            mock.patch.object(update_cli.cli, "main") as core,
        ):
            self.assertEqual(update_cli.main(["restore"]), 1)
        guard.assert_called_once_with(machine=False)
        storage.assert_not_called()
        core.assert_not_called()
        with (
            mock.patch.object(update_cli, "_require_storage", return_value=False) as storage,
            mock.patch("vaultwarden_oci.recovery_ux.main") as recovery,
        ):
            self.assertEqual(update_cli.main(["recovery", "offsite", "configure"]), 1)
        storage.assert_called_once_with()
        recovery.assert_not_called()

    def test_direct_guides_require_both_terminal_streams_before_dispatch(self) -> None:
        for workflow in ("restore", "offsite", "recovery-kit"):
            for input_tty, output_tty in ((False, False), (True, False), (False, True)):
                stdin = Terminal() if input_tty else io.StringIO()
                stdout = Terminal() if output_tty else io.StringIO()
                stderr = io.StringIO()
                with (
                    self.subTest(workflow=workflow, input_tty=input_tty, output_tty=output_tty),
                    mock.patch("sys.stdin", stdin),
                    mock.patch("sys.stdout", stdout),
                    mock.patch("sys.stderr", stderr),
                    mock.patch.object(dashboard.os, "geteuid", return_value=0),
                    mock.patch.object(dashboard, "_run") as command,
                ):
                    self.assertEqual(update_cli.main(["guide", workflow]), 1)
                command.assert_not_called()
                self.assertIn("terminal", (stdout.getvalue() + stderr.getvalue()).lower())

    def test_nested_guide_interrupt_or_eof_closes_the_parent_console(self) -> None:
        for interruption in (KeyboardInterrupt, EOFError):
            output = io.StringIO()
            with (
                self.subTest(interruption=interruption),
                mock.patch.object(dashboard.os, "geteuid", return_value=0),
                mock.patch.object(dashboard, "_status", return_value={"presentation_error": "unavailable"}) as status,
                mock.patch.object(dashboard, "_prompt", side_effect=["g", interruption]) as prompt,
                mock.patch.object(dashboard, "_run") as command,
                redirect_stdout(output),
            ):
                self.assertEqual(dashboard.main([]), 0)
            status.assert_called_once_with()
            self.assertEqual(prompt.call_count, 2)
            command.assert_not_called()
            self.assertEqual(output.getvalue().count("CANCELLED:"), 1)

    def test_direct_chooser_exits_once_when_its_selected_guide_is_interrupted(self) -> None:
        output = Terminal()
        with (
            mock.patch.object(dashboard.os, "geteuid", return_value=0),
            mock.patch("sys.stdin", Terminal()),
            redirect_stdout(output),
            mock.patch.object(dashboard, "_status") as status,
            mock.patch.object(dashboard, "_prompt", side_effect=["restore"]) as prompt,
            mock.patch.object(dashboard, "_guided_operation", side_effect=KeyboardInterrupt) as operation,
        ):
            self.assertEqual(dashboard.guide([]), 0)
        prompt.assert_called_once()
        operation.assert_called_once_with("restore")
        status.assert_not_called()
        self.assertEqual(output.getvalue().count("CANCELLED:"), 1)

    def test_public_cli_help_discovers_supported_console_and_guides(self) -> None:
        for argv in (["--help"], ["menu", "--help"], ["guide", "--help"]):
            with self.subTest(argv=argv):
                result = subprocess.run(
                    [sys.executable, "-B", str(ROOT / "vwctl"), *argv],
                    cwd=ROOT, capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("\x1b[", result.stdout + result.stderr)
                if argv == ["--help"]:
                    self.assertIn("menu", result.stdout)
                    self.assertIn("guide", result.stdout)
                elif argv[0] == "guide":
                    for workflow in ("restore", "offsite", "recovery-kit"):
                        self.assertIn(workflow, result.stdout)


if __name__ == "__main__":
    unittest.main()
