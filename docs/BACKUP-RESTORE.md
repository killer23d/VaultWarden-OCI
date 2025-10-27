# Backup and Restore Guide - VaultWarden-OCI-Simplified

This comprehensive guide covers backup creation, management, and restoration procedures for VaultWarden-OCI-Simplified, including the new interactive features and Makefile shortcuts.

## Quick Reference

### Backup Operations
```bash
# Create backups
make backup-db          # Quick database backup
make backup-full        # Complete system backup  
make backup-emergency   # Disaster recovery kit

# Manage backups
make list-backups       # Show all available backups
make configure-rclone   # Setup remote backup storage

# Restore operations
make restore            # Interactive backup selection and restore
```

### Emergency Recovery
```bash
# SSH access lost - Use break-glass admin
make breakglass-status  # Check emergency admin status
# Use OCI Console → Instance → Console Connection
# Login with break-glass credentials, fix SSH, then clean up

# Complete system recovery
make restore            # Select emergency kit from interactive menu
```

## Backup Strategy Overview

### Three-Tier Backup System

| Backup Type | Contents | Frequency | Retention | Use Case |
|-------------|----------|-----------|-----------|----------|
| **Database** | SQLite database only | Daily (automated) | 14 days | Quick data recovery |
| **Full System** | Complete configuration + data | Weekly (automated) | 30 days | System restoration |
| **Emergency Kit** | Self-contained recovery package | Manual/as-needed | 90 days | Disaster recovery |

### Backup Security Features

- **Age Encryption**: All backups encrypted with ChaCha20-Poly1305
- **Integrity Verification**: Automatic verification after creation
- **Tamper Prevention**: Authenticated encryption prevents modification
- **Key Management**: Separate Age keys for enhanced security
- **Remote Sync**: Optional cloud storage with rclone integration

## Enhanced Backup Operations

### Interactive Backup Listing

The `backup.sh` script now includes enhanced listing capabilities:

```bash
# List all available backups with details
make list-backups
# Or: ./backup.sh --list

# Example output:
# Available local backups:
#
#  ID | Type        | Date       | Time     | Size   | Filename
# ----|-------------|------------|----------|--------|------------------------------------------
#   1 | emergency   | 2024-10-25 | 14:30:15 | 245M   | emergency-kit-20241025-143015.tar.gz.age
#   2 | full        | 2024-10-24 | 02:00:12 | 189M   | vw-full-backup-20241024-020012.tar.gz.age
#   3 | db          | 2024-10-25 | 02:00:05 | 12M    | vw-db-backup-20241025-020005.sqlite3.gz.age
# ----|-------------|------------|----------|--------|------------------------------------------
```

### Database Backups

#### Automated Daily Backups
```bash
# Configured via cron-setup.sh (automated)
# Daily at 2:00 AM: Database backup with rclone sync
# Retention: 14 days local, configurable remote

# Manual database backup
make backup-db
# Or: ./backup.sh --type db

# Database backup with cloud sync
./backup.sh --type db --rclone

# Database backup with email notification
./backup.sh --type db --email
```

#### Database Backup Features
- **Live Backup**: Creates consistent snapshot from running container
- **Integrity Check**: Verifies database integrity before backup
- **Compression**: Gzip compression for space efficiency
- **Encryption**: Age encryption with verification
- **Fallback**: Automatic fallback to filesystem backup if container stopped

### Full System Backups

#### Automated Weekly Backups
```bash
# Configured via cron-setup.sh (automated)
# Weekly on Sunday at 1:00 AM: Full system backup with rclone sync
# Retention: 30 days local, configurable remote

# Manual full system backup
make backup-full
# Or: ./backup.sh --type full

# Full backup with all options
./backup.sh --type full --rclone --email
```

#### Full Backup Contents
- **Configuration Files**: docker-compose.yml, .env, Caddyfile, fail2ban configs
- **Encrypted Secrets**: Complete secrets directory with Age keys
- **Application Data**: VaultWarden database and user data
- **System Information**: Backup metadata and recovery instructions
- **Consistent Snapshot**: Database snapshot taken while running if possible

### Emergency Recovery Kits

#### Manual Emergency Kits
```bash
# Create disaster recovery kit
make backup-emergency
# Or: ./backup.sh --type emergency

# Emergency kit with cloud sync and notification
./backup.sh --type emergency --rclone --email
```

#### Emergency Kit Contents
- **Complete System State**: All configuration and data files
- **Recovery Documentation**: Detailed restoration instructions
- **Self-Contained**: Everything needed for bare-metal recovery
- **Kit Information**: Metadata about source system and creation time
- **Verified Integrity**: Full verification of all components

#### Emergency Kit Structure
```
emergency-kit-YYYYMMDD-HHMMSS.tar.gz.age
├── docker-compose.yml          # Container configuration
├── .env                        # Environment variables
├── caddy/                      # Reverse proxy configuration
├── fail2ban/                   # Security configuration  
├── secrets/                    # Encrypted secrets and keys
├── data/                       # VaultWarden database and files
├── RECOVERY.md                 # Recovery instructions
└── kit-info.txt               # Kit metadata
```

## Enhanced Restore Operations

### Interactive Restore Process

The new interactive restore feature provides a user-friendly way to select and restore backups:

```bash
# Start interactive restore
make restore
# Or: ./restore.sh --interactive

# Example interactive session:
# Scanning for available local backups...
#
# Available Backups (Newest First):
#  ID | Type        | Date       | Time     | Size   | Filename  
# ----|-------------|------------|----------|--------|------------------------------------------
#   1 | emergency   | 2024-10-25 | 14:30:15 | 245M   | emergency-kit-20241025-143015.tar.gz.age
#   2 | full        | 2024-10-24 | 02:00:12 | 189M   | vw-full-backup-20241024-020012.tar.gz.age
#   3 | db          | 2024-10-25 | 02:00:05 | 12M    | vw-db-backup-20241025-020005.sqlite3.gz.age
# ----|-------------|------------|----------|--------|------------------------------------------
#
# Enter the ID number of the backup to restore (1-3) or 'q' to quit: 
```

### Restore Types and Procedures

#### Database Restore
```bash
# Interactive database restore
make restore
# Select database backup from menu

# Direct database restore
./restore.sh backups/db/vw-db-backup-20241025-020005.sqlite3.gz.age

# Preview database restore
./restore.sh --dry-run backups/db/backup-file.age
```

**Database Restore Process:**
1. **Service Stop**: Stops VaultWarden service safely
2. **Current Backup**: Creates backup of current database
3. **Integrity Check**: Verifies restored database integrity
4. **Permission Setting**: Sets correct ownership and permissions
5. **Service Start**: Restarts VaultWarden service
6. **Health Verification**: Confirms successful restoration

#### Full System Restore
```bash
# Interactive full system restore
make restore
# Select full backup from menu

# Direct full system restore
./restore.sh backups/full/vw-full-backup-20241024-020012.tar.gz.age

# Preview full system restore
./restore.sh --dry-run backups/full/backup-file.age
```

**Full System Restore Process:**
1. **Service Stop**: Stops all services
2. **Configuration Backup**: Backs up current configuration with timestamp
3. **File Restoration**: Restores all configuration files
4. **Data Restoration**: Restores VaultWarden data directory
5. **Permission Setting**: Sets correct ownership and permissions
6. **Service Start**: Starts all services
7. **Health Verification**: Confirms successful restoration

#### Emergency Kit Restore
```bash  
# Interactive emergency kit restore
make restore
# Select emergency kit from menu

# Direct emergency kit restore
./restore.sh backups/emergency/emergency-kit-20241025-143015.tar.gz.age

# Force emergency restore (skip confirmations)
./restore.sh --force backups/emergency/emergency-kit.age
```

**Emergency Kit Restore Process:**
1. **Service Stop**: Stops all services
2. **Complete Backup**: Creates backup of entire current state
3. **System Replacement**: Replaces all configuration and data
4. **Recovery Notes**: Saves recovery documentation
5. **Permission Setting**: Sets correct ownership and permissions
6. **Service Start**: Starts restored services
7. **Comprehensive Verification**: Full system health check

### Restore Safety Features

#### Confirmation Process
```bash
# Example confirmation dialog:
⚠️  DESTRUCTIVE OPERATION WARNING ⚠️

Restore Details:
  Type: full
  File: vw-full-backup-20241024-020012.tar.gz.age
  Path: /opt/vaultwarden/backups/full/vw-full-backup-20241024-020012.tar.gz.age
  Size: 189M
  Date: 2024-10-24 02:00:12 UTC

This will:
  - Stop all services
  - Replace configuration files (.env, compose, secrets, caddy, fail2ban)
  - Replace database and data directory with content from the backup
  - Restart all services

⚠️  All current configuration and data created *after* the backup date will be lost!

Are you absolutely sure you want to continue? (type 'yes' to confirm):
```

#### Automatic Backups Before Restore
- **Current State Backup**: Automatically backs up current state before restoration
- **Timestamped Backups**: Uses timestamp suffixes for backup identification
- **Recovery Capability**: Allows recovery to pre-restore state if needed

## Remote Backup Configuration

### rclone Integration

#### Interactive Setup
```bash
# Configure remote storage
make configure-rclone
# Or: rclone config

# Example providers:
# - Google Drive
# - Amazon S3  
# - Dropbox
# - Microsoft OneDrive
# - SFTP
# - Many others
```

#### Configuration Process
1. **Provider Selection**: Choose cloud storage provider
2. **Authentication**: Complete OAuth or credential setup
3. **Remote Naming**: Set remote name for .env configuration
4. **Testing**: Verify connection and permissions
5. **Integration**: Update RCLONE_REMOTE_NAME in .env

#### Remote Backup Operations
```bash
# Backup with automatic remote sync
./backup.sh --type db --rclone
./backup.sh --type full --rclone
./backup.sh --type emergency --rclone

# Verify remote backups
rclone ls YourRemote:vaultwarden_backups/

# Manual remote sync
rclone sync backups/ YourRemote:vaultwarden_backups/
```

### Supported Remote Storage

#### Cloud Providers
- **Google Drive**: Personal and business accounts
- **Amazon S3**: S3-compatible storage providers
- **Microsoft OneDrive**: Personal and business accounts
- **Dropbox**: Personal and business accounts
- **Box**: Enterprise cloud storage
- **pCloud**: European cloud storage

#### Self-Hosted Options
- **SFTP**: Any SSH-enabled server
- **WebDAV**: Nextcloud, ownCloud, etc.
- **FTP**: Traditional FTP servers
- **SMB**: Windows network shares

## Backup Verification and Integrity

### Automatic Verification

#### Encryption Verification
```bash
# All backups automatically verified after creation:
# 1. Encryption integrity check
# 2. Decryption test
# 3. Content structure verification
# 4. Database integrity check (for database backups)
```

#### Manual Verification
```bash
# Test backup integrity
age -d -i secrets/keys/age-key.txt backup-file.age > /dev/null
echo $?  # Should return 0

# Test database backup integrity
age -d -i secrets/keys/age-key.txt db-backup.age | gunzip | sqlite3 :memory: "PRAGMA integrity_check;"

# List backup contents (tar backups)
age -d -i secrets/keys/age-key.txt full-backup.age | tar -tzf -
```

### Health Monitoring Integration

```bash
# Health checks include backup verification
make health
# Verifies:
# - Recent backup existence
# - Backup file integrity
# - Age key accessibility
# - Remote storage connectivity (if configured)
```

## Disaster Recovery Procedures

### Complete System Loss Recovery

#### Prerequisites
- **Emergency Kit**: Recent emergency kit backup
- **Age Private Key**: Secure backup of encryption keys
- **DNS Access**: Ability to update DNS records
- **Cloud Access**: Access to cloud provider console

#### Recovery Steps

##### 1. New Server Provisioning
```bash
# Provision new server (Ubuntu 24.04 LTS recommended)
# Ensure network connectivity and DNS configuration
```

##### 2. Base System Setup
```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install required dependencies
sudo apt install -y docker.io docker-compose-plugin age sops nano rclone sqlite3 argon2 jq mailutils ufw curl

# Create project directory
sudo mkdir -p /opt/vaultwarden
sudo chown $USER:$USER /opt/vaultwarden
cd /opt/vaultwarden
```

##### 3. Emergency Kit Restoration
```bash
# Transfer emergency kit to new server
# Extract kit (example)
age -d -i /path/to/age-key.txt emergency-kit-YYYYMMDD-HHMMSS.tar.gz.age | tar -xzf -

# Set permissions
chmod 600 .env secrets/secrets.yaml secrets/keys/age-key.txt
chmod +x *.sh

# Set ownership
sudo chown -R $USER:$USER .
sudo chown -R $USER:$USER /var/lib/vaultwarden/
```

##### 4. Service Startup
```bash
# Start services
make up
# Or: ./startup.sh

# Verify health
make health
# Or: ./health.sh --comprehensive
```

##### 5. DNS Update
```bash
# Update DNS record to point to new server IP
# Test connectivity: nslookup vault.yourdomain.com
```

##### 6. Post-Recovery Verification
```bash
# Test web access
curl -f https://vault.yourdomain.com/

# Test admin panel
curl -u "admin:password" https://vault.yourdomain.com/admin/

# Create new backup
make backup-emergency

# Test break-glass admin
make breakglass-status
```

### Partial Recovery Scenarios

#### Configuration Loss Only
```bash
# If only configuration lost but data intact
make restore
# Select full system backup, data will be preserved if newer
```

#### Database Corruption
```bash
# If database corrupted but configuration intact
make restore  
# Select database backup only
```

#### Secret Key Loss
```bash
# If Age keys lost but backups exist with embedded keys
# Restore from emergency kit which includes keys
make restore
# Select emergency kit backup
```

## Backup Retention and Cleanup

### Automatic Cleanup

#### Retention Policies
```bash
# Configured in .env file:
BACKUP_RETENTION_DAYS=30              # Full system backups
DB_BACKUP_RETENTION_DAYS=14           # Database backups  
EMERGENCY_BACKUP_RETENTION_DAYS=90    # Emergency kits

# Automatic cleanup via maintenance.sh (monthly)
make maint-standard
```

#### Manual Cleanup
```bash
# Clean old backups manually
find backups/ -name "*.age" -mtime +30 -delete

# Clean specific backup type
find backups/db/ -name "*.age" -mtime +14 -delete
```

### Remote Storage Management

```bash
# List remote backups
rclone ls YourRemote:vaultwarden_backups/

# Clean old remote backups
rclone delete YourRemote:vaultwarden_backups/ --min-age 30d

# Sync local cleanup to remote
rclone sync backups/ YourRemote:vaultwarden_backups/ --delete-during
```

## Best Practices

### Backup Best Practices

1. **Regular Testing**: Test restore procedures quarterly
2. **Multiple Locations**: Use remote backups for off-site storage
3. **Key Security**: Maintain secure, separate backup of Age keys
4. **Documentation**: Keep current recovery procedures offline
5. **Verification**: Regularly verify backup integrity
6. **Retention**: Balance storage costs with recovery needs

### Security Best Practices

1. **Encryption Keys**: Store Age private keys separately from backups
2. **Access Control**: Restrict backup file permissions (600)
3. **Transport Security**: Use encrypted channels for remote backups
4. **Audit Trail**: Monitor backup and restore operations
5. **Key Rotation**: Rotate encryption keys quarterly
6. **Clean Credentials**: Remove temporary credentials after use

### Operational Best Practices

1. **Automation**: Rely on automated backups for consistency
2. **Monitoring**: Include backup status in health checks
3. **Documentation**: Maintain current restoration procedures
4. **Testing**: Practice emergency procedures without disruption
5. **Communication**: Document emergency contact procedures
6. **Recovery Time**: Optimize procedures for quick recovery

---

This backup and restore guide provides comprehensive coverage of all backup operations, including the new interactive features and Makefile shortcuts, optimized for reliable data protection and quick recovery in small team environments.
