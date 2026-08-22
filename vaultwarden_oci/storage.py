"""Dedicated production-storage ownership for first-run setup and runtime gates."""
from __future__ import annotations

import json
import os
import re
import stat
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping, Sequence

STATE_ROOT = Path("/var/lib/vaultwarden-oci")
IDENTITY_FILE = STATE_ROOT / ".vaultwarden-oci-volume.json"
DOCKER_DROPIN = Path("/etc/systemd/system/docker.service.d/10-vaultwarden-oci-storage.conf")
FSTAB = Path("/etc/fstab")
_ALLOWED_FS = {"ext4", "xfs"}
_UUID = re.compile(r"^[A-Fa-f0-9-]{4,128}$")


class StorageError(RuntimeError):
    pass


@dataclass(frozen=True)
class CommandResult:
    argv: tuple[str, ...]
    returncode: int | None
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.returncode == 0


@dataclass(frozen=True)
class StorageIdentity:
    uuid: str
    fs_type: str
    source: str
    mount: str = str(STATE_ROOT)

    def as_dict(self) -> dict[str, object]:
        return {
            "schema_version": 1,
            "uuid": self.uuid,
            "fs_type": self.fs_type,
            "source": self.source,
            "mount": self.mount,
        }


Runner = Callable[[Sequence[str]], CommandResult]


def run(argv: Sequence[str]) -> CommandResult:
    args = tuple(str(item) for item in argv)
    try:
        completed = subprocess.run(args, check=False, capture_output=True, text=True)
    except FileNotFoundError as exc:
        return CommandResult(args, None, "", str(exc))
    return CommandResult(args, completed.returncode, completed.stdout, completed.stderr)


def _required(result: CommandResult, label: str) -> str:
    if not result.ok:
        detail = result.stderr.strip() or result.stdout.strip() or "command unavailable"
        raise StorageError(f"{label} failed: {detail}")
    return result.stdout.strip()


def _real_device(value: str) -> str:
    try:
        return str(Path(value).resolve(strict=True))
    except OSError as exc:
        raise StorageError(f"cannot resolve block device {value}: {exc}") from exc


def root_source(*, runner: Runner = run) -> str:
    source = _required(runner(["findmnt", "-n", "-o", "SOURCE", "--target", "/"]), "root filesystem discovery")
    if not source.startswith("/dev/"):
        raise StorageError(f"root filesystem source is not a supported block device: {source}")
    return _real_device(source)


def _lsblk_paths(device: str, flag: str, *, runner: Runner) -> set[str]:
    output = _required(runner(["lsblk", flag, "-n", "-o", "PATH", device]), f"block lineage discovery for {device}")
    return {_real_device(line.strip()) for line in output.splitlines() if line.strip().startswith("/dev/")}


def device_family(device: str, *, runner: Runner = run) -> set[str]:
    resolved = _real_device(device)
    return {resolved} | _lsblk_paths(resolved, "-s", runner=runner) | _lsblk_paths(resolved, "-r", runner=runner)


def reject_boot_related(device: str, *, runner: Runner = run) -> None:
    root = root_source(runner=runner)
    if device_family(device, runner=runner) & device_family(root, runner=runner):
        raise StorageError(
            f"refusing {device}: it is the boot/root device or a parent/child of the filesystem mounted at /"
        )


def inventory(*, runner: Runner = run) -> list[dict[str, object]]:
    raw = _required(
        runner(["lsblk", "-J", "-b", "-p", "-o", "PATH,TYPE,SIZE,FSTYPE,MOUNTPOINTS,UUID,MODEL"]),
        "block-device inventory",
    )
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise StorageError("lsblk returned invalid JSON") from exc
    rows: list[dict[str, object]] = []

    def visit(node: Mapping[str, object]) -> None:
        path = node.get("path")
        kind = node.get("type")
        if isinstance(path, str) and kind in {"disk", "part", "lvm", "crypt"}:
            try:
                reject_boot_related(path, runner=runner)
            except StorageError:
                pass
            else:
                rows.append(
                    {
                        "path": path,
                        "type": kind,
                        "size": int(node.get("size") or 0),
                        "fstype": str(node.get("fstype") or ""),
                        "mountpoints": tuple(m for m in (node.get("mountpoints") or []) if isinstance(m, str) and m),
                        "uuid": str(node.get("uuid") or ""),
                        "model": str(node.get("model") or "").strip(),
                    }
                )
        for child in node.get("children") or []:
            if isinstance(child, dict):
                visit(child)

    for item in payload.get("blockdevices") or []:
        if isinstance(item, dict):
            visit(item)
    return rows


def _blkid(device: str, field: str, *, runner: Runner) -> str:
    result = runner(["blkid", "-o", "value", "-s", field, device])
    return result.stdout.strip() if result.ok else ""


def _mounted_source(target: Path, *, runner: Runner) -> str:
    return _required(runner(["findmnt", "-n", "-o", "SOURCE", "--target", str(target)]), f"mount discovery for {target}")


def _atomic_write(path: Path, text: str, mode: int) -> None:
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


def _identity_from_mount(*, runner: Runner) -> StorageIdentity:
    if not STATE_ROOT.is_mount():
        raise StorageError(f"required dedicated state mount is absent: {STATE_ROOT}")
    source = _mounted_source(STATE_ROOT, runner=runner)
    if not source.startswith("/dev/"):
        raise StorageError(f"state mount source is not a supported block device: {source}")
    resolved = _real_device(source)
    reject_boot_related(resolved, runner=runner)
    fs_type = _blkid(resolved, "TYPE", runner=runner)
    uuid = _blkid(resolved, "UUID", runner=runner)
    if fs_type not in _ALLOWED_FS:
        raise StorageError(f"state filesystem must be ext4 or xfs, got {fs_type or 'unknown'}")
    if not _UUID.fullmatch(uuid):
        raise StorageError("state filesystem has no stable UUID")
    if os.stat(STATE_ROOT).st_dev == os.stat("/").st_dev:
        raise StorageError("production state resolves to the boot/root filesystem")
    return StorageIdentity(uuid=uuid, fs_type=fs_type, source=resolved)


def load_identity(path: Path = IDENTITY_FILE) -> StorageIdentity:
    try:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise StorageError(f"storage identity marker is not a regular file: {path}")
        payload = json.loads(path.read_text(encoding="utf-8"))
    except StorageError:
        raise
    except (OSError, json.JSONDecodeError) as exc:
        raise StorageError(f"cannot read storage identity marker {path}: {exc}") from exc
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise StorageError("storage identity marker has an unsupported schema")
    try:
        identity = StorageIdentity(
            uuid=str(payload["uuid"]),
            fs_type=str(payload["fs_type"]),
            source=str(payload["source"]),
            mount=str(payload["mount"]),
        )
    except KeyError as exc:
        raise StorageError("storage identity marker is incomplete") from exc
    if identity.mount != str(STATE_ROOT) or identity.fs_type not in _ALLOWED_FS or not _UUID.fullmatch(identity.uuid):
        raise StorageError("storage identity marker is invalid")
    return identity


def verify(*, runner: Runner = run, require_marker: bool = True) -> StorageIdentity:
    actual = _identity_from_mount(runner=runner)
    if not require_marker:
        return actual
    expected = load_identity()
    if actual.uuid != expected.uuid or actual.fs_type != expected.fs_type:
        raise StorageError(
            f"wrong filesystem mounted at {STATE_ROOT}: expected UUID={expected.uuid} {expected.fs_type}, "
            f"got UUID={actual.uuid} {actual.fs_type}"
        )
    return actual


def write_identity(identity: StorageIdentity, path: Path = IDENTITY_FILE) -> None:
    existing = None
    if path.exists() or path.is_symlink():
        existing = load_identity(path)
    if existing is not None and (existing.uuid, existing.fs_type) != (identity.uuid, identity.fs_type):
        raise StorageError("existing storage identity belongs to a different filesystem; refusing silent replacement")
    _atomic_write(path, json.dumps(identity.as_dict(), indent=2, sort_keys=True) + "\n", 0o600)


def _fstab_line(identity: StorageIdentity) -> str:
    return f"UUID={identity.uuid}\t{STATE_ROOT}\t{identity.fs_type}\tnoatime,nofail,x-systemd.device-timeout=30s\t0\t2"


def ensure_fstab(identity: StorageIdentity, *, path: Path = FSTAB) -> None:
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    lines = text.splitlines()
    desired = _fstab_line(identity)
    kept = [line for line in lines if not (line.strip() and not line.lstrip().startswith("#") and (f"UUID={identity.uuid}" in line or str(STATE_ROOT) in line.split()))]
    kept.append(desired)
    _atomic_write(path, "\n".join(kept) + "\n", 0o644)


def ensure_docker_guard(identity: StorageIdentity, *, path: Path = DOCKER_DROPIN) -> None:
    content = (
        "[Unit]\n"
        f"RequiresMountsFor={STATE_ROOT}\n"
        f"ConditionPathIsMountPoint={STATE_ROOT}\n"
        "After=var-lib-vaultwarden\\x2doci.mount\n"
    )
    _atomic_write(path, content, 0o644)


def _confirm(prompt: str, *, acknowledgement: bool, interactive: bool) -> None:
    if acknowledgement:
        return
    if not interactive:
        raise StorageError(prompt)
    answer = input(prompt + " Type YES to continue: ")
    if answer != "YES":
        raise StorageError("storage confirmation was not received")


def provision(
    device: str,
    *,
    acknowledge_existing: bool = False,
    acknowledge_format: bool = False,
    interactive: bool = False,
    runner: Runner = run,
) -> StorageIdentity:
    resolved = _real_device(device)
    reject_boot_related(resolved, runner=runner)
    probe = runner(["lsblk", "-n", "-o", "TYPE", resolved])
    if not probe.ok or not probe.stdout.strip():
        raise StorageError(f"not a usable block device: {device}")
    fs_type = _blkid(resolved, "TYPE", runner=runner)
    if fs_type:
        if fs_type not in _ALLOWED_FS:
            raise StorageError(f"unknown/unsupported filesystem {fs_type!r}; only ext4/xfs may be adopted")
        _confirm(
            f"Existing {fs_type} filesystem detected on {device}; adoption requires explicit acknowledgement.",
            acknowledgement=acknowledge_existing,
            interactive=interactive,
        )
    else:
        signatures = runner(["wipefs", "--no-act", "--all", "--parsable", resolved])
        if not signatures.ok:
            raise StorageError("cannot prove the selected device is blank because wipefs failed")
        if signatures.stdout.strip():
            raise StorageError("selected device has unknown data signatures; refusing automatic formatting")
        _confirm(
            f"Blank device {device} will be formatted as ext4; destructive acknowledgement is required.",
            acknowledgement=acknowledge_format,
            interactive=interactive,
        )
        result = runner(["mkfs.ext4", "-L", "vwoci-data", resolved])
        if not result.ok:
            raise StorageError("mkfs.ext4 failed")
        fs_type = "ext4"
    uuid = _blkid(resolved, "UUID", runner=runner)
    if not _UUID.fullmatch(uuid):
        raise StorageError("selected filesystem has no stable UUID")
    identity = StorageIdentity(uuid=uuid, fs_type=fs_type, source=resolved)
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    ensure_fstab(identity)
    if not STATE_ROOT.is_mount():
        mounted = runner(["mount", str(STATE_ROOT)])
        if not mounted.ok:
            raise StorageError(f"failed to mount selected filesystem at {STATE_ROOT}")
    actual = verify(runner=runner, require_marker=False)
    if (actual.uuid, actual.fs_type) != (identity.uuid, identity.fs_type):
        raise StorageError("mounted filesystem does not match the selected device")
    write_identity(actual)
    ensure_docker_guard(actual)
    reload_result = runner(["systemctl", "daemon-reload"])
    if not reload_result.ok:
        raise StorageError("systemctl daemon-reload failed after installing the Docker mount guard")
    return verify(runner=runner)
