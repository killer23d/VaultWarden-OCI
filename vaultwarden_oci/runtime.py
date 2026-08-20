"""Vaultwarden + Caddy Phase 3 runtime rendering and lifecycle."""
from __future__ import annotations

import json
import os
import re
import stat
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping, Sequence

from . import secrets
from .cli import CommandResult, DoctorCheck, VersionsError, load_versions, mutation_lock, run_command

ETC = Path("/etc/vaultwarden-oci")
STATE = Path("/var/lib/vaultwarden-oci")
RUN = Path("/run/vaultwarden-oci")
CONFIG = ETC / "config.toml"
TRANSIENT = RUN / "transient"
LOCK = RUN / "lock"
SERVICE_UID = SERVICE_GID = 1000
NAMES = {"vaultwarden": "vaultwarden-oci-vaultwarden", "caddy": "vaultwarden-oci-caddy"}
_HOST = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")


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


@dataclass(frozen=True)
class Paths:
    config: Path = CONFIG
    data: Path = STATE / "data"
    caddy_data: Path = STATE / "caddy/data"
    caddy_config: Path = STATE / "caddy/config"
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

    def secret_paths(self) -> secrets.SecretPaths:
        return secrets.SecretPaths(root=self.secret_root, vaultwarden=self.secret_root / "vaultwarden", caddy=self.secret_root / "caddy")


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
    if not isinstance(value, str) or not value or value.strip() != value or any(c in value for c in "\0\r\n"):
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
    _unknown(data, {"schema_version", "site", "secrets", "vaultwarden", "smtp"}, "top-level")
    if data.get("schema_version") != 1:
        raise RuntimeConfigError("config requires schema_version = 1")
    site, secret_cfg, vw, smtp = (_mapping(data, key) for key in ("site", "secrets", "vaultwarden", "smtp"))
    _unknown(site, {"domain", "acme_email"}, "site")
    _unknown(secret_cfg, {"offline_recovery_recipient"}, "secrets")
    _unknown(vw, {"signups_allowed"}, "vaultwarden")
    _unknown(smtp, {"host", "port", "security", "from_email", "from_name", "timeout_seconds"}, "smtp")
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
    return RuntimeConfig(
        _hostname(_string(site, "domain", "site"), "site.domain", fqdn=True),
        _email(_string(site, "acme_email", "site"), "site.acme_email"),
        offline,
        signups,
        _hostname(_string(smtp, "host", "smtp"), "smtp.host"),
        port,
        security,
        _email(_string(smtp, "from_email", "smtp"), "smtp.from_email"),
        _string(smtp, "from_name", "smtp"),
        timeout,
    )


def load_config(path: Path = CONFIG) -> RuntimeConfig:
    try:
        with path.open("rb") as handle:
            return parse_config(tomllib.load(handle))
    except RuntimeConfigError:
        raise
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise RuntimeConfigError(f"cannot load config {path}: {exc}") from exc


def _pins(path: Path) -> tuple[str, str, str]:
    try:
        manifest = load_versions(path, require_components=True)
    except VersionsError as exc:
        raise RuntimeErrorV2(str(exc)) from exc
    return manifest.vaultwarden, manifest.caddy, manifest.caddy_dns_cloudflare


def _dir(path: Path, uid: int, gid: int, mode: int) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chown(path, uid, gid)
    os.chmod(path, mode)
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (uid, gid, mode):
        raise RuntimeErrorV2(f"incompatible runtime path: {path}")


def ensure_paths(paths: Paths, *, uid: int = 0, gid: int = 0, service_uid: int = SERVICE_UID, service_gid: int = SERVICE_GID) -> None:
    _dir(paths.run, uid, gid, 0o700)
    _dir(paths.transient, uid, gid, 0o700)
    for path in (paths.data, paths.caddy_data, paths.caddy_config):
        _dir(path, service_uid, service_gid, 0o700)
    secrets.ensure_runtime(paths.secret_paths(), uid=uid, gid=gid, service_gid=service_gid)


def _write(path: Path, text: str, mode: int) -> None:
    tmp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), mode)
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


def render(config: RuntimeConfig, versions_path: Path, paths: Paths = Paths()) -> None:
    vw, caddy, cf = _pins(versions_path)
    q = json.dumps
    signups = "true" if config.signups_allowed else "false"
    vw_command = 'export SMTP_USERNAME="$(cat /run/vw-secrets/smtp_username)"; export SMTP_PASSWORD="$(cat /run/vw-secrets/smtp_password)"; if [ -s /run/vw-secrets/vaultwarden_admin_token ]; then export ADMIN_TOKEN="$(cat /run/vw-secrets/vaultwarden_admin_token)"; fi; exec /start.sh'
    caddy_command = 'export CLOUDFLARE_API_TOKEN="$(cat /run/caddy-secrets/cloudflare_api_token)"; exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile'
    compose = f'''name: vaultwarden-oci
services:
  vaultwarden:
    image: {q("vaultwarden/server:" + vw)}
    container_name: {NAMES["vaultwarden"]}
    user: "1000:1000"
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
    build: {{context: ., dockerfile: Caddy.Dockerfile, args: {{CADDY_VERSION: {q(caddy)}, CADDY_DNS_CLOUDFLARE_VERSION: {q(cf)}}}}}
    image: {q("vaultwarden-oci/caddy:" + caddy + "-cloudflare-" + cf.removeprefix("v"))}
    container_name: {NAMES["caddy"]}
    user: "1000:1000"
    restart: unless-stopped
    command: ["/bin/sh", "-ec", {q(caddy_command)}]
    depends_on: {{vaultwarden: {{condition: service_healthy}}}}
    environment: {{VAULTWARDEN_DOMAIN: {q(config.domain)}, ACME_EMAIL: {q(config.acme_email)}}}
    ports: ["443:443/tcp"]
    volumes: ["./Caddyfile:/etc/caddy/Caddyfile:ro", {q(str(paths.caddy_data) + ":/data")}, {q(str(paths.caddy_config) + ":/config")}, {q(str(paths.secret_root / "caddy") + ":/run/caddy-secrets:ro")}]
    read_only: true
    tmpfs: ["/tmp:rw,noexec,nosuid,nodev,size=32m,mode=1777"]
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: ["no-new-privileges:true"]
    pids_limit: 100
    mem_limit: 256m
    healthcheck: {{test: ["CMD", "caddy", "validate", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"], interval: 30s, timeout: 10s, retries: 3}}
    logging: {{driver: json-file, options: {{max-size: "10m", max-file: "3"}}}}
    networks: [backend]
networks: {{backend: {{driver: bridge}}}}
'''
    caddyfile = '''{\n email {$ACME_EMAIL}\n}\n{$VAULTWARDEN_DOMAIN} {\n tls {\n  dns cloudflare {env.CLOUDFLARE_API_TOKEN}\n  resolvers 1.1.1.1 1.0.0.1\n }\n encode zstd gzip\n reverse_proxy vaultwarden:8080\n}\n'''
    dockerfile = '''ARG CADDY_VERSION\nFROM caddy:${CADDY_VERSION}-builder-alpine AS builder\nARG CADDY_DNS_CLOUDFLARE_VERSION\nRUN xcaddy build --with github.com/caddy-dns/cloudflare@${CADDY_DNS_CLOUDFLARE_VERSION}\nFROM caddy:${CADDY_VERSION}-alpine\nCOPY --from=builder /usr/bin/caddy /usr/bin/caddy\n'''
    _write(paths.compose, compose, 0o600)
    _write(paths.caddyfile, caddyfile, 0o444)
    _write(paths.dockerfile, dockerfile, 0o600)


def _compose(args: Sequence[str], paths: Paths, runner: Runner) -> CommandResult:
    return runner(["docker", "compose", "-f", str(paths.compose), *args])


def tools(runner: Runner = run_command) -> bool:
    docker = runner(["docker", "version", "--format", "{{.Server.Version}}"])
    compose = runner(["docker", "compose", "version", "--short"])
    help_result = runner(["docker", "compose", "up", "--help"]) if compose.ok else None
    return docker.ok and compose.ok and help_result is not None and help_result.ok and "--wait" in help_result.stdout and "--wait-timeout" in help_result.stdout


def lifecycle(action: str, *, paths: Paths = Paths(), versions_path: Path | None = None, runner: Runner = run_command) -> None:
    if action not in {"start", "stop", "restart"}:
        raise ValueError(action)
    if paths == Paths() and os.geteuid() != 0:
        raise RuntimeErrorV2(f"vwctl {action} must run as root")
    versions_path = versions_path or Path(__file__).resolve().parents[1] / "versions.toml"
    uid, gid, service_uid, service_gid = (0, 0, SERVICE_UID, SERVICE_GID) if paths == Paths() else (os.geteuid(), os.getegid(), os.geteuid(), os.getegid())
    with mutation_lock(paths.lock):
        if action == "stop":
            if not runner(["docker", "version", "--format", "{{.Server.Version}}"] ).ok:
                raise RuntimeErrorV2("Docker Engine unavailable; stop state unknown")
            existing = [NAMES[name] for name in ("caddy", "vaultwarden") if runner(["docker", "container", "inspect", NAMES[name]]).ok]
            if existing and not runner(["docker", "stop", *existing]).ok:
                raise RuntimeErrorV2("Docker stop failed")
            secrets.cleanup(paths.secret_paths())
            return
        if not tools(runner):
            raise RuntimeErrorV2("Docker Engine + Compose with up --wait --wait-timeout are required")
        ensure_paths(paths, uid=uid, gid=gid, service_uid=service_uid, service_gid=service_gid)
        config = load_config(paths.config)
        render(config, versions_path, paths)
        if not _compose(["config", "--quiet"], paths, runner).ok:
            raise RuntimeErrorV2("rendered Compose validation failed")
        values = secrets.load(config.offline_recovery_recipient, paths=paths.secret_paths(), runner=runner, uid=uid)
        secrets.materialize(values, paths=paths.secret_paths(), uid=uid, gid=gid, service_gid=service_gid)
        args = ["up", "-d", "--build", "--wait", "--wait-timeout", "120"] + (["--force-recreate"] if action == "restart" else [])
        if not _compose(args, paths, runner).ok:
            secrets.cleanup(paths.secret_paths())
            raise RuntimeErrorV2("Docker Compose lifecycle failed")


def status(*, runner: Runner = run_command) -> tuple[str, list[dict[str, str]]]:
    if not runner(["docker", "version", "--format", "{{.Server.Version}}"] ).ok:
        return "unavailable", [{"service": name, "state": "unknown", "health": "unknown"} for name in ("vaultwarden", "caddy")]
    rows = []
    for name in ("vaultwarden", "caddy"):
        result = runner(["docker", "container", "inspect", "--format", "{{json .State}}", NAMES[name]])
        try:
            state = json.loads(result.stdout) if result.ok else {}
            current = state.get("Status", "absent")
            health = state.get("Health", {}).get("Status", "-")
        except (json.JSONDecodeError, AttributeError):
            current = health = "unknown"
        rows.append({"service": name, "state": current, "health": health})
    running = [row for row in rows if row["state"] == "running"]
    healthy = [row for row in running if row["health"] in {"healthy", "-"}]
    overall = "stopped" if not running else "running" if len(healthy) == 2 else "degraded"
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


def doctor_checks(*, config_path: Path = CONFIG, paths: Paths = Paths(), runner: Runner = run_command, **_):
    checks = [
        DoctorCheck("runtime.docker", "PASS" if runner(["docker", "version", "--format", "{{.Server.Version}}"] ).ok else "FAIL", "Docker Engine availability"),
        DoctorCheck("runtime.compose", "PASS" if tools(runner) else "FAIL", "Compose up --wait support"),
    ]
    try:
        config = load_config(config_path)
        secret_paths = paths.secret_paths()
        secrets.validate_custody(config.offline_recovery_recipient, paths=secret_paths, runner=runner)
        checks.extend([DoctorCheck("runtime.paths", "PASS", "runtime paths are managed by start"), DoctorCheck("secrets.custody", "PASS", "Age/SOPS custody valid")])
        secrets.decrypt(paths=secret_paths, runner=runner)
        checks.append(DoctorCheck("secrets.decrypt", "PASS", "required Phase 3 secrets decrypt"))
    except (RuntimeConfigError, secrets.SecretsError) as exc:
        checks.extend([DoctorCheck("runtime.paths", "SKIP", "runtime paths checked on start"), DoctorCheck("secrets.custody", "FAIL", str(exc)), DoctorCheck("secrets.decrypt", "SKIP", "custody/config validation failed")])
    return checks


RuntimePaths = Paths
parse_runtime_config = parse_config
load_runtime_config = load_config
DATA_DIR = STATE / "data"
CADDY_DATA_DIR = STATE / "caddy/data"
CADDY_CONFIG_DIR = STATE / "caddy/config"
RUNTIME_ROOT = RUN
RUNTIME_TRANSIENT_DIR = TRANSIENT
STATE_ROOT = STATE
CONFIG_PATH = CONFIG
