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
        if (not isinstance(name, str) or not isinstance(status, str)
                or name not in allowed_ids or name in checks
                or status not in {"PASS", "WARN", "FAIL", "SKIP"}):
            return "unexpected_or_duplicate_check_id", {}
        checks[name] = status
    if set(checks) != set(allowed_ids):
        return "missing_check_ids", {}
    overall = ("FAIL" if "FAIL" in checks.values() else "WARN" if "WARN" in checks.values()
               else "SKIP" if set(checks.values()) == {"SKIP"} else "PASS")
    if payload.get("overall") != overall or (return_code == 0) != (overall != "FAIL"):
        return "inconsistent_overall_or_exit", {}
    return "valid", checks



def safe_doctor_shape(raw: str, allowed_ids: tuple[str, ...]) -> str:
    """Report shape only. Unrecognized IDs, messages and statuses are never echoed.

    The accepted rc.12 source declares exactly 26 check IDs. Detect whether a
    mismatch is extra/missing IDs, duplicate IDs, or an invalid status without
    changing the actual fail-closed doctor contract or displaying raw JSON.
    """
    expected = set(allowed_ids)
    if len(expected) != len(allowed_ids):
        return "invalid_approved_registry"
    if len(raw) > 256 * 1024:
        return "doctor_output_oversized"
    try:
        obj = json.loads(raw)
    except (TypeError, ValueError):
        return "doctor_output_not_json"
    if not isinstance(obj, dict) or not isinstance(obj.get("checks"), list):
        return "doctor_output_invalid_schema"
    rows = obj["checks"]
    seen: dict[str, int] = {}
    unknown_hashes: set[str] = set()
    bad_types = 0
    bad_status = 0
    invalid_rows = 0
    invalid_status_ids: set[str] = set()
    for item in rows:
        if not isinstance(item, dict):
            invalid_rows += 1
            continue
        identifier = item.get("id")
        status = item.get("status")
        if not isinstance(identifier, str):
            bad_types += 1
            continue
        if identifier in expected:
            seen[identifier] = seen.get(identifier, 0) + 1
        else:
            # A digest permits deterministic comparison with code without
            # disclosing an unknown, potentially sensitive dynamic ID value.
            unknown_hashes.add(hashlib.sha256(identifier.encode("utf-8", "replace")).hexdigest()[:12])
        if not isinstance(status, str) or status not in {"PASS", "WARN", "FAIL", "SKIP"}:
            bad_status += 1
            if identifier in expected:
                invalid_status_ids.add(identifier)
    duplicates = sorted(k for k, count in seen.items() if count > 1)
    missing = sorted(expected - seen.keys())
    return (
        f"observed_checks={len(rows)} expected_checks={len(expected)} "
        f"unique_expected_seen={len(seen)} unknown_id_count={len(unknown_hashes)} "
        f"unknown_id_hashes={','.join(sorted(unknown_hashes)[:8]) or 'none'} "
        f"duplicate_expected_ids={','.join(duplicates) or 'none'} "
        f"missing_expected_ids={','.join(missing) or 'none'} "
        f"invalid_status_count={bad_status} "
        f"invalid_status_expected_ids={','.join(sorted(invalid_status_ids)) or 'none'} "
        f"invalid_id_type_count={bad_types} invalid_row_count={invalid_rows}"
    )



def product_doctor_ids() -> tuple[str, ...]:
    """Obtain the installed product's complete, canonical doctor registry.

    The installed vwctl entrypoint imports update_cli before invoking the
    product doctor. update_cli registers the mandatory storage.dedicated
    check in cli.DOCTOR_CHECK_IDS. The acceptance process must do exactly
    the same in-memory registration, with no on-disk modifications.
    """
    from vaultwarden_oci import cli, update_cli

    names = tuple(cli.DOCTOR_CHECK_IDS)
    extra = update_cli._STORAGE_DOCTOR_ID
    if (extra != "storage.dedicated" or len(names) != 27
            or len(set(names)) != len(names)
            or extra not in names or names.index(extra) != names.index("runtime.paths") + 1):
        raise ValueError("installed product doctor registry differs from the reviewed rc.12 contract")
    return names


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


def diagnose_doctor(output: Path, label: str, *, seconds: int = 120) -> tuple[str, dict[str, str], str]:
    """Inspect installed doctor; return trusted IDs plus safe shape, never raw text."""
    try:
        approved = product_doctor_ids()
    except (ImportError, AttributeError, RuntimeError, ValueError):
        return "invalid_installed_doctor_registry", {}, "registered_check_set_not_approved"
    try:
        run = subprocess.run(
            [sys.executable, "-B", "-E", str(INSTALLED / "vwctl"), "doctor", "--json"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
            cwd="/", check=False, timeout=seconds,
        )
        # Never persist doctor output or print exception detail: messages can
        # contain credentials, hostnames, operator addresses or other secrets.
        raw = run.stdout[:256 * 1024 + 1].decode("utf-8", "replace")
        classification, checks = class_doctor(raw, run.returncode, approved)
        shape = "not_needed" if classification == "valid" else safe_doctor_shape(raw, approved)
        return classification, checks, shape
    except (OSError, subprocess.TimeoutExpired):
        return "command_unavailable_or_timeout", {}, "doctor_command_unavailable_or_timeout"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()



def inspect_stopped_runtime_paths(runtime, secrets) -> tuple[str, str]:
    """Categorize installed runtime.paths without reading any file content.

    Use only product-owned constant Paths, UID/GID/mode contracts. Never make
    directories, materialize secrets, start Docker, or reveal raw error text.
    MISSING is PENDING because installed runtime.ensure_paths() normally
    materializes generated paths at a later, separately authorized startup.
    Wrong type, symlink, identity or permissions are BLOCKED, not normalized.
    """
    paths = runtime.Paths()
    secret_paths = paths.secret_paths()
    dir_entries = (
        ("run.root", paths.run, 0, 0, 0o700),
        ("run.transient", paths.transient, 0, 0, 0o700),
        ("run.secrets", paths.secret_root, 0, 0, 0o700),
        ("data.vaultwarden", paths.data, runtime.VAULTWARDEN_UID, runtime.VAULTWARDEN_GID, 0o700),
        ("log.vaultwarden.dir", paths.vaultwarden_log_path, runtime.VAULTWARDEN_UID, runtime.VAULTWARDEN_GID, 0o700),
        ("data.caddy", paths.caddy_data, runtime.CADDY_UID, runtime.CADDY_GID, 0o700),
        ("config.caddy", paths.caddy_config, runtime.CADDY_UID, runtime.CADDY_GID, 0o700),
        ("log.caddy.dir", paths.caddy_log_path, runtime.CADDY_UID, runtime.CADDY_GID, 0o700),
        ("run.vaultwarden-secrets", secret_paths.vaultwarden, 0, runtime.VAULTWARDEN_GID, 0o750),
        ("run.caddy-secrets", secret_paths.caddy, 0, runtime.CADDY_GID, 0o750),
    )
    file_entries = (
        ("run.lock", paths.lock, 0, 0, 0o600),
        ("log.vaultwarden.file", paths.vaultwarden_log_file, runtime.VAULTWARDEN_UID, runtime.VAULTWARDEN_GID, 0o600),
        ("render.compose", paths.compose, 0, 0, 0o600),
        ("render.Caddyfile", paths.caddyfile, 0, 0, 0o444),
        ("render.Dockerfile", paths.dockerfile, 0, 0, 0o600),
        *(
            ("secret.required." + key, secret_paths.file(key),
             0,
             runtime.CADDY_GID if key == "cloudflare_api_token" else runtime.VAULTWARDEN_GID,
             0o440)
            for key in secrets.REQUIRED
        ),
    )

    missing: list[str] = []
    unsafe: list[str] = []
    for kind, entries in (("dir", dir_entries), ("file", file_entries)):
        for label, path, uid, gid, expected_mode in entries:
            try:
                info = path.lstat()
            except FileNotFoundError:
                missing.append(label)
                continue
            except OSError:
                unsafe.append(label + "=inspection-error")
                continue
            if stat.S_ISLNK(info.st_mode):
                unsafe.append(label + "=symlink")
            elif not (stat.S_ISDIR(info.st_mode) if kind == "dir" else stat.S_ISREG(info.st_mode)):
                unsafe.append(label + "=wrong-type")
            elif (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (uid, gid, expected_mode):
                unsafe.append(label + "=wrong-owner-or-mode")

    identity_collision = runtime._service_identity_error() is not None
    actual = runtime.runtime_paths_check(paths).status
    if actual not in {"PASS", "FAIL", "SKIP"}:
        return "BLOCKED", "product=invalid-status"
    if identity_collision:
        unsafe.append("service-uid-or-gid=reserved-host-collision")

    # Rendered files and volatile secret files are valid as a completely
    # absent group before startup, but never partially materialized.
    def partial(group: set[str]) -> bool:
        missing_in_group = sum(label in missing for label in group)
        return 0 < missing_in_group < len(group)

    render_group = {"render.compose", "render.Caddyfile", "render.Dockerfile"}
    secret_group = {"secret.required." + key for key in secrets.REQUIRED}
    if partial(render_group):
        unsafe.append("rendered-files=partially-materialized")
    if partial(secret_group):
        unsafe.append("required-volatile-secrets=partially-materialized")

    optional_missing = render_group | secret_group
    unexpected_missing = set(missing) - optional_missing
    if unsafe:
        state = "BLOCKED"
    elif actual == "PASS":
        # The product explicitly accepts fully absent rendered/secret files.
        state = "PASS" if not unexpected_missing else "BLOCKED"
        if unexpected_missing:
            unsafe.append("cross-check=product-pass-with-required-path-missing")
    elif missing:
        state = "PENDING"
    else:
        state = "BLOCKED"
        unsafe.append("cross-check=unclassified-product-failure")
    return state, (
        f"product={actual} missing_count={len(missing)} "
        f"missing_labels={','.join(missing) or 'none'} "
        f"unsafe_count={len(unsafe)} "
        f"unsafe_labels={','.join(unsafe) or 'none'}"
    )

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
    diagnose_only = sys.argv[1:] == ["--diagnose-only"]
    if (sys.argv[1:] not in ([], ["--diagnose-only"]) or os.geteuid() != 0
            or not (sys.stdin.isatty() and sys.stdout.isatty())):
        print("BLOCKED: sudo -n from ubuntu in interactive terminal; only optional --diagnose-only", file=sys.stderr)
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
        diagnosis, statuses, structure = diagnose_doctor(out, "before")
        gate.add("PASS" if diagnosis == "valid" else "PENDING",
                 "Pre-foundation doctor JSON classification=" + diagnosis
                 + (f" failing_ids={','.join(sorted(k for k, v in statuses.items() if v == 'FAIL'))}"
                    if statuses else " (private error text withheld)"))
        if diagnosis != "valid":
            gate.add("PENDING", "Doctor safe structure: " + structure)
            gate.add("PENDING", "Doctor structural diagnostic unresolved: no firewall, package, or service changes authorized")
            gate.add("NOT RUN", "P5 mutation and activation held before operator consent, pending doctor classification repair")
            return gate.finish()
        if statuses.get("storage.dedicated") != "PASS":
            gate.add("BLOCKED", "Installed product dedicated-storage doctor check did not PASS; no host mutation permitted")
            return gate.finish()
        gate.add("PASS", "Complete installed product doctor registry validated: 27 unique checks including storage.dedicated")
        path_status, path_summary = inspect_stopped_runtime_paths(runtime, secrets)
        gate.add(path_status, "Stopped-host runtime.paths inventory: " + path_summary)
        if path_status == "BLOCKED":
            gate.add("NOT RUN", "Unsafe runtime path metadata detected; security foundation authorization suppressed")
            return gate.finish()
        if statuses.get("runtime.paths") == "PASS" and path_status != "PASS":
            gate.add("BLOCKED", "Product reported runtime.paths PASS but independent stopped-host inventory disagrees")
            return gate.finish()
        if statuses.get("runtime.paths") == "FAIL" and path_status == "PASS":
            gate.add("BLOCKED", "Runtime path doctor FAIL without a matching independent stopped-host reason")
            return gate.finish()
        if diagnose_only:
            gate.add("PENDING", "Doctor-only mode completed; security foundation remains unconfigured and requires later explicit consent")
            gate.add("NOT RUN", "No consent requested; no firewall, package, CrowdSec, Worker, app, timer or Box mutation")
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
        diagnosis, checks, structure = diagnose_doctor(out, "after")
        if diagnosis != "valid":
            gate.add("BLOCKED", "Post-security doctor cannot be safely parsed: "+diagnosis+"; safe_shape="+structure+"; no raw output disclosed")
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
