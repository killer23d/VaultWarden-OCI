#!/usr/bin/env python3
"""Bounded native installed-console smoke; no operation is approved or applied.

Run only on an explicitly approved disposable Ubuntu ARM64 host, with the exact
candidate already installed. Invoke with sudo -n /usr/bin/python3 -B -I. This
instrument never installs a candidate, changes services, invokes a workflow,
contacts a provider directly, or records terminal output/secret values. Its only
writes are a private temporary comparison tree under /run, removed on exit.
The JSON receipt describes console behavior and immutable integrity, not health
or production deployment acceptance.
"""
from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import platform
import pty
import pwd
import re
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Sequence

sys.dont_write_bytecode = True

SHA = re.compile(r"[0-9a-f]{40}\Z")
HOST = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,62}\Z")
RELEASE_PATHS = ("vwctl", "versions.toml", "email-providers.toml", "vaultwarden_oci", "systemd")
OUTPUT_LIMIT = 128 * 1024


class Hold(RuntimeError):
    """A fixed, safe explanation of missing evidence."""


def environment() -> dict[str, str]:
    return {
        "PATH": "/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin",
        "HOME": pwd.getpwuid(os.geteuid()).pw_dir,
        "LANG": "C.UTF-8", "TERM": "dumb", "NO_COLOR": "1",
        "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1",
    }


def read_command(argv: Sequence[str], *, timeout: float = 20) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            list(argv), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, check=False, timeout=timeout,
            cwd="/", env=environment(),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Hold("a required read-only command was unavailable or timed out") from exc


def native_host(expected: str) -> pwd.struct_passwd:
    if os.geteuid() != 0:
        raise Hold("run with sudo -n /usr/bin/python3 -B -I; interactive sudo is not supported")
    if not sys.flags.isolated:
        raise Hold("isolated Python is required: use /usr/bin/python3 -B -I")
    operator = os.environ.get("SUDO_USER", "")
    if not operator or operator == "root":
        raise Hold("invoke through sudo -n from the approved non-root operator account")
    try:
        account = pwd.getpwnam(operator)
        valid_uid = str(account.pw_uid) == os.environ.get("SUDO_UID") and account.pw_uid != 0
    except KeyError:
        valid_uid = False
    if not valid_uid:
        raise Hold("the sudo invoking operator identity is not established")
    if platform.node().split(".", 1)[0] != expected:
        raise Hold("host does not match --expected-host")
    values = {}
    for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            values[key] = value.strip('"')
    codename = {"24.04": "noble", "26.04": "resolute"}.get(values.get("VERSION_ID"))
    if (values.get("ID") != "ubuntu" or codename is None
            or codename != values.get("VERSION_CODENAME")
            or platform.machine() not in {"aarch64", "arm64"}):
        raise Hold("native supported Ubuntu ARM64 is required")
    return account


def verified_source(source: Path, expected_sha: str, account: pwd.struct_passwd) -> None:
    if not source.is_absolute() or source.is_symlink() or source.resolve(strict=True) != source:
        raise Hold("--source must be the absolute real checkout path")
    if source.stat().st_uid != account.pw_uid:
        raise Hold("source checkout must belong to the invoking operator")
    for path in (source / ".git", source / ".git/index"):
        info = path.lstat()
        if path.is_symlink() or info.st_uid != account.pw_uid:
            raise Hold("source Git directory/index ownership or type is unsafe")
    prefix = [
        "/usr/sbin/runuser", "-u", account.pw_name, "--", "/usr/bin/git",
        "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
        "-C", str(source),
    ]
    head = read_command([*prefix, "rev-parse", "HEAD"])
    clean = read_command([*prefix, "status", "--porcelain", "--untracked-files=all"])
    if head.returncode != 0 or head.stdout.strip() != expected_sha or clean.returncode != 0 or clean.stdout:
        raise Hold("source SHA/clean-checkout verification failed")
    tree = read_command([*prefix, "ls-tree", "-r", "-z", expected_sha])
    if tree.returncode != 0:
        raise Hold("exact source tree could not be read")
    tracked = set()
    for item in tree.stdout.split("\0"):
        if not item:
            continue
        metadata, relative = item.split("\t", 1)
        mode, kind, digest = metadata.split()
        path = source / relative
        if mode not in {"100644", "100755"} or kind != "blob" or path.is_symlink() or not path.is_file():
            raise Hold("source contains an unsupported or missing tracked entry")
        content = path.read_bytes()
        actual = hashlib.sha1(b"blob " + str(len(content)).encode("ascii") + b"\0" + content).hexdigest()
        if actual != digest or bool(path.stat().st_mode & stat.S_IXUSR) != (mode == "100755"):
            raise Hold("tracked source bytes or executable mode differ from the reviewed commit")
        tracked.add(relative)
    # -B prevents writes but still permits reading bytecode. Refuse caches and
    # every untracked entry before root imports any reviewed project module.
    tracked_directories = {str(parent) for name in tracked for parent in Path(name).parents}
    for root in RELEASE_PATHS:
        path = source / root
        for entry in ([path] if path.is_file() else path.rglob("*")):
            if "__pycache__" in entry.parts or entry.suffix == ".pyc":
                raise Hold("bytecode or cache content exists in a release-owned source path")
            relative = str(entry.relative_to(source))
            if (entry.is_symlink() or (entry.is_file() and relative not in tracked)
                    or (entry.is_dir() and relative not in tracked_directories)):
                raise Hold("untracked or linked content exists in a release-owned source path")


def snapshot(paths: Sequence[Path]) -> dict[str, tuple[Any, ...]]:
    result: dict[str, tuple[Any, ...]] = {}
    for root in paths:
        entries = [root]
        if root.is_dir() and not root.is_symlink():
            entries.extend(root.rglob("*"))
        if len(entries) > 2000:
            raise Hold("unexpectedly large immutable tree")
        for path in entries:
            info = path.lstat()
            if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)):
                raise Hold("unexpected file type in installed evidence")
            value = os.readlink(path) if path.is_symlink() else hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "directory"
            result[str(path)] = (info.st_mode, info.st_uid, info.st_gid, info.st_ino, info.st_mtime_ns, info.st_ctime_ns, value)
    return result


def require_root_ownership(paths: Sequence[Path]) -> None:
    for path in paths:
        info = path.lstat()
        if info.st_uid != 0 or info.st_gid != 0:
            raise Hold("installed evidence is not root:root owned")


def verify_installation(source: Path, install: Any, versions: Any, *, temporary_base: Path = Path("/run")) -> tuple[Path, str, list[Path]]:
    release = install.load_versions(source / "versions.toml").version
    selected = install.RELEASES_DIR / install.validate_release_name(release)
    for link, target in ((install.CURRENT_LINK, selected), (install.VWCTL_LINK, install.CURRENT_LINK / "vwctl")):
        if not install._check_symlink_compatible(link, target):
            raise Hold("canonical current/launcher symlink is absent")
    if selected.is_symlink() or selected.resolve(strict=True) != selected:
        raise Hold("selected immutable release is not a real canonical directory")
    if temporary_base.is_symlink() or not temporary_base.is_dir():
        raise Hold("private temporary comparison location is unavailable")
    kind = "exact_source_manifest"
    with tempfile.TemporaryDirectory(prefix="vwoci-console-", dir=temporary_base) as directory:
        comparison = Path(directory) / "expected"
        comparison.mkdir(mode=0o700)
        try:
            install._copy_release_tree(source, comparison)
            installed_manifest = (selected / "versions.toml").read_bytes()
            if installed_manifest != (source / "versions.toml").read_bytes():
                frozen = versions.frozen_versions_toml(versions.resolve_pinned(source, machine="aarch64")).encode("utf-8")
                if installed_manifest != frozen:
                    raise Hold("installed versions manifest is neither exact source nor canonical ARM64 frozen content")
                (comparison / "versions.toml").write_bytes(frozen)
                kind = "canonical_arm64_frozen_manifest"
            install._make_release_immutable(comparison)
            if not install._same_tree(comparison, selected):
                raise Hold("installed immutable content differs from the reviewed source")
        finally:
            install._remove_release_staging(comparison)
    units = [install.SYSTEMD_DIR / unit for unit in install.SYSTEMD_UNITS]
    require_root_ownership([selected, *selected.rglob("*"), *units, install.CURRENT_LINK, install.VWCTL_LINK])
    for unit in units:
        info = unit.lstat()
        if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o644
                or unit.read_bytes() != (selected / "systemd" / unit.name).read_bytes()):
            raise Hold("installed systemd fragment differs from the exact release")
    return selected, kind, [selected, install.CURRENT_LINK, install.VWCTL_LINK, *units]


def terminal(argv: Sequence[str], response: bytes, *, timeout: float = 75) -> tuple[int, str]:
    """A separate PTY process group receives only fixed exit/default-No input."""
    master, slave = pty.openpty()
    process = None
    complete = False
    output = bytearray()
    try:
        process = subprocess.Popen(
            list(argv), stdin=slave, stdout=slave, stderr=slave, cwd="/",
            env=environment(), start_new_session=True,
        )
        os.close(slave)
        slave = -1
        os.write(master, response)
        deadline = time.monotonic() + timeout
        while True:
            if time.monotonic() >= deadline:
                raise Hold("console PTY smoke timed out; its own process group was stopped")
            ready, _, _ = select.select([master], [], [], min(0.2, max(0, deadline - time.monotonic())))
            if ready:
                try:
                    chunk = os.read(master, 8192)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
                    chunk = b""
                if chunk:
                    output.extend(chunk)
                    if len(output) > OUTPUT_LIMIT:
                        raise Hold("console PTY output exceeded its fixed bound")
                    continue
            if process.poll() is not None:
                complete = True
                return process.returncode, output.decode("utf-8", errors="replace")
    finally:
        if process is not None and not complete:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=2)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
        os.close(master)
        if slave >= 0:
            os.close(slave)


def smoke_cases(launcher: Path, selected: Path) -> tuple[tuple[str, list[str], bytes, tuple[str, ...]], ...]:
    return (
        ("canonical_menu_exit", [str(launcher), "menu"], b"q\n", ("Administrator objectives", "INFO: console closed.")),
        ("legacy_menu_exit", ["/bin/bash", str(selected / "vaultwarden_oci/dashboard.sh")], b"q\n", ("Administrator objectives", "INFO: console closed.")),
        ("guide_selector_back", [str(launcher), "guide"], b"b\n", ("Available guided operations",)),
        *((f"guide_{workflow}_default_no", [str(launcher), "guide", workflow], b"\n",
           ("Purpose:", "Prerequisites:", "Impact and consent:", "CANCELLED: no command was started."))
          for workflow in ("restore", "offsite", "recovery-kit")),
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-host", required=True, help="approved disposable host's exact short hostname")
    parser.add_argument("--expected-sha", required=True, help="exact reviewed 40-character source commit")
    parser.add_argument("--source", required=True, type=Path, help="absolute clean operator-owned checkout")
    args = parser.parse_args(argv)
    receipt: dict[str, Any] = {"schema_version": 1, "scope": "installed console exit and default-No smoke", "verdict": "HOLD", "checks": []}
    try:
        if not HOST.fullmatch(args.expected_host) or not SHA.fullmatch(args.expected_sha):
            raise Hold("explicit expected host and exact source SHA are required")
        account = native_host(args.expected_host)
        verified_source(args.source, args.expected_sha, account)
        if Path(__file__).resolve() != args.source / "tests/host-acceptance/dashboard-console.py":
            raise Hold("run the instrument from the exact verified source checkout")
        # No project module is imported until the complete tracked source has
        # been independently checked against the operator's exact Git pin.
        sys.path.insert(0, str(args.source))
        from vaultwarden_oci import install, storage, update_versions
        if Path(install.__file__).resolve().parents[1] != args.source:
            raise Hold("product verifier import did not come from the reviewed checkout")
        selected, manifest, paths = verify_installation(args.source, install, update_versions)
        def storage_read(argv: Sequence[str]) -> Any:
            result = read_command(argv)
            return storage.CommandResult(tuple(argv), result.returncode, result.stdout, "")
        storage.verify(runner=storage_read)
        before = snapshot(paths)
        receipt.update(source_sha=args.expected_sha, host=args.expected_host, source=str(args.source), selected_release=str(selected), manifest=manifest)
        try:
            for name, command, response, markers in smoke_cases(install.VWCTL_LINK, selected):
                code, output = terminal(command, response)
                if code != 0 or any(marker not in output for marker in markers):
                    raise Hold("a console exit/default-No check did not produce its expected result")
                receipt["checks"].append({"name": name, "result": "PASS", "exit_code": code})
        finally:
            unchanged = snapshot(paths) == before
            receipt["immutable_tree_unchanged"] = unchanged
            if not unchanged:
                raise Hold("immutable contents, metadata, installed units, or selected symlinks changed")
        verified_source(args.source, args.expected_sha, account)
        receipt.update(verdict="PASS", immutable_files=sum(1 for path in selected.rglob("*") if path.is_file()), installed_units=len(install.SYSTEMD_UNITS))
        receipt["limits"] = "No workflow execution, mutation, provider/custody proof, release approval, or production deployment acceptance."
    except Hold as exc:
        receipt["reason"] = str(exc)
    except (OSError, ValueError, RuntimeError, ImportError) as exc:
        receipt["reason"] = f"required verification failed ({type(exc).__name__}); details withheld"
    except KeyboardInterrupt:
        receipt["reason"] = "acceptance interrupted; no PASS receipt issued"
    print(json.dumps(receipt, indent=2, sort_keys=True))
    return 0 if receipt["verdict"] == "PASS" else 2


if __name__ == "__main__":
    os.umask(0o077)
    raise SystemExit(main())
