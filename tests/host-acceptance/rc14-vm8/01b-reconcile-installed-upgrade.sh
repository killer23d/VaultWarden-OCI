#!/usr/bin/env bash
bash <<'RC14_C_RECONCILE'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0

hold() { printf 'RC14_C_RECONCILE_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'Wrong operator'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'Wrong VM'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
sudo -n true >/dev/null 2>&1 || hold 'Passwordless sudo unavailable'

PIN='92b9300f96125d19105cc1d4865024cb49612b28'
WORK="$HOME/VaultWarden-OCI-rc14-c-92b9300f9612"
EVID="$HOME/vwoci-acceptance/rc14-c-plpbvT"
[ -d "$WORK/.git" ] && [ ! -L "$WORK" ] || hold 'Pinned candidate missing'
[ "$(git -C "$WORK" rev-parse HEAD)" = "$PIN" ] || hold 'Candidate SHA changed'
[ -z "$(git -C "$WORK" status --porcelain)" ] || hold 'Candidate source dirty'
[ -d "$EVID" ] && [ ! -L "$EVID" ] || hold 'Original upgrade evidence missing'
[ "$(stat -c '%u:%a' "$EVID")" = "$(id -u):700" ] || hold 'Evidence custody unsafe'
[ ! -e "$EVID/rc14-c-reconciled.json" ] && [ ! -L "$EVID/rc14-c-reconciled.json" ] ||
  hold 'Reconciliation already recorded; no replay'

echo '=== RC14-C independent read-only installed-release verification ==='
echo 'INFO: No updater, Worker stop/start, Cloudflare PUT, DNS, timers or reboot'

if sudo -n /usr/bin/python3 -B - "$WORK" "$EVID" "$PIN" <<'PY_RECONCILE'
import hashlib
import json
import os
import pathlib
import platform
import pwd
import stat
import subprocess
import sys

def hold(message):
    print('RC14_C_RECONCILE_EXIT=2 HOLD: ' + message, flush=True)
    raise SystemExit(2)

def run(args, timeout=90):
    try:
        p = subprocess.run(
            args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=timeout, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        hold('Read-only verification command unavailable')
    if p.returncode != 0 or len(p.stdout) > 1048576:
        hold('Read-only verification command returned unexpected status')
    return p.stdout

work = pathlib.Path(sys.argv[1]).resolve(strict=True)
evidence = pathlib.Path(sys.argv[2])
pin = sys.argv[3]
operator = pwd.getpwnam('ubuntu')
if (os.geteuid() != 0 or os.environ.get('SUDO_USER') != 'ubuntu'
    or os.environ.get('SUDO_UID') != str(operator.pw_uid)
    or platform.node().split('.')[0] != 'vaultwarden-oci-8'
    or platform.machine() != 'aarch64'
    or sys.version_info[:2] != (3, 14)
    or work != pathlib.Path('/home/ubuntu/VaultWarden-OCI-rc14-c-92b9300f9612')
    or evidence != pathlib.Path('/home/ubuntu/vwoci-acceptance/rc14-c-plpbvT')
    or pin != '92b9300f96125d19105cc1d4865024cb49612b28'):
    hold('Unexpected source, host, operator or evidence identity')

def original(name):
    path = evidence / name
    try:
        meta = path.lstat()
        if (not stat.S_ISREG(meta.st_mode) or stat.S_ISLNK(meta.st_mode)
            or meta.st_uid != operator.pw_uid
            or stat.S_IMODE(meta.st_mode) != 0o600):
            hold('Original update evidence custody invalid')
        return path.read_text(encoding='utf-8')
    except (OSError, UnicodeError):
        hold('Original update evidence unreadable')

try:
    plan = json.loads(original('plan.json'))
    receipts = [json.loads(line) for line in original('apply.stdout').splitlines() if line.strip()]
    if not (plan['schema_version'] == 1
        and plan['current']['project'] == '0.1.0-rc.13'
        and plan['candidate']['project'] == '0.1.0-rc.14'
        and plan['architecture'] == 'arm64'
        and len(receipts) == 2
        and receipts[0]['candidate']['project'] == '0.1.0-rc.14'
        and receipts[1]['schema_version'] == 1
        and receipts[1]['result'] == 'applied'):
        hold('Original supported update receipt did not show a completed rc14 apply')
except (OSError, ValueError, KeyError, TypeError):
    hold('Original supported update receipt invalid')
print('PASS: Original supported rc13 to rc14 update completed once')

current = pathlib.Path('/opt/vaultwarden-oci/current')
release = pathlib.Path('/opt/vaultwarden-oci/releases/0.1.0-rc.14')
if (not current.is_symlink()
    or os.readlink(current) != 'releases/0.1.0-rc.14'
    or release.is_symlink() or not release.is_dir()
    or current.resolve() != release):
    hold('Active release is not the approved immutable rc14')

sys.path.insert(0, str(work))
from vaultwarden_oci import storage, update_versions
if not pathlib.Path(update_versions.__file__).resolve().is_relative_to(work):
    hold('Wrong candidate version-freezing owner')
expected = update_versions.frozen_versions_toml(
    update_versions.resolve_pinned(work, machine='arm64')
).encode('utf-8')
installed_version = release / 'versions.toml'
if (installed_version.is_symlink() or not installed_version.is_file()
    or installed_version.read_bytes() != expected):
    hold('Installed frozen ARM64 manifest differs from updater specification')
print('PASS: Exact frozen ARM64 versions manifest matches rc14 candidate')

rows = run([
    'git', '-c', 'safe.directory=' + str(work), '-C', str(work),
    'ls-files', '-z', '--', 'vwctl', 'versions.toml',
    'email-providers.toml', 'vaultwarden_oci', 'systemd'
]).split(b'\x00')
count = 0
for raw in rows:
    if not raw:
        continue
    relative = pathlib.Path(os.fsdecode(raw))
    source, installed = work / relative, release / relative
    if (relative.is_absolute() or '..' in relative.parts
        or source.is_symlink() or not source.is_file()
        or installed.is_symlink() or not installed.is_file()):
        hold('Installed release file missing or unsafe')
    if relative.as_posix() != 'versions.toml':
        if hashlib.sha256(source.read_bytes()).digest() != hashlib.sha256(installed.read_bytes()).digest():
            hold('Installed release differs from pinned tested source')
    count += 1
if count < 50:
    hold('Installed release inventory incomplete')
print('PASS: All ' + str(count) + ' installed source files match the tested Git commit')

try:
    disk = storage.verify()
except Exception:
    hold('Dedicated device proof unavailable')
if disk.uuid != 'f4e0bd62-48e7-4745-8987-44b14013216d' or disk.fs_type != 'ext4':
    hold('Dedicated storage identity mismatch')
print('PASS: Dedicated ext4 volume and no-root-fallback verified')

guard = pathlib.Path('/var/lib/vaultwarden-oci/state/update-recovery-required.json')
if guard.exists() or guard.is_symlink():
    hold('Update recovery guard still present')

raw = run([
    'systemctl', 'show', 'vaultwarden-oci-crowdsec-boot.service',
    '--no-pager', '--property=LoadState,UnitFileState'
]).decode('utf-8')
unit = dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)
if unit.get('LoadState') != 'loaded' or unit.get('UnitFileState') != 'disabled':
    hold('Optional boot unit not installed and disabled')
print('PASS: Opt-in boot unit loaded and disabled; update guard clear')

try:
    doctor = json.loads(run(['/usr/local/bin/vwctl', 'doctor', '--json']))
    checks = {x['id']: x['status'] for x in doctor['checks']}
except (ValueError, KeyError, TypeError):
    hold('Doctor JSON was invalid')
if (doctor.get('overall') != 'PASS' or 'FAIL' in checks.values()
    or checks.get('crowdsec.cloudflare') != 'PASS'):
    hold('Installed rc14 doctor or CrowdSec Cloudflare not PASS')
print('PASS: Installed rc14 doctor overall PASS; CrowdSec Cloudflare PASS')

receipt = {
    'schema_version': 1, 'result': 'INSTALLED_RC14_UPGRADE_PASS',
    'candidate_sha': pin, 'installed_release': '0.1.0-rc.14',
    'verified_release_files': count,
    'frozen_manifest_sha256': hashlib.sha256(expected).hexdigest(),
    'disk_uuid': disk.uuid, 'doctor': 'PASS',
    'crowdsec_cloudflare': 'PASS', 'boot_rearm_unit': 'disabled'
}
try:
    path = evidence / 'rc14-c-reconciled.json'
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as out:
        json.dump(receipt, out, indent=2, sort_keys=True)
        out.write('\n')
        out.flush()
        os.fsync(out.fileno())
except OSError:
    hold('Unable to save protected reconciliation receipt')

print('RC14_C_RECONCILE_EXIT=0 INSTALLED_RC14_UPGRADE_PASS')
print('BOOT_REARM=NOT_ENABLED; REBOOT=NOT_RUN; RELEASE_GO=HOLD')
PY_RECONCILE
then
  printf 'RC14_C_RECONCILE_WRAPPER_EXIT=0\n'
  printf 'PRIVATE_EVIDENCE_DIR=%s\n' "$EVID"
else
  hold 'Post-upgrade reconciliation did not pass; do not rerun the updater'
fi
RC14_C_RECONCILE
