#!/usr/bin/env python3
"""Gate P0: bounded, read-only inventory of an operator-selected VaultWarden-OCI host.

Only writes root-private evidence below the invoking operator's home directory.
Does not provision storage, change services, write remote objects, update DNS, or
claim that a host is production merely because VaultWarden is installed there.
"""
from __future__ import annotations

import datetime as dt
import hashlib
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
from typing import Any

sys.dont_write_bytecode = True
os.umask(0o077)

ETC = Path('/etc/vaultwarden-oci')
STATE = Path('/var/lib/vaultwarden-oci')
CURRENT = Path('/opt/vaultwarden-oci/current')
RELEASES = Path('/opt/vaultwarden-oci/releases')
GUARD = STATE / 'state/update-recovery-required.json'
TIMERS = (
    'vaultwarden-oci-health.timer',
    'vaultwarden-oci-backup.timer',
    'vaultwarden-oci-maintenance.timer',
    'vaultwarden-oci-update-check.timer',
)
SAFE_ID = re.compile(r'^[a-z][a-z0-9_.-]{0,80}$')
SUPPORTED = {'24.04': 'noble', '26.04': 'resolute'}


def command(args: list[str], timeout: int = 35, env: dict[str, str] | None = None) -> tuple[int | None, str]:
    """Capture command stdout only; never surface arbitrary stderr or stdout."""
    try:
        done = subprocess.run(
            args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, timeout=timeout,
            check=False, env=env, cwd='/',
        )
        return done.returncode, done.stdout
    except (OSError, subprocess.TimeoutExpired):
        return None, ''


def load_json(path: Path) -> dict[str, Any] | None:
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
            return None
        value = json.loads(path.read_text(encoding='utf-8'))
        return value if isinstance(value, dict) else None
    except (OSError, ValueError, UnicodeError):
        return None


def safe_mode(path: Path) -> bool:
    try:
        info = path.lstat()
        return (stat.S_ISREG(info.st_mode) and info.st_uid == 0
                and not (stat.S_IMODE(info.st_mode) & 0o077) and info.st_size > 0)
    except OSError:
        return False


def doctor_summary(value: object) -> tuple[str, list[str], list[str]]:
    if not isinstance(value, dict) or value.get('schema_version') != 1:
        return 'INVALID', [], []
    checks = value.get('checks')
    if not isinstance(checks, list) or not checks:
        return 'INVALID', [], []
    errors: list[str] = []
    warns: list[str] = []
    for check in checks:
        if not isinstance(check, dict) or not isinstance(check.get('id'), str):
            return 'INVALID', [], []
        ident = check['id']
        if not SAFE_ID.fullmatch(ident):
            return 'INVALID', [], []
        status = check.get('status')
        if status not in {'PASS', 'WARN', 'FAIL', 'SKIP'}:
            return 'INVALID', [], []
        if status == 'FAIL':
            errors.append(ident)
        if status == 'WARN':
            warns.append(ident)
    overall = value.get('overall')
    expected = 'FAIL' if errors else 'WARN' if warns else 'SKIP' if all(c['status'] == 'SKIP' for c in checks) else 'PASS'
    return (overall if overall == expected else 'INVALID'), errors, warns


def timer_summary(value: object) -> tuple[bool, int]:
    if not isinstance(value, dict) or value.get('schema_version') != 1:
        return False, 0
    rows = value.get('timers')
    if not isinstance(rows, list):
        return False, 0
    names = [row.get('unit') for row in rows if isinstance(row, dict)]
    if len(names) != len(TIMERS) or set(names) != set(TIMERS):
        return False, 0
    healthy = sum(1 for row in rows if row.get('health') == 'PASS')
    return value.get('overall') == 'PASS' and healthy == 4, healthy


def verified_recovery(value: object, kind: str) -> str:
    """Reported by the appliance, not an independent current integrity proof."""
    if not isinstance(value, dict):
        return 'none'
    row = value.get(kind)
    if not isinstance(row, dict) or not isinstance(row.get('verified_at'), str):
        return 'none'
    date = row['verified_at']
    try:
        parsed = dt.datetime.fromisoformat(date.replace('Z', '+00:00'))
        if parsed.tzinfo is None:
            return 'invalid'
    except ValueError:
        return 'invalid'
    return parsed.astimezone(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def systemd(unit: str) -> dict[str, str]:
    fields = 'LoadState,ActiveState,UnitFileState,Result,ExecMainStatus,LastTriggerUSec,NextElapseUSecRealtime'
    rc, result = command(['systemctl', 'show', unit, '--no-pager', '--property=' + fields])
    if rc != 0:
        return {}
    raw = dict(x.split('=', 1) for x in result.splitlines() if '=' in x)
    return {key: raw.get(key, 'unknown') for key in fields.split(',')}


def by_id_alias(device: Path) -> str | None:
    """Require a stable symlink resolving to the mounted filesystem device."""
    try:
        actual = device.resolve(strict=True)
        aliases = []
        for link in Path('/dev/disk/by-id').iterdir():
            if not link.is_symlink():
                continue
            try:
                if link.resolve(strict=True) == actual:
                    aliases.append(link)
            except OSError:
                continue  # One stale alias must not invalidate another valid alias.
    except OSError:
        return None
    acceptable = [p for p in aliases if p.name.startswith(('scsi-', 'wwn-', 'nvme-', 'virtio-'))]
    return str(sorted(acceptable)[0]) if acceptable else None


def safe_secret_failure(exc: Exception) -> str:
    """Expose only fixed non-secret reasons from the installed secret validator."""
    reason = str(exc)
    match = re.fullmatch(r'decrypted secret ([a-z_]+) must be a non-empty single-line string', reason)
    safe_keys = {
        'cloudflare_api_token', 'cloudflare_remediation_token',
        'smtp_username', 'smtp_password', 'vaultwarden_admin_token',
        'admin_basic_auth_password', 'email_api_token',
    }
    if match and match.group(1) in safe_keys:
        return 'invalid or missing required secret value: ' + match.group(1)
    if 'decrypted Cloudflare token does not match the supported' in reason:
        return 'decrypted Cloudflare token has invalid format (value withheld)'
    if reason.startswith('SOPS decryption'):
        return 'installed SOPS JSON decryption failed (details withheld)'
    return 'installed secret schema validation failed (details withheld)'


def local_backup_inventory(path: Path, state_root: Path) -> tuple[str, str]:
    """Inspect only backup metadata. No artifact is read, opened or decrypted."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        return 'NOT RUN', 'backup directory absent; no first backup established'
    except OSError:
        return 'BLOCKED', 'cannot inspect backup directory'

    if not stat.S_ISDIR(info.st_mode):
        return 'BLOCKED', 'backup path is not a regular directory'
    try:
        if info.st_dev != state_root.stat().st_dev:
            return 'BLOCKED', 'backup directory is not on the mounted dedicated volume'
        timestamps: list[float] = []
        for artifact in path.iterdir():
            if not artifact.name.endswith('.vwrec'):
                continue
            stat_info = artifact.lstat()
            if not stat.S_ISREG(stat_info.st_mode) or stat_info.st_size <= 0:
                return 'BLOCKED', 'encrypted backup entry is not a nonempty regular file'
            timestamps.append(stat_info.st_mtime)
    except OSError:
        return 'BLOCKED', 'backup directory unreadable'

    if not timestamps:
        return 'NOT RUN', 'backup directory present but no encrypted .vwrec created'
    newest = dt.datetime.fromtimestamp(max(timestamps), tz=dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    return 'PASS', f'count={len(timestamps)} newest_mtime_UTC={newest} (metadata only; not reverified)'


def last_backup_witness(service: dict[str, str], timer: dict[str, str]) -> tuple[str, str]:
    """systemd default Result=success is NOT proof of a scheduled invocation."""
    triggered = timer.get('LastTriggerUSec', '').strip()
    result = service.get('Result', 'unknown')
    if not triggered or triggered in {'n/a', 'unknown', '-'}:
        return 'NOT RUN', 'no recorded scheduled trigger; systemd Result is not execution evidence'
    if result != 'success':
        return 'WARN', 'a timer trigger exists but the backup service result is not success'
    return 'PENDING', 'timer trigger and unit result recorded; matching journal and verified .vwrec still required'


class Report:
    def __init__(self) -> None:
        self.rows: list[tuple[str, str, str]] = []
        self.data: dict[str, object] = {}
        self.blocked = False

    def add(self, status: str, label: str, detail: str) -> None:
        if status not in {'PASS', 'WARN', 'BLOCKED', 'PENDING', 'NOT RUN'}:
            raise ValueError('invalid status')
        if status == 'BLOCKED':
            self.blocked = True
        self.rows.append((status, label, detail))

    def output(self, folder: Path) -> None:
        gate = 'BLOCKED' if self.blocked else 'PENDING'
        self.rows.append((gate, 'Gate P0', 'operator target/OCI ownership attestation pending; no production mutation authorized'))
        rendered = 'Gate P0 - read-only production inventory\n' + '\n'.join(
            f'{state:<8} {label}: {detail}' for state, label, detail in self.rows
        ) + '\n'
        (folder / 'summary.txt').write_text(rendered, encoding='utf-8')
        (folder / 'diagnostics.json').write_text(json.dumps(
            {'gate': gate, 'checks': [{'status': a, 'label': b, 'detail': c} for a, b, c in self.rows],
             'inspection': self.data}, indent=2, sort_keys=True) + '\n', encoding='utf-8')
        print(rendered, end='')
        print('Private evidence:', folder)
        print('Paste only the summary above; do not share config, secrets, keys, or raw journals.')


def evidence_directory() -> Path:
    invoking = os.environ.get('SUDO_USER') or pwd.getpwuid(os.getuid()).pw_name
    home = Path(pwd.getpwnam(invoking).pw_dir)
    if not home.is_dir() or home.is_symlink():
        raise RuntimeError('operator home is not a real directory')
    base = home / 'vwoci-acceptance'
    if base.is_symlink():
        raise RuntimeError('evidence base must not be a symlink')
    if not base.exists():
        base.mkdir(mode=0o700)
    mode = base.lstat().st_mode
    if not stat.S_ISDIR(mode) or stat.S_IMODE(mode) & 0o077:
        raise RuntimeError('existing evidence base is not private')
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    folder = base / f'production-p0-{stamp}-{os.getpid()}'
    folder.mkdir(mode=0o700)
    return folder


def main() -> int:
    if len(sys.argv) != 1:
        print('Usage: sudo -n python3 -B production-readiness-inventory.py', file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        print('BLOCKED: run with sudo -n (passwordless, noninteractive)', file=sys.stderr)
        return 2
    try:
        folder = evidence_directory()
    except (OSError, RuntimeError, KeyError) as exc:
        print('BLOCKED: cannot create private evidence directory (' + type(exc).__name__ + ')', file=sys.stderr)
        return 2

    r = Report()
    now = dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    machine = platform.machine()
    hostname = platform.node().split('.')[0]
    os_release: dict[str, str] = {}
    try:
        for line in Path('/etc/os-release').read_text().splitlines():
            if '=' in line and not line.startswith('#'):
                k, v = line.split('=', 1)
                os_release[k] = v.strip('"')
    except OSError:
        pass
    version = os_release.get('VERSION_ID', '?')
    codename = os_release.get('VERSION_CODENAME', '?')
    supported = os_release.get('ID') == 'ubuntu' and SUPPORTED.get(version) == codename and machine in {'aarch64', 'arm64', 'x86_64', 'amd64'}
    r.add('PASS' if supported else 'BLOCKED', 'Host', f'{hostname} Ubuntu={version}/{codename} arch={machine} UTC={now}')
    rc, pyversion = command(['/usr/bin/python3', '--version'])
    r.add('PASS' if rc == 0 else 'WARN', 'Runtime', f'kernel={platform.release()} python={pyversion.strip() if rc == 0 else "unavailable"}')
    r.add('PENDING', 'Production identity', 'operator must confirm this host is CURRENT or REPLACEMENT and verify OCI attachment in Console')

    if not CURRENT.is_symlink():
        r.add('BLOCKED', 'Appliance', 'no supported current-release symlink; installed release not proven')
        r.add('NOT RUN', 'Installed checks', 'requires an installed, immutable VaultWarden release')
        r.output(folder)
        return 2
    try:
        selected = CURRENT.resolve(strict=True)
        versions = selected / 'versions.toml'
        manifest = tomllib.loads(versions.read_text(encoding='utf-8'))
        relversion = manifest['vaultwarden_oci']['version']
        if not (isinstance(relversion, str) and re.fullmatch(r'[0-9][A-Za-z0-9.+-]{2,60}', relversion)
                and selected == RELEASES / relversion and (selected / 'vwctl').is_file()):
            raise ValueError('invalid release layout')
    except (OSError, ValueError, KeyError, TypeError):
        r.add('BLOCKED', 'Appliance', 'invalid or unreadable immutable release selection')
        r.output(folder)
        return 2
    r.add('PASS', 'Appliance', f'selected={relversion} path={selected}')
    r.data['release_versions_sha256'] = hashlib.sha256(versions.read_bytes()).hexdigest()
    launcher = Path('/usr/local/bin/vwctl')
    r.add('PASS' if launcher.exists() and launcher.resolve() == selected / 'vwctl' else 'WARN',
          'Launcher', 'points to selected vwctl' if launcher.exists() and launcher.resolve() == selected / 'vwctl' else 'launcher selection requires review')
    r.add('PENDING', 'Update predecessor', 'current deployment lineage and supported update candidate require operator review')

    # The installed product owner proves both independent storage markers,
    # physical root-device exclusion, filesystem type and stable UUID.
    try:
        sys.path.insert(0, str(selected))
        from vaultwarden_oci import storage
        identity = storage.verify()
        alias = by_id_alias(Path(identity.source))
        if alias is None:
            raise RuntimeError('missing stable by-id alias')
    except (Exception,) as exc:
        r.add('BLOCKED', 'Storage', f'dedicated disk/host-marker/volume-marker verification failed ({type(exc).__name__})')
        r.add('NOT RUN', 'Installed checks', 'storage not proven; no config/secret/backup inspection attempted')
        r.output(folder)
        return 2
    r.add('PASS', 'Storage', f'UUID={identity.uuid} fs={identity.fs_type} by-id={alias} root-separated=yes dual-markers=yes')
    r.data['storage'] = {'uuid': identity.uuid, 'type': identity.fs_type, 'by_id': alias, 'source': identity.source}
    usage = os.statvfs(STATE)
    total = usage.f_blocks * usage.f_frsize
    free = usage.f_bavail * usage.f_frsize
    r.add('PASS' if total and free > 0 else 'WARN', 'Capacity', f'total_GiB={total // (1024**3)} available_GiB={free // (1024**3)}')

    protected = ('config.toml', 'secrets.sops.yaml', 'age-key.txt', 'storage-identity.json')
    good = all(safe_mode(ETC / f) for f in protected)
    r.add('PASS' if good else 'BLOCKED', 'Protected custody', 'root-owned, private nonempty config/SOPS/operational Age/storage markers' if good else 'missing, non-private or nonregular protected file')
    crypto_ok = False
    if good:
        sops = Path('/usr/local/bin/sops')
        if not sops.is_file():
            r.add('BLOCKED', 'SOPS', 'installed SOPS binary missing')
        else:
            env = dict(os.environ)
            env['SOPS_AGE_KEY_FILE'] = str(ETC / 'age-key.txt')
            rc, _ = command([str(sops), '--decrypt', '--output', '/dev/null', str(ETC / 'secrets.sops.yaml')], timeout=50, env=env)
            crypto_ok = rc == 0
            r.add('PASS' if crypto_ok else 'BLOCKED', 'SOPS', 'operational key decrypts ciphertext (cryptography only)' if crypto_ok else 'non-disclosing cryptographic check failed')
    else:
        r.add('NOT RUN', 'SOPS', 'protected custody did not pass')

    # The direct SOPS test checks cryptography only; the product's secret owner
    # also requires actual nonempty fields and accepted Cloudflare token formats.
    # Neither values nor arbitrary exceptions are written to the evidence.
    if crypto_ok:
        try:
            from vaultwarden_oci import secrets
            values = secrets.decrypt()
            required_remediation = bool(values.get('cloudflare_remediation_token'))
            del values
        except (secrets.SecretsError, OSError) as exc:
            r.add('BLOCKED', 'Secret schema', safe_secret_failure(exc))
        else:
            r.add('PASS' if required_remediation else 'BLOCKED', 'Secret schema',
                  'required fields, remediation credential and token formats validated; values withheld'
                  if required_remediation else 'required cloudflare_remediation_token missing; values withheld')
    else:
        r.add('NOT RUN', 'Secret schema', 'requires successful SOPS cryptographic check')

    try:
        with (ETC / 'config.toml').open('rb') as handle:
            config = tomllib.load(handle)
        backup = config.get('backup', {})
        if not isinstance(backup, dict):
            raise ValueError('invalid backup config')
        remote = backup.get('remote', '')
        local_days = backup.get('local_retention_days', 0)
        remote_days = backup.get('remote_retention_days', 0)
        if not isinstance(remote, str) or not all(type(n) is int and n >= 0 for n in [local_days, remote_days]):
            raise ValueError('invalid backup settings')
        remote_name = remote.split(':', 1)[0] if ':' in remote else ''
        if remote and not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', remote_name):
            raise ValueError('invalid rclone destination syntax')
        r.add('PASS', 'Backup policy', f'offsite_configured={bool(remote)} remote_name={remote_name or "none"} local_retention_days={local_days} remote_retention_days={remote_days}')
        r.data['backup'] = {'offsite_configured': bool(remote), 'remote_destination': remote,
                            'local_retention_days': local_days, 'remote_retention_days': remote_days}
        if remote:
            rclone_rc, names = command(['rclone', 'listremotes'], timeout=15)
            configured = {name.strip().rstrip(':') for name in names.splitlines()}
            r.add('PASS' if rclone_rc == 0 and remote_name in configured else 'WARN',
                  'Root rclone configuration', 'saved remote name exists' if rclone_rc == 0 and remote_name in configured else 'saved remote not confirmed in root rclone configuration')
        r.add('PENDING', 'Offsite destination', 'root rclone destination/retention requires independent credential and provider review' if remote else 'no automatic offsite publication configured')
    except (OSError, TypeError, ValueError, tomllib.TOMLDecodeError):
        r.add('BLOCKED', 'Backup policy', 'config.toml missing or invalid; no destination can be assumed')

    backup_state, backup_detail = local_backup_inventory(STATE / 'backups', STATE)
    r.add(backup_state, 'Local encrypted backups', backup_detail)

    state = load_json(STATE / 'state/recovery.json')
    r.add('PENDING', 'Recovery verification record', f'local={verified_recovery(state, "local")} offsite={verified_recovery(state, "offsite")} (historical; independent readback not performed)')
    r.add('BLOCKED' if GUARD.exists() or GUARD.is_symlink() else 'PASS',
          'Update guard', 'recovery-required guard present; no update allowed' if GUARD.exists() or GUARD.is_symlink() else 'no recovery-required guard present')
    r.add('WARN' if Path('/var/run/reboot-required').exists() else 'PASS', 'Reboot required', 'yes (no reboot performed)' if Path('/var/run/reboot-required').exists() else 'no')

    release_cli = str(selected / 'vwctl')
    for item in ('doctor', 'status', 'timers'):
        rc, output = command([sys.executable, '-B', '-E', release_cli, item, '--json'], timeout=90)
        r.data['vwctl_' + item + '_rc'] = rc
        try:
            data = json.loads(output)
        except (ValueError, TypeError):
            data = None
        if item == 'doctor':
            overall, errors, warns = doctor_summary(data)
            if overall == 'INVALID' or (rc == 0) != (overall != 'FAIL'):
                r.add('BLOCKED', 'Doctor', 'invalid JSON/status or inconsistent exit code')
            else:
                status = 'BLOCKED' if errors else 'WARN' if warns else 'PASS'
                r.add(status, 'Doctor', f'overall={overall} FAIL={",".join(errors[:12]) or "none"} WARN={",".join(warns[:12]) or "none"}')
            r.data['doctor'] = {'overall': overall, 'fail_ids': errors, 'warn_ids': warns}
            if isinstance(data, dict) and isinstance(data.get('checks'), list):
                sec = {check.get('id'): check.get('status') for check in data['checks']
                       if isinstance(check, dict) and check.get('id') in {
                           'crowdsec.engine', 'crowdsec.hub', 'crowdsec.firewall', 'crowdsec.cloudflare',
                           'edge.caddy.trusted_proxy', 'edge.cloudflare.cidrs',
                           'edge.cloudflare.iptables', 'edge.admin.protection'}}
                sec_ok = len(sec) == 8 and all(x == 'PASS' for x in sec.values())
                r.add('PASS' if sec_ok else 'WARN', 'Security owners',
                      f'CrowdSec/Cloudflare/Caddy/admin doctor checks PASS={sum(v == "PASS" for v in sec.values())}/8')
        elif item == 'status':
            if not isinstance(data, dict) or data.get('schema_version') != 1:
                r.add('BLOCKED', 'Status', 'status JSON unavailable or invalid')
            else:
                runtime = data.get('runtime') or {}
                storage_status = data.get('storage') or {}
                state_text = str(runtime.get('overall')) if runtime.get('overall') in {'running', 'stopped', 'degraded'} else 'unknown'
                storage_text = str(storage_status.get('state')) if storage_status.get('state') in {'ok', 'warning', 'failure'} else 'unknown'
                status_result = (
                    'BLOCKED' if storage_text in {'failure', 'unknown'} or state_text == 'unknown' or rc not in {0, 1}
                    else 'WARN' if state_text == 'stopped' or rc != 0
                    else 'PASS'
                )
                r.add(status_result, 'Status', f'runtime={state_text} storage={storage_text} exit={rc} (stopped is not live acceptance)')
                r.data['status'] = {'runtime': state_text, 'storage': storage_text}
        else:
            healthy, n = timer_summary(data)
            r.add('PASS' if healthy and rc == 0 else 'WARN', 'Timers', f'healthy={n}/4 overall={"PASS" if healthy else "not established"} (activation is not proof of a scheduled backup)')

    target = systemd('vaultwarden-oci.target')
    last = systemd('vaultwarden-oci-backup.service')
    btimer = systemd('vaultwarden-oci-backup.timer')
    r.add('PASS' if target.get('ActiveState') == 'active' else 'WARN', 'Systemd target', f'active={target.get("ActiveState", "unknown")} enabled={target.get("UnitFileState", "unknown")}')
    witness_state, witness_detail = last_backup_witness(last, btimer)
    r.add(witness_state, 'Last backup unit', witness_detail)
    r.data['systemd'] = {'target': target, 'backup_service': last, 'backup_timer': btimer}
    rc, output = command(['systemctl', 'list-units', '--failed', '--plain', '--no-legend', '--no-pager'])
    failed = [line.split()[0] for line in output.splitlines() if line.split() and re.fullmatch(r'[A-Za-z0-9_.@-]+\.(?:service|timer|target)', line.split()[0])]
    r.add('PASS' if rc == 0 and not failed else 'WARN', 'Failed systemd units', f'count={len(failed)}' if rc == 0 else 'unavailable')
    r.data['failed_unit_names'] = failed

    rc, dns_output = command([sys.executable, '-B', '-E', release_cli, 'dns', 'status'], timeout=45)
    if rc in (0, 1) and 'in_sync=' in dns_output and 'proxied=' in dns_output:
        sync = re.search(r'\bin_sync=(true|false)\b', dns_output)
        proxied = re.search(r'\bproxied=(true|false)\b', dns_output)
        if sync and proxied:
            r.add('PASS' if rc == 0 and sync[1] == 'true' and proxied[1] == 'true' else 'WARN',
                  'Cloudflare DNS', f'proxied={proxied[1]} in_sync={sync[1]} (read-only live query)')
        else:
            r.add('WARN', 'Cloudflare DNS', 'read-only query returned unrecognized state')
    else:
        r.add('PENDING', 'Cloudflare DNS', 'read-only authority query unavailable; no DNS edits performed')
    r.add('PENDING', 'Offline recovery custody', 'original encrypted kit, separate passphrase and offline private identity require off-host attestation')
    r.add('PENDING', 'Worker Routes', 'current invocation Fail Open must be manually attested in Cloudflare')
    r.add('PENDING', 'OCI attachment', 'volume identity from OCI Console must be independently matched')
    r.add('NOT RUN', 'External proof', 'no remote readback, client login, SMTP, restore, DNS update, service change, timer trigger or reboot')
    r.output(folder)
    return 2 if r.blocked else 0


if __name__ == '__main__':
    raise SystemExit(main())
