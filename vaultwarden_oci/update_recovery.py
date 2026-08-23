"""Prepared recovery adapter for coherent application rollback.

The recovery module remains the data-restore owner.  This adapter reuses its
validated staging primitives so the updater can prepare expensive decryption
and validation before taking the appliance mutation lock, then promote the
prepared recovery inside the *same* lock transaction as the previous-release
systemd/current switch.
"""
from __future__ import annotations

import os
import shutil
import tempfile
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Sequence

from . import recovery, runtime


class PromotionError(recovery.RecoveryError):
    """Recovery promotion failed; records whether original live state was restored."""

    def __init__(self, message: str, *, rollback_complete: bool) -> None:
        super().__init__(message)
        self.rollback_complete = rollback_complete


def _remove(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        return
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()


def _promote_with_proven_rollback(staged: Sequence[tuple[Path, Path]]) -> None:
    """Promote staged targets and prove restoration of live state on failure."""
    rollback: list[tuple[Path, Path | None]] = []
    try:
        for candidate, target in staged:
            previous: Path | None = None
            if target.exists() or target.is_symlink():
                previous = target.parent / f".{target.name}.rollback-{uuid.uuid4().hex[:8]}"
                os.replace(target, previous)
            rollback.append((target, previous))
            os.replace(candidate, target)
    except Exception as exc:
        failures: list[str] = []
        for target, previous in reversed(rollback):
            try:
                _remove(target)
                if previous is not None:
                    if not previous.exists() and not previous.is_symlink():
                        raise OSError(f"missing rollback source {previous}")
                    os.replace(previous, target)
                    if not (target.exists() or target.is_symlink()):
                        raise OSError(f"rollback target was not restored: {target}")
                elif target.exists() or target.is_symlink():
                    raise OSError(f"target that was originally absent still exists: {target}")
            except OSError as rollback_exc:
                failures.append(f"{target}: {rollback_exc}")
        if failures:
            raise PromotionError(
                f"restore promotion failed and original live state could not be proven restored: {exc}; "
                + "; ".join(failures),
                rollback_complete=False,
            ) from exc
        raise PromotionError(
            f"restore promotion failed; original live state was restored and proven: {exc}",
            rollback_complete=True,
        ) from exc

    for _, previous in rollback:
        if previous is not None and (previous.exists() or previous.is_symlink()):
            _remove(previous)


@dataclass
class PreparedRestore:
    manifest: dict[str, object]
    staged: list[tuple[Path, Path]]
    paths: recovery.RecoveryPaths
    cleanup_runtime_secrets: bool

    def promote_locked(self, *, runner=recovery.run_command) -> None:
        """Stop remaining containers and promote staged data under the caller's lock."""
        recovery._stop_services(
            runner,
            cleanup_runtime_secrets=self.cleanup_runtime_secrets,
        )
        _promote_with_proven_rollback(self.staged)


@contextmanager
def prepare_restore(
    artifact: Path,
    identity: Path,
    *,
    paths: recovery.RecoveryPaths = recovery.RecoveryPaths(),
    runner=recovery.run_command,
) -> Iterator[PreparedRestore]:
    """Prepare a verified restore without promoting any live application data."""
    default_paths = paths == recovery.RecoveryPaths()
    if default_paths and os.geteuid() != 0:
        raise recovery.RecoveryError("coherent update rollback must run as root")
    paths.backups.mkdir(parents=True, exist_ok=True)
    uid, gid = (0, 0) if default_paths else (os.geteuid(), os.getegid())
    vw_uid, vw_gid = (
        (runtime.VAULTWARDEN_UID, runtime.VAULTWARDEN_GID)
        if default_paths
        else (uid, gid)
    )
    caddy_uid, caddy_gid = (
        (runtime.CADDY_UID, runtime.CADDY_GID)
        if default_paths
        else (uid, gid)
    )

    with tempfile.TemporaryDirectory(
        prefix="vwrec-update-rollback-",
        dir=str(paths.backups),
    ) as directory:
        root = Path(directory)
        extracted = root / "extracted"
        extracted.mkdir()
        manifest = recovery._decrypt_and_validate(
            artifact,
            identity,
            extracted,
            runner=runner,
        )
        payload = extracted / "payload"
        _, offline_recipient = recovery._validate_offline_sops(
            payload,
            identity,
            runner=runner,
        )
        recovery._preflight_targets(paths, extracted)

        staged = [
            (recovery._copy_stage_to_target_parent(source, target), target)
            for source, target in recovery._restore_sources(paths, extracted)
        ]
        staged_by_target = {target: candidate for candidate, target in staged}
        operational_candidate: Path | None = None
        try:
            staged_sops = staged_by_target[paths.encrypted_secrets]
            recovery._apply_permissions(staged_by_target[paths.config], uid, gid)
            recovery._apply_permissions(staged_sops, uid, gid)
            recovery._apply_permissions(staged_by_target[paths.data], vw_uid, vw_gid)
            recovery._apply_permissions(staged_by_target[paths.caddy_data], caddy_uid, caddy_gid)
            recovery._apply_permissions(staged_by_target[paths.caddy_config], caddy_uid, caddy_gid)
            recovery._sqlite_snapshot(
                staged_by_target[paths.data] / recovery._DB_NAME,
                root / "sqlite-proof.db",
            )

            operational_candidate = recovery._prepare_operational_custody(
                paths,
                staged_sops,
                identity,
                offline_recipient,
                runner=runner,
                uid=uid,
                gid=gid,
            )
            if operational_candidate is not None:
                staged.append((operational_candidate, paths.operational_age_key))

            yield PreparedRestore(
                manifest=manifest,
                staged=staged,
                paths=paths,
                cleanup_runtime_secrets=default_paths,
            )
        finally:
            for candidate, _ in staged:
                if candidate.exists() or candidate.is_symlink():
                    try:
                        _remove(candidate)
                    except OSError:
                        pass
            if operational_candidate is not None and (
                operational_candidate.exists() or operational_candidate.is_symlink()
            ):
                try:
                    _remove(operational_candidate)
                except OSError:
                    pass
