#!/usr/bin/env bash
# Consolidated backup regression suite.
set -euo pipefail

check_backup_architecture_policy() (
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
require '--exclude=\$\{state_dir#/\}/data/db\.sqlite3' "$BACKUP" 'full/emergency must exclude raw live DB'
require '--exclude=\$\{state_dir#/\}/data/db\.sqlite3-wal' "$BACKUP" 'full/emergency must exclude WAL'
require '--exclude=\$\{state_dir#/\}/data/db\.sqlite3-shm' "$BACKUP" 'full/emergency must exclude SHM'
require 'local db_archive_member="\$\{state_dir#/\}/data/db\.sqlite3"' "$BACKUP" 'full/emergency must target staged DB at live archive path'
require '--transform=s#\^\$\{snap_payload_regex\}\\\$#\$\{db_archive_member\}#' "$BACKUP" 'full/emergency must transform staged DB to live archive path'
require '-C "\$snap_payload_dir"' "$BACKUP" 'full/emergency must inject DB from staged snapshot payload directory'
require '"\$snap_payload_name"' "$BACKUP" 'full/emergency must inject staged DB snapshot payload'
require 'SECRETS_FILE|secrets/secrets.yaml|state directory' "$BACKUP" 'backup script should preserve encrypted SOPS secrets through state archive'
require '--exclude=etc/vaultwarden/age-key\.txt|--exclude=\$\{SCRIPT_DIR#/\}/secrets/keys/age-key\.txt' "$BACKUP" 'full backup must exclude age private keys'
require 'install -m 600 "\$etc_file" "\$snap_dir/etc/vaultwarden/\$\(basename "\$etc_file"\)"' "$BACKUP" 'emergency must stage /etc/vaultwarden files'
require '--exclude=run/vaultwarden-oci/secrets/\*' "$BACKUP" 'runtime /run secrets must be excluded'
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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESTORE="$ROOT/utilities/restore-run.sh"
BACKUP="$ROOT/utilities/backup-run.sh"
UTILS="$ROOT/lib/backup-utils.sh"
fail(){ echo "not ok - $*" >&2; exit 1; }
pass(){ echo "ok - $*"; }
require(){ local pat="$1" file="$2" msg="$3"; grep -Eq -- "$pat" "$file" || fail "$msg"; }
reject(){ local pat="$1" file="$2" msg="$3"; ! grep -Eq -- "$pat" "$file" || fail "$msg"; }
require '--exclude=\$\{state_dir#/\}/\.pre-restore-\*' "$BACKUP" 'state-dir pre-restore snapshots must be explicitly excluded'
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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
grep -Fq 'rm -f "$backup_file" "${backup_file}.meta" "${backup_file}.sha256" "${backup_file}.sha256.hmac"' <<< "$verify_failure_block" \
    || fail "backup verification failure does not discard archive and sidecars"
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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP="$ROOT/utilities/backup-run.sh"
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
TMPDIR_BACKUP="$TMP/work"
mkdir -p "\$TMPDIR_BACKUP"
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
$(_extract_func "$BACKUP" _validate_emergency_restore_metadata)
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
grep -q '^RC=2$' "$TMP/sha-fail.out" || { cat "$TMP/sha-fail.out" >&2; fail '.sha256 upload failure must remain warning-class status 2'; }
grep -q 'The primary backup archive was delivered' "$TMP/sha-fail.out" \
  || fail '.sha256 upload failure must retain warning-class primary-delivered wording'

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
BATCH_META_CASE="\${BATCH_META_CASE:-zero}"
COPY_LOG="$TMP/batch-copy.calls"
rm -rf "\$BASE_DIR"
mkdir -p "\$BASE_DIR/emergency"
archive="\$BASE_DIR/emergency/emergency-retained-20260710-120000.tar.zst.age"
printf archive > "\$archive"
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
_retention_days_for_type(){ printf '%s\\n' 30; }
cleanup_old_backups(){ return 0; }
_prune_remote_backups(){ return 0; }
rclone(){
  local cmd="\$1"; shift
  case "\$cmd" in
    lsd) return 0 ;;
    copy) printf '%s\\n' "\$*" >> "\$COPY_LOG"; return 0 ;;
    *) return 0 ;;
  esac
}
$(_extract_func "$BACKUP" _validate_emergency_restore_metadata)
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

grep -Fq 'elif (( _sync_rc == 3 )); then' "$BACKUP" \
  || fail 'backup run caller must handle emergency metadata delivery status separately'
grep -Fq 'FAILED: emergency restore metadata missing or unusable; local backup is safe' "$BACKUP" \
  || fail 'backup run summary must mark incomplete emergency offsite delivery as failed'

printf 'PASS: emergency offsite metadata is restore-usable before sync and verification; checksum sidecars remain warning-class\n'
)

check_emergency_offsite_metadata_contract
check_rclone_config_contracts() (
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
check_backup_retention_contracts() (
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
    if [[ "$1" == "BACKUP_DIR" ]]; then
        printf '%s\n' "$maintenance_dry_run_dir"
    else
        printf '%s\n' "${2:-}"
    fi
}

DRY_RUN=true CLEAN_BACKUPS=true DB_BACKUP_RETENTION_DAYS=1 \
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
backup_log_info(){ printf 'INFO:%s\n' "\$*" >> "\$REMOTE_LOG"; }
backup_log_success(){ printf 'SUCCESS:%s\n' "\$*" >> "\$REMOTE_LOG"; }
backup_log_warn(){ printf 'WARN:%s\n' "\$*" >> "\$REMOTE_LOG"; }
log_warn(){ printf 'WARN:%s\n' "\$*" >> "\$REMOTE_LOG"; }
log_error(){ printf 'ERROR:%s\n' "\$*" >> "\$REMOTE_LOG"; }
get_config_value(){
    case "\$1" in
        RCLONE_REMOTE_NAME) printf '%s\n' mockremote ;;
        RCLONE_REMOTE_PATH) printf '%s\n' vaultwarden_backups ;;
        *) printf '%s\n' "\${2:-}" ;;
    esac
}
_retention_days_for_type(){ printf '%s\n' 1; }
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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
if create_consistent_db_snapshot "$TMP/state" "$TMP/snap.sqlite3" db-test; then exit 1; fi
EOF_PROBE
bash "$TMP/db-restart-probe.sh" || fail 'DB restart probe script failed'
grep -q 'docker compose stop vaultwarden' "$TMP/docker.calls" || fail 'offline fallback did not stop container in probe'
[[ "$(grep -c 'docker compose start vaultwarden' "$TMP/docker.calls")" == "1" ]] || fail 'offline fallback did not restart exactly once after wait failure'

)

check_backup_db_restart_fallback
