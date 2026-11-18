bash <<'P3G11F'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
REPO='killer23d/VaultWarden-OCI'
E_COMMIT='5649ff7f91cbda7099deb43d07f93bd3831e19c8'
E_PATH='tests/host-acceptance/rc13-p3g11e-postbackup-delta-readonly.sh'
E_SHA='657c8940acbaf3ee9420ffcd4eaafa0da4b6b028c61e1c5b124192e52e0428d3'
G_COMMIT='4a877a5f5f43658a485f480076329c3c2b178b5a'
G_PATH='tests/host-acceptance/rc13-p3g11g-remote-postrestore-readonly.sh'
G_SHA='813687ed517de9e3d0fdb379acd4e55c07e344288d611a12a6c8ad5048ceb082'
OBJECT='bw-backup:bw-backup/acceptance-rc13-vm8-20261118T215615Z-208eae43675f/recovery-20261118T215628Z-a478ee3e.vwrec'
hold() { printf 'P3_G11F_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'expected ubuntu operator'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'wrong disposable acceptance host'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
sudo -n true >/dev/null 2>&1 || hold 'passwordless sudo required'
for exe in curl bash sha256sum python3; do command -v "$exe" >/dev/null || hold "missing $exe"; done
if ! (exec 3<>/dev/tty) 2>/dev/null; then hold 'interactive operator terminal required'; fi
DIR="$(mktemp -d)" || hold 'cannot prepare temporary scripts'
trap 'rm -rf -- "$DIR"' EXIT
chmod 700 "$DIR"
for stage in E G; do
    if [ "$stage" = E ]; then
        SRC="$E_COMMIT" ; SCRIPT="$E_PATH" ; SHA="$E_SHA"
    else
        SRC="$G_COMMIT" ; SCRIPT="$G_PATH" ; SHA="$G_SHA"
    fi
    TARGET="$DIR/$stage.sh"
    curl --fail --silent --show-error --location \
        --connect-timeout 15 --max-time 60 \
        "https://raw.githubusercontent.com/$REPO/$SRC/$SCRIPT" \
        --output "$TARGET" || hold "pinned $stage script download failed"
    chmod 600 "$TARGET"
    printf '%s  %s\n' "$SHA" "$TARGET" |
        sha256sum --check --status || hold "pinned $stage script hash mismatch"
    bash -n "$TARGET" || hold "pinned $stage script bash syntax failed"
done
python3 -B - "$DIR/E.sh" "$DIR/G.sh" <<'PY'
import ast,pathlib,re,sys
for path in sys.argv[1:]:
    s=pathlib.Path(path).read_text(encoding='utf-8')
    chunks=re.findall(r"<<'PY'\n(.*?)\nPY(?:\n|$)",s,re.DOTALL)
    if len(chunks)!=1:raise SystemExit('HOLD: expected exactly one embedded Python gate in '+path)
    ast.parse(chunks[0])
print('PASS: exact pinned G11E/G11G script hashes and all embedded Python syntax')
PY

printf '%s\n' '=== P3-G11F: FRESH READ-ONLY POSTBACKUP DELTA/CIPHERTEXT PROOF ==='
bash "$DIR/E.sh" || hold 'G11E delta or remote ciphertext preflight failed; no restore'

sudo -n python3 -B <<'PY'
import fcntl,json,os,subprocess
def hold(s):print('P3_G11F_EXIT=2 HOLD: '+s);raise SystemExit(2)
def show(unit):
    try:p=subprocess.run(['systemctl','show',unit,'--property=LoadState,ActiveState,SubState,UnitFileState,InvocationID'],capture_output=True,text=True,timeout=15,check=True)
    except (OSError,subprocess.SubprocessError):hold('systemd preflight unavailable')
    return dict(x.split('=',1) for x in p.stdout.splitlines() if '=' in x)
try:
    fd=os.open('/run/vaultwarden-oci/lock',os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    fcntl.flock(fd,fcntl.LOCK_UN);os.close(fd)
except OSError:hold('mutation lock occupied/unreadable')
for unit in ('vaultwarden-oci-backup.service','vaultwarden-oci-update-check.service',
             'vaultwarden-oci-maintenance.service','vaultwarden-oci-dns.service',
             'vaultwarden-oci-health.service','vaultwarden-oci-backup.timer',
             'vaultwarden-oci-update-check.timer','vaultwarden-oci-maintenance.timer',
             'vaultwarden-oci-health.timer'):
    v=show(unit)
    if v.get('LoadState')!='loaded' or v.get('ActiveState')!='inactive':
        hold('unexpected background automation: '+unit)
w=show('crowdsec-cloudflare-worker-bouncer.service')
if tuple(w.get(k) for k in ('LoadState','ActiveState','SubState','UnitFileState','InvocationID'))!=(
       'loaded','active','running','disabled','a80be9e43af84a24b505b9e4b127abeb'):
    hold('CrowdSec Worker invocation/Fail Open boundary changed')
for name in ('vaultwarden-oci-vaultwarden','vaultwarden-oci-caddy'):
    try:
        p=subprocess.run(['docker','container','inspect',name],capture_output=True,text=True,timeout=20,check=True)
        state=json.loads(p.stdout)[0]['State']
    except (OSError,ValueError,IndexError,KeyError,TypeError,subprocess.SubprocessError):
        hold('application container inspection failed')
    if state.get('Status')!='running' or state.get('Paused') is not False or state.get('Health',{}).get('Status')!='healthy':
        hold('application container not healthy: '+name)
print('PASS: mutation lock, idle automation, containers, Worker invocation')
PY

printf '\n%s\n' '=== SEPARATE OPERATOR AUTHORIZATION: REAL REMOTE RESTORE ==='
printf '%s\n' 'RESTORE IMPACT: the live Vaultwarden database and file data, Caddy data/config, config.toml, and SOPS secrets will be REPLACED.'
printf '%s\n' 'Vaultwarden and Caddy stop/remove/rebuild during recovery; the operational Age key may be rekeyed.'
printf '%s\n' 'The second, post-backup synthetic saved item will be permanently LOST by this rollback.'
printf '%s\n' 'The original first saved item should return, with its recorded pre-backup fingerprint.'
printf '%s\n' 'No historical Box backups, rclone configuration, public DNS, or Worker invocation are intentional targets.'
printf 'SOURCE: %s\n' "$OBJECT"
exec 3<>/dev/tty || hold 'operator terminal unavailable'
printf 'Type AUTHORIZE P3-G11F REMOTE RESTORE, or anything else to HOLD: ' >&3
IFS= read -r answer <&3 || hold 'authorization read failed'
[ "$answer" = 'AUTHORIZE P3-G11F REMOTE RESTORE' ] || hold 'real remote restore not authorized'
exec 3>&-
printf '\n%s\n' '=== RECHECK PREMUTATION SOURCE AND DELTA ==='
bash "$DIR/E.sh" || hold 'state or remote changed after authorization; restore not started'
printf '\n%s\n' '=== SUPPORTED PRODUCT REMOTE RESTORE; FINAL RESTORE CONSENT REQUIRED ==='
printf '%s\n' 'Use your matching separately held offline test Age identity via hidden input.'
printf '%s\n' 'The product independently requires typing RESTORE after complete cryptographic preflight.'
if ! sudo -n /usr/local/bin/vwctl restore --from-remote "$OBJECT" --start \
    </dev/tty >/dev/tty 2>&1; then
    hold 'product remote restore failed: DO NOT automatically retry/restart services'
fi
printf '%s\n' 'INFO: CLI exit=0 alone may indicate cancellation; checking actual restored data independently'
printf '\n%s\n' '=== INDEPENDENT P3-G11G POSTRESTORE STATE, TLS, SOPS AND WORKER ==='
bash "$DIR/G.sh" || hold 'G11G postrestore verification did not pass; do not auto-retry'
printf '%s\n' 'P3_G11F_EXIT=0 REMOTE_RESTORE_AND_INDEPENDENT_POSTCHECK_PASS; RELEASE_GO=HOLD'
P3G11F
