#!/usr/bin/env bash
bash <<'RC14_D'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
hold() { printf 'RC14_D_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'Wrong user'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'Wrong VM'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
sudo -n true >/dev/null 2>&1 || hold 'Passwordless sudo required'

PIN='92b9300f96125d19105cc1d4865024cb49612b28'
WORK="$HOME/VaultWarden-OCI-rc14-c-${PIN:0:12}"
EVID="$HOME/vwoci-acceptance/rc14-d-${PIN:0:12}"
[ -d "$WORK/.git" ] && [ "$(git -C "$WORK" rev-parse HEAD)" = "$PIN" ] || hold 'Pinned source missing or changed'
[ "$(readlink -f /opt/vaultwarden-oci/current)" = '/opt/vaultwarden-oci/releases/0.1.0-rc.14' ] || hold 'Selected release is not installed rc14'
[ ! -e "$EVID" ] && [ ! -L "$EVID" ] || hold 'Phase already begun; no replay'
mkdir -m 700 "$EVID" || hold 'Evidence folder unavailable'

echo '=== RC14-D current Worker, Cloudflare Route and data witness ==='
if sudo -n /usr/bin/python3 -B - "$EVID" "$PIN" <<'PY_PRE'
import datetime,hashlib,json,os,pathlib,re,sqlite3,stat,sys
sys.path.insert(0, '/opt/vaultwarden-oci/releases/0.1.0-rc.14')
from vaultwarden_oci import cloudflare_route_mode as route, crowdsec_worker_policy,edge,storage

def hold(s):print('RC14_D_PRE_EXIT=2 HOLD: '+s,flush=True);raise SystemExit(2)
p=pathlib.Path(sys.argv[1]);pin=sys.argv[2]
if os.geteuid()!=0 or pathlib.Path('/opt/vaultwarden-oci/current').resolve()!=pathlib.Path('/opt/vaultwarden-oci/releases/0.1.0-rc.14'):hold('Unexpected source/privilege')
identity=storage.verify()
if identity.uuid!='f4e0bd62-48e7-4745-8987-44b14013216d' or identity.fs_type!='ext4':hold('Disk mismatch')
inv=edge._service_invocation_id(edge.run_command)
if not inv or not edge._disabled(edge.BOUNCER_SERVICE,edge.run_command) or not crowdsec_worker_policy.runtime_policy_healthy(edge.EdgePaths(),edge.run_command) or not edge._fail_open_confirmed(edge.FAIL_OPEN_CONFIRMATION,inv):hold('Current Worker not proven active, boot-disabled and confirmed')
old_id=route.read_owned_route_id(require_fail_open=True)
route.wait_owned_route_stable(old_id)
try:
    src=sqlite3.connect('file:/var/lib/vaultwarden-oci/data/db.sqlite3?mode=ro',uri=True,timeout=15)
    db=sqlite3.connect(':memory:');src.backup(db,pages=128,sleep=0.1);src.close()
    if db.execute('PRAGMA integrity_check').fetchone()!=('ok',):hold('Database integrity')
    users=db.execute('SELECT count(*) FROM users').fetchone()[0];count=db.execute('SELECT count(*) FROM ciphers').fetchone()[0]
    h=hashlib.sha256()
    for row in db.execute('SELECT * FROM ciphers ORDER BY uuid'):
        raw=repr(row).encode();h.update(len(raw).to_bytes(8,'big'));h.update(raw)
    db.close()
except (OSError,sqlite3.Error):hold('SQLite read-only snapshot failed')
if (users,count,h.hexdigest())!=(1,1,'10b53feb60db4f7d94f280b6601e6fdfd35d6137d13eb351b94f99234c4149fa'):hold('Original restored item/user changed')
record={'boot_id':pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip(),'source_commit':pin,'old_invocation':inv,'old_route_id':old_id,'original_cipher_sha256':h.hexdigest(),'phase':'prestop','utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
fd=os.open(p/'before.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,'w',encoding='utf-8') as stream: json.dump(record,stream,sort_keys=True,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
print('PASS: exact current confirmed Worker Route, two provider samples and original 1 user/1 cipher')
print('RC14_D_PRE_EXIT=0; STOP_NOT_RUN')
PY_PRE
then :; else hold 'Prestop witness failed; no Worker stop'; fi

if sudo -n /usr/local/bin/vwctl doctor --json >"$EVID/doctor-before.json"; then :; else hold 'Prestop installed doctor failed'; fi

echo '=== RC14-D ONE supported controlled stop and expected upstream exit-1 normalization ==='
if sudo -n /usr/local/bin/vwctl crowdsec remediation-stop >"$EVID/stop.stdout" 2>"$EVID/stop.stderr"; then
  echo 'PASS: controlled stop verified Cloudflare cleanup and normalized only expected upstream exit-1'
else
  rc=$?; printf 'RC14_D_EXIT=2 HOLD: controlled stop rc=%s; DO NOT retry; evidence=%s\n' "$rc" "$EVID" >&2; exit 2
fi
if sudo -n /usr/bin/python3 -B - <<'PY_STOP'
import subprocess,sys
p=subprocess.run(['systemctl','show','crowdsec-cloudflare-worker-bouncer.service','--property=ActiveState,MainPID,UnitFileState,Restart,Result','--no-pager'],capture_output=True,text=True,check=True)
s=dict(x.split('=',1) for x in p.stdout.splitlines() if '=' in x)
if any(s.get(k)!=v for k,v in {'ActiveState':'inactive','MainPID':'0','UnitFileState':'disabled','Restart':'no','Result':'success'}.items()):raise SystemExit(2)
print('PASS: after controlled stop, systemd inactive/success, no PID, Worker boot-disabled')
PY_STOP
then :; else hold 'Controlled stop left unexpected unit state; no Worker restart'; fi

echo '=== RC14-D ONE supported new invocation and automatic Fail Open ==='
if sudo -n /usr/local/bin/vwctl crowdsec remediation-start --auto-fail-open >"$EVID/rearm.stdout" 2>"$EVID/rearm.stderr"; then
  echo 'PASS: new invocation/automatic Cloudflare command exited 0'
else
  rc=$?; printf 'RC14_D_EXIT=2 HOLD: re-arm rc=%s; DO NOT retry; evidence=%s\n' "$rc" "$EVID" >&2; exit 2
fi
if grep -Fq 'updated=yes' "$EVID/rearm.stdout"; then
  echo 'PASS: new Route required and received automatic Fail Open update'
else
  hold 'No updated=yes evidence; do not restart Worker'
fi

echo '=== RC14-D independent new Route, original vault data, doctor ==='
if sudo -n /usr/bin/python3 -B - "$EVID" "$PIN" <<'PY_AFTER'
import datetime,hashlib,json,os,pathlib,sqlite3,stat,subprocess,sys
sys.path.insert(0, '/opt/vaultwarden-oci/releases/0.1.0-rc.14')
from vaultwarden_oci import cloudflare_route_mode as route,crowdsec_worker_policy,edge,storage

def hold(s):print('RC14_D_POST_EXIT=2 HOLD: '+s,flush=True);raise SystemExit(2)
p=pathlib.Path(sys.argv[1]);pin=sys.argv[2]
b=p/'before.json';st=b.lstat()
if not stat.S_ISREG(st.st_mode) or st.st_uid!=0 or stat.S_IMODE(st.st_mode)!=0o600:hold('Private before witness unsafe')
before=json.loads(b.read_text())
if before.get('source_commit')!=pin or before.get('boot_id')!=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip():hold('Checkpoint stale or boot changed')
inv=edge._service_invocation_id(edge.run_command)
if not inv or inv==before['old_invocation'] or not edge._disabled(edge.BOUNCER_SERVICE,edge.run_command):hold('Expected fresh active/disabled Worker invocation missing')
if not crowdsec_worker_policy.runtime_policy_healthy(edge.EdgePaths(),edge.run_command) or not edge._fail_open_confirmed(edge.FAIL_OPEN_CONFIRMATION,inv):hold('Local-only policy or current confirmation invalid')
new_id=route.read_owned_route_id(require_fail_open=True)
route.wait_owned_route_stable(new_id)
if new_id==before['old_route_id']:hold('Expected recreated Route ID')
if storage.verify().uuid!='f4e0bd62-48e7-4745-8987-44b14013216d':hold('Disk changed')
try:
    src=sqlite3.connect('file:/var/lib/vaultwarden-oci/data/db.sqlite3?mode=ro',uri=True,timeout=15)
    db=sqlite3.connect(':memory:');src.backup(db,pages=128,sleep=0.1);src.close()
    if db.execute('PRAGMA integrity_check').fetchone()!=('ok',):hold('Database integrity')
    h=hashlib.sha256()
    for row in db.execute('SELECT * FROM ciphers ORDER BY uuid'):
        raw=repr(row).encode();h.update(len(raw).to_bytes(8,'big'));h.update(raw)
    if db.execute('SELECT count(*) FROM users').fetchone()[0]!=1 or db.execute('SELECT count(*) FROM ciphers').fetchone()[0]!=1 or h.hexdigest()!=before['original_cipher_sha256']:hold('Vault contents changed')
    db.close()
except (OSError,sqlite3.Error):hold('SQLite read-only snapshot failed')
r=subprocess.run(['/usr/local/bin/vwctl','doctor','--json'],capture_output=True,text=True,timeout=90,check=False)
try:
    doc=json.loads(r.stdout)
    checks={x['id']:x['status'] for x in doc['checks']}
except (ValueError,TypeError,KeyError):hold('Installed doctor JSON missing')
if r.returncode!=0 or doc.get('overall')!='PASS' or 'FAIL' in checks.values() or checks.get('crowdsec.cloudflare')!='PASS':hold('Installed doctor not fully PASS')
receipt={'boot_id':before['boot_id'],'source_commit':pin,'old_invocation':before['old_invocation'],'new_invocation':inv,'old_route_id':before['old_route_id'],'new_route_id':new_id,'cloudflare_route_fail_open':True,'doctor':'PASS','original_cipher_sha256':h.hexdigest(),'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'result':'PASS'}
fd=os.open(p/'after.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,'w',encoding='utf-8') as stream:json.dump(receipt,stream,sort_keys=True,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
print('PASS: original Worker stopped through verified path; new invocation, new Route ID, Fail Open and original cipher persist')
print('PASS: installed rc14 doctor overall PASS and new source policy attested')
print('RC14_D_POST_EXIT=0 CONTROLLED_STOP_AND_NEW_REARM_PASS; REBOOT_NOT_RUN; RELEASE_GO=HOLD')
PY_AFTER
then
  echo 'RC14_D_EXIT=0 CONTROLLED_SHUTDOWN_AND_REARM_PASS; REBOOT=NOT_RUN; RELEASE_GO=HOLD'
  printf 'PRIVATE_EVIDENCE_DIR=%s\n' "$EVID"
else
  hold "New Worker postflight failed; no retries; evidence $EVID"
fi
RC14_D
