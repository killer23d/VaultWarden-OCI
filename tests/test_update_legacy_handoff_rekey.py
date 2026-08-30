from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import install, update_controller_handoff, update_versions

_PREDECESSOR = "0.1.0-dev.16.latest.aaaaaaaaaaaa"
_LEGACY_TARGET = "0.1.0-dev.17.latest.fe96c65498dd"


def _digest(char: str) -> str:
    return "sha256:" + char * 64


def _legacy_frozen_versions() -> str:
    return f'''schema_version = 1

[vaultwarden_oci]
version = "{_LEGACY_TARGET}"

[components]
vaultwarden = "1.37.2"
caddy = "2.11.4"
caddy_dns_cloudflare = "v0.2.4"
caddy_cloudflare_ip = "f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5"
caddy_combine_ip_ranges = "v0.0.1"
caddy_ratelimit = "v0.1.0"

[image_digests.vaultwarden]
amd64 = "{_digest('a')}"

[image_digests.caddy_builder]
amd64 = "{_digest('b')}"

[image_digests.caddy_runtime]
amd64 = "{_digest('c')}"
'''


class LegacyHandoffRekeyTests(unittest.TestCase):
    def test_legacy_latest_handoff_is_rekeyed_and_republished_before_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
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

            legacy = releases / _LEGACY_TARGET
            legacy.mkdir(parents=True)
            legacy_vwctl = legacy / "vwctl"
            legacy_vwctl.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            legacy_vwctl.chmod(0o555)

            launcher = layout.path(install.VWCTL_LINK)
            launcher.parent.mkdir(parents=True, exist_ok=True)
            launcher.symlink_to(legacy_vwctl)

            state_path = root / "var/lib/vaultwarden-oci/state/update-controller-handoff.json"
            state_path.parent.mkdir(parents=True, exist_ok=True)
            state_path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "predecessor_release": _PREDECESSOR,
                        "target_release": _LEGACY_TARGET,
                        "controller": str(legacy_vwctl),
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            state_path.chmod(0o600)

            source = root / "candidate"
            source.mkdir()
            versions = source / "versions.toml"
            versions.write_text(_legacy_frozen_versions(), encoding="utf-8")
            (source / "vwctl").write_text("#!/usr/bin/env python3\nprint('corrected')\n", encoding="utf-8")
            (source / "vwctl").chmod(0o755)

            corrected = update_versions.rekey_latest_frozen_source(
                source,
                versions,
                machine="amd64",
            )
            self.assertNotEqual(corrected.project_version, _LEGACY_TARGET)
            corrected_controller = releases / corrected.project_version / "vwctl"

            def stage(_source: Path, actual_layout: install.Layout, release: str) -> Path:
                self.assertEqual(actual_layout.root, layout.root)
                self.assertEqual(release, corrected.project_version)
                staged = releases / release
                staged.mkdir(parents=True, exist_ok=True)
                controller = staged / "vwctl"
                if not controller.exists():
                    controller.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                    controller.chmod(0o555)
                return staged

            with (
                mock.patch.object(update_controller_handoff.install, "stage_release", side_effect=stage),
                mock.patch.object(
                    update_controller_handoff.update_versions,
                    "rekey_latest_frozen_source",
                    wraps=lambda source_root, versions_path: update_versions.rekey_latest_frozen_source(
                        source_root,
                        versions_path,
                        machine="amd64",
                    ),
                ),
            ):
                changed = update_controller_handoff._prepare_handoff_from_candidate_versions(
                    versions,
                    root=root,
                )

            self.assertTrue(changed)
            self.assertEqual((layout.path(install.CURRENT_LINK).resolve()).name, _PREDECESSOR)
            self.assertTrue(legacy_vwctl.exists())
            self.assertEqual(Path(os.readlink(launcher)), corrected_controller)
            state = json.loads(state_path.read_text(encoding="utf-8"))
            self.assertEqual(state["predecessor_release"], _PREDECESSOR)
            self.assertEqual(state["target_release"], corrected.project_version)
            self.assertEqual(state["controller"], str(corrected_controller))


if __name__ == "__main__":
    unittest.main()
