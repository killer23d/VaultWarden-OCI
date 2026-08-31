from __future__ import annotations

import io
import os
import unittest
from unittest import mock

from vaultwarden_oci import operator_output


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
        with mock.patch.dict(os.environ, {"NO_COLOR": "1"}):
            self.assertFalse(operator_output.color_enabled(TTY()))

    def test_non_tty_is_never_colored(self) -> None:
        stream = io.StringIO()
        writer = operator_output.ColorizingWriter(stream)
        writer.write("WARN: plain\n")
        self.assertEqual(stream.getvalue(), "WARN: plain\n")


if __name__ == "__main__":
    unittest.main()
