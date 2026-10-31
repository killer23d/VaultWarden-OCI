#!/usr/bin/env bash
# D1: CLEAN Ubuntu 26.04 ARM64 installer regression on a disposable host.
# FORMATS ONE VERIFIED BLANK NON-BOOT DISK. Never run on restored rc.11 host.
# No Cloudflare API/DNS/Worker calls, Box writes, app start, timers or reboot.
# No redundant typed consent; operator supplies exact by-id/serial/size/public recipient.
set -Eeuo pipefail
umask 077

PIN="155aef81d065be4feb3737fcbc126f3ae2effa62"
RELEASE="0.1.0-rc.12"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
DATA_BY_ID="$(printenv DATA_BY_ID || true)"
EXPECTED_SERIAL="$(printenv EXPECTED_SERIAL || true)"
EXPECTED_SIZE_BYTES="$(printenv EXPECTED_SIZE_BYTES || true)"
OFFLINE_RECIPIENT="$(printenv OFFLINE_RECIPIENT || true)"
SITE_DOMAIN="bw.lazymocha.com"
EMAIL="bw@lazymocha.com"
ROOT="$HOME/vwoci-rc12-acceptance"
OUT="$ROOT/clean-install-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$ROOT"
chmod 700 "$ROOT"
mkdir -m 700 "$OUT"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
chmod 600 "$SUMMARY"
say() { printf '%-8s %s\n' "$1" "$2" | tee -a "$SUMMARY"; }
block() {
    say BLOCKED "$*"
    say HOLD "Do not blindly rerun after a partial installation or formatted data disk."
    echo "Evidence: $OUT"
    exit 1
}
[ "$#" -eq 0 ] || block "No positional arguments accepted"
[ "$(id -un)" = ubuntu ] && [ "$(id -u)" -ne 0 ] ||
    block "Run as ubuntu on a new disposable ARM64 VM"
[ -n "$DATA_BY_ID" ] && [ -n "$EXPECTED_SERIAL" ] &&
    [ -n "$EXPECTED_SIZE_BYTES" ] && [ -n "$OFFLINE_RECIPIENT" ] ||
    block "Provide DATA_BY_ID, EXPECTED_SERIAL, EXPECTED_SIZE_BYTES, OFFLINE_RECIPIENT"
case "$DATA_BY_ID" in /dev/disk/by-id/*) ;; *)
    block "DATA_BY_ID must be a stable /dev/disk/by-id/ name" ;;
esac
case "$EXPECTED_SIZE_BYTES" in *[!0-9]*|"") block "EXPECTED_SIZE_BYTES must be decimal" ;; esac
[ "$EXPECTED_SIZE_BYTES" -ge 21474836480 ] || block "Data disk must be at least 20 GiB"
case "$EXPECTED_SERIAL" in *[!A-Za-z0-9-]*|"") block "Invalid expected serial" ;; esac
[[ "$OFFLINE_RECIPIENT" =~ ^age1[0-9a-z]{50,70}$ ]] ||
    block "OFFLINE_RECIPIENT must be a genuine public age1 value"
for cmd in sudo git python3 lsblk wipefs readlink stat sha256sum findmnt \
    systemctl grep cmp date tr bash; do
    command -v "$cmd" >/dev/null 2>&1 || block "Missing tool $cmd"
done
sudo -n true >/dev/null 2>&1 || block "Passwordless sudo unavailable"
. /etc/os-release
[ "$ID" = ubuntu ] && [ "$VERSION_ID" = 26.04 ] &&
    [ "$VERSION_CODENAME" = resolute ] &&
    [ "$(uname -m)" = aarch64 ] ||
    block "Only clean Ubuntu 26.04 ARM64 is approved"
python3 -c 'import sys;assert sys.version_info[:2]==(3,14)' ||
    block "Native Python 3.14 is required"
git -C "$SOURCE" cat-file -e "$PIN^{commit}" 2>/dev/null &&
    git -C "$SOURCE" merge-base --is-ancestor "$PIN" HEAD &&
    [ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
    block "Source does not descend cleanly from exact reviewed PR #373 SHA"
if ! git -C "$SOURCE" diff --quiet "$PIN" HEAD -- setup.sh versions.toml \
    vaultwarden_oci systemd vwctl email-providers.toml; then
    block "Product runtime changed after reviewed corrective SHA"
fi
while IFS= read -r changed; do
    case "$changed" in tests/host-acceptance/*|tests/test_host_acceptance_rc12_gate_syntax.py|docs/*) ;; *)
        block "Unexpected source changes beyond accepted test/docs since corrective SHA" ;;
    esac
done < <(git -C "$SOURCE" diff --name-only "$PIN" HEAD)
python3 - "$SOURCE/versions.toml" <<'PY' || block "Source version is not rc.12"
import sys,tomllib
with open(sys.argv[1],"rb") as f:
    assert tomllib.load(f)["vaultwarden_oci"]["version"]=="0.1.0-rc.12"
PY
[ -f "$SOURCE/tests/test_setup_sops_atomic.py" ] &&
    [ -f "$SOURCE/tests/test_recovery_kit_explicit_path.py" ] ||
    block "Corrective source regression tests missing"
say PASS "Exact rc.12 corrective release and fresh Ubuntu ARM64 host pinned"

for path in /opt/vaultwarden-oci /etc/vaultwarden-oci /var/lib/vaultwarden-oci; do
    if sudo -n test -e "$path" || sudo -n test -L "$path"; then
        block "Existing appliance state: $path; not a clean installation"
    fi
done
if command -v sops >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then
    block "Previously installed SOPS/Docker; not a clean base image"
fi
for unit in vaultwarden-oci.target vaultwarden-oci.service \
    vaultwarden-oci-backup.timer vaultwarden-oci-health.timer \
    vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer; do
    if systemctl is-active --quiet "$unit" ||
       systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        block "Existing active or enabled appliance unit: $unit"
    fi
done
[ -d /run ] && [ -d /usr/local/bin ] ||
    block "Required installed host directories /run or /usr/local/bin absent"
[ "$(stat -c %d /run)" != "$(stat -c %d /usr/local/bin)" ] ||
    block "Cannot reproduce cross-filesystem SOPS install; /run and /usr/local/bin share a filesystem"
say PASS "Blank OS and real /run tmpfs vs /usr/local/bin cross-filesystem boundary"

[ -L "$DATA_BY_ID" ] || block "Selected disk symlink absent"
DISK="$(readlink -e "$DATA_BY_ID")" || block "Selected disk cannot be resolved"
[ -b "$DISK" ] && [ "$(lsblk -dn -o TYPE "$DISK" | tr -d '[:space:]')" = disk ] ||
    block "Selected target is not a whole block disk"
[ "$(lsblk -dn -o SERIAL "$DISK" | tr -d '[:space:]')" = "$EXPECTED_SERIAL" ] &&
    [ "$(lsblk -bdn -o SIZE "$DISK" | tr -d '[:space:]')" = "$EXPECTED_SIZE_BYTES" ] ||
    block "Selected disk serial/size differs from independent inventory"
if findmnt -rn -S "$DISK" | grep -q .; then
    block "Selected disk is already mounted"
fi
if ! sudo -n python3 -B -E - "$SOURCE" "$DISK" "$EXPECTED_SIZE_BYTES" \
    > "$OUT/disk-report.txt" 2> "$OUT/disk-report.private.stderr" <<'PY'
import json,subprocess,sys
sys.path.insert(0,sys.argv[1])
from vaultwarden_oci import storage
disk=sys.argv[2]
storage.reject_boot_related(disk)
p=subprocess.run(["lsblk","-J","-b","-p","-o",
    "PATH,TYPE,SIZE,FSTYPE,PTTYPE,UUID,MOUNTPOINTS",disk],
    capture_output=True,text=True,check=True)
rows=json.loads(p.stdout).get("blockdevices",[])
if len(rows)!=1 or rows[0].get("type")!="disk":
    raise RuntimeError("not one whole disk")
r=rows[0]
if r.get("children") or int(r.get("size") or 0)!=int(sys.argv[3]):
    raise RuntimeError("partitions or unexpected disk size")
if r.get("fstype") or r.get("pttype") or r.get("uuid") or any(r.get("mountpoints") or []):
    raise RuntimeError("filesystem/partition/mount already present")
q=subprocess.run(["wipefs","--noheadings","--output","TYPE",disk],
    capture_output=True,text=True,check=True)
if q.stdout.strip():
    raise RuntimeError("disk signatures already present")
print("boot_related=no")
print("partition_children=no")
print("recognized_signatures=none")
print("selected_disk_size_verified=yes")
PY
then block "Selected disk is not provably blank and non-boot"; fi
say PASS "Stable by-id, disk serial, capacity, root ancestry and blank signatures"

if ! NO_COLOR=1 sudo -n bash "$SOURCE/setup.sh" install \
    --domain "$SITE_DOMAIN" --url "https://$SITE_DOMAIN" --email "$EMAIL" \
    --data-device "$DATA_BY_ID" --offline-recipient "$OFFLINE_RECIPIENT" \
    --auto --dry-run > "$OUT/dry-run.private.log" 2>&1; then
    block "Approved installer dry-run failed; no disk modification requested"
fi
grep -Fq 'dry run: no filesystem, package, config, secret, or systemd changes were made' \
    "$OUT/dry-run.private.log" ||
    block "Installer did not confirm mutation-free dry-run"
say PASS "Supported installer accepted all exact dry-run inputs"

[ "$DISK" = "$(readlink -e "$DATA_BY_ID")" ] &&
    [ "$(lsblk -bdn -o SIZE "$DISK" | tr -d '[:space:]')" = "$EXPECTED_SIZE_BYTES" ] &&
    [ "$(lsblk -dn -o SERIAL "$DISK" | tr -d '[:space:]')" = "$EXPECTED_SERIAL" ] &&
    [ -z "$(sudo -n wipefs --noheadings --output TYPE "$DISK")" ] ||
    block "Disk signatures or identity changed before formatting"
say INFO "FORMATTING VERIFIED BLANK DISPOSABLE DATA DISK; installing rc.12 with TMPDIR=/run"
if ! NO_COLOR=1 sudo -n env TMPDIR=/run bash "$SOURCE/setup.sh" install \
    --domain "$SITE_DOMAIN" --url "https://$SITE_DOMAIN" --email "$EMAIL" \
    --data-device "$DATA_BY_ID" --offline-recipient "$OFFLINE_RECIPIENT" \
    --confirm-format --auto > "$OUT/install.private.log" 2>&1; then
    block "Clean rc.12 installer failed after potential formatting; preserve private evidence"
fi
say PASS "Real clean rc.12 setup completed with cross-filesystem SOPS staging"

[ "$(readlink -f /opt/vaultwarden-oci/current)" = "/opt/vaultwarden-oci/releases/$RELEASE" ] ||
    block "Unexpected selected immutable release after install"
[ "$(sha256sum /usr/local/bin/sops | cut -d ' ' -f1)" = \
    "53b0abacd38ef1b12a66d6c100956691b9cefce018d91f81e73ddf7438b94d77" ] &&
    [ "$(stat -c %a /usr/local/bin/sops)" = 755 ] &&
    [ "$(stat -c %u /usr/local/bin/sops)" = 0 ] ||
    block "Pinned ARM64 SOPS digest, executable mode or root owner incorrect"
for path in vwctl versions.toml email-providers.toml \
    vaultwarden_oci/setup.py vaultwarden_oci/recovery_ux.py; do
    cmp -s "$SOURCE/$path" "/opt/vaultwarden-oci/current/$path" ||
        block "Installed immutable release differs from reviewed source: $path"
done
say PASS "Exact SHA-256 ARM64 SOPS and immutable candidate source files installed"

if ! sudo -n python3 -B -E - "$SOURCE" "$DISK" "$OFFLINE_RECIPIENT" "$SITE_DOMAIN" \
    > "$OUT/post-install.txt" 2> "$OUT/post-install.private.stderr" <<'PY'
import os,pathlib,stat,subprocess,sys,tomllib
sys.path.insert(0,sys.argv[1])
from vaultwarden_oci import secrets,storage
identity=storage.verify()
if pathlib.Path(identity.source).resolve(strict=True)!=pathlib.Path(sys.argv[2]).resolve(strict=True):
    raise RuntimeError("unexpected data mount identity")
with open("/etc/vaultwarden-oci/config.toml","rb") as f: cfg=tomllib.load(f)
if cfg["site"]["domain"]!=sys.argv[4] or cfg["secrets"]["offline_recovery_recipient"]!=sys.argv[3]:
    raise RuntimeError("unexpected domain or offline recipient")
b=cfg["backup"]
if b["remote"]!="" or b["local_retention_days"] or b["remote_retention_days"]:
    raise RuntimeError("unexpected remote backup or pruning")
secrets.validate_custody(sys.argv[3])
env=os.environ.copy()
env["SOPS_AGE_KEY_FILE"]="/etc/vaultwarden-oci/age-key.txt"
subprocess.run(["/usr/local/bin/sops","--decrypt","--output","/dev/null",
                "/etc/vaultwarden-oci/secrets.sops.yaml"],
               check=True,env=env,capture_output=True,text=True)
for filename in ("config.toml","secrets.sops.yaml","age-key.txt","storage-identity.json"):
    p=pathlib.Path("/etc/vaultwarden-oci")/filename
    st=p.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid!=0 or st.st_size==0 or stat.S_IMODE(st.st_mode)&0o077:
        raise RuntimeError("protected config/secrets owner or mode invalid: "+filename)
print("installed_release=0.1.0-rc.12")
print("dedicated_storage_marker=PASS")
print("operational_and_offline_age_custody=PASS")
print("SOPS_decryption=PASS")
print("protected_files_root_only=PASS")
print("initial_remote_config=disabled")
print("local_retention_days=0")
print("remote_retention_days=0")
PY
then block "Postinstall disk/SOPS/Age/permissions validation failed"; fi
cat "$OUT/post-install.txt" | tee -a "$SUMMARY"
for unit in vaultwarden-oci.target vaultwarden-oci.service \
    vaultwarden-oci-backup.timer vaultwarden-oci-health.timer \
    vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer; do
    [ "$(systemctl show -p ActiveState --value "$unit")" = inactive ] ||
        block "Installed application or timer unexpectedly activated: $unit"
done
say PASS "No Vaultwarden/Caddy startup, timers, dev DNS or Box changes"
if ! python3 -B -m unittest discover -s "$SOURCE/tests" \
    -p 'test_recovery_kit_explicit_path.py' -v \
    > "$OUT/recovery-ux-tests.private.log" 2>&1; then
    block "Real ARM64 explicit encrypted ZIP-path regression tests failed"
fi
say PASS "Encrypted recovery-kit explicit-path regression tests passed on ARM64"
say PASS "D1: clean Ubuntu 26.04 ARM64 rc.12 installer and cross-FS SOPS acceptance passed"
say "NOT RUN" "Cloudflare Worker/DNS, application start, Box publication, real recovery restore, timers or reboot"
echo "Evidence: $OUT"
echo "Share summary.txt and post-install.txt; all *.private.* files remain confidential."
