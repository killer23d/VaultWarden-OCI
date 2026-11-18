bash <<'P3G9C'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0

PIN='fd56313255c97992dc55c1475d94477597b88602'
WORK="$HOME/VaultWarden-OCI-p2b-fd56313255c9"
REL='/opt/vaultwarden-oci/releases/0.1.0-rc.13'
ART='/var/lib/vaultwarden-oci/backups/recovery-20261118T202543Z-e3ef03c7.vwrec'
SHA='47f775b7e2f534e53cc4c6c5056df786fe0bbb0e316f5fa907b1b1c879546a44'
UUID='f4e0bd62-48e7-4745-8987-44b14013216d'
INV='a80be9e43af84a24b505b9e4b127abeb'

hold() { printf 'P3_G9C_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'run as ubuntu'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'wrong acceptance host'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
[ -d "$WORK/.git" ] && [ ! -L "$WORK" ] || hold 'pinned source checkout missing'
HEAD="$(git --no-optional-locks -C "$WORK" rev-parse HEAD 2>/dev/null)" || hold 'source checkout unreadable'
[ "$HEAD" = "$PIN" ] || hold 'pinned release source changed'
sudo -n true >/dev/null 2>&1 || hold 'passwordless sudo unavailable'

sudo -n python3 -B - "$REL" "$ART" "$SHA" "$UUID" "$INV" <<'PY'
import fcntl, hashlib, ipaddress, json, os, re, socket, sqlite3, stat
import subprocess, sys, tomllib
from pathlib import Path
from urllib.parse import quote

rel_arg, archive_arg, expected_sha, expected_uuid, expected_inv = sys.argv[1:]
rel = Path(rel_arg)
archive = Path(archive_arg)
root = Path('/var/lib/vaultwarden-oci')

def hold(reason):
    print('P3_G9C_EXIT=2 HOLD: '+reason, file=sys.stderr, flush=True)
    raise SystemExit(2)

def ok(msg):
    print('PASS: '+msg, flush=True)

def run(argv, timeout=120, allow_nonzero=False):
    try:
        p = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        hold('required read-only command unavailable/timed out: '+argv[0])
    if p.returncode and not allow_nonzero:
        hold('required read-only command failed: '+argv[0])
    return p.stdout, p.returncode

def regular(path, uid=0):
    try:
        s=path.lstat()
    except OSError:
        hold('missing protected file: '+str(path))
    if not stat.S_ISREG(s.st_mode) or s.st_uid!=uid or s.st_nlink!=1 or stat.S_IMODE(s.st_mode)!=0o600:
        hold('unsafe protected file ownership/type/mode: '+str(path))
    return s

def show(unit):
    raw,_=run(['systemctl','show',unit,'--property=LoadState,ActiveState,SubState,UnitFileState,InvocationID'])
    return dict(line.split('=',1) for line in raw.splitlines() if '=' in line)

if os.geteuid()!=0 or socket.gethostname().split('.')[0]!='vaultwarden-oci-8':
    hold('unexpected host or root identity')
if not rel.is_dir() or rel.is_symlink():
    hold('installed immutable release missing')
if Path('/opt/vaultwarden-oci/current').resolve()!=rel.resolve():
    hold('current release symlink changed')
if Path('/usr/local/bin/vwctl').resolve()!=(rel/'vwctl').resolve():
    hold('installed vwctl selection changed')
sys.path.insert(0,str(rel))
from vaultwarden_oci import storage
try:
    disk=storage.verify()
    approved=Path('/dev/oracleoci/oraclevdb').resolve(strict=True)
except (storage.StorageError, OSError):
    hold('dedicated disk and ownership identity invalid')
if disk.uuid!=expected_uuid or disk.fs_type!='ext4' or Path(disk.source).resolve()!=approved:
    hold('dedicated data disk or UUID changed')
if not root.is_mount() or root.stat().st_dev==Path('/').stat().st_dev:
    hold('data disk fell back to root')
opts,_=run(['findmnt','-n','-o','OPTIONS','--target',str(root)])
if 'rw' not in opts.strip().split(','):
    hold('dedicated ext4 mount not read-write')
ok('immutable rc.13 remains selected; original ext4 data disk/UUID/root separation verified')

for path in (Path('/etc/vaultwarden-oci/config.toml'),
             Path('/etc/vaultwarden-oci/secrets.sops.yaml'),
             Path('/etc/vaultwarden-oci/age-key.txt'),
             root/'state/recovery.json',root/'.vaultwarden-oci-volume.json'):
    regular(path)
if (root/'state/update-recovery-required.json').exists():
    hold('pending update recovery guard exists')
try:
    with Path('/etc/vaultwarden-oci/config.toml').open('rb') as stream:
        cfg=tomllib.load(stream)
    backup=cfg['backup']
    domain=cfg['site']['domain']
except (OSError, ValueError, KeyError, TypeError):
    hold('restored configuration invalid')
if backup.get('remote')!='' or backup.get('local_retention_days')!=0 or backup.get('remote_retention_days')!=0:
    hold('restored remote/retention policy unexpectedly changed')
if not isinstance(domain,str) or not re.fullmatch('[A-Za-z0-9][A-Za-z0-9.-]{1,250}[A-Za-z0-9]',domain):
    hold('restored site hostname invalid')
ok('restored config/SOPS/operational Age files protected; local-only backup and retention zero')

s=regular(archive)
if s.st_size!=348440 or s.st_dev!=root.stat().st_dev:
    hold('original encrypted archive size/filesystem changed')
h=hashlib.sha256()
with archive.open('rb') as stream:
    for chunk in iter(lambda:stream.read(1024*1024),b''):
        h.update(chunk)
if h.hexdigest()!=expected_sha:
    hold('original recovery archive SHA256 changed')
ok('the original immutable encrypted .vwrec survives the real restore unchanged')

lock=Path('/run/vaultwarden-oci/lock')
regular(lock)
try:
    fd=os.open(lock,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
    fcntl.flock(fd,fcntl.LOCK_SH|fcntl.LOCK_NB)
except (OSError, BlockingIOError):
    hold('global lock busy or unreadable')
for unit in ('vaultwarden-oci-backup.service','vaultwarden-oci-update-check.service',
             'vaultwarden-oci-maintenance.service','vaultwarden-oci-dns.service',
             'vaultwarden-oci-health.service','vaultwarden-oci-backup.timer',
             'vaultwarden-oci-update-check.timer','vaultwarden-oci-maintenance.timer',
             'vaultwarden-oci-health.timer'):
    data=show(unit)
    if data.get('LoadState')!='loaded' or data.get('ActiveState')!='inactive':
        hold('unexpected active/unloaded background automation: '+unit)
w=show('crowdsec-cloudflare-worker-bouncer.service')
if tuple(w.get(k) for k in ('LoadState','ActiveState','SubState','UnitFileState','InvocationID'))!=(
        'loaded','active','running','disabled',expected_inv):
    hold('CrowdSec Worker invocation/Fail Open confirmation boundary changed')
ok('no automation started; Worker remains active, boot-disabled and invocation-bound')

containers={}
for name in ('vaultwarden-oci-vaultwarden','vaultwarden-oci-caddy'):
    try:
        info=json.loads(run(['docker','container','inspect',name])[0])[0]
        state=info['State']
    except (ValueError,KeyError,TypeError,IndexError):
        hold('Docker inspection unreadable for '+name)
    if state.get('Status')!='running' or state.get('Paused') is not False or state.get('Health',{}).get('Status')!='healthy':
        hold('restored container unhealthy/paused: '+name)
    containers[name]=info
ok('both real postrestore Vaultwarden/Caddy containers running, healthy, unpaused')

db=root/'data/db.sqlite3'
try:
    info=db.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size==0:
        hold('restored SQLite database missing or empty')
    src=sqlite3.connect('file:'+quote(str(db),safe='/')+'?mode=ro',uri=True,timeout=10)
    snap=sqlite3.connect(':memory:')
    try:
        src.backup(snap,pages=128,sleep=0.1)
        if snap.execute('PRAGMA integrity_check').fetchone()!=('ok',):
            hold('restored SQLite integrity_check not ok')
        names={x[0] for x in snap.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if not {'users','ciphers'}.issubset(names):
            hold('restored Vaultwarden schema missing users/ciphers')
        counts={k:snap.execute('SELECT COUNT(*) FROM "'+k+'"').fetchone()[0] for k in ('users','ciphers')}
    finally:
        snap.close()
        src.close()
except (sqlite3.Error,OSError):
    hold('read-only live SQLite snapshot failed')
ok('recovered SQLite integrity=ok; users='+str(counts['users'])+' ciphers='+str(counts['ciphers'])+' (counts only)')

try:
    doctor=json.loads(run(['/usr/local/bin/vwctl','doctor','--json'])[0])
    checks={r['id']:r['status'] for r in doctor['checks']}
except (KeyError,TypeError,ValueError):
    hold('doctor JSON unreadable')
if doctor.get('overall')=='FAIL' or 'FAIL' in checks.values():
    hold('postrestore doctor FAIL')
required=('host.os','host.architecture','config.toml','versions.toml',
          'runtime.paths','secrets.custody','secrets.decrypt','recovery.local',
          'notification.catalog','edge.cloudflare.cidrs','edge.cloudflare.iptables',
          'crowdsec.engine','crowdsec.hub','crowdsec.firewall','crowdsec.cloudflare')
for k in required:
    if checks.get(k)!='PASS':
        hold('required postrestore doctor check not PASS: '+k)
allowed={'recovery.offsite','recovery.rclone','notification.last_delivery'}
if cfg.get('notifications') is None:
    for k in ('notification.provider','notification.api_secret','notification.smtp_fallback'):
        if checks.get(k)!='SKIP':
            hold('unconfigured optional notification not SKIP: '+k)
        allowed.add(k)
else:
    for k in ('notification.provider','notification.api_secret','notification.smtp_fallback'):
        if checks.get(k)!='PASS':
            hold('configured notification check not PASS: '+k)
if checks.get('notification.last_delivery') not in ('PASS','WARN','SKIP'):
    hold('notification.last_delivery status invalid')
warnings=sorted(k for k,v in checks.items() if v in ('WARN','SKIP') and k not in allowed)
if warnings:
    hold('unexpected doctor WARN/SKIP: '+','.join(warnings))
ok('doctor zero FAIL; required SOPS secrets, runtime, recovery, origin and CrowdSec checks PASS')
try:
    status=json.loads(run(['/usr/local/bin/vwctl','status','--json'],allow_nonzero=True)[0])
    runtime=status['runtime']
    services={r['service']:r for r in runtime['services']}
except (KeyError,TypeError,ValueError):
    hold('structured appliance status unreadable')
if runtime.get('overall')!='running':
    hold('restored appliance runtime not running')
for key in ('vaultwarden','caddy'):
    if services.get(key,{}).get('state')!='running' or services[key].get('health')!='healthy':
        hold('structured runtime service not healthy: '+key)
ok('independent runtime status=running; disabled automation remains separate')

# Verify TLS directly over private Docker IPv4, never public DNS. No curl -k.
networks=(containers['vaultwarden-oci-caddy'].get('NetworkSettings') or {}).get('Networks') or {}
ips=[]
for network in networks.values():
    value=network.get('IPAddress','')
    try: ip=ipaddress.ip_address(value)
    except ValueError: continue
    if ip.version==4 and ip.is_private and not ip.is_loopback: ips.append(value)
if not ips:
    hold('Caddy has no private IPv4 endpoint for local TLS probe')
tls_ok=False
for addr in dict.fromkeys(ips):
    codes=[]
    for path in ('/','/api/config','/admin/'):
        output,rc=run(['curl','--noproxy','*','--ipv4','--silent','--show-error',
                       '--output','/dev/null','--write-out','%{http_code}',
                       '--connect-timeout','8','--max-time','20','--resolve',
                       f'{domain}:443:{addr}',f'https://{domain}{path}'],
                      timeout=25,allow_nonzero=True)
        if rc: break
        codes.append(output.strip())
    if codes==['200','200','401']:
        tls_ok=True
        break
if not tls_ok:
    hold('local verified TLS Web/API/Admin did not return 200/200/401')
ok('trusted local Caddy TLS Web Vault=200 API=200 unauth Admin=401; no public DNS or remote change')
print('P3_G9C_AUTOMATED=PASS; LIVE_STATE=HEALTHY',flush=True)
print('INFO: SQLite counts alone do not prove a specific known pre-backup vault item.',flush=True)
PY

if ! exec 3<>/dev/tty; then
  hold 'operator terminal unavailable for postrestore test-data confirmation'
fi
printf '%s\n' 'ATTEST KNOWN_STATE: Compare an actual restored test user/item with your documented pre-backup state.'
printf 'Type YES only after independently checking that state, otherwise HOLD: ' >&3
IFS= read -r answer <&3 || hold 'terminal answer unavailable'
[ "$answer" = YES ] || hold 'specific pre-backup vault state not yet independently checked'
exec 3>&-
printf '%s\n' 'PASS: known pre-backup test state operator-confirmed, not independently machine-verified'
printf '%s\n' 'P3_G9C_EXIT=0 POSTRESTORE_PASS; RELEASE_GO=HOLD'
P3G9C
