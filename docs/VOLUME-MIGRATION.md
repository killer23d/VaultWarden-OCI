# Volume Migration Guide — VaultWarden-OCI

Reference guide for `utilities/setup-storage.sh --mode migrate` — the interactive tool for moving Vaultwarden data between storage volumes (boot volume ↔ block volume, or directory to directory).

---

## 📋 Overview

`setup-storage.sh --mode migrate` is a cloud-agnostic, interactive script that safely moves the Vaultwarden data directory from one storage location to another. It wraps a robust pipeline of steps — format, rsync, byte-count verify — around interactive device selection so the admin never has to specify raw block device paths manually.

Typical use cases:

- **Boot volume → dedicated block volume** — move data off the OS disk onto a separately attached block volume for isolation and persistence
- **Block volume → another block volume** — re-platform or resize the data volume without downtime longer than a stack stop
- **Directory to directory** — path-based move on the same disk, no formatting involved
- **Block volume → boot volume (reversal)** — roll back to boot-volume storage using directory-to-directory mode

---

## ✅ Pre-Migration Checklist

Before running the script:

- ✅ **Backup first** — run `./backup.sh run full` and verify the archive is readable
- ✅ **Attach the target volume** — add the block device via your cloud provider console before running the script; the device must appear in `lsblk`
- ✅ **Confirm free space** — the target must have at least as much free space as the source data directory consumes (checked automatically after format for block-device migrations)
- ✅ **Note your mount point** — know where the volume should be mounted (default: `/mnt/vw-data`, from `DATA_VOLUME_MOUNT` in `.env`)
- ✅ **Verify `sudo` access** — the script requires root privileges
- ✅ **Plan a maintenance window** — the script stops the Docker stack; budget 5–15 minutes depending on data size
- ✅ **SQLite WAL** — the script checks for non-empty WAL files after the stack stops and warns if found; if you see this warning, run `sudo ./maintenance.sh db-maint` to checkpoint the database before proceeding

---

## 🚀 Quick Start

### Interactive (recommended)

Run with no arguments and the script will prompt for everything:

```bash
sudo utilities/setup-storage.sh --mode migrate run
```

You will be shown a numbered device table (like the one below) and prompted to select the target block device and mount point:

```
  1) /dev/sda    size: 50G      mount: /                      [boot]
  2) /dev/sdb    size: 100G     mount: -

  Select TARGET block device for migration (DO NOT choose [boot]):
  Device number [1-2]: 2

  Enter target mount point [/mnt/vw-data]:
```

> **Warning:** Never select a device marked `[boot]`. The script will abort with an error if you do, but avoiding it in the first place is safer.

### Non-interactive (scripted / automated)

Pass all required flags explicitly. `--yes` is required for non-interactive mode and enforces that `--target` is also provided:

```bash
sudo utilities/setup-storage.sh --mode migrate run \
  --source /var/lib/vaultwarden \
  --target /mnt/vw-data \
  --device /dev/sdb \
  --yes
```

---

## 🔄 Migration Scenarios

### Boot Volume → Block Volume

The standard path — moves data from the default location on the OS disk to a freshly attached block device.

```bash
# Interactive (prompts for device and mount point)
sudo utilities/setup-storage.sh --mode migrate run

# Non-interactive
sudo utilities/setup-storage.sh --mode migrate run \
  --source /var/lib/vaultwarden \
  --target /mnt/vw-data \
  --device /dev/sdb \
  --yes
```

The script will:
1. Stop the Docker stack (and check for non-empty SQLite WAL files — a non-empty WAL after a clean stop is warned prominently)
2. Format `/dev/sdb` (ext4 by default) and run a disk space check against the newly mounted volume
3. Mount it at `/mnt/vw-data`
4. `rsync` all data from source to target (WAL and SHM files are excluded from the transfer)
5. Verify: byte-count delta ≤ 1% **and** full rsync checksum pass
6. Optionally rename / delete the source directory (`--delete-source` — requires typing the full absolute path)
7. Update `.env` (PROJECT_STATE_DIR, DATA_VOLUME_MOUNT, DATA_VOLUME_DEVICE, BACKUP_DIR) and prune old `.env` backups
8. Restart the stack and confirm all containers are running and `/alive` responds

### Block Volume → Another Block Volume

Use the same interactive or non-interactive flow. Attach the new volume, run the script, and select the new device. The source volume path should be the current mount point:

```bash
sudo utilities/setup-storage.sh --mode migrate run \
  --source /mnt/vw-data \
  --target /mnt/vw-data2 \
  --device /dev/sdc \
  --yes
```

### Directory to Directory (No Format Step)

Pass `--target` without `--device`. The script skips `_mv_select_device` entirely — no block device is needed and **no formatting occurs**:

```bash
sudo utilities/setup-storage.sh --mode migrate run \
  --source /var/lib/vaultwarden \
  --target /mnt/vw-data2
```

This is also the correct mode for **reversing a migration** (see below).

### Block Volume → Boot Volume (Reversal)

To move data back from a block volume to the boot volume, use directory-to-directory mode. Set `--source` to the current mount point and `--target` to the original path on the boot disk:

```bash
sudo utilities/setup-storage.sh --mode migrate run \
  --source /mnt/vw-data \
  --target /var/lib/vaultwarden
```

> **Important:** Do **not** pass `--device` for reversal. Providing a device path triggers the format step, which would destroy data on whatever device you specify. Directory-to-directory mode `rsync`s without formatting.

Before the reversal, unmount the block volume if it is no longer needed:

```bash
sudo umount /mnt/vw-data
```

Update `DATA_VOLUME_MOUNT` in `.env` (or remove it) to reflect the reverted path, then restart the stack:

```bash
./startup.sh --force
```

---

## ⚙️ All Options

| Flag | Description | Required |
| :-- | :-- | :-- |
| `--source <path>` | Source directory (default: `PROJECT_STATE_DIR` from `.env`) | No |
| `--target <path>` | Destination mount point (prompted interactively if omitted; required with `--yes`) | Conditional |
| `--device <dev>` | Block device to format and mount (e.g. `/dev/sdb`). Prompted interactively via `lsblk` if omitted. Omit entirely for dir-to-dir migration. | No |
| `--skip-stack-stop` | Do not stop the Docker stack before migrating. Requires explicit runtime confirmation. Use with caution. | No |
| `--delete-source` | Delete the renamed source directory after successful verification. | No |
| `--dry-run` | Print all actions without executing them. | No |
| `--force` | Skip the pre-migration backup confirmation prompt. | No |
| `--yes` | Answer yes to all confirmations (except `--delete-source`). Requires `--target`. | No |
| `--log-file <path>` | Override default log file path. | No |
| `--help` | Show built-in help and exit. | No |

---

## 🔁 Subcommands

| Subcommand | Description |
| :-- | :-- |
| `run` | Start a new migration (interactive or non-interactive). |
| `resume` | Resume a previously interrupted migration from the last completed step. Re-validates that the source still exists, the target is mounted (block-device migrations), and `docker-compose.yml` is present before continuing. |
| `status` | Show the current migration state (steps completed, source, target). |
| `abort` | Abort an in-progress or interrupted migration and roll back: restores `.env`, renames source back, and offers to unmount the new volume if it was formatted. |
| `verify` | Re-run byte-count **and checksum** verification only (non-destructive, safe to repeat). |

---

## ⚠️ Potential Data Folder Issues

Be aware of the following edge cases before running a migration.

### 1. Interactive picker lists whole disks and partitions

The interactive device picker uses `lsblk` (without `-d`) so both **whole-disk** devices (e.g., `/dev/sdb`) and their **partitions** (e.g., `/dev/sdb1`) appear in the numbered list. Devices that belong to the boot disk are tagged `[boot]` — this includes the root disk itself **and any of its partitions** (the guard uses a prefix match, so `/dev/nvme0n1p2` is blocked when `/dev/nvme0n1` is the boot disk). If your target block volume is partition-based, select it directly from the interactive list or pass `--device /dev/sdb1` explicitly on the CLI:

```bash
sudo utilities/setup-storage.sh --mode migrate run \
  --source /var/lib/vaultwarden \
  --target /mnt/vw-data \
  --device /dev/sdb1
```

### 2. Mount point path resolution

The `--target` prompt normalises the input with `realpath -m`, which resolves symlinks and relative paths before the pipeline runs. This prevents path mismatches, but it means that if you provide a relative path or a symlink, the resolved absolute path is what the pipeline will use. Verify the logged `Using mount point:` output matches your expectation before confirming.

### 3. Target directory must exist or be creatable

The migration pipeline (`_mv_run_pipeline`) is responsible for creating the mount point directory if it does not exist. If the parent directory is not writable by root, the pipeline will fail at the mount step. Ensure the parent path (e.g., `/mnt`) exists and is accessible:

```bash
ls -la /mnt
```

### 4. Non-empty target warns in dir-to-dir mode

In directory-to-directory mode (no `--device` flag), the format step is skipped entirely. rsync always runs with `--delete`, which means any **existing files at the destination that are absent from the source are removed** before the transfer completes. The pre-flight summary will explicitly warn when the target is a non-empty directory:

```
  ⚠  WARNING: Target directory is non-empty (5 item(s)).
     rsync --delete will REMOVE files in target that do not exist in source.
     Run with --dry-run first to inspect changes before proceeding.
```

Use `--dry-run` first to inspect what will be synced and deleted:

```bash
sudo utilities/setup-storage.sh --mode migrate run \
  --source /mnt/vw-data \
  --target /var/lib/vaultwarden \
  --dry-run
```

If a clean destination is required, manually clear it before running the migration:

```bash
sudo rm -rf /var/lib/vaultwarden/*
```

### 5. `.env` is updated automatically after migration

The script updates `.env` (PROJECT_STATE_DIR, DATA_VOLUME_MOUNT, DATA_VOLUME_DEVICE, BACKUP_DIR) as step 7 of the pipeline. A timestamped backup is created at `.env.pre-migration.<timestamp>` before any changes; only the most recent backup is retained (older ones from previous runs are pruned automatically). If the migration is aborted, `.env` is restored from the backup.

If `BACKUP_DIR` was a custom path (not the default `<STATE_DIR>/backups`), the script will warn and require explicit acknowledgement — it will not auto-update custom paths.

### 6. Boot guard covers the root disk and all its partitions

The boot device guard checks the mountpoint (`== /`), the physical disk identity (`PKNAME` via `lsblk`), **and any partition of that disk** (prefix match). This means selecting `/dev/nvme0n1` or any of its partitions (e.g., `/dev/nvme0n1p1`, `/dev/nvme0n1p2`) is blocked when the root filesystem lives on `/dev/nvme0n1`. All such devices are tagged `[boot]` in the interactive picker. The guard only activates if device detection succeeds — if `findmnt` or `lsblk` return empty, the guard is skipped and the `[boot]` label will not appear. In that case, rely on your cloud provider console to confirm which device is the boot disk before making a selection.

---

## 🔍 Dry Run and Verification

Always run with `--dry-run` first on production systems to preview every action without making changes:

```bash
sudo utilities/setup-storage.sh --mode migrate run \
  --source /var/lib/vaultwarden \
  --target /mnt/vw-data \
  --device /dev/sdb \
  --dry-run
```

After a migration completes, re-run verification at any time without triggering another full migration. The verify subcommand performs both a byte-count delta check (≤ 1% tolerance) and a full content integrity check (`rsync --checksum --dry-run`), which catches silent block-level corruption that byte totals cannot detect:

```bash
sudo utilities/setup-storage.sh --mode verify
```

---

## 🔙 Rollback

If a migration fails or produces unexpected results:

1. **Check status** — `sudo utilities/setup-storage.sh --mode migrate status`
2. **Abort if stuck** — `sudo utilities/setup-storage.sh --mode migrate abort`
3. **Restore from backup** — run `sudo ./restore.sh interactive --file <archive>` (see [BACKUP-RESTORE.md](BACKUP-RESTORE.md))
4. **Reverse via dir-to-dir** — if the rsync completed but you want to revert, use the [block volume → boot volume reversal](#block-volume--boot-volume-reversal) flow described above
5. **Update `.env`** — revert `DATA_VOLUME_MOUNT` to the original path and restart: `./startup.sh --force`

---

## 🔧 Troubleshooting

### No block devices found

```bash
# Verify the volume is attached and visible to the OS
lsblk

# If newly attached, the kernel may not have rescanned — trigger a rescan
sudo partprobe
# or
sudo udevadm trigger
```

### Migration interrupted mid-rsync

```bash
# Check current state
sudo utilities/setup-storage.sh --mode migrate status

# Resume from the last completed step
sudo utilities/setup-storage.sh --mode migrate resume
```

### Byte count mismatch after verify

```bash
# Inspect the migration log for rsync errors
sudo utilities/setup-storage.sh --mode migrate status

# Re-run full verification (byte-count + checksum)
sudo utilities/setup-storage.sh --mode verify

# Re-run rsync manually to check for errors
sudo rsync -av --checksum /var/lib/vaultwarden/ /mnt/vw-data/
```

### Non-empty WAL files after stack stop

```bash
# The script warns if SQLite WAL files are non-empty after stopping the stack.
# Checkpoint the WAL before proceeding:
sudo sqlite3 /var/lib/vaultwarden/data/db.sqlite3 'PRAGMA wal_checkpoint(FULL);'

# Or use the built-in maintenance script:
sudo ./maintenance.sh db-maint

# Then re-run the migration (or resume if interrupted):
sudo utilities/setup-storage.sh --mode migrate resume
```

### Stack fails to start after migration

```bash
# Confirm the new path is set correctly in .env
grep DATA_VOLUME_MOUNT .env

# Confirm the mount is active
mount | grep vw-data

# Check Docker Compose logs
docker compose logs vaultwarden
```

### Permissions incorrect on migrated data

```bash
# VaultWarden runs as UID 1000 inside the container
sudo chown -R 1000:1000 /mnt/vw-data
sudo chmod -R 750       /mnt/vw-data
```

---

## 💡 Best Practices

1. **Always back up before migrating** — run `./backup.sh run full` and verify the archive
2. **Dry run first** — use `--dry-run` to preview actions on production systems
3. **Verify after migration** — re-run `utilities/setup-storage.sh --mode verify` after any migration (byte-count + checksum)
4. **Checkpoint the database** — if WAL files are found after stop, run `sudo ./maintenance.sh db-maint` before proceeding
5. **Use dir-to-dir for reversal** — never pass `--device` when moving data back to the boot volume
6. **Confirm boot device visually** — cross-check the `[boot]` label against your cloud provider's attached volume list
7. **Test with dry run after volume resize** — re-validate the migration pipeline if the underlying block device has been resized

---

## 🆘 Support

For migration assistance:

1. Review related guides in the `/docs` directory:
   - [MIGRATION.md](MIGRATION.md) — moving from other VaultWarden or Bitwarden deployments
   - [BACKUP-RESTORE.md](BACKUP-RESTORE.md) — backup and restore procedures
   - [OPERATIONS.md](OPERATIONS.md) — day-to-day operational reference
   - [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — general troubleshooting
2. Search GitHub Issues for similar volume migration reports
3. Open a new issue with:
   - Output of `lsblk` and `sudo utilities/setup-storage.sh --mode migrate status`
   - Migration mode used (interactive / non-interactive / dir-to-dir)
   - Error messages and the migration log path shown by the script
   - Steps already attempted
