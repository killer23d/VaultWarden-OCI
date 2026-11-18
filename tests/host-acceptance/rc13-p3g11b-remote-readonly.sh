bash <<'P3G11B'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0

hold() { printf 'P3_G11B_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'run as ubuntu'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'wrong acceptance host'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
sudo -n true >/dev/null 2>&1 || hold 'passwordless sudo required'

sudo -n python3 -B - <<'PY'
import json
import os
import pathlib
import re
import stat
import subprocess
import tomllib

REMOTE = 'bw-backup:bw-backup'
NAME = 'bw-backup:'

def hold(reason):
    print('P3_G11B_EXIT=2 HOLD: ' + reason, flush=True)
    raise SystemExit(2)

def read_cmd(args, label, timeout=120):
    try:
        p = subprocess.run(
            args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding='utf-8', errors='replace',
            timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        hold(label + ' unavailable/timed out; no writes attempted')
    if p.returncode != 0:
        hold(label + ' failed; inspect root rclone access locally (stderr intentionally hidden)')
    if len(p.stdout) > 4_000_000:
        hold(label + ' returned excessive metadata; narrower scope required')
    return p.stdout

def parse_json(raw, label, kind):
    try:
        data = json.loads(raw)
    except (TypeError, ValueError):
        hold(label + ' returned invalid JSON')
    if not isinstance(data, kind):
        hold(label + ' returned unexpected schema')
    return data

if os.geteuid() != 0:
    hold('expected root-only rclone inspection')
cfg = pathlib.Path('/etc/vaultwarden-oci/config.toml')
try:
    s = cfg.lstat()
    if not stat.S_ISREG(s.st_mode) or s.st_uid != 0 or stat.S_IMODE(s.st_mode) != 0o600:
        hold('unsafe appliance config ownership/type/mode')
    with cfg.open('rb') as f:
        backup = tomllib.load(f)['backup']
except (OSError, KeyError, TypeError, ValueError):
    hold('cannot read saved backup policy')
if backup.get('remote', '') != '' or backup.get('local_retention_days', 0) != 0 or backup.get('remote_retention_days', 0) != 0:
    hold('automatic publication/retention unexpectedly enabled')
print('PASS: appliance backup policy remains LOCAL-ONLY, retention zero')

names = read_cmd(['rclone','listremotes'], 'root rclone remote list', timeout=20).splitlines()
if NAME not in [n.strip() for n in names]:
    hold('required root rclone remote not configured: ' + NAME)
print('PASS: root rclone remote present: ' + NAME)

stat_info = parse_json(read_cmd(
    ['rclone','lsjson','--stat',REMOTE],
    'backup parent metadata', timeout=120), 'backup parent metadata', dict)
if stat_info.get('IsDir') is not True:
    hold('backup parent exists but is not a readable directory')
print('PASS: remote backup parent is an accessible directory: ' + REMOTE)

top = parse_json(read_cmd(
    ['rclone','lsjson',REMOTE],
    'top-level remote metadata listing', timeout=120),
    'top-level remote metadata listing', list)
if any(not isinstance(o, dict) or not isinstance(o.get('IsDir'),bool) for o in top):
    hold('invalid top-level remote item schema')
dirs = sum(x['IsDir'] for x in top)
files = len(top) - dirs
print(f'PASS: one-level metadata inventory: directories={dirs} files={files}; no object bodies read')

items = parse_json(read_cmd(
    ['rclone','lsjson','--recursive','--files-only',
     '--max-depth','4','--include','*.vwrec','--include','**/*.vwrec',REMOTE],
    'bounded nested .vwrec metadata listing', timeout=180),
    'bounded nested .vwrec metadata listing', list)
points = []
for item in items:
    if not isinstance(item,dict) or item.get('IsDir') is not False:
        hold('invalid recursive file metadata')
    rel = item.get('Path')
    if not isinstance(rel,str) or not rel.endswith('.vwrec'):
        continue
    if not re.fullmatch(r'[A-Za-z0-9._/-]+', rel) or any(part in ('', '.', '..') for part in rel.split('/')):
        hold('unsafe backup object path in remote inventory')
    size = item.get('Size')
    if not isinstance(size,int) or size < 0:
        hold('backup object size missing')
    points.append((item.get('ModTime') or '',rel,size))
print(f'INFO: encrypted .vwrec candidates within 4 levels={len(points)}')
for _,rel,size in sorted(points,reverse=True)[:5]:
    print(f'INFO: CANDIDATE {REMOTE}/{rel} size={size} bytes')
print('INFO: no encrypted object was downloaded, decrypted, written, overwritten or deleted')
print('INFO: this is metadata/reachability proof, NOT successful offline Age recovery')
print('P3_G11B_EXIT=0 REMOTE_METADATA_PASS_ONLY; REMOTE_RESTORE=HOLD')
PY
P3G11B
