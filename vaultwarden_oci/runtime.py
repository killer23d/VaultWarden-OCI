"""Vaultwarden + Caddy runtime rendering and lifecycle for V2."""
from __future__ import annotations

import grp
import json
import os
import pwd
import re
import stat
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping, Sequence

from . import edge, secrets
from .cli import CommandResult, DoctorCheck, mutation_lock, run_command
from .update_versions import FrozenVersions, UpdateError, resolve_pinned_file

ETC = Path("/etc/vaultwarden-oci")
STATE = Path("/var/lib/vaultwarden-oci")
RUN = Path("/run/vaultwarden-oci")
CONFIG = ETC / "config.toml"
TRANSIENT = RUN / "transient"
LOCK = RUN / "lock"
VAULTWARDEN_UID = VAULTWARDEN_GID = 65532
CADDY_UID = CADDY_GID = 65533
NAMES = {"vaultwarden": "vaultwarden-oci-vaultwarden", "caddy": "vaultwarden-oci-caddy"}
_HOST = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
_OPTION_NAME = re.compile(r"^[a-z][a-z0-9_]*$")


class RuntimeConfigError(ValueError):
    pass


class RuntimeErrorV2(RuntimeError):
    pass


@dataclass(frozen=True)
class RuntimeConfig:
    domain: str
    acme_email: str
    offline_recovery_recipient: str
    signups_allowed: bool
    smtp_host: str
    smtp_port: int
    smtp_security: str
    smtp_from_email: str
    smtp_from_name: str
    smtp_timeout_seconds: int
    notification_provider: str | None = None
    notification_to_email: str | None = None
    notification_options: tuple[tuple[str, str], ...] = ()


@dataclass(frozen=True)
class Paths:
    config: Path = CONFIG
    data: Path = STATE / "data"
    caddy_data: Path = STATE / "caddy/data"
    caddy_config: Path = STATE / "caddy/config"
    caddy_log: Path | None = None
    run: Path = RUN
    transient: Path = TRANSIENT
    lock: Path = LOCK
    secret_root: Path = secrets.RUN

    @property
    def compose(self) -> Path:
        return self.transient / "compose.yaml"

    @property
    def caddyfile(self) -> Path:
        return self.transient / "Caddyfile"

    @property
    def dockerfile(self) -> Path:
        return self.transient / "Caddy.Dockerfile"

    @property
    def caddy_log_path(self) -> Path:
        return self.caddy_log if self.caddy_log is not None else self.caddy_data.parent / "log"

    def secret_paths(self) -> secrets.SecretPaths:
        return secrets.SecretPaths(
            root=self.secret_root,
            vaultwarden=self.secret_root / "vaultwarden",
            caddy=self.secret_root / "caddy",
        )


Runner = Callable[..., CommandResult]


def _mapping(data: Mapping[str, object], key: str) -> Mapping[str, object]:
    value = data.get(key)
    if not isinstance(value, dict):
        raise RuntimeConfigError(f"config requires [{key}]")
    return value


def _unknown(data: Mapping[str, object], allowed: set[str], label: str) -> None:
    unknown = sorted(set(data) - allowed)
    if unknown:
        raise RuntimeConfigError(f"unknown {label} setting(s): {', '.join(unknown)}")


def _string(data: Mapping[str, object], key: str, label: str) -> str:
    value = data.get(key)
    if (
        not isinstance(value, str)
        or not value
        or value.strip() != value
        or any(c in value for c in "\0\r\n")
    ):
        raise RuntimeConfigError(f"{label}.{key} must be a non-empty single-line string")
    return value


def _hostname(value: str, label: str, *, fqdn: bool = False) -> str:
    if "://" in value or "/" in value or ":" in value:
        raise RuntimeConfigError(f"{label} must be a hostname without scheme/path/port")
    value = value.lower().rstrip(".")
    parts = value.split(".")
    if len(value) > 253 or (fqdn and len(parts) < 2) or not all(_HOST.fullmatch(part) for part in parts):
        raise RuntimeConfigError(f"{label} is not a valid hostname")
    if fqdn and (value == "example.com" or value.endswith(".example")):
        raise RuntimeConfigError(f"{label} uses a reserved example domain")
    return value


def _email(value: str, label: str) -> str:
    if value.count("@") != 1 or value.startswith("@") or value.endswith("@") or " " in value:
        raise RuntimeConfigError(f"{label} must be a simple email address")
    return value


def parse_config(data: Mapping[str, object]) -> RuntimeConfig:
    _unknown(data, {"schema_version", "site", "secrets", "vaultwarden", "smtp", "notifications"}, "top-level")
    if data.get("schema_version") != 1:
        raise RuntimeConfigError("config requires schema_version = 1")
    site, secret_cfg, vw, smtp = (
        _mapping(data, key) for key in ("site", "secrets", "vaultwarden", "smtp")
    )
    notifications_raw = data.get("notifications")
    if notifications_raw is None:
        notifications: Mapping[str, object] | None = None
    elif isinstance(notifications_raw, dict):
        notifications = notifications_raw
    else:
        raise RuntimeConfigError("config [notifications] must be a table")
    _unknown(site, {"domain", "acme_email"}, "site")
    _unknown(secret_cfg, {"offline_recovery_recipient"}, "secrets")
    _unknown(vw, {"signups_allowed"}, "vaultwarden")
    _unknown(
        smtp,
        {"host", "port", "security", "from_email", "from_name", "timeout_seconds"},
        "smtp",
    )
    offline = _string(secret_cfg, "offline_recovery_recipient", "secrets")
    try:
        secrets.validate_recipient(offline)
    except secrets.SecretsError as exc:
        raise RuntimeConfigError(str(exc)) from exc
    signups = vw.get("signups_allowed")
    port = smtp.get("port")
    timeout = smtp.get("timeout_seconds")
    security = _string(smtp, "security", "smtp")
    if not isinstance(signups, bool):
        raise RuntimeConfigError("vaultwarden.signups_allowed must be true or false")
    if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
        raise RuntimeConfigError("smtp.port must be 1..65535")
    if security not in {"starttls", "force_tls"}:
        raise RuntimeConfigError("smtp.security must be 'starttls' or 'force_tls'")
    if not isinstance(timeout, int) or isinstance(timeout, bool) or not 1 <= timeout <= 120:
        raise RuntimeConfigError("smtp.timeout_seconds must be 1..120")

    notification_provider = notification_to_email = None
    notification_options: tuple[tuple[str, str], ...] = ()
    if notifications is not None:
        _unknown(notifications, {"provider", "to_email", "options"}, "notifications")
        notification_provider = _string(notifications, "provider", "notifications").lower()
        notification_to_email = _email(
            _string(notifications, "to_email", "notifications"),
            "notifications.to_email",
        )
        options_raw = notifications.get("options", {})
        if not isinstance(options_raw, dict):
            raise RuntimeConfigError("notifications.options must be a table")
        supplied: dict[str, str] = {}
        for name, value in options_raw.items():
            if not isinstance(name, str) or not _OPTION_NAME.fullmatch(name):
                raise RuntimeConfigError("notifications.options keys must be lowercase provider option identifiers")
            if (
                not isinstance(value, str)
                or not value
                or value.strip() != value
                or any(c in value for c in "\0\r\n")
            ):
                raise RuntimeConfigError(
                    f"notifications.options.{name} must be a non-empty single-line string"
                )
            supplied[name] = value
        from . import notification
        try:
            provider = notification.load_catalog().resolve(notification_provider)
            notification.validate_provider_options(provider, supplied)
        except notification.CatalogError as exc:
            raise RuntimeConfigError(str(exc)) from exc
        notification_options = tuple(sorted(supplied.items()))

    return RuntimeConfig(
        domain=_hostname(_string(site, "domain", "site"), "site.domain", fqdn=True),
        acme_email=_email(_string(site, "acme_email", "site"), "site.acme_email"),
        offline_recovery_recipient=offline,
        signups_allowed=signups,
        smtp_host=_hostname(_string(smtp, "host", "smtp"), "smtp.host"),
        smtp_port=port,
        smtp_security=security,
        smtp_from_email=_email(_string(smtp, "from_email", "smtp"), "smtp.from_email"),
        smtp_from_name=_string(smtp, "from_name", "smtp"),
        smtp_timeout_seconds=timeout,
        notification_provider=notification_provider,
        notification_to_email=notification_to_email,
        notification_options=notification_options,
    )


def load_config(path: Path = CONFIG) -> RuntimeConfig:
    try:
        with path.open("rb") as handle:
            return parse_config(tomllib.load(handle))
    except RuntimeConfigError:
        raise
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise RuntimeConfigError(f"cannot load config {path}: {exc}") from exc


def _pins(path: Path) -> FrozenVersions:
    try:
        return resolve_pinned_file(path)
    except UpdateError as exc:
        raise RuntimeErrorV2(str(exc)) from exc


def _service_identity_error() -> str | None:
    collisions: list[str] = []
    for label, uid in (("Vaultwarden", VAULTWARDEN_UID), ("Caddy", CADDY_UID)):
        try:
            account = pwd.getpwuid(uid)
        except KeyError:
            pass
        else:
            collisions.append(f"{label} uid {uid} is allocated to host account {account.pw_name}")
    for label, gid in (("Vaultwarden", VAULTWARDEN_GID), ("Caddy", CADDY_GID)):
        try:
            group = grp.getgrgid(gid)
        except KeyError:
            pass
        else:
            collisions.append(f"{label} gid {gid} is allocated to host group {group.gr_name}")
    return "; ".join(collisions) if collisions else None


def validate_service_identities() -> None:
    problem = _service_identity_error()
    if problem:
        raise RuntimeErrorV2(problem)


def _dir(path: Path, uid: int, gid: int, mode: int) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chown(path, uid, gid)
    os.chmod(path, mode)
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise RuntimeErrorV2(f"incompatible runtime path: {path}")
    if (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (uid, gid, mode):
        raise RuntimeErrorV2(f"incompatible ownership/mode at runtime path: {path}")


def ensure_paths(
    paths: Paths,
    *,
    uid: int = 0,
    gid: int = 0,
    vaultwarden_uid: int = VAULTWARDEN_UID,
    vaultwarden_gid: int = VAULTWARDEN_GID,
    caddy_uid: int = CADDY_UID,
    caddy_gid: int = CADDY_GID,
) -> None:
    _dir(paths.run, uid, gid, 0o700)
    _dir(paths.transient, uid, gid, 0o700)
    _dir(paths.data, vaultwarden_uid, vaultwarden_gid, 0o700)
    _dir(paths.caddy_data, caddy_uid, caddy_gid, 0o700)
    _dir(paths.caddy_config, caddy_uid, caddy_gid, 0o700)
    _dir(paths.caddy_log_path, caddy_uid, caddy_gid, 0o700)
    secrets.ensure_runtime(
        paths.secret_paths(),
        uid=uid,
        gid=gid,
        vaultwarden_gid=vaultwarden_gid,
        caddy_gid=caddy_gid,
    )


def _write(path: Path, text: str, mode: int) -> None:
    tmp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    fd = os.open(
        tmp,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        mode,
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        os.chmod(path, mode)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def render(
    config: RuntimeConfig,
    versions_path: Path,
    paths: Paths = Paths(),
    *,
    admin_enabled: bool = False,
) -> None:
    frozen = _pins(versions_path)
    q = json.dumps
    signups = "true" if config.signups_allowed else "false"
    vw_command = (
        'export SMTP_USERNAME="$(cat /run/vw-secrets/smtp_username)"; '
        'export SMTP_PASSWORD="$(cat /run/vw-secrets/smtp_password)"; '
        'if [ -s /run/vw-secrets/vaultwarden_admin_token ]; then '
        'export ADMIN_TOKEN="$(cat /run/vw-secrets/vaultwarden_admin_token)"; fi; exec /start.sh'
    )
    caddy_command = (
        'export CLOUDFLARE_API_TOKEN="$(cat /run/caddy-secrets/cloudflare_api_token)"; '
        'if [ -s /run/caddy-secrets/admin_basic_auth_hash ]; then '
        'export ADMIN_BASIC_AUTH_HASH="$(cat /run/caddy-secrets/admin_basic_auth_hash)"; fi; '
        'exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile'
    )
    compose = f'''name: vaultwarden-oci
services:
  vaultwarden:
    image: {q(frozen.vaultwarden_image.reference)}
    container_name: {NAMES["vaultwarden"]}
    user: "{VAULTWARDEN_UID}:{VAULTWARDEN_GID}"
    restart: unless-stopped
    command: ["/bin/sh", "-ec", {q(vw_command)}]
    environment:
      DOMAIN: {q("https://" + config.domain)}
      ROCKET_ADDRESS: "0.0.0.0"
      ROCKET_PORT: "8080"
      SIGNUPS_ALLOWED: "{signups}"
      SMTP_HOST: {q(config.smtp_host)}
      SMTP_PORT: {q(str(config.smtp_port))}
      SMTP_SECURITY: {q(config.smtp_security)}
      SMTP_FROM: {q(config.smtp_from_email)}
      SMTP_FROM_NAME: {q(config.smtp_from_name)}
      SMTP_TIMEOUT: {q(str(config.smtp_timeout_seconds))}
    volumes: [{q(str(paths.data) + ":/data")}, {q(str(paths.secret_root / "vaultwarden") + ":/run/vw-secrets:ro")}]
    read_only: true
    tmpfs: ["/tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777"]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    pids_limit: 200
    mem_limit: 512m
    healthcheck: {{test: ["CMD", "/healthcheck.sh"], interval: 30s, timeout: 10s, retries: 5, start_period: 30s}}
    logging: {{driver: json-file, options: {{max-size: "10m", max-file: "3"}}}}
    networks: [backend]
  caddy:
    build: {{context: ., dockerfile: Caddy.Dockerfile}}
    image: {q(frozen.caddy_image)}
    container_name: {NAMES["caddy"]}
    user: "{CADDY_UID}:{CADDY_GID}"
    # Phase 4 fail-closed rule: Docker must not republish Caddy after daemon/host
    # restart before the project-owned DOCKER-USER policy is re-established.
    restart: "no"
    command: ["/bin/sh", "-ec", {q(caddy_command)}]
    depends_on: {{vaultwarden: {{condition: service_healthy}}}}
    environment: {{VAULTWARDEN_DOMAIN: {q(config.domain)}, ACME_EMAIL: {q(config.acme_email)}}}
    ports: ["443:443/tcp"]
    volumes: ["./Caddyfile:/etc/caddy/Caddyfile:ro", {q(str(paths.caddy_data) + ":/data")}, {q(str(paths.caddy_config) + ":/config")}, {q(str(paths.caddy_log_path) + ":/var/log/caddy")}, {q(str(paths.secret_root / "caddy") + ":/run/caddy-secrets:ro")}]
    read_only: true
    tmpfs: ["/tmp:rw,noexec,nosuid,nodev,size=32m,mode=1777"]
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: ["no-new-privileges:true"]
    pids_limit: 100
    mem_limit: 256m
    healthcheck: {{test: ["CMD", "curl", "--fail", "--silent", "--show-error", "--output", "/dev/null", "http://127.0.0.1:2019/config/"], interval: 30s, timeout: 10s, retries: 3, start_period: 10s}}
    logging: {{driver: json-file, options: {{max-size: "10m", max-file: "3"}}}}
    networks: [backend]
networks:
  backend:
    name: vaultwarden-oci-backend
    driver: bridge
    enable_ipv6: true
    driver_opts:
      com.docker.network.bridge.name: {q(edge.BRIDGE_IFACE)}
      com.docker.network.bridge.gateway_mode_ipv4: nat
      com.docker.network.bridge.gateway_mode_ipv6: nat
'''
    admin_route = f''' @admin path /admin*
 handle @admin {{
  rate_limit {{
   zone admin {{
    key {{client_ip}}
    events 5
    window 5m
   }}
  }}
  request_body {{
   max_size 2MB
  }}
  basic_auth {{
   admin {{env.ADMIN_BASIC_AUTH_HASH}}
  }}
  reverse_proxy vaultwarden:8080
 }}
''' if admin_enabled else ''' @admin path /admin*
 respond @admin 404
'''
    caddyfile = f'''{{
 email {{$ACME_EMAIL}}
 admin 127.0.0.1:2019
 persist_config off
 order rate_limit before basic_auth
 servers {{
  trusted_proxies cloudflare {{
   timeout 15s
  }}
  trusted_proxies_strict
  client_ip_headers CF-Connecting-IP
 }}
}}
{{$VAULTWARDEN_DOMAIN}} {{
 tls {{
  dns cloudflare {{env.CLOUDFLARE_API_TOKEN}}
  resolvers 1.1.1.1 1.0.0.1
 }}
 log {{
  output file /var/log/caddy/access.log {{
   mode 0600
   roll_size 10MiB
   roll_keep 5
   roll_keep_for 168h
  }}
  format json
 }}
 header {{
  Strict-Transport-Security "max-age=31536000; includeSubDomains"
  X-Content-Type-Options "nosniff"
  Referrer-Policy "same-origin"
  -Server
 }}
 encode zstd gzip
{admin_route} @auth path /identity/connect/token* /api/accounts/prelogin* /api/accounts/register*
 handle @auth {{
  rate_limit {{
   zone auth {{
    key {{client_ip}}
    events 10
    window 1m
   }}
  }}
  request_body {{
   max_size 512KB
  }}
  reverse_proxy vaultwarden:8080
 }}
 handle {{
  reverse_proxy vaultwarden:8080
 }}
}}
'''
    dockerfile = f'''FROM {frozen.caddy_builder_image.reference} AS builder
RUN xcaddy build \\
    --with github.com/caddy-dns/cloudflare@{frozen.caddy_dns_cloudflare} \\
    --with github.com/WeidiDeng/caddy-cloudflare-ip@{frozen.caddy_cloudflare_ip} \\
    --with github.com/fvbommel/caddy-combine-ip-ranges@{frozen.caddy_combine_ip_ranges} \\
    --with github.com/mholt/caddy-ratelimit@{frozen.caddy_ratelimit}
FROM {frozen.caddy_runtime_image.reference}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
'''
    _write(paths.compose, compose, 0o600)
    _write(paths.caddyfile, caddyfile, 0o444)
    _write(paths.dockerfile, dockerfile, 0o600)


def _compose(args: Sequence[str], paths: Paths, runner: Runner) -> CommandResult:
    return runner(["docker", "compose", "-f", str(paths.compose), *args])


def tools(runner: Runner = run_command) -> bool:
    docker = runner(["docker", "version", "--format", "{{.Server.Version}}"])
    compose = runner(["docker", "compose", "version", "--short"])
    help_result = runner(["docker", "compose", "up", "--help"]) if compose.ok else None
    return (
        docker.ok
        and compose.ok
        and help_result is not None
        and help_result.ok
        and "--wait" in help_result.stdout
        and "--wait-timeout" in help_result.stdout
    )


def _inspect_is_absent(result: CommandResult) -> bool:
    if result.ok:
        return False
    message = (result.stderr or result.stdout).lower()
    return "no such object" in message or "no such container" in message


def lifecycle(
    action: str,
    *,
    paths: Paths = Paths(),
    versions_path: Path | None = None,
    runner: Runner = run_command,
) -> None:
    if action not in {"start", "stop", "restart"}:
        raise ValueError(action)
    default_paths = paths == Paths()
    if default_paths and os.geteuid() != 0:
        raise RuntimeErrorV2(f"vwctl {action} must run as root")
    versions_path = versions_path or Path(__file__).resolve().parents[1] / "versions.toml"
    if default_paths:
        validate_service_identities()
        uid = gid = 0
        vaultwarden_uid, vaultwarden_gid = VAULTWARDEN_UID, VAULTWARDEN_GID
        caddy_uid, caddy_gid = CADDY_UID, CADDY_GID
    else:
        uid, gid = os.geteuid(), os.getegid()
        vaultwarden_uid = caddy_uid = uid
        vaultwarden_gid = caddy_gid = gid

    with mutation_lock(paths.lock):
        if action == "stop":
            if not runner(["docker", "version", "--format", "{{.Server.Version}}"] ).ok:
                raise RuntimeErrorV2("Docker Engine unavailable; stop state unknown")
            existing: list[str] = []
            for name in ("caddy", "vaultwarden"):
                container = NAMES[name]
                inspection = runner(["docker", "container", "inspect", container])
                if inspection.ok:
                    existing.append(container)
                elif not _inspect_is_absent(inspection):
                    raise RuntimeErrorV2("Docker container inspection failed; stop state unknown")
            if existing and not runner(["docker", "stop", *existing]).ok:
                raise RuntimeErrorV2("Docker stop failed")
            removed = not existing or runner(["docker", "rm", *existing]).ok
            secrets.cleanup(paths.secret_paths())
            if not removed:
                raise RuntimeErrorV2("Docker container removal failed after stop")
            return

        if not tools(runner):
            raise RuntimeErrorV2("Docker Engine + Compose with up --wait --wait-timeout are required")
        ensure_paths(
            paths,
            uid=uid,
            gid=gid,
            vaultwarden_uid=vaultwarden_uid,
            vaultwarden_gid=vaultwarden_gid,
            caddy_uid=caddy_uid,
            caddy_gid=caddy_gid,
        )
        config = load_config(paths.config)
        if default_paths:
            try:
                edge.refresh_origin_policy(runner=runner)
            except edge.EdgeError as exc:
                raise RuntimeErrorV2(str(exc)) from exc
        values = secrets.load(
            config.offline_recovery_recipient,
            paths=paths.secret_paths(),
            runner=runner,
            uid=uid,
        )
        admin_enabled = secrets.admin_enabled(values)
        derived: dict[str, str] = {}
        if admin_enabled:
            frozen = _pins(versions_path)
            derived["admin_basic_auth_hash"] = secrets.derive_admin_basic_auth_hash(
                values["admin_basic_auth_password"], frozen.caddy_runtime_image.reference
            )
        render(config, versions_path, paths, admin_enabled=admin_enabled)
        if not _compose(["config", "--quiet"], paths, runner).ok:
            raise RuntimeErrorV2("rendered Compose validation failed")
        secrets.materialize(
            values,
            derived=derived,
            paths=paths.secret_paths(),
            uid=uid,
            gid=gid,
            vaultwarden_gid=vaultwarden_gid,
            caddy_gid=caddy_gid,
        )
        args = ["up", "-d", "--build", "--wait", "--wait-timeout", "120"]
        if action == "restart":
            args.append("--force-recreate")
        if not _compose(args, paths, runner).ok:
            _compose(["down"], paths, runner)
            secrets.cleanup(paths.secret_paths())
            raise RuntimeErrorV2("Docker Compose lifecycle failed")


def status(*, runner: Runner = run_command) -> tuple[str, list[dict[str, str]]]:
    if not runner(["docker", "version", "--format", "{{.Server.Version}}"] ).ok:
        return "unavailable", [
            {"service": name, "state": "unknown", "health": "unknown"}
            for name in ("vaultwarden", "caddy")
        ]
    rows: list[dict[str, str]] = []
    for name in ("vaultwarden", "caddy"):
        result = runner(
            ["docker", "container", "inspect", "--format", "{{json .State}}", NAMES[name]]
        )
        if not result.ok:
            if _inspect_is_absent(result):
                rows.append({"service": name, "state": "absent", "health": "-"})
            else:
                rows.append({"service": name, "state": "unknown", "health": "unknown"})
            continue
        try:
            state = json.loads(result.stdout)
            if not isinstance(state, dict):
                raise TypeError
            current = state.get("Status", "unknown")
            health_state = state.get("Health")
            health = health_state.get("Status", "-") if isinstance(health_state, dict) else "-"
        except (json.JSONDecodeError, TypeError, AttributeError):
            current = health = "unknown"
        rows.append({"service": name, "state": str(current), "health": str(health)})

    if all(row["state"] == "absent" for row in rows):
        overall = "stopped"
    elif all(
        row["state"] == "running" and row["health"] in {"healthy", "-"}
        for row in rows
    ):
        overall = "running"
    else:
        overall = "degraded"
    return overall, rows


def logs(service: str | None, *, tail: int = 200, runner: Runner = run_command):
    results = []
    code = 0
    for name in ((service,) if service else ("vaultwarden", "caddy")):
        result = runner(["docker", "logs", "--tail", str(tail), NAMES[name]])
        results.append((name, result))
        if not result.ok:
            code = 1
    return code, results


def _directory_problem(path: Path, uid: int, gid: int, mode: int) -> str | None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return f"missing directory {path}"
    except OSError as exc:
        return f"cannot inspect {path}: {exc}"
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        return f"expected directory at {path}"
    actual_mode = stat.S_IMODE(info.st_mode)
    if (info.st_uid, info.st_gid, actual_mode) != (uid, gid, mode):
        return (
            f"incompatible ownership/mode at {path}: "
            f"got {info.st_uid}:{info.st_gid} {actual_mode:04o}, expected {uid}:{gid} {mode:04o}"
        )
    return None


def _file_problem(path: Path, uid: int, gid: int, mode: int) -> str | None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return f"missing file {path}"
    except OSError as exc:
        return f"cannot inspect {path}: {exc}"
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        return f"expected regular file at {path}"
    actual_mode = stat.S_IMODE(info.st_mode)
    if (info.st_uid, info.st_gid, actual_mode) != (uid, gid, mode):
        return (
            f"incompatible ownership/mode at {path}: "
            f"got {info.st_uid}:{info.st_gid} {actual_mode:04o}, expected {uid}:{gid} {mode:04o}"
        )
    return None


def runtime_paths_check(
    paths: Paths = Paths(),
    *,
    uid: int = 0,
    gid: int = 0,
    vaultwarden_uid: int = VAULTWARDEN_UID,
    vaultwarden_gid: int = VAULTWARDEN_GID,
    caddy_uid: int = CADDY_UID,
    caddy_gid: int = CADDY_GID,
    check_service_identities: bool = True,
) -> DoctorCheck:
    if check_service_identities:
        identity_problem = _service_identity_error()
        if identity_problem:
            return DoctorCheck("runtime.paths", "FAIL", identity_problem)

    base_checks = (
        _directory_problem(paths.run, uid, gid, 0o700),
        _directory_problem(paths.transient, uid, gid, 0o700),
        _directory_problem(paths.secret_root, uid, gid, 0o700),
        _file_problem(paths.lock, uid, gid, 0o600),
    )
    problems = [problem for problem in base_checks if problem]
    if problems:
        return DoctorCheck("runtime.paths", "FAIL", "; ".join(problems))

    secret_paths = paths.secret_paths()
    runtime_directories = (
        (paths.data, vaultwarden_uid, vaultwarden_gid, 0o700),
        (paths.caddy_data, caddy_uid, caddy_gid, 0o700),
        (paths.caddy_config, caddy_uid, caddy_gid, 0o700),
        (paths.caddy_log_path, caddy_uid, caddy_gid, 0o700),
        (secret_paths.vaultwarden, uid, vaultwarden_gid, 0o750),
        (secret_paths.caddy, uid, caddy_gid, 0o750),
    )
    present = [path.exists() or path.is_symlink() for path, *_ in runtime_directories]
    if not any(present):
        return DoctorCheck("runtime.paths", "SKIP", "runtime paths are not materialized yet")
    if not all(present):
        return DoctorCheck("runtime.paths", "FAIL", "runtime paths are only partially materialized")

    problems = [
        problem
        for path, owner_uid, owner_gid, mode in runtime_directories
        if (problem := _directory_problem(path, owner_uid, owner_gid, mode))
    ]
    rendered = (
        (paths.compose, uid, gid, 0o600),
        (paths.caddyfile, uid, gid, 0o444),
        (paths.dockerfile, uid, gid, 0o600),
    )
    rendered_present = [path.exists() or path.is_symlink() for path, *_ in rendered]
    if any(rendered_present) and not all(rendered_present):
        problems.append("rendered runtime files are only partially materialized")
    elif all(rendered_present):
        problems.extend(
            problem
            for path, owner_uid, owner_gid, mode in rendered
            if (problem := _file_problem(path, owner_uid, owner_gid, mode))
        )

    secret_files = [secret_paths.file(key) for key in secrets.REQUIRED]
    secret_present = [path.exists() or path.is_symlink() for path in secret_files]
    if any(secret_present) and not all(secret_present):
        problems.append("required volatile secret files are only partially materialized")
    elif all(secret_present):
        for key in secrets.REQUIRED:
            path = secret_paths.file(key)
            secret_gid = caddy_gid if key == "cloudflare_api_token" else vaultwarden_gid
            problem = _file_problem(path, uid, secret_gid, 0o440)
            if problem:
                problems.append(problem)

    if problems:
        return DoctorCheck("runtime.paths", "FAIL", "; ".join(problems))
    return DoctorCheck("runtime.paths", "PASS", "runtime ownership and modes are valid")


def doctor_checks(
    *,
    config_path: Path = CONFIG,
    paths: Paths = Paths(),
    runner: Runner = run_command,
    **_,
):
    checks = [
        DoctorCheck(
            "runtime.docker",
            "PASS" if runner(["docker", "version", "--format", "{{.Server.Version}}"] ).ok else "FAIL",
            "Docker Engine availability",
        ),
        DoctorCheck(
            "runtime.compose",
            "PASS" if tools(runner) else "FAIL",
            "Compose up --wait support",
        ),
        runtime_paths_check(paths),
    ]

    try:
        config = load_config(config_path)
    except RuntimeConfigError:
        checks.extend(
            [
                DoctorCheck("secrets.custody", "SKIP", "valid runtime config is required"),
                DoctorCheck("secrets.decrypt", "SKIP", "valid runtime config is required"),
            ]
        )
        return checks

    secret_paths = paths.secret_paths()
    try:
        secrets.validate_custody(
            config.offline_recovery_recipient,
            paths=secret_paths,
            runner=runner,
        )
    except secrets.SecretsError as exc:
        checks.extend(
            [
                DoctorCheck("secrets.custody", "FAIL", str(exc)),
                DoctorCheck("secrets.decrypt", "SKIP", "secret custody validation failed"),
            ]
        )
        return checks

    checks.append(DoctorCheck("secrets.custody", "PASS", "Age/SOPS custody valid"))
    try:
        values = secrets.decrypt(paths=secret_paths, runner=runner)
    except secrets.SecretsError as exc:
        checks.append(DoctorCheck("secrets.decrypt", "FAIL", str(exc)))
    else:
        if "cloudflare_remediation_token" not in values:
            checks.append(
                DoctorCheck(
                    "secrets.decrypt",
                    "FAIL",
                    "required Phase 4 cloudflare_remediation_token is missing",
                )
            )
        else:
            checks.append(DoctorCheck("secrets.decrypt", "PASS", "required Phase 3/4 secrets decrypt"))
    return checks


RuntimePaths = Paths
parse_runtime_config = parse_config
load_runtime_config = load_config
DATA_DIR = STATE / "data"
CADDY_DATA_DIR = STATE / "caddy/data"
CADDY_CONFIG_DIR = STATE / "caddy/config"
CADDY_LOG_DIR = STATE / "caddy/log"
RUNTIME_ROOT = RUN
RUNTIME_TRANSIENT_DIR = TRANSIENT
STATE_ROOT = STATE
CONFIG_PATH = CONFIG
