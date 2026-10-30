#!/usr/bin/env bash
# Gate A2R-FINAL: read-only attestation after successful rc.11 install
# was incorrectly blocked by systemctl is-enabled returning 0 for a
# STATIC DNS oneshot. This does NOT rerun setup, start/enable services,
# verify Box, restore backups, change DNS, or touch the appliance volume.
set -Eeuo pipefail
umask 077

BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
HOST="vaultwarden-oci-5-vnic"
RELEASE="0.1.0-rc.11"
BYID="/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628"
ALIAS="/dev/oracleoci/oraclevdb"
SERIAL="6015f8fecf5e4f7ab864af5a651cc628"
SIZE_BYTES="53687091200"
RECIPIENT_SHA256="7d08721bcc02bbef7dae1f07bfde244852560c69d0b72f8dc0fcba0da30c6773"
SOPS_SHA256="53b0abacd38ef1b12a66d6c100956691b9cefce018d91f81e73ddf7438b94d77"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
ORIGINAL="$HOME/vwoci-acceptance/gate-a2r-existing-volume-20261030T220144Z"
EVIDENCE="$HOME/vwoci-acceptance/gate-a2r-final-check-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$EVIDENCE"
SUMMARY="$EVIDENCE/summary.txt"
: > "$SUMMARY"
chmod 600 "$SUMMARY"

report() { printf '%-8s %s\n' "$1" "$2" | tee -a "$SUMMARY"; }
block() {
    report BLOCKED "$*"
    report "NOT RUN" "Box remote backup retrieval, offline Age decryption, restore, DNS or timer enable"
    printf 'Evidence: %s\n' "$EVIDENCE"
    exit 1
}
[ "$#" -eq 0 ] || block "No arguments supported"
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = "$HOST" ] ||
    block "Wrong operator or original disposable VM"
sudo -n true >/dev/null 2>&1 || block "Passwordless sudo missing"
for cmd in git sha256sum systemctl lsblk findmnt readlink python3 cmp; do
    command -v "$cmd" >/dev/null 2>&1 ||
        block "Missing required inspection command: $cmd"
done
[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
    block "Wrong audit branch"
git -C "$SOURCE" cat-file -e "$BASE^{commit}" 2>/dev/null ||
    block "Approved immutable rc.11 source missing"
git -C "$SOURCE" merge-base --is-ancestor "$BASE" HEAD ||
    block "Audit HEAD does not descend from the approved release"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
    block "Uncommitted tracked source modifications"
while IFS= read -r file; do
    case "$file" in
        docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md|tests/host-acceptance/*) ;;
        *) block "Release/runtime source differs from approved rc.11: $file" ;;
    esac
done < <(git -C "$SOURCE" diff --name-only "$BASE" HEAD)
report PASS "Approved immutable rc.11 source and audit-only changes verified"

[ -f "$ORIGINAL/summary.txt" ] && [ -f "$ORIGINAL/post-install.txt" ] ||
    block "Original successful-install/blocked-systemd evidence absent"
grep -Fq 'PASS     Supported existing-filesystem setup completed without --confirm-format' \
    "$ORIGINAL/summary.txt" || block "Original supported installation did not report success"
grep -Fq 'PASS     Installed rc.11, verified dedicated storage, original offline recipient and root-only secrets' \
    "$ORIGINAL/summary.txt" || block "Original storage/custody postinstall verification not recorded"
grep -Fq 'PASS     SOPS v3.13.3 matches official SHA-256 and executes' \
    "$ORIGINAL/summary.txt" || block "Original pinned SOPS verification not recorded"
grep -Fq 'BLOCKED  Unexpected active/enabled app or DNS/timer unit: vaultwarden-oci-dns.service' \
    "$ORIGINAL/summary.txt" || block "Failure not the known static-unit ambiguity; do not infer"
report PASS "Original A2R successfully installed; only the expected DNS unit gate blocked"

[ -L "$BYID" ] && [ -L "$ALIAS" ] ||
    block "Data disk stable OCI aliases missing"
DEVICE="$(readlink -e "$BYID")" || block "Data disk cannot resolve"
[ "$DEVICE" = "$(readlink -e "$ALIAS")" ] ||
    block "Data disk OCI alias mismatch"
[ "$(lsblk -dn -o SERIAL "$DEVICE" | tr -d '[:space:]')" = "$SERIAL" ] ||
    block "Selected disk serial changed"
[ "$(lsblk -bdn -o SIZE "$DEVICE" | tr -d '[:space:]')" = "$SIZE_BYTES" ] ||
    block "Selected disk capacity changed"
[ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o SOURCE)" = "$DEVICE" ] ||
    block "Dedicated mount no longer uses approved data disk"
[ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o FSTYPE)" = ext4 ] ||
    block "Dedicated ext4 filesystem missing"

if ! sudo -n python3 -B -E - "$SOURCE" "$DEVICE" "$RELEASE" "$RECIPIENT_SHA256" \
    > "$EVIDENCE/appliance-proof.txt" 2> "$EVIDENCE/appliance-proof.private.stderr" <<'PY'
import hashlib
import pathlib
import stat
import sys
import tomllib
sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import storage
from vaultwarden_oci import secrets as secret_owner

storage.reject_boot_related(sys.argv[2])
identity = storage.verify()
if identity.fs_type != "ext4" or pathlib.Path(identity.source).resolve(strict=True) != pathlib.Path(sys.argv[2]).resolve(strict=True):
    raise RuntimeError("installed volume does not match approved disk")
release = pathlib.Path("/opt/vaultwarden-oci/current").resolve(strict=True)
if release != pathlib.Path("/opt/vaultwarden-oci/releases") / sys.argv[3]:
    raise RuntimeError("installed release differs from approved rc.11")
with open("/etc/vaultwarden-oci/config.toml", "rb") as f:
    config = tomllib.load(f)
recipient = config["secrets"]["offline_recovery_recipient"]
if hashlib.sha256(recipient.encode()).hexdigest() != sys.argv[4]:
    raise RuntimeError("offline recovery recipient does not match emailed kit")
if config["site"]["domain"] != "bw.lazymocha.com":
    raise RuntimeError("installed vault domain changed")
if config["site"]["acme_email"] != "bw@lazymocha.com":
    raise RuntimeError("administrator email changed")
backup = config["backup"]
if backup["remote"] != "" or backup["local_retention_days"] != 0 or backup["remote_retention_days"] != 0:
    raise RuntimeError("backup/offsite publishing or retention unexpectedly enabled")
for filename in ("config.toml", "age-key.txt", "secrets.sops.yaml", "storage-identity.json"):
    p = pathlib.Path("/etc/vaultwarden-oci") / filename
    info = p.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o077 or info.st_size == 0:
        raise RuntimeError("protected file metadata mismatch")
encrypted = pathlib.Path("/etc/vaultwarden-oci/secrets.sops.yaml")
if recipient not in secret_owner.encrypted_recipients(encrypted):
    raise RuntimeError("existing offline recipient is missing from the SOPS ciphertext")
print("storage_volume_and_independent_markers=PASS")
print("immutable_release=0.1.0-rc.11")
print("original_offline_age_recipient=PASS")
print("sops_offline_recipient_encrypted=PASS")
print("backup_remote=unconfigured")
print("backup_retention=zero")
print("all_protected_files=root_only")
PY
then block "Installed appliance/custody/storage verification failed; see private stderr"; fi
cat "$EVIDENCE/appliance-proof.txt" | tee -a "$SUMMARY"
report PASS "Dedicated volume, protected config, release and original offline key custody checked"

[ "$(sudo -n sha256sum /usr/local/bin/sops | cut -d ' ' -f 1)" = "$SOPS_SHA256" ] ||
    block "Installed SOPS hash differs from official pinned v3.13.3 ARM64"
if ! sudo -n /usr/local/bin/sops --version > /dev/null 2>&1; then
    block "Pinned SOPS no longer executes"
fi
if ! sudo -n env SOPS_AGE_KEY_FILE=/etc/vaultwarden-oci/age-key.txt \
    /usr/local/bin/sops --decrypt --output /dev/null \
    /etc/vaultwarden-oci/secrets.sops.yaml \
    > /dev/null 2> "$EVIDENCE/sops-decrypt.private.stderr"; then
    block "Installed operational Age key cannot decrypt initial SOPS ciphertext"
fi
report PASS "Pinned SOPS binary and non-disclosing operational Age decryption verified"

# Validate byte-for-byte frozen immutable release content against original
# approved SHA while excluding audit-only files outside the release.
MATCHED=0
while IFS= read -r file; do
    expected="$(git -C "$SOURCE" show "$BASE:$file" | sha256sum | cut -d ' ' -f 1)"
    actual="$(sudo -n sha256sum "/opt/vaultwarden-oci/current/$file" | cut -d ' ' -f 1)" ||
        block "Installed release-owned file missing: $file"
    [ "$actual" = "$expected" ] ||
        block "Installed release-owned file differs from approved commit: $file"
    MATCHED=$((MATCHED + 1))
done < <(git -C "$SOURCE" ls-tree -r --name-only "$BASE" -- \
    vwctl versions.toml email-providers.toml vaultwarden_oci systemd)
[ "$MATCHED" -gt 20 ] ||
    block "Insufficient immutable release files compared against original SHA"
report PASS "$MATCHED installed immutable release-owned files match approved source checksums"

# Static service: systemctl is-enabled returns 0, which caused the false alarm
# in the original Gate A2R script. Require exact observed states, not exit
# code alone. DNS must be inactive/static and have no installed activation
# triggers; targets, app and all four timers must be inactive/disabled.
for unit in vaultwarden-oci.target vaultwarden-oci.service \
    vaultwarden-oci-backup.timer vaultwarden-oci-health.timer \
    vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer \
    vaultwarden-oci-dns.service; do
    LOAD="$(systemctl show --property=LoadState --value "$unit")" ||
        block "Cannot inspect load state of $unit"
    ACTIVE="$(systemctl show --property=ActiveState --value "$unit")" ||
        block "Cannot inspect active state of $unit"
    FILESTATE="$(systemctl show --property=UnitFileState --value "$unit")" ||
        block "Cannot inspect unit file state of $unit"
    [ "$LOAD" = loaded ] || block "Expected loaded unit missing: $unit ($LOAD)"
    [ "$ACTIVE" = inactive ] || block "Unexpected app/timer/DNS activation: $unit ($ACTIVE)"
    case "$unit" in
        vaultwarden-oci-dns.service)
            [ "$FILESTATE" = static ] ||
                block "DNS unit is not static: $FILESTATE"
            INSTALLED="/etc/systemd/system/vaultwarden-oci-dns.service"
            RELEASE_UNIT="/opt/vaultwarden-oci/current/systemd/vaultwarden-oci-dns.service"
            [ -f "$INSTALLED" ] && [ ! -L "$INSTALLED" ] &&
                sudo -n cmp -s "$INSTALLED" "$RELEASE_UNIT" ||
                block "Installed DNS unit differs from immutable approved release"
            TRIGGERS="$(systemctl show --property=TriggeredBy --value "$unit")" ||
                block "Cannot inspect DNS triggering units"
            [ -z "$TRIGGERS" ] || block "Unexpected DNS service activation trigger present"
            ;;
        *)
            [ "$FILESTATE" = disabled ] ||
                block "Unexpected enabled app/target/timer: $unit ($FILESTATE)" ;;
    esac
    printf 'systemd_unit=%s active=%s unit_file=%s\n' "$unit" "$ACTIVE" "$FILESTATE" |
        tee -a "$SUMMARY"
done
report PASS "All appliance targets/timers inactive/disabled and DNS service inactive/static"

report "NOT RUN" "Box backup retrieval, offline Age identity decryption, guided restoration"
report "NOT RUN" "Cloudflare DNS writes, VaultWarden start, any unattended timers"
report "NOT RUN" "Clean-image verification of draft rc.12 EXDEV fix"
printf 'Evidence: %s\n' "$EVIDENCE"
printf 'Share summary.txt and appliance-proof.txt only. Do not share private stderr files.\n'
