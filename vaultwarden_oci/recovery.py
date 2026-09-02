"""Encrypted application recovery and rclone publication owner."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import sqlite3
import stat
import tarfile
import tempfile
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Callable, Iterable, Mapping, Sequence

from . import runtime, runtime_health, secrets
from .cli import CommandResult, DoctorCheck, mutation_lock, run_command

FORMAT_VERSION = 2
ETC = Path("/etc/vaultwarden-oci")
STATE_ROOT = Path("/var/lib/vaultwarden-oci")
BACKUP_DIR = STATE_ROOT / "backups"
RECOVERY_STATE = STATE_ROOT / "state/recovery.json"
CONFIG = ETC / "config.toml"
ENCRYPTED_SECRETS = ETC / "secrets.sops.yaml"
OPERATIONAL_AGE_KEY = ETC / "age-key.txt"
_ALLOWED_TOP_LEVEL = {"manifest.json", "payload"}
_DB_NAME = "db.sqlite3"
_DB_SIDECARS = {"db.sqlite3-wal", "db.sqlite3-shm"}
_FREE_SPACE_MARGIN = 16 * 1024 * 1024


class RecoveryError(RuntimeError):
    pass


@dataclass(frozen=True)
class RecoveryPaths:
    backups: Path = BACKUP_DIR
    state_file: Path = RECOVERY_STATE
    config: Path = CONFIG
    encrypted_secrets: Path = ENCRYPTED_SECRETS
    operational_age_key: Path = OPERATIONAL_AGE_KEY
    data: Path = STATE_ROOT / "data"
    caddy_data: Path = STATE_ROOT / "caddy/data"
    caddy_config: Path = STATE_ROOT / "caddy/config"
    lock: Path = runtime.LOCK


@dataclass(frozen=True)
class VerifiedRecovery:
    artifact: Path
    sha256: str
    size: int
    created_at: str


@dataclass(frozen=True)
class PruneDecision:
    keep: tuple[str, ...]
    delete: tuple[str, ...]


Runner = Callable[..., CommandResult]


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_error(label: str, result: CommandResult) -> RecoveryError:
    detail = result.kind if result.returncode is None else f"exit {result.returncode}"
    return RecoveryError(f"{label} failed ({detail})")


def _ensure_regular(path: Path, label: str, *, nonempty: bool = False) -> None:
    try:
        info = path.lstat()
    except OSError as exc:
        raise RecoveryError(f"cannot inspect {label} {path}: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise RecoveryError(f"{label} must be a regular file: {path}")
    if nonempty and info.st_size == 0:
        raise RecoveryError(f"{label} must be non-empty: {path}")


def _ensure_directory(path: Path, label: str) -> None:
    try:
        info = path.lstat()
    except OSError as exc:
        raise RecoveryError(f"cannot inspect {label} {path}: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise RecoveryError(f"{label} must be a directory: {path}")


def _copy_tree(source: Path, destination: Path, *, skip_names: set[str] | None = None) -> None:
    skip_names = skip_names or set()
    destination.mkdir(parents=True, exist_ok=True)
    for entry in source.iterdir():
        if entry.name in skip_names:
            continue
        target = destination / entry.name
        info = entry.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise RecoveryError(f"recovery source contains unsupported symlink: {entry}")
        if stat.S_ISDIR(info.st_mode):
            _copy_tree(entry, target)
        elif stat.S_ISREG(info.st_mode):
            shutil.copy2(entry, target)
        else:
            raise RecoveryError(f"recovery source contains unsupported file type: {entry}")


def _sqlite_snapshot(source: Path, destination: Path) -> None:
    _ensure_regular(source, "Vaultwarden SQLite database", nonempty=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        source_db = sqlite3.connect(f"file:{source}?mode=ro", uri=True, timeout=10)
        target_db = sqlite3.connect(destination)
        try:
            source_db.backup(target_db)
            row = target_db.execute("PRAGMA integrity_check").fetchone()
            if row != ("ok",):
                raise RecoveryError("SQLite snapshot integrity_check failed")
            target_db.commit()
        finally:
            target_db.close()
            source_db.close()
    except (sqlite3.Error, OSError) as exc:
        destination.unlink(missing_ok=True)
        raise RecoveryError(f"cannot create consistent SQLite snapshot: {exc}") from exc


def _manifest_files(payload: Path) -> list[dict[str, object]]:
    files: list[dict[str, object]] = []
    for path in sorted(payload.rglob("*")):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise RecoveryError(f"recovery payload contains unsupported symlink: {path}")
        if stat.S_ISREG(info.st_mode):
            files.append(
                {
                    "path": path.relative_to(payload.parent).as_posix(),
                    "sha256": _sha256(path),
                    "size": info.st_size,
                }
            )
    return files


def _write_manifest(staging: Path, *, created_at: str) -> dict[str, object]:
    manifest: dict[str, object] = {
        "format": "vaultwarden-oci-recovery",
        "format_version": FORMAT_VERSION,
        "created_at": created_at,
        "files": _manifest_files(staging / "payload"),
    }
    path = staging / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)
    return manifest


def _validate_manifest(staging: Path) -> dict[str, object]:
    manifest_path = staging / "manifest.json"
    _ensure_regular(manifest_path, "recovery manifest", nonempty=True)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise RecoveryError(f"invalid recovery manifest: {exc}") from exc
    if not isinstance(manifest, dict) or manifest.get("format") != "vaultwarden-oci-recovery":
        raise RecoveryError("unsupported recovery manifest")
    if manifest.get("format_version") != FORMAT_VERSION:
        raise RecoveryError("restore supports .vwrec format version 2 only")
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        raise RecoveryError("recovery manifest has no files")
    seen: set[str] = set()
    for item in files:
        if not isinstance(item, dict):
            raise RecoveryError("invalid recovery manifest file entry")
        name, digest, size = item.get("path"), item.get("sha256"), item.get("size")
        if (
            not isinstance(name, str)
            or not isinstance(digest, str)
            or len(digest) != 64
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size < 0
        ):
            raise RecoveryError("invalid recovery manifest file entry")
        pure = PurePosixPath(name)
        if pure.is_absolute() or ".." in pure.parts or not pure.parts or pure.parts[0] != "payload":
            raise RecoveryError("recovery manifest contains an unsafe path")
        if name in seen:
            raise RecoveryError("recovery manifest contains duplicate paths")
        seen.add(name)
        path = staging / Path(*pure.parts)
        _ensure_regular(path, "recovery payload file")
        if path.stat().st_size != size or _sha256(path) != digest:
            raise RecoveryError(f"recovery checksum mismatch: {name}")
    actual = {
        path.relative_to(staging).as_posix()
        for path in (staging / "payload").rglob("*")
        if path.is_file()
    }
    if actual != seen:
        raise RecoveryError("recovery payload and manifest file set differ")
    required = {
        "payload/etc/config.toml",
        "payload/etc/secrets.sops.yaml",
        "payload/data/db.sqlite3",
    }
    if not required <= seen:
        raise RecoveryError("recovery manifest is incomplete")
    if any(name.endswith("/age-key.txt") for name in seen):
        raise RecoveryError("operational Age private key must not appear in recovery artifacts")
    return manifest


def _inspect_absent(result: CommandResult) -> bool:
    if result.ok:
        return False
    message = (result.stderr or result.stdout).lower()
    return "no such object" in message or "no such container" in message


def _resume_paused_services(paused: Sequence[str], runner: Runner) -> None:
    failures = [
        container
        for container in reversed(paused)
        if not runner(["docker", "unpause", container]).ok
    ]
    if failures:
        raise RecoveryError("failed to resume quiesced recovery service(s): " + ", ".join(failures))


def _pause_live_services(runner: Runner) -> tuple[tuple[str, ...], tuple[str, ...]]:
    if not runner(["docker", "version", "--format", "{{.Server.Version}}"]).ok:
        raise RecoveryError("Docker Engine unavailable; cannot prove a quiescent recovery point")
    paused: list[str] = []
    previously_healthy: list[str] = []
    try:
        for service in ("caddy", "vaultwarden"):
            container = runtime.NAMES[service]
            inspection = runner(
                ["docker", "container", "inspect", "--format", "{{json .State}}", container]
            )
            if not inspection.ok:
                if _inspect_absent(inspection):
                    continue
                raise RecoveryError("Docker container inspection failed; backup consistency is unknown")
            try:
                state = json.loads(inspection.stdout)
            except json.JSONDecodeError as exc:
                raise RecoveryError("Docker container state was not valid JSON") from exc
            if not isinstance(state, dict):
                raise RecoveryError("Docker container state was not an object")
            status = state.get("Status")
            is_paused = state.get("Paused") is True
            health_state = state.get("Health")
            was_healthy = isinstance(health_state, dict) and health_state.get("Status") == "healthy"
            if status == "running" and not is_paused:
                if not runner(["docker", "pause", container]).ok:
                    raise RecoveryError(f"failed to quiesce {container} for recovery")
                paused.append(container)
                if was_healthy:
                    previously_healthy.append(service)
            elif status == "running" and is_paused:
                continue
            elif status in {"created", "exited", "dead"}:
                continue
            else:
                raise RecoveryError(
                    f"unsupported container state for recovery consistency: {container}={status!r}"
                )
    except Exception as exc:
        try:
            _resume_paused_services(paused, runner)
        except RecoveryError as resume_exc:
            raise RecoveryError(f"{exc}; additionally {resume_exc}") from exc
        raise
    return tuple(paused), tuple(previously_healthy)


def _wait_for_resumed_health(
    required: Sequence[str],
    runner: Runner,
    *,
    settle_seconds: float = runtime_health.SETTLE_SECONDS,
    poll_seconds: float = runtime_health.POLL_SECONDS,
    sleep: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
) -> None:
    required_set = set(required)
    if not required_set:
        return
    if not required_set <= set(runtime.NAMES):
        raise RecoveryError("post-backup health proof received an unknown runtime service")

    def probe() -> tuple[bool, bool, str]:
        _, rows = runtime.status(runner=runner)
        by_service = {row["service"]: row for row in rows}
        pending: list[str] = []
        unsafe: list[str] = []
        for service in sorted(required_set):
            row = by_service.get(service)
            if row is None:
                unsafe.append(f"{service}=missing")
                continue
            state, health = row["state"], row["health"]
            if state == "running" and health == "healthy":
                continue
            detail = f"{service}={state}/{health}"
            if state == "running" and health in {"starting", "unhealthy"}:
                pending.append(detail)
            else:
                unsafe.append(detail)
        if not pending and not unsafe:
            return True, False, "post-backup runtime health recovered"
        detail = ", ".join(unsafe + pending)
        return False, not unsafe, detail

    try:
        runtime_health.wait_until_ready(
            probe,
            settle_seconds=settle_seconds,
            poll_seconds=poll_seconds,
            sleep=sleep,
            monotonic=monotonic,
        )
    except runtime_health.RuntimeHealthError as exc:
        raise RecoveryError(f"post-backup runtime health did not recover: {exc}") from exc


def _build_candidate(paths: RecoveryPaths, staging: Path) -> dict[str, object]:
    _ensure_regular(paths.config, "operator config", nonempty=True)
    _ensure_regular(paths.encrypted_secrets, "encrypted secrets document", nonempty=True)
    _ensure_directory(paths.data, "Vaultwarden data")
    _ensure_directory(paths.caddy_data, "Caddy data")
    _ensure_directory(paths.caddy_config, "Caddy config")
    if paths.encrypted_secrets == paths.operational_age_key or paths.config == paths.operational_age_key:
        raise RecoveryError("operational Age private key cannot be a recovery input")
    payload = staging / "payload"
    etc = payload / "etc"
    etc.mkdir(parents=True)
    shutil.copy2(paths.config, etc / "config.toml")
    shutil.copy2(paths.encrypted_secrets, etc / "secrets.sops.yaml")
    _copy_tree(paths.data, payload / "data", skip_names={_DB_NAME, *_DB_SIDECARS})
    _sqlite_snapshot(paths.data / _DB_NAME, payload / "data" / _DB_NAME)
    _copy_tree(paths.caddy_data, payload / "caddy/data")
    _copy_tree(paths.caddy_config, payload / "caddy/config")
    return _write_manifest(staging, created_at=_utc_now())


def _safe_extract(archive: Path, destination: Path) -> None:
    try:
        with tarfile.open(archive, "r") as tar:
            members = tar.getmembers()
            if not members:
                raise RecoveryError("recovery archive is empty")
            for member in members:
                pure = PurePosixPath(member.name)
                if pure.is_absolute() or ".." in pure.parts or not pure.parts:
                    raise RecoveryError("recovery archive contains an unsafe path")
                if pure.parts[0] not in _ALLOWED_TOP_LEVEL:
                    raise RecoveryError("recovery archive contains an unexpected top-level path")
                if not (member.isdir() or member.isreg()):
                    raise RecoveryError("recovery archive contains an unsupported file type")
            tar.extractall(destination, members=members)
    except (tarfile.TarError, OSError) as exc:
        raise RecoveryError(f"invalid recovery archive: {exc}") from exc


def _archive_candidate(staging: Path, archive: Path) -> None:
    with tarfile.open(archive, "w", format=tarfile.PAX_FORMAT) as tar:
        tar.add(staging / "manifest.json", arcname="manifest.json", recursive=False)
        tar.add(staging / "payload", arcname="payload", recursive=True)
    with tempfile.TemporaryDirectory(prefix="vwrec-verify-", dir=str(archive.parent)) as directory:
        extracted = Path(directory)
        _safe_extract(archive, extracted)
        _validate_manifest(extracted)


def _verify_age_artifact(path: Path) -> None:
    _ensure_regular(path, "encrypted recovery artifact", nonempty=True)
    if path.stat().st_size < 64:
        raise RecoveryError("encrypted recovery artifact is unexpectedly small")
    try:
        with path.open("rb") as handle:
            header = handle.read(64)
    except OSError as exc:
        raise RecoveryError(f"cannot inspect encrypted recovery artifact: {exc}") from exc
    if not header.startswith(b"age-encryption.org/v1"):
        raise RecoveryError("encrypted recovery artifact does not have an Age v1 header")


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
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        os.chmod(path, 0o600)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def _load_state(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"schema_version": 1}
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {"schema_version": 1, "state_error": "unreadable recovery state"}
    return value if isinstance(value, dict) else {"schema_version": 1, "state_error": "invalid recovery state"}


def _record_local(paths: RecoveryPaths, verified: VerifiedRecovery) -> None:
    state = _load_state(paths.state_file)
    state.update(
        {
            "schema_version": 1,
            "local": {
                "artifact": str(verified.artifact),
                "created_at": verified.created_at,
                "verified_at": _utc_now(),
                "sha256": verified.sha256,
                "size": verified.size,
            },
        }
    )
    _atomic_json(paths.state_file, state)


def _record_offsite(paths: RecoveryPaths, *, remote_object: str, verified: VerifiedRecovery) -> None:
    state = _load_state(paths.state_file)
    state.update(
        {
            "schema_version": 1,
            "offsite": {
                "remote_object": remote_object,
                "verified_at": _utc_now(),
                "sha256": verified.sha256,
                "size": verified.size,
            },
        }
    )
    _atomic_json(paths.state_file, state)


def _secret_paths(encrypted: Path, age_key: Path) -> secrets.SecretPaths:
    unused = age_key.parent / ".recovery-unused-runtime-secrets"
    return secrets.SecretPaths(
        encrypted=encrypted,
        age_key=age_key,
        root=unused,
        vaultwarden=unused / "vaultwarden",
        caddy=unused / "caddy",
    )


def _validate_backup_secret_custody(
    offline_recipient: str,
    paths: RecoveryPaths,
    *,
    runner: Runner,
    uid: int,
) -> None:
    try:
        config = runtime.load_config(paths.config)
    except runtime.RuntimeConfigError as exc:
        raise RecoveryError(f"recovery config validation failed: {exc}") from exc
    if config.offline_recovery_recipient != offline_recipient:
        raise RecoveryError("backup recipient does not match config.toml offline recovery recipient")
    secret_paths = _secret_paths(paths.encrypted_secrets, paths.operational_age_key)
    try:
        secrets.validate_custody(offline_recipient, paths=secret_paths, runner=runner, uid=uid)
        secrets.decrypt(paths=secret_paths, runner=runner)
    except secrets.SecretsError as exc:
        raise RecoveryError(f"recovery secret custody is not recoverable: {exc}") from exc


def create_recovery(
    offline_recipient: str,
    *,
    paths: RecoveryPaths = RecoveryPaths(),
    runner: Runner = run_command,
    remote: str | None = None,
) -> VerifiedRecovery:
    default_paths = paths == RecoveryPaths()
    if default_paths and os.geteuid() != 0:
        raise RecoveryError("vwctl backup must run as root")
    try:
        secrets.validate_recipient(offline_recipient)
    except secrets.SecretsError as exc:
        raise RecoveryError(str(exc)) from exc
    paths.backups.mkdir(parents=True, exist_ok=True)
    os.chmod(paths.backups, 0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    name = f"recovery-{stamp}-{uuid.uuid4().hex[:8]}.vwrec"
    final = paths.backups / name
    partial = paths.backups / f".{name}.partial"
    uid = 0 if default_paths else os.geteuid()

    with mutation_lock(paths.lock):
        _validate_backup_secret_custody(offline_recipient, paths, runner=runner, uid=uid)
        with tempfile.TemporaryDirectory(prefix="vwrec-build-", dir=str(paths.backups)) as directory:
            staging = Path(directory) / "staging"
            staging.mkdir()
            paused, health_required = _pause_live_services(runner)
            try:
                manifest = _build_candidate(paths, staging)
            finally:
                _resume_paused_services(paused, runner)
            _validate_manifest(staging)
            tar_path = Path(directory) / "candidate.tar"
            _archive_candidate(staging, tar_path)
            result = runner(
                [
                    "age",
                    "--encrypt",
                    "--recipient",
                    offline_recipient,
                    "--output",
                    str(partial),
                    str(tar_path),
                ]
            )
            if not result.ok:
                partial.unlink(missing_ok=True)
                raise _safe_error("Age encryption", result)
            try:
                _verify_age_artifact(partial)
                os.replace(partial, final)
                os.chmod(final, 0o600)
            except Exception:
                partial.unlink(missing_ok=True)
                final.unlink(missing_ok=True)
                raise

        verified = VerifiedRecovery(
            artifact=final,
            sha256=_sha256(final),
            size=final.stat().st_size,
            created_at=str(manifest["created_at"]),
        )
        try:
            _wait_for_resumed_health(health_required, runner)
        except RecoveryError as exc:
            raise RecoveryError(
                f"verified recovery artifact {verified.artifact} was created, but {exc}"
            ) from exc
        _record_local(paths, verified)
        if remote:
            remote_object = publish_offsite(verified, remote, paths=paths, runner=runner)
            _record_offsite(paths, remote_object=remote_object, verified=verified)
        return verified


def _remote_parts(remote: str) -> tuple[str, str]:
    if not isinstance(remote, str) or not remote or any(c in remote for c in "\0\r\n") or ":" not in remote:
        raise RecoveryError("rclone remote must use REMOTE:path syntax")
    name, path = remote.split(":", 1)
    if not name or not name.replace("-", "").replace("_", "").isalnum():
        raise RecoveryError("rclone remote name is invalid")
    return name, path.rstrip("/")


def rclone_diagnostics(remote: str | None = None, *, runner: Runner = run_command) -> tuple[bool, str]:
    if not runner(["rclone", "version"]).ok:
        return False, "rclone is unavailable"
    if not runner(["rclone", "config", "file"]).ok:
        return False, "rclone configuration is unavailable"
    remotes = runner(["rclone", "listremotes"])
    if not remotes.ok:
        return False, "rclone remote listing failed"
    configured = {line.strip().rstrip(":") for line in remotes.stdout.splitlines() if line.strip()}
    if remote is None:
        return (
            (True, "rclone and configuration are available")
            if configured
            else (False, "rclone has no configured remotes")
        )
    name, _ = _remote_parts(remote)
    if name not in configured:
        return False, f"rclone remote {name!r} is not configured"
    if not runner(["rclone", "lsf", f"{name}:", "--max-depth", "1"]).ok:
        return False, f"rclone remote {name!r} is not reachable"
    return True, f"rclone remote {name!r} is reachable"


def _remote_object(remote: str, filename: str) -> str:
    name, path = _remote_parts(remote)
    return f"{name}:{path + '/' if path else ''}{filename}"


def publish_offsite(
    verified: VerifiedRecovery,
    remote: str,
    *,
    paths: RecoveryPaths = RecoveryPaths(),
    runner: Runner = run_command,
) -> str:
    _verify_age_artifact(verified.artifact)
    if verified.artifact.stat().st_size != verified.size or _sha256(verified.artifact) != verified.sha256:
        raise RecoveryError("local recovery artifact changed before offsite publication")
    ok, message = rclone_diagnostics(remote, runner=runner)
    if not ok:
        raise RecoveryError(message)
    destination = _remote_object(remote, verified.artifact.name)
    upload = runner(["rclone", "copyto", str(verified.artifact), destination])
    if not upload.ok:
        raise _safe_error("rclone publication", upload)
    with tempfile.TemporaryDirectory(prefix="vwrec-remote-verify-", dir=str(paths.backups)) as directory:
        downloaded = Path(directory) / verified.artifact.name
        check = runner(["rclone", "copyto", destination, str(downloaded)])
        if not check.ok:
            raise _safe_error("rclone remote verification download", check)
        _verify_age_artifact(downloaded)
        if downloaded.stat().st_size != verified.size or _sha256(downloaded) != verified.sha256:
            raise RecoveryError("rclone remote verification checksum mismatch")
    return destination


def download_remote(remote_object: str, destination: Path, *, runner: Runner = run_command) -> Path:
    _remote_parts(remote_object)
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.parent / f".{destination.name}.partial"
    partial.unlink(missing_ok=True)
    result = runner(["rclone", "copyto", remote_object, str(partial)])
    if not result.ok:
        partial.unlink(missing_ok=True)
        raise _safe_error("rclone recovery download", result)
    _verify_age_artifact(partial)
    os.replace(partial, destination)
    return destination


def _decrypt_and_validate(
    artifact: Path,
    identity: Path,
    staging: Path,
    *,
    runner: Runner,
) -> dict[str, object]:
    _ensure_regular(artifact, "encrypted recovery artifact", nonempty=True)
    _ensure_regular(identity, "offline recovery identity", nonempty=True)
    _verify_age_artifact(artifact)
    tar_path = staging.parent / "decrypted.tar"
    result = runner(
        [
            "age",
            "--decrypt",
            "--identity",
            str(identity),
            "--output",
            str(tar_path),
            str(artifact),
        ]
    )
    if not result.ok:
        tar_path.unlink(missing_ok=True)
        raise _safe_error("Age decryption", result)
    try:
        _safe_extract(tar_path, staging)
        return _validate_manifest(staging)
    finally:
        tar_path.unlink(missing_ok=True)


def _tree_size(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    return sum(child.stat().st_size for child in path.rglob("*") if child.is_file())


def _existing_ancestor(path: Path) -> Path:
    current = path
    while not current.exists():
        parent = current.parent
        if parent == current:
            raise RecoveryError(f"cannot find existing filesystem ancestor for {path}")
        current = parent
    return current


def _restore_sources(paths: RecoveryPaths, staging: Path) -> tuple[tuple[Path, Path], ...]:
    payload = staging / "payload"
    return (
        (payload / "etc/config.toml", paths.config),
        (payload / "etc/secrets.sops.yaml", paths.encrypted_secrets),
        (payload / "data", paths.data),
        (payload / "caddy/data", paths.caddy_data),
        (payload / "caddy/config", paths.caddy_config),
    )


def _preflight_targets(paths: RecoveryPaths, staging: Path) -> None:
    for path in (paths.config, paths.encrypted_secrets, paths.operational_age_key):
        if path.exists() or path.is_symlink():
            _ensure_regular(path, "restore target")
    for path in (paths.data, paths.caddy_data, paths.caddy_config):
        if path.exists() or path.is_symlink():
            _ensure_directory(path, "restore target")

    filesystems: dict[int, tuple[Path, int]] = {}
    for source, target in _restore_sources(paths, staging):
        anchor = _existing_ancestor(target.parent)
        device = anchor.stat().st_dev
        previous_anchor, current_size = filesystems.get(device, (anchor, 0))
        filesystems[device] = (previous_anchor, current_size + _tree_size(source))
    for anchor, incoming in filesystems.values():
        if shutil.disk_usage(anchor).free < incoming + _FREE_SPACE_MARGIN:
            raise RecoveryError(f"insufficient free space for staged restore on filesystem containing {anchor}")


def _copy_stage_to_target_parent(source: Path, target: Path) -> Path:
    target.parent.mkdir(parents=True, exist_ok=True)
    token = uuid.uuid4().hex[:8]
    if source.is_file() and target.suffix:
        candidate = target.parent / f".{target.stem}.restore-{token}{target.suffix}"
    else:
        candidate = target.parent / f".{target.name}.restore-{token}"
    if source.is_dir():
        shutil.copytree(source, candidate)
    else:
        shutil.copy2(source, candidate)
    return candidate


def _apply_permissions(
    path: Path,
    uid: int,
    gid: int,
    *,
    directory_mode: int = 0o700,
    file_mode: int = 0o600,
) -> None:
    targets: list[tuple[Path, int]] = []
    if path.is_dir():
        for current, directories, files in os.walk(path):
            current_path = Path(current)
            targets.append((current_path, directory_mode))
            targets.extend((current_path / name, directory_mode) for name in directories)
            targets.extend((current_path / name, file_mode) for name in files)
    else:
        targets.append((path, file_mode))
    for target, mode in targets:
        os.chown(target, uid, gid)
        os.chmod(target, mode)
        info = target.lstat()
        if stat.S_ISLNK(info.st_mode) or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (
            uid,
            gid,
            mode,
        ):
            raise RecoveryError(f"failed to establish restore ownership/mode at {target}")


def _stop_services(runner: Runner, *, cleanup_runtime_secrets: bool) -> None:
    if not runner(["docker", "version", "--format", "{{.Server.Version}}"]).ok:
        raise RecoveryError("Docker Engine unavailable; restore stop state unknown")
    existing: list[str] = []
    for container in (runtime.NAMES["caddy"], runtime.NAMES["vaultwarden"]):
        inspection = runner(["docker", "container", "inspect", container])
        if inspection.ok:
            existing.append(container)
        elif not _inspect_absent(inspection):
            raise RecoveryError("Docker container inspection failed; restore stop state unknown")
    if existing and not runner(["docker", "stop", *existing]).ok:
        raise RecoveryError("Docker stop failed during restore")
    if existing and not runner(["docker", "rm", *existing]).ok:
        raise RecoveryError("Docker container removal failed during restore")
    if cleanup_runtime_secrets:
        try:
            secrets.cleanup()
        except secrets.SecretsError as exc:
            raise RecoveryError(str(exc)) from exc


def _promote(staged: Sequence[tuple[Path, Path]]) -> None:
    rollback: list[tuple[Path, Path | None]] = []
    try:
        for candidate, target in staged:
            previous: Path | None = None
            if target.exists():
                previous = target.parent / f".{target.name}.rollback-{uuid.uuid4().hex[:8]}"
                os.replace(target, previous)
            rollback.append((target, previous))
            os.replace(candidate, target)
    except Exception as exc:
        for target, previous in reversed(rollback):
            try:
                if target.exists():
                    if target.is_dir():
                        shutil.rmtree(target)
                    else:
                        target.unlink()
                if previous is not None and previous.exists():
                    os.replace(previous, target)
            except OSError:
                pass
        raise RecoveryError(f"restore promotion failed and rollback was attempted: {exc}") from exc
    for _, previous in rollback:
        if previous is not None and previous.exists():
            if previous.is_dir():
                shutil.rmtree(previous)
            else:
                previous.unlink()


def _validate_offline_sops(
    payload: Path,
    identity: Path,
    *,
    runner: Runner,
) -> tuple[runtime.RuntimeConfig, str]:
    try:
        config = runtime.load_config(payload / "etc/config.toml")
        offline = secrets.derive_recipient(identity, runner=runner)
        if offline != config.offline_recovery_recipient:
            raise RecoveryError("supplied offline identity does not match the recovery config recipient")
        secrets.decrypt(
            paths=_secret_paths(payload / "etc/secrets.sops.yaml", identity),
            runner=runner,
        )
    except (runtime.RuntimeConfigError, secrets.SecretsError) as exc:
        raise RecoveryError(f"offline SOPS recovery preflight failed: {exc}") from exc
    return config, offline


def _existing_operational_recipient(path: Path, *, runner: Runner) -> str | None:
    if not (path.exists() or path.is_symlink()):
        return None
    _ensure_regular(path, "operational Age identity")
    if path.stat().st_size == 0:
        return None
    try:
        return secrets.derive_recipient(path, runner=runner)
    except secrets.SecretsError as exc:
        raise RecoveryError("existing operational Age identity is invalid; refusing automatic replacement") from exc


def _new_operational_identity(target: Path, uid: int, gid: int, *, runner: Runner) -> tuple[Path, str]:
    target.parent.mkdir(parents=True, exist_ok=True)
    candidate = target.parent / f".{target.name}.restore-{uuid.uuid4().hex[:8]}"
    result = runner(["age-keygen", "-o", str(candidate)])
    if not result.ok:
        candidate.unlink(missing_ok=True)
        raise _safe_error("generating replacement operational Age identity", result)
    try:
        _apply_permissions(candidate, uid, gid)
        recipient = secrets.derive_recipient(candidate, runner=runner)
    except Exception:
        candidate.unlink(missing_ok=True)
        raise
    return candidate, recipient


def _rekey_staged_sops(
    encrypted: Path,
    offline_identity: Path,
    offline_recipient: str,
    operational_recipient: str,
    *,
    runner: Runner,
) -> None:
    try:
        current = secrets.encrypted_recipients(encrypted)
    except secrets.SecretsError as exc:
        raise RecoveryError(f"cannot inspect restored SOPS recipients: {exc}") from exc
    if offline_recipient not in current:
        raise RecoveryError("restored SOPS document is not addressed to the supplied offline identity")
    desired = {offline_recipient, operational_recipient}
    add = operational_recipient not in current
    remove = sorted(current - desired)
    if add or remove:
        argv = ["sops", "rotate", "--in-place"]
        if add:
            argv.extend(["--add-age", operational_recipient])
        if remove:
            argv.extend(["--rm-age", ",".join(remove)])
        argv.append(str(encrypted))
        env = os.environ.copy()
        env["SOPS_AGE_KEY_FILE"] = str(offline_identity)
        result = runner(argv, env=env)
        if not result.ok:
            raise _safe_error("rekeying restored SOPS document", result)
    try:
        after = secrets.encrypted_recipients(encrypted)
    except secrets.SecretsError as exc:
        raise RecoveryError(f"cannot verify restored SOPS recipients: {exc}") from exc
    if after != desired:
        raise RecoveryError(
            "restored SOPS document does not have exactly offline and current operational Age recipients"
        )


def _prepare_operational_custody(
    paths: RecoveryPaths,
    staged_sops: Path,
    offline_identity: Path,
    offline_recipient: str,
    *,
    runner: Runner,
    uid: int,
    gid: int,
) -> Path | None:
    operational = _existing_operational_recipient(paths.operational_age_key, runner=runner)
    candidate: Path | None = None
    if operational is None:
        candidate, operational = _new_operational_identity(
            paths.operational_age_key,
            uid,
            gid,
            runner=runner,
        )
    if operational == offline_recipient:
        if candidate is not None:
            candidate.unlink(missing_ok=True)
        raise RecoveryError("operational and offline recovery Age identities must differ")
    try:
        _rekey_staged_sops(
            staged_sops,
            offline_identity,
            offline_recipient,
            operational,
            runner=runner,
        )
        _apply_permissions(staged_sops, uid, gid)
        validation_key = candidate if candidate is not None else paths.operational_age_key
        custody_paths = _secret_paths(staged_sops, validation_key)
        secrets.validate_custody(
            offline_recipient,
            paths=custody_paths,
            runner=runner,
            uid=uid,
        )
        secrets.decrypt(paths=custody_paths, runner=runner)
    except (RecoveryError, secrets.SecretsError, OSError) as exc:
        if candidate is not None:
            candidate.unlink(missing_ok=True)
        if isinstance(exc, RecoveryError):
            raise
        raise RecoveryError(f"replacement operational SOPS custody validation failed: {exc}") from exc
    return candidate


def restore_recovery(
    artifact: Path,
    identity: Path,
    *,
    paths: RecoveryPaths = RecoveryPaths(),
    runner: Runner = run_command,
    start: bool = False,
) -> dict[str, object]:
    default_paths = paths == RecoveryPaths()
    if default_paths and os.geteuid() != 0:
        raise RecoveryError("vwctl restore must run as root")
    paths.backups.mkdir(parents=True, exist_ok=True)
    uid, gid = (0, 0) if default_paths else (os.geteuid(), os.getegid())
    vw_uid, vw_gid = (
        (runtime.VAULTWARDEN_UID, runtime.VAULTWARDEN_GID) if default_paths else (uid, gid)
    )
    caddy_uid, caddy_gid = (
        (runtime.CADDY_UID, runtime.CADDY_GID) if default_paths else (uid, gid)
    )

    with tempfile.TemporaryDirectory(prefix="vwrec-restore-", dir=str(paths.backups)) as directory:
        root = Path(directory)
        extracted = root / "extracted"
        extracted.mkdir()
        manifest = _decrypt_and_validate(artifact, identity, extracted, runner=runner)
        payload = extracted / "payload"
        _, offline_recipient = _validate_offline_sops(payload, identity, runner=runner)
        _preflight_targets(paths, extracted)

        staged = [
            (_copy_stage_to_target_parent(source, target), target)
            for source, target in _restore_sources(paths, extracted)
        ]
        staged_by_target = {target: candidate for candidate, target in staged}
        operational_candidate: Path | None = None
        try:
            staged_sops = staged_by_target[paths.encrypted_secrets]
            _apply_permissions(staged_by_target[paths.config], uid, gid)
            _apply_permissions(staged_sops, uid, gid)
            _apply_permissions(staged_by_target[paths.data], vw_uid, vw_gid)
            _apply_permissions(staged_by_target[paths.caddy_data], caddy_uid, caddy_gid)
            _apply_permissions(staged_by_target[paths.caddy_config], caddy_uid, caddy_gid)
            _sqlite_snapshot(staged_by_target[paths.data] / _DB_NAME, root / "sqlite-proof.db")

            operational_candidate = _prepare_operational_custody(
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

            with mutation_lock(paths.lock):
                _stop_services(runner, cleanup_runtime_secrets=default_paths)
                _promote(staged)
        finally:
            for candidate, _ in staged:
                if candidate.exists():
                    if candidate.is_dir():
                        shutil.rmtree(candidate, ignore_errors=True)
                    else:
                        candidate.unlink(missing_ok=True)
            if operational_candidate is not None and operational_candidate.exists():
                operational_candidate.unlink(missing_ok=True)

    if start:
        if not default_paths:
            raise RecoveryError("custom-path restore cannot start production services")
        try:
            runtime.lifecycle("start")
        except Exception as exc:
            raise RecoveryError(
                f"restore promoted successfully but requested start failed health gate: {exc}"
            ) from exc
        overall, _ = runtime.status(runner=runner)
        if overall != "running":
            raise RecoveryError("restore promoted but requested start did not reach healthy running state")
    return manifest


def restore_from_remote(
    remote_object: str,
    identity: Path,
    *,
    paths: RecoveryPaths = RecoveryPaths(),
    runner: Runner = run_command,
    start: bool = False,
) -> dict[str, object]:
    paths.backups.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="vwrec-download-", dir=str(paths.backups)) as directory:
        local = download_remote(remote_object, Path(directory) / "remote.vwrec", runner=runner)
        return restore_recovery(local, identity, paths=paths, runner=runner, start=start)


def list_remote(remote: str, *, runner: Runner = run_command) -> list[dict[str, object]]:
    ok, message = rclone_diagnostics(remote, runner=runner)
    if not ok:
        raise RecoveryError(message)
    result = runner(["rclone", "lsjson", remote, "--files-only"])
    if not result.ok:
        raise _safe_error("rclone remote listing", result)
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RecoveryError("rclone remote listing returned invalid JSON") from exc
    if not isinstance(payload, list):
        raise RecoveryError("rclone remote listing returned invalid JSON")
    return [
        item
        for item in payload
        if isinstance(item, dict)
        and isinstance(item.get("Name"), str)
        and item["Name"].endswith(".vwrec")
    ]


def pruning_decision(entries: Iterable[Mapping[str, object]], keep_last: int) -> PruneDecision:
    if keep_last < 1:
        raise RecoveryError("keep_last must be at least 1")
    names = sorted(
        {
            str(item["Name"])
            for item in entries
            if isinstance(item.get("Name"), str) and str(item["Name"]).endswith(".vwrec")
        },
        reverse=True,
    )
    return PruneDecision(tuple(names[:keep_last]), tuple(names[keep_last:]))


def prune_remote(
    remote: str,
    keep_last: int,
    *,
    confirm: bool,
    runner: Runner = run_command,
) -> PruneDecision:
    decision = pruning_decision(list_remote(remote, runner=runner), keep_last)
    if not confirm:
        return decision
    for name in decision.delete:
        result = runner(["rclone", "deletefile", _remote_object(remote, name)])
        if not result.ok:
            raise _safe_error(f"rclone prune {name}", result)
    return decision


def status_rows(paths: RecoveryPaths = RecoveryPaths()) -> list[dict[str, str]]:
    state = _load_state(paths.state_file)
    rows: list[dict[str, str]] = []
    for key in ("local", "offsite"):
        value = state.get(key)
        if isinstance(value, dict) and isinstance(value.get("verified_at"), str):
            rows.append(
                {
                    "kind": key,
                    "state": "verified",
                    "verified_at": str(value["verified_at"]),
                    "location": str(value.get("artifact") or value.get("remote_object") or "-"),
                }
            )
        else:
            rows.append({"kind": key, "state": "none", "verified_at": "-", "location": "-"})
    return rows


def doctor_checks(
    paths: RecoveryPaths = RecoveryPaths(),
    *,
    runner: Runner = run_command,
) -> list[DoctorCheck]:
    rows = {row["kind"]: row for row in status_rows(paths)}
    local, offsite = rows["local"], rows["offsite"]
    rclone_ok, rclone_message = rclone_diagnostics(runner=runner)
    return [
        DoctorCheck(
            "recovery.local",
            "PASS" if local["state"] == "verified" else "WARN",
            f"last verified local recovery: {local['verified_at']}"
            if local["state"] == "verified"
            else "no verified local recovery recorded",
        ),
        DoctorCheck(
            "recovery.offsite",
            "PASS" if offsite["state"] == "verified" else "WARN",
            f"last verified offsite recovery: {offsite['verified_at']}"
            if offsite["state"] == "verified"
            else "no verified offsite recovery recorded",
        ),
        DoctorCheck(
            "recovery.rclone",
            "PASS" if rclone_ok else "WARN",
            rclone_message,
        ),
    ]
