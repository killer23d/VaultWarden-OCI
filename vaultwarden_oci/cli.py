#!/usr/bin/env python3
"""VaultWarden-OCI V2 operator CLI and shared subprocess/lock primitives."""
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
from typing import Iterator, Mapping, Sequence

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
    "runtime.docker",
    "runtime.compose",
    "runtime.paths",
    "secrets.custody",
    "secrets.decrypt",
    "edge.cloudflare.cidrs",
    "edge.cloudflare.iptables",
    "crowdsec.engine",
    "crowdsec.cloudflare",
    "recovery.local",
    "recovery.offsite",
    "recovery.rclone",
)
_ARCH = {"amd64": "amd64", "x86_64": "amd64", "arm64": "arm64", "aarch64": "arm64"}


class ConfigError(ValueError):
    pass


class VersionsError(ValueError):
    pass


class UnsupportedArchitecture(ValueError):
    pass


class LockBusyError(RuntimeError):
    pass


@dataclass(frozen=True)
class VersionsManifest:
    schema_version: int
    version: str
    vaultwarden: str = ""
    caddy: str = ""
    caddy_dns_cloudflare: str = ""


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
        return {"id": self.check_id, "status": self.status, "message": self.message}


def _toml(path: Path, label: str) -> dict[str, object]:
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise ValueError(f"cannot load {label} {path}: {exc}") from exc


def validate_config(path: Path) -> dict[str, object]:
    try:
        data = _toml(path, "config")
        from .runtime import parse_config
        parse_config(data)
        return data
    except ValueError as exc:
        raise ConfigError(str(exc)) from exc


def _pin(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or value.strip() != value or any(c.isspace() for c in value):
        raise VersionsError(f"{label} must be a non-empty exact pin")
    if value.lower() in {"latest", "stable", "main", "master", "edge"} or "*" in value:
        raise VersionsError(f"{label} must be an exact production pin")
    return value


def load_versions(path: Path = DEFAULT_VERSIONS_PATH, *, require_components: bool = False) -> VersionsManifest:
    try:
        data = _toml(path, "versions manifest")
    except ValueError as exc:
        raise VersionsError(str(exc)) from exc
    if data.get("schema_version") != 1:
        raise VersionsError("versions manifest requires schema_version = 1")
    project = data.get("vaultwarden_oci")
    components = data.get("components", {})
    if not isinstance(project, dict) or not isinstance(components, dict):
        raise VersionsError("versions manifest requires [vaultwarden_oci] and optional [components]")
    unknown = sorted(set(components) - {"vaultwarden", "caddy", "caddy_dns_cloudflare"})
    if unknown:
        raise VersionsError("unknown component pin(s): " + ", ".join(unknown))

    def component(key: str) -> str:
        value = components.get(key)
        if value is None and not require_components:
            return ""
        return _pin(value, f"components.{key}")

    return VersionsManifest(
        1,
        _pin(project.get("version"), "vaultwarden_oci.version"),
        component("vaultwarden"),
        component("caddy"),
        component("caddy_dns_cloudflare"),
    )


def normalize_architecture(machine: str) -> str:
    value = _ARCH.get(machine.strip().lower())
    if value is None:
        raise UnsupportedArchitecture(f"unsupported architecture {machine!r}; use amd64/x86_64 or arm64/aarch64")
    return value


def run_command(argv: Sequence[str], *, env: Mapping[str, str] | None = None, cwd: Path | None = None) -> CommandResult:
    if isinstance(argv, (str, bytes)):
        raise TypeError("argv must be a sequence of strings")
    args = tuple(argv)
    if not args or not all(isinstance(item, str) for item in args):
        raise ValueError("argv must contain at least one string")
    try:
        completed = subprocess.run(
            list(args),
            check=False,
            capture_output=True,
            text=True,
            shell=False,
            env=dict(env) if env is not None else None,
            cwd=str(cwd) if cwd else None,
        )
    except FileNotFoundError as exc:
        return CommandResult(args, "not_found", None, "", str(exc))
    return CommandResult(
        args,
        "success" if completed.returncode == 0 else "nonzero",
        completed.returncode,
        completed.stdout,
        completed.stderr,
    )


@contextmanager
def mutation_lock(path: Path = GLOBAL_LOCK_PATH) -> Iterator[None]:
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        handle = os.fdopen(fd, "r+", encoding="utf-8")
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


def _os_release(path: Path) -> dict[str, str]:
    values = {}
    with path.open("r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key] = value.strip().strip("\"'")
    return values


def doctor_checks(
    *,
    config_path: Path = DEFAULT_CONFIG_PATH,
    versions_path: Path = DEFAULT_VERSIONS_PATH,
    os_release_path: Path = OS_RELEASE_PATH,
    machine: str | None = None,
) -> list[DoctorCheck]:
    try:
        release = _os_release(os_release_path)
        os_check = DoctorCheck(
            "host.os",
            "PASS" if release.get("ID") == "ubuntu" and release.get("VERSION_ID") == "24.04" else "FAIL",
            "Ubuntu 24.04 LTS required",
        )
    except OSError as exc:
        os_check = DoctorCheck("host.os", "FAIL", str(exc))
    try:
        arch = normalize_architecture(machine if machine is not None else platform.machine())
        arch_check = DoctorCheck("host.architecture", "PASS", f"supported architecture {arch}")
    except UnsupportedArchitecture as exc:
        arch_check = DoctorCheck("host.architecture", "FAIL", str(exc))
    if not config_path.exists():
        config_check = DoctorCheck("config.toml", "WARN", f"operator config is not present: {config_path}")
    else:
        try:
            validate_config(config_path)
            config_check = DoctorCheck("config.toml", "PASS", "config TOML is valid")
        except ConfigError as exc:
            config_check = DoctorCheck("config.toml", "FAIL", str(exc))
    try:
        manifest = load_versions(versions_path, require_components=True)
        versions_check = DoctorCheck("versions.toml", "PASS", f"exact runtime pins configured for {manifest.version}")
    except VersionsError as exc:
        versions_check = DoctorCheck("versions.toml", "FAIL", str(exc))
    from . import edge, recovery, runtime

    return [
        os_check,
        arch_check,
        config_check,
        versions_check,
        *runtime.doctor_checks(config_path=config_path, paths=runtime.Paths(config=config_path)),
        *edge.doctor_checks(),
        *recovery.doctor_checks(),
    ]


def doctor_overall(checks: Sequence[DoctorCheck]) -> str:
    statuses = {check.status for check in checks}
    return "FAIL" if "FAIL" in statuses else "WARN" if "WARN" in statuses else "SKIP" if statuses and statuses <= {"SKIP"} else "PASS"


def doctor_payload(checks: Sequence[DoctorCheck]) -> dict[str, object]:
    return {"schema_version": 1, "overall": doctor_overall(checks), "checks": [check.as_dict() for check in checks]}


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=PROGRAM_NAME, description="VaultWarden-OCI V2 operator CLI")
    parser.add_argument("--version", action="store_true")
    commands = parser.add_subparsers(dest="command")
    config = commands.add_parser("config")
    config_commands = config.add_subparsers(dest="config_command", required=True)
    validate = config_commands.add_parser("validate")
    validate.add_argument("--file", required=True, type=Path)
    commands.add_parser("versions")
    for action in ("start", "stop", "restart", "status"):
        commands.add_parser(action)
    logs = commands.add_parser("logs")
    logs.add_argument("service", nargs="?", choices=("vaultwarden", "caddy"))
    logs.add_argument("--tail", type=int, default=200)
    doctor = commands.add_parser("doctor")
    doctor.add_argument("--json", action="store_true")

    backup = commands.add_parser("backup", help="create and verify one encrypted V2 recovery point")
    backup.add_argument("--remote", help="optional rclone REMOTE:path publication destination")
    restore = commands.add_parser("restore", help="restore one encrypted V2 recovery point")
    source = restore.add_mutually_exclusive_group(required=True)
    source.add_argument("--file", type=Path, help="local .vwrec recovery artifact")
    source.add_argument("--from-remote", help="rclone REMOTE:path/to/file.vwrec")
    restore.add_argument("--identity", required=True, type=Path, help="offline Age private identity file")
    restore.add_argument("--start", action="store_true", help="start and health-gate services after promotion")
    recovery_cmd = commands.add_parser("recovery", help="explicit recovery retention operations")
    recovery_commands = recovery_cmd.add_subparsers(dest="recovery_command", required=True)
    prune = recovery_commands.add_parser("prune", help="plan or execute explicit remote recovery pruning")
    prune.add_argument("--remote", required=True, help="rclone REMOTE:path containing recovery points")
    prune.add_argument("--keep-last", required=True, type=int)
    prune.add_argument("--confirm", action="store_true", help="execute the displayed deletion decision")

    edge_cmd = commands.add_parser("edge", help="Cloudflare origin edge policy")
    edge_commands = edge_cmd.add_subparsers(dest="edge_command", required=True)
    edge_commands.add_parser("refresh", help="refresh validated Cloudflare CIDRs and apply origin policy")

    crowdsec = commands.add_parser("crowdsec", help="CrowdSec Security Engine and Cloudflare remediation")
    crowdsec_commands = crowdsec.add_subparsers(dest="crowdsec_command", required=True)
    crowdsec_commands.add_parser("setup", help="install/configure the supported CrowdSec beta path")
    crowdsec_commands.add_parser("remediation-start", help="explicitly start one Cloudflare remediation invocation")
    crowdsec_commands.add_parser("confirm-fail-open", help="confirm current Worker Routes are set to Fail Open")
    crowdsec_commands.add_parser("status", help="show CrowdSec engine and Cloudflare remediation health")
    crowdsec_commands.add_parser("prepare-remediation", help=argparse.SUPPRESS)
    crowdsec_commands.add_parser("consume-start-token", help=argparse.SUPPRESS)
    return parser


def _versions() -> int:
    try:
        v = load_versions(require_components=True)
    except VersionsError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    print(
        f"vaultwarden-oci {v.version}; vaultwarden {v.vaultwarden}; "
        f"caddy {v.caddy}; caddy-dns/cloudflare {v.caddy_dns_cloudflare}"
    )
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.version:
        try:
            print(f"{PROGRAM_NAME} {load_versions().version}")
            return 0
        except VersionsError as exc:
            print(f"FAIL: {exc}", file=sys.stderr)
            return 1
    if args.command is None:
        _parser().print_help()
        return 0
    if args.command == "config":
        try:
            validate_config(args.file)
            print(f"PASS: valid config TOML: {args.file}")
            return 0
        except ConfigError as exc:
            print(f"FAIL: {exc}", file=sys.stderr)
            return 1
    if args.command == "versions":
        return _versions()
    if args.command in {"start", "stop", "restart"}:
        from . import runtime, secrets
        try:
            runtime.lifecycle(args.command)
            print(f"PASS: {args.command} completed")
            return 0
        except (
            runtime.RuntimeConfigError,
            runtime.RuntimeErrorV2,
            secrets.SecretsError,
            LockBusyError,
            VersionsError,
        ) as exc:
            print(f"FAIL: {exc}", file=sys.stderr)
            return 1
    if args.command == "status":
        from . import recovery, runtime
        overall, rows = runtime.status()
        for row in rows:
            print(f"{row['service']}: {row['state']} (health={row['health']})")
        for row in recovery.status_rows():
            print(f"recovery-{row['kind']}: {row['state']} (verified_at={row['verified_at']})")
        print(f"Overall: {overall}")
        return 0 if overall in {"running", "stopped"} else 1
    if args.command == "logs":
        if not 1 <= args.tail <= 10000:
            print("FAIL: --tail must be between 1 and 10000", file=sys.stderr)
            return 2
        from . import runtime
        code, results = runtime.logs(args.service, tail=args.tail)
        for name, result in results:
            print(f"== {name} ==")
            if result.stdout:
                print(result.stdout, end="" if result.stdout.endswith("\n") else "\n")
            if result.stderr:
                print(result.stderr, file=sys.stderr, end="" if result.stderr.endswith("\n") else "\n")
        return code
    if args.command == "backup":
        from . import recovery, runtime
        try:
            config = runtime.load_config()
            verified = recovery.create_recovery(config.offline_recovery_recipient, remote=args.remote)
            print(f"PASS: verified local recovery {verified.artifact} sha256={verified.sha256}")
            if args.remote:
                print("PASS: offsite publication was remotely re-downloaded and checksum-verified")
            return 0
        except (recovery.RecoveryError, runtime.RuntimeConfigError, LockBusyError, OSError) as exc:
            print(f"FAIL: {exc}", file=sys.stderr)
            return 1
    if args.command == "restore":
        from . import recovery
        try:
            if args.file is not None:
                manifest = recovery.restore_recovery(args.file, args.identity, start=args.start)
            else:
                manifest = recovery.restore_from_remote(args.from_remote, args.identity, start=args.start)
            print(f"PASS: restored V2 recovery created {manifest['created_at']}")
            if not args.start:
                print("ACTION: services remain stopped; run 'vwctl start' when you are ready to bring the restored service online")
            return 0
        except (recovery.RecoveryError, LockBusyError, OSError) as exc:
            print(f"FAIL: {exc}", file=sys.stderr)
            return 1
    if args.command == "recovery":
        from . import recovery
        try:
            if args.recovery_command == "prune":
                decision = recovery.prune_remote(
                    args.remote,
                    args.keep_last,
                    confirm=args.confirm,
                )
                print("Keep:")
                for name in decision.keep:
                    print(f"  {name}")
                print("Delete:")
                for name in decision.delete:
                    print(f"  {name}")
                if decision.delete and not args.confirm:
                    print("PLAN ONLY: pass --confirm to execute these explicit deletions")
                elif args.confirm:
                    print("PASS: explicit remote pruning completed")
                return 0
        except (recovery.RecoveryError, OSError) as exc:
            print(f"FAIL: {exc}", file=sys.stderr)
            return 1
    if args.command == "edge":
        from . import edge
        try:
            if args.edge_command == "refresh":
                policy = edge.refresh_origin_policy()
                print(
                    f"PASS: Cloudflare edge policy source={policy.source} "
                    f"ipv4={len(policy.ipv4)} ipv6={len(policy.ipv6)}"
                )
                return 0
        except edge.EdgeError as exc:
            print(f"FAIL: {exc}", file=sys.stderr)
            return 1
    if args.command == "crowdsec":
        from . import edge, secrets
        try:
            if args.crowdsec_command == "setup":
                edge.setup_crowdsec()
                print("PASS: CrowdSec Security Engine and Cloudflare remediation boundary configured")
                print("ACTION: run 'vwctl crowdsec remediation-start' to create one explicit Worker Route invocation")
                return 0
            if args.crowdsec_command == "remediation-start":
                edge.start_remediation()
                print("PASS: CrowdSec Cloudflare remediation started for one explicit service invocation")
                print("ACTION: set every bouncer-created Worker Route to Fail Open in Cloudflare, then run 'vwctl crowdsec confirm-fail-open'")
                return 0
            if args.crowdsec_command == "confirm-fail-open":
                edge.confirm_fail_open()
                print("PASS: Fail Open confirmation recorded for the current CrowdSec Cloudflare invocation")
                return 0
            if args.crowdsec_command == "prepare-remediation":
                edge.prepare_remediation(config_path=DEFAULT_CONFIG_PATH)
                return 0
            if args.crowdsec_command == "consume-start-token":
                edge.consume_remediation_start_token()
                return 0
            if args.crowdsec_command == "status":
                checks = edge.doctor_checks()
                for check in checks:
                    if check.check_id.startswith("crowdsec."):
                        print(f"[{check.status}] {check.check_id}: {check.message}")
                return 1 if any(c.status == "FAIL" and c.check_id.startswith("crowdsec.") for c in checks) else 0
        except (edge.EdgeError, secrets.SecretsError, ConfigError, LockBusyError) as exc:
            print(f"FAIL: {exc}", file=sys.stderr)
            return 1
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
    return 2


if __name__ == "__main__":
    raise SystemExit(main())