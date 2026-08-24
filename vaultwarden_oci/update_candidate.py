"""Candidate-owned prepare/activate/stop primitives for appliance updates.

This module is intentionally executed through the candidate release's own
``vwctl`` entrypoint.  The installed updater orchestrates the transaction, but
candidate runtime rendering and activation semantics come from candidate code.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import tempfile
from pathlib import Path
from typing import Mapping, Sequence

from . import cli, edge, runtime, secrets
from .update_versions import FrozenVersions, UpdateError, resolve_pinned_file

PRESTART_FAILURE = 20
POSTSTART_FAILURE = 21
_MANIFEST = "candidate-render.json"


class CandidateActivationError(UpdateError):
    def __init__(self, message: str, *, state_change_possible: bool) -> None:
        super().__init__(message)
        self.state_change_possible = state_change_possible


def _detail(result: cli.CommandResult) -> str:
    return result.stderr.strip() or result.stdout.strip() or result.kind


def _candidate_paths(root: Path) -> runtime.Paths:
    transient = root / "rendered"
    transient.mkdir(parents=True, exist_ok=True)
    return runtime.Paths(
        config=runtime.CONFIG,
        data=runtime.STATE / "data",
        caddy_data=runtime.STATE / "caddy/data",
        caddy_config=runtime.STATE / "caddy/config",
        caddy_log=runtime.STATE / "caddy/log",
        run=root,
        transient=transient,
        lock=root / "lock",
        secret_root=runtime.RUN / "secrets",
    )


def _bundle_files(paths: runtime.Paths) -> tuple[Path, ...]:
    return (paths.compose, paths.caddyfile, paths.dockerfile)


def _bundle_digest(paths: runtime.Paths, *, admin_enabled: bool) -> str:
    digest = hashlib.sha256()
    digest.update(b"admin_enabled=")
    digest.update(b"1" if admin_enabled else b"0")
    digest.update(b"\0")
    for path in _bundle_files(paths):
        if path.is_symlink() or not path.is_file():
            raise UpdateError(f"candidate rendered resource is missing or unsafe: {path}")
        digest.update(path.name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def _atomic_json(path: Path, payload: Mapping[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
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
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def _manifest_path(render_root: Path) -> Path:
    return render_root / _MANIFEST


def _load_manifest(render_root: Path) -> dict[str, object]:
    path = _manifest_path(render_root)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise UpdateError(f"candidate render manifest is unavailable or invalid: {exc}") from exc
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise UpdateError("candidate render manifest has an unsupported schema")
    return value


def _ensure_compose_features(runner=cli.run_command) -> None:
    if not runtime.tools(runner):
        raise UpdateError("Docker Engine + Compose with wait support are required")
    help_result = runner(["docker", "compose", "up", "--help"])
    if (
        not help_result.ok
        or "--no-build" not in help_result.stdout
        or "--pull" not in help_result.stdout
    ):
        raise UpdateError("Docker Compose with --no-build and --pull is required")


def prepare(
    versions_path: Path,
    render_root: Path,
    *,
    runner=cli.run_command,
) -> dict[str, object]:
    """Render/build/validate with candidate code while the old stack stays live."""
    frozen = resolve_pinned_file(versions_path)
    _ensure_compose_features(runner)
    config = runtime.load_config()
    values = secrets.load(config.offline_recovery_recipient, runner=runner)
    admin_enabled = secrets.admin_enabled(values)

    for pin in (frozen.vaultwarden_image, frozen.caddy_builder_image, frozen.caddy_runtime_image):
        result = runner(["docker", "pull", pin.reference])
        if not result.ok:
            raise UpdateError(f"cannot pull exact {pin.name} image: {_detail(result)}")

    paths = _candidate_paths(render_root)
    runtime.render(config, versions_path, paths, admin_enabled=admin_enabled)
    compose = runner(["docker", "compose", "-f", str(paths.compose), "config", "--quiet"])
    if not compose.ok:
        raise UpdateError(f"candidate Compose validation failed: {_detail(compose)}")

    built = runner(
        [
            "docker",
            "build",
            "--pull=false",
            "--tag",
            frozen.caddy_image,
            "--file",
            str(paths.dockerfile),
            str(paths.transient),
        ]
    )
    if not built.ok:
        raise UpdateError(f"exact custom Caddy build failed: {_detail(built)}")

    caddy = runner(
        [
            "docker",
            "run",
            "--rm",
            "--env",
            f"VAULTWARDEN_DOMAIN={config.domain}",
            "--env",
            f"ACME_EMAIL={config.acme_email}",
            "--env",
            "CLOUDFLARE_API_TOKEN=validation-only",
            "--env",
            "ADMIN_BASIC_AUTH_HASH=$2a$14$validationonlyvalidationonlyvalidationonlyvalidationonly",
            "--volume",
            f"{paths.caddyfile}:/etc/caddy/Caddyfile:ro",
            frozen.caddy_image,
            "caddy",
            "validate",
            "--config",
            "/etc/caddy/Caddyfile",
            "--adapter",
            "caddyfile",
        ]
    )
    if not caddy.ok:
        raise UpdateError(f"candidate Caddy validation failed: {_detail(caddy)}")

    payload: dict[str, object] = {
        "schema_version": 1,
        "project_version": frozen.project_version,
        "caddy_image": frozen.caddy_image,
        "admin_enabled": admin_enabled,
        "render_sha256": _bundle_digest(paths, admin_enabled=admin_enabled),
    }
    _atomic_json(_manifest_path(render_root), payload)
    return payload


def _atomic_copy(source: Path, destination: Path) -> None:
    if source.is_symlink() or not source.is_file():
        raise UpdateError(f"prepared candidate resource is missing or unsafe: {source}")
    source_info = source.stat()
    mode = stat.S_IMODE(source_info.st_mode)
    destination.parent.mkdir(parents=True, exist_ok=True)
    tmp = destination.parent / f".{destination.name}.{os.getpid()}.tmp"
    try:
        fd = os.open(
            tmp,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            mode,
        )
        with os.fdopen(fd, "wb") as handle:
            handle.write(source.read_bytes())
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, destination)
        os.chmod(destination, mode)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def stop_locked(*, runner=cli.run_command) -> bool:
    """Stop/remove candidate containers without acquiring the appliance lock.

    The parent updater already owns the mutation lock when this primitive is used.
    """
    docker = runner(["docker", "version", "--format", "{{.Server.Version}}"])
    if not docker.ok:
        return False
    existing: list[str] = []
    for container in (runtime.NAMES["caddy"], runtime.NAMES["vaultwarden"]):
        inspection = runner(["docker", "container", "inspect", container])
        if inspection.ok:
            existing.append(container)
            continue
        detail = (inspection.stderr or inspection.stdout).lower()
        if "no such object" not in detail and "no such container" not in detail:
            return False
    if existing:
        if not runner(["docker", "stop", *existing]).ok:
            return False
        if not runner(["docker", "rm", *existing]).ok:
            return False
    for container in (runtime.NAMES["caddy"], runtime.NAMES["vaultwarden"]):
        inspection = runner(["docker", "container", "inspect", container])
        if inspection.ok:
            return False
        detail = (inspection.stderr or inspection.stdout).lower()
        if "no such object" not in detail and "no such container" not in detail:
            return False
    try:
        secrets.cleanup()
    except secrets.SecretsError:
        return False
    return True


def activate(
    versions_path: Path,
    render_root: Path,
    *,
    runner=cli.run_command,
) -> None:
    """Activate only resources rendered and validated by this candidate release."""
    frozen = resolve_pinned_file(versions_path)
    manifest = _load_manifest(render_root)
    try:
        if manifest.get("project_version") != frozen.project_version:
            raise UpdateError("prepared candidate project version does not match staged release")
        if manifest.get("caddy_image") != frozen.caddy_image:
            raise UpdateError("prepared candidate Caddy image does not match staged release")
        _ensure_compose_features(runner)
        runtime.validate_service_identities()
        production = runtime.Paths()
        runtime.ensure_paths(production)
        config = runtime.load_config(production.config)
        edge.refresh_origin_policy(runner=runner)
        values = secrets.load(
            config.offline_recovery_recipient,
            paths=production.secret_paths(),
            runner=runner,
        )
        admin_enabled = secrets.admin_enabled(values)
        if manifest.get("admin_enabled") is not admin_enabled:
            raise UpdateError("admin enablement changed after candidate pre-validation")

        with tempfile.TemporaryDirectory(prefix="candidate-recheck-", dir=str(render_root)) as directory:
            check_paths = _candidate_paths(Path(directory))
            runtime.render(config, versions_path, check_paths, admin_enabled=admin_enabled)
            actual = _bundle_digest(check_paths, admin_enabled=admin_enabled)
        expected = manifest.get("render_sha256")
        if not isinstance(expected, str) or actual != expected:
            raise UpdateError("candidate rendered resources changed after pre-validation")

        prepared = _candidate_paths(render_root)
        for source, destination in zip(_bundle_files(prepared), _bundle_files(production), strict=True):
            _atomic_copy(source, destination)
        compose = runner(["docker", "compose", "-f", str(production.compose), "config", "--quiet"])
        if not compose.ok:
            raise UpdateError("prepared Compose failed validation at activation boundary")

        derived: dict[str, str] = {}
        if admin_enabled:
            derived["admin_basic_auth_hash"] = secrets.derive_admin_basic_auth_hash(
                values["admin_basic_auth_password"], frozen.caddy_image
            )
        secrets.materialize(values, derived=derived, paths=production.secret_paths())
    except Exception as exc:
        if isinstance(exc, KeyboardInterrupt):
            raise
        if isinstance(exc, CandidateActivationError):
            raise
        raise CandidateActivationError(str(exc), state_change_possible=False) from exc

    result = runner(
        [
            "docker",
            "compose",
            "-f",
            str(production.compose),
            "up",
            "-d",
            "--no-build",
            "--pull",
            "never",
            "--force-recreate",
            "--wait",
            "--wait-timeout",
            "120",
        ]
    )
    if not result.ok:
        stopped = stop_locked(runner=runner)
        raise CandidateActivationError(
            "candidate Compose activation failed after runtime start was attempted"
            + ("; candidate was stopped" if stopped else "; candidate stop could not be proven"),
            state_change_possible=True,
        )

    https = runner(
        [
            "curl",
            "--fail",
            "--silent",
            "--show-error",
            "--output",
            "/dev/null",
            "--max-time",
            "20",
            f"https://{config.domain}/",
        ]
    )
    if not https.ok:
        stopped = stop_locked(runner=runner)
        raise CandidateActivationError(
            "candidate public HTTPS gate failed after runtime start was attempted"
            + ("; candidate was stopped" if stopped else "; candidate stop could not be proven"),
            state_change_possible=True,
        )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vwctl __update-candidate", add_help=False)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("prepare", "activate"):
        item = sub.add_parser(name, add_help=False)
        item.add_argument("--versions", type=Path, required=True)
        item.add_argument("--render-root", type=Path, required=True)
    sub.add_parser("stop", add_help=False)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(list(argv or ()))
    try:
        if args.command == "prepare":
            payload = prepare(args.versions, args.render_root)
            print(json.dumps({"ok": True, **payload}, sort_keys=True))
            return 0
        if args.command == "activate":
            activate(args.versions, args.render_root)
            print(json.dumps({"ok": True, "state_change_possible": True}, sort_keys=True))
            return 0
        if args.command == "stop":
            stopped = stop_locked()
            print(json.dumps({"ok": stopped, "stopped": stopped}, sort_keys=True))
            return 0 if stopped else 1
    except CandidateActivationError as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": str(exc),
                    "state_change_possible": exc.state_change_possible,
                },
                sort_keys=True,
            )
        )
        return POSTSTART_FAILURE if exc.state_change_possible else PRESTART_FAILURE
    except Exception as exc:
        print(
            json.dumps(
                {"ok": False, "error": str(exc), "state_change_possible": False},
                sort_keys=True,
            )
        )
        return PRESTART_FAILURE
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
