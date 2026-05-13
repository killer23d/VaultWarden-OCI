# Volume Migration Guide — VaultWarden-OCI

Reference guide for `utilities/migrate-volume.sh`, the interactive tool for moving Vaultwarden data between storage volumes (boot volume ↔ block volume, or directory to directory).

---

## 📋 Overview

`migrate-volume.sh` is a cloud-agnostic, interactive script that safely moves the Vaultwarden data directory from one storage location to another. It wraps a robust pipeline of steps — format, rsync, byte-count verify — around interactive device selection so the admin never has to specify raw block device paths manually.

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
- ✅ **Confirm free space** — the target must have at least as much free space as the source data directory consumes
- ✅ **Note your mount point** — know where the volume should be mounted (default: `/mnt/vw-data`, from `DATA_VOLUME_MOUNT` in `.env`)
- ✅ **Verify `sudo` access** — the script requires root privileges
- ✅ **Plan a maintenance window** — the script stops the Docker stack; budget 5–15 minutes depending on data size

---

## 🚀 Quick Start

### Interactive (recommended)

Run with no arguments and the script will prompt for everything:

```bash
sudo utilities/migrate-volume.sh run
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
sudo utilities/migrate-volume.sh run \
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
sudo utilities/migrate-volume.sh run

# Non-interactive
sudo utilities/migrate-volume.sh run \
  --source /var/lib/vaultwarden \
  --target /mnt/vw-data \
  --device /dev/sdb \
  --yes
```

The script will:
1. Stop the Docker stack
2. Format `/dev/sdb` (ext4 by default)
3. Mount it at `/mnt/vw-data`
4. `rsync` all data from source to target
5. Verify byte counts match
6. Optionally rename / delete the source directory (`--delete-source`)
7. Restart the stack

### Block Volume → Another Block Volume

Use the same interactive or non-interactive flow. Attach the new volume, run the script, and select the new device. The source volume path should be the current mount point:

```bash
sudo utilities/migrate-volume.sh run \
  --source /mnt/vw-data \
  --target /mnt/vw-data2 \
  --device /dev/sdc \
  --yes
```

### Directory to Directory (No Format Step)

Pass `--target` without `--device`. The script skips `_mv_select_device` entirely — no block device is needed and **no formatting occurs**:

```bash
sudo utilities/migrate-volume.sh run \
  --source /var/lib/vaultwarden \
  --target /mnt/vw-data2
```

This is also the correct mode for **reversing a migration** (see below).

### Block Volume → Boot Volume (Reversal)

To move data back from a block volume to the boot volume, use directory-to-directory mode. Set `--source` to the current mount point and `--target` to the original path on the boot disk:

```bash
sudo utilities/migrate-volume.sh run \
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
| `resume` | Resume a previously interrupted migration from the last completed step. |
| `status` | Show the current migration state (steps completed, source, target). |
| `abort` | Abort an in-progress or interrupted migration and clean up lock files. |
| `verify` | Re-run byte-count verification only (non-destructive, safe to repeat). |

---

## ⚠️ Potential Data Folder Issues

Be aware of the following edge cases before running a migration.

### 1. Interactive picker only lists whole disks

The interactive device picker uses `lsblk -d` (no children), so only **whole disk devices** (e.g., `/dev/sdb`) appear in the numbered list — partitions (e.g., `/dev/sdb1`) are excluded. If your target block volume is partition-based, skip the interactive picker and pass `--device /dev/sdb1` explicitly on the CLI:

```bash
sudo utilities/migrate-volume.sh run \
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

### 4. No data wipe on reversal / dir-to-dir

In directory-to-directory mode (no `--device` flag), the format step is skipped entirely. This means any **existing files at the destination are not removed** before `rsync` runs. If the destination already contains data from a previous migration, you may end up with merged content. Use `--dry-run` first to inspect what will be synced:

```bash
sudo utilities/migrate-volume.sh run \
  --source /mnt/vw-data \
  --target /var/lib/vaultwarden \
  --dry-run
```

If a clean destination is required, manually clear it before running the migration:

```bash
sudo rm -rf /var/lib/vaultwarden/*
```

### 5. `.env` must be updated after migration

The script moves data but does not modify `.env`. After a successful migration, update `DATA_VOLUME_MOUNT` to reflect the new path so that subsequent script calls and systemd services resolve the correct location:

```bash
nano .env
# Set: DATA_VOLUME_MOUNT=/mnt/vw-data
```

Then restart the stack to pick up the change:

```bash
./startup.sh --force
```

### 6. Boot guard covers partitions on the root disk

The boot device guard checks both the mountpoint (`== /`) **and** the physical disk identity (`PKNAME` via `lsblk`). This means selecting `/dev/sda` (the underlying disk) is blocked even when `/` lives on `/dev/sda1`. The guard only activates if device detection succeeds — if `findmnt` or `lsblk` return empty, the guard is skipped and the `[boot]` label will not appear. In that case, rely on your cloud provider console to confirm which device is the boot disk before making a selection.

---

## 🔍 Dry Run and Verification

Always run with `--dry-run` first on production systems to preview every action without making changes:

```bash
sudo utilities/migrate-volume.sh run \
  --source /var/lib/vaultwarden \
  --target /mnt/vw-data \
  --device /dev/sdb \
  --dry-run
```

After a migration completes, re-run byte-count verification at any time without triggering another full migration:

```bash
sudo utilities/migrate-volume.sh verify
```

---

## 🔙 Rollback

If a migration fails or produces unexpected results:

1. **Check status** — `sudo utilities/migrate-volume.sh status`
2. **Abort if stuck** — `sudo utilities/migrate-volume.sh abort`
3. **Restore from backup** — `./backup.sh restore <archive>` (see [BACKUP-RESTORE.md](BACKUP-RESTORE.md))
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
sudo utilities/migrate-volume.sh status

# Resume from the last completed step
sudo utilities/migrate-volume.sh resume
```

### Byte count mismatch after verify

```bash
# Inspect the migration log for rsync errors
sudo utilities/migrate-volume.sh status

# Re-run rsync manually to check for errors
sudo rsync -av --checksum /var/lib/vaultwarden/ /mnt/vw-data/
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
3. **Verify after migration** — re-run `utilities/migrate-volume.sh verify` after any migration
4. **Update `.env` immediately** — set `DATA_VOLUME_MOUNT` to the new path before restarting services
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
   - Output of `lsblk` and `sudo utilities/migrate-volume.sh status`
   - Migration mode used (interactive / non-interactive / dir-to-dir)
   - Error messages and the migration log path shown by the script
   - Steps already attempted
