#!/usr/bin/env bash
# A6 fast-track PRE/POST attestation only.
# This file NEVER invokes restore, rclone, mkfs, systemctl start or DNS.
# Run "pre" before the product's interactive restore; "post" immediately after.
set -Eeuo pipefail
umask 077

BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
BYID="/dev/disk/by-id/scsi-36015f8fecf5e4f7ab864af5a651cc628"
ALIAS="/dev/oracleoci/oraclevdb"
SERIAL="6015f8fecf5e4f7ab864af5a651cc628"
BYTES="53687091200"
SHA="ee2b43a859ca85fb64ce20af67a3c862a2c2946ebf11df1e9fb95f880e235060"
REMOTE="bw-backup:bw-backup/recovery-20261029T223200Z-1d319a79.vwrec"
RECIPIENT_SHA="7d08721bcc02bbef7dae1f07bfde244852560c69d0b72f8dc0fcba0da30c6773"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
A5="$HOME/vwoci-acceptance/gate-a5-recovery-cancel-20261030T222929Z/summary.txt"

[ "$#" -eq 1 ] && { [ "$1" = pre ] || [ "$1" = post ]; } || {
  echo "BLOCKED: expected exactly: pre or post"
  exit 1
}
MODE="$1"
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = vaultwarden-oci-5-vnic ] || {
  echo "BLOCKED: wrong operator or disposable recovery host"; exit 1;
}
sudo -n true >/dev/null 2>&1 || { echo "BLOCKED: sudo -n unavailable"; exit 1; }
[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
  { echo "BLOCKED: wrong audit branch"; exit 1; }
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
  { echo "BLOCKED: dirty audit source"; exit 1; }
git -C "$SOURCE" cat-file -e "$BASE^{commit}" ||
  { echo "BLOCKED: approved runtime baseline unavailable"; exit 1; }
while IFS= read -r path; do
  case "$path" in
    docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md|tests/host-acceptance/*) ;;
    *) echo "BLOCKED: source modification relative to frozen release"; exit 1 ;;
  esac
done < <(git -C "$SOURCE" diff --name-only "$BASE" HEAD)
[ -f "$A5" ] && ! [ -L "$A5" ] ||
  { echo "BLOCKED: A5 operator evidence absent"; exit 1; }
grep -Fq 'PASS     Real Box pre-restore crypto completed and cancelled before all state mutation' "$A5" &&
grep -Fq 'PASS     Temporary root-owned encrypted kit copy removed' "$A5" ||
  { echo "BLOCKED: A5 cancelled restore not proven"; exit 1; }

[ -L "$BYID" ] && [ -L "$ALIAS" ] ||
  { echo "BLOCKED: missing stable data aliases"; exit 1; }
DEVICE="$(readlink -e "$BYID")"
[ "$DEVICE" = "$(readlink -e "$ALIAS")" ] &&
[ "$(lsblk -dn -o SERIAL "$DEVICE" | tr -d '[:space:]')" = "$SERIAL" ] &&
[ "$(lsblk -bdn -o SIZE "$DEVICE" | tr -d '[:space:]')" = "$BYTES" ] &&
[ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o SOURCE)" = "$DEVICE" ] &&
[ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o FSTYPE)" = ext4 ] ||
  { echo "BLOCKED: selected OCI disk, mount, serial or filesystem changed"; exit 1; }
[ "$(readlink -f /opt/vaultwarden-oci/current)" = "/opt/vaultwarden-oci/releases/0.1.0-rc.11" ] ||
  { echo "BLOCKED: immutable runtime release changed"; exit 1; }

for unit in vaultwarden-oci.target vaultwarden-oci.service \
    vaultwarden-oci-health.timer vaultwarden-oci-backup.timer \
    vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer \
    vaultwarden-oci-dns.service; do
  active="$(systemctl show -p ActiveState --value "$unit")"
  enabled="$(systemctl show -p UnitFileState --value "$unit")"
  [ "$active" = inactive ] || { echo "BLOCKED: appliance unit unexpectedly active: $unit"; exit 1; }
  if [ "$unit" = vaultwarden-oci-dns.service ]; then
    [ "$enabled" = static ] || { echo "BLOCKED: DNS unit not static"; exit 1; }
  else
    [ "$enabled" = disabled ] || { echo "BLOCKED: appliance unit enabled: $unit"; exit 1; }
  fi
done

sudo -n python3 -B -E - "$SOURCE" "$DEVICE" "$MODE" "$RECIPIENT_SHA" "$REMOTE" "$SHA" <<'PY'
import hashlib
import json
import pathlib
import sqlite3
import stat
import sys
import tomllib

sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import secrets, storage
selected = pathlib.Path(sys.argv[2]).resolve(strict=True)
mode, expected_recipient, remote, expected_sha = sys.argv[3:]
storage.reject_boot_related(str(selected))
identity = storage.verify()
if identity.fs_type != "ext4" or pathlib.Path(identity.source).resolve(strict=True) != selected:
    raise RuntimeError("dedicated volume identity invalid")
config_file = pathlib.Path("/etc/vaultwarden-oci/config.toml")
with config_file.open("rb") as file:
    config = tomllib.load(file)
recipient = config["secrets"]["offline_recovery_recipient"]
if hashlib.sha256(recipient.encode()).hexdigest() != expected_recipient:
    raise RuntimeError("offline recovery recipient mismatch")
backup = config["backup"]
statefile = pathlib.Path("/var/lib/vaultwarden-oci/state/recovery.json")
with statefile.open() as file:
    entry = json.load(file)["verified_objects"][remote]
if entry["sha256"] != expected_sha or entry["size"] != 358680:
    raise RuntimeError("A4 verified backup record changed")
db = pathlib.Path("/var/lib/vaultwarden-oci/data/db.sqlite3")
if mode == "pre":
    if db.exists() or db.is_symlink():
        raise RuntimeError("pre-restore database exists: do not overwrite previously restored data")
    for path in ("/var/lib/vaultwarden-oci/data", "/var/lib/vaultwarden-oci/caddy/data",
                 "/var/lib/vaultwarden-oci/caddy/config"):
        folder = pathlib.Path(path)
        if folder.exists() or folder.is_symlink():
            if not folder.is_dir() or folder.is_symlink() or any(folder.iterdir()):
                raise RuntimeError("pre-restore application directory unexpectedly contains data")
    if backup["remote"] or backup["local_retention_days"] or backup["remote_retention_days"]:
        raise RuntimeError("pre-restore backup automation/retention is not disabled")
    print("PASS: A6 pre-restore storage, original Age recipient and empty disposable data")
else:
    info = db.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size == 0 or info.st_uid != 65532:
        raise RuntimeError("restored Vaultwarden SQLite absent/empty/incorrect ownership")
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=15)
    try:
        if conn.execute("PRAGMA integrity_check").fetchone() != ("ok",):
            raise RuntimeError("restored SQLite integrity check did not pass")
    finally:
        conn.close()
    secrets.validate_custody(recipient)
    secrets.decrypt()
    for p in ("/var/lib/vaultwarden-oci/caddy/data", "/var/lib/vaultwarden-oci/caddy/config"):
        info = pathlib.Path(p).lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 65533:
            raise RuntimeError("restored Caddy directory or ownership missing")
    print("PASS: restored SQLite integrity and Vaultwarden/Caddy ownership")
    print("PASS: restored operational Age key/SOPS decrypt and original offline recipient")
    print("INFO: restored_backup_remote_configured=" + str(bool(backup["remote"])).lower())
    print("INFO: restored_local_retention_days=" + str(backup["local_retention_days"]))
    print("INFO: restored_remote_retention_days=" + str(backup["remote_retention_days"]))
    if backup["local_retention_days"] or backup["remote_retention_days"]:
        print("BLOCKED: retention is positive; do not enable backup timers without explicit policy review")
print("PASS: all appliance targets/timers inactive or disabled; DNS one-shot static")
print("NOT RUN: service start, backup timer, DNS publication, reboot, production cutover")
PY
