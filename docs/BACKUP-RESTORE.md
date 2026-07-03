# Backup & Restore — VaultWarden-OCI

This guide is the operator-facing reference for VaultWarden-OCI backups and restores. It reflects the current root-operated model, the 2026 backup tier model, separate boot/block storage support, post-restore Age key rotation, operator-controlled service start, and post-restore runtime permission repair.

Related docs: [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md) · [RESTORE-RUNTIME-PERMISSIONS.md](RESTORE-RUNTIME-PERMISSIONS.md) · [OPERATIONS.md](OPERATIONS.md) · [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

---

## 💾 Backup Tiers

VaultWarden-OCI has three deliberately different backup tiers:

| Tier | Use | Contents | Key handling |
| --- | --- | --- | --- |
| `db` | Quick database rollback | A single encrypted, integrity-checked SQLite snapshot (`.sqlite3.age`) | Encrypted to the operational Age recipient. |
| `full` | Normal fresh-VM disaster recovery | Project root, state directory, persistent config, encrypted SOPS `secrets.yaml`, sidecars/metadata, and a verified DB injected at `${PROJECT_STATE_DIR}/data/db.sqlite3` | Excludes `/etc/vaultwarden/age-key.txt`; restore requires the offline Age recipient's private key or the operational Age key that encrypted that backup. |
| `emergency` | Fastest clone-style recovery | Everything in `full`, plus staged persistent `/etc/vaultwarden` key/config material such as `age-key.txt`, `vaultwarden.env`, and `rclone.conf` when present | Protected independently with `age -p` passphrase mode or `EMERGENCY_BACKUP_AGE_RECIPIENT`; it is never encrypted only to the operational key it contains. |

All tiers contain a complete verified SQLite database snapshot. Backups first try the SQLite Online Backup API (`sqlite3 .backup`). If that is unavailable or fails, Vaultwarden is stopped, the WAL is checkpointed, `db.sqlite3` is copied, integrity is verified, and Vaultwarden is restarted. No backup should report success with an unverified or partial database.

Full and emergency archives exclude live `db.sqlite3`, WAL/SHM files, backup directories, logs, temp files, sockets/locks, `.pre-restore-*` snapshots, decrypted runtime secrets, and `/run/vaultwarden-oci/secrets/*`. The verified staged DB is then added back to the archive at the normal live path, so `.pre-restore-*` databases never satisfy archive validation.

> **Warning:** Emergency backups are clone-grade secrets-bearing artifacts. Treat them like a password-manager vault export. Because they can contain the operational Age private key, they must be sealed with an independent passphrase prompt or a separate DR recipient (`EMERGENCY_BACKUP_AGE_RECIPIENT`). Do not store passphrases in shell history, environment variables, logs, or metadata.

Choose `db` for quick database rollback, `full` for a fresh VM restore when you have the offline Age recipient's private key or the operational Age key that encrypted the backup, and `emergency` when the fastest clone-style recovery is worth carrying key material inside the sealed capsule. The offline Age recipient is an optional extra Age public recipient for SOPS recovery; it is not the emergency passphrase for a passphrase-sealed emergency backup.

---

## 📦 Creating Backups

All production backup operations are root-operated because they read state, encrypted secrets, and root-owned runtime config.

```bash
# Database backup
sudo ./backup.sh run db
sudo make backup

# Full DR backup
sudo ./backup.sh run full
sudo make backup-full

# Clone-grade emergency backup
sudo ./backup.sh run emergency
sudo make backup-emergency
```

### Full verification

Use full verification before major changes, after storage migration, and for periodic DR confidence checks:

```bash
sudo ./backup.sh run full --full-verification
sudo ./backup.sh run emergency --full-verification
```

### Offsite sync

When rclone is configured, use `--rclone` to copy the encrypted backup and sidecars to the remote:

```bash
sudo ./backup.sh run db --rclone
sudo ./backup.sh run full --full-verification --rclone
sudo ./backup.sh sync
```

`backup.sh sync` copies retained local backups to the matching remote folders. It does not mirror-delete remote backups merely because a local copy is absent.

### Retention

Retention defaults are type-specific:

| Tier | Default retention |
| :-- | :-- |
| `db` | 14 days |
| `full` | 30 days |
| `emergency` | 90 days |

Override per run with `--keep N`:

```bash
sudo ./backup.sh run full --keep 30
```

`--keep` accepts only positive integers. Values that are empty, non-integer, or shell-injectable are rejected during argument parsing.

---

## 🔎 Restore Storage-Layout Preflight

Before a destructive full or emergency restore, inspect the selected archive and the target storage layout:

```bash
sudo ./restore.sh inspect --remote
# or
sudo ./restore.sh interactive --remote --inspect
```

The report shows the backup source layout, current target layout, live DB presence, snapshot-only DBs, required directories, and a recommended next action.

Database backups are storage-layout independent and are the safest option when only Vaultwarden data is needed. Full and emergency archives restore broader application state/config and require a compatible, prepared target storage layout.

Block-storage backups should be restored to a mounted block/data-volume target, not silently into boot storage. If a backup expects `/mnt/vw-data` or another data-volume root and the current host targets `/var/lib/vaultwarden` on boot storage, restore stops before services are stopped. Attach and configure the data volume first, or restore the latest DB backup.

Prepared block-storage targets must provide these entries under `PROJECT_STATE_DIR` / `DATA_VOLUME_MOUNT`: `data`, `caddy`, `logs`, `config`, `secrets`, `backups`, and the `.vw-data-volume` sentinel. When the volume is already mounted and writable, restore may safely recreate missing directories and the sentinel. It will not format, partition, or guess block devices.

---

## 🔄 Restore Flow

`restore.sh` follows an auditable root-operated sequence:

| Step | What happens |
| :-- | :-- |
| 1 | Select backup by menu, `latest`, `--file`, or `--remote` |
| 2 | Validate storage readiness before destructive actions |
| 3 | Prompt for or resolve the Age identity/passphrase that decrypts this backup |
| 4 | Verify integrity sidecars when present |
| 5 | Parse `.meta` sidecar for type, format, version, and storage metadata |
| 6 | Ask final confirmation unless `--force` was provided |
| 7 | Create a pre-restore safety backup unless `--no-backup` was provided |
| 8 | Stop services |
| 9 | Restore `db`, `full`, or `emergency` content |
| 10 | Re-key persistent SOPS secrets and promote the new operational Age key |
| 11 | Re-apply runtime permissions for the target host |
| 12 | Start services according to start policy and run health checks |

Full and emergency restores extract with portable ownership/mode handling first, then re-apply the target host's runtime permission contract. This prevents stale archive ownership from breaking a replacement VM while still keeping root-operated secrets private and Caddy writable. See [RESTORE-RUNTIME-PERMISSIONS.md](RESTORE-RUNTIME-PERMISSIONS.md).

---

## 🔐 Supplying the Decryption Key

Use the key that can decrypt the selected backup, not necessarily the key currently installed on the server.

```bash
# Interactive prompt
sudo ./restore.sh latest full

# Explicit key file
sudo ./restore.sh latest full --key-file /path/to/old-age-key.txt

# Environment-based scripted restore
RESTORE_AGE_KEY_FILE=/path/to/old-age-key.txt sudo ./restore.sh latest db

# Recovery kit path when applicable
sudo ./restore.sh interactive --remote --from-recovery-kit /path/to/recovery-kit.txt
```

If decryption fails because no Age identity matches, the backup may have been encrypted with an older operational Age key or an offline Age recipient's private key. Retry with the key that was active when the backup was created.

Emergency backups may be passphrase-sealed (`age -p`) or encrypted to `EMERGENCY_BACKUP_AGE_RECIPIENT`. A passphrase-sealed emergency backup will prompt for that emergency passphrase during decrypt/verification.

### Restore-time passphrase prompts

Two different prompts can appear during restore:

- The selected `db` or `full` backup is decrypted with the Age private key prompt. Use the Age private key that matches the Age public recipient used when that backup was created.
- A separate emergency passphrase prompt can appear because `restore.sh` creates a pre-restore emergency snapshot of the current VM before overwrite. That emergency passphrase protects the safety snapshot, not the selected `db`/`full` backup.

Keep the pre-restore emergency snapshot on existing/live VMs unless you understand the rollback risk. On a freshly rebuilt VM where the current local state has no value and only a remote DB backup is being restored, `sudo ./restore.sh interactive --remote --no-backup` is an intentional shortcut.

### Fresh-server rclone prompts

On a fresh server without `.env`, `sudo ./restore.sh interactive --remote` and `sudo ./restore.sh inspect --remote` can ask for the rclone remote name and remote path. Enter the configured rclone remote name (for example `b2`, `gdrive`, or `s3`) and the backup subfolder (default: `vaultwarden_backups`). These values are session-scoped so restore can find the remote backup; they are not written to `.env` unless you save them separately.

---

## 🚦 Operator-Controlled Service Start

Restore and migration workflows support an explicit start policy:

| Option | Behavior |
| :-- | :-- |
| `--start-policy auto` or `--start` | Start services automatically after successful restore/migration. |
| `--start-policy ask` | Prompt before starting. Interactive restores default to this and ask `Start VaultWarden services now? [yes/no] (default: no):`. |
| `--start-policy manual` or `--no-start` | Do not start services; print the manual checklist instead. |

Use `manual` or `ask` when you want to inspect `.env`, `/etc/vaultwarden/*`, mounted storage, Cloudflare/DNS, and firewall state before the stack starts.

Manual start checklist:

```bash
sudo utilities/repair-permissions.sh
sudo ./startup.sh --skip-pull
docker compose ps
docker compose logs --tail=100
sudo ./maintenance.sh health
```

---

## 🧰 Post-Restore Runtime Permission Repair

Full and emergency restores automatically call the runtime permission repair helper before the service-start gate.

Manual repair command:

```bash
sudo utilities/repair-permissions.sh
sudo docker compose restart caddy
sudo ./maintenance.sh health
```

Expected health indicator:

```text
[pass] permissions:caddy-storage    Caddy storage/log permissions are correct
```

This step normalizes, among other paths:

- `${PROJECT_STATE_DIR}/data` to `${PUID}:${PGID}`;
- `${PROJECT_STATE_DIR}/caddy/data`, `${PROJECT_STATE_DIR}/caddy/config`, and `${PROJECT_STATE_DIR}/logs/caddy` to `2000:2000`;
- root-operated config/secrets under `${PROJECT_STATE_DIR}/config`, `${PROJECT_STATE_DIR}/secrets`, `/etc/vaultwarden`, and `/run/vaultwarden-oci/secrets`.

It also removes a restored `${PROJECT_STATE_DIR}/data/.permissions-initialized` sentinel so startup cannot skip a host-specific permission scan after DR.

Do not repair restore drift with broad commands such as `chmod -R 777` or `chown -R 2000:2000 ${PROJECT_STATE_DIR}`. Those commands can expose root-operated secrets or break SOPS state.

---

## 🧭 Common Restore Scenarios

### Database rollback

```bash
sudo ./restore.sh latest db
sudo ./maintenance.sh health
```

Use this when only Vaultwarden database contents need rollback. It is storage-layout independent.

### Full fresh-VM restore

```bash
sudo ./restore.sh inspect --remote
sudo ./restore.sh interactive --remote --key-file /path/to/offline-age-key.txt --start-policy ask
sudo ./setup.sh systemd install
sudo ./maintenance.sh health
```

Use this for normal DR when you have the offline Age recipient's private key or the operational Age key that encrypted the selected full backup. The offline Age recipient is an optional extra recipient for decrypting/recovering SOPS material; it is not the emergency passphrase used for a passphrase-sealed emergency backup.

### Emergency clone-style restore

```bash
sudo ./restore.sh interactive --remote --start-policy ask
sudo utilities/repair-permissions.sh
sudo ./startup.sh --skip-pull
sudo ./maintenance.sh health
```

Use this when the fastest clone-style recovery is worth restoring sealed `/etc/vaultwarden` material from the emergency capsule.

### Failed update rollback

`maintenance.sh update` can call restore automatically when post-update health checks fail. Manual rollback remains available:

```bash
sudo ./restore.sh latest full --force --no-backup
```

---

## Verification After Restore

After any restore, verify:

```bash
sudo ./maintenance.sh health
sudo ./backup.sh verify
sudo make key-health
sudo make timers
```

For Caddy/TLS symptoms after a full or emergency restore:

```bash
DOMAIN="vault.example.com"

curl -vk --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/alive" \
  -o /dev/null -w "local HTTPS /alive: HTTP %{http_code}\n"

curl -vk --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/api/config" \
  -o /dev/null -w "local HTTPS /api/config: HTTP %{http_code}\n"

sudo docker logs vaultwarden_caddy --tail=120 2>&1 \
  | grep -Ei 'permission|certificate|tls|handshake|error|warn|storage|autosave' || true
```

Expected result: local HTTPS `/alive` and `/api/config` return HTTP `200`, and health reports no Caddy storage drift.

---

## Recovery Kit and Key Escrow

Export a recovery kit after initial setup and after any Age key rotation:

```bash
sudo ./utilities/secrets-export-recovery-kit.sh
```

Store the recovery kit in a password manager and an offline location. If a restore rotates the operational key, update your escrow immediately before considering the DR complete.

---

## Monthly / Quarterly Checklist

- Daily: DB backup runs and offsite sync succeeds.
- Weekly: Full backup with `--full-verification` succeeds.
- Monthly: Emergency clone-grade backup is created and sealed independently.
- Quarterly: Rehearse restore on a disposable VM or copied state volume; never rehearse on the live production state volume.
