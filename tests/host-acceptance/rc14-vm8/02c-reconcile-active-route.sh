#!/usr/bin/env bash
bash <<'RC14_D_02C'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
hold() { printf 'RC14_D_02C_WRAPPER_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'Run as ubuntu'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'Wrong VM'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
sudo -n true >/dev/null 2>&1 || hold 'Passwordless sudo required'

PIN='92b9300f96125d19105cc1d4865024cb49612b28'
EVID="$HOME/vwoci-acceptance/rc14-d-92b9300f9612"
WORK="$HOME/VaultWarden-OCI-rc14-c-92b9300f9612"
[ -d "$EVID" ] && [ ! -L "$EVID" ] || hold 'Original RC14-D evidence missing'
[ "$(stat -c '%u:%a' "$EVID")" = "$(id -u):700" ] || hold 'Unsafe evidence custody'
[ -d "$WORK/.git" ] && [ ! -L "$WORK" ] || hold 'Pinned source checkout missing'
[ "$(git -C "$WORK" rev-parse HEAD)" = "$PIN" ] || hold 'Candidate SHA changed'
[ -z "$(git -C "$WORK" status --porcelain)" ] || hold 'Candidate checkout dirty'
[ "$(readlink -f /opt/vaultwarden-oci/current)" = '/opt/vaultwarden-oci/releases/0.1.0-rc.14' ] ||
  hold 'Installed immutable rc14 changed'
for name in reconcile-pre.json reconcile.stdout reconcile.stderr reconciled.json after.json; do
  [ ! -e "$EVID/$name" ] && [ ! -L "$EVID/$name" ] ||
    hold "Evidence $name already exists; no automatic replay"
done

echo '=== RC14-D-02C preflight: live Worker unchanged, Fail Open stable ==='
if sudo -n /usr/bin/python3 -B - "$EVID" "$PIN" <<'PY_PRE'
import hashlib,json,os,pathlib,pwd,re,sqlite3,stat,subprocess,sys
def hold(s):print('RC14_D_02C_PRE_EXIT=2 HOLD: '+s,flush=True);raise SystemExit(2)
evid=pathlib.Path(sys.argv[1]);pin=sys.argv[2]
if os.geteuid()!=0 or os.environ.get('SUDO_USER')!='ubuntu':hold('Expected root from ubuntu sudo')
operator=pwd.getpwnam('ubuntu')
def original(name,uid):
    p=evid/name;st=p.lstat()
    if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)
        or st.st_uid!=uid or stat.S_IMODE(st.st_mode)!=0o600 or st.st_size>65536):
        hold('Unsafe prior evidence custody: '+name)
    return p.read_text(encoding='utf-8')
try:
    old=json.loads(original('before.json',0))
    stopped=original('stop.stdout',operator.pw_uid)
    started=original('rearm.stdout',operator.pw_uid)
    error=original('rearm.stderr',operator.pw_uid)
except (OSError,ValueError,TypeError,UnicodeError):hold('Prior phase evidence missing or malformed')
if (old.get('source_commit')!=pin or old.get('phase')!='prestop'
    or not re.fullmatch('[0-9a-f]{32}',str(old.get('old_invocation','')))
    or not re.fullmatch('[0-9a-f]{32}',str(old.get('old_route_id','')))
    or 'controlled Worker stop' not in stopped
    or 'Cloudflare remediation started for one explicit service invocation' not in started
    or 'Cloudflare did not independently report Fail Open=true' not in error):
    hold('Failed rearm cause or controlled shutdown receipt is not the diagnosed checkpoint')
boot=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
if boot!=old.get('boot_id'):hold('Kernel rebooted since failed rearm')
sys.path.insert(0,'/opt/vaultwarden-oci/releases/0.1.0-rc.14')
from vaultwarden_oci import cloudflare_route_mode as cf,crowdsec_worker_policy,edge,storage
args=['systemctl','show',edge.BOUNCER_SERVICE,'--no-pager','--property=LoadState,ActiveState,SubState,Result,UnitFileState,MainPID,NRestarts,Restart,InvocationID']
p=subprocess.run(args,stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=20,check=True)
state=dict(x.split('=',1) for x in p.stdout.splitlines() if '=' in x)
inv=state.get('InvocationID')
if (state.get('LoadState')!='loaded' or state.get('ActiveState')!='active'
    or state.get('SubState')!='running' or state.get('Result')!='success'
    or state.get('UnitFileState')!='disabled' or state.get('Restart')!='no'
    or state.get('NRestarts')!='0'
    or not str(state.get('MainPID','')).isdigit() or int(state['MainPID'])<=0
    or not re.fullmatch('[0-9a-f]{32}',str(inv)) or inv==old['old_invocation']
    or edge._service_invocation_id(edge.run_command)!=inv):
    hold('Worker is not the expected new healthy and boot-disabled invocation')
paths=edge.EdgePaths()
if not crowdsec_worker_policy.runtime_policy_healthy(paths,edge.run_command):
    hold('Current invocation has no local-only source attestation')
if edge._fail_open_confirmed(paths.fail_open_confirmation,inv):
    hold('Local confirmation already exists; do not recreate')
identity=storage.verify()
if identity.uuid!='f4e0bd62-48e7-4745-8987-44b14013216d' or identity.fs_type!='ext4':
    hold('Dedicated disk identity changed')
rid=cf.read_owned_route_id(require_fail_open=True)
if rid==old['old_route_id']:hold('Cloudflare Route not recreated')
cf.wait_owned_route_stable(rid)
record={'schema_version':1,'result':'PRECHECK_CURRENT_WORKER_STABLE','source_commit':pin,
        'boot_id':boot,'old_invocation':old['old_invocation'],'new_invocation':inv,
        'old_route_id':old['old_route_id'],'new_route_id':rid,
        'main_pid':int(state['MainPID']),'original_cipher_sha256':old['original_cipher_sha256']}
try:
    out=evid/'reconcile-pre.json'
    fd=os.open(out,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w',encoding='utf-8') as stream:
        json.dump(record,stream,sort_keys=True,indent=2);stream.write('\n')
        stream.flush();os.fsync(stream.fileno())
except OSError:hold('Cannot publish private preflight')
print('PASS: Unchanged new Worker, local policy, dedicated disk, two independent Fail Open Route reads')
print('RC14_D_02C_PRE_EXIT=0 ONE_IDEMPOTENT_CONFIRMATION_ALLOWED')
PY_PRE
then :; else hold 'Preflight failed; no provider/API reconciliation'; fi

echo '=== RC14-D-02C supported existing-invocation ensure-fail-open ONCE ==='
echo 'INFO: No systemctl start/stop. Already Fail Open is required; updated=yes is HOLD.'
if sudo -n /usr/local/bin/vwctl crowdsec ensure-fail-open \
   >"$EVID/reconcile.stdout" 2>"$EVID/reconcile.stderr"; then
  :
else
  rc=$?
  printf 'RC14_D_02C_WRAPPER_EXIT=2 HOLD: confirmation rc=%s; no retry; private evidence=%s\n' "$rc" "$EVID" >&2
  exit 2
fi
if ! grep -Fq 'updated=no' "$EVID/reconcile.stdout"; then
  hold "Exact existing Route was not idempotent; inspect private evidence, no retry"
fi
echo 'PASS: Installed owner confirmed existing Route; updated=no (no Cloudflare PUT)'

echo '=== RC14-D-02C independent postflight: same invocation and original vault ==='
if sudo -n /usr/bin/python3 -B - "$EVID" "$PIN" <<'PY_POST'
import hashlib,json,os,pathlib,sqlite3,stat,subprocess,sys
def hold(s):print('RC14_D_02C_POST_EXIT=2 HOLD: '+s,flush=True);raise SystemExit(2)
evid=pathlib.Path(sys.argv[1]);pin=sys.argv[2]
before=evid/'reconcile-pre.json'
st=before.lstat()
if not stat.S_ISREG(st.st_mode) or st.st_uid!=0 or stat.S_IMODE(st.st_mode)!=0o600:
    hold('Preflight receipt custody invalid')
row=json.loads(before.read_text())
if row.get('source_commit')!=pin or row.get('result')!='PRECHECK_CURRENT_WORKER_STABLE':
    hold('Preflight identity changed')
if row.get('boot_id')!=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip():
    hold('Unexpected kernel boot change')
sys.path.insert(0,'/opt/vaultwarden-oci/releases/0.1.0-rc.14')
from vaultwarden_oci import cloudflare_route_mode as cf,crowdsec_worker_policy,edge,storage
inv=edge._service_invocation_id(edge.run_command)
paths=edge.EdgePaths()
if (inv!=row['new_invocation'] or not edge._disabled(edge.BOUNCER_SERVICE,edge.run_command)
    or not crowdsec_worker_policy.runtime_policy_healthy(paths,edge.run_command)
    or not edge._fail_open_confirmed(paths.fail_open_confirmation,inv)):
    hold('Current Worker invocation, confinement, or proof differs from prestop')
p=paths.fail_open_confirmation;st=p.lstat()
if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_uid!=0 or stat.S_IMODE(st.st_mode)!=0o600:
    hold('New proof custody invalid')
try: proof=json.loads(p.read_text())
except (OSError,ValueError):hold('New local proof invalid')
if (proof.get('verification')!='cloudflare-api-readback'
    or proof.get('invocation_id')!=inv
    or not isinstance(proof.get('route'),dict)
    or proof['route'].get('id')!=row['new_route_id']):
    hold('Provider-verified local proof is not bound to current exact Route')
rid=cf.read_owned_route_id(require_fail_open=True)
if rid!=row['new_route_id']:hold('Current provider Route identity changed')
cf.wait_owned_route_stable(rid)
if storage.verify().uuid!='f4e0bd62-48e7-4745-8987-44b14013216d':
    hold('Dedicated storage changed')
try:
    src=sqlite3.connect('file:/var/lib/vaultwarden-oci/data/db.sqlite3?mode=ro',uri=True,timeout=15)
    db=sqlite3.connect(':memory:');src.backup(db,pages=128,sleep=0.1);src.close()
    if db.execute('PRAGMA integrity_check').fetchone()!=('ok',):
        hold('SQLite integrity mismatch')
    users=db.execute('SELECT count(*) FROM users').fetchone()[0]
    ciphers=db.execute('SELECT count(*) FROM ciphers').fetchone()[0]
    h=hashlib.sha256()
    for item in db.execute('SELECT * FROM ciphers ORDER BY uuid'):
        value=repr(item).encode('utf-8');h.update(len(value).to_bytes(8,'big'));h.update(value)
    db.close()
except (OSError,sqlite3.Error):hold('Private read-only SQLite snapshot failed')
if (users,ciphers,h.hexdigest())!=(1,1,row['original_cipher_sha256']):
    hold('Original vault contents changed')
proc=subprocess.run(['/usr/local/bin/vwctl','doctor','--json'],stdin=subprocess.DEVNULL,
                    capture_output=True,text=True,timeout=90,check=False)
try:
    report=json.loads(proc.stdout)
    checks={x['id']:x['status'] for x in report['checks']}
except (ValueError,KeyError,TypeError):hold('Installed doctor JSON unavailable')
if proc.returncode!=0 or report.get('overall')!='PASS' or 'FAIL' in checks.values() or checks.get('crowdsec.cloudflare')!='PASS':
    hold('Installed doctor not PASS')
record=dict(row, result='CURRENT_WORKER_ROUTE_RECONCILED',
            original_auto_rearm_exit=1, approved_idempotent_reconcile='updated=no',
            proof_verified=True, original_vault_verified=True, doctor='PASS')
try:
    out=evid/'reconciled.json'
    fd=os.open(out,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w',encoding='utf-8') as stream:
        json.dump(record,stream,sort_keys=True,indent=2);stream.write('\n')
        stream.flush();os.fsync(stream.fileno())
except OSError:hold('Failed to publish root-private reconciliation witness')
print('PASS: same healthy Worker invocation; API proof, two provider samples, original vault and doctor PASS')
print('RC14_D_02C_EXIT=0 CURRENT_WORKER_ROUTE_RECONCILED')
print('ORIGINAL_SINGLE_COMMAND_REARM=FAILED; RELEASE_GO=HOLD')
print('REBOOT=NOT_AUTHORIZED_UNTIL_READBACK_FIX_ACCEPTED')
PY_POST
then
  printf 'RC14_D_02C_WRAPPER_EXIT=0\n'
  printf 'PRIVATE_EVIDENCE_DIR=%s\n' "$EVID"
else
  hold 'Independent reconciliation postflight failed; no restart or automatic retry'
fi
RC14_D_02C
