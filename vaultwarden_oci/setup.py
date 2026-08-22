"""Supported blank-VM first-run setup orchestration."""
from __future__ import annotations

import argparse
import json
import os
import re
import secrets as pysecrets
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path
from typing import Sequence

from . import install, storage
from .update_versions import RESOLVED_STATE, frozen_versions_toml, record_frozen, resolve_latest, resolve_pinned

SOPS_VERSION = "3.13.3"
SOPS_URL = "https://github.com/getsops/sops/releases/download/v{version}/sops-v{version}.linux.{arch}"
DOCKER_KEY = "https://download.docker.com/linux/ubuntu/gpg"
DOCKER_SOURCE = Path("/etc/apt/sources.list.d/docker.sources")
DOCKER_KEYRING = Path("/etc/apt/keyrings/docker.asc")
CONFIG = Path("/etc/vaultwarden-oci/config.toml")
AGE_KEY = Path("/etc/vaultwarden-oci/age-key.txt")
ENCRYPTED = Path("/etc/vaultwarden-oci/secrets.sops.yaml")
_RECIPIENT = re.compile(r"^age1[0-9a-z]{50,70}$")


class SetupError(RuntimeError):
    pass


class UI:
    def __init__(self, *, color: bool):
        self.color = color

    def _line(self, label: str, text: str, code: str) -> None:
        prefix = f"\033[{code}m{label}\033[0m" if self.color else label
        print(f"{prefix} {text}")

    def header(self, text: str) -> None:
        print(f"\n== {text} ==")

    def ok(self, text: str) -> None: self._line("PASS", text, "32")
    def warn(self, text: str) -> None: self._line("WARN", text, "33")
    def info(self, text: str) -> None: self._line("INFO", text, "36")
    def action(self, text: str) -> None: self._line("ACTION", text, "34")
    def fail(self, text: str) -> None: self._line("FAIL", text, "31")


def _run(argv: Sequence[str], *, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(tuple(argv), check=False, capture_output=True, text=True, input=input_text)


def _must(argv: Sequence[str], label: str, *, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    result = _run(argv, input_text=input_text)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise SetupError(f"{label} failed: {detail}")
    return result


def _normalize(domain: str, url: str, email: str) -> tuple[str, str, str]:
    domain = domain.strip().lower().rstrip(".")
    if not domain or "." not in domain or any(c in domain for c in "/:@ "):
        raise SetupError("--domain must be a DNS hostname such as example.com or vault.example.com")
    parsed = urllib.parse.urlsplit(url.strip())
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.port or parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise SetupError("--url must be a simple https:// hostname URL without credentials, port, query, or fragment")
    host = (parsed.hostname or "").lower().rstrip(".")
    if host not in {domain, f"vault.{domain}"}:
        raise SetupError("--url hostname must equal --domain or vault.--domain; URL is validated, not stored as a second authority")
    if email.count("@") != 1 or email.startswith("@") or email.endswith("@") or any(c.isspace() for c in email):
        raise SetupError("--email must be a simple email address")
    return host, f"https://{host}", email.strip()


def _config_text(host: str, email: str, offline: str) -> str:
    return f'''# VaultWarden-OCI operator configuration. Secrets belong in secrets.sops.yaml.
schema_version = 1

[site]
domain = "{host}"
acme_email = "{email}"

[secrets]
offline_recovery_recipient = "{offline}"

[vaultwarden]
signups_allowed = false

[smtp]
# Complete these external SMTP settings before start.
host = "smtp.invalid"
port = 587
security = "starttls"
from_email = "vaultwarden@{host}"
from_name = "Vaultwarden"
timeout_seconds = 15
'''


def _write_atomic(path: Path, text: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
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


def _select_storage(args: argparse.Namespace, ui: UI) -> str:
    if args.data_mount and Path(args.data_mount) != storage.STATE_ROOT:
        raise SetupError(f"--data-mount is fixed to the canonical state mount {storage.STATE_ROOT}")
    if args.data_device:
        storage.reject_boot_related(args.data_device)
        return args.data_device
    if args.auto or not sys.stdin.isatty():
        raise SetupError("noninteractive setup requires --data-device; --auto never guesses a disk")
    rows = storage.inventory()
    if not rows:
        raise SetupError("no acceptable separate block device/filesystem was found; attach dedicated storage and re-run setup")
    ui.info("Plausible non-boot storage candidates:")
    for index, row in enumerate(rows, 1):
        size_gib = int(row["size"]) / (1024 ** 3)
        mounts = ",".join(row["mountpoints"]) or "-"
        fs = row["fstype"] or "blank"
        model = f" {row['model']}" if row["model"] else ""
        print(f"  {index}) {row['path']} {size_gib:.1f} GiB {fs} mount={mounts}{model}")
    answer = input("Select dedicated data device number (or q to quit): ").strip()
    if answer.lower() == "q":
        raise SetupError("storage selection cancelled; no installation changes were made")
    try:
        selected = rows[int(answer) - 1]["path"]
    except (ValueError, IndexError):
        raise SetupError("invalid storage selection")
    assert isinstance(selected, str)
    return selected


def _install_dependencies(host_arch: str, ui: UI) -> None:
    ui.header("Dependencies")
    _must(["apt-get", "update"], "apt package index refresh")
    _must(
        ["apt-get", "install", "-y", "ca-certificates", "curl", "gnupg", "age", "rclone", "7zip", "util-linux"],
        "Ubuntu dependency installation",
    )
    DOCKER_KEYRING.parent.mkdir(parents=True, exist_ok=True)
    _must(["curl", "-fsSL", DOCKER_KEY, "-o", str(DOCKER_KEYRING)], "Docker repository key download")
    os.chmod(DOCKER_KEYRING, 0o644)
    docker_source = '''Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: {arch}
Signed-By: /etc/apt/keyrings/docker.asc
'''.format(arch="amd64" if host_arch == "amd64" else "arm64")
    _write_atomic(DOCKER_SOURCE, docker_source, 0o644)
    _must(["apt-get", "update"], "Docker repository refresh")
    _must(
        ["apt-get", "install", "-y", "docker-ce", "docker-ce-cli", "containerd.io", "docker-buildx-plugin", "docker-compose-plugin"],
        "Docker Engine/Compose installation",
    )
    sops_arch = "amd64" if host_arch == "amd64" else "arm64"
    url = SOPS_URL.format(version=SOPS_VERSION, arch=sops_arch)
    _must(["curl", "-fL", url, "-o", "/usr/local/bin/sops"], f"SOPS {SOPS_VERSION} download")
    os.chmod("/usr/local/bin/sops", 0o755)
    checks = (
        (["docker", "version", "--format", "{{.Server.Version}}"], "Docker Engine"),
        (["docker", "compose", "version", "--short"], "Docker Compose"),
        (["sops", "--version"], "SOPS"),
        (["age", "--version"], "Age"),
        (["age-keygen", "--version"], "Age keygen"),
        (["rclone", "version"], "rclone"),
        (["7zz", "--help"], "7-Zip"),
    )
    for command, label in checks:
        if _run(command).returncode != 0:
            raise SetupError(f"dependency verification failed: {label}")
    ui.ok("required dependencies verified")


def _install_release(source: Path, *, use_latest: bool) -> str:
    if not use_latest:
        frozen = resolve_pinned(source)
        release = install.install_layout(source)
    else:
        old = os.environ.get("VWOCI_DEVELOPMENT")
        os.environ["VWOCI_DEVELOPMENT"] = "1"
        try:
            frozen = resolve_latest(source)
        finally:
            if old is None:
                os.environ.pop("VWOCI_DEVELOPMENT", None)
            else:
                os.environ["VWOCI_DEVELOPMENT"] = old
        with install._frozen_source(source, frozen_versions_toml(frozen)) as frozen_source:
            release = install.install_layout(frozen_source, require_all_architectures=False)
    record_frozen(frozen, RESOLVED_STATE)
    return release


def _ensure_age_identity() -> str:
    if AGE_KEY.exists() or AGE_KEY.is_symlink():
        if AGE_KEY.is_symlink() or not AGE_KEY.is_file():
            raise SetupError(f"operational Age identity path is unsafe: {AGE_KEY}")
        if AGE_KEY.stat().st_size:
            os.chmod(AGE_KEY, 0o600)
            return _must(["age-keygen", "-y", str(AGE_KEY)], "operational Age recipient derivation").stdout.strip()
        AGE_KEY.unlink()
    _must(["age-keygen", "-o", str(AGE_KEY)], "operational Age identity generation")
    os.chmod(AGE_KEY, 0o600)
    return _must(["age-keygen", "-y", str(AGE_KEY)], "operational Age recipient derivation").stdout.strip()


def _ensure_config(host: str, email: str, offline: str) -> None:
    desired = _config_text(host, email, offline)
    if CONFIG.exists() and CONFIG.stat().st_size:
        current = CONFIG.read_text(encoding="utf-8")
        if current == desired:
            return
        if "vault.invalid" not in current and "admin@vault.invalid" not in current:
            raise SetupError(f"existing operator config differs from requested first-run values: {CONFIG}; edit/validate it explicitly rather than overwriting")
    _write_atomic(CONFIG, desired)


def _ensure_secret_start(operational: str, offline: str) -> None:
    if not _RECIPIENT.fullmatch(offline):
        raise SetupError("--offline-recipient must be an Age X25519 public recipient")
    if operational == offline:
        raise SetupError("operational and offline recovery Age identities must differ")
    if ENCRYPTED.exists() and ENCRYPTED.stat().st_size:
        return
    admin_token = pysecrets.token_urlsafe(48)
    plaintext = json.dumps({"vaultwarden_admin_token": admin_token}) + "\n"
    result = _must(
        ["sops", "--encrypt", "--age", f"{operational},{offline}", "--input-type", "json", "--output-type", "yaml", "/dev/stdin"],
        "initial encrypted secrets creation",
        input_text=plaintext,
    )
    _write_atomic(ENCRYPTED, result.stdout)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="setup.sh", description="Supported VaultWarden-OCI blank-VM setup")
    commands = parser.add_subparsers(dest="command", required=True)
    install_cmd = commands.add_parser("install")
    install_cmd.add_argument("--domain", required=True)
    install_cmd.add_argument("--url", required=True)
    install_cmd.add_argument("--email", required=True)
    install_cmd.add_argument("--data-device")
    install_cmd.add_argument("--data-mount", default=str(storage.STATE_ROOT))
    install_cmd.add_argument("--offline-recipient")
    install_cmd.add_argument("--accept-existing-filesystem", action="store_true")
    install_cmd.add_argument("--confirm-format", action="store_true")
    install_cmd.add_argument("--auto", action="store_true")
    install_cmd.add_argument("--use-latest", action="store_true")
    install_cmd.add_argument("--dry-run", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    color = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
    ui = UI(color=color)
    try:
        if os.geteuid() != 0:
            raise SetupError("setup must run as root; use sudo ./setup.sh install ...")
        host = install.validate_host()
        domain, normalized_url, email = _normalize(args.domain, args.url, args.email)
        ui.header("Host and dedicated storage preflight")
        ui.ok(f"Ubuntu 24.04 {host.architecture}; canonical URL {normalized_url}")
        selected = _select_storage(args, ui)
        ui.info(f"selected dedicated storage: {selected} -> {storage.STATE_ROOT}")
        offline = args.offline_recipient
        if not offline and not args.auto and sys.stdin.isatty():
            offline = input("Offline recovery Age recipient (public age1... value; keep its private key off-host): ").strip()
        if not offline:
            raise SetupError("an offline recovery public recipient is required; --auto cannot invent custody for an off-host private key")
        if not _RECIPIENT.fullmatch(offline):
            raise SetupError("offline recovery recipient is not a valid Age X25519 recipient")
        if args.dry_run:
            ui.warn("dry run: no filesystem, package, config, secret, or systemd changes were made")
            ui.action("re-run without --dry-run after verifying the selected dedicated device")
            return 0

        identity = storage.provision(
            selected,
            acknowledge_existing=args.accept_existing_filesystem,
            acknowledge_format=args.confirm_format,
            interactive=not args.auto and sys.stdin.isatty(),
        )
        ui.ok(f"dedicated storage proven: UUID={identity.uuid} {identity.fs_type} at {identity.mount}")
        _install_dependencies(host.architecture, ui)
        ui.header("Immutable application install")
        release = _install_release(Path(__file__).resolve().parents[1], use_latest=args.use_latest)
        ui.ok(f"installed exact immutable release at {release}")
        operational = _ensure_age_identity()
        _ensure_config(domain, email, offline)
        _ensure_secret_start(operational, offline)
        storage.verify()
        ui.ok("operational Age identity, operator config, and encrypted-secrets starting point are present")
        ui.header("Next actions")
        ui.action("complete external Cloudflare/SMTP/API credentials with the supported secrets editor/config workflow")
        ui.action("run: sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml")
        ui.action("run: sudo vwctl doctor")
        ui.action("when doctor is ready, run: sudo vwctl start")
        return 0
    except (SetupError, storage.StorageError, install.InstallError, OSError, ValueError) as exc:
        ui.fail(str(exc))
        ui.action("correct the failed step above and re-run the same setup command; completed safe steps are idempotent")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
