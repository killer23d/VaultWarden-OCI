# Backup & Restore — VaultWarden-OCI

All backups are encrypted with **Age** and managed by `backup.sh`. The backup lock uses `flock` on a file descriptor — the kernel releases it automatically on any process exit, including SIGKILL and OOM kill.

Related docs: [OPERATIONS.md](OPERATIONS.md) · [SCRIPTS.md](SCRIPTS.md) · [ADVANCED-CUSTOMIZATION.md](ADVANCED-CUSTOMIZATION.md)

---

## 💾 Backup Tiers

| Type | Contents | Retention | Age Key Required |
| :-- | :-- | :-- | :-- |
| **Database** (`db`) | SQLite database only | 14 days | Yes |
| **Full** (`full`) | Config + data (no secrets) | 30 days | Yes |
| **Emergency** (`emergency`) | Everything + secrets + Age key | 90 days | Included in archive |

> **⚠️** Full and database backups require your Age key (`secrets/keys/age-key.txt`) to decrypt. Keep a copy offline or in a secure separate location before restoring to a new server. Emergency kits include the key inside the archive.

---

## 📦 Creating Backups

### Database Backup (Daily)

```bash
./backup.sh --type db                        # default
./backup.sh --type db --rclone               # with offsite sync
./backup.sh --type db --email                # with email notification
make backup                                  # silent (no email)
```

### Full System Backup (Weekly)

```bash
./backup.sh --type full                      # fast checksum verification
./backup.sh --type full --full-verification  # end-to-end decrypt + integrity test
./backup.sh --type full --full-verification --rclone --email
make backup-full                             # full backup with email
```

**Included:** Docker Compose config, `.env`, Caddy config, Fail2ban config, VaultWarden data directory, database snapshot.
**Excluded:** `secrets/` directory, Age keys, SSH keys.

### Emergency Recovery Kit (As Needed)

```bash
./backup.sh --type emergency                  # includes secrets + Age key
./backup.sh --type emergency --full-verification --rclone --email
make backup-emergency                         # emergency kit with email
```

> ⚠️ Emergency kits contain your encryption keys. Store them securely offline.

### List & Inspect Backups

```bash
./backup.sh --list
make list-backups
```

Each backup produces three files:

| File | Purpose |
| :-- | :-- |
| `*.age` | Encrypted backup archive |
| `*.sha256` | Post-encryption checksum |
| `*.meta` | Metadata (type, timestamp, version, size) |

---

## 🔄 Verification Modes

| Mode | Flag | Speed | What It Tests |
| :-- | :-- | :-- | :-- |
| Fast (default) | *(none)* | Seconds | SHA256 checksum post-encryption |
| Full | `--full-verification` | Minutes | Decrypt → extract → DB integrity check |

Use fast for daily automated backups; full for weekly and before major changes.

---

## 🔑 Age Key Protection (`lib/simple_key_resilience.sh`)

Your Age key (`secrets/keys/age-key.txt`) is the single point of failure for all backup decryption. If you lose it, **every backup is permanently unrecoverable**. `lib/simple_key_resilience.sh` provides three complementary protection tiers.

### Tier 1 — Automatic Health Check (runs on every backup)

`backup.sh` calls `simple_verify_age_key` before every backup run. It checks that the key file exists, auto-corrects permissions to 600 if needed, validates the key structure, and performs a live encrypt/decrypt roundtrip. If the check fails, the backup is aborted.

No action required — this runs automatically.

### Tier 2 — Password Manager Escrow (recommended after setup)

Exports a formatted plain-text document containing the Age private key, public key, and recovery instructions — ready to paste as a Secure Note in Bitwarden, 1Password, or similar.

```bash
source lib/simple_key_resilience.sh
create_password_manager_escrow ~/vaultwarden-age-key-escrow.txt

# ⚠️ Copy contents to your password manager NOW, then securely delete:
shred -fuz ~/vaultwarden-age-key-escrow.txt
```

Re-run this any time you rotate the Age key.

### Tier 3 — Paper Backup (optional, for physical offline storage)

Generates a printable PDF (or HTML if `wkhtmltopdf` is not installed) containing the Age key, optional QR code, and recovery steps. The temp HTML file is securely wiped after PDF generation.

```bash
# Install optional dependencies
sudo apt install qrencode wkhtmltopdf

source lib/simple_key_resilience.sh
create_printable_key_backup ~/vaultwarden-key-backup.pdf

# Print and store in a fireproof safe, then delete the file
```

> **When to run each tier:**
> - Tier 1: automatic on every `backup.sh` run
> - Tier 2: after initial setup and after any Age key rotation
> - Tier 3: optional — for physical offline copies in a fireproof safe or safety deposit box

---

## ☁️ Offsite Storage (rclone)

```bash
# Configure a remote
rclone config

# Set the remote name in .env
RCLONE_REMOTE_NAME=your_remote_name

# Test
./backup.sh --type db --rclone

# Verify remote contents
rclone ls your_remote_name:vaultwarden_backups/
```

Automation installs rclone-enabled crons via `sudo ./cron-setup.sh --install`.

---

## ⏪ Restoring

### Interactive Restore (Recommended)

```bash
./restore.sh      # lists backups, prompts for selection
make restore
```

`restore.sh` selects the newest backup by **file modification time** (not lexicographic filename order), so it reliably finds the latest regardless of filename format.

### Command-Line Restore

```bash
# Restore the latest backup of a specific type
./restore.sh --latest --type full
./restore.sh --latest --type db

# Restore the latest backup, skip confirmation and skip pre-restore backup
# (used internally by update.sh rollback)
./restore.sh --latest --type full --force --no-backup

# Restore a specific file
./restore.sh --file /path/to/backup.age
./restore.sh --file /path/to/backup.age --force
```

### Exit Codes

| Code | Meaning |
| :-- | :-- |
| `0` | Restore completed, all health checks passed |
| `1` | Restore failed or critical phase error |
| `2` | Restore completed but post-restore health check reported issues |

---

## 🚨 Disaster Recovery Scenarios

### Scenario 1 — Database Corruption

```bash
docker compose stop vaultwarden
./restore.sh --latest --type db
make health
```

### Scenario 2 — Configuration Loss

```bash
docker compose down
./restore.sh --latest --type full
docker compose config   # validate
make start
```

### Scenario 3 — Complete Server Loss

```bash
# 1. Provision new OCI instance, configure Security List (ports 80/443/22)
# 2. Clone repo
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

# 3. Pull emergency kit from offsite
rclone copy your_remote_name:vaultwarden_backups/emergency/ ./backups/emergency/

# 4. Run setup (generates baseline config)
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com

# 5. Restore emergency kit (overwrites generated config)
./restore.sh --file ./backups/emergency/emergency-TIMESTAMP.age --force

# 6. Verify
make health
```

### Scenario 4 — Failed Update (Auto-Rollback)

`update.sh` triggers this automatically when its post-update health check fails:

```bash
./restore.sh --latest --type full --force --no-backup
```

If you need to trigger it manually:

```bash
./restore.sh --latest --type full --force
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
./maintenance.sh --db-maint   # offline SQLite VACUUM + WAL checkpoint
./backup.sh --type db
```

**"Encryption failed" / Age key missing**

```bash
ls -l secrets/keys/age-key.txt

# Manual health check
source lib/simple_key_resilience.sh && simple_verify_age_key

# If missing, restore from your password manager escrow (Tier 2)
# or from an emergency kit, then re-run setup:
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
```

**"Decryption failed" on restore**

```bash
# Verify checksum
sha256sum -c backup.age.sha256

# Make sure the Age key matches the backup
age-keygen -y secrets/keys/age-key.txt

# Try an older backup
./restore.sh --file /path/to/older-backup.age
```

**"Services won't start after restore"**

```bash
docker compose config   # check for config errors
docker compose logs
make restart
```

**"rclone sync failed"**

```bash
rclone lsd your_remote_name:
rclone config show your_remote_name
./backup.sh --type db --rclone 2>&1 | tee /tmp/backup-debug.log
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

**Daily:** Automated db backup runs and checksum passes
**Weekly:** Full backup with `--full-verification`; offsite sync verified
**Monthly:** Emergency kit created; `restore.sh` tested in dry-run; Tier 2 escrow refreshed if Age key was rotated
**Quarterly:** Full disaster recovery drill on a fresh instance
