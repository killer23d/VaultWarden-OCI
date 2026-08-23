"""First-run wrapper for transient offline recovery identity handoff.

The existing setup.py remains the installation owner. This wrapper only adds the
human custody step that must span initial setup and recovery-kit publication.
"""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Sequence

from . import recovery_ux, secrets, setup, sevenzip_secure

SENSITIVE_RUN = recovery_ux.SENSITIVE_RUN
_ORIGINAL_SETUP_RUN = setup._run
recovery_ux._seven = sevenzip_secure.run


class SetupFrontendError(RuntimeError):
    pass


def _setup_run_7zip_compat(argv: Sequence[str]):
    """Let setup verify Ubuntu's 7zip package whether it exposes 7zz or 7z."""
    command = list(argv)
    if command and command[0] == "7zz" and shutil.which("7zz") is None:
        seven = shutil.which("7z")
        if seven is not None:
            command[0] = seven
    return _ORIGINAL_SETUP_RUN(command)


setup._run = _setup_run_7zip_compat


def _ensure_7zz_alias() -> None:
    if shutil.which("7zz") is not None or os.geteuid() != 0:
        return
    seven = shutil.which("7z")
    if seven is None:
        raise SetupFrontendError("Ubuntu 7zip was installed but neither 7zz nor 7z is available")
    alias = Path("/usr/local/bin/7zz")
    if alias.exists() or alias.is_symlink():
        if alias.is_symlink() and alias.resolve() == Path(seven).resolve():
            return
        raise SetupFrontendError(f"refusing to replace unexpected 7zz compatibility path: {alias}")
    alias.symlink_to(seven)
    if shutil.which("7zz") is None:
        raise SetupFrontendError("failed to expose Ubuntu 7zip as 7zz for recovery-kit tooling")


def _generate_offline_identity(root: Path = SENSITIVE_RUN) -> tuple[Path, Path, str]:
    recovery_ux._safe_private_dir(root)
    workspace = Path(tempfile.mkdtemp(prefix="setup-offline-recovery-", dir=str(root)))
    os.chmod(workspace, 0o700)
    identity = workspace / "offline-age-identity.txt"
    result = recovery_ux.recovery.run_command(["age-keygen", "-o", str(identity)])
    if not result.ok:
        shutil.rmtree(workspace, ignore_errors=True)
        raise SetupFrontendError("offline recovery Age identity generation failed")
    os.chmod(identity, 0o600)
    recipient = secrets.derive_recipient(identity)
    return workspace, identity, recipient


def _cleanup_generated(workspace: Path) -> None:
    recovery_ux._cleanup_workspace(workspace)


def _should_generate(args: Sequence[str]) -> bool:
    return (
        bool(args)
        and args[0] == "install"
        and "--offline-recipient" not in args
        and "--auto" not in args
        and "--dry-run" not in args
        and sys.stdin.isatty()
    )


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args[:1] == ["recovery-kit"]:
        return recovery_ux.main(args)
    if not _should_generate(args):
        code = setup.main(args)
        if code == 0 and args[:1] == ["install"] and "--dry-run" not in args:
            try:
                _ensure_7zz_alias()
            except SetupFrontendError as exc:
                print(f"FAIL: {exc}", file=sys.stderr)
                return 1
        return code

    workspace: Path | None = None
    identity: Path | None = None
    try:
        print("\n== Offline recovery custody ==")
        print("INFO Generating the separate offline Age identity in root-only volatile /run storage.")
        print("INFO Its public recipient will be configured on the server; the private identity will only enter the encrypted recovery kit.")
        workspace, identity, recipient = _generate_offline_identity()
        code = setup.main([*args, "--offline-recipient", recipient])
        if code != 0:
            print(
                f"ACTION Setup did not complete. The generated offline identity remains temporarily at {identity}; "
                "secure it before reboot if config/secrets were already written.",
                file=sys.stderr,
            )
            return code
        _ensure_7zz_alias()

        print("\n== Initial credential recovery-kit handoff ==")
        result = recovery_ux.export_recovery_kit(identity)
        print(f"PASS Verified complete recovery kit: {result.archive}")
        _cleanup_generated(workspace)
        if workspace.exists() or identity.exists():
            raise SetupFrontendError("offline identity remained in volatile server state after successful recovery-kit handoff")
        print("PASS Offline recovery private identity removed from host-side volatile workspace after successful handoff.")
        print("ACTION Store the encrypted recovery-kit ZIP and its separately remembered passphrase off-host.")
        return 0
    except (SetupFrontendError, recovery_ux.RecoveryUXError, secrets.SecretsError, OSError) as exc:
        print(f"FAIL: initial recovery custody handoff failed: {exc}", file=sys.stderr)
        if identity is not None and identity.exists():
            print(
                f"ACTION The offline private identity remains only in volatile root-only storage at {identity}; "
                "secure it before reboot, then retry recovery-kit export.",
                file=sys.stderr,
            )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
