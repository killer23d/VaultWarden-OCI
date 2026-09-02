from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import recovery, runtime, runtime_health, update
from vaultwarden_oci.cli import CommandResult


def result(argv, stdout="", stderr="", code=0):
    return CommandResult(tuple(argv), "success" if code == 0 else "nonzero", code, stdout, stderr)


class RuntimeStateRunner:
    def __init__(self, states: dict[str, dict[str, object]]):
        self.states = states
        self.calls: list[tuple[str, ...]] = []

    def __call__(self, argv, **_):
        call = tuple(argv)
        self.calls.append(call)
        if call[:2] == ("docker", "version"):
            return result(argv, "28.0\n")
        if call[:4] == ("docker", "container", "inspect", "--format"):
            container = call[-1]
            state = self.states.get(container)
            if state is None:
                return result(argv, stderr="Error: No such object", code=1)
            return result(argv, json.dumps(state))
        if call[:2] == ("docker", "pause"):
            self.states[call[2]]["Paused"] = True
            return result(argv)
        if call[:2] == ("docker", "unpause"):
            self.states[call[2]]["Paused"] = False
            return result(argv)
        raise AssertionError(call)


class SequencedStatusRunner:
    def __init__(self, snapshots: list[dict[str, str]]):
        self.snapshots = snapshots
        self.index = 0
        self.calls: list[tuple[str, ...]] = []

    def __call__(self, argv, **_):
        call = tuple(argv)
        self.calls.append(call)
        if call[:2] == ("docker", "version"):
            return result(argv, "28.0\n")
        if call[:4] == ("docker", "container", "inspect", "--format"):
            service = "vaultwarden" if call[-1] == runtime.NAMES["vaultwarden"] else "caddy"
            snapshot = self.snapshots[min(self.index, len(self.snapshots) - 1)]
            health = snapshot[service]
            if service == "caddy":
                self.index += 1
            return result(
                argv,
                json.dumps(
                    {
                        "Status": "running",
                        "Paused": False,
                        "Health": {"Status": health},
                    }
                ),
            )
        raise AssertionError(call)


class BackupHealthSettleTests(unittest.TestCase):
    def test_shared_bounded_policy_is_used_by_updater_constants(self) -> None:
        self.assertEqual(update.CURRENT_HEALTH_SETTLE_SECONDS, runtime_health.SETTLE_SECONDS)
        self.assertEqual(update.CURRENT_HEALTH_POLL_SECONDS, runtime_health.POLL_SECONDS)

    def test_transient_post_unpause_health_waits_until_healthy(self) -> None:
        runner = SequencedStatusRunner(
            [
                {"vaultwarden": "unhealthy", "caddy": "unhealthy"},
                {"vaultwarden": "healthy", "caddy": "healthy"},
            ]
        )
        sleeps: list[float] = []
        ticks = iter([0.0, 0.0])
        recovery._wait_for_resumed_health(
            ("vaultwarden", "caddy"),
            runner,
            settle_seconds=10,
            poll_seconds=2,
            sleep=sleeps.append,
            monotonic=lambda: next(ticks),
        )
        self.assertEqual(sleeps, [2])

    def test_post_unpause_health_timeout_is_bounded_and_actionable(self) -> None:
        runner = SequencedStatusRunner(
            [{"vaultwarden": "unhealthy", "caddy": "unhealthy"}]
        )
        ticks = iter([0.0, 0.0, 3.0])
        with self.assertRaisesRegex(
            recovery.RecoveryError,
            "post-backup runtime health did not recover: timed out after 3s",
        ):
            recovery._wait_for_resumed_health(
                ("vaultwarden", "caddy"),
                runner,
                settle_seconds=3,
                poll_seconds=1,
                sleep=lambda _: None,
                monotonic=lambda: next(ticks),
            )

    def test_preexisting_stopped_degraded_and_paused_states_do_not_create_health_obligations(self) -> None:
        states = {
            runtime.NAMES["caddy"]: {
                "Status": "running",
                "Paused": True,
                "Health": {"Status": "healthy"},
            },
            runtime.NAMES["vaultwarden"]: {
                "Status": "exited",
                "Paused": False,
                "Health": {"Status": "unhealthy"},
            },
        }
        runner = RuntimeStateRunner(states)
        paused, health_required = recovery._pause_live_services(runner)
        self.assertEqual(paused, ())
        self.assertEqual(health_required, ())
        self.assertFalse(any(call[:2] == ("docker", "pause") for call in runner.calls))
        self.assertFalse(any(call[:2] == ("docker", "unpause") for call in runner.calls))

    def test_only_services_healthy_before_backup_are_post_resume_obligations(self) -> None:
        states = {
            runtime.NAMES["caddy"]: {
                "Status": "running",
                "Paused": False,
                "Health": {"Status": "healthy"},
            },
            runtime.NAMES["vaultwarden"]: {
                "Status": "running",
                "Paused": False,
                "Health": {"Status": "unhealthy"},
            },
        }
        runner = RuntimeStateRunner(states)
        paused, health_required = recovery._pause_live_services(runner)
        self.assertEqual(set(paused), set(runtime.NAMES.values()))
        self.assertEqual(health_required, ("caddy",))
        recovery._resume_paused_services(paused, runner)
        self.assertFalse(any(bool(state["Paused"]) for state in states.values()))

    def test_resume_failure_is_surfaced_and_never_claimed_success(self) -> None:
        def failing_runner(argv, **_):
            if argv[:2] == ["docker", "unpause"]:
                return result(argv, stderr="forced unpause failure", code=1)
            raise AssertionError(tuple(argv))

        with self.assertRaisesRegex(
            recovery.RecoveryError,
            "failed to resume quiesced recovery service",
        ):
            recovery._resume_paused_services((runtime.NAMES["caddy"],), failing_runner)

    def test_committed_artifact_is_retained_if_post_resume_health_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = recovery.RecoveryPaths(
                backups=root / "backups",
                state_file=root / "state/recovery.json",
                config=root / "etc/config.toml",
                encrypted_secrets=root / "etc/secrets.sops.yaml",
                operational_age_key=root / "etc/age-key.txt",
                data=root / "data",
                caddy_data=root / "caddy/data",
                caddy_config=root / "caddy/config",
                lock=root / "run/lock",
            )
            paths.lock.parent.mkdir(parents=True)

            def runner(argv, **_):
                if argv[:2] == ["age", "--encrypt"]:
                    output = Path(argv[argv.index("--output") + 1])
                    output.write_bytes(b"age-encryption.org/v1\n" + b"x" * 80)
                    return result(argv)
                raise AssertionError(tuple(argv))

            manifest = {"created_at": "2026-09-02T20:00:00Z"}
            with (
                mock.patch.object(recovery.secrets, "validate_recipient"),
                mock.patch.object(recovery, "_validate_backup_secret_custody"),
                mock.patch.object(
                    recovery,
                    "_pause_live_services",
                    return_value=((runtime.NAMES["caddy"],), ("caddy",)),
                ),
                mock.patch.object(recovery, "_resume_paused_services"),
                mock.patch.object(recovery, "_build_candidate", return_value=manifest),
                mock.patch.object(recovery, "_validate_manifest"),
                mock.patch.object(recovery, "_archive_candidate"),
                mock.patch.object(recovery, "_verify_age_artifact"),
                mock.patch.object(
                    recovery,
                    "_wait_for_resumed_health",
                    side_effect=recovery.RecoveryError("post-backup runtime health did not recover"),
                ),
            ):
                with self.assertRaisesRegex(
                    recovery.RecoveryError,
                    "verified recovery artifact .* was created",
                ):
                    recovery.create_recovery("age1" + "q" * 58, paths=paths, runner=runner)

            artifacts = list(paths.backups.glob("*.vwrec"))
            self.assertEqual(len(artifacts), 1)
            self.assertFalse(paths.state_file.exists())


if __name__ == "__main__":
    unittest.main()
