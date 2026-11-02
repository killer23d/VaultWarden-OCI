#!/usr/bin/env python3
"""P5: explicitly consented security foundation on the P3-restored disposable VM.

Before consent: read-only P4 + sanitized doctor diagnostics.
After exact typed consent: installed product-owned Cloudflare CIDR ingress policy,
CrowdSec engine and host-INPUT bouncer setup. Never starts the Cloudflare Worker,
Vaultwarden/Caddy, timers, sends mail, changes DNS, or touches Box objects.
A failure AFTER first mutation is a partial-state HOLD: never auto-retry.
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
import signal
import stat
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-6-vnic"
VERSION = "0.1.0-rc.12"
SRC = Path(__file__).resolve().parents[2]
INSTALLED = Path("/opt/vaultwarden-oci/releases") / VERSION
CURRENT = Path("/opt/vaultwarden-oci/current")
STATE = Path("/var/lib/vaultwarden-oci")
P4 = Path(__file__).resolve().with_name("production-postrestore-preactivation.py")
P1 = Path(__file__).resolve().with_name("production-recovery-source-preflight.py")
DB_SHA = "075163445a045cf274f7b1bf52ecb4f8f90b460cf13de418664c1c60cbfe9a35"
EXPECTED_REMOTE = "bw-backup:bw-backup"
CONSENT = "SECURITY FOUNDATION vaultwarden-oci-6-vnic OCI CONSOLE READY"
REQUIRED_DOCTOR = (
    "edge.cloudflare.cidrs",
    "edge.cloudflare.iptables",
    "crowdsec.engine",
    "crowdsec.hub",
    "crowdsec.firewall",
)
SECURITY_UNITS = (
    "crowdsec.service",
    "crowdsec-firewall-bouncer.service",
    "crowdsec-cloudflare-worker-bouncer.service",
)


def module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if not spec or not spec.loader:
        raise RuntimeError("missing approved source helper")
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


def evidence_root() -> Path:
    if os.geteuid() != 0 or os.environ.get("SUDO_USER") != "ubuntu":
        raise RuntimeError("only sudo from ubuntu may execute P5")
    home = Path(pwd.getpwnam("ubuntu").pw_dir)
    if home.is_symlink() or not home.is_dir():
        raise RuntimeError("unsafe home")
    base = home / "vwoci-acceptance"
    if base.is_symlink():
        raise RuntimeError("evidence symlink")
    if not base.exists():
        base.mkdir(mode=0o700)
    info = base.lstat()
    if (not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077
            or info.st_uid not in {0, pwd.getpwnam("ubuntu").pw_uid}):
        raise RuntimeError("evidence root not private")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = base / f"p5-security-foundation-{stamp}-{os.getpid()}"
    output.mkdir(mode=0o700)
    return output


class Gate:
    def __init__(self, output: Path):
        self.output = output
        self.rows: list[tuple[str, str]] = []
        self.mutation_started = False
        self.verified = False
        self.cancelled = False
        self.blocked = False

    def add(self, status: str, message: str) -> None:
        if status not in {"PASS", "PENDING", "BLOCKED", "NOT RUN"} or "\r" in message or "\n" in message:
            raise ValueError("unsafe report")
        self.rows.append((status, message))
        self.blocked = self.blocked or status == "BLOCKED"

    def finish(self) -> int:
        if self.mutation_started and not self.verified:
            status, code = "HOLD", 2
            self.rows.append(("BLOCKED", "Partial host security state possible; preserve VM, never rerun setup automatically"))
        elif self.blocked:
            status, code = "BLOCKED", 2
        elif self.verified:
            status, code = "FOUNDATION", 0
        else:
            status, code = ("CANCELLED" if self.cancelled else "HOLD"), 0
        self.rows.append((status, "P5 local foundation only; live Vaultwarden and production cutover NOT AUTHORIZED"))
        summary = "Gate P5 - consented disposable VM Cloudflare origin and CrowdSec foundation\n"
        summary += "\n".join(f"{status:<10} {message}" for status, message in self.rows) + "\n"
        (self.output / "summary.txt").write_text(summary, encoding="utf-8")
        print(summary, end="")
        print("Private summary:", self.output / "summary.txt")
        print("Paste summary only; do not share private logs, tokens, configuration or raw doctor output.")
        return code


def check_consent(value: str) -> bool:
    return value == CONSENT


def class_doctor(data: str, return_code: int | None, allowed_ids: tuple[str, ...]) -> tuple[str, dict[str, str]]:
    """Parse only safe schema/check IDs; never expose messages or source bytes."""
    if return_code is None:
        return "command_unavailable_or_timeout", {}
    if return_code not in (0, 1):
        return "unexpected_exit_status", {}
    if not data.strip():
        return "empty_stdout", {}
    if len(data) > 256 * 1024:
        return "oversized_stdout", {}
    try:
        payload = json.loads(data)
    except (json.JSONDecodeError, ValueError, TypeError):
        return "non_json_stdout", {}
    if not isinstance(payload, dict) or payload.get("schema_version") != 1 or not isinstance(payload.get("checks"), list):
        return "invalid_schema", {}
    checks: dict[str, str] = {}
    for entry in payload["checks"]:
        if not isinstance(entry, dict):
            return "invalid_check", {}
        name, status = entry.get("id"), entry.get("status")
        if name not in allowed_ids or name in checks or status not in {"PASS", "WARN", "FAIL", "SKIP"}:
            return "unexpected_or_duplicate_check_id", {}
        checks[name] = status
    if set(checks) != set(allowed_ids):
        return "missing_check_ids", {}
    overall = ("FAIL" if "FAIL" in checks.values() else "WARN" if "WARN" in checks.values()
               else "SKIP" if set(checks.values()) == {"SKIP"} else "PASS")
    if payload.get("overall") != overall or (return_code == 0) != (overall != "FAIL"):
        return "inconsistent_overall_or_exit", {}
    return "valid", checks


def run_private(args: list[str], output: Path, label: str, seconds: int, *, env: dict[str, str] | None = None) -> int | None:
    """Raw tool stdout/stderr is never printed or added to the safe summary."""
    if not re.fullmatch(r"[a-z0-9_-]{1,64}", label):
        raise ValueError("unsafe private log name")
    path = output / f"{label}.private.log"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    with os.fdopen(descriptor, "wb") as log:
        try:
            result = subprocess.run(
                args, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                cwd="/", env=env, timeout=seconds, check=False,
            )
            return result.returncode
        except (OSError, subprocess.TimeoutExpired):
            return None


def diagnose_doctor(output: Path, label: str, *, seconds: int = 120) -> tuple[str, dict[str, str]]:
    """Inspect installed doctor without exposing potential private error messages."""
    from vaultwarden_oci import cli
    try:
        run = subprocess.run(
            [sys.executable, "-B", "-E", str(INSTALLED / "vwctl"), "doctor", "--json"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
            cwd="/", check=False, timeout=seconds,
        )
        # Never persist doctor text: operational messages can contain secrets.
        raw = run.stdout[:256 * 1024 + 1].decode("utf-8", "replace")
        return class_doctor(raw, run.returncode, tuple(cli.DOCTOR_CHECK_IDS))
    except (OSError, subprocess.TimeoutExpired):
        return "command_unavailable_or_timeout", {}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def exact_isolation(p1, p4, storage, *, expect_security_installed: bool) -> bool:
    if not CURRENT.is_symlink() or CURRENT.resolve(strict=True) != INSTALLED:
        return False
    identity = storage.verify()
    if identity.uuid != p1.EXPECTED_VOLUME_UUID or p1.EXPECTED_BYID.resolve(strict=True) != Path(identity.source).resolve(strict=True):
        return False
    states: dict[str, dict[str, str]] = {}
    dropins: dict[str, str] = {}
    for unit in p4.CRITICAL_UNITS:
        props = p1.service_properties(unit)
        if props is None:
            return False
        states[unit] = props
        code, value = p1.run_readonly(["systemctl", "show", unit, "-p", "DropInPaths", "--value"], timeout=12)
        if code != 0:
            return False
        dropins[unit] = value
    if not p4.effective_unstarted(states, dropins=dropins):
        return False
    if (STATE / "state/update-recovery-required.json").exists() or sha256_file(STATE / "data/db.sqlite3") != DB_SHA:
        return False
    if p1.listening_ports() != set():
        return False
    if not p1.daemon_running(p1.service_properties("docker.service")):
        return False
    code, running = p1.run_readonly(
        ["docker", "ps", "--filter", "name=^vaultwarden-oci-", "--format", "{{.ID}}"], timeout=20
    )
    if code != 0 or running.strip():
        return False
    worker = p1.service_properties("crowdsec-cloudflare-worker-bouncer.service")
    if worker is None or worker.get("ActiveState") in {"active", "activating", "reloading"}:
        return False
    if expect_security_installed:
        if worker.get("ActiveState") != "inactive" or worker.get("UnitFileState") != "disabled":
            return False
    else:
        if any((p1.service_properties(unit) or {}).get("LoadState") == "loaded" for unit in SECURITY_UNITS):
            return False
        if Path("/usr/bin/cscli").exists():
            return False
    return True


def main() -> int:
    if len(sys.argv) != 1 or os.geteuid() != 0 or not (sys.stdin.isatty() and sys.stdout.isatty()):
        print("BLOCKED: sudo -n from ubuntu in interactive terminal is required", file=sys.stderr)
        return 2
    try:
        out = evidence_root()
    except (OSError, KeyError, RuntimeError):
        print("BLOCKED: root-private acceptance directory unavailable", file=sys.stderr)
        return 2
    gate = Gate(out)
    phase = "initial host and release"
    deferred: list[int] = []
    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    saved = {item: signal.getsignal(item) for item in signals}

    def stopped(signum, frame):
        raise KeyboardInterrupt()
    def defer(signum, frame):
        deferred.append(signum)

    for sig in signals:
        signal.signal(sig, stopped)
    try:
        if platform.node().split(".")[0] != HOST or platform.machine() not in {"aarch64", "arm64"} or sys.version_info[:2] != (3, 14):
            gate.add("BLOCKED", "Host architecture/Python differs from approved Ubuntu 26.04 ARM64 VM")
            return gate.finish()
        if not CURRENT.is_symlink() or CURRENT.resolve(strict=True) != INSTALLED:
            gate.add("BLOCKED", "Installed rc.12 release pointer differs")
            return gate.finish()
        p1 = module(P1, "p5_p1_reader")
        p4 = module(P4, "p5_p4_reader")
        if not p1.release_integrity(SRC, INSTALLED)[0]:
            gate.add("BLOCKED", "Installed immutable release differs from reviewed source")
            return gate.finish()
        sys.path.insert(0, str(INSTALLED))
        if not p1.systemd_unit_integrity(INSTALLED)[0]:
            gate.add("BLOCKED", "Installed immutable systemd units changed")
            return gate.finish()
        from vaultwarden_oci import runtime, secrets, storage
        if not exact_isolation(p1, p4, storage, expect_security_installed=False):
            gate.add("BLOCKED", "Pre-foundation original disk/SQLite/service/Docker/security state changed")
            return gate.finish()
        cfg = runtime.load_config()
        if not p1.matches_offline_recipient(cfg.offline_recovery_recipient):
            gate.add("BLOCKED", "Restored public Age recipient differs")
            return gate.finish()
        values = secrets.validate_encrypted(cfg.offline_recovery_recipient)
        remediation_available = bool(values.get("cloudflare_remediation_token"))
        del values
        if not remediation_available or cfg.offsite_remote != EXPECTED_REMOTE or cfg.local_retention_days != 0 or cfg.remote_retention_days != 0:
            gate.add("BLOCKED", "Restored credential, offsite or no-prune boundary changed")
            return gate.finish()
        gate.add("PASS", "Immutable rc.12, original disk and restored SQLite SHA, SOPS and no-prune Box policy verified")
        gate.add("PASS", "All app/DNS/four timers stopped; Docker already active without containers; no HTTPS listener")
        gate.add("PASS", "CrowdSec engine/INPUT bouncer and Cloudflare Worker not previously installed or active")

        phase = "pre-change doctor classification"
        diagnosis, statuses = diagnose_doctor(out, "before")
        gate.add("PASS" if diagnosis == "valid" else "PENDING",
                 "Pre-foundation doctor JSON classification=" + diagnosis
                 + (f" failing_ids={','.join(sorted(k for k, v in statuses.items() if v == 'FAIL'))}"
                    if statuses else " (private error text withheld)"))
        if diagnosis != "valid":
            gate.add("PENDING", "Doctor structural diagnostic unresolved: no firewall, package, or service changes authorized")
            gate.add("NOT RUN", "P5 mutation and activation held before operator consent, pending doctor classification repair")
            return gate.finish()
        gate.add("NOT RUN", "No pre-consent Cloudflare CIDR/firewall, CrowdSec package or runtime mutation")
        print("\n=== SECURITY FOUNDATION: DISPOSABLE VM ONLY ===")
        print("This WILL modify this VM's apt repositories/packages and firewall:")
        print("  - fetch Cloudflare IPv4/IPv6 ranges and apply the Docker-origin HTTPS filter")
        print("  - install CrowdSec engine, detection collections and nftables INPUT-only bouncer")
        print("  - start/enable only the CrowdSec engine and host INPUT bouncer")
        print("Risk: host firewall decisions may interfere with SSH and require OCI serial console access.")
        print("Verify an ACTIVE OCI serial/console access path BEFORE authorizing.")
        print("The public hostname is shared: NO Worker invocation or DNS change is allowed.")
        print("Vaultwarden/Caddy, automation timers, SMTP, remote Box and reboot remain untouched.")
        print("If setup fails after a mutation, preserve the VM and DO NOT re-run automatically.")
        print("Enter the exact phrase below to attest console access and authorize host security:")
        print(CONSENT)
        phase = "explicit operator authorization"
        answer = input("Authorization [CANCEL]: ")
        if not check_consent(answer):
            gate.cancelled = True
            gate.add("PENDING", "Operator declined local firewall/package changes; all appliance data preserved")
            return gate.finish()
        gate.add("PASS", "Operator explicitly authorized disposable-host firewall/apt changes with OCI console attestation")
        if not exact_isolation(p1, p4, storage, expect_security_installed=False):
            gate.add("BLOCKED", "Host changed between consent and proposed security mutation")
            return gate.finish()

        # Product commands alone own changes. Protect the parent against Ctrl-C
        # midway through firewall and apt transactions; unexpected termination
        # or power loss can still leave partial state.
        for sig in signals:
            signal.signal(sig, defer)
        gate.mutation_started = True
        phase = "Cloudflare origin ingress filter"
        edge_code = run_private(
            [sys.executable, "-B", "-E", str(INSTALLED / "vwctl"), "edge", "refresh"],
            out, "edge-refresh", 180,
        )
        if edge_code != 0:
            gate.add("BLOCKED", "Cloudflare-origin firewall refresh failed or timed out; private log retained")
            return gate.finish()
        gate.add("PASS", "Installed product refreshed Cloudflare-only Docker 443 ingress policy")

        phase = "CrowdSec package and host firewall foundation"
        setup_code = run_private(
            [sys.executable, "-B", "-E", str(INSTALLED / "vwctl"), "crowdsec", "setup"],
            out, "crowdsec-setup", 2400,
        )
        if setup_code != 0:
            gate.add("BLOCKED", "Installed CrowdSec setup failed or timed out; private log retained")
            return gate.finish()
        gate.add("PASS", "Installed product set up CrowdSec engine/Hub and host INPUT-only bouncer")

        phase = "post-change isolation and doctor verification"
        if not exact_isolation(p1, p4, storage, expect_security_installed=True):
            gate.add("BLOCKED", "Post-security restored DB, inactive appliance, Worker or isolation proof failed")
            return gate.finish()
        from vaultwarden_oci import cli
        diagnosis, checks = diagnose_doctor(out, "after")
        if diagnosis != "valid":
            gate.add("BLOCKED", "Post-security doctor cannot be safely parsed: "+diagnosis+"; private details retained")
            return gate.finish()
        failed = tuple(sorted(key for key in REQUIRED_DOCTOR if checks.get(key) != "PASS"))
        if failed:
            gate.add("BLOCKED", "Required security foundation doctor checks not PASS: "+",".join(failed))
            return gate.finish()
        gate.add("PASS", "Cloudflare CIDR/iptables and CrowdSec engine/Hub/host INPUT firewall doctor checks all PASS")
        gate.add("PASS", "App/Caddy/DNS/4 timers remain inactive and original restored SQLite SHA unchanged")
        gate.add("PASS", "Cloudflare Worker remains boot-disabled and inactive; no Worker Route changed")
        if deferred:
            gate.add("BLOCKED", "Interrupt deferred during foundational mutation; preserve VM and inspect before next gate")
            return gate.finish()
        gate.add("NOT RUN", "Cloudflare Worker start/Fail Open, Vaultwarden/Caddy, SMTP, DNS/record, timers, Box uploads or reboot")
        gate.add("PENDING", "External OCI ingress isolation and independent offline recovery kit custody still require attestation")
        gate.verified = True
        return gate.finish()
    except KeyboardInterrupt:
        gate.cancelled = not gate.mutation_started
        gate.add("BLOCKED" if gate.mutation_started else "PENDING",
                 f"Interrupted during {phase}; do not automatically retry after any mutation")
        return gate.finish()
    except Exception:
        gate.add("BLOCKED", f"Failure during {phase}; exception and credentials withheld")
        return gate.finish()
    finally:
        for sig, handler in saved.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    raise SystemExit(main())
