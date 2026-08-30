from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, install, update
from vaultwarden_oci.update_versions import UpdateError


def command(argv, *, ok: bool = True, stdout: str = "", stderr: str = "") -> cli.CommandResult:
    return cli.CommandResult(
        tuple(argv),
        "success" if ok else "nonzero",
        0 if ok else 1,
        stdout,
        stderr,
    )


class CurrentRuntimeHealthSettleTests(unittest.TestCase):
    def _layout(self, root: Path) -> install.Layout:
        install_root = root / "opt/vaultwarden-oci"
        release = install_root / "releases/1.0.0"
        release.mkdir(parents=True)
        (release / "vwctl").write_text("#!/bin/sh\n", encoding="utf-8")
        (install_root / "current").symlink_to("releases/1.0.0")
        return install.Layout(root)

    def test_transient_unhealthy_status_settles_before_doctor_gate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            layout = self._layout(Path(directory))
            calls: list[tuple[str, ...]] = []
            status_count = 0

            def runner(argv, **_kwargs):
                nonlocal status_count
                call = tuple(argv)
                calls.append(call)
                if call[-1] == "status":
                    status_count += 1
                    if status_count == 1:
                        return command(
                            argv,
                            ok=False,
                            stderr="vaultwarden: running (health=unhealthy)\ncaddy: running (health=unhealthy)",
                        )
                return command(argv)

            with (
                mock.patch.object(update.time, "monotonic", side_effect=[100.0, 101.0]),
                mock.patch.object(update.time, "sleep") as sleep,
            ):
                update._gate_current(layout, runner)

        self.assertEqual(status_count, 2)
        sleep.assert_called_once_with(update.CURRENT_HEALTH_POLL_SECONDS)
        self.assertTrue(any(call[-2:] == ("doctor", "--json") for call in calls))

    def test_persistent_unhealthy_status_times_out_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            layout = self._layout(Path(directory))
            calls: list[tuple[str, ...]] = []

            def runner(argv, **_kwargs):
                call = tuple(argv)
                calls.append(call)
                if call[-1] == "status":
                    return command(
                        argv,
                        ok=False,
                        stderr="vaultwarden: running (health=unhealthy)\ncaddy: running (health=unhealthy)",
                    )
                return command(argv)

            with (
                mock.patch.object(
                    update.time,
                    "monotonic",
                    side_effect=[100.0, 100.0 + update.CURRENT_HEALTH_SETTLE_SECONDS],
                ),
                mock.patch.object(update.time, "sleep") as sleep,
            ):
                with self.assertRaisesRegex(UpdateError, "current runtime status is not safe"):
                    update._gate_current(layout, runner)

        sleep.assert_not_called()
        self.assertFalse(any(call[-2:] == ("doctor", "--json") for call in calls))

    def test_non_health_failure_is_not_retried(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            layout = self._layout(Path(directory))
            calls: list[tuple[str, ...]] = []

            def runner(argv, **_kwargs):
                calls.append(tuple(argv))
                return command(argv, ok=False, stderr="crowdsec.engine: FAIL")

            with mock.patch.object(update.time, "sleep") as sleep:
                with self.assertRaisesRegex(UpdateError, "crowdsec.engine: FAIL"):
                    update._gate_current(layout, runner)

        sleep.assert_not_called()
        self.assertEqual(len(calls), 1)

    def test_mixed_unhealthy_and_stopped_runtime_is_not_retried(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            layout = self._layout(Path(directory))
            calls: list[tuple[str, ...]] = []

            def runner(argv, **_kwargs):
                calls.append(tuple(argv))
                return command(
                    argv,
                    ok=False,
                    stderr=(
                        "vaultwarden: running (health=unhealthy)\n"
                        "caddy: exited (health=-)"
                    ),
                )

            with mock.patch.object(update.time, "sleep") as sleep:
                with self.assertRaisesRegex(UpdateError, "caddy: exited"):
                    update._gate_current(layout, runner)

        sleep.assert_not_called()
        self.assertEqual(len(calls), 1)

    def test_unhealthy_runtime_plus_independent_failure_is_not_retried(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            layout = self._layout(Path(directory))
            calls: list[tuple[str, ...]] = []

            def runner(argv, **_kwargs):
                calls.append(tuple(argv))
                return command(
                    argv,
                    ok=False,
                    stderr=(
                        "vaultwarden: running (health=unhealthy)\n"
                        "caddy: running (health=healthy)\n"
                        "crowdsec.engine: FAIL (engine unavailable)"
                    ),
                )

            with mock.patch.object(update.time, "sleep") as sleep:
                with self.assertRaisesRegex(UpdateError, "crowdsec.engine: FAIL"):
                    update._gate_current(layout, runner)

        sleep.assert_not_called()
        self.assertEqual(len(calls), 1)

    def test_caddy_health_doctor_derivative_can_settle_with_unhealthy_caddy(self) -> None:
        detail = (
            "vaultwarden: running (health=healthy)\n"
            "caddy: running (health=unhealthy)\n"
            "edge.caddy.health: FAIL (Caddy container is stopped, unhealthy, or could not be inspected)"
        )
        self.assertTrue(update._transient_runtime_health(detail))


if __name__ == "__main__":
    unittest.main()
