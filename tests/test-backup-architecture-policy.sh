#!/usr/bin/env bash
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
