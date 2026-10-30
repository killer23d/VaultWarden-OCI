#!/usr/bin/env bash
# Gate A5: real encrypted recovery-kit -> restore PREVIEW -> enforced CANCEL.
# The paired Python helper's approval callback NEVER returns True.
# No setup, restore promotion, service start, DNS, prune, or backup upload.
set -Eeuo pipefail
umask 077

BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
HOST="vaultwarden-oci-5-vnic"
VERSION="0.1.0-rc.11"
BYID="/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628"
ALIAS="/dev/oracleoci/oraclevdb"
SERIAL="6015f8fecf5e4f7ab864af5a651cc628"
BYTES="53687091200"
REMOTE="bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec"
EXPECTED_SHA="ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060"
ORIGINAL_KIT="$HOME/vaultwarden-recovery-kit-20261006T222828Z.zip"
KITDIR="/root/vaultwarden-recovery"
STAGED_KIT="$KITDIR/vaultwarden-recovery-kit-20261006T222828Z.zip"
A4="$HOME/vwoci-acceptance/gate-a4-cryptographic-verify-20261030T222301Z"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
OUT="$HOME/vwoci-acceptance/gate-a5-recovery-cancel-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$OUT"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
chmod 600 "$SUMMARY"

STAGED=0
MADE_KITDIR=0
say() { printf '%-8s %s\n' "$1" "$2" | tee -a "$SUMMARY"; }
block() {
    say BLOCKED "$*"
    say "NOT RUN" "Restoration/promotion, application start, DNS update, backup/timer activation"
    printf 'Evidence: %s\n' "$OUT"
    exit 1
}
cleanup() {
    local result=$?
    trap - EXIT
    if [ "$STAGED" -eq 1 ]; then
        if sudo -n rm -f -- "$STAGED_KIT" >/dev/null 2>&1; then
            say PASS "Temporary root-owned encrypted kit copy removed"
        else
            say BLOCKED "Could not delete temporary encrypted kit: $STAGED_KIT"
            result=1
        fi
    fi
    if [ "$MADE_KITDIR" -eq 1 ]; then
        if ! sudo -n rmdir -- "$KITDIR" >/dev/null 2>&1; then
            say BLOCKED "Root-only temporary kit directory was not removable; inspect locally"
            result=1
        fi
    fi
    exit "$result"
}
trap cleanup EXIT

[ "$#" -eq 0 ] || block "No arguments accepted"
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = "$HOST" ] ||
    block "Wrong acceptance host or operator"
[ -t 0 ] && [ -t 1 ] && [ -r /dev/tty ] ||
    block "Actual operator TTY required; ZIP password must be hidden"
for tool in git sudo python3 sha256sum stat lsblk findmnt readlink systemctl \
    grep install rm rmdir cut tr; do
    command -v "$tool" >/dev/null 2>&1 ||
        block "Host prerequisite unavailable: $tool"
done
sudo -n true >/dev/null 2>&1 ||
    block "Noninteractive sudo is unavailable"

[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
    block "Wrong audit branch"
git -C "$SOURCE" cat-file -e "$BASE^{commit}" 2>/dev/null ||
    block "Approved source commit missing"
git -C "$SOURCE" merge-base --is-ancestor "$BASE" HEAD ||
    block "Audit checkout not descended from rc.11"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
    block "Uncommitted tracked changes in audit checkout"
while IFS= read -r path; do
    case "$path" in
        docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md|tests/host-acceptance/*) ;;
        *) block "Runtime source modified from frozen rc.11: $path" ;;
    esac
done < <(git -C "$SOURCE" diff --name-only "$BASE" HEAD)

[ -f "$A4/summary.txt" ] && [ ! -L "$A4/summary.txt" ] ||
    block "Successful A4 gate summary missing"
for marker in \
    'PASS     Actually decrypted archive matches original Box SHA-256 and validates manifest/SOPS' \
    "PASS     Product's offline private-key and recovery plaintext staging directories cleaned" \
    'PASS     Initial application secrets unchanged and services/timers remain inactive' \
    'PASS     Temporary root-only encrypted kit copy removed'; do
    grep -Fq "$marker" "$A4/summary.txt" ||
        block "A4 evidence does not contain complete passed postconditions"
done

[ "$(readlink -f /opt/vaultwarden-oci/current)" = \
    "/opt/vaultwarden-oci/releases/$VERSION" ] ||
    block "Installed appliance is not the frozen rc.11 release"
[ -L "$BYID" ] && [ -L "$ALIAS" ] ||
    block "Chosen OCI disk aliases are missing"
DEVICE="$(readlink -e "$BYID")" || block "Could not resolve selected disk"
[ "$DEVICE" = "$(readlink -e "$ALIAS")" ] ||
    block "OCI block-volume alias changed"
[ "$(lsblk -dn -o SERIAL "$DEVICE" | tr -d '[:space:]')" = "$SERIAL" ] ||
    block "OCI block-volume serial changed"
[ "$(lsblk -bdn -o SIZE "$DEVICE" | tr -d '[:space:]')" = "$BYTES" ] ||
    block "OCI block-volume capacity changed"
[ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o SOURCE)" = "$DEVICE" ] ||
    block "Selected ext4 recovery volume is no longer mounted at appliance path"
if ! sudo -n python3 -B -E - "$SOURCE" "$DEVICE" "$REMOTE" "$EXPECTED_SHA" \
    > "$OUT/preflight.private.txt" 2>&1 <<'PY'
import json, pathlib, sys, tomllib
sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import storage
storage.reject_boot_related(sys.argv[2])
identity = storage.verify()
if identity.fs_type != "ext4" or pathlib.Path(identity.source).resolve(strict=True) != pathlib.Path(sys.argv[2]).resolve(strict=True):
    raise RuntimeError("identity/mount mismatch")
with pathlib.Path("/etc/vaultwarden-oci/config.toml").open("rb") as f:
    config = tomllib.load(f)
backup = config["backup"]
if backup["remote"] != "" or backup["local_retention_days"] != 0 or backup["remote_retention_days"] != 0:
    raise RuntimeError("cloud write or retention no longer disabled")
with pathlib.Path("/var/lib/vaultwarden-oci/state/recovery.json").open() as f:
    verified = json.load(f)["verified_objects"][sys.argv[3]]
if verified["sha256"] != sys.argv[4] or verified["size"] != 358680 or verified["created_at"] != "2026-10-29T22:32:01Z":
    raise RuntimeError("A4 recorded backup differs from exact approved artifact")
print("PASS: storage identity, safe backup policy and verified Box record")
PY
then block "Dedicated storage/config/A4 verification state changed; inspect private preflight"; fi

for unit in vaultwarden-oci.target vaultwarden-oci.service \
    vaultwarden-oci-health.timer vaultwarden-oci-backup.timer \
    vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer \
    vaultwarden-oci-dns.service; do
    active="$(systemctl show --property=ActiveState --value "$unit")" ||
        block "Cannot read systemd unit state: $unit"
    state="$(systemctl show --property=UnitFileState --value "$unit")" ||
        block "Cannot read unit file state: $unit"
    [ "$active" = inactive ] || block "Unit activated unexpectedly: $unit ($active)"
    case "$unit" in
        vaultwarden-oci-dns.service) [ "$state" = static ] ||
            block "DNS oneshot not static: $unit ($state)" ;;
        *) [ "$state" = disabled ] ||
            block "Unintended scheduled/boot activation: $unit ($state)" ;;
    esac
done

[ -f "$ORIGINAL_KIT" ] && [ ! -L "$ORIGINAL_KIT" ] &&
    [ "$(stat -c '%a' "$ORIGINAL_KIT")" = 600 ] ||
    block "The original emailed encrypted ZIP is not the protected 0600 regular file"
say PASS "A4, installed release, original data volume, root-only kit and dormant services verified"

printf '\n============================================================\n'
printf 'GATE A5: REAL RESTORE PREFLIGHT / FORCED CANCEL ONLY\n'
printf ' Host: %s\n' "$HOST"
printf ' Volume: %s (existing ext4; NEVER formatted again)\n' "$BYID"
printf ' Source: %s\n' "$REMOTE"
printf ' SHA-256: %s\n' "$EXPECTED_SHA"
printf ' Offline identity MUST be extracted from original encrypted ZIP.\n'
printf ' Password will be prompted invisibly; never paste it into chat.\n'
printf ' The restore engine approval callback is HARDWIRED FALSE.\n'
printf ' Typing RESTORE cannot make this test promote recovered data.\n'
printf ' Verification decrypts into private temporary staging on ext4;\n'
printf ' deletion is not cryptographic erasure of unencrypted blocks.\n'
printf ' No application data mutation, startup, remote write, or DNS.\n'
printf '============================================================\n'
IFS= read -r -p "To authorize only a cancelled restore preflight, type TEST CANCEL ONLY: " ACK </dev/tty ||
    block "A5 not authorized"
[ "$ACK" = "TEST CANCEL ONLY" ] ||
    block "A5 authorization did not match"

# Exclusive private, root-owned copy of ENCRYPTED kit for the product's
# standard kit functions. Never copy or print any plaintext recovery key.
if sudo -n test -L "$KITDIR"; then
    block "Kit publication directory must not be a symlink"
fi
if sudo -n test -e "$KITDIR"; then
    [ "$(sudo -n stat -c '%u %a %F' "$KITDIR")" = "0 700 directory" ] ||
        block "Existing kit directory has unsafe ownership/mode"
    if sudo -n python3 -B -E - "$KITDIR" <<'PY' >/dev/null 2>&1
from pathlib import Path
import sys
root = Path(sys.argv[1])
raise SystemExit(0 if not any(root.iterdir()) else 1)
PY
    then
        :
    else
        block "Root publication directory is not empty; refuse to touch any existing kit"
    fi
else
    sudo -n install -d -m 700 -o root -g root -- "$KITDIR" ||
        block "Cannot create private root publication directory"
    MADE_KITDIR=1
fi

if ! sudo -n python3 -B -E - "$ORIGINAL_KIT" "$STAGED_KIT" <<'PY' \
    > "$OUT/kit-stage.private.txt" 2>&1
import hashlib, os, pathlib, shutil, stat, sys
source, destination = map(pathlib.Path, sys.argv[1:])
info = source.lstat()
if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or not 0 < info.st_size <= 16 * 1024 * 1024:
    raise RuntimeError("encrypted source ZIP metadata mismatch")
fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
try:
    with os.fdopen(fd, "wb") as target, source.open("rb") as origin:
        shutil.copyfileobj(origin, target, 1024 * 1024)
        target.flush()
        os.fsync(target.fileno())
    def digest(path):
        h = hashlib.sha256()
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        return h.digest()
    if digest(source) != digest(destination):
        raise RuntimeError("encrypted kit checksum mismatch after copying")
except Exception:
    destination.unlink(missing_ok=True)
    raise
PY
then block "Failed copying encrypted kit; no restore preflight started"; fi
STAGED=1
say PASS "Exact encrypted emailed recovery kit staged root-only with matching checksum"

HELPER="$SOURCE/tests/host-acceptance/16-a5-kit-cancel-helper.py"
[ -f "$HELPER" ] && [ ! -L "$HELPER" ] ||
    block "Missing immutable audit-only cancellation helper"
printf '\nEnter the original ZIP passphrase at the hidden prompt.\n'
printf 'After full cryptographic preflight, type CANCEL exactly.\n'
printf 'This helper CAN NEVER invoke a destructive restore.\n\n'

# A direct interactive Python program, not stdin/heredoc: preserves TTY for
# getpass and refuses restore in the product's own approval callback.
if sudo -n python3 -B -E "$HELPER" "$REMOTE" "$EXPECTED_SHA"; then
    say PASS "Real Box pre-restore crypto completed and cancelled before all state mutation"
else
    RC=$?
    block "Protected A5 cancellation preview exited $RC; no restore was authorized"
fi

for unit in vaultwarden-oci.target vaultwarden-oci.service \
    vaultwarden-oci-health.timer vaultwarden-oci-backup.timer \
    vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer \
    vaultwarden-oci-dns.service; do
    [ "$(systemctl show --property=ActiveState --value "$unit")" = inactive ] ||
        block "An appliance, DNS or timer unit became active during cancelled preview: $unit"
done
say PASS "Vaultwarden target/DNS/timers remain inactive after full cancel preflight"
say "NOT RUN" "Recovery promotion, Cloudflare DNS change, application start or automated jobs"
printf 'Evidence: %s\n' "$OUT"
printf 'Share summary and displayed helper PASS lines only; keep private evidence and ZIP passphrase off-chat.\n'
