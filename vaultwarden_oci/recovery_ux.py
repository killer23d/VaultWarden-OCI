"""Human recovery inventory/restore UX and credential recovery-kit handoff.

The encrypted application-recovery transaction remains owned by recovery.py.
This module adds human selection/verification and the separate credential kit.
"""
from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import shutil
import stat
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Mapping, Sequence

from . import notification, recovery, runtime, secrets, sevenzip_secure, storage

PUBLICATION_DIR = Path("/root/vaultwarden-recovery")
SENSITIVE_RUN = Path("/run/vaultwarden-oci")
KIT_MEMBERS = (
    "README.txt",
    "config.toml",
    "credentials.txt",
    "operational-age-identity.txt",
    "offline-recovery-identity.txt",
)
_RECOVERY_NAME = re.compile(r"recovery-(\d{8}T\d{6}Z)-[A-Za-z0-9]+\.vwrec$")
_LABELS = {
    "vaultwarden_admin_token": "Vaultwarden admin token",
    "admin_basic_auth_password": "Caddy admin Basic Auth password",
    "cloudflare_api_token": "Cloudflare API token",
    "cloudflare_remediation_token": "Cloudflare remediation token",
    "email_api_token": "Operational email API token",
    "smtp_username": "SMTP username",
    "smtp_password": "SMTP password",
}


class RecoveryUXError(RuntimeError):
    pass


@dataclass(frozen=True)
class RecoveryPoint:
    source: str
    name: str
    location: str
    size: int
    created_at: str
    verification: str


@dataclass(frozen=True)
class KitResult:
    archive: Path
    members: tuple[str, ...]
    emailed: bool


class UI:
    def __init__(self, *, color: bool | None = None) -> None:
        if color is None:
            color = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
        self.color = color

    def _line(self, label: str, text: str, code: str) -> None:
        prefix = f"\033[{code}m{label}\033[0m" if self.color else label
        print(f"{prefix} {text}")

    def header(self, text: str) -> None:
        print(f"\n== {text} ==")

    def ok(self, text: str) -> None:
        self._line("PASS", text, "32")

    def warn(self, text: str) -> None:
        self._line("WARN", text, "33")

    def info(self, text: str) -> None:
        self._line("INFO", text, "36")

    def action(self, text: str) -> None:
        self._line("ACTION", text, "34")


def _created_from_name(name: str, fallback: datetime | None = None) -> str:
    match = _RECOVERY_NAME.search(name)
    if match:
        try:
            value = datetime.strptime(match.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
            return value.isoformat().replace("+00:00", "Z")
        except ValueError:
            pass
    value = fallback or datetime.fromtimestamp(0, timezone.utc)
    return value.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _sort_key(point: RecoveryPoint) -> tuple[str, str]:
    return point.created_at, point.name


def _known_verifications(paths: recovery.RecoveryPaths) -> dict[str, Mapping[str, object]]:
    state = recovery._load_state(paths.state_file)
    known: dict[str, Mapping[str, object]] = {}
    for key in ("local", "offsite"):
        item = state.get(key)
        if isinstance(item, dict):
            location = item.get("artifact") or item.get("remote_object")
            if isinstance(location, str) and isinstance(item.get("verified_at"), str):
                known[location] = item
    verified = state.get("verified_objects")
    if isinstance(verified, dict):
        for location, item in verified.items():
            if isinstance(location, str) and isinstance(item, dict) and isinstance(item.get("verified_at"), str):
                known[location] = item
    return known


def _verification_for(location: str, size: int, known: Mapping[str, Mapping[str, object]]) -> str:
    item = known.get(location)
    if item is None:
        return "unknown"
    recorded_size = item.get("size")
    if isinstance(recorded_size, int) and recorded_size != size:
        return "changed"
    # Inventory intentionally does not hash/download every artifact. A matching
    # recorded size therefore proves only that this location was verified in the
    # past, not that its current bytes are still identical. `recovery verify`
    # performs the current cryptographic verification.
    return "previously-verified"


def list_local(paths: recovery.RecoveryPaths = recovery.RecoveryPaths()) -> list[RecoveryPoint]:
    paths.backups.mkdir(parents=True, exist_ok=True)
    known = _known_verifications(paths)
    points: list[RecoveryPoint] = []
    for artifact in paths.backups.glob("*.vwrec"):
        try:
            info = artifact.lstat()
        except OSError:
            continue
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            continue
        location = str(artifact)
        points.append(
            RecoveryPoint(
                "local",
                artifact.name,
                location,
                info.st_size,
                _created_from_name(artifact.name, datetime.fromtimestamp(info.st_mtime, timezone.utc)),
                _verification_for(location, info.st_size, known),
            )
        )
    return sorted(points, key=_sort_key, reverse=True)


def list_remote_points(
    remote: str,
    *,
    paths: recovery.RecoveryPaths = recovery.RecoveryPaths(),
    runner: recovery.Runner = recovery.run_command,
) -> list[RecoveryPoint]:
    known = _known_verifications(paths)
    points: list[RecoveryPoint] = []
    for item in recovery.list_remote(remote, runner=runner):
        raw_name = item.get("Path") if isinstance(item.get("Path"), str) else item.get("Name")
        if not isinstance(raw_name, str) or not raw_name.endswith(".vwrec"):
            continue
        name = Path(raw_name).name
        size = item.get("Size", 0)
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            size = 0
        modtime = item.get("ModTime")
        created = _created_from_name(name)
        if not _RECOVERY_NAME.search(name) and isinstance(modtime, str):
            created = modtime
        location = recovery._remote_object(remote, raw_name)
        points.append(
            RecoveryPoint(
                "remote",
                name,
                location,
                size,
                created,
                _verification_for(location, size, known),
            )
        )
    return sorted(points, key=_sort_key, reverse=True)


def _human_size(size: int) -> str:
    value = float(size)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024 or unit == "TiB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{size} B"


def print_inventory(points: Sequence[RecoveryPoint]) -> None:
    if not points:
        print("  (none)")
        return
    for index, point in enumerate(points, 1):
        print(
            f"  {index}) {point.created_at}  {_human_size(point.size):>10}  "
            f"{point.verification:<19}  {point.location}"
        )


def _record_verification(
    location: str,
    verified: recovery.VerifiedRecovery,
    *,
    paths: recovery.RecoveryPaths,
) -> None:
    state = recovery._load_state(paths.state_file)
    objects = state.get("verified_objects")
    if not isinstance(objects, dict):
        objects = {}
    objects[location] = {
        "verified_at": recovery._utc_now(),
        "created_at": verified.created_at,
        "sha256": verified.sha256,
        "size": verified.size,
    }
    state["schema_version"] = 1
    state["verified_objects"] = objects
    recovery._atomic_json(paths.state_file, state)


def verify_local(
    artifact: Path,
    identity: Path,
    *,
    paths: recovery.RecoveryPaths = recovery.RecoveryPaths(),
    runner: recovery.Runner = recovery.run_command,
    state_location: str | None = None,
    record: bool = True,
) -> recovery.VerifiedRecovery:
    paths.backups.mkdir(parents=True, exist_ok=True)
    recovery._ensure_regular(artifact, "encrypted recovery artifact", nonempty=True)
    with tempfile.TemporaryDirectory(prefix="vwrec-inspect-", dir=str(paths.backups)) as directory:
        staging = Path(directory) / "extracted"
        staging.mkdir()
        manifest = recovery._decrypt_and_validate(artifact, identity, staging, runner=runner)
        recovery._validate_offline_sops(staging / "payload", identity, runner=runner)
    created = manifest.get("created_at")
    if not isinstance(created, str) or not created:
        raise RecoveryUXError("verified recovery manifest has no valid creation time")
    verified = recovery.VerifiedRecovery(
        artifact=artifact,
        sha256=recovery._sha256(artifact),
        size=artifact.stat().st_size,
        created_at=created,
    )
    if record:
        _record_verification(state_location or str(artifact), verified, paths=paths)
    return verified


def verify_remote(
    remote_object: str,
    identity: Path,
    *,
    paths: recovery.RecoveryPaths = recovery.RecoveryPaths(),
    runner: recovery.Runner = recovery.run_command,
) -> recovery.VerifiedRecovery:
    paths.backups.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="vwrec-remote-inspect-", dir=str(paths.backups)) as directory:
        local = recovery.download_remote(remote_object, Path(directory) / "remote.vwrec", runner=runner)
        verified = verify_local(
            local,
            identity,
            paths=paths,
            runner=runner,
            state_location=remote_object,
            record=True,
        )
    return recovery.VerifiedRecovery(
        artifact=Path(remote_object),
        sha256=verified.sha256,
        size=verified.size,
        created_at=verified.created_at,
    )


def restore_remote_once(
    remote_object: str,
    identity: Path,
    *,
    paths: recovery.RecoveryPaths = recovery.RecoveryPaths(),
    runner: recovery.Runner = recovery.run_command,
    start: bool = False,
) -> Mapping[str, object]:
    """Download one remote object, verify it, then restore those exact bytes."""
    paths.backups.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="vwrec-remote-restore-", dir=str(paths.backups)) as directory:
        local = recovery.download_remote(remote_object, Path(directory) / "remote.vwrec", runner=runner)
        verify_local(
            local,
            identity,
            paths=paths,
            runner=runner,
            state_location=remote_object,
            record=True,
        )
        return recovery.restore_recovery(local, identity, paths=paths, runner=runner, start=start)


def _choice(prompt: str, count: int) -> int | None:
    answer = input(prompt).strip()
    if answer.lower() in {"q", "quit", "cancel"}:
        return None
    try:
        value = int(answer)
    except ValueError as exc:
        raise RecoveryUXError("invalid numbered selection") from exc
    if not 1 <= value <= count:
        raise RecoveryUXError("selection is outside the displayed range")
    return value - 1


def _restore_summary(point: RecoveryPoint, verified: recovery.VerifiedRecovery, ui: UI) -> None:
    ui.header("Restore preflight complete")
    ui.ok(f"recovery point cryptography, manifest, checksums, and SOPS custody verified ({verified.created_at})")
    ui.info(f"selected {point.source} recovery point: {point.location}")
    ui.info("The following live state will be replaced only after final confirmation:")
    print("  - /etc/vaultwarden-oci/config.toml")
    print("  - /etc/vaultwarden-oci/secrets.sops.yaml")
    print("  - Vaultwarden application data and SQLite database")
    print("  - Caddy data and configuration state")
    print("  - operational Age custody is preserved or safely regenerated/rekeyed as required")
    ui.info("Services are not stopped until the restore engine finishes staging, free-space, ownership, SQLite, and custody preflight.")


def guided_restore(
    *,
    start: bool = False,
    paths: recovery.RecoveryPaths = recovery.RecoveryPaths(),
    runner: recovery.Runner = recovery.run_command,
    ui: UI | None = None,
) -> int:
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        raise RecoveryUXError("guided restore requires a TTY; use --file/--from-remote and --identity for automation")
    ui = ui or UI()
    ui.header("Guided restore")
    print("  1) Local recovery points")
    print("  2) Remote recovery points (rclone)")
    print("  q) Cancel")
    source_choice = _choice("Choose recovery source: ", 2)
    if source_choice is None:
        ui.info("restore cancelled; no live state was changed")
        return 0

    if source_choice == 0:
        points = list_local(paths)
        ui.header("Local recovery points (newest first)")
        print_inventory(points)
        if not points:
            raise RecoveryUXError("no local .vwrec recovery points are available")
    else:
        remote = input("rclone REMOTE:path containing recovery points: ").strip()
        if not remote:
            raise RecoveryUXError("remote recovery source is required")
        points = list_remote_points(remote, paths=paths, runner=runner)
        ui.header("Remote recovery points (newest first)")
        print_inventory(points)
        if not points:
            raise RecoveryUXError("no remote .vwrec recovery points are available")

    selected_index = _choice("Choose recovery point number (or q to cancel): ", len(points))
    if selected_index is None:
        ui.info("restore cancelled; no live state was changed")
        return 0
    point = points[selected_index]
    identity_text = input("Offline Age private identity file: ").strip()
    if not identity_text:
        raise RecoveryUXError("offline Age identity file is required")
    identity = Path(identity_text)

    # The wrapper verifies storage before dispatch, and guided restore proves it
    # again immediately before any restore transaction for a fail-closed human path.
    storage.verify()

    if point.source == "local":
        artifact = Path(point.location)
        verified = verify_local(artifact, identity, paths=paths, runner=runner)
        _restore_summary(point, verified, ui)
        if input("Type RESTORE to replace the live state, or anything else to cancel: ").strip() != "RESTORE":
            ui.info("restore cancelled after preflight; no live state was changed")
            return 0
        manifest = recovery.restore_recovery(artifact, identity, paths=paths, runner=runner, start=start)
    else:
        paths.backups.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="vwrec-guided-remote-", dir=str(paths.backups)) as directory:
            artifact = recovery.download_remote(point.location, Path(directory) / point.name, runner=runner)
            verified = verify_local(
                artifact,
                identity,
                paths=paths,
                runner=runner,
                state_location=point.location,
                record=True,
            )
            _restore_summary(point, verified, ui)
            if input("Type RESTORE to replace the live state, or anything else to cancel: ").strip() != "RESTORE":
                ui.info("restore cancelled after preflight; no live state was changed")
                return 0
            manifest = recovery.restore_recovery(artifact, identity, paths=paths, runner=runner, start=start)

    ui.ok(f"restored recovery point created {manifest['created_at']}")
    if not start:
        ui.action("services remain stopped; run 'vwctl start' when ready")
    return 0


def _safe_private_dir(path: Path) -> None:
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise RecoveryUXError(f"protected recovery path is unsafe: {path}")
    else:
        path.mkdir(parents=True, mode=0o700)
    os.chmod(path, 0o700)
    info = path.lstat()
    if stat.S_IMODE(info.st_mode) != 0o700:
        raise RecoveryUXError(f"cannot establish mode 0700 on protected recovery path: {path}")


def _private_copy(source: Path, destination: Path) -> None:
    recovery._ensure_regular(source, "recovery-kit source", nonempty=True)
    shutil.copyfile(source, destination)
    os.chmod(destination, 0o600)


def _decrypt_all_sops(
    encrypted: Path,
    identity: Path,
    *,
    runner: recovery.Runner = recovery.run_command,
) -> dict[str, str]:
    env = os.environ.copy()
    env["SOPS_AGE_KEY_FILE"] = str(identity)
    result = runner(["sops", "--decrypt", "--output-type", "json", str(encrypted)], env=env)
    if not result.ok:
        raise RecoveryUXError("SOPS credential decryption failed")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RecoveryUXError("SOPS credential decryption did not return a JSON object") from exc
    if not isinstance(payload, dict) or not payload:
        raise RecoveryUXError("SOPS credential document is empty or invalid")
    values: dict[str, str] = {}
    for key, value in payload.items():
        if not isinstance(key, str) or not key or not isinstance(value, str) or not value or any(c in value for c in "\0\r\n"):
            raise RecoveryUXError("SOPS credential document contains an unsupported key/value")
        values[key] = value
    return values


def _credential_document(values: Mapping[str, str]) -> str:
    lines = [
        "VaultWarden-OCI credential recovery values",
        "",
        "Keep this document private. Values are intentionally present only inside the encrypted recovery-kit ZIP.",
        "",
    ]
    for key in sorted(values):
        label = _LABELS.get(key, key)
        lines.extend((f"[{label}]", f"key = {key}", f"value = {values[key]}", ""))
    return "\n".join(lines)


def _kit_readme(config: runtime.RuntimeConfig) -> str:
    return (
        "VaultWarden-OCI complete credential recovery kit\n\n"
        "This ZIP is a credential/admin custody handoff, not an application backup.\n"
        "Application data is restored from a .vwrec recovery point.\n\n"
        f"Site: {config.domain}\n"
        f"Offline recovery recipient: {config.offline_recovery_recipient}\n\n"
        "Members:\n"
        "- config.toml: canonical non-secret appliance configuration\n"
        "- credentials.txt: all current top-level SOPS-managed credential values\n"
        "- operational-age-identity.txt: server operational Age private identity\n"
        "- offline-recovery-identity.txt: matching off-host recovery Age private identity\n\n"
        "Store this encrypted ZIP away from the server. Store its ZIP passphrase separately.\n"
    )


def _prompt_passphrase() -> tuple[str, str]:
    first = getpass.getpass("Recovery-kit ZIP passphrase (minimum 16 characters): ")
    second = getpass.getpass("Confirm recovery-kit ZIP passphrase: ")
    return first, second


def _validate_passphrase(first: str, second: str) -> str:
    if first != second:
        raise RecoveryUXError("recovery-kit ZIP passphrases do not match")
    if len(first) < 16:
        raise RecoveryUXError("recovery-kit ZIP passphrase must be at least 16 characters")
    if "\n" in first or "\r" in first or "\0" in first:
        raise RecoveryUXError("recovery-kit ZIP passphrase contains unsupported control characters")
    return first


# Subprocess-shaped seam retained for focused tests; the implementation itself
# is the proven V1-compatible secure transport.
_seven = sevenzip_secure.run


def _seven_required(
    argv: Sequence[str],
    *,
    password_input: str | None,
    cwd: Path | None = None,
    label: str,
):
    result = _seven(argv, password_input=password_input, cwd=cwd)
    if result.returncode != 0:
        raise RecoveryUXError(f"{label} failed (7zz exit {result.returncode})")
    return result


def _slt_records(text: str) -> list[dict[str, str]]:
    records: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            if current:
                records.append(current)
                current = {}
            continue
        if " = " in line:
            key, value = line.split(" = ", 1)
            current[key] = value
    if current:
        records.append(current)
    return records


def verify_zip(
    archive: Path,
    passphrase: str,
    *,
    expected_members: Sequence[str] = KIT_MEMBERS,
) -> None:
    expected_counts = Counter(expected_members)
    if not expected_counts or any(count != 1 for count in expected_counts.values()):
        raise RecoveryUXError("recovery-kit expected member contract is invalid")
    listing = _seven_required(
        ["7zz", "l", "-slt", "-p", str(archive)],
        password_input=passphrase,
        label="recovery-kit ZIP inspection",
    )
    records = _slt_records(listing.stdout)
    archive_records = [record for record in records if record.get("Type") == "zip"]
    if len(archive_records) != 1:
        raise RecoveryUXError("recovery-kit publication is not exactly one ZIP container")
    member_records = [record for record in records if record.get("Path") and record.get("Type") != "zip"]
    member_paths = [record["Path"] for record in member_records]
    if Counter(member_paths) != expected_counts:
        raise RecoveryUXError("recovery-kit ZIP member multiset does not exactly match the required member set")
    for record in member_records:
        name = record["Path"]
        method = record.get("Method", "").upper()
        encrypted = record.get("Encrypted", "+")
        if "AES" not in method or "256" not in method or encrypted == "-":
            raise RecoveryUXError(f"recovery-kit member is not AES-256 encrypted: {name}")

    _seven_required(
        ["7zz", "t", "-p", str(archive)],
        password_input=passphrase,
        label="recovery-kit correct-passphrase archive test",
    )
    wrong = ("X" if not passphrase.startswith("X") else "Y") * max(16, len(passphrase))
    if _seven(["7zz", "t", "-p", str(archive)], password_input=wrong).returncode == 0:
        raise RecoveryUXError("recovery-kit ZIP unexpectedly accepted a deliberately wrong passphrase")
    if _seven(["7zz", "t", "-p", str(archive)], password_input="").returncode == 0:
        raise RecoveryUXError("recovery-kit ZIP unexpectedly accepted an explicitly empty passphrase")
    if _seven(["7zz", "t", str(archive)], password_input=None).returncode == 0:
        raise RecoveryUXError("recovery-kit ZIP unexpectedly tested successfully with no password input")


def _smtp_attachment(
    *,
    config: runtime.RuntimeConfig,
    values: Mapping[str, str],
    archive: Path,
    recipient: str,
) -> None:
    result = notification.send_smtp_attachment(
        config=config,
        secrets=values,
        to_email=recipient,
        subject="VaultWarden-OCI verified recovery kit",
        text=(
            "Attached is the verified AES-256 recovery-kit ZIP.\n"
            "The ZIP passphrase is intentionally not included in this email.\n"
        ),
        attachment=archive,
        attachment_name=archive.name,
    )
    if not result.ok:
        raise RecoveryUXError(
            f"authenticated SMTP recovery-kit delivery failed: {result.category}: {result.reason}"
        )


def _cleanup_workspace(path: Path) -> None:
    try:
        shutil.rmtree(path)
    except OSError as exc:
        raise RecoveryUXError(f"failed to remove protected recovery-kit plaintext workspace: {path}") from exc
    if path.exists() or path.is_symlink():
        raise RecoveryUXError(f"protected recovery-kit plaintext workspace still exists after cleanup: {path}")


def export_recovery_kit(
    offline_identity: Path,
    *,
    publication_dir: Path = PUBLICATION_DIR,
    sensitive_root: Path = SENSITIVE_RUN,
    paths: recovery.RecoveryPaths = recovery.RecoveryPaths(),
    runner: recovery.Runner = recovery.run_command,
    passphrase_provider: Callable[[], tuple[str, str]] = _prompt_passphrase,
    offer_email: bool = True,
    email_prompt: Callable[[str], str] = input,
    smtp_sender: Callable[..., None] = _smtp_attachment,
) -> KitResult:
    if paths == recovery.RecoveryPaths() and os.geteuid() != 0:
        raise RecoveryUXError("recovery-kit export must run as root")
    config = runtime.load_config(paths.config)
    recovery._ensure_regular(paths.operational_age_key, "operational Age identity", nonempty=True)
    recovery._ensure_regular(offline_identity, "offline recovery identity", nonempty=True)
    operational_recipient = secrets.derive_recipient(paths.operational_age_key, runner=runner)
    offline_recipient = secrets.derive_recipient(offline_identity, runner=runner)
    if offline_recipient != config.offline_recovery_recipient:
        raise RecoveryUXError("supplied offline identity does not match the configured offline recovery recipient")
    if operational_recipient == offline_recipient:
        raise RecoveryUXError("operational and offline Age identities must differ")
    recipients = secrets.encrypted_recipients(paths.encrypted_secrets)
    if operational_recipient not in recipients or offline_recipient not in recipients:
        raise RecoveryUXError("SOPS document is not addressed to both operational and offline recovery identities")

    operational_values = _decrypt_all_sops(paths.encrypted_secrets, paths.operational_age_key, runner=runner)
    offline_values = _decrypt_all_sops(paths.encrypted_secrets, offline_identity, runner=runner)
    if operational_values != offline_values:
        raise RecoveryUXError("operational and offline SOPS decryption results do not match")

    first, second = passphrase_provider()
    passphrase = _validate_passphrase(first, second)
    _safe_private_dir(sensitive_root)
    _safe_private_dir(publication_dir)
    workspace = Path(tempfile.mkdtemp(prefix="recovery-kit-", dir=str(sensitive_root)))
    os.chmod(workspace, 0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    final = publication_dir / f"vaultwarden-recovery-kit-{stamp}.zip"
    partial = publication_dir / f".{final.name}.{os.getpid()}.partial"
    if final.exists() or partial.exists() or final.is_symlink() or partial.is_symlink():
        _cleanup_workspace(workspace)
        raise RecoveryUXError("recovery-kit publication target already exists")

    emailed = False
    cleanup_error: RecoveryUXError | None = None
    try:
        (workspace / "README.txt").write_text(_kit_readme(config), encoding="utf-8")
        (workspace / "config.toml").write_text(paths.config.read_text(encoding="utf-8"), encoding="utf-8")
        (workspace / "credentials.txt").write_text(_credential_document(operational_values), encoding="utf-8")
        _private_copy(paths.operational_age_key, workspace / "operational-age-identity.txt")
        _private_copy(offline_identity, workspace / "offline-recovery-identity.txt")
        for name in KIT_MEMBERS:
            target = workspace / name
            os.chmod(target, 0o600)
            recovery._ensure_regular(target, "recovery-kit member", nonempty=True)

        create = _seven(
            ["7zz", "a", "-tzip", "-mem=AES256", "-p", str(partial), *KIT_MEMBERS],
            password_input=passphrase,
            cwd=workspace,
        )
        if create.returncode != 0:
            raise RecoveryUXError(f"AES-256 recovery-kit ZIP creation failed (7zz exit {create.returncode})")
        os.chmod(partial, 0o600)
        verify_zip(partial, passphrase, expected_members=KIT_MEMBERS)
        os.replace(partial, final)
        os.chmod(final, 0o600)

        if offer_email and sys.stdin.isatty():
            recipient = config.notification_to_email or config.acme_email
            answer = email_prompt(f"Email the verified recovery-kit ZIP to {recipient}? [y/N]: ").strip().lower()
            if answer in {"y", "yes"}:
                # This point is deliberately after every ZIP verification gate.
                smtp_sender(config=config, values=operational_values, archive=final, recipient=recipient)
                emailed = True
    except Exception:
        partial.unlink(missing_ok=True)
        if final.exists() and not final.is_symlink():
            # A fully verified published ZIP is retained if a later email attempt fails;
            # it remains a truthful local handoff artifact. Other failures remove output.
            if not final.stat().st_size:
                final.unlink(missing_ok=True)
        raise
    finally:
        try:
            _cleanup_workspace(workspace)
        except RecoveryUXError as exc:
            cleanup_error = exc
    if cleanup_error is not None:
        raise cleanup_error
    return KitResult(final, KIT_MEMBERS, emailed)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vwctl", description="VaultWarden-OCI recovery UX")
    commands = parser.add_subparsers(dest="command", required=True)

    restore = commands.add_parser("restore", help="guided or explicit .vwrec restore")
    source = restore.add_mutually_exclusive_group()
    source.add_argument("--file", type=Path)
    source.add_argument("--from-remote")
    restore.add_argument("--identity", type=Path)
    restore.add_argument("--start", action="store_true")

    recovery_cmd = commands.add_parser("recovery", help="recovery inventory, verification, and retention")
    recovery_commands = recovery_cmd.add_subparsers(dest="recovery_command", required=True)
    listing = recovery_commands.add_parser("list", help="list local and optional remote recovery points")
    listing.add_argument("--remote", help="rclone REMOTE:path to include")
    verify = recovery_commands.add_parser("verify", help="non-destructively verify a recovery point")
    verify_source = verify.add_mutually_exclusive_group(required=True)
    verify_source.add_argument("--file", type=Path)
    verify_source.add_argument("--from-remote")
    verify.add_argument("--identity", required=True, type=Path)
    prune = recovery_commands.add_parser("prune", help="plan or execute explicit remote recovery pruning")
    prune.add_argument("--remote", required=True)
    prune.add_argument("--keep-last", required=True, type=int)
    prune.add_argument("--confirm", action="store_true")

    kit = commands.add_parser("recovery-kit", help="credential/admin recovery-kit handoff")
    kit_commands = kit.add_subparsers(dest="kit_command", required=True)
    export = kit_commands.add_parser("export", help="export a complete verified AES-256 recovery-kit ZIP")
    export.add_argument(
        "--offline-identity",
        required=True,
        type=Path,
        help="matching off-host Age private identity; required because it cannot be recreated later",
    )
    export.add_argument("--no-email", action="store_true", help="do not offer authenticated SMTP delivery")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(list(argv) if argv is not None else None)
    ui = UI()
    try:
        if args.command == "restore":
            if args.file is None and args.from_remote is None:
                if args.identity is not None:
                    raise RecoveryUXError("--identity requires an explicit --file/--from-remote source, or omit it for guided restore")
                return guided_restore(start=args.start, ui=ui)
            if args.identity is None:
                raise RecoveryUXError("explicit restore requires --identity")
            storage.verify()
            if args.file is not None:
                verify_local(args.file, args.identity)
                manifest = recovery.restore_recovery(args.file, args.identity, start=args.start)
            else:
                manifest = restore_remote_once(args.from_remote, args.identity, start=args.start)
            ui.ok(f"restored recovery point created {manifest['created_at']}")
            if not args.start:
                ui.action("services remain stopped; run 'vwctl start' when ready")
            return 0

        if args.command == "recovery":
            if args.recovery_command == "list":
                ui.header("Local recovery points (newest first)")
                print_inventory(list_local())
                if args.remote:
                    ui.header("Remote recovery points (newest first)")
                    print_inventory(list_remote_points(args.remote))
                return 0
            if args.recovery_command == "verify":
                storage.verify()
                if args.file is not None:
                    verified = verify_local(args.file, args.identity)
                    location = str(args.file)
                else:
                    verified = verify_remote(args.from_remote, args.identity)
                    location = args.from_remote
                ui.ok(
                    f"verified recovery {location} created={verified.created_at} "
                    f"size={verified.size} sha256={verified.sha256}"
                )
                return 0
            if args.recovery_command == "prune":
                decision = recovery.prune_remote(args.remote, args.keep_last, confirm=args.confirm)
                print("Keep:")
                for name in decision.keep:
                    print(f"  {name}")
                print("Delete:")
                for name in decision.delete:
                    print(f"  {name}")
                if decision.delete and not args.confirm:
                    print("PLAN ONLY: pass --confirm to execute these explicit deletions")
                elif args.confirm:
                    ui.ok("explicit remote pruning completed")
                return 0

        if args.command == "recovery-kit":
            if not sys.stdin.isatty():
                raise RecoveryUXError("recovery-kit export requires an interactive TTY for the independent ZIP passphrase")
            result = export_recovery_kit(args.offline_identity, offer_email=not args.no_email)
            ui.ok(f"verified complete recovery kit: {result.archive}")
            ui.info("the ZIP contains credential custody material; it is not a .vwrec application recovery point")
            ui.info("store the ZIP passphrase separately; it was not written to disk or email")
            if result.emailed:
                ui.ok("verified ZIP delivered through authenticated SMTP")
            return 0
    except (
        RecoveryUXError,
        notification.NotificationError,
        recovery.RecoveryError,
        runtime.RuntimeConfigError,
        secrets.SecretsError,
        sevenzip_secure.SevenZipError,
        storage.StorageError,
        OSError,
    ) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
