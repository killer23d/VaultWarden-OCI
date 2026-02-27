# Bootstrap Key Recovery — VaultWarden-OCI

This guide describes how to protect your **Age encryption key** against loss, solving the circular dependency in encrypted backups: you need the Age key to decrypt a backup, but the Age key lives on the server you are trying to recover.

Related docs: [BACKUP-RESTORE.md](BACKUP-RESTORE.md) · [SECURITY.md](SECURITY.md)

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

---

## ⏪ Recovery Procedures

### Standard Recovery (Bootstrap Passphrase Available)

```bash
# 1. Decrypt the Age key
gpg --decrypt age-key-TIMESTAMP.gpg > age-key.txt

# 2. Use it to decrypt a backup
age -d -i age-key.txt backup-TIMESTAMP.tar.gz.age | tar -xzf -

# 3. Place the Age key in the project
mkdir -p VaultWarden-OCI/secrets/keys
mv age-key.txt VaultWarden-OCI/secrets/keys/
chmod 600 VaultWarden-OCI/secrets/keys/age-key.txt

# 4. Start services
cd VaultWarden-OCI
./startup.sh
# or: make start
```

### Emergency Recovery (GPG Keyring Lost)

```bash
# 1. Import your GPG private key backup
gpg --import gpg-private-key-backup.asc

# 2. Follow standard recovery above
```

### Full Disaster Recovery (Server Lost, Only Offsite Backup Available)

```bash
# 1. Install dependencies on new server
apt-get update && apt-get install -y gnupg git

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
./restore.sh --file ../backup-TIMESTAMP.age --force

# 7. Verify
make health
```

---

## 🧪 Quarterly Test Procedure

Run this every quarter to confirm you can actually recover:

```bash
mkdir -p ~/bootstrap-test && cd ~/bootstrap-test

# Copy bootstrap key and a recent backup
cp /path/to/bootstrap/age-key-*.gpg .
cp ~/VaultWarden-OCI/backups/emergency/emergency-*.age . 2>/dev/null || \
  cp ~/VaultWarden-OCI/backups/full/full-*.age .

# Test 1: Decrypt bootstrap key
gpg --decrypt age-key-*.gpg > age-key-test.txt
echo "✓ Bootstrap key decryption OK"

# Test 2: Decrypt backup and list contents
age -d -i age-key-test.txt *.age | tar -tzf - | head -20
echo "✓ Backup decryption and listing OK"

# Test 3: Extract and check the database
mkdir extract
age -d -i age-key-test.txt *.age | tar -xzf - -C extract data/db.sqlite3 2>/dev/null
sqlite3 extract/data/db.sqlite3 "SELECT count(*) FROM sqlite_master WHERE type='table';"
echo "✓ Database integrity OK"

# Cleanup
cd ~ && rm -rf ~/bootstrap-test
echo "✅ All recovery tests passed"
```

---

## 🛠️ Troubleshooting

| Error | Cause | Fix |
| :-- | :-- | :-- |
| `gpg: decryption failed: No secret key` | GPG private key not in keyring | `gpg --import gpg-private-key-backup.asc` |
| `age: no identity matched any recipient` | Wrong or corrupted Age key file | Try alternate bootstrap key copy; verify Age key format |
| `Cannot decrypt — wrong passphrase` | Incorrect passphrase | Check password manager; try alternate saved passphrases |
| `Backup file corrupted or invalid` | Partial download or disk corruption | Re-download from offsite; verify SHA256 checksum |

---

## 📅 Maintenance Schedule

| Frequency | Task |
| :-- | :-- |
| Monthly | Create new emergency kit: `./backup.sh --type emergency` |
| Quarterly | Full recovery test (procedure above) |
| Yearly | Optionally rotate GPG bootstrap passphrase |

---

## ✅ Security Practices

- Use a strong, unique passphrase (15+ characters) stored in your password manager
- Never reuse the bootstrap passphrase for any other system
- Store bootstrap key and backups in **different** locations and cloud accounts
- Label files clearly: `"VaultWarden Bootstrap Key — Required for Recovery"`
- Never leave the Age key unencrypted on any networked system
