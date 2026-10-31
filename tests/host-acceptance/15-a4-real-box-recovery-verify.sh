#!/usr/bin/env bash
# A4: VERIFY original Box .vwrec with the matching OFFLINE identity recovered
# by the supported interactive encrypted recovery-kit chooser.
# No restore, DNS update, backup publication, service start, or timer enable.
# Verification writes recovery metadata and temporary plaintext staging to
# the already dedicated data volume; NOT a strictly disk-read-only operation.
set -Eeuo pipefail
umask 077

BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
HOST="vaultwarden-oci-5-vnic"
RELEASE="0.1.0-rc.11"
BYID="/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628"
ALIAS="/dev/oracleoci/oraclevdb"
SERIAL="6015f8fecf5e4f7ab864af5a651cc628"
BYTES="53687091200"
EXPECTED_RECIPIENT_HASH="7d08721bcc02bbef7dae1f07bfde244852560c69d0b72f8dc0fcba0da30c6773"
REMOTE="bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec"
EXPECTED_ARCHIVE_SHA="ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060"
KIT_NAME="vaultwarden-recovery-kit-20261006T222828Z.zip"
KIT_SOURCE="$HOME/$KIT_NAME"
KIT_DIR="/root/vaultwarden-recovery"
KIT_STAGE="$KIT_DIR/$KIT_NAME"
ORIGINAL_A3="$HOME/vwoci-acceptance/gate-a3-box-ciphertext-20261030T221705Z"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
OUT="$HOME/vwoci-acceptance/gate-a4-cryptographic-verify-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$OUT"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
chmod 600 "$SUMMARY"

STAGE_ATTEMPTED=0
CREATED_DIR=0
report() { printf '%-8s %s\n' "$1" "$2" | tee -a "$SUMMARY"; }
block() {
    report BLOCKED "$*"
    report "NOT RUN" "Destructive recovery restore, Cloudflare DNS changes, application start or timers"
    printf 'Evidence: %s\n' "$OUT"
    exit 1
}
cleanup() {
    local status=$?
    trap - EXIT
    if [ "$STAGE_ATTEMPTED" -eq 1 ]; then
        if ! sudo -n rm -f -- "$KIT_STAGE" >/dev/null 2>&1; then
            report BLOCKED "Failed to remove staged encrypted kit (root-only path $KIT_STAGE)"
            status=1
        else
            report PASS "Temporary root-only encrypted kit copy removed"
        fi
    fi
    if [ "$CREATED_DIR" -eq 1 ]; then
        if ! sudo -n rmdir -- "$KIT_DIR" >/dev/null 2>&1; then
            report BLOCKED "Failed to remove temporary root recovery-kit directory"
            status=1
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

check_dormant_units() {
    local unit active state
    for unit in vaultwarden-oci.target vaultwarden-oci.service \
        vaultwarden-oci-health.timer vaultwarden-oci-backup.timer \
        vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer \
        vaultwarden-oci-dns.service; do
        active="$(systemctl show --property=ActiveState --value "$unit")" ||
            block "Cannot inspect unit activity: $unit"
        state="$(systemctl show --property=UnitFileState --value "$unit")" ||
            block "Cannot inspect unit-file state: $unit"
        [ "$active" = inactive ] ||
            block "Appliance or timer activated unexpectedly: $unit ($active)"
        case "$unit" in
            vaultwarden-oci-dns.service)
                [ "$state" = static ] ||
                    block "DNS one-shot changed from static: $state" ;;
            *)
                [ "$state" = disabled ] ||
                    block "App/target/timer enabled unexpectedly: $unit ($state)" ;;
        esac
    done
}

[ "$#" -eq 0 ] || block "No arguments accepted"
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = "$HOST" ] ||
    block "Wrong operator or disposable acceptance VM"
[ -t 0 ] && [ -t 1 ] && [ -r /dev/tty ] ||
    block "Interactive terminal needed for hidden ZIP passphrase and protected identity chooser"
for cmd in git sudo python3 sha256sum stat lsblk findmnt readlink systemctl \
    rclone grep install rmdir rm cut tr cat; do
    command -v "$cmd" >/dev/null 2>&1 || block "Missing utility: $cmd"
done
sudo -n true >/dev/null 2>&1 || block "Noninteractive sudo unavailable"
[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
    block "Not on approved audit branch"
git -C "$SOURCE" cat-file -e "$BASE^{commit}" 2>/dev/null ||
    block "Pinned rc.11 source unavailable"
git -C "$SOURCE" merge-base --is-ancestor "$BASE" HEAD ||
    block "Audit source is not descended from the approved rc.11"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
    block "Uncommitted tracked checkout modifications"
while IFS= read -r file; do
    case "$file" in
        docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md|tests/host-acceptance/*) ;;
        *) block "Runtime/release content differs from pinned rc.11: $file" ;;
    esac
done < <(git -C "$SOURCE" diff --name-only "$BASE" HEAD)

[ -f "$ORIGINAL_A3/summary.txt" ] && [ ! -L "$ORIGINAL_A3/summary.txt" ] ||
    block "Original passing A3 evidence missing"
grep -Fq 'PASS     Box encrypted recovery point matches independently recorded SHA-256 exactly' \
    "$ORIGINAL_A3/summary.txt" ||
    block "Original Box ciphertext checksum gate not confirmed"
grep -Fq 'PASS     Box ciphertext access and integrity proven without remote or appliance changes' \
    "$ORIGINAL_A3/summary.txt" ||
    block "Independent Box readback gate absent"
[ "$(readlink -f /opt/vaultwarden-oci/current)" = \
    "/opt/vaultwarden-oci/releases/$RELEASE" ] ||
    block "Installed release is not approved rc.11"
[ -L "$BYID" ] && [ -L "$ALIAS" ] ||
    block "OCI data disk aliases missing"
DEVICE="$(readlink -e "$BYID")" || block "OCI selected disk missing"
[ "$DEVICE" = "$(readlink -e "$ALIAS")" ] ||
    block "OCI alias no longer identifies same data volume"
[ "$(lsblk -dn -o SERIAL "$DEVICE" | tr -d '[:space:]')" = "$SERIAL" ] ||
    block "Data disk serial changed"
[ "$(lsblk -bdn -o SIZE "$DEVICE" | tr -d '[:space:]')" = "$BYTES" ] ||
    block "Data disk capacity changed"
[ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o SOURCE)" = "$DEVICE" ] ||
    block "Dedicated mount source is no longer the approved disk"
if ! sudo -n python3 -B -E - "$SOURCE" "$DEVICE" "$EXPECTED_RECIPIENT_HASH" "$REMOTE" \
    > "$OUT/preflight.private.txt" 2>&1 <<'PY'
import hashlib, json, pathlib, sys, tomllib
sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import storage, secrets
storage.reject_boot_related(sys.argv[2])
identity = storage.verify()
if identity.fs_type != "ext4" or pathlib.Path(identity.source).resolve(strict=True) != pathlib.Path(sys.argv[2]).resolve(strict=True):
    raise RuntimeError("wrong dedicated volume")
with pathlib.Path("/etc/vaultwarden-oci/config.toml").open("rb") as stream:
    config = tomllib.load(stream)
recipient = config["secrets"]["offline_recovery_recipient"]
if hashlib.sha256(recipient.encode()).hexdigest() != sys.argv[3]:
    raise RuntimeError("configured public recipient changed")
backup = config["backup"]
if backup["remote"] != "" or backup["local_retention_days"] != 0 or backup["remote_retention_days"] != 0:
    raise RuntimeError("offsite upload or pruning unexpectedly enabled")
if recipient not in secrets.encrypted_recipients(pathlib.Path("/etc/vaultwarden-oci/secrets.sops.yaml")):
    raise RuntimeError("current encrypted secrets lost the offline Age recipient")
state = pathlib.Path("/var/lib/vaultwarden-oci/state/recovery.json")
if state.exists():
    obj = json.loads(state.read_text())
    if sys.argv[4] in obj.get("verified_objects", {}):
        raise RuntimeError("this remote object already has verification state; do not repeat A4 blindly")
print("PASS: identity, recipient, backup policy and prior state")
PY
then block "Storage/recipient/backup-policy/first-verification preflight failed; see private evidence"; fi
check_dormant_units
if ! sudo -n rclone listremotes > "$OUT/root-remotes.private.txt" \
    2> "$OUT/rclone.private.stderr"; then
    block "Root's rclone config is inaccessible; leave secrets private"
fi
grep -Fxq 'bw-backup:' "$OUT/root-remotes.private.txt" ||
    block "Root bw-backup: rclone remote not available"
[ -f "$KIT_SOURCE" ] && [ ! -L "$KIT_SOURCE" ] &&
[ "$(stat -c %a "$KIT_SOURCE")" = 600 ] ||
    block "Original encrypted emailed kit must be a regular mode-0600 file at approved user path"
report PASS "Approved A3 evidence, rc.11, data-volume custody, public Age recipient and inactive services"
report PASS "Existing root Box remote and encrypted emailed recovery kit available"

printf '\n============================================================\n'
printf 'A4: REAL CRYPTOGRAPHIC VERIFICATION — NO RESTORE\n'
printf ' Remote: %s\n' "$REMOTE"
printf ' Expected SHA-256: %s\n' "$EXPECTED_ARCHIVE_SHA"
printf ' Identity: encrypted emailed recovery-kit ZIP (root-only temporary copy)\n'
printf ' User workflow: choose 3 (local ZIP), then 1 (single listed kit)\n'
printf ' Your ZIP passphrase is HIDDEN and must not be pasted into chat.\n'
printf ' Verification may write metadata to recovery.json and temporary\n'
printf ' decrypted plaintext into protected staging on the ext4 data volume.\n'
printf ' The product deletes staging on completion, but deletion is not\n'
printf ' cryptographic erasure of an unencrypted ext4 disk.\n'
printf ' No restore, application start, DNS updates, backup uploads or timers.\n'
printf '============================================================\n'
IFS= read -r -p "Type VERIFY EXISTING BOX BACKUP to authorize verification: " CONFIRM </dev/tty ||
    block "Verification not authorized"
[ "$CONFIRM" = "VERIFY EXISTING BOX BACKUP" ] ||
    block "Verification authorization mismatch"

# Create only an empty, private root-owned publication directory if needed.
if sudo -n test -L "$KIT_DIR"; then
    block "Recovery-kit directory is a symlink"
fi
if sudo -n test -e "$KIT_DIR"; then
    [ "$(sudo -n stat -c '%u %a %F' "$KIT_DIR")" = "0 700 directory" ] ||
        block "Existing root recovery-kit directory ownership/permissions unsafe"
    if sudo -n python3 -B -E - "$KIT_DIR" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
raise SystemExit(0 if not any(path.iterdir()) else 1)
PY
    then :
    else block "Existing recovery-kit directory is not empty; refuse ambiguity"; fi
else
    sudo -n install -d -m 700 -o root -g root -- "$KIT_DIR" ||
        block "Cannot create private root recovery-kit directory"
    CREATED_DIR=1
fi

# Copy ONLY the encrypted ZIP, exclusively; no plaintext secret is extracted
# here. The product's option 3 extracts its private key under root /run and
# cleans it via the supported context manager.
STAGE_ATTEMPTED=1
if ! sudo -n python3 -B -E - "$KIT_SOURCE" "$KIT_STAGE" <<'PY' \
    > "$OUT/kit-copy.private.txt" 2>&1
import hashlib, os, pathlib, shutil, stat, sys
src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
s = src.lstat()
if not stat.S_ISREG(s.st_mode) or stat.S_IMODE(s.st_mode) != 0o600 or not 0 < s.st_size <= 16*1024*1024:
    raise RuntimeError("unexpected source archive size/permissions")
fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
try:
    with os.fdopen(fd, "wb") as output, src.open("rb") as inp:
        shutil.copyfileobj(inp, output, 1024*1024)
        output.flush()
        os.fsync(output.fileno())
    def digest(path):
        with path.open("rb") as stream:
            h = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024*1024), b""):
                h.update(chunk)
            return h.hexdigest()
    if digest(src) != digest(dst):
        raise RuntimeError("encrypted ZIP copy checksum mismatch")
except Exception:
    dst.unlink(missing_ok=True)
    raise
print("PASS: root-only encrypted ZIP copy matches original")
PY
then block "Encrypted kit could not be copied safely; private evidence retained"; fi
report PASS "Encrypted kit copied byte-for-byte to private root chooser directory"

BEFORE_CONFIG="$(sudo -n sha256sum /etc/vaultwarden-oci/config.toml | cut -d ' ' -f1)"
BEFORE_SECRETS="$(sudo -n sha256sum /etc/vaultwarden-oci/secrets.sops.yaml | cut -d ' ' -f1)"
BEFORE_KEY="$(sudo -n sha256sum /etc/vaultwarden-oci/age-key.txt | cut -d ' ' -f1)"

printf '\nNext, the SUPPORTED vwctl verification will open.\n'
printf 'Select option 3 (local recovery-kit ZIP), then option 1.\n'
printf 'Enter the emailed ZIP password at the HIDDEN prompt.\n'
printf 'Do not select restore; this command only runs recovery verify.\n\n'
if sudo -n /usr/local/bin/vwctl recovery verify --from-remote "$REMOTE"; then
    report PASS "Supported remote Age/SOPS/manifest verification command returned success"
else
    RC=$?
    block "Recovery verification failed or was cancelled (exit $RC); no restore performed"
fi

# Remote verification must have persisted the digest of the ACTUAL downloaded
# archive after decrypting and checking manifest + offline SOPS validation.
if ! sudo -n python3 -B -E - "$REMOTE" "$EXPECTED_ARCHIVE_SHA" \
    > "$OUT/verified-record.txt" 2> "$OUT/verified-record.private.stderr" <<'PY'
import json, pathlib, sys
path = pathlib.Path("/var/lib/vaultwarden-oci/state/recovery.json")
with path.open() as stream:
    data = json.load(stream)
record = data["verified_objects"][sys.argv[1]]
if record["sha256"] != sys.argv[2] or not isinstance(record["size"], int) or record["size"] < 64:
    raise RuntimeError("verified download hash or size mismatch")
if not isinstance(record.get("created_at"), str) or not record["created_at"]:
    raise RuntimeError("manifest creation time missing")
if not isinstance(record.get("verified_at"), str) or not record["verified_at"]:
    raise RuntimeError("verification time missing")
print("verification_state=PASS")
print("downloaded_ciphertext_sha256_matches_A3=PASS")
print("decrypted_manifest_and_SOPS=PASS")
print("verified_object_bytes=" + str(record["size"]))
print("backup_created_at=" + record["created_at"])
PY
then block "Verified remote record not consistent with independent A3 checksum"; fi
cat "$OUT/verified-record.txt" | tee -a "$SUMMARY"
report PASS "Actually decrypted archive matches original Box SHA-256 and validates manifest/SOPS"

[ "$BEFORE_CONFIG" = "$(sudo -n sha256sum /etc/vaultwarden-oci/config.toml | cut -d ' ' -f1)" ] ||
    block "Verification unexpectedly changed operator config"
[ "$BEFORE_SECRETS" = "$(sudo -n sha256sum /etc/vaultwarden-oci/secrets.sops.yaml | cut -d ' ' -f1)" ] ||
    block "Verification unexpectedly changed live SOPS ciphertext"
[ "$BEFORE_KEY" = "$(sudo -n sha256sum /etc/vaultwarden-oci/age-key.txt | cut -d ' ' -f1)" ] ||
    block "Verification unexpectedly changed live operational Age identity"
check_dormant_units
if sudo -n python3 -B -E - <<'PY'
from pathlib import Path
run = Path("/run/vaultwarden-oci")
backups = Path("/var/lib/vaultwarden-oci/backups")
if run.is_dir() and list(run.glob("offline-identity-*")):
    raise SystemExit(1)
if backups.is_dir() and (list(backups.glob("vwrec-remote-inspect-*")) or list(backups.glob("vwrec-inspect-*"))):
    raise SystemExit(1)
PY
then
    report PASS "Product's offline private-key and recovery plaintext staging directories cleaned"
else
    block "Transient offline identity or decrypted recovery staging remains; secure host and inspect privately"
fi
report PASS "Initial application secrets unchanged and services/timers remain inactive"
report "NOT RUN" "Destructive restore, Vaultwarden start, DNS cutover, timers or production action"
report INFO "Verification metadata was intentionally recorded under the dedicated state volume"
printf 'Evidence: %s\n' "$OUT"
printf 'Share summary.txt and verified-record.txt; never share private stderr, key or ZIP password.\n'
