# Backup and Restore Guide - VaultWarden-OCI

Comprehensive guide for backup and restore operations in VaultWarden-OCI with enhanced atomic operations, full verification modes, and reliable recovery procedures.

## Backup Overview

VaultWarden-OCI provides three types of backups with enhanced safety features:

| Type | Contents | Use Case | Retention | Verification |
|------|----------|----------|-----------|--------------|
| **Database** | SQLite database only | Daily automated backups | 14 days | Fast checksum (default) |
| **Full** | Config + data (NO secrets) | Weekly system backups | 30 days | Optional full verification |
| **Emergency** | Everything + secrets | Disaster recovery | 90 days | Full verification recommended |

### Enhanced Backup Features

✅ **Atomic Operations**: Prevents corrupt backups during creation  
✅ **Safe Database Snapshots**: WAL checkpoints for live backups  
✅ **Dual Verification Modes**: Fast checksum or full recoverability testing  
✅ **Conservative Space Management**: Pre-operation disk space validation  
✅ **Age Encryption**: Industry-standard encryption for all backups  
✅ **Metadata Generation**: Comprehensive backup information tracking  
✅ **Offsite Sync**: Optional rclone integration for remote storage  

## Backup Creation

### Database Backups (Recommended Daily)

**Fast Database Backup** (Default - Uses Checksum Verification):
```bash
# Quick database backup with post-encryption checksum
./backup.sh --type db

# With email notification
./backup.sh --type db --email

# With offsite sync
./backup.sh --type db --rclone

# Using Makefile
make backup              # Database backup
```

**Features**:
- Creates consistent SQLite snapshot using WAL checkpoints
- Verifies database integrity before backup
- Compresses and encrypts with Age
- Post-encryption checksum verification
- Typical completion time: 30-60 seconds

### Full System Backups (Recommended Weekly)

**Full Backup with Fast Verification**:
```bash
# Full system backup (config + data, NO secrets)
./backup.sh --type full

# Using Makefile
make backup-full
```

**Full Backup with Complete Verification** (Recommended Weekly):
```bash
# Full backup with end-to-end verification test
./backup.sh --type full --full-verification --email

# Using Makefile for comprehensive backup
make backup-full
# Then manually add --full-verification if desired
```

**What's Included**:
- Docker Compose configuration
- Environment variables (.env)
- Caddy configuration
- Fail2ban configuration
- VaultWarden data directory
- Database snapshot (verified)

**What's Excluded**:
- Encrypted secrets (secrets/ directory)
- Age encryption keys
- SSH keys

**Features**:
- Atomic archive creation
- Database integrity verification before backup
- Optional full recoverability testing
- Typical completion time: 2-5 minutes

### Emergency Recovery Kits (As Needed)

**Emergency Kit with Full Verification**:
```bash
# Complete disaster recovery kit (includes secrets)
./backup.sh --type emergency

# With full verification and offsite sync
./backup.sh --type emergency --full-verification --rclone --email

# Using Makefile
make backup-emergency
```

**What's Included**:
- Everything from full backup
- **PLUS encrypted secrets directory**
- **PLUS Age encryption keys**
- Complete system recovery capability

**Security Note**:
⚠️  Emergency kits contain your encryption keys. Store securely!

### Backup Verification Modes

#### Fast Verification (Default)
```bash
# Uses post-encryption checksum only (recommended for daily backups)
./backup.sh --type db
```

**Benefits**:
- Very fast completion (seconds)
- Reliable corruption detection
- Minimal system impact
- Suitable for daily automated backups

#### Full Verification (Optional)
```bash
# Complete end-to-end recoverability test
./backup.sh --type full --full-verification
```

**Benefits**:
- Guarantees backup can be restored
- Tests decryption process
- Validates database integrity after extraction
- Recommended for weekly full backups

**Process**:
1. Decrypt backup file
2. Extract archive contents
3. Verify database can be queried
4. Validate file integrity

**Trade-off**: Slower but provides complete confidence

### Backup Operations Reference

```bash
# List all available backups
./backup.sh --list
make list-backups

# Preview backup operation (dry-run)
./backup.sh --type db --dry-run

# Full featured backup with all options
./backup.sh --type full \
  --full-verification \
  --rclone \
  --email \
  --dry-run
```

## Backup Storage

### Local Backup Storage

Backups are stored in:
```
PROJECT_ROOT/backups/
├── db/          # Database backups (14-day retention)
├── full/        # Full system backups (30-day retention)
└── emergency/   # Emergency kits (90-day retention)
```

Each backup includes:
- `.age` file - Encrypted backup
- `.sha256` file - Post-encryption checksum
- `.meta` file - Backup metadata

**Metadata Contents**:
```
backup_type=db
timestamp=20250106-143022
hostname=vaultwarden-server
verification_mode=quick_check
full_verification=true
vaultwarden_version=1.34.3
file_size=5242880
sha256=abc123...
```

### Offsite Backup with Rclone

#### Initial Rclone Configuration

```bash
# Configure rclone remote
rclone config

# Common remote types:
# - Google Drive (gdrive)
# - Amazon S3 (s3)
# - Dropbox (dropbox)
# - OneDrive (onedrive)
# - SFTP/SSH (sftp)
```

#### Configure Offsite Backups

```bash
# Set remote name in .env
nano .env
# Set: RCLONE_REMOTE_NAME=your_remote_name

# Test rclone sync
./backup.sh --type db --rclone

# Verify remote backup
rclone ls your_remote_name:vaultwarden_backups/
```

#### Automated Offsite Backups

Add rclone to cron jobs:
```bash
# Automated daily backup with offsite sync
0 2 * * * cd /path/to/VaultWarden-OCI && ./backup.sh --type db --rclone --email
```

### Backup Space Management

**Check Available Space**:
```bash
# Check backup directory space
df -h PROJECT_ROOT/backups/

# Check total backup usage
du -sh PROJECT_ROOT/backups/*
```

**Automatic Cleanup**:
Backups are automatically pruned based on retention policies:
- Database backups: 14 days
- Full backups: 30 days
- Emergency kits: 90 days

**Manual Cleanup**:
```bash
# Remove backups older than retention period
./maintenance.sh --comprehensive
```

## Backup Restoration

### Interactive Restore (Recommended)

```bash
# Interactive restore with backup selection
./restore.sh

# Using Makefile
make restore
```

**Interactive Process**:
1. Lists all available backups
2. Displays backup metadata (type, size, date)
3. Allows selection of specific backup
4. Confirms restoration
5. Performs restore with validation
6. Restarts services

### Direct File Restore

```bash
# Restore specific backup file
./restore.sh --file /path/to/backup.age

# With force (skip confirmation)
./restore.sh --file /path/to/backup.age --force

# Dry-run (preview only)
./restore.sh --file /path/to/backup.age --dry-run
```

### Restore Process Details

**Database Backup Restoration**:
1. Stop VaultWarden service
2. Backup current database
3. Decrypt and decompress backup
4. Verify database integrity
5. Replace database file
6. Restart VaultWarden
7. Verify service health

**Full/Emergency Backup Restoration**:
1. Stop all services
2. Backup current configuration
3. Decrypt and extract archive
4. Restore files to correct locations
5. Restore database
6. Fix permissions
7. Restart services
8. Comprehensive health check

### Restore from Offsite Backup

```bash
# Download from rclone remote
rclone copy your_remote_name:vaultwarden_backups/db/backup.age ./backups/db/

# Restore downloaded backup
./restore.sh --file ./backups/db/backup.age
```

## Disaster Recovery Scenarios

### Scenario 1: Database Corruption

**Symptoms**:
- VaultWarden service fails to start
- Database errors in logs
- Cannot access web vault

**Recovery**:
```bash
# 1. Stop VaultWarden
docker compose stop vaultwarden

# 2. Restore latest database backup
./restore.sh --type db

# 3. Verify service
make health
```

### Scenario 2: Configuration Loss

**Symptoms**:
- Services won't start after system update
- Missing configuration files
- Docker Compose errors

**Recovery**:
```bash
# 1. Stop all services
docker compose down

# 2. Restore full backup
./restore.sh --type full

# 3. Verify configuration
docker compose config

# 4. Start services
make start
```

### Scenario 3: Complete System Loss

**Symptoms**:
- Server failure
- Data center outage
- Ransomware attack

**Recovery**:
```bash
# 1. Setup new server with basic OS
# 2. Clone repository
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI

# 3. Download emergency kit from offsite
rclone copy your_remote_name:vaultwarden_backups/emergency/ ./backups/emergency/

# 4. Run setup (generates new configs)
sudo ./setup.sh --domain vault.example.com --email admin@example.com

# 5. Restore emergency kit (overwrites generated configs)
./restore.sh --file ./backups/emergency/emergency-kit-TIMESTAMP.tar.gz.age --force

# 6. Verify all services
make health --comprehensive

# 7. Test access
curl -I https://vault.example.com
```

### Scenario 4: Secret Loss

**Symptoms**:
- Cannot access admin panel
- Email notifications not working
- Cloudflare integration broken

**Recovery**:
```bash
# 1. Restore emergency kit (contains secrets)
./restore.sh --type emergency

# Or if you have backup of secrets only:
# 2. Restore secrets directory
cp -r /backup/secrets ./

# 3. Verify secrets
./edit-secrets.sh --test

# 4. Restart services
make restart
```

## Backup Best Practices

### Automated Backup Strategy

**Daily**:
```bash
# Database backup with fast verification
./backup.sh --type db --rclone --email
```

**Weekly** (Recommended):
```bash
# Full backup with complete verification
./backup.sh --type full --full-verification --rclone --email
```

**Monthly**:
```bash
# Emergency kit for disaster recovery
./backup.sh --type emergency --full-verification --rclone --email
```

### Installation via Cron

```bash
# Install automated backups
sudo ./cron-setup.sh --install

# Default schedule:
# - Daily 2 AM: Database backup with rclone
# - Weekly Sunday 3 AM: Full backup with verification
# - (Manual emergency kits as needed)
```

### Backup Verification Schedule

**Daily**: Fast checksum verification (automatic)  
**Weekly**: Full recoverability verification (recommended)  
**Monthly**: Test complete restore procedure (best practice)  

### Testing Backups

```bash
# 1. Create test backup
./backup.sh --type db --full-verification

# 2. Verify backup can be listed
./backup.sh --list

# 3. Test restore in dry-run mode
./restore.sh --dry-run

# 4. Quarterly: Perform actual test restore
# (on non-production system or during maintenance window)
./restore.sh --file /path/to/test-backup.age
```

### Backup Security

**Encryption**:
- All backups encrypted with Age
- Encryption keys stored in `secrets/keys/`
- Secrets encrypted with SOPS

**Access Control**:
```bash
# Verify backup file permissions
ls -la backups/*/*.age
# Should be: -rw------- (600)

# Verify secrets directory permissions
ls -ld secrets/
# Should be: drwx------ (700)
```

**Offsite Storage**:
- Use encrypted rclone remotes when possible
- Enable two-factor authentication on cloud storage
- Regularly verify remote backup integrity
- Keep multiple backup generations

### Monitoring Backups

**Check Backup Status**:
```bash
# List recent backups
./backup.sh --list | head -10

# Check backup disk usage
du -sh backups/*

# Verify backup integrity
for file in backups/db/*.age; do
    sha256sum -c "$file.sha256"
done
```

**Email Notifications**:
```bash
# Enable email for all backups
./backup.sh --type db --email

# Automated email via cron (already configured)
sudo ./cron-setup.sh --install
```

## Troubleshooting

### Backup Creation Issues

**Issue**: "Insufficient disk space"
```bash
# Check available space
df -h PROJECT_ROOT/backups/

# Clean up old backups
./maintenance.sh --comprehensive

# Check retention settings in .env
```

**Issue**: "Database snapshot failed"
```bash
# Check VaultWarden status
docker compose logs vaultwarden

# Try database maintenance first
./db-maint.sh

# Retry backup
./backup.sh --type db
```

**Issue**: "Encryption failed"
```bash
# Verify Age key exists
ls -l secrets/keys/age-key.txt

# Test Age encryption
echo "test" | age -r $(age-keygen -y secrets/keys/age-key.txt) | age -d -i secrets/keys/age-key.txt

# Regenerate key if necessary (requires setup re-run)
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com
```

### Restore Issues

**Issue**: "Decryption failed"
```bash
# Verify Age key matches backup
age-keygen -y secrets/keys/age-key.txt

# Check backup file integrity
sha256sum -c backup.age.sha256

# Try emergency kit if available
./restore.sh --type emergency
```

**Issue**: "Database integrity check failed"
```bash
# Extract database manually for inspection
age -d -i secrets/keys/age-key.txt backup.age | gzip -d > test.db

# Check database
sqlite3 test.db "PRAGMA integrity_check;"

# If corrupt, try previous backup
./restore.sh --file /path/to/older-backup.age
```

**Issue**: "Services won't start after restore"
```bash
# Check Docker Compose configuration
docker compose config

# Review logs
docker compose logs

# Verify file permissions
./health.sh --comprehensive

# Restart services
make restart
```

### Offsite Backup Issues

**Issue**: "Rclone sync failed"
```bash
# Test rclone connectivity
rclone lsd your_remote_name:

# Check configuration
rclone config show your_remote_name

# Test with smaller file
echo "test" | rclone rcat your_remote_name:test.txt
rclone cat your_remote_name:test.txt

# Retry backup with verbose output
./backup.sh --type db --rclone 2>&1 | tee backup.log
```

## Recovery Time Objectives

| Scenario | Recovery Time | Data Loss |
|----------|---------------|-----------|
| Database restore | 5-10 minutes | Up to 24 hours (last backup) |
| Full system restore | 15-30 minutes | Up to 7 days (last full backup) |
| Complete rebuild | 30-60 minutes | Minimal with emergency kit |

## Backup Checklist

### Daily Operations
- ✅ Automated database backup runs successfully
- ✅ Backup completes with verified integrity
- ✅ Offsite sync completes successfully
- ✅ Receive confirmation email

### Weekly Tasks
- ✅ Review backup logs for errors
- ✅ Verify offsite backups are accessible
- ✅ Check backup disk space usage
- ✅ Run full backup with verification

### Monthly Tasks
- ✅ Test restore procedure (non-production)
- ✅ Create emergency recovery kit
- ✅ Verify all backup types are working
- ✅ Review and update backup strategy

### Quarterly Tasks
- ✅ Complete disaster recovery drill
- ✅ Verify emergency kit can rebuild system
- ✅ Test offsite backup restoration
- ✅ Review backup retention policies

---

This comprehensive backup and restore guide ensures reliable data protection and recovery capabilities for your VaultWarden-OCI deployment with enhanced atomic operations, dual verification modes, and robust disaster recovery procedures.
