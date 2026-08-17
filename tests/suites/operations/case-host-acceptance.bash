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
(
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
)
grep -Fq 'save_phase incomplete' "$A" || fail "non-certifying terminal phase is missing"

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

# Run/resume metadata binds exact code, host identity, rclone location,
# DNS mutation scope, recovery inputs, and E2E code.
(
  AT="$T/binding"
  mkdir -p "$AT"
  RECOVERY_KIT="$AT/recovery-kit"
  RCLONE_CONFIG_PATH="$AT/rclone.conf"
  APPLICATION_E2E="$AT/e2e.sh"
  # shellcheck disable=SC2034 # consumed by sourced acceptance helpers
  RCLONE_REMOTE=acceptance
  # shellcheck disable=SC2034 # consumed by sourced acceptance helpers
  RCLONE_REMOTE_PATH=vaultwarden_acceptance
  # shellcheck disable=SC2034 # consumed by sourced acceptance helpers
  DNS_MUTATION_DOMAIN=vw-acceptance.example.com
  # shellcheck disable=SC2034 # consumed by sourced acceptance helpers
  ALLOW_DNS_MUTATION=true
  printf 'old recovery\n' > "$RECOVERY_KIT"
  printf '[acceptance]\ntype = local\n' > "$RCLONE_CONFIG_PATH"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$APPLICATION_E2E"
  chmod 0755 "$APPLICATION_E2E"
  META_FILE="$AT/metadata"
  DESTRUCTIVE=false
  # shellcheck disable=SC2034 # consumed by sourced acceptance metadata helpers
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
  # shellcheck disable=SC2034 # consumed by sourced acceptance helpers
  RCLONE_REMOTE=acceptance
  RCLONE_REMOTE_PATH=other-path
  if ( verify_metadata ) >/dev/null 2>&1; then fail "rclone path drift was accepted"; fi
  # shellcheck disable=SC2034 # consumed by sourced acceptance helpers
  RCLONE_REMOTE_PATH=vaultwarden_acceptance
  DNS_MUTATION_DOMAIN=other.example.com
  if ( verify_metadata ) >/dev/null 2>&1; then fail "DNS mutation scope drift was accepted"; fi
)

# Destructive mode and DNS mutation both require explicit two-part consent.
(
  external_file(){ printf '%s\n' "$1"; }
  validate_e2e_hook(){ :; }
  RECOVERY_KIT="$T/recovery-kit"
  RCLONE_CONFIG_PATH="$T/rclone.conf"
  APPLICATION_E2E="$T/e2e.sh"
  # shellcheck disable=SC2034 # consumed by sourced acceptance helpers
  RCLONE_REMOTE=acceptance
  # shellcheck disable=SC2034 # consumed by sourced acceptance helpers
  RCLONE_REMOTE_PATH=vaultwarden_acceptance
  # shellcheck disable=SC2034 # consumed by sourced acceptance helpers
  DNS_MUTATION_DOMAIN=vw-acceptance.example.com
  # shellcheck disable=SC2034 # consumed by sourced acceptance helpers
  ALLOW_DNS_MUTATION=true
  : > "$RECOVERY_KIT"; : > "$RCLONE_CONFIG_PATH"; : > "$APPLICATION_E2E"
  # shellcheck disable=SC2034 # consumed by sourced acceptance helpers
  DESTRUCTIVE=true
  # shellcheck disable=SC2034 # consumed by sourced acceptance helpers
  VW_NOBLE_TEST_DNS_MUTATION=YES
  unset VW_NOBLE_TEST_DESTRUCTIVE || true
  if ( validate_inputs ) >/dev/null 2>&1; then fail "destructive acceptance bypassed environment acknowledgement"; fi
  VW_NOBLE_TEST_DESTRUCTIVE=YES validate_inputs >/dev/null || fail "double destructive consent was rejected"
  unset VW_NOBLE_TEST_DNS_MUTATION
  if ( VW_NOBLE_TEST_DESTRUCTIVE=YES validate_inputs ) >/dev/null 2>&1; then fail "DNS mutation bypassed environment acknowledgement"; fi
)

# The external DNS mutation gate requires both consent and an exact runtime
# DOMAIN match, so a production hostname cannot be mutated accidentally by
# merely running the foreground systemd-job phase.
(
  # shellcheck disable=SC2034 # consumed by sourced acceptance helpers
  DNS_MUTATION_DOMAIN=vw-acceptance.example.com
  # shellcheck disable=SC2034 # consumed by sourced acceptance helpers
  ALLOW_DNS_MUTATION=true
  runtime_config_value(){ printf 'vw-acceptance.example.com\n'; }
  unset VW_NOBLE_TEST_DNS_MUTATION || true
  if ( validate_dns_mutation_scope ) >/dev/null 2>&1; then fail "DNS mutation ran without environment consent"; fi
  VW_NOBLE_TEST_DNS_MUTATION=YES validate_dns_mutation_scope >/dev/null \
    || fail "matching dedicated DNS mutation scope was rejected"
  runtime_config_value(){ printf 'vault.example.com\n'; }
  if ( VW_NOBLE_TEST_DNS_MUTATION=YES validate_dns_mutation_scope ) >/dev/null 2>&1; then
    fail "mismatched runtime DOMAIN was accepted for DNS mutation"
  fi
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
  if ( validate_e2e_hook ) >/dev/null 2>&1; then fail "group-writable root E2E hook was accepted"; fi
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

# Rotated recovery custody is tied to the active operational Age recipient,
# not merely to a different whole-file digest.
(
  AT="$T/age-binding"
  mkdir -p "$AT/state"
  # shellcheck disable=SC2034 # consumed by sourced recovery helpers
  STATE_ROOT="$AT/state"
  age-keygen -o "$AT/old.key" >/dev/null 2>&1
  age-keygen -o "$AT/new.key" >/dev/null 2>&1
  age-keygen -o "$AT/other.key" >/dev/null 2>&1
  cat "$AT/old.key" > "$AT/old.kit"; printf 'END OF RECOVERY KIT\n' >> "$AT/old.kit"
  cat "$AT/new.key" > "$AT/new.kit"; printf 'END OF RECOVERY KIT\n' >> "$AT/new.kit"
  cat "$AT/other.key" > "$AT/other.kit"; printf 'END OF RECOVERY KIT\n' >> "$AT/other.kit"
  RECOVERY_KIT="$AT/old.kit"
  validate_recovery_recipient_binding "$AT/new.kit" "$AT/new.key" \
    || fail "matching rotated recovery identity was rejected"
  if ( validate_recovery_recipient_binding "$AT/other.kit" "$AT/new.key" ) >/dev/null 2>&1; then
    fail "unrelated valid recovery identity was accepted"
  fi
  cp "$AT/old.kit" "$AT/modified-old.kit"
  printf '# digest-only change\n' >> "$AT/modified-old.kit"
  if ( validate_recovery_recipient_binding "$AT/modified-old.kit" "$AT/old.key" ) >/dev/null 2>&1; then
    fail "modified copy of the old Age identity was accepted as rotated custody"
  fi

  old_recipient="$(age-keygen -y "$AT/old.key")"
  new_recipient="$(age-keygen -y "$AT/new.key")"
  printf 'bound DR source payload\n' | age -r "$old_recipient" -o "$AT/dr-source-full.age"
  printf 'bound post-DR payload\n' | age -r "$new_recipient" -o "$AT/post-dr-full.age"
  META_FILE="$AT/metadata"
  : > "$META_FILE"
  meta_add DR_SOURCE_BACKUP_BASENAME full_backup_source_fixture.tar.zst.age
  meta_add DR_SOURCE_BACKUP_ARCHIVE_SHA256 "$(sha_file "$AT/dr-source-full.age")"
  meta_add DR_SOURCE_BACKUP_COHORT_SHA256 "$(printf '0%.0s' {1..64})"
  meta_add POST_DR_BACKUP_BASENAME full_backup_fixture.tar.zst.age
  meta_add POST_DR_BACKUP_ARCHIVE_SHA256 "$(sha_file "$AT/post-dr-full.age")"
  meta_add POST_DR_BACKUP_COHORT_SHA256 "$(printf '0%.0s' {1..64})"
  download_bound_backup(){
    case "$1" in
      DR_SOURCE)
        # shellcheck disable=SC2034 # consumed by sourced verify_bound_backup_with_kit()
        BOUND_BACKUP_FILE="$AT/dr-source-full.age"
        ;;
      POST_DR)
        # shellcheck disable=SC2034 # consumed by sourced verify_bound_backup_with_kit()
        BOUND_BACKUP_FILE="$AT/post-dr-full.age"
        ;;
      *) return 1 ;;
    esac
  }
  verify_bound_backup_with_kit DR_SOURCE "$AT/old.kit" \
    || fail "pre-DR recovery kit could not decrypt the bound DR source backup"
  if ( verify_bound_backup_with_kit DR_SOURCE "$AT/other.kit" ) >/dev/null 2>&1; then
    fail "unrelated pre-DR recovery kit decrypted the bound DR source backup"
  fi
  verify_bound_backup_with_kit POST_DR "$AT/new.kit" \
    || fail "copied rotated recovery kit could not decrypt bound post-DR backup"
)

# Canary creation must precede the specifically bound full backup. Restore
# must download that exact cohort and use --file, never remote 'latest'.
canary_line="$(grep -n 'application-before-dr' "$A" | cut -d: -f1)"
source_backup_line="$(grep -n 'dr-full-backup run_and_bind_full_backup DR_SOURCE' "$A" | cut -d: -f1)"
source_kit_decrypt_line="$(grep -n 'pre-dr-recovery-kit-decrypt verify_bound_backup_with_kit DR_SOURCE' "$A" | cut -d: -f1)"
source_download_line="$(grep -n 'dr-source-download download_bound_backup DR_SOURCE restore-source' "$A" | cut -d: -f1)"
exact_restore_line="$(grep -n 'bash ./restore.sh interactive --file \"\$BOUND_BACKUP_FILE\"' "$A" | cut -d: -f1)"
restore_checkpoint_line="$(grep -n 'save_phase post-restore-validation' "$A" | cut -d: -f1)"
repair_line="$(grep -n 'repair-permissions bash ./utilities/repair-permissions.sh' "$A" | cut -d: -f1)"
e2e_line="$(grep -n 'application-after-dr' "$A" | cut -d: -f1)"
custody_line="$(grep -n 'validate_post_restore_recovery_kit' "$A" | tail -1 | cut -d: -f1)"
activate_line="$(grep -n 'systemd-activate bash ./utilities/setup-systemd.sh install --enable-now' "$A" | cut -d: -f1)"
final_backup_line="$(grep -n 'post-dr-full run_and_bind_full_backup POST_DR' "$A" | cut -d: -f1)"
final_decrypt_line="$(grep -n 'post-dr-recovery-kit-decrypt verify_bound_backup_with_kit POST_DR' "$A" | cut -d: -f1)"
(( canary_line < source_backup_line && source_backup_line < source_kit_decrypt_line \
   && source_kit_decrypt_line < source_download_line && source_download_line < exact_restore_line )) \
  || fail "canary/bound-backup/pre-DR-kit-proof/exact-restore sequencing regressed"
(( exact_restore_line < restore_checkpoint_line && restore_checkpoint_line < repair_line && repair_line < e2e_line )) \
  || fail "successful restore is not checkpointed before post-restore validation"
(( e2e_line < custody_line && custody_line < activate_line && activate_line < final_backup_line && final_backup_line < final_decrypt_line )) \
  || fail "post-restore custody/automation/final-backup sequencing regressed"
! grep -Fq 'restore.sh latest full --remote' "$A" || fail "controller still restores an unbound remote latest backup"
grep -Fq 'POST_RESTORE_AGE_RECIPIENT_HASH' "$A" || fail "rotated Age recipient is not checkpointed"
grep -Fq 'dns-mutation-scope-after-restore validate_dns_mutation_scope' "$A" \
  || fail "post-restore timer activation is not protected by the DNS mutation gate"

echo 'case-host-acceptance: ok'
