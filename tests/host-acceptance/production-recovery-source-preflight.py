#!/usr/bin/env python3
"""Read-only source/custody preflight before an explicitly authorized rc.12 restore.

Disposable host-specific acceptance instrument, NOT an installed product command.
No remote API access, credential refresh, decrypt-to-disk, restore, backup,
Cloudflare change, systemd activation, or appliance filesystem mutation.
Only a root-private summary under the sudo operator's acceptance directory.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import os
import platform
import pwd
import re
import stat
import subprocess
import sys
import tomllib
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-6-vnic"
VERSION = "0.1.0-rc.12"
EXPECTED_VOLUME_UUID = "75ceee68-0fff-4f74-b629-4e22b3b99c20"
EXPECTED_BYID = Path("/dev/disk/by-id/scsi-36088f6a844d04920961a8a7b0feab3b9")
OFFLINE_RECIPIENT_SHA256 = "7d08721bcc02bbef7dae1f07bfde244852560c69d0b72f8dc0fcba0da30c6773"
HISTORICAL_REMOTE = "bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec"
HISTORICAL_SHA256 = "ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060"
ENCRYPTED_KIT = Path("/home/ubuntu/vaultwarden-recovery-kit-20261006T222828Z.zip")
RELEASE = Path("/opt/vaultwarden-oci/releases") / VERSION
CURRENT = Path("/opt/vaultwarden-oci/current")
STATE = Path("/var/lib/vaultwarden-oci")
UNITS = (
    "vaultwarden-oci.target",
    "vaultwarden-oci.service",
    "vaultwarden-oci-health.timer",
    "vaultwarden-oci-backup.timer",
    "vaultwarden-oci-maintenance.timer",
    "vaultwarden-oci-update-check.timer",
    "vaultwarden-oci-dns.service",
)
REMOTE = "bw-backup"


def run_readonly(argv: list[str], timeout: int = 15) -> tuple[int | None, str]:
    try:
        env = {key: val for key, val in os.environ.items()
               if not key.startswith("RCLONE_")}
        env["HOME"] = "/root"
        env["XDG_CONFIG_HOME"] = "/root/.config"
        result = subprocess.run(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, check=False,
            timeout=timeout, cwd="/", env=env,
        )
        return result.returncode, result.stdout
    except (OSError, subprocess.TimeoutExpired):
        return None, ""


def matches_offline_recipient(value: object) -> bool:
    return (isinstance(value, str) and hashlib.sha256(value.encode("utf-8")).hexdigest()
            == OFFLINE_RECIPIENT_SHA256)


def remote_available(stdout: str, code: int | None) -> bool:
    if code != 0:
        return False
    names = {line.strip() for line in stdout.splitlines()
             if re.fullmatch(r"[A-Za-z0-9_-]{1,80}:", line.strip())}
    return REMOTE + ":" in names


def kit_metadata(path: Path, operator_uid: int) -> str:
    """No ZIP open, decryption, private key extraction, or passphrase reading."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        return "absent"
    except OSError:
        return "unsafe"
    if (not stat.S_ISREG(info.st_mode) or info.st_uid not in {0, operator_uid}
            or stat.S_IMODE(info.st_mode) != 0o600
            or not 0 < info.st_size <= 16 * 1024 * 1024):
        return "unsafe"
    return "present-unverified"


def stopped_units(states: dict[str, dict[str, str]]) -> bool:
    if set(states) != set(UNITS):
        return False
    for unit, fields in states.items():
        if fields.get("LoadState") != "loaded" or fields.get("ActiveState") != "inactive":
            return False
        expected = "static" if unit == "vaultwarden-oci-dns.service" else "disabled"
        if fields.get("UnitFileState") != expected:
            return False
    return True


def backup_policy_safe(remote: object, local: object, offsite: object) -> bool:
    return remote in ("", None) and type(local) is int and local == 0 and type(offsite) is int and offsite == 0


def evidence_dir() -> Path:
    operator = os.environ.get("SUDO_USER")
    if operator != "ubuntu":
        raise RuntimeError("not invoked by the recorded disposable-host operator")
    home = Path(pwd.getpwnam(operator).pw_dir)
    if home.is_symlink() or not home.is_dir():
        raise RuntimeError("unsafe operator home")
    base = home / "vwoci-acceptance"
    if base.is_symlink():
        raise RuntimeError("acceptance evidence root is a symlink")
    if not base.exists():
        base.mkdir(mode=0o700)
    info = base.lstat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
        raise RuntimeError("acceptance evidence root is not private")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = base / f"p1-recovery-source-{stamp}-{os.getpid()}"
    out.mkdir(mode=0o700)
    return out


def main() -> int:
    if len(sys.argv) != 1 or os.geteuid() != 0:
        print("BLOCKED: no arguments; run with sudo -n as ubuntu", file=sys.stderr)
        return 2
    try:
        out = evidence_dir()
    except (OSError, KeyError, RuntimeError) as exc:
        print("BLOCKED: cannot create private operator evidence (" + type(exc).__name__ + ")", file=sys.stderr)
        return 2

    rows: list[tuple[str, str]] = []
    blocked = False

    def record(state: str, msg: str) -> None:
        nonlocal blocked
        if state not in {"PASS", "BLOCKED", "PENDING", "NOT RUN"}:
            raise RuntimeError("invalid evidence classification")
        rows.append((state, msg))
        if state == "BLOCKED":
            blocked = True

    def finish() -> int:
        overall = "BLOCKED" if blocked else "PENDING"
        record(overall, "Pre-restore readiness; no restore or external side effects authorized")
        summary = ("Gate P1 — rc.12 recovery source/custody inventory (read only)\n"
                   + "\n".join(f"{state:<8} {msg}" for state, msg in rows) + "\n")
        (out / "summary.txt").write_text(summary, encoding="utf-8")
        print(summary, end="")
        print("Private summary:", out / "summary.txt")
        print("Paste summary only; never paste rclone configuration, identity files, ZIP passphrase or secrets.")
        return 2 if blocked else 0

    record("PASS" if platform.node().split(".")[0] == HOST else "BLOCKED",
           f"Host identity {'matches' if platform.node().split('.')[0] == HOST else 'mismatch'}: expected {HOST}")
    if not CURRENT.is_symlink():
        record("BLOCKED", "No installed immutable release symlink")
        return finish()
    try:
        installed = CURRENT.resolve(strict=True)
    except OSError:
        installed = None
    if installed != RELEASE:
        record("BLOCKED", "Installed release does not match frozen 0.1.0-rc.12")
        return finish()
    record("PASS", "Installed immutable rc.12 release selected; no source update performed")

    try:
        sys.path.insert(0, str(installed))
        from vaultwarden_oci import runtime, secrets, storage
        ident = storage.verify()
        if ident.uuid != EXPECTED_VOLUME_UUID or EXPECTED_BYID.resolve(strict=True) != Path(ident.source).resolve(strict=True):
            raise RuntimeError("storage identity mismatch")
    except Exception as exc:
        record("BLOCKED", "Original mounted dedicated volume/dual markers not proven (" + type(exc).__name__ + ")")
        return finish()
    record("PASS", "Original dedicated ext4 volume, stable by-id, root separation and dual ownership markers verified")

    unit_states: dict[str, dict[str, str]] = {}
    for unit in UNITS:
        code, stdout = run_readonly(
            ["systemctl", "show", unit, "--no-pager",
             "--property=LoadState,ActiveState,UnitFileState"]
        )
        if code != 0:
            break
        unit_states[unit] = dict(line.split("=", 1) for line in stdout.splitlines() if "=" in line)
    if not stopped_units(unit_states):
        record("BLOCKED", "Appliance/automation is active, enabled or unexpectedly missing; do not treat as an isolated restore target")
        return finish()
    record("PASS", "Appliance, DNS oneshot and four timers remain inactive with approved disabled/static states")

    if (STATE / "state/update-recovery-required.json").exists():
        record("BLOCKED", "Update recovery-required guard exists; no restore permitted")
        return finish()
    record("PASS", "No update recovery-required guard")
    try:
        config = runtime.load_config()
        if not matches_offline_recipient(config.offline_recovery_recipient):
            record("BLOCKED", "Offline recovery public recipient does not match accepted rc.11 A4/rc.12 D1R custody")
            return finish()
        secrets.validate_custody(config.offline_recovery_recipient)
    except (runtime.RuntimeConfigError, secrets.SecretsError, OSError) as exc:
        record("BLOCKED", "Cannot prove matching public/offline SOPS recipient custody (" + type(exc).__name__ + ")")
        return finish()
    record("PASS", "Offline public recipient fingerprint matches original Box acceptance and current encrypted secrets")
    record("PASS" if backup_policy_safe(config.offsite_remote, config.local_retention_days, config.remote_retention_days) else "BLOCKED",
           "Pre-restore offsite publishing disabled and retention 0/0" if backup_policy_safe(config.offsite_remote, config.local_retention_days, config.remote_retention_days) else "Unexpected configured offsite publication or pruning risk")
    if blocked:
        return finish()

    # rclone listremotes loads root configuration names only: no cloud API call.
    # Do NOT call rclone lsf/lsjson: an OAuth refresh can rewrite host credentials.
    status, names = run_readonly(["rclone", "listremotes"], timeout=15)
    present = remote_available(names, status)
    record("PASS" if present else "PENDING",
           "Root's bw-backup: rclone name exists (no remote connectivity tested)" if present
           else "Root's bw-backup: remote not available; credentials must be provisioned securely or a trusted workstation must transfer ciphertext")
    record("PENDING", "Historical Box ciphertext known from A3/A4: " + HISTORICAL_REMOTE
           + "; original recorded SHA-256=" + HISTORICAL_SHA256 + " (current availability and hash NOT checked)")

    uid = pwd.getpwnam("ubuntu").pw_uid
    kit_state = kit_metadata(ENCRYPTED_KIT, uid)
    if kit_state == "unsafe":
        record("BLOCKED", "Potential recovery-kit ZIP at prior source path is unsafe; do not open")
    elif kit_state == "absent":
        record("PENDING", "Prior encrypted recovery-kit ZIP not present at accepted temporary VM path; off-host custody required")
    else:
        record("PENDING", "Encrypted recovery-kit ZIP found at original VM path (metadata only; AES-256 and matching identity not reverified)")
    record("PENDING", "Offline private Age identity plus recovery-kit passphrase must be attested by operator off-host; do not paste them")
    record("NOT RUN", "No Box metadata API/readback, ciphertext download, Age private-key extraction, archive verification or restore")
    record("NOT RUN", "No services, CrowdSec Worker, DNS, SMTP, timers, snapshot, package changes or reboot")
    return finish()


if __name__ == "__main__":
    raise SystemExit(main())
