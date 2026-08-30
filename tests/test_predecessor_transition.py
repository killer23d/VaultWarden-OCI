from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, edge, predecessor_transition
from vaultwarden_oci.update_versions import UpdateError


def result(argv, *, ok: bool = True, stdout: str = "") -> cli.CommandResult:
    return cli.CommandResult(
        tuple(str(value) for value in argv),
        "success" if ok else "nonzero",
        0 if ok else 1,
        stdout,
        "",
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

    def test_failed_transition_restores_predecessor_acquisition_and_removes_new_firewall_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            acquisition = root / "etc/crowdsec/acquis.d/vaultwarden-oci.yaml"
            acquisition.parent.mkdir(parents=True)
            original = "source: file\nlabels:\n  type: caddy\n"
            acquisition.write_text(original, encoding="utf-8")
            paths = edge.EdgePaths(
                lkg=root / "state/cloudflare.json",
                acquisition=acquisition,
                bouncer_dropin=root / "systemd/worker.conf",
                remediation_config=root / "run/worker.yaml",
                caddy_log=root / "caddy/access.log",
                remediation_start_token=root / "run/start.token",
                fail_open_confirmation=root / "state/fail-open.json",
            )
            calls: list[tuple[str, ...]] = []

            def runner(argv, **_kwargs):
                call = tuple(str(value) for value in argv)
                calls.append(call)
                if call == ("systemctl", "is-active", "--quiet", edge.CROWDSEC_SERVICE):
                    return result(argv)
                return result(argv)

            worker = predecessor_transition._WorkerSnapshot(
                "0123456789abcdef0123456789abcdef",
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
