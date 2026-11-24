from __future__ import annotations

import io
import os
import unittest
from unittest import mock

from vaultwarden_oci import operator_output, recovery_ux, update_cli


class TTY(io.StringIO):
    def isatty(self) -> bool:
        return True


class OperatorOutputTests(unittest.TestCase):
    def test_human_status_labels_are_colored(self) -> None:
        text = operator_output.colorize(
            "INFO: starting\nPASS: done\n[WARN] recovery.local: stale\n[FAIL] crowdsec.engine: down\n"
        )
        self.assertIn("\x1b[36mINFO\x1b[0m: starting", text)
        self.assertIn("\x1b[32mPASS\x1b[0m: done", text)
        self.assertIn("[\x1b[33mWARN\x1b[0m]", text)
        self.assertIn("[\x1b[31mFAIL\x1b[0m]", text)

    def test_no_color_honors_standard_opt_out(self) -> None:
        for value in ("1", ""):
            with self.subTest(value=value), mock.patch.dict(os.environ, {"NO_COLOR": value}):
                self.assertFalse(operator_output.color_enabled(TTY()))

    def test_dumb_terminal_is_never_colored(self) -> None:
        with mock.patch.dict(os.environ, {"TERM": "dumb"}, clear=True):
            self.assertFalse(operator_output.color_enabled(TTY()))

    def test_capable_terminal_uses_color(self) -> None:
        with mock.patch.dict(os.environ, {"TERM": "xterm-256color"}, clear=True):
            self.assertTrue(operator_output.color_enabled(TTY()))

    def test_non_tty_is_never_colored(self) -> None:
        stream = io.StringIO()
        writer = operator_output.ColorizingWriter(stream)
        writer.write("WARN: plain\n")
        self.assertEqual(stream.getvalue(), "WARN: plain\n")

    def test_guided_owners_render_with_shared_terminal_policy(self) -> None:
        cases = (
            (True, {"TERM": "xterm-256color"}, True),
            (True, {"TERM": "dumb"}, False),
            (True, {"TERM": "xterm", "NO_COLOR": ""}, False),
            (True, {"TERM": "xterm", "NO_COLOR": "1"}, False),
            (False, {"TERM": "xterm"}, False),
        )
        for factory in (recovery_ux.UI, update_cli.UI):
            for terminal, environment, colored in cases:
                stream = TTY() if terminal else io.StringIO()
                with (
                    self.subTest(factory=factory, terminal=terminal, environment=environment),
                    mock.patch.dict(os.environ, environment, clear=True),
                    mock.patch("sys.stdout", stream),
                ):
                    factory().ok("verified")
                self.assertEqual("\x1b[" in stream.getvalue(), colored)
                if not colored:
                    self.assertEqual(stream.getvalue(), "PASS verified\n")


if __name__ == "__main__":
    unittest.main()
