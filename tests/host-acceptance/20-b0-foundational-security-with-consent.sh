#!/usr/bin/env bash
# Gate B0: security foundation only, on the named DISPOSABLE recovery VM.
# Changes local iptables DOCKER-USER Cloudflare-443 filter and installs/starts
# CrowdSec engine + host-INPUT bouncer. Requires explicit console-access assent.
# DOES NOT call CrowdSec Cloudflare Worker remediation-start, DNS update,
# Vaultwarden start, backup, timer enable, reboot or any cloud-object write.
set -Eeuo pipefail
umask 077

BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
HOST="vaultwarden-oci-5-vnic"
RELEASE="0.1.0-rc.11"
BYID="/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628"
ALIAS="/dev/oracleoci/oraclevdb"
SERIAL="6015f8fecf5e4f7ab864af5a651cc628"
DISK_BYTES="53687091200"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
PRIOR="$HOME/vwoci-acceptance/gate-bc-readiness-20261030T224330Z"
OUT="$HOME/vwoci-acceptance/gate-b0-security-foundation-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$OUT"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
chmod 600 "$SUMMARY"
MUTATION_STARTED=0

report() { printf '%-8s %s\n' "$1" "$2" | tee -a "$SUMMARY"; }
blocked() {
    report BLOCKED "$*"
    if [ "$MUTATION_STARTED" -eq 1 ]; then
        report HOLD "Do not retry or run broad firewall cleanup; partial CrowdSec/firewall state needs review"
    fi
    report "NOT RUN" "Cloudflare Worker, DNS write, Vaultwarden start, backup/timer activation, reboot"
    printf 'Evidence: %s\n' "$OUT"
    exit 1
}
[ "$#" -eq 0 ] || blocked "No arguments supported"
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = "$HOST" ] ||
    blocked "Wrong user or disposable recovery VM"
[ -t 0 ] && [ -t 1 ] && [ -r /dev/tty ] ||
    blocked "Interactive operator console required"
for cmd in git sudo python3 sha256sum lsblk findmnt readlink systemctl grep \
    cat tr timeout; do
    command -v "$cmd" >/dev/null 2>&1 || blocked "Required tool missing: $cmd"
done
sudo -n true >/dev/null 2>&1 || blocked "Passwordless sudo unavailable"

[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
    blocked "Wrong audit branch"
git -C "$SOURCE" cat-file -e "$BASE^{commit}" 2>/dev/null ||
    blocked "Frozen release commit unavailable"
git -C "$SOURCE" merge-base --is-ancestor "$BASE" HEAD ||
    blocked "Audit checkout diverged from frozen source"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
    blocked "Tracked checkout changes present"
while IFS= read -r file; do
    case "$file" in
        docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md|tests/host-acceptance/*) ;;
        *) blocked "Release runtime modified relative to approved rc.11: $file" ;;
    esac
done < <(git -C "$SOURCE" diff --name-only "$BASE" HEAD)
[ "$(readlink -f /opt/vaultwarden-oci/current)" = \
    "/opt/vaultwarden-oci/releases/$RELEASE" ] ||
    blocked "Wrong installed release"

[ -f "$PRIOR/summary.txt" ] && [ ! -L "$PRIOR/summary.txt" ] ||
    blocked "Approved B/C readiness evidence missing"
grep -Fq 'PASS     Source backup, protected custody, restored SQLite and zero retention verified' \
    "$PRIOR/summary.txt" || blocked "B/C readiness did not pass restored-state safeguards"
grep -Fq 'PASS     All systemd units inactive/disabled, original backup calendar unchanged' \
    "$PRIOR/summary.txt" || blocked "B/C readiness did not establish dormant app/timer boundary"

[ -L "$BYID" ] && [ -L "$ALIAS" ] ||
    blocked "Approved OCI disk aliases absent"
DEVICE="$(readlink -e "$BYID")" || blocked "Approved OCI volume cannot be resolved"
[ "$DEVICE" = "$(readlink -e "$ALIAS")" ] &&
    [ "$(lsblk -dn -o SERIAL "$DEVICE" | tr -d '[:space:]')" = "$SERIAL" ] &&
    [ "$(lsblk -bdn -o SIZE "$DEVICE" | tr -d '[:space:]')" = "$DISK_BYTES" ] &&
    [ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o SOURCE)" = "$DEVICE" ] &&
    [ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o FSTYPE)" = ext4 ] ||
    blocked "Data-volume identity/serial/mount changed"

if ! sudo -n python3 -B -E - "$SOURCE" "$DEVICE" > "$OUT/preflight.private.txt" 2>&1 <<'PY'
import hashlib, json, pathlib, sqlite3, sys, tomllib
sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import secrets, storage
device = pathlib.Path(sys.argv[2]).resolve(strict=True)
storage.reject_boot_related(str(device))
identity=storage.verify()
if identity.fs_type != "ext4" or pathlib.Path(identity.source).resolve(strict=True) != device:
    raise RuntimeError("storage identity mismatch")
with open("/etc/vaultwarden-oci/config.toml","rb") as f:
    config=tomllib.load(f)
backup=config["backup"]
if (backup["remote"] != "bw-backup:bw-backup"
    or backup["local_retention_days"] != 0
    or backup["remote_retention_days"] != 0):
    raise RuntimeError("approved offsite/retention policy changed")
recipient=config["secrets"]["offline_recovery_recipient"]
if hashlib.sha256(recipient.encode()).hexdigest() != "7d08721bcc02bbef7dae1f07bfde244852560c69d0b72f8dc0fcba0da30c6773":
    raise RuntimeError("offline recipient changed")
if recipient not in secrets.encrypted_recipients(pathlib.Path("/etc/vaultwarden-oci/secrets.sops.yaml")):
    raise RuntimeError("SOPS offline recipient missing")
db=pathlib.Path("/var/lib/vaultwarden-oci/data/db.sqlite3")
connection=sqlite3.connect("file:"+str(db)+"?mode=ro",uri=True,timeout=10)
try:
    if connection.execute("PRAGMA integrity_check").fetchone()!=("ok",):
        raise RuntimeError("restored DB corrupt")
finally:
    connection.close()
PY
then blocked "Restored storage/backup/recipient/SQLite invariants failed"; fi

for unit in vaultwarden-oci.target vaultwarden-oci.service \
    vaultwarden-oci-backup.timer vaultwarden-oci-health.timer \
    vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer \
    vaultwarden-oci-dns.service; do
    active="$(systemctl show -p ActiveState --value "$unit")"
    enabled="$(systemctl show -p UnitFileState --value "$unit")"
    [ "$active" = inactive ] || blocked "Appliance unit already active: $unit"
    case "$unit" in
        vaultwarden-oci-dns.service)
            [ "$enabled" = static ] || blocked "DNS unit unexpectedly modified" ;;
        *)
            [ "$enabled" = disabled ] || blocked "App/automation already enabled: $unit" ;;
    esac
done
worker_unit="crowdsec-cloudflare-worker-bouncer.service"
worker_active="$(systemctl show -p ActiveState --value "$worker_unit" 2>/dev/null || true)"
[ "$worker_active" != active ] ||
    blocked "Cloudflare Worker is already active: do not affect production routes"

report PASS "Original rc.11, accepted A6+B/C state, disk, backup and inactive automation verified"
printf '\n============================================================\n'
printf 'SECURITY FOUNDATION: DISPOSABLE VM ONLY\n'
printf 'This modifies the TEST HOST (not production):\n'
printf ' - Install/apply Cloudflare-only Docker 443 ingress filter\n'
printf ' - Install CrowdSec engine and host-INPUT-only firewall bouncer\n'
printf ' - Enable/start CrowdSec engine and host firewall bouncer\n'
printf '\nPotential risk: host firewall decisions can affect SSH access.\n'
printf 'You must have working OCI serial/console recovery access first.\n'
printf 'No Cloudflare Worker routes, Cloudflare DNS writes, Caddy start,\n'
printf 'application timers, remote backups, pruning or reboot are authorized.\n'
printf 'The production Cloudflare hostname remains SHARED with this VM.\n'
printf '============================================================\n'
REQUIRED="SECURITY FOUNDATION TEST VM $SERIAL"
printf 'Type EXACTLY to confirm test-host firewall changes and OCI console access:\n%s\n' "$REQUIRED"
IFS= read -r -p "Authorization: " CONFIRM </dev/tty ||
    blocked "Firewall/package modification not authorized"
[ "$CONFIRM" = "$REQUIRED" ] ||
    blocked "Explicit security-foundation authorization not granted"

MUTATION_STARTED=1
report INFO "Refreshing Cloudflare IP policy and Docker 443 firewall on TEST VM; log private"
if sudo -n timeout --signal=TERM --kill-after=10s 180 \
    /usr/local/bin/vwctl edge refresh \
    > "$OUT/edge-refresh.private.log" 2>&1; then
    report PASS "Cloudflare-only Docker 443 origin policy refreshed"
else
    rc=$?
    blocked "Origin firewall refresh failed (exit $rc); inspect private log"
fi

report INFO "Installing CrowdSec engine/host firewall using product setup; no Worker start"
if sudo -n /usr/local/bin/vwctl crowdsec setup \
    > "$OUT/crowdsec-setup.private.log" 2>&1; then
    report PASS "Product-owned CrowdSec foundational setup completed"
else
    rc=$?
    blocked "CrowdSec setup failed (exit $rc); preserve partial host state"
fi

active="$(systemctl show -p ActiveState --value "$worker_unit" 2>/dev/null || true)"
enabled="$(systemctl show -p UnitFileState --value "$worker_unit" 2>/dev/null || true)"
[ "$active" = inactive ] && [ "$enabled" = disabled ] ||
    blocked "Cloudflare Worker unexpectedly activated/enabled ($active/$enabled)"
report PASS "Cloudflare Worker remains explicitly disabled/inactive (NO production route changes)"

for unit in vaultwarden-oci.target vaultwarden-oci.service \
    vaultwarden-oci-backup.timer vaultwarden-oci-health.timer \
    vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer \
    vaultwarden-oci-dns.service; do
    active="$(systemctl show -p ActiveState --value "$unit")"
    [ "$active" = inactive ] ||
        blocked "Appliance or timer unexpectedly activated: $unit"
done
report PASS "Vaultwarden/Caddy/DNS/timer activation not performed"

set +e
sudo -n timeout --kill-after=5s 120 /usr/local/bin/vwctl doctor --json \
    > "$OUT/doctor.private.json" 2> "$OUT/doctor.private.stderr"
doctor_rc=$?
set -e
if [ "$doctor_rc" -ne 0 ] && [ "$doctor_rc" -ne 1 ]; then
    blocked "Doctor did not complete after setup (exit $doctor_rc)"
fi
if ! python3 -B - "$OUT/doctor.private.json" <<'PY' > "$OUT/foundation-checks.txt" 2> "$OUT/doctor-parse.private.stderr"
import json,sys
with open(sys.argv[1]) as stream: data=json.load(stream)
rows={x.get("id"):x.get("status") for x in data.get("checks",[]) if isinstance(x,dict)}
required=("edge.cloudflare.cidrs","edge.cloudflare.iptables",
          "crowdsec.engine","crowdsec.hub","crowdsec.firewall")
for name in required:
    value=rows.get(name,"MISSING")
    print("foundation_check="+name+" status="+value)
if any(rows.get(key)!="PASS" for key in required):
    raise SystemExit(1)
print("cloudflare_worker_check="+str(rows.get("crowdsec.cloudflare","MISSING")))
print("runtime_paths_check="+str(rows.get("runtime.paths","MISSING")))
runtime=next((x for x in data.get("checks",[]) if isinstance(x,dict) and x.get("id")=="runtime.paths"),{})
message=str(runtime.get("message","")).lower()
if rows.get("runtime.paths")=="PASS":
    reason="none"
elif "only partially materialized" in message:
    reason="incomplete_prestart_runtime"
elif "missing directory" in message:
    reason="missing_directory"
elif "missing file" in message:
    reason="missing_file"
elif "incompatible ownership/mode" in message:
    reason="ownership_or_mode"
elif "service identity" in message or "uid" in message or "gid" in message:
    reason="service_identity"
else:
    reason="unclassified_private_detail"
print("runtime_paths_reason_category="+reason)
print("foundation_ready=PASS")
PY
then
    cat "$OUT/foundation-checks.txt" | tee -a "$SUMMARY"
    blocked "One or more foundational edge/CrowdSec checks failed; no Worker or app start"
fi
cat "$OUT/foundation-checks.txt" | tee -a "$SUMMARY"
report PASS "Cloudflare origin + CrowdSec engine/Hub/INPUT firewall checks passed"
report HOLD "Cloudflare Worker remediation-start is forbidden on a shared production hostname"
report HOLD "Cloudflare worker needs a segregated test hostname/token or deliberate production cutover"
report HOLD "runtime.paths may remain incomplete until legitimate first start"
report "NOT RUN" "Worker remediation, Cloudflare DNS, Vaultwarden/Caddy start, timer, Box write, reboot"
printf 'Evidence: %s\n' "$OUT"
printf 'Share summary.txt only. All *.private.* logs and JSON are operator-private.\n'
