#!/usr/bin/env bash
# Focused uninstall safety/regression suite.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_uninstall_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
SCRIPT="$ROOT/utilities/uninstall-vaultwarden.sh"
TMP="$(mktemp -d)"
ORIG_ENV_BACKUP=""
cleanup() {
  rm -rf "$TMP"
  if [[ -n "$ORIG_ENV_BACKUP" && -f "$ORIG_ENV_BACKUP" ]]; then
    mv -f "$ORIG_ENV_BACKUP" "$ROOT/.env"
  else
    rm -f "$ROOT/.env"
  fi
}
trap cleanup EXIT

if [[ -f "$ROOT/.env" ]]; then
  ORIG_ENV_BACKUP="$TMP/original.env"
  cp "$ROOT/.env" "$ORIG_ENV_BACKUP"
fi

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "did not expect '$2' in $1"; }

bash -n "$SCRIPT"
"$SCRIPT" --help >/dev/null
"$SCRIPT" --version >/dev/null

# Dry-run is non-mutating and resolves a coherent repository/install environment.
printf 'PROJECT_STATE_DIR=%s/state-repo\nDATA_VOLUME_DEVICE=\n' "$TMP" > "$ROOT/.env"
before="$(sha256sum "$ROOT/.env" | awk '{print $1}')"
"$SCRIPT" run --dry-run > "$TMP/dry-repo.out" 2>&1
[[ "$before" == "$(sha256sum "$ROOT/.env" | awk '{print $1}')" ]] || fail "dry-run mutated repo .env"
assert_contains "$TMP/dry-repo.out" "Storage mode      : boot-volume"
assert_contains "$TMP/dry-repo.out" "$TMP/state-repo"

mkdir -p "$TMP/state-repo/config"
printf 'PROJECT_STATE_DIR=%s/state-installed\nDATA_VOLUME_DEVICE=\n' "$TMP" > "$TMP/state-repo/config/install.env"
"$SCRIPT" run --dry-run > "$TMP/dry-install.out" 2>&1
assert_contains "$TMP/dry-install.out" "$TMP/state-installed"

# Separate storage is detach-only, including --test-reset.
printf 'PROJECT_STATE_DIR=%s/mnt\nDATA_VOLUME_DEVICE=/dev/sdz\nDATA_VOLUME_MOUNT=%s/mnt\n' "$TMP" "$TMP" > "$ROOT/.env"
rm -rf "$TMP/state-repo"
"$SCRIPT" run --dry-run > "$TMP/dry-block.out" 2>&1
assert_contains "$TMP/dry-block.out" "Storage mode      : separate block-storage"
assert_contains "$TMP/dry-block.out" "Volume data       : PRESERVED (detach only)"
assert_contains "$TMP/dry-block.out" "separate data-volume filesystem contents are preserved"

"$SCRIPT" run --test-reset --dry-run > "$TMP/dry-reset.out" 2>&1
assert_contains "$TMP/dry-reset.out" "Reset mode        : TEST RESET"
assert_contains "$TMP/dry-reset.out" "Git checkout preserved"

# Managed service names remain aligned with setup-systemd.
for expected in \
  vaultwarden-firewall-update.timer \
  vaultwarden-notify-failure@.service \
  vaultwarden-startup.service \
  10-state-dir.conf \
  20-identity.conf \
  30-run-as-root.conf; do
  assert_contains "$SCRIPT" "$expected"
done

# Destructive ownership policy: labels/markers are required for shared-host assets.
assert_contains "$SCRIPT" 'com.docker.compose.project'
assert_contains "$SCRIPT" 'Preserving unlabeled/foreign container'
assert_contains "$SCRIPT" '# Managed by VaultWarden-OCI: CrowdSec email notification'
assert_contains "$SCRIPT" '# BEGIN VaultWarden-OCI CrowdSec email notifications'
assert_contains "$SCRIPT" 'Preserving CrowdSec engine, firewall/Cloudflare bouncers, packages, repository, config, state, and logs.'
assert_contains "$SCRIPT" 'Preserving unmarked raw iptables/ip6tables rules.'
assert_not_contains "$SCRIPT" 'apt-get remove -y --purge'
assert_not_contains "$SCRIPT" 'apt-get autoremove -y'
assert_not_contains "$SCRIPT" 'netfilter-persistent save'
assert_not_contains "$SCRIPT" 'ufw delete allow from'
assert_not_contains "$SCRIPT" 'find "$DATA_VOLUME_MOUNT" -mindepth 1 -maxdepth 1 -xdev -exec rm -rf'

# External backups and operation-lock paths are never casually deleted.
assert_contains "$SCRIPT" "Preserving external backup directory"
assert_contains "$SCRIPT" "Preserving project checkout because external BACKUP_DIR is inside it"
assert_not_contains "$SCRIPT" "rm -f /run/lock/vaultwarden-operations.lock"
assert_not_contains "$SCRIPT" "rm -f /run/lock/vaultwarden-uninstall.lock"
assert_contains "$SCRIPT" 'OPERATION_OWNS_STATE=false'
assert_contains "$SCRIPT" 'OPERATION_STATE_FILE=""'

# Broad recursive deletion retains a hard denylist.
assert_contains "$SCRIPT" "Refusing to remove unsafe broad path"
assert_contains "$SCRIPT" "/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/mnt|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var|/var/lib"

# Destructive phases remain ordered: data first, checkout late, runtime/verification last.
state_line="$(awk '/^main\(\)/{in_main=1} in_main && /remove_state_and_mount/{print NR; exit}' "$SCRIPT")"
installed_line="$(awk '/^main\(\)/{in_main=1} in_main && /remove_installed_files/{print NR; exit}' "$SCRIPT")"
checkout_line="$(awk '/^main\(\)/{in_main=1} in_main && /remove_project_checkout/{print NR; exit}' "$SCRIPT")"
runtime_line="$(awk '/^main\(\)/{in_main=1} in_main && /remove_runtime_artifacts/{print NR; exit}' "$SCRIPT")"
verify_line="$(awk '/^main\(\)/{in_main=1} in_main && /verify_uninstall_complete/{print NR; exit}' "$SCRIPT")"
(( state_line < installed_line && installed_line < checkout_line && checkout_line < runtime_line && runtime_line < verify_line )) \
  || fail "unexpected uninstall cleanup order"

source_uninstaller_for_behavior() {
  set -- run --dry-run
  # shellcheck source=../utilities/uninstall-vaultwarden.sh
  source "$SCRIPT"
  DRY_RUN=false
  FORCE=false
}

write_basic_command_mocks() {
  local bin="$1"
  mkdir -p "$bin"
  for cmd in systemctl chattr; do
    cat > "$bin/$cmd" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$bin/$cmd"
  done
}

write_ufw_mock() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/ufw" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${UFW_LOG:?}"
if [[ "${1:-}" == "status" && "${2:-}" == "numbered" ]]; then
  cat "$UFW_STATE"
  exit 0
fi
if [[ "${1:-}" == "--force" && "${2:-}" == "delete" && "${3:-}" =~ ^[0-9]+$ ]]; then
  num="$3"
  tmp="${UFW_STATE}.tmp"
  awk -v num="$num" '$0 !~ "^\\[[[:space:]]*" num "\\]" { print }' "$UFW_STATE" > "$tmp"
  mv -f "$tmp" "$UFW_STATE"
  exit 0
fi
exit 0
MOCK
  chmod +x "$bin/ufw"
}

# Separate-volume cleanup verifies identity, removes host wiring, and preserves filesystem data.
(
  source_uninstaller_for_behavior
  bin="$TMP/storage-bin"
  write_basic_command_mocks "$bin"
  export MOCK_MOUNTPOINT="$TMP/mounted-data" MOCK_DETACHED="$TMP/detached-data" MOCK_MOUNTED_FLAG="$TMP/is-mounted"
  : > "$MOCK_MOUNTED_FLAG"
  cat > "$bin/mountpoint" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "-q" && "${2:-}" == "${MOCK_MOUNTPOINT:?}" && -e "${MOCK_MOUNTED_FLAG:?}" ]]
MOCK
  cat > "$bin/findmnt" <<'MOCK'
#!/usr/bin/env bash
printf '/dev/mock-volume\n'
MOCK
  cat > "$bin/blkid" <<'MOCK'
#!/usr/bin/env bash
printf 'mock-uuid\n'
MOCK
  cat > "$bin/umount" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
rm -f "${MOCK_MOUNTED_FLAG:?}"
mv "${MOCK_MOUNTPOINT:?}" "${MOCK_DETACHED:?}"
mkdir -p "${MOCK_MOUNTPOINT:?}"
MOCK
  chmod +x "$bin/mountpoint" "$bin/findmnt" "$bin/blkid" "$bin/umount"
  PATH="$bin:$PATH"

  DATA_VOLUME_DEVICE="/dev/mock-volume"
  DATA_VOLUME_MOUNT="$MOCK_MOUNTPOINT"
  PROJECT_STATE_DIR="$DATA_VOLUME_MOUNT"
  mkdir -p "$DATA_VOLUME_MOUNT/config" "$TMP/systemd/docker.service.d"
  cat > "$DATA_VOLUME_MOUNT/.vw-data-volume" <<SENTINEL
VaultWarden-OCI data volume
Device: /dev/mock-volume
Mounted: $DATA_VOLUME_MOUNT
UUID: mock-uuid
SENTINEL
  chmod 444 "$DATA_VOLUME_MOUNT/.vw-data-volume"
  printf 'keep-me\n' > "$DATA_VOLUME_MOUNT/operator-note.txt"
  printf 'vault-data\n' > "$DATA_VOLUME_MOUNT/config/install.env"

  FSTAB_FILE="$TMP/storage-fstab"
  printf 'UUID=mock-uuid\t%s\text4\tdefaults,nofail\t0\t2\n' "$DATA_VOLUME_MOUNT" > "$FSTAB_FILE"
  SYSTEMD_SYSTEM_DIR="$TMP/systemd"
  DOCKER_MOUNT_GUARD_DIR="$SYSTEMD_SYSTEM_DIR/docker.service.d"
  DOCKER_MOUNT_GUARD="$DOCKER_MOUNT_GUARD_DIR/10-vaultwarden-data-volume.conf"
  : > "$DOCKER_MOUNT_GUARD"

  remove_state_and_mount > "$TMP/storage.out" 2>&1
  [[ -f "$MOCK_DETACHED/operator-note.txt" ]] || fail "separate-volume content was deleted"
  [[ -f "$MOCK_DETACHED/config/install.env" ]] || fail "VaultWarden data on separate volume was bulk-deleted"
  [[ ! -e "$MOCK_DETACHED/.vw-data-volume" ]] || fail "sentinel remained on detached volume"
  ! grep -qF "$DATA_VOLUME_MOUNT" "$FSTAB_FILE" || fail "fstab entry remained"
  [[ ! -e "$DOCKER_MOUNT_GUARD" ]] || fail "Docker mount guard remained"
)

# A partial/stale env can never turn a mounted path into recursively deletable boot state.
(
  source_uninstaller_for_behavior
  bin="$TMP/partial-env-bin"
  mkdir -p "$bin"
  export MOCK_PARTIAL_MOUNT="$TMP/partial-mounted"
  cat > "$bin/mountpoint" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "-q" && "${2:-}" == "${MOCK_PARTIAL_MOUNT:?}" ]]
MOCK
  chmod +x "$bin/mountpoint"
  PATH="$bin:$PATH"
  DATA_VOLUME_DEVICE=""
  DATA_VOLUME_MOUNT=""
  PROJECT_STATE_DIR="$MOCK_PARTIAL_MOUNT"
  mkdir -p "$PROJECT_STATE_DIR/config"
  printf 'keep-me\n' > "$PROJECT_STATE_DIR/config/install.env"
  if ( remove_state_and_mount ) > "$TMP/partial-env.out" 2>&1; then
    fail "mount-backed PROJECT_STATE_DIR without device identity should fail closed"
  fi
  [[ -f "$PROJECT_STATE_DIR/config/install.env" ]] || fail "mount-backed state was recursively deleted"
  assert_contains "$TMP/partial-env.out" "looks mount-backed"
)

# Detached device: a unique configured mountpoint entry is removable without manual UUID forensics.
(
  source_uninstaller_for_behavior
  FSTAB_FILE="$TMP/detached-fstab"
  printf 'UUID=old-uuid\t/mnt/vw-data\text4\tdefaults,nofail\t0\t2\n/dev/other\t/mnt/other\text4\tdefaults\t0\t2\n' > "$FSTAB_FILE"
  _remove_fstab_mount /mnt/vw-data /dev/does-not-exist ""
  assert_not_contains "$FSTAB_FILE" "/mnt/vw-data"
  assert_contains "$FSTAB_FILE" "/mnt/other"

  printf 'UUID=a\t/mnt/vw-data\text4\tdefaults\t0\t2\nUUID=b\t/mnt/vw-data\text4\tdefaults\t0\t2\n' > "$FSTAB_FILE"
  if _remove_fstab_mount /mnt/vw-data /dev/does-not-exist ""; then
    fail "duplicate detached fstab entries should fail closed"
  fi
  [[ "$(grep -c '/mnt/vw-data' "$FSTAB_FILE")" == 2 ]] || fail "ambiguous fstab entries changed"
)

# Explicit recovery-kit flag is sufficient; no additional secret/key typing challenge.
(
  source_uninstaller_for_behavior
  RECOVERY_HANDOFF_DIR="$TMP/recovery"
  mkdir -p "$RECOVERY_HANDOFF_DIR"
  printf 'secret\n' > "$RECOVERY_HANDOFF_DIR/vaultwarden-setup-credentials-20260807T000000Z.txt"
  MANAGED_AGE_KEY_PATHS=()
  I_HAVE_SAVED_RECOVERY_KIT=true
  _confirm_age_key_safety </dev/null > "$TMP/recovery.out" 2>&1
  assert_contains "$TMP/recovery.out" "confirmed by explicit flag"
)

# CrowdSec cleanup is marker-scoped and preserves operator content/shared installation.
(
  source_uninstaller_for_behavior
  CROWDSEC_ETC_DIR="$TMP/crowdsec"
  CROWDSEC_EMAIL_PLUGIN="$CROWDSEC_ETC_DIR/notifications/vaultwarden-email.yaml"
  CROWDSEC_EMAIL_PROFILES="$CROWDSEC_ETC_DIR/profiles.yaml.local"
  mkdir -p "$CROWDSEC_ETC_DIR/notifications"
  printf '%s\nname: vaultwarden_email\n' "$CROWDSEC_EMAIL_PLUGIN_MARKER" > "$CROWDSEC_EMAIL_PLUGIN"
  cat > "$CROWDSEC_EMAIL_PROFILES" <<PROFILES
# operator comment
name: operator_profile
$CROWDSEC_EMAIL_PROFILE_BEGIN
---
name: vaultwarden_email_notifications
$CROWDSEC_EMAIL_PROFILE_END
PROFILES
  remove_crowdsec > "$TMP/crowdsec.out" 2>&1
  [[ ! -e "$CROWDSEC_EMAIL_PLUGIN" ]] || fail "marked CrowdSec plugin remained"
  assert_contains "$CROWDSEC_EMAIL_PROFILES" "operator_profile"
  assert_not_contains "$CROWDSEC_EMAIL_PROFILES" "$CROWDSEC_EMAIL_PROFILE_BEGIN"
  assert_contains "$TMP/crowdsec.out" "Preserving CrowdSec engine"

  printf 'name: operator_owned\n' > "$CROWDSEC_EMAIL_PLUGIN"
  remove_crowdsec > "$TMP/crowdsec-unmarked.out" 2>&1
  [[ -f "$CROWDSEC_EMAIL_PLUGIN" ]] || fail "unmarked CrowdSec plugin was removed"
)

# UFW cleanup removes only rules carrying explicit VaultWarden comments.
(
  source_uninstaller_for_behavior
  bin="$TMP/ufw-bin"
  write_ufw_mock "$bin"
  cat > "$bin/iptables" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$bin/iptables"
  PATH="$bin:$PATH"
  export UFW_STATE="$TMP/ufw-state" UFW_LOG="$TMP/ufw.log"
  cat > "$UFW_STATE" <<'UFW'
[ 1] 80/tcp  ALLOW IN 173.245.48.0/20 # CF-IPv4
[ 2] 443/tcp ALLOW IN 173.245.48.0/20
[ 3] 443/tcp ALLOW IN 2606:4700::/32 # CF-IPv6-NEW
[ 4] 22/tcp  ALLOW IN Anywhere # SSH
UFW
  : > "$UFW_LOG"
  remove_firewall_rules > "$TMP/ufw.out" 2>&1
  assert_not_contains "$UFW_STATE" "CF-IPv4"
  assert_not_contains "$UFW_STATE" "CF-IPv6"
  assert_contains "$UFW_STATE" "[ 2] 443/tcp ALLOW IN 173.245.48.0/20"
  assert_contains "$UFW_STATE" "SSH"
  assert_contains "$TMP/ufw.out" "Preserving unmarked raw iptables/ip6tables rules"
)

# Runtime finalization removes transient state without recreating it or unlinking lock pathnames.
(
  source_uninstaller_for_behavior
  _safe_rm_rf() { rm -rf "$1"; }
  RUNTIME_DIR="$TMP/final-runtime"
  mkdir -p "$RUNTIME_DIR"
  global_lock="$TMP/vaultwarden-operations.lock"
  uninstall_lock="$TMP/vaultwarden-uninstall.lock"
  : > "$global_lock"; : > "$uninstall_lock"
  operation_release() {
    if [[ "${OPERATION_OWNS_STATE:-true}" != "false" || -n "${OPERATION_STATE_FILE:-}" ]]; then
      mkdir -p "$RUNTIME_DIR"
    fi
  }
  UNINSTALL_OPERATION_HELD=true
  OPERATION_OWNS_STATE=true
  OPERATION_STATE_FILE="$RUNTIME_DIR/state.json"
  remove_runtime_artifacts
  _finalize_successful_operation_guard
  [[ ! -e "$RUNTIME_DIR" ]] || fail "finalization recreated runtime state"
  [[ -e "$global_lock" && -e "$uninstall_lock" ]] || fail "lock pathnames were unlinked"
)

# Normal uninstall preserves ambiguous host settings; test-reset intentionally resets them.
(
  source_uninstaller_for_behavior
  bin="$TMP/swap-bin"
  mkdir -p "$bin"
  cat > "$bin/swapon" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "--show" ]] && printf '%s\n' "${SWAPON_OUTPUT:-}"
MOCK
  cat > "$bin/swapoff" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SWAPOFF_LOG:?}"
MOCK
  chmod +x "$bin/swapon" "$bin/swapoff"
  PATH="$bin:$PATH"
  export SWAPOFF_LOG="$TMP/swapoff.log"; : > "$SWAPOFF_LOG"

  TEST_RESET=false
  SWAPFILE_PATH="$TMP/swapfile-normal"
  FSTAB_FILE="$TMP/swap-normal-fstab"
  SYSCTL_CONF="$TMP/swap-normal-sysctl.conf"
  APT_SOURCE_UNIVERSE="$TMP/ubuntu-universe.list"
  : > "$SWAPFILE_PATH"; : > "$APT_SOURCE_UNIVERSE"
  printf '%s none swap sw 0 0\n' "$SWAPFILE_PATH" > "$FSTAB_FILE"
  printf 'vm.swappiness=10\nvm.swappiness=60\n' > "$SYSCTL_CONF"
  remove_swap_and_apt_sources > "$TMP/swap-normal.out" 2>&1
  [[ -e "$SWAPFILE_PATH" && -e "$APT_SOURCE_UNIVERSE" ]] || fail "normal uninstall removed ambiguous host state"
  assert_contains "$FSTAB_FILE" "$SWAPFILE_PATH"
  assert_contains "$SYSCTL_CONF" "vm.swappiness=10"

  TEST_RESET=true
  SWAPFILE_PATH="$TMP/swapfile-reset"
  FSTAB_FILE="$TMP/swap-reset-fstab"
  SYSCTL_CONF="$TMP/swap-reset-sysctl.conf"
  APT_SOURCE_UNIVERSE="$TMP/ubuntu-universe-reset.list"
  export SWAPON_OUTPUT="$SWAPFILE_PATH file 1048572 0 -2"
  : > "$SWAPFILE_PATH"; : > "$APT_SOURCE_UNIVERSE"; : > "$SWAPOFF_LOG"
  printf '%s none swap sw 0 0\n/dev/other none swap sw 0 0\n' "$SWAPFILE_PATH" > "$FSTAB_FILE"
  printf 'vm.swappiness=10\nvm.swappiness=5\n' > "$SYSCTL_CONF"
  remove_swap_and_apt_sources > "$TMP/swap-reset.out" 2>&1
  [[ ! -e "$SWAPFILE_PATH" && ! -e "$APT_SOURCE_UNIVERSE" ]] || fail "test-reset preserved setup-only host state"
  assert_not_contains "$FSTAB_FILE" "$SWAPFILE_PATH"
  assert_contains "$FSTAB_FILE" "/dev/other"
  assert_not_contains "$SYSCTL_CONF" "vm.swappiness=10"
  assert_contains "$SYSCTL_CONF" "vm.swappiness=5"
)

# Ambiguous standalone SOPS remains shared host tooling.
(
  source_uninstaller_for_behavior
  SOPS_BIN="$TMP/operator-sops"
  : > "$SOPS_BIN"
  remove_sops_and_packages > "$TMP/sops.out" 2>&1
  [[ -f "$SOPS_BIN" ]] || fail "ambiguous SOPS binary was removed"
  assert_contains "$TMP/sops.out" "Preserving $SOPS_BIN"
)

echo "test-uninstall-vaultwarden: ok"
)

check_uninstall_contracts
