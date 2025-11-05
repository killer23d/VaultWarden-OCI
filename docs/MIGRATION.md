# Migration Guide - VaultWarden-OCI

This guide helps you migrate to VaultWarden-OCI's current template-based architecture and provides migration paths for different scenarios including version updates, system migrations, and configuration changes with enhanced security features.

## Current Template-Based Migration Overview

The current VaultWarden-OCI system provides:
- **Resource-Optimized Templates**: Container limits for 6GB systems  
- **Enhanced Security Integration**: Dual CF+UFW blocking, forensic logging
- **Atomic Operations**: Backup and restore procedures with integrity
- **Centralized Security**: lib/security.sh validation functions
- **Emergency Access**: Break-glass admin with validation
- **Consistent Deployments**: Same templates, identical configurations
- **Containerized Email**: msmtpd relay by default (host msmtp-mta optional)

## Current Migration Types

### 1. Legacy to Current Template-Based Migration

Migrating existing installations to current enhanced architecture:

#### Current Pre-Migration Assessment
```bash
# Check current template availability
ls -la *.example

# Check current container resource usage
docker stats --no-stream

# Check current security features
docker compose logs fail2ban | grep -E "CF|UFW|Rate"

# Create comprehensive backup with current atomic operations
./backup.sh --type emergency --rclone --email  # (email via msmtpd)
```

#### Current Migration Steps
```bash
# 1. Update to current enhanced version
git pull origin main

# 2. Stop services safely
./startup.sh --down

# 3. Generate current configuration with resource limits
sudo ./setup.sh --domain $(grep DOMAIN .env | cut -d= -f2) --email $(grep ADMIN_EMAIL .env | cut -d= -f2) --force

# 4. Validate current template configuration
docker compose config

# 5. Start with current enhanced features
./startup.sh

# 6. Verify current implementation
./health.sh --comprehensive
docker compose logs fail2ban | grep -E "CF.*ok|UFW.*ok"
```

### 2. Current Server Migration (Same Domain)

Moving to new server with current enhanced architecture:

#### Current Source Server Preparation
```bash
# Create current emergency kit with templates
./backup.sh --type emergency --rclone --email  # (email via msmtpd)

# Document current enhanced configuration
docker compose config > migration-current-config.yml
docker stats --no-stream > migration-resources.txt
./health.sh --comprehensive --json > migration-health.json
./create-breakglass-admin.sh status > migration-breakglass.txt

# Document current security features
docker compose logs fail2ban | grep -E "Rate|CF|UFW" > migration-security.txt

# Stop services when ready
./startup.sh --down
```

#### Current Target Server Setup
```bash
# 1. Provision server for current requirements
sudo apt update && sudo apt upgrade -y

# 2. Clone current enhanced version
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

# 3. Transfer emergency kit with current templates
scp emergency-kit-YYYYMMDD-HHMMSS.tar.gz.age user@newserver:/tmp/

# 4. Restore with current enhanced features
./restore.sh /tmp/emergency-kit-YYYYMMDD-HHMMSS.tar.gz.age

# 5. Validate current template configuration
docker compose config

# 6. Start with current enhanced architecture
./startup.sh

# 7. Verify current implementation works
./health.sh --comprehensive
docker compose logs fail2ban | grep "dual.*action"
```

## Current Configuration Migration Scenarios

### Enhanced Security Migration (Current Features)

Migrating to current dual CF+UFW and forensic logging:

```bash
# 1. Update to current enhanced version
git pull origin main

# 2. Create backup with current atomic operations
./backup.sh --type emergency

# 3. Generate configuration with current enhancements
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# 4. Verify current dual-action configuration
docker compose config | grep -A 20 fail2ban

# 5. Start with current enhanced security
./startup.sh --force-restart

# 6. Verify current dual blocking works
docker compose logs fail2ban | grep -E "CF.*ok.*UFW.*ok"

# 7. Verify current forensic logging (3GB capacity)
ls -la /var/lib/vaultwarden/logs/caddy/
du -sh /var/lib/vaultwarden/logs/
```

### Current Resource Optimization Migration

Migrating to current container resource limits:

```bash
# 1. Document current resource usage
docker stats --no-stream > pre-migration-resources.txt

# 2. Create emergency backup
./backup.sh --type emergency

# 3. Update .env.example with current resource limits
nano .env.example
# Verify current limits:
# VAULTWARDEN_MEMORY_LIMIT=2G
# CADDY_MEMORY_LIMIT=1G  
# FAIL2BAN_MEMORY_LIMIT=512M
# MSMTPD_MEMORY_LIMIT=32M

# 4. Apply current resource-optimized templates
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# 5. Restart with current resource limits
./startup.sh --force-restart

# 6. Verify current resource allocation
docker stats --no-stream
docker compose config | grep -E "memory:|cpus:"
```

### Current Version Migration

Updating versions within current template system:

```bash
# 1. Create comprehensive backup
./backup.sh --type emergency --rclone

# 2. Update current version pins in template
nano .env.example
# Update to current stable versions:
# VAULTWARDEN_VERSION=1.30.5
# CADDY_VERSION=2.8.4-cloudflare
# FAIL2BAN_VERSION=1.1.0
# MSMTPD_VERSION=1.0.0

# 3. Apply current template updates
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# 4. Update with current safety measures
./startup.sh --force-restart

# 5. Verify current version deployment
./health.sh --comprehensive
docker compose ps --format "table {{.Service}}\t{{.Image}}"
```

## Current Migration Best Practices

### Current Pre-Migration Preparation

1. **Current Backup Strategy**
   ```bash
   # Create all current backup types
   ./backup.sh --type db --rclone
   ./backup.sh --type full --rclone  
   ./backup.sh --type emergency --rclone
   ```

2. **Current State Documentation**
   ```bash
   # Document current enhanced configuration
   docker compose config > current-pre-migration-config.yml
   docker stats --no-stream > current-resources.txt
   ./health.sh --comprehensive --json > current-health.json
   du -sh /var/lib/vaultwarden/logs/ > current-forensic-logs.txt
   ```

### Current Migration Execution

1. **Current Template-First Approach**
   - Edit `.example` files for current architecture
   - Use `sudo ./setup.sh --force` with current validation
   - Verify with `docker compose config` including resource limits
   - Test current dual CF+UFW blocking

2. **Current Validation Steps**
   ```bash
   # Validate current configuration
   docker compose config
   ./health.sh --comprehensive
   docker compose logs fail2ban | grep -E "CF|UFW|dual"
   curl -f https://vault.yourdomain.com/alive
   ```

### Current Migration Checklist

#### Current Pre-Migration
- [ ] Create current comprehensive backups (atomic operations)
- [ ] Document current resource usage and limits
- [ ] Document current security features (dual blocking, forensic logs)
- [ ] Test current migration in development
- [ ] Prepare current rollback procedures

#### Current Migration Execution  
- [ ] Stop services with current safe shutdown
- [ ] Update to current enhanced templates
- [ ] Apply current resource optimization
- [ ] Validate current template configuration
- [ ] Start with current enhanced features
- [ ] Verify current dual-action security

#### Current Post-Migration
- [ ] Verify current health checks pass
- [ ] Test current enhanced security (dual blocking)
- [ ] Confirm current forensic logging (3GB capacity)
- [ ] Verify current resource limits work
- [ ] Test current break-glass admin access
- [ ] Create post-migration backup with current atomic operations

## Current Rollback Procedures

### Current Configuration Rollback
```bash
# If current migration fails
./startup.sh --down

# Restore previous configuration
./restore.sh --interactive  # Select pre-migration backup

# Verify rollback
./health.sh --comprehensive
```

### Current Emergency Rollback
```bash
# Use current break-glass admin if needed
./create-breakglass-admin.sh status

# Access via OCI console if SSH unavailable
# Restore from current emergency kit
./restore.sh /path/to/emergency-kit.age

# Verify current system works
./health.sh --comprehensive
```

---

**Current Migration Status**: This guide reflects migration to the current VaultWarden-OCI implementation with:
- Resource optimization for 6GB systems (container limits)
- Dual Cloudflare+UFW fail2ban protection (idempotent operations)
- Enhanced forensic logging (3GB capacity, 60x retention improvement)  
- Atomic backup operations with template integration
- Centralized security validation (lib/security.sh)
- Break-glass emergency access with comprehensive validation
- Containerized email via msmtpd for notifications

All migration procedures work within the current enhanced architecture optimized for reliable, secure operation in small team environments.

**Migration Support**: Test all current procedures in development first. The current template-based system provides safer, more predictable migrations with enhanced security and resource management.
