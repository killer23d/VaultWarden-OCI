bash <<'P3G11C'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
hold() { printf 'P3_G11C_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'wrong user'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'wrong host'
[ "$(uname -m)" = aarch64 ] || hold 'wrong architecture'
sudo -n true >/dev/null 2>&1 || hold 'passwordless sudo unavailable'
sudo -n python3 -B <<'PY'
import hashlib, os, pathlib, sqlite3, sys, tomllib
def hold(message):
    print('P3_G11C_EXIT=2 HOLD: '+message)
    raise SystemExit(2)
if os.geteuid()!=0: hold('root inspection required')
release=pathlib.Path('/opt/vaultwarden-oci/releases/0.1.0-rc.13')
if pathlib.Path('/opt/vaultwarden-oci/current').resolve()!=release.resolve():
    hold('active installed release changed')
sys.path.insert(0,str(release))
from vaultwarden_oci import storage
try: identity=storage.verify()
except (storage.StorageError,OSError): hold('dedicated storage verification failed')
if identity.uuid!='f4e0bd62-48e7-4745-8987-44b14013216d':
    hold('dedicated storage UUID changed')
try:
    with open('/etc/vaultwarden-oci/config.toml','rb') as stream:
        policy=tomllib.load(stream)['backup']
except (OSError,KeyError,ValueError): hold('backup policy unreadable')
if policy.get('remote','')!='' or policy.get('local_retention_days',0)!=0 or policy.get('remote_retention_days',0)!=0:
    hold('backup publishing or retention unexpectedly enabled')
print('PASS: immutable release, dedicated disk and LOCAL-ONLY backup policy')
root=pathlib.Path('/var/lib/vaultwarden-oci')
if (root/'state/update-recovery-required.json').exists():
    hold('pending update recovery guard')
try:
    db=sqlite3.connect('file:'+str(root/'data/db.sqlite3')+'?mode=ro',uri=True,timeout=10)
    snapshot=sqlite3.connect(':memory:')
    try:
        db.backup(snapshot)
        if snapshot.execute('PRAGMA integrity_check').fetchone()!=('ok',):
            hold('SQLite integrity failed')
        users=snapshot.execute('SELECT COUNT(*) FROM users').fetchone()[0]
        ciphers=snapshot.execute('SELECT COUNT(*) FROM ciphers').fetchone()[0]
        digest=hashlib.sha256()
        for row in snapshot.execute('SELECT * FROM ciphers ORDER BY uuid'):
            raw=repr(row).encode('utf-8')
            digest.update(len(raw).to_bytes(8,'big'))
            digest.update(raw)
    finally: snapshot.close(); db.close()
except (sqlite3.Error,OSError): hold('read-only vault snapshot unavailable')
print('INFO: disposable vault users='+str(users)+' ciphers='+str(ciphers))
if not (1<=users<=3 and 1<=ciphers<=15):
    hold('create 1-3 synthetic test users and 1-15 saved items before offsite backup')
print('PASS: populated disposable vault fixture and SQLite integrity')
print('CIPHER_RECORDS_FINGERPRINT_SHA256='+digest.hexdigest())
print('P3_G11C_EXIT=0 POPULATED_FIXTURE_READY; REMOTE_UPLOAD=HOLD')
PY
P3G11C
