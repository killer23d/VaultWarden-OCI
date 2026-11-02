#!/usr/bin/env python3
"""P3: operator-approved disposable-host recovery from a pinned Box archive.

No production DNS, email, service start, timer enable, rclone upload/prune or reboot.
Reads the remote .vwrec into swap-free tmpfs, verifies source and offline custody,
then requires an exact interactive RESTORE before any persistent app-state change.
After consent, only the installed product recovery owner promotes application data.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import importlib.util
import os
import platform
import pwd
import shutil
import signal
import stat
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-6-vnic"
VERSION = "0.1.0-rc.12"
ROOT = Path(__file__).resolve().parents[2]
P2_SCRIPT = Path(__file__).resolve().with_name("production-cryptographic-readiness.py")
RELEASE = Path("/opt/vaultwarden-oci/releases") / VERSION
CURRENT = Path("/opt/vaultwarden-oci/current")
STATE = Path("/var/lib/vaultwarden-oci")
ORIGINAL_UUID = "75ceee68-0fff-4f74-b629-4e22b3b99c20"
EXPECTED_SHA = "ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060"
ARCHIVE = "bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec"


def p2_module():
    spec = importlib.util.spec_from_file_location("p3_p2_owner", P2_SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError("expected source-owned P2 verification helper unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def evidence_directory() -> Path:
    if os.environ.get("SUDO_USER") != "ubuntu":
        raise RuntimeError("only the original acceptance operator may execute P3")
    home = Path(pwd.getpwnam("ubuntu").pw_dir)
    if home.is_symlink() or not home.is_dir():
        raise RuntimeError("unsafe operator home")
    base = home / "vwoci-acceptance"
    if base.is_symlink():
        raise RuntimeError("acceptance evidence is a symlink")
    if not base.exists():
        base.mkdir(mode=0o700)
    info = base.lstat()
    if (not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077
            or info.st_uid not in {0, pwd.getpwnam("ubuntu").pw_uid}):
        raise RuntimeError("untrusted private evidence root")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    directory = base / f"p3-real-restore-{stamp}-{os.getpid()}"
    directory.mkdir(mode=0o700)
    return directory


class Gate:
    def __init__(self, evidence: Path):
        self.evidence = evidence
        self.rows: list[tuple[str, str]] = []
        self.blocked = False
        self.cancelled = False
        self.restore_invoked = False
        self.promoted = False
        self.postverified = False

    def record(self, state: str, message: str) -> None:
        if state not in {"PASS", "BLOCKED", "PENDING", "NOT RUN"} or "\n" in message or "\r" in message:
            raise ValueError("unsafe evidence classification")
        self.blocked |= state == "BLOCKED"
        self.rows.append((state, message))

    def finish(self) -> int:
        if self.blocked or self.restore_invoked and not self.postverified:
            status, code = "BLOCKED", 2
        elif self.postverified and self.promoted:
            status, code = "RESTORED", 0
        else:
            status, code = "CANCELLED" if self.cancelled else "PENDING", 0
        if self.restore_invoked and not self.postverified:
            self.rows.append(("BLOCKED", "A restore was invoked: state may be partially changed; preserve host and do not retry blindly"))
        if status != "RESTORED":
            self.rows.append(("NOT RUN", "Full post-restore operational/security/notification/backup acceptance remains unproven"))
        self.rows.append((status, "P3 test-VM restore outcome; production cutover NOT AUTHORIZED"))
        summary = "Gate P3 - rc.12 test VM real Box recovery with explicit consent\n" + "\n".join(
            f"{state:<9} {message}" for state, message in self.rows
        ) + "\n"
        (self.evidence / "summary.txt").write_text(summary, encoding="utf-8")
        print(summary, end="")
        print("Private summary:", self.evidence / "summary.txt")
        print("Paste the summary only; never share private Age key, rclone secrets, decrypted config, logs or ZIP passphrase.")
        return code


def approve_restore(raw: str) -> bool:
    """Only the exact typed word is destructive consent."""
    return raw.strip() == "RESTORE"


def pristine_backup_dir(path: Path, root: Path) -> bool:
    """No unexpected backup inventory or symlink in the pre-consent target."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        return True
    except OSError:
        return False
    try:
        return (stat.S_ISDIR(info.st_mode) and info.st_uid == 0
                and stat.S_IMODE(info.st_mode) == 0o700
                and info.st_dev == root.stat().st_dev
                and not any(path.iterdir()))
    except OSError:
        return False


def create_empty_backup_dir_after_consent(path: Path, root: Path) -> None:
    """Persistent staging directory is allowed only AFTER typed RESTORE."""
    if not pristine_backup_dir(path, root):
        raise RuntimeError("unexpected existing backup directory contents or permissions")
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        pass
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != 0
            or stat.S_IMODE(info.st_mode) != 0o700
            or info.st_dev != root.stat().st_dev):
        raise RuntimeError("backup staging directory integrity changed")
    if any(path.iterdir()):
        raise RuntimeError("backup staging directory became occupied")


def confirm_isolated(p1, storage, *, require_empty_database: bool) -> bool:
    """Independent state check. Never assumes installed product can self-authorize."""
    identity = storage.verify()
    if identity.uuid != ORIGINAL_UUID or p1.EXPECTED_BYID.resolve(strict=True) != Path(identity.source).resolve(strict=True):
        return False
    states = {unit: p1.service_properties(unit) for unit in p1.UNITS}
    if any(value is None for value in states.values()) or not p1.stopped_units(states):
        return False
    if (STATE / "state/update-recovery-required.json").exists():
        return False
    if p1.daemon_running(p1.service_properties("docker.service")):
        code, lines = p1.run_readonly([
            "docker", "ps", "--filter", "name=^vaultwarden-oci-",
            "--format", "{{.ID}}"], timeout=20,
        )
        if code != 0 or bool(lines.strip()):
            return False
    if require_empty_database and (STATE / "data/db.sqlite3").exists():
        return False
    return True


def verify_promoted(p1, p2, runtime, secrets, *, expected_db_sha: str, expected_recipient: str) -> tuple[bool, str]:
    """Verify recovered config/SOPS/DB without starting or contacting services."""
    if not confirm_isolated(p1, __import__("vaultwarden_oci.storage", fromlist=["verify"]), require_empty_database=False):
        return False, "Post-promotion host/storage/isolation check failed"
    try:
        cfg = runtime.load_config()
        if cfg.offline_recovery_recipient != expected_recipient:
            return False, "Recovered offline public recipient differs"
        secrets.validate_custody(expected_recipient)
        values = secrets.decrypt()
        del values
        database = STATE / "data/db.sqlite3"
        if not p2.sqlite_snapshot_integrity(database):
            return False, "Promoted SQLite integrity check failed"
        if hashlib.sha256(database.read_bytes()).hexdigest() != expected_db_sha:
            return False, "Promoted SQLite differs from manifest-verified snapshot"
        offsite, _, local_days, remote_days = p2.preview_policy(cfg)
        if local_days or remote_days:
            return False, "Unexpected recovered age-based backup pruning policy"
        return True, f"Restored config, SOPS, SQLite and stopped-service state verified; offsite_configured={offsite}; retention_days={local_days}/{remote_days}"
    except Exception:
        return False, "Post-promotion app custody or database check failed (private details withheld)"


def main() -> int:
    if os.geteuid() != 0 or sys.argv[1:] or not (sys.stdin.isatty() and sys.stdout.isatty()):
        print("BLOCKED: run with sudo -n in an interactive terminal; no arguments", file=sys.stderr)
        return 2
    try:
        evidence = evidence_directory()
    except Exception:
        print("BLOCKED: no safe root-private evidence destination", file=sys.stderr)
        return 2
    gate = Gate(evidence)
    stage = "host and source verification"

    def interrupted(signum, frame):
        raise KeyboardInterrupt()
    old_signal = signal.signal(signal.SIGTERM, interrupted)
    try:
        if platform.node().split(".")[0] != HOST or platform.machine() not in {"aarch64", "arm64"}:
            gate.record("BLOCKED", "Unexpected target host or CPU")
            return gate.finish()
        if not CURRENT.is_symlink() or CURRENT.resolve(strict=True) != RELEASE:
            gate.record("BLOCKED", "Installed release is no longer rc.12")
            return gate.finish()
        p2 = p2_module()
        p1 = p2.p1_model()
        if not p1.release_integrity(ROOT, RELEASE)[0]:
            gate.record("BLOCKED", "Immutable installed rc.12 differs from approved source checkout")
            return gate.finish()
        sys.path.insert(0, str(RELEASE))
        if not p1.systemd_unit_integrity(RELEASE)[0]:
            gate.record("BLOCKED", "Original installed systemd unit integrity changed")
            return gate.finish()
        from vaultwarden_oci import recovery, recovery_ux, runtime, secrets, storage
        if not confirm_isolated(p1, storage, require_empty_database=True):
            gate.record("BLOCKED", "Original storage, stopped services, or empty test-VM database condition changed")
            return gate.finish()
        if not pristine_backup_dir(STATE / "backups", STATE):
            gate.record("BLOCKED", "Original backup staging is no longer empty/private")
            return gate.finish()
        gate.record("PASS", "Pinned rc.12, original dedicated data disk, inactive units/timers, empty DB and safe backup path")
        cfg = runtime.load_config()
        if not p1.matches_offline_recipient(cfg.offline_recovery_recipient):
            gate.record("BLOCKED", "Offline public recipient mismatches original accepted key")
            return gate.finish()
        secrets.validate_custody(cfg.offline_recovery_recipient)
        if not p1.backup_policy_safe(cfg.offsite_remote, cfg.local_retention_days, cfg.remote_retention_days):
            gate.record("BLOCKED", "Unapproved pre-restore offsite publication/pruning is configured")
            return gate.finish()
        rc, root_remotes = p1.run_readonly(["rclone", "listremotes"], timeout=15)
        if not p1.remote_available(root_remotes, rc):
            gate.record("BLOCKED", "Root's original Box remote unavailable")
            return gate.finish()
        gate.record("PASS", "Offline public custody, current no-publish policy and root Box credentials verified")
        if not p2.verified_tmpfs():
            gate.record("BLOCKED", "Memory-backed, swap-free protected /run is unavailable")
            return gate.finish()
        gate.record("PASS", "Protected swap-free temporary memory storage is available")

        stage = "single pinned Box read and source validation"
        with tempfile.TemporaryDirectory(dir="/run", prefix="vwoci-p3-") as directory:
            private = Path(directory)
            os.chmod(private, 0o700)
            if not p2.filename_guard(private):
                gate.record("BLOCKED", "Unsafe private memory workspace")
                return gate.finish()
            file = private / "pinned-recovery.vwrec"
            try:
                digest, size = p2.stream_exact_ciphertext(file, env=p1.root_command_env())
            except Exception:
                gate.record("BLOCKED", "Bounded Box readback failed (private details withheld)")
                return gate.finish()
            if digest != EXPECTED_SHA:
                gate.record("BLOCKED", "Original Box encrypted object SHA-256 no longer matches the accepted pin")
                return gate.finish()
            gate.record("PASS", f"One bounded Box transfer to tmpfs: 358680-byte candidate SHA-256 verified={size == 358680}")
            if size != 358680:
                gate.record("BLOCKED", "Original Box archive size changed unexpectedly")
                return gate.finish()

            stage = "secure offline identity and payload verification"
            with recovery_ux.acquire_offline_identity(
                cfg.offline_recovery_recipient, sensitive_root=private,
                ui=recovery_ux.UI(color=False)
            ) as identity:
                if identity is None:
                    gate.cancelled = True
                    gate.record("PENDING", "Operator cancelled offline Age identity selection; no persistent state changed")
                    return gate.finish()
                gate.record("PASS", "Original offline private Age identity matches accepted public recipient")
                extracted = private / "decrypted"
                extracted.mkdir(mode=0o700)
                manifest = recovery._decrypt_and_validate(file, identity, extracted, runner=recovery.run_command)
                recovered_config, recovered_recipient = recovery._validate_offline_sops(
                    extracted / "payload", identity, runner=recovery.run_command
                )
                if recovered_recipient != cfg.offline_recovery_recipient:
                    gate.record("BLOCKED", "Restored offline public recipient differs")
                    return gate.finish()
                database = extracted / "payload/data/db.sqlite3"
                if not p2.sqlite_snapshot_integrity(database):
                    gate.record("BLOCKED", "Original recovered SQLite integrity verification failed")
                    return gate.finish()
                database_sha = hashlib.sha256(database.read_bytes()).hexdigest()
                offsite, pruning, days_local, days_remote = p2.preview_policy(recovered_config)
                if pruning:
                    gate.record("BLOCKED", "Recovered backup has positive retention; refuse promotion before policy review")
                    return gate.finish()
                recovery._preflight_targets(recovery.RecoveryPaths(), extracted)
                gate.record("PASS", "Age decryption, exact manifest/checksums, SOPS, SQLite and target capacity passed")
                gate.record("PENDING", f"Recovered backup policy offsite={offsite} retention_days={days_local}/{days_remote}; timers stay disabled")

                print("\n=== DESTRUCTIVE CONSENT: DISPOSABLE TEST VM ONLY ===")
                print("Target host: vaultwarden-oci-6-vnic (NOT a production cutover).")
                print("The following *local test VM* state will be REPLACED:")
                print(" - /etc/vaultwarden-oci/config.toml and secrets.sops.yaml")
                print(" - /var/lib/vaultwarden-oci/data (including SQLite)")
                print(" - Caddy persistent data/config and operational SOPS custody as needed")
                print("Root's Box object will remain unchanged.")
                print("No service, timer, DNS, Worker, mail or reboot will be started.")
                print("Type exact RESTORE to authorize replacement; anything else cancels.")
                stage = "explicit RESTORE authorization"
                answer = input("Authorization [CANCEL]: ")
                if not approve_restore(answer):
                    gate.cancelled = True
                    gate.record("PENDING", "Operator declined RESTORE; no persistent app state changed")
                    return gate.finish()
                gate.record("PASS", "Exact manual RESTORE consent received for this disposable test VM")

                stage = "recheck local authority before persistent mutation"
                if not confirm_isolated(p1, storage, require_empty_database=True):
                    gate.record("BLOCKED", "Storage, running service or database state changed before promotion")
                    return gate.finish()
                if not pristine_backup_dir(STATE / "backups", STATE):
                    gate.record("BLOCKED", "Backup staging changed before promotion")
                    return gate.finish()
                if hashlib.sha256(file.read_bytes()).hexdigest() != EXPECTED_SHA:
                    gate.record("BLOCKED", "Downloaded ciphertext changed before promotion")
                    return gate.finish()

                # From here forward a failure requires investigation; never auto-retry.
                stage = "installed product restore transaction"
                create_empty_backup_dir_after_consent(STATE / "backups", STATE)
                gate.restore_invoked = True
                restored = recovery.restore_recovery(file, identity, start=False)
                gate.promoted = True
                if restored.get("format_version") != 2:
                    gate.record("BLOCKED", "Installed restore owner returned unexpected manifest format")
                    return gate.finish()
                gate.record("PASS", "Installed product restore engine promoted archive with start=False")
                stage = "post-promotion local acceptance"
                okay, message = verify_promoted(
                    p1, p2, runtime, secrets,
                    expected_db_sha=database_sha, expected_recipient=cfg.offline_recovery_recipient,
                )
                gate.record("PASS" if okay else "BLOCKED", message)
                if not okay:
                    return gate.finish()
                gate.record("PASS", "All application/timer/Worker/DNS services remain dormant; no remote uploads/pruning or reboot")
                gate.record("NOT RUN", "Live rc.12 Caddy/TLS, CrowdSec, Cloudflare, SMTP, authenticated client, timer/backup and reboot remain separate approval gates")
                gate.record("PENDING", "Original off-host encrypted ZIP/private key and passphrase still require independent custody attestation")
                gate.postverified = True
                return gate.finish()
    except KeyboardInterrupt:
        gate.record("PENDING" if not gate.restore_invoked else "BLOCKED",
                    f"Operator interrupted during {stage}; no automatic retry or rollback attempted")
        gate.cancelled = not gate.restore_invoked
        return gate.finish()
    except Exception:
        gate.record("BLOCKED", f"Failure at {stage}; private exception details withheld; do not automatically retry")
        return gate.finish()
    finally:
        signal.signal(signal.SIGTERM, old_signal)


if __name__ == "__main__":
    raise SystemExit(main())
