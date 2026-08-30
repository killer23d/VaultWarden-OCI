from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, crowdsec_worker_policy, edge, predecessor_transition
from vaultwarden_oci.update_versions import UpdateError

_OLD_INVOCATION = "0123456789abcdef0123456789abcdef"
_NEW_INVOCATION = "fedcba9876543210fedcba9876543210"


def result(argv, *, ok: bool = True, stdout: str = "") -> cli.CommandResult:
    return cli.CommandResult(
        tuple(str(value) for value in argv),
        "success" if ok else "nonzero",
        0 if ok else 1,
        stdout,
        "",
    )


def paths_for(root: Path) -> edge.EdgePaths:
    return edge.EdgePaths(
        lkg=root / "state/cloudflare.json",
        acquisition=root / "etc/crowdsec/acquis.d/vaultwarden-oci.yaml",
        bouncer_dropin=root / "systemd/worker.conf",
        remediation_config=root / "run/worker.yaml",
        caddy_log=root / "caddy/access.log",
        remediation_start_token=root / "run/start.token",
        fail_open_confirmation=root / "state/fail-open.json",
    )


class SupportedPredecessorTransitionTests(unittest.TestCase):
    def test_only_direct_supported_release_pair_is_recognized(self) -> None:
        self.assertTrue(
            predecessor_transition._required("0.1.0-dev.16", "0.1.0-dev.17")
        )
        self.assertTrue(
            predecessor_transition._required(
                "0.1.0-dev.16.latest.aaaaaaaaaaaa",
                "0.1.0-dev.17.latest.bbbbbbbbbbbb",
            )
        )
        for current, candidate in (
            ("0.1.0-dev.15", "0.1.0-dev.17"),
            ("0.1.0-dev.16", "0.1.0-dev.18"),
            ("0.1.0-dev.17", "0.1.0-dev.18"),
        ):
            self.assertFalse(predecessor_transition._required(current, candidate))

    def test_worker_rearm_invalidates_old_confirmation_and_requires_new_fail_open(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = paths_for(root)
            paths.remediation_config.parent.mkdir(parents=True)
            paths.fail_open_confirmation.parent.mkdir(parents=True)
            paths.remediation_config.write_text(
                "crowdsec_config:\n  only_include_decisions_from: []\n",
                encoding="utf-8",
            )
            paths.fail_open_confirmation.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "invocation_id": _OLD_INVOCATION,
                        "confirmed_at": 1,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            worker = {"active": True, "invocation": _OLD_INVOCATION}
            calls: list[tuple[str, ...]] = []

            def runner(argv, **_kwargs):
                call = tuple(str(value) for value in argv)
                calls.append(call)
                if call == ("systemctl", "is-active", "--quiet", edge.BOUNCER_SERVICE):
                    return result(argv, ok=worker["active"])
                if call == ("systemctl", "is-enabled", edge.BOUNCER_SERVICE):
                    return result(argv, ok=False, stdout="disabled\n")
                if call == (
                    "systemctl",
                    "show",
                    edge.BOUNCER_SERVICE,
                    "--property=InvocationID",
                    "--value",
                ):
                    return result(argv, stdout=str(worker["invocation"]) + "\n")
                if call == ("systemctl", "stop", edge.BOUNCER_SERVICE):
                    worker["active"] = False
                    return result(argv)
                if call == ("systemctl", "start", edge.BOUNCER_SERVICE):
                    paths.remediation_start_token.unlink(missing_ok=True)
                    worker["active"] = True
                    worker["invocation"] = _NEW_INVOCATION
                    return result(argv)
                if call[:3] == ("cscli", "bouncers", "inspect"):
                    return result(argv, stdout="{}\n")
                if call and call[0] == edge.BOUNCER_BINARY and call[-1:] == ("-t",):
                    return result(argv)
                return result(argv)

            with self.assertRaisesRegex(UpdateError, "set every bouncer-created Worker Route to Fail Open"):
                predecessor_transition.prepare_worker_prerequisite(
                    "0.1.0-dev.17",
                    current_release="0.1.0-dev.16",
                    paths=paths,
                    runner=runner,
                )

            self.assertFalse(paths.fail_open_confirmation.exists())
            self.assertTrue(crowdsec_worker_policy.managed_override_present(paths))
            self.assertTrue(crowdsec_worker_policy.runtime_policy_healthy(paths, runner))
            self.assertEqual(worker["invocation"], _NEW_INVOCATION)
            self.assertIn(("systemctl", "stop", edge.BOUNCER_SERVICE), calls)
            self.assertIn(("systemctl", "start", edge.BOUNCER_SERVICE), calls)

            paths.fail_open_confirmation.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "invocation_id": _NEW_INVOCATION,
                        "confirmed_at": 2,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            self.assertEqual(
                predecessor_transition.prepare_worker_prerequisite(
                    "0.1.0-dev.17",
                    current_release="0.1.0-dev.16",
                    paths=paths,
                    runner=runner,
                ),
                "0.1.0-dev.16",
            )

    def test_failed_transition_restores_predecessor_acquisition_and_removes_new_firewall_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            acquisition = root / "etc/crowdsec/acquis.d/vaultwarden-oci.yaml"
            acquisition.parent.mkdir(parents=True)
            original = "source: file\nlabels:\n  type: caddy\n"
            acquisition.write_text(original, encoding="utf-8")
            paths = paths_for(root)
            calls: list[tuple[str, ...]] = []

            def runner(argv, **_kwargs):
                call = tuple(str(value) for value in argv)
                calls.append(call)
                if call == ("systemctl", "is-active", "--quiet", edge.CROWDSEC_SERVICE):
                    return result(argv)
                return result(argv)

            worker = predecessor_transition._WorkerSnapshot(
                _NEW_INVOCATION,
                b"confirmation\n",
            )

            def fail_after_mutation(_paths, _runner):
                acquisition.write_text("candidate acquisition\n", encoding="utf-8")
                raise UpdateError("injected candidate CrowdSec failure")

            with (
                mock.patch.object(
                    predecessor_transition,
                    "_worker_snapshot",
                    return_value=worker,
                ),
                mock.patch.object(predecessor_transition, "_install_packages"),
                mock.patch.object(
                    predecessor_transition,
                    "_provision_candidate_crowdsec",
                    side_effect=fail_after_mutation,
                ),
                mock.patch.object(
                    predecessor_transition,
                    "_contain_firewall",
                    return_value=None,
                ),
            ):
                with self.assertRaisesRegex(
                    UpdateError,
                    "supported predecessor CrowdSec transition failed",
                ):
                    predecessor_transition._migrate(
                        paths=paths,
                        runner=runner,
                        policy_path=root / "policy-rc.d",
                    )

            self.assertEqual(acquisition.read_text(encoding="utf-8"), original)
            self.assertIn(
                (
                    "cscli",
                    "bouncers",
                    "delete",
                    edge.FIREWALL_BOUNCER_ID,
                    "--ignore-missing",
                ),
                calls,
            )
            self.assertIn(("systemctl", "restart", edge.CROWDSEC_SERVICE), calls)
            mutating_worker_calls = [
                call
                for call in calls
                if edge.BOUNCER_SERVICE in call
                and call[:2] in {
                    ("systemctl", "restart"),
                    ("systemctl", "stop"),
                    ("systemctl", "enable"),
                    ("systemctl", "disable"),
                }
            ]
            self.assertEqual(mutating_worker_calls, [])


if __name__ == "__main__":
    unittest.main()
