#!/usr/bin/env bash
# Focused regression checks for destructive uninstall boundaries.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"
ROOT_REPO="$VW_TEST_REPO_ROOT"
U="$ROOT_REPO/utilities/uninstall-vaultwarden.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

bash -n "$U"
[[ ! -e "$ROOT_REPO/utilities/uninstall-vaultwarden-core.sh" ]] || fail "split core file returned"
! grep -q 'uninstall-vaultwarden-core' "$U" || fail "entrypoint/core split reference returned"
! grep -q 'umount -l' "$U" || fail "lazy unmount returned"
! grep -Eq 'apt-get (remove|autoremove).*purge|apt-get autoremove' "$U" || fail "shared package purge returned"

set -- run --dry-run
source "$U"
DRY_RUN=false FORCE=false TEST_RESET=false SAVED_RECOVERY=false

FSTAB="$T/fstab"
printf 'UUID=managed\t/mnt/vw-data\text4\tnoatime,nofail,x-systemd.device-timeout=30s\t0\t2\n' > "$FSTAB"
chmod 640 "$FSTAB"
remove_fstab /mnt/vw-data /dev/missing '' || fail "setup fstab signature rejected"
[[ ! -s "$FSTAB" && "$(stat -c %a "$FSTAB")" == 640 ]] || fail "fstab rewrite or metadata preservation failed"
printf 'UUID=operator\t/mnt/vw-data\text4\tdefaults,nofail\t0\t2\n' > "$FSTAB"
if remove_fstab /mnt/vw-data /dev/missing ''; then fail "mountpoint-only fstab entry removed"; fi
grep -q 'UUID=operator' "$FSTAB" || fail "operator fstab entry changed"
printf 'UUID=managed\t/mnt/other\text4\tnoatime,nofail,x-systemd.device-timeout=30s\t0\t2\n' > "$FSTAB"
if fstab_can_remove /mnt/vw-data /dev/missing managed; then fail "same UUID at another mountpoint accepted"; fi

mkdir -p "$T/x"
if safe_rm "$T/x/.."; then fail "canonical broad path accepted"; fi
PROJECT_STATE_DIR="$DEFAULT_DATA"; DATA_VOLUME_MOUNT="$DEFAULT_DATA"; DATA_VOLUME_DEVICE=''
if ( preflight_storage ) >/dev/null 2>&1; then fail "partial separate-volume config accepted"; fi

handoff_name 'vaultwarden-setup-credentials-20260807T000000Z.txt' || fail "valid credentials handoff missed"
if handoff_name 'vaultwarden-setup-credentials-operator.txt'; then fail "broad credentials handoff matched"; fi
handoff_name 'vaultwarden-recovery-kit-20260807T000000Z-abcdef.txt' || fail "valid recovery kit missed"
if handoff_name 'vaultwarden-recovery-kit-current.txt'; then fail "broad recovery kit matched"; fi

ROOT="$T/VaultWarden-OCI"; ETC_DIR="$T/etc-vw"; PROJECT_STATE_DIR="$T/state"; DATA_VOLUME_DEVICE=''; BACKUP_DIR="$ROOT/backups/retained"
mkdir -p "$ROOT/secrets/keys" "$BACKUP_DIR"
key="$ROOT/secrets/keys/age-key.txt"; printf key > "$key"; AGE_KEYS=("$key")
[[ "$(existing_keys)" == "$key" ]] || fail "repo Age key escaped recovery guard"
printf secret > "$ROOT/secrets/local"; printf old > "$ROOT/backups/old"; printf keep > "$BACKUP_DIR/keep"
cleanup_checkout_artifacts
[[ -f "$BACKUP_DIR/keep" ]] || fail "nested external backup deleted"
[[ ! -e "$ROOT/backups/old" && ! -e "$ROOT/secrets" ]] || fail "generated checkout artifacts remained"

SYSTEMD="$T/systemd"; MOUNT_GUARD="$SYSTEMD/docker.service.d/10-vaultwarden-data-volume.conf"; mkdir -p "$(dirname "$MOUNT_GUARD")"
printf '# Managed by VaultWarden-OCI setup.sh - do not edit by hand.\n[Unit]\n' > "$MOUNT_GUARD"
DATA_VOLUME_MOUNT="$T/mnt"; PROJECT_STATE_DIR="$DATA_VOLUME_MOUNT"; DATA_VOLUME_DEVICE=/dev/mock; mkdir -p "$DATA_VOLUME_MOUNT"
printf 'VaultWarden-OCI data volume\nDevice: /dev/mock\nMounted: %s\n' "$DATA_VOLUME_MOUNT" > "$DATA_VOLUME_MOUNT/.vw-data-volume"
printf keep > "$DATA_VOLUME_MOUNT/operator-note"
FSTAB="$T/fstab-mounted"; printf 'UUID=mock\t%s\text4\tnoatime,nofail,x-systemd.device-timeout=30s\t0\t2\n' "$DATA_VOLUME_MOUNT" > "$FSTAB"
B="$T/bin"; mkdir -p "$B"; export MOCK_MOUNT="$DATA_VOLUME_MOUNT" MOCK_FLAG="$T/is-mounted" MOCK_DETACHED="$T/detached"; : > "$MOCK_FLAG"
cat > "$B/mountpoint" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -q && "$2" == "$MOCK_MOUNT" && -e "$MOCK_FLAG" ]]
MOCK
cat > "$B/findmnt" <<'MOCK'
#!/usr/bin/env bash
printf '/dev/mock\n'
MOCK
cat > "$B/blkid" <<'MOCK'
#!/usr/bin/env bash
printf 'mock\n'
MOCK
cat > "$B/umount" <<'MOCK'
#!/usr/bin/env bash
rm -f "$MOCK_FLAG"; mv "$MOCK_MOUNT" "$MOCK_DETACHED"; mkdir -p "$MOCK_MOUNT"
MOCK
chmod +x "$B"/*; PATH="$B:$PATH"
remove_state >/dev/null
[[ -f "$MOCK_DETACHED/operator-note" && -f "$MOCK_DETACHED/.vw-data-volume" ]] || fail "separate-volume data or sentinel deleted"
! grep -q "$DATA_VOLUME_MOUNT" "$FSTAB" || fail "managed fstab entry remained"
[[ ! -e "$MOUNT_GUARD" ]] || fail "managed mount guard remained"

echo 'case-uninstall: ok'
