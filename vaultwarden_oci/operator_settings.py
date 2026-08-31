"""Curated non-secret operator settings for the small-team appliance.

This is intentionally not a pass-through for every upstream Vaultwarden option.
The catalog contains the stable, day-2 settings that a small-team administrator
is reasonably expected to change. Security-sensitive plumbing owned by the
appliance (proxy trust, storage, logging paths, database paths, admin secrets,
and experimental features) stays outside this catalog.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Mapping


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


VAULTWARDEN_SETTINGS: tuple[SettingSpec, ...] = (
    SettingSpec("signups_allowed", "SIGNUPS_ALLOWED", "bool", False, "Allow open self-registration. Keep false for an invite-only small team."),
    SettingSpec("signups_verify", "SIGNUPS_VERIFY", "bool", False, "Require email verification for self-registration."),
    SettingSpec("signups_verify_resend_time", "SIGNUPS_VERIFY_RESEND_TIME", "int", 3600, "Seconds before another verification email may be sent.", 60, 86400),
    SettingSpec("signups_verify_resend_limit", "SIGNUPS_VERIFY_RESEND_LIMIT", "int", 6, "Maximum verification-email resends triggered by login attempts.", 1, 100),
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
    SettingSpec("client_suppress_onboarding", "CLIENT_SUPPRESS_ONBOARDING", "bool", False, "Suppress client onboarding and promotional interstitials."),
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
            if spec.minimum is not None and value < spec.minimum or spec.maximum is not None and value > spec.maximum:
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


def environment(values: Mapping[str, object]) -> tuple[tuple[str, str], ...]:
    normalized = parse_vaultwarden_settings(values)
    # Vaultwarden persists Admin-panel edits to DATA_FOLDER/config.json and that
    # file overrides environment variables on later starts. Point CONFIG_FILE at
    # the container tmpfs so the appliance config remains the only durable
    # non-secret authority while the upstream Admin UI can still make temporary
    # in-process changes for diagnostics. Existing /data/config.json files are
    # therefore ignored rather than silently overriding the appliance config.
    rendered: list[tuple[str, str]] = [("CONFIG_FILE", "/tmp/vaultwarden-admin-config.json")]
    for spec in VAULTWARDEN_SETTINGS:
        value = normalized[spec.name]
        if isinstance(value, bool):
            text = "true" if value else "false"
        else:
            text = str(value)
        rendered.append((spec.env, text))
    return tuple(rendered)


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
