"""Offline regressions for bounded TLS readiness; no DNS, HTTP or service changes."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest


_TARGET = Path(__file__).parent / "host-acceptance" / "https_readiness.py"
_SPEC = importlib.util.spec_from_file_location("https_readiness_acceptance", _TARGET)
assert _SPEC is not None and _SPEC.loader is not None
_module = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = _module
_SPEC.loader.exec_module(_module)


class HTTPSReadinessTests(unittest.TestCase):
    def test_first_start_tls_failure_then_verified_https_is_accepted(self) -> None:
        outcomes = [(35, "000"), (0, "200"), (0, "200"), (0, "401")]
        argv_seen = []
        now = [0.0]

        def run(argv, **kwargs):
            argv_seen.append(argv)
            self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
            code, response = outcomes.pop(0)
            return subprocess.CompletedProcess(argv, code, response, "")

        def sleep(seconds):
            now[0] += seconds

        result = _module.wait_for_https(
            "bw.lazymocha.com", timeout_seconds=10, interval_seconds=1,
            runner=run, clock=lambda: now[0], sleeper=sleep,
        )
        self.assertEqual(result.outcome, "pass")
        self.assertEqual(result.attempts, 2)
        self.assertEqual(len(argv_seen), 4)
        for argv in argv_seen:
            self.assertEqual(argv[:2], ["curl", "-q"])
            self.assertIn("bw.lazymocha.com:443:127.0.0.1", argv)
            self.assertIn("=https", argv)
            self.assertNotIn("-k", argv)
            self.assertNotIn("--insecure", argv)
        self.assertFalse(outcomes)

    def test_unexpected_http_response_is_not_retried(self) -> None:
        attempts = []

        def run(argv, **kwargs):
            attempts.append(argv)
            return subprocess.CompletedProcess(argv, 0, "503", "")

        result = _module.wait_for_https("bw.lazymocha.com", runner=run)
        self.assertEqual(result.outcome, "hold")
        self.assertIn("UNEXPECTED_HTTP_STATUS", result.reason)
        self.assertEqual(len(attempts), 1)

    def test_unavailable_certificate_times_out_without_fail_open(self) -> None:
        now = [0.0]
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 35, "000", "")

        def sleep(seconds):
            now[0] += seconds

        result = _module.wait_for_https(
            "bw.lazymocha.com", timeout_seconds=3, interval_seconds=1,
            runner=run, clock=lambda: now[0], sleeper=sleep,
        )
        self.assertEqual(result.outcome, "hold")
        self.assertTrue(result.reason.startswith("TIMEOUT_LAST_"))
        self.assertEqual(len(calls), 4)
        self.assertEqual(now[0], 3.0)

    def test_invalid_host_or_time_is_rejected_before_network(self) -> None:
        for value in ("https://bw.lazymocha.com", "bw.lazymocha.com;echo", "A.example.com", "localhost", ""):
            with self.subTest(host=value), self.assertRaises(ValueError):
                _module.wait_for_https(value)
        with self.assertRaises(ValueError):
            _module.wait_for_https("bw.lazymocha.com", timeout_seconds=601)


if __name__ == "__main__":
    unittest.main()
