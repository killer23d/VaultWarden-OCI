from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, install, update, update_appliance, update_cli, update_versions


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


def versions_text(project: str, vaultwarden: str) -> str:
    return f'''schema_version = 1
[vaultwarden_oci]
version = "{project}"
[components]
vaultwarden = "{vaultwarden}"
caddy = "2.12.0"
caddy_dns_cloudflare = "v0.3.0"
caddy_cloudflare_ip = "dddddddddddddddddddddddddddddddddddddddd"
caddy_combine_ip_ranges = "v0.0.2"
caddy_ratelimit = "v0.2.0"
[image_digests.vaultwarden]
amd64 = "{digest('a')}"
arm64 = "{digest('b')}"
[image_digests.caddy_builder]
amd64 = "{digest('c')}"
arm64 = "{digest('d')}"
[image_digests.caddy_runtime]
amd64 = "{digest('e')}"
arm64 = "{digest('f')}"
'''


def write_current_versions(path: Path, *, project: str = "2.0.0.latest.abcdef123456") -> None:
    path.mkdir(parents=True, exist_ok=True)
    (path / "versions.toml").write_text(
        versions_text(project, "1.40.0"),
        encoding="utf-8",
    )


def write_candidate_source(
    path: Path,
    *,
    project: str,
    vaultwarden: str,
) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    (path / "vwctl").write_text("#!/usr/bin/env python3\n", encoding="utf-8")
    (path / "versions.toml").write_text(
        versions_text(project, vaultwarden),
        encoding="utf-8",
    )
    (path / "email-providers.toml").write_text("# test catalog\n", encoding="utf-8")
    package = path / "vaultwarden_oci"
    package.mkdir()
    for name in ("update.py", "update_versions.py", "update_cli.py", "update_candidate.py"):
        (package / name).write_text(f"# {name}\n", encoding="utf-8")
    (path / install.SYSTEMD_SOURCE_DIR).mkdir()
    return path


def install_current(root: Path, *, project: str = "2.0.0.latest.abcdef123456") -> Path:
    layout = install.Layout(root)
    current_dir = layout.path(install.RELEASES_DIR) / project
    write_current_versions(current_dir, project=project)
    current = layout.path(install.CURRENT_LINK)
    current.parent.mkdir(parents=True, exist_ok=True)
    current.symlink_to(Path("releases") / project)
    return current_dir


def project_release(project: str) -> update_appliance.ProjectRelease:
    return update_appliance.ProjectRelease(
        f"v{project}",
        f"https://api.github.com/repos/killer23d/VaultWarden-OCI/tarball/v{project}",
        "2026-08-23T00:00:00Z",
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

    def test_same_base_latest_stable_check_uses_real_plan_update_without_component_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            root = temp / "host"
            install_current(root)
            source = write_candidate_source(
                temp / "candidate",
                project="2.0.0",
                vaultwarden="1.39.0",
            )

            prepared = update_appliance.prepare_plan(
                source,
                project_release=project_release("2.0.0"),
                root=root,
                machine="amd64",
                runner=command,
            )

        self.assertFalse(prepared.available)
        self.assertEqual(prepared.plan.current_release, "2.0.0.latest.abcdef123456")
        self.assertEqual(prepared.plan.target_release, "2.0.0")
        self.assertIn("implicit component downgrade", prepared.availability_reason)

    def test_newer_recommended_stable_still_rejects_component_downgrade_after_applicability(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            root = temp / "host"
            install_current(root)
            source = write_candidate_source(
                temp / "candidate",
                project="3.0.0",
                vaultwarden="1.39.0",
            )

            with self.assertRaisesRegex(update.UpdateError, "Vaultwarden downgrade"):
                update_appliance.prepare_plan(
                    source,
                    project_release=project_release("3.0.0"),
                    root=root,
                    machine="amd64",
                    runner=command,
                )

    def test_timer_same_base_latest_records_successful_no_update(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            root = temp / "host"
            install_current(root)
            source = write_candidate_source(
                temp / "candidate",
                project="2.0.0",
                vaultwarden="1.39.0",
            )
            release = project_release("2.0.0")
            real_prepare_plan = update_appliance.prepare_plan
            recorded: list[dict[str, object]] = []

            @contextlib.contextmanager
            def candidate_source(_source):
                yield source, release

            def prepare_plan(source_root, **kwargs):
                return real_prepare_plan(
                    source_root,
                    root=root,
                    machine="amd64",
                    runner=command,
                    **kwargs,
                )

            stdout = io.StringIO()
            stderr = io.StringIO()
            with (
                mock.patch.object(update_cli.storage, "verify"),
                mock.patch.object(update_appliance, "candidate_source", candidate_source),
                mock.patch.object(update_appliance, "prepare_plan", side_effect=prepare_plan),
                mock.patch.object(update_appliance, "_load_state", return_value={}),
                mock.patch.object(
                    update_appliance,
                    "_atomic_state",
                    side_effect=lambda payload, _path=update_appliance.UPDATE_STATE: recorded.append(dict(payload)),
                ),
                mock.patch.object(update_appliance, "_notify") as notify,
                mock.patch("sys.stdout", stdout),
                mock.patch("sys.stderr", stderr),
            ):
                code = update_cli._update_command(["check", "--timer", "--json"])

        self.assertEqual(code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(len(recorded), 1)
        self.assertEqual(recorded[0]["current"], "2.0.0.latest.abcdef123456")
        self.assertEqual(recorded[0]["candidate"], "2.0.0")
        self.assertFalse(recorded[0]["available"])
        self.assertIsNone(recorded[0]["error"])
        notify.assert_not_called()

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
