#!/usr/bin/env bash
# Gate A0: fresh-host/dedicated-storage preflight. NO appliance or disk mutations.
# Creates only private, timestamped evidence under the login user's home directory.
set -Eeuo pipefail
umask 077

BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="$HOME/vwoci-acceptance/gate-a0-fresh-host-$STAMP"
SUMMARY="$EVDIR/summary.txt"

mkdir -p "$EVDIR"
chmod 700 "$HOME/vwoci-acceptance" "$EVDIR"
: > "$SUMMARY"
chmod 600 "$SUMMARY"
printf 'Gate A0, UTC %s\nSource: %s\n' "$(date -u --iso-8601=seconds)" "$SOURCE" > "$EVDIR/metadata.txt"

say() {
    printf '%-8s %s\n' "$1" "$2" | tee -a "$SUMMARY"
}
stop() {
    say "$1" "$2"
    say "NOT RUN" "Installation, disk provisioning, remote recovery and DNS operations"
    printf 'Evidence: %s\n' "$EVDIR"
    exit 1
}

[ "$(id -u)" -ne 0 ] || stop BLOCKED "Run as the unprivileged ubuntu login user"
for bin in git python3 sudo lsblk findmnt wipefs systemctl bash grep; do
    command -v "$bin" >/dev/null 2>&1 || stop BLOCKED "Missing read-only preflight command: $bin"
done
[ -f "$SOURCE/setup.sh" ] || stop BLOCKED "Expected audited source checkout not found"
[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
    stop BLOCKED "Wrong branch: this audit must use the dedicated audit checkout"
git -C "$SOURCE" cat-file -e "$BASE^{commit}" 2>/dev/null ||
    stop BLOCKED "Approved baseline commit is absent"
git -C "$SOURCE" merge-base --is-ancestor "$BASE" HEAD ||
    stop FAIL "Source is not descended from the approved release baseline"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
    stop BLOCKED "Source checkout has modified tracked files"
git -C "$SOURCE" diff --name-only "$BASE" HEAD > "$EVDIR/source-diff-paths.txt"
while IFS= read -r name; do
    case "$name" in
        tests/host-acceptance/*|docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md) ;;
        *) stop FAIL "Audit branch unexpectedly modifies a production-source path: $name" ;;
    esac
done < "$EVDIR/source-diff-paths.txt"
say PASS "Approved rc.11 baseline and audit-only branch delta verified"

. /etc/os-release
[ "$ID" = ubuntu ] && [ "$VERSION_ID" = 26.04 ] &&
    [ "$VERSION_CODENAME" = resolute ] || stop FAIL "Require Ubuntu 26.04 Resolute"
case "$(uname -m)" in aarch64|arm64) ;; *) stop FAIL "Require OCI ARM64 host" ;; esac
python3 -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3,14) else 1)' ||
    stop FAIL "Require native Python 3.14"
sudo -n true >/dev/null 2>&1 || stop BLOCKED "Passwordless sudo -n unavailable"
say PASS "Ubuntu 26.04 ARM64, Python 3.14, sudo -n available"

# Prevent accidental execution on an installed or partially installed appliance.
for path in /opt/vaultwarden-oci /etc/vaultwarden-oci /var/lib/vaultwarden-oci /run/vaultwarden-oci; do
    if sudo -n test -e "$path" || sudo -n test -L "$path"; then
        stop BLOCKED "Appliance path already exists: $path; do not assume this host is disposable"
    fi
done
for unit in vaultwarden-oci.target vaultwarden-oci-health.timer \
    vaultwarden-oci-backup.timer vaultwarden-oci-maintenance.timer \
    vaultwarden-oci-update-check.timer; do
    if systemctl is-active --quiet "$unit" || systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        stop BLOCKED "Appliance unit is enabled or active: $unit"
    fi
done
say PASS "No installed appliance path or active/enabled appliance automation"

findmnt -n -o SOURCE,FSTYPE,TARGET --target / > "$EVDIR/root-filesystem.txt" ||
    stop FAIL "Could not inspect root filesystem"
lsblk -J -b -p -o PATH,TYPE,SIZE,FSTYPE,MOUNTPOINTS,UUID,MODEL \
    > "$EVDIR/lsblk.json" || stop FAIL "Could not inspect block-device inventory"

# Reuse the precise product root-ancestry filter, instead of trying to
# identify a safe disk by guessing that it is /dev/sdb or /dev/vdb.
if ! sudo -n python3 -B -E - "$SOURCE" > "$EVDIR/candidates.txt" 2> "$EVDIR/inventory.stderr" <<'PY'
import pathlib
import subprocess
import sys

sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import storage

root = storage.root_source()
print("ROOT_DEVICE=" + root)
rows = storage.inventory()
usable = 0
if not rows:
    print("NO_NONBOOT_DEVICES")
for row in rows:
    path = str(row["path"])
    fs = str(row["fstype"]) or "none"
    mounts = tuple(row["mountpoints"])
    probe = subprocess.run(
        ["wipefs", "--noheadings", "--output", "TYPE", path],
        capture_output=True, text=True, check=False,
    )
    if probe.returncode:
        signatures = "unavailable"
    else:
        types = sorted(set(probe.stdout.split()))
        signatures = ",".join(types) if types else "none-detected"
    by_id = []
    folder = pathlib.Path("/dev/disk/by-id")
    if folder.is_dir():
        for link in folder.iterdir():
            try:
                if link.is_symlink() and link.resolve(strict=True) == pathlib.Path(path).resolve(strict=True):
                    by_id.append(str(link))
            except OSError:
                continue
    if mounts:
        category = "MOUNTED_REVIEW_REQUIRED"
    elif fs in ("none", "ext4", "xfs") and signatures != "unavailable":
        category = "POSSIBLE_NONBOOT_DEVICE_NOT_APPROVED"
        usable += 1
    else:
        category = "UNSUPPORTED_OR_UNKNOWN_SIGNATURES"
    print("DEVICE=" + path)
    print("  type=" + str(row["type"]) +
          " size_GiB=" + format(int(row["size"]) / 1073741824, ".2f") +
          " fs=" + fs + " mounted=" + str(bool(mounts)).lower() +
          " signature_types=" + signatures)
    print("  stable_by_id=" + (", ".join(sorted(by_id)) or "(none found)"))
    print("  category=" + category)
print("POSSIBLE_NONBOOT_DEVICES=" + str(usable))
PY
then
    stop FAIL "Source-owned storage inventory failed (private inventory.stderr)"
fi

cat "$EVDIR/candidates.txt" | tee "$EVDIR/displayed-inventory.txt"
ROOT_DEVICE="$(sed -n 's/^ROOT_DEVICE=//p' "$EVDIR/candidates.txt" | head -n 1)"
[ -n "$ROOT_DEVICE" ] || stop FAIL "Root device could not be resolved"
say PASS "Non-boot candidates enumerated without mounting or formatting any device"

# Exercise the actual setup front-end fail-closed boot-disk check, under --dry-run.
# The deliberately dummy audit hostname and missing private key are never persisted.
set +e
NO_COLOR=1 sudo -n bash "$SOURCE/setup.sh" install \
    --domain example.com \
    --url https://vault.example.com \
    --email audit@example.com \
    --data-device "$ROOT_DEVICE" \
    --auto --dry-run > "$EVDIR/root-refusal.txt" 2>&1
RC=$?
set -e
if [ "$RC" -eq 1 ] && grep -Fq "boot/root device" "$EVDIR/root-refusal.txt"; then
    say PASS "Actual installer rejected the boot/root disk using --dry-run"
else
    stop FAIL "Installer did not demonstrate expected root-disk refusal (rc=$RC)"
fi

# Explicitly verify that read-only installation probes did not create state.
for path in /opt/vaultwarden-oci /etc/vaultwarden-oci /var/lib/vaultwarden-oci /run/vaultwarden-oci; do
    if sudo -n test -e "$path" || sudo -n test -L "$path"; then
        stop FAIL "Unexpected appliance path appeared during dry-run: $path"
    fi
done
say PASS "Dry-run left appliance installation paths absent"

if grep -Eq '^POSSIBLE_NONBOOT_DEVICES=0$' "$EVDIR/candidates.txt"; then
    say BLOCKED "No plausible independent storage device; attach OCI block volume"
else
    say "NOT RUN" "Operator has not identified/authorized a specific dedicated storage device"
fi
say "NOT RUN" "Offline recovery identity custody; Box access; exact ciphertext SHA-256"
say "NOT RUN" "New-host installation, guided cancellation, destructive restore and DNS cutover"
printf 'Evidence: %s\n' "$EVDIR"
printf 'Post summary.txt and candidates.txt only. Do not share secrets or raw stderr.\n'
if grep -Eq '^(FAIL|BLOCKED)[[:space:]]' "$SUMMARY"; then exit 1; fi
exit 0
