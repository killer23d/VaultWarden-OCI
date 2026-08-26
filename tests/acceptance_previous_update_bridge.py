#!/usr/bin/env python3
"""Prove the immediately preceding installed updater can consume this source tree."""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

# CI intentionally supplies PYTHONPATH for the immutable immediately preceding
# release. These imports must therefore resolve to predecessor code, not HEAD.
from vaultwarden_oci import install, update  # type: ignore[import-not-found]


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: acceptance_previous_update_bridge.py CANDIDATE_SOURCE")
    candidate = Path(sys.argv[1]).resolve()

    # This is the exact pre-candidate-code source gate used by the predecessor
    # project updater. It must accept the release source before new code runs.
    update._validate_source(candidate)

    with tempfile.TemporaryDirectory(prefix="vwoci-previous-updater-") as directory:
        root = Path(directory) / "host"
        installed = Path(
            install.install_layout(
                candidate,
                root=root,
                systemd_reload=False,
                require_all_architectures=True,
            )
        )
        manifest = install.load_versions(candidate / "versions.toml")
        if installed.name != manifest.version:
            raise SystemExit("predecessor updater staged the wrong immutable release identity")
        historical_units = installed / install.SYSTEMD_SOURCE_DIR
        if not historical_units.is_dir():
            raise SystemExit("predecessor updater did not stage its required systemd source layout")
        missing = [unit for unit in install.SYSTEMD_UNITS if not (historical_units / unit).is_file()]
        if missing:
            raise SystemExit("predecessor updater staged incomplete systemd units: " + ", ".join(missing))
        current = install.Layout(root).path(install.CURRENT_LINK)
        if not current.is_symlink():
            raise SystemExit("predecessor updater did not publish a current release selector")

    print("PASS: immediately preceding updater accepts and stages candidate source")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
