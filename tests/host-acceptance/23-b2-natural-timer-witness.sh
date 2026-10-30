#!/usr/bin/env bash
# B2: a read-only witness of the actual original backup.timer firing.
# No service starts, timer overrides, downloads, cloud writes or reboot.
set -Eeuo pipefail
umask 077
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
B1="$HOME/vwoci-acceptance/gate-b1-dev-operating-20261030T232046Z/summary.txt"
OUT="$HOME/vwoci-acceptance/gate-b2-natural-timer-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$OUT"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
chmod 600 "$SUMMARY"
say() { printf '%-8s %s\n' "$1" "$2" | tee -a "$SUMMARY"; }
fail() { say BLOCKED "$*"; echo "Evidence: $OUT"; exit 1; }
pending() { say PENDING "$*"; echo "Evidence: $OUT"; exit 2; }
[ "$#" -eq 0 ] || fail "This witness takes no arguments"
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = vaultwarden-oci-5-vnic ] ||
    fail "Wrong operator or host"
sudo -n true >/dev/null 2>&1 || fail "Passwordless sudo unavailable"
[ "$(git -C "$ROOT" branch --show-current)" = "$BRANCH" ] &&
    [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] ||
    fail "Wrong branch or dirty audit checkout"
[ "$(readlink -f /opt/vaultwarden-oci/current)" = /opt/vaultwarden-oci/releases/0.1.0-rc.11 ] ||
    fail "Wrong installed release"
[ -f "$B1" ] &&
    grep -Fq 'PASS     B1: dev Worker Fail Open, running appliance, DNS, cloud backup and automation armed' "$B1" ||
    fail "B1 approval/evidence absent"
TIMER=vaultwarden-oci-backup.timer
UNIT=vaultwarden-oci-backup.service
sudo -n cmp -s /etc/systemd/system/"$TIMER" \
    /opt/vaultwarden-oci/current/systemd/"$TIMER" ||
    fail "Packaged timer changed"
[ -z "$(systemctl show -p DropInPaths --value "$TIMER")" ] ||
    fail "Timer has unapproved unit overrides"
[ "$(systemctl show -p ActiveState --value "$TIMER")" = active ] &&
    [ "$(systemctl show -p ActiveState --value vaultwarden-oci.target)" = active ] &&
    [ "$(systemctl show -p UnitFileState --value vaultwarden-oci.target)" = enabled ] ||
    fail "Backup timer/target disabled or inactive"
say PASS "Original daily 03:15 timer, service and enabled lifecycle are unchanged"

LAST="$(systemctl show -p LastTriggerUSec --value "$TIMER")"
NEXT="$(systemctl show -p NextElapseUSecRealtime --value "$TIMER")"
say INFO "next_original_timer=$NEXT"
case "$LAST" in ""|n/a|N/A|0|"-") pending "Daily timer has not fired yet" ;; esac
LAST_EPOCH="$(date -d "$LAST" -u '+%s' 2>/dev/null)" ||
    fail "LastTriggerUSec cannot be parsed"
AFTER="$(date -d '2026-10-30T23:20:46Z' -u '+%s')"
[ "$LAST_EPOCH" -gt "$AFTER" ] ||
    pending "Last genuine timer firing predates B1 activation"
say INFO "last_timer_trigger=$LAST"
say PASS "systemd timer LastTriggerUSec is after B1"

[ "$(systemctl show -p Result --value "$UNIT")" = success ] &&
    [ "$(systemctl show -p ExecMainStatus --value "$UNIT")" = 0 ] ||
    fail "Backup service result/exit not successful"
SINCE="$(date -u -d "@$((LAST_EPOCH - 30))" '+%Y-%m-%d %H:%M:%S UTC')"
sudo -n journalctl -u "$UNIT" --since "$SINCE" --output=cat \
    --no-pager > "$OUT/backup-journal.private.txt" 2> "$OUT/journal.private.stderr" ||
    fail "Cannot inspect scheduled service journal"
grep -Fq 'PASS: verified local recovery ' "$OUT/backup-journal.private.txt" ||
    fail "Scheduled service did not report local cryptographic verification"
grep -Fq 'PASS: offsite publication was remotely re-downloaded and checksum-verified' \
    "$OUT/backup-journal.private.txt" ||
    fail "Scheduled service did not report successful Box readback"
say PASS "Original systemd backup service succeeded; local ciphertext and Box readback verified"

sudo -n python3 -B -E - <<'PY' > "$OUT/retention.private.txt" || fail "Backup pruning policy changed"
import tomllib
from vaultwarden_oci import storage
storage.verify()
with open("/etc/vaultwarden-oci/config.toml","rb") as stream:
    backup=tomllib.load(stream)["backup"]
if backup["remote"]!="bw-backup:bw-backup" or backup["local_retention_days"] or backup["remote_retention_days"]:
    raise SystemExit("unexpected backup destination or retention")
print("retention_0_0=PASS")
PY
say PASS "Scheduled publication retained approved zero-pruning policy"
say PASS "B2 natural calendar timer execution accepted"
say "NOT RUN" "Restore, reboot, release upgrade, cloud write from this audit"
echo "Evidence: $OUT"
echo "Share summary.txt only; scheduled backup logs are private."
