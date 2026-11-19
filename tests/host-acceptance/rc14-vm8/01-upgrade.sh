#!/usr/bin/env bash
bash <<'RC14_C'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0

hold() { printf 'RC14_C_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'Wrong operator'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'Wrong VM'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
sudo -n true >/dev/null 2>&1 || hold 'Passwordless sudo required'

REPO='killer23d/VaultWarden-OCI'
BR='feature/cf-free-auto-fail-open'
PIN='92b9300f96125d19105cc1d4865024cb49612b28'
WORK="$HOME/VaultWarden-OCI-rc14-c-${PIN:0:12}"
BASE="$HOME/vwoci-acceptance"
P4A="$HOME/rc13-p4a-readonly-b98a96fa92c3.py"
P4A_SHA='bac3b2fa65b5952a70a5977b8b846c555ac5b912e04304606fa88bd5e199143c'

[ -f "$P4A" ] && [ ! -L "$P4A" ] || hold 'Pinned original rc13 preflight unavailable'
printf '%s  %s\n' "$P4A_SHA" "$P4A" | sha256sum --check --status || hold 'P4A checksum mismatch'
[ -d "$BASE" ] && [ ! -L "$BASE" ] || hold 'Acceptance directory missing'
[ "$(stat -c '%u:%a' "$BASE")" = "$(id -u):700" ] || hold 'Unsafe acceptance directory'
[ ! -e "$WORK" ] && [ ! -L "$WORK" ] || hold 'Exact candidate workdir already exists; no replay'
[ "$(readlink -f /opt/vaultwarden-oci/current)" = '/opt/vaultwarden-oci/releases/0.1.0-rc.13' ] || hold 'Current selected release is not rc13'

EVID="$(mktemp -d "$BASE/rc14-c-XXXXXX")" || hold 'Failed to create private evidence'
chmod 700 "$EVID"
echo '=== RC14-C verify current exact candidate full CI ==='
if python3 -B - "$REPO" "$PIN" <<'PY_CI'
import json, sys, urllib.request
repo, pin=sys.argv[1:3]
url=f'https://api.github.com/repos/{repo}/actions/runs?head_sha={pin}&per_page=10'
try:
    with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'VaultWarden-OCI-acceptance','Accept':'application/vnd.github+json'}),timeout=15) as response:
        payload=json.load(response)
    runs=payload.get('workflow_runs',[])
    good=[r for r in runs if r.get('head_sha')==pin and r.get('status')=='completed' and r.get('conclusion')=='success']
    if not good:
        raise ValueError('no completed successful GitHub Actions run for exact source SHA')
except (OSError,ValueError,KeyError,TypeError) as exc:
    print('HOLD: exact candidate CI not successful or unavailable (no upgrade)')
    raise SystemExit(2) from None
print('PASS: exact SHA has completed successful CI')
PY_CI
then :; else hold 'CI gate failed; no installation'; fi

echo '=== RC14-C fetch exact candidate (no floating source used) ==='
git clone -q --depth 1 --single-branch --branch "$BR" "https://github.com/$REPO.git" "$WORK" || hold 'GitHub checkout failed'
[ "$(git -C "$WORK" rev-parse HEAD)" = "$PIN" ] || hold 'Candidate branch moved; SHA mismatch'
[ -z "$(git -C "$WORK" status --porcelain)" ] || hold 'Source checkout dirty'
[ "$(cd "$WORK" && python3 -B ./vwctl --version)" = 'vwctl 0.1.0-rc.14' ] || hold 'Wrong candidate version'

if (cd "$WORK" && PYTHONPATH="$WORK" /usr/bin/python3 -B -m unittest discover -s tests -p 'test_crowdsec_boot_stop.py' -q && PYTHONPATH="$WORK" /usr/bin/python3 -B -m unittest discover -s tests -p 'test_cloudflare_route_mode.py' -q) >"$EVID/units.stdout" 2>"$EVID/units.stderr"; then
  echo 'PASS: focused rc14 boot, stop and Cloudflare tests'
else
  hold "Focused unit test failed; private evidence $EVID"
fi

echo '=== RC14-C accepted previous source and config; live doctor ==='
if sudo -n /usr/bin/python3 -B - "$P4A" <<'PY_OLD'
import runpy,sys
source=sys.argv[1];sys.argv=[source]
checks=runpy.run_path(source,run_name='rc14c_preflight_only')
checks['verify_host_and_storage']()
checks['verify_config']()
PY_OLD
then :; else hold 'Original installed source/config/storage changed'; fi

if sudo -n /usr/local/bin/vwctl doctor --json >"$EVID/doctor-before.json"; then :; else hold 'Pre-upgrade doctor exit failure'; fi
if python3 -B - "$EVID/doctor-before.json" <<'PY_DOC'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
    c={x['id']:x['status'] for x in d['checks']}
    assert d.get('overall')=='PASS' and 'FAIL' not in c.values() and c.get('crowdsec.cloudflare')=='PASS'
except (ValueError,KeyError,TypeError,AssertionError,OSError):
    raise SystemExit(2)
print('PASS: previous doctor overall PASS; Worker Fail Open confirmed')
PY_DOC
then :; else hold 'Doctor did not accept current rc13 state'; fi

echo '=== RC14-C supported read-only exact source upgrade plan ==='
if sudo -n env VWOCI_SOURCE_OVERRIDE=1 /usr/local/bin/vwctl update check --source "$WORK" --json >"$EVID/plan.json"; then :; else hold 'Supported update check failed'; fi
if python3 -B - "$EVID/plan.json" <<'PY_PLAN'
import json,sys
try:
    p=json.load(open(sys.argv[1],encoding='utf-8'))
    assert p['schema_version']==1 and p['current']['project']=='0.1.0-rc.13'
    assert p['candidate']['project']=='0.1.0-rc.14' and p['architecture']=='arm64'
    assert p['available'] is True and p['already_active'] is False and p['use_latest'] is False
except (OSError,ValueError,KeyError,TypeError,AssertionError):
    raise SystemExit(2)
print('PASS: planned immutable rc13 -> rc14; architecture arm64; no latest')
PY_PLAN
then :; else hold 'Source upgrade plan does not match approved transition'; fi

echo '=== RC14-C apply supported verified-recovery upgrade ONCE ==='
echo 'The installed update owner creates and verifies a pre-update encrypted .vwrec.'
if sudo -n env VWOCI_SOURCE_OVERRIDE=1 /usr/local/bin/vwctl update apply --source "$WORK" --yes --json >"$EVID/apply.stdout" 2>"$EVID/apply.stderr"; then
  echo 'PASS: supported update apply exited 0'
else
  rc=$?; printf 'RC14_C_EXIT=2 HOLD: update apply rc=%s; DO NOT retry; evidence=%s\n' "$rc" "$EVID" >&2; exit 2
fi

echo '=== RC14-C independent installed rc14 source, disk, doctor ==='
if sudo -n /usr/bin/python3 -B - "$WORK" "$PIN" <<'PY_AFTER'
import hashlib,json,os,pathlib,subprocess,sys,tomllib
work=pathlib.Path(sys.argv[1]).resolve(strict=True);pin=sys.argv[2]
release=pathlib.Path('/opt/vaultwarden-oci/releases/0.1.0-rc.14')
if pathlib.Path('/opt/vaultwarden-oci/current').resolve()!=release:
    raise SystemExit('HOLD: selected immutable rc14 release not active')
paths=subprocess.run(['git','-C',str(work),'ls-files','-z','--','vwctl','versions.toml','email-providers.toml','vaultwarden_oci','systemd'],capture_output=True,check=True).stdout.split(b'\x00')
count=0
for raw in paths:
    if not raw:continue
    relative=pathlib.Path(os.fsdecode(raw))
    source=work/relative;installed=release/relative
    if not source.is_file() or installed.is_symlink() or not installed.is_file():
        raise SystemExit('HOLD: installed rc14 release file unavailable')
    if relative.as_posix()=='versions.toml':
        if tomllib.loads(source.read_text())!=tomllib.loads(installed.read_text()):
            raise SystemExit('HOLD: installed rc14 versions semantically differ from pinned candidate')
    elif hashlib.sha256(source.read_bytes()).digest()!=hashlib.sha256(installed.read_bytes()).digest():
        raise SystemExit('HOLD: installed rc14 differs from candidate tracked source')
    count+=1
if count<50:raise SystemExit('HOLD: incomplete immutable release file inventory')
sys.path.insert(0,str(release))
from vaultwarden_oci import storage
identity=storage.verify()
if identity.uuid!='f4e0bd62-48e7-4745-8987-44b14013216d' or identity.fs_type!='ext4':
    raise SystemExit('HOLD: dedicated disk identity changed')
print('PASS: rc14 selected and '+str(count)+' tracked release files match exact tested candidate')
print('PASS: dedicated ext4 disk UUID persisted; no root fallback')
PY_AFTER
then :; else hold "Independent rc14 source/disk proof failed; evidence $EVID"; fi

if sudo -n /usr/local/bin/vwctl doctor --json >"$EVID/doctor-after.json"; then :; else hold 'Installed rc14 doctor failed'; fi
if python3 -B - "$EVID/doctor-after.json" <<'PY_DOC2'
import json,sys
p=json.load(open(sys.argv[1],encoding='utf-8'))
c={x['id']:x['status'] for x in p['checks']}
if p.get('overall')!='PASS' or 'FAIL' in c.values() or c.get('crowdsec.cloudflare')!='PASS':
    raise SystemExit(2)
print('PASS: installed rc14 doctor overall PASS, CrowdSec Cloudflare PASS')
PY_DOC2
then :; else hold 'Installed rc14 doctor reconciliation mismatch'; fi

BOOT_STATE="$(systemctl show vaultwarden-oci-crowdsec-boot.service --property=LoadState,UnitFileState --no-pager)"
case "$BOOT_STATE" in
  *'LoadState=loaded'*'UnitFileState=disabled'*|*'UnitFileState=disabled'*'LoadState=loaded'*) :;;
  *) hold 'Opt-in boot unit not installed and disabled as expected';;
esac

printf 'RC14_C_EXIT=0 INSTALLED_RC14_UPGRADE_PASS; BOOT_REARM=NOT_ENABLED; REBOOT=NOT_RUN; RELEASE_GO=HOLD\n'
printf 'PRIVATE_EVIDENCE_DIR=%s\n' "$EVID"
printf 'CANDIDATE_WORK=%s\n' "$WORK"
RC14_C
