#!/usr/bin/env bash
# D1R: resume a genuinely interrupted D1 on the ORIGINAL disposable OCI host.
# The original 24 gate formatted the exact disk; this script NEVER formats it.
# It requires the dual storage identity marker written by the product and a
# cryptographically pinned release source. No Cloudflare/Box/app/timer writes.
set -Eeuo pipefail
umask 077

HOST="vaultwarden-oci-6-vnic"
PIN="12d014e03bd5830adfa4e10defcb43056f9bea9d"
RELEASE="0.1.0-rc.12"
BYID="/dev/disk/by-id/scsi-36088f6a844d04920961a8a7b0feab3b9"
SERIAL="6088f6a844d04920961a8a7b0feab3b9"
BYTES="53687091200"
DOMAIN="bw.lazymocha.com"
EMAIL="bw@lazymocha.com"
OFFLINE="age1z7tqg4zrlnul8kang4lny9405elnya5nh3rt3dk440s766rf8assh33sku"
ROOT="$HOME/vwoci-rc12-acceptance"
PRIOR="$ROOT/clean-install-20261031T063818Z"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
OUT="$ROOT/resume-d1-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$ROOT"
chmod 700 "$ROOT"
mkdir -m 700 "$OUT"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
chmod 600 "$SUMMARY"

record() { printf '%-8s %s\n' "$1" "$2" | tee -a "$SUMMARY"; }
block() {
    record BLOCKED "$*"
    record HOLD "Preserve this exact volume and all private evidence; no blind restart."
    printf 'Evidence: %s\n' "$OUT"
    exit 1
}

[ "$#" -eq 0 ] || block "No arguments supported; exact accepted VM/disk/recipient are pinned"
[ "$(id -un)" = ubuntu ] && [ "$(hostname -s)" = "$HOST" ] ||
    block "Wrong user/host. This is not a general-use resume script."
sudo -n true >/dev/null 2>&1 || block "Passwordless sudo is required"
for command in git python3 readlink lsblk findmnt stat grep cmp \
    sha256sum systemctl ps dpkg date bash; do
    command -v "$command" >/dev/null 2>&1 || block "Missing tool: $command"
done
. /etc/os-release
[ "$ID" = ubuntu ] && [ "$VERSION_ID" = 26.04 ] &&
    [ "$VERSION_CODENAME" = resolute ] &&
    [ "$(uname -m)" = aarch64 ] ||
    block "Wrong operating system/architecture"
python3 -B -c 'import sys; assert sys.version_info[:2] == (3,14)' ||
    block "Expected Python 3.14"
[ "$(stat -c %d /run)" != "$(stat -c %d /usr/local/bin)" ] ||
    block "EXDEV regression boundary disappeared"

git -C "$SOURCE" cat-file -e "$PIN^{commit}" 2>/dev/null ||
    block "Original reviewed rc.12 product source is unavailable"
git -C "$SOURCE" merge-base --is-ancestor "$PIN" HEAD ||
    block "Checkout is not descended from reviewed rc.12 commit"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
    block "Modified tracked checkout; refuse to run installer"
git -C "$SOURCE" diff --quiet "$PIN" HEAD -- \
    setup.sh versions.toml vwctl email-providers.toml vaultwarden_oci systemd ||
    block "Runtime or pinned versions changed since reviewed rc.12 source"
while IFS= read -r changed; do
    case "$changed" in
        tests/host-acceptance/*|tests/test_host_acceptance_rc12_gate_syntax.py|docs/*) ;;
        *) block "Unexpected non-audit source change since original candidate: $changed" ;;
    esac
done < <(git -C "$SOURCE" diff --name-only "$PIN" HEAD)
[ -f "$PRIOR/summary.txt" ] && [ ! -L "$PRIOR/summary.txt" ] &&
    [ -f "$PRIOR/install.private.log" ] && [ ! -L "$PRIOR/install.private.log" ] ||
    block "Original interrupted D1 evidence missing"
for expected in \
    'PASS     Exact rc.12 corrective release and fresh Ubuntu ARM64 host pinned' \
    'PASS     Blank OS and real /run tmpfs vs /usr/local/bin cross-filesystem boundary' \
    'PASS     Stable by-id, disk serial, capacity, root ancestry and blank signatures' \
    'PASS     Supported installer accepted all exact dry-run inputs' \
    'INFO     FORMATTING VERIFIED BLANK DISPOSABLE DATA DISK; installing rc.12 with TMPDIR=/run'
do
    grep -Fq "$expected" "$PRIOR/summary.txt" ||
        block "Required original blank-disk evidence absent: $expected"
done
if grep -Fq 'PASS     D1: clean Ubuntu 26.04 ARM64 rc.12 installer and cross-FS SOPS acceptance passed' \
    "$PRIOR/summary.txt"; then
    block "D1 was already accepted; do not repeat the installer"
fi
record PASS "Original genuine clean-host, blank-disk and cross-FS D1 provenance preserved"

# Check processes by executable name, not by matching shell scripts or printing
# full command lines. Avoid competing with a potentially active apt/installer.
if ! sudo -n python3 -B -E - <<'PY' > "$OUT/process-check.txt" 2> "$OUT/process-check.private.stderr"
from pathlib import Path
import os
dangerous={"apt-get","dpkg","mkfs.ext4","curl","sops"}
busy=[]
for node in Path("/proc").iterdir():
    if not node.name.isdecimal() or int(node.name)==os.getpid():
        continue
    try:
        parts=(node/"cmdline").read_bytes().split(b"\0")
        args=[p.decode("utf-8","replace") for p in parts if p]
        if not args:
            continue
        exe=Path(args[0]).name
        if exe in dangerous or "vaultwarden_oci.setup_frontend" in args or (
            exe=="bash" and any(arg.endswith("/setup.sh") for arg in args)
        ):
            busy.append((int(node.name),exe))
    except (OSError,ValueError):
        continue
if busy:
    print("ACTIVE_INSTALL_OR_PACKAGE_PROCESSES="+",".join(f"{pid}:{exe}" for pid,exe in busy))
    raise SystemExit(1)
print("ACTIVE_INSTALL_OR_PACKAGE_PROCESSES=none")
PY
then block "An installer/package process may still be running; do not resume"; fi
if ! sudo -n dpkg --audit > "$OUT/dpkg-audit.private.txt" 2>&1; then
    block "dpkg package audit command failed"
fi
[ ! -s "$OUT/dpkg-audit.private.txt" ] ||
    block "Packages need attention before continuing; see dpkg-audit.private.txt"
record PASS "No competing install/package processes; dpkg audit is clean"

[ -L "$BYID" ] || block "Original by-id disk alias is missing"
DISK="$(readlink -e "$BYID")" || block "Original disk no longer resolves"
[ "$DISK" = /dev/sda ] &&
    [ -b "$DISK" ] &&
    [ "$(lsblk -dn -o TYPE "$DISK" | tr -d '[:space:]')" = disk ] &&
    [ "$(lsblk -dn -o SERIAL "$DISK" | tr -d '[:space:]')" = "$SERIAL" ] &&
    [ "$(lsblk -bdn -o SIZE "$DISK" | tr -d '[:space:]')" = "$BYTES" ] ||
    block "Original accepted volume serial/capacity/real device changed"
[ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o SOURCE)" = "$DISK" ] &&
    [ "$(findmnt -rn -M /var/lib/vaultwarden-oci -o FSTYPE)" = ext4 ] ||
    block "Original data volume is not mounted at the canonical production state path"

# Must prove that this filesystem is already claimed by the precise host-side
# storage marker AND an independent on-volume marker. No auto-repair here.
if ! sudo -n python3 -B -E - "$SOURCE" "$DISK" "$OFFLINE" "$DOMAIN" \
    > "$OUT/pre-resume.txt" 2> "$OUT/pre-resume.private.stderr" <<'PY'
import pathlib,sys,tomllib
sys.path.insert(0,sys.argv[1])
from vaultwarden_oci import storage
target=pathlib.Path(sys.argv[2]).resolve(strict=True)
storage.reject_boot_related(str(target))
actual=storage.verify()
if actual.fs_type!="ext4" or pathlib.Path(actual.source).resolve(strict=True)!=target:
    raise RuntimeError("Host and disk marker disagree with selected filesystem")
cfg=pathlib.Path("/etc/vaultwarden-oci/config.toml")
if cfg.exists():
    with cfg.open("rb") as f: data=tomllib.load(f)
    if data["site"]["domain"]!=sys.argv[4] or data["secrets"]["offline_recovery_recipient"]!=sys.argv[3]:
        raise RuntimeError("Partial config hostname/recovery recipient differs")
print("host_storage_identity=PASS")
print("on_volume_storage_identity=PASS")
print("source_disk_boot_ancestry=SEPARATE")
print("saved_recipient_and_hostname=UNCHANGED_OR_NOT_CREATED")
PY
then block "Cannot prove dual host/volume storage ownership; do not adopt existing filesystem"; fi
cat "$OUT/pre-resume.txt" | tee -a "$SUMMARY"
record PASS "Identical original data filesystem mounted with verified independent ownership markers"

if [ -e /opt/vaultwarden-oci/current ] || [ -L /opt/vaultwarden-oci/current ]; then
    block "An installed release already exists; use a postinstall check rather than reinstallation"
fi
for unit in vaultwarden-oci.target vaultwarden-oci.service \
    vaultwarden-oci-backup.timer vaultwarden-oci-health.timer \
    vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer; do
    [ "$(systemctl show -p ActiveState --value "$unit")" != active ] ||
        block "An application/timer unit is already active: $unit"
done
record PASS "No installed release, no running lifecycle or scheduled automation"

# This is an intentional adoption of a previously initialized filesystem.
# This is an adoption-only resumption and cannot request another format.
record INFO "Resuming supported rc.12 setup using --accept-existing-filesystem; NO mkfs permitted"
record INFO "Unbuffered phase markers; apt/dpkg subprocess output remains privately captured until completion"
if ! NO_COLOR=1 sudo -n env TMPDIR=/run PYTHONUNBUFFERED=1 DEBIAN_FRONTEND=noninteractive \
    bash "$SOURCE/setup.sh" install \
    --domain "$DOMAIN" --url "https://$DOMAIN" --email "$EMAIL" \
    --data-device "$BYID" --offline-recipient "$OFFLINE" \
    --accept-existing-filesystem --auto > "$OUT/resume-install.private.log" 2>&1; then
    record BLOCKED "Supported setup resume failed. Inspect private log and do not automatically retry."
    record HOLD "The selected ext4 volume was ADOPTED, not reformatted."
    echo "Evidence: $OUT"
    exit 1
fi
record PASS "Real supported setup completed without reformatting the existing volume"

[ "$(readlink -f /opt/vaultwarden-oci/current)" = \
    "/opt/vaultwarden-oci/releases/$RELEASE" ] ||
    block "Completed installer did not activate rc.12 immutable release"
[ -f /usr/local/bin/sops ] && [ ! -L /usr/local/bin/sops ] &&
    [ "$(sha256sum /usr/local/bin/sops | cut -d ' ' -f1)" = \
      "53b0abacd38ef1b12a66d6c100956691b9cefce018d91f81e73ddf7438b94d77" ] &&
    [ "$(stat -c %u /usr/local/bin/sops)" = 0 ] &&
    [ "$(stat -c %a /usr/local/bin/sops)" = 755 ] ||
    block "Installed ARM64 SOPS checksum/owner/mode not correct"
for file in vwctl versions.toml email-providers.toml \
    vaultwarden_oci/setup.py vaultwarden_oci/recovery_ux.py; do
    cmp -s "$SOURCE/$file" "/opt/vaultwarden-oci/current/$file" ||
        block "Installed application differs from exact reviewed rc.12 source: $file"
done
record PASS "Cross-filesystem SOPS installed with pinned ARM64 digest; immutable rc.12 files match"

if ! sudo -n python3 -B -E - "$SOURCE" "$DISK" "$OFFLINE" "$DOMAIN" \
    > "$OUT/post-install.txt" 2> "$OUT/post-install.private.stderr" <<'PY'
import os,pathlib,stat,subprocess,sys,tomllib
sys.path.insert(0,sys.argv[1])
from vaultwarden_oci import storage,secrets
ident=storage.verify()
if pathlib.Path(ident.source).resolve(strict=True)!=pathlib.Path(sys.argv[2]).resolve(strict=True):
    raise RuntimeError("Dedicated source changed")
with open("/etc/vaultwarden-oci/config.toml","rb") as f: cfg=tomllib.load(f)
if cfg["site"]["domain"]!=sys.argv[4] or cfg["secrets"]["offline_recovery_recipient"]!=sys.argv[3]:
    raise RuntimeError("Offline recipient or site changed")
backup=cfg["backup"]
if backup["remote"]!="" or backup["local_retention_days"] or backup["remote_retention_days"]:
    raise RuntimeError("Unexpected remote backup/retention mutation")
secrets.validate_custody(sys.argv[3])
env=os.environ.copy()
env["SOPS_AGE_KEY_FILE"]="/etc/vaultwarden-oci/age-key.txt"
subprocess.run(["/usr/local/bin/sops","--decrypt","--output","/dev/null",
                "/etc/vaultwarden-oci/secrets.sops.yaml"],
                check=True,env=env,capture_output=True,text=True)
for name in ("config.toml","secrets.sops.yaml","age-key.txt","storage-identity.json"):
    p=pathlib.Path("/etc/vaultwarden-oci")/name
    x=p.lstat()
    if not stat.S_ISREG(x.st_mode) or x.st_uid!=0 or x.st_size==0 or stat.S_IMODE(x.st_mode)&0o077:
        raise RuntimeError("Incorrect protected config/key permissions: "+name)
print("installed_release=0.1.0-rc.12")
print("original_dedicated_storage_marker=PASS")
print("separate_offline_and_operational_age_custody=PASS")
print("SOPS_decryption=PASS")
print("root_only_protected_files=PASS")
print("backup_remote=disabled")
print("local_retention_days=0")
print("remote_retention_days=0")
PY
then block "Installed rc.12 custody/backup/storage validation failed"; fi
cat "$OUT/post-install.txt" | tee -a "$SUMMARY"
for unit in vaultwarden-oci.target vaultwarden-oci.service \
    vaultwarden-oci-backup.timer vaultwarden-oci-health.timer \
    vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer; do
    [ "$(systemctl show -p ActiveState --value "$unit")" = inactive ] ||
        block "New installer unexpectedly started application/automation: $unit"
done
record PASS "Caddy/Vaultwarden/timers remain stopped; no Cloudflare or Box writes"

if ! (cd "$SOURCE" && python3 -B -m unittest discover -s tests \
    -p 'test_recovery_kit_explicit_path.py' -v) \
    > "$OUT/recovery-ux.private.log" 2>&1; then
    block "Native ARM64 explicit encrypted ZIP-path regressions did not pass"
fi
record PASS "Native ARM64 encrypted recovery-kit path regression tests passed"
record PASS "D1R: supported same-volume resume accepted; rc.12 EXDEV/SOPS clean-image validation passed"
record "NOT RUN" "Real ZIP cryptographic D2, Vaultwarden startup, Cloudflare, Box, reboot and production cutover"
echo "Evidence: $OUT"
echo "Share summary.txt, pre-resume.txt, post-install.txt only; all *.private.* logs stay on test VM."
