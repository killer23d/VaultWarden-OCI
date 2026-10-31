#!/usr/bin/env python3
"""D2: verify rc.12's actual encrypted ZIP path on a disposable installed host.

Run from an interactive terminal with sudo and a mode-0600 encrypted recovery
ZIP at an absolute path OUTSIDE /root/vaultwarden-recovery. This verifies real
AES-256 ZIP decryption and matching offline Age identity in protected /run,
then checks plaintext cleanup. It never starts a restore or prints the key.
"""
from __future__ import annotations

import os
import pathlib
import stat
import sys
from unittest import mock


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: sudo -n python3 25-rc12-real-encrypted-kit-path.py /absolute/encrypted-kit.zip", file=sys.stderr)
        return 2
    if os.geteuid() != 0 or not sys.stdin.isatty() or not sys.stdout.isatty():
        print("BLOCKED: root and interactive terminal are required", file=sys.stderr)
        return 2
    release = pathlib.Path("/opt/vaultwarden-oci/current")
    if release.resolve(strict=True) != pathlib.Path("/opt/vaultwarden-oci/releases/0.1.0-rc.12"):
        print("BLOCKED: installed rc.12 release required", file=sys.stderr)
        return 2
    source = pathlib.Path(sys.argv[1])
    if not source.is_absolute() or source.suffix.lower() != ".zip":
        print("BLOCKED: provide one absolute encrypted ZIP path", file=sys.stderr)
        return 2
    if str(source).startswith("/root/vaultwarden-recovery/"):
        print("BLOCKED: test requires the ZIP OUTSIDE the default chooser folder", file=sys.stderr)
        return 2
    info = source.lstat()
    if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600:
        print("BLOCKED: ZIP must be a regular (not symlink) mode-0600 file", file=sys.stderr)
        return 2

    sys.path.insert(0, str(release))
    from vaultwarden_oci import recovery_ux, runtime, secrets

    config = runtime.load_config()
    sensitive = recovery_ux.SENSITIVE_RUN
    before = set(p.name for p in sensitive.glob("offline-identity-*")) if sensitive.exists() else set()
    try:
        with mock.patch("builtins.input", side_effect=["4", str(source)]):
            with recovery_ux.acquire_offline_identity(
                config.offline_recovery_recipient,
                publication_dir=pathlib.Path("/root/vaultwarden-recovery/absent-d2-chooser"),
                sensitive_root=sensitive,
                ui=recovery_ux.UI(color=False),
            ) as identity:
                if identity is None:
                    raise RuntimeError("offline identity chooser cancelled unexpectedly")
                if not identity.exists() or stat.S_IMODE(identity.stat().st_mode) != 0o600:
                    raise RuntimeError("temporary decrypted private identity is not mode 0600")
                if secrets.derive_recipient(identity) != config.offline_recovery_recipient:
                    raise RuntimeError("offline identity does not match the recovered public recipient")
        after = set(p.name for p in sensitive.glob("offline-identity-*"))
        if before != after:
            raise RuntimeError("private transient workspace not cleaned")
    except Exception as exc:
        print("BLOCKED: real encrypted kit path acceptance failed: " + type(exc).__name__, file=sys.stderr)
        return 1
    print("PASS: option 4 selected an encrypted ZIP outside the default publication directory")
    print("PASS: AES-256 recovery-kit ZIP verified; offline Age identity matched")
    print("PASS: volatile extracted identity and staged ciphertext cleaned")
    print("NOT RUN: actual restoration, Box activity, app startup, Cloudflare DNS/Worker or reboot")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
