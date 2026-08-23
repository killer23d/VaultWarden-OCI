"""Candidate activation primitive for appliance updates."""
from __future__ import annotations

from pathlib import Path

from . import edge, runtime, secrets, update
from .update_versions import FrozenVersions, UpdateError


def _started_failure(message: str, paths: runtime.Paths, runner: update.Runner) -> None:
    runner(["docker", "compose", "-f", str(paths.compose), "down"])
    try:
        secrets.cleanup(paths.secret_paths())
    except secrets.SecretsError:
        pass
    raise update.RuntimeActivationError(message, state_change_possible=True)


def activate_runtime(frozen: FrozenVersions, versions_path: Path, runner: update.Runner) -> None:
    """Activate the prebuilt exact candidate and preserve the persistent-state boundary."""
    paths = runtime.Paths()
    try:
        if not runtime.tools(runner):
            raise UpdateError("Docker Engine + Compose with wait support are required")
        help_result = runner(["docker", "compose", "up", "--help"])
        if not help_result.ok or "--no-build" not in help_result.stdout or "--pull" not in help_result.stdout:
            raise UpdateError("Docker Compose with --no-build and --pull is required")
        runtime.validate_service_identities()
        runtime.ensure_paths(paths)
        config = runtime.load_config(paths.config)
        edge.refresh_origin_policy(runner=runner)
        values = secrets.load(config.offline_recovery_recipient, paths=paths.secret_paths(), runner=runner)
        admin_enabled = secrets.admin_enabled(values)
        derived: dict[str, str] = {}
        if admin_enabled:
            derived["admin_basic_auth_hash"] = secrets.derive_admin_basic_auth_hash(
                values["admin_basic_auth_password"], frozen.caddy_image
            )
        runtime.render(config, versions_path, paths, admin_enabled=admin_enabled)
        check = runner(["docker", "compose", "-f", str(paths.compose), "config", "--quiet"])
        if not check.ok:
            raise UpdateError("rendered Compose validation failed during update activation")
        secrets.materialize(values, derived=derived, paths=paths.secret_paths())
    except Exception as exc:
        if isinstance(exc, KeyboardInterrupt):
            raise
        raise update.RuntimeActivationError(str(exc), state_change_possible=False) from exc

    result = runner([
        "docker", "compose", "-f", str(paths.compose), "up", "-d",
        "--no-build", "--pull", "never", "--force-recreate", "--wait", "--wait-timeout", "120",
    ])
    if not result.ok:
        _started_failure(
            "candidate Compose activation failed after runtime start was attempted",
            paths,
            runner,
        )

    https = runner([
        "curl", "--fail", "--silent", "--show-error", "--output", "/dev/null",
        "--max-time", "20", f"https://{config.domain}/",
    ])
    if not https.ok:
        _started_failure(
            "candidate public HTTPS gate failed after runtime start was attempted",
            paths,
            runner,
        )
