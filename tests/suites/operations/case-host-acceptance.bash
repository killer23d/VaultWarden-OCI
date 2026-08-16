#!/usr/bin/env bash
# Contract checks for the destructive Noble host acceptance controller.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"
ROOT_REPO="$VW_TEST_REPO_ROOT"
A="$ROOT_REPO/utilities/noble-host-acceptance.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

bash -n "$A" || fail "host acceptance controller has invalid Bash syntax"
[[ -x "$A" ]] || fail "host acceptance controller is not executable"

# shellcheck source=../../../utilities/noble-host-acceptance.sh
source "$A"

# A real reboot is proved by boot ID. --skip-reboot is explicitly
# non-certifying rather than a shortcut to destructive phases.
META_FILE="$T/reboot.meta"
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
unset -f boot_id

# Reuse the canonical uninstaller's authoritative environment precedence and
# storage_ambiguous checks rather than a parallel environment-only detector.
AT="$T/storage"
mkdir -p "$AT/systemd"
: > "$AT/fstab"
printf 'PROJECT_STATE_DIR=%s\n' "$AT/state" > "$AT/installed.env"
VW_UNINSTALL_INSTALLED_ENV="$AT/installed.env" \
VW_UNINSTALL_FSTAB="$AT/fstab" \
VW_UNINSTALL_SYSTEMD_DIR="$AT/systemd" \
  validate_boot_volume
[[ "$PROJECT_STATE_PATH" == "$AT/state" ]] || fail "canonical boot-volume state path was not resolved"
printf 'PROJECT_STATE_DIR=%s\nDATA_VOLUME_DEVICE=/dev/mock\nDATA_VOLUME_MOUNT=%s\n' "$AT/state" "$AT/state" > "$AT/installed.env"
if ( VW_UNINSTALL_INSTALLED_ENV="$AT/installed.env" VW_UNINSTALL_FSTAB="$AT/fstab" VW_UNINSTALL_SYSTEMD_DIR="$AT/systemd" validate_boot_volume ) >/dev/null 2>&1; then
  fail "explicit attached volume was accepted"
fi
printf 'PROJECT_STATE_DIR=%s\n' "$AT/mounted-state" > "$AT/installed.env"
mkdir -p "$AT/mounted-state" "$AT/bin"
cat > "$AT/bin/mountpoint" <<EOF_MOUNTPOINT
#!/usr/bin/env bash
[[ "\${1:-}" == -q && "\${2:-}" == "$AT/mounted-state" ]]
EOF_MOUNTPOINT
chmod 0755 "$AT/bin/mountpoint"
if ( PATH="$AT/bin:$PATH" VW_UNINSTALL_INSTALLED_ENV="$AT/installed.env" VW_UNINSTALL_FSTAB="$AT/fstab" VW_UNINSTALL_SYSTEMD_DIR="$AT/systemd" validate_boot_volume ) >/dev/null 2>&1; then
  fail "ambiguously mounted project state was accepted"
fi

# Run/resume metadata binds exact code, host identity, and operator inputs.
AT="$T/binding"
mkdir -p "$AT"
RECOVERY_KIT="$AT/recovery-kit"
RCLONE_CONFIG_PATH="$AT/rclone.conf"
APPLICATION_E2E="$AT/e2e.sh"
RCLONE_REMOTE=acceptance
printf 'old recovery\n' > "$RECOVERY_KIT"
printf '[acceptance]\ntype = local\n' > "$RCLONE_CONFIG_PATH"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APPLICATION_E2E"
chmod 0755 "$APPLICATION_E2E"
META_FILE="$AT/metadata"
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
unset -f current_sha machine_id_hash boot_id

# Destructive mode requires both CLI state and the explicit environment
# acknowledgement. Stub file trust only so the consent gate remains real.
(
  external_file(){ printf '%s\n' "$1"; }
  validate_e2e_hook(){ :; }
  RECOVERY_KIT="$T/recovery-kit"
  RCLONE_CONFIG_PATH="$T/rclone.conf"
  APPLICATION_E2E="$T/e2e.sh"
  RCLONE_REMOTE=acceptance
  : > "$RECOVERY_KIT"; : > "$RCLONE_CONFIG_PATH"; : > "$APPLICATION_E2E"
  DESTRUCTIVE=true
  unset VW_NOBLE_TEST_DESTRUCTIVE || true
  if validate_inputs >/dev/null 2>&1; then fail "destructive acceptance bypassed environment acknowledgement"; fi
  VW_NOBLE_TEST_DESTRUCTIVE=YES validate_inputs >/dev/null || fail "double destructive consent was rejected"
)

# Root-executed E2E hooks may not be writable by group/other.
(
  APPLICATION_E2E="$T/e2e-trust.sh"
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
  if validate_e2e_hook >/dev/null 2>&1; then fail "group-writable root E2E hook was accepted"; fi
)

# Canonical uninstall success is not trusted blindly: the independently saved
# project-state path and Compose runtime must also be absent before restore.
(
  AT="$T/residual"
  mkdir -p "$AT/repo"
  ROOT="$AT/repo"
  STATE_PATH_FILE="$AT/original-state"
  printf '%s\n' "$AT/state" > "$STATE_PATH_FILE"
  docker(){ return 0; }
  post_uninstall_check "$AT/no-etc" "$AT/no-run" "$ROOT" acceptance \
    || fail "clean post-uninstall fixture was rejected"
  mkdir -p "$AT/state"
  if post_uninstall_check "$AT/no-etc" "$AT/no-run" "$ROOT" acceptance; then
    fail "residual managed project state was accepted"
  fi
)

# Restore stays manual until health/E2E and rotated recovery custody complete;
# only then may timers activate and fresh offsite recovery points be created.
manual_line="$(grep -n 'systemd-install-manual manual_systemd_install_check' "$A" | cut -d: -f1)"
e2e_line="$(grep -n 'application-after-dr' "$A" | cut -d: -f1)"
custody_line="$(grep -n 'validate_post_restore_recovery_kit' "$A" | tail -1 | cut -d: -f1)"
activate_line="$(grep -n 'systemd-activate bash ./utilities/setup-systemd.sh install --enable-now' "$A" | cut -d: -f1)"
final_backup_line="$(grep -n 'post-dr-db' "$A" | cut -d: -f1)"
(( manual_line < e2e_line && e2e_line < custody_line && custody_line < activate_line && activate_line < final_backup_line )) \
  || fail "post-restore automation/custody/final-backup sequencing regressed"

echo 'case-host-acceptance: ok'
