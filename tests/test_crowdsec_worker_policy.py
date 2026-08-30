from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

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
    def test_native_local_only_config_is_healthy_without_migration_attestation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = paths_for(Path(directory))
            paths.remediation_config.parent.mkdir(parents=True)
            paths.remediation_config.write_text(
                'crowdsec_config:\n  only_include_decisions_from: ["cscli", "crowdsec"]\n',
                encoding="utf-8",
            )
            self.assertTrue(crowdsec_worker_policy.runtime_policy_healthy(paths, runner))

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


if __name__ == "__main__":
    unittest.main()
