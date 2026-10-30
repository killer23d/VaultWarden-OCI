#!/usr/bin/env bash
# Gate A1: exact selected-volume, non-mutating setup dry-run on a fresh host.
# This stage NEVER formats, mounts, installs, restores, changes DNS, or uses real Age custody.
set -Eeuo pipefail
umask 077

BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="$HOME/vwoci-acceptance/gate-a1-selected-disk-dryrun-$STAMP"
SUMMARY="$EVDIR/summary.txt"

mkdir -p "$EVDIR"
chmod 700 "$HOME/vwoci-acceptance" "$EVDIR"
: > "$SUMMARY"
chmod 600 "$SUMMARY"

say() { printf '%-8s %s\n' "$1" "$2" | tee -a "$SUMMARY"; }
stop() {
    say "$1" "$2"
    say "NOT RUN" "Disk provisioning, installation, backup retrieval, restore or DNS cutover"
    printf 'Evidence: %s\n' "$EVDIR"
    exit 1
}

[ "$#" -eq 2 ] ||
    stop BLOCKED "Usage: $0 /dev/disk/by-id/<exact-identifier> <expected-size-bytes>"

DATA_BY_ID="$1"
EXPECTED_BYTES="$2"
[ "$(id -u)" -ne 0 ] || stop BLOCKED "Run as the normal SSH user, not root"
case "$DATA_BY_ID" in
    /dev/disk/by-id/*) ;;
    *) stop BLOCKED "Require a stable /dev/disk/by-id/ device path" ;;
esac
[ "$(dirname -- "$DATA_BY_ID")" = /dev/disk/by-id ] ||
    stop BLOCKED "The device must be a direct /dev/disk/by-id/ entry"
[[ "$EXPECTED_BYTES" =~ ^[1-9][0-9]*$ ]] ||
    stop BLOCKED "Expected size must be an exact positive integer in bytes"
for bin in git python3 sudo lsblk findmnt wipefs readlink cmp bash; do
    command -v "$bin" >/dev/null 2>&1 ||
        stop BLOCKED "Missing read-only preflight tool: $bin"
done

[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
    stop BLOCKED "Incorrect audit branch"
git -C "$SOURCE" cat-file -e "$BASE^{commit}" 2>/dev/null ||
    stop BLOCKED "Approved rc.11 source baseline unavailable"
git -C "$SOURCE" merge-base --is-ancestor "$BASE" HEAD ||
    stop FAIL "Audit tree is not based on the approved rc.11 commit"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
    stop BLOCKED "Tracked audit source modifications present"
git -C "$SOURCE" diff --name-only "$BASE" HEAD > "$EVDIR/source-diff-paths.txt"
while IFS= read -r path; do
    case "$path" in
        tests/host-acceptance/*|docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md) ;;
        *) stop FAIL "Unexpected appliance-source modification: $path" ;;
    esac
done < "$EVDIR/source-diff-paths.txt"
say PASS "Unmodified approved rc.11 appliance implementation; audit-only branch changes"

. /etc/os-release
[ "$ID" = ubuntu ] && [ "$VERSION_ID" = 26.04 ] &&
    [ "$VERSION_CODENAME" = resolute ] ||
    stop FAIL "Ubuntu 26.04 Resolute required"
case "$(uname -m)" in
    aarch64|arm64) ;;
    *) stop FAIL "ARM64 host required" ;;
esac
python3 -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 14) else 1)' ||
    stop FAIL "Native Python 3.14 required"
sudo -n true >/dev/null 2>&1 ||
    stop BLOCKED "Passwordless sudo -n unavailable"
say PASS "Ubuntu 26.04 ARM64 and Python 3.14 verified"

# This is a genuinely new-host gate. Do not run over an existing installation
# or after a partial installation without reviewing that state first.
for path in /opt/vaultwarden-oci /etc/vaultwarden-oci \
            /var/lib/vaultwarden-oci /run/vaultwarden-oci; do
    if sudo -n test -e "$path" || sudo -n test -L "$path"; then
        stop BLOCKED "Appliance path already exists: $path"
    fi
done
for unit in vaultwarden-oci.target vaultwarden-oci-health.timer \
            vaultwarden-oci-backup.timer vaultwarden-oci-maintenance.timer \
            vaultwarden-oci-update-check.timer; do
    if systemctl is-active --quiet "$unit" ||
       systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        stop BLOCKED "Appliance systemd unit already active or enabled: $unit"
    fi
done
say PASS "Fresh host is uninstalled, with no appliance automation"

[ -L "$DATA_BY_ID" ] ||
    stop BLOCKED "Expected stable /dev/disk/by-id symlink is missing: $DATA_BY_ID"
DEVICE="$(readlink -e -- "$DATA_BY_ID")" ||
    stop BLOCKED "Cannot resolve the stable device path"
[ -b "$DEVICE" ] ||
    stop BLOCKED "Selected path does not resolve to a block device"

# Record only filesystem metadata; no raw disk contents or private credentials.
sudo -n lsblk -J -b -p -o PATH,TYPE,SIZE,FSTYPE,MOUNTPOINTS,UUID,MODEL,PTTYPE "$DEVICE" \
    > "$EVDIR/disk-before.json" ||
    stop FAIL "Could not inventory candidate disk"
sudo -n wipefs --noheadings --output TYPE "$DEVICE" \
    > "$EVDIR/signatures-before.txt" ||
    stop FAIL "Could not inspect candidate disk signatures"

if ! sudo -n python3 -B -E - "$SOURCE" "$DATA_BY_ID" "$EXPECTED_BYTES" \
    > "$EVDIR/device-report.txt" 2> "$EVDIR/device-validation.stderr" <<'PY'
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import storage

by_id = Path(sys.argv[2])
expected_size = int(sys.argv[3])
device = by_id.resolve(strict=True)
if not stat.S_ISBLK(device.stat().st_mode):
    raise RuntimeError("selected path is not a block device")
storage.reject_boot_related(str(by_id))
root = storage.root_source()

proc = subprocess.run(
    ["lsblk", "-J", "-b", "-p", "-o",
     "PATH,TYPE,SIZE,FSTYPE,MOUNTPOINTS,UUID,MODEL,PTTYPE", str(device)],
    capture_output=True, text=True, check=True,
)
rows = json.loads(proc.stdout).get("blockdevices", [])
if len(rows) != 1:
    raise RuntimeError("device inventory has unexpected top-level count")
item = rows[0]
if item.get("type") != "disk" or item.get("children"):
    raise RuntimeError("selected device is not a standalone unpartitioned disk")
if item.get("size") != expected_size:
    raise RuntimeError("selected device size differs from prior operator evidence")
if any(isinstance(v, str) and v for v in (item.get("mountpoints") or [])):
    raise RuntimeError("selected device is mounted")
if item.get("fstype") or item.get("pttype") or item.get("uuid"):
    raise RuntimeError("selected disk reports existing filesystem/partition metadata")
signatures = subprocess.run(
    ["wipefs", "--noheadings", "--output", "TYPE", str(device)],
    capture_output=True, text=True, check=True,
)
if signatures.stdout.strip():
    raise RuntimeError("selected device has detected filesystem/partition signatures")
candidates = storage.inventory()
if not any(Path(str(row["path"])).resolve(strict=True) == device for row in candidates):
    raise RuntimeError("selected device is absent from product's independent storage inventory")

print("stable_device_path=" + str(by_id))
print("resolved_device=" + str(device))
print("root_source=" + root)
print("capacity_bytes=" + str(expected_size))
print("capacity_GiB=" + format(expected_size / (1024 ** 3), ".2f"))
print("is_boot_related=no")
print("mounted=no")
print("partition_children=no")
print("recognized_signatures=none")
print("OCI_ATTACHMENT_OWNERSHIP=NOT_VERIFIED_BY_GUEST")
print("OPERATOR_FORMAT_APPROVAL=NOT_GRANTED")
PY
then
    stop FAIL "Disk identity, size, or empty-device metadata did not match expected facts"
fi
cat "$EVDIR/device-report.txt"
say PASS "Stable by-id target is a separate unmounted 50 GiB-class disk with no recognized signatures"
say BLOCKED "OCI Console block-volume ownership must be independently confirmed before formatting"

# This recipient is synthetic, format-only test data for --dry-run.
# It is NOT an Age recovery recipient to use for any real installation.
FIXTURE_RECIPIENT="$(python3 -c 'print("age1" + "q" * 60)')"
DOMAIN="example.com"
URL="https://vault.example.com"
EMAIL="audit@example.com"

if ! NO_COLOR=1 sudo -n bash "$SOURCE/setup.sh" install \
    --domain "$DOMAIN" --url "$URL" --email "$EMAIL" \
    --data-device "$DATA_BY_ID" \
    --offline-recipient "$FIXTURE_RECIPIENT" \
    --auto --dry-run > "$EVDIR/selected-device-dryrun.txt" 2>&1; then
    stop FAIL "Supported setup --dry-run did not accept candidate disk (no changes requested)"
fi
if ! grep -Fq 'dry run: no filesystem, package, config, secret, or systemd changes were made' \
    "$EVDIR/selected-device-dryrun.txt"; then
    stop FAIL "Installer dry-run did not print its explicit no-mutation confirmation"
fi
say PASS "Actual setup --dry-run accepted exact by-id device; installation NOT authorized"

BAD_DEVICE="/dev/disk/by-id/vwoci-audit-intentionally-nonexistent-$$"
if [ -e "$BAD_DEVICE" ] || [ -L "$BAD_DEVICE" ]; then
    stop BLOCKED "Unexpected collision with deliberately invalid device name"
fi
if NO_COLOR=1 sudo -n bash "$SOURCE/setup.sh" install \
    --domain "$DOMAIN" --url "$URL" --email "$EMAIL" \
    --data-device "$BAD_DEVICE" \
    --offline-recipient "$FIXTURE_RECIPIENT" \
    --auto --dry-run > "$EVDIR/missing-device-refusal.txt" 2>&1; then
    stop FAIL "Setup unexpectedly accepted a nonexistent dedicated-storage device"
fi
if ! grep -Fq 'cannot resolve block device' "$EVDIR/missing-device-refusal.txt"; then
    stop FAIL "Setup refusal was not classified as missing block device"
fi
say PASS "Actual setup --dry-run rejected nonexistent storage"

sudo -n lsblk -J -b -p -o PATH,TYPE,SIZE,FSTYPE,MOUNTPOINTS,UUID,MODEL,PTTYPE "$DEVICE" \
    > "$EVDIR/disk-after.json" ||
    stop FAIL "Could not re-inventory candidate disk"
sudo -n wipefs --noheadings --output TYPE "$DEVICE" \
    > "$EVDIR/signatures-after.txt" ||
    stop FAIL "Could not re-inspect disk signatures"
cmp -s "$EVDIR/disk-before.json" "$EVDIR/disk-after.json" ||
    stop FAIL "Disk metadata changed between read-only checks"
cmp -s "$EVDIR/signatures-before.txt" "$EVDIR/signatures-after.txt" ||
    stop FAIL "Disk signatures changed between read-only checks"
for path in /opt/vaultwarden-oci /etc/vaultwarden-oci \
            /var/lib/vaultwarden-oci /run/vaultwarden-oci; do
    if sudo -n test -e "$path" || sudo -n test -L "$path"; then
        stop FAIL "An installation path appeared during dry-run: $path"
    fi
done
say PASS "Disk metadata unchanged and no appliance installation paths created"
say "NOT RUN" "Actual/off-host Age recipient and encrypted recovery-kit custody"
say "NOT RUN" "Installation, filesystem provisioning, Box retrieval or ciphertext verification"
say "NOT RUN" "Guided restore cancellation, authorized restore, application health and DNS cutover"
printf 'Evidence: %s\n' "$EVDIR"
printf 'Share summary.txt and device-report.txt; keep other files private.\n'
exit 0
