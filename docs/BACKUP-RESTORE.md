# Backup and Restore — VaultWarden-OCI

This guide reflects the current backup and restore model used by the repository: encrypted backup archives created by `backup.sh`, restore workflows driven by `restore.sh`, optional offsite sync through rclone, and recovery material managed through the Age + SOPS workflow.

Related docs: [OPERATIONS.md](OPERATIONS.md) · [BOOTSTRAP_KEY_RECOVERY.md](BOOTSTRAP_KEY_RECOVERY.md) · [SCRIPTS.md](SCRIPTS.md)

---

## Backup model

The project currently supports three backup types:

| Type | Purpose | Notes |
| :-- | :-- | :-- |
| `db` | Fast database-focused backup | Best for frequent scheduled protection |
| `full` | Broader system-state backup | Use before larger changes and for regular full recovery points |
| `emergency` | Disaster-recovery archive | Use before high-risk changes and for server-loss scenarios |

All normal backup flows are encrypted. Recovery depends on preserving the required key material outside the server.

---

## Recovery material

Your backups are only as good as your ability to decrypt them later.

Critical items to protect:

- `secrets/keys/age-key.txt`
- Any exported recovery kit produced by `./edit-secrets.sh --export-recovery-kit`
- Any separate offline escrow or paper backup you maintain for the Age key

Recommended step after deployment or secret changes:

```bash
./edit-secrets.sh --export-recovery-kit
```

Store recovery material outside the server and outside the same failure domain as the primary VM.

---

## Creating backups

### Database backup

```bash
./backup.sh --type db
make backup
make db-backup
```

Use this for the normal fast backup path.

### Full backup

```bash
./backup.sh --type full
make backup-full
```

Use this for regular broader recovery points and before meaningful system changes.

### Emergency backup

```bash
./backup.sh --type emergency
make backup-emergency
```

Use this before high-risk changes or when you want the strongest rebuild path available.

---

## Verification and remote sync

### Full verification

```bash
./backup.sh --type full --full-verification
./backup.sh --type emergency --full-verification
```

Use full verification for higher-confidence backups, especially before major upgrades, infrastructure moves, or risky customization work.

### rclone offsite copy

```bash
./backup.sh --type db --rclone
./backup.sh --type full --rclone --email
```

Configure the remote in your environment before relying on offsite copy:

```bash
rclone config
nano .env
```

Set or review `RCLONE_REMOTE_NAME`, then test with a manual run before assuming cron coverage is sufficient.

---

## Retention

Retention should be treated as a deployment setting, not a fixed value hard-coded in documentation.

Current tuning options:

- Override a run with `--keep N`.
- Review or adjust the default retention in `.env`.

Example:

```bash
./backup.sh --type full --keep 30
```

This is the safer way to describe the project because deployed values can differ across environments.

---

## Listing and selecting backups

```bash
./backup.sh --list
make list-backups
```

Use the listing flow before a restore if you want to confirm available archives, timestamps, and which recovery tier you intend to use.

---

## Restore workflows

### Interactive restore

```bash
./restore.sh
make restore
```

This is the preferred restore path for most operators because it guides archive selection and reduces the chance of restoring the wrong backup.

### Latest backup restore

```bash
./restore.sh --latest --type db
./restore.sh --latest --type full
```

Use this when you already know the recovery tier you want and you are comfortable with a non-interactive selection path.

### Specific archive restore

```bash
./restore.sh --file /path/to/backup.age
./restore.sh --file /path/to/backup.age --force
```

This is useful for disaster recovery, archived offsite pulls, or testing a particular recovery point.

---

## Common recovery scenarios

### Database-only recovery

```bash
docker compose stop vaultwarden
./restore.sh --latest --type db
./health.sh
```

Use this when the application is intact but the database needs to be rolled back.

### Full environment recovery

```bash
docker compose down
./restore.sh --latest --type full
./startup.sh
./health.sh
```

Use this when broader configuration or service-state recovery is required.

### Rebuild on a fresh server

```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com
./restore.sh --file /path/to/emergency-backup.age --force
./health.sh
```

This is the normal pattern for complete host loss or migration to a new VM.

### Rollback after a failed update

`update.sh` is the preferred update path partly because it is designed around validation and recovery logic.

If you need to trigger a manual rollback path yourself:

```bash
./restore.sh --latest --type full --force
./health.sh
```

---

## Scheduled operations

Cron installation wires backup behavior into the project’s automation model:

```bash
sudo ./cron-setup.sh --install
sudo ./cron-setup.sh --list
sudo ./cron-setup.sh --validate
```

The current operational pattern is:

- Regular database backups during the week.
- A weekly full backup cycle.
- Health checks and other maintenance as separate automated jobs.

Review [OPERATIONS.md](OPERATIONS.md) for the current documented schedule.

---

## Integrity and validation

Use these checks when validating backup readiness:

```bash
./backup.sh --type db
./backup.sh --type full --full-verification
./restore.sh
./health.sh --comprehensive
```

A backup strategy is not complete until you have also tested the restore path.

---

## Troubleshooting

### Not enough disk space

```bash
df -h
./maintenance.sh --comprehensive
```

### Age key issues

```bash
ls -la secrets/keys/age-key.txt
./edit-secrets.sh --test
```

If the key is missing or unusable, recover it from your recovery kit or other offline escrow before assuming the backups are restorable.

### rclone issues

```bash
rclone lsd your_remote_name:
./backup.sh --type db --rclone
```

Test remote sync manually before depending on unattended runs.

### Restore uncertainty

Use the interactive restore flow first. It is usually safer than jumping straight to forced command-line recovery when you are under time pressure.

---

## Recommended policy

For most small-team deployments, a good operating baseline is:

- Frequent `db` backups.
- Regular `full` backups with periodic full verification.
- An `emergency` backup before risky changes.
- Offsite encrypted copies through rclone if available.
- Recovery material exported and stored separately from the host.
- Periodic restore drills, not just backup creation.

That combination matches the repository’s current recovery-first design.
