#!/usr/bin/env python3
"""Temporary rc.13 VM8 actual-reboot witness; no service/VM mutation here.

Phase preboot: verify P4-E1 checkpoint, immutable source and disk, prior
Worker invocation, and disabled app target/timers, then write a private
preboot-armed record. Caller alone separately executes systemctl reboot.

Phase postboot: verify the boot ID changed, preserved database/disk/source,
Worker boot-disabled/inactive and Caddy deliberately not auto-published.
This is FAIL-CLOSED BOOT evidence, NOT active target/timer persistence.
Never enable automation or perform Cloudflare DNS writes on test VM8.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
import pathlib
import platform
import pwd
import re
import runpy
import sqlite3
import stat
import subprocess
import sys

sys.dont_write_bytecode = True
os.umask(0o077)

SOURCE = "fd56313255c97992dc55c1475d94477597b88602"
HOST = "vaultwarden-oci-8"
UUID = "f4e0bd62-48e7-4745-8987-44b14013216d"
CIPHER_SHA = "10b53feb60db4f7d94f280b6601e6fdfd35d6137d13eb351b94f99234c4149fa"
WORKER_INV = "a80be9e43af84a24b505b9e4b127abeb"
ROOT = pathlib.Path("/home/ubuntu/vwoci-acceptance")
TIMERS = (
    "vaultwarden-oci-health.timer",
    "vaultwarden-oci-backup.timer",
    "vaultwarden-oci-maintenance.timer",
    "vaultwarden-oci-update-check.timer",
)


def hold(message: str) -> None:
    print("P4_E2_EXIT=2 HOLD: " + message, flush=True)
    raise SystemExit(2)


def passed(message: str) -> None:
    print("PASS: " + message, flush=True)


def run(args: list[str], *, allowed: tuple[int, ...] = (0,), timeout: int = 50) -> str:
    try:
        p = subprocess.run(
            args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, check=False, timeout=timeout, cwd="/",
        )
    except (OSError, subprocess.TimeoutExpired):
        hold("read-only command unavailable: " + args[0])
    if p.returncode not in allowed:
        hold("unexpected command status: " + args[0])
    return p.stdout


def systemd(name: str) -> dict[str, str]:
    props = "LoadState,ActiveState,UnitFileState,InvocationID,ExecMainStartTimestampMonotonic"
    output = run(["systemctl", "show", name, "--no-pager", "--property=" + props])
    return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)


def boot_id() -> str:
    try:
        value = pathlib.Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
    except OSError:
        hold("cannot read kernel boot ID")
    if re.fullmatch(r"[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}", value) is None:
        hold("invalid kernel boot ID")
    return value


def private_file(path: pathlib.Path) -> dict:
    try:
        s = path.lstat()
        if (not stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode)
                or s.st_uid != 0 or stat.S_IMODE(s.st_mode) != 0o600):
            hold("checkpoint file custody unsafe")
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            hold("checkpoint format invalid")
    except (OSError, ValueError, TypeError):
        hold("checkpoint missing or invalid")
    return data


def write_private(path: pathlib.Path, obj: dict) -> None:
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(obj, stream, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
    except OSError:
        hold("protected checkpoint write failed; do not reboot")


def safe_identity(source: pathlib.Path, folder: pathlib.Path) -> None:
    try:
        operator = pwd.getpwnam("ubuntu")
    except KeyError:
        hold("operator identity missing")
    if (os.geteuid() != 0 or os.environ.get("SUDO_USER") != "ubuntu"
            or os.environ.get("SUDO_UID") != str(operator.pw_uid)
            or platform.node().split(".")[0] != HOST
            or platform.machine() != "aarch64"
            or sys.version_info[:2] != (3, 14)):
        hold("wrong privilege/operator/host/architecture/Python")
    if (folder.parent != ROOT or folder.name != "p4e-kXzQYJ"
            or not source.is_absolute()):
        hold("unrecognized checkpoint/source location")
    for item in (ROOT, folder):
        try:
            s = item.lstat()
        except OSError:
            hold("private evidence folder missing")
        if (not stat.S_ISDIR(s.st_mode) or stat.S_ISLNK(s.st_mode)
                or s.st_uid != operator.pw_uid
                or stat.S_IMODE(s.st_mode) != 0o700):
            hold("private evidence folder ownership/mode unsafe")
    try:
        s = source.lstat()
    except OSError:
        hold("pinned P4-A source missing")
    if (not stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode)
            or s.st_uid != operator.pw_uid
            or stat.S_IMODE(s.st_mode) != 0o600):
        hold("pinned source custody unsafe")


def verify_host(source: pathlib.Path, phase: str) -> None:
    oldargs = sys.argv
    sys.argv = [str(source)]
    try:
        helpers = runpy.run_path(str(source), run_name="p4e2_verification_only")
        helpers["verify_host_and_storage"]()
        helpers["verify_config"]()
        if phase == "preboot":
            helpers["verify_runtime"]()
    finally:
        sys.argv = oldargs


def cipher_fingerprint() -> None:
    path = pathlib.Path("/var/lib/vaultwarden-oci/data/db.sqlite3")
    try:
        db = sqlite3.connect("file:" + str(path) + "?mode=ro", uri=True, timeout=15)
        snap = sqlite3.connect(":memory:")
        try:
            db.backup(snap, pages=128, sleep=0.1)
            if snap.execute("PRAGMA integrity_check").fetchone() != ("ok",):
                hold("SQLite integrity check failed")
            users = snap.execute("SELECT COUNT(*) FROM users").fetchone()[0]
            count = snap.execute("SELECT COUNT(*) FROM ciphers").fetchone()[0]
            h = hashlib.sha256()
            for row in snap.execute("SELECT * FROM ciphers ORDER BY uuid"):
                raw = repr(row).encode("utf-8")
                h.update(len(raw).to_bytes(8, "big"))
                h.update(raw)
        finally:
            snap.close()
            db.close()
    except (OSError, sqlite3.Error):
        hold("independent read-only SQLite snapshot failed")
    if (users, count, h.hexdigest()) != (1, 1, CIPHER_SHA):
        hold("original recovery record/data changed; stop")
    passed("SQLite integrity, original 1 user/1 cipher and original fingerprint unchanged")


def check_units(phase: str) -> None:
    target = systemd("vaultwarden-oci.target")
    if (target.get("LoadState"), target.get("ActiveState"),
            target.get("UnitFileState")) != ("loaded", "inactive", "disabled"):
        hold("target not deliberately disabled/inactive")
    app = systemd("vaultwarden-oci.service")
    if (app.get("LoadState"), app.get("ActiveState"),
            app.get("UnitFileState")) != ("loaded", "inactive", "disabled"):
        hold("application systemd service unexpectedly enabled/active")
    dns = systemd("vaultwarden-oci-dns.service")
    if dns.get("LoadState") != "loaded" or dns.get("ActiveState") != "inactive":
        hold("DNS synchronization unit unexpectedly active/unavailable")
    if phase == "postboot" and dns.get("ExecMainStartTimestampMonotonic") not in ("", "0"):
        hold("DNS writer apparently executed since boot; stop")
    for name in TIMERS:
        row = systemd(name)
        if (row.get("LoadState"), row.get("ActiveState"),
                row.get("UnitFileState")) != ("loaded", "inactive", "disabled"):
            hold("timer active/enabled or missing: " + name)
    worker = systemd("crowdsec-cloudflare-worker-bouncer.service")
    if worker.get("LoadState") != "loaded" or worker.get("UnitFileState") != "disabled":
        hold("Worker unit not boot-disabled")
    if phase == "preboot":
        if (worker.get("ActiveState"), worker.get("InvocationID")) != ("active", WORKER_INV):
            hold("previous CrowdSec Worker invocation/state changed")
    else:
        if worker.get("ActiveState") != "inactive":
            hold("Worker unexpectedly active/failed after boot")
    passed("target/timers still disabled and inactive; Worker boot-disabled")


def inspect(name: str) -> dict:
    try:
        data = json.loads(run(["docker", "container", "inspect", name], timeout=30))
        if not isinstance(data, list) or len(data) != 1:
            hold("Docker container inspection shape invalid")
        return data[0]
    except (ValueError, TypeError, IndexError):
        hold("Docker container inspection failed")


def check_container_policy(phase: str) -> None:
    caddy = inspect("vaultwarden-oci-caddy")
    vault = inspect("vaultwarden-oci-vaultwarden")
    try:
        cp = caddy["HostConfig"]["RestartPolicy"]["Name"]
        vp = vault["HostConfig"]["RestartPolicy"]["Name"]
        cs = caddy["State"]["Status"]
        vs = vault["State"]["Status"]
    except (KeyError, TypeError):
        hold("Docker restart/state metadata missing")
    if cp != "no" or vp != "unless-stopped":
        hold("unexpected installed Docker restart policy")
    if phase == "preboot":
        if cs != "running" or vs != "running":
            hold("baseline application not running")
    else:
        if cs == "running" or cs not in ("exited", "created", "dead"):
            hold("Caddy unexpectedly exposed/unknown after fail-closed reboot")
        # Vaultwarden may restart via Docker. Only Caddy is the public origin.
        if vs not in ("running", "exited", "created"):
            hold("Vaultwarden Docker state unexpectedly unavailable")
    passed("Docker restart policy: Caddy=no; Vaultwarden=unless-stopped")
    if phase == "postboot":
        passed("Caddy is not auto-running after host reboot (intentional fail-closed mode)")


def main() -> None:
    if len(sys.argv) != 4 or sys.argv[1] not in ("preboot", "postboot"):
        hold("phase must be preboot|postboot with pinned source and checkpoint paths")
    phase, source, folder = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
    safe_identity(source, folder)
    checkpoint = private_file(folder / "preboot.json")
    if (checkpoint.get("schema_version") != 1
            or checkpoint.get("phase") != "preboot_readonly"
            or checkpoint.get("installed_source") != SOURCE
            or checkpoint.get("release") != "0.1.0-rc.13"
            or checkpoint.get("disk_uuid") != UUID
            or checkpoint.get("sqlite_fingerprint") != CIPHER_SHA
            or checkpoint.get("worker_invocation") != WORKER_INV
            or checkpoint.get("dns_in_sync") != "true"
            or checkpoint.get("dns_proxied") != "true"
            or checkpoint.get("dns_isolation_required") is not True
            or checkpoint.get("reboot_performed") is not False):
        hold("P4-E1 checkpoint not applicable to this exact boot/scope")
    now_boot = boot_id()
    verify_host(source, phase)
    cipher_fingerprint()
    check_units(phase)
    check_container_policy(phase)

    if phase == "preboot":
        if now_boot != checkpoint.get("boot_id"):
            hold("boot already changed since E1; no repeat reboot")
        if (folder / "armed.json").exists() or (folder / "armed.json").is_symlink():
            hold("preboot already armed; do not repeat")
        # Read-only authenticated Cloudflare status; never call dns update.
        dns = run(["/usr/local/bin/vwctl", "dns", "status"], timeout=90)
        if ("in_sync=true" not in dns or "proxied=true" not in dns):
            hold("read-only Cloudflare DNS no longer confirmed in-sync/proxied")
        write_private(folder / "armed.json", {
            "source": SOURCE, "disk_uuid": UUID, "boot_id": now_boot,
            "sqlite_fingerprint": CIPHER_SHA, "worker_invocation": WORKER_INV,
            "target_timers": "disabled",
            "dns_automation": "disabled",
            "armed_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        })
        passed("P4-E1 source/boot checkpoint and Cloudflare DNS in-sync confirmed")
        print("P4_E2_PREBOOT_EXIT=0 PASS; REBOOT_REQUEST_SEPARATE", flush=True)
        return

    armed = private_file(folder / "armed.json")
    if (armed.get("source"), armed.get("disk_uuid"), armed.get("sqlite_fingerprint"),
            armed.get("worker_invocation"), armed.get("boot_id"),
            armed.get("target_timers"), armed.get("dns_automation")) != (
                SOURCE, UUID, CIPHER_SHA, WORKER_INV, checkpoint.get("boot_id"),
                "disabled", "disabled"):
        hold("preboot armed checkpoint mismatch")
    if now_boot == armed["boot_id"]:
        hold("boot identity unchanged; actual reboot NOT established")
    if (folder / "postboot.json").exists() or (folder / "postboot.json").is_symlink():
        hold("postboot evidence already exists; no duplicate acceptance")
    write_private(folder / "postboot.json", {
        "source": SOURCE,
        "disk_uuid": UUID,
        "original_boot_id": armed["boot_id"],
        "new_boot_id": now_boot,
        "sqlite_fingerprint": CIPHER_SHA,
        "worker": "boot-disabled/inactive",
        "target_timers": "disabled",
        "caddy": "not_running",
        "result": "PASS_FAIL_CLOSED_BOOT",
        "observed_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    })
    passed("genuine new kernel boot, dedicated data preserved, no auto-published Caddy")
    print("P4_E2_POSTBOOT_EXIT=0 FAIL_CLOSED_BOOT_PASS; APP_START_AND_WORKER_REARM=NOT_RUN", flush=True)
    print("P4_E2_AUTOMATIC_TARGET_TIMER_PERSISTENCE=NOT_RUN", flush=True)
    print("RELEASE_GO=HOLD", flush=True)


if __name__ == "__main__":
    main()
