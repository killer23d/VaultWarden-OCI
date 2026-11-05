#!/usr/bin/env python3
"""P8Q: inspect why the real P8P NEW-VM postboot snapshot BLOCKED.

This is an independent, source-pinned, read-only diagnostic. It imports the
exact reviewed P8P checkout to reuse its acceptance contract, then checks
small groups independently. The only writes are a sanitized summary and the
pre-existing product doctor's root-private diagnostic log. No repairs.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import os
import platform
import pwd
import re
import stat
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

HOST = "vaultwarden-oci-7-vnic"
BRANCH = "audit/rc12-p8q-postboot-blocker-readonly"
SRC = Path(__file__).resolve().parents[2]
PRIOR = Path("/home/ubuntu/VaultWarden-OCI-p8p-f17df88")
PRIOR_BRANCH = "audit/rc12-p8p-batched-reboot-persistence-newvm"
PRIOR_SHA = "f17df88f0c0720be062efcc13cb35080cd0d7ac9"
PRIOR_SCRIPT = PRIOR / "tests/host-acceptance/production-p8p-batched-reboot-persistence-newvm.py"
EVIDENCE = Path("/home/ubuntu/vwoci-acceptance")
SHA40 = re.compile(r"[0-9a-f]{40}\Z")
GOOD_STATES = frozenset({"PASS", "PENDING", "BLOCKED", "NOT RUN"})


class Blocked(RuntimeError):
    pass


def git_clean(repo: Path, branch: str, pin: str) -> bool:
    if not SHA40.fullmatch(pin) or repo.is_symlink() or not repo.is_dir():
        return False
    output = []
    for args in (("rev-parse", "HEAD"), ("symbolic-ref", "--quiet", "--short", "HEAD"),
                 ("status", "--porcelain", "--untracked-files=all")):
        try:
            proc = subprocess.run(
                ["/usr/bin/git", *args], stdin=subprocess.DEVNULL, cwd=repo,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=20, check=False,
                env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat"),
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        if proc.returncode != 0 or len(proc.stdout) > 8192:
            return False
        output.append(proc.stdout.decode("utf-8", "replace").strip())
    return output == [pin, branch, ""]


def host_ok() -> bool:
    if (os.geteuid() != 0 or os.getenv("SUDO_USER") != "ubuntu"
            or platform.node().split(".")[0] != HOST
            or platform.machine() not in ("aarch64", "arm64")
            or sys.version_info[:2] != (3, 14)):
        return False
    try:
        info = dict(row.split("=", 1) for row in
                    Path("/etc/os-release").read_text(encoding="utf-8").splitlines()
                    if "=" in row)
        return (info.get("ID", "").strip('"') == "ubuntu"
                and info.get("VERSION_ID", "").strip('"') == "26.04")
    except (OSError, ValueError):
        return False


def checked_helper(path: Path, name: str):
    if not path.is_file() or path.is_symlink():
        raise Blocked("reviewed acceptance helper absent")
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise Blocked("reviewed acceptance helper unreadable")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def evidence_root_ok() -> bool:
    try:
        home = Path(pwd.getpwnam("ubuntu").pw_dir)
        if home.is_symlink() or not home.is_dir():
            return False
        meta = EVIDENCE.lstat()
        return (stat.S_ISDIR(meta.st_mode)
                and meta.st_uid in (0, pwd.getpwnam("ubuntu").pw_uid)
                and stat.S_IMODE(meta.st_mode) == 0o700
                and not EVIDENCE.is_symlink())
    except (OSError, KeyError):
        return False


def init_report_dir() -> Path:
    suffix = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder = EVIDENCE / ("p8q-postboot-readonly-" + suffix + "-" + str(os.getpid()))
    folder.mkdir(mode=0o700)
    if folder.lstat().st_uid != 0:
        raise Blocked("diagnostic evidence is not root private")
    return folder


def write_summary(path: Path, content: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    dfd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


class Report:
    def __init__(self, folder: Path):
        self.folder = folder
        self.rows: list[tuple[str, str]] = []
        self.states: dict[str, str] = {}
        self.detail_ids: list[str] = []

    def record(self, key: str, outcome: str) -> None:
        if (key in self.states or not re.fullmatch(r"[a-z0-9_.-]{3,78}", key)
                or outcome not in GOOD_STATES):
            raise Blocked("unsafe diagnostic record")
        self.states[key] = outcome
        self.rows.append((outcome, key))

    def check(self, key: str, evaluator, *, needs: tuple[str, ...] = ()) -> bool:
        if any(self.states.get(dep) != "PASS" for dep in needs):
            self.record(key, "NOT RUN")
            return False
        try:
            result = evaluator()
            if result in (True, "PASS"):
                state = "PASS"
            elif result == "PENDING":
                state = "PENDING"
            else:
                state = "BLOCKED"
        except Exception:
            # Never echo raw Python error: exceptions may contain filenames,
            # config values or secret-bearing subprocess output.
            state = "BLOCKED"
        self.record(key, state)
        return state == "PASS"

    def finish(self) -> int:
        blocked = any(level == "BLOCKED" for level, _ in self.rows)
        verdict = "BLOCKED" if blocked else "READONLY"
        self.rows.append((verdict, "p8q.no-mutation.no-reboot.no-rearm.no-box.no-live-go"))
        body = "Gate P8Q - NEW disposable VM independent P8P postboot blocker diagnosis (READ-ONLY)\n"
        body += "".join(f"{level:<10} {key}\n" for level, key in self.rows)
        try:
            write_summary(self.folder / "summary.txt", body)
        except OSError:
            print("BLOCKED: unable to persist root-private sanitized summary")
            return 2
        print(body, end="")
        print("Private summary:", self.folder / "summary.txt")
        print("Paste ONLY this sanitized P8Q summary and P8Q_EXIT.")
        print("Never paste full doctor JSON, config, journal, original checkpoint, private keys or debug logs.")
        return 2 if blocked else 0


def stopped_app_units(p8p, install) -> bool:
    units = tuple(install.SYSTEMD_UNITS)
    if len(units) != 12 or "vaultwarden-oci-notify@.service" not in units:
        return False
    for unit in units:
        if unit.endswith("@.service"):
            continue
        data = p8p.systemd_state(unit)
        if (data.get("LoadState") != "loaded"
                or data.get("ActiveState") != "inactive"
                or data.get("UnitFileState") in
                ("enabled", "enabled-runtime", "linked", "linked-runtime")):
            return False
    return True


def notify_template_off(p8p) -> bool:
    code, present = p8p.run([
        "/usr/bin/systemctl", "list-units", "--all", "--no-legend",
        "--plain", "--full", "vaultwarden-oci-notify@*.service",
    ])
    code2, files = p8p.run([
        "/usr/bin/systemctl", "list-unit-files", "--all", "--no-legend",
        "--plain", "vaultwarden-oci-notify@*.service",
    ])
    return (code == 0 and not present.strip() and code2 == 0
            and [x.split()[:2] for x in files.splitlines()]
            == [["vaultwarden-oci-notify@.service", "static"]])


def listeners_closed(p8p) -> bool:
    code, sockets = p8p.run(["/usr/bin/ss", "-H", "-lnt"])
    if code != 0:
        return False
    for raw in sockets.splitlines():
        cols = raw.split()
        port = re.search(r":([0-9]{1,5})$", cols[3]) if len(cols) >= 5 else None
        if port is None or int(port.group(1)) in (80, 443, 2375, 2376):
            return False
    return True


def containers_absent(p8p) -> bool:
    code, names = p8p.run(
        ["/usr/bin/docker", "ps", "-a", "--format", "{{.ID}}"], timeout=35
    )
    if code != 0 or names.strip():
        return False
    meta = Path("/var/lib/docker/containers")
    if not (meta.exists() or meta.is_symlink()):
        return True
    return not meta.is_symlink() and meta.is_dir() and not any(meta.iterdir())


def security_unit(p8p, unit: str, *, active: str, enablement: str) -> bool:
    state = p8p.systemd_state(unit)
    return (state.get("LoadState") == "loaded"
            and state.get("ActiveState") == active
            and state.get("UnitFileState") == enablement)


def config_ok(p8p, cfg) -> bool:
    return (
        cfg.domain == p8p.DOMAIN
        and cfg.acme_email == p8p.EMAIL
        and p8p.sha_bytes(cfg.offline_recovery_recipient.encode()) == p8p.RECIPIENT_SHA
        and cfg.offsite_remote == p8p.REMOTE
        and type(cfg.local_retention_days) is int
        and type(cfg.remote_retention_days) is int
        and cfg.local_retention_days == 0
        and cfg.remote_retention_days == 0
        and not cfg.smtp_accept_invalid_certs
        and not cfg.smtp_accept_invalid_hostnames
    )


def secured_secrets(secrets, cfg) -> bool:
    secrets.validate_custody(cfg.offline_recovery_recipient)
    values = secrets.validate_encrypted(cfg.offline_recovery_recipient)
    try:
        return (isinstance(values, dict) and secrets.admin_enabled(values)
                and bool(values.get("cloudflare_remediation_token")))
    finally:
        del values


def storage_ok(p8p, storage) -> bool:
    proof = storage.verify()
    storage.reject_boot_related(proof.source)
    return (proof.fs_type == "ext4"
            and p8p.sha_bytes(proof.uuid.encode())[:12] == p8p.VOLUME_FP
            and os.stat(p8p.STATE).st_dev != os.stat("/").st_dev)


def private_doctor(p8p, p5, folder: Path, report: Report) -> dict[str, str] | None:
    try:
        decision, statuses, _ = p5.diagnose_doctor(folder, "p8q-classified", seconds=180)
        ids = tuple(p5.product_doctor_ids())
        valid = (
            decision == "valid" and len(ids) == 27 and len(set(ids)) == 27
            and set(statuses) == set(ids)
            and all(value in ("PASS", "WARN", "FAIL", "SKIP")
                    for value in statuses.values())
        )
        if not valid:
            report.record("doctor.27-id-schema", "BLOCKED")
            return None
        report.record("doctor.27-id-schema", "PASS")
        for name in ids:
            status = statuses[name]
            if name in p8p.MANDATORY:
                verdict = "PASS" if status == "PASS" else "BLOCKED"
            elif name == "crowdsec.cloudflare":
                verdict = "PASS" if status == "FAIL" else "BLOCKED"
            elif name in ("runtime.paths", "edge.cloudflare.iptables"):
                verdict = "PASS" if status == "PASS" else ("PENDING" if status == "FAIL" else "BLOCKED")
            elif name in p8p.FOUNDATION:
                verdict = "PASS" if status == "PASS" else "BLOCKED"
            else:
                verdict = "BLOCKED" if status == "FAIL" else (
                    "PENDING" if status in ("WARN", "SKIP") else "PASS"
                )
            report.record("doctor." + name, verdict)
        return statuses
    except Exception:
        report.record("doctor.27-id-schema", "BLOCKED")
        return None


def main() -> int:
    args = sys.argv[1:]
    if (len(args) != 2 or args[0] != "--expected-commit"
            or not SHA40.fullmatch(args[1]) or not host_ok()
            or not git_clean(SRC, BRANCH, args[1])
            or not git_clean(PRIOR, PRIOR_BRANCH, PRIOR_SHA)
            or not PRIOR_SCRIPT.is_file() or PRIOR_SCRIPT.is_symlink()
            or not evidence_root_ok()):
        print("BLOCKED: exact reviewed P8Q/P8P checkout, host, sudo or private evidence precondition failed")
        return 2
    try:
        p8p = checked_helper(PRIOR_SCRIPT, "p8q_exact_reviewed_p8p")
        if (p8p.HOST != HOST or p8p.BRANCH != PRIOR_BRANCH
                or p8p.P8O_COMMIT != "f989f2c91a1276501aab126443b96d593261e54e"
                or p8p.SRC != PRIOR or not p8p.source_clean(PRIOR_SHA)):
            raise Blocked("reviewed P8P source constants inconsistent")
        folder = init_report_dir()
    except Exception:
        print("BLOCKED: exact P8P source import or private P8Q evidence directory unsafe")
        return 2

    report = Report(folder)
    ctx: dict[str, object] = {}
    report.record("source.exact-reviewed-p8p", "PASS")
    report.check("prior.p8o-foundation-evidence", lambda: p8p.accepted_p8o() is None)
    def check_checkpoint():
        value = p8p.checkpoint_read()
        if (value.get("phase") != "requested"
                or value.get("reviewed_commit") != PRIOR_SHA):
            return False
        ctx["checkpoint"] = value
        return True
    report.check("reboot.root-private-checkpoint", check_checkpoint)
    report.check("reboot.changed-kernel-boot-id",
                 lambda: p8p.boot_id() != ctx["checkpoint"]["original_boot_id"],
                 needs=("reboot.root-private-checkpoint",))
    report.check("release.immutable-current-link",
                 lambda: p8p.CURRENT.is_symlink()
                 and p8p.CURRENT.resolve(strict=True) == p8p.INSTALLED)

    def imports():
        sys.path.insert(0, str(p8p.INSTALLED))
        from vaultwarden_oci import install, runtime, secrets, storage
        ctx.update({"install": install, "runtime": runtime,
                    "secrets": secrets, "storage": storage})
        ctx["p1"] = p8p.load_helper(p8p.P1_FILE, "p8q_source_integrity")
        ctx["p5"] = p8p.load_helper(p8p.P5_FILE, "p8q_prior_doctor")
        return True
    report.check("release.imported-original-witnesses", imports,
                 needs=("release.immutable-current-link",))
    report.check("release.52-immutable-product-files",
                 lambda: ctx["p1"].release_integrity(p8p.SRC, p8p.INSTALLED) == (True, 52),
                 needs=("release.imported-original-witnesses",))
    report.check("release.12-installed-systemd-definitions",
                 lambda: ctx["p1"].systemd_unit_integrity(p8p.INSTALLED) == (True, 12),
                 needs=("release.imported-original-witnesses",))
    report.check("storage.dedicated-original-ext4",
                 lambda: storage_ok(p8p, ctx["storage"]),
                 needs=("release.imported-original-witnesses",))
    def config():
        cfg = ctx["runtime"].load_config()
        if not config_ok(p8p, cfg):
            return False
        ctx["cfg"] = cfg
        return True
    report.check("config.historical-domain-recipient-smtp-box-no-prune", config,
                 needs=("release.imported-original-witnesses",))
    report.check("secrets.offline-custody-sops-admin-remediation",
                 lambda: secured_secrets(ctx["secrets"], ctx["cfg"]),
                 needs=("config.historical-domain-recipient-smtp-box-no-prune",))
    report.check("sqlite.readonly-integrity-and-historical-sha",
                 lambda: p8p.sqlite_ok(p8p.STATE / "data/db.sqlite3"),
                 needs=("release.imported-original-witnesses",))

    report.check("services.app-dns-timers-disabled-inactive",
                 lambda: stopped_app_units(p8p, ctx["install"]),
                 needs=("release.12-installed-systemd-definitions",))
    report.check("services.notification-template-inactive",
                 lambda: notify_template_off(p8p))
    report.check("network.no-http-or-docker-tcp-listeners",
                 lambda: listeners_closed(p8p))
    report.check("docker.no-retained-or-running-containers",
                 lambda: containers_absent(p8p))
    report.check("updates.no-recovery-required-guard",
                 lambda: not (p8p.STATE / "state/update-recovery-required.json").exists()
                 and not (p8p.STATE / "state/update-recovery-required.json").is_symlink())
    report.check("security.crowdsec-package",
                 lambda: Path("/usr/bin/cscli").is_file())
    report.check("security.crowdsec-engine-active-enabled",
                 lambda: security_unit(p8p, "crowdsec.service",
                                       active="active", enablement="enabled"))
    report.check("security.crowdsec-input-bouncer-active-enabled",
                 lambda: security_unit(p8p, "crowdsec-firewall-bouncer.service",
                                       active="active", enablement="enabled"))
    report.check("security.cloudflare-worker-disabled-inactive",
                 lambda: security_unit(p8p, "crowdsec-cloudflare-worker-bouncer.service",
                                       active="inactive", enablement="disabled"))

    report.check("os.dpkg-audit-clean",
                 lambda: (lambda x: x[0] == 0 and not x[1].strip())(
                     p8p.run(["/usr/bin/dpkg", "--audit"], timeout=45)))
    report.check("os.run-is-tmpfs",
                 lambda: (lambda res: res[0] == 0 and res[1].strip() == "tmpfs")(
                     p8p.run(["/usr/bin/findmnt", "-n", "-o", "FSTYPE",
                              "--target", "/run"])))
    report.check("os.swap-empty",
                 lambda: (lambda lines: len(lines) == 1 and
                         lines[0].startswith("Filename"))(
                     Path("/proc/swaps").read_text(encoding="ascii").splitlines()))
    def ntp():
        code, text = p8p.run(["/usr/bin/timedatectl", "show",
                              "-p", "NTPSynchronized", "--value"])
        return "PASS" if code == 0 and text.strip().lower() in ("yes", "true", "1") else "PENDING"
    report.check("os.ntp-synchronized", ntp)

    if report.states.get("release.imported-original-witnesses") == "PASS":
        statuses = private_doctor(p8p, ctx["p5"], folder, report)
    else:
        statuses = None
        report.record("doctor.27-id-schema", "NOT RUN")
    def volatile_paths():
        kind, _ = ctx["p5"].inspect_stopped_runtime_paths(ctx["runtime"], ctx["secrets"])
        if kind == "BLOCKED":
            return False
        if statuses is not None and ((statuses.get("runtime.paths") == "PASS") != (kind == "PASS")):
            return False
        return kind
    report.check("runtime.volatile-path-metadata-consistent", volatile_paths,
                 needs=("doctor.27-id-schema",))

    def match_checkpoint_hashes():
        paths = p8p.tracked_paths(ctx["secrets"], ctx["storage"])
        checksums = p8p.digest_paths(paths)
        p8p.compare_paths(ctx["checkpoint"], checksums)
        return True
    report.check("checkpoint.original-file-hashes-match",
                 match_checkpoint_hashes, needs=(
                     "reboot.root-private-checkpoint",
                     "release.imported-original-witnesses",
                     "storage.dedicated-original-ext4",
                     "sqlite.readonly-integrity-and-historical-sha",
                 ))

    # Only re-run the original all-in-one witness when the independently
    # classified components have no blocked state. Its methods are read-only
    # except writing root-private doctor evidence in the P8Q report folder.
    def parity():
        inner = p8p.Report(folder, "p8q-parity")
        protected = p8p.snapshot(inner, folder, after_boot=True)
        p8p.compare_paths(ctx["checkpoint"], protected)
        return True
    if "BLOCKED" not in report.states.values() and "NOT RUN" not in report.states.values():
        report.check("original-p8p.snapshot-parity", parity)
    else:
        report.record("original-p8p.snapshot-parity", "NOT RUN")

    report.record("not-run.reboot-firewall-start-cloud-box-timers", "NOT RUN")
    return report.finish()


if __name__ == "__main__":
    raise SystemExit(main())
