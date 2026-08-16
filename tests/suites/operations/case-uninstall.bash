#!/usr/bin/env bash
# Focused regression checks for destructive uninstall boundaries.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"
ROOT_REPO="$VW_TEST_REPO_ROOT"
U="$ROOT_REPO/utilities/uninstall-vaultwarden.sh"
T="$(mktemp -d)"
UNINSTALL_MOUNT="/tmp/vw_uninstall_mount_$$"
trap 'rm -rf "$T" "$UNINSTALL_MOUNT"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

bash -n "$U"
[[ ! -e "$ROOT_REPO/utilities/uninstall-vaultwarden-core.sh" ]] || fail "split core file returned"
! grep -q 'uninstall-vaultwarden-core' "$U" || fail "entrypoint/core split reference returned"
! grep -q 'umount -l' "$U" || fail "lazy unmount returned"
! grep -Eq 'apt-get (remove|autoremove).*purge|apt-get autoremove' "$U" || fail "shared package purge returned"
grep -Fq '20-vaultwarden-runtime.conf' "$U" || fail "uninstaller does not own the Docker runtime drop-in"
grep -Fq 'VW-CF-INGRESS' "$U" || fail "uninstaller does not own the project Docker ingress chain"

set -- run --dry-run
# shellcheck source=../../../utilities/uninstall-vaultwarden.sh
source "$U"
# These fixture globals are consumed by functions sourced from the uninstaller.
# shellcheck disable=SC2034
DRY_RUN=false FORCE=false TEST_RESET=false SAVED_RECOVERY=false

FSTAB="$T/fstab"
printf 'UUID=managed\t/mnt/vw-data\text4\tnoatime,nofail,x-systemd.device-timeout=30s\t0\t2\n' > "$FSTAB"
chmod 640 "$FSTAB"
remove_fstab /mnt/vw-data /dev/missing '' || fail "setup fstab signature rejected"
[[ ! -s "$FSTAB" && "$(stat -c %a "$FSTAB")" == 640 ]] || fail "fstab rewrite or metadata preservation failed"
remove_fstab /mnt/vw-data /dev/missing '' || fail "already-clean fstab was not idempotent"
printf 'UUID=operator\t/mnt/vw-data\text4\tdefaults,nofail\t0\t2\n' > "$FSTAB"
if remove_fstab /mnt/vw-data /dev/missing ''; then fail "mountpoint-only fstab entry removed"; fi
grep -q 'UUID=operator' "$FSTAB" || fail "operator fstab entry changed"
printf 'UUID=managed\t/mnt/other\text4\tnoatime,nofail,x-systemd.device-timeout=30s\t0\t2\n' > "$FSTAB"
if fstab_can_remove /mnt/vw-data /dev/missing managed; then fail "same UUID at another mountpoint accepted"; fi

# The installed runtime env is authoritative; a stale repo .env must not win
# merely because it contains more populated storage keys.
ROOT="$T/config-repo"; mkdir -p "$ROOT"
INSTALLED_ENV="$T/installed.env"; DEFAULT_STATE="$T/default-state"; DEFAULT_DATA="$T/default-data"
printf 'PROJECT_STATE_DIR=%s\nDATA_VOLUME_MOUNT=/mnt/vw-data\n' "$T/live-state" > "$INSTALLED_ENV"
printf 'PROJECT_STATE_DIR=/mnt/stale\nDATA_VOLUME_MOUNT=/mnt/stale\nDATA_VOLUME_DEVICE=/dev/stale\nBACKUP_DIR=/stale/backups\n' > "$ROOT/.env"
resolve
[[ "$CONFIG_SOURCE" == "$INSTALLED_ENV" && "$PROJECT_STATE_DIR" == "$T/live-state" && -z "$DATA_VOLUME_DEVICE" ]] \
  || fail "stale repo env outranked installed runtime env"

mkdir -p "$T/x"
if safe_rm "$T/x/.."; then fail "canonical broad path accepted"; fi
PROJECT_STATE_DIR="$DEFAULT_DATA"; DATA_VOLUME_MOUNT="$DEFAULT_DATA"; DATA_VOLUME_DEVICE=''
if ( preflight_storage ) >/dev/null 2>&1; then fail "partial separate-volume config accepted"; fi

# A stale project-managed Docker mount guard is also separate-volume evidence,
# even when a damaged env file lost the mount/device fields.
SYSTEMD="$T/ambiguous-systemd"; MOUNT_GUARD="$SYSTEMD/docker.service.d/10-vaultwarden-data-volume.conf"
mkdir -p "$(dirname "$MOUNT_GUARD")"
printf '# Managed by VaultWarden-OCI setup.sh\n[Unit]\nRequiresMountsFor=/mnt/old-vw-data\n' > "$MOUNT_GUARD"
PROJECT_STATE_DIR="$T/custom-state"; DATA_VOLUME_MOUNT=''; DATA_VOLUME_DEVICE=''; FSTAB="$T/no-fstab"
storage_ambiguous || fail "managed mount guard did not expose partial storage config"

# The Docker lifecycle drop-in is positively owned only when it matches the
# exact setup-systemd managed contract. Foreign content is preserved.
DOCKER_RUNTIME_DROPIN="$SYSTEMD/docker.service.d/20-vaultwarden-runtime.conf"
cat > "$DOCKER_RUNTIME_DROPIN" <<'EOF_RUNTIME_DROPIN'
# Managed by VaultWarden-OCI setup-systemd.sh — do not edit by hand.
# Caddy uses restart: on-failure, which does not auto-start on dockerd restart.
[Unit]
Wants=vaultwarden-iptables.service vaultwarden-startup.service
EOF_RUNTIME_DROPIN
docker_runtime_dropin_managed || fail "exact managed Docker runtime drop-in was not recognized"
remove_docker_runtime_dropin || fail "managed Docker runtime drop-in could not be removed"
[[ ! -e "$DOCKER_RUNTIME_DROPIN" ]] || fail "managed Docker runtime drop-in remained"
mkdir -p "$(dirname "$DOCKER_RUNTIME_DROPIN")"
printf '%s\n' '# operator-owned Docker drop-in' '[Unit]' 'Wants=example.service' > "$DOCKER_RUNTIME_DROPIN"
if docker_runtime_dropin_managed; then fail "foreign Docker runtime drop-in was classified as managed"; fi
remove_docker_runtime_dropin || fail "foreign Docker runtime drop-in preservation returned failure"
[[ -f "$DOCKER_RUNTIME_DROPIN" ]] || fail "foreign Docker runtime drop-in was removed"
rm -f "$DOCKER_RUNTIME_DROPIN"

# The uniquely named project chain and its exact DOCKER-USER jump are removed
# without touching unrelated raw iptables state.
IPT_GATE_DIR="$T/iptables-gate"; mkdir -p "$IPT_GATE_DIR"
IPT_GATE_JUMP="$IPT_GATE_DIR/jump"; IPT_GATE_CHAIN="$IPT_GATE_DIR/chain"; IPT_GATE_CALLS="$IPT_GATE_DIR/calls"
printf 'present\n' > "$IPT_GATE_JUMP"; printf 'present\n' > "$IPT_GATE_CHAIN"; : > "$IPT_GATE_CALLS"
iptables(){
  printf '%s\n' "$*" >> "$IPT_GATE_CALLS"
  case "$*" in
    '-t filter -C DOCKER-USER -j VW-CF-INGRESS') [[ -e "$IPT_GATE_JUMP" ]] ;;
    '-t filter -D DOCKER-USER -j VW-CF-INGRESS') rm -f "$IPT_GATE_JUMP" ;;
    '-t filter -S VW-CF-INGRESS') [[ -e "$IPT_GATE_CHAIN" ]] && printf '%s\n' '-N VW-CF-INGRESS' ;;
    '-t filter -F VW-CF-INGRESS') [[ -e "$IPT_GATE_CHAIN" ]] ;;
    '-t filter -X VW-CF-INGRESS') rm -f "$IPT_GATE_CHAIN" ;;
    '-t filter -S DOCKER-USER') [[ -e "$IPT_GATE_JUMP" ]] && printf '%s\n' '-A DOCKER-USER -j VW-CF-INGRESS' ;;
    *) return 1 ;;
  esac
}
remove_vaultwarden_docker_gate || fail "managed Docker ingress gate cleanup failed"
[[ ! -e "$IPT_GATE_JUMP" && ! -e "$IPT_GATE_CHAIN" ]] || fail "managed Docker ingress gate remained"
grep -Fq -- '-D DOCKER-USER -j VW-CF-INGRESS' "$IPT_GATE_CALLS" || fail "managed DOCKER-USER jump was not removed"
grep -Fq -- '-F VW-CF-INGRESS' "$IPT_GATE_CALLS" || fail "managed ingress chain was not flushed"
grep -Fq -- '-X VW-CF-INGRESS' "$IPT_GATE_CALLS" || fail "managed ingress chain was not deleted"
unset -f iptables

# A mounted custom state root is separate-volume evidence even when persisted
# device/mount fields and other wiring are missing; destructive uninstall must
# fail closed rather than treating the live mount as boot-storage data.
SYSTEMD="$T/no-managed-systemd"; MOUNT_GUARD="$SYSTEMD/docker.service.d/10-vaultwarden-data-volume.conf"
PROJECT_STATE_DIR="$T/custom-mounted-state"; DATA_VOLUME_MOUNT=''; DATA_VOLUME_DEVICE=''; FSTAB="$T/no-mounted-fstab"
mkdir -p "$PROJECT_STATE_DIR"
mountpoint(){ [[ "${1:-}" == -q && "${2:-}" == "$PROJECT_STATE_DIR" ]]; }
storage_ambiguous || fail "mounted custom state root did not expose ambiguous separate storage"
unset -f mountpoint

DEFAULT_STATE="$T/default-owned"; mkdir -p "$DEFAULT_STATE"
if state_evidence "$DEFAULT_STATE"; then fail "empty default state was accepted as recursive ownership evidence"; fi
mkdir -p "$T/strong-state/data" "$T/strong-state/logs/vaultwarden"
printf 'SQLite format 3\000' > "$T/strong-state/data/db.sqlite3"
state_evidence "$T/strong-state" || fail "strong state evidence was not recognized"

handoff_name 'vaultwarden-setup-credentials-20260807T000000Z.txt' || fail "valid credentials handoff missed"
if handoff_name 'vaultwarden-setup-credentials-operator.txt'; then fail "broad credentials handoff matched"; fi
handoff_name 'vaultwarden-recovery-kit-20260807T000000Z-abcdef.txt' || fail "valid recovery kit missed"
if handoff_name 'vaultwarden-recovery-kit-current.txt'; then fail "broad recovery kit matched"; fi

ROOT="$T/VaultWarden-OCI"
# shellcheck disable=SC2034 # consumed by sourced cleanup helpers
ETC_DIR="$T/etc-vw"
PROJECT_STATE_DIR="$T/state"
DATA_VOLUME_DEVICE=''
BACKUP_DIR="$ROOT/backups/retained"
mkdir -p "$ROOT/secrets/keys" "$BACKUP_DIR"
key="$ROOT/secrets/keys/age-key.txt"
printf 'AGE-SECRET-KEY-TEST\n' > "$key"
# shellcheck disable=SC2034 # consumed by sourced existing_keys()
AGE_KEYS=("$key")
[[ "$(existing_keys)" == "$key" ]] || fail "repo Age key escaped recovery guard"
FORCE=true; SAVED_RECOVERY=false
if ( confirm_recovery ) >/dev/null 2>&1; then fail "--force bypassed explicit recovery acknowledgement"; fi
SAVED_RECOVERY=true; confirm_recovery >/dev/null
# Reset sourced recovery globals before the remaining fixture checks.
# shellcheck disable=SC2034
FORCE=false
# shellcheck disable=SC2034
SAVED_RECOVERY=false
printf secret > "$ROOT/secrets/local"; printf old > "$ROOT/backups/old"; printf keep > "$BACKUP_DIR/keep"
cleanup_checkout_artifacts
[[ -f "$BACKUP_DIR/keep" ]] || fail "nested external backup deleted"
[[ ! -e "$ROOT/backups/old" && ! -e "$ROOT/secrets" ]] || fail "generated checkout artifacts remained"

# Project-rendered Workers config remains attributable even if env/domain files
# were already removed by a partial uninstall.
CS_WORKER="$T/crowdsec-worker.yaml"
# shellcheck disable=SC2034 # consumed by sourced worker_config_managed()
DOMAIN_NAME=''
printf '# crowdsec/crowdsec-cloudflare-worker-bouncer.yaml.example\ncloudflare_config: {}\n' > "$CS_WORKER"
worker_config_managed || fail "managed CrowdSec Workers config depended on surviving DOMAIN config"

SYSTEMD="$T/systemd"; MOUNT_GUARD="$SYSTEMD/docker.service.d/10-vaultwarden-data-volume.conf"; mkdir -p "$(dirname "$MOUNT_GUARD")"
printf '# Managed by VaultWarden-OCI setup.sh - do not edit by hand.\n[Unit]\n' > "$MOUNT_GUARD"
DATA_VOLUME_MOUNT="$UNINSTALL_MOUNT"; PROJECT_STATE_DIR="$DATA_VOLUME_MOUNT"; DATA_VOLUME_DEVICE=/dev/mock; mkdir -p "$DATA_VOLUME_MOUNT"
MOCK_UUID='11111111-2222-3333-4444-555555555555'
cat > "$DATA_VOLUME_MOUNT/.vw-data-volume" <<EOF_MARKER
SIGNATURE=VaultWarden-OCI-data-volume
FORMAT=1
FILESYSTEM_UUID=$MOCK_UUID
MOUNT_TARGET=$DATA_VOLUME_MOUNT
DEVICE_CONTEXT=/dev/mock
CREATED_AT=2026-08-10T12:00:00Z
OPERATION=setup
EOF_MARKER
chmod 444 "$DATA_VOLUME_MOUNT/.vw-data-volume"
printf keep > "$DATA_VOLUME_MOUNT/operator-note"
FSTAB="$T/fstab-mounted"; printf 'UUID=%s\t%s\text4\tnoatime,nofail,x-systemd.device-timeout=30s\t0\t2\n' "$MOCK_UUID" "$DATA_VOLUME_MOUNT" > "$FSTAB"
B="$T/bin"; mkdir -p "$B"
REAL_STAT="$(command -v stat)"
export MOCK_MOUNT="$DATA_VOLUME_MOUNT" MOCK_FLAG="$T/is-mounted" MOCK_DETACHED="$T/detached" REAL_STAT MOCK_UUID
: > "$MOCK_FLAG"
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
printf '%s\n' "$MOCK_UUID"
MOCK
cat > "$B/umount" <<'MOCK'
#!/usr/bin/env bash
rm -f "$MOCK_FLAG"; mv "$MOCK_MOUNT" "$MOCK_DETACHED"; mkdir -p "$MOCK_MOUNT"
MOCK
cat > "$B/stat" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *'.vw-data-volume'* && "${1:-}" == -c ]]; then
  case "${2:-}" in
    %u) printf '0\n'; exit 0 ;;
    %g) printf '0\n'; exit 0 ;;
    %a) printf '444\n'; exit 0 ;;
    %h) printf '1\n'; exit 0 ;;
  esac
fi
exec "$REAL_STAT" "$@"
MOCK
chmod +x "$B"/*; PATH="$B:$PATH"

# Keep the validator real while mocking only mount/device identity discovery.
_storage_identity_read_mount_facts(){ printf '/dev/mock\n%s\n%s\n' "$MOCK_UUID" "$DATA_VOLUME_MOUNT"; }
_storage_identity_device_uuid(){ printf '%s\n' "$MOCK_UUID"; }

verify_volume || fail "structured filesystem identity was not accepted for uninstall"
remove_state >/dev/null
[[ -f "$MOCK_DETACHED/operator-note" && -f "$MOCK_DETACHED/.vw-data-volume" ]] || fail "separate-volume data or identity marker deleted"
! grep -q "$DATA_VOLUME_MOUNT" "$FSTAB" || fail "managed fstab entry remained"
[[ ! -e "$MOUNT_GUARD" ]] || fail "managed mount guard remained"

# Successful operation finalization must not recreate the runtime operation state
# that uninstall deliberately removed immediately before verification.
OP_HELD=true
OPERATION_OWNS_STATE=true
OPERATION_STATE_FILE="$T/uninstall.state"
# shellcheck disable=SC2034 # consumed by sourced release_operation_lock()
OPERATION_RELEASED=false
operation_release(){ [[ "$OPERATION_OWNS_STATE" == false && -z "$OPERATION_STATE_FILE" ]]; }
finalize_op_success || fail "successful operation release would recreate runtime state"
[[ "$OP_HELD" == false ]] || fail "operation remained marked held after finalization"

# Noble host acceptance is a destructive-controller extension of uninstall/DR.
# Keep its contract coverage here so the canonical operations suite remains the
# single permanent inventory owner for teardown and same-host reset behavior.
(
  A="$ROOT_REPO/utilities/noble-host-acceptance.sh"
  AT="$T/host-acceptance"
  mkdir -p "$AT"
  bash -n "$A" || fail "host acceptance controller has invalid Bash syntax"
  [[ -x "$A" ]] || fail "host acceptance controller is not executable"

  # shellcheck source=../../../utilities/noble-host-acceptance.sh
  source "$A"

  # A real reboot is proved by boot ID. --skip-reboot is permanently
  # non-certifying rather than a shortcut to the destructive phases.
  META_FILE="$AT/reboot.meta"
  printf 'REBOOT_FROM_BOOT_ID=boot-a\n' > "$META_FILE"
  SKIP_REBOOT=false
  boot_id(){ printf 'boot-b\n'; }
  verify_reboot_transition || fail "changed boot ID was rejected"
  boot_id(){ printf 'boot-a\n'; }
  if ( verify_reboot_transition ) >/dev/null 2>&1; then fail "same boot ID was accepted as a reboot"; fi
  SKIP_REBOOT=true
  set +e
  verify_reboot_transition >/dev/null 2>&1
  reboot_rc=$?
  set -e
  [[ $reboot_rc -eq 2 ]] || fail "--skip-reboot did not return the non-certifying result"
  grep -Fq 'save_phase incomplete' "$A" || fail "non-certifying terminal phase is missing"

  # The controller must use the canonical uninstaller resolver instead of a
  # weaker environment-only attached-volume detector.
  installed_env="$AT/installed.env"
  acceptance_fstab="$AT/fstab"
  acceptance_systemd="$AT/systemd"
  mkdir -p "$acceptance_systemd"
  : > "$acceptance_fstab"
  printf 'PROJECT_STATE_DIR=%s\n' "$AT/state" > "$installed_env"
  VW_UNINSTALL_INSTALLED_ENV="$installed_env" \
  VW_UNINSTALL_FSTAB="$acceptance_fstab" \
  VW_UNINSTALL_SYSTEMD_DIR="$acceptance_systemd" \
    validate_boot_volume
  [[ "$PROJECT_STATE_PATH" == "$AT/state" ]] || fail "canonical boot-volume state path was not resolved"
  printf 'PROJECT_STATE_DIR=%s\nDATA_VOLUME_DEVICE=/dev/mock\nDATA_VOLUME_MOUNT=%s\n' "$AT/state" "$AT/state" > "$installed_env"
  if ( VW_UNINSTALL_INSTALLED_ENV="$installed_env" VW_UNINSTALL_FSTAB="$acceptance_fstab" VW_UNINSTALL_SYSTEMD_DIR="$acceptance_systemd" validate_boot_volume ) >/dev/null 2>&1; then
    fail "explicit attached volume was accepted by host acceptance"
  fi
  printf 'PROJECT_STATE_DIR=%s\n' "$AT/mounted-state" > "$installed_env"
  mkdir -p "$AT/mounted-state" "$AT/mock-bin"
  cat > "$AT/mock-bin/mountpoint" <<EOF_MOUNTPOINT
#!/usr/bin/env bash
[[ "\${1:-}" == -q && "\${2:-}" == "$AT/mounted-state" ]]
EOF_MOUNTPOINT
  chmod 0755 "$AT/mock-bin/mountpoint"
  if ( PATH="$AT/mock-bin:$PATH" VW_UNINSTALL_INSTALLED_ENV="$installed_env" VW_UNINSTALL_FSTAB="$acceptance_fstab" VW_UNINSTALL_SYSTEMD_DIR="$acceptance_systemd" validate_boot_volume ) >/dev/null 2>&1; then
    fail "ambiguously mounted project state was accepted by host acceptance"
  fi

  # Run/resume metadata binds the exact SHA, host and operator-supplied inputs.
  RECOVERY_KIT="$AT/recovery-kit"
  RCLONE_CONFIG_PATH="$AT/rclone.conf"
  APPLICATION_E2E="$AT/e2e.sh"
  RCLONE_REMOTE=acceptance
  printf 'old recovery\n' > "$RECOVERY_KIT"
  printf '[acceptance]\ntype = local\n' > "$RCLONE_CONFIG_PATH"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$APPLICATION_E2E"
  chmod 0755 "$APPLICATION_E2E"
  META_FILE="$AT/binding.meta"
  DESTRUCTIVE=false
  SKIP_REBOOT=false
  current_sha(){ printf 'sha-a\n'; }
  machine_id_hash(){ printf 'host-a\n'; }
  boot_id(){ printf 'boot-a\n'; }
  init_metadata
  verify_metadata || fail "fresh checkpoint metadata was rejected"
  printf '# drift\n' >> "$APPLICATION_E2E"
  if ( verify_metadata ) >/dev/null 2>&1; then fail "E2E hook content drift was accepted"; fi
  printf '#!/usr/bin/env bash\nexit 0\n' > "$APPLICATION_E2E"
  current_sha(){ printf 'sha-b\n'; }
  if ( verify_metadata ) >/dev/null 2>&1; then fail "Git SHA drift was accepted"; fi
  current_sha(){ printf 'sha-a\n'; }
  RCLONE_REMOTE=other
  if ( verify_metadata ) >/dev/null 2>&1; then fail "rclone remote drift was accepted"; fi

  # Destructive mode needs both the CLI flag state and the explicit environment
  # acknowledgement; this test stubs only file-trust checks, not the consent gate.
  external_file(){ printf '%s\n' "$1"; }
  validate_e2e_hook(){ :; }
  RECOVERY_KIT="$AT/recovery-kit"
  RCLONE_CONFIG_PATH="$AT/rclone.conf"
  APPLICATION_E2E="$AT/e2e.sh"
  RCLONE_REMOTE=acceptance
  DESTRUCTIVE=true
  unset VW_NOBLE_TEST_DESTRUCTIVE || true
  if ( validate_inputs ) >/dev/null 2>&1; then fail "destructive acceptance bypassed the environment acknowledgement"; fi
  VW_NOBLE_TEST_DESTRUCTIVE=YES validate_inputs >/dev/null || fail "double destructive consent was rejected"
  unset -f external_file validate_e2e_hook

  # Root-executed E2E hooks may not be writable by group/other.
  APPLICATION_E2E="$AT/e2e-trust.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$APPLICATION_E2E"
  chmod 0755 "$APPLICATION_E2E"
  real_stat="$(command -v stat)"
  stat(){
    case "$*" in
      '-c %u:%g '*) printf '0:0\n' ;;
      '-c %a '*) printf '775\n' ;;
      *) "$real_stat" "$@" ;;
    esac
  }
  if ( validate_e2e_hook ) >/dev/null 2>&1; then fail "group-writable root E2E hook was accepted"; fi
  unset -f stat

  # Uninstall success is not trusted blindly; original managed state must also
  # be absent before the controller enters restore.
  ROOT="$AT/repo"
  mkdir -p "$ROOT"
  STATE_PATH_FILE="$AT/original-state"
  printf '%s\n' "$AT/residual-state" > "$STATE_PATH_FILE"
  docker(){ return 0; }
  post_uninstall_check || fail "clean post-uninstall state was rejected"
  mkdir -p "$AT/residual-state"
  if post_uninstall_check; then fail "residual managed state was accepted"; fi
  unset -f docker

  # Restore remains manual until health/E2E and new recovery custody complete;
  # only then may timers activate and fresh rclone recovery points be created.
  manual_line="$(grep -n 'systemd-install-manual manual_systemd_install_check' "$A" | cut -d: -f1)"
  e2e_line="$(grep -n 'application-after-dr' "$A" | cut -d: -f1)"
  custody_line="$(grep -n 'validate_post_restore_recovery_kit' "$A" | tail -1 | cut -d: -f1)"
  activate_line="$(grep -n 'systemd-activate bash ./utilities/setup-systemd.sh install --enable-now' "$A" | cut -d: -f1)"
  final_backup_line="$(grep -n 'post-dr-db' "$A" | cut -d: -f1)"
  (( manual_line < e2e_line && e2e_line < custody_line && custody_line < activate_line && activate_line < final_backup_line )) \
    || fail "post-restore automation/custody/final-backup sequencing regressed"
)

echo 'case-uninstall: ok'
