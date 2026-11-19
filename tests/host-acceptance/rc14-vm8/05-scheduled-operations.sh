#!/usr/bin/env bash
bash <<'RC14_F_SCHEDULED'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
hold() { printf 'RC14_F_WRAPPER_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'Wrong operator'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'Wrong VM'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
sudo -n true >/dev/null 2>&1 || hold 'Passwordless sudo required'
PIN='92b9300f96125d19105cc1d4865024cb49612b28'
WORK="$HOME/VaultWarden-OCI-rc14-c-${PIN:0:12}"
EVID="$HOME/vwoci-acceptance/rc14-e-${PIN:0:12}"
[ -d "$WORK/.git" ] && [ ! -L "$WORK" ] || hold 'Pinned candidate source missing'
[ "$(git -C "$WORK" rev-parse HEAD)" = "$PIN" ] || hold 'Candidate SHA changed'
[ -d "$EVID" ] && [ ! -L "$EVID" ] || hold 'Protected postboot evidence directory missing'
[ "$(stat -c '%u:%a' "$EVID")" = "$(id -u):700" ] || hold 'Evidence ownership/mode mismatch'
[ ! -e "$EVID/schedule-attempted.json" ] && [ ! -L "$EVID/schedule-attempted.json" ] || hold 'Scheduled operation sequence already attempted; do not replay'

printf '%s\n' '=== RC14-F preflight verified postboot receipt, local-only policy and DNS isolation ==='
if sudo -n /usr/bin/python3 -B - "$EVID" "$PIN" <<'PY_PRE'
import datetime,json,os,pathlib,stat,subprocess,sys
EVID=pathlib.Path(sys.argv[1]);PIN=sys.argv[2]
RELEASE=pathlib.Path('/opt/vaultwarden-oci/releases/0.1.0-rc.14')
DNS_DROP=pathlib.Path('/etc/systemd/system/vaultwarden-oci-dns.service.d/vwoci-rc14-acceptance.conf')
PERMIT=pathlib.Path('/run/vwoci-rc14-acceptance-dns-permit')
BACKUPS=pathlib.Path('/var/lib/vaultwarden-oci/backups')

def hold(m):print('RC14_F_PRE_EXIT=2 HOLD: '+m,flush=True);raise SystemExit(2)
def protected(path):
    try:
        s=path.lstat()
        if not stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode) or s.st_uid!=0 or stat.S_IMODE(s.st_mode)!=0o600:
            hold('Private receipt custody invalid')
        return json.loads(path.read_text())
    except (OSError,ValueError,UnicodeError):hold('Private receipt missing or invalid')
pre=protected(EVID/'preboot.json');post=protected(EVID/'postboot.json')
if (pre.get('source_commit')!=PIN or post.get('source_commit')!=PIN
        or post.get('phase')!='POSTBOOT_PASS'
        or post.get('preboot_boot_id')!=pre.get('boot_id')
        or pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()!=post.get('new_boot_id')
        or pathlib.Path('/opt/vaultwarden-oci/current').resolve()!=RELEASE):
    hold('Accepted rc14 reboot evidence invalid or host changed')
if PERMIT.exists() or PERMIT.is_symlink():hold('Public DNS writer allow marker unexpectedly exists')
if (not DNS_DROP.is_file() or DNS_DROP.is_symlink()
        or DNS_DROP.read_text()!='[Unit]\nConditionPathExists='+str(PERMIT)+'\n'):
    hold('Reversible Cloudflare DNS writer isolation not intact')
sys.path.insert(0,str(RELEASE))
from vaultwarden_oci import runtime,storage
cfg=runtime.load_config()
if cfg.offsite_remote is not None or cfg.local_retention_days!=0 or cfg.remote_retention_days!=0:
    hold('Backup is not local-only with zero retention')
if storage.verify().uuid!='f4e0bd62-48e7-4745-8987-44b14013216d':hold('Dedicated disk identity mismatch')
if not BACKUPS.is_dir() or BACKUPS.is_symlink():hold('Local encrypted-backup directory missing')
before={p.name for p in BACKUPS.iterdir() if p.is_file() and not p.is_symlink() and p.name.endswith('.vwrec')}
record={'source_commit':PIN,'boot_id':post['new_boot_id'],'initial_backups':sorted(before),
        'dns_isolation_sha256':pre['dns_isolation_sha256'],'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'state':'SEQUENCE_STARTED'}
path=EVID/'schedule-attempted.json'
try:
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as stream:
        json.dump(record,stream,indent=2,sort_keys=True);stream.write('\n');stream.flush();os.fsync(stream.fileno())
except OSError:hold('Could not record private one-shot schedule attempt')
print('PASS: installed rc14, protected genuine boot, dedicated disk and local-only zero-pruning backup')
print('PASS: Cloudflare DNS publication stays blocked by systemd condition')
print('RC14_F_PRE_EXIT=0 READ_ONLY_PREFLIGHT_PASS; SCHEDULE_JOBS_NOT_YET_RUN')
PY_PRE
then :; else hold 'Scheduled operations preflight failed; no jobs triggered'; fi

printf '%s\n' '=== RC14-F trigger production local health oneshot (Cloudflare DNS condition will skip) ==='
if sudo -n systemctl start vaultwarden-oci-health.service >"$EVID/health.stdout" 2>"$EVID/health.stderr"; then
  echo 'PASS: local health service completed'
else
  hold "Health service failed; no other scheduled test job; evidence $EVID"
fi
if sudo -n /usr/bin/python3 -B - <<'PY_DNS'
import pathlib,subprocess
permit=pathlib.Path('/run/vwoci-rc14-acceptance-dns-permit')
if permit.exists() or permit.is_symlink():raise SystemExit('HOLD: DNS allow marker present after health')
p=subprocess.run(['systemctl','show','vaultwarden-oci-dns.service','--property=LoadState,ExecMainStartTimestampMonotonic,DropInPaths','--no-pager'],capture_output=True,text=True,check=True)
d=dict(x.split('=',1) for x in p.stdout.splitlines() if '=' in x)
if (d.get('LoadState')!='loaded' or d.get('ExecMainStartTimestampMonotonic') not in ('0','')
        or '/etc/systemd/system/vaultwarden-oci-dns.service.d/vwoci-rc14-acceptance.conf' not in d.get('DropInPaths','')):
    raise SystemExit('HOLD: DNS writer executed or condition lost')
print('PASS: health job did not execute DNS writer')
PY_DNS
then :; else hold 'Cloudflare DNS publication boundary changed; no other jobs'; fi

printf '%s\n' '=== RC14-F trigger production encrypted local-only recovery backup service ==='
if sudo -n systemctl start vaultwarden-oci-backup.service >"$EVID/backup.stdout" 2>"$EVID/backup.stderr"; then
  echo 'PASS: systemd encrypted recovery backup completed'
else
  hold "Backup job failed; no retry, no subsequent jobs; evidence $EVID"
fi

printf '%s\n' '=== RC14-F trigger production maintenance (Cloudflare CIDR refresh and doctor, NOT DNS) ==='
if sudo -n systemctl start vaultwarden-oci-maintenance.service >"$EVID/maintenance.stdout" 2>"$EVID/maintenance.stderr"; then
  echo 'PASS: maintenance refresh and doctor succeeded'
else
  hold "Maintenance job failed; no retry; evidence $EVID"
fi

printf '%s\n' '=== RC14-F trigger scheduled update availability (check only; NO apply) ==='
if sudo -n systemctl start vaultwarden-oci-update-check.service >"$EVID/update-check.stdout" 2>"$EVID/update-check.stderr"; then
  echo 'PASS: unattended update availability check completed without apply'
else
  hold "Update availability check failed; do not retry; evidence $EVID"
fi

printf '%s\n' '=== RC14-F independent scheduled-service, CF, database and backup witness ==='
if sudo -n /usr/bin/python3 -B - "$EVID" "$PIN" <<'PY_POST'
import datetime,hashlib,json,os,pathlib,sqlite3,stat,subprocess,sys
EVID=pathlib.Path(sys.argv[1]);PIN=sys.argv[2]
RELEASE=pathlib.Path('/opt/vaultwarden-oci/releases/0.1.0-rc.14')
PERMIT=pathlib.Path('/run/vwoci-rc14-acceptance-dns-permit')
BACKUPS=pathlib.Path('/var/lib/vaultwarden-oci/backups')
SERVICES=('vaultwarden-oci-health.service','vaultwarden-oci-backup.service',
          'vaultwarden-oci-maintenance.service','vaultwarden-oci-update-check.service')
TIMERS=('vaultwarden-oci-health.timer','vaultwarden-oci-backup.timer',
        'vaultwarden-oci-maintenance.timer','vaultwarden-oci-update-check.timer')

def hold(msg):print('RC14_F_POST_EXIT=2 HOLD: '+msg,flush=True);raise SystemExit(2)
def read(path):
    try:
        s=path.lstat()
        if not stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode) or s.st_uid!=0 or stat.S_IMODE(s.st_mode)!=0o600:hold('Protected prior evidence unsafe')
        return json.loads(path.read_text())
    except (OSError,ValueError,UnicodeError):hold('Protected prior evidence invalid')
def command(args,allowed=(0,),timeout=90):
    try:
        p=subprocess.run(args,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=timeout,check=False)
    except (OSError,subprocess.TimeoutExpired):hold('Read-only command unavailable')
    if p.returncode not in allowed or len(p.stdout)>200000:hold('Unexpected read-only command result')
    return p.stdout
def unit(name):
    o=command(['systemctl','show',name,'--no-pager','--property=LoadState,ActiveState,Result,ExecMainStartTimestampMonotonic,ExecMainStatus,DropInPaths'],timeout=20)
    return dict(x.split('=',1) for x in o.splitlines() if '=' in x)
pre=read(EVID/'preboot.json');post=read(EVID/'postboot.json');attempt=read(EVID/'schedule-attempted.json')
if (post.get('source_commit')!=PIN or attempt.get('source_commit')!=PIN
        or attempt.get('boot_id')!=post.get('new_boot_id')
        or pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()!=post.get('new_boot_id')
        or pathlib.Path('/opt/vaultwarden-oci/current').resolve()!=RELEASE):
    hold('Postboot checkpoint or release changed while scheduled tasks ran')
if PERMIT.exists() or PERMIT.is_symlink():hold('DNS allow marker unexpectedly exists')
dns=unit('vaultwarden-oci-dns.service')
if (dns.get('LoadState')!='loaded' or dns.get('ExecMainStartTimestampMonotonic') not in ('0','')
        or '/etc/systemd/system/vaultwarden-oci-dns.service.d/vwoci-rc14-acceptance.conf' not in dns.get('DropInPaths','')):
    hold('Public Cloudflare DNS service executed or isolation lost')
for name in SERVICES:
    p=unit(name)
    if (p.get('LoadState')!='loaded' or p.get('Result')!='success'
            or p.get('ExecMainStatus')!='0' or p.get('ExecMainStartTimestampMonotonic') in ('0','')):
        hold('Scheduled job not successfully executed: '+name)
for name in TIMERS:
    p=unit(name)
    if p.get('LoadState')!='loaded' or p.get('ActiveState')!='active':
        hold('Scheduled timer inactive after manual trigger: '+name)
print('PASS: all four actual production scheduled service units executed; all timers remain active')
print('PASS: Cloudflare DNS writer never executed; reversible test condition intact')

try:
    initial=set(attempt['initial_backups'])
    current={p.name for p in BACKUPS.iterdir() if p.is_file() and not p.is_symlink() and p.name.endswith('.vwrec')}
    created=sorted(current-initial)
    if not created:hold('Backup job did not create a new encrypted .vwrec archive')
    sizes={name:(BACKUPS/name).stat().st_size for name in created}
    if any(size<=0 for size in sizes.values()):hold('Scheduled encrypted backup file empty')
except (OSError,TypeError,ValueError,KeyError):hold('Encrypted backup inventory failed')
print('PASS: newly created encrypted local .vwrec archive(s) present; no remote publication or pruning configured')
sys.path.insert(0,str(RELEASE))
from vaultwarden_oci import cloudflare_route_mode as route, edge, crowdsec_worker_policy, runtime, storage
cfg=runtime.load_config()
if cfg.offsite_remote is not None or cfg.local_retention_days!=0 or cfg.remote_retention_days!=0:hold('Backup destination/retention unexpectedly changed')
if storage.verify().uuid!='f4e0bd62-48e7-4745-8987-44b14013216d':hold('Dedicated data UUID changed')
inv=edge._service_invocation_id(edge.run_command)
if inv!=post.get('new_worker_invocation') or not crowdsec_worker_policy.runtime_policy_healthy(edge.EdgePaths(),edge.run_command):
    hold('Current boot Worker source attestation/invocation drifted')
routeid=route.read_owned_route_id(require_fail_open=True)
if routeid!=post.get('new_worker_route_id') or not edge._fail_open_confirmed(edge.FAIL_OPEN_CONFIRMATION,inv):hold('Cloudflare Route receipt drifted')
route.wait_owned_route_stable(routeid)
try:
    src=sqlite3.connect('file:/var/lib/vaultwarden-oci/data/db.sqlite3?mode=ro',uri=True,timeout=15)
    mem=sqlite3.connect(':memory:');src.backup(mem,pages=128,sleep=0.1);src.close()
    if mem.execute('PRAGMA integrity_check').fetchone()!=('ok',):hold('SQLite corruption')
    count=mem.execute('SELECT count(*) FROM ciphers').fetchone()[0]
    users=mem.execute('SELECT count(*) FROM users').fetchone()[0]
    h=hashlib.sha256()
    for row in mem.execute('SELECT * FROM ciphers ORDER BY uuid'):
        raw=repr(row).encode();h.update(len(raw).to_bytes(8,'big'));h.update(raw)
    mem.close()
except (OSError,sqlite3.Error):hold('Original SQLite inspection failed')
if (users,count,h.hexdigest())!=(1,1,post['original_cipher_sha256']):hold('Scheduled operations changed original 1 user/1 cipher')
status=json.loads(command(['/usr/local/bin/vwctl','doctor','--json'],timeout=90))
checks={x['id']:x['status'] for x in status['checks']}
if status.get('overall')!='PASS' or 'FAIL' in checks.values() or checks.get('crowdsec.cloudflare')!='PASS':hold('Doctor not PASS after scheduled jobs')
record={'phase':'SCHEDULE_PASS','source_commit':PIN,'boot_id':post['new_boot_id'],
        'jobs':list(SERVICES),'new_backup_names':created,'new_backup_sizes':sizes,
        'cloudflare_worker_invocation':inv,'cloudflare_route_id':routeid,
        'database_cipher_sha256':h.hexdigest(),'doctor':'PASS','dns_writer':'CONDITION_SKIPPED',
        'utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
try:
    fd=os.open(EVID/'schedule.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w',encoding='utf-8') as out:
        json.dump(record,out,indent=2,sort_keys=True);out.write('\n');out.flush();os.fsync(out.fileno())
except OSError:hold('Private scheduled acceptance receipt could not be committed')
print('PASS: data, new encrypted backup, confirmed Cloudflare Route and full doctor are healthy')
print('RC14_F_POST_EXIT=0 PRODUCTION_SCHEDULED_OPERATIONS_PASS; DNS_PUBLICATION_NOT_RUN; RELEASE_GO=HOLD')
PY_POST
then
  echo 'RC14_F_WRAPPER_EXIT=0'
  printf 'PRIVATE_EVIDENCE_DIR=%s\n' "$EVID"
else
  rc=$?; printf 'RC14_F_WRAPPER_EXIT=2 HOLD: scheduled reconciliation rc=%s; no retry\n' "$rc" >&2; exit 2
fi
RC14_F_SCHEDULED
