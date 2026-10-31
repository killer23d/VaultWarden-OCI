#!/usr/bin/env bash
# Gate A3-SOURCE: verify the known Box ciphertext against a separately recorded
# SHA-256, without restoring data or modifying Box objects / Vaultwarden state.
# Remote authentication may update LOCAL root rclone OAuth token cache/config.
set -Eeuo pipefail
umask 077

BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
HOST="vaultwarden-oci-5-vnic"
VERSION="0.1.0-rc.11"
EXPECTED_BYID="/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628"
EXPECTED_ALIAS="/dev/oracleoci/oraclevdb"
EXPECTED_SERIAL="6015f8fecf5e4f7ab864af5a651cc628"
EXPECTED_BYTES="53687091200"
REMOTE_NAME="bw-backup:"
REMOTE_OBJECT="bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec"
EXPECTED_SHA="ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060"
KIT="$HOME/vaultwarden-recovery-kit-20261006T222828Z.zip"
A2R="$HOME/vwoci-acceptance/gate-a2r-final-check-20261030T220920Z"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$HOME/vwoci-acceptance/gate-a3-box-ciphertext-$STAMP"
mkdir -m 700 "$OUT"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
chmod 600 "$SUMMARY"
say() { printf '%-8s %s\n' "$1" "$2" | tee -a "$SUMMARY"; }
blocked() {
    say BLOCKED "$*"
    say "NOT RUN" "Box object decryption, guided restore, DNS write, app start or backup timers"
    printf 'Evidence: %s\n' "$OUT"
    exit 1
}

[ "$#" -eq 0 ] || blocked "No arguments supported"
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = "$HOST" ] ||
    blocked "Wrong operator/acceptance host"
for cmd in git sudo python3 lsblk findmnt readlink timeout rclone sha256sum awk \
    systemctl grep cut; do
    command -v "$cmd" >/dev/null 2>&1 || blocked "Missing tool: $cmd"
done
sudo -n true >/dev/null 2>&1 || blocked "Passwordless sudo not available"
[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
    blocked "Not on pinned audit branch"
git -C "$SOURCE" cat-file -e "$BASE^{commit}" 2>/dev/null ||
    blocked "Approved rc.11 commit missing"
git -C "$SOURCE" merge-base --is-ancestor "$BASE" HEAD ||
    blocked "Audit branch does not descend from approved base"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
    blocked "Checkout has uncommitted tracked modifications"
while IFS= read -r file; do
    case "$file" in
        docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md|tests/host-acceptance/*) ;;
        *) blocked "Approved runtime source changed: $file" ;;
    esac
done < <(git -C "$SOURCE" diff --name-only "$BASE" HEAD)

[ -f "$A2R/summary.txt" ] && [ -f "$A2R/appliance-proof.txt" ] ||
    blocked "A2R final evidence missing"
grep -Fq 'PASS     All appliance targets/timers inactive/disabled and DNS service inactive/static' \
    "$A2R/summary.txt" ||
    blocked "A2R final unit-state acceptance not recorded"
[ "$(readlink -f /opt/vaultwarden-oci/current)" = "/opt/vaultwarden-oci/releases/$VERSION" ] ||
    blocked "Installed release no longer equals pinned rc.11"

[ -L "$EXPECTED_BYID" ] && [ -L "$EXPECTED_ALIAS" ] ||
    blocked "OCI data volume aliases missing"
DEVICE="$(readlink -e "$EXPECTED_BYID")" ||
    blocked "OCI data volume not resolved"
[ "$DEVICE" = "$(readlink -e "$EXPECTED_ALIAS")" ] ||
    blocked "OCI selected disk alias changed"
[ "$(lsblk -dn -o SERIAL "$DEVICE" | tr -d '[:space:]')" = "$EXPECTED_SERIAL" ] ||
    blocked "Data volume serial changed"
[ "$(lsblk -bdn -o SIZE "$DEVICE" | tr -d '[:space:]')" = "$EXPECTED_BYTES" ] ||
    blocked "Data volume capacity changed"
[ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o SOURCE)" = "$DEVICE" ] ||
    blocked "Dedicated volume mount source changed"
if ! sudo -n python3 -B -E - "$SOURCE" "$DEVICE" <<'PY' > "$OUT/storage-proof.private.txt" 2>&1
import pathlib
import sys
sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import storage
identity = storage.verify()
if identity.fs_type != "ext4" or pathlib.Path(identity.source).resolve(strict=True) != pathlib.Path(sys.argv[2]).resolve(strict=True):
    raise RuntimeError("wrong dedicated recovery volume")
PY
then blocked "Storage identity and volume marker verification failed"; fi
say PASS "A2R accepted, pinned release and exact dedicated storage marker verified"

for unit in vaultwarden-oci.target vaultwarden-oci.service \
    vaultwarden-oci-health.timer vaultwarden-oci-backup.timer \
    vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer \
    vaultwarden-oci-dns.service; do
    ACTIVE="$(systemctl show --property=ActiveState --value "$unit")" ||
        blocked "Cannot inspect systemd state of $unit"
    [ "$ACTIVE" = inactive ] ||
        blocked "Appliance/automation unexpectedly activated: $unit"
done
say PASS "Vaultwarden/backup/DNS units remain inactive"

if [ -f "$KIT" ] && [ ! -L "$KIT" ]; then
    say PASS "Emailed encrypted recovery-kit ZIP present on disposable host (not opened)"
else
    blocked "Emailed encrypted recovery-kit ZIP not available at approved local path"
fi
say INFO "No ZIP passphrase, private Age identity or cloud token is read or printed"

say INFO "Checking whether the replacement VM has independent ROOT rclone access"
if ! sudo -n rclone listremotes > "$OUT/root-remotes.private.txt" \
    2> "$OUT/rclone-list.private.stderr"; then
    blocked "Root rclone configuration inaccessible; Box backup itself NOT checked"
fi
if ! grep -Fxq "$REMOTE_NAME" "$OUT/root-remotes.private.txt"; then
    say INFO "root_rclone_box_remote=NOT_CONFIGURED"
    say INFO "Root's Box credentials are not contained in the recovery kit or .vwrec"
    blocked "Configure root's bw-backup: remote on this replacement VM through a secure, independent mechanism; do not share credentials"
fi
say PASS "Root rclone has the expected bw-backup: remote; Box access is still unproven"
say INFO "Known independent source object: $REMOTE_OBJECT"
say INFO "Previously recorded remote/local SHA256: $EXPECTED_SHA"
say INFO "Streaming encrypted Box object directly into SHA-256; no local ciphertext file or remote object write"
say INFO "If it stalls, the download is bounded to 300 seconds and the command fails closed"

# Only remote READ (rclone cat); it might refresh root's local OAuth state.
# Never print raw rclone errors or configuration. The pipeline must succeed
# completely before comparing hashes (set -o pipefail above).
if ACTUAL_SHA="$(timeout --signal=TERM --kill-after=10s 300 \
    sudo -n rclone cat "$REMOTE_OBJECT" \
      --retries=1 --low-level-retries=1 \
      2> "$OUT/rclone-cat.private.stderr" \
    | sha256sum | awk '{print $1}')"; then
    say PASS "Encrypted Box object streamed completely"
else
    RC=$?
    say INFO "remote_read_status=FAILED_rc_$RC"
    blocked "Remote read failed or timed out; preserve private rclone stderr for local diagnosis"
fi

[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] ||
    blocked "Box object SHA-256 differs from previously recorded verified recovery point"
say PASS "Box encrypted recovery point matches independently recorded SHA-256 exactly"
say PASS "Box ciphertext access and integrity proven without remote or appliance changes"
say "NOT RUN" "Offline Age private-key decryption, SOPS/manifest validation or restore"
say "NOT RUN" "Vaultwarden startup, DNS update, service/timer enable, production cutover"
printf 'Evidence: %s\n' "$OUT"
printf 'Share only summary.txt. Keep root-remotes.private.txt and rclone-*.private.stderr private.\n'
