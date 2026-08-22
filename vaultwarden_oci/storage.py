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
HOST_IDENTITY_FILE = Path("/etc/vaultwarden-oci/storage-identity.json")
VOLUME_MARKER = STATE_ROOT / ".vaultwarden-oci-volume.json"
# Backward-compatible name for callers/tests that display the expected identity path.
IDENTITY_FILE = HOST_IDENTITY_FILE
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
    source = _required(
        runner(["findmnt", "-n", "-o", "SOURCE", "--target", "/"]),
        "root filesystem discovery",
    )
    if not source.startswith("/dev/"):
        raise StorageError(f"root filesystem source is not a supported block device: {source}")
    return _real_device(source)


def _lsblk_paths(device: str, flag: str, *, runner: Runner) -> set[str]:
    output = _required(
        runner(["lsblk", flag, "-n", "-o", "PATH", device]),
        f"block lineage discovery for {device}",
    )
    return {
        _real_device(line.strip())
        for line in output.splitlines()
        if line.strip().startswith("/dev/")
    }


def device_family(device: str, *, runner: Runner = run) -> set[str]:
    resolved = _real_device(device)
    return (
        {resolved}
        | _lsblk_paths(resolved, "-s", runner=runner)
        | _lsblk_paths(resolved, "-r", runner=runner)
    )


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
                        "mountpoints": tuple(
                            m
                            for m in (node.get("mountpoints") or [])
                            if isinstance(m, str) and m
                        ),
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
    return _required(
        runner(["findmnt", "-n", "-o", "SOURCE", "--target", str(target)]),
        f"mount discovery for {target}",
    )


def _atomic_write(path: Path, text: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    fd = os.open(
        tmp,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        mode,
    )
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


def _load_identity(path: Path, label: str) -> StorageIdentity:
    try:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise StorageError(f"{label} is not a regular file: {path}")
        payload = json.loads(path.read_text(encoding="utf-8"))
    except StorageError:
        raise
    except (OSError, json.JSONDecodeError) as exc:
        raise StorageError(f"cannot read {label} {path}: {exc}") from exc
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise StorageError(f"{label} has an unsupported schema")
    try:
        identity = StorageIdentity(
            uuid=str(payload["uuid"]),
            fs_type=str(payload["fs_type"]),
            source=str(payload["source"]),
            mount=str(payload["mount"]),
        )
    except KeyError as exc:
        raise StorageError(f"{label} is incomplete") from exc
    if (
        identity.mount != str(STATE_ROOT)
        or identity.fs_type not in _ALLOWED_FS
        or not _UUID.fullmatch(identity.uuid)
    ):
        raise StorageError(f"{label} is invalid")
    return identity


def load_identity(path: Path = HOST_IDENTITY_FILE) -> StorageIdentity:
    """Load the host-side expected identity, independent of the mounted volume."""
    return _load_identity(path, "host storage identity")


def load_volume_marker(path: Path = VOLUME_MARKER) -> StorageIdentity:
    return _load_identity(path, "volume ownership marker")


def _same_identity(left: StorageIdentity, right: StorageIdentity) -> bool:
    return (left.uuid, left.fs_type, left.mount) == (right.uuid, right.fs_type, right.mount)


def verify(*, runner: Runner = run, require_marker: bool = True) -> StorageIdentity:
    actual = _identity_from_mount(runner=runner)
    expected = load_identity()
    if not _same_identity(actual, expected):
        raise StorageError(
            f"wrong filesystem mounted at {STATE_ROOT}: expected UUID={expected.uuid} {expected.fs_type}, "
            f"got UUID={actual.uuid} {actual.fs_type}"
        )
    if require_marker:
        marker = load_volume_marker()
        if not _same_identity(marker, expected):
            raise StorageError(
                "mounted filesystem ownership marker does not match the host-side expected identity"
            )
    return actual


def _write_identity(path: Path, identity: StorageIdentity, label: str) -> None:
    if path.exists() or path.is_symlink():
        existing = _load_identity(path, label)
        if not _same_identity(existing, identity):
            raise StorageError(f"existing {label} belongs to a different filesystem; refusing silent replacement")
        return
    _atomic_write(path, json.dumps(identity.as_dict(), indent=2, sort_keys=True) + "\n", 0o600)


def write_identity(identity: StorageIdentity, path: Path = HOST_IDENTITY_FILE) -> None:
    _write_identity(path, identity, "host storage identity")


def write_volume_marker(identity: StorageIdentity, path: Path = VOLUME_MARKER) -> None:
    _write_identity(path, identity, "volume ownership marker")


def _fstab_line(identity: StorageIdentity) -> str:
    return (
        f"UUID={identity.uuid}\t{STATE_ROOT}\t{identity.fs_type}\t"
        "noatime,nofail,x-systemd.device-timeout=30s\t0\t2"
    )


def ensure_fstab(identity: StorageIdentity, *, path: Path = FSTAB) -> None:
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    lines = text.splitlines()
    desired = _fstab_line(identity)
    kept = [
        line
        for line in lines
        if not (
            line.strip()
            and not line.lstrip().startswith("#")
            and (
                f"UUID={identity.uuid}" in line
                or str(STATE_ROOT) in line.split()
            )
        )
    ]
    kept.append(desired)
    _atomic_write(path, "\n".join(kept) + "\n", 0o644)


def ensure_docker_guard(identity: StorageIdentity, *, path: Path = DOCKER_DROPIN) -> None:
    del identity  # guard is path-based; runtime identity is separately host-authoritative.
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


def _signature_types(device: str, *, runner: Runner) -> set[str]:
    result = runner(["wipefs", "--no-act", "--all", "--output", "TYPE", "--noheadings", device])
    if not result.ok:
        raise StorageError("cannot prove selected-device signatures because wipefs failed")
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def _selected_identity(resolved: str, fs_type: str, *, runner: Runner) -> StorageIdentity:
    uuid = _blkid(resolved, "UUID", runner=runner)
    if not _UUID.fullmatch(uuid):
        raise StorageError("selected filesystem has no stable UUID")
    return StorageIdentity(uuid=uuid, fs_type=fs_type, source=resolved)


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
            raise StorageError(
                f"unknown/unsupported filesystem {fs_type!r}; only ext4/xfs may be adopted"
            )
        signatures = _signature_types(resolved, runner=runner)
        if signatures - {fs_type}:
            raise StorageError(
                "selected existing filesystem has mixed/unknown signatures: "
                + ", ".join(sorted(signatures - {fs_type}))
            )
        _confirm(
            f"Existing {fs_type} filesystem detected on {device}; adoption requires explicit acknowledgement.",
            acknowledgement=acknowledge_existing,
            interactive=interactive,
        )
    else:
        signatures = _signature_types(resolved, runner=runner)
        if signatures:
            raise StorageError(
                "selected device has unknown data signatures; refusing automatic formatting"
            )
        _confirm(
            f"Blank device {device} will be formatted as ext4; destructive acknowledgement is required.",
            acknowledgement=acknowledge_format,
            interactive=interactive,
        )
        result = runner(["mkfs.ext4", "-L", "vwoci-data", resolved])
        if not result.ok:
            raise StorageError("mkfs.ext4 failed")
        fs_type = "ext4"

    selected = _selected_identity(resolved, fs_type, runner=runner)
    STATE_ROOT.mkdir(parents=True, exist_ok=True)

    # Re-runs must reconcile the live mount before changing fstab or host identity.
    if STATE_ROOT.is_mount():
        actual = _identity_from_mount(runner=runner)
        if not _same_identity(actual, selected):
            raise StorageError(
                f"{STATE_ROOT} is already mounted from UUID={actual.uuid}; refusing to rewrite persistent mount state for selected UUID={selected.uuid}"
            )
    else:
        mounted = runner(["mount", resolved, str(STATE_ROOT)])
        if not mounted.ok:
            raise StorageError(f"failed to mount selected filesystem at {STATE_ROOT}")
        actual = _identity_from_mount(runner=runner)
        if not _same_identity(actual, selected):
            raise StorageError("mounted filesystem does not match the selected device")

    # The host-side expected identity is independent of data-volume contents.
    write_identity(actual)
    write_volume_marker(actual)
    ensure_fstab(actual)
    ensure_docker_guard(actual)
    reload_result = runner(["systemctl", "daemon-reload"])
    if not reload_result.ok:
        raise StorageError("systemctl daemon-reload failed after installing the Docker mount guard")
    return verify(runner=runner)
