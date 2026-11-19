#!/usr/bin/env bash
bash <<'RC15_F_CLEANUP'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
hold() { printf 'RC15_F_WRAPPER_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'Wrong operator'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'Wrong VM'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
sudo -n true >/dev/null 2>&1 || hold 'Passwordless sudo required'
PIN='32beec5bc905cdecdfdc4a359147c3f1d45d8444'
EVID="$HOME/vwoci-acceptance/rc15-c-${PIN:0:12}"
[ -d "$EVID" ] && [ ! -L "$EVID" ] || hold 'Protected acceptance directory missing'
[ "$(stat -c '%u:%a' "$EVID")" = "$(id -u):700" ] || hold 'Evidence ownership/mode mismatch'
[ ! -e "$EVID/cleanup-attempted.json" ] && [ ! -L "$EVID/cleanup-attempted.json" ] || hold 'Cleanup already attempted; do not replay'

printf '%s\n' '=== RC15-F verify completed scheduled acceptance and exact reversible DNS override ==='
if sudo -n /usr/bin/python3 -B - "$EVID" "$PIN" <<'PY_PRE'
import datetime,hashlib,json,os,pathlib,stat,subprocess,sys
EVID=pathlib.Path(sys.argv[1]);PIN=sys.argv[2]
DROP=pathlib.Path('/etc/systemd/system/vaultwarden-oci-dns.service.d/vwoci-rc15-acceptance.conf')
PERMIT=pathlib.Path('/run/vwoci-rc15-acceptance-dns-permit')

def hold(s):print('RC15_F_PRE_EXIT=2 HOLD: '+s,flush=True);raise SystemExit(2)
def protected(name):
    path=EVID/name
    try:
        st=path.lstat()
        if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_uid!=0 or stat.S_IMODE(st.st_mode)!=0o600:
            hold('Prior receipt custody invalid')
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError,ValueError,UnicodeError):hold('Prior acceptance receipt missing')
pre=protected('preboot.json');post=protected('postboot.json');done=protected('schedule.json')
if (pre.get('source_commit')!=PIN or post.get('source_commit')!=PIN or done.get('source_commit')!=PIN
        or post.get('phase')!='POSTBOOT_PASS' or done.get('phase')!='SCHEDULE_PASS'
        or pre.get('boot_id')!=post.get('preboot_boot_id')
        or post.get('new_boot_id')!=done.get('boot_id')
        or pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()!=post.get('new_boot_id')
        or pathlib.Path('/opt/vaultwarden-oci/current').resolve()!=pathlib.Path('/opt/vaultwarden-oci/releases/0.1.0-rc.15')):
    hold('Original postboot/scheduled acceptance is not complete on this boot')
if PERMIT.exists() or PERMIT.is_symlink():hold('DNS-writing permit marker unexpectedly present')
try:
    st=DROP.lstat()
    expected='[Unit]\nConditionPathExists='+str(PERMIT)+'\n'
    if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_uid!=0 or stat.S_IMODE(st.st_mode)!=0o644
            or DROP.read_text()!=expected or hashlib.sha256(DROP.read_bytes()).hexdigest()!=pre.get('dns_isolation_sha256')):
        hold('DNS isolation override changed or unsafe')
except OSError:hold('Expected owned DNS isolation missing')
record={'source_commit':PIN,'boot_id':post['new_boot_id'],'dns_isolation_sha256':pre['dns_isolation_sha256'],
        'started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'phase':'CLEANUP_ATTEMPTED'}
try:
    fd=os.open(EVID/'cleanup-attempted.json',os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w',encoding='utf-8') as out:
        json.dump(record,out,indent=2,sort_keys=True);out.write('\n');out.flush();os.fsync(out.fileno())
except OSError:hold('Could not write protected cleanup attempt')
print('PASS: accepted scheduled and postboot phases match; owned DNS isolation protected')
print('RC15_F_PRE_EXIT=0 READY_TO_DISABLE_AUTOMATION_FIRST')
PY_PRE
then :; else hold 'Cleanup preflight failed; DNS isolation remains'; fi

printf '%s\n' '=== RC15-F disable production-style target and every timer BEFORE removing DNS isolation ==='
sudo -n systemctl disable --now vaultwarden-oci.target || hold 'Could not disable appliance target; retain DNS condition'
for timer in vaultwarden-oci-health.timer vaultwarden-oci-backup.timer vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer; do
  sudo -n systemctl disable --now "$timer" || hold "Could not disable $timer; retain DNS condition"
done
sudo -n systemctl disable vaultwarden-oci-crowdsec-boot.service || hold 'Could not disable optional Worker boot rearm; retain DNS condition'

if sudo -n /usr/bin/python3 -B - <<'PY_SAFETY'
import subprocess
units=('vaultwarden-oci.target','vaultwarden-oci-health.timer','vaultwarden-oci-backup.timer',
       'vaultwarden-oci-maintenance.timer','vaultwarden-oci-update-check.timer')
for name in units:
    p=subprocess.run(['systemctl','show',name,'--no-pager','--property=LoadState,ActiveState,UnitFileState'],capture_output=True,text=True,check=True)
    row=dict(x.split('=',1) for x in p.stdout.splitlines() if '=' in x)
    if (row.get('LoadState'),row.get('ActiveState'),row.get('UnitFileState'))!=('loaded','inactive','disabled'):
        raise SystemExit('HOLD: automation unit remains active/enabled: '+name)
p=subprocess.run(['systemctl','show','vaultwarden-oci-crowdsec-boot.service','--no-pager','--property=UnitFileState'],capture_output=True,text=True,check=True)
if 'UnitFileState=disabled' not in p.stdout:raise SystemExit('HOLD: opt-in CrowdSec boot unit not disabled')
print('PASS: appliance target and all four timers disabled and inactive; Worker auto-rearm disabled')
PY_SAFETY
then :; else hold 'Automation still potentially active; retain DNS condition'; fi

printf '%s\n' '=== RC15-F remove only exact owned DNS test-only override ==='
if sudo -n /usr/bin/python3 -B - "$EVID" <<'PY_REMOVE'
import hashlib,json,os,pathlib,stat,sys
EVID=pathlib.Path(sys.argv[1]);DROP=pathlib.Path('/etc/systemd/system/vaultwarden-oci-dns.service.d/vwoci-rc15-acceptance.conf')
PERMIT=pathlib.Path('/run/vwoci-rc15-acceptance-dns-permit')
pre=json.loads((EVID/'preboot.json').read_text())
if PERMIT.exists() or PERMIT.is_symlink():raise SystemExit('HOLD: DNS writer marker exists')
st=DROP.lstat()
expected='[Unit]\nConditionPathExists='+str(PERMIT)+'\n'
if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_uid!=0
        or stat.S_IMODE(st.st_mode)!=0o644 or DROP.read_text()!=expected
        or hashlib.sha256(DROP.read_bytes()).hexdigest()!=pre['dns_isolation_sha256']):
    raise SystemExit('HOLD: DNS override changed since acceptance')
DROP.unlink()
print('PASS: removed only accepted DNS test-only condition, after all timers stopped')
PY_REMOVE
then :; else hold 'Cannot safely remove DNS override'; fi
sudo -n systemctl daemon-reload || hold 'Systemd reload failed after override removal'

printf '%s\n' '=== RC15-F verify safe idle target/timers, installed rc15 and existing application/Worker ==='
if sudo -n /usr/bin/python3 -B - "$EVID" "$PIN" <<'PY_FINAL'
import datetime,hashlib,json,os,pathlib,sqlite3,subprocess,sys
EVID=pathlib.Path(sys.argv[1]);PIN=sys.argv[2]
DROP=pathlib.Path('/etc/systemd/system/vaultwarden-oci-dns.service.d/vwoci-rc15-acceptance.conf')
PERMIT=pathlib.Path('/run/vwoci-rc15-acceptance-dns-permit')

def hold(s):print('RC15_F_POST_EXIT=2 HOLD: '+s,flush=True);raise SystemExit(2)
if DROP.exists() or DROP.is_symlink() or PERMIT.exists() or PERMIT.is_symlink():hold('Test-only DNS artifacts remain')
for name in ('vaultwarden-oci.target','vaultwarden-oci-health.timer','vaultwarden-oci-backup.timer',
             'vaultwarden-oci-maintenance.timer','vaultwarden-oci-update-check.timer'):
    p=subprocess.run(['systemctl','show',name,'--no-pager','--property=LoadState,ActiveState,UnitFileState'],capture_output=True,text=True,check=True)
    row=dict(x.split('=',1) for x in p.stdout.splitlines() if '=' in x)
    if (row.get('LoadState'),row.get('ActiveState'),row.get('UnitFileState'))!=('loaded','inactive','disabled'):
        hold('Appliance target or scheduled timer not safely disabled: '+name)
p=subprocess.run(['systemctl','show','vaultwarden-oci-crowdsec-boot.service','--no-pager','--property=UnitFileState'],capture_output=True,text=True,check=True)
if 'UnitFileState=disabled' not in p.stdout:hold('Optional Worker boot unit still enabled')
release=pathlib.Path('/opt/vaultwarden-oci/releases/0.1.0-rc.15')
if pathlib.Path('/opt/vaultwarden-oci/current').resolve()!=release:hold('Selected installed rc15 changed')
sys.path.insert(0,str(release))
from vaultwarden_oci import cloudflare_route_mode as route,edge,crowdsec_worker_policy,storage
if storage.verify().uuid!='f4e0bd62-48e7-4745-8987-44b14013216d':hold('Data volume changed')
inv=edge._service_invocation_id(edge.run_command)
if not inv or not crowdsec_worker_policy.runtime_policy_healthy(edge.EdgePaths(),edge.run_command):hold('Existing Worker no longer healthy')
routeid=route.read_owned_route_id(require_fail_open=True)
route.wait_owned_route_stable(routeid)
if not edge._fail_open_confirmed(edge.FAIL_OPEN_CONFIRMATION,inv):hold('Worker invocation confirmation missing')
for name in ('vaultwarden-oci-caddy','vaultwarden-oci-vaultwarden'):
    p=subprocess.run(['docker','inspect',name],capture_output=True,text=True,timeout=45,check=False)
    try:
        if p.returncode!=0:hold('Application container query failed')
        state=json.loads(p.stdout)[0]['State']
        if state['Status']!='running' or state.get('Health',{}).get('Status')!='healthy' or state.get('Paused') is not False:
            hold('Application container not healthy after safe cleanup')
    except (ValueError,KeyError,IndexError,TypeError):hold('Application container inspection invalid')
receipt={'source_commit':PIN,'boot_id':pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
         'target_and_timers':'disabled/inactive','worker_boot_unit':'disabled',
         'dns_test_override':'removed','installed_release':'0.1.0-rc.15',
         'live_worker_invocation':inv,'live_worker_route_id':routeid,
         'application':'running/healthy','phase':'CLEANUP_PASS',
         'utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
try:
    fd=os.open(EVID/'cleanup.json',os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w',encoding='utf-8') as out:
        json.dump(receipt,out,indent=2,sort_keys=True);out.write('\n');out.flush();os.fsync(out.fileno())
except OSError:hold('Cleanup receipt commit failed')
print('PASS: installed rc15 persists, current app and Worker remain healthy')
print('PASS: test-only DNS override removed only after target/four timers disabled; Cloudflare Route remains Fail Open')
print('RC15_F_POST_EXIT=0 CLEANUP_COMPLETE; OPTIONAL_AUTOSTART_DISABLED; RELEASE_GO=HOLD')
PY_FINAL
then
  echo 'RC15_F_WRAPPER_EXIT=0'
  printf 'PRIVATE_EVIDENCE_DIR=%s\n' "$EVID"
else
  rc=$?; printf 'RC15_F_WRAPPER_EXIT=2 HOLD: cleanup final rc=%s; do not retry original script\n' "$rc" >&2; exit 2
fi
RC15_F_CLEANUP
