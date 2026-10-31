#!/usr/bin/env bash
# C1: two-phase DEV reboot acceptance (pre / post), with optional actual email.
# PRE reuses a validated same-boot checkpoint and reboots only the approved disposable VM.
# POST verifies a different boot ID, unchanged disk/recovery authority, automatic
# application startup, then requires fresh manual Fail Open for the Worker.
# No disk formatting, restore, DNS publication command, backup job, or timer edits.
set -Eeuo pipefail
umask 077

BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
HOST="vaultwarden-oci-5-vnic"
DOMAIN="bw.lazymocha.com"
SERIAL="6015f8fecf5e4f7ab864af5a651cc628"
BYID="/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628"
ALIAS="/dev/oracleoci/oraclevdb"
SIZE=53687091200
B1="$HOME/vwoci-acceptance/gate-b1-dev-operating-20261030T232046Z/summary.txt"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
ROOT="$HOME/vwoci-acceptance"
POINTER="$ROOT/current-c1-reboot-evidence"
OUT=""
PHASE=""

report() { printf '%-8s %s\n' "$1" "$2" | tee -a "$OUT/summary.txt"; }
blocked() {
    report BLOCKED "$*"
    report HOLD "Preserve existing live state. Do not rerun a completed reboot or Worker activation."
    printf 'Evidence: %s\n' "$OUT"
    exit 1
}
[ "$#" -eq 1 ] && { [ "$1" = pre ] || [ "$1" = post ]; } || {
    echo "BLOCKED: usage: $0 {pre|post}"
    exit 1
}
PHASE="$1"
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = "$HOST" ] || {
    echo "BLOCKED: wrong user or disposable VM"
    exit 1
}
for t in git sudo python3 sha256sum lsblk findmnt readlink systemctl grep \
    docker timeout cat tr sleep; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "BLOCKED: required command unavailable: $t"; exit 1;
    }
done
sudo -n true >/dev/null 2>&1 || { echo "BLOCKED: sudo -n unavailable"; exit 1; }

REUSING=0
if [ "$PHASE" = pre ]; then
    if [ -e "$POINTER" ] || [ -L "$POINTER" ]; then
        [ -f "$POINTER" ] && [ ! -L "$POINTER" ] || {
            echo "BLOCKED: existing C1 pointer unsafe"; exit 1;
        }
        IFS= read -r OUT < "$POINTER"
        case "$OUT" in "$ROOT"/gate-c1-dev-reboot-*) ;; *)
            echo "BLOCKED: unexpected saved C1 evidence path"; exit 1 ;;
        esac
        [ -d "$OUT" ] && [ ! -L "$OUT" ] &&
        [ -f "$OUT/baseline.json" ] && [ ! -L "$OUT/baseline.json" ] &&
        [ -f "$OUT/summary.txt" ] && [ ! -L "$OUT/summary.txt" ] || {
            echo "BLOCKED: existing C1 checkpoint incomplete"; exit 1;
        }
        grep -Fq 'PASS     Protected persistent Age/SOPS/config and pre-reboot kernel boot ID recorded' "$OUT/summary.txt" || {
            echo "BLOCKED: previous C1 baseline lacks a PASS record"; exit 1;
        }
        REUSING=1
    else
        OUT="$ROOT/gate-c1-dev-reboot-$(date -u +%Y%m%dT%H%M%SZ)"
        mkdir -m 700 "$OUT"
    fi
else
    [ -f "$POINTER" ] && [ ! -L "$POINTER" ] || {
        echo "BLOCKED: C1 reboot evidence pointer absent or symlink"
        exit 1
    }
    IFS= read -r OUT < "$POINTER"
    case "$OUT" in "$ROOT"/gate-c1-dev-reboot-*) ;; *)
        echo "BLOCKED: unexpected C1 evidence directory pointer"; exit 1 ;;
    esac
    [ -d "$OUT" ] && [ ! -L "$OUT" ] && [ -f "$OUT/baseline.json" ] &&
        [ ! -L "$OUT/baseline.json" ] || {
        echo "BLOCKED: original C1 baseline directory unavailable"; exit 1;
    }
fi
touch "$OUT/summary.txt"
chmod 600 "$OUT/summary.txt"

[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
    blocked "unexpected audit checkout"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
    blocked "uncommitted source modifications"
git -C "$SOURCE" cat-file -e "$BASE^{commit}" 2>/dev/null ||
    blocked "frozen rc.11 source commit absent"
git -C "$SOURCE" merge-base --is-ancestor "$BASE" HEAD ||
    blocked "source not descended from accepted rc.11"
while IFS= read -r file; do
    case "$file" in
        docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md|tests/host-acceptance/*) ;;
        *) blocked "release product runtime was edited: $file" ;;
    esac
done < <(git -C "$SOURCE" diff --name-only "$BASE" HEAD)
[ "$(readlink -f /opt/vaultwarden-oci/current)" = \
    "/opt/vaultwarden-oci/releases/0.1.0-rc.11" ] ||
    blocked "installed release changed unexpectedly"
[ -L "$BYID" ] && [ -L "$ALIAS" ] ||
    blocked "approved disk aliases unavailable"
DEVICE="$(readlink -e "$BYID")" || blocked "approved disk does not resolve"
[ "$DEVICE" = "$(readlink -e "$ALIAS")" ] &&
    [ "$(lsblk -dn -o SERIAL "$DEVICE" | tr -d '[:space:]')" = "$SERIAL" ] &&
    [ "$(lsblk -bdn -o SIZE "$DEVICE" | tr -d '[:space:]')" = "$SIZE" ] &&
    [ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o SOURCE)" = "$DEVICE" ] &&
    [ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o FSTYPE)" = ext4 ] ||
    blocked "selected data volume, filesystem or serial changed"
[ -f "$B1" ] && [ ! -L "$B1" ] ||
    blocked "completed B1 evidence unavailable"
for expected in \
    'PASS     B1: dev Worker Fail Open, running appliance, DNS, cloud backup and automation armed' \
    'PASS     All foundational and dev Cloudflare Worker security IDs PASS' \
    'PASS     Running Vaultwarden/Caddy, guarded origin, credentials and CrowdSec doctor checks PASS'; do
    grep -Fq "$expected" "$B1" || blocked "B1 operating gate no longer has approved PASS evidence"
done

if [ "$PHASE" = pre ]; then
    for unit in vaultwarden-oci.target vaultwarden-oci.service \
        vaultwarden-oci-health.timer vaultwarden-oci-backup.timer \
        vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer \
        crowdsec.service crowdsec-firewall-bouncer.service \
        crowdsec-cloudflare-worker-bouncer.service; do
        [ "$(systemctl show -p ActiveState --value "$unit")" = active ] ||
            blocked "required running dev unit unexpectedly not active: $unit"
    done
    [ "$(systemctl show -p UnitFileState --value vaultwarden-oci.target)" = enabled ] ||
        blocked "dev lifecycle target is not enabled for reboot"
    [ "$(systemctl show -p UnitFileState --value crowdsec-cloudflare-worker-bouncer.service)" = disabled ] ||
        blocked "Worker must stay boot-disabled; manual re-authorization required"
    if ! sudo -n /usr/local/bin/vwctl doctor --json \
        > "$OUT/pre-doctor.private.json" 2> "$OUT/pre-doctor.private.stderr"; then
        blocked "doctor not clean before reboot"
    fi
    if ! python3 -B - "$OUT/pre-doctor.private.json" <<'PY' > "$OUT/pre-doctor-check.txt"
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("overall") == "PASS"
assert not [c for c in d.get("checks",[]) if c.get("status") == "FAIL"]
print("pre_reboot_doctor=PASS")
PY
    then blocked "doctor has failures before reboot"; fi

    BASELINE_OUTPUT="$OUT/baseline.json"
    if [ "$REUSING" -eq 1 ]; then
        BASELINE_OUTPUT="$OUT/baseline-resume-check.json"
    fi
    if ! sudo -n python3 -B -E - "$SOURCE" > "$BASELINE_OUTPUT" \
        2> "$OUT/baseline.private.stderr" <<'PY'
import hashlib,json,pathlib,sqlite3,sys,tomllib
sys.path.insert(0,sys.argv[1])
from vaultwarden_oci import secrets,storage
storage.verify()
with pathlib.Path("/etc/vaultwarden-oci/config.toml").open("rb") as f: config=tomllib.load(f)
if config["site"]["domain"]!="bw.lazymocha.com":
    raise RuntimeError("dev hostname mismatch")
if config["backup"]["remote"]!="bw-backup:bw-backup" or config["backup"]["local_retention_days"] or config["backup"]["remote_retention_days"]:
    raise RuntimeError("backup destination or zero retention changed")
rec=config["secrets"]["offline_recovery_recipient"]
if rec!="age1z7tqg4zrlnul8kang4lny9405elnya5nh3rt3dk440s766rf8assh33sku":
    raise RuntimeError("offline recipient changed")
secrets.validate_custody(rec)
secrets.decrypt()
db="/var/lib/vaultwarden-oci/data/db.sqlite3"
con=sqlite3.connect("file:"+db+"?mode=ro",uri=True,timeout=15)
try:
    if con.execute("PRAGMA quick_check").fetchone()!=("ok",):
        raise RuntimeError("SQLite quick check failed")
finally:
    con.close()
protected=("/etc/vaultwarden-oci/config.toml",
"/etc/vaultwarden-oci/secrets.sops.yaml",
"/etc/vaultwarden-oci/age-key.txt",
"/etc/vaultwarden-oci/storage-identity.json")
files={}
for name in protected:
    with open(name,"rb") as f:
        files[name]=hashlib.file_digest(f,"sha256").hexdigest()
print(json.dumps({"schema":1,"boot_id":pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
                  "release":"0.1.0-rc.11","files_sha256":files},sort_keys=True))
PY
    then blocked "cannot capture immutable ownership and boot baseline"; fi
    if [ "$REUSING" -eq 1 ]; then
        if ! python3 -B - "$OUT/baseline.json" "$BASELINE_OUTPUT" <<'PY'
import json,sys
with open(sys.argv[1]) as original, open(sys.argv[2]) as now:
    before, current=json.load(original),json.load(now)
if before != current or before.get("schema")!=1:
    raise SystemExit("BLOCKED: existing C1 authority or boot ID changed; do not reboot")
print("PASS: existing C1 checkpoint and current boot match exactly")
PY
        then blocked "prior C1 checkpoint cannot safely be reused"; fi
    fi
    report PASS "B1 runtime, CrowdSec/Worker, doctor, backup policy and enabled target are valid"
    report PASS "Protected persistent Age/SOPS/config and pre-reboot kernel boot ID recorded"
    report INFO "Reboot will be test-host only; original app/Box objects kept; no release changes"
    printf '\nGATE C1: DEVELOPMENT REBOOT ACCEPTANCE\n'
    printf 'This action will immediately reboot %s and disconnect SSH.\n' "$HOST"
    printf 'Systemd target WILL boot-start Vaultwarden/Caddy and four timers.\n'
    printf 'The Cloudflare Worker is intentionally DISABLED at boot.\n'
    printf 'After reconnecting, run THIS script with post to manually re-arm\n'
    printf 'the Worker and attest NEW Fail Open Cloudflare Routes.\n'
    printf 'Before re-arm, health checks can be degraded and failure alerts may fire.\n'
    printf 'Use OCI console access if network access does not return.\n'
    printf 'No rc.12 update, disk format or destructive restore is performed.\n'
    # The operator opted out of redundant consent for this exact disposable VM.
    # Record the pointer only when a full fresh preflight has passed.
    if [ "$REUSING" -eq 0 ]; then
        printf '%s\n' "$OUT" > "$POINTER"
        chmod 600 "$POINTER"
    fi
    report INFO "Rebooting the approved disposable VM with preserved C1 evidence"
    printf 'Evidence: %s\n' "$OUT"
    printf 'After SSH returns, run: bash %s post\n' "$0"
    sudo -n systemctl reboot || blocked "systemctl reboot was rejected"
    exit 0
fi

# post phase: refuse same boot; operator must intentionally reconnect.
if ! sudo -n python3 -B -E - "$OUT/baseline.json" "$SOURCE" > "$OUT/post-baseline.txt" \
    2> "$OUT/post-baseline.private.stderr" <<'PY'
import hashlib,json,pathlib,sqlite3,sys,tomllib
sys.path.insert(0,sys.argv[2])
from vaultwarden_oci import secrets,storage
baseline=json.load(open(sys.argv[1]))
if baseline.get("schema")!=1 or baseline.get("release")!="0.1.0-rc.11":
    raise RuntimeError("invalid stored baseline")
current=pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip()
if not baseline["boot_id"] or baseline["boot_id"]==current:
    raise RuntimeError("kernel boot ID unchanged; reboot not proven")
storage.verify()
for name,old in baseline["files_sha256"].items():
    if name not in ("/etc/vaultwarden-oci/config.toml","/etc/vaultwarden-oci/secrets.sops.yaml",
                    "/etc/vaultwarden-oci/age-key.txt","/etc/vaultwarden-oci/storage-identity.json"):
        raise RuntimeError("unexpected tracked authority file")
    with open(name,"rb") as f:
        if hashlib.file_digest(f,"sha256").hexdigest()!=old:
            raise RuntimeError("persistent application authority changed on reboot")
with open("/etc/vaultwarden-oci/config.toml","rb") as f: cfg=tomllib.load(f)
if cfg["site"]["domain"]!="bw.lazymocha.com" or cfg["backup"]["remote"]!="bw-backup:bw-backup" or cfg["backup"]["local_retention_days"] or cfg["backup"]["remote_retention_days"]:
    raise RuntimeError("restored dev config/retention changed")
recipient=cfg["secrets"]["offline_recovery_recipient"]
secrets.validate_custody(recipient)
secrets.decrypt()
db="/var/lib/vaultwarden-oci/data/db.sqlite3"
with sqlite3.connect("file:"+db+"?mode=ro",uri=True,timeout=15) as conn:
    if conn.execute("PRAGMA quick_check").fetchone()!=("ok",):
        raise RuntimeError("SQLite quick check failed")
print("different_kernel_boot_id=PASS")
print("persistent_config_sops_operational_Age_storage_marker=UNCHANGED")
print("restored_SQLite_quick_check=PASS")
print("Box_destination_and_zero_retention=PASS")
PY
then blocked "reboot or persistent authority proof failed"; fi
cat "$OUT/post-baseline.txt" | tee -a "$OUT/summary.txt"
report PASS "Actual kernel reboot completed; original encrypted custody and SQLite intact"

# A service may still be settling from the automatic enabled-target lifecycle.
report INFO "Checking boot-started Docker/Caddy/Vaultwarden and target; no automatic repair"
boot_ready=0
for (( attempt=1; attempt<=60; attempt++ )); do
    if [ "$(systemctl show -p ActiveState --value vaultwarden-oci.target)" = active ] &&
       [ "$(systemctl show -p ActiveState --value vaultwarden-oci.service)" = active ] &&
       sudo -n docker inspect --format '{{.State.Health.Status}}' vaultwarden-oci-vaultwarden \
           > "$OUT/docker-wait.private.txt" 2>&1; then
        if grep -Fqx healthy "$OUT/docker-wait.private.txt"; then
            boot_ready=1
            break
        fi
    fi
    if [ $((attempt % 6)) -eq 0 ]; then
        report INFO "Waiting for genuine post-boot service health (attempt $attempt of 60)"
    fi
    sleep 10
done
[ "$boot_ready" -eq 1 ] || blocked "automatic target/Vaultwarden start did not become healthy after reboot"
[ "$(systemctl show -p UnitFileState --value vaultwarden-oci.target)" = enabled ] ||
    blocked "lifecycle target lost persistent boot enablement"
for unit in vaultwarden-oci-health.timer vaultwarden-oci-backup.timer \
    vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer; do
    [ "$(systemctl show -p ActiveState --value "$unit")" = active ] ||
        blocked "original timer did not rearm on reboot: $unit"
done
for unit in crowdsec.service crowdsec-firewall-bouncer.service; do
    [ "$(systemctl show -p ActiveState --value "$unit")" = active ] ||
        blocked "CrowdSec engine or INPUT host bouncer did not persist across reboot: $unit"
done
WORKER="crowdsec-cloudflare-worker-bouncer.service"
[ "$(systemctl show -p UnitFileState --value "$WORKER")" = disabled ] &&
    [ "$(systemctl show -p ActiveState --value "$WORKER")" = inactive ] ||
    blocked "Cloudflare Worker must remain boot-disabled and inactive until explicit re-arm"
report PASS "Boot lifecycle, Vaultwarden health, four timers, CrowdSec engine and host firewall persisted"
report PASS "Cloudflare Worker remained intentionally disabled/inactive after boot"

# The sole expected pre-rearm FAIL is the Worker which requires manual action.
set +e
sudo -n /usr/local/bin/vwctl doctor --json \
    > "$OUT/doctor-pre-rearm.private.json" 2> "$OUT/doctor-pre-rearm.private.stderr"
doctor_rc=$?
set -e
[ "$doctor_rc" -eq 0 ] || [ "$doctor_rc" -eq 1 ] ||
    blocked "Doctor failed unexpectedly before Worker re-arm"
if ! python3 -B - "$OUT/doctor-pre-rearm.private.json" <<'PY' \
    > "$OUT/expected-worker-gap.txt" 2> "$OUT/expected-worker-gap.private.stderr"
import json,sys
d=json.load(open(sys.argv[1]))
fails={c.get("id") for c in d.get("checks",[]) if isinstance(c,dict) and c.get("status")=="FAIL"}
print("pre_worker_rearm_failure_ids="+",".join(sorted(str(i) for i in fails)))
if fails!={"crowdsec.cloudflare"}:
    raise SystemExit(1)
print("all_other_doctor_checks=PASS_OR_NONFAIL")
PY
then
    cat "$OUT/expected-worker-gap.txt" | tee -a "$OUT/summary.txt"
    blocked "Non-Worker doctor failure after boot; inspect before rearm"
fi
cat "$OUT/expected-worker-gap.txt" | tee -a "$OUT/summary.txt"
report PASS "Expected manual Cloudflare Worker re-arm requirement isolated after actual reboot"

printf '\nWORKER RE-ARM (NEW SYSTEMD INVOCATION)\n'
printf 'The worker was deliberately boot-disabled. Re-arming can recreate\n'
printf 'Cloudflare Worker Routes for the APPROVED DEVELOPMENT hostname %s.\n' "$DOMAIN"
printf 'You must inspect and set all newly affected Routes to FAIL OPEN again.\n'
report INFO "Starting the approved dev Worker after exact-host reboot validation"
if ! sudo -n /usr/local/bin/vwctl crowdsec remediation-start \
    > "$OUT/worker-rearm.private.txt" 2>&1; then
    blocked "current-invocation Cloudflare Worker re-arm failed"
fi
report PASS "New dev CrowdSec Worker invocation started after cold reboot"
printf '\nACTION REQUIRED: Check EVERY current CrowdSec Worker Route for %s/*\n' "$DOMAIN"
printf 'in Cloudflare. Set and SAVE failure behavior to FAIL OPEN for this invocation.\n'
printf 'After verifying every current dev Worker Route is Fail Open, press ENTER: '
IFS= read -r response </dev/tty || blocked "Fail Open manual verification unfinished"
[ -z "$response" ] || blocked "Expected ENTER after confirming the Fail Open settings"
if ! sudo -n /usr/local/bin/vwctl crowdsec confirm-fail-open \
    > "$OUT/rearm-attest.private.txt" 2>&1; then
    blocked "product refused current-invocation Fail Open attestation"
fi
report PASS "All newly recreated dev Worker Routes manually attested Fail Open"

if ! sudo -n /usr/local/bin/vwctl doctor --json \
    > "$OUT/post-doctor.private.json" 2> "$OUT/post-doctor.private.stderr"; then
    blocked "Doctor not healthy after Worker re-arm"
fi
if ! python3 -B - "$OUT/post-doctor.private.json" <<'PY' > "$OUT/post-doctor-summary.txt"
import json,sys
d=json.load(open(sys.argv[1]))
fails=[c.get("id") for c in d.get("checks",[]) if isinstance(c,dict) and c.get("status")=="FAIL"]
print("post_reboot_doctor_overall="+str(d.get("overall")))
print("post_reboot_doctor_failures="+str(len(fails)))
if d.get("overall")!="PASS" or fails:
    raise SystemExit(1)
print("all_security_runtime_storage_checks=PASS")
PY
then blocked "Doctor JSON not clean after reboot and Worker re-arm"; fi
cat "$OUT/post-doctor-summary.txt" | tee -a "$OUT/summary.txt"
# A five-minute health job might have fired before the deliberately manual
# Worker re-arm; wait for the real recurring timer to clear the stale result.
timer_healthy=0
for (( check=1; check<=42; check++ )); do
    if sudo -n /usr/local/bin/vwctl timers --json \
        > "$OUT/timers.private.json" 2> "$OUT/timers.private.stderr"; then
        timer_healthy=1
        break
    fi
    if [ $((check % 6)) -eq 0 ]; then
        report INFO "Waiting for genuine health-timer retry after Worker re-arm ($check/42)"
    fi
    sleep 10
done
[ "$timer_healthy" -eq 1 ] ||
    blocked "The timer/service result remains unhealthy after genuine post-boot retries"
if ! python3 -B - "$OUT/timers.private.json" <<'PY' > "$OUT/timer-summary.txt"
import json,sys
d=json.load(open(sys.argv[1]))
if d.get("overall")!="PASS" or d.get("target",{}).get("health")!="PASS":
    raise SystemExit(1)
timers=d.get("timers",[])
expected={"vaultwarden-oci-health.timer","vaultwarden-oci-backup.timer",
          "vaultwarden-oci-maintenance.timer","vaultwarden-oci-update-check.timer"}
if {x.get("unit") for x in timers}!=expected or any(x.get("health")!="PASS" for x in timers):
    raise SystemExit(1)
print("boot_rearmed_original_four_timers=PASS")
print("boot_lifecycle_target_persisted=PASS")
PY
then blocked "Original boot timer target unhealthy"; fi
cat "$OUT/timer-summary.txt" | tee -a "$OUT/summary.txt"
report PASS "C1: actual reboot, restored state, boot startup, worker re-arm and doctor fully passed"

printf '\nOPTIONAL REAL EMAIL DELIVERY ACCEPTANCE\n'
printf 'This sends one operational HTTPS-provider test email AND one direct\n'
printf 'authenticated SMTP test to the configured dev appliance recipient.\n'
printf 'This is an external message-delivery action, not a dry-run.\n'
printf 'Type SEND DEV EMAIL TESTS to authorize both emails, otherwise press Enter to skip: '
IFS= read -r response </dev/tty || blocked "terminal unavailable for optional email decision"
if [ "$response" = "SEND DEV EMAIL TESTS" ]; then
    if ! sudo -n /usr/local/bin/vwctl notification test \
        > "$OUT/notification-route.private.txt" 2>&1; then
        blocked "Operational email delivery was not accepted"
    fi
    grep -Eq '^PASS: route=[A-Za-z0-9_-]+ category=[A-Za-z0-9_-]+$' \
        "$OUT/notification-route.private.txt" ||
        blocked "Notification routing reported ambiguous success"
    report PASS "Real dev HTTPS operational notification accepted"
    if ! sudo -n /usr/local/bin/vwctl notification test --smtp \
        > "$OUT/notification-smtp.private.txt" 2>&1; then
        blocked "Direct authenticated TLS SMTP was not accepted"
    fi
    grep -Eq '^PASS: direct SMTP category=[A-Za-z0-9_-]+' \
        "$OUT/notification-smtp.private.txt" ||
        blocked "Direct SMTP reported ambiguous success"
    report PASS "Real dev direct authenticated TLS SMTP accepted"
else
    report "NOT RUN" "Notification delivery (operator did not authorize outbound emails)"
fi
report "NOT RUN" "Next natural 03:15 scheduled backup firing, rc.12 clean install, production cutover"
printf 'Evidence: %s\n' "$OUT"
printf 'Share summary.txt and post-doctor-summary.txt only; all *.private.* evidence remains private.\n'
