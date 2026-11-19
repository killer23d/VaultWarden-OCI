#!/usr/bin/env bash
bash <<'RC15_D_POSTBOOT'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
hold() { printf 'RC15_D_POST_WRAPPER_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'Wrong operator'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'Wrong VM'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
sudo -n true >/dev/null 2>&1 || hold 'Passwordless sudo required'
PIN='32beec5bc905cdecdfdc4a359147c3f1d45d8444'
WORK="$HOME/VaultWarden-OCI-rc15-a-${PIN:0:12}"
EVID="$HOME/vwoci-acceptance/rc15-c-${PIN:0:12}"
DROP='/etc/systemd/system/vaultwarden-oci-dns.service.d/vwoci-rc15-acceptance.conf'
PERMIT='/run/vwoci-rc15-acceptance-dns-permit'
[ -d "$WORK/.git" ] && [ ! -L "$WORK" ] || hold 'Pinned release source checkout missing'
[ "$(git -C "$WORK" rev-parse HEAD)" = "$PIN" ] || hold 'Exact candidate source changed'
[ -z "$(git -C "$WORK" status --porcelain)" ] || hold 'Candidate source checkout dirty'
[ -d "$EVID" ] && [ ! -L "$EVID" ] || hold 'Protected original preboot checkpoint directory missing'
[ "$(stat -c '%u:%a' "$EVID")" = "$(id -u):700" ] || hold 'Evidence custody unsafe'
[ ! -e "$EVID/postboot.json" ] && [ ! -L "$EVID/postboot.json" ] || hold 'Postboot receipt already exists; do not replay'

printf '%s\n' '=== RC15-D genuine reboot: independent current-boot/source/data/Worker/DNS checks ==='
if sudo -n /usr/bin/python3 -B - "$WORK" "$EVID" "$PIN" "$DROP" "$PERMIT" <<'PY_POST'
import datetime, hashlib, ipaddress, json, os, pathlib, pwd, re, sqlite3, stat, subprocess, sys, time, tomllib

WORK, EVID, PIN, DROP, PERMIT = pathlib.Path(sys.argv[1]).resolve(strict=True), pathlib.Path(sys.argv[2]), sys.argv[3], pathlib.Path(sys.argv[4]), pathlib.Path(sys.argv[5])
RELEASE=pathlib.Path('/opt/vaultwarden-oci/releases/0.1.0-rc.15')
DB=pathlib.Path('/var/lib/vaultwarden-oci/data/db.sqlite3')
UUID='f4e0bd62-48e7-4745-8987-44b14013216d'
TIMERS=('vaultwarden-oci-health.timer','vaultwarden-oci-backup.timer','vaultwarden-oci-maintenance.timer','vaultwarden-oci-update-check.timer')

def hold(message):
    print('RC15_D_POST_EXIT=2 HOLD: '+message,flush=True)
    raise SystemExit(2)

def command(args, allowed=(0,), timeout=60):
    try:
        p=subprocess.run(args,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=timeout,check=False)
    except (OSError,subprocess.TimeoutExpired):
        hold('Read-only command unavailable: '+args[0])
    if p.returncode not in allowed or len(p.stdout)>262144:
        hold('Unexpected read-only status or oversized output: '+args[0])
    return p.returncode,p.stdout

def unit(name):
    _,output=command(['systemctl','show',name,'--no-pager','--property=LoadState,ActiveState,SubState,Result,UnitFileState,MainPID,NRestarts,Restart,InvocationID,ExecMainStatus,ExecMainStartTimestampMonotonic,DropInPaths'],timeout=20)
    return dict(s.split('=',1) for s in output.splitlines() if '=' in s)

def protected(file):
    try:
        s=file.lstat()
        if not stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode) or s.st_uid!=0 or stat.S_IMODE(s.st_mode)!=0o600:
            hold('Private checkpoint custody mismatch')
        value=json.loads(file.read_text(encoding='utf-8'))
        if not isinstance(value,dict):hold('Private checkpoint not an object')
        return value
    except (OSError,ValueError,UnicodeError):hold('Private checkpoint missing or invalid')

operator=pwd.getpwnam('ubuntu')
if (os.geteuid()!=0 or os.environ.get('SUDO_USER')!='ubuntu' or os.environ.get('SUDO_UID')!=str(operator.pw_uid)
        or WORK!=pathlib.Path('/home/ubuntu/VaultWarden-OCI-rc15-a-32beec5bc905')
        or EVID!=pathlib.Path('/home/ubuntu/vwoci-acceptance/rc15-c-32beec5bc905')
        or PIN!='32beec5bc905cdecdfdc4a359147c3f1d45d8444'):
    hold('Operator/source/evidence identity mismatch')
if pathlib.Path('/opt/vaultwarden-oci/current').resolve()!=RELEASE:
    hold('Selected immutable release is not rc15')
pre=protected(EVID/'preboot.json')
try:
    new_boot=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
except OSError:hold('Kernel boot identity missing')
if (pre.get('result')!='PREBOOT_ARMED' or pre.get('source_commit')!=PIN or pre.get('disk_uuid')!=UUID
        or pre.get('boot_id')==new_boot or not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}',new_boot)):
    hold('Genuine reboot and protected identity comparison did not pass')
print('PASS: genuine new kernel boot ID differs from protected preboot checkpoint')

# Verbatim exact release source comparison with the pinned accepted tree,
# apart from versions.toml where the frozen updater is allowed to reorder keys.
_,tracked=command(['git','-C',str(WORK),'ls-files','--','vwctl','versions.toml','email-providers.toml','vaultwarden_oci','systemd'])
files=[pathlib.Path(s) for s in tracked.splitlines() if s]
if len(files)<50:hold('Incomplete immutable source inventory')
for relative in files:
    source,installed=WORK/relative,RELEASE/relative
    if not source.is_file() or not installed.is_file() or installed.is_symlink():hold('Installed candidate blob missing')
    if str(relative)=='versions.toml':
        if tomllib.loads(source.read_text())!=tomllib.loads(installed.read_text()):hold('Frozen version manifest differs')
    elif hashlib.sha256(source.read_bytes()).digest()!=hashlib.sha256(installed.read_bytes()).digest():
        hold('Installed immutable release blob differs from acceptance source')
print('PASS: selected rc15 immutable release matches '+str(len(files))+' candidate blobs')

sys.path.insert(0,str(RELEASE))
from vaultwarden_oci import cloudflare_route_mode as route, crowdsec_worker_policy, edge, storage, runtime
identity=storage.verify()
if identity.uuid!=UUID or identity.fs_type!='ext4':hold('Dedicated ext4 UUID changed/root fallback suspected')
try:
    if not DB.is_file() or DB.is_symlink():hold('Original SQLite path missing/unsafe')
    src=sqlite3.connect('file:'+str(DB)+'?mode=ro',uri=True,timeout=15)
    mem=sqlite3.connect(':memory:');src.backup(mem,pages=128,sleep=0.1);src.close()
    if mem.execute('PRAGMA integrity_check').fetchone()!=('ok',):hold('Restored SQLite integrity failed')
    users=mem.execute('SELECT COUNT(*) FROM users').fetchone()[0]
    count=mem.execute('SELECT COUNT(*) FROM ciphers').fetchone()[0]
    digest=hashlib.sha256()
    for row in mem.execute('SELECT * FROM ciphers ORDER BY uuid'):
        raw=repr(row).encode();digest.update(len(raw).to_bytes(8,'big'));digest.update(raw)
    mem.close()
except (sqlite3.Error,OSError):hold('Read-only SQLite snapshot failed')
if (users,count,digest.hexdigest())!=(1,1,pre.get('original_cipher_sha256')):hold('Original 1 user/1 cipher or fingerprint changed')
print('PASS: original SQLite 1 user/1 cipher unchanged after reboot; independent integrity OK')

try:
    meta=DROP.lstat()
    if not stat.S_ISREG(meta.st_mode) or stat.S_ISLNK(meta.st_mode) or meta.st_uid!=0 or stat.S_IMODE(meta.st_mode)!=0o644:
        hold('DNS isolation override custody invalid')
    expected='[Unit]\nConditionPathExists='+str(PERMIT)+'\n'
    if DROP.read_text()!=expected or hashlib.sha256(DROP.read_bytes()).hexdigest()!=pre.get('dns_isolation_sha256'):
        hold('DNS isolation override changed during reboot')
except OSError:hold('DNS isolation override missing')
if PERMIT.exists() or PERMIT.is_symlink():hold('DNS-writing allow marker unexpectedly exists')
dns=unit('vaultwarden-oci-dns.service')
if dns.get('LoadState')!='loaded' or str(DROP) not in dns.get('DropInPaths','') or dns.get('ActiveState') not in ('inactive','failed'):
    hold('DNS isolation unit not safely loaded')
if dns.get('ExecMainStartTimestampMonotonic') not in ('0',''):
    hold('Cloudflare DNS writing service actually executed after boot')
print('PASS: tested health timer cannot execute Cloudflare DNS writer; no permit marker')

# Poll only current systemd metadata for bounded boot stabilization.
for attempt in range(18):
    target=unit('vaultwarden-oci.target')
    app=unit('vaultwarden-oci.service')
    bootunit=unit('vaultwarden-oci-crowdsec-boot.service')
    timers={name:unit(name) for name in TIMERS}
    if (target.get('ActiveState')=='active' and app.get('ActiveState')=='active'
            and all(t.get('ActiveState')=='active' for t in timers.values())
            and bootunit.get('ActiveState')!='activating'):
        break
    if attempt!=17:time.sleep(4)
if (target.get('LoadState'),target.get('ActiveState'),target.get('UnitFileState'))!=('loaded','active','enabled'):
    hold('Production-style appliance target not enabled/active after boot')
if (app.get('LoadState'),app.get('ActiveState'),app.get('Result'))!=('loaded','active','success'):
    hold('Caddy/Vaultwarden lifecycle unit not active/successful after boot')
if app.get('ExecMainStartTimestampMonotonic') in ('0',''):
    hold('Application systemd lifecycle did not genuinely execute in this boot')
for name,t in timers.items():
    if t.get('LoadState')!='loaded' or t.get('ActiveState')!='active' or t.get('Result') not in ('success',''):
        hold('Required scheduled timer not active/healthy: '+name)
if (bootunit.get('LoadState')!='loaded' or bootunit.get('UnitFileState')!='enabled'
        or bootunit.get('ActiveState')!='inactive' or bootunit.get('Result')!='success'
        or bootunit.get('ExecMainStatus')!='0'
        or bootunit.get('ExecMainStartTimestampMonotonic') in ('0','')):
    hold('Opt-in CrowdSec boot one-shot did not execute successfully after reboot')
print('PASS: enabled production-style target/application and all four timers active on genuine reboot')
print('PASS: opt-in CrowdSec boot one-shot ran and exited successfully, worker package remains boot-disabled')

worker=unit(edge.BOUNCER_SERVICE)
inv=edge._service_invocation_id(edge.run_command)
if (worker.get('LoadState'),worker.get('ActiveState'),worker.get('SubState'),worker.get('UnitFileState'),worker.get('Restart'))!=('loaded','active','running','disabled','no'):
    hold('CrowdSec package Worker boot policy or runtime differs')
if not inv or inv==pre.get('old_worker_invocation') or worker.get('InvocationID')!=inv:
    hold('Expected new postboot Worker invocation missing')
if not crowdsec_worker_policy.runtime_policy_healthy(edge.EdgePaths(),edge.run_command):
    hold('Boot Worker local-only decision-policy attestation invalid')
proof=protected(edge.FAIL_OPEN_CONFIRMATION)
if proof.get('schema_version')!=1 or proof.get('verification')!='cloudflare-api-readback' or proof.get('invocation_id')!=inv:
    hold('Boot Worker API confirmation not bound to new invocation')
routeid=route.read_owned_route_id(require_fail_open=True)
if routeid==pre.get('old_worker_route_id') or proof.get('route',{}).get('id')!=routeid:
    hold('New unique boot Route ID missing or not bound to API proof')
route.wait_owned_route_stable(routeid)
if not edge._fail_open_confirmed(edge.FAIL_OPEN_CONFIRMATION,inv):
    hold('Installed doctor Worker confirmation validation failed')
print('PASS: new Worker invocation, fresh unique Cloudflare Route, Fail Open=true in two independent GET/list samples')

for name in ('vaultwarden-oci-caddy','vaultwarden-oci-vaultwarden'):
    _,response=command(['docker','container','inspect',name],timeout=45)
    try:
        c=json.loads(response)[0]
        state=c['State']
        if (state.get('Status')!='running' or state.get('Paused') is not False
                or state.get('Health',{}).get('Status')!='healthy'):
            hold('Runtime container not healthy after target startup: '+name)
        if name.endswith('caddy'):
            addresses=[n.get('IPAddress') for n in c['NetworkSettings']['Networks'].values()]
            private=[ip for ip in addresses if ip and ipaddress.ip_address(ip).version==4 and ipaddress.ip_address(ip).is_private]
            if not private:hold('No internal IPv4 Caddy HTTPS origin found')
            origin=private[0]
    except (KeyError,TypeError,IndexError,ValueError):hold('Container inspection incomplete: '+name)
from urllib.parse import quote
from subprocess import run
for endpoint,expected in (('/', '200'),('/api/config','200'),('/admin/','401')):
    _,status=command(['curl','--noproxy','*','--ipv4','--silent','--show-error','--output','/dev/null',
                      '--write-out','%{http_code}','--connect-timeout','8','--max-time','20',
                      '--resolve','bw.lazymocha.com:443:'+origin,'https://bw.lazymocha.com'+endpoint],timeout=25)
    if status.strip()!=expected:hold('Private TLS expected HTTP '+expected+' for '+endpoint+' but did not match')
print('PASS: private TLS Web/API/Admin (unauth) statuses 200/200/401 after target-owned startup')

_,doctor_text=command(['/usr/local/bin/vwctl','doctor','--json'],timeout=100)
try:
    doctor=json.loads(doctor_text);checks={x['id']:x['status'] for x in doctor['checks']}
except (ValueError,TypeError,KeyError):hold('Installed doctor JSON invalid')
if doctor.get('overall')!='PASS' or 'FAIL' in checks.values() or checks.get('crowdsec.cloudflare')!='PASS':
    hold('Installed rc15 doctor not fully PASS after reboot')
print('PASS: installed rc15 full doctor PASS, CrowdSec Cloudflare PASS')

receipt={'source_commit':PIN,'preboot_boot_id':pre['boot_id'],'new_boot_id':new_boot,
         'disk_uuid':UUID,'original_cipher_sha256':digest.hexdigest(),'new_worker_invocation':inv,
         'new_worker_route_id':routeid,'dns_isolation_sha256':pre['dns_isolation_sha256'],
         'crowdsec_boot_unit':'enabled/oneshot-success','target':'enabled/active',
         'timers':'all-four-active','full_doctor':'PASS','phase':'POSTBOOT_PASS',
         'utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
try:
    fd=os.open(EVID/'postboot.json',os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w',encoding='utf-8') as out:
        json.dump(receipt,out,sort_keys=True,indent=2);out.write('\n');out.flush();os.fsync(out.fileno())
except OSError:hold('Unable to durably record protected postboot acceptance receipt')
print('RC15_D_POST_EXIT=0 GENUINE_REBOOT_AND_WORKER_AUTO_FAIL_OPEN_PASS; PRODUCTION_TARGET_TIMERS_ACTIVE; SCHEDULE_JOBS_NOT_YET_RUN; RELEASE_GO=HOLD')
PY_POST
then
  echo 'RC15_D_POST_WRAPPER_EXIT=0'
  printf 'PRIVATE_EVIDENCE_DIR=%s\n' "$EVID"
else
  rc=$?; printf 'RC15_D_POST_WRAPPER_EXIT=2 HOLD: postboot rc=%s; NO REARM/REBOOT/RETRY\n' "$rc" >&2; exit 2
fi
RC15_D_POSTBOOT
