# Backup & Restore — VaultWarden-OCI

All backups are encrypted with **Age** and managed by `backup.sh`. The backup lock uses `flock` with bash automatic FD allocation (`exec {LOCK_FD}>file`) so the kernel assigns a safe, unused file descriptor at runtime. `FD_CLOEXEC` is set so child processes cannot inherit and hold the lock open after fork/exec. The kernel releases the lock automatically on any process exit, including SIGKILL and OOM kill.

Related docs: [OPERATIONS.md](OPERATIONS.md) · [SCRIPTS.md](SCRIPTS.md) · [ADVANCED-CUSTOMIZATION.md](ADVANCED-CUSTOMIZATION.md) · [BOOTSTRAP_KEY_RECOVERY.md](BOOTSTRAP_KEY_RECOVERY.md)

---

> **Bare-Metal Disaster Recovery**
> If you are recovering from total server loss, see the dedicated
> [Disaster Recovery guide](./DISASTER-RECOVERY.md) for the minimal-touchpoint
> procedure that covers dependency installation, repo checkout, and single-command
> restore from a remote backup.

## 💾 Backup Tiers

| Type | Contents | Retention | Age Key Required |
| :-- | :-- | :-- | :-- |
| **Database** (`db`) | SQLite database snapshot only | 14 days | Yes |
| **Full** (`full`) | Project root + state directory, excluding `.git`, `backups/`, `logs/`, `.rate-limit`, `secrets/`, `*.sock`, `*.lock`, `*.tmp`, and `*.age.tmp` | 30 days | Yes |
| **Emergency** (`emergency`) | Same contents as full backup | 90 days | Yes |

> **⚠️** Database, full, and emergency backups all require your Age key (`secrets/keys/age-key.txt`) to decrypt. The `secrets/` directory and Age key are excluded from the archives, so back up the key separately and store it offline or in another secure location before restoring to a new server.

---

## 📦 Archive Format

### File naming and extensions

| Backup type | Encrypted file | Sidecar files |
| :-- | :-- | :-- |
| `db` | `db_backup_YYYYMMDD_HHMMSS.sqlite3.age` | `.sha256`, `.sha256.hmac`, `.meta` |
| `full` | `full_backup_YYYYMMDD_HHMMSS.tar.zst.age` | `.sha256`, `.sha256.hmac`, `.meta` |
| `emergency` | `emergency_backup_YYYYMMDD_HHMMSS.tar.zst.age` | `.sha256`, `.sha256.hmac`, `.meta` |

Full and emergency archives are compressed with **zstd** (threaded, level 3: `zstd -T0 -3`), replacing the previous gzip compression. The `.tar.zst.age` extension reflects this. Database-only backups are a raw SQLite file encrypted directly with Age — no compression layer.

Each new backup produces four files:

| File | Purpose |
| :-- | :-- |
| `*.age` | Encrypted backup archive |
| `*.sha256` | Post-encryption SHA-256 checksum (generated automatically) |
| `*.sha256.hmac` | HMAC-SHA256 authentication of the checksum using the SOPS-managed `file_integrity_hmac_key` |
| `*.meta` | Metadata (type, timestamp, archive format, version) |

### Retention age calculation

Retention is based on the **`YYYYMMDD_HHMMSS` timestamp embedded in the filename** (immutable across `cp`, `mv`, `chmod`, `chown`). This prevents a known failure mode where backups restored to a fresh host showed `ctime = now`, appeared 0 days old, and were never pruned. The ctime fallback is used only for files predating the current naming convention.

Orphaned sidecar files (`.meta`, `.sha256`, `.sha256.hmac`) whose corresponding `.age` primary is absent are removed on every cleanup sweep.

---

## 📦 Creating Backups

### Database Backup (Daily)

```bash
./backup.sh run db                        # default
./backup.sh run db --rclone               # with offsite sync
./backup.sh run db --email                # with email notification
make backup                             # database backup via Makefile
```

### Full System Backup (Weekly)

```bash
./backup.sh run full                      # fast checksum + decrypt probe
./backup.sh run full --full-verification  # end-to-end decrypt + integrity test
./backup.sh run full --full-verification --rclone --email
make backup-full                        # full backup via Makefile
```

**Included:** Project root, state directory, and a SQLite database snapshot.
**Excluded:** `.git`, `backups/`, `logs/`, `.rate-limit`, `secrets/`, `*.sock`, `*.lock`, `*.tmp`, and `*.age.tmp`. The Age key is not included and must be backed up separately.

### Emergency Recovery Kit (As Needed)

```bash
./backup.sh run emergency                  # same archive contents as full backup
./backup.sh run emergency --full-verification --rclone --email
make backup-emergency                   # emergency kit via Makefile
```

> ⚠️ Emergency backups do **not** include the `secrets/` directory or the Age key. Store the Age key securely offline as a separate backup.

### List & Inspect Backups

```bash
./backup.sh list
make list-backups
```

### Retention control

Retention defaults are type-specific (`db` 14 days, `full` 30 days, `emergency` 90 days). Override per run with `--keep N`:

```bash
sudo ./backup.sh run db --keep 30
```

`--keep` accepts only positive integers; non-integer or shell-injectable values (e.g. `"14; rm -rf /"`) are rejected immediately after argument parsing.

Configured retention is resolved per type: `BACKUP_RETENTION_DB_DAYS`, `BACKUP_RETENTION_FULL_DAYS`, or `BACKUP_RETENTION_EMERGENCY_DAYS`, then `BACKUP_RETENTION_DAYS`, then the built-in fallback. An explicit `--keep N` overrides every configured value for that invocation.

---

## 🔄 Verification Modes

| Mode | Flag | Speed | What It Tests |
| :-- | :-- | :-- | :-- |
| Quick (default) | *(none)* | Seconds | SHA-256 checksum + Age decrypt probe |
| Full | `--full-verification` | Minutes | Decrypt → extract → DB integrity check |

The quick mode always performs an Age decrypt probe and verifies the checksum HMAC when available. New installations set `REQUIRE_AUTHENTICATED_INTEGRITY=true`, making a missing or invalid HMAC sidecar a hard failure. Upgraded installations can temporarily leave it false while rotating `file_integrity_hmac_key` and generating new backups.

Use quick for daily automated backups; full for weekly and before major changes.

---

## 🗄️ Database Snapshot Integrity

`backup.sh` uses the **SQLite Online Backup API** (`sqlite3 .backup`) to produce a fully consistent database snapshot while VaultWarden is running. This replaces the previous approach of three sequential `cp` calls, which could capture an inconsistent state if VaultWarden committed a transaction between copies.

For the WAL checkpoint fallback path (used only when the host `sqlite3` binary cannot be found), the script:
1. Stops the VaultWarden container and waits up to 30 seconds for it to reach `exited` state.
2. Validates the WAL checkpoint result (`PRAGMA wal_checkpoint(TRUNCATE)`) — if any WAL pages remain unincorporated, the backup is aborted rather than producing a partial snapshot.
3. Restarts the container after the copy.

---

## 🔑 Age Key Protection (`lib/crypto.sh`)

Your Age key (`secrets/keys/age-key.txt`) is the single point of failure for all backup decryption. If you lose it, **every backup is permanently unrecoverable**. `lib/crypto.sh` provides three complementary protection tiers.

> **Lost your Age key?** See [BOOTSTRAP_KEY_RECOVERY.md](BOOTSTRAP_KEY_RECOVERY.md) for the complete recovery procedure, including the GPG-wrapped offsite key workflow and a quarterly recovery drill.

### Tier 1 — Automatic Health Check (runs on every backup)

`backup.sh` validates the Age key before every backup run. It checks that the key file exists, auto-corrects permissions to 600 if needed, validates the key structure (including the `AGE-SECRET-KEY-1` prefix on the private key body), and performs a live encrypt/decrypt roundtrip using `printf '%s'` for deterministic byte handling. If the check fails, the backup is aborted. Call `make key-health` or use the dashboard key-verify menu option.

No action required — this runs automatically.

### Tier 2 — Password Manager Escrow (recommended after setup)

Exports a formatted plain-text document containing the Age private key, public key, and recovery instructions — ready to paste as a Secure Note in Bitwarden, 1Password, or similar.

```bash
# Export the Age key escrow document via utilities/secrets-edit.sh:
sudo ./utilities/secrets-export-recovery-kit.sh

# ⚠️ Copy contents to your password manager NOW, then securely delete:
shred -fuz ~/vaultwarden-age-key-escrow.txt
```

Re-run this any time you rotate the Age key.

### Tier 3 — Paper Backup (optional, for physical offline storage)

Generates a printable PDF (or HTML if `wkhtmltopdf` is not installed) containing the Age key, optional QR code, and recovery steps. The temp HTML file is securely wiped after PDF generation.

```bash
# Install optional dependencies
sudo apt install qrencode wkhtmltopdf

# `make key-backup` copies the Age key to `$HOME/age-key-backup-<timestamp>.txt`
# for offline safekeeping.
make key-backup

# Print and store in a fireproof safe, then delete the file
```

> **When to run each tier:**
> - Tier 1: automatic on every `backup.sh` run
> - Tier 2: after initial setup and after any Age key rotation
> - Tier 3: optional — for physical offline copies in a fireproof safe or safety deposit box

---

## ☁️ Offsite Storage (rclone)

`backup.sh` reads `RCLONE_REMOTE_NAME` from `.env` and syncs the encrypted archive plus `.meta`, `.sha256`, and `.sha256.hmac` sidecars to `${RCLONE_REMOTE_NAME}:vaultwarden_backups/${type}/` when `--rclone` is passed.

To backfill every retained local backup to its corresponding remote folder in one operation, use the dashboard Backup menu option **Copy All Local Backups to Rclone Remote** or run:

```bash
sudo ./backup.sh sync
```

The command copies rather than mirrors, so it never deletes a remote file merely because the local copy is absent. It applies local retention before upload and the same per-type retention rules to the remote afterward.

**Rclone failure is fatal when `--rclone` is set** — a missing binary or unconfigured remote causes a non-zero exit so monitoring and the systemd timer capture the failure. The rclone config path (`RCLONE_CONFIG`) is validated before use: shell metacharacters, world-writable files, and paths resolving into sensitive system locations are all rejected.

```bash
# 1. Install rclone (if not already present)
curl https://rclone.tech/install.sh | sudo bash

# 2. Configure a remote
rclone config

# 3. Set the remote name in .env
RCLONE_REMOTE_NAME=your_remote_name

# 4. (Optional) set a custom config path
RCLONE_CONFIG=/path/to/rclone.conf

# 5. Test
./backup.sh run db --rclone

# 6. Verify remote contents
rclone ls your_remote_name:vaultwarden_backups/
```

`sudo ./setup.sh systemd install` (or `make install-systemd`) provisions systemd timers for automated backups:

| Timer | Schedule | Command |
| :-- | :-- | :-- |
| `vaultwarden-db-backup.timer` | Daily 04:00 (+ 0–60 s jitter) | `backup.sh run db --rclone --full-verification` |
| `vaultwarden-full-backup.timer` | Sunday 03:00 (+ 0–300 s jitter) | `backup.sh run full --rclone --full-verification` |

Check timer status:

```bash
make timers
journalctl -u vaultwarden-db-backup.service --since today
```

---

## ⏪ Restoring

### The Restore Flow (12 Steps)

`restore.sh` now follows a numbered, auditable sequence designed to minimise downtime and operator interactions:

| Step | What happens |
| :-- | :-- |
| 1 | Select backup (interactive menu, `--file`, `--latest`, or `--remote`) |
| 2 | **Prompt for the age decryption key** — the key that encrypted *this specific backup* |
| 3 | Verify `.sha256` sidecar checksum |
| 4 | Parse `.meta` sidecar (version/format detection) |
| 5 | Final operator confirmation prompt |
| 6 | Pre-restore emergency snapshot (unless `--no-backup`) |
| 7 | Stop Docker services |
| 8 | Perform restore (`db` / `full` / `emergency`) |
| 9 | Prune old pre-restore artefacts |
| 10 | **Generate + rotate a new age key** |
| 11 | **Display new key prominently — operator must type `SAVED` (all caps) to confirm** |
| 12 | Start services + health check |

> **Why rotate the key after restore?** A restore rewrites data from a potentially old backup. The key in use at backup time may have been compromised or lost. Generating a new key immediately after restore ensures the next backup uses a fresh, uncompromised key and brings the stack to a known-good security baseline with a single operation.

### Supplying the Decryption Key

At step 2, `restore.sh` resolves the decryption key using the following priority order:

| Priority | Source | Use case |
| :-- | :-- | :-- |
| 1 (highest) | `--key-file <path>` CLI flag | Scripted / automated restores |
| 2 | `RESTORE_AGE_KEY_FILE` env var (set in `.env`) | CI pipelines / systemd |
| 3 | Interactive `read -s` prompt (no terminal echo) | Normal operator restore |
| 4 (fallback) | Press Enter (blank) → uses `SOPS_AGE_KEY_FILE` | Restoring with the current key |

The entered key is written to a `chmod 600` temp file inside the restore temp directory. The `cleanup()` trap **always** wipes it on exit regardless of success or failure.

Before any restore work begins, the key is validated with a live **encrypt/decrypt round-trip** so a wrong key is caught immediately.

### Interactive Restore (Recommended)

```bash
# Standard interactive restore — prompts for backup selection and age key:
sudo ./restore.sh interactive
make restore

# Restore from a remote (rclone) backup:
sudo ./restore.sh interactive --remote
make restore-remote
```

### Command-Line Restore

```bash
# Restore the latest backup of a specific type
sudo ./restore.sh latest full
sudo ./restore.sh latest db

# Supply the decryption key non-interactively
RESTORE_AGE_KEY_FILE=/path/to/old-age-key.txt sudo ./restore.sh latest db

# Automated pipeline restore (no prompts; key via env)
RESTORE_AGE_KEY_FILE=/root/keys/age-key-old.txt \
  sudo ./restore.sh latest db --force

# Restore a specific file
sudo ./restore.sh latest --file /path/to/backup.age
sudo ./restore.sh latest --file /path/to/backup.age --force

# Restore the latest backup, skip confirmation and skip pre-restore backup
# (used internally by maintenance.sh update rollback)
sudo ./restore.sh latest full --force --no-backup
```

> **Note on `--force`:** Suppresses the confirmation prompt (step 5) and the key acknowledgement prompt (step 11). Useful for automated invocations. The key prompt (step 2) is still evaluated — supply a key via `RESTORE_AGE_KEY_FILE`, or set `SOPS_AGE_KEY_FILE` as the fallback.

### Post-Restore Key Rotation

After data is successfully restored (step 10), a brand-new age key pair is atomically generated and installed to **all configured locations** before services start:

- `secrets/keys/age-key.txt` — project-local copy (atomic `mktemp` → `mv`, no 644 exposure window)
- `/etc/vaultwarden/age-key.txt` — systemd canonical location, only if the file already exists
- `SOPS_AGE_KEY_FILE=` updated in `.env` via in-place `sed`
- `SOPS_AGE_KEY_FILE=` updated in `/etc/vaultwarden/vaultwarden.env` if present
- The old key is preserved as `age-key.txt.pre-rotate-<timestamp>` before overwrite (only the 2 most recent backups are kept)

The new key is then displayed in the same prominent banner style as a fresh `setup.sh` run (step 11):

```
  ╔══════════════════════════════════════════════════════════╗
  ║       ⚠️  SAVE YOUR NEW AGE ENCRYPTION KEY  ⚠️         ║
  ╚══════════════════════════════════════════════════════════╝

  Private key:   AGE-SECRET-KEY-1...
  Public key:    age1...
  Installed at:  secrets/keys/age-key.txt
```

The operator must type `SAVED` (all caps) to confirm they have saved the key before services start. Under `--force`, this acknowledgement step is suppressed (suitable for automated pipelines).

**Key rotation failure is non-fatal** — if key generation fails for any reason, services still start and a recovery message is shown. The old key remains in place.

**After restore, re-run the Tier 2 escrow** to update your password manager with the new key:

```bash
sudo ./utilities/secrets-export-recovery-kit.sh
# Copy to password manager, then:
shred -fuz ~/vaultwarden-age-key-escrow.txt
```

**Quick key status check:**

```bash
make key-show    # shows path, permissions, public key
make key-rotate  # standalone key rotation (outside of restore)
```

### Exit Codes

| Code | Meaning |
| :-- | :-- |
| `0` | Restore completed successfully |
| `1` | Restore failed or critical phase error |

---

## 🚨 Disaster Recovery Scenarios

### Scenario 1 — Database Corruption

```bash
docker compose stop vaultwarden
make restore-db    # restores the latest DB backup and prompts for the age key
make health
```

### Scenario 2 — Configuration Loss

```bash
docker compose down
make restore       # interactive: select full backup, supply age key
docker compose config   # validate
make start
```

### Scenario 3 — Complete Server Loss

```bash
# 1. Provision a replacement Ubuntu host, open required provider ingress (80/443/22),
#    and attach any dedicated data volume before setup if you use separate-volume mode.
# 2. Clone repo
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

# 3. Pull emergency kit from offsite
rclone copy your_remote_name:vaultwarden_backups/emergency/ ./backups/emergency/

# 4. Run setup (generates baseline config, new age key)
sudo ./setup.sh install --domain vault.yourdomain.com --email admin@yourdomain.com

# 5. Restore emergency backup
#    restore.sh will prompt for the age key that encrypted this backup.
#    Use your separately backed-up Age key, or pass it directly with
#    RESTORE_AGE_KEY_FILE.
RESTORE_AGE_KEY_FILE=/path/to/offline-age-key.txt \
  sudo ./restore.sh latest --file ./backups/emergency/emergency_backup-TIMESTAMP.tar.zst.age

# 6. A new age key is generated automatically after the restore.
#    Save the new key when prompted, then verify:
make health
make key-show
```

> **Note:** Emergency kit archives use the `.tar.zst.age` extension (zstd-compressed). Adjust the filename to match your actual backup file.

### Scenario 4 — Failed Update (Auto-Rollback)

`maintenance.sh update` triggers this automatically when its post-update health check fails:

```bash
sudo ./restore.sh latest full --force --no-backup
```

If you need to trigger it manually:

```bash
make restore    # interactive: select full backup, supply age key
```

---

## 🛠️ Troubleshooting

**"Insufficient disk space"**

```bash
df -h
./maintenance.sh   # runs cleanup as part of full maintenance
```

**"Database snapshot failed"**

```bash
docker compose logs vaultwarden
sudo ./maintenance.sh db-maint   # offline SQLite VACUUM + WAL checkpoint
./backup.sh run db
```

**"WAL checkpoint incomplete"**

This means unincorporated WAL pages remain after `PRAGMA wal_checkpoint(TRUNCATE)`. The backup was deliberately aborted to avoid an inconsistent snapshot. Fix:

```bash
# Option 1: Stop VaultWarden and retry
docker compose stop vaultwarden
./backup.sh run db
docker compose start vaultwarden

# Option 2: Run offline maintenance to force a clean checkpoint
sudo ./maintenance.sh db-maint
./backup.sh run db
```

**"Encryption failed" / Age key missing**

```bash
make key-show   # check path, permissions, public key

# Verify the Age key
make key-health
# or use the dashboard key-verify menu option

# If missing, restore from your password manager escrow (Tier 2)
# or from an emergency kit, then re-run setup:
sudo ./setup.sh install --domain vault.yourdomain.com --email admin@yourdomain.com --force
```

**"Wrong key / decryption failed during restore" (step 2 validation)**

```bash
# restore.sh validates the key with a live encrypt/decrypt round-trip
# before any restore work begins. If you see this error:

# 1. Confirm you are using the key that was active when this backup was created.
#    The public key comment in the backup's age header should match:
grep '# public key:' /path/to/old-age-key.txt

# 2. Verify the checksum of the backup archive first:
sha256sum -c backup.age.sha256

# 3. Try an older backup (the key may have been rotated since this backup was made):
make restore    # select an older backup from the list

# 4. If you have a matching key file, pass it directly:
RESTORE_AGE_KEY_FILE=/path/to/matching-age-key.txt sudo ./restore.sh latest --file /path/to/backup.age
```

**"rclone sync failed"**

```bash
rclone lsd your_remote_name:
rclone config show your_remote_name
./backup.sh run db --rclone 2>&1 | tee /tmp/backup-debug.log

# If RCLONE_CONFIG is set, verify it passes validation:
# - no shell metacharacters
# - regular file, not world-writable
# - does not resolve into a sensitive system path
```

**"Invalid --keep value"**

`--keep` accepts only a positive integer. Values like `"14; rm -rf /"` are rejected immediately after argument parsing as a command-injection guard.

**"New key not showing after restore"**

If key rotation failed non-fatally during restore, services are still running with the old key. Check:

```bash
make key-show                     # confirm current key path and public key
make key-rotate                   # rotate manually if needed (requires sudo)
make systemd-validate             # confirm systemd scripts are in sync
sudo make install-systemd         # re-sync /opt scripts and reload timers
```

---

## ⏱️ Recovery Time Reference

| Scenario | Estimated Time | Max Data Loss |
| :-- | :-- | :-- |
| Database restore | 5–10 min | Up to 24 h (last db backup) |
| Full system restore | 15–30 min | Up to 7 days (last full backup) |
| Complete server rebuild | 30–60 min | Minimal with emergency kit |

---

## ✅ Backup Operations Checklist

**Daily:** Automated db backup runs, SHA-256 + decrypt probe passes, and offsite sync succeeds
**Weekly:** Full backup with `--full-verification`; offsite sync verified
**Monthly:** Emergency kit created; `restore.sh` tested; Tier 2 escrow refreshed if Age key was rotated (`make key-show` to confirm)
**Quarterly:** Full disaster recovery drill on a fresh instance; verify `make timers` shows expected schedules

## Restore storage-layout preflight

Before a destructive full or emergency restore, inspect the backup and the target storage layout:

```bash
sudo ./restore.sh inspect --remote
# or
sudo ./restore.sh interactive --remote --inspect
```

Database backups are storage-layout independent and are the safest option when only Vaultwarden data is needed. Full and emergency backups restore broader application state/config and require a compatible, prepared target storage layout.

Block-storage backups should be restored to a mounted block/data-volume target, not silently into boot storage. If a backup expects `/mnt/vw-data` (or another data-volume root) and the current host targets `/var/lib/vaultwarden` on boot storage, restore stops before services are stopped. Attach and configure the data volume first, or restore the latest DB backup.

A normal full/emergency restore requires a live `data/db.sqlite3` under the detected source state root. Databases found only below `.pre-restore-*` snapshots are reported for manual recovery but are not restored automatically.

Prepared block-storage targets must provide these entries under `PROJECT_STATE_DIR` / `DATA_VOLUME_MOUNT`: `data`, `caddy`, `logs`, `config`, `secrets`, `backups`, and the `.vw-data-volume` sentinel. When the volume is already mounted and writable, restore may safely recreate missing directories and the sentinel. It will not format, partition, or guess block devices.

If decryption fails because no Age identity matches, the backup may have been encrypted with an older operational key or an offline recovery key. Retry with `--key-file /path/to/old-age-key.txt` or `--from-recovery-kit /path/to/recovery-kit.txt`.
