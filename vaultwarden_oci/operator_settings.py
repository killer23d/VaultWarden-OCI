"""Curated non-secret operator settings for the small-team appliance.

This is intentionally not a pass-through for every upstream Vaultwarden option.
The catalog contains the stable, day-2 settings that a small-team administrator
is reasonably expected to change. Security-sensitive plumbing owned by the
appliance (proxy trust, storage, logging paths, database paths, admin secrets,
and experimental features) stays outside this catalog.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping
from urllib.parse import urlsplit


class OperatorSettingError(ValueError):
    pass


@dataclass(frozen=True)
class SettingSpec:
    name: str
    env: str
    kind: str
    default: object
    description: str
    minimum: int | None = None
    maximum: int | None = None


@dataclass(frozen=True)
class LegacyDifference:
    legacy_key: str
    target: str
    legacy_value: object
    current_value: object


@dataclass(frozen=True)
class LegacyAdminReport:
    active: bool
    finalized: bool
    legacy_path: Path
    marker_path: Path
    sha256: str | None
    differences: tuple[LegacyDifference, ...] = ()
    discard_keys: tuple[str, ...] = ()


LEGACY_CONFIG_PATH = Path("/var/lib/vaultwarden-oci/data/config.json")
LEGACY_FINALIZATION_PATH = Path(
    "/var/lib/vaultwarden-oci/state/legacy-admin-config-finalized.json"
)
TMPFS_CONFIG_FILE = "/tmp/vaultwarden-admin-config.json"
LEGACY_CONTAINER_CONFIG_FILE = "/data/config.json"
_MAX_LEGACY_CONFIG_BYTES = 1024 * 1024


VAULTWARDEN_SETTINGS: tuple[SettingSpec, ...] = (
    SettingSpec("signups_allowed", "SIGNUPS_ALLOWED", "bool", False, "Allow open self-registration. Keep false for an invite-only small team."),
    SettingSpec("signups_verify", "SIGNUPS_VERIFY", "bool", False, "Require email verification for self-registration."),
    SettingSpec("signups_verify_resend_time", "SIGNUPS_VERIFY_RESEND_TIME", "int", 3600, "Seconds before another verification email may be sent.", 60, 86400),
    SettingSpec("signups_verify_resend_limit", "SIGNUPS_VERIFY_RESEND_LIMIT", "int", 6, "Maximum verification-email resends triggered by login attempts; 0 means unlimited.", 0, 100),
    SettingSpec("sends_allowed", "SENDS_ALLOWED", "bool", True, "Allow Bitwarden Sends."),
    SettingSpec("invitations_allowed", "INVITATIONS_ALLOWED", "bool", True, "Allow organization admins to invite users even when open signups are disabled."),
    SettingSpec("invitation_org_name", "INVITATION_ORG_NAME", "string", "Vaultwarden", "Name used for invitations that are not sent by a specific organization."),
    SettingSpec("invitation_expiration_hours", "INVITATION_EXPIRATION_HOURS", "int", 120, "Hours before invitation and related email tokens expire.", 1, 8760),
    SettingSpec("emergency_access_allowed", "EMERGENCY_ACCESS_ALLOWED", "bool", True, "Allow users to configure emergency access."),
    SettingSpec("email_change_allowed", "EMAIL_CHANGE_ALLOWED", "bool", True, "Allow users to change their account email address."),
    SettingSpec("org_events_enabled", "ORG_EVENTS_ENABLED", "bool", False, "Enable organization event logging."),
    SettingSpec("org_creation_users", "ORG_CREATION_USERS", "string", "all", "Who may create organizations: all, none, or a comma-separated email list."),
    SettingSpec("incomplete_2fa_time_limit", "INCOMPLETE_2FA_TIME_LIMIT", "int", 3, "Minutes before an incomplete 2FA login can trigger an email notice; 0 disables it.", 0, 1440),
    SettingSpec("password_iterations", "PASSWORD_ITERATIONS", "int", 600000, "Server-side password hashing iterations for new users.", 100000, 5000000),
    SettingSpec("password_hints_allowed", "PASSWORD_HINTS_ALLOWED", "bool", True, "Allow users to set password hints."),
    SettingSpec("show_password_hint", "SHOW_PASSWORD_HINT", "bool", False, "Never expose password hints directly on a public page by default."),
    SettingSpec("require_device_email", "REQUIRE_DEVICE_EMAIL", "bool", False, "Fail new-device login when its notification email cannot be sent."),
    SettingSpec("email_token_size", "EMAIL_TOKEN_SIZE", "int", 6, "Number of digits in email 2FA tokens.", 6, 255),
    SettingSpec("email_expiration_time", "EMAIL_EXPIRATION_TIME", "int", 600, "Email 2FA token lifetime in seconds.", 60, 86400),
    SettingSpec("email_attempts_limit", "EMAIL_ATTEMPTS_LIMIT", "int", 3, "Maximum attempts before an email 2FA token is reset.", 1, 100),
    SettingSpec("email_2fa_enforce_on_verified_invite", "EMAIL_2FA_ENFORCE_ON_VERIFIED_INVITE", "bool", False, "Automatically set up email 2FA for verified invited users."),
    SettingSpec("email_2fa_auto_fallback", "EMAIL_2FA_AUTO_FALLBACK", "bool", False, "Automatically use email 2FA as a fallback provider."),
    SettingSpec("admin_ratelimit_seconds", "ADMIN_RATELIMIT_SECONDS", "int", 300, "Vaultwarden admin-login average rate-limit interval in seconds.", 1, 3600),
    SettingSpec("admin_ratelimit_max_burst", "ADMIN_RATELIMIT_MAX_BURST", "int", 3, "Vaultwarden admin-login burst size.", 1, 100),
    SettingSpec("admin_session_lifetime", "ADMIN_SESSION_LIFETIME", "int", 20, "Vaultwarden admin-session lifetime in minutes.", 1, 1440),
    SettingSpec("login_ratelimit_seconds", "LOGIN_RATELIMIT_SECONDS", "int", 60, "Average login rate-limit interval in seconds.", 1, 3600),
    SettingSpec("login_ratelimit_max_burst", "LOGIN_RATELIMIT_MAX_BURST", "int", 10, "Login/2FA burst size.", 2, 1000),
    SettingSpec("unauthenticated_ratelimit_seconds", "UNAUTHENTICATED_RATELIMIT_SECONDS", "int", 60, "Average rate-limit interval for unauthenticated recovery/hint/Send endpoints.", 1, 3600),
    SettingSpec("unauthenticated_ratelimit_max_burst", "UNAUTHENTICATED_RATELIMIT_MAX_BURST", "int", 50, "Shared unauthenticated endpoint burst size.", 1, 5000),
)

_BY_NAME = {item.name: item for item in VAULTWARDEN_SETTINGS}
_EMAIL = re.compile(r"^[^\s@]+@[^\s@]+$")


def _clean_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or value.strip() != value or any(c in value for c in "\0\r\n"):
        raise OperatorSettingError(f"{label} must be a non-empty single-line string")
    return value


def parse_vaultwarden_settings(data: Mapping[str, object]) -> dict[str, object]:
    unknown = sorted(set(data) - set(_BY_NAME))
    if unknown:
        raise OperatorSettingError("unknown vaultwarden setting(s): " + ", ".join(unknown))
    values: dict[str, object] = {}
    for spec in VAULTWARDEN_SETTINGS:
        value = data.get(spec.name, spec.default)
        if spec.kind == "bool":
            if not isinstance(value, bool):
                raise OperatorSettingError(f"vaultwarden.{spec.name} must be true or false")
        elif spec.kind == "int":
            if not isinstance(value, int) or isinstance(value, bool):
                raise OperatorSettingError(f"vaultwarden.{spec.name} must be an integer")
            below_minimum = spec.minimum is not None and value < spec.minimum
            above_maximum = spec.maximum is not None and value > spec.maximum
            if below_minimum or above_maximum:
                raise OperatorSettingError(
                    f"vaultwarden.{spec.name} must be {spec.minimum}..{spec.maximum}"
                )
        else:
            value = _clean_string(value, f"vaultwarden.{spec.name}")
        values[spec.name] = value

    creators = str(values["org_creation_users"]).strip().lower()
    if creators not in {"all", "none"}:
        emails = [item.strip() for item in creators.split(",")]
        if not emails or any(not _EMAIL.fullmatch(item) for item in emails):
            raise OperatorSettingError(
                "vaultwarden.org_creation_users must be all, none, or a comma-separated email list"
            )
        creators = ",".join(emails)
    values["org_creation_users"] = creators
    return values


def _marker_digest(path: Path) -> str | None:
    try:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            return None
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        return None
    digest = payload.get("legacy_config_sha256")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        return None
    return digest


def _selection_digest(path: Path) -> str | None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    except OSError:
        return "unsafe"
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        return "unsafe"
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return "unsafe"


def legacy_admin_active(
    *,
    legacy_path: Path = LEGACY_CONFIG_PATH,
    marker_path: Path = LEGACY_FINALIZATION_PATH,
) -> bool:
    """Return whether the old Admin file must remain effective for safe transition."""
    digest = _selection_digest(legacy_path)
    if digest is None:
        return False
    return digest == "unsafe" or _marker_digest(marker_path) != digest


def environment(
    values: Mapping[str, object],
    *,
    legacy_path: Path = LEGACY_CONFIG_PATH,
    marker_path: Path = LEGACY_FINALIZATION_PATH,
) -> tuple[tuple[str, str], ...]:
    normalized = parse_vaultwarden_settings(values)
    config_file = (
        LEGACY_CONTAINER_CONFIG_FILE
        if legacy_admin_active(legacy_path=legacy_path, marker_path=marker_path)
        else TMPFS_CONFIG_FILE
    )
    rendered: list[tuple[str, str]] = [("CONFIG_FILE", config_file)]
    for spec in VAULTWARDEN_SETTINGS:
        value = normalized[spec.name]
        if isinstance(value, bool):
            text = "true" if value else "false"
        else:
            text = str(value)
        rendered.append((spec.env, text))
    return tuple(rendered)


def _strict_legacy(path: Path) -> tuple[dict[str, object], str]:
    try:
        info = path.lstat()
    except FileNotFoundError as exc:
        raise OperatorSettingError(f"legacy Vaultwarden Admin config is not present: {path}") from exc
    except OSError as exc:
        raise OperatorSettingError(f"cannot inspect legacy Vaultwarden Admin config {path}: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise OperatorSettingError(f"legacy Vaultwarden Admin config is not a regular file: {path}")
    if info.st_size > _MAX_LEGACY_CONFIG_BYTES:
        raise OperatorSettingError("legacy Vaultwarden Admin config is unexpectedly large")
    try:
        raw = path.read_bytes()
        payload = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise OperatorSettingError(f"legacy Vaultwarden Admin config is invalid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise OperatorSettingError("legacy Vaultwarden Admin config must contain one JSON object")
    return payload, hashlib.sha256(raw).hexdigest()


def _current_setting_value(spec: SettingSpec, environment_values: Mapping[str, str]) -> object:
    try:
        text = environment_values[spec.env]
    except KeyError as exc:
        raise OperatorSettingError(f"runtime configuration is missing {spec.env}") from exc
    if spec.kind == "bool":
        if text not in {"true", "false"}:
            raise OperatorSettingError(f"runtime configuration has invalid {spec.env}")
        return text == "true"
    if spec.kind == "int":
        try:
            return int(text)
        except ValueError as exc:
            raise OperatorSettingError(f"runtime configuration has invalid {spec.env}") from exc
    return text


def _legacy_domain(value: object) -> str:
    text = _clean_string(value, "legacy domain")
    parsed = urlsplit(text)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port is not None
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
    ):
        raise OperatorSettingError("legacy domain is not a simple HTTPS URL")
    return parsed.hostname.lower()


def _legacy_smtp_value(key: str, value: object) -> object:
    if key in {"smtp_embed_images", "smtp_accept_invalid_certs", "smtp_accept_invalid_hostnames"}:
        if not isinstance(value, bool):
            raise OperatorSettingError(f"legacy {key} is not boolean")
        return value
    if key == "smtp_port":
        if not isinstance(value, int) or isinstance(value, bool) or not 1 <= value <= 65535:
            raise OperatorSettingError("legacy smtp_port is outside the supported range")
        return value
    if key == "smtp_timeout":
        if not isinstance(value, int) or isinstance(value, bool) or not 1 <= value <= 120:
            raise OperatorSettingError("legacy smtp_timeout is outside the supported range")
        return value
    text = _clean_string(value, f"legacy {key}")
    if key == "smtp_security" and text not in {"starttls", "force_tls"}:
        raise OperatorSettingError("legacy smtp_security is not supported by the appliance")
    if key == "smtp_from" and not _EMAIL.fullmatch(text):
        raise OperatorSettingError("legacy smtp_from is not a simple email address")
    if key == "smtp_host" and ("://" in text or "/" in text or ":" in text):
        raise OperatorSettingError("legacy smtp_host is not a simple hostname")
    return text


def legacy_admin_report(
    config: object,
    secret_values: Mapping[str, str],
    *,
    legacy_path: Path = LEGACY_CONFIG_PATH,
    marker_path: Path = LEGACY_FINALIZATION_PATH,
) -> LegacyAdminReport:
    """Compare one old Admin file with the appliance-owned settings it can replace."""
    if not legacy_path.exists() and not legacy_path.is_symlink():
        return LegacyAdminReport(False, False, legacy_path, marker_path, None)
    payload, digest = _strict_legacy(legacy_path)
    finalized = _marker_digest(marker_path) == digest
    if finalized:
        return LegacyAdminReport(False, True, legacy_path, marker_path, digest)

    env = dict(getattr(config, "vaultwarden_environment", ()))
    differences: list[LegacyDifference] = []
    handled: set[str] = set()
    discard: set[str] = set()

    for spec in VAULTWARDEN_SETTINGS:
        if spec.name not in payload or payload[spec.name] is None:
            continue
        handled.add(spec.name)
        try:
            legacy_value = parse_vaultwarden_settings({spec.name: payload[spec.name]})[spec.name]
        except OperatorSettingError:
            discard.add(spec.name)
            continue
        current_value = _current_setting_value(spec, env)
        if legacy_value != current_value:
            differences.append(
                LegacyDifference(
                    spec.name,
                    f"vaultwarden.{spec.name}",
                    legacy_value,
                    current_value,
                )
            )

    if "domain" in payload and payload["domain"] is not None:
        handled.add("domain")
        try:
            legacy_domain = _legacy_domain(payload["domain"])
        except OperatorSettingError:
            discard.add("domain")
        else:
            current_domain = str(getattr(config, "domain", ""))
            if legacy_domain != current_domain:
                differences.append(
                    LegacyDifference("domain", "site.domain", legacy_domain, current_domain)
                )

    smtp_fields = {
        "smtp_host": ("smtp.host", "smtp_host"),
        "smtp_port": ("smtp.port", "smtp_port"),
        "smtp_security": ("smtp.security", "smtp_security"),
        "smtp_from": ("smtp.from_email", "smtp_from_email"),
        "smtp_from_name": ("smtp.from_name", "smtp_from_name"),
        "smtp_timeout": ("smtp.timeout_seconds", "smtp_timeout_seconds"),
        "smtp_embed_images": ("smtp.embed_images", "smtp_embed_images"),
        "smtp_accept_invalid_certs": ("smtp.accept_invalid_certs", "smtp_accept_invalid_certs"),
        "smtp_accept_invalid_hostnames": ("smtp.accept_invalid_hostnames", "smtp_accept_invalid_hostnames"),
    }
    for legacy_key, (target, attribute) in smtp_fields.items():
        if legacy_key not in payload or payload[legacy_key] is None:
            continue
        handled.add(legacy_key)
        try:
            legacy_value = _legacy_smtp_value(legacy_key, payload[legacy_key])
        except OperatorSettingError:
            discard.add(legacy_key)
            continue
        current_value = getattr(config, attribute, None)
        if legacy_value != current_value:
            differences.append(
                LegacyDifference(legacy_key, target, legacy_value, current_value)
            )

    secret_fields = {
        "smtp_username": "smtp_username",
        "smtp_password": "smtp_password",
        "admin_token": "vaultwarden_admin_token",
    }
    for legacy_key, secret_key in secret_fields.items():
        if legacy_key not in payload or payload[legacy_key] is None:
            continue
        handled.add(legacy_key)
        value = payload[legacy_key]
        if not isinstance(value, str) or value != secret_values.get(secret_key):
            discard.add(legacy_key)

    for key, value in payload.items():
        if value is not None and key not in handled:
            discard.add(str(key))

    differences.sort(key=lambda item: item.target)
    return LegacyAdminReport(
        True,
        False,
        legacy_path,
        marker_path,
        digest,
        tuple(differences),
        tuple(sorted(discard)),
    )


def _atomic_marker(path: Path, payload: Mapping[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        parent = path.parent.lstat()
    except OSError as exc:
        raise OperatorSettingError(f"cannot inspect legacy finalization directory: {exc}") from exc
    if stat.S_ISLNK(parent.st_mode) or not stat.S_ISDIR(parent.st_mode):
        raise OperatorSettingError("legacy finalization parent is not a directory")
    os.chmod(path.parent, 0o700)
    tmp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    try:
        fd = os.open(
            tmp,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(dict(payload), handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        os.chmod(path, 0o600)
        descriptor = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def finalize_legacy_admin(report: LegacyAdminReport, *, confirm: bool) -> None:
    """Record explicit reconciliation without deleting the historical Admin file."""
    if report.finalized:
        return
    if not report.active or report.sha256 is None:
        raise OperatorSettingError("there is no active legacy Vaultwarden Admin config to finalize")
    if report.differences:
        raise OperatorSettingError("supported legacy Admin values still differ from config.toml")
    if not confirm:
        raise OperatorSettingError("legacy Admin finalization requires explicit confirmation")
    _, digest = _strict_legacy(report.legacy_path)
    if digest != report.sha256:
        raise OperatorSettingError("legacy Vaultwarden Admin config changed during reconciliation")
    _atomic_marker(
        report.marker_path,
        {
            "schema_version": 1,
            "legacy_config_sha256": digest,
            "finalized_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "discarded_keys": list(report.discard_keys),
        },
    )


def render_toml() -> str:
    lines = ["[vaultwarden]"]
    for spec in VAULTWARDEN_SETTINGS:
        lines.append(f"# {spec.description}")
        value = spec.default
        if isinstance(value, bool):
            rendered = "true" if value else "false"
        elif isinstance(value, str):
            rendered = json.dumps(value, ensure_ascii=False)
        else:
            rendered = str(value)
        lines.append(f"{spec.name} = {rendered}")
    return "\n".join(lines) + "\n"