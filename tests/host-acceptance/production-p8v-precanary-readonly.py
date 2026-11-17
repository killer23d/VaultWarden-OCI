#!/usr/bin/env python3
"""P8V-C grouped pre-canary READ-ONLY acceptance.

Runs bounded offline source tests and checks owner-private, independently
reviewed attestations. No OCI/Cloudflare GETs, SSH, guest access, Docker,
firewall refresh, rclone, data reads, DNS/Worker changes or installation.
Manual attestations are not provider proof or external packet-path proof.
"""
from __future__ import annotations

from collections import Counter
from datetime import datetime, timedelta, timezone
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import subprocess
import sys
import tomllib

sys.dont_write_bytecode = True
os.umask(0o077)

ROOT = Path(__file__).resolve().parents[2]
BRANCH = "audit/rc13-p8v-precanary-grouped-readonly-20261117"
SOURCE_SHA = re.compile(r"[0-9a-f]{40}\Z")
PROVIDER_SHA = "358d64373bf79d335b575ec5308ad3821a14df60"
PRODUCTION_FQDN = "bw.lazymocha.com"
PRODUCTION_REMOTE = "bw-backup"
PROTECTED_PATHS = ("/var/lib/vaultwarden-oci", "/root/vaultwarden-recovery")
SAFE_LABEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{1,63}\Z")
DOMAIN_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")
BACKUP = re.compile(r"([A-Za-z][A-Za-z0-9_-]{0,63}):([A-Za-z0-9._/-]{1,200})\Z")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
MAX_INPUT = 32768
FRESH_FOR = timedelta(hours=24)
FUTURE_SKEW = timedelta(minutes=5)

CLOUDFLARE_FLAGS = (
    "zone_ownership_reviewed", "dns_no_wildcards",
    "dns_no_conflicting_proxied_records", "worker_routes_no_overlap",
    "worker_custom_domains_no_overlap", "production_origin_distinct",
    "caddy_tls_source_reviewed",
)
STORAGE_FLAGS = (
    "blank_test_dataset_verified", "separate_dedicated_storage_verified",
    "data_ownership_and_capacity_verified", "backup_destination_approved",
    "backup_remote_permissions_test_only", "backup_prune_restore_test_only",
    "no_production_credentials", "separate_offline_recovery_identity",
)
MANAGEMENT_FLAGS = (
    "current_private_ssh_revalidated", "serial_console_fallback_ready",
    "oci_instance_and_subnet_reconfirmed", "dedicated_security_list_unchanged",
    "rollback_preserves_private_ssh_and_public22_denial",
    "quarantine_without_default_list_reattachment",
    "original_vm_off_limits", "public_tcp80_still_absent",
)
TEMPLATE = {
    "schema_version": 1,
    "review": {
        "observed_utc": None, "operator": None,
        "independent_reviewer": None, "method": None,
    },
    "cloudflare": {
        "zone": None, "test_fqdn": None,
        **{key: None for key in CLOUDFLARE_FLAGS},
    },
    "storage": {
        "test_data_path": None, "test_backup_target": None,
        **{key: None for key in STORAGE_FLAGS},
    },
    "management": {key: None for key in MANAGEMENT_FLAGS},
}


class PrivateEvidenceError(ValueError):
    """Only constant, sanitized reason codes may be surfaced."""


def add(rows: list[tuple[str, str]], status: str, reason: str) -> None:
    if status not in ("PASS", "PENDING", "BLOCKED", "NOT RUN"):
        raise ValueError("invalid controlled verdict")
    if not re.fullmatch(r"[a-z][a-z0-9-]{1,100}", reason):
        raise ValueError("unsafe verdict reason")
    rows.append((status, reason))


def git_pinned(sha: str) -> bool:
    if not SOURCE_SHA.fullmatch(sha) or ROOT.is_symlink() or not (ROOT / ".git").is_dir():
        return False
    outputs: list[str] = []
    for args in (
        ("rev-parse", "HEAD"),
        ("symbolic-ref", "--quiet", "--short", "HEAD"),
        ("status", "--porcelain", "--untracked-files=all"),
    ):
        try:
            p = subprocess.run(
                ["git", *args], cwd=ROOT, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                env={**os.environ, "GIT_OPTIONAL_LOCKS": "0", "GIT_PAGER": "cat"},
                timeout=25, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        if p.returncode != 0 or len(p.stdout) > 8192:
            return False
        outputs.append(p.stdout.decode("utf-8", "replace").strip())
    return outputs == [sha, BRANCH, ""]


def private_dir() -> Path:
    folder = Path.home() / "vwoci-acceptance"
    try:
        folder.mkdir(mode=0o700, exist_ok=True)
        st = folder.lstat()
        if (not stat.S_ISDIR(st.st_mode) or folder.is_symlink()
                or st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o700):
            raise PrivateEvidenceError("private-evidence-directory-unsafe")
    except OSError as exc:
        raise PrivateEvidenceError("private-evidence-directory-unavailable") from exc
    return folder


def safe_read(path: Path, folder: Path) -> dict:
    """Never read a link, permissive file, other owner's file or oversized data."""
    try:
        if path.parent.resolve() != folder.resolve():
            raise PrivateEvidenceError("evidence-outside-private-directory")
        st = path.lstat()
        if (not stat.S_ISREG(st.st_mode) or path.is_symlink()
                or st.st_uid != os.geteuid()
                or stat.S_IMODE(st.st_mode) != 0o600
                or not 0 < st.st_size <= MAX_INPUT):
            raise PrivateEvidenceError("evidence-file-not-owner-private")
        raw = path.read_bytes()
        if len(raw) > MAX_INPUT:
            raise PrivateEvidenceError("evidence-file-oversized")
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise PrivateEvidenceError("evidence-schema-invalid")
        return value
    except FileNotFoundError as exc:
        raise PrivateEvidenceError("evidence-not-provided") from exc
    except (UnicodeError, ValueError, OSError) as exc:
        if isinstance(exc, PrivateEvidenceError):
            raise
        raise PrivateEvidenceError("evidence-unreadable-or-invalid") from exc


def make_template(path: Path, folder: Path) -> bool:
    if path.parent.resolve() != folder.resolve():
        raise PrivateEvidenceError("template-path-outside-private-directory")
    try:
        fd = os.open(
            path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600,
        )
    except FileExistsError:
        return False
    except OSError as exc:
        raise PrivateEvidenceError("private-template-creation-failed") from exc
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(TEMPLATE, handle, indent=2)
        handle.write("\n")
    return True


def validate_source(rows: list[tuple[str, str]]) -> None:
    """Source-only checks; never assert deployed/runtime or packet proof."""
    try:
        versions = tomllib.loads((ROOT / "versions.toml").read_text("utf-8"))
        if versions["vaultwarden_oci"]["version"] != "0.1.0-rc.13":
            add(rows, "BLOCKED", "rc13-source-release-pin-mismatch")
            return
        images = versions["image_digests"]
        if any(not isinstance(images[name].get(arch), str)
               or not DIGEST.fullmatch(images[name][arch])
               for name in ("vaultwarden", "caddy_builder", "caddy_runtime")
               for arch in ("amd64", "arm64")):
            add(rows, "BLOCKED", "immutable-image-digest-invalid")
            return
        add(rows, "PASS", "rc13-source-release-and-six-digests-pinned")
        runtime = (ROOT / "vaultwarden_oci/runtime.py").read_text("utf-8")
        expected = (
            "trusted_proxies cloudflare", "trusted_proxies_strict",
            "client_ip_headers CF-Connecting-IP",
            "dns cloudflare {{env.CLOUDFLARE_API_TOKEN}}",
            "@admin path /admin*", "enable_ipv6: true",
        )
        add(rows, "PASS" if all(term in runtime for term in expected) else "BLOCKED",
            "caddy-tls-and-dual-stack-source-template-only")
    except (OSError, UnicodeError, KeyError, TypeError, ValueError):
        add(rows, "BLOCKED", "source-release-or-caddy-validation-unavailable")


def test_suite(rows: list[tuple[str, str]]) -> None:
    """One grouped test call per reviewed fixture; stdout/stderr suppressed."""
    patterns = (
        "test_production_p8v_precanary.py",
        "test_cloudflare_api_policy.py",
        "test_edge.py",
        "test_edge_blockers.py",
        "test_production_p8v_oci_provider_batch.py",
    )
    for name in patterns:
        try:
            p = subprocess.run(
                [sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests",
                 "-p", name],
                cwd=ROOT, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=180, check=False,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": str(ROOT)},
            )
            log = (p.stdout + p.stderr).decode("utf-8", "replace")
            match = re.search(r"Ran (\d+) tests? in", log)
            if (p.returncode == 0 and match is not None and int(match.group(1)) > 0
                    and len(p.stdout) + len(p.stderr) < 131072):
                add(rows, "PASS", "offline-tests-" + name.removesuffix(".py").replace("_", "-"))
            else:
                add(rows, "BLOCKED", "offline-tests-failed-" + name.removesuffix(".py").replace("_", "-"))
        except (OSError, subprocess.TimeoutExpired):
            add(rows, "PENDING", "offline-tests-unavailable-" + name.removesuffix(".py").replace("_", "-"))


def fqdn_status(zone: object, fqdn: object) -> tuple[str, str]:
    if zone is None or fqdn is None:
        return "PENDING", "test-zone-or-fqdn-unselected"
    if not all(isinstance(x, str) and 0 < len(x) <= 253 for x in (zone, fqdn)):
        return "BLOCKED", "test-fqdn-or-zone-invalid"
    if not all(len(v.split(".")) >= 2 and all(DOMAIN_LABEL.fullmatch(part) for part in v.split("."))
               for v in (zone, fqdn)):
        return "BLOCKED", "test-fqdn-or-zone-invalid"
    if fqdn == zone or not fqdn.endswith("." + zone):
        return "BLOCKED", "test-fqdn-outside-selected-zone"
    if (fqdn == PRODUCTION_FQDN or fqdn.endswith("." + PRODUCTION_FQDN)
            or PRODUCTION_FQDN.endswith("." + fqdn)):
        return "BLOCKED", "test-fqdn-collides-with-production-host"
    return "PASS", "test-fqdn-lexically-distinct-from-production"


def data_path_status(path: object) -> tuple[str, str]:
    if path is None:
        return "PENDING", "canary-data-path-unselected"
    if (not isinstance(path, str) or not path.startswith("/")
            or path.startswith("//") or "//" in path or len(path) > 512
            or path.endswith("/") or "\x00" in path):
        return "BLOCKED", "canary-data-path-invalid"
    parts = PurePosixPath(path).parts
    if any(part in (".", "..") for part in path.split("/")) or len(parts) < 3:
        return "BLOCKED", "canary-data-path-invalid"
    target = PurePosixPath(path)
    for name in PROTECTED_PATHS:
        protected = PurePosixPath(name)
        if target == protected or target in protected.parents or protected in target.parents:
            return "BLOCKED", "canary-data-overlaps-protected-state"
    return "PASS", "canary-data-path-no-lexical-overlap-only"


def backup_status(target: object) -> tuple[str, str]:
    if target is None:
        return "PENDING", "canary-backup-target-unselected"
    if not isinstance(target, str):
        return "BLOCKED", "canary-backup-target-invalid"
    found = BACKUP.fullmatch(target)
    if not found:
        return "BLOCKED", "canary-backup-target-invalid"
    remote, prefix = found.group(1).lower(), found.group(2)
    components = prefix.split("/")
    if remote == PRODUCTION_REMOTE or any(
        segment in ("", ".", "..", "bw-backup") for segment in components
    ):
        return "BLOCKED", "canary-backup-overlaps-protected-remote"
    if len(components) < 1 or prefix.startswith("/"):
        return "BLOCKED", "canary-backup-target-invalid"
    return "PASS", "canary-backup-alias-and-prefix-lexically-distinct-only"


def fresh_review(value: object, *, now: datetime | None = None) -> tuple[str, str]:
    if not isinstance(value, dict):
        return "PENDING", "independent-review-not-provided"
    if set(value) != {"observed_utc", "operator", "independent_reviewer", "method"}:
        return "PENDING", "independent-review-schema-incomplete"
    actor, checker = value["operator"], value["independent_reviewer"]
    if (not isinstance(actor, str) or not SAFE_LABEL.fullmatch(actor)
            or not isinstance(checker, str) or not SAFE_LABEL.fullmatch(checker)
            or actor == checker
            or value["method"] not in ("dashboard-two-person", "api-readonly-two-person")):
        return "PENDING", "independent-review-corroboration-missing"
    stamp = value["observed_utc"]
    try:
        if not isinstance(stamp, str) or not stamp.endswith("Z"):
            raise ValueError("UTC required")
        observed = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        if observed.utcoffset() != timedelta(0):
            raise ValueError("UTC required")
    except ValueError:
        return "PENDING", "independent-review-date-invalid"
    current = now or datetime.now(timezone.utc)
    age = current - observed
    if age > FRESH_FOR or age < -FUTURE_SKEW:
        return "PENDING", "independent-review-not-current"
    return "PASS", "independent-review-attestation-current-manual-only"


def attest_flags(rows: list[tuple[str, str]], group: object,
                 flags: tuple[str, ...], label: str, *, corroborated: bool = True) -> None:
    if not isinstance(group, dict):
        add(rows, "PENDING", label + "-section-not-provided")
        return
    for field in flags:
        outcome = "PASS" if group.get(field) is True and corroborated else (
            "BLOCKED" if group.get(field) is False else "PENDING"
        )
        add(rows, outcome, label + "-" + field.replace("_", "-"))


def validate_attestation(rows: list[tuple[str, str]], doc: dict) -> None:
    if set(doc) != {"schema_version", "review", "cloudflare", "storage", "management"} or doc.get("schema_version") != 1:
        add(rows, "PENDING", "precanary-attestation-schema-incomplete")
        return
    review_status, review_reason = fresh_review(doc["review"])
    add(rows, review_status, review_reason)
    corroborated = review_status == "PASS"
    cloudflare = doc["cloudflare"]
    if isinstance(cloudflare, dict):
        add(rows, *fqdn_status(cloudflare.get("zone"), cloudflare.get("test_fqdn")))
    else:
        add(rows, "PENDING", "test-zone-or-fqdn-unselected")
    attest_flags(rows, cloudflare, CLOUDFLARE_FLAGS, "cloudflare", corroborated=corroborated)
    storage = doc["storage"]
    if isinstance(storage, dict):
        add(rows, *data_path_status(storage.get("test_data_path")))
        add(rows, *backup_status(storage.get("test_backup_target")))
    else:
        add(rows, "PENDING", "canary-storage-section-not-provided")
    attest_flags(rows, storage, STORAGE_FLAGS, "storage", corroborated=corroborated)
    attest_flags(rows, doc["management"], MANAGEMENT_FLAGS, "management", corroborated=corroborated)
    add(rows, "PENDING", "manual-attestation-never-proves-host-path-or-packet-denial")


def validate_provider(rows: list[tuple[str, str]], doc: dict) -> None:
    raw = doc.get("sanitized_rows")
    if (doc.get("schema") != 1 or doc.get("source") != PROVIDER_SHA
            or doc.get("outcome") != "HOLD" or not isinstance(raw, list)):
        add(rows, "PENDING", "historical-provider-report-schema-or-source-mismatch")
        return
    if not all(isinstance(item, list) and len(item) == 2
               and item[0] in ("PASS", "PENDING", "BLOCKED", "NOT RUN")
               and isinstance(item[1], str) for item in raw):
        add(rows, "PENDING", "historical-provider-report-row-schema-invalid")
        return
    counts = Counter(item[0] for item in raw)
    if counts != Counter({"PASS": 16, "PENDING": 12, "BLOCKED": 0, "NOT RUN": 1}):
        add(rows, "PENDING", "historical-provider-report-counts-unexpected")
        return
    add(rows, "PASS", "historical-scoped-oci-evidence-reused-20261117")
    add(rows, "PENDING", "provider-snapshot-not-fresh-live-origin-proof")


def write_summary(folder: Path, sha: str, rows: list[tuple[str, str]],
                  verdict: str) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    target = folder / ("p8v-precanary-" + stamp + "-" + str(os.getpid()) + ".json")
    fd = os.open(
        target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600,
    )
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump({"schema_version": 1, "source": sha, "observed_utc": stamp,
                   "outcome": verdict, "sanitized_rows": rows}, out, indent=2)
        out.write("\n")
    return target


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="P8V-C read-only grouped source and scope attestation")
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--provider-report", type=Path, required=True)
    parser.add_argument("--attestation", type=Path, required=True)
    parser.add_argument("--create-template", action="store_true")
    args = parser.parse_args(argv)
    if (platform.system() != "Linux" or os.geteuid() == 0
            or sys.version_info < (3, 12) or not git_pinned(args.expected_sha)):
        print("BLOCKED/2: require non-root Linux Python 3.12+ and exact clean reviewed branch/SHA")
        return 2
    try:
        folder = private_dir()
    except PrivateEvidenceError:
        print("HOLD/1: owner-private evidence directory unavailable or unsafe")
        return 1
    rows: list[tuple[str, str]] = []
    if args.create_template:
        try:
            created = make_template(args.attestation, folder)
            add(rows, "PASS" if created else "PENDING",
                "owner-private-blank-template-created" if created else "existing-template-left-unaltered")
        except PrivateEvidenceError:
            add(rows, "PENDING", "owner-private-template-unavailable")
    validate_source(rows)
    test_suite(rows)
    try:
        validate_provider(rows, safe_read(args.provider_report, folder))
    except PrivateEvidenceError:
        add(rows, "PENDING", "historical-oci-evidence-not-reusable")
    try:
        validate_attestation(rows, safe_read(args.attestation, folder))
    except PrivateEvidenceError:
        add(rows, "PENDING", "precanary-attestation-missing-or-unsafe")
    add(rows, "PENDING", "host-stopped-state-last-verified-20261113-not-current")
    add(rows, "NOT RUN", "no-provider-write-app-start-backup-or-external-canary")
    state = "BLOCKED" if any(status == "BLOCKED" for status, _ in rows) else "HOLD"
    try:
        saved = write_summary(folder, args.expected_sha, rows, state)
    except OSError:
        print("HOLD/1: unable to write owner-private report")
        return 1
    print("P8V PRECANARY: " + ("BLOCKED/2" if state == "BLOCKED" else "HOLD/1"))
    for status, reason in rows:
        print(status + ": " + reason)
    counts = Counter(status for status, _ in rows)
    print("Sanitized counts:", {x: counts.get(x, 0)
                                for x in ("PASS", "PENDING", "BLOCKED", "NOT RUN")})
    print("Private report:", saved)
    print("No provider or host actions, external packet proof or production authorization.")
    return 2 if state == "BLOCKED" else 1


if __name__ == "__main__":
    raise SystemExit(main())
