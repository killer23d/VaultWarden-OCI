from __future__ import annotations

import contextlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, install, recovery, update, update_appliance, update_versions


def command(argv) -> cli.CommandResult:
    return cli.CommandResult(tuple(str(value) for value in argv), "success", 0, "", "")


def frozen() -> update_versions.FrozenVersions:
    digest = "sha256:" + "a" * 64
    return update_versions.FrozenVersions(
        source="pinned",
        architecture="amd64",
        project_version="0.1.0-dev.17",
        vaultwarden="1.37.1",
        caddy="2.11.4",
        caddy_dns_cloudflare="v0.2.4",
        vaultwarden_image=update_versions.ImagePin("vaultwarden", "vaultwarden/server", "1.37.1", digest),
        caddy_builder_image=update_versions.ImagePin("caddy_builder", "caddy", "2.11.4-builder-alpine", digest),
        caddy_runtime_image=update_versions.ImagePin("caddy_runtime", "caddy", "2.11.4-alpine", digest),
        caddy_cloudflare_ip="f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5",
        caddy_combine_ip_ranges="v0.0.1",
        caddy_ratelimit="v0.1.0",
    )


class PredecessorRecoveryBoundaryTests(unittest.TestCase):
    def test_recovery_failure_after_candidate_prerequisite_cannot_reach_host_transition(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            exact = root / "exact"
            source.mkdir()
            exact.mkdir()
            host = root / "host"
            old_release = host / "opt/vaultwarden-oci/releases/0.1.0-dev.16"
            old_release.mkdir(parents=True)
            plan = update.UpdatePlan(
                source_root=source,
                root=host,
                current_target=Path("releases/0.1.0-dev.16"),
                current_release="0.1.0-dev.16",
                target_release="0.1.0-dev.17",
                frozen=frozen(),
            )
            prepared = update_appliance.PreparedPlan(
                plan=plan,
                project_release=None,
                use_latest=False,
                available=True,
                availability_reason="recovery-boundary regression",
            )
            activator = mock.Mock()

            @contextlib.contextmanager
            def exact_source(*_args, **_kwargs):
                yield exact

            with (
                mock.patch.object(install, "_frozen_source", exact_source),
                mock.patch.object(update, "_validate_source"),
                mock.patch.object(
                    update,
                    "_current",
                    return_value=(
                        Path("releases/0.1.0-dev.16"),
                        "0.1.0-dev.16",
                        old_release,
                    ),
                ),
                mock.patch.object(
                    update_appliance,
                    "_preflight",
                    return_value=mock.Mock(offline_recovery_recipient="age1" + "q" * 58),
                ) as preflight,
                mock.patch.object(install, "stage_release") as stage,
                mock.patch.object(update_appliance.update_guard, "engage") as guard,
            ):
                with self.assertRaisesRegex(recovery.RecoveryError, "injected recovery failure"):
                    update_appliance.apply_prepared(
                        prepared,
                        runner=lambda argv, **_kwargs: command(argv),
                        activator=activator,
                        recovery_creator=lambda *_args, **_kwargs: (_ for _ in ()).throw(
                            recovery.RecoveryError("injected recovery failure")
                        ),
                    )

            preflight.assert_called_once()
            stage.assert_not_called()
            guard.assert_not_called()
            activator.assert_not_called()
            self.assertEqual(plan.current_release, "0.1.0-dev.16")


if __name__ == "__main__":
    unittest.main()
