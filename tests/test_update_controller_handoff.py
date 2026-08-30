from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import install, update_controller_handoff
from vaultwarden_oci.update_versions import UpdateError

_PREDECESSOR = "0.1.0-dev.16.latest.aaaaaaaaaaaa"
_TARGET = "0.1.0-dev.17.latest.bbbbbbbbbbbb"


def _versions(path: Path, version: str = _TARGET) -> None:
    path.write_text(
        "schema_version = 1\n\n"
        "[vaultwarden_oci]\n"
        f'version = "{version}"\n',
        encoding="utf-8",
    )


class UpdateControllerHandoffTests(unittest.TestCase):
    def _host(self, root: Path) -> tuple[install.Layout, Path, Path, Path]:
        layout = install.Layout(root.resolve())
        releases = layout.path(install.RELEASES_DIR)
        predecessor = releases / _PREDECESSOR
        predecessor.mkdir(parents=True)
        predecessor_vwctl = predecessor / "vwctl"
        predecessor_vwctl.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        predecessor_vwctl.chmod(0o755)

        current = layout.path(install.CURRENT_LINK)
        current.parent.mkdir(parents=True, exist_ok=True)
        current.symlink_to(Path("releases") / _PREDECESSOR)

        launcher = layout.path(install.VWCTL_LINK)
        launcher.parent.mkdir(parents=True, exist_ok=True)
        launcher.symlink_to(current / "vwctl")

        source = root / "candidate-source"
        source.mkdir()
        _versions(source / "versions.toml")
        return layout, source, launcher, predecessor_vwctl

    @staticmethod
    def _fake_stage(layout: install.Layout):
        def stage(_source: Path, actual_layout: install.Layout, release: str) -> Path:
            assert actual_layout.root == layout.root
            destination = actual_layout.path(install.RELEASES_DIR) / release
            controller = destination / "vwctl"
            if not destination.exists():
                destination.mkdir(parents=True)
                controller.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                controller.chmod(0o555)
            return destination

        return stage

    def test_prepare_stages_exact_controller_and_revalidates_active_handoff(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            layout, source, launcher, _ = self._host(root)
            controller = layout.path(install.RELEASES_DIR) / _TARGET / "vwctl"

            with mock.patch.object(
                update_controller_handoff.install,
                "stage_release",
                side_effect=self._fake_stage(layout),
            ) as staged:
                changed = update_controller_handoff.prepare_if_required(
                    _TARGET,
                    source,
                    current_release=_PREDECESSOR,
                    root=root,
                )
                self.assertTrue(changed)
                self.assertEqual(Path(os.readlink(launcher)), controller)
                state_path = root / "var/lib/vaultwarden-oci/state/update-controller-handoff.json"
                self.assertTrue(state_path.is_file())
                self.assertEqual(state_path.stat().st_mode & 0o777, 0o600)
                state = json.loads(state_path.read_text(encoding="utf-8"))
                self.assertEqual(state["predecessor_release"], _PREDECESSOR)
                self.assertEqual(state["target_release"], _TARGET)
                self.assertEqual(state["controller"], str(controller))

                again = update_controller_handoff.prepare_if_required(
                    _TARGET,
                    source,
                    current_release=_PREDECESSOR,
                    root=root,
                )
                self.assertFalse(again)
                self.assertEqual(staged.call_count, 2)

    def test_active_handoff_refuses_changed_source_under_same_release_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            layout, source, _, _ = self._host(root)
            with mock.patch.object(
                update_controller_handoff.install,
                "stage_release",
                side_effect=self._fake_stage(layout),
            ):
                update_controller_handoff.prepare_if_required(
                    _TARGET,
                    source,
                    current_release=_PREDECESSOR,
                    root=root,
                )

            def reject_changed(_source: Path, _layout: install.Layout, _release: str) -> Path:
                raise install.InstallError(
                    "release already exists with different content; choose a new immutable release version"
                )

            with mock.patch.object(
                update_controller_handoff.install,
                "stage_release",
                side_effect=reject_changed,
            ):
                with self.assertRaisesRegex(install.InstallError, "different content"):
                    update_controller_handoff.prepare_if_required(
                        _TARGET,
                        source,
                        current_release=_PREDECESSOR,
                        root=root,
                    )

    def test_existing_state_with_canonical_launcher_repairs_publication(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            layout, source, launcher, _ = self._host(root)
            controller = layout.path(install.RELEASES_DIR) / _TARGET / "vwctl"
            state_path = root / "var/lib/vaultwarden-oci/state/update-controller-handoff.json"
            state_path.parent.mkdir(parents=True, exist_ok=True)
            state_path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "predecessor_release": _PREDECESSOR,
                        "target_release": _TARGET,
                        "controller": str(controller),
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            state_path.chmod(0o600)

            with mock.patch.object(
                update_controller_handoff.install,
                "stage_release",
                side_effect=self._fake_stage(layout),
            ):
                changed = update_controller_handoff.prepare_if_required(
                    _TARGET,
                    source,
                    current_release=_PREDECESSOR,
                    root=root,
                )
            self.assertTrue(changed)
            self.assertEqual(Path(os.readlink(launcher)), controller)

    def test_non_update_delegates_to_selected_predecessor_but_update_does_not(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            layout, source, _, predecessor_vwctl = self._host(root)
            with mock.patch.object(
                update_controller_handoff.install,
                "stage_release",
                side_effect=self._fake_stage(layout),
            ):
                update_controller_handoff.prepare_if_required(
                    _TARGET,
                    source,
                    current_release=_PREDECESSOR,
                    root=root,
                )
            controller = layout.path(install.RELEASES_DIR) / _TARGET / "vwctl"

            with mock.patch.object(update_controller_handoff.os, "execv") as execv:
                delegated = update_controller_handoff.delegate_non_update_if_handoff(
                    ["doctor", "--json"],
                    root=root,
                    controller_vwctl=controller,
                )
                self.assertTrue(delegated)
                execv.assert_called_once_with(
                    str(predecessor_vwctl),
                    [str(predecessor_vwctl), "doctor", "--json"],
                )

            with mock.patch.object(update_controller_handoff.os, "execv") as execv:
                self.assertFalse(
                    update_controller_handoff.delegate_non_update_if_handoff(
                        ["update", "apply", "--yes"],
                        root=root,
                        controller_vwctl=controller,
                    )
                )
                execv.assert_not_called()

    def test_finalize_only_after_target_is_selected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            layout, source, launcher, _ = self._host(root)
            with mock.patch.object(
                update_controller_handoff.install,
                "stage_release",
                side_effect=self._fake_stage(layout),
            ):
                update_controller_handoff.prepare_if_required(
                    _TARGET,
                    source,
                    current_release=_PREDECESSOR,
                    root=root,
                )
            controller = layout.path(install.RELEASES_DIR) / _TARGET / "vwctl"
            state_path = root / "var/lib/vaultwarden-oci/state/update-controller-handoff.json"

            self.assertFalse(
                update_controller_handoff.finalize_if_target_current(
                    root=root,
                    controller_vwctl=controller,
                )
            )
            self.assertTrue(state_path.exists())

            current = layout.path(install.CURRENT_LINK)
            current.unlink()
            current.symlink_to(Path("releases") / _TARGET)
            self.assertTrue(
                update_controller_handoff.finalize_if_target_current(
                    root=root,
                    controller_vwctl=controller,
                )
            )
            self.assertEqual(Path(os.readlink(launcher)), current / "vwctl")
            self.assertFalse(state_path.exists())

    def test_unexpected_launcher_or_target_source_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, source, launcher, _ = self._host(root)
            launcher.unlink()
            launcher.symlink_to(root / "unexpected-vwctl")
            with self.assertRaisesRegex(UpdateError, "launcher changed outside"):
                update_controller_handoff.prepare_if_required(
                    _TARGET,
                    source,
                    current_release=_PREDECESSOR,
                    root=root,
                )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, source, _, _ = self._host(root)
            _versions(source / "versions.toml", "0.1.0-dev.18")
            with self.assertRaisesRegex(UpdateError, "does not match target"):
                update_controller_handoff.prepare_if_required(
                    _TARGET,
                    source,
                    current_release=_PREDECESSOR,
                    root=root,
                )

    def test_successful_hidden_prepare_requests_one_rerun_before_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, source, _, _ = self._host(root)
            versions = source / "versions.toml"
            with mock.patch.object(
                update_controller_handoff,
                "prepare_if_required",
                return_value=True,
            ) as prepare:
                with self.assertRaisesRegex(
                    update_controller_handoff.HandoffRequired,
                    "rerun the same",
                ):
                    update_controller_handoff.post_command(
                        0,
                        [
                            "__update-candidate",
                            "prepare",
                            "--versions",
                            str(versions),
                            "--render-root",
                            str(root / "render"),
                        ],
                        root=root,
                    )
                prepare.assert_called_once_with(
                    _TARGET,
                    source,
                    current_release=_PREDECESSOR,
                    root=root,
                )

            with mock.patch.object(
                update_controller_handoff,
                "prepare_if_required",
            ) as prepare:
                self.assertEqual(
                    update_controller_handoff.post_command(
                        1,
                        ["__update-candidate", "prepare", "--versions", str(versions)],
                        root=root,
                    ),
                    1,
                )
                prepare.assert_not_called()

    def test_read_only_update_check_never_finalizes_root_handoff(self) -> None:
        with mock.patch.object(
            update_controller_handoff,
            "finalize_if_target_current",
        ) as finalize:
            self.assertEqual(
                update_controller_handoff.post_command(
                    0,
                    ["update", "check", "--json"],
                ),
                0,
            )
            finalize.assert_not_called()

        with mock.patch.object(
            update_controller_handoff,
            "finalize_if_target_current",
        ) as finalize:
            self.assertEqual(
                update_controller_handoff.post_command(
                    0,
                    ["update", "apply", "--yes"],
                ),
                0,
            )
            finalize.assert_called_once()


if __name__ == "__main__":
    unittest.main()
