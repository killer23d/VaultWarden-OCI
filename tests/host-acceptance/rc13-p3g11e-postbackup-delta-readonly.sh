bash <<'P3G11E'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
hold() { printf 'P3_G11E_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'wrong operator'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'wrong host'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
sudo -n true >/dev/null 2>&1 || hold 'passwordless sudo unavailable'
sudo -n python3 -B <<'PY'
import hashlib, json, os, pathlib, sqlite3, stat, subprocess, sys, tomllib
REMOTE='bw-backup:bw-backup/acceptance-rc13-vm8-20261118T215615Z-208eae43675f/recovery-20261118T215628Z-a478ee3e.vwrec'
LOCAL=pathlib.Path('/var/lib/vaultwarden-oci/backups/recovery-20261118T215628Z-a478ee3e.vwrec')
SHA='48c46b90e4a2b0004d920b286df2c2649c6a80bcf34bd6be038ffe3eefb7e749'
BASE='10b53feb60db4f7d94f280b6601e6fdfd35d6137d13eb351b94f99234c4149fa'
root=pathlib.Path('/var/lib/vaultwarden-oci')
def hold(s): print('P3_G11E_EXIT=2 HOLD: '+s,flush=True);raise SystemExit(2)
if os.geteuid()!=0:hold('root inspection required')
release=pathlib.Path('/opt/vaultwarden-oci/releases/0.1.0-rc.13')
if not release.is_dir() or pathlib.Path('/opt/vaultwarden-oci/current').resolve()!=release.resolve():
    hold('installed immutable release changed')
sys.path.insert(0,str(release))
from vaultwarden_oci import storage
try: disk=storage.verify()
except (OSError,storage.StorageError):hold('dedicated storage verification failed')
if disk.uuid!='f4e0bd62-48e7-4745-8987-44b14013216d' or disk.fs_type!='ext4' or root.stat().st_dev==pathlib.Path('/').stat().st_dev:
    hold('dedicated ext4 disk/UUID/root fallback changed')
try:
    with open('/etc/vaultwarden-oci/config.toml','rb') as f: backup=tomllib.load(f)['backup']
except (OSError,KeyError,ValueError):hold('backup policy unreadable')
if (backup.get('remote',''),backup.get('local_retention_days',0),backup.get('remote_retention_days',0))!=('',0,0):
    hold('saved offsite publication or retention unexpectedly enabled')
if (root/'state/update-recovery-required.json').exists():hold('pending update recovery guard')
print('PASS: pinned release, dedicated storage, local-only backup/retention-zero',flush=True)
try:
    db=sqlite3.connect('file:'+str(root/'data/db.sqlite3')+'?mode=ro',uri=True,timeout=10)
    snapshot=sqlite3.connect(':memory:')
    try:
        db.backup(snapshot)
        if snapshot.execute('PRAGMA integrity_check').fetchone()!=('ok',):hold('SQLite integrity failed')
        users=snapshot.execute('SELECT COUNT(*) FROM users').fetchone()[0]
        rows=list(snapshot.execute('SELECT * FROM ciphers ORDER BY uuid'))
    finally:snapshot.close();db.close()
except (OSError,sqlite3.Error):hold('live snapshot failed')
def rowhash(row):
    data=repr(row).encode('utf-8')
    return hashlib.sha256(len(data).to_bytes(8,'big')+data).hexdigest()
if users!=1 or len(rows)!=2:
    hold('create exactly one NEW synthetic saved item AFTER the backup; need 1 user/2 ciphers')
if sum(rowhash(row)==BASE for row in rows)!=1:
    hold('original backed-up cipher no longer matches G11C/G11D baseline')
print('PASS: post-backup delta proved; one original cipher unchanged plus one new cipher',flush=True)
try:
    s=LOCAL.lstat()
    if not stat.S_ISREG(s.st_mode) or s.st_uid!=0 or stat.S_IMODE(s.st_mode)!=0o600 or s.st_size!=348440:
        hold('original local recovery artifact unsafe or changed')
    if hashlib.sha256(LOCAL.read_bytes()).hexdigest()!=SHA:hold('original local recovery SHA256 changed')
    state=json.loads((root/'state/recovery.json').read_text())
    assert state['local']['artifact']==str(LOCAL)
    assert state['local']['sha256']==SHA
    assert state['offsite']['remote_object']==REMOTE
    assert state['offsite']['sha256']==SHA
    assert state['verified_objects'][REMOTE]['sha256']==SHA
except (OSError,ValueError,KeyError,TypeError,AssertionError):
    hold('G11D local/offsite/independent-Age verification record missing')
print('PASS: exact G11D local and Box recovery point still pinned',flush=True)
try:
    p=subprocess.run(['rclone','cat',REMOTE],capture_output=True,timeout=180,check=False)
except (OSError,subprocess.TimeoutExpired):hold('read-only remote ciphertext retrieval failed')
if p.returncode!=0 or len(p.stdout)!=348440 or hashlib.sha256(p.stdout).hexdigest()!=SHA:
    hold('Box ciphertext SHA256 or size differs from pinned recovery point')
print('PASS: actual remote ciphertext bytes match exact SHA256 (read-only)',flush=True)
print('P3_G11E_EXIT=0 POSTBACKUP_DELTA_AND_REMOTE_BYTES_PASS; REMOTE_RESTORE=HOLD',flush=True)
PY
P3G11E
