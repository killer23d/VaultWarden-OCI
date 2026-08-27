"""First-run wrapper for transient offline recovery identity handoff.

The existing setup.py remains the installation owner. This wrapper adds the
human custody step and the supported, explicitly confirmed --use-latest UX.
"""
from __future__ import annotations

import contextlib
import io
import os
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Sequence

from . import notification, recovery_ux, secrets, setup, sevenzip_secure

SENSITIVE_RUN = recovery_ux.SENSITIVE_RUN
_ORIGINAL_SETUP_RUN = setup._run



class SetupFrontendError(RuntimeError):
    pass


def _setup_run_7zip_compat(argv: Sequence[str], *, input_text=None, env=None):
    """Preserve setup._run's full call contract while accepting Ubuntu's 7z name."""
    command = list(argv)
    if command and command[0] == "7zz" and shutil.which("7zz") is None:
        seven = shutil.which("7z")
        if seven is not None:
            command[0] = seven
    return _ORIGINAL_SETUP_RUN(command, input_text=input_text, env=env)


setup._run = _setup_run_7zip_compat


def _generate_offline_identity(root: Path = SENSITIVE_RUN) -> tuple[Path, Path, str]:
    recovery_ux._safe_private_dir(root)
    workspace = Path(tempfile.mkdtemp(prefix="setup-offline-recovery-", dir=str(root)))
    os.chmod(workspace, 0o700)
    identity = workspace / "offline-age-identity.txt"
    result = recovery_ux.recovery.run_command(["age-keygen", "-o", str(identity)])
    if not result.ok:
        recovery_ux._cleanup_workspace(workspace)
        raise SetupFrontendError("offline recovery Age identity generation failed")
    os.chmod(identity, 0o600)
    recipient = secrets.derive_recipient(identity)
    return workspace, identity, recipient


def _cleanup_generated(workspace: Path) -> None:
    recovery_ux._cleanup_workspace(workspace)


def _parse_install_args(args: Sequence[str]):
    """Parse setup install argv with the authoritative argparse grammar.

    Parsing failures are deliberately silent here because setup.main remains the
    owner of user-facing CLI errors. This seam exists only so custody decisions
    cannot disagree with argparse over split, equals, or abbreviated long forms.
    """
    if not args or args[0] != "install":
        return None
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return setup._parser().parse_args(list(args))
    except SystemExit:
        return None


def _should_generate(args: Sequence[str]) -> bool:
    parsed = _parse_install_args(args)
    return bool(
        parsed is not None
        and parsed.offline_recipient is None
        and not parsed.dry_run
        and sys.stdin.isatty()
    )


def _confirm_use_latest(args: Sequence[str]) -> bool:
    parsed = _parse_install_args(args)
    if parsed is None or not parsed.use_latest:
        return True
    warning = (
        "--use-latest bypasses the project's tested release pins. Vaultwarden, Caddy, all xcaddy addon refs, "
        "and architecture image digests will be resolved once and frozen exactly for this install."
    )
    if sys.stderr.isatty() and not os.environ.get("NO_COLOR"):
        print(f"\033[33mWARN\033[0m {warning}", file=sys.stderr)
    else:
        print(f"WARN {warning}", file=sys.stderr)
    if parsed.auto or not sys.stdin.isatty():
        return True
    try:
        answer = input("Continue with this untested exact upstream snapshot? [y/N]: ").strip().lower()
    except EOFError:
        return False
    return answer in {"y", "yes"}


def _confirm_local_handoff(result: recovery_ux.KitResult) -> None:
    if result.emailed:
        return
    print(f"ACTION Copy the verified encrypted recovery kit off-host now: {result.archive}")
    print("ACTION Keep its ZIP passphrase separately from the archive.")
    try:
        answer = input("Type SAVED after the recovery-kit ZIP is in off-host operator custody: ").strip()
    except EOFError as exc:
        raise SetupFrontendError("off-host recovery-kit custody was not acknowledged") from exc
    if answer != "SAVED":
        raise SetupFrontendError("off-host recovery-kit custody was not acknowledged; the transient offline identity is being retained")


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args[:1] == ["recovery-kit"]:
        return recovery_ux.main(args)
    if not _confirm_use_latest(args):
        print("ACTION setup cancelled before installation changes", file=sys.stderr)
        return 2
    if not _should_generate(args):
        return setup.main(args)

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

        print("\n== Initial credential recovery-kit handoff ==")
        result = recovery_ux.export_recovery_kit(identity)
        print(f"PASS Verified complete recovery kit: {result.archive}")
        _confirm_local_handoff(result)
        _cleanup_generated(workspace)
        if workspace.exists() or identity.exists():
            raise SetupFrontendError("offline identity remained in volatile server state after successful recovery-kit handoff")
        print("PASS Offline recovery private identity removed from host-side volatile workspace after successful handoff.")
        print("ACTION Store the encrypted recovery-kit ZIP and its separately remembered passphrase off-host.")
        return 0
    except (
        SetupFrontendError,
        notification.NotificationError,
        recovery_ux.RecoveryUXError,
        secrets.SecretsError,
        sevenzip_secure.SevenZipError,
        OSError,
    ) as exc:
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
