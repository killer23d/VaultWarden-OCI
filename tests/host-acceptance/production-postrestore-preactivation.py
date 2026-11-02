#!/usr/bin/env python3
"""P4: broad read-only preactivation inventory on the P3-restored rc.12 VM.

All product modules originate from the independently checked installed release.
No DNS/API queries, Box object access, SMTP, service/timer/package/firewall
activation, Caddy render, promotion, backup, reboot or Docker socket startup.
The only persistent write is a root-private, sanitized operator summary.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import importlib.util
import json
import os
import platform
import pwd
import re
import stat
import sys
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-6-vnic"
VERSION = "0.1.0-rc.12"
CHECKOUT = Path(__file__).resolve().parents[2]
INSTALLED = Path("/opt/vaultwarden-oci/releases") / VERSION
CURRENT = Path("/opt/vaultwarden-oci/current")
STATE = Path("/var/lib/vaultwarden-oci")
P1_SCRIPT = Path(__file__).resolve().with_name("production-recovery-source-preflight.py")
P2_SCRIPT = Path(__file__).resolve().with_name("production-cryptographic-readiness.py")
EXPECTED_REMOTE = "bw-backup:bw-backup"
EXPECTED_RECIPIENT_DIGEST = "7d08721bcc02bbef7dae1f07bfde244852560c69d0b72f8dc0fcba0da30c6773"
EXPECTED_UUID = "75ceee68-0fff-4f74-b629-4e22b3b99c20"
CRITICAL_UNITS = (
    "vaultwarden-oci.target",
    "vaultwarden-oci.service",
    "vaultwarden-oci-health.timer",
    "vaultwarden-oci-backup.timer",
    "vaultwarden-oci-maintenance.timer",
    "vaultwarden-oci-update-check.timer",
    "vaultwarden-oci-dns.service",
)


def source_module(path: Path, label: str):
    spec = importlib.util.spec_from_file_location(label, path)
    if spec is None or spec.loader is None:
        raise RuntimeError("required read-only acceptance helper unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def private_evidence() -> Path:
    if os.geteuid() != 0 or os.environ.get("SUDO_USER") != "ubuntu":
        raise RuntimeError("only sudo from original ubuntu operator permitted")
    user = pwd.getpwnam("ubuntu")
    home = Path(user.pw_dir)
    if home.is_symlink() or not home.is_dir():
        raise RuntimeError("operator home is unsafe")
    root = home / "vwoci-acceptance"
    if root.is_symlink():
        raise RuntimeError("acceptance evidence directory symlink refused")
    if not root.exists():
        root.mkdir(mode=0o700)
    info = root.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in {0, user.pw_uid}
            or stat.S_IMODE(info.st_mode) & 0o077):
        raise RuntimeError("acceptance evidence directory is not private")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = root / f"p4-postrestore-preactivation-{stamp}-{os.getpid()}"
    out.mkdir(mode=0o700)
    return out


class Gate:
    def __init__(self, evidence: Path) -> None:
        self.evidence = evidence
        self.rows: list[tuple[str, str]] = []
        self.blocked = False
        self.pending = False

    def record(self, classification: str, message: str) -> None:
        if classification not in {"PASS", "PENDING", "BLOCKED", "NOT RUN"}:
            raise ValueError("invalid classification")
        if "\n" in message or "\r" in message:
            raise ValueError("multiline evidence rejected")
        self.blocked |= classification == "BLOCKED"
        self.pending |= classification == "PENDING"
        self.rows.append((classification, message))

    def finish(self) -> int:
        result = "BLOCKED" if self.blocked else "HOLD" if self.pending else "HOLD"
        self.rows.append((result, "P4 preactivation survey only; no live startup or production cutover authorized"))
        summary = "Gate P4 - restored rc.12 preactivation and security inventory (read-only)\n"
        summary += "\n".join(f"{status:<8} {message}" for status, message in self.rows) + "\n"
        (self.evidence / "summary.txt").write_text(summary, encoding="utf-8")
        print(summary, end="")
        print("Private summary:", self.evidence / "summary.txt")
        print("Paste only this summary; do not share keys, configuration files, raw doctor JSON or journals.")
        return 2 if self.blocked else 0


def private_directory(path: Path, owner: int, expected_device: int) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    return (stat.S_ISDIR(info.st_mode) and info.st_uid == owner
            and stat.S_IMODE(info.st_mode) == 0o700 and info.st_dev == expected_device)


def private_sqlite(path: Path, owner: int, expected_device: int) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    return (stat.S_ISREG(info.st_mode) and info.st_size > 100
            and info.st_uid == owner and stat.S_IMODE(info.st_mode) == 0o600
            and info.st_dev == expected_device)


def effective_unstarted(states: dict[str, dict[str, str]], *, dropins: dict[str, str]) -> bool:
    if set(states) != set(CRITICAL_UNITS) or set(dropins) != set(CRITICAL_UNITS):
        return False
    for name in CRITICAL_UNITS:
        fields = states[name]
        if fields.get("LoadState") != "loaded" or fields.get("ActiveState") != "inactive":
            return False
        expected = "static" if name.endswith("-dns.service") else "disabled"
        if fields.get("UnitFileState") != expected or dropins[name].strip():
            return False
    return True


def doctor_statuses(output: str, exit_code: int | None, expected_ids: tuple[str, ...]) -> dict[str, str] | None:
    """Allowlisted IDs only; reject malformed/truncated/duplicate checks."""
    try:
        if exit_code not in {0, 1} or len(output) > 128 * 1024:
            return None
        payload = json.loads(output)
        if payload.get("schema_version") != 1 or not isinstance(payload.get("checks"), list):
            return None
        checks: dict[str, str] = {}
        for entry in payload["checks"]:
            name, status = entry["id"], entry["status"]
            if name not in expected_ids or name in checks or status not in {"PASS", "FAIL", "SKIP", "WARN"}:
                return None
            checks[name] = status
        if set(checks) != set(expected_ids):
            return None
        overall = "FAIL" if "FAIL" in checks.values() else "WARN" if "WARN" in checks.values() else (
            "SKIP" if set(checks.values()) == {"SKIP"} else "PASS"
        )
        if payload.get("overall") != overall or (exit_code == 0) != (overall != "FAIL"):
            return None
        return checks
    except (TypeError, KeyError, AttributeError, ValueError):
        return None


def missing_required_service_dependencies(states: dict[str, dict[str, str]]) -> tuple[str, ...]:
    return tuple(sorted(name for name, props in states.items() if (
        props.get("LoadState") != "loaded" or props.get("ActiveState") != "active"
    )))


def main() -> int:
    if len(sys.argv) != 1 or os.geteuid() != 0:
        print("BLOCKED: run via sudo -n as ubuntu with no arguments", file=sys.stderr)
        return 2
    try:
        evidence = private_evidence()
    except (OSError, KeyError, RuntimeError):
        print("BLOCKED: cannot open private acceptance evidence directory", file=sys.stderr)
        return 2
    gate = Gate(evidence)
    phase = "host identity"
    try:
        if (platform.node().split(".")[0] != HOST
                or platform.machine() not in {"aarch64", "arm64"}
                or sys.version_info[:2] != (3, 14)):
            gate.record("BLOCKED", "Unexpected host, CPU, or Python interpreter")
            return gate.finish()
        gate.record("PASS", "Original Ubuntu ARM64 Python 3.14 acceptance host")
        phase = "immutable release"
        if not CURRENT.is_symlink() or CURRENT.resolve(strict=True) != INSTALLED:
            gate.record("BLOCKED", "Installed rc.12 pointer changed")
            return gate.finish()
        p1 = source_module(P1_SCRIPT, "p4_p1_source")
        p2 = source_module(P2_SCRIPT, "p4_p2_source")
        ok, file_count = p1.release_integrity(CHECKOUT, INSTALLED)
        if not ok:
            gate.record("BLOCKED", "Installed immutable release differs from approved reviewed source")
            return gate.finish()
        sys.path.insert(0, str(INSTALLED))
        if not p1.systemd_unit_integrity(INSTALLED)[0]:
            gate.record("BLOCKED", "Installed systemd unit content differs from approved release")
            return gate.finish()
        gate.record("PASS", f"Installed rc.12 file integrity ({file_count}) and all systemd units reverified")
        from vaultwarden_oci import cli, runtime, secrets, storage
        phase = "dedicated restored state"
        identity = storage.verify()
        if (identity.uuid != EXPECTED_UUID or identity.fs_type != "ext4"
                or p1.EXPECTED_BYID.resolve(strict=True) != Path(identity.source).resolve(strict=True)):
            gate.record("BLOCKED", "Original dedicated ext4 data volume or ownership markers changed")
            return gate.finish()
        storage.reject_boot_related(identity.source)
        filesystem = STATE.stat().st_dev
        gate.record("PASS", "Original by-id data volume, root separation, ext4 UUID and dual markers verified")
        db = STATE / "data/db.sqlite3"
        if not (private_directory(STATE / "data", runtime.VAULTWARDEN_UID, filesystem)
                and private_sqlite(db, runtime.VAULTWARDEN_UID, filesystem)
                and p2.sqlite_snapshot_integrity(db)):
            gate.record("BLOCKED", "Post-P3 SQLite missing, malformed, unsafe or not on the owned dedicated volume")
            return gate.finish()
        try:
            digest = hashlib.sha256(db.read_bytes()).hexdigest()
            db_size = db.stat().st_size
        except OSError:
            gate.record("BLOCKED", "Restored SQLite cannot be hashed")
            return gate.finish()
        gate.record("PASS", f"Restored Vaultwarden SQLite full integrity verified; bytes={db_size} SHA-256={digest}")
        caddy_paths = (STATE / "caddy/data", STATE / "caddy/config")
        if not all(private_directory(path, runtime.CADDY_UID, filesystem) for path in caddy_paths):
            gate.record("BLOCKED", "Restored Caddy data/config ownership, permission or volume identity invalid")
            return gate.finish()
        gate.record("PASS", "Restored Caddy data/config ownership and private directories verified")

        phase = "restored operational secrets and policy"
        config = runtime.load_config()
        if not p1.matches_offline_recipient(config.offline_recovery_recipient):
            gate.record("BLOCKED", "Restored offline public Age recipient changed from accepted custody")
            return gate.finish()
        try:
            values = secrets.validate_encrypted(config.offline_recovery_recipient)
        except (secrets.SecretsError, OSError):
            gate.record("BLOCKED", "Restored SOPS/operational Age semantic credentials or admin invariant invalid")
            return gate.finish()
        have_remediation = bool(values.get("cloudflare_remediation_token"))
        have_api_mail = bool(values.get("email_api_token"))
        have_admin = secrets.admin_enabled(values)
        del values
        gate.record("PASS", f"Restored required Cloudflare/SMTP credentials, operational Age, SOPS and admin pairing valid; admin_enabled={have_admin}")
        gate.record("PASS" if have_remediation else "PENDING",
                    "Dedicated CrowdSec Cloudflare remediation credential present"
                    if have_remediation else "CrowdSec remediation credential not configured; worker setup cannot proceed")
        if config.smtp_accept_invalid_certs or config.smtp_accept_invalid_hostnames:
            gate.record("BLOCKED", "Restored SMTP permits insecure TLS; review before any mail/start")
            return gate.finish()
        gate.record("PASS", "Restored SMTP certificate and hostname checks enabled; no real SMTP transaction attempted")
        alerts = config.notification_provider is not None
        gate.record("PENDING" if not (alerts and have_api_mail) else "PASS",
                    f"Operational alert provider configured={alerts} API credential present={have_api_mail}; no real notification delivered")
        if (config.offsite_remote != EXPECTED_REMOTE or config.local_retention_days != 0
                or config.remote_retention_days != 0):
            gate.record("BLOCKED", "Restored offsite remote differs from accepted Box destination or retention is nonzero")
            return gate.finish()
        gate.record("PASS", "Restored automatic offsite destination points to accepted Box folder; retention 0/0")
        rc, names = p1.run_readonly(["rclone", "listremotes"], timeout=15)
        gate.record("PASS" if p1.remote_available(names, rc) else "PENDING",
                    "Root Box remote is configured (names only; no Box API access)"
                    if p1.remote_available(names, rc) else "Root Box remote missing or unreadable after restore")

        phase = "automation, security and ports"
        states = {}
        dropins = {}
        for unit in CRITICAL_UNITS:
            props = p1.service_properties(unit)
            if props is None:
                gate.record("BLOCKED", "Cannot query expected installed service/timer state")
                return gate.finish()
            states[unit] = props
            rc, stdout = p1.run_readonly(
                ["systemctl", "show", unit, "--property=DropInPaths", "--value"], timeout=12
            )
            if rc != 0:
                gate.record("BLOCKED", "Cannot query timer/service drop-in state")
                return gate.finish()
            dropins[unit] = stdout
        if not effective_unstarted(states, dropins=dropins):
            gate.record("BLOCKED", "Unexpected started/enabled unit or service/timer drop-in; preserve restored VM")
            return gate.finish()
        gate.record("PASS", "Original appliance, DNS and four timer units remain stopped and disabled with no drop-ins")
        if (STATE / "state/update-recovery-required.json").exists():
            gate.record("BLOCKED", "Update recovery-required guard is present")
            return gate.finish()
        gate.record("PASS", "No update recovery-required guard")
        listeners = p1.listening_ports()
        if listeners is None:
            gate.record("PENDING", "Cannot independently inspect TCP/80 and TCP/443 listener state")
        elif listeners:
            gate.record("BLOCKED", "TCP/80 or TCP/443 listener is already active before authorized startup")
            return gate.finish()
        else:
            gate.record("PASS", "No TCP/80 or TCP/443 listeners before activation")

        docker_active = p1.daemon_running(p1.service_properties("docker.service"))
        if not docker_active:
            gate.record("PENDING", "Docker Engine is not active; no socket-activating CLI inspection performed")
        else:
            rc, result = p1.run_readonly([
                "docker", "ps", "--filter", "name=^vaultwarden-oci-",
                "--format", "{{.ID}}"], timeout=20
            )
            if rc != 0 or result.strip():
                gate.record("BLOCKED", "Unexpected running appliance container or Docker inspection failed")
                return gate.finish()
            gate.record("PASS", "Docker already active and no appliance containers running")
        security_units = (
            "crowdsec.service",
            "crowdsec-firewall-bouncer.service",
            "crowdsec-cloudflare-worker-bouncer.service",
        )
        security = {}
        for unit in security_units:
            security[unit] = p1.service_properties(unit) or {
                "LoadState": "unknown", "ActiveState": "unknown", "UnitFileState": "unknown"
            }
        worker = security["crowdsec-cloudflare-worker-bouncer.service"]
        if worker.get("ActiveState") in {"active", "activating", "reloading"}:
            gate.record("BLOCKED", "Cloudflare Worker unexpectedly activated without the next gate's invocation/Fail Open proof")
            return gate.finish()
        missing_security = missing_required_service_dependencies(security)
        gate.record("PENDING" if missing_security else "PASS",
                    f"Security engine/firewall/worker deploy state: units_ready={3-len(missing_security)}/3; Worker remains dormant (required until explicit authorization)")
        cli_bins = ("cscli", "crowdsec-firewall-bouncer", "iptables", "ip6tables",
                    "nft", "7zz", "rclone", "sops", "age", "docker")
        import shutil
        missing_bins = [name for name in cli_bins if shutil.which(name) is None]
        gate.record("PENDING" if missing_bins else "PASS",
                    "Dependency inventory missing: " + ",".join(missing_bins)
                    if missing_bins else "Security/recovery dependency binaries all present (presence only)")
        rc, package_audit = p1.run_readonly(["dpkg", "--audit"], timeout=30)
        gate.record("PASS" if rc == 0 and not package_audit.strip() else "PENDING",
                    "dpkg state clean" if rc == 0 and not package_audit.strip()
                    else "Package database requires review; no apt changes executed")
        rc, time_value = p1.run_readonly(["timedatectl", "show", "-p", "NTPSynchronized", "--value"], timeout=12)
        gate.record("PASS" if rc == 0 and time_value.strip() == "yes" else "PENDING",
                    "NTP synchronized" if rc == 0 and time_value.strip() == "yes" else "NTP not confirmed")
        gate.record("PASS" if not Path("/var/run/reboot-required").exists() else "PENDING",
                    "No Ubuntu reboot-required marker" if not Path("/var/run/reboot-required").exists()
                    else "Reboot required; cannot reboot as part of this gate")

        phase = "sanitized product doctor"
        if docker_active:
            rc, stdout = p1.run_readonly(
                [sys.executable, "-B", "-E", str(INSTALLED / "vwctl"), "doctor", "--json"],
                timeout=100,
            )
            parsed = doctor_statuses(stdout, rc, tuple(cli.DOCTOR_CHECK_IDS))
            if parsed is None:
                gate.record("PENDING", "Product doctor could not be safely parsed; no diagnostic values published")
            else:
                passed = sorted(name for name, value in parsed.items() if value == "PASS")
                fails = sorted(name for name, value in parsed.items() if value == "FAIL")
                gate.record("PENDING" if fails else "PASS",
                            f"Stopped-system doctor: PASS={len(passed)} FAIL={len(fails)}; failing_ids="
                            + (",".join(fails) if fails else "none"))
                gate.record("PENDING", "Doctor failures caused by deliberately unactivated security/runtime require separate, consented security gate")
        else:
            gate.record("NOT RUN", "Docker-backed doctor deferred to avoid socket-start side effects")
        backup_class, backup_summary = p1.local_recovery_inventory(STATE)
        gate.record(backup_class, "Current local .vwrec inventory: "+backup_summary)
        gate.record("PENDING", "Restored offsite destination is the existing Box folder; select an isolated test prefix before authorizing any new backup")
        gate.record("PENDING", "OCI public ingress/NSG and public-hostname isolation require operator Console attestation")
        gate.record("PENDING", "Cloudflare Worker Routes Fail Open must be attested for the next actual Worker invocation, never inherited")
        gate.record("NOT RUN", "External DNS/Cloudflare API query or write, app/Caddy TLS, CrowdSec setup/Worker, SMTP, authenticated browser/client")
        gate.record("NOT RUN", "Any new backup, Box upload/prune, timer activation, update/rollback, reboot or production cutover")
        return gate.finish()
    except Exception:
        gate.record("BLOCKED", f"Unexpected error during {phase}; raw exception details withheld")
        return gate.finish()


if __name__ == "__main__":
    raise SystemExit(main())
