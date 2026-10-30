#!/usr/bin/env bash
# A2R: recover interrupted rc.11 setup on the SAME verified ext4 OCI volume.
# NO --confirm-format; NO mkfs; NO backup restore; NO DNS/timer/application start.
# TEMPORARY ACCEPTANCE WORKAROUND only for Ubuntu 26.04 /tmp-to-/usr/local/bin
# EXDEV in the unmodified, pinned rc.11 installer. Permanent fix: draft PR #373.
set -Eeuo pipefail
umask 077

BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
EXPECTED_HOST="vaultwarden-oci-5-vnic"
EXPECTED_RELEASE="0.1.0-rc.11"
BYID="/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628"
OCI_ALIAS="/dev/oracleoci/oraclevdb"
SERIAL="6015f8fecf5e4f7ab864af5a651cc628"
SIZE_BYTES="53687091200"
OFFLINE_PUBLIC_SHA256="7d08721bcc02bbef7dae1f07bfde244852560c69d0b72f8dc0fcba0da30c6773"
EXPECTED_SOPS_SHA256="53b0abacd38ef1b12a66d6c100956691b9cefce018d91f81e73ddf7438b94d77"
DATA_MOUNT="/var/lib/vaultwarden-oci"
ORIGINAL="$HOME/vwoci-acceptance/gate-a2-install-20261030T210031Z"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$HOME/vwoci-acceptance/gate-a2r-existing-volume-$STAMP"
mkdir -p "$OUT"
chmod 700 "$HOME/vwoci-acceptance" "$OUT"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
chmod 600 "$SUMMARY"

say() { printf '%-8s %s\n' "$1" "$2" | tee -a "$SUMMARY"; }
block() {
    say BLOCKED "$*"
    say "NOT RUN" "Box backup verification, restore, DNS or unattended timers"
    printf 'Evidence: %s\n' "$OUT"
    exit 1
}
[ "$#" -eq 0 ] || block "This controlled resume takes no arguments"
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = "$EXPECTED_HOST" ] ||
    block "Run only as ubuntu on the original disposable OCI acceptance host"
[ -t 0 ] && [ -r /dev/tty ] || block "Interactive operator terminal required"
for cmd in git python3 sudo stat lsblk findmnt wipefs sha256sum systemctl \
    grep readlink tr bash dpkg pgrep tail cut; do
    command -v "$cmd" >/dev/null 2>&1 || block "Missing required host command: $cmd"
done
sudo -n true >/dev/null 2>&1 || block "Passwordless sudo unavailable"

[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
    block "Not on pinned audit branch"
git -C "$SOURCE" cat-file -e "$BASE^{commit}" 2>/dev/null ||
    block "Approved release source baseline missing"
git -C "$SOURCE" merge-base --is-ancestor "$BASE" HEAD ||
    block "Audit source diverged from approved release"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
    block "Uncommitted tracked code exists"
while IFS= read -r file; do
    case "$file" in
        docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md|tests/host-acceptance/*) ;;
        *) block "Appliance runtime source modified relative to pinned base: $file" ;;
    esac
done < <(git -C "$SOURCE" diff --name-only "$BASE" HEAD)
if ! python3 -B - "$SOURCE/versions.toml" "$EXPECTED_RELEASE" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    value = tomllib.load(f)["vaultwarden_oci"]["version"]
if value != sys.argv[2]:
    raise SystemExit(1)
PY
then block "Release manifest is not the approved rc.11"; fi
say PASS "Unmodified approved rc.11 source, audit-only deltas, and release manifest"

. /etc/os-release
[ "$ID" = ubuntu ] && [ "$VERSION_ID" = 26.04 ] &&
    [ "$VERSION_CODENAME" = resolute ] ||
    block "Ubuntu 26.04 Resolute required"
case "$(uname -m)" in aarch64|arm64) ;; *) block "ARM64 host required" ;; esac
python3 -c 'import sys;sys.exit(0 if sys.version_info[:2]==(3,14) else 1)' ||
    block "Python 3.14 required"

# The first operator explicitly authorized this precise blank disk. This
# continuation is NOT a second authorization to format it.
[ -L "$BYID" ] && [ -L "$OCI_ALIAS" ] ||
    block "Confirmed OCI block-volume aliases missing"
DEVICE="$(readlink -e "$BYID")" || block "Selected block-volume alias broken"
[ -b "$DEVICE" ] && [ "$DEVICE" = "$(readlink -e "$OCI_ALIAS")" ] ||
    block "OCI consistent alias changed"
[ "$(lsblk -dn -o SERIAL "$DEVICE" | tr -d '[:space:]')" = "$SERIAL" ] ||
    block "Selected OCI volume serial changed"
[ "$(lsblk -bdn -o SIZE "$DEVICE" | tr -d '[:space:]')" = "$SIZE_BYTES" ] ||
    block "Selected OCI volume size changed"
[ "$(lsblk -dn -o FSTYPE "$DEVICE" | tr -d '[:space:]')" = ext4 ] ||
    block "Existing disk is not ext4 (never format)"
[ "$(lsblk -dn -o TYPE "$DEVICE" | tr -d '[:space:]')" = disk ] ||
    block "Selected device is not a whole disk"
[ -z "$(lsblk -nr -o NAME "$DEVICE" | tail -n +2)" ] ||
    block "Unexpected partitions/children on the verified filesystem"
[ "$(findmnt -rn -M "$DATA_MOUNT" -o SOURCE)" = "$DEVICE" ] ||
    block "Vaultwarden mount source no longer equals approved disk"
[ "$(findmnt -rn -M "$DATA_MOUNT" -o FSTYPE)" = ext4 ] ||
    block "Vaultwarden mount filesystem changed"

if ! sudo -n python3 -B -E - "$SOURCE" "$DEVICE" > "$OUT/storage-proof.txt" \
    2> "$OUT/storage-proof.private.stderr" <<'PY'
import pathlib, sys
sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import storage
storage.reject_boot_related(sys.argv[2])
identity = storage.verify()
if identity.fs_type != "ext4":
    raise RuntimeError("non-ext4 installed storage")
if pathlib.Path(identity.source).resolve(strict=True) != pathlib.Path(sys.argv[2]).resolve(strict=True):
    raise RuntimeError("storage identity differs from previously approved disk")
print("storage_identity=PASS")
print("host_identity_and_volume_marker=PASS")
print("mount_matches_selected_block_volume=PASS")
PY
then block "Existing filesystem identity/volume marker no longer match"; fi
say PASS "Approved ext4 filesystem, mounted identity, root-disk guard and volume marker"

# Confirm this is the unique partial install, without old secrets or application.
[ -f "$ORIGINAL/install.private.log" ] &&
[ -f "$ORIGINAL/summary.txt" ] ||
    block "Original Gate A2 evidence is missing"
grep -Fq 'PASS     Original recovery-kit offline private identity derives exact supplied public recipient' \
    "$ORIGINAL/summary.txt" || block "Original offline private identity check has not passed"
grep -Fq 'PASS     Operator explicitly authorized formatting the identified test volume' \
    "$ORIGINAL/summary.txt" || block "Original disk-format authorization not in evidence"
grep -Fq 'FAIL     Installer returned rc=1' "$ORIGINAL/summary.txt" ||
    block "No original interrupted installation in evidence"
if ! python3 -B - "$ORIGINAL/install.private.log" <<'PY'
from pathlib import Path
import sys
log = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
tokens = ("[Errno 18]", "Invalid cross-device link", "vwoci-sops-", "/usr/local/bin/sops")
if not all(token in log for token in tokens):
    raise SystemExit(1)
PY
then block "Original error was not proven to be SOPS cross-filesystem rename; do not guess"; fi
say PASS "Original private log confirms SOPS EXDEV cross-filesystem publish failure"

for path in /opt/vaultwarden-oci/current \
    "/opt/vaultwarden-oci/releases/$EXPECTED_RELEASE" \
    /etc/vaultwarden-oci/config.toml \
    /etc/vaultwarden-oci/age-key.txt \
    /etc/vaultwarden-oci/secrets.sops.yaml \
    /usr/local/bin/sops; do
    if sudo -n test -e "$path" || sudo -n test -L "$path"; then
        block "Unexpected partial install state needs independent review: $path"
    fi
done
for unit in vaultwarden-oci.target vaultwarden-oci.service \
    vaultwarden-oci-dns.service vaultwarden-oci-backup.timer; do
    if systemctl is-active --quiet "$unit" ||
       systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        block "Unexpected enabled/active Vaultwarden service: $unit"
    fi
done
if [ -n "$(sudo -n dpkg --audit)" ]; then
    block "Package database has incomplete configuration"
fi
for name in apt-get dpkg; do
    if pgrep -x "$name" >/dev/null 2>&1; then
        block "Existing package manager process still active: $name"
    fi
done
say PASS "No existing release, config, SOPS, secrets or running appliance automation"

# /tmp was the original source of EXDEV; choose a verified, same-root-FS
# TMPDIR for the existing *unmodified* setup.py TemporaryDirectory invocation.
# Use sudo env after privilege elevation so sudo does not discard TMPDIR.
TMPBASE="/var/tmp"
if ! sudo -n python3 -B -E - "$TMPBASE" <<'PY'
import os, stat, sys
base = sys.argv[1]
source = os.stat(base)
destination = os.stat("/usr/local/bin")
if any(os.path.islink(p) for p in (base, "/usr/local/bin")):
    raise SystemExit(1)
if not stat.S_ISDIR(source.st_mode) or not stat.S_ISDIR(destination.st_mode):
    raise SystemExit(1)
if source.st_dev != destination.st_dev:
    raise SystemExit(1)
if source.st_uid != 0 or destination.st_uid != 0:
    raise SystemExit(1)
if stat.S_IMODE(source.st_mode) & 0o002 and not source.st_mode & stat.S_ISVTX:
    raise SystemExit(1)
PY
then
    block "/var/tmp is NOT on the same filesystem as /usr/local/bin; no resume attempted"
fi
ACTUAL_TEMP="$(sudo -n env TMPDIR="$TMPBASE" python3 -B -E -c 'import tempfile;print(tempfile.gettempdir())')"
[ "$ACTUAL_TEMP" = "$TMPBASE" ] ||
    block "Elevated Python does not honor the same-filesystem TMPDIR"
say PASS "Root Python TMPDIR=/var/tmp is on the same filesystem as /usr/local/bin"

printf '\nREQUIRED PUBLIC RECIPIENT (from previously verified emailed kit):\n'
IFS= read -r -p "Paste the same offline PUBLIC Age recipient (age1...): " RECIPIENT </dev/tty ||
    block "Missing public recipient"
[[ "$RECIPIENT" =~ ^age1[0-9a-z]{50,70}$ ]] ||
    block "Invalid public recipient syntax"
HASH="$(printf '%s' "$RECIPIENT" | sha256sum | cut -d ' ' -f 1)"
[ "$HASH" = "$OFFLINE_PUBLIC_SHA256" ] ||
    block "Public Age recipient does not match original emailed-kit recipient"

printf '\nOriginal site configuration:\n'
printf ' Domain: bw.lazymocha.com\n HTTPS URL: https://bw.lazymocha.com\n'
printf ' Contact: bw@lazymocha.com\n'
DOMAIN="bw.lazymocha.com"
URL="https://bw.lazymocha.com"
EMAIL="bw@lazymocha.com"

if ! sudo -n env TMPDIR="$TMPBASE" NO_COLOR=1 bash "$SOURCE/setup.sh" install \
    --domain "$DOMAIN" --url "$URL" --email "$EMAIL" \
    --data-device "$BYID" --offline-recipient "$RECIPIENT" \
    --auto --dry-run > "$OUT/setup-dryrun.private.log" 2>&1; then
    block "Actual installer --dry-run rejected exact existing-volume inputs"
fi
grep -Fq 'dry run: no filesystem, package, config, secret, or systemd changes were made' \
    "$OUT/setup-dryrun.private.log" ||
    block "Installer dry-run did not confirm no mutation"
say PASS "Actual installer dry-run succeeds with exact approved recipient/domain/volume"

printf '\n============================================================\n'
printf 'PARTIAL-INSTALL CONTINUATION ON THE EXISTING DATA VOLUME\n'
printf ' Host: %s\n' "$EXPECTED_HOST"
printf ' Source release: %s (unchanged)\n' "$EXPECTED_RELEASE"
printf ' Data volume: %s\n' "$BYID"
printf ' Resolved: %s\n' "$DEVICE"
printf ' Serial: %s\n' "$SERIAL"
printf ' Filesystem: ext4, ALREADY mounted, verified by two markers\n'
printf ' Installer flag: --accept-existing-filesystem\n'
printf ' SOPS temp workaround: TMPDIR=%s (same device as /usr/local/bin)\n' "$TMPBASE"
printf ' FORBIDDEN: --confirm-format, mkfs, restore, DNS changes, service enable/start\n'
printf '============================================================\n'
ACK_REQUIRED="RESUME EXISTING $SERIAL"
printf 'To authorize continuing on the existing disk without formatting, type:\n%s\n' "$ACK_REQUIRED"
IFS= read -r -p "Authorization: " ACK </dev/tty ||
    block "Continuation not authorized"
[ "$ACK" = "$ACK_REQUIRED" ] ||
    block "Existing-volume continuation was not explicitly authorized"

# Re-verify identity at the state-change boundary. Do not restart if this fails.
[ "$DEVICE" = "$(readlink -e "$BYID")" ] &&
[ "$DEVICE" = "$(readlink -e "$OCI_ALIAS")" ] ||
    block "Storage alias changed before continuation"
if ! sudo -n python3 -B -E - "$SOURCE" <<'PY' >/dev/null 2>&1
import sys
sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import storage
storage.verify()
PY
then block "Volume identity/marker failed on final pre-mutation recheck"; fi
say PASS "Final disk identity guard passed; explicit non-formatting continuation authorized"

say INFO "Resuming supported pinned setup on existing filesystem; private log remains local"
if sudo -n env TMPDIR="$TMPBASE" NO_COLOR=1 bash "$SOURCE/setup.sh" install \
    --domain "$DOMAIN" --url "$URL" --email "$EMAIL" \
    --data-device "$BYID" --offline-recipient "$RECIPIENT" \
    --accept-existing-filesystem --auto > "$OUT/resume.private.log" 2>&1; then
    say PASS "Supported existing-filesystem setup completed without --confirm-format"
else
    RC=$?
    say FAIL "Setup continuation failed (exit $RC). State may now be partially installed"
    say BLOCKED "Do not rerun, reformat, reinstall or enable services until private log is reviewed"
    printf 'Private log: %s\n' "$OUT/resume.private.log"
    exit 1
fi

# Read-only installation verification. Do not start systemd target.
if ! sudo -n python3 -B -E - "$SOURCE" "$DEVICE" "$RECIPIENT" "$EXPECTED_RELEASE" \
    > "$OUT/post-install.txt" 2> "$OUT/post-install.private.stderr" <<'PY'
import os, pathlib, stat, sys, tomllib
sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import storage
resolved = pathlib.Path("/opt/vaultwarden-oci/current").resolve(strict=True)
if resolved != pathlib.Path("/opt/vaultwarden-oci/releases") / sys.argv[4]:
    raise RuntimeError("installed release differs from immutable rc.11")
identity = storage.verify()
if pathlib.Path(identity.source).resolve(strict=True) != pathlib.Path(sys.argv[2]).resolve(strict=True):
    raise RuntimeError("installed storage does not match the approved volume")
with open("/etc/vaultwarden-oci/config.toml", "rb") as stream:
    config = tomllib.load(stream)
if config["secrets"]["offline_recovery_recipient"] != sys.argv[3]:
    raise RuntimeError("installed config changed the existing recovery recipient")
if config["backup"]["remote"] != "" or config["backup"]["local_retention_days"] != 0 \
   or config["backup"]["remote_retention_days"] != 0:
    raise RuntimeError("initial backup publishing or retention is not disabled")
for filename in ("config.toml", "age-key.txt", "secrets.sops.yaml", "storage-identity.json"):
    path = pathlib.Path("/etc/vaultwarden-oci") / filename
    value = path.lstat()
    if not stat.S_ISREG(value.st_mode) or value.st_uid != 0 or stat.S_IMODE(value.st_mode) & 0o077:
        raise RuntimeError("sensitive file permissions/ownership invalid: " + filename)
    if value.st_size == 0:
        raise RuntimeError("sensitive file was empty: " + filename)
print("installed_release=" + sys.argv[4])
print("dedicated_storage=PASS")
print("offline_public_recipient=preserved")
print("initial_offsite_remote=disabled")
print("local_retention_days=0")
print("remote_retention_days=0")
print("sensitive_state=root_only")
PY
then block "Installed release, storage, recipient or sensitive-state verification failed"; fi
say PASS "Installed rc.11, verified dedicated storage, original offline recipient and root-only secrets"

[ "$(sudo -n sha256sum /usr/local/bin/sops | cut -d ' ' -f 1)" = "$EXPECTED_SOPS_SHA256" ] ||
    block "Installed SOPS differs from pinned official ARM64 SHA-256"
sudo -n /usr/local/bin/sops --version >/dev/null 2>&1 ||
    block "Pinned installed SOPS does not execute"
say PASS "SOPS v3.13.3 matches official SHA-256 and executes"

for unit in vaultwarden-oci.target vaultwarden-oci.service \
    vaultwarden-oci-backup.timer vaultwarden-oci-dns.service; do
    if systemctl is-active --quiet "$unit" ||
       systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        block "Unexpected active/enabled app or DNS/timer unit: $unit"
    fi
done
say PASS "Appliance target, DNS service and backup timer remain inactive/disabled"
say "NOT RUN" "Box archive download/decryption verification, restore or DNS cutover"
say "NOT RUN" "Upstream PR #373 validation on clean Ubuntu 26.04 with new pinned release"
printf 'Evidence: %s\n' "$OUT"
printf 'Share summary.txt and post-install.txt only, not private logs.\n'
