from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, crowdsec_worker_policy, edge

_INVOCATION = "0123456789abcdef0123456789abcdef"


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


def runner(argv, **_kwargs):
    call = tuple(str(value) for value in argv)
    if call == ("systemctl", "is-active", "--quiet", edge.BOUNCER_SERVICE):
        return result(argv)
    if call == (
        "systemctl",
        "show",
        edge.BOUNCER_SERVICE,
        "--property=InvocationID",
        "--value",
    ):
        return result(argv, stdout=_INVOCATION + "\n")
    return result(argv)


class CloudflareWorkerPolicyTests(unittest.TestCase):
    def test_native_local_only_config_requires_current_invocation_attestation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = paths_for(Path(directory))
            paths.remediation_config.parent.mkdir(parents=True)
            paths.remediation_config.write_text(
                'crowdsec_config:\n  only_include_decisions_from: ["cscli", "crowdsec"]\n',
                encoding="utf-8",
            )
            self.assertFalse(crowdsec_worker_policy.runtime_policy_healthy(paths, runner))
            crowdsec_worker_policy.attest_current(paths, runner)
            self.assertTrue(crowdsec_worker_policy.runtime_policy_healthy(paths, runner))

            paths.remediation_config.write_text(
                'crowdsec_config:\n  only_include_decisions_from: ["cscli", "crowdsec"]\n# drift\n',
                encoding="utf-8",
            )
            self.assertFalse(crowdsec_worker_policy.runtime_policy_healthy(paths, runner))

    def test_legacy_base_requires_managed_override_and_current_invocation_attestation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = paths_for(Path(directory))
            paths.remediation_config.parent.mkdir(parents=True)
            paths.remediation_config.write_text(
                "crowdsec_config:\n  only_include_decisions_from: []\n",
                encoding="utf-8",
            )
            crowdsec_worker_policy.install_managed_override(paths)
            self.assertFalse(crowdsec_worker_policy.runtime_policy_healthy(paths, runner))

            crowdsec_worker_policy.attest_current(paths, runner)
            self.assertTrue(crowdsec_worker_policy.runtime_policy_healthy(paths, runner))

            paths.remediation_config.write_text(
                "crowdsec_config:\n  only_include_decisions_from: []\n# changed after start\n",
                encoding="utf-8",
            )
            self.assertFalse(crowdsec_worker_policy.runtime_policy_healthy(paths, runner))

    def test_unexpected_local_override_is_never_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = paths_for(Path(directory))
            local = crowdsec_worker_policy.override_path(paths)
            local.parent.mkdir(parents=True)
            local.write_text("# operator-owned\ncrowdsec_config:\n  log_level: debug\n", encoding="utf-8")
            with self.assertRaises(crowdsec_worker_policy.WorkerPolicyError):
                crowdsec_worker_policy.install_managed_override(paths)
            self.assertEqual(
                local.read_text(encoding="utf-8"),
                "# operator-owned\ncrowdsec_config:\n  log_level: debug\n",
            )

    def test_doctor_pass_is_downgraded_when_source_policy_is_not_proven(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = paths_for(Path(directory))
            paths.remediation_config.parent.mkdir(parents=True)
            paths.remediation_config.write_text(
                "crowdsec_config:\n  only_include_decisions_from: []\n",
                encoding="utf-8",
            )
            checks = [
                cli.DoctorCheck("crowdsec.engine", "PASS", "engine"),
                cli.DoctorCheck("crowdsec.cloudflare", "PASS", "mechanical checks passed"),
            ]
            enforced = crowdsec_worker_policy.enforce_doctor_checks(
                checks,
                paths=paths,
                runner=runner,
            )
            cloudflare = next(check for check in enforced if check.check_id == "crowdsec.cloudflare")
            self.assertEqual(cloudflare.status, "FAIL")
            self.assertIn("exactly local", cloudflare.message)

    def test_edge_doctor_owner_always_applies_worker_source_policy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = paths_for(Path(directory))
            sentinel = [cli.DoctorCheck("crowdsec.cloudflare", "FAIL", "policy sentinel")]
            with mock.patch.object(
                crowdsec_worker_policy,
                "enforce_doctor_checks",
                return_value=sentinel,
            ) as enforce:
                self.assertIs(edge.doctor_checks(paths=paths, runner=runner, now=1), sentinel)
            enforce.assert_called_once()
            args, kwargs = enforce.call_args
            self.assertTrue(any(check.check_id == "crowdsec.cloudflare" for check in args[0]))
            self.assertEqual(kwargs["paths"], paths)
            self.assertIs(kwargs["runner"], runner)

    def test_start_owner_attests_current_invocation_and_stops_on_attestation_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = paths_for(Path(directory))
            state = {"active": False}
            calls: list[tuple[str, ...]] = []

            def start_runner(argv, **_kwargs):
                call = tuple(str(value) for value in argv)
                calls.append(call)
                if call == ("systemctl", "is-active", "--quiet", edge.BOUNCER_SERVICE):
                    return result(argv, ok=bool(state["active"]))
                if call == ("systemctl", "is-enabled", edge.BOUNCER_SERVICE):
                    return result(argv, ok=False, stdout="disabled\n")
                if call == ("systemctl", "start", edge.BOUNCER_SERVICE):
                    state["active"] = True
                    paths.remediation_start_token.unlink(missing_ok=True)
                    return result(argv)
                if call == ("systemctl", "stop", edge.BOUNCER_SERVICE):
                    state["active"] = False
                    return result(argv)
                return result(argv)

            with mock.patch.object(crowdsec_worker_policy, "attest_current") as attest:
                edge.start_remediation(paths=paths, runner=start_runner)
            attest.assert_called_once_with(paths, start_runner)
            self.assertTrue(state["active"])

            state["active"] = False
            with mock.patch.object(
                crowdsec_worker_policy,
                "attest_current",
                side_effect=crowdsec_worker_policy.WorkerPolicyError("not local-only"),
            ):
                with self.assertRaisesRegex(edge.EdgeError, "local-only decision policy could not be proven"):
                    edge.start_remediation(paths=paths, runner=start_runner)
            self.assertFalse(state["active"])
            self.assertIn(("systemctl", "stop", edge.BOUNCER_SERVICE), calls)


if __name__ == "__main__":
    unittest.main()
