# Bootstrap Key Recovery Guide

## Overview

The bootstrap key system solves the circular dependency problem in encrypted backups:
- **Problem**: Age key is needed to decrypt backup, but Age key is inside the backup
- **Solution**: Age key is separately encrypted with GPG using a different passphrase

## Architecture

\`\`\`
┌─────────────────────────────────────────────────────────┐
│ Bootstrap Protection Architecture                       │
└─────────────────────────────────────────────────────────┘

Tier 1: Bootstrap Passphrase (Memorized or in password manager)
  │
  ├─> Decrypts Bootstrap Key (GPG-encrypted Age key)
  │
  └─> Produces: Age Key

Tier 2: Age Key
  │
  ├─> Decrypts Backup Archive (Age-encrypted backup)
  │
  └─> Produces: Complete System Backup

Result: Full System Recovery
\`\`\`

## Storage Strategy

### Bootstrap Key Storage Locations

**Primary Locations** (Keep 2-3):
1. Password manager (1Password, Bitwarden, LastPass) - Secure note or file attachment
2. USB drive in fireproof safe at home
3. Encrypted cloud storage (separate account from main backups)

**Secondary Locations** (Optional but recommended):
4. Bank safety deposit box
5. Trusted family member (sealed envelope with instructions)
6. Separate encrypted USB at work/office

### Encrypted Backup Storage

**Never store in same location as bootstrap key!**
1. Primary: rclone remote (Backblaze B2, AWS S3, etc.)
2. Secondary: Local NAS or external drive
3. Tertiary: Different cloud provider or offsite

### GPG Private Key Backup

**Critical - Without this, bootstrap keys are useless!**
- Store in password manager as highest priority
- Keep encrypted copy on separate USB
- Consider paper backup in safe

## Recovery Procedures

### Standard Recovery (You have bootstrap passphrase)

\`\`\`bash
# 1. Decrypt bootstrap key to get Age key
gpg --decrypt age-key-TIMESTAMP.gpg > age-key.txt

# 2. Decrypt backup with Age key
age -d -i age-key.txt emergency-kit-TIMESTAMP.tar.gz.age | tar -xzf -

# 3. Restore to project
cd VaultWarden-OCI
mkdir -p secrets/keys
mv ../age-key.txt secrets/keys/
chmod 600 secrets/keys/age-key.txt

# 4. Start system
./startup.sh
make up
\`\`\`

### Emergency Recovery (Lost GPG keyring)

\`\`\`bash
# 1. Import GPG private key backup
gpg --import gpg-private-key-backup.asc

# 2. Follow standard recovery procedure above
\`\`\`

### Disaster Recovery (Lost everything except backups)

You need:
- Bootstrap key file (age-key-TIMESTAMP.gpg)
- Bootstrap passphrase (from memory or password manager)
- GPG private key backup (from password manager)

\`\`\`bash
# 1. Install dependencies
apt-get update
apt-get install -y gnupg age tar gzip

# 2. Import GPG key
gpg --import gpg-private-key-backup.asc

# 3. Decrypt bootstrap key
gpg --decrypt age-key-TIMESTAMP.gpg > age-key.txt

# 4. Download and decrypt backup
# (download from cloud/USB/etc)
age -d -i age-key.txt emergency-kit-TIMESTAMP.tar.gz.age | tar -xzf -

# 5. Clone repository and restore
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
# Copy extracted files to appropriate locations
cp -r ../secrets ./
cp -r ../data /var/lib/vaultwarden/
cp ../.env ./
# ... etc

# 6. Start system
./startup.sh
make up
\`\`\`

## Testing Your Backup

### Quarterly Test (Recommended)

\`\`\`bash
# Create test directory
mkdir -p ~/backup-test
cd ~/backup-test

# Copy latest bootstrap key and backup
cp ~/.vaultwarden-bootstrap/age-key-*.gpg ./
cp ~/VaultWarden-OCI/backups/emergency/emergency-kit-*.tar.gz.age ./

# Test 1: Can you decrypt bootstrap key?
gpg --decrypt age-key-*.gpg > age-key-test.txt
echo "✓ Bootstrap key decryption successful"

# Test 2: Does Age key look valid?
head -c 50 age-key-test.txt
echo "✓ Age key format appears valid"

# Test 3: Can you decrypt backup?
age -d -i age-key-test.txt emergency-kit-*.tar.gz.age | tar -tzf - | head -20
echo "✓ Backup decryption and archive listing successful"

# Test 4: Can you extract database?
mkdir extract-test
age -d -i age-key-test.txt emergency-kit-*.tar.gz.age | tar -xzf - -C extract-test ./data/db.sqlite3
echo "✓ Database extraction successful"

# Test 5: Is database readable?
sqlite3 extract-test/data/db.sqlite3 "SELECT count(*) FROM sqlite_master WHERE type='table';"
echo "✓ Database integrity check passed"

# Cleanup
cd ~
rm -rf ~/backup-test
echo "✅ All recovery tests passed!"
\`\`\`

## Security Best Practices

### Passphrase Management
- **DO**: Use a strong, unique passphrase (15+ characters)
- **DO**: Store in password manager immediately
- **DO**: Use password manager's secure note with warning labels
- **DON'T**: Reuse any existing system password
- **DON'T**: Write on paper unless in secure safe
- **DON'T**: Email or message to yourself

### Bootstrap Key Protection
- **DO**: Use different storage locations than backups
- **DO**: Encrypt USB drives storing bootstrap keys
- **DO**: Label clearly: "VaultWarden Bootstrap Key - Required for Recovery"
- **DON'T**: Store on same cloud account as backups
- **DON'T**: Leave unencrypted on any system
- **DON'T**: Share unnecessarily

### Backup Verification
- **DO**: Test recovery quarterly
- **DO**: Verify checksums after transfers
- **DO**: Keep recovery manifest with each backup
- **DON'T**: Assume backups work without testing
- **DON'T**: Wait for emergency to test first time

## Troubleshooting

### "gpg: decryption failed: No secret key"
**Cause**: GPG private key not in keyring  
**Solution**: Import GPG backup: `gpg --import gpg-private-key-backup.asc`

### "age: no identity matched any recipient"
**Cause**: Wrong Age key file or corrupted key  
**Solution**: Try alternate bootstrap key, or check Age key format

### "Cannot decrypt bootstrap key - wrong passphrase"
**Cause**: Incorrect passphrase entered  
**Solution**: Check password manager, try alternate saved passphrases

### "Backup file corrupted or invalid"
**Cause**: Partial download or disk corruption  
**Solution**: Re-download from alternate location, verify checksums

## Maintenance Schedule

| Frequency | Task | Duration |
|-----------|------|----------|
| Daily | Automated backup creation | Automatic |
| Weekly | Verify latest backup checksums | 2 min |
| Monthly | Create new emergency kit with bootstrap | 5 min |
| Quarterly | Full recovery test | 15 min |
| Yearly | Rotate bootstrap passphrases (optional) | 10 min |
| Yearly | Update emergency contacts | 5 min |

## Additional Resources

- [Age Encryption Documentation](https://github.com/FiloSottile/age)
- [GPG Handbook](https://www.gnupg.org/gph/en/manual.html)
- [VaultWarden Backup Guide](https://github.com/dani-garcia/vaultwarden/wiki/Backing-up-your-vault)
\`\`\`

## Integration with Existing System

### Update Makefile

Add convenience targets to your `Makefile`:

\`\`\`makefile
# Add to existing Makefile

.PHONY: backup-bootstrap
backup-bootstrap: ## Create backup with bootstrap key protection
	@./backup-with-bootstrap.sh emergency --rclone

.PHONY: backup-bootstrap-test
backup-bootstrap-test: ## Test bootstrap key recovery
	@echo "Testing bootstrap key recovery..."
	@bash -c ' \
		latest_bootstrap=$$(ls -t ~/.vaultwarden-bootstrap/age-key-*.gpg 2>/dev/null | head -1); \
		if [ -z "$$latest_bootstrap" ]; then \
			echo "No bootstrap key found"; exit 1; \
		fi; \
		echo "Decrypting: $$latest_bootstrap"; \
		gpg --decrypt "$$latest_bootstrap" | head -c 50; \
		echo ""; echo "✅ Bootstrap key decryption successful"; \
	'
\`\`\`

## Summary

This implementation provides:

✅ **Solves circular dependency** - Age key encrypted separately with GPG  
✅ **Integrates seamlessly** - Uses your existing `backup.sh`, `lib/common.sh`, `lib/crypto.sh`  
✅ **Industry-standard encryption** - GPG (AES-256) + Age  
✅ **Clear recovery procedures** - Detailed manifests with each backup  
✅ **Multiple storage options** - Bootstrap key separate from backups  
✅ **Regular testing** - Quarterly verification procedures included  
✅ **Well-documented** - Complete recovery guide and troubleshooting  

The key advantage of Option C over alternatives is the **separate encryption layer** - your bootstrap passphrase is completely independent from the Age key, eliminating the circular dependency while maintaining strong security.
