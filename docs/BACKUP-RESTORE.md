# Backup and Restore Guide - VaultWarden-OCI

This comprehensive guide covers backup creation, management, and restoration procedures for VaultWarden-OCI, including enhanced atomic operations, improved backup listing, and interactive restore features.

## Quick Reference

### Backup Operations
```bash
# Create backups with enhanced atomic operations
./backup.sh --type db          # Quick database backup
./backup.sh --type full        # Complete system backup  
./backup.sh --type emergency   # Disaster recovery kit

# Manage backups with enhanced listing
./backup.sh --list             # Show all available backups with details

# Remote backup configuration
rclone config                   # Setup remote backup storage
```

### Emergency Recovery
```bash
# SSH access lost - Use break-glass admin
./create-breakglass-admin.sh status  # Check emergency admin status
# Use OCI Console → Instance → Console Connection
# Login with break-glass credentials, fix SSH, then clean up

# Complete system recovery with interactive selection
./restore.sh --interactive     # Select backup from enhanced menu
```

## Backup Strategy Overview

### Three-Tier Backup System

| Backup Type | Contents | Frequency | Retention | Use Case |
|-------------|----------|-----------|-----------|----------|
| **Database** | SQLite database only | Daily (automated) | 14 days | Quick data recovery |
| **Full System** | Complete configuration + data | Weekly (automated) | 30 days | System restoration |
| **Emergency Kit** | Self-contained recovery package | Manual/as-needed | 90 days | Disaster recovery |

### Enhanced Backup Security Features

- **Age Encryption**: All backups encrypted with ChaCha20-Poly1305
- **Atomic Operations**: Prevents corrupt backups during creation
- **Integrity Verification**: Automatic verification after creation
- **Tamper Prevention**: Authenticated encryption prevents modification
- **Key Management**: Separate Age keys for enhanced security
- **Remote Sync**: Optional cloud storage with rclone integration

## Enhanced Backup Operations

### Interactive Backup Listing

The `backup.sh` script now includes significantly enhanced listing capabilities:

```bash
# List all available backups with detailed information
./backup.sh --list

# Example enhanced output:
# Available local backups:
#
#  ID | Type        | Date       | Time     | Size   | Filename
# ----|-------------|------------|----------|--------|------------------------------------------
#   1 | emergency   | 2024-10-25 | 14:30:15 | 245M   | emergency-kit-20241025-143015.tar.gz.age
#   2 | full        | 2024-10-24 | 02:00:12 | 189M   | vw-full-backup-20241024-020012.tar.gz.age
#   3 | db          | 2024-10-25 | 02:00:05 | 12M    | vw-db-backup-20241025-020005.sqlite3.gz.age
# ----|-------------|------------|----------|--------|------------------------------------------
```

### Database Backups with Atomic Operations

#### Enhanced Automated Daily Backups
```bash
# Configured via cron-setup.sh (automated)
# Daily at 2:00 AM: Database backup with rclone sync
# Retention: 14 days local, configurable remote

# Manual database backup with atomic operations
./backup.sh --type db

# Database backup with cloud sync
./backup.sh --type db --rclone

# Database backup with email notification
./backup.sh --type db --email
```

#### Enhanced Database Backup Features
- **Atomic Operations**: Prevents corrupt backups during creation
- **Live Backup**: Creates consistent snapshot from running container
- **WAL Checkpoints**: Improved database consistency for live snapshots
- **Integrity Check**: Verifies database integrity before backup
- **Better Disk Space Management**: More conservative space checks
- **Compression**: Gzip compression for space efficiency
- **Encryption**: Age encryption with verification
- **Fallback**: Automatic fallback to filesystem backup if container stopped

### Full System Backups with Enhanced Reliability

#### Automated Weekly Backups
```bash
# Configured via cron-setup.sh (automated)
# Weekly on Sunday at 1:00 AM: Full system backup with rclone sync
# Retention: 30 days local, configurable remote

# Manual full system backup with atomic operations
./backup.sh --type full

# Full backup with all options
./backup.sh --type full --rclone --email
```

#### Full Backup Contents
- **Template Files**: docker-compose.yml.example, .env.example
- **Generated Configuration**: docker-compose.yml, .env, Caddyfile, fail2ban configs
- **Encrypted Secrets**: Complete secrets directory with Age keys
- **Application Data**: VaultWarden database and user data
- **System Information**: Backup metadata and recovery instructions
- **Atomic Snapshot**: Database snapshot taken while running with WAL checkpoints

### Emergency Recovery Kits

#### Manual Emergency Kits with Self-Contained Recovery
```bash
# Create disaster recovery kit with atomic operations
./backup.sh --type emergency

# Emergency kit with cloud sync and notification
./backup.sh --type emergency --rclone --email
```

#### Emergency Kit Contents
- **Complete System State**: All configuration and data files
- **Template Files**: Source .example files for reconstruction
- **Recovery Documentation**: Detailed restoration instructions
- **Self-Contained**: Everything needed for bare-metal recovery
- **Kit Information**: Metadata about source system and creation time
- **Verified Integrity**: Full verification of all components

#### Emergency Kit Structure
```
emergency-kit-YYYYMMDD-HHMMSS.tar.gz.age
├── docker-compose.yml.example  # Template files
├── .env.example               # Environment template
├── docker-compose.yml         # Generated configuration
├── .env                       # Environment variables
├── caddy/                     # Reverse proxy configuration
├── fail2ban/                  # Enhanced security configuration  
├── secrets/                   # Encrypted secrets and keys
├── data/                      # VaultWarden database and files
├── RECOVERY.md               # Recovery instructions
└── kit-info.txt              # Kit metadata
```

## Enhanced Restore Operations

### Interactive Restore Process

The new interactive restore feature provides a user-friendly way to select and restore backups:

```bash
# Start interactive restore with enhanced menu
./restore.sh --interactive

# Example enhanced interactive session:
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

### Restore Types and Enhanced Procedures

#### Database Restore with Integrity Verification
```bash
# Interactive database restore
./restore.sh --interactive
# Select database backup from enhanced menu

# Direct database restore
./restore.sh backups/db/vw-db-backup-20241025-020005.sqlite3.gz.age

# Preview database restore
./restore.sh --dry-run backups/db/backup-file.age
```

**Enhanced Database Restore Process:**
1. **Service Stop**: Stops VaultWarden service safely
2. **Current Backup**: Creates atomic backup of current database
3. **Integrity Check**: Verifies restored database integrity
4. **WAL Processing**: Properly handles WAL files
5. **Permission Setting**: Sets correct ownership and permissions
6. **Service Start**: Restarts VaultWarden service
7. **Health Verification**: Confirms successful restoration

#### Full System Restore with Template Integration
```bash
# Interactive full system restore
./restore.sh --interactive
# Select full backup from enhanced menu

# Direct full system restore
./restore.sh backups/full/vw-full-backup-20241024-020012.tar.gz.age

# Preview full system restore
./restore.sh --dry-run backups/full/backup-file.age
```

**Enhanced Full System Restore Process:**
1. **Service Stop**: Stops all services
2. **Configuration Backup**: Backs up current configuration with timestamp
3. **Template Restoration**: Restores both templates and generated files
4. **Data Restoration**: Restores VaultWarden data directory
5. **Permission Setting**: Sets correct ownership and permissions
6. **Service Start**: Starts all services
7. **Health Verification**: Confirms successful restoration

#### Emergency Kit Restore with Complete Recovery
```bash  
# Interactive emergency kit restore
./restore.sh --interactive
# Select emergency kit from enhanced menu

# Direct emergency kit restore
./restore.sh backups/emergency/emergency-kit-20241025-143015.tar.gz.age

# Force emergency restore (skip confirmations)
./restore.sh --force backups/emergency/emergency-kit.age
```

**Enhanced Emergency Kit Restore Process:**
1. **Service Stop**: Stops all services
2. **Complete Backup**: Creates atomic backup of entire current state
3. **Template Replacement**: Replaces both templates and generated files
4. **System Replacement**: Replaces all configuration and data
5. **Recovery Notes**: Saves recovery documentation
6. **Permission Setting**: Sets correct ownership and permissions
7. **Service Start**: Starts restored services
8. **Comprehensive Verification**: Full system health check

### Enhanced Restore Safety Features

#### Comprehensive Confirmation Process
```bash
# Example enhanced confirmation dialog:
⚠️  DESTRUCTIVE OPERATION WARNING ⚠️

Restore Details:
  Type: full
  File: vw-full-backup-20241024-020012.tar.gz.age
  Path: /opt/vaultwarden/backups/full/vw-full-backup-20241024-020012.tar.gz.age
  Size: 189M
  Date: 2024-10-24 02:00:12 UTC
  Contains: Templates, configuration, database, secrets

This will:
  - Stop all services
  - Replace template files (.example files)
  - Replace configuration files (.env, compose, secrets, caddy, fail2ban)
  - Replace database and data directory with content from the backup
  - Restart all services

⚠️  All current configuration and data created *after* the backup date will be lost!

Are you absolutely sure you want to continue? (type 'yes' to confirm):
```

#### Automatic Backups Before Restore
- **Current State Backup**: Automatically creates atomic backup of current state before restoration
- **Timestamped Backups**: Uses timestamp suffixes for backup identification
- **Recovery Capability**: Allows recovery to pre-restore state if needed

## Remote Backup Configuration

### rclone Integration

#### Interactive Setup
```bash
# Configure remote storage
rclone config

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

#### Remote Backup Operations with Atomic Sync
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

## Backup Verification and Integrity

### Enhanced Automatic Verification

#### Atomic Encryption Verification
```bash
# All backups automatically verified after creation with atomic operations:
# 1. Encryption integrity check
# 2. Decryption test
# 3. Content structure verification
# 4. Database integrity check (for database backups)
# 5. WAL checkpoint verification
```

#### Manual Verification
```bash
# Test backup integrity
age -d -i secrets/keys/age-key.txt backup-file.age > /dev/null
echo $?  # Should return 0

# Test database backup integrity with WAL consideration
age -d -i secrets/keys/age-key.txt db-backup.age | gunzip | sqlite3 :memory: "PRAGMA integrity_check;"

# List backup contents (tar backups)
age -d -i secrets/keys/age-key.txt full-backup.age | tar -tzf -
```

### Health Monitoring Integration

```bash
# Health checks include enhanced backup verification
./health.sh --comprehensive
# Verifies:
# - Recent backup existence
# - Backup file integrity
# - Age key accessibility
# - Remote storage connectivity (if configured)
# - Atomic operation completion
```

## Best Practices

### Enhanced Backup Best Practices

1. **Atomic Operations**: Rely on enhanced atomic backup operations
2. **Multiple Locations**: Use remote backups for off-site storage
3. **Key Security**: Maintain secure, separate backup of Age keys
4. **Template Preservation**: Ensure emergency kits include template files
5. **Interactive Restore**: Use enhanced interactive restore for reliability
6. **Regular Testing**: Test restore procedures quarterly with atomic operations

### Security Best Practices

1. **Encryption Keys**: Store Age private keys separately from backups
2. **Access Control**: Restrict backup file permissions (600)
3. **Transport Security**: Use encrypted channels for remote backups
4. **Atomic Operations**: Leverage atomic operations to prevent corruption
5. **Audit Trail**: Monitor backup and restore operations
6. **Key Rotation**: Rotate encryption keys quarterly
7. **Clean Credentials**: Remove temporary credentials after use

### Operational Best Practices

1. **Template-Based Recovery**: Ensure emergency kits include template files
2. **Enhanced Automation**: Rely on atomic backup operations for consistency
3. **Interactive Restore**: Use enhanced interactive features for reliability
4. **Monitoring**: Include backup status in health checks
5. **Documentation**: Maintain current restoration procedures
6. **Testing**: Practice emergency procedures with atomic operations
7. **Communication**: Document emergency contact procedures
8. **Recovery Time**: Optimize procedures for quick recovery with enhanced features

---

This backup and restore guide provides comprehensive coverage of all backup operations, including enhanced atomic operations, improved backup listing, interactive restore features, and template-based recovery optimized for reliable data protection and quick recovery in small team environments.
