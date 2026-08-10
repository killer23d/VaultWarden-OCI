#!/usr/bin/env bash
# Consolidated backup regression suite.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_backup_architecture_policy() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
BACKUP="$ROOT/utilities/backup-run.sh"
RESTORE="$ROOT/utilities/restore-run.sh"
SETUP="$ROOT/utilities/setup-system.sh"
fail(){ echo "FAIL: $*" >&2; exit 1; }
require(){ local pat="$1" file="$2" msg="$3"; grep -Eq -- "$pat" "$file" || fail "$msg"; }
reject(){ local pat="$1" file="$2" msg="$3"; ! grep -Eq -- "$pat" "$file" || fail "$msg"; }

require 'local basic_packages=\(.*"zstd".*\)' "$SETUP" 'normal setup must install zstd'
require '^[[:space:]]*\[zstd\]=zstd$' "$SETUP" 'normal setup must map zstd package to zstd command'
require 'local required_commands=\(.*"zstd".*\)' "$SETUP" 'final setup dependency verification must require zstd'
require 'create_consistent_db_snapshot\(\)' "$BACKUP" 'shared DB snapshot helper missing'
require 'perform_db_backup\(\)' "$BACKUP" 'db backup function missing'
require 'create_consistent_db_snapshot "\$state_dir" "\$snap" "db backup"' "$BACKUP" 'db backup must use shared helper'
require 'DB_SNAPSHOT_METHOD="sqlite-online-backup"' "$BACKUP" 'online snapshot method metadata value missing'
require 'DB_SNAPSHOT_METHOD="offline-checkpoint-copy"' "$BACKUP" 'offline snapshot method metadata value missing'
reject 'will use live DB file in archive|falling back to live DB' "$BACKUP" 'full backup must not fall back to raw live DB archival'
require '"\$\{state_member\}/data/db\.sqlite3"' "$BACKUP" 'full/emergency exclusion owner must exclude raw live DB'
require '"\$\{state_member\}/data/db\.sqlite3-wal"' "$BACKUP" 'full/emergency exclusion owner must exclude WAL'
require '"\$\{state_member\}/data/db\.sqlite3-shm"' "$BACKUP" 'full/emergency exclusion owner must exclude SHM'
require 'local db_archive_member="\$\{state_dir#/\}/data/db\.sqlite3"' "$BACKUP" 'full/emergency must target staged DB at live archive path'
require '--transform=s#\^\$\{snap_payload_regex\}\\\$#\$\{db_archive_member\}#' "$BACKUP" 'full/emergency must transform staged DB to live archive path'
require '-C "\$snap_payload_dir"' "$BACKUP" 'full/emergency must inject DB from staged snapshot payload directory'
require '"\$snap_payload_name"' "$BACKUP" 'full/emergency must inject staged DB snapshot payload'
require 'SECRETS_FILE|secrets/secrets.yaml|state directory' "$BACKUP" 'backup script should preserve encrypted SOPS secrets through state archive'
require '"\$\{project_member\}/secrets/keys/age-key\.txt"' "$BACKUP" 'full backup exclusion owner must exclude project Age private key'
require 'install -m 600 "\$etc_file" "\$snap_dir/etc/vaultwarden/\$\(basename "\$etc_file"\)"' "$BACKUP" 'emergency must stage /etc/vaultwarden files'
require '"run/vaultwarden-oci/secrets/\*"' "$BACKUP" 'runtime /run secrets must be excluded'
require 'requires either a TTY passphrase prompt or EMERGENCY_BACKUP_AGE_RECIPIENT' "$BACKUP" 'emergency noninteractive refusal missing'
require 'Emergency backup includes key material and cannot be encrypted only to the operational Age recipient' "$BACKUP" 'emergency must reject same operational key recipient'
require 'emergency_contains_key_material=%s' "$BACKUP" 'metadata key-material policy missing'
require 'encryption_mode=%s' "$BACKUP" 'metadata encryption mode missing'
require 'db_snapshot_method=%s' "$BACKUP" 'metadata db snapshot method missing'
require 'grep -Fxc "\$expected_db"' "$BACKUP" 'archive validation must require exactly one live DB path'
require 'ignored pre-restore snapshot DBs' "$BACKUP" 'archive validation must ignore pre-restore DBs'
require 'install -o root -g root -m 600.*etc/vaultwarden' "$RESTORE" 'restore must install emergency /etc/vaultwarden files with mode 0600'
require 'EMERGENCY_BACKUP_AGE_RECIPIENT' "$ROOT/.env.example" 'config example must document emergency DR recipient'
for doc in docs/BACKUP-RESTORE.md docs/DISASTER-RECOVERY.md README.md; do
  require 'db`.*database|database rollback' "$ROOT/$doc" "$doc must document db tier"
  require 'emergency`.*clone|clone-grade' "$ROOT/$doc" "$doc must document emergency tier"
done
for doc in docs/BACKUP-RESTORE.md docs/DISASTER-RECOVERY.md README.md; do
  require 'full`.*(private (key|identity)|recipient)|full backup.*private identity' "$ROOT/$doc" "$doc must document full tier decryption identity"
done
for doc in docs/BACKUP-RESTORE.md README.md; do
  require 'Emergency backups are clone-grade secrets-bearing artifacts' "$ROOT/$doc" "$doc must warn about emergency artifacts"
done

)

check_backup_architecture_policy
check_backup_preflight_and_metadata_safety() (
# shellcheck disable=SC2016
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
RESTORE="$ROOT/utilities/restore-run.sh"
BACKUP="$ROOT/utilities/backup-run.sh"
UTILS="$ROOT/lib/backup-utils.sh"
fail(){ echo "not ok - $*" >&2; exit 1; }
pass(){ echo "ok - $*"; }
require(){ local pat="$1" file="$2" msg="$3"; grep -Eq -- "$pat" "$file" || fail "$msg"; }
reject(){ local pat="$1" file="$2" msg="$3"; ! grep -Eq -- "$pat" "$file" || fail "$msg"; }
require '"\$\{state_member\}/\.pre-restore-\*"' "$BACKUP" 'state-dir pre-restore snapshots must be explicitly excluded'
require '_validate_full_archive_payload' "$BACKUP" 'post-tar validation helper must exist'
require 'project_state_dir=' "$BACKUP" 'full metadata must include project_state_dir'
require 'storage_mode=' "$BACKUP" 'full metadata must include storage_mode'
require 'awk -F=.*\^\[A-Za-z_\]' "$UTILS" 'metadata writer must keep valid key=value lines only'
reject '^[[:space:]]*\$additional_info$' "$UTILS" 'metadata writer must not heredoc additional_info with leading whitespace'

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Backup tar validation functional checks.
BH="$TMP/backup-harness.sh"
cat > "$BH" <<'BH'
set -euo pipefail
log_error(){ echo "$*" >&2; }; backup_log_warn(){ :; }
BH
sed -n '/^_validate_full_archive_payload()/,/^create_db_snapshot_host()/p' "$BACKUP" | sed '$d' >> "$BH"
state="$TMP/state"; mkdir -p "$state/data"; : > "$state/data/db.sqlite3"
badroot="$TMP/badroot"; mkdir -p "$badroot/${state#/}/.pre-restore-x/data"; : > "$badroot/${state#/}/.pre-restore-x/data/db.sqlite3"; (cd "$badroot" && tar --use-compress-program='zstd --no-progress -T0 -3' -cf "$TMP/bad.tar.zst" .)
if bash -c "source '$BH'; _validate_full_archive_payload '$TMP/bad.tar.zst' '$state' '$ROOT' full" >/dev/null 2>&1; then fail 'snapshot-only DB must not satisfy backup validation'; fi
forbiddenroot="$TMP/forbiddenroot"; mkdir -p "$forbiddenroot/${state#/}/data" "$forbiddenroot/${ROOT#/}"; : > "$forbiddenroot/${state#/}/data/db.sqlite3"; printf secret > "$forbiddenroot/${ROOT#/}/vaultwarden-recovery-kit-test.txt"; (cd "$forbiddenroot" && tar --use-compress-program='zstd --no-progress -T0 -3' -cf "$TMP/forbidden.tar.zst" .)
if bash -c "source '$BH'; _validate_full_archive_payload '$TMP/forbidden.tar.zst' '$state' '$ROOT' full" >/dev/null 2>&1; then fail 'full archive accepted a recovery artifact'; fi
goodroot="$TMP/goodroot"; mkdir -p "$goodroot/${state#/}/data"; : > "$goodroot/${state#/}/data/db.sqlite3"; mkdir -p "$goodroot/${ROOT#/}"; (cd "$goodroot" && tar --use-compress-program='zstd --no-progress -T0 -3' -cf "$TMP/good.tar.zst" .)
bash -c "source '$BH'; _validate_full_archive_payload '$TMP/good.tar.zst' '$state' '$ROOT' full" || fail 'live DB archive should pass backup validation'

# Metadata generation: create a sidecar and assert no malformed lines.
MH="$TMP/meta-harness.sh"
cat > "$MH" <<'MH'
set -euo pipefail
log_error(){ echo "$*" >&2; }; log_warn(){ :; }; log_debug(){ :; }
_stat_file_size(){ stat -c %s "$1"; }; calculate_sha256(){ sha256sum "$1" | awk '{print $1}'; }; require_docker(){ return 1; }
MH
sed -n '/^create_backup_metadata()/,/^_repair_sudo_user_rclone_config_permissions()/p' "$UTILS" | sed '$d' >> "$MH"
: > "$TMP/backup.age"
bash -c "source '$MH'; create_backup_metadata '$TMP/backup.age' full 'project_state_dir=/mnt/vw-data
storage_mode=block
data_volume_mount=/mnt/vw-data
data_volume_device=/dev/sdb
state_dir_is_mountpoint=true
repo_root=$ROOT
archive_format=relative
version=2
barebadline'"
awk 'NF && $0 !~ /^#/ && $0 !~ /^[A-Za-z_][A-Za-z0-9_]*=/ { bad=1 } END { exit bad }' "$TMP/backup.age.meta" || fail 'metadata contains malformed non key=value lines'
grep -q '^project_state_dir=' "$TMP/backup.age.meta" || fail 'metadata missing project_state_dir without leading whitespace'

bash -n "$RESTORE" "$BACKUP" "$UTILS"
pass 'restore/backup preflight safety functional checks'

)

check_backup_preflight_and_metadata_safety
check_backup_completion_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
BACKUP="$ROOT/utilities/backup-run.sh"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Backup owns completion ordering, verification-failure discard, retention gates,
# and internal summary state transitions. Operator UI tests only own displayed text.
grep -Fq '_print_backup_run_summary "$actual_type" "$backup_file" "$verification_status" "$offsite_status"' "$BACKUP" \
    || fail "backup final summary call missing"
grep -Fq '[[ "$QUIET" == "true" ]] && return 0' "$BACKUP" \
    || fail "backup summary is not quiet-aware"

verify_failure_block="$(awk '/if ! verify_backup_quick/,/exit 1/' "$BACKUP")"
grep -Fq 'if [[ "$RCLONE_SYNC" == "true" ]]; then' <<< "$verify_failure_block" \
    || fail "backup verification failure should not change offsite status when rclone was not requested"
grep -Fq 'offsite_status="skipped because verification failed"' <<< "$verify_failure_block" \
    || fail "backup verification failure missing rclone-specific offsite skip state"
grep -Fq '_discard_backup_cohort "$candidate_file"' <<< "$verify_failure_block" \
    || fail "backup verification failure does not discard the hidden candidate cohort"
grep -Fq '_print_backup_run_summary "$actual_type" "$candidate_file" "$verification_status" "$offsite_status"' <<< "$verify_failure_block" \
    || fail "backup verification failure summary does not report the unpublished candidate"
grep -Fq '"$(basename "${candidate_file:-unknown}")"' <<< "$verify_failure_block" \
    || fail "backup verification failure email does not report the unpublished candidate"
grep -Fq 'log_error "  $candidate_file"' <<< "$verify_failure_block" \
    || fail "backup verification failure discard log does not report the unpublished candidate"
grep -Fq 'backup_log_info "DB backup candidate ready: $(basename "$candidate_path")"' "$BACKUP" \
    || fail "DB candidate-ready log does not report the actual hidden candidate"
grep -Fq 'backup_log_info "${backup_label_title} backup candidate ready: $(basename "$candidate_path")"' "$BACKUP" \
    || fail "full/emergency candidate-ready log does not report the actual hidden candidate"
! grep -Fq 'backup candidate ready: $(basename "$final_archive")' "$BACKUP" \
    || fail "candidate-ready logging incorrectly reports an unpublished final name"
! grep -Fq '_print_backup_run_summary "$actual_type" "$backup_file"' <<< "$verify_failure_block" \
    || fail "backup verification failure summary incorrectly reports the unpublished final path"
! grep -Fq 'log_error "  $backup_file"' <<< "$verify_failure_block" \
    || fail "backup verification failure discard log incorrectly reports the unpublished final path"
grep -Fq 'exit 1' <<< "$verify_failure_block" \
    || fail "backup quick-verification failure must exit non-zero before retention"
! grep -Fq 'cleanup_old_backups' <<< "$verify_failure_block" \
    || fail "backup quick-verification failure must not run local retention before exit"

quick_fail_line="$(grep -n 'Backup failed: quick verification did not complete successfully.' "$BACKUP" | cut -d: -f1 | head -1)"
retention_line="$(grep -n 'cleanup_old_backups "$backup_dir"' "$BACKUP" | cut -d: -f1 | head -1)"
success_line="$(grep -n 'backup_log_success "Backup completed successfully"' "$BACKUP" | cut -d: -f1 | head -1)"
[[ -n "$quick_fail_line" && -n "$retention_line" && -n "$success_line" ]] \
    || fail "backup verification ordering markers missing"
(( quick_fail_line < retention_line )) \
    || fail "quick verification failure must be handled before retention"
(( quick_fail_line < success_line )) \
    || fail "quick verification failure must be handled before success line"

printf 'PASS: backup completion ordering and discard contracts\n'
)

check_backup_completion_contracts
check_emergency_offsite_metadata_contract() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
BACKUP="$ROOT/utilities/backup-run.sh"
UTILS="$ROOT/lib/backup-utils.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

_extract_func(){
  local file="$1" func="$2"
  awk -v f="$func" '
    $0 ~ "^" f "\\(\\)" {p=1}
    p {
      print
      opens=gsub(/\{/,"{"); closes=gsub(/\}/,"}")
      depth += opens - closes
      if (depth == 0) exit
    }' "$file"
}

cat > "$TMP/sync-probe.sh" <<EOF_PROBE
set -uo pipefail
CONTROL_WORKSPACE="$TMP/work"
mkdir -p "\$CONTROL_WORKSPACE"
FAIL_SUFFIX="\${FAIL_SUFFIX:-}"
META_CASE="\${META_CASE:-age-passphrase}"
backup_log_info(){ printf 'INFO %s\\n' "\$*"; }
log_warn(){ printf 'WARN %s\\n' "\$*"; }
log_error(){ printf 'ERROR %s\\n' "\$*"; }
get_config_value(){
  case "\$1" in
    RCLONE_REMOTE_NAME) printf '%s\\n' mockremote ;;
    RCLONE_REMOTE_PATH) printf '%s\\n' vaultwarden_backups ;;
    *) printf '%s\\n' "\${2:-}" ;;
  esac
}
_resolve_rclone_config_arg(){ local -n _out="\$1"; _out=(--config "$TMP/mock-rclone.conf"); }
age(){ : > "$TMP/age.called"; return 0; }
rclone(){
  local cmd="\$1"; shift
  case "\$cmd" in
    lsd) return 0 ;;
    copy)
      if [[ "\${1:-}" == --config ]]; then shift 2; fi
      local src="\$1"
      printf '%s\\n' "\$src" >> "$TMP/rclone-copy.calls"
      if [[ -n "\$FAIL_SUFFIX" && "\$src" == *"\$FAIL_SUFFIX" ]]; then return 9; fi
      return 0
      ;;
    size) printf 'Total size: 1234 Bytes (1.205 KiB)\\n'; return 0 ;;
    *) return 0 ;;
  esac
}
$(_extract_func "$UTILS" backup_required_cohort_suffixes)
$(_extract_func "$BACKUP" _validate_emergency_restore_metadata)
$(_extract_func "$BACKUP" _verify_remote_cohort_member)
$(_extract_func "$BACKUP" sync_to_rclone)
archive="$TMP/emergency.tar.zst.age"
printf archive > "\$archive"
case "\$META_CASE" in
  zero) : > "\${archive}.meta" ;;
  missing-mode) printf 'version=2\\n' > "\${archive}.meta" ;;
  unsupported) printf 'encryption_mode=future-mode\\n' > "\${archive}.meta" ;;
  duplicate) printf 'encryption_mode=age-passphrase\\nencryption_mode=age-recipient\\n' > "\${archive}.meta" ;;
  age-passphrase|age-recipient) printf 'encryption_mode=%s\\n' "\$META_CASE" > "\${archive}.meta" ;;
  *) exit 90 ;;
esac
printf checksum > "\${archive}.sha256"
rc=0
sync_to_rclone "\$archive" emergency || rc=\$?
printf 'RC=%s\\n' "\$rc"
exit 0
EOF_PROBE

: > "$TMP/rclone-copy.calls"
FAIL_SUFFIX=.meta bash "$TMP/sync-probe.sh" >"$TMP/meta-fail.out" 2>&1 || fail 'emergency metadata upload probe crashed'
grep -q '^RC=3$' "$TMP/meta-fail.out" || { cat "$TMP/meta-fail.out" >&2; fail 'emergency .meta upload failure must return distinct status 3'; }
grep -qi 'emergency offsite delivery is incomplete\|remote emergency recovery point is incomplete' "$TMP/meta-fail.out" \
  || fail 'emergency .meta upload failure must report incomplete recovery delivery'
! grep -q 'The primary backup archive was delivered' "$TMP/meta-fail.out" \
  || fail 'emergency .meta upload failure must not claim the primary is a complete delivered recovery point'

: > "$TMP/rclone-copy.calls"
FAIL_SUFFIX=.sha256 bash "$TMP/sync-probe.sh" >"$TMP/sha-fail.out" 2>&1 || fail 'checksum sidecar upload probe crashed'
grep -q '^RC=1$' "$TMP/sha-fail.out" || { cat "$TMP/sha-fail.out" >&2; fail '.sha256 upload failure must make offsite delivery incomplete'; }
! grep -q 'Offsite sync complete' "$TMP/sha-fail.out" \
  || fail '.sha256 upload failure must not report a complete remote recovery point'

for meta_case in zero missing-mode unsupported duplicate; do
  : > "$TMP/rclone-copy.calls"
  rm -f "$TMP/age.called"
  META_CASE="$meta_case" bash "$TMP/sync-probe.sh" >"$TMP/$meta_case.out" 2>&1 \
    || fail "emergency metadata $meta_case probe crashed"
  grep -q '^RC=3$' "$TMP/$meta_case.out" \
    || { cat "$TMP/$meta_case.out" >&2; fail "emergency metadata $meta_case must return distinct status 3"; }
  ! grep -q 'Offsite sync complete' "$TMP/$meta_case.out" \
    || fail "emergency metadata $meta_case printed complete offsite wording"
  ! grep -q 'The primary backup archive was delivered' "$TMP/$meta_case.out" \
    || fail "emergency metadata $meta_case claimed the remote primary was delivered as a complete recovery point"
  grep -qi 'restore-critical metadata is missing, unusable, or not delivered' "$TMP/$meta_case.out" \
    || fail "emergency metadata $meta_case did not explain unusable restore-critical metadata"
  [[ ! -e "$TMP/age.called" ]] || fail "emergency metadata $meta_case triggered an Age trial-decrypt fallback"
done
grep -qi 'metadata is empty' "$TMP/zero.out" || fail 'zero-byte emergency .meta was not identified as empty'
grep -qi 'missing encryption_mode' "$TMP/missing-mode.out" || fail 'missing emergency encryption_mode was not reported'
grep -qi "unsupported encryption_mode 'future-mode'" "$TMP/unsupported.out" || fail 'unsupported emergency encryption_mode was not reported truthfully'
grep -qi 'multiple encryption_mode entries' "$TMP/duplicate.out" || fail 'duplicate emergency encryption_mode entries were not rejected as ambiguous'

for meta_case in age-passphrase age-recipient; do
  : > "$TMP/rclone-copy.calls"
  META_CASE="$meta_case" bash "$TMP/sync-probe.sh" >"$TMP/$meta_case.out" 2>&1 \
    || fail "supported emergency metadata $meta_case probe crashed"
  grep -q '^RC=0$' "$TMP/$meta_case.out" || fail "supported emergency mode $meta_case did not continue through normal sync"
  grep -q 'Offsite sync complete' "$TMP/$meta_case.out" || fail "supported emergency mode $meta_case did not reach normal sync completion"
  grep -Fq "$TMP/emergency.tar.zst.age.meta" "$TMP/rclone-copy.calls" || fail "supported emergency mode $meta_case did not upload metadata"
done

cat > "$TMP/verify-metadata-probe.sh" <<EOF_PROBE
set -uo pipefail
REQUIRE_AUTHENTICATED_INTEGRITY=false
EMERGENCY_BACKUP_AGE_IDENTITY_FILE=""
backup_log_info(){ printf 'INFO %s\\n' "\$*"; }
backup_log_warn(){ printf 'WARN %s\\n' "\$*"; }
log_error(){ printf 'ERROR %s\\n' "\$*"; }
verify_file_integrity(){ return 0; }
verify_sqlite(){ return 0; }
_resolve_age_key(){ printf '%s\\n' "$TMP/key.txt"; }
get_config_value(){ printf '%s\\n' "\${2:-}"; }
age(){ printf '%s\\n' "\$*" >> "$TMP/verify-age.calls"; return 0; }
$(_extract_func "$BACKUP" _validate_emergency_restore_metadata)
$(_extract_func "$BACKUP" verify_backup_full)
$(_extract_func "$BACKUP" verify_backup_quick)
archive="$TMP/verify-emergency.age"
printf archive > "\$archive"
printf checksum > "\${archive}.sha256"
case "\${VERIFY_META_CASE:-missing-mode}" in
  missing-mode) printf 'version=2\\n' > "\${archive}.meta" ;;
  unsupported) printf 'encryption_mode=future-mode\\n' > "\${archive}.meta" ;;
  *) exit 91 ;;
esac
quick_rc=0
verify_backup_quick "\$archive" "$TMP/key.txt" emergency || quick_rc=\$?
full_rc=0
verify_backup_full "\$archive" emergency "$TMP" || full_rc=\$?
printf 'QUICK_RC=%s\\nFULL_RC=%s\\n' "\$quick_rc" "\$full_rc"
EOF_PROBE
for verify_case in missing-mode unsupported; do
  : > "$TMP/verify-age.calls"
  VERIFY_META_CASE="$verify_case" bash "$TMP/verify-metadata-probe.sh" >"$TMP/verify-$verify_case.out" 2>&1 \
    || fail "emergency verification metadata $verify_case probe crashed"
  grep -q '^QUICK_RC=1$' "$TMP/verify-$verify_case.out" || fail "quick verification accepted emergency metadata $verify_case"
  grep -q '^FULL_RC=1$' "$TMP/verify-$verify_case.out" || fail "full verification accepted emergency metadata $verify_case"
  [[ ! -s "$TMP/verify-age.calls" ]] || fail "emergency verification $verify_case trial-decrypted after unusable metadata"
done

cat > "$TMP/batch-sync-probe.sh" <<EOF_PROBE
set -uo pipefail
BASE_DIR="$TMP/retained"
DRY_RUN=false
KEEP_DAYS=""
BATCH_META_CASE="\${BATCH_META_CASE:-zero}"
COPY_LOG="$TMP/batch-copy.calls"
rm -rf "\$BASE_DIR"
mkdir -p "\$BASE_DIR/emergency"
archive="\$BASE_DIR/emergency/emergency-retained-20260710-120000.tar.zst.age"
printf archive > "\$archive"
printf checksum > "\${archive}.sha256"
case "\$BATCH_META_CASE" in
  zero) : > "\${archive}.meta" ;;
  valid) printf 'encryption_mode=age-recipient\\n' > "\${archive}.meta" ;;
  *) exit 92 ;;
esac
backup_log_info(){ printf 'INFO %s\\n' "\$*"; }
backup_log_success(){ printf 'SUCCESS %s\\n' "\$*"; }
log_error(){ printf 'ERROR %s\\n' "\$*"; }
get_config_value(){
  case "\$1" in
    RCLONE_REMOTE_NAME) printf '%s\\n' mockremote ;;
    RCLONE_REMOTE_PATH) printf '%s\\n' vaultwarden_backups ;;
    BACKUP_DIR) printf '%s\\n' "\$BASE_DIR" ;;
    *) printf '%s\\n' "\${2:-}" ;;
  esac
}
_default_backup_dir(){ printf '%s\\n' "\$BASE_DIR"; }
_resolve_rclone_config_arg(){ local -n _out="\$1"; _out=(--config "$TMP/mock-rclone.conf"); }
backup_retention_days_for_type(){ printf '%s\\n' 30; }
cleanup_old_backups(){ return 0; }
_prune_remote_backups(){ return 0; }
rclone(){
  local cmd="\$1"; shift
  case "\$cmd" in
    lsd) return 0 ;;
    copy) printf '%s\\n' "\$*" >> "\$COPY_LOG"; return 0 ;;
    size) printf 'Total size: 1234 Bytes (1.205 KiB)\\n'; return 0 ;;
    *) return 0 ;;
  esac
}
$(_extract_func "$UTILS" backup_required_cohort_suffixes)
$(_extract_func "$BACKUP" _validate_emergency_restore_metadata)
$(_extract_func "$BACKUP" _verify_remote_cohort_member)
$(_extract_func "$BACKUP" sync_all_backups_to_rclone)
sync_all_backups_to_rclone
EOF_PROBE

: > "$TMP/batch-copy.calls"
if BATCH_META_CASE=zero bash "$TMP/batch-sync-probe.sh" >"$TMP/batch-invalid.out" 2>&1; then
  fail 'standalone retained sync accepted zero-byte emergency metadata'
fi
grep -Fq 'emergency-retained-20260710-120000.tar.zst.age' "$TMP/batch-invalid.out" \
  || fail 'standalone retained sync did not identify the invalid emergency archive'
grep -qi 'metadata is empty' "$TMP/batch-invalid.out" || fail 'standalone retained sync did not explain zero-byte emergency metadata'
[[ ! -s "$TMP/batch-copy.calls" ]] || fail 'standalone retained sync invoked emergency batch upload before metadata validation'
! grep -q 'Rclone backup copy complete' "$TMP/batch-invalid.out" || fail 'standalone retained sync printed success for invalid emergency metadata'

: > "$TMP/batch-copy.calls"
BATCH_META_CASE=valid bash "$TMP/batch-sync-probe.sh" >"$TMP/batch-valid.out" 2>&1 \
  || { cat "$TMP/batch-valid.out" >&2; fail 'standalone retained sync rejected supported emergency metadata'; }
grep -Fq "$TMP/retained/emergency/" "$TMP/batch-copy.calls" || fail 'valid retained emergency backup did not continue to batch copy'
grep -q 'Rclone backup copy complete' "$TMP/batch-valid.out" || fail 'valid retained emergency backup did not reach normal batch-sync completion'

grep -Fq 'if (( _sync_rc == 3 )); then' "$BACKUP" \
  || fail 'backup run caller must handle emergency metadata delivery status separately'
! grep -Fq 'synced with sidecar warnings' "$BACKUP" \
  || fail 'backup run must not report incomplete required sidecars as synced'
grep -Fq 'FAILED: emergency restore metadata missing or unusable; local backup is safe' "$BACKUP" \
  || fail 'backup run summary must mark incomplete emergency offsite delivery as failed'

printf 'PASS: emergency offsite metadata and required integrity sidecars must all complete before offsite success\n'
)

check_emergency_offsite_metadata_contract
check_rclone_config_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
BACKUP="$ROOT/utilities/backup-run.sh"
UTILS="$ROOT/lib/backup-utils.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

source "$ROOT/lib/log.sh"
source "$ROOT/lib/config.sh"
# shellcheck source=../lib/backup-utils.sh
source "$UTILS"
# shellcheck disable=SC1090  # process substitution intentionally extracts one function
source <(sed -n '/^_resolve_rclone_config_arg()/,/^}/p' "$BACKUP")

# The resolver/validator path does not invoke rclone. Keep this regression
# runnable on CI and development hosts where the optional binary is absent.
mock_cfg="$TMP/rclone.conf"
printf '[myremote]\ntype = local\n' > "$mock_cfg"
chmod 600 "$mock_cfg"
result_arr=()
rc=0
RCLONE_CONFIG="$mock_cfg" _resolve_rclone_config_arg result_arr || rc=$?
(( rc == 0 )) || fail "explicit rclone config resolver failed with exit $rc"
[[ "${result_arr[0]:-}" == "--config" ]] || fail "resolver did not populate --config"
[[ "${result_arr[1]:-}" == "$(realpath -e "$mock_cfg")" ]] \
    || fail "resolver returned the wrong explicit config path"

canonical_line=$(grep -nF 'canonical=$(realpath -e' "$UTILS" | head -1 | cut -d: -f1)
exception_line=$(grep -nF 'local root_rclone_config="/root/.config/rclone/rclone.conf"' "$UTILS" | head -1 | cut -d: -f1)
[[ -n "$canonical_line" && -n "$exception_line" && "$canonical_line" -lt "$exception_line" ]] \
    || fail "root rclone exception must be evaluated only after canonical path resolution"
grep -Fq '&& "$prefix" == "/root"' "$UTILS" \
    || fail "root rclone validator exception is not narrowly scoped to /root"

root_probe="$TMP/root-rclone-config-probe.sh"
cat > "$root_probe" <<'EOF_ROOT_PROBE'
#!/usr/bin/env bash
set -euo pipefail

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/backup-utils.sh"

root_dir=/root/.config/rclone
root_parent=/root/.config
root_config="${root_dir}/rclone.conf"
unrelated="${root_dir}/vw-rclone-unrelated-$$.conf"
created_root_dir=false
created_root_parent=false

# Never overwrite a real operator config or shadow the higher-priority /etc
# fallback. Structural assertions above remain active when a fixture is unsafe.
[[ ! -e "$root_config" && ! -L "$root_config" ]] || exit 77
[[ ! -e /etc/rclone/rclone.conf && ! -L /etc/rclone/rclone.conf ]] || exit 77
unset SUDO_USER

cleanup() {
    rm -f "$unrelated" "$root_config" "${root_config}.real"
    [[ "$created_root_dir" == "true" ]] && rmdir "$root_dir" 2>/dev/null || true
    [[ "$created_root_parent" == "true" ]] && rmdir "$root_parent" 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -d "$root_dir" ]]; then
    [[ -d "$root_parent" ]] || created_root_parent=true
    install -d -m 700 "$root_dir"
    created_root_dir=true
fi

printf '[test]\ntype = local\n' > "$root_config"
chmod 600 "$root_config"
RCLONE_CONFIG=""
resolved="$(_resolve_rclone_config)"
[[ "$resolved" == "$root_config" ]] || exit 1
validate_rclone_config_path "$resolved" || exit 1

printf '[test]\ntype = local\n' > "$unrelated"
chmod 600 "$unrelated"
if validate_rclone_config_path "$unrelated"; then exit 1; fi
if validate_rclone_config_path /etc/shadow; then exit 1; fi

mv "$root_config" "${root_config}.real"
ln -s /etc/shadow "$root_config"
if validate_rclone_config_path "$root_config"; then exit 1; fi
rm -f "$root_config"
mv "${root_config}.real" "$root_config"

chmod 666 "$root_config"
if validate_rclone_config_path "$root_config"; then exit 1; fi
chmod 600 "$root_config"

if id -u nobody >/dev/null 2>&1; then
    chown "$(id -u nobody)" "$root_config"
    if validate_rclone_config_path "$root_config"; then exit 1; fi
    chown 0 "$root_config"
fi
EOF_ROOT_PROBE
chmod 700 "$root_probe"

root_probe_rc=0
if (( EUID == 0 )); then
    PROJECT_ROOT="$ROOT" "$BASH" "$root_probe" || root_probe_rc=$?
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n env PROJECT_ROOT="$ROOT" "$BASH" "$root_probe" || root_probe_rc=$?
else
    root_probe_rc=77
fi

if (( root_probe_rc == 0 )); then
    printf 'PASS: canonical root rclone resolver/validator contract\n'
elif (( root_probe_rc == 77 )); then
    printf 'SKIP: root rclone fixture unavailable; structural canonical-path assertions passed\n'
else
    fail "canonical root rclone config probe failed (exit ${root_probe_rc})"
fi

)

check_rclone_config_contracts
check_backup_policy_retention_truthfulness() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
BACKUP="$ROOT/utilities/backup-run.sh"
UTILS="$ROOT/lib/backup-utils.sh"
MAINT="$ROOT/lib/maintenance-utils.sh"
MAINT_RUN="$ROOT/utilities/maintenance-run.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

_extract_func(){
  local file="$1" func="$2"
  awk -v f="$func" '
    $0 ~ "^" f "\\(\\)" {p=1}
    p {
      print
      opens=gsub(/\{/,"{"); closes=gsub(/\}/,"}")
      depth += opens - closes
      if (depth == 0) exit
    }' "$file"
}

source "$ROOT/lib/log.sh"
# shellcheck source=../lib/backup-utils.sh
source "$UTILS"

declare -A RETENTION_CONFIG=()
get_config_value(){
    local key="$1" fallback="${2:-}"
    printf '%s\n' "${RETENTION_CONFIG[$key]:-$fallback}"
}

RETENTION_CONFIG[BACKUP_RETENTION_DB_DAYS]=11
RETENTION_CONFIG[BACKUP_RETENTION_FULL_DAYS]=22
RETENTION_CONFIG[BACKUP_RETENTION_EMERGENCY_DAYS]=33
[[ "$(backup_retention_days_for_type db)" == "11" ]] || fail "db type-specific retention was not selected"
[[ "$(backup_retention_days_for_type full)" == "22" ]] || fail "full type-specific retention was not selected"
[[ "$(backup_retention_days_for_type emergency)" == "33" ]] || fail "emergency type-specific retention was not selected"
for backup_type in db full emergency; do
    [[ "$(backup_retention_days_for_type "$backup_type" 7)" == "7" ]] \
        || fail "explicit --keep retention did not win for $backup_type"
done

RETENTION_CONFIG[BACKUP_RETENTION_DB_DAYS]=""
RETENTION_CONFIG[BACKUP_RETENTION_FULL_DAYS]=""
RETENTION_CONFIG[BACKUP_RETENTION_EMERGENCY_DAYS]=""
RETENTION_CONFIG[BACKUP_RETENTION_DAYS]=44
for backup_type in db full emergency; do
    [[ "$(backup_retention_days_for_type "$backup_type")" == "44" ]] \
        || fail "generic retention fallback was not selected for $backup_type"
done
RETENTION_CONFIG[BACKUP_RETENTION_DAYS]=""
[[ "$(backup_retention_days_for_type db)" == "14" ]] || fail "db safe retention fallback was not 14 days"
[[ "$(backup_retention_days_for_type full)" == "30" ]] || fail "full safe retention fallback was not 30 days"
[[ "$(backup_retention_days_for_type emergency)" == "90" ]] || fail "emergency safe retention fallback was not 90 days"

for invalid in 0 -1 abc 1.5; do
    if backup_retention_days_for_type db "$invalid" >/dev/null 2>&1; then
        fail "invalid explicit retention was accepted: $invalid"
    fi
done
RETENTION_CONFIG[BACKUP_RETENTION_DB_DAYS]=bad
if backup_retention_days_for_type db >/dev/null 2>&1; then
    fail "invalid configured retention was accepted"
fi
if backup_retention_days_for_type unknown >/dev/null 2>&1; then
    fail "unknown backup type was accepted"
fi

for file in "$ROOT/.env.example" "$ROOT/docs/CONFIGURATION.md" "$ROOT/docs/ADVANCED-CUSTOMIZATION.md"; do
    ! grep -Eq 'BACKUP_ENCRYPTION_ENABLED|BACKUP_VERIFICATION_MODE' "$file" \
        || fail "unowned backup setting remains in $file"
done
if grep -R -nE 'BACKUP_ENCRYPTION_ENABLED|BACKUP_VERIFICATION_MODE' "$ROOT" \
        --include='*.sh' --include='*.bash' --exclude-dir=.git --exclude-dir=tests >/dev/null; then
    fail "unowned backup setting has an executable consumer"
fi
for legacy in DB_BACKUP_RETENTION_DAYS FULL_BACKUP_RETENTION_DAYS EMERGENCY_BACKUP_RETENTION_DAYS; do
    ! grep -Fq "$legacy" "$BACKUP" || fail "legacy retention owner remains in backup runner: $legacy"
    ! grep -Fq "$legacy" "$MAINT" || fail "legacy retention owner remains in maintenance library: $legacy"
    ! grep -Fq "$legacy" "$MAINT_RUN" || fail "legacy retention global remains in maintenance runner: $legacy"
done
grep -Fq 'backup_retention_days_for_type "$backup_type"' "$MAINT" \
    || fail "maintenance does not use the canonical retention resolver"
grep -Fq 'backup_retention_days_for_type "$actual_type" "${KEEP_DAYS:-}"' "$BACKUP" \
    || fail "backup run does not preserve explicit --keep precedence"
grep -Fq 'Local retention completed, but remote retention failed.' "$BACKUP" \
    || fail "rotate does not distinguish local completion from remote failure"

if (( BASH_VERSINFO[0] < 5 )); then
    printf 'SKIP: remote listing failure probe requires Bash 5 namerefs used by production backup-run.sh\n'
    return 0
fi

cat > "$TMP/remote-listing-probe.sh" <<EOF_PROBE
set -uo pipefail
ROOT="$ROOT"
CONTROL_WORKSPACE="$TMP/remote-work"
mkdir -p "\$CONTROL_WORKSPACE"
REMOTE_MODE="\${REMOTE_MODE:-empty}"
DELETE_LOG="$TMP/remote-listing-delete.log"
OUTPUT_LOG="$TMP/remote-listing-output.log"
DRY_RUN=false
KEEP_DAYS=""
source "\$ROOT/lib/log.sh"
source "\$ROOT/lib/backup-utils.sh"
backup_log_info(){ printf 'INFO:%s\n' "\$*" >> "\$OUTPUT_LOG"; }
backup_log_success(){ printf 'SUCCESS:%s\n' "\$*" >> "\$OUTPUT_LOG"; }
backup_log_warn(){ printf 'WARN:%s\n' "\$*" >> "\$OUTPUT_LOG"; }
log_warn(){ printf 'WARN:%s\n' "\$*" >> "\$OUTPUT_LOG"; }
log_error(){ printf 'ERROR:%s\n' "\$*" >> "\$OUTPUT_LOG"; }
get_config_value(){
    case "\$1" in
        RCLONE_REMOTE_NAME) printf '%s\n' mockremote ;;
        RCLONE_REMOTE_PATH) printf '%s\n' vaultwarden_backups ;;
        BACKUP_RETENTION_DB_DAYS|BACKUP_RETENTION_FULL_DAYS|BACKUP_RETENTION_EMERGENCY_DAYS) printf '%s\n' 1 ;;
        *) printf '%s\n' "\${2:-}" ;;
    esac
}
_resolve_rclone_config_arg(){ local -n _out="\$1"; _out=(); }
rclone(){
    local cmd="\${1:-}"
    shift || true
    case "\$cmd" in
        lsf)
            local remote_path="\${1:-}"
            case "\$REMOTE_MODE:\$remote_path" in
                absent:mockremote:vaultwarden_backups/db/) return 0 ;;
                absent:mockremote:vaultwarden_backups/full/|absent:mockremote:vaultwarden_backups/emergency/)
                    printf 'directory not found\n' >&2
                    return 3
                    ;;
                delete-fail:mockremote:vaultwarden_backups/db/)
                    printf '%s\n' 'db-z-20000101-000000.age' 'db-a-20010101-000000.age'
                    return 0
                    ;;
                delete-fail:mockremote:vaultwarden_backups/full/|delete-fail:mockremote:vaultwarden_backups/emergency/)
                    return 3
                    ;;
                fail:*)
                    printf 'simulated listing failure\n' >&2
                    return 17
                    ;;
                *) return 0 ;;
            esac
            ;;
        deletefile)
            printf '%s\n' "\$*" >> "\$DELETE_LOG"
            if [[ "\$REMOTE_MODE" == "delete-fail" && "\$*" == *'/db-z-20000101-000000.age '* ]]; then
                return 23
            fi
            return 0
            ;;
        *) return 0 ;;
    esac
}
$(_extract_func "$BACKUP" _prune_remote_backups)
_prune_remote_backups
EOF_PROBE

: > "$TMP/remote-listing-delete.log"
: > "$TMP/remote-listing-output.log"
REMOTE_MODE=empty bash "$TMP/remote-listing-probe.sh" \
    || { cat "$TMP/remote-listing-output.log" >&2; fail "empty remote inventory should succeed"; }
[[ ! -s "$TMP/remote-listing-delete.log" ]] || fail "empty remote inventory triggered deletion"
grep -Fq '[remote] No db backup archives found on remote — nothing to prune.' "$TMP/remote-listing-output.log" \
    || fail "empty remote inventory was not reported distinctly"

: > "$TMP/remote-listing-delete.log"
: > "$TMP/remote-listing-output.log"
REMOTE_MODE=absent bash "$TMP/remote-listing-probe.sh" \
    || { cat "$TMP/remote-listing-output.log" >&2; fail "absent full/emergency remote tiers should succeed"; }
[[ ! -s "$TMP/remote-listing-delete.log" ]] || fail "absent remote tier triggered deletion"
grep -Fq 'No full backup directory exists yet at mockremote:vaultwarden_backups/full/ — nothing to prune.' "$TMP/remote-listing-output.log" \
    || fail "absent full tier was not reported as expected"
grep -Fq 'No emergency backup directory exists yet at mockremote:vaultwarden_backups/emergency/ — nothing to prune.' "$TMP/remote-listing-output.log" \
    || fail "absent emergency tier was not reported as expected"
! grep -Fq 'Remote retention did not complete' "$TMP/remote-listing-output.log" \
    || fail "absent remote tier was classified as a retention failure"

: > "$TMP/remote-listing-delete.log"
: > "$TMP/remote-listing-output.log"
if REMOTE_MODE=fail bash "$TMP/remote-listing-probe.sh"; then
    fail "failed remote inventory returned success"
fi
[[ ! -s "$TMP/remote-listing-delete.log" ]] || fail "failed remote inventory triggered deletion"
grep -Fq 'Failed to list mockremote:vaultwarden_backups/db/ (rclone exit 17). No db files were deleted.' "$TMP/remote-listing-output.log" \
    || fail "remote listing failure did not report the remote path and no-delete outcome"
grep -Fq 'simulated listing failure' "$TMP/remote-listing-output.log" \
    || fail "remote listing failure omitted actionable rclone output"
grep -Fq 'Remote retention did not complete' "$TMP/remote-listing-output.log" \
    || fail "remote listing failure did not propagate a nonzero result"

: > "$TMP/remote-listing-delete.log"
: > "$TMP/remote-listing-output.log"
if REMOTE_MODE=delete-fail bash "$TMP/remote-listing-probe.sh"; then
    fail "failed remote primary deletion returned success"
fi
grep -Fq 'One or more old db backups could not be pruned from mockremote:vaultwarden_backups/db/.' "$TMP/remote-listing-output.log" \
    || fail "remote primary deletion failure did not report the tier outcome"
! grep -Fq '[remote] No old db backups to prune on remote.' "$TMP/remote-listing-output.log" \
    || fail "remote primary deletion failure printed a contradictory no-work message"

grep -Fq 'Remote retention did not complete' "$TMP/remote-listing-output.log" \
    || fail "remote primary deletion failure did not propagate a nonzero result"

printf 'PASS: canonical retention policy and remote inventory failure reporting\n'
)

check_backup_policy_retention_truthfulness
check_backup_retention_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
BACKUP="$ROOT/utilities/backup-run.sh"
UTILS="$ROOT/lib/backup-utils.sh"
fail(){ echo "FAIL: $*" >&2; exit 1; }

_extract_func(){
  local file="$1" func="$2"
  awk -v f="$func" '
    $0 ~ "^" f "\\(\\)" {p=1}
    p {
      print
      opens=gsub(/\{/,"{"); closes=gsub(/\}/,"}")
      depth += opens - closes
      if (depth == 0) exit
    }' "$file"
}

_write_archive_with_sidecars() {
    local archive="$1"
    printf 'archive\n' > "$archive"
    printf 'sha\n' > "$archive.sha256"
    printf 'hmac\n' > "$archive.sha256.hmac"
    printf 'meta\n' > "$archive.meta"
}

_assert_exists() {
    [[ -e "$1" ]] || fail "expected retained file missing: $1"
}

_assert_missing() {
    [[ ! -e "$1" ]] || fail "expected deleted file still present: $1"
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../lib/log.sh
source "$ROOT/lib/log.sh"
# shellcheck source=../lib/backup-utils.sh
source "$UTILS"

local_dir="$TMP/local/db"
mkdir -p "$local_dir"
newest="$local_dir/db-a-20010101-000000.age"
older="$local_dir/db-z-20000101-000000.age"
_write_archive_with_sidecars "$newest"
_write_archive_with_sidecars "$older"

cleanup_old_backups "$local_dir" db 1 > "$TMP/local-retention.out" 2>&1 \
    || { cat "$TMP/local-retention.out" >&2; fail "local retention cleanup failed"; }

for suffix in "" ".sha256" ".sha256.hmac" ".meta"; do
    _assert_exists "$newest$suffix"
    _assert_missing "$older$suffix"
done

unparseable="$local_dir/db-manual-before-contract.age"
_write_archive_with_sidecars "$unparseable"
cleanup_old_backups "$local_dir" db 1 > "$TMP/local-unparseable.out" 2>&1 \
    || { cat "$TMP/local-unparseable.out" >&2; fail "local retention with unparseable archive failed"; }
_assert_exists "$unparseable"

no_parse_dir="$TMP/no-parse/db"
mkdir -p "$no_parse_dir"
no_parse_a="$no_parse_dir/db-manual-a.age"
no_parse_b="$no_parse_dir/db-manual-b.age"
_write_archive_with_sidecars "$no_parse_a"
_write_archive_with_sidecars "$no_parse_b"
cleanup_old_backups "$no_parse_dir" db 1 > "$TMP/local-no-parse.out" 2>&1 \
    || { cat "$TMP/local-no-parse.out" >&2; fail "local no-parse retention failed"; }
_assert_exists "$no_parse_a"
_assert_exists "$no_parse_b"

dry_run_dir="$TMP/dry-run/db"
mkdir -p "$dry_run_dir"
dry_run_older="$dry_run_dir/db-z-20000101-000000.age"
dry_run_newest="$dry_run_dir/db-a-20010101-000000.age"
orphan_sidecar="$dry_run_dir/db-orphan-19990101-000000.age.meta"
_write_archive_with_sidecars "$dry_run_older"
_write_archive_with_sidecars "$dry_run_newest"
printf 'orphan\n' > "$orphan_sidecar"
DRY_RUN=true cleanup_old_backups "$dry_run_dir" db 1 > "$TMP/local-dry-run.out" 2>&1 \
    || { cat "$TMP/local-dry-run.out" >&2; fail "local retention dry-run failed"; }
for file in \
    "$dry_run_older" "$dry_run_older.sha256" "$dry_run_older.sha256.hmac" "$dry_run_older.meta" \
    "$dry_run_newest" "$dry_run_newest.sha256" "$dry_run_newest.sha256.hmac" "$dry_run_newest.meta" \
    "$orphan_sidecar"; do
    _assert_exists "$file"
done
grep -Fq "[DRY RUN] Would remove: $(basename "$dry_run_older") (and sidecars)" "$TMP/local-dry-run.out" \
    || fail "local dry-run did not report the stale deletion candidate"
! grep -Fq "[DRY RUN] Would remove: $(basename "$dry_run_newest") (and sidecars)" "$TMP/local-dry-run.out" \
    || fail "local dry-run reported the preserved newest archive as a deletion candidate"
grep -Fq '[DRY RUN] Would clean up 1 old db backups' "$TMP/local-dry-run.out" \
    || fail "local dry-run summary did not count the planned archive deletion"
grep -Fq "[DRY RUN] Would remove orphaned sidecar: $(basename "$orphan_sidecar")" "$TMP/local-dry-run.out" \
    || fail "local dry-run did not report the orphaned sidecar candidate"
grep -Fq '[DRY RUN] Would remove 1 orphaned sidecar file(s) from db backups' "$TMP/local-dry-run.out" \
    || fail "local dry-run summary did not count the planned orphan sidecar deletion"

# Maintenance owns orchestration, but cleanup_old_backups remains the canonical
# retention selector. Exercise that wrapper with DRY_RUN=true so this test
# protects delegation rather than duplicating helper coverage above.
source "$ROOT/lib/maintenance-utils.sh"
maintenance_dry_run_dir="$TMP/maintenance-dry-run"
mkdir -p "$maintenance_dry_run_dir/db"
maintenance_older="$maintenance_dry_run_dir/db/db-z-20000101-000000.age"
maintenance_newest="$maintenance_dry_run_dir/db/db-a-20010101-000000.age"
maintenance_manual="$maintenance_dry_run_dir/db/db-manual-before-contract.age"
maintenance_orphan="$maintenance_dry_run_dir/db/db-orphan-19990101-000000.age.meta"
_write_archive_with_sidecars "$maintenance_older"
_write_archive_with_sidecars "$maintenance_newest"
_write_archive_with_sidecars "$maintenance_manual"
printf 'orphan\n' > "$maintenance_orphan"

vw_default_backup_dir(){ printf '%s\n' "$maintenance_dry_run_dir"; }
get_config_value(){
    case "$1" in
        BACKUP_DIR) printf '%s\n' "$maintenance_dry_run_dir" ;;
        BACKUP_RETENTION_DB_DAYS) printf '%s\n' 1 ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}

DRY_RUN=true CLEAN_BACKUPS=true \
    cleanup_backups > "$TMP/maintenance-dry-run.out" 2>&1 \
    || { cat "$TMP/maintenance-dry-run.out" >&2; fail "maintenance retention dry-run failed"; }
for file in \
    "$maintenance_older" "$maintenance_older.sha256" "$maintenance_older.sha256.hmac" "$maintenance_older.meta" \
    "$maintenance_newest" "$maintenance_newest.sha256" "$maintenance_newest.sha256.hmac" "$maintenance_newest.meta" \
    "$maintenance_manual" "$maintenance_manual.sha256" "$maintenance_manual.sha256.hmac" "$maintenance_manual.meta" \
    "$maintenance_orphan"; do
    _assert_exists "$file"
done
grep -Fq "[DRY RUN] Would clean up db backups older than 1 days" "$TMP/maintenance-dry-run.out" \
    || fail "maintenance dry-run did not reach canonical retention preview"
grep -Fq 'db backup retention preview completed (1d retention)' "$TMP/maintenance-dry-run.out" \
    || fail "maintenance dry-run did not report successful retention preview"
! grep -Fq 'db backups cleaned (1d retention)' "$TMP/maintenance-dry-run.out" \
    || fail "maintenance dry-run falsely reported backups as cleaned"
grep -Fq "[DRY RUN] Would remove: $(basename "$maintenance_older") (and sidecars)" "$TMP/maintenance-dry-run.out" \
    || fail "maintenance dry-run did not report stale archive candidate"
grep -Fq '[DRY RUN] Would clean up 1 old db backups' "$TMP/maintenance-dry-run.out" \
    || fail "maintenance dry-run did not report canonical archive cleanup summary"
grep -Fq "[DRY RUN] Would remove orphaned sidecar: $(basename "$maintenance_orphan")" "$TMP/maintenance-dry-run.out" \
    || fail "maintenance dry-run did not report orphaned sidecar candidate"
grep -Fq '[DRY RUN] Would remove 1 orphaned sidecar file(s) from db backups' "$TMP/maintenance-dry-run.out" \
    || fail "maintenance dry-run did not report canonical orphan cleanup summary"
! grep -Fq "[DRY RUN] Would remove: $(basename "$maintenance_newest") (and sidecars)" "$TMP/maintenance-dry-run.out" \
    || fail "maintenance dry-run reported newest archive as a deletion candidate"
! grep -Fq "[DRY RUN] Would remove: $(basename "$maintenance_manual") (and sidecars)" "$TMP/maintenance-dry-run.out" \
    || fail "maintenance dry-run reported manual archive as a deletion candidate"
! grep -Fq '[DRY RUN] Would clean up old backups based on retention policy' "$TMP/maintenance-dry-run.out" \
    || fail "maintenance dry-run used obsolete generic retention message"

if (( BASH_VERSINFO[0] < 5 )); then
    printf 'SKIP: remote prune mock requires Bash 5 namerefs used by production backup-run.sh\n'
    return 0
fi

cat > "$TMP/remote-prune-probe.sh" <<EOF_PROBE
set -euo pipefail
ROOT="$ROOT"
DELETE_LOG="$TMP/remote-delete.log"
REMOTE_LOG="$TMP/remote-prune.log"
DRY_RUN="\${REMOTE_DRY_RUN:-false}"
KEEP_DAYS=""
backup_log_info(){ printf 'INFO:%s\n' "\$*" >> "\$REMOTE_LOG"; }
backup_log_success(){ printf 'SUCCESS:%s\n' "\$*" >> "\$REMOTE_LOG"; }
backup_log_warn(){ printf 'WARN:%s\n' "\$*" >> "\$REMOTE_LOG"; }
log_warn(){ printf 'WARN:%s\n' "\$*" >> "\$REMOTE_LOG"; }
log_error(){ printf 'ERROR:%s\n' "\$*" >> "\$REMOTE_LOG"; }
get_config_value(){
    case "\$1" in
        RCLONE_REMOTE_NAME) printf '%s\n' mockremote ;;
        RCLONE_REMOTE_PATH) printf '%s\n' vaultwarden_backups ;;
        BACKUP_RETENTION_DB_DAYS|BACKUP_RETENTION_FULL_DAYS|BACKUP_RETENTION_EMERGENCY_DAYS) printf '%s\n' 1 ;;
        *) printf '%s\n' "\${2:-}" ;;
    esac
}
_resolve_rclone_config_arg(){ local -n _out="\$1"; _out=(); }
rclone(){
    local cmd="\${1:-}"
    shift || true
    case "\$cmd" in
        lsf)
            local arg
            for arg in "\$@"; do
                if [[ "\$arg" == "mockremote:vaultwarden_backups/db/" ]]; then
                    printf '%s\n' \
                        'db-z-20000101-000000.age' \
                        'db-manual-upload.age' \
                        'db-a-20010101-000000.age'
                    return 0
                fi
            done
            return 0
            ;;
        deletefile)
            printf '%s\n' "\$*" >> "\$DELETE_LOG"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
source "\$ROOT/lib/log.sh"
source "\$ROOT/lib/backup-utils.sh"
$(_extract_func "$BACKUP" _prune_remote_backups)
_prune_remote_backups
EOF_PROBE

: > "$TMP/remote-delete.log"
: > "$TMP/remote-prune.log"
REMOTE_DRY_RUN=true bash "$TMP/remote-prune-probe.sh" \
    || { cat "$TMP/remote-prune.log" >&2; fail "remote dry-run prune probe failed"; }
[[ ! -s "$TMP/remote-delete.log" ]] || fail "remote dry-run called rclone deletefile"
grep -Fq 'Would delete remote: mockremote:vaultwarden_backups/db/db-z-20000101-000000.age' "$TMP/remote-prune.log" \
    || fail "remote dry-run did not report older stale archive"
! grep -Fq 'Would delete remote: mockremote:vaultwarden_backups/db/db-a-20010101-000000.age' "$TMP/remote-prune.log" \
    || fail "remote dry-run reported newest archive as deletion candidate"
grep -Fq '[DRY RUN] Would prune 1 old db backup(s) from mockremote:vaultwarden_backups/db/' "$TMP/remote-prune.log" \
    || fail "remote dry-run summary did not count the planned archive deletion"
! grep -Fq '[remote] No old db backups to prune on remote.' "$TMP/remote-prune.log" \
    || fail "remote dry-run contradicted its own deletion candidate"

: > "$TMP/remote-delete.log"
: > "$TMP/remote-prune.log"
bash "$TMP/remote-prune-probe.sh" \
    || { cat "$TMP/remote-prune.log" >&2; fail "remote prune probe failed"; }
grep -Fq 'mockremote:vaultwarden_backups/db/db-z-20000101-000000.age' "$TMP/remote-delete.log" \
    || fail "remote prune did not delete older stale archive"
for suffix in .sha256 .sha256.hmac .meta; do
    grep -Fq "mockremote:vaultwarden_backups/db/db-z-20000101-000000.age${suffix}" "$TMP/remote-delete.log" \
        || fail "remote prune did not delete older sidecar ${suffix}"
    ! grep -Fq "mockremote:vaultwarden_backups/db/db-a-20010101-000000.age${suffix}" "$TMP/remote-delete.log" \
        || fail "remote prune deleted newest sidecar ${suffix}"
done
! grep -Fq 'mockremote:vaultwarden_backups/db/db-a-20010101-000000.age' "$TMP/remote-delete.log" \
    || fail "remote prune deleted newest archive"
! grep -Fq 'mockremote:vaultwarden_backups/db/db-manual-upload.age' "$TMP/remote-delete.log" \
    || fail "remote prune deleted unparseable archive"

printf 'PASS: backup retention preserves newest local and remote archives\n'

)

check_backup_retention_contracts
check_backup_db_restart_fallback() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
fail(){ echo "FAIL: $*" >&2; exit 1; }

_extract_func(){
  local file="$1" func="$2"
  awk -v f="$func" '
    $0 ~ "^" f "\\(\\)" {p=1}
    p {
      print
      opens=gsub(/\{/,"{"); closes=gsub(/\}/,"}")
      depth += opens - closes
      if (depth == 0) exit
    }' "$file"
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Behavior: offline DB fallback restarts if this helper stopped the container and wait fails.
cat > "$TMP/db-restart-probe.sh" <<EOF_PROBE
set -uo pipefail
SCRIPT_DIR="$ROOT"; DB_SNAPSHOT_METHOD=""; DB_SNAPSHOT_RESTART_SERVICE=""; DB_SNAPSHOT_STOPPED_CONTAINER=false; DB_SNAPSHOT_RESTARTED=false
backup_log_info(){ :; }; backup_log_warn(){ :; }; log_error(){ :; }; cleanup(){ :; }
get_config_value(){ printf '%s\n' vaultwarden; }
create_db_snapshot_host(){ return 1; }
verify_sqlite(){ return 1; }
_vaultwarden_container_running(){ return 0; }
wait_for_container_stopped(){ return 1; }
docker(){ printf '%s\n' "docker \$*" >> "$TMP/docker.calls"; }
sqlite3(){ return 1; }
$(_extract_func "$ROOT/utilities/backup-run.sh" _db_snapshot_restart_if_needed)
$(_extract_func "$ROOT/utilities/backup-run.sh" create_consistent_db_snapshot)
mkdir -p "$TMP/state/data"; printf db > "$TMP/state/data/db.sqlite3"
trap ':' EXIT
trap ':' ERR
trap ':' INT
trap ':' HUP
trap ':' TERM
before_traps="\$(trap -p EXIT ERR INT HUP TERM)"
if create_consistent_db_snapshot "$TMP/state" "$TMP/snap.sqlite3" db-test; then exit 1; fi
after_traps="\$(trap -p EXIT ERR INT HUP TERM)"
[[ "\$before_traps" == "\$after_traps" ]] || exit 2
EOF_PROBE
bash "$TMP/db-restart-probe.sh" || fail 'DB restart probe script failed'
grep -q 'docker compose stop vaultwarden' "$TMP/docker.calls" || fail 'offline fallback did not stop container in probe'
[[ "$(grep -c 'docker compose start vaultwarden' "$TMP/docker.calls")" == "1" ]] || fail 'offline fallback did not restart exactly once after wait failure'

)

check_backup_db_restart_fallback

_extract_shell_function() {
    local file="$1" function_name="$2"
    sed -n "/^${function_name}() {$/,/^}$/p" "$file"
}

check_backup_workspace_and_manifest_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
BACKUP="$ROOT/utilities/backup-run.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log_error(){ printf 'ERROR %s\n' "$*" >&2; }

for function_name in \
    _archive_member_path backup_archive_exclusions \
    _require_safe_backup_source_layout \
    _workspace_identity _remove_owned_workspace _create_owned_workspace; do
    eval "$(_extract_shell_function "$BACKUP" "$function_name")"
done

project="$TMP/project"
state="$TMP/state"
backup_base="$state/custom-backups"
age_key="$state/ops/private.age"
mkdir -p \
    "$project/.git" "$project/backups" "$project/logs" \
    "$state/data/attachments" "$state/.pre-restore-fixture" \
    "$backup_base/.vaultwarden-backup.fixture" "$state/ops" "$state/config"
printf keep > "$project/keep.txt"
printf git-secret > "$project/.git/secret"
printf old-backup > "$project/backups/recursive.secret"
printf attachment > "$state/data/attachments/keep.txt"
printf live-db > "$state/data/db.sqlite3"
printf wal > "$state/data/db.sqlite3-wal"
printf key > "$age_key"
printf recurse > "$backup_base/.vaultwarden-backup.fixture/recursive.secret"
printf scratch > "$state/.pre-restore-fixture/scratch"

mapfile -t effective < <(backup_archive_exclusions "$project" "$state" "$backup_base" "$age_key")
contains(){ printf '%s\n' "${effective[@]}" | grep -Fxq -- "$1"; }
contains "${state#/}/data/db.sqlite3" || fail "effective exclusions omitted live DB"
contains "${state#/}/data/db.sqlite3-wal" || fail "effective exclusions omitted WAL"
contains "${state#/}/data/db.sqlite3-shm" || fail "effective exclusions omitted SHM"
contains "${project#/}/backups" || fail "effective exclusions omitted legacy project backup path"
contains "${backup_base#/}" || fail "effective exclusions omitted configured BACKUP_DIR"
contains "${backup_base#/}/.vaultwarden-backup.*" || fail "effective exclusions omitted payload staging pattern"
contains "${age_key#/}" || fail "effective exclusions omitted configured operational Age key"
contains "run/vaultwarden-oci/secrets/*" || fail "effective exclusions omitted runtime decrypted secrets"
state_parent_member="$(_archive_member_path "$(dirname "$state")")"
state_basename="$(basename "$state")"
contains "${state#/}/.vaultwarden-restore-payload.*" \
    || fail "effective exclusions omitted mounted restore payload workspaces"
contains "${state_parent_member}/.${state_basename}.restore-payload.*" \
    || fail "effective exclusions omitted boot restore payload workspaces"
contains "${state#/}.restore-workspace.*" \
    || fail "effective exclusions omitted boot promotion workspaces"
contains "${state#/}.restore-staged.*" || fail "effective exclusions omitted legacy restore staging siblings"

mapfile -t unique_effective < <(printf '%s\n' "${effective[@]}" | awk '!seen[$0]++')
[[ ${#unique_effective[@]} -eq ${#effective[@]} ]] || fail "effective exclusions contain duplicates"

tar_args=()
for item in "${effective[@]}"; do tar_args+=("--exclude=$item"); done
tar -cf "$TMP/exclusions.tar" -C / "${tar_args[@]}" "${project#/}" "${state#/}"
tar -tf "$TMP/exclusions.tar" | sed 's#^\./##' > "$TMP/members"
grep -Fxq "${project#/}/keep.txt" "$TMP/members" || fail "tar exclusions removed included project content"
grep -Fxq "${state#/}/data/attachments/keep.txt" "$TMP/members" || fail "tar exclusions removed included state content"
! grep -Fq "${state#/}/data/db.sqlite3" "$TMP/members" || fail "tar archived live DB/WAL input"
! grep -Fq "${project#/}/backups" "$TMP/members" || fail "tar recursed into the legacy project backup path"
! grep -Fq "${backup_base#/}" "$TMP/members" || fail "tar recursed into configured backup staging"
! grep -Fq "${age_key#/}" "$TMP/members" || fail "tar archived configured operational Age key"
! grep -Fq '.pre-restore-fixture' "$TMP/members" || fail "tar archived restore scratch state"

# Real tar coverage for crash-residual restore workspace names. Keep the state
# directory below the project root so sibling boot workspaces are archive inputs.
residue_project="$TMP/restore-residue-project"
residue_state="$residue_project/state"
residue_backup="$residue_state/backups"
residue_extract="$TMP/restore-residue-extract"
residue_dirs=(
    "$residue_state/.vaultwarden-restore-payload.mounted"
    "$residue_project/.state.restore-payload.boot"
    "$residue_project/state.restore-workspace.promotion"
    "$residue_project/state.restore-staged.legacy"
)
mkdir -p "$residue_state/data" "$residue_backup" "$residue_extract"
printf included > "$residue_state/data/keep.txt"
for residue_dir in "${residue_dirs[@]}"; do
    mkdir -p "$residue_dir"
    printf 'RESTORE-RESIDUE-MARKER-%s\n' "$(basename "$residue_dir")" > "$residue_dir/marker.txt"
    printf 'AGE-SECRET-KEY-1FAKE-RESTORE-RESIDUE-%s\n' "$(basename "$residue_dir")" \
        > "$residue_dir/private-age-key.txt"
done
mapfile -t residue_excludes < <(
    backup_archive_exclusions "$residue_project" "$residue_state" "$residue_backup" ""
)
residue_tar_args=()
for item in "${residue_excludes[@]}"; do residue_tar_args+=("--exclude=$item"); done
tar -cf "$TMP/restore-residue-exclusions.tar" -C / "${residue_tar_args[@]}" \
    "${residue_project#/}" "${residue_state#/}"
tar -tf "$TMP/restore-residue-exclusions.tar" | sed 's#^\./##' > "$TMP/restore-residue.members"
grep -Fxq "${residue_state#/}/data/keep.txt" "$TMP/restore-residue.members" \
    || fail "restore-residue exclusions removed included state content"
! grep -Fq '.vaultwarden-restore-payload.' "$TMP/restore-residue.members" \
    || fail "tar archived a mounted restore payload workspace"
! grep -Fq '.state.restore-payload.' "$TMP/restore-residue.members" \
    || fail "tar archived a boot restore payload workspace"
! grep -Fq 'state.restore-workspace.' "$TMP/restore-residue.members" \
    || fail "tar archived a boot promotion workspace"
! grep -Fq 'state.restore-staged.' "$TMP/restore-residue.members" \
    || fail "tar archived a legacy restore staging workspace"
tar -xf "$TMP/restore-residue-exclusions.tar" -C "$residue_extract"
! grep -R -Fq 'RESTORE-RESIDUE-MARKER-' "$residue_extract" \
    || fail "tar archived restore workspace marker content"
! grep -R -Fq 'AGE-SECRET-KEY-1FAKE-RESTORE-RESIDUE-' "$residue_extract" \
    || fail "tar archived fake private Age key material from restore residue"

assert_canonical_backup_exclusion() {
    local case_name="$1" raw_backup="$2"
    local canonical_backup canonical_project canonical_state
    _require_safe_backup_source_layout \
        "$raw_backup" "$project" "$state" \
        canonical_backup canonical_project canonical_state \
        || fail "$case_name canonical descendant was rejected"
    [[ "$canonical_backup" != "$raw_backup" ]] \
        || fail "$case_name fixture did not exercise a non-canonical path"

    local -a case_effective=() case_tar_args=()
    local item
    mapfile -t case_effective < <(
        backup_archive_exclusions \
            "$canonical_project" "$canonical_state" "$raw_backup" "$age_key"
    )
    for item in "${case_effective[@]}"; do
        case_tar_args+=("--exclude=$item")
    done

    tar -cf "$TMP/${case_name}.tar" -C / "${case_tar_args[@]}" \
        "${canonical_project#/}" "${canonical_state#/}"
    tar -tf "$TMP/${case_name}.tar" | sed 's#^\./##' > "$TMP/${case_name}.members"
    grep -Fxq "${canonical_state#/}/data/attachments/keep.txt" "$TMP/${case_name}.members" \
        || fail "$case_name removed included state content"
    ! grep -Fq "${canonical_backup#/}" "$TMP/${case_name}.members" \
        || fail "$case_name archived the canonical backup directory"
    ! grep -Fq "${canonical_backup#/}/.vaultwarden-backup.fixture" "$TMP/${case_name}.members" \
        || fail "$case_name archived its payload workspace"
}

dotdot_backup="$state/../state/dotdot-backups"
mkdir -p "$state/dotdot-backups/full" "$state/dotdot-backups/.vaultwarden-backup.fixture/db-snapshot-payload"
printf old > "$state/dotdot-backups/full/old.age"
printf staged > "$state/dotdot-backups/.vaultwarden-backup.fixture/db-snapshot-payload/db.sqlite3"
assert_canonical_backup_exclusion noncanonical-descendant "$dotdot_backup"

symlink_target="$state/symlink-target"
symlink_backup="$TMP/backup-link/custom-backups"
mkdir -p "$symlink_target/custom-backups/full" \
    "$symlink_target/custom-backups/.vaultwarden-backup.fixture/db-snapshot-payload"
ln -s "$symlink_target" "$TMP/backup-link"
printf old > "$symlink_target/custom-backups/full/old.age"
printf staged > "$symlink_target/custom-backups/.vaultwarden-backup.fixture/db-snapshot-payload/db.sqlite3"
assert_canonical_backup_exclusion symlinked-descendant "$symlink_backup"

cat > "$state/config/install.env" <<EOF_ENV
PROJECT_STATE_DIR=$state
BACKUP_DIR=$dotdot_backup
SOPS_AGE_KEY_FILE=$age_key
EOF_ENV
chmod 600 "$state/config/install.env"
manifest="$TMP/manifest"
manifest_runner=()
if (( EUID == 0 )); then
    manifest_runner=(env)
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n chown root:root "$state/config/install.env"
    manifest_runner=(sudo -n env)
else
    printf 'SKIP manifest installed-environment probe: root or passwordless sudo unavailable\n'
fi
if (( ${#manifest_runner[@]} > 0 )); then
    "${manifest_runner[@]}" TERM=dumb PROJECT_STATE_DIR="$state" \
        VW_CONFIG_INSTALLED_ENV_FILE="$TMP/no-system-env" \
        "$ROOT/backup.sh" manifest > "$manifest"
    sed -n 's/^  - //p' "$manifest" > "$TMP/manifest.excludes"
    mapfile -t manifest_effective < <(backup_archive_exclusions "$ROOT" "$state" "$dotdot_backup" "$age_key")
    printf '%s\n' "${manifest_effective[@]}" > "$TMP/effective.excludes"
    cmp -s "$TMP/effective.excludes" "$TMP/manifest.excludes" \
        || { diff -u "$TMP/effective.excludes" "$TMP/manifest.excludes" >&2 || true; fail "manifest differs from effective tar exclusion owner"; }

    if "${manifest_runner[@]}" TERM=dumb PROJECT_STATE_DIR="$TMP/missing-state" \
            VW_CONFIG_INSTALLED_ENV_FILE="$TMP/missing-system-env" \
            "$ROOT/backup.sh" manifest > "$TMP/missing-manifest.out" 2>&1; then
        fail "manifest silently printed defaults without canonical configuration"
    fi
    grep -Fq 'Failed to load canonical project environment for backup manifest.' "$TMP/missing-manifest.out" \
        || fail "manifest configuration failure was not explicit"
fi

grep -Fq $'	@./backup.sh manifest' "$ROOT/Makefile" \
    || fail "make backup-manifest does not execute the normal manifest command"
! grep -Fq 'source utilities/backup-run.sh' "$ROOT/Makefile" \
    || fail "backup-manifest still sources the complete CLI"

workspace_parent="$TMP/workspace-backups"
mkdir -p "$workspace_parent"
control_path="" control_id="" payload_path="" payload_id=""
_create_owned_workspace control_path control_id /dev/shm vw-backup-control true \
    || fail "control workspace creation failed"
_create_owned_workspace payload_path payload_id "$workspace_parent" .vaultwarden-backup \
    || fail "payload workspace creation failed"
[[ "$payload_path" == "$workspace_parent/.vaultwarden-backup."* ]] || fail "payload workspace is not on configured backup filesystem"
[[ -d "$control_path" && ! -L "$control_path" ]] || fail "control workspace is not a real directory"
[[ -d "$payload_path" && ! -L "$payload_path" ]] || fail "payload workspace is not a real directory"
[[ "$(stat -c '%a' "$control_path")" == 700 && "$(stat -c '%a' "$payload_path")" == 700 ]] \
    || fail "backup workspaces are not mode 0700"
_remove_owned_workspace "$control_path" "$control_id" control || fail "control workspace cleanup failed"
_remove_owned_workspace "$payload_path" "$payload_id" payload || fail "payload workspace cleanup failed"
[[ ! -e "$control_path" && ! -e "$payload_path" ]] || fail "owned backup workspaces were not cleaned"
control_path=""; control_id=""; payload_path=""; payload_id=""

_create_owned_workspace payload_path payload_id "$workspace_parent" .vaultwarden-backup \
    || fail "replacement-safety payload creation failed"
mv "$payload_path" "${payload_path}.owned"
mkdir "$payload_path"
printf replacement > "$payload_path/marker"
if _remove_owned_workspace "$payload_path" "$payload_id" payload 2>/dev/null; then
    fail "cleanup accepted a replaced workspace identity"
fi
[[ -f "$payload_path/marker" && -d "${payload_path}.owned" ]] \
    || fail "cleanup deleted a path whose recorded staging identity was replaced"

! grep -Fq 'validate_backup_integrity' "$ROOT/lib/backup-utils.sh" \
    || fail "unused separate archive verifier remains in backup-utils"

printf 'PASS: one owned-workspace primitive and fail-closed manifest command share exact exclusions\n'
)

check_backup_workspace_and_manifest_contracts

check_backup_payload_candidate_and_capacity_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
BACKUP="$ROOT/utilities/backup-run.sh"
UTILS="$ROOT/lib/backup-utils.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for function_name in \
    _archive_member_path backup_archive_exclusions get_backup_dir \
    _require_safe_backup_source_layout _workspace_identity \
    _backup_estimated_source_mb _preflight_backup_payload_capacity \
    _discard_backup_cohort _require_absent_backup_cohorts _cleanup_unpublished_backup \
    _validate_created_backup_cohort _publish_backup_candidate \
    _backup_storage_mode _verify_encrypted_archive_stream verify_backup_full perform_full_backup; do
    eval "$(_extract_shell_function "$BACKUP" "$function_name")"
done
eval "$(_extract_shell_function "$UTILS" check_backup_disk_space)"

project="$TMP/project"
state="$TMP/state"
backup_base="$state/backups"
target="$backup_base/full"
key="$TMP/age-key.txt"
mkdir -p "$project" "$state/data" "$target"
printf project > "$project/config"
printf database > "$state/data/db.sqlite3"
printf key > "$key"

SCRIPT_DIR="$project"
DRY_RUN=false
QUIET=true
FILE_INTEGRITY_HMAC_KEY=""
REQUIRE_AUTHENTICATED_INTEGRITY=false
CONTROL_WORKSPACE="$TMP/control"
PAYLOAD_WORKSPACE="$backup_base/.vaultwarden-backup.fixture"
PENDING_BACKUP_CANDIDATE=""
PENDING_BACKUP_FINAL=""
export SCRIPT_DIR QUIET FILE_INTEGRITY_HMAC_KEY
export PENDING_BACKUP_CANDIDATE PENDING_BACKUP_FINAL
mkdir -m 700 "$CONTROL_WORKSPACE" "$PAYLOAD_WORKSPACE"
backup_log_info(){ :; }
backup_log_warn(){ :; }
log_error(){ printf 'ERROR %s\n' "$*" >&2; }
log_warn(){ :; }
log_debug(){ :; }
get_config_value(){
    case "$1" in
        PROJECT_STATE_DIR) printf '%s\n' "$state" ;;
        BACKUP_DIR) printf '%s\n' "$backup_base" ;;
        DATA_VOLUME_MOUNT|DATA_VOLUME_DEVICE) printf '\n' ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}
_resolve_age_key(){ printf '%s\n' "$key"; }
require_commands(){ return 0; }
create_consistent_db_snapshot(){
    mkdir -p "$(dirname "$2")"
    cp "$state/data/db.sqlite3" "$2"
    DB_SNAPSHOT_METHOD=sqlite-online-backup
    export DB_SNAPSHOT_METHOD
}
verify_sqlite(){ return 0; }
_validate_full_archive_payload(){ return 0; }
secure_file(){ chmod "${2:-600}" "$1"; }
mountpoint(){ return 1; }
verify_file_integrity(){ return 0; }
write_file_integrity(){
    printf 'checksum  %s\n' "$1" > "${1}.sha256"
    chmod 600 "${1}.sha256"
}
create_backup_metadata(){
    local enc="$1" type="$2"
    printf 'backup_type=%s\narchive_format=relative\nversion=2\nencryption_mode=age-recipient\n' "$type" > "${enc}.meta"
    chmod 600 "${enc}.meta"
}

TAR_PLAINTEXT=""
tar(){
    local arg output="" next_is_output=false
    for arg in "$@"; do
        if [[ "$next_is_output" == true ]]; then output="$arg"; next_is_output=false; continue; fi
        [[ "$arg" == -cf ]] && next_is_output=true
    done
    if [[ -n "$output" ]]; then
        dd if=/dev/zero of="$output" bs=1024 count=12 >/dev/null 2>&1
        TAR_PLAINTEXT="$output"
        return 0
    fi
    [[ ! -e "$TAR_PLAINTEXT" ]] || return 91
    cat >/dev/null
    : > "$TMP/tar-stream.called"
    return "${MOCK_TAR_RC:-0}"
}
age(){
    local output="" input="" arg next_is_output=false
    for arg in "$@"; do
        if [[ "$next_is_output" == true ]]; then output="$arg"; next_is_output=false; continue; fi
        [[ "$arg" == -o ]] && { next_is_output=true; continue; }
        [[ "$arg" != -* ]] && input="$arg"
    done
    if [[ -n "$output" ]]; then
        cp "$input" "$output"
        return 0
    fi
    [[ ! -e "$TAR_PLAINTEXT" ]] || return 92
    cat "$input"
    return "${MOCK_AGE_RC:-0}"
}

candidate="" final=""
perform_full_backup "$target" 20990101_000000 age1testrecipient full \
    "$PAYLOAD_WORKSPACE" "$key" candidate final || fail "mocked full backup failed"
[[ "$TAR_PLAINTEXT" == "$PAYLOAD_WORKSPACE/"* ]] || fail "full plaintext archive was not written to payload staging"
[[ ! -e "$TAR_PLAINTEXT" ]] || fail "full plaintext archive remained after encryption"
[[ "$candidate" == "$target/."*'.candidate' && -s "$candidate" ]] || fail "hidden encrypted candidate was not created in final backup filesystem"
[[ -s "$candidate.sha256" && -s "$candidate.meta" ]] || fail "candidate cohort is incomplete"
! find "$target" -maxdepth 1 -name '*.age' -type f -print -quit | grep -q . \
    || fail "discoverable final archive exists before verification and publication"

verify_backup_full "$candidate" full "$PAYLOAD_WORKSPACE" || fail "streaming full verification failed"
[[ -e "$TMP/tar-stream.called" ]] || fail "full verification did not stream into archive listing"
if find "$PAYLOAD_WORKSPACE" -type f \( -name '*.tar' -o -name '*.tar.*' -o -name 'verify_*' \) -print -quit | grep -q .; then
    fail "full verification materialized a second plaintext archive"
fi
_publish_backup_candidate "$candidate" "$final" || fail "candidate publication failed"
[[ -s "$final" && -s "$final.sha256" && -s "$final.meta" ]] || fail "published final cohort is incomplete"
[[ ! -e "$candidate" && "$final" == *.age ]] || fail "archive was not committed by final rename"

conflict_candidate="$target/.conflict.tar.zst.age.candidate"
conflict_final="$target/conflict.tar.zst.age"
printf cipher > "$conflict_candidate"
printf keep > "$conflict_final.meta"
PENDING_BACKUP_CANDIDATE="$conflict_candidate"
PENDING_BACKUP_FINAL=""
if _publish_backup_candidate "$conflict_candidate" "$conflict_final" >/dev/null 2>&1; then
    fail "publication overwrote a pre-existing final cohort member"
fi
_cleanup_unpublished_backup
[[ -f "$conflict_final.meta" && "$(cat "$conflict_final.meta")" == keep ]] \
    || fail "cleanup removed a pre-existing unowned final sidecar"

for fail_move in 1 2 3 4; do
    publish_dir="$target/publish-fail-$fail_move"
    mkdir -p "$publish_dir"
    fail_candidate="$publish_dir/.archive.tar.zst.age.candidate"
    fail_final="$publish_dir/archive.tar.zst.age"
    printf cipher > "$fail_candidate"
    printf meta > "$fail_candidate.meta"
    printf hash > "$fail_candidate.sha256"
    printf hmac > "$fail_candidate.sha256.hmac"
    chmod 600 "$fail_candidate" "$fail_candidate.meta" \
        "$fail_candidate.sha256" "$fail_candidate.sha256.hmac"
    PENDING_BACKUP_CANDIDATE="$fail_candidate"
    PENDING_BACKUP_FINAL=""
    move_count=0
    mv() {
        move_count=$((move_count + 1))
        if (( move_count == fail_move )); then
            return 86
        fi
        command mv "$@"
    }
    if _publish_backup_candidate "$fail_candidate" "$fail_final" >/dev/null 2>&1; then
        unset -f mv
        fail "publication succeeded when rename $fail_move was injected to fail"
    fi
    unset -f mv
    _cleanup_unpublished_backup
    for suffix in "" .meta .sha256 .sha256.hmac; do
        [[ ! -e "${fail_candidate}${suffix}" && ! -L "${fail_candidate}${suffix}" ]] \
            || fail "rename $fail_move left candidate cohort member: ${fail_candidate}${suffix}"
        [[ ! -e "${fail_final}${suffix}" && ! -L "${fail_final}${suffix}" ]] \
            || fail "rename $fail_move left unpublished final cohort member: ${fail_final}${suffix}"
    done
    ! find "$publish_dir" -maxdepth 1 -type f -name '*.age' -print -quit | grep -q . \
        || fail "rename $fail_move exposed a discoverable final archive"
done

dangling_candidate="$target/.full_backup_20990101_000001.tar.zst.age.candidate"
ln -s "$TMP/missing-candidate-target" "$dangling_candidate"
rm -f "$TMP/expensive-work.called"
create_consistent_db_snapshot(){ : > "$TMP/expensive-work.called"; return 1; }
candidate="" final=""
if perform_full_backup "$target" 20990101_000001 age1testrecipient full \
        "$PAYLOAD_WORKSPACE" "$key" candidate final >/dev/null 2>&1; then
    fail "full backup accepted a dangling-symlink candidate path"
fi
[[ ! -e "$TMP/expensive-work.called" ]] \
    || fail "dangling-symlink candidate was rejected after snapshot work"
[[ -L "$dangling_candidate" ]] || fail "candidate preflight removed an unowned dangling symlink"
rm -f "$dangling_candidate"

safe_project="$project"
safe_backup_base="$backup_base"
safe_target="$target"
run_overlap_refusal() {
    local case_name="$1" unsafe_backup_base="$2" unsafe_project_root="$3" timestamp="$4"
    local unsafe_target="$unsafe_backup_base/full" output="$TMP/${case_name}.out"
    rm -f "$TMP/overlap-snapshot.called" "$TMP/overlap-tar.called" "$TMP/overlap-du.called"
    mkdir -p "$unsafe_project_root" "$unsafe_target"
    SCRIPT_DIR="$unsafe_project_root"
    backup_base="$unsafe_backup_base"
    target="$unsafe_target"
    create_consistent_db_snapshot(){ : > "$TMP/overlap-snapshot.called"; return 1; }
    tar(){ : > "$TMP/overlap-tar.called"; return 1; }
    du(){ : > "$TMP/overlap-du.called"; return 1; }
    candidate="" final=""
    if perform_full_backup "$target" "$timestamp" age1testrecipient full \
            "$PAYLOAD_WORKSPACE" "$key" candidate final >"$output" 2>&1; then
        fail "$case_name unsafe BACKUP_DIR layout was accepted"
    fi
    grep -Fq 'Unsafe BACKUP_DIR layout:' "$output" \
        || fail "$case_name refusal did not explain the unsafe BACKUP_DIR relationship"
    grep -Fq 'shared tar exclusion would omit the entire' "$output" \
        || fail "$case_name refusal did not explain the data-protection risk"
    [[ ! -e "$TMP/overlap-du.called" ]] \
        || fail "$case_name refusal occurred after capacity estimation"
    [[ ! -e "$TMP/overlap-snapshot.called" ]] \
        || fail "$case_name refusal occurred after SQLite snapshot work"
    [[ ! -e "$TMP/overlap-tar.called" ]] \
        || fail "$case_name refusal occurred after tar execution"
}

run_overlap_refusal state-equals-backup "$state" "$project" 20990101_000002
project_container="$TMP/project-container"
project_under_backup="$project_container/repository"
run_overlap_refusal backup-contains-project "$project_container" "$project_under_backup" 20990101_000003

run_pre_mutation_source_layout_refusal() (
    set -euo pipefail
    local unsafe_state="$TMP/pre-mutation-state"
    local output="$TMP/pre-mutation-source-layout.out"
    local backup_dir=""
    mkdir -p "$unsafe_state"
    rm -rf -- "$unsafe_state/full" "$unsafe_state"/.vaultwarden-backup.*
    rm -f "$TMP/pre-mutation-source-ensure.called" \
        "$TMP/pre-mutation-source-user.called" \
        "$TMP/pre-mutation-source-payload.called"

    DRY_RUN=true
    SCRIPT_DIR="$safe_project"
    _default_backup_dir(){ printf '%s\n' "$TMP/default-backups"; }
    get_config_value(){
        case "$1" in
            BACKUP_DIR) printf '%s\n' "$unsafe_state" ;;
            *) printf '%s\n' "${2:-}" ;;
        esac
    }
    get_real_user(){
        : > "$TMP/pre-mutation-source-user.called"
        printf 'operator\n'
    }
    ensure_dir(){
        : > "$TMP/pre-mutation-source-ensure.called"
        mkdir -p -- "$1"
        return 0
    }
    _create_owned_workspace(){
        : > "$TMP/pre-mutation-source-payload.called"
        mkdir -p -- "$unsafe_state/.vaultwarden-backup.test"
        return 0
    }

    if backup_dir="$(get_backup_dir full "$unsafe_state" 2>"$output")"; then
        _create_owned_workspace PAYLOAD_WORKSPACE PAYLOAD_WORKSPACE_ID \
            "$(dirname "$backup_dir")" .vaultwarden-backup
        fail "get_backup_dir accepted BACKUP_DIR equal to PROJECT_STATE_DIR"
    fi
    grep -Fq 'Unsafe BACKUP_DIR layout:' "$output" \
        || fail "get_backup_dir source-layout refusal did not explain the unsafe relationship"
    [[ ! -e "$TMP/pre-mutation-source-ensure.called" ]] \
        || fail "get_backup_dir called ensure_dir before rejecting the unsafe backup base"
    [[ ! -e "$TMP/pre-mutation-source-user.called" ]] \
        || fail "get_backup_dir resolved the ownership recipient before rejecting the unsafe backup base"
    [[ ! -e "$TMP/pre-mutation-source-payload.called" ]] \
        || fail "payload workspace creation ran before rejecting the unsafe backup base"
    [[ ! -e "$unsafe_state/full" && ! -L "$unsafe_state/full" ]] \
        || fail "dry-run source-layout refusal created the full backup type directory"
    if compgen -G "$unsafe_state/.vaultwarden-backup.*" >/dev/null; then
        fail "dry-run source-layout refusal created a payload workspace inside PROJECT_STATE_DIR"
    fi
)
run_pre_mutation_source_layout_refusal

run_pre_mutation_target_refusal() (
    set -euo pipefail
    local redirected_base="$TMP/pre-mutation-backups"
    local redirected_target="$state/data/pre-mutation-full-backups"
    local redirected_link="$redirected_base/full"
    local output="$TMP/pre-mutation-target.out"
    local owner_before owner_after
    mkdir -p "$redirected_base" "$redirected_target"
    ln -s "$redirected_target" "$redirected_link"
    owner_before="$(stat -c '%u:%g' "$redirected_target")"
    rm -f "$TMP/pre-mutation-ensure.called" "$TMP/pre-mutation-user.called"

    DRY_RUN=true
    _default_backup_dir(){ printf '%s
' "$TMP/default-backups"; }
    get_config_value(){
        case "$1" in
            BACKUP_DIR) printf '%s
' "$redirected_base" ;;
            *) printf '%s
' "${2:-}" ;;
        esac
    }
    get_real_user(){
        : > "$TMP/pre-mutation-user.called"
        printf 'operator
'
    }
    ensure_dir(){
        : > "$TMP/pre-mutation-ensure.called"
        return 0
    }

    if get_backup_dir full "$state" >"$output" 2>&1; then
        fail "get_backup_dir accepted an escaping full-directory symlink"
    fi
    grep -Fq 'Backup type directory resolves outside configured BACKUP_DIR:' "$output" \
        || fail "get_backup_dir refusal did not explain the containment failure"
    [[ ! -e "$TMP/pre-mutation-ensure.called" ]] \
        || fail "get_backup_dir called ensure_dir before rejecting the escaping target"
    [[ ! -e "$TMP/pre-mutation-user.called" ]] \
        || fail "get_backup_dir resolved the ownership recipient before rejecting the escaping target"
    owner_after="$(stat -c '%u:%g' "$redirected_target")"
    [[ "$owner_after" == "$owner_before" ]] \
        || fail "dry-run target refusal changed ownership of the symlink target"
    [[ -L "$redirected_link" ]] \
        || fail "dry-run target refusal replaced or removed the configured symlink"
)
run_pre_mutation_target_refusal

run_tier_alias_refusal() (
    set -euo pipefail
    local alias_base="$TMP/tier-alias-backups"
    local alias_target="$alias_base/db"
    local alias_link="$alias_base/full"
    local output="$TMP/tier-alias.out"
    local backup_dir="" alias_candidate="" alias_final=""
    local marker
    mkdir -p "$alias_target"
    ln -s "$alias_target" "$alias_link"
    rm -f "$TMP"/tier-alias-*.called

    DRY_RUN=true
    SCRIPT_DIR="$safe_project"
    _default_backup_dir(){ printf '%s\n' "$TMP/default-backups"; }
    get_config_value(){
        case "$1" in
            BACKUP_DIR) printf '%s\n' "$alias_base" ;;
            PROJECT_STATE_DIR) printf '%s\n' "$state" ;;
            *) printf '%s\n' "${2:-}" ;;
        esac
    }
    get_real_user(){ : > "$TMP/tier-alias-user.called"; printf 'operator\n'; }
    ensure_dir(){ : > "$TMP/tier-alias-ensure.called"; return 0; }
    _create_owned_workspace(){ : > "$TMP/tier-alias-workspace.called"; return 0; }
    _preflight_backup_payload_capacity(){ : > "$TMP/tier-alias-capacity.called"; return 1; }
    create_consistent_db_snapshot(){ : > "$TMP/tier-alias-snapshot.called"; return 1; }
    tar(){ : > "$TMP/tier-alias-tar.called"; return 1; }
    cleanup_old_backups(){ : > "$TMP/tier-alias-retention.called"; }

    if backup_dir="$(get_backup_dir full "$state" 2>"$output")"; then
        _create_owned_workspace PAYLOAD_WORKSPACE PAYLOAD_WORKSPACE_ID \
            "$(dirname "$backup_dir")" .vaultwarden-backup
        if perform_full_backup "$backup_dir" 20990101_000005 age1testrecipient full \
                "$PAYLOAD_WORKSPACE" "$key" alias_candidate alias_final; then
            cleanup_old_backups "$backup_dir" full
        fi
        fail "get_backup_dir accepted full redirected to the db tier"
    fi
    grep -Fq "Backup type directory must not be redirected: $alias_link" "$output" \
        || fail "tier-alias refusal did not explain the redirected direct child"

    if perform_full_backup "$alias_link" 20990101_000006 age1testrecipient full \
            "$PAYLOAD_WORKSPACE" "$key" alias_candidate alias_final >"$output.direct" 2>&1; then
        cleanup_old_backups "$alias_target" full
        fail "perform_full_backup accepted full redirected to the db tier"
    fi
    grep -Fq "Backup type directory must not be redirected: $alias_link" "$output.direct" \
        || fail "defense-in-depth tier-alias refusal did not explain the redirected direct child"

    [[ -z "$alias_candidate" && -z "$alias_final" ]] \
    || fail "tier-alias refusal populated backup output paths"
    for marker in user ensure workspace capacity snapshot tar retention; do
        [[ ! -e "$TMP/tier-alias-${marker}.called" ]] \
            || fail "tier-alias refusal reached ${marker} work"
    done
    [[ -L "$alias_link" && "$(realpath -m -- "$alias_link")" == "$alias_target" ]] \
        || fail "tier-alias refusal altered the configured full symlink"
)
run_tier_alias_refusal

run_redirected_target_refusal() {
    local redirected_base="$TMP/redirected-backups"
    local redirected_target="$state/data/full-backups"
    local redirected_link="$redirected_base/full"
    local output="$TMP/redirected-target.out"
    rm -f "$TMP/redirected-snapshot.called" "$TMP/redirected-tar.called" "$TMP/redirected-du.called"
    mkdir -p "$redirected_base" "$redirected_target"
    ln -s "$redirected_target" "$redirected_link"
    SCRIPT_DIR="$safe_project"
    backup_base="$redirected_base"
    target="$redirected_link"
    create_consistent_db_snapshot(){ : > "$TMP/redirected-snapshot.called"; return 1; }
    tar(){ : > "$TMP/redirected-tar.called"; return 1; }
    du(){ : > "$TMP/redirected-du.called"; return 1; }
    candidate="" final=""
    if perform_full_backup "$target" 20990101_000004 age1testrecipient full \
            "$PAYLOAD_WORKSPACE" "$key" candidate final >"$output" 2>&1; then
        fail "redirected per-type backup directory was accepted"
    fi
    grep -Fq 'Backup type directory resolves outside configured BACKUP_DIR:' "$output" \
        || fail "redirected target refusal did not explain the containment failure"
    grep -Fq "$redirected_target" "$output" \
        || fail "redirected target refusal did not report the canonical target"
    [[ ! -e "$TMP/redirected-du.called" ]] \
        || fail "redirected target refusal occurred after capacity estimation"
    [[ ! -e "$TMP/redirected-snapshot.called" ]] \
        || fail "redirected target refusal occurred after SQLite snapshot work"
    [[ ! -e "$TMP/redirected-tar.called" ]] \
        || fail "redirected target refusal occurred after tar execution"
}
run_redirected_target_refusal
unset -f du tar
SCRIPT_DIR="$safe_project"
backup_base="$safe_backup_base"
target="$safe_target"

rm -f "$TMP/expensive-work.called"
df(){
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nmock 100 99 1 99%% /\n'
}
create_consistent_db_snapshot(){ : > "$TMP/expensive-work.called"; return 0; }
candidate="" final=""
if perform_full_backup "$target" 20990101_000001 age1testrecipient full \
        "$PAYLOAD_WORKSPACE" "$key" candidate final >/dev/null 2>&1; then
    fail "full backup continued after insufficient-space preflight"
fi
unset -f df
[[ ! -e "$TMP/expensive-work.called" ]] || fail "insufficient-space failure occurred after DB snapshot work"

check_target_capacity_routing() (
    set -euo pipefail
    local calls="$TMP/target-capacity.calls"
    : > "$calls"
    _workspace_identity() {
        case "$1" in
            "$PAYLOAD_WORKSPACE") printf '101:1\n' ;;
            "$target") printf '202:2\n' ;;
            *) fail "capacity routing inspected an unexpected path: $1" ;;
        esac
    }
    _stat_file_size(){ printf '0\n'; }
    du(){ printf '10\n'; }
    check_backup_disk_space(){ printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$calls"; }

    _preflight_backup_payload_capacity \
        "$state" "$backup_base" full "$project" "$PAYLOAD_WORKSPACE" "$target" \
        || fail "split-filesystem capacity preflight failed"

    mapfile -t capacity_paths < <(cut -d'|' -f1 "$calls")
    [[ ${#capacity_paths[@]} -eq 2 ]] \
        || fail "split-filesystem capacity preflight did not make exactly two checks"
    [[ "${capacity_paths[0]}" == "$PAYLOAD_WORKSPACE" ]] \
        || fail "payload capacity was not checked on the payload filesystem"
    [[ "${capacity_paths[1]}" == "$target" ]] \
        || fail "encrypted output capacity was not checked on the canonical target filesystem"
    grep -Fq 'full backup archive and payload staging' "$calls" \
        || fail "payload capacity check used the wrong purpose"
    grep -Fq 'encrypted full backup output' "$calls" \
        || fail "target capacity check used the wrong purpose"
)
check_target_capacity_routing

truncate -s 128M "$backup_base/old-backup.age"
source_mb="$(_backup_estimated_source_mb "$project" "$state" "$backup_base" "$PAYLOAD_WORKSPACE")"
[[ "$source_mb" =~ ^[0-9]+$ ]] || fail "GNU du capacity estimate is not numeric"
(( source_mb < 64 )) || fail "GNU du estimate traversed the excluded backup tree"

estimate_project="$TMP/restore-estimate-project"
estimate_state="$estimate_project/state"
estimate_backup="$estimate_state/backups"
estimate_payload="$estimate_backup/.vaultwarden-backup.current"
estimate_residue_dirs=(
    "$estimate_state/.vaultwarden-restore-payload.mounted"
    "$estimate_project/.state.restore-payload.boot"
    "$estimate_project/state.restore-workspace.promotion"
    "$estimate_project/state.restore-staged.legacy"
)
mkdir -p "$estimate_state/data" "$estimate_payload"
printf included > "$estimate_state/data/keep.txt"
for residue_dir in "${estimate_residue_dirs[@]}"; do
    mkdir -p "$residue_dir"
    truncate -s 128M "$residue_dir/large-residue.bin"
done
source_mb="$(_backup_estimated_source_mb \
    "$estimate_project" "$estimate_state" "$estimate_backup" "$estimate_payload")"
[[ "$source_mb" =~ ^[0-9]+$ ]] || fail "restore-residue GNU du estimate is not numeric"
(( source_mb < 64 )) \
    || fail "GNU du estimate counted crash-residual restore workspaces"

grep -Fq '_create_owned_workspace PAYLOAD_WORKSPACE PAYLOAD_WORKSPACE_ID /dev/shm .vaultwarden-emergency' "$BACKUP" \
    || fail "emergency payload staging is not constrained to /dev/shm"
grep -Fq 'Refusing to place an unencrypted secret-bearing emergency archive on persistent disk.' "$BACKUP" \
    || fail "emergency persistent-disk refusal is missing"

printf 'PASS: real du/df preflight, hidden candidate, plaintext removal, streaming verification, and final commit point\n'
)

check_backup_payload_candidate_and_capacity_contracts

check_backup_candidate_signal_cleanup() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
BACKUP="$ROOT/utilities/backup-run.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat > "$TMP/candidate-signal-probe.sh" <<EOF_PROBE
#!/usr/bin/env bash
set -Eeuo pipefail
$(_extract_shell_function "$BACKUP" _discard_backup_cohort)
$(_extract_shell_function "$BACKUP" _cleanup_unpublished_backup)
$(_extract_shell_function "$BACKUP" cleanup)
$(_extract_shell_function "$BACKUP" _backup_signal_exit)
_db_snapshot_restart_if_needed(){ :; }
operation_release(){ printf '%s\n' "\${1:-0}" >> "\$PROBE_DIR/releases"; }
_remove_owned_workspace(){ :; }
log_error(){ :; }
CONTROL_WORKSPACE=""; CONTROL_WORKSPACE_ID=""; PAYLOAD_WORKSPACE=""; PAYLOAD_WORKSPACE_ID=""
PENDING_BACKUP_CANDIDATE="\$PROBE_DIR/.backup.tar.zst.age.candidate"
PENDING_BACKUP_FINAL=""
FINAL_ARCHIVE="\$PROBE_DIR/backup.tar.zst.age"
printf cipher > "\$PENDING_BACKUP_CANDIDATE"
case "\$PROBE_PHASE" in
    after-encryption|after-plaintext) ;;
    after-sidecar|during-verification)
        printf meta > "\$PENDING_BACKUP_CANDIDATE.meta"
        printf hash > "\$PENDING_BACKUP_CANDIDATE.sha256"
        ;;
    before-publication)
        PENDING_BACKUP_FINAL="\$FINAL_ARCHIVE"
        printf meta > "\$FINAL_ARCHIVE.meta"
        printf hash > "\$FINAL_ARCHIVE.sha256"
        ;;
esac
trap cleanup EXIT
trap '_backup_signal_exit 130' INT
trap '_backup_signal_exit 129' HUP
trap '_backup_signal_exit 143' TERM
case "\$PROBE_TRIGGER" in
    INT|HUP|TERM) kill "-\$PROBE_TRIGGER" "\$BASHPID" ;;
    ERR) false ;;
    FAILURE) exit 47 ;;
esac
exit 99
EOF_PROBE
chmod 700 "$TMP/candidate-signal-probe.sh"

run_candidate_cleanup_probe() {
    local phase="$1" trigger="$2" expected="$3" rc=0
    local phase_dir="$TMP/$phase-$trigger"
    mkdir -p "$phase_dir"
    PROBE_DIR="$phase_dir" PROBE_PHASE="$phase" PROBE_TRIGGER="$trigger" \
        bash "$TMP/candidate-signal-probe.sh" || rc=$?
    [[ "$rc" == "$expected" ]] || fail "$phase/$trigger cleanup returned $rc instead of $expected"
    ! find "$phase_dir" -maxdepth 1 -type f ! -name releases -print -quit | grep -q . \
        || fail "$phase/$trigger left candidate or unpublished sidecars behind"
    [[ "$(cat "$phase_dir/releases")" == "$expected" ]] \
        || fail "$phase/$trigger did not preserve failure status during release"
}

for phase in after-encryption after-plaintext after-sidecar during-verification before-publication; do
    run_candidate_cleanup_probe "$phase" TERM 143
done
run_candidate_cleanup_probe after-sidecar INT 130
run_candidate_cleanup_probe after-sidecar HUP 129
run_candidate_cleanup_probe after-sidecar ERR 1
run_candidate_cleanup_probe after-sidecar FAILURE 47

printf 'PASS: INT/TERM/HUP, shell errors, and normal failure clean unpublished candidate state\n'
)

check_backup_candidate_signal_cleanup

check_backup_verification_pipeline_statuses() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
BACKUP="$ROOT/utilities/backup-run.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
backup_log_info(){ :; }
log_error(){ printf 'ERROR %s\n' "$*" >&2; }
get_config_value(){ printf '%s\n' "${2:-}"; }
eval "$(_extract_shell_function "$BACKUP" _verify_encrypted_archive_stream)"
CONTROL_WORKSPACE="$TMP/control"
mkdir -p "$CONTROL_WORKSPACE"
key="$TMP/key.txt"
archive="$TMP/.full-test.tar.zst.age.candidate"
printf key > "$key"
dd if=/dev/zero of="$archive" bs=1024 count=12 >/dev/null 2>&1

age(){ cat "${@: -1}"; return "${MOCK_AGE_RC:-0}"; }
tar(){ cat >/dev/null; return "${MOCK_TAR_RC:-0}"; }

_verify_encrypted_archive_stream "$archive" full age-recipient "$key" \
    || fail "verification pipeline rejected two successful components"
if MOCK_AGE_RC=17 MOCK_TAR_RC=0 \
    _verify_encrypted_archive_stream "$archive" full age-recipient "$key" >"$TMP/age-fail.out" 2>&1; then
    fail "verification pipeline ignored Age failure"
fi
grep -Fq 'age decryption exited 17' "$TMP/age-fail.out" || fail "real Age component status was not reported"
if MOCK_AGE_RC=0 MOCK_TAR_RC=23 \
    _verify_encrypted_archive_stream "$archive" full age-recipient "$key" >"$TMP/tar-fail.out" 2>&1; then
    fail "verification pipeline ignored archive-tool failure"
fi
grep -Fq 'archive listing exited 23' "$TMP/tar-fail.out" || fail "real archive component status was not reported"

printf 'PASS: streaming verification preserves both pipeline component statuses\n'
)

check_backup_verification_pipeline_statuses

check_backup_real_streaming_archive() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
BACKUP="$ROOT/utilities/backup-run.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for command_name in age age-keygen zstd tar sha256sum; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'SKIP real streaming archive verification: %s is unavailable\n' "$command_name"
        exit 0
    fi
done

for function_name in \
    _validate_emergency_restore_metadata _verify_encrypted_archive_stream \
    verify_backup_full; do
    eval "$(_extract_shell_function "$BACKUP" "$function_name")"
done

backup_log_info(){ :; }
backup_log_warn(){ :; }
log_error(){ printf 'ERROR %s\n' "$*" >&2; }
log_warn(){ :; }
get_config_value(){ printf '%s\n' "${2:-}"; }
verify_file_integrity(){
    local expected actual
    expected="$(cat "${1}.sha256")"
    actual="$(sha256sum "$1" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]]
}

CONTROL_WORKSPACE="$TMP/control"
mkdir -m 700 "$CONTROL_WORKSPACE" "$TMP/payload"
key="$TMP/key.txt"
age-keygen -o "$key" >/dev/null 2>&1
chmod 600 "$key"
recipient="$(age-keygen -y "$key")"
_resolve_age_key(){ printf '%s\n' "$key"; }

dd if=/dev/urandom of="$TMP/payload/content.bin" bs=1024 count=32 status=none
tar --use-compress-program='zstd --no-progress -T0 -3' \
    -cf "$TMP/full-real.tar.zst" -C "$TMP/payload" .
candidate="$TMP/.full-real.tar.zst.age.candidate"
age -r "$recipient" -o "$candidate" "$TMP/full-real.tar.zst"
chmod 600 "$candidate"
sha256sum "$candidate" | awk '{print $1}' > "$candidate.sha256"
printf 'backup_type=full\narchive_format=relative\nversion=2\nencryption_mode=age-recipient\n' > "$candidate.meta"
chmod 600 "$candidate.sha256" "$candidate.meta"
REQUIRE_AUTHENTICATED_INTEGRITY=false
export REQUIRE_AUTHENTICATED_INTEGRITY

verify_backup_full "$candidate" full "" || fail "real Age-to-zstd/tar streaming verification failed"
printf 'PASS: real Age-to-zstd/tar full archive verification\n'
)

check_backup_real_streaming_archive

check_backup_offline_snapshot_signal_cleanup() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
BACKUP="$ROOT/utilities/backup-run.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat > "$TMP/signal-probe.sh" <<EOF_PROBE
#!/usr/bin/env bash
set -Eeuo pipefail
$(_extract_shell_function "$BACKUP" _workspace_identity)
$(_extract_shell_function "$BACKUP" _remove_owned_workspace)
$(_extract_shell_function "$BACKUP" _create_owned_workspace)
$(_extract_shell_function "$BACKUP" _discard_backup_cohort)
$(_extract_shell_function "$BACKUP" _cleanup_unpublished_backup)
$(_extract_shell_function "$BACKUP" cleanup)
$(_extract_shell_function "$BACKUP" _backup_signal_exit)
$(_extract_shell_function "$BACKUP" _db_snapshot_restart_if_needed)
$(_extract_shell_function "$BACKUP" create_consistent_db_snapshot)

state="\$PROBE_TMP/state"
backup_base="\$PROBE_TMP/backups"
mkdir -p "\$state/data" "\$backup_base"
printf db > "\$state/data/db.sqlite3"
backup_log_info(){ :; }
backup_log_warn(){ :; }
log_error(){ printf 'ERROR %s\n' "\$*" >&2; }
get_config_value(){ [[ "\$1" == COMPOSE_SERVICE_NAME ]] && printf '%s\n' vaultwarden || printf '%s\n' "\${2:-}"; }
create_db_snapshot_host(){ return 1; }
verify_sqlite(){ return 0; }
_vaultwarden_container_running(){ return 0; }
wait_for_container_stopped(){ kill "-\$PROBE_SIGNAL" "\$BASHPID"; return 1; }
sqlite3(){ printf '0|0|0\n'; }
docker(){ printf '%s\n' "docker \$*" >> "\$PROBE_TMP/docker.calls"; return 0; }
operation_release(){ printf '%s\n' "\${1:-0}" >> "\$PROBE_TMP/releases"; }
CONTROL_WORKSPACE=""; CONTROL_WORKSPACE_ID=""; PAYLOAD_WORKSPACE=""; PAYLOAD_WORKSPACE_ID=""
PENDING_BACKUP_CANDIDATE=""; PENDING_BACKUP_FINAL=""
_create_owned_workspace CONTROL_WORKSPACE CONTROL_WORKSPACE_ID /dev/shm vw-backup-control true
_create_owned_workspace PAYLOAD_WORKSPACE PAYLOAD_WORKSPACE_ID "\$backup_base" .vaultwarden-backup
printf '%s\n' "\$CONTROL_WORKSPACE" > "\$PROBE_TMP/control.path"
printf '%s\n' "\$PAYLOAD_WORKSPACE" > "\$PROBE_TMP/payload.path"
trap cleanup EXIT
trap '_backup_signal_exit 130' INT
trap '_backup_signal_exit 129' HUP
trap '_backup_signal_exit 143' TERM
create_consistent_db_snapshot "\$state" "\$PAYLOAD_WORKSPACE/db.sqlite3" signal-test
exit 99
EOF_PROBE
chmod 700 "$TMP/signal-probe.sh"

for signal in INT TERM; do
    case_dir="$TMP/$signal"
    mkdir -p "$case_dir"
    rc=0
    PROBE_TMP="$case_dir" PROBE_SIGNAL="$signal" bash "$TMP/signal-probe.sh" >"$case_dir/out" 2>&1 || rc=$?
    expected=130
    [[ "$signal" == TERM ]] && expected=143
    [[ "$rc" == "$expected" ]] || { cat "$case_dir/out" >&2; fail "$signal expected exit $expected, got $rc"; }
    [[ "$(grep -c 'docker compose start vaultwarden' "$case_dir/docker.calls")" == 1 ]] \
        || fail "$signal did not restart Vaultwarden exactly once"
    [[ "$(grep -c 'docker compose stop vaultwarden' "$case_dir/docker.calls")" == 1 ]] \
        || fail "$signal did not reach the offline stop boundary"
    [[ "$(wc -l < "$case_dir/releases" | tr -d '[:space:]')" == 1 ]] \
        || fail "$signal did not release the operation guard exactly once"
    grep -Fxq "$expected" "$case_dir/releases" || fail "$signal release did not preserve signal status"
    control_path="$(cat "$case_dir/control.path")"
    payload_path="$(cat "$case_dir/payload.path")"
    [[ ! -e "$control_path" && ! -e "$payload_path" ]] || fail "$signal left owned staging behind"
done

printf 'PASS: INT/TERM offline fallback restarts once, preserves status, releases, and cleans staging\n'
)

check_backup_offline_snapshot_signal_cleanup

check_deep_maintenance_safety_backup_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

prepare_case() {
    local case_dir="$1"
    mkdir -p "$case_dir/repo/utilities" "$case_dir/project/utilities" \
        "$case_dir/state/data" "$case_dir/backups/db" "$case_dir/bin"
    ln -s "$ROOT/lib" "$case_dir/repo/lib"
    cp "$ROOT/utilities/maintenance-db-maint.sh" "$case_dir/repo/utilities/maintenance-db-maint.sh"
    sed -i.bak 's/^main "\$@"$/: # test harness: do not auto-run main/' \
        "$case_dir/repo/utilities/maintenance-db-maint.sh"
    rm -f "$case_dir/repo/utilities/maintenance-db-maint.sh.bak"
    printf 'SQLite format 3\000' > "$case_dir/state/data/db.sqlite3"

    cat > "$case_dir/project/utilities/backup-run.sh" <<'MOCK_BACKUP'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "run db" ]] || exit 90
if [[ "${BACKUP_BEHAVIOR:-success}" == "fail" ]]; then
    printf 'mock backup failure\n' >&2
    exit 19
fi
archive="${BACKUP_DIR}/db/db_backup_20990101_000000.sqlite3.age"
printf 'new safety backup\n' > "$archive"
printf 'sha\n' > "${archive}.sha256"
printf 'hmac\n' > "${archive}.sha256.hmac"
printf 'meta\n' > "${archive}.meta"
MOCK_BACKUP
    chmod +x "$case_dir/project/utilities/backup-run.sh"

    cat > "$case_dir/bin/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${ACTION_LOG:?}"
exit 0
MOCK_DOCKER
    cat > "$case_dir/bin/sqlite3" <<'MOCK_SQLITE3'
#!/usr/bin/env bash
printf 'sqlite3 %s\n' "$*" >> "${ACTION_LOG:?}"
case "$*" in
    *integrity_check*) printf 'ok\n' ;;
esac
exit 0
MOCK_SQLITE3
    chmod +x "$case_dir/bin/docker" "$case_dir/bin/sqlite3"
}

run_case() {
    local case_dir="$1" backup_behavior="$2" health_ready="$3" output_file="$4"
    (
        set +e
        # The sourced script parses its own CLI at file scope. Clear run_case's
        # fixture arguments so they are not mistaken for db-maint options.
        set --
        # shellcheck source=/dev/null
        source "$case_dir/repo/utilities/maintenance-db-maint.sh"
        PROJECT_ROOT="$case_dir/project"
        PROJECT_STATE_DIR="$case_dir/state"
        BACKUP_DIR="$case_dir/backups"
        DB_DEEP_FORCE=true
        DRY_RUN=false
        BACKUP_BEHAVIOR="$backup_behavior"
        HEALTH_READY="$health_ready"
        ACTION_LOG="$case_dir/actions.log"
        PATH="$case_dir/bin:$PATH"
        export PROJECT_ROOT PROJECT_STATE_DIR BACKUP_DIR DB_DEEP_FORCE DRY_RUN
        export BACKUP_BEHAVIOR HEALTH_READY ACTION_LOG PATH
        is_root(){ return 0; }
        require_commands(){ return 0; }
        require_docker(){ return 0; }
        is_service_running(){ return 1; }
        _wait_wal_quiesce(){ return 0; }
        wait_for_service_ready(){ [[ "$HEALTH_READY" == "true" ]]; }
        run_deep_db_maintenance
    ) >"$output_file" 2>&1
}

failure_case="$TMP/backup-failure"
prepare_case "$failure_case"
: > "$failure_case/actions.log"
failure_rc=0
run_case "$failure_case" fail true "$failure_case/output" || failure_rc=$?
(( failure_rc != 0 )) || fail "--force deep maintenance continued after safety-backup failure"
grep -Fq 'Pre-maintenance safety backup failed; refusing deep database maintenance.' "$failure_case/output" \
    || fail "backup failure did not report truthful fail-closed output"
[[ ! -s "$failure_case/actions.log" ]] \
    || { cat "$failure_case/actions.log" >&2; fail "backup failure reached Docker or SQLite mutation under --force"; }

success_case="$TMP/success"
prepare_case "$success_case"
old_archive="$success_case/backups/db/db_backup_20000101_000000.sqlite3.age"
for suffix in '' .sha256 .sha256.hmac .meta; do
    printf 'older retained backup\n' > "${old_archive}${suffix}"
done
: > "$success_case/actions.log"
run_case "$success_case" success true "$success_case/output" \
    || { cat "$success_case/output" >&2; fail "successful maintenance fixture failed"; }
new_archive="$success_case/backups/db/db_backup_20990101_000000.sqlite3.age"
for suffix in '' .sha256 .sha256.hmac .meta; do
    [[ ! -e "${new_archive}${suffix}" ]] \
        || fail "successful maintenance retained temporary safety-backup member: ${new_archive}${suffix}"
    [[ -e "${old_archive}${suffix}" ]] \
        || fail "successful maintenance removed older retained backup member: ${old_archive}${suffix}"
done

incomplete_case="$TMP/incomplete"
prepare_case "$incomplete_case"
: > "$incomplete_case/actions.log"
incomplete_rc=0
run_case "$incomplete_case" success false "$incomplete_case/output" || incomplete_rc=$?
(( incomplete_rc != 0 )) || fail "unhealthy post-maintenance fixture unexpectedly succeeded"
retained_archive="$incomplete_case/backups/db/db_backup_20990101_000000.sqlite3.age"
for suffix in '' .sha256 .sha256.hmac .meta; do
    [[ -e "${retained_archive}${suffix}" ]] \
        || fail "incomplete maintenance removed safety-backup member: ${retained_archive}${suffix}"
done
grep -Fq 'Maintenance did not complete successfully. Retaining safety backup:' "$incomplete_case/output" \
    || fail "incomplete maintenance did not report retained safety backup"

printf 'PASS: deep maintenance fails closed and cleans only its successful safety-backup cohort\n'
)

check_deep_maintenance_safety_backup_contracts

check_backup_remote_keep_scope() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
BACKUP="$ROOT/utilities/backup-run.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

_extract_func(){
  local file="$1" func="$2"
  awk -v f="$func" '
    $0 ~ "^" f "\\(\\)" {p=1}
    p {
      print
      opens=gsub(/\{/,"{"); closes=gsub(/\}/,"}")
      depth += opens - closes
      if (depth == 0) exit
    }' "$file"
}

cat > "$TMP/remote-keep-scope-probe.sh" <<EOF_PROBE
set -euo pipefail
CONTROL_WORKSPACE="$TMP/work"
mkdir -p "\$CONTROL_WORKSPACE"
KEEP_DAYS=7
DRY_RUN=false
RETENTION_LOG="$TMP/retention.log"
backup_log_info(){ :; }
backup_log_success(){ :; }
backup_log_warn(){ :; }
log_warn(){ :; }
log_error(){ printf 'ERROR:%s\\n' "\$*" >&2; }
get_config_value(){
    case "\$1" in
        RCLONE_REMOTE_NAME) printf '%s\\n' mockremote ;;
        RCLONE_REMOTE_PATH) printf '%s\\n' vaultwarden_backups ;;
        *) printf '%s\\n' "\${2:-}" ;;
    esac
}
_resolve_rclone_config_arg(){ local -n _out="\$1"; _out=(); }
backup_retention_days_for_type(){
    local backup_type="\$1" explicit_override="\${2:-}"
    printf '%s=%s\\n' "\$backup_type" "\$explicit_override" >> "\$RETENTION_LOG"
    printf '%s\\n' "\${explicit_override:-99}"
}
rclone(){
    [[ "\${1:-}" == "lsf" ]] && return 0
    return 0
}
$(_extract_func "$BACKUP" _prune_remote_backups)
case "\${1:-}" in
    typed) _prune_remote_backups db ;;
    all) _prune_remote_backups ;;
    *) exit 64 ;;
esac
EOF_PROBE

grep -Fq '_prune_remote_backups "$actual_type"' "$BACKUP" \
    || fail "backup run does not scope remote --keep retention to actual_type"

: > "$TMP/retention.log"
bash "$TMP/remote-keep-scope-probe.sh" typed
for expected in 'db=7' 'full=' 'emergency='; do
    grep -Fxq "$expected" "$TMP/retention.log" \
        || fail "typed run remote retention scope missing: $expected"
done
[[ "$(grep -c '=7$' "$TMP/retention.log" || true)" == "1" ]] \
    || fail "typed run applied --keep to more than its selected remote tier"

: > "$TMP/retention.log"
bash "$TMP/remote-keep-scope-probe.sh" all
for expected in 'db=7' 'full=7' 'emergency=7'; do
    grep -Fxq "$expected" "$TMP/retention.log" \
        || fail "sync/rotate all-tier retention scope missing: $expected"
done
[[ "$(grep -c '=7$' "$TMP/retention.log" || true)" == "3" ]] \
    || fail "sync/rotate did not apply --keep to every remote tier"

printf 'PASS: backup run scopes remote --keep while sync/rotate remain all-tier\n'
)

check_backup_remote_keep_scope

check_backup_run_dry_run_completion() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
BACKUP="$ROOT/utilities/backup-run.sh"
fail(){ echo "FAIL: $*" >&2; exit 1; }

validation_block="$(awk '
    /local backup_file=""/ {capture=1}
    capture {print}
    capture && /if \[\[ "\$backup_success" == "true" && "\$DRY_RUN" == "false" \]\]; then/ {exit}
' "$BACKUP")"

grep -Fq 'if [[ "$backup_success" == "true" && "$DRY_RUN" == "false" ]]; then' <<< "$validation_block" \
    || fail "backup archive validation is not guarded from dry-run mode"
! grep -Fq 'if [[ "$backup_success" == "true" ]]; then' <<< "$validation_block" \
    || fail "backup run still validates a real archive path during dry-run"
grep -Fq 'elif [[ "$DRY_RUN" == "true" ]]; then' "$BACKUP" \
    || fail "backup run dry-run completion branch is missing"
grep -Fq 'backup_log_success "Dry run completed"' "$BACKUP" \
    || fail "backup run dry-run success message is missing"

printf 'PASS: backup run dry-run bypasses real archive validation and completes\n'
)

check_backup_run_dry_run_completion


check_standalone_db_verifier_symlink_base() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
BACKUP="$ROOT/utilities/backup-run.sh"
UTILS="$ROOT/lib/backup-utils.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

backup_target="$TMP/backup-target"
configured_backup="$TMP/configured-backup"
archive="$backup_target/db/db_backup_20990101_000000.sqlite3.age"
mkdir -p "$backup_target/db"
ln -s "$backup_target" "$configured_backup"
printf 'encrypted-db' > "$archive"
printf 'identity' > "$TMP/key.txt"

extract_function() {
    local file="$1" function_name="$2"
    awk -v function_name="$function_name" '
        $0 ~ "^" function_name "\\(\\)" { printing=1 }
        printing {
            print
            opens=gsub(/\{/, "{")
            closes=gsub(/\}/, "}")
            depth += opens - closes
            if (depth == 0) exit
        }
    ' "$file"
}

extract_verify_body() {
    awk '
        /^[[:space:]]*if \[\[ "\$_SUBCMD" == "verify" \]\]; then[[:space:]]*$/ {
            printing=1
            next
        }
        printing && /^[[:space:]]*if \[\[ "\$_SUBCMD" == "sync" \]\]; then[[:space:]]*$/ {
            exit
        }
        printing { lines[++count]=$0 }
        END {
            while (count > 0 && lines[count] ~ /^[[:space:]]*$/) count--
            if (count > 0 && lines[count] ~ /^[[:space:]]*fi[[:space:]]*$/) count--
            for (i=1; i <= count; i++) print lines[i]
        }
    ' "$BACKUP"
}

probe="$TMP/standalone-db-verify-probe.sh"
{
    cat <<EOF_PROBE
set -euo pipefail
TMP='$TMP'
SCRIPT_DIR='$ROOT'
PROJECT_ROOT='$ROOT'
BACKUP_TYPE=db
_SUBCMD=verify
DRY_RUN=false
QUIET=false
CONTROL_WORKSPACE=''
CONTROL_WORKSPACE_ID=''
PAYLOAD_WORKSPACE=''
PAYLOAD_WORKSPACE_ID=''
PENDING_BACKUP_CANDIDATE=''
PENDING_BACKUP_FINAL=''
DB_SNAPSHOT_STOPPED_CONTAINER=false
DB_SNAPSHOT_RESTARTED=false
backup_log_info(){ printf 'INFO: %s\\n' "\$*"; }
backup_log_success(){ printf 'SUCCESS: %s\\n' "\$*"; }
backup_log_warn(){ printf 'WARN: %s\\n' "\$*"; }
log_error(){ printf 'ERROR: %s\\n' "\$*" >&2; }
log_header(){ :; }
backup_require_root(){ :; }
require_root(){ :; }
auto_fix_critical_permissions(){ :; }
load_env_file(){ :; }
_load_integrity_hmac_key(){ :; }
_check_backup_deps(){ :; }
require_project_state_ready(){ :; }
operation_set_phase(){ :; }
_db_snapshot_restart_if_needed(){ :; }
_cleanup_unpublished_backup(){ :; }
operation_release(){ :; }
_default_backup_dir(){ printf '%s\\n' '$TMP/default-backups'; }
get_config_value(){
    case "\$1" in
        BACKUP_DIR) printf '%s\\n' '$configured_backup' ;;
        *) printf '%s\\n' "\${2:-}" ;;
    esac
}
_resolve_age_key(){ printf '%s\\n' '$TMP/key.txt'; }
verify_backup_full(){
    local enc_file="\$1" enc_type="\$2" workspace="\$3"
    [[ "\$enc_file" == '$archive' ]] || {
        log_error "standalone verifier selected an unexpected archive: \$enc_file"
        return 1
    }
    [[ "\$enc_type" == db ]] || {
        log_error "standalone verifier selected an unexpected type: \$enc_type"
        return 1
    }
    [[ "\$workspace" == '$backup_target'/.vaultwarden-backup.* ]] || {
        log_error "DB verification workspace is not on the canonical backup target: \$workspace"
        return 1
    }
    [[ "\$workspace" != /dev/shm/* ]] || {
        log_error "DB verification workspace was incorrectly placed on /dev/shm: \$workspace"
        return 1
    }
    printf '%s\\n' "\$workspace" > '$TMP/payload-workspace.path'
    stat -c '%d' "\$workspace" > '$TMP/payload-workspace.device'
    printf 'decrypted-db' > "\$workspace/verify-db.sqlite3"
    printf '%s\\n' "\$workspace/verify-db.sqlite3" > '$TMP/decrypted-db.path'
    [[ -s "\$workspace/verify-db.sqlite3" ]]
}
EOF_PROBE
    extract_function "$BACKUP" _workspace_identity
    extract_function "$BACKUP" _remove_owned_workspace
    extract_function "$BACKUP" _create_owned_workspace
    extract_function "$BACKUP" cleanup
    printf '%s\n' 'standalone_verify() {'
    extract_verify_body
    printf '%s\n' '}' 'trap cleanup EXIT' 'standalone_verify'
} > "$probe"

bash "$probe" > "$TMP/probe.out" 2>&1 || {
    cat "$TMP/probe.out" >&2
    fail "standalone DB verification rejected a final-component BACKUP_DIR symlink"
}
grep -Fq 'Verification passed:' "$TMP/probe.out" \
    || fail "standalone DB verification did not reach successful verification"

payload_workspace="$(cat "$TMP/payload-workspace.path")"
decrypted_db="$(cat "$TMP/decrypted-db.path")"
[[ "$payload_workspace" == "$backup_target"/.vaultwarden-backup.* ]] \
    || fail "payload workspace was not created below the symlink target"
[[ "$(cat "$TMP/payload-workspace.device")" == "$(stat -c '%d' "$backup_target")" ]] \
    || fail "payload workspace was not created on the symlink target filesystem"
[[ "$decrypted_db" == "$payload_workspace/verify-db.sqlite3" ]] \
    || fail "standalone verifier did not place decrypted DB in its payload workspace"
[[ "$decrypted_db" != /dev/shm/* ]] \
    || fail "standalone verifier placed decrypted DB on /dev/shm"
[[ ! -e "$payload_workspace" && ! -L "$payload_workspace" ]] \
    || fail "standalone verifier left its payload workspace behind"
if compgen -G "$backup_target/.vaultwarden-backup.*" >/dev/null; then
    fail "standalone verifier left a payload workspace below the canonical backup target"
fi
[[ -L "$configured_backup" && "$(readlink "$configured_backup")" == "$backup_target" ]] \
    || fail "standalone verifier altered the configured BACKUP_DIR symlink"
! grep -Fq '#   Validation : verify_backup_integrity' "$UTILS" \
    || fail "backup-utils header still advertises removed verify_backup_integrity"

printf 'PASS: standalone DB verifier accepts canonical backup symlink and cleans payload workspace\n'
)

check_standalone_db_verifier_symlink_base


check_authenticated_backup_cohort_contract() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
source "$ROOT/lib/log.sh"
source "$ROOT/lib/crypto.sh"
source "$ROOT/lib/backup-utils.sh"
archive="$TMP/db-test.age"
printf 'encrypted-payload' > "$archive"
FILE_INTEGRITY_HMAC_KEY='cohort-test-key'
REQUIRE_AUTHENTICATED_INTEGRITY=true
export FILE_INTEGRITY_HMAC_KEY REQUIRE_AUTHENTICATED_INTEGRITY
write_file_integrity "$archive" || fail 'strict integrity sidecars were not produced'
printf 'backup_type=db\narchive_format=relative\nversion=2\nencryption_mode=age-recipient\n' > "${archive}.meta"
chmod 600 "$archive" "${archive}.sha256" "${archive}.sha256.hmac" "${archive}.meta"
mapfile -t suffixes < <(backup_required_cohort_suffixes)
[[ "${suffixes[*]}" == ' .sha256 .sha256.hmac .meta' ]] || fail 'strict cohort definition drifted'
verify_file_integrity "$archive" || fail 'valid authenticated cohort did not verify'
printf tampered > "${archive}.sha256.hmac"
if verify_file_integrity "$archive" >/dev/null 2>&1; then fail 'tampered HMAC verified'; fi
write_file_integrity "$archive" || fail 'could not recreate integrity sidecars'
rm -f "${archive}.sha256.hmac"
if verify_file_integrity "$archive" >/dev/null 2>&1; then fail 'missing required HMAC verified'; fi
write_file_integrity "$archive" || fail 'could not recreate integrity sidecars after missing-HMAC case'
FILE_INTEGRITY_HMAC_KEY='wrong-key'
if verify_file_integrity "$archive" >/dev/null 2>&1; then fail 'wrong integrity key verified'; fi
printf 'PASS: authenticated backup cohort rejects tampered/missing HMAC and wrong key\n'
)
check_authenticated_backup_cohort_contract
