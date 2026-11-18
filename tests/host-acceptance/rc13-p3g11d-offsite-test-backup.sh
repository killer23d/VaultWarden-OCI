bash <<'P3G11D'
set -Eeuo pipefail
set +x
umask 077
export GIT_OPTIONAL_LOCKS=0 PYTHONDONTWRITEBYTECODE=1
PARENT='bw-backup:bw-backup'
FINGER='10b53feb60db4f7d94f280b6601e6fdfd35d6137d13eb351b94f99234c4149fa'
INV='a80be9e43af84a24b505b9e4b127abeb'
SUFFIX="$(python3 -B -c 'import secrets;print(secrets.token_hex(6))')"
DEST="$PARENT/acceptance-rc13-vm8-$(date -u +%Y%m%dT%H%M%SZ)-$SUFFIX"
hold() { printf 'P3_G11D_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }

[ "$(id -un)" = ubuntu ] || hold 'wrong user'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'wrong host'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
sudo -n true >/dev/null 2>&1 || hold 'passwordless sudo unavailable'
if ! (exec 3<>/dev/tty) 2>/dev/null; then hold 'interactive terminal required'; fi

printf '%s\n' '=== P3-G11D: READ-ONLY PREFLIGHT ==='
sudo -n python3 -B - "$PARENT" "$DEST" "$FINGER" "$INV" <<'PY'
import fcntl, hashlib, json, os, pathlib, sqlite3, stat, subprocess, sys, tomllib
parent, dest, expected, invocation=sys.argv[1:]
def hold(s): print('P3_G11D_EXIT=2 HOLD: '+s,flush=True); raise SystemExit(2)
def cmd(a,timeout=120):
    try: p=subprocess.run(a,capture_output=True,text=True,timeout=timeout)
    except (OSError,subprocess.TimeoutExpired): hold('read-only command failed: '+a[0])
    if p.returncode or len(p.stdout)>2_000_000: hold('read-only command failed: '+a[0])
    return p.stdout
def unit(name):
    raw=cmd(['systemctl','show',name,'--property=LoadState,ActiveState,SubState,UnitFileState,InvocationID'])
    return dict(x.split('=',1) for x in raw.splitlines() if '=' in x)
rel=pathlib.Path('/opt/vaultwarden-oci/releases/0.1.0-rc.13')
root=pathlib.Path('/var/lib/vaultwarden-oci')
if os.geteuid()!=0 or not rel.is_dir() or pathlib.Path('/opt/vaultwarden-oci/current').resolve()!=rel.resolve():
    hold('wrong release/execution identity')
sys.path.insert(0,str(rel))
from vaultwarden_oci import storage
try: disk=storage.verify()
except (OSError,storage.StorageError): hold('storage verification failed')
if disk.uuid!='f4e0bd62-48e7-4745-8987-44b14013216d' or disk.fs_type!='ext4' or not root.is_mount() or root.stat().st_dev==pathlib.Path('/').stat().st_dev:
    hold('dedicated ext4 disk/UUID guard failed')
if (root/'state/update-recovery-required.json').exists(): hold('update recovery guard exists')
cfg=pathlib.Path('/etc/vaultwarden-oci/config.toml')
try:
    st=cfg.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid!=0 or stat.S_IMODE(st.st_mode)!=0o600:
        hold('unsafe operator configuration')
    with cfg.open('rb') as f: backup=tomllib.load(f)['backup']
except (OSError,ValueError,KeyError): hold('backup policy not readable')
if (backup.get('remote',''),backup.get('local_retention_days',0),backup.get('remote_retention_days',0))!=('',0,0):
    hold('saved cloud publication or pruning enabled')
try:
    fd=os.open('/run/vaultwarden-oci/lock',os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    fcntl.flock(fd,fcntl.LOCK_UN)
    os.close(fd)
except (OSError,BlockingIOError): hold('mutation lock busy')
for name in ('vaultwarden-oci-backup.service','vaultwarden-oci-update-check.service',
             'vaultwarden-oci-maintenance.service','vaultwarden-oci-dns.service',
             'vaultwarden-oci-health.service','vaultwarden-oci-backup.timer',
             'vaultwarden-oci-update-check.timer','vaultwarden-oci-maintenance.timer',
             'vaultwarden-oci-health.timer'):
    u=unit(name)
    if u.get('LoadState')!='loaded' or u.get('ActiveState')!='inactive': hold('unexpected automation: '+name)
w=unit('crowdsec-cloudflare-worker-bouncer.service')
if tuple(w.get(x) for x in ('LoadState','ActiveState','SubState','UnitFileState','InvocationID'))!=(
       'loaded','active','running','disabled',invocation):
    hold('Cloudflare Worker invocation/Fail Open changed')
for name in ('vaultwarden-oci-vaultwarden','vaultwarden-oci-caddy'):
    try: x=json.loads(cmd(['docker','container','inspect',name]))[0]['State']
    except (ValueError,IndexError,KeyError,TypeError): hold('Docker state unreadable')
    if x.get('Status')!='running' or x.get('Paused') is not False or x.get('Health',{}).get('Status')!='healthy':
        hold('container unhealthy: '+name)
db=sqlite3.connect('file:'+str(root/'data/db.sqlite3')+'?mode=ro',uri=True,timeout=10)
snap=sqlite3.connect(':memory:')
try:
    db.backup(snap)
    if snap.execute('PRAGMA integrity_check').fetchone()!=('ok',): hold('SQLite integrity check failed')
    users=snap.execute('SELECT COUNT(*) FROM users').fetchone()[0]
    ciphers=snap.execute('SELECT COUNT(*) FROM ciphers').fetchone()[0]
    digest=hashlib.sha256()
    for row in snap.execute('SELECT * FROM ciphers ORDER BY uuid'):
        raw=repr(row).encode('utf-8')
        digest.update(len(raw).to_bytes(8,'big')); digest.update(raw)
finally: snap.close(); db.close()
if users!=1 or ciphers!=1 or digest.hexdigest()!=expected:
    hold('populated test vault changed since G11C baseline')
print('PASS: populated fixture unchanged (1 user, 1 item), SQLite integrity ok',flush=True)
names=cmd(['rclone','listremotes'],20).splitlines()
if 'bw-backup:' not in [x.strip() for x in names]: hold('root rclone remote not configured')
try:
    info=json.loads(cmd(['rclone','lsjson','--stat',parent]))
    children=json.loads(cmd(['rclone','lsjson',parent]))
except (ValueError,TypeError): hold('rclone parent metadata invalid')
if not isinstance(info,dict) or info.get('IsDir') is not True or not isinstance(children,list):
    hold('remote parent not an accessible directory')
leaf=dest.rsplit('/',1)[-1]
if any(isinstance(x,dict) and str(x.get('Name','')).casefold()==leaf.casefold() for x in children):
    hold('test-only folder already exists')
print('PASS: root Box parent accessible, newly generated test path unused',flush=True)
print('PASS: containers/Worker/automation/lock/dedicated disk guards',flush=True)
print('P3_G11D_PRECHECK=PASS; NO_REMOTE_WRITES_YET',flush=True)
PY

printf 'NEW TEST-ONLY DESTINATION: %s\n' "$DEST"
printf '%s\n' 'This creates one Box subfolder and one NEW encrypted local + remote .vwrec.'
printf '%s\n' 'The product briefly pauses/resumes containers, then verifies remote readback.'
printf '%s\n' 'No historical recovery points, DNS, timers, or saved retention policy will be changed.'
exec 3<>/dev/tty || hold 'cannot open controlling terminal'
printf 'Type AUTHORIZE P3-G11D UPLOAD to permit this one test-only upload: ' >&3
IFS= read -r answer <&3 || hold 'authorization input unavailable'
[ "$answer" = 'AUTHORIZE P3-G11D UPLOAD' ] || hold 'upload not authorized'
exec 3>&-

printf '%s\n' '=== AUTHORIZED NEW FOLDER AND SUPPORTED ONE-TIME BACKUP ==='
sudo -n rclone mkdir "$DEST" || hold 'new Box folder could not be created'
if ! sudo -n rclone lsjson "$DEST" |
  python3 -B -c 'import json,sys; a=json.load(sys.stdin);sys.exit(0 if isinstance(a,list) and not a else 2)'; then
  hold 'new test-only Box folder not empty; refusing upload'
fi
if ! sudo -n /usr/local/bin/vwctl backup --remote "$DEST"; then
  hold 'backup/remote readback failed; preserve artifacts, DO NOT retry blindly'
fi

OBJ="$(sudo -n python3 -B - "$DEST" <<'PY'
import hashlib,json,pathlib,stat,sys
dest=sys.argv[1]
try:
    data=json.loads(pathlib.Path('/var/lib/vaultwarden-oci/state/recovery.json').read_text())
    a=data['local']; b=data['offsite']; f=pathlib.Path(a['artifact']); s=f.lstat()
    assert f.parent==pathlib.Path('/var/lib/vaultwarden-oci/backups')
    assert stat.S_ISREG(s.st_mode) and stat.S_IMODE(s.st_mode)==0o600 and s.st_uid==0
    assert b['remote_object']==dest+'/'+f.name and f.name.endswith('.vwrec')
    assert s.st_size==a['size']==b['size']
    assert hashlib.sha256(f.read_bytes()).hexdigest()==a['sha256']==b['sha256']
except (OSError,ValueError,KeyError,TypeError,AssertionError):
    raise SystemExit('P3_G11D_EXIT=2 HOLD: product post-upload metadata/hash mismatch')
print(b['remote_object'])
PY
)" || hold 'new local/offsite recovery record inconsistent'
[ -n "$OBJ" ] || hold 'missing new offsite object record'
printf 'PASS: product verified cloud readback for %s\n' "$OBJ"

printf '%s\n' '=== INDEPENDENT AGE/SOPS VERIFICATION OF EXACT REMOTE OBJECT ==='
printf '%s\n' 'Use the matching disposable OFFLINE Age private identity through the hidden chooser.'
if ! sudo -n /usr/local/bin/vwctl recovery verify --from-remote "$OBJ" </dev/tty >/dev/tty 2>&1; then
  hold 'independent remote Age/SOPS verification failed or was cancelled'
fi

sudo -n python3 -B - "$OBJ" "$FINGER" "$INV" <<'PY'
import hashlib,json,pathlib,sqlite3,subprocess,sys,tomllib
obj,expected,inv=sys.argv[1:]
root=pathlib.Path('/var/lib/vaultwarden-oci')
try:
    state=json.loads((root/'state/recovery.json').read_text())
    item=state['verified_objects'][obj]; off=state['offsite']
    assert off['remote_object']==obj and item['sha256']==off['sha256'] and item['size']==off['size']
    assert isinstance(item['verified_at'],str) and item['verified_at']
    with pathlib.Path('/etc/vaultwarden-oci/config.toml').open('rb') as f: p=tomllib.load(f)['backup']
    assert (p.get('remote',''),p.get('local_retention_days',0),p.get('remote_retention_days',0))==('',0,0)
    db=sqlite3.connect('file:'+str(root/'data/db.sqlite3')+'?mode=ro',uri=True)
    snap=sqlite3.connect(':memory:')
    db.backup(snap)
    assert snap.execute('PRAGMA integrity_check').fetchone()==('ok',)
    assert snap.execute('SELECT COUNT(*) FROM users').fetchone()[0]==1
    assert snap.execute('SELECT COUNT(*) FROM ciphers').fetchone()[0]==1
    h=hashlib.sha256()
    for row in snap.execute('SELECT * FROM ciphers ORDER BY uuid'):
        b=repr(row).encode('utf-8')
        h.update(len(b).to_bytes(8,'big'));h.update(b)
    snap.close();db.close()
    assert h.hexdigest()==expected
    w=subprocess.run(['systemctl','show','crowdsec-cloudflare-worker-bouncer.service',
                     '--property=InvocationID'],capture_output=True,text=True,check=True)
    assert w.stdout.strip()=='InvocationID='+inv
    for name in ('vaultwarden-oci-vaultwarden','vaultwarden-oci-caddy'):
        x=subprocess.run(['docker','container','inspect',name],capture_output=True,text=True,check=True,timeout=30)
        st=json.loads(x.stdout)[0]['State']
        assert st['Status']=='running' and st['Paused'] is False and st['Health']['Status']=='healthy'
    proc=subprocess.run(['/usr/local/bin/vwctl','doctor','--json'],capture_output=True,text=True,check=True,timeout=120)
    d=json.loads(proc.stdout)
    checks={x['id']:x['status'] for x in d['checks']}
    assert d['overall']!='FAIL' and 'FAIL' not in checks.values()
    for check in ('runtime.paths','recovery.local','edge.cloudflare.iptables',
                  'crowdsec.cloudflare','crowdsec.firewall','secrets.decrypt'):
        assert checks.get(check)=='PASS'
except (OSError,KeyError,IndexError,TypeError,ValueError,AssertionError,sqlite3.Error,
        subprocess.CalledProcessError,subprocess.TimeoutExpired):
    raise SystemExit('P3_G11D_EXIT=2 HOLD: post-upload read-only reconciliation failed')
print('PASS: independent remote Age/SOPS verification recorded')
print('PASS: populated fingerprint unchanged; containers/doctor/Worker healthy; local-only policy preserved')
PY
printf 'P3_G11D_OBJECT=%s\n' "$OBJ"
printf '%s\n' 'P3_G11D_EXIT=0 UPLOAD_READBACK_AGE_PASS; REMOTE_RESTORE=HOLD'
P3G11D
