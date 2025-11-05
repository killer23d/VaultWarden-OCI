# Backup and Restore Guide - VaultWarden-OCI

This comprehensive guide covers backup creation, management, and restoration procedures for VaultWarden-OCI, including enhanced atomic operations, improved backup listing, interactive restore features, and template-integrated recovery.

## Quick Reference

### Backup Operations
```bash
# Create backups with atomic operations
./backup.sh --type db          # Database backup (daily automated)
./backup.sh --type full        # Full system backup (weekly automated)
./backup.sh --type emergency   # Disaster recovery kit (manual)

# Manage backups with detailed listing
./backup.sh --list

# Remote backup configuration
rclone config                   # Setup remote storage
```

### Emergency Recovery
```bash
# SSH access lost - Use break-glass admin
./create-breakglass-admin.sh status  # Check emergency admin readiness

# Complete system recovery
./restore.sh --interactive     # Select backup via interactive menu
```

## Backup Strategy Overview

### Three-Tier Backup System

| Backup Type | Contents | Frequency | Retention | Use Case |
|-------------|----------|-----------|----------|----------|
| **Database** | SQLite database only | Daily (automated) | 14 days | Quick data recovery |
| **Full System** | Templates + config + data | Weekly (automated) | 30 days | System restoration |
| **Emergency Kit** | Self-contained recovery | Manual/as-needed | 90 days | Disaster recovery |

### Backup Security Features

- **Age Encryption**: All backups encrypted (ChaCha20-Poly1305)
- **Atomic Operations**: Prevents corruption during creation
- **Integrity Verification**: Automatic verification after creation
- **Tamper Prevention**: Authenticated encryption
- **Key Management**: Separate Age keys
- **Remote Sync**: rclone integration
- **Notifications**: Optional email on completion/errors (via msmtpd)

## Backup Operations (Current)

### Enhanced Backup Listing
```bash
./backup.sh --list
# Shows ID, type, timestamp, size, filename (newest first)
```

### Database Backups (Atomic)
```bash
# Automated daily at 3:00 AM via cron-setup.sh
./backup.sh --type db
./backup.sh --type db --rclone
./backup.sh --type db --email   # Email sent via msmtpd
```

### Full System Backups (Atomic)
```bash
# Automated weekly on Sunday 1:00 AM
./backup.sh --type full
./backup.sh --type full --rclone --email  # Email via msmtpd
```

### Emergency Kits (Comprehensive)
```bash
./backup.sh --type emergency
./backup.sh --type emergency --rclone --email  # Email via msmtpd
```

## Restore Operations (Current)

### Interactive Restore
```bash
./restore.sh --interactive
# Select from DB / Full / Emergency backups
```

### Database Restore (Safe)
```bash
./restore.sh --interactive  # Choose DB backup
# Process: stop → backup current → restore → verify → start → health check
```

### Full System Restore (Template-Integrated)
```bash
./restore.sh --interactive  # Choose full backup
# Restores templates, generated config, data; then validates and starts
```

### Emergency Kit Restore (Complete)
```bash
./restore.sh --interactive  # Choose emergency kit
# Performs full system replacement with validation
```

## Remote Backup (rclone)

### Setup and Use
```bash
rclone config
# Update RCLONE_REMOTE_NAME in .env
docker compose config  # Validate after changes

# Run backups with remote sync
./backup.sh --type db --rclone
./backup.sh --type full --rclone
./backup.sh --type emergency --rclone

# Verify remote
rclone ls YourRemote:vaultwarden_backups/
```

## Verification and Integrity

### Automatic Verification (Atomic)
- Encryption integrity
- Decryption test
- Content structure verification
- DB integrity (for DB backups)
- WAL checkpoint verification

### Manual Verification
```bash
age -d -i secrets/keys/age-key.txt backup-file.age > /dev/null
age -d -i secrets/keys/age-key.txt db-backup.age | gunzip | sqlite3 :memory: "PRAGMA integrity_check;"
```

## Best Practices (Current)

### Backup
- Use atomic operations
- Keep multiple locations (remote + local)
- Secure keys separately
- Include templates in emergency kits
- Test restore quarterly
- Enable email notifications where helpful (msmtpd)

### Security
- Store Age private keys offline copies
- Restrict backup file permissions (600)
- Use encrypted transport for remotes
- Rotate keys quarterly

### Operations
- Include backups in health checks
- Maintain current recovery procedures
- Practice emergency procedures
