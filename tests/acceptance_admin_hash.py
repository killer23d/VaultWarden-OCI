#!/usr/bin/env python3
"""Real exact-image acceptance for the Vaultwarden admin credential boundary."""
from __future__ import annotations

import platform
from pathlib import Path

from vaultwarden_oci import admin
from vaultwarden_oci.update_versions import resolve_pinned_file


ROOT = Path(__file__).resolve().parents[1]
TEST_SECRET = "vwoci-acceptance-admin-secret-2026"


def main() -> int:
    frozen = resolve_pinned_file(ROOT / "versions.toml", machine=platform.machine())
    phc = admin.derive_vaultwarden_admin_phc(TEST_SECRET, frozen.vaultwarden_image.reference)
    if not admin.is_vaultwarden_phc(phc):
        raise SystemExit("real Vaultwarden hash boundary did not return an Argon2id PHC")
    if TEST_SECRET in phc:
        raise SystemExit("real Vaultwarden hash boundary exposed the source secret")
    print("PASS: exact pinned Vaultwarden image produced a valid Argon2id admin PHC")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
