"""Catalog-driven operational notification delivery for VaultWarden-OCI V2."""
from __future__ import annotations

import base64
import email.utils
import http.client
import json
import math
import os
import re
import smtplib
import socket
import ssl
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from email.message import EmailMessage
from pathlib import Path
from typing import Callable, Mapping

from .cli import DoctorCheck

CATALOG_PATH = Path(__file__).resolve().parents[1] / "email-providers.toml"
STATE_PATH = Path("/var/lib/vaultwarden-oci/state/notification.json")
CANONICAL_FIELDS = frozenset(
    {"from_email", "from_name", "from_header", "to_email", "subject", "text"}
)
_AUTH_MODES = frozenset({"bearer", "fixed_header", "basic"})
_ENCODINGS = frozenset({"json", "form"})
_OPTION_KINDS = frozenset({"enum", "domain"})
_RETRY_UNITS = {"seconds": 1.0, "milliseconds": 0.001}
_PLACEHOLDER = re.compile(r"^\{([a-z][a-z0-9_]*)\}$")
_ENDPOINT_PLACEHOLDER = re.compile(r"\{([a-z][a-z0-9_]*)\}")
_TOKEN = re.compile(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
_DOMAIN = re.compile(
    r"^(?=.{1,253}\Z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"
)
_FIXED_RETRY_SECONDS = (1.0, 2.0)
_MAX_RETRY_DELAY = 5.0
_MAX_DIAGNOSTIC = 180
_MAX_RESPONSE = 4096


class NotificationError(RuntimeError):
    pass


class CatalogError(NotificationError):
    pass


@dataclass(frozen=True)
class OptionSpec:
    kind: str
    default: str | None = None
    allowed: tuple[str, ...] = ()


@dataclass(frozen=True)
class SubstitutionSpec:
    option: str
    values: Mapping[str, str] | None = None


@dataclass(frozen=True)
class Provider:
    provider_id: str
    aliases: tuple[str, ...]
    display_name: str
    endpoint: str
    auth_mode: str
    auth_username: str | None
    auth_header: str | None
    encoding: str
    request_template: object
    success_statuses: tuple[int, ...]
    success_field: str | None
    success_value: object | None
    retry_statuses: tuple[int, ...]
    retry_body_field: str | None
    retry_body_unit: str | None
    options: Mapping[str, OptionSpec]
    substitutions: Mapping[str, SubstitutionSpec]


@dataclass(frozen=True)
class Catalog:
    providers: Mapping[str, Provider]
    aliases: Mapping[str, str]

    def resolve(self, provider_id: str) -> Provider:
        normalized = provider_id.strip().lower()
        canonical = self.aliases.get(normalized, normalized)
        try:
            return self.providers[canonical]
        except KeyError as exc:
            raise CatalogError(f"unsupported operational email provider {provider_id!r}") from exc


@dataclass(frozen=True)
class RenderedRequest:
    provider: Provider
    endpoint: str
    headers: Mapping[str, str]
    body: bytes


@dataclass(frozen=True)
class AttemptResult:
    ok: bool
    transient: bool
    category: str
    reason: str
    retry_after: float | None = None


@dataclass(frozen=True)
class DeliveryResult:
    event_id: str
    provider: str
    transport: str
    outcome: str
    category: str
    reason: str
    recorded_at: str

    def as_dict(self) -> dict[str, str]:
        return {
            "event_id": self.event_id,
            "provider": self.provider,
            "transport": self.transport,
            "outcome": self.outcome,
            "category": self.category,
            "reason": self.reason,
            "recorded_at": self.recorded_at,
        }


def _unknown(data: Mapping[str, object], allowed: set[str], label: str) -> None:
    unknown = sorted(set(data) - allowed)
    if unknown:
        raise CatalogError(f"unknown {label} field(s): {', '.join(unknown)}")


def _string(value: object, label: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or value.strip() != value
        or any(char in value for char in "\0\r\n")
    ):
        raise CatalogError(f"{label} must be a non-empty single-line string")
    return value


def _identifier(value: object, label: str) -> str:
    text = _string(value, label).lower()
    if not re.fullmatch(r"[a-z][a-z0-9_-]*", text):
        raise CatalogError(f"{label} must be a lowercase provider identifier")
    return text


def _int_list(value: object, label: str, *, allow_empty: bool = False) -> tuple[int, ...]:
    if not isinstance(value, list) or (not value and not allow_empty):
        raise CatalogError(f"{label} must be a {'possibly empty ' if allow_empty else 'non-empty '}list")
    result: list[int] = []
    for item in value:
        if not isinstance(item, int) or isinstance(item, bool) or not 100 <= item <= 599:
            raise CatalogError(f"{label} contains an invalid HTTP status")
        if item in result:
            raise CatalogError(f"{label} contains duplicate HTTP status {item}")
        result.append(item)
    return tuple(result)


def _walk_template(value: object, label: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if not isinstance(key, str) or not _TOKEN.fullmatch(key):
                raise CatalogError(f"{label} contains an invalid field name")
            _walk_template(child, label)
        return
    if isinstance(value, list):
        for child in value:
            _walk_template(child, label)
        return
    if isinstance(value, str):
        if "{" in value or "}" in value:
            match = _PLACEHOLDER.fullmatch(value)
            if not match or match.group(1) not in CANONICAL_FIELDS:
                raise CatalogError(f"{label} contains unsupported placeholder {value!r}")
        return
    if value is None or isinstance(value, (bool, int, float)):
        return
    raise CatalogError(f"{label} contains an unsupported value type")


def _parse_options(raw: object, provider_id: str) -> dict[str, OptionSpec]:
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise CatalogError(f"provider {provider_id} options must be a table")
    result: dict[str, OptionSpec] = {}
    for name, item in raw.items():
        if not re.fullmatch(r"[a-z][a-z0-9_]*", name) or not isinstance(item, dict):
            raise CatalogError(f"provider {provider_id} has invalid option {name!r}")
        _unknown(item, {"kind", "default", "allowed"}, f"provider {provider_id} option {name}")
        kind = _string(item.get("kind"), f"provider {provider_id} option {name}.kind")
        if kind not in _OPTION_KINDS:
            raise CatalogError(f"provider {provider_id} option {name} has unknown kind {kind!r}")
        default = item.get("default")
        if default is not None:
            default = _string(default, f"provider {provider_id} option {name}.default")
        allowed_raw = item.get("allowed", [])
        if not isinstance(allowed_raw, list) or not all(isinstance(value, str) for value in allowed_raw):
            raise CatalogError(f"provider {provider_id} option {name}.allowed must be a string list")
        allowed = tuple(_string(value, f"provider {provider_id} option {name}.allowed") for value in allowed_raw)
        if kind == "enum":
            if not allowed or len(set(allowed)) != len(allowed):
                raise CatalogError(f"provider {provider_id} enum option {name} requires unique allowed values")
            if default is not None and default not in allowed:
                raise CatalogError(f"provider {provider_id} option {name} default is not allowed")
        elif allowed:
            raise CatalogError(f"provider {provider_id} domain option {name} cannot declare allowed values")
        result[name] = OptionSpec(kind, default, allowed)
    return result


def _parse_substitutions(
    raw: object, provider_id: str, options: Mapping[str, OptionSpec]
) -> dict[str, SubstitutionSpec]:
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise CatalogError(f"provider {provider_id} substitutions must be a table")
    result: dict[str, SubstitutionSpec] = {}
    for name, item in raw.items():
        if not re.fullmatch(r"[a-z][a-z0-9_]*", name) or not isinstance(item, dict):
            raise CatalogError(f"provider {provider_id} has invalid endpoint substitution {name!r}")
        _unknown(item, {"option", "values"}, f"provider {provider_id} substitution {name}")
        option = _string(item.get("option"), f"provider {provider_id} substitution {name}.option")
        if option not in options:
            raise CatalogError(f"provider {provider_id} substitution {name} references undeclared option {option}")
        values_raw = item.get("values")
        values: dict[str, str] | None = None
        if values_raw is not None:
            if options[option].kind != "enum" or not isinstance(values_raw, dict):
                raise CatalogError(f"provider {provider_id} substitution {name}.values requires an enum option")
            values = {}
            for key, value in values_raw.items():
                if key not in options[option].allowed:
                    raise CatalogError(f"provider {provider_id} substitution {name} maps undeclared value {key}")
                values[key] = _string(value, f"provider {provider_id} substitution {name}.values.{key}")
            if set(values) != set(options[option].allowed):
                raise CatalogError(f"provider {provider_id} substitution {name} must map every enum value")
        result[name] = SubstitutionSpec(option, values)
    return result


def _validate_endpoint_template(endpoint: str, substitutions: Mapping[str, SubstitutionSpec], provider_id: str) -> None:
    names = set(_ENDPOINT_PLACEHOLDER.findall(endpoint))
    if names != set(substitutions):
        raise CatalogError(f"provider {provider_id} endpoint substitutions do not exactly match the endpoint template")
    probe = endpoint
    for name in names:
        probe = probe.replace("{" + name + "}", "example")
    parsed = urllib.parse.urlsplit(probe)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username is not None or parsed.password is not None:
        raise CatalogError(f"provider {provider_id} endpoint must be an HTTPS URL without userinfo")


def _parse_provider(raw: Mapping[str, object]) -> Provider:
    allowed = {
        "id", "aliases", "display_name", "endpoint", "auth_mode", "auth_username",
        "auth_header", "encoding", "request_template", "success_statuses", "success_field",
        "success_value", "retry_statuses", "retry_body_field", "retry_body_unit",
        "options", "substitutions",
    }
    _unknown(raw, allowed, "provider")
    provider_id = _identifier(raw.get("id"), "provider.id")
    aliases_raw = raw.get("aliases", [])
    if not isinstance(aliases_raw, list):
        raise CatalogError(f"provider {provider_id} aliases must be a list")
    aliases = tuple(_identifier(value, f"provider {provider_id} alias") for value in aliases_raw)
    if len(set(aliases)) != len(aliases) or provider_id in aliases:
        raise CatalogError(f"provider {provider_id} aliases must be unique and not repeat the canonical ID")

    endpoint = _string(raw.get("endpoint"), f"provider {provider_id}.endpoint")
    auth_mode = _string(raw.get("auth_mode"), f"provider {provider_id}.auth_mode")
    if auth_mode not in _AUTH_MODES:
        raise CatalogError(f"provider {provider_id} has unsupported auth mode {auth_mode!r}")
    auth_username = raw.get("auth_username")
    auth_header = raw.get("auth_header")
    if auth_username is not None:
        auth_username = _string(auth_username, f"provider {provider_id}.auth_username")
    if auth_header is not None:
        auth_header = _string(auth_header, f"provider {provider_id}.auth_header")
        if not _TOKEN.fullmatch(auth_header):
            raise CatalogError(f"provider {provider_id} auth_header is not a valid HTTP field name")
    if auth_mode == "basic" and not auth_username:
        raise CatalogError(f"provider {provider_id} basic auth requires auth_username")
    if auth_mode == "fixed_header" and not auth_header:
        raise CatalogError(f"provider {provider_id} fixed_header auth requires auth_header")
    if auth_mode != "basic" and auth_username is not None:
        raise CatalogError(f"provider {provider_id} auth_username is not allowed for {auth_mode}")
    if auth_mode != "fixed_header" and auth_header is not None:
        raise CatalogError(f"provider {provider_id} auth_header is not allowed for {auth_mode}")

    encoding = _string(raw.get("encoding"), f"provider {provider_id}.encoding")
    if encoding not in _ENCODINGS:
        raise CatalogError(f"provider {provider_id} has unsupported encoding {encoding!r}")
    template_text = _string(raw.get("request_template"), f"provider {provider_id}.request_template")
    try:
        template = json.loads(template_text)
    except json.JSONDecodeError as exc:
        raise CatalogError(f"provider {provider_id} request_template must be JSON data") from exc
    if not isinstance(template, dict):
        raise CatalogError(f"provider {provider_id} request_template must be a JSON object")
    _walk_template(template, f"provider {provider_id} request_template")

    options = _parse_options(raw.get("options"), provider_id)
    substitutions = _parse_substitutions(raw.get("substitutions"), provider_id, options)
    _validate_endpoint_template(endpoint, substitutions, provider_id)
    success_statuses = _int_list(raw.get("success_statuses"), f"provider {provider_id}.success_statuses")
    retry_statuses = _int_list(raw.get("retry_statuses", []), f"provider {provider_id}.retry_statuses", allow_empty=True)
    if set(success_statuses) & set(retry_statuses):
        raise CatalogError(f"provider {provider_id} success and retry statuses overlap")

    success_field = raw.get("success_field")
    has_success_value = "success_value" in raw
    if success_field is not None:
        success_field = _string(success_field, f"provider {provider_id}.success_field")
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", success_field) or not has_success_value:
            raise CatalogError(f"provider {provider_id} success check must name one top-level field and value")
        if isinstance(raw.get("success_value"), (dict, list)) or raw.get("success_value") is None:
            raise CatalogError(f"provider {provider_id} success_value must be a scalar")
    elif has_success_value:
        raise CatalogError(f"provider {provider_id} success_value requires success_field")

    retry_body_field = raw.get("retry_body_field")
    retry_body_unit = raw.get("retry_body_unit")
    if retry_body_field is None and retry_body_unit is not None:
        raise CatalogError(f"provider {provider_id} retry_body_unit requires retry_body_field")
    if retry_body_field is not None:
        retry_body_field = _string(retry_body_field, f"provider {provider_id}.retry_body_field")
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", retry_body_field):
            raise CatalogError(f"provider {provider_id} retry_body_field must be one top-level field")
        if retry_body_unit is None:
            raise CatalogError(f"provider {provider_id} retry_body_field requires retry_body_unit")
        retry_body_unit = _string(retry_body_unit, f"provider {provider_id}.retry_body_unit")
        if retry_body_unit not in _RETRY_UNITS:
            raise CatalogError(f"provider {provider_id} has unsupported retry_body_unit {retry_body_unit!r}")
        if not retry_statuses:
            raise CatalogError(f"provider {provider_id} body retry delay requires at least one retry status")

    return Provider(
        provider_id=provider_id,
        aliases=aliases,
        display_name=_string(raw.get("display_name"), f"provider {provider_id}.display_name"),
        endpoint=endpoint,
        auth_mode=auth_mode,
        auth_username=auth_username,
        auth_header=auth_header,
        encoding=encoding,
        request_template=template,
        success_statuses=success_statuses,
        success_field=success_field,
        success_value=raw.get("success_value") if has_success_value else None,
        retry_statuses=retry_statuses,
        retry_body_field=retry_body_field,
        retry_body_unit=retry_body_unit,
        options=options,
        substitutions=substitutions,
    )


def load_catalog(path: Path = CATALOG_PATH) -> Catalog:
    try:
        with path.open("rb") as handle:
            raw = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise CatalogError(f"cannot load operational email provider catalog {path}: {exc}") from exc
    _unknown(raw, {"schema_version", "providers"}, "catalog")
    if raw.get("schema_version") != 1:
        raise CatalogError("email provider catalog requires schema_version = 1")
    providers_raw = raw.get("providers")
    if not isinstance(providers_raw, list) or not providers_raw:
        raise CatalogError("email provider catalog requires [[providers]] entries")
    providers: dict[str, Provider] = {}
    aliases: dict[str, str] = {}
    for item in providers_raw:
        if not isinstance(item, dict):
            raise CatalogError("each provider definition must be a table")
        provider = _parse_provider(item)
        if provider.provider_id in providers or provider.provider_id in aliases:
            raise CatalogError(f"duplicate provider identifier {provider.provider_id!r}")
        providers[provider.provider_id] = provider
        for alias in provider.aliases:
            if alias in providers or alias in aliases:
                raise CatalogError(f"duplicate provider alias {alias!r}")
            aliases[alias] = provider.provider_id
    expected = {"mailersend", "sendgrid", "mailgun", "postmark", "resend", "cyberpersons"}
    if set(providers) != expected or aliases != {"cyberpanel": "cyberpersons"}:
        raise CatalogError("catalog must define exactly the six V2 canonical providers and cyberpanel alias")
    return Catalog(providers, aliases)


def _validate_option(name: str, value: str, spec: OptionSpec) -> str:
    value = _string(value, f"notification provider option {name}")
    if spec.kind == "enum" and value not in spec.allowed:
        raise CatalogError(f"notification provider option {name} must be one of {', '.join(spec.allowed)}")
    if spec.kind == "domain" and not _DOMAIN.fullmatch(value):
        raise CatalogError(f"notification provider option {name} must be a DNS domain")
    return value


def validate_provider_options(provider: Provider, supplied: Mapping[str, str]) -> dict[str, str]:
    unknown = sorted(set(supplied) - set(provider.options))
    if unknown:
        raise CatalogError(f"undeclared option(s) for {provider.provider_id}: {', '.join(unknown)}")
    result: dict[str, str] = {}
    for name, spec in provider.options.items():
        if name in supplied:
            result[name] = _validate_option(name, supplied[name], spec)
        elif spec.default is not None:
            result[name] = _validate_option(name, spec.default, spec)
        else:
            raise CatalogError(f"provider {provider.provider_id} requires option {name}")
    return result


def _configured_options(config: object) -> dict[str, str]:
    raw = getattr(config, "notification_options", ())
    try:
        supplied = dict(raw)
    except (TypeError, ValueError) as exc:
        raise NotificationError("notification provider options are malformed") from exc
    if not all(isinstance(key, str) and isinstance(value, str) for key, value in supplied.items()):
        raise NotificationError("notification provider options must contain string keys and values")
    return supplied


def message_context(*, from_email: str, from_name: str, to_email: str, subject: str, text: str) -> dict[str, str]:
    values = {
        "from_email": from_email,
        "from_name": from_name,
        "to_email": to_email,
        "subject": subject,
        "text": text,
    }
    for key, value in values.items():
        if not isinstance(value, str) or not value or "\0" in value:
            raise NotificationError(f"notification {key} must be a non-empty string")
    for key in ("from_email", "from_name", "to_email", "subject"):
        if "\r" in values[key] or "\n" in values[key]:
            raise NotificationError(f"notification {key} must not contain CR/LF")
    for key in ("from_email", "to_email"):
        if values[key].count("@") != 1 or any(char.isspace() for char in values[key]):
            raise NotificationError(f"notification {key} must be a simple email address")
    result = {**values, "from_header": email.utils.formataddr((from_name, from_email))}
    if set(result) != CANONICAL_FIELDS:
        raise AssertionError("canonical notification message vocabulary drift")
    return result


def _render_value(value: object, context: Mapping[str, str]) -> object:
    if isinstance(value, dict):
        return {key: _render_value(child, context) for key, child in value.items()}
    if isinstance(value, list):
        return [_render_value(child, context) for child in value]
    if isinstance(value, str):
        match = _PLACEHOLDER.fullmatch(value)
        if match:
            return context[match.group(1)]
    return value


def _multipart_form(fields: Mapping[str, str]) -> tuple[str, bytes]:
    boundary = "vwoci-" + uuid.uuid4().hex
    chunks: list[bytes] = []
    for key, value in fields.items():
        if not _TOKEN.fullmatch(key):
            raise CatalogError("form template rendered an invalid field name")
        chunks.extend(
            [
                f"--{boundary}\r\n".encode("ascii"),
                f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode("ascii"),
                value.encode("utf-8"),
                b"\r\n",
            ]
        )
    chunks.append(f"--{boundary}--\r\n".encode("ascii"))
    return boundary, b"".join(chunks)


def render_request(
    provider: Provider,
    *,
    context: Mapping[str, str],
    token: str,
    options: Mapping[str, str] | None = None,
) -> RenderedRequest:
    if set(context) != CANONICAL_FIELDS:
        raise NotificationError("notification context must use exactly the canonical message fields")
    if not isinstance(token, str) or not token or any(char in token for char in "\0\r\n"):
        raise NotificationError("email_api_token is missing or malformed")
    selected = validate_provider_options(provider, options or {})
    endpoint = provider.endpoint
    for name, substitution in provider.substitutions.items():
        value = selected[substitution.option]
        replacement = substitution.values[value] if substitution.values is not None else value
        endpoint = endpoint.replace("{" + name + "}", replacement)
    parsed = urllib.parse.urlsplit(endpoint)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or _ENDPOINT_PLACEHOLDER.search(endpoint)
    ):
        raise CatalogError(f"provider {provider.provider_id} rendered an unsafe HTTPS endpoint")

    rendered = _render_value(provider.request_template, context)
    headers = {"Accept": "application/json", "User-Agent": "VaultWarden-OCI/2"}
    if provider.auth_mode == "bearer":
        headers["Authorization"] = "Bearer " + token
    elif provider.auth_mode == "fixed_header":
        assert provider.auth_header is not None
        headers[provider.auth_header] = token
    else:
        assert provider.auth_username is not None
        credentials = base64.b64encode((provider.auth_username + ":" + token).encode("utf-8")).decode("ascii")
        headers["Authorization"] = "Basic " + credentials

    if provider.encoding == "json":
        headers["Content-Type"] = "application/json"
        body = json.dumps(rendered, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    else:
        if not isinstance(rendered, dict) or not all(
            isinstance(key, str) and isinstance(value, str) for key, value in rendered.items()
        ):
            raise CatalogError(f"provider {provider.provider_id} form template must render to flat string fields")
        boundary, body = _multipart_form(rendered)
        headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
    return RenderedRequest(provider, endpoint, headers, body)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


def _retry_after(headers: Mapping[str, str] | None, now: float | None = None) -> float | None:
    if not headers:
        return None
    raw = headers.get("Retry-After")
    if raw is None:
        return None
    raw = raw.strip()
    delay: float | None = None
    if raw.isdigit():
        delay = float(raw)
    else:
        try:
            when = email.utils.parsedate_to_datetime(raw)
            if when.tzinfo is None:
                when = when.replace(tzinfo=timezone.utc)
            delay = when.timestamp() - (time.time() if now is None else now)
        except (TypeError, ValueError, OverflowError):
            return None
    if delay is None or not math.isfinite(delay):
        return None
    return max(0.0, min(delay, _MAX_RETRY_DELAY))


def _body_retry_after(provider: Provider, body: bytes) -> float | None:
    if provider.retry_body_field is None or provider.retry_body_unit is None:
        return None
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    value = payload.get(provider.retry_body_field)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    if value < 0 or not math.isfinite(value):
        return None
    seconds = value * _RETRY_UNITS[provider.retry_body_unit]
    return min(seconds, _MAX_RETRY_DELAY)


def _safe_reason(text: str) -> str:
    clean = " ".join(text.replace("\0", " ").replace("\r", " ").replace("\n", " ").split())
    return clean[:_MAX_DIAGNOSTIC]


def _response_result(provider: Provider, status: int, headers: Mapping[str, str], body: bytes) -> AttemptResult:
    if status in provider.success_statuses:
        if provider.success_field is None:
            return AttemptResult(True, False, "accepted", f"HTTP {status}")
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            return AttemptResult(False, False, "ambiguous_response", f"HTTP {status} success body was not valid JSON")
        if not isinstance(payload, dict) or payload.get(provider.success_field) != provider.success_value:
            return AttemptResult(False, False, "ambiguous_response", f"HTTP {status} did not satisfy the catalog success rule")
        return AttemptResult(True, False, "accepted", f"HTTP {status}")
    if status in provider.retry_statuses:
        delay = _retry_after(headers)
        if delay is None:
            delay = _body_retry_after(provider, body)
        return AttemptResult(False, True, "provider_transient", f"HTTP {status}", delay)
    return AttemptResult(False, False, "provider_rejected", f"HTTP {status}")


def _network_result(exc: BaseException) -> AttemptResult:
    reason: BaseException = exc
    if isinstance(exc, urllib.error.URLError) and isinstance(exc.reason, BaseException):
        reason = exc.reason
    if isinstance(reason, ssl.SSLCertVerificationError):
        return AttemptResult(False, False, "tls_verification", "TLS certificate/hostname verification failed")
    if isinstance(reason, ssl.SSLError):
        return AttemptResult(False, False, "tls_failure", "TLS handshake/validation failed")
    if isinstance(reason, (socket.timeout, TimeoutError)):
        return AttemptResult(False, True, "network_transient", "network timeout")
    if isinstance(reason, socket.gaierror):
        return AttemptResult(False, True, "network_transient", "DNS resolution failed")
    if isinstance(reason, (ConnectionError, OSError)):
        return AttemptResult(False, True, "network_transient", "network connection failed")
    return AttemptResult(False, False, "transport_error", "unexpected HTTPS transport failure")


def https_attempt(
    request: RenderedRequest,
    *,
    timeout: float = 15.0,
    opener: urllib.request.OpenerDirector | None = None,
) -> AttemptResult:
    opener = opener or urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ssl.create_default_context()), _NoRedirect()
    )
    http_request = urllib.request.Request(
        request.endpoint,
        data=request.body,
        headers=dict(request.headers),
        method="POST",
    )
    try:
        with opener.open(http_request, timeout=timeout) as response:
            status = int(response.status)
            headers = response.headers
            body = response.read(_MAX_RESPONSE)
        return _response_result(request.provider, status, headers, body)
    except urllib.error.HTTPError as exc:
        body = exc.read(_MAX_RESPONSE)
        return _response_result(request.provider, exc.code, exc.headers, body)
    except (urllib.error.URLError, ssl.SSLError, socket.timeout, TimeoutError, OSError) as exc:
        return _network_result(exc)
    except http.client.HTTPException:
        return AttemptResult(False, False, "transport_error", "invalid HTTP response")


def send_https(
    request: RenderedRequest,
    *,
    attempt: Callable[[RenderedRequest], AttemptResult] = https_attempt,
    sleep: Callable[[float], None] = time.sleep,
) -> AttemptResult:
    last = AttemptResult(False, False, "transport_error", "delivery was not attempted")
    for index in range(len(_FIXED_RETRY_SECONDS) + 1):
        last = attempt(request)
        if last.ok or not last.transient:
            return last
        if index < len(_FIXED_RETRY_SECONDS):
            delay = last.retry_after if last.retry_after is not None else _FIXED_RETRY_SECONDS[index]
            sleep(min(max(delay, 0.0), _MAX_RETRY_DELAY))
    return last


def send_smtp(*, config: object, secrets: Mapping[str, str], context: Mapping[str, str]) -> AttemptResult:
    username = secrets.get("smtp_username")
    password = secrets.get("smtp_password")
    if not username or not password:
        return AttemptResult(False, False, "smtp_unavailable", "SMTP fallback credentials are unavailable")
    host = getattr(config, "smtp_host", "")
    port = getattr(config, "smtp_port", 0)
    security = getattr(config, "smtp_security", "")
    timeout = getattr(config, "smtp_timeout_seconds", 15)
    message = EmailMessage()
    message["From"] = context["from_header"]
    message["To"] = context["to_email"]
    message["Subject"] = context["subject"]
    message.set_content(context["text"])
    tls = ssl.create_default_context()
    client = None
    try:
        if security == "force_tls":
            client = smtplib.SMTP_SSL(host, port, timeout=timeout, context=tls)
        elif security == "starttls":
            client = smtplib.SMTP(host, port, timeout=timeout)
            client.ehlo()
            client.starttls(context=tls)
            client.ehlo()
        else:
            return AttemptResult(False, False, "smtp_security", "SMTP fallback requires implicit TLS or STARTTLS")
        client.login(username, password)
        client.send_message(message, from_addr=context["from_email"], to_addrs=[context["to_email"]])
        return AttemptResult(True, False, "accepted", "authenticated SMTP accepted the message")
    except ssl.SSLCertVerificationError:
        return AttemptResult(False, False, "smtp_tls_verification", "SMTP TLS certificate/hostname verification failed")
    except ssl.SSLError:
        return AttemptResult(False, False, "smtp_tls_failure", "SMTP TLS handshake/validation failed")
    except (socket.timeout, TimeoutError, socket.gaierror, ConnectionError, OSError, smtplib.SMTPException):
        return AttemptResult(False, False, "smtp_failure", "authenticated SMTP fallback failed")
    finally:
        if client is not None:
            try:
                client.quit()
            except Exception:
                pass


def _now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def persist_result(result: DeliveryResult, path: Path = STATE_PATH) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.{os.getpid()}.tmp"
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(result.as_dict(), handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def load_result(path: Path = STATE_PATH) -> DeliveryResult | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError, json.JSONDecodeError):
        return DeliveryResult("unknown", "unknown", "unknown", "failure", "state_invalid", "last notification state is unreadable", "unknown")
    keys = {"event_id", "provider", "transport", "outcome", "category", "reason", "recorded_at"}
    if not isinstance(payload, dict) or set(payload) != keys or not all(isinstance(payload[key], str) for key in keys):
        return DeliveryResult("unknown", "unknown", "unknown", "failure", "state_invalid", "last notification state is invalid", "unknown")
    return DeliveryResult(**payload)


def deliver(
    *,
    event_id: str,
    config: object,
    secrets: Mapping[str, str],
    subject: str,
    text: str,
    catalog: Catalog | None = None,
    api_sender: Callable[[RenderedRequest], AttemptResult] | None = None,
    smtp_sender: Callable[..., AttemptResult] = send_smtp,
    state_path: Path = STATE_PATH,
) -> DeliveryResult:
    provider_name = getattr(config, "notification_provider", None)
    to_email = getattr(config, "notification_to_email", None)
    if not provider_name or not to_email:
        raise NotificationError("operational notifications are not configured")
    catalog = catalog or load_catalog()
    provider = catalog.resolve(provider_name)
    context = message_context(
        from_email=getattr(config, "smtp_from_email"),
        from_name=getattr(config, "smtp_from_name"),
        to_email=to_email,
        subject=subject,
        text=text,
    )
    request = render_request(
        provider,
        context=context,
        token=secrets.get("email_api_token", ""),
        options=_configured_options(config),
    )
    if api_sender is None:
        api_result = send_https(request)
    else:
        api_result = send_https(request, attempt=api_sender, sleep=lambda _: None)
    recorded_at = _now()
    if api_result.ok:
        result = DeliveryResult(event_id, provider.provider_id, "https", "success", api_result.category, _safe_reason(api_result.reason), recorded_at)
    elif api_result.transient:
        smtp_result = smtp_sender(config=config, secrets=secrets, context=context)
        if smtp_result.ok:
            result = DeliveryResult(event_id, provider.provider_id, "smtp_fallback", "success", "fallback_after_transient", _safe_reason(api_result.reason), recorded_at)
        else:
            result = DeliveryResult(event_id, provider.provider_id, "https+smtp", "failure", smtp_result.category, _safe_reason(smtp_result.reason), recorded_at)
    else:
        result = DeliveryResult(event_id, provider.provider_id, "https", "failure", api_result.category, _safe_reason(api_result.reason), recorded_at)
    persist_result(result, state_path)
    return result


def status_row(path: Path = STATE_PATH) -> dict[str, str]:
    result = load_result(path)
    if result is None:
        return {"kind": "notification", "state": "never", "transport": "-", "detail": "no delivery recorded"}
    # Delivery history is advisory. A past notification failure must stay visible
    # without turning an otherwise healthy periodic `vwctl status` into another
    # systemd failure notification and creating a persistent retry loop.
    state = "success" if result.outcome == "success" else "warning"
    return {
        "kind": "notification",
        "state": state,
        "transport": result.transport,
        "detail": f"{result.category} at {result.recorded_at}",
    }


def doctor_checks(
    *,
    config: object | None,
    secret_values: Mapping[str, str] | None,
    catalog_path: Path = CATALOG_PATH,
    state_path: Path = STATE_PATH,
) -> list[DoctorCheck]:
    try:
        catalog = load_catalog(catalog_path)
    except CatalogError as exc:
        return [
            DoctorCheck("notification.catalog", "FAIL", _safe_reason(str(exc))),
            DoctorCheck("notification.provider", "SKIP", "valid provider catalog is required"),
            DoctorCheck("notification.api_secret", "SKIP", "valid provider configuration is required"),
            DoctorCheck("notification.smtp_fallback", "SKIP", "valid provider configuration is required"),
            DoctorCheck("notification.last_delivery", "SKIP", "provider catalog is invalid"),
        ]
    checks = [DoctorCheck("notification.catalog", "PASS", "closed provider catalog is valid")]
    if config is None or not getattr(config, "notification_provider", None):
        checks.extend(
            [
                DoctorCheck("notification.provider", "SKIP", "operational notifications are not configured"),
                DoctorCheck("notification.api_secret", "SKIP", "operational notifications are not configured"),
                DoctorCheck("notification.smtp_fallback", "SKIP", "operational notifications are not configured"),
            ]
        )
    else:
        try:
            provider = catalog.resolve(getattr(config, "notification_provider"))
            validate_provider_options(provider, _configured_options(config))
        except (CatalogError, NotificationError) as exc:
            checks.append(DoctorCheck("notification.provider", "FAIL", _safe_reason(str(exc))))
        else:
            checks.append(DoctorCheck("notification.provider", "PASS", f"configured provider resolves to {provider.provider_id}"))
        if secret_values is None:
            checks.append(DoctorCheck("notification.api_secret", "SKIP", "decrypted secret values are unavailable"))
            checks.append(DoctorCheck("notification.smtp_fallback", "SKIP", "decrypted secret values are unavailable"))
        else:
            token = secret_values.get("email_api_token", "")
            checks.append(
                DoctorCheck(
                    "notification.api_secret",
                    "PASS" if token else "FAIL",
                    "email_api_token is present" if token else "required email_api_token is missing",
                )
            )
            fallback = bool(secret_values.get("smtp_username") and secret_values.get("smtp_password"))
            secure = getattr(config, "smtp_security", "") in {"starttls", "force_tls"}
            checks.append(
                DoctorCheck(
                    "notification.smtp_fallback",
                    "PASS" if fallback and secure else "WARN",
                    "authenticated TLS SMTP fallback is configured" if fallback and secure else "authenticated TLS SMTP fallback is not configured",
                )
            )
    last = load_result(state_path)
    if last is None:
        checks.append(DoctorCheck("notification.last_delivery", "SKIP", "no operational delivery has been recorded"))
    elif last.outcome == "success":
        checks.append(DoctorCheck("notification.last_delivery", "PASS", f"last delivery succeeded via {last.transport}"))
    else:
        checks.append(DoctorCheck("notification.last_delivery", "WARN", f"last delivery failed: {last.category}"))
    return checks
