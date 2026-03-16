# VaultWarden-OCI: Backup & Restore Administration Guide

> **Audience:** System administrators managing this deployment.  
> **Last updated:** 2026-03-16  
> This guide covers normal operations, scheduled automation, manual backup
> commands, all restore scenarios, and retention management. All commands
> assume your working directory is the project root.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Backup Types](#backup-types)
3. [Running Backups Manually](#running-backups-manually)
4. [Scheduled Automation](#scheduled-automation)
5. [Backup Storage Layout](#backup-storage-layout)
6. [Backup File Format](#backup-file-format)
7. [Listing and Inspecting Backups](#listing-and-inspecting-backups)
8. [Validating a Backup](#validating-a-backup)
9. [Restore Procedures](#restore-procedures)
10. [Retention Policy](#retention-policy)
11. [Remote Storage (Rclone)](#remote-storage-rclone)
12. [Monitoring Backup Health](#monitoring-backup-health)
13. [Disaster Recovery Checklist](#disaster-recovery-checklist)
14. [Known Issues Fixed](#known-issues-fixed)

---

## Architecture Overview

```
VaultWarden (SQLite WAL mode)
        │
        │  sqlite3 .backup (Online Backup API — WAL-safe)
        ▼
   Consistent DB snapshot
        │
        │  tar + gzip (full backup)
        ▼
   Plaintext archive
        │
        │  age -r <public_key>   (Age encryption)
        ▼
   .age encrypted archive
        │
        ├── SHA-256 sidecar  (.sha256)
        ├── Metadata sidecar (.meta)
        │
        ├── Local storage:  backups/{db,full,emergency}/
        └── Remote storage: rclone → S3/B2/GCS/OCI Object Storage
```

All backups are encrypted with the Age public key derived from
`secrets/keys/age-key.txt`. **If the Age private key is lost, all backups are
permanently unrecoverable.** Store the key in your password manager and
generate a recovery kit immediately after setup.

---

## Backup Types

| Type | Script flag | Contents | Default retention |
|------|------------|----------|------------------|
| **DB** | `--type db` | VaultWarden SQLite database only | 30 days |
| **Full** | `--type full` | DB + config files + secrets (encrypted) | 90 days |
| **Emergency** | `--type emergency` | DB + config, taken before risky operations | 90 days |

All types are stored as `.tar.gz` archives encrypted with Age (`*.tar.gz.age`).

---

## Running Backups Manually

### Quick commands

```bash
# Database-only backup (fastest, safest for daily automation)
./backup.sh --type db

# Full backup (DB + config + encrypted secrets)
./backup.sh --type full

# Emergency backup (taken automatically by maintenance.sh before major ops)
./backup.sh --type emergency

# Full backup, upload to remote, and clean up old local copies
./backup.sh --type full --upload --cleanup

# Dry run (show what would happen without writing anything)
./backup.sh --type full --dry-run

# Backup with explicit keep-days override
./backup.sh --type db --keep 14
```

### Make targets

```bash
make backup          # DB backup
make backup-full     # Full backup
make backup-upload   # Full backup + rclone upload
```

### Options reference

| Flag | Description |
|------|-------------|
| `--type db\|full\|emergency` | Backup type (required) |
| `--upload` | Upload to rclone remote after backup |
| `--cleanup` | Remove backups older than retention threshold |
| `--keep N` | Override retention days for this run |
| `--dry-run` | Simulate without writing files |
| `--no-verify` | Skip post-backup integrity verification |
| `--debug` | Enable verbose `set -x` output |

---

## Scheduled Automation

Backups are managed by systemd timers installed via `./systemd-setup.sh --install`.

```bash
# Install all timers
sudo ./systemd-setup.sh --install

# Check timer status
systemctl list-timers 'vaultwarden-*'

# Check last backup run
journalctl -u vaultwarden-db-backup.service -n 50
```

### Default schedule

| Timer | Schedule | Action |
|-------|----------|--------|
| `vaultwarden-db-backup.timer` | Mon–Sat 04:00 | DB backup + cleanup |
| `vaultwarden-full-backup.timer` | Sun 03:00 | Full backup + upload + cleanup |
| `vaultwarden-health.timer` | Every 15 min | Health check + alert on failure |

> **Important — Sunday gap (SY-3):** The `vaultwarden-db-backup.timer` runs
> Mon–Sat only. A backup failure between Saturday 04:00 and Sunday 03:00
> creates a ~47-hour gap with no DB-only snapshot. Consider changing the
> timer to `daily *-*-* 04:00:00` for continuous coverage:
> ```bash
> sudo systemctl edit vaultwarden-db-backup.timer
> # Add: OnCalendar=daily *-*-* 04:00:00
> ```

### Systemd hardening note (SY-1)

All backup services currently run as `User=root` with no filesystem namespace
restrictions. For improved security, add to each `.service` file:

```ini
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/vaultwarden-scripts /var/lib/vaultwarden /etc/vaultwarden
```

Also add `Conflicts=shutdown.target` to all backup timers to prevent a backup
starting during system shutdown from interrupting a live WAL checkpoint. *(SY-2)*

---

## Backup Storage Layout

```
backups/
├── db/
│   ├── db-20260310-040012.tar.gz.age        # Encrypted archive
│   ├── db-20260310-040012.tar.gz.age.sha256  # SHA-256 checksum
│   └── db-20260310-040012.tar.gz.age.meta   # Metadata
├── full/
│   └── full-20260309-030045.tar.gz.age
└── emergency/
    └── emergency-20260308-120000.tar.gz.age
```

The `YYYYMMDD-HHMMSS` timestamp embedded in each filename is the **primary
source of truth for retention age calculations** (see
[Retention Policy](#retention-policy)). It is immune to `cp`, `mv`,
`chmod`, and `chown` operations that would reset `ctime`.

---

## Backup File Format

Each backup is:
1. A `.tar.gz` archive containing the backed-up files.
2. Encrypted with `age -r <public_key>` producing a `.age` file.
3. Accompanied by two sidecar files:
   - `.sha256` — hex SHA-256 of the `.age` file for integrity verification.
   - `.meta` — key=value metadata (type, timestamp, hostname, size, checksum,
     VaultWarden version).

### Decrypting a backup manually

```bash
# Decrypt to stdout and extract
age -d -i secrets/keys/age-key.txt backups/db/db-YYYYMMDD-HHMMSS.tar.gz.age \
    | tar -xzv -C /tmp/restore-test/
```

---

## Listing and Inspecting Backups

```bash
# List all backups with sizes and timestamps
./restore.sh --list

# Or use the library function directly (from any sourcing script)
list_backups backups/

# Show statistics (count + size per type)
# This calls get_backup_statistics() from lib/backup_utils.sh
make backup-stats
```

### Reading a .meta sidecar

```bash
cat backups/db/db-20260310-040012.tar.gz.age.meta
# backup_type=db
# timestamp=2026-03-10T04:00:12+00:00
# hostname=vaultwarden-oci
# file_size=245760
# sha256=a1b2c3...
# vaultwarden_version=1.32.0
# creator=VaultWarden-OCI-NG
```

---

## Validating a Backup

Always validate before relying on a backup for restore.

```bash
# Validate a single backup file (size + SHA-256 + decryption test)
./restore.sh --validate backups/db/db-YYYYMMDD-HHMMSS.tar.gz.age

# Or call library function directly
validate_backup_integrity \
    backups/db/db-YYYYMMDD-HHMMSS.tar.gz.age \
    secrets/keys/age-key.txt
```

`validate_backup_integrity` performs three checks:
1. File is > 1 KiB (basic corruption detection).
2. SHA-256 matches the `.sha256` sidecar (if present).
3. `age -d` can decrypt the file without error (decrypts to `/dev/null`).

### Validating the live database (WAL-safe)

```bash
# Runs PRAGMA integrity_check using SQLite Online Backup API (not a live-file cp)
verify_backup_integrity /var/lib/vaultwarden/db.sqlite3
```

This function creates a consistent snapshot via `sqlite3 .backup` before
running `PRAGMA integrity_check`, so it is safe while VaultWarden is running.
*(See LB-1 fix in [Known Issues Fixed](#known-issues-fixed))*

---

## Restore Procedures

### Pre-restore checklist

```bash
# 1. Verify the Age key is present and healthy
./health.sh --check-keys

# 2. List available backups
./restore.sh --list

# 3. Validate the target backup
./restore.sh --validate backups/db/db-YYYYMMDD-HHMMSS.tar.gz.age

# 4. Stop VaultWarden to prevent writes during restore
make down
```

### Restore: database from DB backup

```bash
./restore.sh --type db --file backups/db/db-YYYYMMDD-HHMMSS.tar.gz.age
```

### Restore: full backup (DB + config)

```bash
./restore.sh --type full --file backups/full/full-YYYYMMDD-HHMMSS.tar.gz.age
```

### Restore: interactive mode (guided prompts)

```bash
./restore.sh --interactive
```

### Restore: emergency restore (latest available backup, minimal prompts)

```bash
./restore.sh --type emergency
```

### Post-restore steps

```bash
# 1. Restart services
make up

# 2. Verify health
./health.sh

# 3. Confirm VaultWarden is accessible and vault data looks correct
curl -sf https://your.domain/alive
```

### Restore from remote storage

```bash
# List remote backups
rclone ls remote:your-bucket/

# Download a specific backup
rclone copy remote:your-bucket/db-YYYYMMDD-HHMMSS.tar.gz.age backups/db/

# Then restore normally
./restore.sh --type db --file backups/db/db-YYYYMMDD-HHMMSS.tar.gz.age
```

---

## Retention Policy

Retention is enforced by `cleanup_old_backups()` in `lib/backup_utils.sh`,
called by `backup.sh --cleanup`.

### Age calculation (important: filename-first)

**Since patch LB-2:** The age of a backup is determined by the
`YYYYMMDD-HHMMSS` timestamp in its filename, **not** by `ctime` or `mtime`.

This matters because:
- `ctime` is reset to now when a file is copied to a new host (`cp`, `rsync --times`).
- On a fresh disaster-recovery host, all restored backups would appear 0 days
  old and would **never be cleaned up** under a `ctime`-based system, causing
  unbounded disk growth.
- The filename timestamp is set once at backup creation and is immutable.

The fallback to `ctime` applies only to files whose names contain no
`YYYYMMDD-HHMMSS` pattern (files predating this naming convention).

### Default retention values

Set in `.env` or overridden per-run with `--keep N`:

```bash
BACKUP_RETENTION_DB_DAYS=30
BACKUP_RETENTION_FULL_DAYS=90
BACKUP_RETENTION_EMERGENCY_DAYS=90
```

### Orphan sidecar cleanup

After the age-based pass, a second sweep removes `.meta` and `.sha256` files
whose corresponding `.age` primary no longer exists. *(Patch P2-M3)*

This prevents indefinite accumulation of orphaned sidecars from:
- Partial prior cleanup runs.
- Manual deletion of `.age` files.
- Any other out-of-band removal.

### Running cleanup manually

```bash
# Clean up old DB backups (uses configured retention)
./backup.sh --type db --cleanup

# Clean with explicit override
./backup.sh --type db --cleanup --keep 7
```

---

## Remote Storage (Rclone)

Rclone is used to upload backups to an off-host remote (S3, Backblaze B2,
OCI Object Storage, GCS, etc.).

### Initial configuration

```bash
# Configure a remote interactively
rclone config

# Test connectivity
rclone lsd remote:your-bucket
```

Set in `.env`:

```bash
RCLONE_REMOTE=remote:your-bucket    # e.g. "b2:my-vw-backups"
RCLONE_ENABLED=true
```

### Manual upload

```bash
# Upload all local backups to remote
rclone sync backups/ remote:your-bucket/vaultwarden-backups/

# Upload a single file
rclone copy backups/full/full-YYYYMMDD-HHMMSS.tar.gz.age remote:your-bucket/
```

### Push notifications and `internal: true` network (DC-1)

If `PUSH_ENABLED=true`, the VaultWarden container must be able to reach
`https://push.bitwarden.com`. If your Docker network uses `internal: true`,
outbound internet access is blocked and push sync will **silently fail** on
every sync cycle.

Either:
- Set `PUSH_ENABLED=false` in `.env`, or
- Remove `internal: true` from the network definition in `docker-compose.yml`.

The startup script will fail with an explicit error if push is enabled but the
endpoint is unreachable.

---

## Monitoring Backup Health

```bash
# Full system health check (includes backup age check)
./health.sh

# Check only backup-related health
./health.sh --check-backups

# View last backup results from systemd journal
journalctl -u vaultwarden-db-backup.service --since "24 hours ago"
journalctl -u vaultwarden-full-backup.service --since "7 days ago"
```

Health check alerts are sent by email if SMTP is configured in `.env`:

```bash
SMTP_ENABLED=true
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=alerts@example.com
SMTP_FROM=alerts@example.com
SMTP_TO=admin@example.com
```

---

## Disaster Recovery Checklist

Use this when recovering onto new hardware or after complete data loss.

```
[ ] 1. Provision new OCI compute instance
[ ] 2. Install dependencies: git docker docker-compose age sops sqlite3 rclone
[ ] 3. Clone repository:
        git clone <your-repo-url>
        cd VaultWarden-OCI
[ ] 4. Restore Age private key:
        mkdir -p secrets/keys
        # Paste key content from recovery kit:
        nano secrets/keys/age-key.txt
        chmod 600 secrets/keys/age-key.txt
[ ] 5. Run setup:
        ./setup.sh --domain your.domain --email admin@example.com
[ ] 6. Download latest backup from remote:
        rclone copy remote:your-bucket/full-YYYYMMDD-HHMMSS.tar.gz.age backups/full/
[ ] 7. Validate backup:
        ./restore.sh --validate backups/full/full-YYYYMMDD-HHMMSS.tar.gz.age
[ ] 8. Restore:
        ./restore.sh --type full --file backups/full/full-YYYYMMDD-HHMMSS.tar.gz.age
[ ] 9. Start services:
        make up
[ ] 10. Verify health:
        ./health.sh
[ ] 11. Test login at https://your.domain
[ ] 12. Reinstall systemd timers:
        sudo ./systemd-setup.sh --install
```

---

## Known Issues Fixed

The following bugs in the backup pipeline have been patched. They are
documented here so administrators understand why certain implementation
choices were made.

| ID | Severity | File | Summary |
|----|----------|------|---------|
| LB-1 | Critical | `backup_utils.sh` | `verify_backup_integrity`: replaced three sequential `cp` calls with `sqlite3 .backup` (SQLite Online Backup API). Three sequential copies could produce an inconsistent snapshot if VaultWarden committed a transaction between them; `PRAGMA integrity_check` on such a snapshot could return a false `ok`. |
| LB-2 | High | `backup_utils.sh` | Retention age uses filename `YYYYMMDD-HHMMSS` timestamp as primary source; `ctime` as fallback only. `ctime` is reset by `cp`/`mv`/`chmod`/`chown`, causing restored backups to appear 0 days old on a new host and never be cleaned up. |
| P2-M3 | Medium | `backup_utils.sh` | Orphaned `.meta`/`.sha256` sidecars are swept in a second pass after the age-based cleanup. Previously accumulated indefinitely. |
| BUG-B1 | High | `backup_utils.sh` | `check_backup_disk_space`: replaced GNU-only `df --output=avail` with portable `awk 'END {print $4}'`. |
| BUG-B2 | High | `backup_utils.sh` | `get_backup_statistics`: replaced GNU-only `find -exec stat -c%s {} +` with portable `_stat_file_size()` loop. |
| BUG-B3 | Medium | `backup_utils.sh` | `create_backup_metadata`: replaced GNU-only `stat -c%s` with `_stat_file_size()`. |
| BUG-B4 | Medium | `backup_utils.sh` | `cleanup_old_backups`: quoted `$retention_days` in `find` to prevent `set -u` failures. |
| BUG-B5 | Low | `backup_utils.sh` | `create_backup_metadata`: replaced `$?` anti-pattern after heredoc with direct `if ! cat > file <<EOF` guard. |
| AUD-B1 | High | `backup_utils.sh` | `verify_backup_integrity`: integrity check now runs on a private `700` tmpdir copy, not the live file. |
| AUD-B2 | Medium | `backup_utils.sh` | `get_backup_size`: returns raw bytes, not `du -sh` human-readable string. |
| AUD-B3 | Low | `backup_utils.sh` | `cleanup_old_backups`: `stat`-based ctime check replaces `-mtime` (mtime can be faked by `rsync --times`). |
| B-1 | Critical | `backup.sh` | WAL checkpoint `elif ... ; do` parse error (shell syntax bug) — see `backup.sh` source comments. |
| B-2 | Medium | `backup.sh` | GNU-specific `sed 's/./\u&/'` replaced with portable `printf`/`tr` for backup label title-casing. |
| B-3 | Medium | `backup.sh` | WAL checkpoint result not validated; backup proceeded silently on WAL inconsistency. |
| B-4 | Medium | `backup.sh` | Age key missing at quick-verify time returned success (0); now returns error. |
| B-5 | Medium | `backup.sh` | `LOCK_FD=200` replaced with `LOCK_FD=9` for POSIX FD range compatibility. |
| B-6 | Medium | `backup.sh` | `--keep` argument not validated as integer; potential command injection via argument parsing. |
