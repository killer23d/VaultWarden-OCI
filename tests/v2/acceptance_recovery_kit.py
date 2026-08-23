#!/usr/bin/env python3
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from vaultwarden_oci import recovery_ux


def main() -> int:
    passphrase = "acceptance-only-recovery-passphrase"
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        workspace = root / "plain"
        workspace.mkdir(mode=0o700)
        archive = root / "kit.zip"
        for name in recovery_ux.KIT_MEMBERS:
            (workspace / name).write_text(f"acceptance member {name}\n", encoding="utf-8")
        recovery_ux._seven_required(
            ["7zz", "a", "-tzip", "-mem=AES256", "-p", str(archive), *recovery_ux.KIT_MEMBERS],
            password_input=passphrase,
            cwd=workspace,
            label="acceptance AES-256 ZIP creation",
        )
        recovery_ux.verify_zip(archive, passphrase)
    print("PASS: real 7zz AES-256 ZIP/member/correct-password/wrong-password/empty-password/no-password verification")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
