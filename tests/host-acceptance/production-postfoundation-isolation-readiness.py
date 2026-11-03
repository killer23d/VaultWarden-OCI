#!/usr/bin/env python3
"""P6: read-only post-P5 security and isolated-start readiness (disposable VM).

This acceptance step is deliberately unable to start the restored vault. The
configured hostname is shared, and a supported first start may fetch Cloudflare
CIDRs, request a DNS-01 certificate, and expose the origin. A separate approval
must verify OCI ingress isolation and the current Worker invocation's Fail Open.
No Cloudflare/Box/SMTP API call, package change, service start or timer action.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import os
import platform
import pwd
import stat
import sys
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-6-vnic"
RELEASE = "0.1.0-rc.12"
BASE = Path(__file__).resolve().parents[2]
INSTALLED = Path("/opt/vaultwarden-oci/releases") / RELEASE
CURRENT = Path("/opt/vaultwarden-oci/current")
P5_SCRIPT = Path(__file__).resolve().with_name("production-security-foundation-consent.py")
EXPECTED_SHARED_DOMAIN = "bw.lazymocha.com"
FOUNDATION_IDS = (
    "edge.cloudflare.cidrs",
    "edge.cloudflare.iptables",
    "crowdsec.engine",
    "crowdsec.hub",
    "crowdsec.firewall",
)
EXPECTED_STOPPED_FAILS = frozenset(("crowdsec.cloudflare", "runtime.paths"))
APPLIANCE_UNIT = "vaultwarden-oci.target"
SECURITY_SERVICE_UNITS = ("crowdsec.service", "crowdsec-firewall-bouncer.service")
WORKER_UNIT = "crowdsec-cloudflare-worker-bouncer.service"


def load_source(path: Path, label: str):
    spec = importlib.util.spec_from_file_location(label, path)
    if spec is None or spec.loader is None:
        raise RuntimeError("approved acceptance helper not found")
    instance = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(instance)
    return instance


def private_evidence() -> Path:
    if os.geteuid() != 0 or os.environ.get("SUDO_USER") != "ubuntu":
        raise RuntimeError("requires sudo -n by ubuntu")
    operator = pwd.getpwnam("ubuntu")
    home = Path(operator.pw_dir)
    base = home / "vwoci-acceptance"
    if home.is_symlink() or not home.is_dir() or base.is_symlink():
        raise RuntimeError("unsafe operator evidence parent")
    info = base.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in {0, operator.pw_uid}
            or stat.S_IMODE(info.st_mode) & 0o077):
        raise RuntimeError("evidence parent not private")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    evidence = base / f"p6-postfoundation-readiness-{stamp}-{os.getpid()}"
    evidence.mkdir(mode=0o700)
    return evidence


class Report:
    def __init__(self, evidence: Path):
        self.evidence = evidence
        self.rows: list[tuple[str, str]] = []
        self.blocked = False

    def add(self, status: str, message: str) -> None:
        if status not in {"PASS", "PENDING", "BLOCKED", "NOT RUN"} or "\n" in message or "\r" in message:
            raise ValueError("unsafe summary entry")
        self.rows.append((status, message))
        self.blocked |= status == "BLOCKED"

    def finish(self) -> int:
        outcome = "BLOCKED" if self.blocked else "HOLD"
        self.rows.append((outcome, "P6 read-only isolation planning; live startup and production cutover NOT AUTHORIZED"))
        summary = "Gate P6 - post-foundation rc.12 isolated-start readiness (read-only)\n"
        summary += "\n".join(f"{kind:<10} {message}" for kind, message in self.rows) + "\n"
        (self.evidence / "summary.txt").write_text(summary, encoding="utf-8")
        print(summary, end="")
        print("Private summary:", self.evidence / "summary.txt")
        print("Share only this summary; never share raw doctor output, credentials or private logs.")
        return 2 if self.blocked else 0


def evaluate_stopped_doctor(checks: dict[str, str], paths_status: str) -> tuple[bool, str]:
    """Require five active foundation checks and coherent pre-start exceptions.

    The source doctor parser validates all 27 IDs and overall/exit status first.
    This secondary check rejects any new FAIL rather than treating all failures
    as an expected consequence of deliberately leaving Caddy/Worker stopped.
    """
    not_passing = tuple(sorted(k for k in (*FOUNDATION_IDS, "storage.dedicated")
                               if checks.get(k) != "PASS"))
    if not_passing:
        return False, "required_foundation_not_pass=" + ",".join(not_passing)
    if checks.get("crowdsec.cloudflare") != "FAIL":
        return False, "dormant_worker_doctor_inconsistent"
    if paths_status not in {"PASS", "PENDING"}:
        return False, "runtime_paths_unsafe_or_unknown"
    if (checks.get("runtime.paths") == "PASS") != (paths_status == "PASS"):
        return False, "runtime_paths_doctor_inventory_disagree"
    unexpected = sorted(k for k, v in checks.items()
                        if v == "FAIL" and k not in EXPECTED_STOPPED_FAILS)
    if unexpected:
        return False, "unexpected_stopped_doctor_failure_ids=" + ",".join(unexpected)
    return True, "only_expected_prestart_failures"


def expected_security_units(p1) -> bool:
    for name in SECURITY_SERVICE_UNITS:
        state = p1.service_properties(name)
        if (state is None or state.get("LoadState") != "loaded"
                or state.get("ActiveState") != "active"
                or state.get("UnitFileState") != "enabled"):
            return False
    worker = p1.service_properties(WORKER_UNIT)
    return (worker is not None and worker.get("LoadState") == "loaded"
            and worker.get("ActiveState") == "inactive"
            and worker.get("UnitFileState") == "disabled")


def main() -> int:
    if sys.argv[1:] or os.geteuid() != 0 or os.environ.get("SUDO_USER") != "ubuntu":
        print("BLOCKED: run without arguments using sudo -n as ubuntu", file=sys.stderr)
        return 2
    try:
        out = private_evidence()
    except (OSError, KeyError, RuntimeError):
        print("BLOCKED: cannot create private P6 evidence directory", file=sys.stderr)
        return 2
    report = Report(out)
    phase = "host and approved source"
    try:
        if (platform.node().split(".")[0] != HOST
                or platform.machine() not in {"aarch64", "arm64"}
                or sys.version_info[:2] != (3, 14)):
            report.add("BLOCKED", "Host/CPU/Python differs from accepted Ubuntu 26.04 ARM64 VM")
            return report.finish()
        if not CURRENT.is_symlink() or CURRENT.resolve(strict=True) != INSTALLED:
            report.add("BLOCKED", "Selected immutable rc.12 pointer changed")
            return report.finish()
        p5 = load_source(P5_SCRIPT, "p6_reviewed_p5")
        p1 = p5.module(p5.P1, "p6_reviewed_p1")
        p4 = p5.module(p5.P4, "p6_reviewed_p4")
        match, count = p1.release_integrity(BASE, INSTALLED)
        if not match:
            report.add("BLOCKED", "Immutable rc.12 release differs from reviewed source")
            return report.finish()
        sys.path.insert(0, str(INSTALLED))
        unit_ok, unit_count = p1.systemd_unit_integrity(INSTALLED)
        if not unit_ok:
            report.add("BLOCKED", "Installed systemd unit definitions differ from rc.12")
            return report.finish()
        report.add("PASS", f"Approved immutable rc.12 release files={count}, systemd_units={unit_count}, Ubuntu ARM64 identity")
        from vaultwarden_oci import runtime, secrets, storage

        phase = "restored app/data and host isolation"
        if not p5.exact_isolation(p1, p4, storage, expect_security_installed=True):
            report.add("BLOCKED", "Original dedicated volume/SQLite, dormant app/ports/timers, Docker or Worker isolation differs")
            return report.finish()
        report.add("PASS", "Original disk and restored SQLite SHA unchanged; no app containers, listeners, DNS or four timers")
        cfg = runtime.load_config()
        if (cfg.domain != EXPECTED_SHARED_DOMAIN
                or not p1.matches_offline_recipient(cfg.offline_recovery_recipient)
                or cfg.offsite_remote != p5.EXPECTED_REMOTE
                or cfg.local_retention_days != 0 or cfg.remote_retention_days != 0
                or cfg.smtp_accept_invalid_certs or cfg.smtp_accept_invalid_hostnames):
            report.add("BLOCKED", "Restored domain/recipient/SMTP TLS/Box no-prune configuration differs")
            return report.finish()
        values = secrets.validate_encrypted(cfg.offline_recovery_recipient)
        allowed = (secrets.admin_enabled(values)
                   and bool(values.get("cloudflare_remediation_token")))
        del values
        if not allowed:
            report.add("BLOCKED", "Restored operational SOPS, CrowdSec remediation or admin-pairing invalid")
            return report.finish()
        report.add("PASS", "SOPS, offline recipient, admin pairing and SMTP certificate/hostname validation intact")
        report.add("PASS", "Saved Box destination and zero retention unchanged; no Box remote access or publication")

        phase = "post-foundation units and doctor"
        if not expected_security_units(p1):
            report.add("BLOCKED", "CrowdSec engine/host bouncer not enabled+active or Worker not disabled+inactive")
            return report.finish()
        report.add("PASS", "CrowdSec engine and INPUT bouncer active+enabled; Worker disabled+inactive")
        diagnosis, checks, shape = p5.diagnose_doctor(out, "post-foundation")
        if diagnosis != "valid":
            report.add("BLOCKED", "Installed 27-ID doctor invalid: " + diagnosis + "; " + shape)
            return report.finish()
        if len(checks) != 27:
            report.add("BLOCKED", "Expected complete 27-check installed product doctor registry")
            return report.finish()
        paths_status, paths_summary = p5.inspect_stopped_runtime_paths(runtime, secrets)
        report.add(paths_status, "Stopped runtime path metadata: " + paths_summary)
        result, why = evaluate_stopped_doctor(checks, paths_status)
        if not result:
            report.add("BLOCKED", "Post-foundation product doctor inconsistent: " + why)
            return report.finish()
        report.add("PASS", "Five P5 security doctor controls and dedicated-storage doctor PASS")
        report.add("PENDING", "Worker/current-invocation Fail Open and generated startup paths remain unverified by design")

        phase = "host continuity"
        code, audit = p1.run_readonly(["dpkg", "--audit"], timeout=30)
        if code != 0 or audit.strip():
            report.add("BLOCKED", "dpkg reports a partial package state after P5")
            return report.finish()
        report.add("PASS", "Post-P5 package database audit clean")
        code, ntp = p1.run_readonly(["timedatectl", "show", "-p", "NTPSynchronized", "--value"], timeout=12)
        report.add("PASS" if code == 0 and ntp.strip() == "yes" else "PENDING",
                   "NTP synchronized" if code == 0 and ntp.strip() == "yes" else "NTP not confirmed")
        report.add("PENDING" if Path("/var/run/reboot-required").exists() else "PASS",
                   "Reboot marker present; separate approval needed" if Path("/var/run/reboot-required").exists()
                   else "No reboot-required marker")

        phase = "external boundary"
        if not p5.exact_isolation(p1, p4, storage, expect_security_installed=True):
            report.add("BLOCKED", "App/port/Worker/volume isolation changed during read-only P6")
            return report.finish()
        report.add("PENDING", "Shared public hostname is configured; separate dev origin/hostname or explicit shared-hostname authority is needed")
        report.add("PENDING", "OCI Console public IP, NSG/security lists and restricted inbound ingress require independent operator attestation")
        report.add("PENDING", "Current Cloudflare Worker Routes must be verified Fail Open after any separately authorized invocation")
        report.add("PENDING", "Original encrypted recovery kit, private Age identity and separate passphrase require independent off-host custody attestation")
        report.add("NOT RUN", "No DNS/Cloudflare/Worker API, certificate DNS-01, Vaultwarden/Caddy start, login, SMTP, Box or timers")
        report.add("NOT RUN", "No host package/firewall changes, restore, timer activation, reboot, rollback or production cutover")
        return report.finish()
    except Exception:
        report.add("BLOCKED", f"Uncertain P6 failure during {phase}; raw exception and credentials withheld")
        return report.finish()


if __name__ == "__main__":
    raise SystemExit(main())
