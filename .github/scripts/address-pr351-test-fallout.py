#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def edit(path: str, old: str, new: str) -> None:
    target = ROOT / path
    text = target.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"expected text not found in {path}: {old!r}")
    target.write_text(text.replace(old, new, 1), encoding="utf-8")


# DoctorCheck's public fields are check_id/status/message.
edit(
    "tests/test_runtime.py",
    'next(check for check in checks if check.id == "secrets.decrypt")',
    'next(check for check in checks if check.check_id == "secrets.decrypt")',
)
edit(
    "tests/test_runtime.py",
    'self.assertEqual(decrypt.detail, "required appliance secrets decrypt")',
    'self.assertEqual(decrypt.message, "required appliance secrets decrypt")',
)
edit(
    "tests/test_runtime.py",
    'next(check for check in checks if check.id == "secrets.decrypt")',
    'next(check for check in checks if check.check_id == "secrets.decrypt")',
)
edit(
    "tests/test_runtime.py",
    'self.assertEqual(decrypt.detail, "required cloudflare_remediation_token is missing")',
    'self.assertEqual(decrypt.message, "required cloudflare_remediation_token is missing")',
)

# Current-selection durability belongs to the supported appliance updater now.
edit(
    "tests/test_update_durability.py",
    "from vaultwarden_oci import durability, install, update, update_guard, update_recovery",
    "from vaultwarden_oci import durability, install, update_appliance, update_guard, update_recovery",
)
edit(
    "tests/test_update_durability.py",
    'update._switch(layout, Path("releases/2.0.0"))',
    'update_appliance._switch_current(layout, Path("releases/2.0.0"))',
)

# Frozen-version serialization is owned by update_versions, not update.py.
edit(
    "tests/test_update_workflow.py",
    "snapshot = update.frozen_versions_toml(frozen)",
    "snapshot = update_versions.frozen_versions_toml(frozen)",
)

print("PR 351 test fallout fixes applied")
