#!/usr/bin/env python3
"""Read-only source/custody preflight before an explicitly authorized rc.12 restore.

Disposable host-specific acceptance instrument, NOT an installed product command.
Default: no remote API access, credential refresh, decrypt-to-disk, restore,
backup, Cloudflare change, systemd activation or appliance mutation.
Explicit --verify-box-readback: streams one exact historical Box ciphertext
for SHA-256 verification; rclone may refresh root's local OAuth token.
Only a root-private summary under the sudo operator's acceptance directory.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import os
import platform
import pwd
import re
import select
import stat
import time
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


def root_command_env() -> dict[str, str]:
    """Explicit root rclone config, avoiding accidental sudo-inherited overrides."""
    env = {key: val for key, val in os.environ.items()
           if not key.startswith("RCLONE_")}
    env["HOME"] = "/root"
    env["XDG_CONFIG_HOME"] = "/root/.config"
    return env


def run_readonly(argv: list[str], timeout: int = 15) -> tuple[int | None, str]:
    try:
        result = subprocess.run(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, check=False,
            timeout=timeout, cwd="/", env=root_command_env(),
        )
        return result.returncode, result.stdout
    except (OSError, subprocess.TimeoutExpired):
        return None, ""



def digest_bounded_stdout(
    argv: list[str],
    *,
    timeout_seconds: int = 600,
    max_bytes: int = 4 * 1024**3,
    env: dict[str, str] | None = None,
) -> tuple[str, int]:
    """Read-only bounded stream digest. Never buffer/write recovered ciphertext.

    Exit code and bytes read must both be valid. The subprocess's stderr stays
    private (discarded) because rclone failures can include sensitive paths.
    """
    if timeout_seconds < 1 or max_bytes < 1 or not argv:
        raise ValueError("invalid bounded stream limits")
    process = subprocess.Popen(
        argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, cwd="/", env=env or root_command_env(),
    )
    digest = hashlib.sha256()
    size = 0
    deadline = time.monotonic() + timeout_seconds
    try:
        if process.stdout is None:
            raise RuntimeError("stream missing")
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("stream timed out")
            readable, _, _ = select.select([process.stdout], [], [], remaining)
            if not readable:
                raise TimeoutError("stream timed out")
            block = os.read(process.stdout.fileno(), 1024 * 1024)
            if not block:
                break
            size += len(block)
            if size > max_bytes:
                raise ValueError("bounded stream limit exceeded")
            digest.update(block)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("stream timed out")
        if process.wait(timeout=remaining) != 0:
            raise RuntimeError("stream process failed")
        if size == 0:
            raise ValueError("empty stream")
        return digest.hexdigest(), size
    finally:
        if process.poll() is None:
            process.kill()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        if process.stdout is not None:
            process.stdout.close()


def box_ciphertext_readback(enabled: bool, configured: bool, safe_to_run: bool) -> tuple[str, str]:
    """One exact Box object, client-read-only. OAuth token may refresh locally."""
    if not enabled:
        return ("NOT RUN", "Box ciphertext SHA-256 readback not requested (default offline gate)")
    if not safe_to_run:
        return ("NOT RUN", "Box readback skipped because host identity/isolation checks blocked")
    if not configured:
        return ("PENDING", "Box readback skipped: root bw-backup: rclone remote unavailable")
    try:
        digest, size = digest_bounded_stdout(
            ["rclone", "cat", HISTORICAL_REMOTE, "--retries", "1"],
            timeout_seconds=600,
            max_bytes=4 * 1024**3,
        )
    except TimeoutError:
        return ("PENDING", "Box ciphertext readback timed out; remote unchanged")
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError):
        return ("PENDING", "Box ciphertext readback failed or exceeded safe bound; private diagnostics withheld")
    if digest != HISTORICAL_SHA256:
        return ("BLOCKED", "Historical Box ciphertext SHA-256 mismatch; do not restore")
    return ("PASS", f"Original Box ciphertext SHA-256 matched independent acceptance pin; bytes={size}, no local artifact saved")


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



def release_fingerprints(root: Path, *, strict_modes: bool = False) -> dict[str, str]:
    """Hash product-owned release files only. Reject extra symlinks/bytecode."""
    files = ("vwctl", "versions.toml", "email-providers.toml")
    dirs = ("vaultwarden_oci", "systemd")
    found: dict[str, str] = {}

    def visit(path: Path) -> None:
        if path.is_symlink():
            raise ValueError("symlink in release")
        info = path.lstat()
        if strict_modes and (info.st_uid != 0 or stat.S_IMODE(info.st_mode)
                             not in ({0o555} if stat.S_ISDIR(info.st_mode) else {0o444, 0o555})):
            raise ValueError("immutable file ownership/mode drift")
        if stat.S_ISDIR(info.st_mode):
            if path.name == "__pycache__":
                raise ValueError("bytecode directory in immutable source")
            for item in path.iterdir():
                visit(item)
        elif stat.S_ISREG(info.st_mode):
            if path.suffix == ".pyc" or info.st_size > 16 * 1024 * 1024:
                raise ValueError("unexpected release file")
            hash_value = hashlib.sha256()
            with path.open("rb") as handle:
                for part in iter(lambda: handle.read(1024 * 1024), b""):
                    hash_value.update(part)
            found[path.relative_to(root).as_posix()] = hash_value.hexdigest()
        else:
            raise ValueError("nonregular release object")

    for file in files:
        if not (root / file).is_file():
            raise ValueError("required release file missing")
        visit(root / file)
    for directory in dirs:
        if not (root / directory).is_dir():
            raise ValueError("required release directory missing")
        visit(root / directory)
    return found


def release_integrity(source: Path, installed: Path) -> tuple[bool, int]:
    """No source identifier or live secret content is emitted."""
    try:
        expected = release_fingerprints(source)
        actual = release_fingerprints(installed, strict_modes=True)
    except (OSError, ValueError):
        return False, 0
    return expected == actual and len(expected) > 40, len(expected)


def systemd_unit_integrity(installed: Path) -> tuple[bool, int]:
    try:
        from vaultwarden_oci import install
        units = install.SYSTEMD_UNITS
        for unit in units:
            source = installed / "systemd" / unit
            destination = Path("/etc/systemd/system") / unit
            info = destination.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o644:
                return False, len(units)
            if hashlib.sha256(source.read_bytes()).digest() != hashlib.sha256(destination.read_bytes()).digest():
                return False, len(units)
        return True, len(units)
    except (OSError, ValueError):
        return False, 0


def doctor_readout(stdout: str, rc: int | None) -> tuple[bool, str, list[str]]:
    """Allowlisted check IDs only; never expose any doctor check messages."""
    import json
    try:
        payload = json.loads(stdout)
        if payload.get("schema_version") != 1:
            raise ValueError("invalid doctor schema")
        checks = payload["checks"]
        if not isinstance(checks, list) or not checks:
            raise ValueError("empty checks")
        fails = []
        for check in checks:
            check_id = check["id"]
            state = check["status"]
            if not isinstance(check_id, str) or not re.fullmatch(r"[a-z][a-z0-9_.-]{0,80}", check_id):
                raise ValueError("unsafe check id")
            if state not in {"PASS", "WARN", "FAIL", "SKIP"}:
                raise ValueError("unexpected check status")
            if state == "FAIL":
                fails.append(check_id)
        overall = payload["overall"]
        if overall != ("FAIL" if fails else "WARN" if any(c["status"] == "WARN" for c in checks)
                       else "SKIP" if all(c["status"] == "SKIP" for c in checks) else "PASS"):
            raise ValueError("doctor overall mismatch")
        if rc not in (0, 1) or (rc == 0) == (overall == "FAIL"):
            raise ValueError("doctor returncode mismatch")
        return True, overall, fails
    except (TypeError, ValueError, KeyError, IndexError, AttributeError):
        return False, "INVALID", []


def secret_schema_readout() -> str:
    """Call the installed secret authority, return only known names/status."""
    try:
        from vaultwarden_oci import secrets
        payload = secrets.decrypt()
        remediation = bool(payload.get("cloudflare_remediation_token"))
        del payload
        return "valid" if remediation else "missing cloudflare_remediation_token"
    except Exception as exc:
        reason = str(exc)
        matched = re.fullmatch(
            r"decrypted secret (cloudflare_api_token|smtp_username|smtp_password|cloudflare_remediation_token|email_api_token|admin_basic_auth_password|vaultwarden_admin_token) must be a non-empty single-line string",
            reason,
        )
        if matched:
            return "missing or invalid " + matched.group(1)
        if reason.startswith("decrypted Cloudflare token does not match"):
            return "invalid Cloudflare token format (value withheld)"
        return "unverified (private details withheld)"


def listening_ports(proc_files: tuple[Path, ...] | None = None) -> set[int] | None:
    """Inspect /proc TCP LISTEN only; no listener addresses or socket owners."""
    files = proc_files or (Path("/proc/net/tcp"), Path("/proc/net/tcp6"))
    try:
        ports: set[int] = set()
        for file in files:
            with file.open(encoding="ascii") as handle:
                next(handle)
                for row in handle:
                    fields = row.split()
                    if len(fields) < 4 or fields[3] != "0A":
                        continue
                    port = int(fields[1].rsplit(":", 1)[1], 16)
                    if port in {80, 443}:
                        ports.add(port)
        return ports
    except (OSError, StopIteration, IndexError, ValueError):
        return None


def local_recovery_inventory(root: Path) -> tuple[str, str]:
    """Return only file counts; encrypted artifact content remains unopened."""
    backup = root / "backups"
    try:
        info = backup.lstat()
    except FileNotFoundError:
        return "NOT RUN", "no local recovery points created"
    except OSError:
        return "BLOCKED", "cannot inspect backup directory"
    if not stat.S_ISDIR(info.st_mode):
        return "BLOCKED", "non-directory or symlink in backup path"
    try:
        if info.st_dev != root.stat().st_dev:
            return "BLOCKED", "backup path is outside the dedicated volume"
        count = 0
        for path in backup.iterdir():
            if path.name.endswith(".vwrec"):
                item = path.lstat()
                if not stat.S_ISREG(item.st_mode) or item.st_size == 0:
                    return "BLOCKED", "invalid local recovery artifact metadata"
                count += 1
    except OSError:
        return "BLOCKED", "unreadable local backup directory"
    if not count:
        return "NOT RUN", "backup directory exists but no recovery points"
    return "PENDING", f"{count} encrypted .vwrec object(s) present; integrity NOT reverified"


def daemon_running(props: dict[str, str] | None) -> bool:
    """A CLI probe is permitted only if its daemon is already active."""
    return bool(props and props.get("LoadState") == "loaded" and props.get("ActiveState") == "active")


def service_properties(unit: str) -> dict[str, str] | None:
    code, raw = run_readonly(
        ["systemctl", "show", unit, "--no-pager",
         "--property=LoadState,ActiveState,UnitFileState"],
        timeout=12,
    )
    if code != 0:
        return None
    values = dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)
    return {key: values.get(key, "unknown") for key in ("LoadState", "ActiveState", "UnitFileState")}



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
    if sys.argv[1:] not in ([], ["--verify-box-readback"]) or os.geteuid() != 0:
        print("BLOCKED: unsupported arguments or not root; use sudo -n as ubuntu", file=sys.stderr)
        return 2
    verify_box = sys.argv[1:] == ["--verify-box-readback"]
    try:
        out = evidence_dir()
    except (OSError, KeyError, RuntimeError) as exc:
        print("BLOCKED: cannot create private operator evidence (" + type(exc).__name__ + ")", file=sys.stderr)
        return 2

    report_rows: list[tuple[str, str]] = []
    blocked = False

    def record(state: str, msg: str) -> None:
        nonlocal blocked
        if state not in {"PASS", "BLOCKED", "PENDING", "NOT RUN"}:
            raise RuntimeError("invalid evidence classification")
        report_rows.append((state, msg))
        if state == "BLOCKED":
            blocked = True

    def finish() -> int:
        overall = "BLOCKED" if blocked else "PENDING"
        record(overall, "Pre-restore readiness; no restore or external side effects authorized")
        summary = ("Gate P1 — rc.12 recovery source/custody inventory (read only)\n"
                   + "\n".join(f"{state:<8} {msg}" for state, msg in report_rows) + "\n")
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
    box_remote_configured = remote_available(names, status)
    record("PASS" if box_remote_configured else "PENDING",
           "Root's bw-backup: rclone name exists (no remote connectivity tested)" if box_remote_configured
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
    # Broad release and host readiness: all reads, independent of remote custody.
    # These checks continue even when the known Box remote/kit are unavailable.
    import shutil
    from vaultwarden_oci import cli

    host_ok = platform.machine() in {"aarch64", "arm64"} and sys.version_info[:2] == (3, 14)
    try:
        os_values = cli.read_os_release()
        cli.validate_supported_ubuntu_release(os_values)
        host_ok = host_ok and os_values.get("VERSION_ID") == "26.04"
    except (OSError, cli.UnsupportedHost):
        host_ok = False
    record("PASS" if host_ok else "BLOCKED",
           "Native Ubuntu 26.04 ARM64 / Python 3.14 host contract verified" if host_ok
           else "Unsupported operating system or native Python interpreter")

    clean, count = release_integrity(Path(__file__).resolve().parents[2], installed)
    record("PASS" if clean else "BLOCKED",
           f"Exact installed immutable release content matches reviewed checkout ({count} release-owned files)"
           if clean else "Immutable release source, content, permissions or file inventory diverge; no update/restore authorized")

    units_match, units_n = systemd_unit_integrity(installed)
    record("PASS" if units_match else "BLOCKED",
           f"Installed systemd unit files match immutable rc.12 release ({units_n} units)"
           if units_match else "Installed systemd unit content/ownership differs from approved immutable release")

    try:
        usage = os.statvfs(STATE)
        free_gib = usage.f_bavail * usage.f_frsize // (1024 ** 3)
        free_inodes = usage.f_favail
        capacity_ok = free_gib >= 4 and free_inodes >= 100
        record("PASS" if capacity_ok else "PENDING",
               f"Dedicated-volume capacity available_GiB={free_gib}; free_inodes={free_inodes}")
    except OSError:
        record("BLOCKED", "Cannot inspect dedicated data-volume capacity")

    try:
        cli.validate_config(Path("/etc/vaultwarden-oci/config.toml"))
        config_ok = True
    except (cli.ConfigError, OSError):
        config_ok = False
    record("PASS" if config_ok else "BLOCKED",
           "Installed non-secret site/SMTP/backup config schema valid (values withheld)"
           if config_ok else "Installed non-secret config validation fails (details withheld)")
    schema = secret_schema_readout()
    record("PASS" if schema == "valid" else "PENDING",
           "Encrypted SOPS semantic credential schema valid; values withheld"
           if schema == "valid" else
           f"Pre-start credential readiness incomplete: {schema}; revalidate after approved restore/credential setup")
    record("PENDING",
           "SMTP endpoint and operational notifier settings parsed; no outbound TLS/SMTP/email delivery exercised")

    def local_file_kind(path: Path) -> str:
        try:
            meta = path.lstat()
        except FileNotFoundError:
            return "absent"
        except OSError:
            return "unreadable"
        if stat.S_ISLNK(meta.st_mode) or not stat.S_ISREG(meta.st_mode):
            return "unsafe"
        return "present" if meta.st_size > 0 else "empty"

    db = local_file_kind(STATE / "data/db.sqlite3")
    record("BLOCKED" if db in {"unsafe", "unreadable", "empty"} else "PENDING" if db == "present" else "NOT RUN",
           "Vaultwarden database metadata: " + db +
           ("; no SQLite integrity/read executed" if db == "present" else ""))
    backup_class, backup_detail = local_recovery_inventory(STATE)
    record(backup_class, "Local .vwrec inventory: " + backup_detail)

    # A docker CLI inspection may trigger an inactive socket-activated daemon.
    # Skip Docker-backed doctor entirely unless Docker is ALREADY active.
    docker_unit = service_properties("docker.service")
    docker_active = daemon_running(docker_unit)
    if docker_active:
        doctor_rc, doctor_json = run_readonly(
            [sys.executable, "-B", "-E", str(installed / "vwctl"), "doctor", "--json"], timeout=85
        )
        valid_doctor, doctor_overall, failed_checks = doctor_readout(doctor_json, doctor_rc)
        record("BLOCKED" if not valid_doctor else "PASS" if doctor_overall == "PASS" else "PENDING",
               "Product doctor: " +
               (f"overall={doctor_overall}; failing_check_ids={','.join(failed_checks[:16]) or 'none'}"
                if valid_doctor else "malformed JSON or inconsistent exit status (messages withheld)"))
    else:
        record("NOT RUN", "Docker-backed doctor skipped: Docker daemon was not already active")

    binaries = ("git", "docker", "rclone", "sops", "age", "age-keygen",
                "7zz", "cscli", "iptables", "ip6tables", "nft", "ss")
    present_tools = {item for item in binaries if shutil.which(item)}
    absent = sorted(set(binaries) - present_tools)
    record("PASS" if not absent else "PENDING",
           "Host dependency binaries " +
           ("all present" if not absent else "not yet installed: " + ",".join(absent)) +
           " (presence only; no package changes)")
    dpkg_rc, dpkg_out = run_readonly(["dpkg", "--audit"], timeout=30)
    record("PASS" if dpkg_rc == 0 and not dpkg_out.strip() else "PENDING",
           "Host dpkg state clean" if dpkg_rc == 0 and not dpkg_out.strip()
           else "Package audit requires administrator review; no apt action performed")

    if docker_active:
        docker_rc, docker_version = run_readonly(
            ["docker", "version", "--format", "{{.Server.Version}}"], timeout=20
        )
        compose_rc, compose_version = run_readonly(["docker", "compose", "version", "--short"], timeout=20)
        engine_ok = docker_rc == 0 and bool(docker_version.strip())
        compose_ok = compose_rc == 0 and bool(compose_version.strip())
        record("PASS" if engine_ok and compose_ok else "PENDING",
               f"Docker engine reachable={engine_ok} Compose available={compose_ok} (no containers started)")
        if engine_ok:
            code, container_id_output = run_readonly(
                ["docker", "ps", "--all",
                 "--filter", "name=^vaultwarden-oci-",
                 "--format", "{{.ID}}"], timeout=20
            )
            count_containers = len([line for line in container_id_output.splitlines() if line.strip()])
            running_rc, running_id_output = run_readonly(
                ["docker", "ps",
                 "--filter", "name=^vaultwarden-oci-",
                 "--format", "{{.ID}}"], timeout=20
            )
            running_count = len([line for line in running_id_output.splitlines() if line.strip()])
            if running_rc != 0 or code != 0:
                container_state = "PENDING"
            elif running_count:
                container_state = "BLOCKED"
            elif count_containers:
                container_state = "PENDING"
            else:
                container_state = "PASS"
            record(container_state,
                   f"Appliance-named containers total={count_containers if code == 0 else 'unknown'} "
                   f"running={running_count if running_rc == 0 else 'unknown'}"
                   " (names, IDs and logs withheld)")
        else:
            record("NOT RUN", "Container inventory unavailable without a healthy Docker engine")
    else:
        record("NOT RUN", "Docker CLI/Compose/container inventory skipped to avoid socket service activation")

    security_units = (
        "crowdsec.service",
        "crowdsec-firewall-bouncer.service",
        "crowdsec-cloudflare-worker-bouncer.service",
    )
    security_states = {name: service_properties(name) for name in security_units}
    active_worker = (security_states["crowdsec-cloudflare-worker-bouncer.service"] or {}).get("ActiveState") in {
        "active", "activating", "reloading"
    }
    installed_security = sum((state or {}).get("LoadState") == "loaded"
                             for state in security_states.values())
    record("BLOCKED" if active_worker else "PENDING",
           f"Security unit deployment {installed_security}/3; "
           f"Cloudflare Worker active={active_worker} (policy and Worker Route not validated)"
           if not active_worker else
           "Unexpected active Cloudflare Worker on dormant test VM; do not change it automatically")
    record("PENDING", "Cloudflare origin CIDR/iptables rules and CrowdSec source ownership require separately authorized live security gate")

    listeners = listening_ports()
    record("PASS" if listeners == set() else "PENDING",
           "No TCP/80 or TCP/443 listener on dormant host" if listeners == set()
           else "Listener state unavailable" if listeners is None
           else "Host TCP port(s) occupied: " + ",".join(str(i) for i in sorted(listeners)) +
                " (listener ownership not determined)")
    clock_rc, clock_val = run_readonly(["timedatectl", "show", "--property=NTPSynchronized", "--value"], timeout=12)
    synced = clock_rc == 0 and clock_val.strip() == "yes"
    record("PASS" if synced else "PENDING",
           "Host NTP synchronized" if synced else "NTP synchronization not yet confirmed")
    record("PENDING" if Path("/var/run/reboot-required").exists() else "PASS",
           "OS reboot pending (no reboot attempted)" if Path("/var/run/reboot-required").exists()
           else "No Ubuntu reboot-required marker")
    record("NOT RUN", "Live client login, Admin UI, SSH ingress, Caddy TLS, SMTP, notification delivery, edge packets and current Worker Fail Open")
    record("NOT RUN", "Actual scheduled backup, independent offsite readback, real restore, update rollback and reboot remain separate approved gates")

    box_status, box_detail = box_ciphertext_readback(
        verify_box, box_remote_configured, safe_to_run=not blocked
    )
    record(box_status, "Box ciphertext readback: " + box_detail)
    record("NOT RUN", "No offline Age private-key extraction, archive decryption/manifest verification or restore")
    record("NOT RUN", "No services, CrowdSec Worker, DNS, SMTP, timers, snapshot, package changes or reboot")
    return finish()


if __name__ == "__main__":
    raise SystemExit(main())
