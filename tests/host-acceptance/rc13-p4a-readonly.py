#!/usr/bin/env python3
"""Temporary P4-A software-facing read-only acceptance (remove before merge).

Only inspects the already installed disposable rc.13 appliance and issues three
UNAUTHENTICATED HTTPS GETs to its PRIVATE Caddy container endpoint. It neither
retrieves nor prints secrets, sends SMTP, mutates application data, manages
systemd/Docker, uploads/changes remote objects, or touches public DNS/Cloudflare.
A running web request can append ordinary application/access logs.

This test cannot prove real client synchronization, Admin browser navigation,
or independently received email. Record those separately; do not promote this
temporary one-host tool into permanent site tooling.
"""
from __future__ import annotations

import fcntl
import hashlib
import ipaddress
import json
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

SOURCE = "fd56313255c97992dc55c1475d94477597b88602"
EXPECTED_BLOBS = json.loads(r'''{"email-providers.toml":"b03abb359666f42128485b674363ce0282e68958","systemd/vaultwarden-oci-backup.service":"5d228a087b8e5230c67146cf932d14fd358faab5","systemd/vaultwarden-oci-backup.timer":"ac950294ba3e6eb3e1847f0362fc7de7e7be7bcb","systemd/vaultwarden-oci-dns.service":"3a7ced674787ec6887b03ccc1b7ab088449423d7","systemd/vaultwarden-oci-health.service":"96d30be45efa3edd2c723c328068c04188b7a345","systemd/vaultwarden-oci-health.timer":"722bb0e12bd38fae956b89a6b26054ac2e9b757b","systemd/vaultwarden-oci-maintenance.service":"678f36973717458c4d346f58deda696f13d663c3","systemd/vaultwarden-oci-maintenance.timer":"6e8a8aa0ee8569bb4dd8b8bc9ac87c2364d111e0","systemd/vaultwarden-oci-notify@.service":"9c648cb5f2f39b3e64182131be96d66f9f045937","systemd/vaultwarden-oci-update-check.service":"14f78a700bcacf7dd3d0c0575012cf4e7fc7d584","systemd/vaultwarden-oci-update-check.timer":"dc9c060ac638fe5476664c5e107e6a5c7d60cdad","systemd/vaultwarden-oci.service":"44bcc9f1b944cffdb17407fcba4b06a02b9c4b9e","systemd/vaultwarden-oci.target":"3c979092f6c35ac8cd3e05e653316851db3b2ee7","vaultwarden_oci/__init__.py":"f18a4246d38c92666bc9a300922e0f1b1316ac18","vaultwarden_oci/admin.py":"714fa189ec7f0d0739178eac320b1956d5cb7e3d","vaultwarden_oci/cli.py":"6bf4793ef2d6a8babf1d0fd6900b0203aaa52397","vaultwarden_oci/crowdsec_worker_policy.py":"e132dcce6a102849da058e79bf6cd31236a219e6","vaultwarden_oci/dashboard.py":"de4ca05a144fd9f1f33c3deb49766f9f8e5b5ade","vaultwarden_oci/dashboard.sh":"efd26b8f871fde8a525c009dad5e7995af874343","vaultwarden_oci/dns_publication.py":"5a10ddfc2768bb5d7a404b6bce94218a0d3faf6a","vaultwarden_oci/durability.py":"abce24778aad3c9204e427995d298f33e9bbf7b0","vaultwarden_oci/edge.py":"9a8759d8c5a8428582d87891629197d2a4687b71","vaultwarden_oci/install.py":"5c43d5ae17e18b5806b20f36a21b8862a139487f","vaultwarden_oci/notification.py":"b780184e11cd678bb6996639e3fb6fe2251110c3","vaultwarden_oci/offsite.py":"276a6cccb1115db24f0adb31ee8ebdaf67e0c6f1","vaultwarden_oci/operations.py":"f7e085c832625a85714ca0dfdf7eaa45f17e48ca","vaultwarden_oci/operator_cosmetics.py":"7c6d85f7911e9fba2c10ada48cf03463ebf2cd14","vaultwarden_oci/operator_entrypoint.py":"c5f1ef1c24f27851d5e0f325db8342aa0e926a11","vaultwarden_oci/operator_output.py":"a346ba8c75b3a0f08bb06051791f848f52495698","vaultwarden_oci/operator_settings.py":"6e5dcb02f40e5c1fd5b90641655482e4f6d217d3","vaultwarden_oci/predecessor_transition.py":"42b7694a76f392949629b2f5a87af97926eefa8a","vaultwarden_oci/recovery.py":"0d4c0f55dc8406232793f7b64968382a8f965c0a","vaultwarden_oci/recovery_ux.py":"735a73bf672d3cf6e8423de9721f4db2f0582720","vaultwarden_oci/runtime.py":"96bfe7db6d2f44e1f2a52cb9f98302f25827e7a0","vaultwarden_oci/runtime_health.py":"f0d5c0666afac828a5d234c48164f121082f73b0","vaultwarden_oci/secrets.py":"665c2930a3466b1cb16b981ae66f662d26c2ea48","vaultwarden_oci/setup.py":"121b4e2ec10d093165bdde50d0e48f5cda738596","vaultwarden_oci/setup_frontend.py":"00f8f969abfa93a89d565dd167e5b5bfbc6955d9","vaultwarden_oci/sevenzip_secure.py":"d7fd25e6f94bb2c46a3bd08e637506760a198a11","vaultwarden_oci/storage.py":"02b7965abfde9d673e6ac94536ab19ec0d9632cd","vaultwarden_oci/update.py":"898e7d2a90ba88d572bb1a5ceba47e99fc8dda97","vaultwarden_oci/update_appliance.py":"e14fd160f5df77fd3256c9406016b6897311f8ce","vaultwarden_oci/update_candidate.py":"bb192a63f94d5a82136cc2ff6b0c10ff10127304","vaultwarden_oci/update_cli.py":"fb861650696d2e524f21805530b10e6b32abca6f","vaultwarden_oci/update_controller_handoff.py":"6b1a9922de72ad9a160f522ad476c91bd03d7a30","vaultwarden_oci/update_guard.py":"bd959adec7c877384455f6ee0f85ed67f3558e4c","vaultwarden_oci/update_recovery.py":"b83f0a5a99f9559c6fb2a7c583f3af388f026379","vaultwarden_oci/update_status.py":"04ed15874281a9dc10275a6c31c70470ed903a3e","vaultwarden_oci/update_unit_migration.py":"3406d490c9f4f838e247558ac3830dd8a5c05630","vaultwarden_oci/update_versions.py":"fdf034f8d5dd14dd38ae74f37803c6158c92c105","versions.toml":"9035d3428daadee4c35087bdc05e8a7f106fe0c3","vwctl":"e3574728a7fdf184226a04c291253e7e955a550d"}''')
EXPECTED_HOST = "vaultwarden-oci-8"
EXPECTED_UUID = "f4e0bd62-48e7-4745-8987-44b14013216d"
EXPECTED_WORKER_INVOCATION = "a80be9e43af84a24b505b9e4b127abeb"
RELEASE = Path("/opt/vaultwarden-oci/releases/0.1.0-rc.13")
DATA = Path("/var/lib/vaultwarden-oci")
ETC = Path("/etc/vaultwarden-oci")


def hold(reason: str) -> None:
    print("P4_A_EXIT=2 HOLD: " + reason, flush=True)
    raise SystemExit(2)


def passed(message: str) -> None:
    print("PASS: " + message, flush=True)


def run(argv: list[str], *, timeout: int = 35) -> str:
    try:
        result = subprocess.run(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, timeout=timeout,
            cwd="/", check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        hold("read-only command unavailable: " + argv[0])
    if result.returncode != 0:
        hold("read-only command failed: " + argv[0])
    return result.stdout


def unit(name: str) -> dict[str, str]:
    fields = "LoadState,ActiveState,SubState,UnitFileState,InvocationID"
    output = run(["systemctl", "show", name, "--no-pager", "--property=" + fields])
    return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)


def verify_source() -> None:
    try:
        selected = Path("/opt/vaultwarden-oci/current").resolve(strict=True)
        executable = Path("/usr/local/bin/vwctl").resolve(strict=True)
    except OSError:
        hold("immutable release selection missing")
    if selected != RELEASE or executable != RELEASE / "vwctl":
        hold("selected installed release or launcher has drifted")
    found: dict[str, str] = {}
    files = [RELEASE / name for name in ("vwctl", "versions.toml", "email-providers.toml")]
    for folder in ("vaultwarden_oci", "systemd"):
        root = RELEASE / folder
        if not root.is_dir() or root.is_symlink():
            hold("immutable release directory missing/unsafe")
        for item in root.rglob("*"):
            if item.is_symlink():
                hold("immutable release contains symlink")
            if item.is_file():
                files.append(item)
            elif not item.is_dir():
                hold("immutable release contains nonregular entry")
    for item in files:
        try:
            s = item.lstat()
            if not stat.S_ISREG(s.st_mode) or item.is_symlink():
                hold("immutable release file missing/unsafe")
            content = item.read_bytes()
        except OSError:
            hold("immutable source file inaccessible")
        # Git source blob identity: SHA-1("blob <length>\0" + file bytes).
        digest = hashlib.sha1(b"blob " + str(len(content)).encode("ascii")
                              + b"\0" + content).hexdigest()
        found[item.relative_to(RELEASE).as_posix()] = digest
    if found != EXPECTED_BLOBS:
        missing = sorted(set(EXPECTED_BLOBS) - set(found))
        extra = sorted(set(found) - set(EXPECTED_BLOBS))
        drift = sorted(p for p in set(EXPECTED_BLOBS) & set(found)
                       if EXPECTED_BLOBS[p] != found[p])
        # Paths only, never contents or candidate secret values.
        hold(f"installed source differs from tested {SOURCE[:12]}; "
             f"missing={len(missing)} extra={len(extra)} mismatched={len(drift)}")
    passed(f"selected immutable rc.13 release: all {len(found)} files match "
           f"tested Git source {SOURCE}")


def verify_host_and_storage() -> None:
    if len(sys.argv) != 1 or os.geteuid() != 0:
        hold("root sudo -n execution and zero arguments required")
    try:
        expected_user = pwd.getpwnam("ubuntu")
    except KeyError:
        hold("expected operator missing")
    if (os.environ.get("SUDO_USER") != "ubuntu"
            or os.environ.get("SUDO_UID") != str(expected_user.pw_uid)
            or platform.node().split(".")[0] != EXPECTED_HOST
            or platform.machine() != "aarch64"
            or sys.version_info[:2] != (3, 14)):
        hold("operator, host, ARM64 or Python 3.14 mismatch")
    try:
        lines = Path("/etc/os-release").read_text(encoding="utf-8").splitlines()
        distro = dict(line.split("=", 1) for line in lines
                      if "=" in line and not line.startswith("#"))
    except OSError:
        hold("host OS identity unavailable")
    if (distro.get("ID", "").strip('"') != "ubuntu"
            or distro.get("VERSION_ID", "").strip('"') != "26.04"
            or distro.get("VERSION_CODENAME", "").strip('"') != "resolute"):
        hold("expected Ubuntu 26.04 release not present")
    verify_source()
    sys.path.insert(0, str(RELEASE))
    try:
        from vaultwarden_oci import storage
        identity = storage.verify()
        expected_device = Path("/dev/oracleoci/oraclevdb").resolve(strict=True)
        device = Path(identity.source).resolve(strict=True)
        correct = (identity.uuid == EXPECTED_UUID
                   and identity.fs_type == "ext4"
                   and device == expected_device
                   and DATA.is_mount()
                   and DATA.stat().st_dev != Path("/").stat().st_dev)
    except (OSError, ValueError, RuntimeError, storage.StorageError):
        hold("installed storage verification failed")
    if not correct:
        hold("dedicated disk/UUID mismatch or root-volume fallback")
    # Separate block-device UUID check in addition to product dual markers.
    block_uuid = run(["blkid", "-s", "UUID", "-o", "value", str(device)]).strip()
    if block_uuid != EXPECTED_UUID:
        hold("independent block-device UUID mismatch")
    if (DATA / "state/update-recovery-required.json").exists():
        hold("update recovery-required guard present")
    passed("Ubuntu 26.04 ARM64/Python 3.14; approved data device, ext4 UUID,"
           " dual storage markers and independent blkid; no root fallback")


def verify_config() -> str:
    for name in ("config.toml", "secrets.sops.yaml", "age-key.txt"):
        try:
            s = (ETC / name).lstat()
        except OSError:
            hold("protected installed configuration missing")
        if (not stat.S_ISREG(s.st_mode) or s.st_uid != 0
                or stat.S_IMODE(s.st_mode) != 0o600):
            hold("installed config/SOPS/operational identity custody unsafe")
    try:
        with (ETC / "config.toml").open("rb") as handle:
            cfg = tomllib.load(handle)
        site = cfg["site"]["domain"]
        caddy = cfg["caddy"]
        backup = cfg["backup"]
        smtp = cfg.get("smtp", {})
    except (OSError, KeyError, TypeError, ValueError, tomllib.TOMLDecodeError):
        hold("installed config shape invalid")
    if not isinstance(site, str) or not re.fullmatch(
        r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", site
    ):
        hold("invalid HTTPS host identity")
    if (caddy.get("admin_rate_limit_events") != 60
            or caddy.get("admin_rate_limit_window") != "1m"):
        hold("accepted Caddy outer Admin limit is not 60 events/1m")
    if (backup.get("remote", ""), backup.get("local_retention_days"),
            backup.get("remote_retention_days")) != ("", 0, 0):
        hold("previous local-only/zero-retention safety policy changed")
    if not isinstance(smtp, dict):
        hold("SMTP config invalid")
    # Decrypt into memory with the supported owner; never display values.
    try:
        from vaultwarden_oci import secrets
        values = secrets.decrypt()
        valid = all(isinstance(values.get(key), str) and bool(values[key])
                    for key in ("admin_basic_auth_password", "vaultwarden_admin_token"))
        del values
    except Exception:
        hold("admin secret custody validation failed (details withheld)")
    if not valid:
        hold("one of the separate Admin credential authorities is missing")
    passed("Admin credential ownership: Caddy Basic Auth user=admin "
           "and SOPS admin_basic_auth_password; separate Vaultwarden "
           "SOPS vaultwarden_admin_token (all secret values withheld)")
    passed("accepted Caddy limit 60/1m; backup remains local-only with zero pruning;"
           " SMTP not invoked")
    return site


def verify_runtime() -> str:
    # Lock is read-only and is never created here. Do not touch any current
    # application, Docker, systemd, Worker, Cloudflare or offsite state.
    try:
        lock = os.open("/run/vaultwarden-oci/lock",
                       os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(lock, fcntl.LOCK_UN)
        finally:
            os.close(lock)
    except OSError:
        hold("appliance lock busy or unavailable")
    for name in ("vaultwarden-oci-backup.timer",
                 "vaultwarden-oci-update-check.timer",
                 "vaultwarden-oci-maintenance.timer",
                 "vaultwarden-oci-health.timer",
                 "vaultwarden-oci-backup.service",
                 "vaultwarden-oci-update-check.service",
                 "vaultwarden-oci-maintenance.service",
                 "vaultwarden-oci-dns.service",
                 "vaultwarden-oci-health.service"):
        row = unit(name)
        if row.get("LoadState") != "loaded" or row.get("ActiveState") != "inactive":
            hold("unexpected active/missing automation unit: " + name)
    worker = unit("crowdsec-cloudflare-worker-bouncer.service")
    if tuple(worker.get(k) for k in (
        "LoadState", "ActiveState", "SubState", "UnitFileState", "InvocationID"
    )) != ("loaded", "active", "running", "disabled", EXPECTED_WORKER_INVOCATION):
        hold("Worker invocation/boot-disable changed; fresh Fail Open consent required")
    containers: dict[str, dict] = {}
    for name in ("vaultwarden-oci-vaultwarden", "vaultwarden-oci-caddy"):
        try:
            payload = json.loads(run(["docker", "container", "inspect", name]))
            info = payload[0]
            state = info["State"]
            healthy = (state.get("Status") == "running"
                       and state.get("Paused") is False
                       and state.get("Health", {}).get("Status") == "healthy")
        except (IndexError, TypeError, ValueError, KeyError):
            hold("Docker state unavailable (details withheld)")
        if not healthy:
            hold("installed application container not healthy: " + name)
        containers[name] = info
    try:
        doctor = json.loads(run(["/usr/local/bin/vwctl", "doctor", "--json"], timeout=90))
        checks = {entry["id"]: entry["status"] for entry in doctor["checks"]}
        status = json.loads(run(["/usr/local/bin/vwctl", "status", "--json"], timeout=60))
        good = (doctor.get("overall") in ("PASS", "WARN")
                and "FAIL" not in checks.values()
                and status["runtime"]["overall"] == "running")
    except (TypeError, ValueError, KeyError):
        hold("doctor/status output invalid (details withheld)")
    mandatory = ("runtime.paths", "secrets.custody", "secrets.decrypt",
                 "edge.admin.protection", "edge.cloudflare.iptables",
                 "crowdsec.engine", "crowdsec.firewall", "crowdsec.cloudflare")
    if not good or any(checks.get(k) != "PASS" for k in mandatory):
        hold("runtime, secrets or security doctor evidence not PASS")
    passed("healthy/unpaused Caddy and Vaultwarden; doctor no FAIL; "
           "security checks PASS; prior Worker invocation unchanged")
    passed("all scheduled units idle; Worker active but boot-disabled")
    networks = (containers["vaultwarden-oci-caddy"].get("NetworkSettings") or {}).get("Networks") or {}
    ips = []
    for net in networks.values():
        try:
            ip = ipaddress.ip_address(net.get("IPAddress", ""))
        except ValueError:
            continue
        if ip.version == 4 and ip.is_private and not ip.is_loopback:
            ips.append(str(ip))
    if not ips:
        hold("no private IPv4 Caddy endpoint available")
    return ips[0]


def verify_local_https(domain: str, ip: str) -> None:
    results = []
    for path in ("/", "/api/config", "/admin/"):
        answer = run([
            "curl", "--noproxy", "*", "--ipv4", "--silent",
            "--show-error", "--output", "/dev/null",
            "--write-out", "%{http_code}",
            "--connect-timeout", "8", "--max-time", "20",
            "--resolve", domain + ":443:" + ip,
            "https://" + domain + path,
        ], timeout=25).strip()
        results.append(answer)
    if results != ["200", "200", "401"]:
        hold("verified private HTTPS status mismatch: "
             "Web/API/unauth Admin=" + "/".join(results))
    passed("TLS-verified private Caddy HTTPS: Web/API/unauth Admin=200/200/401;"
           " no premature 429 on this bounded unauthenticated sample")
    print("NOT RUN: fresh-sync real client item fields/absence; browser Admin navigation;"
          " Admin SMTP test and independent mailbox receipt", flush=True)
    print("P4_A_EXIT=0 READ_ONLY_SERVER_PREFLIGHT_PASS;"
          " FULL_CLIENT_ADMIN_SMTP=NOT_RUN; RELEASE_GO=HOLD", flush=True)


def main() -> None:
    verify_host_and_storage()
    domain = verify_config()
    ip = verify_runtime()
    verify_local_https(domain, ip)


if __name__ == "__main__":
    main()
