# BACKUP & RESTORE

Operational guidance for creating, validating, syncing, and restoring encrypted backups using a pragmatic, small-scale workflow.

## Strategy Overview
- Daily encrypted database backups with pre-encryption integrity check.
- Weekly encrypted full backups; on-demand emergency kits include secrets for DR.
- Atomic write pattern prevents partial/corrupt artifacts.
- Optional rclone sync to remote storage; encryption occurs before upload.

## Backup Types
- db: SQLite snapshot with integrity check, gzip, Age encryption.
- full: Config + data (no secrets) with DB snapshot; ideal for version upgrades.
- emergency: Everything (config, data, secrets); store offsite securely.

## Commands
- Create: ./backup.sh --type db|full|emergency [--rclone]
- List:   ./backup.sh --list
- Dry run: ./backup.sh --type full --dry-run

## Integrity & Consistency
- Live DB snapshots use WAL checkpoint + .backup; integrity checked via PRAGMA quick_check.
- Atomic staging file then mv to final path prevents half-written results.
- Disk space checks require ~3× data size for safety.

## Offsite Sync (Optional)
- Prereq: rclone config (set remote named in .env: RCLONE_REMOTE_NAME).
- Sync: ./backup.sh --type db --rclone (uploads .age + .sha256 + .meta)

## Restore
- Interactive: ./restore.sh (choose backup file)
- Direct file: ./restore.sh --file /path/to/file.age
- Validate-only: ./restore.sh --validate-only /path/to/file.age

## Retention
- Retention is handled by maintenance scripts; defaults (edit in .env):
  - DB: 14 days
  - Full: 30 days
  - Emergency: 90 days

## Best Practices
- Store age key offline (secrets/keys/age-key.txt) with emergency kit.
- Test restore occasionally using --validate-only and non-production target.
- Ensure backups complete before updates; Makefile flows do this automatically.
