#!/usr/bin/env bash
# Gate A2: operator-authorized fresh-host installation on the disposable OCI host.
# DESTRUCTIVE ONLY AFTER EXACT TYPED CONSENT: format one blank 50 GiB data disk.
# No restore, DNS write, application start, Worker setup or timer enable.
set -Eeuo pipefail
umask 077

BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
HOST="vaultwarden-oci-5-vnic"
BYID="/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628"
ALIAS="/dev/oracleoci/oraclevdb"
SERIAL="6015f8fecf5e4f7ab864af5a651cc628"
BYTES="53687091200"
RELEASE="0.1.0-rc.11"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$HOME/vwoci-acceptance/gate-a2-install-$STAMP"
mkdir -p "$OUT"
chmod 700 "$HOME/vwoci-acceptance" "$OUT"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
chmod 600 "$SUMMARY"
say() { printf '%-8s %s\n' "$1" "$2" | tee -a "$SUMMARY"; }
stop() {
  say "$1" "$2"
  say "NOT RUN" "Restore, Box retrieval, DNS cutover and unattended backup timer"
  printf 'Evidence: %s\n' "$OUT"
  exit 1
}

[ "$#" -eq 0 ] || stop BLOCKED "No arguments supported"
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = "$HOST" ] ||
  stop BLOCKED "Run as ubuntu on the exact disposable acceptance host only"
[ -t 0 ] && [ -r /dev/tty ] || stop BLOCKED "Interactive terminal required"
for cmd in git python3 sudo lsblk wipefs readlink sha256sum systemctl bash grep tr cut; do
  command -v "$cmd" >/dev/null 2>&1 || stop BLOCKED "Missing: $cmd"
done
[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
  stop BLOCKED "Wrong audit branch"
git -C "$SOURCE" cat-file -e "$BASE^{commit}" 2>/dev/null ||
  stop BLOCKED "Missing approved rc.11 baseline"
git -C "$SOURCE" merge-base --is-ancestor "$BASE" HEAD ||
  stop FAIL "Audit source not descended from approved baseline"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
  stop BLOCKED "Uncommitted tracked source changes"
while IFS= read -r path; do
  case "$path" in
    tests/host-acceptance/*|docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md) ;;
    *) stop FAIL "Unexpected appliance source change: $path" ;;
  esac
done < <(git -C "$SOURCE" diff --name-only "$BASE" HEAD)
git -C "$SOURCE" diff --quiet "$BASE" HEAD -- vwctl versions.toml \
  email-providers.toml vaultwarden_oci systemd ||
  stop FAIL "Release source changed against approved commit"
if ! python3 - "$SOURCE/versions.toml" "$RELEASE" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)
assert data["vaultwarden_oci"]["version"] == sys.argv[2]
PY
then stop FAIL "Release version differs from rc.11"; fi
say PASS "Exact rc.11 runtime source and audit-only branch verified"

. /etc/os-release
[ "$ID" = ubuntu ] && [ "$VERSION_ID" = 26.04 ] &&
  [ "$VERSION_CODENAME" = resolute ] ||
  stop BLOCKED "Require Ubuntu 26.04 Resolute"
case "$(uname -m)" in aarch64|arm64) ;; *) stop BLOCKED "Require ARM64" ;; esac
python3 -c 'import sys;sys.exit(0 if sys.version_info[:2]==(3,14) else 1)' ||
  stop BLOCKED "Require native Python 3.14"
sudo -n true >/dev/null 2>&1 || stop BLOCKED "Passwordless sudo unavailable"
say PASS "Supported Ubuntu 26.04 ARM64 and noninteractive sudo"

for path in /opt/vaultwarden-oci /etc/vaultwarden-oci \
  /var/lib/vaultwarden-oci /run/vaultwarden-oci; do
  if sudo -n test -e "$path" || sudo -n test -L "$path"; then
    stop BLOCKED "Existing or partial appliance path: $path"
  fi
done
for unit in vaultwarden-oci.target vaultwarden-oci.service \
  vaultwarden-oci-health.timer vaultwarden-oci-backup.timer \
  vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer; do
  if systemctl is-active --quiet "$unit" ||
     systemctl is-enabled --quiet "$unit" 2>/dev/null; then
    stop BLOCKED "Existing appliance activation: $unit"
  fi
done
say PASS "Fresh/uninstalled appliance, no scheduled or running services"

[ -L "$BYID" ] && [ -L "$ALIAS" ] || stop BLOCKED "Expected OCI disk aliases missing"
DISK="$(readlink -e "$BYID")" || stop BLOCKED "By-id device no longer resolves"
[ -b "$DISK" ] && [ "$DISK" = "$(readlink -e "$ALIAS")" ] ||
  stop BLOCKED "OCI device alias no longer resolves to the selected disk"
[ "$(sudo -n lsblk -bdn -o SIZE "$DISK" | tr -d '[:space:]')" = "$BYTES" ] ||
  stop BLOCKED "Disk capacity mismatch"
[ "$(sudo -n lsblk -dn -o SERIAL "$DISK" | tr -d '[:space:]')" = "$SERIAL" ] ||
  stop BLOCKED "Disk serial mismatch"

# Call the product's boot-device ancestry check, and prove the disk is blank.
if ! sudo -n python3 -B -E - "$SOURCE" "$BYID" "$BYTES" > "$OUT/disk-report.txt" 2> "$OUT/disk-report.stderr" <<'PY'
import json, pathlib, subprocess, sys
sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import storage
path = pathlib.Path(sys.argv[2]).resolve(strict=True)
storage.reject_boot_related(str(path))
x = subprocess.run(["lsblk", "-J", "-b", "-p", "-o",
    "PATH,TYPE,SIZE,FSTYPE,PTTYPE,UUID,MOUNTPOINTS", str(path)],
    capture_output=True, text=True, check=True)
rows = json.loads(x.stdout).get("blockdevices", [])
if len(rows) != 1 or rows[0].get("type") != "disk":
    raise RuntimeError("not one whole disk")
r = rows[0]
if int(r.get("size") or 0) != int(sys.argv[3]) or r.get("children"):
    raise RuntimeError("size/partition tree mismatch")
if r.get("fstype") or r.get("pttype") or r.get("uuid") or any(r.get("mountpoints") or []):
    raise RuntimeError("disk is not provably blank and unmounted")
p = subprocess.run(["wipefs", "--noheadings", "--output", "TYPE", str(path)],
                   capture_output=True, text=True, check=True)
if p.stdout.strip():
    raise RuntimeError("filesystem or partition signatures present")
if not any(pathlib.Path(row["path"]).resolve(strict=True) == path
           for row in storage.inventory()):
    raise RuntimeError("disk excluded by product inventory")
print("device=" + str(path))
print("capacity_bytes=" + sys.argv[3])
print("boot_related=no")
print("mounted=no")
print("partition_children=no")
print("recognized_signatures=none")
PY
then stop BLOCKED "Disk no longer meets blank, non-boot, 50 GiB preflight"; fi
say PASS "Exact OCI-alias disk, serial, size and blank state reverified"

printf '\nRecovery custody is mandatory BEFORE the disk is formatted.\n'
printf 'The emailed AES-256 recovery-kit ZIP contains the existing offline Age identity.\n'
printf 'Use ONLY the PUBLIC age1... value printed by the prior kit-config check.\n'
printf 'This script will verify the matching private identity in RAM without writing it.\n'
printf 'The ORIGINAL encrypted ZIP and its passphrase must remain in off-host custody.\n'
printf 'Do NOT paste private keys, recovery passwords or cloud tokens.\n\n'
IFS= read -r -p "Existing OFFLINE Age PUBLIC recipient (age1...): " RECIPIENT </dev/tty ||
  stop BLOCKED "Public recipient not supplied"
if [ -z "$RECIPIENT" ]; then
  stop BLOCKED "No existing public Age recipient provided. This NEW host cannot generate a replacement key that decrypts the OLD Box backup. Find the original offline recovery kit or offline private identity first; no disk changes have occurred."
fi
[[ "$RECIPIENT" =~ ^age1[0-9a-z]{50,70}$ ]] ||
  stop BLOCKED "Invalid public Age recipient. Reuse only the exact age1... recipient from the successfully decrypted EMAIL recovery kit."

# Verify the actual emailed offline private identity before the destructive gate.
# The helper extracts only two ZIP members in process memory. It never prints
# or persists the private identity, password, or credential member.
KIT="$HOME/vaultwarden-recovery-kit-20261006T222828Z.zip"
HELPER="$SOURCE/tests/host-acceptance/07-kit-identity-match-ubuntu.py"
[ -f "$KIT" ] && [ ! -L "$KIT" ] ||
  stop BLOCKED "Expected emailed recovery kit missing: $KIT"
[ -f "$HELPER" ] || stop BLOCKED "Missing in-memory offline-key verification helper"
command -v 7zz >/dev/null 2>&1 || command -v 7z >/dev/null 2>&1 ||
  stop BLOCKED "7-Zip missing; install Ubuntu 7zip first"
command -v age-keygen >/dev/null 2>&1 ||
  stop BLOCKED "age-keygen missing; install Ubuntu 'age' before running Gate A2"
if python3 -B "$HELPER" "$KIT" "$RECIPIENT" | tee "$OUT/kit-identity-verification.txt"; then
  say PASS "Original recovery-kit offline private identity derives exact supplied public recipient"
else
  stop BLOCKED "Offline private-key verification failed; disk formatting is forbidden"
fi

printf '\nThis match does NOT yet prove decryption of the existing Box .vwrec.\n'
printf 'The original encrypted kit, its passphrase and Box access must remain in\n'
printf 'your independent OFF-HOST custody. No new offline Age identity was generated.\n'
IFS= read -r -p "Type KIT HELD OFFHOST to attest existing ZIP/passphrase custody: " CUSTODY </dev/tty ||
  stop BLOCKED "Independent recovery-kit custody not confirmed"
[ "$CUSTODY" = "KIT HELD OFFHOST" ] ||
  stop BLOCKED "Independent recovery-kit custody not confirmed"
say PASS "Operator attested off-host encrypted kit and passphrase custody"

printf '\nFirst-install site values are temporary until the older vault is restored.\n'
printf 'This command WILL NOT publish the public hostname or enable DNS timers.\n'
IFS= read -r -p "Intended vault domain/hostname: " DOMAIN </dev/tty ||
  stop BLOCKED "Missing domain"
IFS= read -r -p "Intended HTTPS URL (https://...): " URL </dev/tty ||
  stop BLOCKED "Missing URL"
IFS= read -r -p "Administrator/contact email: " EMAIL </dev/tty ||
  stop BLOCKED "Missing email"

# Real argument validation; no --confirm-format in dry run.
if ! NO_COLOR=1 sudo -n bash "$SOURCE/setup.sh" install \
  --domain "$DOMAIN" --url "$URL" --email "$EMAIL" \
  --data-device "$BYID" --offline-recipient "$RECIPIENT" \
  --auto --dry-run > "$OUT/setup-dryrun.private.log" 2>&1; then
  stop BLOCKED "Exact setup dry-run refused input; see private log"
fi
grep -Fq 'dry run: no filesystem, package, config, secret, or systemd changes were made' \
  "$OUT/setup-dryrun.private.log" ||
  stop FAIL "Setup dry-run lacked its expected no-mutation confirmation"
say PASS "Exact site/recipient/device accepted by genuine setup --dry-run"

printf '\n====================================================\n'
printf 'ERASE CONFIRMATION REQUIRED -- DISPOSABLE DATA DISK\n'
printf 'Host: %s\nDevice: %s\nOCI alias: %s\n' "$HOST" "$BYID" "$ALIAS"
printf 'Resolved disk: %s\nSerial: %s\nSize: 50 GiB\n' "$DISK" "$SERIAL"
printf 'Action: FORMAT the entire blank data volume as ext4, install pinned rc.11\n'
printf 'Not performed: backup restore, DNS changes, timers, or app start\n'
printf '====================================================\n'
ACK_REQUIRED="ERASE $SERIAL"
printf 'To authorize erasing only this confirmed volume, type:\n%s\n' "$ACK_REQUIRED"
IFS= read -r -p "Authorization: " ACK </dev/tty ||
  stop BLOCKED "Formatting not authorized"
[ "$ACK" = "$ACK_REQUIRED" ] ||
  stop BLOCKED "Exact per-volume erase authorization NOT received"
say PASS "Operator explicitly authorized formatting the identified test volume"

# Recheck the exact target at the irreversible boundary, after typed consent.
[ "$DISK" = "$(readlink -e "$BYID")" ] &&
[ "$DISK" = "$(readlink -e "$ALIAS")" ] &&
[ "$(sudo -n lsblk -bdn -o SIZE "$DISK" | tr -d '[:space:]')" = "$BYTES" ] &&
[ "$(sudo -n lsblk -dn -o SERIAL "$DISK" | tr -d '[:space:]')" = "$SERIAL" ] ||
  stop BLOCKED "Disk alias, size, or serial changed after authorization"
[ -z "$(sudo -n wipefs --noheadings --output TYPE "$DISK")" ] ||
  stop BLOCKED "Disk signatures changed after authorization"
say PASS "Final stable device identity and blank signatures rechecked immediately before formatting"

say INFO "Installing pinned appliance and host dependencies; raw log remains PRIVATE"
if NO_COLOR=1 sudo -n bash "$SOURCE/setup.sh" install \
  --domain "$DOMAIN" --url "$URL" --email "$EMAIL" \
  --data-device "$BYID" --offline-recipient "$RECIPIENT" \
  --confirm-format --auto > "$OUT/install.private.log" 2>&1; then
  say PASS "Supported installer completed"
else
  RC=$?
  say FAIL "Installer returned rc=$RC; state may be partially installed"
  say BLOCKED "Do not repeat formatting, clean up disks, or rerun setup without reviewing private evidence"
  printf 'Private installer log: %s\n' "$OUT/install.private.log"
  exit 1
fi

if ! sudo -n python3 -B -E - "$DISK" "$RECIPIENT" "$RELEASE" \
  > "$OUT/post-install.txt" 2> "$OUT/post-install.stderr" <<'PY'
import os, pathlib, stat, sys, tomllib
sys.path.insert(0, "/opt/vaultwarden-oci/current")
from vaultwarden_oci import storage
release = pathlib.Path("/opt/vaultwarden-oci/current").resolve(strict=True)
if release != pathlib.Path("/opt/vaultwarden-oci/releases") / sys.argv[3]:
    raise RuntimeError("unexpected immutable release")
identity = storage.verify()
if pathlib.Path(identity.source).resolve(strict=True) != pathlib.Path(sys.argv[1]):
    raise RuntimeError("dedicated mount not the approved disk")
with open("/etc/vaultwarden-oci/config.toml", "rb") as f:
    config = tomllib.load(f)
if config["secrets"]["offline_recovery_recipient"] != sys.argv[2]:
    raise RuntimeError("offline recipient was changed")
backup = config["backup"]
if backup.get("remote") != "" or backup.get("local_retention_days") != 0 or backup.get("remote_retention_days") != 0:
    raise RuntimeError("unexpected backup publishing/retention policy")
for filename in ("config.toml", "age-key.txt", "secrets.sops.yaml", "storage-identity.json"):
    path = "/etc/vaultwarden-oci/" + filename
    info = os.stat(path, follow_symlinks=False)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_size == 0 or stat.S_IMODE(info.st_mode) & 0o077:
        raise RuntimeError("invalid protected file/permissions: " + filename)
print("installed_release=" + sys.argv[3])
print("dedicated_storage=PASS")
print("source_device=" + identity.source)
print("filesystem=" + identity.fs_type)
print("offline_public_recipient=preserved")
print("initial_remote_publication=disabled")
print("local_retention_days=0")
print("remote_retention_days=0")
print("protected_credentials=root_only")
PY
then stop FAIL "Installed storage/custody/policy validation failed; do not enable any timers"; fi
say PASS "Protected config, Age/SOPS starting point, dedicated storage and safe retention verified"

matched=0
while IFS= read -r p; do
  expected="$(git -C "$SOURCE" show "$BASE:$p" | sha256sum | cut -d ' ' -f1)"
  actual="$(sudo -n sha256sum "/opt/vaultwarden-oci/current/$p" | cut -d ' ' -f1)" ||
    stop FAIL "Installed release file missing: $p"
  [ "$expected" = "$actual" ] || stop FAIL "Installed release byte mismatch: $p"
  matched=$((matched + 1))
done < <(git -C "$SOURCE" ls-tree -r --name-only "$BASE" -- vwctl versions.toml email-providers.toml vaultwarden_oci systemd)
[ "$matched" -gt 20 ] || stop FAIL "Insufficient release-owned files verified"
say PASS "$matched installed release-owned files match approved base commit SHA-256"

if ! sudo -n /opt/vaultwarden-oci/current/vwctl versions \
  > "$OUT/versions.txt" 2> "$OUT/versions.stderr"; then
  stop FAIL "Installed vwctl cannot report component pins"
fi
say PASS "Installed vwctl versions command works"

for unit in vaultwarden-oci.target vaultwarden-oci.service \
  vaultwarden-oci-health.timer vaultwarden-oci-backup.timer \
  vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer \
  vaultwarden-oci-dns.service; do
  if systemctl is-active --quiet "$unit" ||
     systemctl is-enabled --quiet "$unit" 2>/dev/null; then
    stop BLOCKED "Unexpected active/enabled appliance or DNS service: $unit"
  fi
done
say PASS "Appliance target, DNS service, and four timers remain inactive and disabled"

say "NOT RUN" "External Box ciphertext readback, SHA-256 verification or Age decryption"
say "NOT RUN" "Guided restore cancellation or separately authorized destructive restore"
say "NOT RUN" "Application/Cloudflare security activation, real notifications, DNS cutover and reboot"
printf 'Evidence: %s\n' "$OUT"
printf 'Share summary.txt and post-install.txt only. Keep raw logs private.\n'
