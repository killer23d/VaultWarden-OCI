#!/usr/bin/env bash
# Consolidated uninstall regression suite.
set -euo pipefail

check_uninstall_contracts() (
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# Dry-run does not require root-only live operations and does not mutate repo .env.
printf 'PROJECT_STATE_DIR=%s/state-repo\nDATA_VOLUME_DEVICE=\n' "$TMP" > "$ROOT/.env"
before="$(sha256sum "$ROOT/.env" | awk '{print $1}')"
"$SCRIPT" run --dry-run > "$TMP/dry-repo.out" 2>&1
_after="$(sha256sum "$ROOT/.env" | awk '{print $1}')"
[[ "$before" == "$_after" ]] || fail "dry-run mutated repo .env"
assert_contains "$TMP/dry-repo.out" "Storage mode      : boot-volume"
assert_contains "$TMP/dry-repo.out" "$TMP/state-repo"

# Test-reset dry-run preserves source while promising a clean generated install state.
"$SCRIPT" run --test-reset --dry-run > "$TMP/dry-reset.out" 2>&1
assert_contains "$TMP/dry-reset.out" "Reset mode        : TEST RESET"
assert_contains "$TMP/dry-reset.out" "preserve Git checkout: $ROOT"
assert_contains "$TMP/dry-reset.out" "remove generated checkout-local config/secrets/compose/runtime artifacts for a clean reinstall"

# Install env discovered through repo PROJECT_STATE_DIR takes precedence over repo-local values.
mkdir -p "$TMP/state-repo/config"
printf 'PROJECT_STATE_DIR=%s/state-installed\nDATA_VOLUME_DEVICE=\n' "$TMP" > "$TMP/state-repo/config/install.env"
"$SCRIPT" run --dry-run > "$TMP/dry-install.out" 2>&1
assert_contains "$TMP/dry-install.out" "$TMP/state-installed"

# Separate-volume path resolution and unmounted safety wording.
printf 'PROJECT_STATE_DIR=%s/mnt\nDATA_VOLUME_DEVICE=/dev/sdz\nDATA_VOLUME_MOUNT=%s/mnt\n' "$TMP" "$TMP" > "$ROOT/.env"
rm -rf "$TMP/state-repo"
"$SCRIPT" run --dry-run > "$TMP/dry-block.out" 2>&1
assert_contains "$TMP/dry-block.out" "Storage mode      : separate block-storage"
assert_contains "$TMP/dry-block.out" "device=/dev/sdz mount=$TMP/mnt mounted=false sentinel=false"
assert_contains "$TMP/dry-block.out" "unmounted mountpoint contents will NOT be recursively deleted"

# Systemd and Docker managed lists match current setup contracts.
assert_contains "$SCRIPT" "vaultwarden-firewall-update.timer"
assert_contains "$SCRIPT" "vaultwarden-notify-failure@.service"
assert_contains "$SCRIPT" "vaultwarden-startup.service"
assert_contains "$SCRIPT" "10-state-dir.conf"
assert_contains "$SCRIPT" "20-identity.conf"
assert_contains "$SCRIPT" "30-run-as-root.conf"
assert_contains "$SCRIPT" "vaultwarden_init"
assert_contains "$SCRIPT" "vaultwarden_app"
assert_contains "$SCRIPT" "vaultwarden_caddy"
assert_contains "$SCRIPT" "vaultwarden_postfix"
assert_contains "$SCRIPT" "vaultwarden_egress_network"
assert_contains "$SCRIPT" "caddy_external_network"
assert_contains "$SCRIPT" "postfix_relay_network"
assert_not_contains "$SCRIPT" "name=caddy"
assert_not_contains "$SCRIPT" "name=postfix"

# Current and historical firewall contracts are exhausted and persisted cleanly.
assert_contains "$SCRIPT" "172.21.0.0/28"
assert_contains "$SCRIPT" "172.22.0.0/28"
assert_contains "$SCRIPT" "172.23.0.0/28"
assert_contains "$SCRIPT" "172.21.0.0/16"
assert_contains "$SCRIPT" "MANAGED_CLOUDFLARE_CIDRS"
assert_contains "$SCRIPT" "_remove_managed_cloudflare_ufw_rules"
assert_contains "$SCRIPT" "ufw delete allow from"
assert_not_contains "$SCRIPT" "{1..30}"
assert_not_contains "$SCRIPT" "yes | ufw delete"
assert_contains "$SCRIPT" "netfilter-persistent save"

# Both firewall-bouncer backends can be installed by setup-crowdsec and must be purged.
assert_contains "$SCRIPT" "crowdsec-firewall-bouncer-iptables"
assert_contains "$SCRIPT" "crowdsec-firewall-bouncer-nftables"

# External BACKUP_DIR preservation must run before checkout deletion can remove its parent.
assert_contains "$SCRIPT" "_backup_dir_is_external_to_state()"
assert_contains "$SCRIPT" "Preserving project checkout because external BACKUP_DIR is inside it"
assert_contains "$SCRIPT" "Move/delete the backup directory manually"
state_line="$(awk '/^main\(\)/{in_main=1} in_main && /remove_state_and_mount/{print NR; exit}' "$SCRIPT")"
installed_line="$(awk '/^main\(\)/{in_main=1} in_main && /remove_installed_files/{print NR; exit}' "$SCRIPT")"
checkout_line="$(awk '/^main\(\)/{in_main=1} in_main && /remove_project_checkout/{print NR; exit}' "$SCRIPT")"
runtime_line="$(awk '/^main\(\)/{in_main=1} in_main && /remove_runtime_artifacts/{print NR; exit}' "$SCRIPT")"
verify_line="$(awk '/^main\(\)/{in_main=1} in_main && /verify_uninstall_complete/{print NR; exit}' "$SCRIPT")"
[[ -n "$state_line" && -n "$installed_line" && -n "$checkout_line" && -n "$runtime_line" && -n "$verify_line" ]] \
  || fail "could not locate cleanup order in main"
(( state_line < installed_line )) || fail "remove_state_and_mount must run before remove_installed_files"
(( installed_line < checkout_line )) || fail "checkout deletion must be deferred until host cleanup is complete"
(( checkout_line < runtime_line && runtime_line < verify_line )) || fail "runtime cleanup and residual verification must run last"

# The live operation guard must not unlink its own global or specific lock path.
assert_contains "$SCRIPT" "Do not unlink"
assert_not_contains "$SCRIPT" "rm -f /run/lock/vaultwarden-operations.lock"
assert_not_contains "$SCRIPT" "rm -f /run/lock/vaultwarden-uninstall.lock"
assert_contains "$SCRIPT" "OPERATION_OWNS_STATE=false"
assert_contains "$SCRIPT" "OPERATION_STATE_FILE=\"\""

# _safe_rm_rf broad-path denylist contract.
assert_contains "$SCRIPT" "Refusing to remove unsafe broad path"
assert_contains "$SCRIPT" "/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/mnt|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var|/var/lib"

# A complete uninstall is explicitly verified instead of assuming cleanup succeeded.
assert_contains "$SCRIPT" "verify_uninstall_complete()"
assert_contains "$SCRIPT" "Uninstall incomplete —"
assert_contains "$SCRIPT" "Residual verification passed: no managed stack artifacts remain."

source_uninstaller_for_behavior() {
  set -- run --dry-run
  # shellcheck source=../utilities/uninstall-vaultwarden.sh
  source "$SCRIPT"
  DRY_RUN=false
  FORCE=false
  operation_package_run() { return 0; }
}

write_basic_command_mocks() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  cat > "$bin/chattr" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  cat > "$bin/docker" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  network\ inspect*) exit 1 ;;
  *) exit 0 ;;
esac
MOCK
  cat > "$bin/dpkg" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  cat > "$bin/getent" <<'MOCK'
#!/usr/bin/env bash
exit 2
MOCK
  chmod +x "$bin/systemctl" "$bin/chattr" "$bin/docker" "$bin/dpkg" "$bin/getent"
}

write_ufw_mock() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/ufw" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${UFW_LOG:?}"
remove_line() {
  local port="$1" source="$2" before after tmp
  tmp="${UFW_STATE}.tmp"
  before="$(wc -l < "$UFW_STATE")"
  awk -v port="${port}/tcp" -v source="$source" '!(index($0, port) && index($0, source)) { print }' "$UFW_STATE" > "$tmp"
  mv -f "$tmp" "$UFW_STATE"
  after="$(wc -l < "$UFW_STATE")"
  [[ "$before" != "$after" ]]
}
if [[ "${1:-}" == "status" && "${2:-}" == "numbered" ]]; then
  cat "$UFW_STATE"
  exit 0
fi
if [[ "${1:-}" == "delete" && "${2:-}" == "allow" && "${3:-}" == "80/tcp" ]]; then
  remove_line 80 Anywhere
  exit $?
fi
if [[ "${1:-}" == "delete" && "${2:-}" == "allow" && "${3:-}" == "443/tcp" ]]; then
  remove_line 443 Anywhere
  exit $?
fi
if [[ "${1:-}" == "delete" && "${2:-}" == "allow" && "${3:-}" == "from" ]]; then
  remove_line "${8:-}" "${4:-}"
  exit $?
fi
if [[ "${1:-}" == "--force" && "${2:-}" == "delete" && "${3:-}" =~ ^[0-9]+$ ]]; then
  num="$3"
  tmp="${UFW_STATE}.tmp"
  awk -v num="$num" '
    {
      if ($0 ~ "^\\[ *" num "\\]") { next }
      print
    }
  ' "$UFW_STATE" > "$tmp"
  mv -f "$tmp" "$UFW_STATE"
  exit 0
fi
if [[ "${1:-}" == "allow" && "${2:-}" == "proto" && "${3:-}" == "tcp" && "${4:-}" == "from" ]]; then
  cidr="$5"
  port="$9"
  comment="${11:-}"
  next_num=$(( $(wc -l < "$UFW_STATE" 2>/dev/null || echo 0) + 1 ))
  printf '[ %d] %s/tcp                     ALLOW IN    %s            # %s\n' "$next_num" "$port" "$cidr" "$comment" >> "$UFW_STATE"
  exit 0
fi
if [[ "${1:-}" == "status" ]]; then
  cat "$UFW_STATE"
  exit 0
fi
exit 0
MOCK
  chmod +x "$bin/ufw"
}

write_noop_iptables_mock() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/iptables" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  cat > "$bin/netfilter-persistent" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$bin/iptables" "$bin/netfilter-persistent"
}

# Mounted block-storage without the sentinel must fail before fstab or guard mutation.
(
  source_uninstaller_for_behavior
  bin="$TMP/storage-bin"
  write_basic_command_mocks "$bin"
  cat > "$bin/mountpoint" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "-q" && "${2:-}" == "${MOCK_MOUNTPOINT:?}" ]]
MOCK
  cat > "$bin/findmnt" <<'MOCK'
#!/usr/bin/env bash
printf '/dev/mock-volume\n'
MOCK
  cat > "$bin/umount" <<'MOCK'
#!/usr/bin/env bash
printf 'umount %s\n' "$*" >> "${UMOUNT_LOG:?}"
exit 0
MOCK
  chmod +x "$bin/mountpoint" "$bin/findmnt" "$bin/umount"
  PATH="$bin:$PATH"
  export MOCK_MOUNTPOINT="$TMP/mounted-data" UMOUNT_LOG="$TMP/storage-umount.log"
  DATA_VOLUME_DEVICE="/dev/mock-volume"
  DATA_VOLUME_MOUNT="$MOCK_MOUNTPOINT"
  PROJECT_STATE_DIR="$DATA_VOLUME_MOUNT"
  mkdir -p "$DATA_VOLUME_MOUNT" "$TMP/systemd/docker.service.d"
  FSTAB_FILE="$TMP/storage-fstab"
  printf '/dev/mock-volume\t%s\text4\tdefaults\t0\t2\n' "$DATA_VOLUME_MOUNT" > "$FSTAB_FILE"
  cp "$FSTAB_FILE" "$TMP/storage-fstab.before"
  SYSTEMD_SYSTEM_DIR="$TMP/systemd"
  DOCKER_MOUNT_GUARD_DIR="$SYSTEMD_SYSTEM_DIR/docker.service.d"
  DOCKER_MOUNT_GUARD="$DOCKER_MOUNT_GUARD_DIR/10-vaultwarden-data-volume.conf"
  : > "$DOCKER_MOUNT_GUARD"
  if ( remove_state_and_mount ) > "$TMP/storage.out" 2>&1; then
    fail "mounted data volume without sentinel should fail closed"
  fi
  cmp -s "$FSTAB_FILE" "$TMP/storage-fstab.before" || fail "fstab changed before mounted sentinel validation"
  [[ -f "$DOCKER_MOUNT_GUARD" ]] || fail "docker mount guard removed before mounted sentinel validation"
  [[ ! -s "$UMOUNT_LOG" ]] || fail "unknown mounted volume was unmounted"
  assert_contains "$TMP/storage.out" "lacks .vw-data-volume sentinel"
)

# UFW cleanup removes cached Cloudflare CIDRs, explicitly commented managed rules, and historical broad rules.
(
  source_uninstaller_for_behavior
  bin="$TMP/ufw-bin"
  write_basic_command_mocks "$bin"
  write_ufw_mock "$bin"
  write_noop_iptables_mock "$bin"
  PATH="$bin:$PATH"
  export UFW_STATE="$TMP/ufw-state" UFW_LOG="$TMP/ufw.log"

  # A = 173.245.48.0/20 (cached managed)
  # B = 104.16.0.0/12 (commented managed, absent from cache)
  # C = 203.0.113.77 (unrelated)
  cat > "$UFW_STATE" <<EOF_UFW
[ 1] 80/tcp                     ALLOW IN    173.245.48.0/20            # CF-IPv4
[ 2] 443/tcp                    ALLOW IN    173.245.48.0/20            # CF-IPv4
[ 3] 80/tcp                     ALLOW IN    104.16.0.0/12              # CF-IPv4-NEW
[ 4] 443/tcp                    ALLOW IN    104.16.0.0/12              # CF-IPv4-NEW
[ 5] 443/tcp                    ALLOW IN    203.0.113.77
[ 6] 22/tcp                     ALLOW IN    Anywhere                   # SSH
EOF_UFW
  : > "$UFW_LOG"
  PROJECT_STATE_DIR="$TMP/ufw-project-state"
  DATA_VOLUME_MOUNT=""
  mkdir -p "$PROJECT_STATE_DIR"
  printf '173.245.48.0/20\n' > "$PROJECT_STATE_DIR/cf-cidrs.cache"
  _capture_managed_cloudflare_cidrs

  remove_firewall_rules
  remove_firewall_rules

  assert_not_contains "$UFW_STATE" "173.245.48.0/20"
  assert_not_contains "$UFW_STATE" "104.16.0.0/12"
  assert_contains "$UFW_STATE" "203.0.113.77"
  assert_contains "$UFW_STATE" "22/tcp"
  assert_contains "$UFW_STATE" "SSH"
  assert_contains "$UFW_LOG" "delete allow from 173.245.48.0/20 to any port 80 proto tcp"
)

# Netfilter cleanup removes managed current subnet rules, preserves unrelated rules, then persists.
(
  source_uninstaller_for_behavior
  bin="$TMP/netfilter-bin"
  write_basic_command_mocks "$bin"
  cat > "$bin/ufw" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  cat > "$bin/iptables" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'iptables %s\n' "$*" >> "${IPTABLES_LOG:?}"
remove_rule() {
  local kind="$1" subnet="$2" before after tmp
  tmp="${IPTABLES_STATE}.tmp"
  before="$(wc -l < "$IPTABLES_STATE")"
  awk -v kind="$kind" -v subnet="$subnet" '!(($1 == kind) && ($2 == subnet)) { print }' "$IPTABLES_STATE" > "$tmp"
  mv -f "$tmp" "$IPTABLES_STATE"
  after="$(wc -l < "$IPTABLES_STATE")"
  [[ "$before" != "$after" ]]
}
if [[ "$*" == "-t filter -S DOCKER-USER" ]]; then
  exit 0
fi
if [[ "${1:-}" == "-t" && "${2:-}" == "nat" && "${3:-}" == "-D" ]]; then
  remove_rule nat "${6:-}"
  exit $?
fi
if [[ "${1:-}" == "-t" && "${2:-}" == "filter" && "${3:-}" == "-D" ]]; then
  remove_rule filter "${6:-}"
  exit $?
fi
exit 1
MOCK
  cat > "$bin/netfilter-persistent" <<'MOCK'
#!/usr/bin/env bash
printf 'netfilter-persistent %s\n' "$*" >> "${IPTABLES_LOG:?}"
exit 0
MOCK
  chmod +x "$bin/ufw" "$bin/iptables" "$bin/netfilter-persistent"
  PATH="$bin:$PATH"
  export IPTABLES_STATE="$TMP/iptables-state" IPTABLES_LOG="$TMP/iptables.log"
  cat > "$IPTABLES_STATE" <<'EOF_IPT'
nat 172.21.0.0/28
filter 172.21.0.0/28
nat 10.77.0.0/16
EOF_IPT
  : > "$IPTABLES_LOG"
  MANAGED_CLOUDFLARE_CIDRS=()
  remove_firewall_rules
  assert_not_contains "$IPTABLES_STATE" "172.21.0.0/28"
  assert_contains "$IPTABLES_STATE" "10.77.0.0/16"
  [[ "$(tail -n 1 "$IPTABLES_LOG")" == "netfilter-persistent save" ]] || fail "netfilter save did not happen after cleanup"
  assert_contains "$IPTABLES_LOG" "iptables -t nat -D POSTROUTING -s 172.21.0.0/28"
)

# Residual verifier accepts clean mocked state with unrelated HTTPS and retained shared SOPS.
(
  source_uninstaller_for_behavior
  bin="$TMP/residual-bin"
  write_basic_command_mocks "$bin"
  write_ufw_mock "$bin"
  write_noop_iptables_mock "$bin"
  PATH="$bin:$PATH"
  export UFW_STATE="$TMP/residual-ufw-state" UFW_LOG="$TMP/residual-ufw.log"
  printf '[ 1] 443/tcp                    ALLOW IN    203.0.113.77\n' > "$UFW_STATE"
  : > "$UFW_LOG"
  TEST_RESET=true
  PROJECT_DIR="$TMP/mock-clean-checkout"
  PROJECT_BASENAME="VaultWarden-OCI"
  DATA_VOLUME_DEVICE=""
  PROJECT_STATE_DIR="$TMP/no-state"
  BACKUP_DIR="$PROJECT_STATE_DIR/backups"
  SYSTEMD_SYSTEM_DIR="$TMP/residual-systemd"
  DOCKER_MOUNT_GUARD_DIR="$SYSTEMD_SYSTEM_DIR/docker.service.d"
  DOCKER_MOUNT_GUARD="$DOCKER_MOUNT_GUARD_DIR/10-vaultwarden-data-volume.conf"
  OPT_SCRIPTS_DIR="$TMP/no-opt-scripts"
  ETC_VAULTWARDEN_DIR="$TMP/no-etc-vaultwarden"
  CROWDSEC_BOUNCER_BIN="$TMP/no-crowdsec-bouncer"
  CROWDSEC_BOUNCER_SERVICE="$SYSTEMD_SYSTEM_DIR/crowdsec-cloudflare-worker-bouncer.service"
  CROWDSEC_ETC_DIR="$TMP/no-etc-crowdsec"
  CROWDSEC_STATE_DIR="$TMP/no-var-lib-crowdsec"
  CROWDSEC_LOG_DIR="$TMP/no-var-log-crowdsec"
  RUNTIME_DIR="$TMP/no-runtime"
  SWAPFILE_PATH="$TMP/no-swapfile"
  SOPS_BIN="$TMP/shared-sops"
  FSTAB_FILE="$TMP/residual-fstab"
  IPTABLES_RULES_V4="$TMP/rules.v4"
  MANAGED_CLOUDFLARE_CIDRS=(173.245.48.0/20)
  mkdir -p "$PROJECT_DIR/.git"
  mkdir -p "$SYSTEMD_SYSTEM_DIR"
  : > "$FSTAB_FILE"
  : > "$IPTABLES_RULES_V4"
  : > "$SOPS_BIN"
  if ! verify_uninstall_complete > "$TMP/residual-clean.out" 2>&1; then
    cat "$TMP/residual-clean.out" >&2
    fail "clean mocked residual state should pass verification"
  fi
  assert_contains "$TMP/residual-clean.out" "Residual verification passed"

  printf '[ 1] 443/tcp                    ALLOW IN    173.245.48.0/20\n' > "$UFW_STATE"
  if ( verify_uninstall_complete ) > "$TMP/residual-managed.out" 2>&1; then
    fail "managed UFW residual should fail verification"
  fi
  assert_contains "$TMP/residual-managed.out" "RESIDUAL: UFW still has managed Cloudflare HTTP/HTTPS rule for 173.245.48.0/20"

  printf '[ 1] 80/tcp                     ALLOW IN    104.16.0.0/12              # CF-IPv4\n' > "$UFW_STATE"
  if ( verify_uninstall_complete ) > "$TMP/residual-managed-b.out" 2>&1; then
    fail "managed UFW residual with explicit comment should fail verification"
  fi
  assert_contains "$TMP/residual-managed-b.out" "RESIDUAL"
  assert_contains "$TMP/residual-managed-b.out" "104.16.0.0/12"

  printf '[ 1] 443/tcp                    ALLOW IN    203.0.113.77\n' > "$UFW_STATE"
  if ! verify_uninstall_complete > "$TMP/residual-clean-c.out" 2>&1; then
    cat "$TMP/residual-clean-c.out" >&2
    fail "clean mocked residual state with unrelated rule should pass verification"
  fi
)

# Final runtime cleanup must not recreate runtime state and must preserve lock pathnames.
(
  source_uninstaller_for_behavior
  _safe_rm_rf() { rm -rf "$1"; }
  RUNTIME_DIR="$TMP/final-runtime"
  mkdir -p "$RUNTIME_DIR"
  global_lock="$TMP/vaultwarden-operations.lock"
  uninstall_lock="$TMP/vaultwarden-uninstall.lock"
  : > "$global_lock"
  : > "$uninstall_lock"
  operation_release() {
    if [[ "${OPERATION_OWNS_STATE:-true}" != "false" || -n "${OPERATION_STATE_FILE:-}" ]]; then
      mkdir -p "$RUNTIME_DIR"
    fi
    return 0
  }
  UNINSTALL_OPERATION_HELD=true
  OPERATION_OWNS_STATE=true
  OPERATION_STATE_FILE="$RUNTIME_DIR/state.json"
  remove_runtime_artifacts
  _finalize_successful_operation_guard
  [[ ! -e "$RUNTIME_DIR" ]] || fail "finalization recreated runtime state"
  [[ -e "$global_lock" && -e "$uninstall_lock" ]] || fail "lock pathnames were unlinked"
)

# Swap cleanup preserves ambiguous swap in normal uninstall but resets it for test-reset.
(
  source_uninstaller_for_behavior
  bin="$TMP/swap-bin"
  write_basic_command_mocks "$bin"
  cat > "$bin/swapon" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "--show" ]] && printf '%s\n' "${SWAPON_OUTPUT:-}"
MOCK
  cat > "$bin/swapoff" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SWAPOFF_LOG:?}"
exit 0
MOCK
  cat > "$bin/sysctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSCTL_LOG:?}"
exit 0
MOCK
  chmod +x "$bin/swapon" "$bin/swapoff" "$bin/sysctl"
  PATH="$bin:$PATH"
  export SWAPOFF_LOG="$TMP/swapoff.log" SYSCTL_LOG="$TMP/sysctl.log"
  : > "$SWAPOFF_LOG"
  : > "$SYSCTL_LOG"

  TEST_RESET=false
  SWAPFILE_PATH="$TMP/swapfile-normal"
  FSTAB_FILE="$TMP/swap-normal-fstab"
  SYSCTL_CONF="$TMP/swap-normal-sysctl.conf"
  APT_SOURCE_UNIVERSE="$TMP/ubuntu-universe.list"
  : > "$SWAPFILE_PATH"
  printf '%s none swap sw 0 0\n' "$SWAPFILE_PATH" > "$FSTAB_FILE"
  printf 'vm.swappiness=10\nvm.swappiness=60\nvm.swappiness = 10\n' > "$SYSCTL_CONF"
  remove_swap_and_apt_sources > "$TMP/swap-normal.out" 2>&1
  [[ -e "$SWAPFILE_PATH" ]] || fail "normal uninstall removed ambiguous swapfile"
  assert_contains "$FSTAB_FILE" "$SWAPFILE_PATH"
  assert_not_contains "$SYSCTL_CONF" "vm.swappiness=10"
  assert_contains "$SYSCTL_CONF" "vm.swappiness=60"
  assert_contains "$SYSCTL_CONF" "vm.swappiness = 10"
  [[ ! -s "$SWAPOFF_LOG" ]] || fail "normal uninstall called swapoff for ambiguous swapfile"
  [[ ! -s "$SYSCTL_LOG" ]] || fail "uninstall forced runtime swappiness"

  TEST_RESET=true
  SWAPFILE_PATH="$TMP/swapfile-reset"
  FSTAB_FILE="$TMP/swap-reset-fstab"
  SYSCTL_CONF="$TMP/swap-reset-sysctl.conf"
  export SWAPON_OUTPUT="$SWAPFILE_PATH file 1048572 0 -2"
  : > "$SWAPFILE_PATH"
  : > "$SWAPOFF_LOG"
  printf '%s none swap sw 0 0\n/dev/other none swap sw 0 0\n' "$SWAPFILE_PATH" > "$FSTAB_FILE"
  printf 'vm.swappiness=10\nvm.swappiness=5\n' > "$SYSCTL_CONF"
  remove_swap_and_apt_sources > "$TMP/swap-reset.out" 2>&1
  [[ ! -e "$SWAPFILE_PATH" ]] || fail "test-reset preserved setup swap path"
  assert_not_contains "$FSTAB_FILE" "$SWAPFILE_PATH"
  assert_contains "$FSTAB_FILE" "/dev/other"
  assert_not_contains "$SYSCTL_CONF" "vm.swappiness=10"
  assert_contains "$SYSCTL_CONF" "vm.swappiness=5"
  assert_contains "$SWAPOFF_LOG" "$SWAPFILE_PATH"
)

# Ambiguous pre-existing SOPS is retained and does not fail clean reset verification.
(
  source_uninstaller_for_behavior
  SOPS_BIN="$TMP/operator-sops"
  : > "$SOPS_BIN"
  remove_sops_and_packages > "$TMP/sops.out" 2>&1
  [[ -f "$SOPS_BIN" ]] || fail "ambiguous SOPS binary was removed"
  assert_contains "$TMP/sops.out" "Preserving $SOPS_BIN"
)

# Maintenance lifecycle and set -e regression test
(
  export UPDATE_FIREWALL=true DRY_RUN=false CLOUDFLARE_PROXY_ENABLED=true
  bin="$TMP/maint-bin"
  write_basic_command_mocks "$bin"
  write_ufw_mock "$bin"
  chmod +x "$bin/ufw"
  PATH="$bin:$PATH"
  export UFW_STATE="$TMP/maint-ufw-state" UFW_LOG="$TMP/maint-ufw.log"
  export PROJECT_STATE_DIR="$TMP/state-dir"
  mkdir -p "$PROJECT_STATE_DIR"
  : > "$UFW_STATE"
  : > "$UFW_LOG"

  # 1. Previous cache contains CIDR A (104.16.0.0/12 and 2606:4700::/32)
  printf '104.16.0.0/12\n2606:4700::/32\n' > "$PROJECT_STATE_DIR/cf-cidrs.cache"

  # 2. UFW contains un-commented port 80 and 443 rules for A, representing the existing setup-firewall.sh contract
  ufw allow proto tcp from 104.16.0.0/12 to any port 80 >/dev/null
  ufw allow proto tcp from 104.16.0.0/12 to any port 443 >/dev/null
  ufw allow proto tcp from 2606:4700::/32 to any port 80 >/dev/null
  ufw allow proto tcp from 2606:4700::/32 to any port 443 >/dev/null

  # Add an unrelated HTTPS rule C
  ufw allow proto tcp from 1.2.3.4 to any port 443 >/dev/null

  # 3. current Cloudflare fetch returns CIDR B instead
  cat > "$bin/curl" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" =~ ips-v4 ]]; then
    printf '173.245.48.0/20\n' > "$6"
    exit 0
elif [[ "$*" =~ ips-v6 ]]; then
    printf '2803:f800::/32\n' > "$6"
    exit 0
fi
exit 1
MOCK
  chmod +x "$bin/curl"

  cp "$ROOT/utilities/maintenance-update-firewall.sh" "$TMP/maint-mock.sh"
  sed -i.bak 's/main "$@"//' "$TMP/maint-mock.sh"
  sed -i.bak 's|PROJECT_ROOT=.*|PROJECT_ROOT="'"$ROOT"'"|g' "$TMP/maint-mock.sh"
  cat << 'EOF' >> "$TMP/maint-mock.sh"
require_root() { return 0; }
update_firewall_ranges
EOF

  # 4 & 5. execute the maintenance update in a fresh Bash process with set -euo pipefail
  bash -euo pipefail "$TMP/maint-mock.sh" > "$TMP/maint1.out" 2>&1 || fail "maintenance update failed under set -e"

  # Assert maintenance exits zero (done above via || fail)
  # Assert all stale managed rules (un-commented A) are removed
  assert_not_contains "$UFW_STATE" "104.16.0.0/12"
  assert_not_contains "$UFW_STATE" "2606:4700::/32"

  # Assert current rules remain (actually new B installed with stable comment)
  assert_contains "$UFW_STATE" "173.245.48.0/20"
  assert_contains "$UFW_STATE" "2803:f800::/32"
  assert_contains "$UFW_STATE" "CF-IPv4"
  assert_contains "$UFW_STATE" "CF-IPv6"

  # Assert unrelated rule C survives
  assert_contains "$UFW_STATE" "1.2.3.4"

  # 6. the cache is updated to B
  assert_contains "$PROJECT_STATE_DIR/cf-cidrs.cache" "173.245.48.0/20"
  assert_contains "$PROJECT_STATE_DIR/cf-cidrs.cache" "2803:f800::/32"
  assert_not_contains "$PROJECT_STATE_DIR/cf-cidrs.cache" "104.16.0.0/12"

  # 7. uninstall can subsequently recognize and remove B
  source_uninstaller_for_behavior
  write_noop_iptables_mock "$bin"
  export MANAGED_CLOUDFLARE_CIDRS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && MANAGED_CLOUDFLARE_CIDRS+=("$line")
  done < "$PROJECT_STATE_DIR/cf-cidrs.cache"
  
  remove_firewall_rules
  assert_not_contains "$UFW_STATE" "173.245.48.0/20"
  assert_not_contains "$UFW_STATE" "2803:f800::/32"

  # 8. unrelated HTTPS rule C survives
  assert_contains "$UFW_STATE" "1.2.3.4"
)

echo "test-uninstall-vaultwarden: ok"

)

check_uninstall_contracts
