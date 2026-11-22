# TEMPORARY RC15-G2B VM9 grouped acceptance harness. Delete from branch before merge.
# Runtime and provider mutations require fresh literal authorizations.
set -Eeuo pipefail
set +x
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0

SRC_PIN='162289365800ffe814517fbed920b5066cba4c33'
WORK="$HOME/VaultWarden-OCI-rc15g-g1a-${SRC_PIN:0:12}"
BASE="$HOME/vwoci-acceptance"
EVID="$BASE/rc15-g2b-$(date -u +%Y%m%dT%H%M%SZ)-$$"
HOST='bw.lazymocha.com'
UUID='0d043614-606c-4098-9617-1b1467155b6f'

hold() {
    printf 'RC15_G2B_EXIT=2 HOLD: %s\n' "$*" >&2
    if [ -n "${EVID:-}" ] && [ -d "$EVID" ]; then
        printf 'Private evidence: %s\n' "$EVID" >&2
    fi
    exit 2
}

[ "$(id -un)" = ubuntu ] &&
[ "$(hostname -s)" = vaultwarden-oci-9-vnic ] &&
[ "$(uname -m)" = aarch64 ] &&
[ -t 0 ] && [ -t 1 ] || hold 'Interactive private SSH on VM9 required'
sudo -n true || hold 'Passwordless sudo required'
[ -d "$WORK/.git" ] && [ -d "$BASE" ] && [ ! -L "$BASE" ] &&
[ "$(stat -c %a "$BASE")" = 700 ] &&
[ "$(stat -c %u "$BASE")" = "$(id -u)" ] || hold 'Source/evidence base missing or unsafe'
cd "$WORK"
[ "$(git --no-optional-locks rev-parse HEAD)" = "$SRC_PIN" ] || hold 'Pinned installed-source commit differs'
if ! STATUS="$(git --no-optional-locks status --porcelain --untracked-files=all 2>/dev/null)"; then
    hold 'Cannot prove Git cleanliness'
fi
[ -z "$STATUS" ] || hold 'Pinned source changed'
[ "$(git rev-parse HEAD:vaultwarden_oci/cloudflare_route_mode.py)" = 'a502a83610a8ff14ed73ce525c7f001ac8261216' ] || hold 'Route manager blob changed'
[ "$(git rev-parse HEAD:vaultwarden_oci/edge.py)" = 'afe6541769870ee47596c902d3515274157c4c9c' ] || hold 'Origin-policy blob changed'

if ! CONTAINERS="$(sudo -n docker ps -q)"; then
    hold 'Cannot read Docker container state'
fi
[ -z "$CONTAINERS" ] || hold 'Unexpected running containers on VM9'
if sudo -n systemctl is-active --quiet crowdsec-cloudflare-worker-bouncer.service; then
    hold 'Worker is already active; refuse ambiguous existing invocation'
fi
if sudo -n systemctl is-active --quiet vaultwarden-oci.target; then
    hold 'Application systemd target already active'
fi

mkdir -m 700 "$EVID"
HELPER="$EVID/cf_route_once.py"
trap 'rm -f -- "$HELPER"' EXIT
printf '%s\n' "$SRC_PIN" > "$EVID/installed-source.txt"

# Ephemeral helper: accepts no bearer token on argv/env; token stays in root memory.
cat > "$HELPER" <<'PY'
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, '/opt/vaultwarden-oci/current')
from vaultwarden_oci import cloudflare_route_mode as route_mode, dns_publication, edge, runtime, secrets, storage

API = 'https://api.cloudflare.com/client/v4'
HOST = 'bw.lazymocha.com'
UUID = '0d043614-606c-4098-9617-1b1467155b6f'
MAX = 65536

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

def hold(text):
    print('HOLD: ' + text)
    raise SystemExit(2)

def request(path, token, method='GET'):
    if not path.startswith(('/zones/', '/accounts/')) or method not in ('GET', 'DELETE'):
        hold('Unapproved API path or method')
    req = urllib.request.Request(API + path, method=method,
        headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/json'})
    try:
        with opener.open(req, timeout=12) as resp:
            body = resp.read(MAX + 1)
            status = resp.status
    except (OSError, urllib.error.HTTPError, urllib.error.URLError):
        hold('Cloudflare API request failed')
    if status != 200 or len(body) > MAX:
        hold('Unexpected Cloudflare API response')
    try:
        obj = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        hold('Invalid Cloudflare API JSON')
    if not isinstance(obj, dict) or obj.get('success') is not True:
        hold('Cloudflare API did not report success')
    return obj

def rows(doc):
    value = doc.get('result')
    info = doc.get('result_info', {})
    if not isinstance(value, list) or len(value) >= 100 or any(not isinstance(x, dict) for x in value):
        hold('Cloudflare listing incomplete or invalid')
    if isinstance(info, dict) and (info.get('total_pages', 1) != 1 or info.get('page', 1) != 1):
        hold('Cloudflare listing requires pagination')
    return value

def context():
    current = pathlib.Path('/opt/vaultwarden-oci/current')
    if not current.is_symlink() or current.resolve(strict=True) != pathlib.Path('/opt/vaultwarden-oci/releases/0.1.0-rc.15'):
        hold('Installed release changed')
    identity = storage.verify()
    if identity.uuid != UUID or identity.fs_type != 'ext4':
        hold('Dedicated data volume changed')
    cfg = runtime.load_config()
    if cfg.domain != HOST or cfg.acme_email != 'bw@lazymocha.com':
        hold('Configured site identity changed')
    if cfg.offsite_remote or cfg.local_retention_days != 0 or cfg.remote_retention_days != 0:
        hold('Recovery offsite/retention policy unexpectedly changed')
    creds = secrets.load(cfg.offline_recovery_recipient)
    token = creds.get('cloudflare_remediation_token')
    if not isinstance(token, str) or not token:
        hold('Cloudflare Worker credential missing')
    account, zone = edge.resolve_cloudflare_zone(cfg.domain, token)
    if not all(isinstance(x, str) and len(x) == 32 for x in (account, zone)):
        hold('Cloudflare account/zone identity malformed')
    state = dns_publication.status()
    if state.domain != HOST or not state.proxied:
        hold('Cloudflare DNS record not the expected proxied A-only shape')
    domain_rows = rows(request('/accounts/' + account + '/workers/domains?per_page=100', token))
    if any(not isinstance(x.get('hostname'), str) for x in domain_rows):
        hold('Worker Custom Domain inventory is malformed')
    if any(x['hostname'].lower() == HOST for x in domain_rows):
        hold('Worker Custom Domain overlaps the reserved hostname')
    return token, zone, state

def route_rows(token, zone):
    return rows(request('/zones/' + zone + '/workers/routes?per_page=100', token))

def old_route(token, zone):
    routes = route_rows(token, zone)
    if len(routes) != 1:
        hold('Expected exactly one remaining old Worker Route; no mutation')
    r = routes[0]
    rid = r.get('id')
    if not isinstance(rid, str) or not route_mode.ZONE_OR_ROUTE_ID.fullmatch(rid):
        hold('Worker Route ID invalid')
    if r.get('pattern') != HOST + '/*' or r.get('script') != route_mode.BOUNCER_SCRIPT:
        hold('Route pattern/script is not the exact retired project-owned one')
    exact = request('/zones/' + zone + '/workers/routes/' + rid, token).get('result')
    if not isinstance(exact, dict) or any(exact.get(k) != r.get(k) for k in ('id', 'pattern', 'script')):
        hold('Route detail differs from list')
    return rid

def main():
    if len(sys.argv) not in (2, 3):
        hold('Incorrect helper arguments')
    mode = sys.argv[1]
    token, zone, state = context()
    if mode == 'inspect' and len(sys.argv) == 2:
        rid = old_route(token, zone)
        if state.in_sync:
            hold('DNS was unexpectedly repointed to VM9 before ownership approval')
        print('PASS: Cloudflare DNS/Worker scopes independently rechecked')
        print('DNS_ORIGIN=DIFFERENT_ORIGIN')
        print('OLD_ROUTE_PATTERN=' + HOST + '/*')
        print('OLD_ROUTE_SCRIPT=' + route_mode.BOUNCER_SCRIPT)
        print('OLD_ROUTE_ID=' + rid)
        return
    if mode == 'delete' and len(sys.argv) == 3:
        expected_id = sys.argv[2]
        rid = old_route(token, zone)
        if rid != expected_id or state.in_sync:
            hold('Exact route or DNS origin changed before authorized deletion')
        response = request('/zones/' + zone + '/workers/routes/' + rid, token, 'DELETE').get('result')
        if not isinstance(response, dict) or response.get('id') != rid:
            hold('Cloudflare did not confirm deletion of exact route ID')
        # Readbacks only; never replay a DELETE.
        for check in range(12):
            remaining = route_rows(token, zone)
            if len(remaining) == 0:
                second = route_rows(token, zone)
                if len(second) == 0:
                    print('PASS: Exact stale Worker Route deleted; independent GET readbacks empty')
                    return
            if check != 11:
                time.sleep(2)
        hold('Cloudflare Route deletion response accepted, but independent readback is not empty')
    hold('Unapproved helper mode')

if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:
        hold('Unexpected preflight condition: ' + type(exc).__name__)
PY
chmod 600 "$HELPER"

echo '=== G2B: Exact provider/route read-only scope ==='
if ! sudo -n /usr/bin/python3 -B "$HELPER" inspect > "$EVID/cloudflare-before.txt" 2>&1; then
    grep -E '^(PASS|HOLD|DNS_ORIGIN|OLD_ROUTE_)' "$EVID/cloudflare-before.txt" || true
    hold 'Cloudflare route scope is not uniquely proven'
fi
cat "$EVID/cloudflare-before.txt"
ROUTE_ID="$(sed -n 's/^OLD_ROUTE_ID=//p' "$EVID/cloudflare-before.txt")"
[[ "$ROUTE_ID" =~ ^[0-9a-f]{32}$ ]] || hold 'Cannot independently extract route ID'

echo
echo '=== G2B: Independent old Route deletion authorization ==='
echo 'VM8 is operator-confirmed terminated. Only the exact old Route is targeted.'
echo 'No Worker script, Cloudflare DNS record, or other Route will be deleted.'
read -r -p "Type DELETE_STALE_ROUTE_${ROUTE_ID} to authorize one Cloudflare DELETE: " AUTH
[ "$AUTH" = "DELETE_STALE_ROUTE_${ROUTE_ID}" ] || hold 'Old Worker Route deletion declined'
if ! sudo -n /usr/bin/python3 -B "$HELPER" delete "$ROUTE_ID" > "$EVID/cloudflare-delete.txt" 2>&1; then
    grep -E '^(PASS|HOLD)' "$EVID/cloudflare-delete.txt" || true
    hold 'Old Route deletion/readback not independently proven; no automatic retry'
fi
cat "$EVID/cloudflare-delete.txt"

echo
echo '=== G2B: Separate host firewall/CrowdSec authorization ==='
echo 'This installs/configures CrowdSec, changes the VM9 host firewall and may affect SSH.'
echo 'Confirm private SSH and Console/serial recovery access before continuing.'
read -r -p 'Type AUTHORIZE_VM9_CROWDSEC_HOST_FIREWALL_SETUP: ' AUTH
[ "$AUTH" = AUTHORIZE_VM9_CROWDSEC_HOST_FIREWALL_SETUP ] || hold 'Host firewall setup not authorized'
if ! sudo -n vwctl crowdsec setup > "$EVID/crowdsec-setup.txt" 2>&1; then
    hold 'CrowdSec setup failed or partially applied; inspect protected evidence, do not retry automatically'
fi
echo 'PASS: Supported CrowdSec host/INPUT-only security setup'

echo
echo '=== G2B: Separate Cloudflare Worker + Fail Open authorization ==='
echo 'The product will start one boot-disabled Worker and create a fresh Route.'
echo 'Its opt-in Cloudflare API Fail Open field requires two fresh GET confirmations.'
read -r -p 'Type AUTHORIZE_VM9_WORKER_ROUTE_AND_AUTO_FAIL_OPEN: ' AUTH
[ "$AUTH" = AUTHORIZE_VM9_WORKER_ROUTE_AND_AUTO_FAIL_OPEN ] || hold 'Worker Route creation not authorized'
if ! sudo -n vwctl crowdsec remediation-start --auto-fail-open > "$EVID/worker-start.txt" 2>&1; then
    hold 'Worker/Route/Fail Open was not fully proven; do not restart or rearm automatically'
fi
echo 'PASS: Product attested current Worker invocation and API-readback Fail Open'

# This proof reads the current API Route rather than trusting a stale local receipt.
if ! sudo -n /usr/bin/python3 -B - > "$EVID/worker-readback.txt" 2>&1 <<'PY'
from vaultwarden_oci import cloudflare_route_mode as m
rid = m.read_owned_route_id(require_fail_open=True)
print('PASS: Fresh exact Worker Route ID and Fail Open readback: ' + rid[:8])
PY
then
    hold 'Independent current Worker Route readback failed'
fi
cat "$EVID/worker-readback.txt"

echo
echo '=== G2B: Separate first application start authorization ==='
echo 'The supported start will refresh BOTH iptables families before Docker 443 publication.'
echo 'It will start Caddy and Vaultwarden on VM9. DNS remains unchanged unless later authorized.'
read -r -p 'Type AUTHORIZE_VM9_SECURED_FIRST_START: ' AUTH
[ "$AUTH" = AUTHORIZE_VM9_SECURED_FIRST_START ] || hold 'First application start not authorized'
if ! sudo -n vwctl start > "$EVID/start.txt" 2>&1; then
    hold 'Supported first start failed; preserve live state, no automatic retries'
fi
echo 'PASS: Supported rc.15 secured first application start'

if ! sudo -n vwctl doctor --json > "$EVID/doctor.json" 2> "$EVID/doctor-stderr.txt"; then
    hold 'Doctor reported FAIL; preserve full protected diagnostics'
fi
if ! python3 -B - "$EVID/doctor.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    doc = json.load(f)
checks = doc.get('checks')
if not isinstance(checks, list):
    raise SystemExit('HOLD: doctor check list invalid')
by_id = {c.get('id'): c.get('status') for c in checks if isinstance(c, dict)}
need = (
    'edge.cloudflare.cidrs', 'edge.cloudflare.iptables',
    'crowdsec.engine', 'crowdsec.hub', 'crowdsec.firewall',
    'crowdsec.cloudflare', 'edge.caddy.health',
    'edge.caddy.trusted_proxy', 'edge.admin.protection', 'runtime.paths',
)
missing = [k for k in need if by_id.get(k) != 'PASS']
if missing or doc.get('overall') == 'FAIL' or any(x.get('status') == 'FAIL' for x in checks):
    print('HOLD: mandatory doctor PASS gates not met: ' + ','.join(missing))
    raise SystemExit(2)
print('PASS: All mandatory doctor edge/CrowdSec/runtime checks and zero FAIL')
print('DOCTOR_OVERALL=' + str(doc.get('overall')))
PY
then
    hold 'Doctor mandatory security gates unproven'
fi

for name in vaultwarden-oci-caddy vaultwarden-oci-vaultwarden; do
    if ! state="$(sudo -n docker inspect --format '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name")"; then
        hold "Cannot inspect expected container $name"
    fi
    case "$state" in running/healthy) echo "PASS: $name healthy" ;; *) hold "Container $name not healthy ($state)" ;; esac
done

for endpoint in / /api/config /admin/; do
    code="$(curl --noproxy '*' --silent --show-error --resolve "${HOST}:443:127.0.0.1" \
        --connect-timeout 10 --max-time 30 --output /dev/null --write-out '%{http_code}' \
        "https://${HOST}${endpoint}")" || hold "Verified local TLS request failed ($endpoint)"
    case "$endpoint:$code" in /:200|/api/config:200|/admin/:401) echo "PASS: Verified loopback TLS $endpoint -> $code" ;; *) hold "Unexpected local HTTPS status for $endpoint: $code" ;; esac
done

echo '=== G2B: Optional separately authorized test DNS A repoint ==='
echo 'Only the one existing PROXIED A-record content would change to VM9 public IPv4.'
echo 'This publishes VM9 to Cloudflare. No AAAA, new DNS record or historical Box object will be changed.'
read -r -p 'Type AUTHORIZE_VM9_TEST_DNS_A_REPOINT, or Enter to skip: ' AUTH
if [ "$AUTH" = AUTHORIZE_VM9_TEST_DNS_A_REPOINT ]; then
    if ! sudo -n vwctl dns update --dry-run > "$EVID/dns-dry-run.txt" 2>&1; then
        hold 'DNS dry run did not validate; no DNS write attempted'
    fi
    if ! sudo -n vwctl dns update > "$EVID/dns-write.txt" 2>&1; then
        hold 'DNS update failed or not proven; do not retry automatically'
    fi
    if ! sudo -n vwctl dns status > "$EVID/dns-status.txt" 2>&1; then
        hold 'Cloudflare DNS independent in-sync status unproven'
    fi
    echo 'PASS: Existing proxied A record repointed to VM9 and read back in sync'
    DNS='PASS'
else
    echo 'DNS_REPOINT=NOT_RUN (operator declined)'
    DNS='NOT_RUN'
fi

# No cron/timers/remote backup/restore, no teardown of the working appliance.
echo
echo 'RC15_G2B_EXIT=0 SECURE_LOCAL_START_AND_ROUTE_PASS'
echo "DNS_REPOINT=$DNS"
echo 'EXTERNAL_ORIGIN_DENIAL=NOT_RUN'
echo 'PUBLIC_SSH22_HTTP80_OCI_RULES=NOT_VERIFIED'
echo 'REMOTE_RECOVERY=NOT_RUN; RELEASE_GO=HOLD'
echo "Private evidence: $EVID"