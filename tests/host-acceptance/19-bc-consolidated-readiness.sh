#!/usr/bin/env bash
# B/C readiness inventory AFTER A6. No service starts, timers, DNS, Box writes.
set -Eeuo pipefail
umask 077
BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
A6="$HOME/vwoci-acceptance/gate-a6-fast-20261030T223854Z"
BYID="/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628"
ALIAS="/dev/oracleoci/oraclevdb"
SERIAL="6015f8fecf5e4f7ab864af5a651cc628"
SIZE=53687091200
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
OUT="$HOME/vwoci-acceptance/gate-bc-readiness-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$OUT"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
chmod 600 "$SUMMARY"
say() { printf '%-8s %s\n' "$1" "$2" | tee -a "$SUMMARY"; }
block() { say BLOCKED "$*"; say "NOT RUN" "App start, timer, backup, DNS, reboot"; echo "Evidence: $OUT"; exit 1; }
[ "$#" -eq 0 ] || block "No arguments accepted"
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = vaultwarden-oci-5-vnic ] ||
  block "Wrong operator or disposable VM"
for t in git sudo python3 systemctl lsblk findmnt readlink grep cmp timeout; do
  command -v "$t" >/dev/null 2>&1 || block "Missing tool: $t"
done
sudo -n true >/dev/null 2>&1 || block "Passwordless sudo unavailable"
[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
  block "Wrong audit branch"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
  block "Uncommitted tracked source modifications"
git -C "$SOURCE" cat-file -e "$BASE^{commit}" 2>/dev/null ||
  block "Pinned original release missing"
git -C "$SOURCE" merge-base --is-ancestor "$BASE" HEAD ||
  block "Audit branch diverged from pinned release"
while IFS= read -r file; do
  case "$file" in
    docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md|tests/host-acceptance/*) ;;
    *) block "Original release runtime differs from approved source: $file" ;;
  esac
done < <(git -C "$SOURCE" diff --name-only "$BASE" HEAD)
[ "$(readlink -f /opt/vaultwarden-oci/current)" = /opt/vaultwarden-oci/releases/0.1.0-rc.11 ] ||
  block "Installed release is no longer approved rc.11"
[ -f "$A6/preflight.txt" ] && [ -f "$A6/postrestore.txt" ] ||
  block "A6 original acceptance evidence unavailable"
grep -Fq 'PASS: A6 pre-restore storage, original Age recipient and empty disposable data' \
  "$A6/preflight.txt" || block "A6 preflight not passed"
grep -Fq 'PASS: restored SQLite integrity and Vaultwarden/Caddy ownership' \
  "$A6/postrestore.txt" || block "A6 recovery postcheck not passed"
grep -Fq 'PASS: restored operational Age key/SOPS decrypt and original offline recipient' \
  "$A6/postrestore.txt" || block "A6 offline/operational Age custody postcheck not passed"
say PASS "A6 accepted, frozen release source and restoration evidence verified"

[ -L "$BYID" ] && [ -L "$ALIAS" ] || block "Known data disk aliases missing"
DEVICE="$(readlink -e "$BYID")" || block "Data disk alias invalid"
[ "$DEVICE" = "$(readlink -e "$ALIAS")" ] &&
  [ "$(lsblk -dn -o SERIAL "$DEVICE" | tr -d '[:space:]')" = "$SERIAL" ] &&
  [ "$(lsblk -bdn -o SIZE "$DEVICE" | tr -d '[:space:]')" = "$SIZE" ] &&
  [ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o SOURCE)" = "$DEVICE" ] &&
  [ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o FSTYPE)" = ext4 ] ||
  block "Selected OCI data disk/volume identity changed"

if ! sudo -n python3 -B -E - "$SOURCE" "$DEVICE" <<'PY' \
    > "$OUT/restored-readiness.txt" 2> "$OUT/readiness.private.stderr"
import hashlib, json, pathlib, sqlite3, sys, tomllib
sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import runtime, secrets, storage
device=pathlib.Path(sys.argv[2]).resolve(strict=True)
storage.reject_boot_related(str(device))
identity=storage.verify()
if identity.fs_type != "ext4" or pathlib.Path(identity.source).resolve(strict=True) != device:
    raise RuntimeError("dedicated volume marker mismatch")
with pathlib.Path("/etc/vaultwarden-oci/config.toml").open("rb") as f:
    config=tomllib.load(f)
if config["backup"]["remote"] != "bw-backup:bw-backup":
    raise RuntimeError("restored Box publication target differs")
if config["backup"]["local_retention_days"] != 0 or config["backup"]["remote_retention_days"] != 0:
    raise RuntimeError("unexpected automatic pruning policy")
recipient=config["secrets"]["offline_recovery_recipient"]
if hashlib.sha256(recipient.encode()).hexdigest() != "7d08721bcc02bbef7dae1f07bfde244852560c69d0b72f8dc0fcba0da30c6773":
    raise RuntimeError("offline recovery recipient changed")
with pathlib.Path("/var/lib/vaultwarden-oci/state/recovery.json").open() as f:
    record=json.load(f)["verified_objects"]["bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec"]
if record["sha256"] != "ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060":
    raise RuntimeError("Box verification record changed")
db=pathlib.Path("/var/lib/vaultwarden-oci/data/db.sqlite3")
con=sqlite3.connect("file:"+str(db)+"?mode=ro",uri=True,timeout=10)
try:
    if con.execute("PRAGMA integrity_check").fetchone()!=("ok",):
        raise RuntimeError("restored sqlite integrity invalid")
finally:
    con.close()
settings=runtime.load_config()
values=secrets.load(settings.offline_recovery_recipient)
def has(name): return isinstance(values.get(name),str) and bool(values[name])
print("storage_marker_and_sqlite=PASS")
print("source_Box_verification_record=PASS")
print("backup_remote=approved_existing_Box_folder")
print("local_retention_days=0")
print("remote_retention_days=0")
print("offline_and_operational_Age_custody=PASS")
for name in ("cloudflare_api_token","cloudflare_remediation_token","smtp_username","smtp_password","email_api_token"):
    print(name+"_present="+str(has(name)).lower())
print("notification_provider_configured="+str(settings.notification_provider is not None).lower())
print("site_domain=original_shared_hostname")
PY
then block "Protected data/credential/retention inspection failed (private stderr retained)"; fi
cat "$OUT/restored-readiness.txt" | tee -a "$SUMMARY"
say PASS "Source backup, protected custody, restored SQLite and zero retention verified"

for unit in vaultwarden-oci.target vaultwarden-oci.service \
  vaultwarden-oci-health.timer vaultwarden-oci-backup.timer \
  vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer \
  vaultwarden-oci-dns.service; do
  load="$(systemctl show -p LoadState --value "$unit")"
  active="$(systemctl show -p ActiveState --value "$unit")"
  state="$(systemctl show -p UnitFileState --value "$unit")"
  [ "$load" = loaded ] && [ "$active" = inactive ] ||
    block "Appliance unit missing/active unexpectedly: $unit"
  if [ "$unit" = vaultwarden-oci-dns.service ]; then
    [ "$state" = static ] || block "DNS one-shot is not static"
  else
    [ "$state" = disabled ] || block "Service/target/timer unexpectedly enabled: $unit"
  fi
  say INFO "unit=$unit active=$active file_state=$state"
done
sudo -n cmp -s /etc/systemd/system/vaultwarden-oci-backup.timer \
  /opt/vaultwarden-oci/current/systemd/vaultwarden-oci-backup.timer ||
  block "Installed backup timer differs from pinned release"
[ -z "$(systemctl show -p DropInPaths --value vaultwarden-oci-backup.timer)" ] ||
  block "Unexpected backup timer drop-in detected"
say PASS "All systemd units inactive/disabled, original backup calendar unchanged"

set +e
sudo -n timeout --kill-after=5s 120 /usr/local/bin/vwctl doctor --json \
  > "$OUT/doctor.private.json" 2> "$OUT/doctor.private.stderr"
doctor_rc=$?
set -e
say INFO "stopped_system_doctor_exit=$doctor_rc"
if [ "$doctor_rc" -eq 0 ] || [ "$doctor_rc" -eq 1 ]; then
  if ! python3 -B - "$OUT/doctor.private.json" <<'PY' \
      > "$OUT/doctor-summary.txt" 2> "$OUT/doctor-parse.private.stderr"
import json, sys
with open(sys.argv[1]) as f: data=json.load(f)
checks=data.get("checks",[])
if not isinstance(checks,list): raise ValueError("missing doctor checks")
print("doctor_overall="+str(data.get("overall","unknown")))
for check in checks:
    label, status=check.get("id"),check.get("status")
    if isinstance(label,str) and label.isascii() and all(c.isalnum() or c in "_-." for c in label) and status in ("PASS","WARN","FAIL","SKIP"):
        print("doctor="+label+" status="+status)
PY
  then
    say WARN "doctor JSON parse failed (private output retained)"
  else
    cat "$OUT/doctor-summary.txt" | tee -a "$SUMMARY"
  fi
else
  say WARN "doctor failed/timed out; inspect private evidence locally"
fi
for unit in crowdsec.service crowdsec-firewall-bouncer.service \
  crowdsec-cloudflare-worker-bouncer.service; do
  load="$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)"
  active="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)"
  say INFO "security_unit=$unit load=$load active=$active"
done
say HOLD "Public hostname is still shared; independently verify OCI NSG/public ingress isolation before startup"
say HOLD "Enabling vaultwarden-oci.target starts ALL four timers; activation requires separate approval"
say "NOT RUN" "App start, backup/timer execution, DNS writes, notifications, reboot, cutover"
printf 'Evidence: %s\n' "$OUT"
printf 'Share summary.txt and restored-readiness.txt only; raw doctor and stderr are PRIVATE.\n'
