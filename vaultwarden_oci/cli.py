#!/usr/bin/env python3
"""Minimal VaultWarden-OCI V2 command-line foundation."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import platform
import subprocess
import sys
import tomllib
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Sequence

PROGRAM_NAME = "vwctl"
DEFAULT_CONFIG_PATH = Path("/etc/vaultwarden-oci/config.toml")
DEFAULT_VERSIONS_PATH = Path(__file__).resolve().parent.parent / "versions.toml"
OS_RELEASE_PATH = Path("/etc/os-release")
GLOBAL_LOCK_PATH = Path("/run/vaultwarden-oci/lock")

DOCTOR_STATUSES = ("PASS", "WARN", "FAIL", "SKIP")
DOCTOR_CHECK_IDS = (
    "host.os",
    "host.architecture",
    "config.toml",
    "versions.toml",
)

_ARCHITECTURES = {
    "amd64": "amd64",
    "x86_64": "amd64",
    "arm64": "arm64",
    "aarch64": "arm64",
}


class ConfigError(ValueError):
    """Raised when config.toml cannot be parsed."""


class VersionsError(ValueError):
    """Raised when versions.toml is missing or invalid."""


class UnsupportedArchitecture(ValueError):
    """Raised when the host architecture is outside the V2 support boundary."""


class LockBusyError(RuntimeError):
    """Raised when another mutating vwctl operation owns the global lock."""


@dataclass(frozen=True)
class VersionsManifest:
    schema_version: int
    version: str


@dataclass(frozen=True)
class CommandResult:
    argv: tuple[str, ...]
    kind: str
    returncode: int | None
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.kind == "success"


@dataclass(frozen=True)
class DoctorCheck:
    check_id: str
    status: str
    message: str

    def as_dict(self) -> dict[str, str]:
        return {
            "id": self.check_id,
            "status": self.status,
            "message": self.message,
        }


def _load_toml(path: Path, label: str) -> dict[str, object]:
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)
    except FileNotFoundError as exc:
        raise ValueError(f"{label} not found: {path}") from exc
    except PermissionError as exc:
        raise ValueError(f"{label} is not readable: {path}") from exc
    except OSError as exc:
        raise ValueError(f"cannot read {label} {path}: {exc}") from exc
    except tomllib.TOMLDecodeError as exc:
        raise ValueError(f"invalid {label} TOML in {path}: {exc}") from exc


def validate_config(path: Path) -> dict[str, object]:
    """Parse the operator config without inventing later-phase schema fields."""
    try:
        return _load_toml(path, "config")
    except ValueError as exc:
        raise ConfigError(str(exc)) from exc


def load_versions(path: Path = DEFAULT_VERSIONS_PATH) -> VersionsManifest:
    """Load the minimal V2 versions manifest required by Phase 1."""
    try:
        data = _load_toml(path, "versions manifest")
    except ValueError as exc:
        raise VersionsError(str(exc)) from exc

    if data.get("schema_version") != 1:
        raise VersionsError("versions manifest requires schema_version = 1")

    project = data.get("vaultwarden_oci")
    if not isinstance(project, dict):
        raise VersionsError("versions manifest requires [vaultwarden_oci]")

    version = project.get("version")
    if not isinstance(version, str) or not version or version.strip() != version:
        raise VersionsError("versions manifest requires a non-empty vaultwarden_oci.version")
    if any(character.isspace() for character in version):
        raise VersionsError("vaultwarden_oci.version must not contain whitespace")

    return VersionsManifest(schema_version=1, version=version)


def normalize_architecture(machine: str) -> str:
    """Return the canonical V2 architecture name or fail clearly."""
    normalized = _ARCHITECTURES.get(machine.strip().lower())
    if normalized is None:
        raise UnsupportedArchitecture(
            f"unsupported architecture {machine!r}; supported aliases are "
            "amd64/x86_64 and arm64/aarch64"
        )
    return normalized


def run_command(argv: Sequence[str]) -> CommandResult:
    """Run an argv array without shell interpolation and normalize basic outcomes."""
    if isinstance(argv, (str, bytes)):
        raise TypeError("argv must be a sequence of strings, not a shell command string")
    args = tuple(argv)
    if not args or not all(isinstance(item, str) for item in args):
        raise ValueError("argv must contain at least one string argument")

    try:
        completed = subprocess.run(
            list(args),
            check=False,
            capture_output=True,
            text=True,
            shell=False,
        )
    except FileNotFoundError as exc:
        return CommandResult(
            argv=args,
            kind="not_found",
            returncode=None,
            stdout="",
            stderr=str(exc),
        )

    kind = "success" if completed.returncode == 0 else "nonzero"
    return CommandResult(
        argv=args,
        kind=kind,
        returncode=completed.returncode,
        stdout=completed.stdout,
        stderr=completed.stderr,
    )


@contextmanager
def mutation_lock(path: Path = GLOBAL_LOCK_PATH) -> Iterator[None]:
    """Acquire the one V2 mutation lock; read-only commands never call this."""
    try:
        descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        handle = os.fdopen(descriptor, "r+", encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"cannot open mutation lock {path}: {exc}") from exc

    acquired = False
    try:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            acquired = True
        except BlockingIOError as exc:
            raise LockBusyError(f"another mutating vwctl operation holds {path}") from exc
        yield
    finally:
        if acquired:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        handle.close()


def _parse_os_release(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    with path.open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
                value = value[1:-1]
            values[key] = value
    return values


def _check_host_os(path: Path) -> DoctorCheck:
    try:
        os_release = _parse_os_release(path)
    except OSError as exc:
        return DoctorCheck("host.os", "FAIL", f"cannot read {path}: {exc}")

    distro = os_release.get("ID", "")
    version = os_release.get("VERSION_ID", "")
    if distro == "ubuntu" and version == "24.04":
        return DoctorCheck("host.os", "PASS", "Ubuntu 24.04 LTS detected")
    return DoctorCheck(
        "host.os",
        "FAIL",
        f"unsupported host {distro or 'unknown'} {version or 'unknown'}; Ubuntu 24.04 is required",
    )


def _check_architecture(machine: str) -> DoctorCheck:
    try:
        architecture = normalize_architecture(machine)
    except UnsupportedArchitecture as exc:
        return DoctorCheck("host.architecture", "FAIL", str(exc))
    return DoctorCheck("host.architecture", "PASS", f"supported architecture {architecture}")


def _check_config(path: Path) -> DoctorCheck:
    if not path.exists():
        return DoctorCheck(
            "config.toml",
            "WARN",
            f"operator config is not present yet: {path}",
        )
    try:
        validate_config(path)
    except ConfigError as exc:
        return DoctorCheck("config.toml", "FAIL", str(exc))
    return DoctorCheck("config.toml", "PASS", f"config TOML is valid: {path}")


def _check_versions(path: Path) -> DoctorCheck:
    try:
        manifest = load_versions(path)
    except VersionsError as exc:
        return DoctorCheck("versions.toml", "FAIL", str(exc))
    return DoctorCheck(
        "versions.toml",
        "PASS",
        f"versions manifest is valid for {manifest.version}",
    )


def doctor_checks(
    *,
    config_path: Path = DEFAULT_CONFIG_PATH,
    versions_path: Path = DEFAULT_VERSIONS_PATH,
    os_release_path: Path = OS_RELEASE_PATH,
    machine: str | None = None,
) -> list[DoctorCheck]:
    """Run the read-only Phase 1 diagnostic checks in stable-ID order."""
    checks = [
        _check_host_os(os_release_path),
        _check_architecture(machine if machine is not None else platform.machine()),
        _check_config(config_path),
        _check_versions(versions_path),
    ]
    return checks


def doctor_overall(checks: Sequence[DoctorCheck]) -> str:
    statuses = {check.status for check in checks}
    if "FAIL" in statuses:
        return "FAIL"
    if "WARN" in statuses:
        return "WARN"
    if statuses and statuses <= {"SKIP"}:
        return "SKIP"
    return "PASS"


def doctor_payload(checks: Sequence[DoctorCheck]) -> dict[str, object]:
    return {
        "schema_version": 1,
        "overall": doctor_overall(checks),
        "checks": [check.as_dict() for check in checks],
    }


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=PROGRAM_NAME,
        description="VaultWarden-OCI V2 operator CLI",
    )
    parser.add_argument(
        "--version",
        action="store_true",
        help="show the vwctl version and exit",
    )

    commands = parser.add_subparsers(dest="command")

    config = commands.add_parser("config", help="validate operator configuration")
    config_commands = config.add_subparsers(dest="config_command", required=True)
    validate = config_commands.add_parser("validate", help="validate a TOML config file")
    validate.add_argument("--file", required=True, type=Path, help="config TOML path")

    commands.add_parser("versions", help="show exact V2 version values required now")

    doctor = commands.add_parser("doctor", help="run read-only host/config diagnostics")
    doctor.add_argument("--json", action="store_true", help="emit stable structured output")

    return parser


def _print_versions(path: Path = DEFAULT_VERSIONS_PATH) -> int:
    try:
        manifest = load_versions(path)
    except VersionsError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"vaultwarden-oci {manifest.version}")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    if args.version:
        try:
            manifest = load_versions()
        except VersionsError as exc:
            print(f"FAIL: {exc}", file=sys.stderr)
            return 1
        print(f"{PROGRAM_NAME} {manifest.version}")
        return 0

    if args.command is None:
        parser.print_help()
        return 0

    if args.command == "config":
        try:
            validate_config(args.file)
        except ConfigError as exc:
            print(f"FAIL: {exc}", file=sys.stderr)
            return 1
        print(f"PASS: valid config TOML: {args.file}")
        return 0

    if args.command == "versions":
        return _print_versions()

    if args.command == "doctor":
        checks = doctor_checks()
        payload = doctor_payload(checks)
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            for check in checks:
                print(f"[{check.status}] {check.check_id}: {check.message}")
            print(f"Overall: {payload['overall']}")
        return 1 if payload["overall"] == "FAIL" else 0

    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
