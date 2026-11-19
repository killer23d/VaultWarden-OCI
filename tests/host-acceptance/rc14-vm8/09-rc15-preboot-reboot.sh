#!/usr/bin/env bash
bash <<'RC15_C_PREBOOT'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
hold() { printf 'RC15_C_PREBOOT_WRAPPER_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'Wrong operator'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'Wrong host'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
sudo -n true >/dev/null 2>&1 || hold 'Passwordless sudo required'
PIN='32beec5bc905cdecdfdc4a359147c3f1d45d8444'
WORK="$HOME/VaultWarden-OCI-rc15-a-${PIN:0:12}"
PRIOR="$HOME/vwoci-acceptance/rc15-b-${PIN:0:12}/after.json"
EVID="$HOME/vwoci-acceptance/rc15-c-${PIN:0:12}"
DNS_DROP='/etc/systemd/system/vaultwarden-oci-dns.service.d/vwoci-rc15-acceptance.conf'
DNS_PERMIT='/run/vwoci-rc15-acceptance-dns-permit'
[ -d "$WORK/.git" ] && [ "$(git -C "$WORK" rev-parse HEAD)" = "$PIN" ] || hold 'Pinned rc15 source missing or changed'
[ "$(readlink -f /opt/vaultwarden-oci/current)" = '/opt/vaultwarden-oci/releases/0.1.0-rc.15' ] || hold 'Installed rc15 not selected'
[ -f "$PRIOR" ] || hold 'RC15-B accepted stop/re-arm evidence missing'
[ ! -e "$EVID" ] && [ ! -L "$EVID" ] || hold 'Preboot already begun; do not replay'
[ ! -e "$DNS_PERMIT" ] && [ ! -L "$DNS_PERMIT" ] || hold 'DNS test-only allow marker unexpectedly exists'
[ ! -e "$DNS_DROP" ] && [ ! -L "$DNS_DROP" ] || hold 'DNS isolation override already exists; do not overwrite'
[ -z "$(git -C "$WORK" status --porcelain)" ] || hold 'Pinned candidate checkout dirty'
[ "$(stat -c '%u:%a' "$HOME/vwoci-acceptance")" = "$(id -u):700" ] || hold 'Evidence base custody unsafe'

echo '=== RC15-C preboot: fresh Worker, exact Route, and immutable data ==='
if sudo -n /usr/bin/python3 -B - "$WORK" "$PRIOR" "$PIN" "$EVID" <<'PY_PRE'
import hashlib,json,os,pathlib,sqlite3,stat,subprocess,sys,tomllib
sys.path.insert(0, '/opt/vaultwarden-oci/releases/0.1.0-rc.15')
from vaultwarden_oci import cloudflare_route_mode as route,crowdsec_worker_policy,edge,storage,runtime

def hold(s):print('RC15_C_PRE_EXIT=2 HOLD: '+s,flush=True);raise SystemExit(2)
work, prior, pin, evid=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]),sys.argv[3],pathlib.Path(sys.argv[4])
s=prior.lstat()
if not stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode) or s.st_uid!=0 or stat.S_IMODE(s.st_mode)!=0o600:hold('Prior acceptance custody invalid')
record=json.loads(prior.read_text())
boot=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
if (record.get('schema_version')!=1 or record.get('source_commit')!=pin
    or record.get('result')!='PASS' or record.get('installed_release')!='0.1.0-rc.15'
    or record.get('doctor')!='PASS' or record.get('cloudflare_route_fail_open') is not True
    or record.get('boot_id')!=boot):hold('Accepted RC15-B checkpoint missing or stale')
ident=storage.verify()
if ident.uuid!='f4e0bd62-48e7-4745-8987-44b14013216d' or ident.fs_type!='ext4':hold('Dedicated disk changed')
inv=edge._service_invocation_id(edge.run_command)
if inv!=record.get('new_invocation') or not edge._disabled(edge.BOUNCER_SERVICE,edge.run_command) or not crowdsec_worker_policy.runtime_policy_healthy(edge.EdgePaths(),edge.run_command) or not edge._fail_open_confirmed(edge.FAIL_OPEN_CONFIRMATION,inv):hold('Worker/current confirmation changed')
rid=route.read_owned_route_id(require_fail_open=True)
if rid!=record.get('new_route_id'):hold('Cloudflare Route changed after RC15-B')
route.wait_owned_route_stable(rid)
try:
    source=sqlite3.connect('file:/var/lib/vaultwarden-oci/data/db.sqlite3?mode=ro',uri=True,timeout=15)
    clone=sqlite3.connect(':memory:');source.backup(clone,pages=128,sleep=0.1);source.close()
    if clone.execute('PRAGMA integrity_check').fetchone()!=('ok',):hold('Vault SQLite integrity failed')
    users=clone.execute('SELECT count(*) FROM users').fetchone()[0]
    items=clone.execute('SELECT count(*) FROM ciphers').fetchone()[0]
    fingerprint=hashlib.sha256()
    for row in clone.execute('SELECT * FROM ciphers ORDER BY uuid'):
        raw=repr(row).encode();fingerprint.update(len(raw).to_bytes(8,'big'));fingerprint.update(raw)
    clone.close()
except (OSError,sqlite3.Error):hold('Read-only vault snapshot failed')
if (users,items,fingerprint.hexdigest())!=(1,1,record.get('original_cipher_sha256')):
    hold('Original restored vault contents changed')
if runtime.load_config().offsite_remote is not None:hold('VM8 offsite backup publication not disabled')
if runtime.load_config().local_retention_days!=0 or runtime.load_config().remote_retention_days!=0:hold('VM8 retention not zero')
for unit in ('vaultwarden-oci.target','vaultwarden-oci-crowdsec-boot.service'):
    p=subprocess.run(['systemctl','show',unit,'--property=LoadState,UnitFileState,ActiveState','--no-pager'],capture_output=True,text=True,check=True)
    d=dict(x.split('=',1) for x in p.stdout.splitlines() if '=' in x)
    if (d.get('LoadState')!='loaded' or d.get('UnitFileState')!='disabled'
        or d.get('ActiveState')!='inactive'):hold('Boot unit already active/enabled or missing: '+unit)
print('PASS: RC15-B fresh invocation and exact Fail Open Route, original restored vault and dedicated disk')
print('PASS: selected rc15 boot units are idle/disabled; offsite and pruning remain disabled')
print('RC15_C_PRE_EXIT=0 SAFE_TO_STAGE_DNS_ISOLATION')
PY_PRE
then :; else hold 'Preboot identity or policy preflight failed; no unit enablement'; fi

printf '\n=== Independent RC15-C reboot authorization ===\n' >&2
printf 'This reboot interrupts the disposable VM and recreates the Worker Route for the configured hostname.\n' >&2
printf 'The Worker Route may also affect traffic to the existing public DNS origin; public DNS will NOT be changed.\n' >&2
printf 'A reversible systemd DNS-writer block and opt-in boot/target enablement will be staged first.\n' >&2
printf 'Type AUTHORIZE_RC15_VM8_REBOOT to proceed, or anything else to decline: ' >&2
IFS= read -r CONSENT </dev/tty || hold 'No independent interactive reboot consent'
if [ "$CONSENT" != 'AUTHORIZE_RC15_VM8_REBOOT' ]; then
  echo 'RC15_C_CONSENT=DECLINED; NO_BOOT_MUTATION; REBOOT=NOT_RUN'
  exit 0
fi
[ ! -e "$EVID" ] && [ ! -L "$EVID" ] || hold 'Preboot evidence appeared during consent'
mkdir -m 700 "$EVID" || hold 'Protected evidence directory unavailable'
if sudo -n /usr/local/bin/vwctl doctor --json >"$EVID/doctor-before.json"; then :; else hold 'Current installed doctor failed'; fi
if sudo -n /usr/bin/python3 -B - "$EVID/doctor-before.json" <<'PY_DOCTOR'
import json,sys
with open(sys.argv[1],encoding='utf-8') as f:doc=json.load(f)
checks={item['id']:item['status'] for item in doc['checks']}
if doc.get('overall')!='PASS' or 'FAIL' in checks.values() or checks.get('crowdsec.cloudflare')!='PASS':
    raise SystemExit('HOLD: preboot installed doctor not fully PASS')
print('PASS: installed rc15 doctor fully PASS before DNS isolation and unit enablement')
PY_DOCTOR
then :; else hold 'Preboot doctor JSON gate failed; no DNS or unit mutation'; fi

printf '\n=== RC15-C stage reversible DNS writer condition ===\n'
if sudo -n /usr/bin/python3 -B - "$DNS_DROP" "$DNS_PERMIT" <<'PY_DNS'
import os,pathlib,stat,sys
path=pathlib.Path(sys.argv[1]);permit=pathlib.Path(sys.argv[2])
if permit.exists() or permit.is_symlink():raise SystemExit('HOLD: DNS allow-marker present')
parent=path.parent
parent.mkdir(mode=0o755,parents=True,exist_ok=True)
info=parent.lstat()
if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_uid!=0:raise SystemExit('HOLD: systemd drop-in parent unsafe')
body='[Unit]\nConditionPathExists='+str(permit)+'\n'
fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o644)
os.fchmod(fd,0o644)  # umask 077 must not silently produce mode 0600
with os.fdopen(fd,'w',encoding='utf-8') as out:out.write(body);out.flush();os.fsync(out.fileno())
print('PASS: DNS publication service must skip while nonexistent test-only marker is absent')
PY_DNS
then :; else hold 'Failed to stage DNS isolation; do not enable target'; fi

sudo -n systemctl daemon-reload || hold 'systemd reload failed; do not enable target'
if ! systemctl show vaultwarden-oci-dns.service --property=DropInPaths --value --no-pager | grep -Fq "$DNS_DROP"; then
  hold 'DNS isolation drop-in not recognized by systemd'
fi
[ ! -e "$DNS_PERMIT" ] && [ ! -L "$DNS_PERMIT" ] || hold 'DNS permit marker appeared; no reboot'

echo '=== RC15-C enable target and separately guarded Worker boot one-shot (NOT --now) ==='
sudo -n systemctl enable vaultwarden-oci-crowdsec-boot.service || hold 'Opt-in CrowdSec boot enable failed'
sudo -n systemctl enable vaultwarden-oci.target || hold 'Appliance target enable failed'

if sudo -n /usr/bin/python3 -B - "$PRIOR" "$EVID" "$PIN" "$DNS_DROP" "$DNS_PERMIT" <<'PY_SAVE'
import datetime,hashlib,json,os,pathlib,stat,subprocess,sys
sys.path.insert(0, '/opt/vaultwarden-oci/releases/0.1.0-rc.15')
from vaultwarden_oci import cloudflare_route_mode as route,edge,crowdsec_worker_policy
prior,evid,pin,drop,permit=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]),sys.argv[3],pathlib.Path(sys.argv[4]),pathlib.Path(sys.argv[5])
before=json.loads(prior.read_text())
if permit.exists() or permit.is_symlink():raise SystemExit('HOLD: DNS marker became present')
if drop.read_text()!=('[Unit]\nConditionPathExists='+str(permit)+'\n'):raise SystemExit('HOLD: DNS isolation contents changed')
for unit in ('vaultwarden-oci.target','vaultwarden-oci-crowdsec-boot.service'):
    p=subprocess.run(['systemctl','show',unit,'--property=UnitFileState','--no-pager'],capture_output=True,text=True,check=True)
    if 'UnitFileState=enabled' not in p.stdout:raise SystemExit('HOLD: expected systemd unit not enabled: '+unit)
if not edge._disabled(edge.BOUNCER_SERVICE,edge.run_command):raise SystemExit('HOLD: package Worker unexpectedly enabled')
inv=edge._service_invocation_id(edge.run_command)
if inv!=before['new_invocation'] or not crowdsec_worker_policy.runtime_policy_healthy(edge.EdgePaths(),edge.run_command):raise SystemExit('HOLD: Worker invocation changed during staging')
rid=route.read_owned_route_id(require_fail_open=True)
if rid!=before['new_route_id']:raise SystemExit('HOLD: Worker Route changed during staging')
row={'source_commit':pin,'boot_id':pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip(),'old_worker_invocation':inv,'old_worker_route_id':rid,'disk_uuid':'f4e0bd62-48e7-4745-8987-44b14013216d','original_cipher_sha256':before['original_cipher_sha256'],'dns_isolation_sha256':hashlib.sha256(drop.read_bytes()).hexdigest(),'expected_target':'enabled','expected_crowdsec_boot':'enabled','result':'PREBOOT_ARMED','utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
fd=os.open(evid/'preboot.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,'w',encoding='utf-8') as out:json.dump(row,out,sort_keys=True,indent=2);out.write('\n');out.flush();os.fsync(out.fileno())
print('PASS: protected kernel boot checkpoint, targeted enabled one-shot and DNS isolation persisted')
print('RC15_C_PREBOOT_EXIT=0 READY_FOR_REAL_REBOOT')
PY_SAVE
then :; else hold 'Systemd enabled state/checkpoint mismatch; DO NOT reboot'; fi

printf 'RC15_C_REBOOT_REQUESTED=1\n'
printf 'PRIVATE_EVIDENCE_DIR=%s\n' "$EVID"
echo 'Expect current SSH session to close. Reconnect via approved OCI private access.'
sudo -n systemctl reboot --no-wall || hold 'Reboot command failed; do not replay preboot script'
RC15_C_PREBOOT
