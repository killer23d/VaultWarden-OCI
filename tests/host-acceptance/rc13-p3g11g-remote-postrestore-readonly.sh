bash <<'P3G11G'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
hold() { printf 'P3_G11G_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'wrong operator'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'wrong disposable host'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
sudo -n true >/dev/null 2>&1 || hold 'passwordless sudo unavailable'
sudo -n python3 -B <<'PY'
import fcntl, hashlib, ipaddress, json, os, pathlib, sqlite3, stat
import subprocess, sys, tomllib
root=pathlib.Path('/var/lib/vaultwarden-oci')
release=pathlib.Path('/opt/vaultwarden-oci/releases/0.1.0-rc.13')
baseline='10b53feb60db4f7d94f280b6601e6fdfd35d6137d13eb351b94f99234c4149fa'
worker_inv='a80be9e43af84a24b505b9e4b127abeb'
def hold(s):
    print('P3_G11G_EXIT=2 HOLD: '+s,flush=True)
    raise SystemExit(2)
def passed(s):print('PASS: '+s,flush=True)
def run(args, timeout=120, check=True):
    try:
        p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                         text=True,timeout=timeout,check=False)
    except (OSError,subprocess.TimeoutExpired):hold('read-only check unavailable: '+args[0])
    if check and p.returncode:hold('read-only check failed: '+args[0])
    return p.stdout,p.returncode
def unit(name):
    raw,_=run(['systemctl','show',name,'--property=LoadState,ActiveState,SubState,UnitFileState,InvocationID'])
    return dict(line.split('=',1) for line in raw.splitlines() if '=' in line)
if os.geteuid()!=0 or pathlib.Path('/opt/vaultwarden-oci/current').resolve()!=release.resolve():
    hold('unexpected root or release identity')
sys.path.insert(0,str(release))
from vaultwarden_oci import storage
try:
    disk=storage.verify()
    approved=pathlib.Path('/dev/oracleoci/oraclevdb').resolve(strict=True)
except (storage.StorageError,OSError):hold('dedicated data device failed verification')
if (disk.uuid!='f4e0bd62-48e7-4745-8987-44b14013216d' or disk.fs_type!='ext4'
    or pathlib.Path(disk.source).resolve()!=approved or not root.is_mount()
    or root.stat().st_dev==pathlib.Path('/').stat().st_dev):
    hold('restored disk changed or fell back to root')
if (root/'state/update-recovery-required.json').exists():hold('unexpected recovery-required guard')
for p in ('/etc/vaultwarden-oci/config.toml','/etc/vaultwarden-oci/secrets.sops.yaml',
          '/etc/vaultwarden-oci/age-key.txt'):
    try: st=pathlib.Path(p).lstat()
    except OSError:hold('protected configuration/secrets file missing')
    if not stat.S_ISREG(st.st_mode) or st.st_uid!=0 or stat.S_IMODE(st.st_mode)!=0o600:
        hold('protected configuration/secrets file unsafe')
try:
    with open('/etc/vaultwarden-oci/config.toml','rb') as f:cfg=tomllib.load(f)
    backup=cfg['backup'];domain=cfg['site']['domain']
except (KeyError,OSError,TypeError,ValueError):hold('restored configuration invalid')
if (backup.get('remote',''),backup.get('local_retention_days',0),
    backup.get('remote_retention_days',0))!=('',0,0):
    hold('restored automatic remote publishing/retention changed')
passed('pinned release/dedicated ext4 disk/protected secrets; local-only retention zero')
try:
    db=sqlite3.connect('file:'+str(root/'data/db.sqlite3')+'?mode=ro',uri=True,timeout=10)
    memory=sqlite3.connect(':memory:')
    try:
        db.backup(memory,pages=128,sleep=0.1)
        if memory.execute('PRAGMA integrity_check').fetchone()!=('ok',):
            hold('restored SQLite integrity check failed')
        users=memory.execute('SELECT COUNT(*) FROM users').fetchone()[0]
        rows=list(memory.execute('SELECT * FROM ciphers ORDER BY uuid'))
    finally:memory.close();db.close()
except (sqlite3.Error,OSError):hold('restored SQLite snapshot unavailable')
digest=hashlib.sha256()
for row in rows:
    b=repr(row).encode('utf-8')
    digest.update(len(b).to_bytes(8,'big'))
    digest.update(b)
if users!=1 or len(rows)!=1 or digest.hexdigest()!=baseline:
    hold('remote restore did not return the original single saved item and remove the postbackup item')
passed('restored SQLite integrity=ok; 1 user, original 1 cipher; newer cipher absent')
print('RESTORED_CIPHER_RECORDS_FINGERPRINT_SHA256='+digest.hexdigest(),flush=True)
try:
    fd=os.open('/run/vaultwarden-oci/lock',os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    fcntl.flock(fd,fcntl.LOCK_UN);os.close(fd)
except (OSError,BlockingIOError):hold('global mutation lock busy')
for name in ('vaultwarden-oci-backup.service','vaultwarden-oci-update-check.service',
             'vaultwarden-oci-maintenance.service','vaultwarden-oci-dns.service',
             'vaultwarden-oci-health.service','vaultwarden-oci-backup.timer',
             'vaultwarden-oci-update-check.timer','vaultwarden-oci-maintenance.timer',
             'vaultwarden-oci-health.timer'):
    value=unit(name)
    if value.get('LoadState')!='loaded' or value.get('ActiveState')!='inactive':
        hold('background job or timer changed: '+name)
worker=unit('crowdsec-cloudflare-worker-bouncer.service')
if tuple(worker.get(x) for x in ('LoadState','ActiveState','SubState','UnitFileState','InvocationID'))!=(
    'loaded','active','running','disabled',worker_inv):
    hold('CrowdSec Worker invocation/Fail Open changed')
passed('automation idle; Worker still active, boot-disabled and invocation-bound')
containers={}
for name in ('vaultwarden-oci-vaultwarden','vaultwarden-oci-caddy'):
    try:
        info=json.loads(run(['docker','container','inspect',name])[0])[0]
        state=info['State']
    except (IndexError,KeyError,TypeError,ValueError):hold('restored Docker state unavailable')
    if state.get('Status')!='running' or state.get('Paused') is not False or state.get('Health',{}).get('Status')!='healthy':
        hold('restored Docker container unhealthy: '+name)
    containers[name]=info
passed('postrestore Vaultwarden/Caddy containers running, healthy and unpaused')
try:
    doctor=json.loads(run(['/usr/local/bin/vwctl','doctor','--json'])[0])
    checks={v['id']:v['status'] for v in doctor['checks']}
except (KeyError,TypeError,ValueError):hold('postrestore doctor JSON invalid')
if doctor.get('overall')=='FAIL' or 'FAIL' in checks.values():hold('postrestore doctor FAIL')
for name in ('host.os','host.architecture','config.toml','versions.toml',
             'runtime.paths','secrets.custody','secrets.decrypt','recovery.local',
             'edge.cloudflare.iptables','crowdsec.engine','crowdsec.firewall',
             'crowdsec.cloudflare','notification.catalog'):
    if checks.get(name)!='PASS':hold('postrestore doctor check not PASS: '+name)
try:
    status=json.loads(run(['/usr/local/bin/vwctl','status','--json'],check=False)[0])
    if status['runtime']['overall']!='running':hold('appliance runtime not running')
except (KeyError,TypeError,ValueError):hold('postrestore appliance status JSON invalid')
passed('doctor zero FAIL; SOPS custody/decryption, recovery, origin/CrowdSec PASS')
networks=(containers['vaultwarden-oci-caddy'].get('NetworkSettings') or {}).get('Networks') or {}
ips=[]
for item in networks.values():
    address=item.get('IPAddress','')
    try:ip=ipaddress.ip_address(address)
    except ValueError:continue
    if ip.version==4 and ip.is_private and not ip.is_loopback:ips.append(address)
if not ips:hold('private Caddy IPv4 endpoint missing')
valid=False
for addr in dict.fromkeys(ips):
    codes=[]
    for route in ('/','/api/config','/admin/'):
        result,code=run(['curl','--noproxy','*','--ipv4','--silent','--show-error',
              '--output','/dev/null','--write-out','%{http_code}',
              '--connect-timeout','8','--max-time','20',
              '--resolve',domain+':443:'+addr,'https://'+domain+route],
              timeout=25,check=False)
        if code:break
        codes.append(result.strip())
    if codes==['200','200','401']:valid=True;break
if not valid:hold('verified local HTTPS Web/API/Admin 200/200/401 check failed')
passed('verified private Caddy TLS: Web Vault 200, API 200, unauth Admin 401')
print('P3_G11G_EXIT=0 INDEPENDENT_POSTRESTORE_PASS; PRODUCTION_GO=HOLD',flush=True)
print('INFO: browser/client item check and remaining release gates are separate',flush=True)
PY
P3G11G
