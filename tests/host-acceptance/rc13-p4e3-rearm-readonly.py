#!/usr/bin/env python3
"""Temporary VM8 P4-E3 guarded post-reboot application/Worker acceptance.

Three read-only phases: preflight, after-start and after-worker.
The invoking one-shot alone performs supported vwctl start and
crowdsec remediation-start as separate, gated state changes.
This script intentionally does NOT confirm Cloudflare Route Fail Open.
Remove from active tree once its immutable evidence is archived.
"""
from __future__ import annotations

import datetime
import hashlib
import ipaddress
import json
import os
from pathlib import Path
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
APP = "0.1.0-rc.13"
UUID = "f4e0bd62-48e7-4745-8987-44b14013216d"
CIPHER = "10b53feb60db4f7d94f280b6601e6fdfd35d6137d13eb351b94f99234c4149fa"
OLD_WORKER = "a80be9e43af84a24b505b9e4b127abeb"
P4A_SHA = "bac3b2fa65b5952a70a5977b8b846c555ac5b912e04304606fa88bd5e199143c"
ROOT = Path("/home/ubuntu/vwoci-acceptance")
CHECKPOINT = ROOT / "p4e-kXzQYJ"
TIMERS = (
    "vaultwarden-oci-health.timer",
    "vaultwarden-oci-backup.timer",
    "vaultwarden-oci-maintenance.timer",
    "vaultwarden-oci-update-check.timer",
)


def hold(message: str) -> None:
    print("P4_E3_EXIT=2 HOLD: " + message, flush=True)
    raise SystemExit(2)


def passed(message: str) -> None:
    print("PASS: " + message, flush=True)


def command(args: list[str], allowed=(0,), timeout=90) -> tuple[int, str]:
    try:
        p = subprocess.run(
            args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, cwd="/",
            timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        hold("read-only command unavailable: " + args[0])
    if p.returncode not in allowed or len(p.stdout) > 256000:
        hold("unexpected read-only command status/size: " + args[0])
    return p.returncode, p.stdout


def unit(name: str) -> dict[str, str]:
    _, out = command([
        "systemctl", "show", name, "--no-pager",
        "--property=LoadState,ActiveState,UnitFileState,InvocationID,ExecMainStartTimestampMonotonic",
    ], timeout=20)
    return dict(l.split("=", 1) for l in out.splitlines() if "=" in l)


def safe_file(path: Path, *, owner: int = 0) -> dict:
    try:
        s = path.lstat()
        if (not stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode)
                or s.st_uid != owner or stat.S_IMODE(s.st_mode) != 0o600):
            hold("unsafe protected checkpoint file")
        result = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(result, dict):
            hold("protected checkpoint JSON is not an object")
        return result
    except (OSError, ValueError, TypeError):
        hold("protected checkpoint missing or unreadable")


def write_once(path: Path, obj: dict) -> None:
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(obj, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
    except OSError:
        hold("could not write protected phase checkpoint")


def boot_id() -> str:
    try:
        result = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
    except OSError:
        hold("kernel boot ID unavailable")
    if not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", result):
        hold("kernel boot ID invalid")
    return result


def source_and_host(script: Path) -> tuple[dict, str]:
    try:
        operator = pwd.getpwnam("ubuntu")
    except KeyError:
        hold("ubuntu operator missing")
    if (os.geteuid() != 0 or os.environ.get("SUDO_USER") != "ubuntu"
            or os.environ.get("SUDO_UID") != str(operator.pw_uid)
            or platform.node().split(".")[0] != "vaultwarden-oci-8"
            or platform.machine() != "aarch64"
            or sys.version_info[:2] != (3, 14)):
        hold("operator, privilege, host, ARM64 or Python 3.14 mismatch")
    if script != Path("/home/ubuntu/rc13-p4a-readonly-b98a96fa92c3.py"):
        hold("unexpected P4-A pin location")
    for directory in (ROOT, CHECKPOINT):
        try:
            meta = directory.lstat()
        except OSError:
            hold("protected checkpoint directory missing")
        if (not stat.S_ISDIR(meta.st_mode) or stat.S_ISLNK(meta.st_mode)
                or meta.st_uid != operator.pw_uid or stat.S_IMODE(meta.st_mode) != 0o700):
            hold("private checkpoint folder custody mismatch")
    try:
        st = script.lstat()
        if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)
                or st.st_uid != operator.pw_uid or stat.S_IMODE(st.st_mode) != 0o600
                or hashlib.sha256(script.read_bytes()).hexdigest() != P4A_SHA):
            hold("pinned source preflight custody/checksum mismatch")
    except OSError:
        hold("pinned P4-A script unavailable")
    old = sys.argv
    sys.argv = [str(script)]
    try:
        helpers = runpy.run_path(str(script), run_name="p4e3_import_only")
        helpers["verify_host_and_storage"]()
        domain = helpers["verify_config"]()
    finally:
        sys.argv = old
    return helpers, domain


def fingerprint() -> None:
    try:
        db = sqlite3.connect("file:/var/lib/vaultwarden-oci/data/db.sqlite3?mode=ro", uri=True, timeout=15)
        mem = sqlite3.connect(":memory:")
        try:
            db.backup(mem, pages=128, sleep=0.1)
            if mem.execute("PRAGMA integrity_check").fetchone() != ("ok",):
                hold("SQLite integrity failed")
            users = mem.execute("SELECT COUNT(*) FROM users").fetchone()[0]
            count = mem.execute("SELECT COUNT(*) FROM ciphers").fetchone()[0]
            digest = hashlib.sha256()
            for row in mem.execute("SELECT * FROM ciphers ORDER BY uuid"):
                raw = repr(row).encode("utf-8")
                digest.update(len(raw).to_bytes(8, "big"))
                digest.update(raw)
        finally:
            db.close()
            mem.close()
    except (OSError, sqlite3.Error):
        hold("read-only SQLite snapshot failed")
    if (users, count, digest.hexdigest()) != (1, 1, CIPHER):
        hold("restored original cipher/user state changed")
    passed("post-reboot SQLite integrity, 1 user/1 original cipher and fingerprint unchanged")


def checkpoint(phase: str) -> str:
    entry = safe_file(CHECKPOINT / "postboot.json")
    armed = safe_file(CHECKPOINT / "armed.json")
    if (entry.get("result") != "PASS_FAIL_CLOSED_BOOT"
            or entry.get("source") != SOURCE or entry.get("disk_uuid") != UUID
            or entry.get("sqlite_fingerprint") != CIPHER
            or entry.get("target_timers") != "disabled"
            or entry.get("worker") != "boot-disabled/inactive"
            or entry.get("caddy") != "not_running"
            or armed.get("source") != SOURCE
            or armed.get("disk_uuid") != UUID
            or armed.get("worker_invocation") != OLD_WORKER
            or armed.get("boot_id") != entry.get("original_boot_id")
            or entry.get("new_boot_id") == entry.get("original_boot_id")
            or boot_id() != entry.get("new_boot_id")):
        hold("P4-E2 postboot checkpoint not valid for this host/boot")
    if phase != "preflight":
        previous = safe_file(CHECKPOINT / "p4e3-preflight.json")
        if (previous.get("boot_id"), previous.get("source"),
                previous.get("disk_uuid")) != (boot_id(), SOURCE, UUID):
            hold("P4-E3 preflight checkpoint stale")
    return entry["new_boot_id"]


def check_units(worker_expected: str) -> str:
    app = unit("vaultwarden-oci.service")
    target = unit("vaultwarden-oci.target")
    if any((r.get("LoadState"), r.get("ActiveState"), r.get("UnitFileState"))
           != ("loaded", "inactive", "disabled") for r in (app, target)):
        hold("application/target systemd enablement changed")
    for name in TIMERS:
        row = unit(name)
        if (row.get("LoadState"), row.get("ActiveState"), row.get("UnitFileState")) != (
            "loaded", "inactive", "disabled"
        ):
            hold("timer enabled, active or missing: " + name)
    dns = unit("vaultwarden-oci-dns.service")
    if (dns.get("LoadState") != "loaded" or dns.get("ActiveState") != "inactive"
            or dns.get("ExecMainStartTimestampMonotonic") not in ("0", "")):
        hold("public DNS update service unexpectedly active or executed since boot")
    worker = unit("crowdsec-cloudflare-worker-bouncer.service")
    if (worker.get("LoadState"), worker.get("ActiveState"),
            worker.get("UnitFileState")) != ("loaded", worker_expected, "disabled"):
        hold("Worker or boot policy changed")
    return worker.get("InvocationID", "")


def containers(expected_caddy_running: bool) -> str:
    names = ("vaultwarden-oci-caddy", "vaultwarden-oci-vaultwarden")
    data = {}
    for name in names:
        try:
            _, out = command(["docker", "container", "inspect", name], timeout=30)
            data[name] = json.loads(out)[0]
        except (ValueError, TypeError, KeyError, IndexError):
            hold("Docker installed container inspection failed")
    caddy, vault = (data[name] for name in names)
    try:
        cs, vs = caddy["State"], vault["State"]
        if (caddy["HostConfig"]["RestartPolicy"]["Name"] != "no"
                or vault["HostConfig"]["RestartPolicy"]["Name"] != "unless-stopped"):
            hold("Docker boot restart policies changed")
        if expected_caddy_running:
            if any(row["Status"] != "running" or row["Paused"] is not False
                   or row["Health"]["Status"] != "healthy" for row in (cs, vs)):
                hold("Caddy/Vaultwarden not healthy, running and unpaused")
        elif cs["Status"] == "running":
            hold("Caddy running before explicit start, fail-closed baseline changed")
        networks = caddy["NetworkSettings"]["Networks"]
        ips = [ipaddress.ip_address(n.get("IPAddress", ""))
               for n in networks.values() if n.get("IPAddress")]
        private = [str(ip) for ip in ips if ip.version == 4 and ip.is_private]
    except (KeyError, TypeError, ValueError):
        hold("Docker runtime state incomplete")
    if expected_caddy_running and not private:
        hold("no private IPv4 TLS origin after startup")
    return private[0] if private else ""


def security_checks(*, worker: str) -> None:
    rc, out = command(["/usr/local/bin/vwctl", "doctor", "--json"],
                      allowed=(0, 1), timeout=90)
    try:
        data = json.loads(out)
        checks = {x["id"]: x["status"] for x in data["checks"]}
    except (ValueError, TypeError, KeyError):
        hold("doctor output invalid")
    required = (
        "runtime.paths", "secrets.custody", "secrets.decrypt",
        "edge.caddy.trusted_proxy", "edge.admin.protection",
        "edge.cloudflare.cidrs", "edge.cloudflare.iptables",
        "crowdsec.engine", "crowdsec.hub", "crowdsec.firewall",
    )
    if any(checks.get(x) != "PASS" for x in required):
        hold("app, data, origin or CrowdSec non-Worker doctor check failed")
    if checks.get("crowdsec.cloudflare") != "FAIL" or rc != 1:
        hold("expected unconfirmed Cloudflare Worker state not observed")
    if any(x == "FAIL" for k, x in checks.items() if k != "crowdsec.cloudflare"):
        hold("other doctor check unexpectedly failed")
    passed("all non-Worker doctor/security checks PASS; Worker Fail Open still unconfirmed")


def main() -> None:
    if (len(sys.argv) != 3 or sys.argv[1] not in
            ("preflight", "after-start", "after-worker")):
        hold("expected phase and pinned P4-A script path")
    phase, source = sys.argv[1], Path(sys.argv[2])
    helpers, domain = source_and_host(source)
    current_boot = checkpoint(phase)
    fingerprint()
    from vaultwarden_oci import edge, crowdsec_worker_policy

    if phase == "preflight":
        check_units("inactive")
        containers(False)
        if (CHECKPOINT / "p4e3-preflight.json").exists():
            hold("P4-E3 has already started; do not repeat")
        write_once(CHECKPOINT / "p4e3-preflight.json", {
            "source": SOURCE, "disk_uuid": UUID, "boot_id": current_boot,
            "phase": "preflight", "observed_at_utc":
                datetime.datetime.now(datetime.timezone.utc).isoformat(),
        })
        passed("boot-recovered data and intentional disabled DNS/automation state verified")
        print("P4_E3_PREFLIGHT_EXIT=0 PASS; NO_MUTATION_YET", flush=True)
        return

    expected = "inactive" if phase == "after-start" else "active"
    new_invocation = check_units(expected)
    ip = containers(True)
    helpers["verify_local_https"](domain, ip)
    security_checks(worker=expected)
    if phase == "after-start":
        if (CHECKPOINT / "p4e3-app.json").exists():
            hold("application start already accepted, no repeat")
        write_once(CHECKPOINT / "p4e3-app.json", {
            "source": SOURCE, "boot_id": current_boot,
            "phase": "after-start", "caddy": "healthy",
            "observed_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        })
        passed("application restarted through supported CLI, private HTTPS restored")
        print("P4_E3_APP_EXIT=0 APP_START_PASS; WORKER_START_NOT_YET_RUN", flush=True)
        return

    app_witness = safe_file(CHECKPOINT / "p4e3-app.json")
    if (app_witness.get("source"), app_witness.get("boot_id"),
            app_witness.get("caddy")) != (SOURCE, current_boot, "healthy"):
        hold("application restart witness absent/stale")
    paths = edge.EdgePaths()
    if (not re.fullmatch(r"[a-f0-9]{32}", new_invocation)
            or new_invocation == OLD_WORKER
            or not crowdsec_worker_policy.runtime_policy_healthy(paths, edge.run_command)):
        hold("new Worker invocation or local-only source attestation failed")
    if paths.fail_open_confirmation.exists() or paths.fail_open_confirmation.is_symlink():
        hold("previous or unverified Fail Open acknowledgment still present")
    if (CHECKPOINT / "p4e3-worker.json").exists():
        hold("Worker startup already accepted; no repeat")
    write_once(CHECKPOINT / "p4e3-worker.json", {
        "source": SOURCE, "boot_id": current_boot,
        "new_worker_invocation": new_invocation, "phase": "awaiting-route-fail-open",
        "route_verified": False, "confirmed": False,
        "observed_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    })
    passed("new Worker invocation active/boot-disabled and attested to local-only decisions")
    print("P4_E3_NEW_WORKER_INVOCATION=" + new_invocation, flush=True)
    print("P4_E3_EXIT=0 APP_AND_WORKER_STARTED; ROUTE_FAIL_OPEN_CONFIRMATION=NOT_RUN", flush=True)
    print("RELEASE_GO=HOLD", flush=True)


if __name__ == "__main__":
    main()
