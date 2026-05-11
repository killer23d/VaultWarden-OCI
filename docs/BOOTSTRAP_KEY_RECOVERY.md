# Bootstrap Key Recovery — VaultWarden-OCI

This guide describes how to protect your **Age encryption key** against loss, solving the circular dependency in encrypted backups: you need the Age key to decrypt a backup, but the Age key lives on the server you are trying to recover.

Related docs: [BACKUP-RESTORE.md](BACKUP-RESTORE.md) · [SECURITY.md](SECURITY.md) · [SCRIPTS.md](SCRIPTS.md)

> **💡 Built-in alternatives:** Before using the manual GPG workflow below, consider the native three-tier protection in `lib/crypto.sh`: **Tier 1** (`simple_verify_age_key`) runs automatically on every `backup.sh` invocation — checking permissions, ownership, and performing an encrypt/decrypt roundtrip; **Tier 2** (`create_password_manager_escrow`) exports a password-manager-ready plaintext escrow; **Tier 3** (`create_printable_key_backup`) generates a printable PDF paper backup (HTML fallback if `wkhtmltopdf` is unavailable, with a 30-minute auto-delete reminder). `./edit-secrets.sh export-recovery-kit` also creates a full recovery document including the Age key and all secrets. See [BACKUP-RESTORE.md](BACKUP-RESTORE.md) for details on each tier. See [SCRIPTS.md](SCRIPTS.md) for the full `lib/crypto.sh` function reference. The GPG-based approach below is a supplementary option for those wanting an additional passphrase-protected layer independent of the project tooling.

---

## 📍 The Circular Dependency Problem

```
Tier 1 — Bootstrap Passphrase (memorised or in password manager)
  └─> Decrypts GPG-wrapped Age key
        └─> Decrypts Age-encrypted backup archive
              └─> Full system recovery
```

By encrypting the Age key with GPG (a separate passphrase), you can keep the Age key offsite without storing it in plaintext. Emergency kits already include the Age key inside the archive, but full and database backups do not — this procedure covers those cases.

---

## 💾 Storage Strategy

### Where to Keep the GPG-Wrapped Age Key

Store **2–3 copies** in different locations:

| Location | Notes |
| :-- | :-- |
| Password manager (secure note/attachment) | Primary; most accessible |
| Encrypted USB in fireproof safe | Offline; survives cloud outage |
| Encrypted cloud storage (separate account) | Must differ from backup storage |
| Bank safety deposit box (optional) | For highest-risk environments |

> **Never store the bootstrap key and the encrypted backups in the same location.**

### Where to Keep the GPG Private Key

- Password manager (highest priority secure note)
- Encrypted copy on a separate USB drive
- Consider a paper backup kept in a safe

---

## 🔒 Creating a Bootstrap-Protected Age Key

```bash
# GPG-encrypt your Age key with a strong passphrase
gpg --symmetric --cipher-algo AES256 \
    --output ~/age-key-$(date +%Y%m%d).gpg \
    secrets/keys/age-key.txt

# Copy to your bootstrap storage location(s)
cp ~/age-key-$(date +%Y%m%d).gpg /path/to/usb/

# Export your GPG private key for safekeeping
gpg --export-secret-keys --armor YOUR_GPG_KEY_ID > gpg-private-key-backup.asc
```

### Verifying the Age key before wrapping it

Before encrypting the key for offsite storage, confirm it is valid and the roundtrip works:

```bash
# Check key structure and perform encrypt/decrypt roundtrip (lib/crypto.sh)
source lib/crypto.sh
check_age_key secrets/keys/age-key.txt

# Or use the Makefile shortcut
make key-health

# Manually verify the key format (private key must start with AGE-SECRET-KEY-1)
grep '^AGE-SECRET-KEY-1' secrets/keys/age-key.txt
grep '^# public key:' secrets/keys/age-key.txt
```

If `check_age_key` fails, do not proceed — restore the key from an existing escrow copy first.

---

## ⏪ Recovery Procedures

### Standard Recovery (Bootstrap Passphrase Available)

```bash
# 1. Decrypt the Age key
gpg --decrypt age-key-TIMESTAMP.gpg > age-key.txt

# 2. Use it to decrypt a backup
#    DB backups (.sqlite3.age): raw SQLite, no compression
age -d -i age-key.txt db_backup_YYYYMMDD_HHMMSS.sqlite3.age > db.sqlite3

#    Full/emergency backups (.tar.zst.age): zstd-compressed tar
age -d -i age-key.txt full_backup_YYYYMMDD_HHMMSS.tar.zst.age | zstd -d -T0 -c | tar -xf -

# 3. Place the Age key in the project
mkdir -p VaultWarden-OCI/secrets/keys
mv age-key.txt VaultWarden-OCI/secrets/keys/
chmod 600 VaultWarden-OCI/secrets/keys/age-key.txt

# 4. Start services
cd VaultWarden-OCI
./startup.sh
# or: make start
```

> **Archive format note:** Full and emergency backups use `.tar.zst.age` (zstd compression). The previous format was `.tar.gz.age` (gzip). If you have older backups from before the zstd migration, use `tar -xzf -` instead of `zstd -d -T0 -c | tar -xf -` for those specific files.

### Emergency Recovery (GPG Keyring Lost)

```bash
# 1. Import your GPG private key backup
gpg --import gpg-private-key-backup.asc

# 2. Follow standard recovery above
```

### Full Disaster Recovery (Server Lost, Only Offsite Backup Available)

```bash
# 1. Install dependencies on new server
apt-get update && apt-get install -y gnupg git age zstd sqlite3

# 2. Import GPG key
gpg --import gpg-private-key-backup.asc

# 3. Decrypt Age key from bootstrap key
gpg --decrypt age-key-TIMESTAMP.gpg > age-key.txt

# 4. Download encrypted backup from offsite
rclone copy your_remote_name:vaultwarden_backups/emergency/ ./

# 5. Clone repo and run setup
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com

# 6. Place Age key and restore
mkdir -p secrets/keys
mv ../age-key.txt secrets/keys/
chmod 600 secrets/keys/age-key.txt
# Supply the key non-interactively with --key-file, or omit to be prompted
./restore.sh interactive --file ../emergency_backup_YYYYMMDD_HHMMSS.tar.zst.age \
             --key-file secrets/keys/age-key.txt --force

# 7. Verify
make health
```

---

## 🧪 Quarterly Test Procedure

Run this every quarter to confirm you can actually recover. The test uses `zstd` for decompression to match the current `.tar.zst.age` archive format.

```bash
mkdir -p ~/bootstrap-test && cd ~/bootstrap-test

# Copy bootstrap key and a recent backup
cp /path/to/bootstrap/age-key-*.gpg .
cp ~/VaultWarden-OCI/backups/emergency/emergency_backup_*.tar.zst.age . 2>/dev/null || \
  cp ~/VaultWarden-OCI/backups/full/full_backup_*.tar.zst.age .

# Select the backup file
BACKUP_FILE=$(ls *.age | head -1)

# Test 1: Decrypt bootstrap key
gpg --decrypt age-key-*.gpg > age-key-test.txt
echo "✓ Bootstrap key decryption OK"

# Test 2: Verify Age key format (must contain AGE-SECRET-KEY-1 and public key comment)
grep -q '^AGE-SECRET-KEY-1' age-key-test.txt && echo "✓ Private key format OK"
grep -q '^# public key:' age-key-test.txt && echo "✓ Public key comment OK"

# Test 3: Decrypt backup and list contents (zstd decompression)
age -d -i age-key-test.txt "$BACKUP_FILE" | zstd -d -T0 -c | tar -tf - | head -20
echo "✓ Backup decryption and listing OK"

# Test 4: Extract and check the database
mkdir extract
age -d -i age-key-test.txt "$BACKUP_FILE" \
  | zstd -d -T0 -c \
  | tar -xf - -C extract --wildcards '*/data/db.sqlite3' 2>/dev/null || true
DB_FILE=$(find extract -name 'db.sqlite3' | head -1)
if [[ -n "$DB_FILE" ]]; then
  sqlite3 "$DB_FILE" "SELECT count(*) FROM sqlite_master WHERE type='table';"
  echo "✓ Database integrity OK"
else
  echo "db.sqlite3 not found in archive — is this a db-only backup? (use .sqlite3.age directly)"
fi

# Cleanup
cd ~ && rm -rf ~/bootstrap-test
echo "✅ All recovery tests passed"
```

> **DB-only backup test:** If your backup is a `db_backup_*.sqlite3.age` file (no tar wrapper), decrypt it directly:
> ```bash
> age -d -i age-key-test.txt db_backup_YYYYMMDD_HHMMSS.sqlite3.age > db-test.sqlite3
> sqlite3 db-test.sqlite3 "PRAGMA integrity_check;"
> ```

---

## 🛠️ Troubleshooting

| Error | Cause | Fix |
| :-- | :-- | :-- |
| `gpg: decryption failed: No secret key` | GPG private key not in keyring | `gpg --import gpg-private-key-backup.asc` |
| `age: no identity matched any recipient` | Wrong or corrupted Age key file | Try alternate bootstrap key copy; verify `AGE-SECRET-KEY-1` prefix is present |
| `Cannot decrypt — wrong passphrase` | Incorrect passphrase | Check password manager; try alternate saved passphrases |
| `Backup file corrupted or invalid` | Partial download or disk corruption | Re-download from offsite; verify SHA256 checksum |
| `zstd: error` or `tar: unexpected EOF` | Archive truncated or wrong decompressor | Confirm backup is `.tar.zst.age` (not `.tar.gz.age`); use `zstd -d`, not `gunzip` |
| `check_age_key` fails on roundtrip | Private key body corrupted | Key file may have been partially overwritten; restore from escrow |

---

## 📅 Maintenance Schedule

| Frequency | Task |
| :-- | :-- |
| Monthly | Create new emergency kit: `./backup.sh run emergency` |
| Quarterly | Full recovery test (procedure above) |
| After any Age key rotation | Re-run Tier 2 escrow (`create_password_manager_escrow`) and re-wrap with GPG |
| After any Age key rotation | `make key-rotate` triggers the built-in key rotation workflow |
| Yearly | Optionally rotate GPG bootstrap passphrase |

---

## ✅ Security Practices

- Use a strong, unique passphrase (15+ characters) stored in your password manager
- Never reuse the bootstrap passphrase for any other system
- Store bootstrap key and backups in **different** locations and cloud accounts
- Label files clearly: `"VaultWarden Bootstrap Key — Required for Recovery"`
- Never leave the Age key unencrypted on any networked system
- Verify the Age key is structurally valid (`check_age_key` or `make key-health`) before wrapping it for offsite storage
