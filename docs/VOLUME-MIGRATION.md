# Volume Migration Guide — VaultWarden-OCI

Reference for `utilities/setup-storage.sh migrate`, the guarded migration workflow for moving current VaultWarden-OCI state between boot storage, attached block/data volumes, or directories.

Do not replace this workflow with manual `cp -r` plus `.env` edits for a current production deployment. The migration utility owns storage identity, resumable state, verification, environment reconciliation, and service start policy.

Related docs: [CONFIGURATION.md](CONFIGURATION.md) · [OPERATIONS.md](OPERATIONS.md) · [BACKUP-RESTORE.md](BACKUP-RESTORE.md)

## Supported migration shapes

- boot volume → dedicated block/data volume;
- one data volume → another data volume;
- block/data volume → boot volume;
- directory → directory with no formatting step.

The default direction is `boot-to-block`. Reverse migration has an explicit `block-to-boot` direction.

## Safety model

The migration path:

- requires root;
- acquires the shared global operation guard and a migration-specific lock;
- keeps resumable state in the repository checkout because `PROJECT_STATE_DIR` can move during the operation;
- never silently selects a target disk;
- identifies boot-device candidates and refuses the detected boot device for forward block migration;
- requires an explicit `--force-format` authorization before formatting a blank/signature-free target device;
- does not use `--force` as formatting authorization;
- refuses `--yes` together with `--skip-stack-stop`;
- re-checks that the stack is stopped immediately before rsync;
- excludes SQLite WAL/SHM files from the transfer;
- protects the target `.vw-data-volume` filesystem identity marker;
- verifies the transfer before completing;
- applies a service start policy instead of always starting production automatically.

## Before migration

1. Create and verify a fresh full backup:

   ```bash
   sudo ./backup.sh run full --full-verification
   sudo ./backup.sh verify
   ```

2. Confirm the current environment/storage identity:

   ```bash
   utilities/env-edit.sh status
   sudo utilities/setup-storage.sh verify
   findmnt
   lsblk -f
   ```

3. Attach the target volume through your provider, hypervisor, or physical host.

4. Identify the target device. Prefer stable paths such as:

   ```text
   /dev/disk/by-id/...
   /dev/disk/by-uuid/...
   ```

5. Plan a maintenance window. The normal migration path stops the Docker stack.

Do not assume `/dev/sdb` or another provider-specific device name is universal.

---

## Quick start — interactive forward migration

```bash
sudo utilities/setup-storage.sh migrate run
```

The utility displays block devices and prompts for the target path/device where required.

For a blank target device, device selection alone is not formatting consent. If the preflight reports that the blank device requires explicit formatting authorization, rerun with `--force-format` after rechecking the device identity.

Example:

```bash
sudo utilities/setup-storage.sh migrate run \
  --target /mnt/vw-data \
  --device /dev/disk/by-id/<your-volume> \
  --force-format
```

## Non-interactive forward migration

A fully scripted boot-to-block migration to a known blank target requires an explicit target, explicit device, `--force-format`, and `--yes`:

```bash
sudo utilities/setup-storage.sh migrate run \
  --source /var/lib/vaultwarden \
  --target /mnt/vw-data \
  --device /dev/disk/by-id/<your-volume> \
  --force-format \
  --yes
```

`--yes` answers confirmations that are safe to automate. It does not bypass the separate typed confirmation for `--delete-source`, and it cannot be combined with live-stack migration.

---

## Forward migration: boot volume → block/data volume

Interactive:

```bash
sudo utilities/setup-storage.sh migrate run
```

Explicit:

```bash
sudo utilities/setup-storage.sh migrate run \
  --direction boot-to-block \
  --source /var/lib/vaultwarden \
  --target /mnt/vw-data \
  --device /dev/disk/by-id/<your-volume> \
  --force-format
```

The high-level pipeline:

1. validate commands, source, target, device, and storage safety;
2. require a recent/accepted backup confirmation unless explicitly bypassed with `--force`;
3. stop the stack unless `--skip-stack-stop` was explicitly requested and interactively accepted;
4. re-check stack stop immediately before data transfer;
5. prepare/mount the target according to the guarded storage contract;
6. rsync state while excluding dead sockets/PIDs and SQLite WAL/SHM files;
7. verify transfer size/content with the migration verification path;
8. update persistent environment/storage identity;
9. regenerate/synchronize installed runtime behavior required by the migration path;
10. start services according to `--start-policy`;
11. record completion and clean resumable state.

A step failure preserves migration state so `resume`, `status`, or `abort` can reason about the partially completed workflow.

---

## Reverse migration: block/data volume → boot volume

Use the explicit reverse direction:

```bash
sudo utilities/setup-storage.sh migrate run \
  --direction block-to-boot \
  --target /var/lib/vaultwarden
```

In interactive reverse mode, the device picker shows only mounted volumes whose complete VaultWarden filesystem identity validates against the selected device and expected mount target.

You may also provide the mounted source device explicitly:

```bash
sudo utilities/setup-storage.sh migrate run \
  --direction block-to-boot \
  --target /var/lib/vaultwarden \
  --device /dev/disk/by-id/<your-data-volume>
```

Do not use the old guidance that tells operators to unmount the source volume before migration or simulate reversal with an unrelated directory copy. Reverse migration must read the mounted source data and has a dedicated direction contract.

After a successful reverse migration, review `/etc/fstab` warnings printed by the migration utility and remove only obsolete old-source mount entries after verifying the resulting fstab.

---

## Data volume → another data volume

Attach the new target and run a normal forward migration from the current state path:

```bash
sudo utilities/setup-storage.sh migrate run \
  --source /mnt/vw-data \
  --target /mnt/vw-data2 \
  --device /dev/disk/by-id/<your-new-volume> \
  --force-format
```

Use `--force-format` only when the target is intentionally blank/signature-free and you have verified the device identity.

---

## Directory-to-directory migration

Omit `--device` completely:

```bash
sudo utilities/setup-storage.sh migrate run \
  --source /var/lib/vaultwarden \
  --target /srv/vaultwarden-state
```

No block-device formatting step occurs.

The migration transfer uses rsync deletion semantics so the target matches the source. A non-empty target is warned because target-only files may be removed.

Always preview an unusual directory target:

```bash
sudo utilities/setup-storage.sh migrate run \
  --source /var/lib/vaultwarden \
  --target /srv/vaultwarden-state \
  --dry-run
```

Do not manually clear a non-empty target with a broad `rm -rf` command merely because an older version of this guide suggested it. Confirm the target identity and use the migration dry run to understand the planned synchronization.

---

## Start policy

Migration supports:

```text
auto
ask
manual
```

Options:

```bash
--start-policy auto
--start-policy ask
--start-policy manual
--start       # alias for auto
--no-start    # alias for manual
```

Default behavior:

- interactive TTY run: `ask`;
- non-interactive or `--yes`: `auto`.

Use `manual`/`--no-start` when you need to inspect the migrated storage, environment, systemd installation, or provider state before starting Vaultwarden.

Example:

```bash
sudo utilities/setup-storage.sh migrate run \
  --source /var/lib/vaultwarden \
  --target /mnt/vw-data \
  --device /dev/disk/by-id/<your-volume> \
  --force-format \
  --no-start
```

After inspection:

```bash
sudo make up
sudo make health
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

---

## Migration subcommands

| Subcommand | Purpose |
| :-- | :-- |
| `run` | Start a new migration |
| `resume` | Continue from the recorded migration state after revalidation |
| `status` | Show recorded migration state |
| `abort` | Roll back the in-progress migration state where the pipeline supports rollback |
| `verify` | Re-run migration transfer verification |

Examples:

```bash
sudo utilities/setup-storage.sh migrate status
sudo utilities/setup-storage.sh migrate resume
sudo utilities/setup-storage.sh migrate abort
sudo utilities/setup-storage.sh migrate verify
```

`status`, `abort`, and `verify` do not accept behavior-changing run options. `resume` accepts only the documented resume-safe options.

When a migration fails, the error output prints the exact resume and abort commands.

---

## Important options

| Option | Meaning |
| :-- | :-- |
| `--source PATH` | Source state directory; default is current `PROJECT_STATE_DIR` in forward mode |
| `--target PATH` | Destination path; required with `--yes` |
| `--device DEV` | Explicit block device; omit for directory-to-directory migration |
| `--direction boot-to-block\|block-to-boot` | Migration direction |
| `--skip-stack-stop` | Migrate with the stack not intentionally stopped; interactive confirmation required; incompatible with `--yes` |
| `--delete-source` | Delete the verified renamed source; always requires typing the exact path |
| `--dry-run` | Preview operations |
| `--force` | Skip the pre-migration backup confirmation; does **not** authorize formatting |
| `--force-format` | Explicitly authorize formatting a blank/signature-free forward target device |
| `--yes` | Non-interactive confirmation for automatable prompts; requires `--target` |
| `--start-policy MODE` | `auto`, `ask`, or `manual` service-start behavior |
| `--start` | Alias for `--start-policy auto` |
| `--no-start` | Alias for `--start-policy manual` |
| `--log-file PATH` | Override migration log path |

For exact parser rules:

```bash
sudo utilities/setup-storage.sh migrate --help
```

---

## WAL and database handling

The normal migration path stops the stack and re-checks it before rsync.

SQLite WAL and SHM files are excluded from the transfer:

```text
*.sqlite3-wal
*.sqlite3-shm
```

A non-empty WAL after a clean source stop is a warning that should be investigated. You may run the guarded database-maintenance path before retrying:

```bash
sudo ./maintenance.sh db-maint
```

Do not manually copy WAL/SHM files to force a deceptively complete-looking target.

---

## `.vw-data-volume` filesystem identity marker

`.vw-data-volume` is a structured filesystem-identity proof, not filename-only authority. A marker is accepted only when the configured device UUID, the filesystem actually mounted at the expected target, and the marker's recorded filesystem UUID and mount target agree. The marker structure plus its root ownership and read-only mode are validated as part of the same check.

Migration protects the target-owned identity marker from rsync deletion/exclusion behavior. Reverse migration's interactive picker shows only mounted volumes whose complete filesystem identity validates against the selected device.

Do not create, copy, or remove the identity marker merely to bypass a storage error. Prove the device and mounted filesystem first, then use the supported setup/adoption/repair path.

---

## `.env`, persistent environment, and systemd runtime

Migration updates the accepted environment/storage identity as part of its pipeline. Current storage state is not represented only by repository `.env`; persistent and installed runtime configuration also matter.

After migration, inspect:

```bash
utilities/env-edit.sh status
sudo utilities/setup-storage.sh verify
sudo ./setup.sh systemd validate
```

When the host is ready for scheduled jobs, activate the current installed runtime:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

Do not hand-edit `/etc/vaultwarden/vaultwarden.env` to conceal an environment/storage mismatch.

---

## Verification after migration

Run:

```bash
sudo utilities/setup-storage.sh migrate verify
sudo utilities/setup-storage.sh verify
sudo utilities/repair-permissions.sh --check
sudo make health
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

Create and verify a fresh backup from the new storage layout:

```bash
sudo ./backup.sh run db
sudo ./backup.sh run full --full-verification
sudo ./backup.sh verify
```

If offsite sync is enabled:

```bash
sudo ./backup.sh sync
```

Only detach/delete the old data source after the new layout and a fresh recovery point are verified.

---

## Recovery after interruption

Start with operation and migration status:

```bash
sudo make operations
sudo utilities/setup-storage.sh migrate status
```

If the migration state is valid and the utility tells you to resume:

```bash
sudo utilities/setup-storage.sh migrate resume
```

To roll back the migration state through the owning workflow:

```bash
sudo utilities/setup-storage.sh migrate abort
```

Do not delete `.migrate-volume.state`, lock files, fstab entries, or volume identity markers as a first troubleshooting step. The recorded state is needed to reason about the partial pipeline.

---

## What not to do

Do not:

```bash
sudo cp -r /var/lib/vaultwarden /mnt/vw-data
sudo chmod -R 777 /mnt/vw-data
sudo chown -R 1000:1000 /mnt/vw-data
```

and then manually rewrite `.env`/systemd environment files.

Those commands bypass the project's stop/WAL, Caddy/root-owned permission, filesystem-identity, persistent environment, installed runtime, verification, and rollback contracts.
