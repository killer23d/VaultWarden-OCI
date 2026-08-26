#!/usr/bin/env python3
from pathlib import Path

path = Path("tests/test_update_interrupt_safety.py")
text = path.read_text(encoding="utf-8")
replacements = {
    "update_unit_migration.update._atomic_write": "update_unit_migration.durability.atomic_write",
    "update_unit_migration.update,\n                    \"_atomic_write\"": "update_unit_migration.durability,\n                    \"atomic_write\"",
}
for old, new in replacements.items():
    if old not in text:
        raise SystemExit(f"expected test owner reference not found: {old!r}")
    text = text.replace(old, new)
path.write_text(text, encoding="utf-8")
print("unit migration interruption tests now patch durability owner")
