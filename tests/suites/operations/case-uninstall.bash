#!/usr/bin/env bash
# Focused regression checks for destructive uninstall boundaries.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_uninstall_safety() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
ENTRY="$ROOT/utilities/uninstall-vaultwarden.sh"
CORE="$ROOT/utilities/uninstall-vaultwarden-core.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
contains_code() { grep -Fq -- "$1" "$ENTRY" || grep -Fq -- "$1" "$CORE"; }
not_in_code() { ! grep -Fq -- "$1" "$ENTRY" && ! grep -Fq -- "$1" "$CORE"; }

bash -n "$ENTRY"
bash -n "$CORE"
"$ENTRY" --help >/dev/null
"$ENTRY" --version >/dev/null

# Shared-host policy stays conservative.
contains_code 'separate data-volume filesystem contents are preserved' || fail "detach-only storage contract missing"
contains_code 'Preserving CrowdSec engine' || fail "shared CrowdSec preservation missing"
contains_code 'Preserving unmarked raw iptables/ip6tables rules' || fail "raw netfilter preservation missing"
contains_code 'com.docker.compose.project' || fail "Compose ownership check missing"
not_in_code 'apt-get remove -y --purge' || fail "uninstall still purges shared packages"
not_in_code 'apt-get autoremove -y' || fail "uninstall still autoremove shared packages"
not_in_code 'find "$DATA_VOLUME_MOUNT" -mindepth 1 -maxdepth 1 -xdev -exec rm -rf' || fail "separate volume bulk-delete returned"

source_uninstaller() {
  set -- run --dry-run
  # shellcheck source=../utilities/uninstall-vaultwarden.sh
  source "$ENTRY"
  DRY_RUN=false
  FORCE=false
}

# Detached-device fallback accepts only the exact setup-written fstab signature.
(
  source_uninstaller
  FSTAB_FILE="$TMP/fstab"
  printf 'UUID=managed\t/mnt/vw-data\text4\tnoatime,nofail,x-systemd.device-timeout=30s\t0\t2\n' > "$FSTAB_FILE"
  _remove_fstab_mount /mnt/vw-data /dev/missing "" || fail "setup-signature fstab fallback was rejected"
  ! grep -qF '/mnt/vw-data' "$FSTAB_FILE" || fail "setup-signature fstab entry remained"

  printf 'UUID=operator\t/mnt/vw-data\text4\tdefaults,nofail\t0\t2\n' > "$FSTAB_FILE"
  if _remove_fstab_mount /mnt/vw-data /dev/missing ""; then
    fail "unmarked mountpoint-only fstab entry was removed"
  fi
  grep -qF 'UUID=operator' "$FSTAB_FILE" || fail "operator fstab entry changed"
)

# A repo-local Age key remains recovery-guarded when source is retained only
# because an external backup subtree lives inside the checkout.
(
  source_uninstaller
  PROJECT_DIR="$TMP/project"
  PROJECT_STATE_DIR="$TMP/state"
  BACKUP_DIR="$PROJECT_DIR/backups/retained"
  DATA_VOLUME_DEVICE=""
  TEST_RESET=false
  mkdir -p "$PROJECT_DIR/secrets/keys" "$BACKUP_DIR"
  key="$PROJECT_DIR/secrets/keys/age-key.txt"
  printf 'AGE-SECRET-KEY-TEST\n' > "$key"
  MANAGED_AGE_KEY_PATHS=("$key")
  [[ "$(_existing_age_keys)" == "$key" ]] || fail "repo Age key escaped recovery guard"
)

# Mount-backed state without verified device identity fails closed instead of
# becoming recursive boot-volume deletion.
(
  source_uninstaller
  bin="$TMP/bin"
  mkdir -p "$bin"
  export MOCK_MOUNT="$TMP/mounted-state"
  cat > "$bin/mountpoint" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "-q" && "${2:-}" == "${MOCK_MOUNT:?}" ]]
MOCK
  chmod +x "$bin/mountpoint"
  PATH="$bin:$PATH"
  DATA_VOLUME_DEVICE=""
  DATA_VOLUME_MOUNT=""
  PROJECT_STATE_DIR="$MOCK_MOUNT"
  mkdir -p "$PROJECT_STATE_DIR/config"
  printf 'keep\n' > "$PROJECT_STATE_DIR/config/install.env"
  if ( remove_state_and_mount ) > "$TMP/mount.out" 2>&1; then
    fail "mount-backed state without device identity did not fail closed"
  fi
  [[ -f "$PROJECT_STATE_DIR/config/install.env" ]] || fail "mount-backed state was deleted"
  grep -Fq 'looks mount-backed' "$TMP/mount.out" || fail "fail-closed diagnostic missing"
)

echo "case-uninstall: ok"
)

check_uninstall_safety
