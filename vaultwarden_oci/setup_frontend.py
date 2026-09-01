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

from . import notification, recovery_ux, runtime, secrets, setup, sevenzip_secure

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


def _ui() -> setup.UI:
    return setup.UI(color=sys.stdout.isatty() and not os.environ.get("NO_COLOR"))


def _generate_offline_identity(root: Path = SENSITIVE_RUN) -> tuple[Path, Path, str]:
    recovery_ux._safe_private_dir(root)
    workspace = Path(tempfile.mkdtemp(prefix="setup-offline-recovery-", dir=str(root)))
    completed = False
    try:
        os.chmod(workspace, 0o700)
        identity = workspace / "offline-age-identity.txt"
        result = recovery_ux.recovery.run_command(["age-keygen", "-o", str(identity)])
        if not result.ok:
            raise SetupFrontendError("offline recovery Age identity generation failed")
        os.chmod(identity, 0o600)
        recipient = secrets.derive_recipient(identity)
        completed = True
        return workspace, identity, recipient
    finally:
        if not completed:
            recovery_ux._cleanup_workspace(workspace)


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
    _ui().warn(warning, file=sys.stderr)
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
    ui = _ui()
    ui.action(f"Copy the verified encrypted recovery kit off-host now: {result.archive}")
    ui.action("Keep its ZIP passphrase separately from the archive.")
    ui.info("If connected over SSH, leave this prompt open and use a second terminal with scp/sftp to copy the ZIP before typing SAVED.")
    try:
        answer = input("Type SAVED after the recovery-kit ZIP is in off-host operator custody: ").strip()
    except EOFError as exc:
        raise SetupFrontendError("off-host recovery-kit custody was not acknowledged") from exc
    if answer != "SAVED":
        raise SetupFrontendError("off-host recovery-kit custody was not acknowledged; the transient offline identity is being retained")


def _complete_external_credentials_before_handoff() -> None:
    ui = _ui()
    config = runtime.load_config()
    secret_paths = runtime.Paths().secret_paths()
    try:
        secrets.validate_encrypted(config.offline_recovery_recipient, paths=secret_paths)
        secrets_ready = True
    except secrets.SecretsError:
        secrets_ready = False
    config_ready = config.smtp_host != "smtp.invalid"
    if config_ready and secrets_ready:
        ui.ok("External runtime config and required SOPS credentials already validate before recovery-kit publication.")
        return

    ui.header("External credentials before recovery handoff")
    ui.info("Complete the credentials first so the initial recovery kit contains the final required credential set and authenticated SMTP delivery is available.")
    if not config_ready:
        ui.action("The validated config editor will open now. Replace smtp.invalid and complete the [smtp] settings. Operational HTTPS notifications are optional and can be configured after first-run custody.")
        runtime.edit_config()
        config = runtime.load_config()
        if config.smtp_host == "smtp.invalid":
            raise SetupFrontendError("SMTP configuration still uses smtp.invalid; complete [smtp] before initial recovery-kit handoff")

    if not secrets_ready:
        ui.action(
            "The validated SOPS editor will open now. Fill required cloudflare_api_token, smtp_username, and smtp_password. "
            "Optional cloudflare_remediation_token and email_api_token are pre-populated and may remain empty unless those features are enabled; "
            "keep the generated admin credentials unchanged unless intentionally rotating them."
        )
        secrets.edit_encrypted(
            config.offline_recovery_recipient,
            paths=runtime.Paths().secret_paths(),
        )

    config = runtime.load_config()
    if config.smtp_host == "smtp.invalid":
        raise SetupFrontendError("SMTP configuration still uses smtp.invalid; complete [smtp] before initial recovery-kit handoff")
    secrets.validate_encrypted(
        config.offline_recovery_recipient,
        paths=runtime.Paths().secret_paths(),
    )
    ui.ok("External runtime config and required SOPS credentials validate before recovery-kit publication.")


def _print_post_handoff_next_actions(*, credentials_ready: bool = True) -> None:
    """Print the supported first-run path in the order a fresh host can satisfy it."""
    ui = _ui()
    ui.header("Next actions")
    if not credentials_ready:
        ui.action("complete remaining Cloudflare/SMTP credentials with: sudo vwctl config edit && sudo vwctl secrets edit")
    ui.action("run: sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml")
    ui.action("run: sudo vwctl secrets validate")
    ui.action("run: sudo vwctl notification test --smtp to verify the shared SMTP transport")
    ui.action("run: sudo vwctl crowdsec setup")
    ui.action("run: sudo vwctl crowdsec remediation-start")
    ui.action("set every bouncer-created Worker Route to Fail Open in Cloudflare")
    ui.action("then run: sudo vwctl crowdsec confirm-fail-open")
    ui.action("run: sudo vwctl start")
    ui.action("run: sudo vwctl backup to create and verify the first application recovery point")
    ui.action("run: sudo vwctl doctor after start has materialized the runtime and Cloudflare origin policy")
    ui.action("enable persistent automation with: sudo systemctl enable --now vaultwarden-oci.target")
    ui.action("run: sudo vwctl timers")
    ui.action("run: sudo vwctl update check to seed the initial update-status snapshot")
    ui.info("A post-start doctor WARN for unconfigured offsite/rclone recovery is expected until offsite application recovery is configured; any FAIL still requires action.")


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    ui = _ui()
    if args[:1] == ["recovery-kit"]:
        return recovery_ux.main(args)
    if not _confirm_use_latest(args):
        ui.action("setup cancelled before installation changes", file=sys.stderr)
        return 2
    if not _should_generate(args):
        parsed = _parse_install_args(args)
        if parsed is None or parsed.dry_run:
            return setup.main(args)
        code = setup.main(args, defer_next_actions=True)
        if code == 0:
            _print_post_handoff_next_actions(credentials_ready=False)
        return code

    workspace: Path | None = None
    identity: Path | None = None
    try:
        def provide_offline_recipient() -> str:
            nonlocal workspace, identity
            ui.info("Generating the separate offline Age identity in root-only volatile /run storage.")
            ui.info("Its public recipient will be configured on the server; the private identity will only enter the encrypted recovery kit.")
            workspace, identity, recipient = _generate_offline_identity()
            return recipient

        code = setup.main(
            args,
            offline_recipient_factory=provide_offline_recipient,
            defer_next_actions=True,
        )
        if code != 0:
            if identity is not None and identity.exists():
                ui.action(
                    f"Setup did not complete. The generated offline identity remains temporarily at {identity}; "
                    "secure it before reboot if config/secrets were already written.",
                    file=sys.stderr,
                )
            return code
        if workspace is None or identity is None:
            raise SetupFrontendError("setup completed without producing the requested offline recovery identity")

        _complete_external_credentials_before_handoff()
        ui.header("Initial credential recovery-kit handoff")
        result = recovery_ux.export_recovery_kit(identity)
        ui.ok(f"Verified complete recovery kit: {result.archive}")
        if result.emailed:
            ui.ok("Verified recovery-kit email handoff completed successfully.")
        _confirm_local_handoff(result)
        _cleanup_generated(workspace)
        if workspace.exists() or identity.exists():
            raise SetupFrontendError("offline identity remained in volatile server state after successful recovery-kit handoff")
        ui.ok("Offline recovery private identity removed from host-side volatile workspace after successful handoff.")
        ui.action("Store the encrypted recovery-kit ZIP and its separately remembered passphrase off-host.")
        _print_post_handoff_next_actions(credentials_ready=True)
        return 0
    except (
        SetupFrontendError,
        notification.NotificationError,
        recovery_ux.RecoveryUXError,
        runtime.RuntimeConfigError,
        secrets.SecretsError,
        sevenzip_secure.SevenZipError,
        OSError,
    ) as exc:
        ui.fail(f"initial recovery custody handoff failed: {exc}", file=sys.stderr)
        if identity is not None and identity.exists():
            ui.action(
                f"The offline private identity remains only in volatile root-only storage at {identity}; "
                "secure it before reboot, then retry recovery-kit export.",
                file=sys.stderr,
            )
            if setup.CONFIG.exists() and setup.ENCRYPTED.exists():
                ui.action("Complete external credentials with: sudo vwctl config edit && sudo vwctl secrets edit", file=sys.stderr)
                ui.action(
                    f"Then export the complete kit with: sudo vwctl recovery-kit export --offline-identity {identity}",
                    file=sys.stderr,
                )
                ui.action(
                    f"Remove {identity.parent} only after the verified kit is in off-host custody.",
                    file=sys.stderr,
                )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
