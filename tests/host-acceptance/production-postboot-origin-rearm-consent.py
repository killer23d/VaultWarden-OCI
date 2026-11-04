#!/usr/bin/env python3
"""P7R: consent-gated installed-product Cloudflare origin re-arm after real P7 reboot.

Two modes only:
  --diagnose-only: no changes except root-private acceptance evidence.
  --rearm: same strict preflight, explicit OCI-console consent, ONE installed
           'vwctl edge refresh', and an independent full stopped-host readback.

This is not a boot-persistence repair or proof of policy surviving a reboot.
It demonstrates fail-closed product-owned policy re-establishment on a STOPPED
VM. Never invoke Worker, Docker Compose up, DNS, SMTP or offsite operations.
"""
from __future__ import annotations

import datetime as dt
import os
import stat
import sys
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

SOURCE = Path(__file__).resolve().parents[2]
P7_FILE = Path(__file__).resolve().with_name("production-reboot-persistence-consent.py")
HOST = "vaultwarden-oci-6-vnic"
CONSENT = "P7R REARM vaultwarden-oci-6-vnic OCI CONSOLE READY"
ATTEMPT_FILE = "p7r-origin-rearm-attempted.json"
EXPECTED_STOPPED_FAILURE_IDS = frozenset({
    "edge.cloudflare.iptables", "crowdsec.cloudflare", "runtime.paths",
})


def consented(value: str) -> bool:
    return value == CONSENT


def original_p7():
    import importlib.util
    spec = importlib.util.spec_from_file_location("p7r_original_p7", P7_FILE)
    if spec is None or spec.loader is None:
        raise RuntimeError("original P7 acceptance helper missing")
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def new_private_evidence(base: Path) -> Path:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    dest = base / f"p7r-origin-rearm-{stamp}-{os.getpid()}"
    dest.mkdir(mode=0o700)
    return dest


def attempt_path(base: Path) -> Path:
    return base / ATTEMPT_FILE


def record_attempt_once(path: Path, original_boot: str, current_boot: str) -> None:
    """Persist a one-shot barrier before firewall mutation, even if interrupted."""
    import json
    payload = json.dumps({
        "schema": 1, "gate": "p7r-origin-rearm",
        "original_boot": original_boot, "current_boot": current_boot,
    }, sort_keys=True, separators=(",", ":")) + "\n"
    fd = os.open(
        path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())


class Report:
    def __init__(self, output: Path, mode: str):
        self.output, self.mode = output, mode
        self.rows: list[tuple[str, str]] = []
        self.mutation_started = False
        self.verified = False
        self.blocked = False

    def add(self, level: str, message: str) -> None:
        if level not in {"PASS", "PENDING", "NOT RUN", "BLOCKED"} or "\n" in message or "\r" in message:
            raise ValueError("unsafe P7R evidence row")
        self.rows.append((level, message))
        self.blocked |= level == "BLOCKED"

    def finish(self) -> int:
        if self.mutation_started and not self.verified:
            final, code = "HOLD", 2
            self.rows.append(("BLOCKED", "Possible partial firewall mutation; preserve VM, never automatically retry P7R"))
        elif self.blocked:
            final, code = "BLOCKED", 2
        elif self.verified:
            final, code = "REARMED", 0
        else:
            final, code = "HOLD", 0
        self.rows.append((final, "Local postboot re-arm only; reboot firewall persistence and production GO NOT PROVEN"))
        text = f"Gate P7R - post-reboot stopped-host Cloudflare origin policy ({self.mode})\n"
        text += "\n".join(f"{status:<10} {message}" for status, message in self.rows) + "\n"
        filename = self.output / "summary.txt"
        filename.write_text(text, encoding="utf-8")
        print(text, end="")
        print("Private summary:", filename)
        print("Share summary only; no raw doctor, credentials, checkpoint, IP or private logs.")
        return code


def preflight(p7, report: Report) -> tuple[object, dict[str, object], tuple[Path, ...], dict[str, str], dict[str, str]]:
    base = p7.safe_base()
    checkpoint = p7.read_checkpoint(p7.checkpoint_path(base))
    if checkpoint.get("phase") != "reboot-requested":
        raise p7.Blocked("P7 checkpoint does not represent the completed HOLD reboot")
    current_boot = p7.read_boot_id()
    if current_boot == checkpoint["boot_id"]:
        raise p7.Blocked("actual P7 kernel reboot was not proven")
    report.add("PASS", "P7 original root-private checkpoint and a different post-reboot kernel boot ID verified")

    inner = p7.Report(report.output, "p7r-preflight")
    paths, hashes = p7.host_snapshot(inner, after_boot=True)
    p7.verified_hashes(checkpoint, paths, hashes)
    if not any(
        level == "PENDING" and "not persistent across cold boot" in message
        for level, message in inner.rows
    ):
        raise p7.Blocked("P7 postboot Cloudflare origin guard is no longer in its observed missing state")
    for level, message in inner.rows:
        report.add(level, message)
    report.add("PASS", "Original restored SQLite/Age/SOPS/volume markers and unchanged P5/P6/P7 source digests match P7 checkpoint")

    p5 = p7.helper(p7.P5_FILE, "p7r_p5")
    classification, checks, safe_shape = p5.diagnose_doctor(report.output, "p7r-before")
    if classification != "valid" or len(checks) != 27:
        raise p7.Blocked("installed 27-check doctor structure invalid before origin rearm")
    if frozenset(k for k, v in checks.items() if v == "FAIL") != EXPECTED_STOPPED_FAILURE_IDS:
        raise p7.Blocked("pre-rearm doctor FAIL-ID set differs from accepted stopped P7 HOLD")
    if checks.get("storage.dedicated") != "PASS" or checks.get("edge.cloudflare.cidrs") != "PASS":
        raise p7.Blocked("dedicated storage or validated Cloudflare policy missing before rearm")
    report.add("PASS", "Exactly expected stopped-host doctor FAIL IDs; live CrowdSec/INPUT remains healthy")
    return p5, checkpoint, paths, hashes, checks


def postflight(p7, p5, report: Report, original: dict[str, object], paths: tuple[Path, ...]) -> None:
    inner = p7.Report(report.output, "p7r-postflight")
    post_paths, protected = p7.host_snapshot(inner, after_boot=True)
    if post_paths != paths:
        raise p7.Blocked("protected path inventory changed after origin rearm")
    p7.verified_hashes(original, post_paths, protected)
    if any(
        level == "PENDING" and "not persistent across cold boot" in message
        for level, message in inner.rows
    ):
        raise p7.Blocked("Cloudflare Docker 443 ingress still missing after installed product refresh")
    classification, checks, _ = p5.diagnose_doctor(report.output, "p7r-after")
    if classification != "valid" or len(checks) != 27:
        raise p7.Blocked("post-rearm full installed doctor contract invalid")
    if any(checks.get(key) != "PASS" for key in (*p5.REQUIRED_DOCTOR, "storage.dedicated")):
        raise p7.Blocked("Cloudflare/CrowdSec/security/storage doctor check regression after rearm")
    if {k for k, v in checks.items() if v == "FAIL"} != {"crowdsec.cloudflare", "runtime.paths"}:
        raise p7.Blocked("unexpected doctor FAIL IDs after installed origin refresh")
    for level, message in inner.rows:
        report.add(level, message)
    report.add("PASS", "Installed Cloudflare-only IPv4/IPv6 Docker origin policy re-established")
    report.add("PASS", "Restored data/SOPS/age/units, CrowdSec INPUT, stopped application and Worker state unchanged")
    report.add("PENDING", "Original P7 HOLD remains: rules did NOT persist over reboot; this proves explicit re-arm only")
    report.add("NOT RUN", "No Caddy/Vaultwarden/Worker start, DNS, SMTP, Box, timers or reboot")


def main() -> int:
    if (sys.argv[1:] not in (["--diagnose-only"], ["--rearm"])
            or os.geteuid() != 0 or os.environ.get("SUDO_USER") != "ubuntu"):
        print("BLOCKED: only --diagnose-only or --rearm via sudo -n as ubuntu", file=sys.stderr)
        return 2
    mode = sys.argv[1]
    if mode == "--rearm" and not (sys.stdin.isatty() and sys.stdout.isatty()):
        print("BLOCKED: interactive terminal required for P7R rearm", file=sys.stderr)
        return 2
    try:
        p7 = original_p7()
        base = p7.safe_base()
        evidence = new_private_evidence(base)
    except Exception:
        print("BLOCKED: original P7 source or private evidence base unavailable", file=sys.stderr)
        return 2
    report = Report(evidence, "diagnose" if mode == "--diagnose-only" else "rearm")
    phase = "source/checkpoint/data/host isolation preflight"
    try:
        p5, checkpoint, paths, hashes, before = preflight(p7, report)
        attempt = attempt_path(base)
        if attempt.exists() or attempt.is_symlink():
            if mode == "--rearm":
                raise p7.Blocked("existing P7R firewall rearm attempt; do not automatically retry")
            report.add("PENDING", "Prior rearm attempt marker exists; inspect before any further mutation")
        if mode == "--diagnose-only":
            report.add("PENDING", "This command did not refresh firewall; separate OCI-console consent needed")
            report.add("NOT RUN", "No origin firewall, packages, app/Worker/DNS, Box or timer changes")
            return report.finish()
        print("\nP7R: LOCAL CLOUDFLARE-ONLY FIREWALL RE-ARM")
        print("The immutable rc.12 product will fetch Cloudflare IP ranges and update")
        print("local Docker DOCKER-USER TCP/443 rules for IPv4 and IPv6.")
        print("The restored vault/Caddy stay STOPPED; no Cloudflare API, DNS or Worker")
        print("invocation, remote Box write, SMTP or reboot will be performed.")
        print("Verify active OCI serial console access before consent.")
        print("Partial firewall state is possible after interruption; do NOT rerun.")
        print("Type the exact phrase below to authorize only this origin refresh:")
        print(CONSENT)
        phase = "explicit OCI-console-backed operator consent"
        if not consented(input("Authorization [CANCEL]: ")):
            report.add("PENDING", "Cancelled; no firewall/host change authorized")
            return report.finish()
        phase = "second full immutable-host pre-mutation validation"
        if attempt.exists() or attempt.is_symlink():
            raise p7.Blocked("P7R attempt marker appeared since consent; preserving original state")
        preflight(p7, Report(evidence, "second-preflight"))
        phase = "one-shot recorded firewall mutation"
        record_attempt_once(attempt, str(checkpoint["boot_id"]), p7.read_boot_id())
        report.mutation_started = True
        code = p5.run_private(
            [sys.executable, "-B", "-E", str(p7.INSTALLED / "vwctl"), "edge", "refresh"],
            evidence, "installed-edge-refresh", 180,
        )
        if code != 0:
            raise p7.Blocked("installed edge refresh failed or timed out; private logs retained")
        report.add("PASS", "Installed rc.12 owner completed one Cloudflare-only origin policy refresh")
        phase = "post-refresh restored data and product-owned doctor"
        postflight(p7, p5, report, checkpoint, paths)
        report.verified = True
        return report.finish()
    except KeyboardInterrupt:
        report.add("BLOCKED", "Interrupt during " + phase + "; preserve VM; never automatically repeat mutation")
        return report.finish()
    except Exception:
        report.add("BLOCKED", "P7R safety failure during " + phase + "; raw exception/credentials withheld")
        return report.finish()


if __name__ == "__main__":
    raise SystemExit(main())
