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
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

from . import recovery, runtime


@dataclass
class PreparedRestore:
    manifest: dict[str, object]
    staged: list[tuple[Path, Path]]
    paths: recovery.RecoveryPaths
    cleanup_runtime_secrets: bool

    def promote_locked(self, *, runner=recovery.run_command) -> None:
        """Stop any remaining containers and atomically promote staged data.

        The caller must already own ``paths.lock``.  This method deliberately
        does not acquire or release the mutation lock itself.
        """
        recovery._stop_services(
            runner,
            cleanup_runtime_secrets=self.cleanup_runtime_secrets,
        )
        recovery._promote(self.staged)


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
                if candidate.exists():
                    if candidate.is_dir():
                        shutil.rmtree(candidate, ignore_errors=True)
                    else:
                        candidate.unlink(missing_ok=True)
            if operational_candidate is not None and operational_candidate.exists():
                operational_candidate.unlink(missing_ok=True)
