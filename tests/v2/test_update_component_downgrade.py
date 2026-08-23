from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, install, update, update_appliance, update_versions


def digest(char: str) -> str:
    return "sha256:" + char * 64


def frozen(*, project: str, vaultwarden: str) -> update_versions.FrozenVersions:
    return update_versions.FrozenVersions(
        "pinned",
        "amd64",
        project,
        vaultwarden,
        "2.12.0",
        "v0.3.0",
        update_versions.ImagePin("vaultwarden", "vaultwarden/server", vaultwarden, digest("a")),
        update_versions.ImagePin("caddy_builder", "caddy", "2.12.0-builder-alpine", digest("b")),
        update_versions.ImagePin("caddy_runtime", "caddy", "2.12.0-alpine", digest("c")),
        caddy_cloudflare_ip="d" * 40,
        caddy_combine_ip_ranges="v0.0.2",
        caddy_ratelimit="v0.2.0",
    )


def command(argv, **_kwargs) -> cli.CommandResult:
    return cli.CommandResult(tuple(argv), "success", 0, "", "")


def write_current_versions(path: Path, *, project: str = "2.0.0.latest.abcdef123456") -> None:
    path.mkdir(parents=True, exist_ok=True)
    (path / "versions.toml").write_text(
        f'''schema_version = 1
[vaultwarden_oci]
version = "{project}"
[components]
vaultwarden = "1.40.0"
caddy = "2.12.0"
caddy_dns_cloudflare = "v0.3.0"
caddy_cloudflare_ip = "dddddddddddddddddddddddddddddddddddddddd"
caddy_combine_ip_ranges = "v0.0.2"
caddy_ratelimit = "v0.2.0"
''',
        encoding="utf-8",
    )


class ComponentDowngradePlanningTests(unittest.TestCase):
    def test_newer_project_release_cannot_hide_vaultwarden_downgrade(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            source = temp / "candidate"
            source.mkdir()
            current = temp / "current-release"
            write_current_versions(current)
            candidate = frozen(project="3.0.0", vaultwarden="1.39.0")
            with (
                mock.patch.object(update, "_validate_source"),
                mock.patch.object(
                    update,
                    "_current",
                    return_value=(Path("releases/2.0.0.latest.abcdef123456"), "2.0.0.latest.abcdef123456", current),
                ),
                mock.patch.object(update, "_gate_current"),
                mock.patch.object(update, "resolve_pinned", return_value=candidate),
            ):
                with self.assertRaisesRegex(update.UpdateError, "Vaultwarden downgrade"):
                    update.plan_update(
                        source,
                        root=temp / "host",
                        machine="amd64",
                        runner=command,
                    )

    def test_use_latest_checks_final_snapshot_not_intermediate_tested_pins(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            root = temp / "host"
            source = temp / "candidate"
            source.mkdir()
            current_target = Path("releases/2.0.0.latest.abcdef123456")
            current_dir = install.Layout(root).path(install.INSTALL_ROOT) / current_target
            write_current_versions(current_dir)

            tested = frozen(project="3.0.0", vaultwarden="1.39.0")
            latest = frozen(project="3.0.0.latest.123456abcdef", vaultwarden="1.41.0")
            base = update.UpdatePlan(
                source,
                root,
                current_target,
                "2.0.0.latest.abcdef123456",
                "3.0.0",
                tested,
            )

            def plan_update(*_args, **kwargs):
                self.assertFalse(kwargs["enforce_component_downgrades"])
                return base

            with (
                mock.patch.object(update_appliance.update, "plan_update", side_effect=plan_update),
                mock.patch.object(update_appliance.update, "resolve_pinned", return_value=tested),
                mock.patch.object(update_appliance, "resolve_latest_supported", return_value=latest),
            ):
                prepared = update_appliance.prepare_plan(
                    source,
                    use_latest=True,
                    root=root,
                    machine="amd64",
                    runner=command,
                )

            self.assertTrue(prepared.available)
            self.assertEqual(prepared.plan.frozen.vaultwarden, "1.41.0")
            self.assertEqual(prepared.plan.target_release, "3.0.0.latest.123456abcdef")


if __name__ == "__main__":
    unittest.main()
