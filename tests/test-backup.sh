#!/usr/bin/env bash
# Consolidated backup regression suite.
set -euo pipefail

check_backup_architecture_policy() (
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP="$ROOT/utilities/backup-run.sh"
RESTORE="$ROOT/utilities/restore-run.sh"
fail(){ echo "FAIL: $*" >&2; exit 1; }
require(){ local pat="$1" file="$2" msg="$3"; grep -Eq -- "$pat" "$file" || fail "$msg"; }
reject(){ local pat="$1" file="$2" msg="$3"; ! grep -Eq -- "$pat" "$file" || fail "$msg"; }

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
for doc in docs/BACKUP-RESTORE.md docs/DISASTER-RECOVERY.md docs/OPERATIONS.md README.md; do
  require 'db`.*database|database rollback' "$ROOT/$doc" "$doc must document db tier"
  require 'full`.*offline Age (key|recipient)|offline Age (key|recipient)' "$ROOT/$doc" "$doc must document full tier offline key/recipient"
  require 'emergency`.*clone|clone-grade' "$ROOT/$doc" "$doc must document emergency tier"
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
