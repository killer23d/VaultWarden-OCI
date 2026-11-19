#!/usr/bin/env bash
bash <<'RC15_A'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0

hold() { printf 'RC15_A_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'Run as ubuntu'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'Wrong acceptance VM'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
[ "$(python3 -B -c 'import sys; print(".".join(map(str,sys.version_info[:2])))')" = 3.14 ] ||
  hold 'Ubuntu 26.04 Python 3.14 required'
sudo -n true >/dev/null 2>&1 || hold 'Passwordless sudo required'

REPO='killer23d/VaultWarden-OCI'
BRANCH='fix/rc15-cloudflare-failopen-readback-20261119'
PIN='32beec5bc905cdecdfdc4a359147c3f1d45d8444'
RUN='44618010233'
PREV='92b9300f96125d19105cc1d4865024cb49612b28'
WORK="$HOME/VaultWarden-OCI-rc15-a-32beec5bc905"
BASE="$HOME/vwoci-acceptance"
PRIOR="$BASE/rc14-d-92b9300f9612/reconciled.json"
FROM="$BASE/rc14-c-plpbvT/rc14-c-reconciled.json"

[ -d "$BASE" ] && [ ! -L "$BASE" ] || hold 'Acceptance evidence base missing'
[ "$(stat -c '%u:%a' "$BASE")" = "$(id -u):700" ] || hold 'Acceptance evidence base unsafe'
[ -f "$PRIOR" ] && [ ! -L "$PRIOR" ] || hold 'RC14-D protected reconciled receipt missing'
[ -f "$FROM" ] && [ ! -L "$FROM" ] || hold 'RC14-C protected accepted upgrade receipt missing'
[ ! -e "$WORK" ] && [ ! -L "$WORK" ] || hold 'Pinned candidate checkout exists; do not replay'
[ "$(readlink -f /opt/vaultwarden-oci/current)" = /opt/vaultwarden-oci/releases/0.1.0-rc.14 ] ||
  hold 'Current selected release no longer rc14'

EVID="$(mktemp -d "$BASE/rc15-a-XXXXXX")" ||
  hold 'Cannot allocate protected new-release evidence'
chmod 700 "$EVID"

echo '=== RC15-A verify exact candidate full GitHub CI ==='
if python3 -B - "$REPO" "$PIN" "$RUN" <<'PY_CI'
import json,sys,urllib.request
repo,pin,run=sys.argv[1:4]
request=urllib.request.Request(
    'https://api.github.com/repos/'+repo+'/actions/runs/'+run,
    headers={'Accept':'application/vnd.github+json','User-Agent':'VaultWarden-OCI-acceptance'}
)
try:
    with urllib.request.urlopen(request,timeout=20) as response: row=json.load(response)
    if (row.get('id')!=int(run) or row.get('head_sha')!=pin
        or row.get('status')!='completed' or row.get('conclusion')!='success'):
        raise ValueError('Required exact run not successful')
except (OSError,ValueError,TypeError):
    raise SystemExit('HOLD: Exact rc15 candidate full CI is unavailable or failed')
print('PASS: Exact rc15 candidate successful full GitHub CI')
PY_CI
then :; else hold 'Pinned CI gate failed; no application mutation'; fi

echo '=== RC15-A obtain exact tested candidate, never a floating release ==='
git clone --quiet --depth 1 --single-branch --branch "$BRANCH" "https://github.com/$REPO.git" "$WORK" ||
  hold "Git clone failed; evidence=$EVID"
[ "$(git -C "$WORK" rev-parse HEAD)" = "$PIN" ] ||
  hold 'Branch moved; pinned rc15 source not current'
[ -z "$(git -C "$WORK" status --porcelain)" ] || hold 'Pinned candidate checkout dirty'
[ "$(cd "$WORK" && python3 -B ./vwctl --version)" = 'vwctl 0.1.0-rc.15' ] ||
  hold 'Wrong rc15 candidate version'
if (
  cd "$WORK"
  PYTHONPATH="$WORK" python3 -B -m unittest discover -s tests -p 'test_cloudflare_route_mode.py' -q
  PYTHONPATH="$WORK" python3 -B -m unittest discover -s tests -p 'test_crowdsec_boot_stop.py' -q
) >"$EVID/focused-tests.stdout" 2>"$EVID/focused-tests.stderr"; then
  echo 'PASS: Cloudflare bounded GET/readback and boot lifecycle focused tests'
else
  hold "Focused candidate tests failed; private evidence=$EVID"
fi

echo '=== RC15-A independent rc14 Worker/data/Route preflight ==='
if sudo -n /usr/bin/python3 -B - "$PRIOR" "$FROM" "$PREV" <<'PY_PRE'
import hashlib,json,os,pathlib,pwd,re,sqlite3,stat,subprocess,sys
def hold(s):print('RC15_A_PRE_EXIT=2 HOLD: '+s,flush=True);raise SystemExit(2)
if os.geteuid()!=0 or os.environ.get('SUDO_USER')!='ubuntu':hold('Unexpected authority')
operator=pwd.getpwnam('ubuntu')
previous=pathlib.Path(sys.argv[1])
old_upgrade=pathlib.Path(sys.argv[2])
pin=sys.argv[3]
def receipt(path):
    m=path.lstat()
    if (not stat.S_ISREG(m.st_mode) or stat.S_ISLNK(m.st_mode)
        or m.st_uid!=0 or stat.S_IMODE(m.st_mode)!=0o600 or m.st_size>16384):
        hold('Previous acceptance receipt custody unsafe')
    return json.loads(path.read_text(encoding='utf-8'))
try:
    row=receipt(previous)
    upgrade=receipt(old_upgrade)
except (OSError,ValueError,TypeError):hold('Previous accepted receipt unreadable')
if (row.get('result')!='CURRENT_WORKER_ROUTE_RECONCILED'
    or row.get('source_commit')!=pin or row.get('original_auto_rearm_exit')!=1
    or row.get('approved_idempotent_reconcile')!='updated=no'
    or row.get('proof_verified') is not True or row.get('original_vault_verified') is not True
    or row.get('doctor')!='PASS'
    or upgrade.get('result')!='INSTALLED_RC14_UPGRADE_PASS'
    or upgrade.get('candidate_sha')!=pin
    or row.get('boot_id')!=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    or not re.fullmatch('[a-f0-9]{32}',str(row.get('new_invocation','')))
    or not re.fullmatch('[a-f0-9]{32}',str(row.get('new_route_id','')))):
    hold('Previous rc14 source/data/boot/worker acceptance differs')
sys.path.insert(0,'/opt/vaultwarden-oci/releases/0.1.0-rc.14')
from vaultwarden_oci import cloudflare_route_mode as cf,crowdsec_worker_policy,edge,runtime,storage
ident=storage.verify()
if ident.uuid!='f4e0bd62-48e7-4745-8987-44b14013216d' or ident.fs_type!='ext4':
    hold('Dedicated ext4 device changed')
paths=edge.EdgePaths()
inv=edge._service_invocation_id(edge.run_command)
if (inv!=row['new_invocation'] or not edge._disabled(edge.BOUNCER_SERVICE,edge.run_command)
    or not crowdsec_worker_policy.runtime_policy_healthy(paths,edge.run_command)
    or not edge._fail_open_confirmed(paths.fail_open_confirmation,inv)):
    hold('Current Worker invocation, local confinement or confirmation missing')
rid=cf.read_owned_route_id(require_fail_open=True)
if rid!=row['new_route_id']:hold('Cloudflare Route ID changed')
cf.wait_owned_route_stable(rid)
data=runtime.load_config()
if data.offsite_remote is not None or data.local_retention_days!=0 or data.remote_retention_days!=0:
    hold('VM8 backup/recovery isolation or zero retention changed')
for unit in ('vaultwarden-oci.target','vaultwarden-oci-crowdsec-boot.service'):
    p=subprocess.run(['systemctl','show',unit,'--property=LoadState,UnitFileState',
        '--no-pager'],stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=15,check=True)
    values=dict(line.split('=',1) for line in p.stdout.splitlines() if '=' in line)
    if values.get('LoadState')!='loaded' or values.get('UnitFileState')!='disabled':
        hold('Unexpected automatic boot/target configuration')
if pathlib.Path('/etc/systemd/system/vaultwarden-oci-dns.service.d/vwoci-rc14-acceptance.conf').exists():
    hold('Unexpected previous DNS acceptance isolation already staged')
guard=pathlib.Path('/var/lib/vaultwarden-oci/state/update-recovery-required.json')
if guard.exists() or guard.is_symlink():hold('Recovery-required guard still engaged')
try:
    src=sqlite3.connect('file:/var/lib/vaultwarden-oci/data/db.sqlite3?mode=ro',uri=True,timeout=15)
    db=sqlite3.connect(':memory:');src.backup(db,pages=128,sleep=0.1);src.close()
    if db.execute('PRAGMA integrity_check').fetchone()!=('ok',):hold('SQLite integrity mismatch')
    users=db.execute('SELECT count(*) FROM users').fetchone()[0]
    ciphers=db.execute('SELECT count(*) FROM ciphers').fetchone()[0]
    digest=hashlib.sha256()
    for values in db.execute('SELECT * FROM ciphers ORDER BY uuid'):
        value=repr(values).encode('utf-8')
        digest.update(len(value).to_bytes(8,'big'));digest.update(value)
    db.close()
except (OSError,sqlite3.Error):hold('Cannot verify original vault contents')
if (users,ciphers,digest.hexdigest())!=(1,1,row.get('original_cipher_sha256')):
    hold('Original vault data fingerprint changed')
print('PASS: Original vault 1 user/1 cipher unchanged; dedicated disk, boot and zero retention')
print('PASS: Current Worker and exact Route/Fail Open confirmed twice without a PUT')
print('PASS: target/boot service disabled; no stale DNS isolation or recovery-required guard')
print('RC15_A_PRE_EXIT=0 SAFE_FOR_SUPPORTED_UPGRADE')
PY_PRE
then :; else hold "Pre-upgrade state changed; evidence=$EVID"; fi

if sudo -n /usr/local/bin/vwctl doctor --json >"$EVID/doctor-before.json"; then
  if python3 -B - "$EVID/doctor-before.json" <<'PY_DOC'
import json,sys
try:
    p=json.load(open(sys.argv[1],encoding='utf-8'))
    checks={x['id']:x['status'] for x in p['checks']}
    if (p.get('overall')!='PASS' or 'FAIL' in checks.values()
        or checks.get('crowdsec.cloudflare')!='PASS'):raise ValueError('doctor not PASS')
except (OSError,ValueError,KeyError,TypeError):
    raise SystemExit('HOLD: rc14 doctor before update not PASS')
print('PASS: Installed rc14 doctor overall/Cloudflare PASS before update')
PY_DOC
  then :; else hold "Doctor preflight failed; evidence=$EVID"; fi
else
  hold "Installed rc14 doctor invocation failed; evidence=$EVID"
fi

echo '=== RC15-A supported immutable ARM64 update plan ==='
if sudo -n env VWOCI_SOURCE_OVERRIDE=1 /usr/local/bin/vwctl update check \
   --source "$WORK" --json >"$EVID/plan.json" 2>"$EVID/plan.stderr"; then
  if python3 -B - "$EVID/plan.json" <<'PY_PLAN'
import json,sys
try:
    row=json.load(open(sys.argv[1],encoding='utf-8'))
    if not (row.get('schema_version')==1
        and row.get('current',{}).get('project')=='0.1.0-rc.14'
        and row.get('candidate',{}).get('project')=='0.1.0-rc.15'
        and row.get('architecture')=='arm64'
        and row.get('available') is True
        and row.get('already_active') is False
        and row.get('use_latest') is False):
        raise ValueError('Unexpected update transition')
except (OSError,ValueError,TypeError):
    raise SystemExit('HOLD: Exact rc14-to-rc15 update plan mismatch')
print('PASS: Supported source-pinned rc14 -> rc15 plan, ARM64, no latest')
PY_PLAN
  then :; else hold "Update plan mismatch; evidence=$EVID"; fi
else
  hold "Read-only update check failed; evidence=$EVID"
fi

echo '=== RC15-A apply supported verified-recovery update exactly ONCE ==='
echo 'The installed updater creates/verifies durable encrypted .vwrec before mutation.'
if sudo -n env VWOCI_SOURCE_OVERRIDE=1 /usr/local/bin/vwctl update apply \
   --source "$WORK" --yes --json >"$EVID/apply.stdout" 2>"$EVID/apply.stderr"; then
  echo 'PASS: Supported update apply returned exit 0; no automatic replay'
else
  rc=$?
  printf 'RC15_A_EXIT=2 HOLD: supported apply rc=%s; DO NOT RETRY; PRIVATE_EVIDENCE_DIR=%s\n' "$rc" "$EVID" >&2
  exit 2
fi

echo '=== RC15-A independent source, disk, Worker and doctor verification ==='
if sudo -n /usr/bin/python3 -B - "$WORK" "$PIN" "$PRIOR" "$EVID" <<'PY_AFTER'
import hashlib,json,os,pathlib,sqlite3,stat,subprocess,sys
def hold(s):print('RC15_A_POST_EXIT=2 HOLD: '+s,flush=True);raise SystemExit(2)
work=pathlib.Path(sys.argv[1]).resolve(strict=True)
pin=sys.argv[2]
prior=pathlib.Path(sys.argv[3])
evid=pathlib.Path(sys.argv[4])
release=pathlib.Path('/opt/vaultwarden-oci/releases/0.1.0-rc.15')
current=pathlib.Path('/opt/vaultwarden-oci/current')
if (not current.is_symlink() or os.readlink(current)!='releases/0.1.0-rc.15'
    or release.is_symlink() or not release.is_dir() or current.resolve()!=release):
    hold('Selected immutable rc15 release not active')
try:
    plan=json.loads((evid/'plan.json').read_text())
    applies=[json.loads(line) for line in (evid/'apply.stdout').read_text().splitlines() if line.strip()]
    old=json.loads(prior.read_text())
except (OSError,ValueError,TypeError):hold('Original plan/apply/accepted rc14 receipt invalid')
if (len(applies)!=2 or applies[1].get('result')!='applied'
    or applies[1].get('schema_version')!=1
    or applies[0].get('candidate',{}).get('project')!='0.1.0-rc.15'
    or plan.get('current',{}).get('project')!='0.1.0-rc.14'
    or old.get('result')!='CURRENT_WORKER_ROUTE_RECONCILED'):
    hold('Original supported update success receipt inconsistent')
sys.path.insert(0,str(work))
from vaultwarden_oci import update_versions
if not pathlib.Path(update_versions.__file__).resolve().is_relative_to(work):
    hold('Wrong pinned candidate manifest freezer')
expected=update_versions.frozen_versions_toml(
    update_versions.resolve_pinned(work,machine='arm64')
).encode('utf-8')
manifest=release/'versions.toml'
if manifest.is_symlink() or not manifest.is_file() or manifest.read_bytes()!=expected:
    hold('Installed rc15 frozen ARM64 manifest differs from tested candidate')
p=subprocess.run(['git','-c','safe.directory='+str(work),'-C',str(work),
    'ls-files','-z','--','vwctl','versions.toml',
    'email-providers.toml','vaultwarden_oci','systemd'],
    stdin=subprocess.DEVNULL,capture_output=True,timeout=30,check=True)
files=p.stdout.split(b'\x00')
count=0
for raw in files:
    if not raw:continue
    relative=pathlib.Path(os.fsdecode(raw))
    source=work/relative
    installed=release/relative
    if (relative.is_absolute() or '..' in relative.parts or source.is_symlink()
        or not source.is_file() or installed.is_symlink() or not installed.is_file()):
        hold('Immutable rc15 source inventory file missing or unsafe')
    if relative.as_posix()!='versions.toml':
        if hashlib.sha256(source.read_bytes()).digest()!=hashlib.sha256(installed.read_bytes()).digest():
            hold('Installed rc15 release bytes differ from Git candidate')
    count+=1
if count<55:hold('Incomplete installed rc15 release source inventory')
print('PASS: '+str(count)+' immutable rc15 source files and frozen ARM64 manifest match exact CI-green Git candidate')
sys.path.insert(0,str(release))
from vaultwarden_oci import cloudflare_route_mode as cf,crowdsec_worker_policy,edge,storage
identity=storage.verify()
if identity.uuid!='f4e0bd62-48e7-4745-8987-44b14013216d' or identity.fs_type!='ext4':
    hold('Dedicated volume identity changed')
if pathlib.Path('/var/lib/vaultwarden-oci/state/update-recovery-required.json').exists():
    hold('Update recovery-required guard present')
old_inv=old.get('new_invocation')
inv=edge._service_invocation_id(edge.run_command)
paths=edge.EdgePaths()
if (inv!=old_inv or not edge._disabled(edge.BOUNCER_SERVICE,edge.run_command)
    or not crowdsec_worker_policy.runtime_policy_healthy(paths,edge.run_command)
    or not edge._fail_open_confirmed(paths.fail_open_confirmation,inv)):
    hold('rc15 upgrade changed current Worker invocation or local-only proof unexpectedly')
rid=cf.read_owned_route_id(require_fail_open=True)
if rid!=old.get('new_route_id'):hold('Current CrowdSec Route identity changed during upgrade')
cf.wait_owned_route_stable(rid)
try:
    src=sqlite3.connect('file:/var/lib/vaultwarden-oci/data/db.sqlite3?mode=ro',uri=True,timeout=15)
    db=sqlite3.connect(':memory:');src.backup(db,pages=128,sleep=0.1);src.close()
    if db.execute('PRAGMA integrity_check').fetchone()!=('ok',):hold('SQLite integrity failed')
    users=db.execute('SELECT count(*) FROM users').fetchone()[0]
    ciphers=db.execute('SELECT count(*) FROM ciphers').fetchone()[0]
    digest=hashlib.sha256()
    for values in db.execute('SELECT * FROM ciphers ORDER BY uuid'):
        encoded=repr(values).encode('utf-8')
        digest.update(len(encoded).to_bytes(8,'big'));digest.update(encoded)
    db.close()
except (OSError,sqlite3.Error):hold('Post-upgrade vault read-only proof unavailable')
if (users,ciphers,digest.hexdigest())!=(1,1,old.get('original_cipher_sha256')):
    hold('Original vault contents changed during update')
p=subprocess.run(['/usr/local/bin/vwctl','doctor','--json'],
    stdin=subprocess.DEVNULL,capture_output=True,timeout=90,check=False)
try:
    doctor=json.loads(p.stdout)
    checks={x['id']:x['status'] for x in doctor['checks']}
except (ValueError,KeyError,TypeError):hold('Installed doctor JSON invalid')
if (p.returncode!=0 or doctor.get('overall')!='PASS'
    or 'FAIL' in checks.values() or checks.get('crowdsec.cloudflare')!='PASS'):
    hold('Installed rc15 doctor not PASS')
for unit in ('vaultwarden-oci.target','vaultwarden-oci-crowdsec-boot.service'):
    p=subprocess.run(['systemctl','show',unit,'--no-pager',
        '--property=LoadState,UnitFileState'],capture_output=True,
        text=True,timeout=15,check=True)
    values=dict(line.split('=',1) for line in p.stdout.splitlines() if '=' in line)
    if values.get('LoadState')!='loaded' or values.get('UnitFileState')!='disabled':
        hold('Automatic startup enabled before live acceptance')
row={
  'schema_version':1, 'result':'INSTALLED_RC15_UPGRADE_PASS',
  'source_commit':pin, 'installed_release':'0.1.0-rc.15',
  'previous_commit':old['source_commit'], 'verified_release_files':count,
  'frozen_manifest_sha256':hashlib.sha256(expected).hexdigest(),
  'disk_uuid':identity.uuid, 'boot_id':old['boot_id'],
  'worker_invocation':inv, 'worker_route_id':rid,
  'original_cipher_sha256':old['original_cipher_sha256'],
  'doctor':'PASS', 'crowdsec.cloudflare':'PASS',
  'boot_rearm':'disabled', 'reboot':'NOT_RUN',
  'supported_update_receipt':'applied'
}
dest=evid/'accepted.json'
try:
    fd=os.open(dest,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w',encoding='utf-8') as stream:
        json.dump(row,stream,indent=2,sort_keys=True);stream.write('\n')
        stream.flush();os.fsync(stream.fileno())
except OSError:hold('Failed to publish private rc15 upgrade acceptance receipt')
print('PASS: Original vault, Worker invocation and exact Cloudflare Route unchanged')
print('PASS: rc15 installed doctor overall/Cloudflare PASS; boot automation disabled')
print('RC15_A_POST_EXIT=0 IMMUTABLE_RC15_INSTALLED_AND_ACCEPTED')
PY_AFTER
then
  echo 'RC15_A_EXIT=0 INSTALLED_RC15_UPGRADE_PASS'
  echo 'BOOT_REARM=NOT_ENABLED; REBOOT=NOT_RUN; RELEASE_GO=HOLD'
  printf 'PRIVATE_EVIDENCE_DIR=%s\n' "$EVID"
  printf 'CANDIDATE_WORK=%s\n' "$WORK"
else
  hold "Independent post-upgrade proof failed; DO NOT REPLAY updater; private evidence=$EVID"
fi
RC15_A
