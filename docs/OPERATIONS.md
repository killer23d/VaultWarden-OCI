# Operations Guide - VaultWarden-OCI

This comprehensive operations guide covers day-to-day management, maintenance procedures, monitoring, and troubleshooting for VaultWarden-OCI with current Cloudflare-only blocking, resource management, and automated operations.

## Daily Operations

### Service Management

#### Starting Services

```bash
# Full initialization startup (recommended)
./startup.sh

# Or use Makefile
make start

# Features:
# - Pre-flight validation checks
# - Secret extraction and validation
# - Dependency checks (Docker, containers)
# - Race condition handling
# - Comprehensive error reporting
```

#### Stopping Services

```bash
# Graceful shutdown
./startup.sh --stop

# Or use Docker Compose directly
docker compose down

# Or use Makefile
make stop

# Emergency stop (if graceful fails)
docker compose kill
```

#### Restarting Services

```bash
# Enhanced restart with fresh configuration
./startup.sh --force-restart

# Or use Makefile
make restart

# Features:
# - Stops all services cleanly
# - Re-extracts secrets
# - Validates configuration
# - Starts with fresh state
```

### Health Monitoring

#### Comprehensive Health Checks

```bash
# Run complete health diagnostic
./health.sh

# Or use Makefile
make health

# Checks performed:
# ✓ Docker daemon accessible
# ✓ All containers running
# ✓ Container resource usage
# ✓ Memory usage < 85% threshold
# ✓ VaultWarden responding
# ✓ Caddy configuration valid
# ✓ Fail2Ban operational
# ✓ msmtpd running
# ✓ Disk space available
# ✓ Secrets properly configured
# ✓ Network connectivity
```

#### Health Check with Email Notification

```bash
# Send health report via email
./health.sh --email

# Or use Makefile
make health-email

# Useful for automated monitoring
```

#### Container-Specific Health

```bash
# Check specific container
docker compose ps vaultwarden

# View container resource usage
docker stats --no-stream vaultwarden_app

# Check health status
docker inspect vaultwarden_app | jq '.[0].State.Health'
```

### Log Management

#### Viewing Logs

```bash
# All services
docker compose logs --follow

# Or use Makefile
make logs

# Specific service
docker compose logs vaultwarden --follow --tail=50
make logs SERVICE=vaultwarden

# Multiple services
docker compose logs vaultwarden caddy --follow

# With timestamps
docker compose logs --follow --timestamps
```

#### Log Analysis

```bash
# Authentication failures
grep "401" ${PROJECT_STATE_DIR}/logs/caddy/auth_attempts.log | jq

# Admin panel access
cat ${PROJECT_STATE_DIR}/logs/caddy/admin_access.log | jq

# Security events
grep "block\|ban" ${PROJECT_STATE_DIR}/logs/fail2ban/fail2ban.log

# VaultWarden errors
grep "ERROR" ${PROJECT_STATE_DIR}/logs/vaultwarden/vaultwarden.log

# Rate limit hits
grep "429" ${PROJECT_STATE_DIR}/logs/caddy/access.log | jq
```

#### Log Rotation Status

Current log retention:
```
Main Access Log:   1GB   (30-day retention)
Admin Access Log:  750MB (90-day retention)
Auth Attempts Log: 750MB (90-day retention)
Security Log:      500MB (180-day retention)
```

Check log sizes:
```bash
# Check log directory sizes
du -sh ${PROJECT_STATE_DIR}/logs/*

# Check specific log files
ls -lh ${PROJECT_STATE_DIR}/logs/caddy/*.log
```

## Backup Operations

### Creating Backups

#### Database Backup (Quick)

```bash
# Create database backup
./backup.sh --type db

# Or use Makefile
make backup

# Features:
# - Atomic operation (prevents corruption)
# - WAL checkpoint before backup
# - Integrity verification
# - Age encryption
# - 14-day retention
```

#### Full System Backup

```bash
# Complete system backup
./backup.sh --type full

# Or use Makefile
make backup-full

# Includes:
# - Database
# - Configuration files
# - Secrets (encrypted)
# - Caddy certificates
# - All logs
# - 30-day retention
```

#### Full Backup with Verification

```bash
# Backup with end-to-end verification
./backup.sh --type full --full-verification

# Verification process:
# 1. Create backup
# 2. Decrypt backup
# 3. Extract contents
# 4. Verify database integrity
# 5. Confirm all files present
# 6. Cleanup test environment

# Recommended: Weekly
```

#### Emergency Recovery Kit

```bash
# Create disaster recovery kit
./backup.sh --type emergency

# Or use Makefile
make backup-emergency

# Includes everything for complete restoration
# Retention: 90 days
```

### Remote Backups

#### Configure Remote Storage

```bash
# Interactive configuration
rclone config

# Example remotes:
# - Google Drive
# - Amazon S3
# - Dropbox
# - OneDrive
# - Backblaze B2

# Update .env with remote name
nano .env
# Set: RCLONE_REMOTE_NAME=your_remote_name
```

#### Backup with Remote Sync

```bash
# Create backup and sync to remote
./backup.sh --type db --rclone

# Or for full backup
./backup.sh --type full --rclone

# Features:
# - Encrypted before upload
# - TLS in transit
# - Age encryption at rest
# - Automatic retry on failure
```

### Managing Backups

#### List Available Backups

```bash
# List all backups with details
./backup.sh --list

# Or use Makefile
make list-backups

# Output includes:
# - Timestamp
# - Backup type
# - Size
# - File location
# - Integrity status
```

#### Restore from Backup

```bash
# Interactive restore (recommended)
./restore.sh

# Or use Makefile
make restore

# Features:
# - Lists available backups
# - Interactive selection
# - Validates before restore
# - Creates safety backup
# - Comprehensive error handling

# Or restore specific file
./restore.sh --file /path/to/backup.age
```

## Update Operations

### Updating Containers

#### Standard Update

```bash
# Update all containers
./update.sh

# Or use Makefile
make update

# Process:
# 1. Create automatic backup
# 2. Pull latest images (respects pinned versions)
# 3. Stop services
# 4. Start with new images
# 5. Verify health
```

#### Update with System Packages

```bash
# Update containers and system
./update.sh --system

# Or use Makefile
make update-system

# Additionally updates:
# - System packages (apt)
# - Security updates
# - Docker engine
```

### Version Management

#### Production Mode (Pinned Versions)

```bash
# .env file (set by setup.sh --auto)
VAULTWARDEN_VERSION=1.34.3
CADDY_VERSION=2.8.4-cloudflare
FAIL2BAN_VERSION=1.1.0
MSMTPD_VERSION=1.0.0
```

Benefits:
- ✅ Predictable updates
- ✅ Tested versions
- ✅ Rollback capability
- ✅ Production stability

#### Development Mode (Latest Versions)

```bash
# .env file (set by setup.sh --use-latest)
#VAULTWARDEN_VERSION=1.34.3      # Commented out
#CADDY_VERSION=2.8.4-cloudflare  # Commented out
#FAIL2BAN_VERSION=1.1.0          # Commented out
#MSMTPD_VERSION=1.0.0            # Commented out
```

Pulls latest versions on update.

### Manual Version Upgrade

```bash
# Edit .env to update version
nano .env
# Change: VAULTWARDEN_VERSION=1.34.4

# Create backup before upgrade
./backup.sh --type emergency

# Apply update
docker compose pull vaultwarden
docker compose up -d vaultwarden

# Verify health
./health.sh
```

## Maintenance Operations

### Basic Maintenance

```bash
# Run basic maintenance
./maintenance.sh

# Or use Makefile
make maintenance

# Tasks performed:
# - Docker system cleanup
# - Remove unused images
# - Remove unused volumes
# - Clear old logs
# - Temporary file cleanup
```

### Comprehensive Maintenance

```bash
# Full maintenance with database optimization
./maintenance.sh --comprehensive

# Or use Makefile
make maintenance-full

# Additional tasks:
# - Stop VaultWarden
# - WAL checkpoint
# - Database integrity check
# - VACUUM database (offline)
# - Verify integrity after VACUUM
# - Restart VaultWarden
# - Verify service health

# Recommended: Monthly
```

### Firewall Maintenance

```bash
# Update Cloudflare IP ranges
./maintenance.sh --update-firewall

# Features:
# - Fetches latest Cloudflare IPs
# - Adds new rules BEFORE removing old
# - Validates before applying
# - Safe fallback if API fails
# - Comprehensive logging

# Recommended: Quarterly
```

### Database Maintenance

```bash
# Safe database optimization
./db-maint.sh

# Process:
# 1. Stop VaultWarden service
# 2. Create backup
# 3. WAL checkpoint
# 4. Integrity check
# 5. VACUUM operation
# 6. Verify integrity
# 7. Restart VaultWarden

# Automated by cron (monthly)
```

## Security Operations

### Fail2Ban Management

#### Check Ban Status

```bash
# Overall status
docker compose exec fail2ban fail2ban-client status

# Specific jail status
docker compose exec fail2ban fail2ban-client status vaultwarden-auth

# View banned IPs
docker compose exec fail2ban fail2ban-client get vaultwarden-auth banip
```

#### Manual Ban/Unban

```bash
# Ban IP manually (Cloudflare)
docker compose exec fail2ban fail2ban-client set vaultwarden-auth banip 1.2.3.4

# Unban IP
docker compose exec fail2ban fail2ban-client set vaultwarden-auth unbanip 1.2.3.4

# Note: Manual bans go to Cloudflare for web jails
```

#### Cloudflare Integration Check

```bash
# Check Cloudflare API connectivity
docker compose logs fail2ban | grep -i cloudflare

# View recent Cloudflare actions
docker compose logs fail2ban | grep "cloudflare-apiv4"

# Test Cloudflare API manually
curl -X GET "https://api.cloudflare.com/client/v4/zones" \
     -H "Authorization: Bearer YOUR_TOKEN" \
     -H "Content-Type: application/json"
```

### Secrets Management

#### Editing Secrets

```bash
# Interactive secrets editor
./edit-secrets.sh

# Specify editor
./edit-secrets.sh --editor vim

# Features:
# - SOPS key path privacy
# - Automatic backup
# - Validation after editing
# - Secure temp file handling
```

#### Rotating Secrets

```bash
# 1. Edit secrets
./edit-secrets.sh

# 2. Update values (admin_token, etc.)

# 3. Restart services to apply
./startup.sh --force-restart

# 4. Verify health
./health.sh

# Recommended: Annually, or after suspected compromise
```

### Break-Glass Admin Management

#### Check Status

```bash
# Check break-glass admin status
./create-breakglass-admin.sh --status

# Or use Makefile
make breakglass-status
```

#### Generate New Password

```bash
# Generate new emergency password
./create-breakglass-admin.sh --password

# Recommended: After each use, or quarterly
```

#### Remove Emergency Admin

```bash
# Remove break-glass admin (when no longer needed)
./create-breakglass-admin.sh --remove

# Or use Makefile
make breakglass-remove

# Confirm removal
./create-breakglass-admin.sh --status
```

## Automated Operations

### Cron Configuration

#### Installing Cron Jobs

```bash
# Install automated operations
sudo ./cron-setup.sh --install

# Or use Makefile
make cron-install

# Automated tasks:
# - Daily 2 AM: Database backup with rclone sync
# - Daily 6 AM: Health checks with email notification
# - Weekly Sunday 3 AM: Full backup with verification
# - Weekly Sunday 4 AM: Container updates
# - Monthly 1st 5 AM: Comprehensive maintenance
```

#### Viewing Cron Jobs

```bash
# List installed cron jobs
sudo crontab -l | grep vaultwarden

# Or use Makefile
make cron-list

# Example output:
# 0 2 * * * /opt/VaultWarden-OCI/backup.sh --type db --rclone
# 0 6 * * * /opt/VaultWarden-OCI/health.sh --email
# 0 3 * * 0 /opt/VaultWarden-OCI/backup.sh --type full --full-verification
# 0 4 * * 0 /opt/VaultWarden-OCI/update.sh
# 0 5 1 * * /opt/VaultWarden-OCI/maintenance.sh --comprehensive
```

#### Removing Cron Jobs

```bash
# Remove automated operations
sudo ./cron-setup.sh --uninstall

# Or use Makefile
make cron-uninstall
```

### Email Notifications

#### Testing Email

```bash
# Test email configuration
./test-email-simple.sh

# Verbose output for troubleshooting
./test-email-simple.sh --verbose

# Test to specific email
./test-email-simple.sh --to test@example.com
```

#### Email via msmtpd

All email notifications use containerized msmtpd:

Benefits:
- ✅ No host mailutils dependency
- ✅ Consistent SMTP configuration
- ✅ Resource-efficient (32MB)
- ✅ Dedicated container logs
- ✅ Easy troubleshooting

Check msmtpd status:
```bash
# Container logs
docker compose logs msmtpd

# Container status
docker compose ps msmtpd

# Test connectivity
docker compose exec msmtpd nc -z localhost 1025
```

## Resource Monitoring

### Container Resource Usage

```bash
# Real-time resource monitoring
docker stats

# Or specific containers
docker stats vaultwarden_app vaultwarden_caddy

# Single snapshot
docker stats --no-stream

# Check against limits:
# VaultWarden: 2GB memory, 60% CPU
# Caddy: 1GB memory, 30% CPU
# Fail2Ban: 1GB memory, 20% CPU
# msmtpd: 32MB memory, 5% CPU
```

### System Resource Usage

```bash
# Memory usage
free -h

# Disk usage
df -h

# Disk usage by directory
du -sh ${PROJECT_STATE_DIR}/*

# Check against thresholds:
# Memory: < 85% used (health.sh alert)
# Disk: > 10% free (backup.sh requirement)
```

### Performance Optimization

If resource usage is high:

```bash
# 1. Review log sizes
du -sh ${PROJECT_STATE_DIR}/logs/*

# 2. Check for old backups
ls -lh ${PROJECT_STATE_DIR}/backups/

# 3. Run maintenance
./maintenance.sh --comprehensive

# 4. Consider adjusting resource limits
# Edit: docker-compose.yml.example
# Then: sudo ./setup.sh --force --domain ... --email ...
```

## Troubleshooting Operations

### Service Won't Start

```bash
# 1. Check configuration
docker compose config

# 2. Check secrets
ls -la secrets/.docker_secrets/

# 3. View startup errors
docker compose up

# 4. Check individual containers
docker compose logs vaultwarden
docker compose logs caddy
docker compose logs fail2ban
docker compose logs msmtpd

# 5. Force restart
./startup.sh --force-restart
```

### High Resource Usage

```bash
# 1. Identify heavy container
docker stats --no-stream

# 2. Check container logs for issues
docker compose logs <container> --tail=100

# 3. Check for log file growth
du -sh ${PROJECT_STATE_DIR}/logs/*

# 4. Run maintenance
./maintenance.sh

# 5. Consider increasing limits if legitimate usage
```

### Email Not Working

```bash
# 1. Check msmtpd container
docker compose ps msmtpd
docker compose logs msmtpd

# 2. Test email
./test-email-simple.sh --verbose

# 3. Check SMTP settings
grep SMTP .env

# 4. Check secrets
./edit-secrets.sh --test

# 5. Test SMTP connectivity
docker compose exec msmtpd nc -z ${SMTP_HOST} ${SMTP_PORT}

# 6. Check firewall (if SMTP blocked)
sudo ufw status | grep ${SMTP_PORT}
```

### Fail2Ban Not Blocking

```bash
# 1. Check fail2ban status
docker compose exec fail2ban fail2ban-client status

# 2. Check jail status
docker compose exec fail2ban fail2ban-client status vaultwarden-auth

# 3. Test filter regex
docker compose exec fail2ban fail2ban-regex \
  /var/log/vaultwarden/vaultwarden.log \
  /data/fail2ban/filter.d/vaultwarden-auth.conf

# 4. Check Cloudflare API
docker compose logs fail2ban | grep -i cloudflare

# 5. Verify environment variables
docker compose exec fail2ban env | grep CF_

# 6. Test Cloudflare API token manually
curl -X GET "https://api.cloudflare.com/client/v4/zones" \
     -H "Authorization: Bearer YOUR_TOKEN"
```

### Backup Issues

```bash
# 1. Check disk space
df -h

# 2. Check backup directory permissions
ls -la ${PROJECT_STATE_DIR}/backups/

# 3. Test Age encryption
age --version

# 4. Verify Age key
ls -la secrets/keys/age-key.txt

# 5. Test backup manually
./backup.sh --type db --verbose

# 6. Check backup logs
grep backup /var/log/syslog
```

## Template Maintenance

### Updating Templates

```bash
# 1. Edit template files
nano docker-compose.yml.example
nano .env.example

# 2. Validate template syntax
docker compose -f docker-compose.yml.example config

# 3. Test in development first
# Create test directory, apply templates, test

# 4. Create backup before applying
./backup.sh --type emergency

# 5. Apply templates to production
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com

# 6. Restart services
./startup.sh --force-restart

# 7. Verify health
./health.sh
```

### Template Best Practices

- ✅ Always edit `.example` files, never generated files
- ✅ Validate templates before applying
- ✅ Test changes in non-production first
- ✅ Create backup before major changes
- ✅ Document customizations in template comments
- ✅ Keep templates in version control
- ✅ Review diffs carefully before committing

## Operational Best Practices

### Daily Checklist
- ✅ Check automated backup success (email notification)
- ✅ Review health check results (email notification)
- ✅ Glance at fail2ban logs for unusual activity
- ✅ Monitor resource usage trends

### Weekly Checklist
- ✅ Review full backup with verification results
- ✅ Check container update results
- ✅ Review authentication failure patterns
- ✅ Verify email notifications working
- ✅ Check disk space usage

### Monthly Checklist
- ✅ Review comprehensive maintenance results
- ✅ Test backup restoration
- ✅ Review security logs thoroughly
- ✅ Check for available updates
- ✅ Verify break-glass admin access
- ✅ Review and archive old logs if needed

### Quarterly Checklist
- ✅ Test emergency procedures (break-glass admin)
- ✅ Update Cloudflare IP ranges
- ✅ Review and update documentation
- ✅ Audit user accounts and permissions
- ✅ Test disaster recovery procedures
- ✅ Review resource limits and adjust if needed

### Annual Checklist
- ✅ Rotate all secrets (tokens, passwords)
- ✅ Review and update security policies
- ✅ Audit complete system configuration
- ✅ Update to latest stable versions
- ✅ Review backup retention policies
- ✅ Test complete system rebuild from backup

## Makefile Quick Reference

```bash
# Service Management
make start              # Start all services
make stop               # Stop all services
make restart            # Restart with enhanced script
make status             # Show service status

# Monitoring
make health             # Run health checks
make health-email       # Health check with email
make logs               # View all logs
make logs SERVICE=name  # View specific service logs

# Backups
make backup             # Database backup
make backup-full        # Full system backup
make backup-emergency   # Emergency recovery kit
make list-backups       # List available backups
make restore            # Interactive restore

# Updates & Maintenance
make update             # Update containers
make update-system      # Update system and containers
make maintenance        # Basic maintenance
make maintenance-full   # Comprehensive maintenance

# Security
make edit-secrets       # Edit encrypted secrets
make breakglass-create  # Create emergency admin
make breakglass-status  # Check emergency admin status
make breakglass-remove  # Remove emergency admin

# Automation
make cron-install       # Install cron jobs
make cron-list          # List cron jobs
make cron-uninstall     # Remove cron jobs

# Configuration
make config             # Show current configuration
make test-config        # Validate configuration
```

---

This operations guide reflects the current state of VaultWarden-OCI with Cloudflare-only blocking for web traffic, comprehensive resource management, automated operations via cron, containerized email via msmtpd, and robust operational procedures optimized for small teams requiring reliable, maintainable password management infrastructure.
