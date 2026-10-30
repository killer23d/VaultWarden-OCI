#!/usr/bin/env bash
# Ubuntu 26.04 ARM64 audit. READ-ONLY for appliance/system state.
# Only creates private evidence files under the invoking user's home directory.
set -Eeuo pipefail
umask 077

BASE="e0f961c9093e98139e4f57bc94c49c9b79bbc386"
BRANCH="audit/rc11-ubuntu2604-arm64-production-readiness"
RELEASE="0.1.0-rc.11"
SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="$HOME/vwoci-acceptance/phase1-readonly-$STAMP"
SUMMARY="$EVDIR/summary.txt"

mkdir -p "$EVDIR"
chmod 700 "$HOME/vwoci-acceptance" "$EVDIR"
: > "$SUMMARY"
chmod 600 "$SUMMARY"

say() {
  printf '%-8s %s\n' "$1" "$2" | tee -a "$SUMMARY"
}
stop() {
  say "$1" "$2"
  printf 'Evidence: %s\n' "$EVDIR"
  exit 1
}

printf 'VaultWarden-OCI Phase 1 — Ubuntu 26.04 ARM64 read-only audit\n'
printf 'Evidence directory: %s\n' "$EVDIR"
printf 'UTC started: %s\n' "$(date -u --iso-8601=seconds)" > "$EVDIR/metadata.txt"
printf 'Source: %s\n' "$SOURCE" >> "$EVDIR/metadata.txt"

[ "$(id -u)" -ne 0 ] || stop BLOCKED "Run as the non-root SSH user, not root"
for bin in git python3 sudo lsblk findmnt sha256sum systemctl; do
  command -v "$bin" >/dev/null 2>&1 || stop BLOCKED "Missing audit dependency: $bin"
done
[ -f "$SOURCE/versions.toml" ] || stop BLOCKED "Run this from the audit branch checkout"
[ "$(git -C "$SOURCE" branch --show-current)" = "$BRANCH" ] ||
  stop BLOCKED "Source checkout is not the expected audit branch"
git -C "$SOURCE" cat-file -e "$BASE^{commit}" 2>/dev/null ||
  stop BLOCKED "Approved baseline commit not present in checkout (do not use a shallow clone)"
git -C "$SOURCE" merge-base --is-ancestor "$BASE" HEAD ||
  stop FAIL "Audit checkout is not descended from approved baseline"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] ||
  stop BLOCKED "Audit checkout contains tracked local modifications"

unexpected=0
while IFS= read -r changed; do
  case "$changed" in
    tests/host-acceptance/*|reports/PRODUCTION-READINESS-UBUNTU2604.md|docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md) ;;
    *) unexpected=$((unexpected + 1));;
  esac
done < <(git -C "$SOURCE" diff --name-only "$BASE" HEAD)
[ "$unexpected" -eq 0 ] ||
  stop FAIL "Audit branch modifies $unexpected unexpected production-source path(s)"
say PASS "Audit checkout differs from approved baseline only in acceptance materials"

python3 - "$SOURCE/versions.toml" "$RELEASE" <<'PY' ||
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    value = tomllib.load(handle)
if value["vaultwarden_oci"]["version"] != sys.argv[2]:
    raise SystemExit("release manifest does not match the approved rc.11 pin")
PY
  stop FAIL "Release manifest is not rc.11"
say PASS "Audit source pins immutable release $RELEASE"

if ! python3 - <<'PY'
import sys
raise SystemExit(0 if sys.version_info[:2] == (3, 14) else 1)
PY
then
  stop FAIL "Ubuntu 26.04 audit requires native Python 3.14"
fi
say PASS "Native Python 3.14 present"

# The local OS file is trusted Ubuntu package state. No shell-sourced remote content.
. /etc/os-release
[ "$ID" = "ubuntu" ] && [ "$VERSION_ID" = "26.04" ] &&
  [ "$VERSION_CODENAME" = "resolute" ] ||
  stop FAIL "This gate requires Ubuntu 26.04 LTS (resolute)"
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) stop FAIL "This release gate requires ARM64 (aarch64)";;
esac
say PASS "Ubuntu 26.04 Resolute on ARM64"
sudo -n true >/dev/null 2>&1 || stop BLOCKED "Passwordless sudo -n is required"
say PASS "Passwordless sudo -n available"

lsblk -p -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,UUID,MODEL \
  > "$EVDIR/block-devices.txt" 2> "$EVDIR/block-devices.err" ||
  stop FAIL "Unable to inventory local block devices"
findmnt -n -o SOURCE,FSTYPE,UUID --target / \
  > "$EVDIR/root-mount.txt" 2> "$EVDIR/root-mount.err" ||
  stop FAIL "Unable to identify root filesystem"
say PASS "Root filesystem and block-device inventory recorded; no disks modified"

if ! sudo -n test -L /opt/vaultwarden-oci/current; then
  if sudo -n test -e /opt/vaultwarden-oci/current; then
    say FAIL "Existing current release path is not a symlink"
    exit 1
  fi
  say "NOT RUN" "No installed appliance: runtime, backup and security tests require installation"
  say "NOT RUN" "No fresh-host recovery or scheduled-backup operation has been performed"
  printf 'Evidence: %s\n' "$EVDIR"
  exit 0
fi

INSTALLED="$(sudo -n readlink -f /opt/vaultwarden-oci/current)" ||
  stop FAIL "Cannot resolve installed release"
[ "$INSTALLED" = "/opt/vaultwarden-oci/releases/$RELEASE" ] ||
  stop FAIL "Installed release is not the exact approved $RELEASE"
say PASS "Installed current release resolves to immutable $RELEASE"

# Prove the installed immutable source matches the approved Git tree by content.
# Only release-owned tracked files are hashed; no config, secrets or vault data.
matched=0
mismatched=0
while IFS= read -r relative; do
  [ -n "$relative" ] || continue
  expected="$(git -C "$SOURCE" show "$BASE:$relative" | sha256sum | awk '{print $1}')" ||
    stop FAIL "Cannot hash approved release source"
  actual="$(sudo -n sha256sum "$INSTALLED/$relative" 2>/dev/null | awk '{print $1}')" || true
  if [ -z "$actual" ] || [ "$expected" != "$actual" ]; then
    printf '%s\n' "$relative" >> "$EVDIR/release-hash-mismatches.txt"
    mismatched=$((mismatched + 1))
  else
    matched=$((matched + 1))
  fi
done < <(git -C "$SOURCE" ls-tree -r --name-only "$BASE" -- vwctl versions.toml email-providers.toml vaultwarden_oci systemd)
printf 'Matched source files: %s\nMismatched source files: %s\n' "$matched" "$mismatched" > "$EVDIR/release-hash-summary.txt"
if [ "$matched" -eq 0 ] || [ "$mismatched" -ne 0 ]; then
  say FAIL "Immutable release content differs from approved Git baseline: $mismatched mismatches"
else
  say PASS "Immutable release matches $matched baseline-tracked release files by SHA-256"
fi

if sudo -n test -e /var/lib/vaultwarden-oci/state/update-recovery-required.json; then
  say BLOCKED "Update recovery-required guard exists: no mutations are authorized"
else
  say PASS "No update recovery-required guard file"
fi

# Invoke only read-only supported application inspectors.
CLI="$INSTALLED/vwctl"
for kind in doctor status timers; do
  if sudo -n "$CLI" "$kind" --json > "$EVDIR/$kind.json" 2> "$EVDIR/$kind.stderr"; then
    printf '%s\n' 0 > "$EVDIR/$kind.rc"
  else
    printf '%s\n' "$?" > "$EVDIR/$kind.rc"
  fi
done

if sudo -n python3 - "$INSTALLED" > "$EVDIR/storage-verification.txt" 2> "$EVDIR/storage-verification.stderr" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from vaultwarden_oci import storage
identity = storage.verify()
print("dedicated_storage_verified=yes")
print("mount=" + identity.mount)
print("source=" + identity.source)
print("fs_type=" + identity.fs_type)
print("uuid=" + identity.uuid)
PY
then
  say PASS "Dedicated storage identity, volume marker and root-disk exclusion verified"
else
  say FAIL "Dedicated storage ownership verification failed (see private evidence)"
fi

if sudo -n python3 - > "$EVDIR/config-safety.txt" 2> "$EVDIR/config-safety.stderr" <<'PY'
import tomllib
with open("/etc/vaultwarden-oci/config.toml", "rb") as stream:
    data = tomllib.load(stream)
backup = data.get("backup", {})
print("offsite_configured=" + str(bool(backup.get("remote"))).lower())
print("local_retention_days=" + str(backup.get("local_retention_days", "missing")))
print("remote_retention_days=" + str(backup.get("remote_retention_days", "missing")))
print("operational_notifications_configured=" + str("notifications" in data).lower())
PY
then
  if grep -qx 'offsite_configured=true' "$EVDIR/config-safety.txt"; then
    say PASS "Saved offsite publication destination is configured"
  else
    say BLOCKED "Offsite destination is disabled; scheduled backup would be local-only"
  fi
  if grep -qx 'local_retention_days=0' "$EVDIR/config-safety.txt" &&
     grep -qx 'remote_retention_days=0' "$EVDIR/config-safety.txt"; then
    say PASS "Local and remote retention are both 0 (keep indefinitely)"
  else
    say BLOCKED "Retention differs from safe acceptance baseline; do not execute backups"
  fi
else
  say FAIL "Cannot safely inspect backup retention and publication settings"
fi

systemctl --failed --no-pager --plain > "$EVDIR/failed-units.txt" 2> "$EVDIR/failed-units.stderr" || true
for unit in vaultwarden-oci.target vaultwarden-oci.service \
  vaultwarden-oci-health.timer vaultwarden-oci-backup.timer \
  vaultwarden-oci-maintenance.timer vaultwarden-oci-update-check.timer \
  vaultwarden-oci-backup.service vaultwarden-oci-dns.service; do
  systemctl show "$unit" --no-pager \
    --property=LoadState,ActiveState,SubState,Result,UnitFileState,LastTriggerUSec,NextElapseUSecRealtime \
    >> "$EVDIR/systemd-properties.txt" 2>> "$EVDIR/systemd-errors.txt" || true
  printf '\n' >> "$EVDIR/systemd-properties.txt"
done
say PASS "Whitelisted systemd properties captured (no journal bodies or secrets)"

python3 - "$EVDIR" <<'PY' | tee -a "$SUMMARY"
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for name in ("doctor", "status", "timers"):
    try:
        data = json.loads((root / f"{name}.json").read_text())
        rc = int((root / f"{name}.rc").read_text().strip())
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"FAIL     {name} JSON unavailable or malformed ({type(exc).__name__})")
        continue
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        print(f"FAIL     {name} JSON schema invalid")
        continue
    if name == "doctor":
        overall = data.get("overall")
        checks = data.get("checks")
        if not isinstance(checks, list):
            print("FAIL     doctor checks missing")
            continue
        warnings = [str(c.get("check_id")) for c in checks
                    if isinstance(c, dict) and c.get("status") in ("FAIL", "WARN")]
        state = "PASS" if overall == "PASS" and rc == 0 else "FAIL" if overall == "FAIL" else "BLOCKED"
        print(f"{state:<8} doctor overall={overall} rc={rc}; concerns={','.join(warnings) or 'none'}")
    elif name == "status":
        overall = (data.get("doctor") or {}).get("overall")
        runtime = (data.get("runtime") or {}).get("overall")
        storage = (data.get("storage") or {}).get("state")
        state = "FAIL" if overall == "FAIL" or storage == "failure" else "PASS" if overall == "PASS" and rc == 0 else "BLOCKED"
        print(f"{state:<8} status doctor={overall} runtime={runtime} storage={storage} rc={rc}")
    else:
        overall = data.get("overall")
        rows = data.get("timers")
        count = len(rows) if isinstance(rows, list) else -1
        state = "PASS" if overall == "PASS" and count == 4 and rc == 0 else "FAIL"
        print(f"{state:<8} scheduled automation overall={overall} timers={count} rc={rc}")
PY

say "NOT RUN" "Fresh-host restore, actual scheduled activation, reboot, notification delivery and DNS cutover"
printf 'Evidence: %s\n' "$EVDIR"
printf 'Share only summary.txt first; keep JSON and any stderr private until reviewed.\n'

if grep -Eq '^(FAIL|BLOCKED)[[:space:]]' "$SUMMARY"; then
  exit 1
fi
exit 0
