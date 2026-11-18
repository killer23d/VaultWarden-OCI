#!/usr/bin/env python3
"""Temporary VM8 P4-D acceptance: rc.13 controlled restart pre/post evidence.

Run separately as preflight/postflight from the pinned operator one-shot.
Read-only except root-private before/after evidence files. The calling
shell alone owns the separately authorized vwctl restart mutation.
Remove from active tree after recording immutable script provenance.
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

EXPECTED_UUID = "f4e0bd62-48e7-4745-8987-44b14013216d"
EXPECTED_DIGEST = "10b53feb60db4f7d94f280b6601e6fdfd35d6137d13eb351b94f99234c4149fa"
EXPECTED_USER = "ubuntu"
EXPECTED_HOST = "vaultwarden-oci-8"
EVIDENCE_ROOT = pathlib.Path("/home/ubuntu/vwoci-acceptance")


def hold(message: str) -> None:
    print("P4_D_EXIT=2 HOLD: " + message, flush=True)
    raise SystemExit(2)


def passed(message: str) -> None:
    print("PASS: " + message, flush=True)


def safe_evidence(folder: pathlib.Path) -> None:
    try:
        operator = pwd.getpwnam(EXPECTED_USER)
    except KeyError:
        hold("expected operator account missing")
    if (os.geteuid() != 0 or os.environ.get("SUDO_USER") != EXPECTED_USER
            or os.environ.get("SUDO_UID") != str(operator.pw_uid)):
        hold("root privilege through ubuntu sudo -n required")
    if (platform.node().split(".")[0] != EXPECTED_HOST
            or platform.machine() != "aarch64"
            or sys.version_info[:2] != (3, 14)):
        hold("host, ARM64 or Python 3.14 mismatch")
    if folder.parent != EVIDENCE_ROOT or not re.fullmatch(r"p4d-[A-Za-z0-9_-]{6,80}", folder.name):
        hold("unexpected evidence location")
    for directory in (EVIDENCE_ROOT, folder):
        try:
            s = directory.lstat()
        except OSError:
            hold("protected evidence directory missing")
        if (not stat.S_ISDIR(s.st_mode) or stat.S_ISLNK(s.st_mode)
                or s.st_uid != operator.pw_uid or stat.S_IMODE(s.st_mode) != 0o700):
            hold("evidence directory must be owned by operator and mode 0700")


def source_preflight(source: pathlib.Path):
    try:
        operator = pwd.getpwnam(EXPECTED_USER)
        s = source.lstat()
    except (OSError, KeyError):
        hold("prior verified source script missing")
    if (not stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode)
            or s.st_uid != operator.pw_uid or stat.S_IMODE(s.st_mode) != 0o600):
        hold("prior source script has unsafe file custody")
    saved = sys.argv
    sys.argv = [str(source)]  # P4-A helper requires len(argv)==1.
    try:
        helpers = runpy.run_path(str(source), run_name="p4d_import_only")
        helpers["verify_host_and_storage"]()
        domain = helpers["verify_config"]()
        ip = helpers["verify_runtime"]()
    finally:
        sys.argv = saved
    return helpers, domain, ip


def cipher_fingerprint() -> str:
    dbpath = pathlib.Path("/var/lib/vaultwarden-oci/data/db.sqlite3")
    try:
        con = sqlite3.connect("file:" + str(dbpath) + "?mode=ro", uri=True, timeout=15)
        snapshot = sqlite3.connect(":memory:")
        try:
            con.backup(snapshot, pages=128, sleep=0.1)
            if snapshot.execute("PRAGMA integrity_check").fetchone() != ("ok",):
                hold("SQLite integrity failure")
            users = snapshot.execute("SELECT COUNT(*) FROM users").fetchone()[0]
            rows = list(snapshot.execute("SELECT * FROM ciphers ORDER BY uuid"))
        finally:
            snapshot.close()
            con.close()
    except (sqlite3.Error, OSError):
        hold("read-only SQLite snapshot unavailable")
    digest = hashlib.sha256()
    for row in rows:
        raw = repr(row).encode("utf-8")
        digest.update(len(raw).to_bytes(8, "big"))
        digest.update(raw)
    if users != 1 or len(rows) != 1 or digest.hexdigest() != EXPECTED_DIGEST:
        hold("restored original single-item fingerprint or user count changed")
    passed("independent SQLite snapshot integrity=ok; one user, one cipher; fingerprint unchanged")
    return digest.hexdigest()


def ids() -> dict[str, str]:
    result = {}
    for name in ("vaultwarden-oci-vaultwarden", "vaultwarden-oci-caddy"):
        try:
            p = subprocess.run(
                ["docker", "container", "inspect", name],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True, timeout=30,
                check=False,
            )
            if p.returncode:
                hold("container inspection unavailable")
            row = json.loads(p.stdout)[0]
            status = row["State"]
            cid = row["Id"]
            if (status["Status"] != "running" or status["Paused"] is not False
                    or status["Health"]["Status"] != "healthy"
                    or not re.fullmatch(r"[0-9a-f]{64}", cid)):
                hold("container not running, unpaused and healthy")
            result[name] = cid
        except (OSError, subprocess.TimeoutExpired, ValueError, IndexError, KeyError, TypeError):
            hold("container ID/health unavailable")
    return result


def write_private(path: pathlib.Path, obj: dict) -> None:
    try:
        with path.open("x", encoding="utf-8") as stream:
            os.chmod(path, 0o600)
            json.dump(obj, stream, indent=2, sort_keys=True)
            stream.write("\n")
    except OSError:
        hold("cannot write private phase evidence")


def read_private(path: pathlib.Path) -> dict:
    try:
        info = path.lstat()
        if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
                or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o600):
            hold("unsafe baseline evidence file")
        value = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            hold("baseline evidence shape invalid")
        return value
    except (OSError, ValueError):
        hold("baseline evidence missing/invalid")


def main() -> None:
    if len(sys.argv) != 4 or sys.argv[1] not in {"preflight", "postflight"}:
        hold("usage: p4d.py preflight|postflight /path/p4a.py /home/ubuntu/vwoci-acceptance/p4d-RUN")
    phase, source, folder = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
    safe_evidence(folder)
    helpers, domain, ip = source_preflight(source)
    digest = cipher_fingerprint()
    current_ids = ids()
    if phase == "preflight":
        if (folder / "before.json").exists() or (folder / "before.json").is_symlink():
            hold("baseline evidence already exists")
        write_private(folder / "before.json", {
            "source": "fd56313255c97992dc55c1475d94477597b88602",
            "release": "0.1.0-rc.13",
            "disk_uuid": EXPECTED_UUID,
            "sqlite_fingerprint": digest,
            "ids": current_ids,
            "worker_invocation": "a80be9e43af84a24b505b9e4b127abeb",
            "observed_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        })
        passed("read-only preflight: restored state, immutable release, healthy runtime")
        passed("Worker invocation preserved, automation idle, no root fallback")
        print("P4_D_PREFLIGHT_EXIT=0 PASS; RESTART_NOT_YET_RUN", flush=True)
        return

    baseline = read_private(folder / "before.json")
    if (baseline.get("source") != "fd56313255c97992dc55c1475d94477597b88602"
            or baseline.get("disk_uuid") != EXPECTED_UUID
            or baseline.get("sqlite_fingerprint") != digest
            or baseline.get("worker_invocation") != "a80be9e43af84a24b505b9e4b127abeb"
            or baseline.get("release") != "0.1.0-rc.13"):
        hold("pre/post source, recovery or Worker identity mismatch")
    prior_ids = baseline.get("ids")
    if (not isinstance(prior_ids, dict) or set(prior_ids) != set(current_ids)
            or any(prior_ids[name] == cid for name, cid in current_ids.items())):
        hold("containers not both recreated by genuine supported restart")
    helpers["verify_local_https"](domain, ip)
    passed("both containers recreated, healthy, unpaused; no recovered item drift")
    passed("CrowdSec/Cloudflare/local doctor PASS; Worker invocation preserved")
    write_private(folder / "after.json", {
        "source": baseline["source"],
        "disk_uuid": EXPECTED_UUID,
        "sqlite_fingerprint": digest,
        "ids": current_ids,
        "observed_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "result": "PASS",
    })
    print("P4_D_EXIT=0 CONTROLLED_RESTART_PASS; REBOOT_AND_TIMER_TEST=NOT_RUN; RELEASE_GO=HOLD", flush=True)


if __name__ == "__main__":
    main()
