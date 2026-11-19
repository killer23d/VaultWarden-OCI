#!/usr/bin/env bash
bash <<'RC14_D_DIAG'
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0

hold() { printf 'RC14_D_DIAG_WRAPPER_EXIT=2 HOLD: %s\n' "$*" >&2; exit 2; }
[ "$(id -un)" = ubuntu ] || hold 'Wrong operator'
[ "$(hostname -s)" = vaultwarden-oci-8 ] || hold 'Wrong host'
[ "$(uname -m)" = aarch64 ] || hold 'ARM64 required'
sudo -n true >/dev/null 2>&1 || hold 'Passwordless sudo required'

EVID="$HOME/vwoci-acceptance/rc14-d-92b9300f9612"
[ -d "$EVID" ] && [ ! -L "$EVID" ] || hold 'Original protected RC14-D folder missing'
[ "$(stat -c '%u:%a' "$EVID")" = "$(id -u):700" ] || hold 'Evidence folder custody changed'
[ "$(readlink -f /opt/vaultwarden-oci/current)" = '/opt/vaultwarden-oci/releases/0.1.0-rc.14' ] ||
  hold 'Selected rc14 release changed'

echo '=== RC14-D READ-ONLY failure and actual Worker/Route inventory ==='
echo 'No Worker stop/start, Cloudflare PUT, replay, DNS, timers, or reboot.'

if sudo -n /usr/bin/python3 -B - "$EVID" <<'PY_DIAG'
import collections
import hashlib
import json
import os
import pathlib
import platform
import pwd
import re
import stat
import subprocess
import sys
import time

def hold(message):
    print('RC14_D_DIAG_EXIT=2 HOLD: ' + message, flush=True)
    raise SystemExit(2)

def unit_state():
    args = [
        'systemctl', 'show', 'crowdsec-cloudflare-worker-bouncer.service',
        '--no-pager', '--property=LoadState,ActiveState,SubState,Result,'
        'UnitFileState,MainPID,NRestarts,Restart,InvocationID,ExecMainStatus'
    ]
    try:
        p = subprocess.run(
            args, stdin=subprocess.DEVNULL, capture_output=True, text=True,
            timeout=20, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        hold('Systemd read-only status command failed')
    if p.returncode != 0 or len(p.stdout) > 16384:
        hold('Cannot independently read systemd unit properties')
    return dict(x.split('=', 1) for x in p.stdout.splitlines() if '=' in x)

evidence = pathlib.Path(sys.argv[1])
operator = pwd.getpwnam('ubuntu')
if (
    os.geteuid() != 0 or os.environ.get('SUDO_USER') != 'ubuntu'
    or os.environ.get('SUDO_UID') != str(operator.pw_uid)
    or platform.node().split('.')[0] != 'vaultwarden-oci-8'
    or platform.machine() != 'aarch64'
    or sys.version_info[:2] != (3, 14)
    or evidence != pathlib.Path('/home/ubuntu/vwoci-acceptance/rc14-d-92b9300f9612')
):
    hold('Host/operator/evidence identity mismatch')

def read_private(name, uid):
    path = evidence / name
    try:
        info = path.lstat()
        if (
            not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or info.st_uid != uid or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_size > 65536
        ):
            hold('Private evidence has unexpected custody or size: ' + name)
        return path.read_text(encoding='utf-8')
    except (OSError, UnicodeError):
        hold('Protected phase evidence unreadable: ' + name)

try:
    before = json.loads(read_private('before.json', 0))
except (ValueError, TypeError):
    hold('Prestop receipt invalid')
if (
    before.get('phase') != 'prestop'
    or before.get('source_commit') != '92b9300f96125d19105cc1d4865024cb49612b28'
    or not re.fullmatch('[a-f0-9]{32}', str(before.get('old_invocation', '')))
    or not re.fullmatch('[a-f0-9]{32}', str(before.get('old_route_id', '')))
):
    hold('Original prestop identity does not match RC14-D')
if 'controlled Worker stop' not in read_private('stop.stdout', operator.pw_uid):
    hold('Original controlled stop receipt missing')
stdout = read_private('rearm.stdout', operator.pw_uid)
stderr = read_private('rearm.stderr', operator.pw_uid)

print('ORIGINAL_CONTROLLED_STOP=PASS')
print('START_COMMAND_MILESTONE=' + str(
    'Cloudflare remediation started for one explicit service invocation' in stdout
).lower())
print('AUTOMATIC_FAIL_OPEN_MILESTONE=' + str(
    'Cloudflare Route Fail Open verified by independent API readback' in stdout
).lower())

categories = [
    ('SYSTEMD_START', 'Cloudflare remediation start failed'),
    ('LOCAL_POLICY_ATTESTATION', 'local-only decision policy could not be proven'),
    ('WORKER_ALREADY_ACTIVE', 'remediation is already active'),
    ('SERVICE_BOOT_ENABLED', 'bouncer must remain disabled at boot'),
    ('ROUTE_NOT_CREATED', 'Worker Route not created before the bounded readiness deadline'),
    ('ROUTE_DUPLICATE', 'Multiple Cloudflare Worker Routes match'),
    ('PROVIDER_API_REQUEST', 'Worker Route API request failed'),
    ('PROVIDER_API_REJECTED', 'Worker Route API rejected the operation'),
    ('PROVIDER_API_FORMAT', 'Worker Route API returned'),
    ('ROUTE_OWNER_MISMATCH', 'Route pattern/script differs'),
    ('ROUTE_ID_CHANGED', 'Worker Route ID changed'),
    ('ROUTE_FAIL_OPEN_NOT_VERIFIED', 'did not independently report Fail Open=true'),
    ('CURRENT_INVOCATION_CHANGED', 'invocation or local-only source policy changed'),
    ('PROOF_PUBLISH_FAILURE', 'cannot persist CrowdSec Fail Open confirmation'),
    ('LAPI_OR_CREDENTIAL_PREPARATION', 'materialize CrowdSec Cloudflare remediation config'),
]
selected = [label for label, needle in categories if needle.lower() in stderr.lower()]
print('REARM_FAILURE_CATEGORY=' + (','.join(selected) if selected else 'UNCLASSIFIED'))
print('REARM_STDERR_PRESENT=' + str(bool(stderr.strip())).lower())
print('REARM_STDERR_SHA256_PREFIX=' + hashlib.sha256(stderr.encode()).hexdigest()[:12])

state = unit_state()
for k in ('LoadState', 'ActiveState', 'SubState', 'Result', 'UnitFileState',
          'MainPID', 'NRestarts', 'Restart', 'ExecMainStatus'):
    print('WORKER_' + k.upper() + '=' + state.get(k, 'unavailable'))
inv = state.get('InvocationID', '')
valid_inv = bool(re.fullmatch('[a-f0-9]{32}', inv))
print('WORKER_INVOCATION_VALID=' + str(valid_inv).lower())
print('WORKER_INVOCATION_CHANGED=' + str(valid_inv and inv != before['old_invocation']).lower())

sys.path.insert(0, '/opt/vaultwarden-oci/releases/0.1.0-rc.14')
from vaultwarden_oci import edge, crowdsec_worker_policy, cloudflare_route_mode as cf
paths = edge.EdgePaths()
if pathlib.Path(cf.__file__).resolve() != pathlib.Path(
    '/opt/vaultwarden-oci/releases/0.1.0-rc.14/vaultwarden_oci/cloudflare_route_mode.py'
):
    hold('Wrong immutable Cloudflare module')

active = state.get('ActiveState') == 'active' and state.get('MainPID') not in ('0', '', None)
policy = (
    crowdsec_worker_policy.runtime_policy_healthy(paths, edge.run_command)
    if active else False
)
local_confirm = (
    edge._fail_open_confirmed(paths.fail_open_confirmation, inv)
    if active and valid_inv else False
)
print('LOCAL_ONLY_INVOCATION_ATTESTATION=' + str(policy).lower())
print('LOCAL_FAIL_OPEN_RECEIPT_CURRENT=' + str(local_confirm).lower())

proof_route_id = None
try:
    fp = paths.fail_open_confirmation
    info = fp.lstat()
    if (stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode)
        and info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o600):
        receipt = json.loads(fp.read_text())
        if isinstance(receipt, dict) and receipt.get('verification') == 'cloudflare-api-readback':
            proof_route_id = receipt.get('route', {}).get('id')
except (OSError, ValueError, AttributeError, TypeError):
    pass
print('LOCAL_API_PROOF_PRESENT=' + str(bool(proof_route_id)).lower())

def provider_sample(index):
    try:
        domain, token, zone = cf._owned_route_context()
        base = cf.CLOUDFLARE_API + '/zones/' + zone + '/workers/routes'
        pattern = domain + '/*'
        rows = cf._owned_list(base, token)
        found = [r for r in rows if r.get('pattern') == pattern]
        print('CF_SAMPLE_' + str(index) + '_COUNT=' + str(len(found)))
        if len(found) != 1:
            print('CF_SAMPLE_' + str(index) + '_STATE=' + (
                'ABSENT' if not found else 'DUPLICATE'
            ))
            return 'absent' if not found else 'ambiguous'
        row = cf._validate_route(found[0], pattern=pattern)
        detail = cf._validate_route(
            cf._api_json(base + '/' + row['id'], token).get('result'),
            pattern=pattern, route_id=row['id']
        )
        mode = detail.get('request_limit_fail_open')
        print('CF_SAMPLE_' + str(index) + '_NEW_ROUTE=' +
              str(detail['id'] != before['old_route_id']).lower())
        print('CF_SAMPLE_' + str(index) + '_FAIL_OPEN=' +
              ('true' if mode is True else 'false' if mode is False else 'not-reported'))
        print('CF_SAMPLE_' + str(index) + '_MATCHES_LOCAL_API_PROOF=' +
              str(proof_route_id is not None and proof_route_id == detail['id']).lower())
        return 'true' if mode is True else 'false_or_unreported'
    except (edge.EdgeError, OSError, ValueError, TypeError, KeyError):
        print('CF_SAMPLE_' + str(index) + '_STATE=READ_FAILED')
        return 'unknown'

one = provider_sample(1)
time.sleep(3)
two = provider_sample(2)
if active and policy and local_confirm and one == two == 'true':
    print('DIAGNOSIS=WORKER_AND_PROVIDER_STABLE_CHECK_REARM_RECEIPT')
elif active:
    print('DIAGNOSIS=WORKER_ACTIVE_UNVERIFIED_DO_NOT_START_OR_STOP')
elif one == two == 'absent':
    print('DIAGNOSIS=WORKER_NOT_ACTIVE_ROUTE_ABSENT_REQUIRES_GUARDED_RECOVERY')
else:
    print('DIAGNOSIS=INCONSISTENT_STATE_REQUIRES_RECONCILIATION')
print('RC14_D_DIAG_EXIT=0 READ_ONLY_STATE_CAPTURED')
print('RC14_D_ACCEPTANCE=HOLD; REBOOT=NOT_AUTHORIZED; RELEASE_GO=HOLD')
PY_DIAG
then
  echo 'RC14_D_DIAG_WRAPPER_EXIT=0'
else
  rc=$?
  printf 'RC14_D_DIAG_WRAPPER_EXIT=2 HOLD: rc=%s; do not retry phase2\n' "$rc" >&2
  exit 2
fi
RC14_D_DIAG
