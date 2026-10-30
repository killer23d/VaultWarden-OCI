#!/usr/bin/env bash
# Gate B1: one-shot DEV Worker + Fail Open + app/Caddy + DNS + offsite backup
# + arm timers, on accepted disposable OCI host only. NEVER reboot/format/prune.
# Requires independent operator authorizations for each external side effect.
set -Eeuo pipefail
umask 077

BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
RELEASE="0.1.0-rc.11"
HOST="vaultwarden-oci-5-vnic"
DOMAIN="bw.lazymocha.com"
SERIAL="6015f8fecf5e4f7ab864af5a51a1051440"
# The actual OCI stable disk serial on this acceptance host:
SERIAL="6015f8fecf5e4f7ab864af5a651cc628"
BYID="/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628"
ALIAS="/dev/oracleoci/oraclevdb"
DISK_BYTES=53687091200
REMOTE="bw-backup:bw-backup"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
B0="$HOME/vwoci-acceptance/gate-b0-security-foundation-20261030T225335Z/summary.txt"
OUT="$HOME/vwoci-acceptance/gate-b1-dev-operating-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$OUT"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
chmod 600 "$SUMMARY"
MUTATED=0
say() { printf '%-8s %s\n' "$1" "$2" | tee -a "$SUMMARY"; }
block() {
    say BLOCKED "$*"
    if [ "$MUTATED" -eq 1 ]; then
        say HOLD "This gate modified dev Cloudflare/app/cloud state. Do not rerun blindly; inspect state first."
    fi
    say "NOT RUN" "Reboot, release upgrade, production cutover, automatic retention/pruning"
    printf 'Evidence: %s\n' "$OUT"
    exit 1
}
[ "$#" -eq 0 ] || block "No command arguments accepted"
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = "$HOST" ] ||
    block "Wrong user or disposable acceptance host"
[ -t 0 ] && [ -t 1 ] && [ -r /dev/tty ] ||
    block "Interactive terminal required for explicit Cloudflare, backup and timers consent"
for t in git sudo python3 sha256sum lsblk findmnt readlink systemctl grep \
    docker timeout cat tr; do
    command -v "$t" >/dev/null 2>&1 || block "Missing tool: $t"
done
sudo -n true >/dev/null 2>&1 || block "Noninteractive sudo unavailable"
[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
    block "Wrong audit branch"
git -C "$SOURCE" cat-file -e "$BASE^{commit}" 2>/dev/null ||
    block "Pinned original rc.11 source missing"
git -C "$SOURCE" merge-base --is-ancestor "$BASE" HEAD ||
    block "Audit branch does not descend from frozen original release"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
    block "Uncommitted tracked checkout modifications"
while IFS= read -r file; do
    case "$file" in
        docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md|tests/host-acceptance/*) ;;
        *) block "Release-owned runtime changed from pinned rc.11: $file" ;;
    esac
done < <(git -C "$SOURCE" diff --name-only "$BASE" HEAD)
[ "$(readlink -f /opt/vaultwarden-oci/current)" = "/opt/vaultwarden-oci/releases/$RELEASE" ] ||
    block "Installed appliance no longer the frozen rc.11"
[ -f "$B0" ] && [ ! -L "$B0" ] ||
    block "Successful foundational B0 evidence missing"
grep -Fq 'foundation_ready=PASS' "$B0" ||
    block "B0 foundational security PASS evidence absent"
grep -Fq 'PASS     Cloudflare Worker remains explicitly disabled/inactive' "$B0" ||
    block "B0 Cloudflare Worker safety evidence absent"
[ -L "$BYID" ] && [ -L "$ALIAS" ] || block "Approved data volume aliases absent"
DEVICE="$(readlink -e "$BYID")" || block "Data disk not resolved"
[ "$DEVICE" = "$(readlink -e "$ALIAS")" ] &&
    [ "$(lsblk -dn -o SERIAL "$DEVICE" | tr -d '[:space:]')" = "$SERIAL" ] &&
    [ "$(lsblk -bdn -o SIZE "$DEVICE" | tr -d '[:space:]')" = "$DISK_BYTES" ] &&
    [ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o SOURCE)" = "$DEVICE" ] &&
    [ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o FSTYPE)" = ext4 ] ||
    block "Exact approved data volume/marker boundary changed"
if ! sudo -n python3 -B -E - "$SOURCE" "$DEVICE" "$DOMAIN" "$REMOTE" \
    > "$OUT/preflight.private.txt" 2>&1 <<'PY'
import pathlib, sqlite3, sys, tomllib
sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import secrets, storage
storage.reject_boot_related(sys.argv[2])
identity=storage.verify()
if identity.fs_type != "ext4" or pathlib.Path(identity.source).resolve(strict=True) != pathlib.Path(sys.argv[2]).resolve(strict=True):
    raise RuntimeError("wrong data volume")
with open("/etc/vaultwarden-oci/config.toml","rb") as f:
    cfg=tomllib.load(f)
if cfg["site"]["domain"] != sys.argv[3] or cfg["backup"]["remote"] != sys.argv[4]:
    raise RuntimeError("approved dev hostname or backup destination changed")
if cfg["backup"]["local_retention_days"] or cfg["backup"]["remote_retention_days"]:
    raise RuntimeError("automatic backup pruning is enabled")
recipient=cfg["secrets"]["offline_recovery_recipient"]
if recipient != "age1z7tqg4zrlnul8kang4lny9405elnya5nh3rt3dk440s766rf8assh33sku":
    raise RuntimeError("offline recipient changed")
if recipient not in secrets.encrypted_recipients(pathlib.Path("/etc/vaultwarden-oci/secrets.sops.yaml")):
    raise RuntimeError("offline recipient no longer in encrypted secrets")
db=pathlib.Path("/var/lib/vaultwarden-oci/data/db.sqlite3")
with sqlite3.connect("file:"+str(db)+"?mode=ro",uri=True,timeout=15) as connection:
    if connection.execute("PRAGMA integrity_check").fetchone()!=("ok",):
        raise RuntimeError("restored sqlite integrity failed")
PY
then block "Source data/recipient/retention preflight failed; private log available"; fi
for unit in vaultwarden-oci.target vaultwarden-oci.service \
    vaultwarden-oci-backup.timer vaultwarden-oci-health.timer \
    vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer \
    vaultwarden-oci-dns.service; do
    [ "$(systemctl show -p ActiveState --value "$unit")" = inactive ] ||
        block "Unexpected pre-existing app/timer: $unit"
done
WORKER="crowdsec-cloudflare-worker-bouncer.service"
[ "$(systemctl show -p ActiveState --value "$WORKER")" = inactive ] &&
    [ "$(systemctl show -p UnitFileState --value "$WORKER")" = disabled ] ||
    block "Cloudflare Worker is already active or boot-enabled"
say PASS "Accepted B0 state, exact dev domain, retention zero, pinned rc.11 and data disk"
say INFO "Read-only Cloudflare DNS preview and root Box destination diagnostics"
if ! sudo -n /usr/local/bin/vwctl dns update --dry-run \
    > "$OUT/dns-preview.private.txt" 2>&1; then
    block "Cloudflare record/zone permissions or DNS preview failed"
fi
if ! sudo -n /usr/local/bin/vwctl recovery offsite status \
    > "$OUT/offsite-private.txt" 2>&1; then
    block "Root rclone remote or configured offsite folder unavailable"
fi
say PASS "Cloudflare DNS dry-run and existing Box destination diagnostics succeeded"

printf '\n============================================================\n'
printf 'B1: DEVELOPMENT HOST OPERATING ACCEPTANCE\n'
printf 'Hostname: %s\n' "$DOMAIN"
printf 'TEST VM: %s; data volume serial: %s\n' "$HOST" "$SERIAL"
printf 'Cloudflare is AUTHORIZED as a development environment.\n'
printf 'This gate WILL create/modify Worker Routes and certificate DNS TXT\n'
printf 'records; it will later PATCH the proxied A record to this test VM\n'
printf 'if you explicitly approve the separate publication prompt.\n'
printf 'You MUST inspect and set EVERY current Worker Route to FAIL OPEN.\n'
printf 'It will create one new, immutable encrypted Box backup in %s,\n' "$REMOTE"
printf 'and arm the four normal systemd timers only with separate consent.\n'
printf 'Retention 0/0 means NO AUTOMATIC PRUNING. Reboot is NOT authorized.\n'
printf 'Do not rerun this gate after any partial mutation without review.\n'
printf '============================================================\n'
EXPECTED="ACTIVATE DEV $DOMAIN"
printf 'Type exactly %s to authorize Cloudflare Worker route changes:\n' "$EXPECTED"
IFS= read -r -p "Authorization: " CONFIRM </dev/tty ||
    block "Cloudflare Worker route mutation not authorized"
[ "$CONFIRM" = "$EXPECTED" ] ||
    block "Dev Cloudflare Worker mutation not authorized"

MUTATED=1
say INFO "Starting current dev CrowdSec Worker invocation; route changes may affect dev traffic"
if ! sudo -n /usr/local/bin/vwctl crowdsec remediation-start \
    > "$OUT/worker-start.private.txt" 2>&1; then
    block "Product dev Worker remediation-start failed; do not retry blindly"
fi
say PASS "Supported current CrowdSec Worker invocation started"
printf '\nACTION REQUIRED IN CLOUDFLARE DASHBOARD\n'
printf 'Find EVERY Worker Route created for %s/* by this current\n' "$DOMAIN"
printf 'CrowdSec invocation. Set failure behavior to FAIL OPEN on each route.\n'
printf 'Verify the saved Route settings and that this is the development zone.\n'
printf 'Do not assume historical Fail Open settings survived this invocation.\n'
printf '============================================================\n'
REQUIRED="ALL DEV WORKER ROUTES FAIL OPEN"
printf 'Type exactly %s only AFTER verifying the current routes:\n' "$REQUIRED"
IFS= read -r -p "Cloudflare route confirmation: " CONFIRM </dev/tty ||
    block "Fail Open confirmation not supplied"
[ "$CONFIRM" = "$REQUIRED" ] ||
    block "Current Cloudflare Worker Routes not attested Fail Open"
if ! sudo -n /usr/local/bin/vwctl crowdsec confirm-fail-open \
    > "$OUT/worker-attest.private.txt" 2>&1; then
    block "Product could not attest current Worker invocation"
fi
say PASS "Operator-attested current Dev Worker Routes Fail Open"

# Before starting Caddy, prove all six foundational security checks, including
# current-invocation Worker, pass even while the runtime has not been rendered.
if ! sudo -n /usr/local/bin/vwctl doctor --json \
    > "$OUT/doctor-prestart.private.json" 2> "$OUT/doctor-prestart.private.stderr"; then :; fi
if ! python3 -B - "$OUT/doctor-prestart.private.json" <<'PY' > "$OUT/security-prestart.txt" 2> "$OUT/security-prestart.private.stderr"
import json,sys
with open(sys.argv[1]) as f: d=json.load(f)
rows={c.get("id"):c.get("status") for c in d.get("checks",[]) if isinstance(c,dict)}
required=("edge.cloudflare.cidrs","edge.cloudflare.iptables","crowdsec.engine",
          "crowdsec.hub","crowdsec.firewall","crowdsec.cloudflare")
for key in required:
    print("security_prestart="+key+" status="+str(rows.get(key,"MISSING")))
if any(rows.get(key)!="PASS" for key in required):
    raise SystemExit(1)
PY
then
    cat "$OUT/security-prestart.txt" | tee -a "$SUMMARY"
    block "All six security check IDs must pass before Caddy start"
fi
cat "$OUT/security-prestart.txt" | tee -a "$SUMMARY"
say PASS "All foundational and dev Cloudflare Worker security IDs PASS"

printf '\nBeginning supported first start; Caddy may build and request a\n'
printf 'Cloudflare DNS-01 certificate using the approved development zone.\n'
printf 'Detailed build output is private; the command is synchronous.\n'
if ! sudo -n /usr/local/bin/vwctl start \
    > "$OUT/first-start.private.log" 2>&1; then
    block "Installed rc.11 product start failed; do not rerun until private log reviewed"
fi
say PASS "Supported first-start command returned success"

if ! sudo -n /usr/local/bin/vwctl doctor --json \
    > "$OUT/doctor-running.private.json" 2> "$OUT/doctor-running.private.stderr"; then :; fi
if ! python3 -B - "$OUT/doctor-running.private.json" <<'PY' > "$OUT/health.txt" 2> "$OUT/health.private.stderr"
import json,sys
with open(sys.argv[1]) as f: d=json.load(f)
rows={c.get("id"):c.get("status") for c in d.get("checks",[]) if isinstance(c,dict)}
required=("host.os","host.architecture","runtime.docker","runtime.compose","runtime.paths",
          "storage.dedicated","secrets.custody","secrets.decrypt",
          "edge.caddy.trusted_proxy","edge.admin.protection","edge.caddy.health",
          "edge.cloudflare.cidrs","edge.cloudflare.iptables",
          "crowdsec.engine","crowdsec.hub","crowdsec.firewall","crowdsec.cloudflare")
for key in required:
    print("running_check="+key+" status="+str(rows.get(key,"MISSING")))
if any(rows.get(key)!="PASS" for key in required):
    raise SystemExit(1)
print("running_critical_health=PASS")
PY
then
    cat "$OUT/health.txt" | tee -a "$SUMMARY"
    block "A required running-state security/runtime doctor ID FAILED"
fi
cat "$OUT/health.txt" | tee -a "$SUMMARY"
say PASS "Running Vaultwarden/Caddy, guarded origin, credentials and CrowdSec doctor checks PASS"

EXPECTED="PUBLISH DEV DNS $DOMAIN"
printf '\nCloudflare A record currently resolves via the previously approved dev zone.\n'
printf 'Type exactly %s to PATCH it to this test VM if needed.\n' "$EXPECTED"
IFS= read -r -p "DNS publication authorization: " CONFIRM </dev/tty ||
    block "Dev DNS change not approved; app running, DNS unchanged"
[ "$CONFIRM" = "$EXPECTED" ] ||
    block "Dev DNS publication not authorized; app running, DNS unchanged"
if ! sudo -n /usr/local/bin/vwctl dns update \
    > "$OUT/dns-write.private.txt" 2>&1; then
    block "Authorized dev DNS publication failed; inspect private evidence"
fi
say PASS "Supported dev DNS sync succeeded (may have been already in sync)"

EXPECTED="PUBLISH DEV BACKUP $REMOTE"
printf '\nOne new encrypted recovery point will be created and published to\n'
printf '%s, with SHA-256 remote readback and ZERO retention.\n' "$REMOTE"
printf 'Type exactly %s to authorize Box object creation:\n' "$EXPECTED"
IFS= read -r -p "Box backup authorization: " CONFIRM </dev/tty ||
    block "New Box recovery object not authorized"
[ "$CONFIRM" = "$EXPECTED" ] ||
    block "New Box recovery object not authorized"
if ! sudo -n /usr/local/bin/vwctl backup \
    > "$OUT/manual-backup.private.txt" 2>&1; then
    block "Product backup or Box readback failed; preserve existing remote history"
fi
grep -Fq 'PASS: offsite publication was remotely re-downloaded and checksum-verified' \
    "$OUT/manual-backup.private.txt" ||
    block "Product did not report verified remote Box publication"
say PASS "Actual local encrypted backup and immutable Box publication/readback PASS"

EXPECTED="ENABLE DEV TIMERS $SERIAL"
printf '\nEnabling vaultwarden-oci.target starts application lifecycle AND all\n'
printf 'four scheduled timers; health.timer will invoke DNS reconciliation.\n'
printf 'The development hostname and Box destination are approved above.\n'
printf 'Type exactly %s to authorize unattended DEV automation:\n' "$EXPECTED"
IFS= read -r -p "Timer activation authorization: " CONFIRM </dev/tty ||
    block "Dev timer automation not approved"
[ "$CONFIRM" = "$EXPECTED" ] ||
    block "Dev timer automation not approved"
if ! sudo -n systemctl enable --now vaultwarden-oci.target \
    > "$OUT/enable-target.private.txt" 2>&1; then
    block "Systemd target enable/start failed; partial automation state requires inspection"
fi
for unit in vaultwarden-oci.target vaultwarden-oci.service \
    vaultwarden-oci-health.timer vaultwarden-oci-backup.timer \
    vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer; do
    active="$(systemctl show -p ActiveState --value "$unit")"
    enabled="$(systemctl show -p UnitFileState --value "$unit")"
    [ "$active" = active ] ||
        block "Expected enabled DEV target/timer is not active: $unit"
    [ "$enabled" = enabled ] ||
        block "DEV target/timer does not report persistent enablement: $unit"
    say INFO "enabled_unit=$unit active=$active persistent=$enabled"
done
[ "$(systemctl show -p UnitFileState --value "$WORKER")" = disabled ] ||
    block "Worker bouncer unexpectedly boot-enabled; must remain explicit"
say PASS "DEV lifecycle target and all four normal systemd timers active/enabled"

if ! sudo -n /usr/local/bin/vwctl doctor --json \
    > "$OUT/doctor-final.private.json" 2> "$OUT/doctor-final.private.stderr"; then :; fi
if ! python3 -B - "$OUT/doctor-final.private.json" <<'PY' > "$OUT/doctor-final-summary.txt" 2> "$OUT/doctor-final-parse.private.stderr"
import json,sys
with open(sys.argv[1]) as f: d=json.load(f)
checks=d.get("checks",[])
failures=[c.get("id") for c in checks if isinstance(c,dict) and c.get("status")=="FAIL"]
print("doctor_overall="+str(d.get("overall","MISSING")))
print("doctor_failure_count="+str(len(failures)))
for name in failures:
    print("doctor_failure_id="+str(name))
if failures:
    raise SystemExit(1)
PY
then
    cat "$OUT/doctor-final-summary.txt" | tee -a "$SUMMARY"
    block "Final doctor contains FAIL; do not reboot or re-run B1"
fi
cat "$OUT/doctor-final-summary.txt" | tee -a "$SUMMARY"
say PASS "B1: dev Worker Fail Open, running appliance, DNS, cloud backup and automation armed"
say "NOT RUN" "Actual unmodified scheduled 03:15 timer firing, reboot persistence, rollback or release rc.12 install"
say INFO "The backup.timer being ACTIVE does not by itself prove that a scheduled firing occurred"
printf 'Evidence: %s\n' "$OUT"
printf 'Share summary.txt, health.txt, doctor-final-summary.txt only. ALL *.private.* logs remain private.\n'
