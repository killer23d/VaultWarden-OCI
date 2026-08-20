"""SOPS/Age custody and volatile Phase 3+ secret materialization."""
from __future__ import annotations

import json
import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping

from .cli import CommandResult, run_command

ETC = Path("/etc/vaultwarden-oci")
ENCRYPTED = ETC / "secrets.sops.yaml"
AGE_KEY = ETC / "age-key.txt"
RUN = Path("/run/vaultwarden-oci/secrets")
REQUIRED = ("cloudflare_api_token", "smtp_username", "smtp_password")
OPTIONAL = ("vaultwarden_admin_token",)
# Used in memory to render volatile component configuration, never materialized
# into the Vaultwarden/Caddy secret mounts.
TRANSIENT_ONLY = ("cloudflare_remediation_token",)
_RECIPIENT = re.compile(r"^age1[0-9a-z]{50,70}$")
_RECIPIENT_LINE = re.compile(r"^\s*-?\s*recipient:\s*(age1[0-9a-z]{50,70})\s*$")
# Keep this validation aligned with pinned caddy-dns/cloudflare v0.2.4. The
# plugin includes a rejected token in its provisioning error, so malformed
# values must be rejected here before Caddy can log them.
_CLOUDFLARE_LEGACY_TOKEN = re.compile(r"^[A-Za-z0-9_-]{35,50}$")
_CLOUDFLARE_NEW_TOKEN = re.compile(r"^cf(?:ut|at)_[A-Za-z0-9_-]{32,256}$")


class SecretsError(RuntimeError):
    pass


@dataclass(frozen=True)
class SecretPaths:
    encrypted: Path = ENCRYPTED
    age_key: Path = AGE_KEY
    root: Path = RUN
    vaultwarden: Path = RUN / "vaultwarden"
    caddy: Path = RUN / "caddy"

    def file(self, key: str) -> Path:
        return (self.caddy if key == "cloudflare_api_token" else self.vaultwarden) / key


Runner = Callable[..., CommandResult]


def validate_recipient(value: str) -> str:
    if not _RECIPIENT.fullmatch(value):
        raise SecretsError("offline recovery recipient must be an Age X25519 recipient")
    return value


def validate_cloudflare_token(value: str) -> str:
    """Reject values that the pinned Caddy Cloudflare module would echo on error."""
    if not (_CLOUDFLARE_NEW_TOKEN.fullmatch(value) or _CLOUDFLARE_LEGACY_TOKEN.fullmatch(value)):
        raise SecretsError(
            "decrypted Cloudflare token does not match the supported Cloudflare provider token format"
        )
    return value


def _secure_file(path: Path, uid: int) -> None:
    try:
        info = path.lstat()
    except OSError as exc:
        raise SecretsError(f"cannot inspect required secret file {path}: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise SecretsError(f"required secret path is not a regular file: {path}")
    if info.st_uid != uid or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size == 0:
        raise SecretsError(f"required secret file must be uid {uid}, mode 0600, and non-empty: {path}")


def _dir(path: Path, uid: int, gid: int, mode: int) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chown(path, uid, gid)
    os.chmod(path, mode)
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise SecretsError(f"runtime secret path is not a directory: {path}")
    if (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (uid, gid, mode):
        raise SecretsError(f"incompatible ownership/mode at runtime secret path: {path}")


def ensure_runtime(
    paths: SecretPaths,
    *,
    uid: int = 0,
    gid: int = 0,
    vaultwarden_gid: int = 65532,
    caddy_gid: int = 65533,
) -> None:
    _dir(paths.root, uid, gid, 0o700)
    _dir(paths.vaultwarden, uid, vaultwarden_gid, 0o750)
    _dir(paths.caddy, uid, caddy_gid, 0o750)


def _recipients(path: Path) -> set[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise SecretsError(f"cannot read encrypted secrets metadata: {exc}") from exc
    found: set[str] = set()
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        payload = None
    if isinstance(payload, dict):
        sops = payload.get("sops")
        age = sops.get("age") if isinstance(sops, dict) else None
        if isinstance(age, list):
            for item in age:
                if isinstance(item, dict) and isinstance(item.get("recipient"), str):
                    found.add(item["recipient"])
    if found:
        return found
    for line in text.splitlines():
        match = _RECIPIENT_LINE.fullmatch(line)
        if match:
            found.add(match.group(1))
    return found


def encrypted_recipients(path: Path) -> set[str]:
    """Return the Age recipients recorded in one SOPS encrypted document."""
    recipients = _recipients(path)
    for recipient in recipients:
        validate_recipient(recipient)
    return recipients


def _failure(label: str, result: CommandResult) -> SecretsError:
    detail = result.kind if result.returncode is None else f"exit {result.returncode}"
    return SecretsError(f"{label} failed ({detail})")


def derive_recipient(identity: Path, *, runner: Runner = run_command) -> str:
    """Derive and validate the public Age recipient for an identity file."""
    result = runner(["age-keygen", "-y", str(identity)])
    if not result.ok:
        raise _failure("deriving Age recipient", result)
    recipient = result.stdout.strip()
    validate_recipient(recipient)
    return recipient


def validate_custody(
    offline: str,
    *,
    paths: SecretPaths = SecretPaths(),
    runner: Runner = run_command,
    uid: int = 0,
) -> None:
    validate_recipient(offline)
    _secure_file(paths.age_key, uid)
    _secure_file(paths.encrypted, uid)
    operational = derive_recipient(paths.age_key, runner=runner)
    if operational == offline:
        raise SecretsError("operational and offline recovery recipients must differ")
    recipients = _recipients(paths.encrypted)
    if operational not in recipients:
        raise SecretsError("encrypted document is not addressed to the operational Age identity")
    if offline not in recipients:
        raise SecretsError("encrypted document is not addressed to the offline recovery recipient")


def _value(key: str, value: object) -> str:
    if not isinstance(value, str) or not value or any(c in value for c in "\0\r\n"):
        raise SecretsError(f"decrypted secret {key} must be a non-empty single-line string")
    if key in {"cloudflare_api_token", "cloudflare_remediation_token"}:
        validate_cloudflare_token(value)
    return value


def decrypt(*, paths: SecretPaths = SecretPaths(), runner: Runner = run_command) -> dict[str, str]:
    env = os.environ.copy()
    env["SOPS_AGE_KEY_FILE"] = str(paths.age_key)
    result = runner(["sops", "--decrypt", "--output-type", "json", str(paths.encrypted)], env=env)
    if not result.ok:
        raise _failure("SOPS decryption", result)
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise SecretsError("SOPS decryption did not return a JSON object") from exc
    if not isinstance(payload, dict):
        raise SecretsError("SOPS decryption did not return a JSON object")
    values = {key: _value(key, payload.get(key)) for key in REQUIRED}
    for key in OPTIONAL + TRANSIENT_ONLY:
        if payload.get(key) not in (None, ""):
            values[key] = _value(key, payload[key])
    return values


def load(
    offline: str,
    *,
    paths: SecretPaths = SecretPaths(),
    runner: Runner = run_command,
    uid: int = 0,
) -> dict[str, str]:
    validate_custody(offline, paths=paths, runner=runner, uid=uid)
    return decrypt(paths=paths, runner=runner)


def _write(path: Path, value: str, uid: int, gid: int) -> None:
    tmp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    if path.is_symlink():
        raise SecretsError(f"refusing to replace symlink: {path}")
    try:
        fd = os.open(
            tmp,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o440,
        )
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.chown(tmp, uid, gid)
        os.chmod(tmp, 0o440)
        os.replace(tmp, path)
        os.chown(path, uid, gid)
        os.chmod(path, 0o440)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def materialize(
    values: Mapping[str, str],
    *,
    paths: SecretPaths = SecretPaths(),
    uid: int = 0,
    gid: int = 0,
    vaultwarden_gid: int = 65532,
    caddy_gid: int = 65533,
) -> None:
    ensure_runtime(
        paths,
        uid=uid,
        gid=gid,
        vaultwarden_gid=vaultwarden_gid,
        caddy_gid=caddy_gid,
    )
    missing = sorted(set(REQUIRED) - set(values))
    if missing:
        raise SecretsError("missing required secret key(s): " + ", ".join(missing))
    written: list[Path] = []
    try:
        for key in REQUIRED + OPTIONAL:
            path = paths.file(key)
            if key not in values:
                path.unlink(missing_ok=True)
                continue
            secret_gid = caddy_gid if key == "cloudflare_api_token" else vaultwarden_gid
            _write(path, _value(key, values[key]), uid, secret_gid)
            written.append(path)
    except Exception:
        for path in written:
            path.unlink(missing_ok=True)
        raise


def cleanup(paths: SecretPaths = SecretPaths()) -> None:
    errors = []
    for key in REQUIRED + OPTIONAL:
        path = paths.file(key)
        try:
            if path.is_symlink() or path.exists():
                path.unlink()
        except OSError as exc:
            errors.append(f"{path}: {exc}")
    if errors:
        raise SecretsError("failed to remove volatile secrets: " + "; ".join(errors))