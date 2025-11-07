# Migration Guide - VaultWarden-OCI

Guide for migrating to VaultWarden-OCI from other VaultWarden deployments or password managers.

## Migration Overview

VaultWarden-OCI uses a template-based, production-ready configuration optimized for small teams. This guide covers:

- Migrating from other VaultWarden deployments
- Migrating from Bitwarden cloud
- Migrating from other password managers
- Platform-specific considerations (OCI, generic cloud providers)

## Pre-Migration Checklist

Before starting migration:

- ✅ **Backup source system**: Create complete backup of current deployment
- ✅ **Export data**: Export all vaults, organizations, and attachments
- ✅ **Document configuration**: Note custom settings and integrations
- ✅ **Prepare target**: Setup VaultWarden-OCI on new server
- ✅ **Test environment**: Verify target system works before migration
- ✅ **Plan downtime**: Schedule maintenance window for migration
- ✅ **Notify users**: Inform team of migration timeline

## Migrating from Existing VaultWarden

### Method 1: Database Migration (Recommended)

**Prerequisites**:
- Access to source VaultWarden database
- Both systems use same VaultWarden version (or source is older)

**Steps**:

1. **Prepare target system**:
```bash
# Setup VaultWarden-OCI
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

# Initial setup
sudo ./setup.sh --domain vault.example.com --email admin@example.com
./edit-secrets.sh
nano .env
```

2. **Export source database**:
```bash
# On source system, stop VaultWarden
docker stop vaultwarden

# Backup database
cp /path/to/vaultwarden/data/db.sqlite3 db.sqlite3.backup

# Copy database to new server
scp db.sqlite3.backup user@new-server:/tmp/
```

3. **Import on target system**:
```bash
# Stop VaultWarden-OCI services
./startup.sh --down

# Copy database to correct location
sudo cp /tmp/db.sqlite3.backup /var/lib/vaultwarden/data/bwdata/db.sqlite3

# Fix permissions
sudo chown 1000:1000 /var/lib/vaultwarden/data/bwdata/db.sqlite3
sudo chmod 600 /var/lib/vaultwarden/data/bwdata/db.sqlite3

# Verify database integrity
docker compose run --rm vaultwarden sqlite3 /data/db.sqlite3 "PRAGMA integrity_check;"

# Start services
./startup.sh

# Verify
./health.sh --comprehensive
```

4. **Migrate attachments** (if applicable):
```bash
# Copy attachments directory
scp -r user@old-server:/path/to/vaultwarden/data/attachments /tmp/

# Copy to target
sudo cp -r /tmp/attachments /var/lib/vaultwarden/data/
sudo chown -R 1000:1000 /var/lib/vaultwarden/data/attachments
```

5. **Verify migration**:
```bash
# Test login
curl -X POST https://vault.example.com/identity/connect/token \\
  -H "Content-Type: application/x-www-form-urlencoded" \\
  -d "grant_type=password&username=test@example.com&password=test"

# Check admin panel
# Navigate to https://vault.example.com/admin

# Verify all vaults accessible
# Login with existing credentials and check data
```

### Method 2: Export/Import (Alternative)

**Use when**:
- Database migration not possible
- Version compatibility issues
- Want clean start with fresh database

**Steps**:

1. **Export from source**:
```bash
# Export via web vault
# Login → Settings → Export Vault → JSON format

# Or via CLI (if using bitwarden CLI)
bw export --output vault-export.json --format json
```

2. **Setup target**:
```bash
# Complete VaultWarden-OCI setup
sudo ./setup.sh --domain vault.example.com --email admin@example.com
./edit-secrets.sh
nano .env
./startup.sh
```

3. **Import to target**:
```bash
# Via web vault
# Login → Settings → Import Data → Select JSON → Upload file

# Or via CLI
bw import bitwardenjson vault-export.json
```

**Note**: Export/import may not preserve:
- Item history
- Trash items
- Some organizational metadata
- Attachment filenames (may need manual re-upload)

## Migrating from Bitwarden Cloud

**Steps**:

1. **Export from Bitwarden**:
```bash
# Via web vault
# Login → Settings → Export Vault → JSON format
# Download encrypted JSON export

# Or via CLI
bw login
bw unlock
bw export --output bitwarden-export.json --format json
```

2. **Setup VaultWarden-OCI**:
```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
sudo ./setup.sh --domain vault.example.com --email admin@example.com
./edit-secrets.sh
nano .env
./startup.sh
```

3. **Import to VaultWarden**:
```bash
# Via web vault
# Login → Settings → Import Data
# Select "Bitwarden (json)" format
# Upload bitwarden-export.json
```

4. **Migrate organizations** (if applicable):
```bash
# For each organization:
# 1. Export from Bitwarden cloud as organization owner
# 2. Create organization in VaultWarden
# 3. Import organization data
# 4. Invite members
```

5. **Update client applications**:
```bash
# Desktop app: Settings → Server URL
# Browser extension: Settings → Server URL
# Mobile app: Settings → Server URL

# Set to: https://vault.example.com
```

## Migrating from Other Password Managers

### From LastPass

1. **Export from LastPass**:
```bash
# LastPass web vault
# More Options → Advanced → Export → Save as CSV
```

2. **Convert format** (if needed):
```bash
# Use bitwarden CLI to import
bw import lastpasscsv lastpass-export.csv
```

3. **Import to VaultWarden**:
```bash
# Via web vault
# Settings → Import Data → LastPass (csv)
```

### From 1Password

1. **Export from 1Password**:
```bash
# 1Password app
# File → Export → 1Password Interchange Format (1pif)
```

2. **Import to VaultWarden**:
```bash
# Via web vault
# Settings → Import Data → 1Password (1pif)
```

### From KeePass

1. **Export from KeePass**:
```bash
# KeePass
# File → Export → KeePass XML (2.x)
```

2. **Import to VaultWarden**:
```bash
# Via web vault
# Settings → Import Data → KeePass 2 (xml)
```

## Platform-Specific Migration

### Migrating to Oracle Cloud Infrastructure (OCI)

**OCI-Specific Considerations**:

- **SSH log location**: Uses `/var/log/secure` instead of `/var/log/auth.log`
- **Dynamic IPs**: Setup includes automatic DNS updates
- **Break-glass admin**: Essential for OCI serial console access
- **Firewall**: Pre-configured for Cloudflare-only traffic

**Setup**:
```bash
# Standard setup auto-detects OCI/Oracle Linux
sudo ./setup.sh --domain vault.example.com --email admin@example.com --auto

# Setup will detect /var/log/secure and configure accordingly
# Create break-glass admin for emergency console access
./create-breakglass-admin.sh
```

### Migrating from Docker Compose to VaultWarden-OCI

**Key Differences**:
- **Template-based**: Configuration via templates
- **Resource limits**: Pre-configured for 6GB systems
- **Enhanced security**: Dual fail2ban, encrypted secrets
- **Email integration**: Uses msmtpd container
- **Automation**: Cron jobs for backups and maintenance

**Migration Steps**:

1. **Backup existing deployment**:
```bash
# On old system
docker compose down
tar -czf vaultwarden-backup.tar.gz /path/to/vaultwarden
```

2. **Extract data directory**:
```bash
# Copy data to new server
scp vaultwarden-backup.tar.gz user@new-server:/tmp/
```

3. **Setup VaultWarden-OCI**:
```bash
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
sudo ./setup.sh --domain vault.example.com --email admin@example.com
./edit-secrets.sh
nano .env
```

4. **Migrate data**:
```bash
# Stop services
./startup.sh --down

# Extract old data
cd /tmp
tar -xzf vaultwarden-backup.tar.gz

# Copy to new location
sudo cp -r /tmp/vaultwarden/data/* /var/lib/vaultwarden/data/
sudo chown -R 1000:1000 /var/lib/vaultwarden/data

# Start services
cd /path/to/VaultWarden-OCI
./startup.sh
```

## Post-Migration Tasks

### Verification Checklist

- ✅ **Login test**: Verify users can login with existing credentials
- ✅ **Data integrity**: Check all vaults, items, and attachments
- ✅ **Organizations**: Verify organization access and permissions
- ✅ **2FA**: Test two-factor authentication
- ✅ **Attachments**: Verify file downloads work
- ✅ **Sends**: Test send functionality
- ✅ **Email**: Test email notifications
- ✅ **Admin panel**: Verify admin access works

### Security Hardening

```bash
# Change admin token
./edit-secrets.sh
# Update: admin_token

# Update admin basic auth
# Generate new bcrypt hash
docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password

# Update secrets
./edit-secrets.sh
# Set: admin_basic_auth_hash

# Restart services
./startup.sh --force-restart

# Verify security
./health.sh --comprehensive
```

### Setup Automation

```bash
# Install cron jobs
sudo ./cron-setup.sh --install

# Verify backups work
./backup.sh --type db
./backup.sh --list

# Test restore
./restore.sh --dry-run
```

### Update Client Applications

For each user:

1. **Desktop applications**:
   - Settings → Account → Server URL
   - Set to: `https://vault.example.com`

2. **Browser extensions**:
   - Settings → Server URL
   - Set to: `https://vault.example.com`

3. **Mobile apps**:
   - Settings → Server URL
   - Set to: `https://vault.example.com`

## Rollback Plan

If migration fails:

1. **Keep old system running** during migration
2. **Test new system thoroughly** before decommissioning old
3. **Keep old system backups** for 30+ days
4. **Document rollback procedure**:

```bash
# If rollback needed:
# 1. Point DNS back to old server
./update-dns.sh  # Update to old IP

# 2. Notify users to switch back
# 3. Restore old system from backup if needed
```

## Troubleshooting Migration

### Database import fails

```bash
# Check database version compatibility
sqlite3 db.sqlite3 "PRAGMA user_version;"

# Verify database integrity
sqlite3 db.sqlite3 "PRAGMA integrity_check;"

# Try database maintenance
./db-maint.sh
```

### Attachments not accessible

```bash
# Check directory permissions
ls -la /var/lib/vaultwarden/data/attachments

# Fix permissions
sudo chown -R 1000:1000 /var/lib/vaultwarden/data/attachments
sudo chmod -R 755 /var/lib/vaultwarden/data/attachments
```

### Users can't login

```bash
# Check admin token
./edit-secrets.sh --test

# Verify VaultWarden is running
docker compose ps vaultwarden

# Check logs
docker compose logs vaultwarden | grep -i auth

# Test admin panel
curl -I https://vault.example.com/admin
```

### Email not working after migration

```bash
# Test email configuration
./test-email-simple.sh --verbose

# Check msmtpd logs
docker compose logs msmtpd

# Verify SMTP settings
nano .env
./edit-secrets.sh  # Check smtp_password
```

## Migration Best Practices

1. **Test in staging first**: Never migrate production directly
2. **Backup everything**: Multiple backups before starting
3. **Document changes**: Keep detailed migration notes
4. **Plan rollback**: Have working rollback plan
5. **Verify thoroughly**: Test all functionality before going live
6. **Communicate clearly**: Keep users informed
7. **Schedule wisely**: Migrate during low-usage periods
8. **Monitor closely**: Watch logs and metrics after migration

## Support

For migration assistance:

1. Review documentation in `/docs` directory
2. Check GitHub issues for similar migrations
3. Create detailed issue with:
   - Source system details
   - Migration method used
   - Error messages and logs
   - Steps already attempted

---

This migration guide provides comprehensive procedures for moving to VaultWarden-OCI from various sources with platform-specific considerations and rollback procedures.
