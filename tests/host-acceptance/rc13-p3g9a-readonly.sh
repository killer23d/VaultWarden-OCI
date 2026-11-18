bash <<'P3G9A'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0

PIN='fd56313255c97992dc55c1475d94477597b88602'
V2='08595bdfe2a08a4946a95a43e83046c82b4d4126'
WORK="$HOME/VaultWarden-OCI-p2b-${PIN:0:12}"
REL='/opt/vaultwarden-oci/releases/0.1.0-rc.13'
ART='/var/lib/vaultwarden-oci/backups/recovery-20261118T202543Z-e3ef03c7.vwrec'
SHA='47f775b7e2f534e53cc4c6c5056df786fe0bbb0e316f5fa907b1b1c879546a44'
INV='a80be9e43af84a24b505b9e4b127abeb'

hold() { printf 'P3_G9A_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'wrong operator; expected ubuntu'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'wrong host'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
command -v sudo >/dev/null || hold 'sudo unavailable'
command -v git >/dev/null || hold 'git unavailable'
sudo -n true >/dev/null 2>&1 || hold 'passwordless sudo unavailable'
[ -d "$WORK/.git" ] && [ ! -L "$WORK" ] || hold 'pinned P2 source checkout missing/unsafe'
HEAD="$(git --no-optional-locks -C "$WORK" rev-parse HEAD 2>/dev/null)" || hold 'cannot read pinned source commit'
[ "$HEAD" = "$PIN" ] || hold 'P2 checkout HEAD differs from installed source pin'

sudo -n python3 -B - "$WORK" "$PIN" "$V2" "$REL" "$ART" "$SHA" "$INV" <<'PY'
import fcntl
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import socket
import stat
import subprocess
import sys
import tomllib

work, pin, v2, release_arg, archive_arg, expected_sha, invocation = sys.argv[1:]
release = pathlib.Path(release_arg)
archive = pathlib.Path(archive_arg)
state_root = pathlib.Path('/var/lib/vaultwarden-oci')
MEG = 1024 * 1024

def hold(reason):
    print('P3_G9A_EXIT=2 HOLD: ' + reason, file=sys.stderr, flush=True)
    raise SystemExit(2)

def passed(reason):
    print('PASS: ' + reason, flush=True)

def cmd(argv, *, timeout=45):
    try:
        r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        hold('read-only command unavailable or timed out: ' + pathlib.Path(argv[0]).name)
    if r.returncode:
        hold('read-only command failed: ' + pathlib.Path(argv[0]).name)
    return r.stdout

def regular(path, uid=0, mode=None, size=None):
    try:
        s = path.lstat()
    except OSError:
        hold('required file missing or unreadable: ' + str(path))
    if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or s.st_uid != uid:
        hold('unsafe file type/owner/hardlinks: ' + str(path))
    if mode is not None and stat.S_IMODE(s.st_mode) != mode:
        hold('incorrect file mode: ' + str(path))
    if size is not None and s.st_size != size:
        hold('unexpected file size: ' + str(path))
    return s

def directory(path, uid=None, mode=None):
    try:
        s = path.lstat()
    except OSError:
        hold('required directory missing: ' + str(path))
    if not stat.S_ISDIR(s.st_mode) or (uid is not None and s.st_uid != uid):
        hold('unsafe directory type or owner: ' + str(path))
    if mode is not None and stat.S_IMODE(s.st_mode) != mode:
        hold('unexpected directory mode: ' + str(path))
    return s

def show(unit, fields=('LoadState', 'ActiveState', 'SubState', 'UnitFileState')):
    raw = cmd(['systemctl', 'show', '--no-pager', '--property=' + ','.join(fields), unit])
    result = {}
    for line in raw.decode('utf-8', 'replace').splitlines():
        k, sep, v = line.partition('=')
        if sep: result[k] = v
    if any(f not in result for f in fields):
        hold('systemd properties unavailable: ' + unit)
    return result

# Host/platform and exact installed release provenance (no fetch and no writes).
try:
    info = dict(line.split('=', 1) for line in pathlib.Path('/etc/os-release').read_text().splitlines() if '=' in line)
    info = {k: v.strip('"') for k,v in info.items()}
except (ValueError, OSError):
    hold('cannot read Ubuntu metadata')
if (os.geteuid(), socket.gethostname().split('.')[0], platform.machine(),
    info.get('ID'), info.get('VERSION_ID'), info.get('VERSION_CODENAME'),
    sys.version_info[:2]) != (0, 'vaultwarden-oci-8', 'aarch64', 'ubuntu', '26.04', 'resolute', (3, 14)):
    hold('host, root, Ubuntu 26.04, ARM64, or native Python 3.14 mismatch')
passed('Ubuntu 26.04 ARM64 / Python 3.14 / expected host')

directory(release, uid=0, mode=0o555)
link = pathlib.Path('/opt/vaultwarden-oci/current')
ctl_link = pathlib.Path('/usr/local/bin/vwctl')
if not link.is_symlink() or os.readlink(link) != 'releases/0.1.0-rc.13':
    hold('immutable current release symlink changed')
if not ctl_link.is_symlink() or ctl_link.resolve(strict=True) != release / 'vwctl':
    hold('vwctl symlink changed')

tree = cmd(['git', '-c', 'safe.directory=' + work, '-C', work, 'ls-tree', '-r', '-z', pin,
            '--', 'vwctl', 'versions.toml', 'email-providers.toml', 'vaultwarden_oci', 'systemd'])
expected_files = {}
for entry in tree.split(b'\0'):
    if not entry: continue
    metadata, separator, name = entry.partition(b'\t')
    if not separator: hold('invalid Git tree response')
    parts = metadata.split()
    if len(parts) != 3 or parts[1] != b'blob' or parts[0] not in (b'100644', b'100755'):
        hold('unsupported source entry in pinned release')
    rel = name.decode('utf-8')
    expected_files[rel] = (parts[2].decode('ascii'), 0o555 if parts[0] == b'100755' else 0o444)
if not expected_files or len(expected_files) < 20:
    hold('pinned Git release inventory is incomplete')
actual_files = set()
for p in release.rglob('*'):
    rel = str(p.relative_to(release))
    s = p.lstat()
    if s.st_uid != 0 or stat.S_ISLNK(s.st_mode):
        hold('unsafe mutable/symlink release entry: ' + rel)
    if stat.S_ISDIR(s.st_mode):
        if stat.S_IMODE(s.st_mode) != 0o555: hold('mutable release directory: ' + rel)
    elif stat.S_ISREG(s.st_mode):
        actual_files.add(rel)
        if rel not in expected_files: hold('extra file in installed release: ' + rel)
        blob, mode = expected_files[rel]
        if stat.S_IMODE(s.st_mode) != mode: hold('mutable/incorrect release file mode: ' + rel)
        data = p.read_bytes()
        observed = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
        if observed != blob: hold('installed release byte mismatch: ' + rel)
    else:
        hold('unexpected installed release file type: ' + rel)
if actual_files != set(expected_files):
    hold('installed release files missing compared with pinned Git commit')
with (release / 'versions.toml').open('rb') as f:
    version = tomllib.load(f).get('vaultwarden_oci', {}).get('version')
if version != '0.1.0-rc.13':
    hold('installed release version mismatch')
passed(f'exact immutable rc.13 source bytes match {pin}; {len(expected_files)} files')
print(f'INFO: repo v2={v2} (GitHub verified; installed source intentionally predates it)')

# Read-only invocation of the installed storage gate.
sys.path.insert(0, str(release))
try:
    from vaultwarden_oci import storage
    disk = storage.verify()
except Exception:
    hold('installed storage.verify() rejected dedicated mount/marker/identity')
try:
    approved = pathlib.Path('/dev/oracleoci/oraclevdb').resolve(strict=True)
except OSError:
    hold('approved OCI block-device alias unavailable')
if disk.fs_type != 'ext4' or pathlib.Path(disk.source).resolve(strict=True) != approved:
    hold('mounted storage differs from approved ext4 device')
if state_root.stat().st_dev == pathlib.Path('/').stat().st_dev:
    hold('dedicated mount fell back to root filesystem')
mount = cmd(['findmnt', '-n', '-o', 'FSTYPE,OPTIONS', '--mountpoint', str(state_root)]).decode().strip()
if not mount.startswith('ext4 ') or 'rw' not in mount.split(' ', 1)[1].split(','):
    hold('dedicated volume is not mounted ext4 read-write')
regular(pathlib.Path('/etc/vaultwarden-oci/storage-identity.json'), mode=0o600)
regular(state_root / '.vaultwarden-oci-volume.json', mode=0o600)
passed(f'dedicated ext4 device={approved} UUID={disk.uuid}; no root fallback')

# Exact encrypted source and prior independent verification, without writing recovery metadata.
s = regular(archive, mode=0o600, size=348440)
if s.st_dev != state_root.stat().st_dev:
    hold('archive is not on approved dedicated mount')
h = hashlib.sha256()
with archive.open('rb') as file:
    for block in iter(lambda: file.read(MEG), b''): h.update(block)
if h.hexdigest() != expected_sha:
    hold('encrypted archive SHA256 mismatch')
record_path = state_root / 'state/recovery.json'
regular(record_path, mode=0o600)
try:
    record = json.loads(record_path.read_text())
except (OSError, ValueError):
    hold('recovery metadata invalid')
for item in (record.get('local'), (record.get('verified_objects') or {}).get(str(archive))):
    if not isinstance(item, dict) or item.get('sha256') != expected_sha or item.get('size') != s.st_size or not item.get('verified_at'):
        hold('previous local/independent recovery verification evidence missing or inconsistent')
if record['local'].get('artifact') != str(archive):
    hold('recovery local recorded artifact changed')
passed(f'encrypted archive 348440 bytes, SHA256={expected_sha}; independent Age verify recorded')

# Current policy, persistent targets, and conservative free-space readiness.
config = pathlib.Path('/etc/vaultwarden-oci/config.toml')
secret = pathlib.Path('/etc/vaultwarden-oci/secrets.sops.yaml')
operational = pathlib.Path('/etc/vaultwarden-oci/age-key.txt')
for path in (config, secret, operational): regular(path, mode=0o600)
try:
    with config.open('rb') as f: current = tomllib.load(f)
    backup = current['backup']
except (OSError, ValueError, KeyError, TypeError):
    hold('current protected TOML backup policy unreadable')
if backup.get('remote', '') != '' or backup.get('local_retention_days', 0) != 0 or backup.get('remote_retention_days', 0) != 0:
    hold('automatic remote publication or retention is not disabled')
passed('saved backup policy LOCAL-ONLY; both automatic retention periods zero')

def tree_size(path):
    total = 0
    for here, dirs, files in os.walk(path, followlinks=False):
        for name in dirs + files:
            p = pathlib.Path(here) / name
            s = p.lstat()
            if stat.S_ISLNK(s.st_mode): hold('symlink in live restore target: ' + str(p))
            if stat.S_ISREG(s.st_mode): total += s.st_size
            elif not stat.S_ISDIR(s.st_mode): hold('unexpected file type in live restore target')
    return total

live = [(state_root / 'data', 65532),
        (state_root / 'caddy/data', 65533),
        (state_root / 'caddy/config', 65533)]
footprint = 0
for path, owner in live:
    directory(path, uid=owner)
    footprint += tree_size(path)
regular(state_root / 'data/db.sqlite3', uid=65532)
free_data = shutil.disk_usage(state_root).free
free_etc = shutil.disk_usage('/etc').free
reserve = max(128 * MEG, 3 * footprint + 64 * MEG)
if free_data < reserve or free_etc < 128 * MEG:
    hold('insufficient conservative spare space for staged restore and rollback')
passed(f'live data/SQLite/Caddy targets present; free data={free_data // MEG} MiB, conservative reserve={reserve // MEG} MiB')
print('INFO: the exact decrypted candidate free-space/SQLite gate runs only after authorized RESTORE')

# No active mutator, timer surprise, or update-recovery guard.
if pathlib.Path('/var/lib/vaultwarden-oci/state/update-recovery-required.json').exists():
    hold('pending update recovery guard exists')
lock = pathlib.Path('/run/vaultwarden-oci/lock')
regular(lock, mode=0o600)
try:
    fd = os.open(lock, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)
except (OSError, BlockingIOError):
    hold('global mutation lock busy or unreadable')
for unit in ('vaultwarden-oci-backup.service', 'vaultwarden-oci-update-check.service',
             'vaultwarden-oci-maintenance.service', 'vaultwarden-oci-dns.service',
             'vaultwarden-oci-health.service'):
    p = show(unit)
    if p['LoadState'] != 'loaded' or p['ActiveState'] != 'inactive':
        hold('background mutator active/failed/missing: ' + unit)
for unit in ('vaultwarden-oci-backup.timer', 'vaultwarden-oci-update-check.timer',
             'vaultwarden-oci-maintenance.timer', 'vaultwarden-oci-health.timer'):
    p = show(unit)
    if p['LoadState'] != 'loaded' or p['ActiveState'] != 'inactive':
        hold('scheduled automation is not quiescent: ' + unit)
for proc in pathlib.Path('/proc').iterdir():
    if not proc.name.isdigit() or int(proc.name) == os.getpid(): continue
    try:
        argv = (proc / 'cmdline').read_bytes().split(b'\0')
    except (OSError, ProcessLookupError):
        continue
    if not argv or not argv[0]: continue
    names = [pathlib.PurePosixPath(p.decode('utf-8', 'replace')).name for p in argv[:4] if p]
    if any(n in ('vwctl', 'setup.sh', 'rclone') for n in names):
        hold('another operator or rclone process is running; inspect separately')
passed('global lock free at observation time; no active backup/update/maintenance jobs or timers')

# Preserve exact Worker invocation and both healthy app containers.
worker = show('crowdsec-cloudflare-worker-bouncer.service',
              ('LoadState', 'ActiveState', 'SubState', 'UnitFileState', 'InvocationID'))
if (worker['LoadState'], worker['ActiveState'], worker['SubState'], worker['UnitFileState'], worker['InvocationID']) != (
    'loaded', 'active', 'running', 'disabled', invocation):
    hold('Worker active/boot-disabled state or Fail Open invocation changed')
for container in ('vaultwarden-oci-vaultwarden', 'vaultwarden-oci-caddy'):
    raw = cmd(['docker', 'container', 'inspect', container])
    try:
        c = json.loads(raw)[0]['State']
    except (ValueError, KeyError, IndexError, TypeError):
        hold('container state cannot be decoded: ' + container)
    if c.get('Status') != 'running' or c.get('Paused') is not False or c.get('Health', {}).get('Status') != 'healthy':
        hold('application container not running/healthy/unpaused: ' + container)
passed('both application containers healthy and unpaused; Worker invocation unchanged/disabled at boot')

# Doctor is diagnostic only; output restricted to check IDs and status, never secret values.
raw = cmd(['/usr/local/bin/vwctl', 'doctor', '--json'], timeout=120)
try:
    doctor = json.loads(raw)
    checks = doctor['checks']
    statuses = {r['id']: r['status'] for r in checks}
except (ValueError, KeyError, TypeError):
    hold('doctor JSON schema unreadable')
if doctor['overall'] == 'FAIL' or any(v == 'FAIL' for v in statuses.values()):
    hold('installed doctor reported FAIL')
for name in ('recovery.local', 'runtime.paths',
             'crowdsec.cloudflare', 'edge.cloudflare.iptables',
             'notification.catalog'):
    if statuses.get(name) != 'PASS':
        hold('required doctor check not PASS: ' + name)

# Operational notifications are optional and independent of restore safety.
# Only the deliberately unconfigured state permits the three notification SKIPs.
notification_allowed = {'notification.last_delivery'}
if current.get('notifications') is None:
    optional_checks = (
        'notification.provider',
        'notification.api_secret',
        'notification.smtp_fallback',
    )
    for name in optional_checks:
        if statuses.get(name) != 'SKIP':
            hold('unconfigured optional notification check has unexpected state: ' + name)
    notification_allowed.update(optional_checks)
    print('INFO: optional operational notifications are NOT CONFIGURED; three notification SKIPs are not PASS')
else:
    for name in ('notification.provider', 'notification.api_secret',
                 'notification.smtp_fallback'):
        if statuses.get(name) != 'PASS':
            hold('configured notification check is not PASS: ' + name)
    print('INFO: configured operational notification checks are PASS')

delivery = statuses.get('notification.last_delivery')
if delivery not in ('PASS', 'WARN', 'SKIP'):
    hold('notification delivery history check missing/invalid')
if delivery != 'PASS':
    print('INFO: notification.last_delivery=' + delivery +
          '; delivery evidence remains outstanding, not a full-restore gate')
other_warns = sorted(
    k for k, v in statuses.items()
    if v in ('WARN', 'SKIP')
    and k not in ({'recovery.offsite', 'recovery.rclone'} | notification_allowed)
)
if other_warns:
    hold('unexpected doctor WARN/SKIP check(s): ' + ','.join(other_warns))
passed('doctor zero FAIL; required runtime/origin/CrowdSec/recovery.local PASS; storage independently verified')
print('INFO: offsite/rclone WARN/SKIP remain open as separate P3-G11 acceptance evidence')

# Operator claims are required but are ATTESTATIONS, not independently observed PASS.
print('INFO: answers below do NOT authorize P3-G9B or any restore')
questions = (
    ('DISPOSABLE', 'This exact VM has no irreplaceable data and may have downtime only if G9B is separately authorized'),
    ('CUSTODY', 'Matching test Age private identity is held separately off-host and available for G9B'),
    ('ROLLBACK', 'Independent off-host recovery/rollback option exists if local restore or disk fails'),
    ('TEST_DATA', 'A specific known test vault state dating from before 2026-11-18 20:25:43 UTC is documented for G9C'),
)
try:
    with open('/dev/tty', 'r+', encoding='utf-8', buffering=1) as tty:
        for tag, question in questions:
            tty.write(f'ATTEST {tag}: {question}\nType YES, or anything else to HOLD: ')
            answer = tty.readline().strip()
            if answer != 'YES': hold('missing operator attestation: ' + tag)
            passed('ATTESTED (not independently verified): ' + tag)
except OSError:
    hold('interactive /dev/tty unavailable for operator readiness attestation')

print('IMPACT: restore replaces /etc/vaultwarden-oci/config.toml and secrets.sops.yaml;')
print('        /var/lib/vaultwarden-oci/data, caddy/data and caddy/config;')
print('        it may replace the operational Age identity after a new SOPS rekey.')
print('IMPACT: Vaultwarden and Caddy containers will stop and be removed during promotion;')
print('        a separately approved --start will rebuild/start and health-check them.')
print('UNCHANGED: original encrypted .vwrec under backups, recovery.json record,')
print('        existing public DNS/A record, Cloudflare routes and CrowdSec Worker invocation.')
print('FOLLOW-UP: G9B requires separate consent, fresh preflight and interactive uppercase RESTORE;')
print('           G9C must prove SQLite/test state, operational SOPS, Caddy, app TLS/Admin and doctor.')
print('P3_G9A_EXIT=0 READINESS_PASS_ONLY; P3_G9B=HOLD_UNTIL_SEPARATELY_AUTHORIZED')
PY
P3G9A
