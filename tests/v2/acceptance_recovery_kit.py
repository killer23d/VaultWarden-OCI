#!/usr/bin/env python3
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from vaultwarden_oci import recovery_ux, sevenzip_secure

recovery_ux._seven = sevenzip_secure.run


def main() -> int:
    passphrase = "acceptance-only-recovery-passphrase"
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        workspace = root / "plain"
        workspace.mkdir(mode=0o700)
        archive = root / "kit.zip"
        for name in recovery_ux.KIT_MEMBERS:
            (workspace / name).write_text(f"acceptance member {name}\n", encoding="utf-8")
        created = sevenzip_secure.run(
            ["7zz", "a", "-tzip", "-mem=AES256", "-p", str(archive), *recovery_ux.KIT_MEMBERS],
            password_input=passphrase,
            cwd=workspace,
        )
        if created.returncode != 0:
            print("CREATE OUTPUT (secret-redacted):")
            print(created.stdout)
            raise RuntimeError(f"AES-256 ZIP creation failed with exit {created.returncode}")
        tested = sevenzip_secure.run(
            ["7zz", "t", "-p", str(archive)],
            password_input=passphrase,
        )
        if tested.returncode != 0:
            print("TEST OUTPUT (secret-redacted):")
            print(tested.stdout)
            raise RuntimeError(f"correct-password ZIP test failed with exit {tested.returncode}")
        recovery_ux.verify_zip(archive, passphrase)
    print("PASS: real 7zz stdin AES-256 ZIP/member/correct-password/wrong-password/empty-password/no-password verification")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
