# Operations Guide - VaultWarden-OCI

Day-to-day operational procedures for managing your VaultWarden-OCI deployment with enhanced automation, monitoring, and maintenance capabilities.

## Daily Operations

### Service Management

**Starting Services**:
```bash
# Full initialization startup (recommended)
./startup.sh

# Or using Makefile
make start

# Force restart all services
./startup.sh --force-restart
make restart
```

**Stopping Services**:
```bash
# Graceful shutdown
./startup.sh --down

# Or using Makefile
make stop
make down
```

**Checking Service Status**:
```bash
# View service status
docker compose ps

# Or using Makefile
make status

# Detailed container information
docker stats --no-stream
```

### Monitoring and Health Checks

**Basic Health Check**:
```bash
# Quick health check
./health.sh

# Using Makefile
make health
```

**Comprehensive Diagnostics**:
```bash
# Full diagnostics with all checks
./health.sh --comprehensive

# With email notification
./health.sh --comprehensive --email

# Using Makefile
make health
make health-email
```

**Viewing Logs**:
```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f vaultwarden

# Using Makefile
make logs
make logs SERVICE=vaultwarden
make logs SERVICE=caddy
make logs SERVICE=fail2ban
make logs SERVICE=msmtpd

# With timestamps and tail
make logs-tail
make logs-tail SERVICE=vaultwarden
```

### Resource Monitoring

**Container Resource Usage**:
```bash
# Real-time resource monitoring
docker stats

# One-time snapshot
docker stats --no-stream

# Format output
docker stats --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}"
```

**Disk Space Monitoring**:
```bash
# Check backup directory space
df -h /path/to/backups

# Check state directory space
df -h /var/lib/vaultwarden

# Check total backup usage
du -sh /path/to/backups/*

# Using Makefile
make info  # Shows disk usage summary
```

## Backup Operations

### Creating Backups

**Database Backup** (Daily):
```bash
# Quick database backup
./backup.sh --type db

# With email notification
./backup.sh --type db --email

# With offsite sync
./backup.sh --type db --rclone

# Using Makefile
make backup
```

**Full System Backup** (Weekly):
```bash
# Full backup
./backup.sh --type full

# With full verification (recommended weekly)
./backup.sh --type full --full-verification

# With offsite sync and email
./backup.sh --type full --rclone --email

# Using Makefile
make backup-full
```

**Emergency Kit** (As Needed):
```bash
# Create emergency recovery kit
./backup.sh --type emergency

# Using Makefile
make backup-emergency
```

### Managing Backups

**List Available Backups**:
```bash
# List all backups with metadata
./backup.sh --list

# Using Makefile
make list-backups
```

**Restore Backup**:
```bash
# Interactive restore
./restore.sh

# Restore specific file
./restore.sh --file /path/to/backup.age

# Using Makefile
make restore
```

## Update Operations

### Container Updates

**Safe Container Update**:
```bash
# Update containers with pre-update backup
./update.sh

# Using Makefile
make update
```

**System and Container Updates**:
```bash
# Update both system packages and containers
./update.sh --system --email

# Using Makefile
make update-system
```

### Updating Configuration

**Template-Based Updates**:
```bash
# 1. Edit templates
nano docker-compose.yml.example
nano .env.example

# 2. Validate templates
docker compose -f docker-compose.yml.example config

# 3. Regenerate from templates
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com

# 4. Apply changes
./startup.sh --force-restart
make restart
```

## Maintenance Operations

### Routine Maintenance

**Basic Maintenance**:
```bash
# Run standard maintenance tasks
./maintenance.sh

# Using Makefile
make maintenance
```

**Comprehensive Maintenance**:
```bash
# Full maintenance with all tasks
./maintenance.sh --comprehensive --email

# Using Makefile
make maintenance-full
```

### Database Maintenance

**SQLite Optimization**:
```bash
# Safe offline database maintenance
./db-maint.sh

# Using Makefile
make db-maint
```

**Database Operations**:
- Stops VaultWarden service
- WAL checkpoint before operations
- Integrity check before VACUUM
- Safe offline VACUUM operation
- Integrity check after operations
- Restarts VaultWarden service

### Docker Cleanup

**Clean Docker Resources**:
```bash
# Basic cleanup
./maintenance.sh --no-logs --no-backups --no-database

# Using Makefile
make clean

# Prune unused resources
make prune
```

## Security Operations

### Fail2Ban Management

**Check Fail2Ban Status**:
```bash
# View fail2ban status
docker compose exec fail2ban fail2ban-client status

# Check specific jail
docker compose exec fail2ban fail2ban-client status vaultwarden-auth

# View banned IPs
docker compose exec fail2ban fail2ban-client status vaultwarden-auth | grep "Banned IP"
```

**Monitor Dual Blocking**:
```bash
# Check Cloudflare + UFW dual action effectiveness
docker compose logs fail2ban | grep -E "CF.*ok|UFW.*ok"

# Count successful blocks
docker compose logs fail2ban | grep -E "CF.*ok.*UFW.*ok" | wc -l
```

### Firewall Management

**Update Cloudflare Firewall Rules**:
```bash
# Safe firewall update with race condition fixes
./maintenance.sh --update-firewall

# Preview firewall update
./maintenance.sh --update-firewall --dry-run
```

**Check UFW Status**:
```bash
# View current UFW rules
sudo ufw status numbered

# Check Cloudflare IP rules
sudo ufw status | grep CF
```

### Secrets Management

**Edit Secrets**:
```bash
# Edit encrypted secrets with enhanced privacy
./edit-secrets.sh

# Using Makefile
make edit-secrets
```

**Test Secrets**:
```bash
# Validate secrets decryption
./edit-secrets.sh --test

# Using Makefile
make test-secrets
```

### Emergency Access

**Break-Glass Admin Management**:
```bash
# Check emergency admin status
./create-breakglass-admin.sh --status

# Create emergency admin
./create-breakglass-admin.sh --create

# Using Makefile
make breakglass-create
make breakglass-status
make breakglass-remove
```

## DNS Operations

### Manual DNS Updates

**Update DNS Record**:
```bash
# Update Cloudflare DNS to current IP
./update-dns.sh

# Using Makefile
make update-dns
```

**Verify DNS**:
```bash
# Check current DNS resolution
dig +short vault.example.com

# Check from external DNS
dig +short @8.8.8.8 vault.example.com
```

## Email Operations

### Email Configuration Testing

**Test Email Functionality**:
```bash
# Test msmtpd email delivery
./test-email-simple.sh

# Verbose output for troubleshooting
./test-email-simple.sh --verbose

# Test to specific address
./test-email-simple.sh --to test@example.com
```

**Check msmtpd Status**:
```bash
# View msmtpd logs
docker compose logs msmtpd

# Using Makefile
make logs SERVICE=msmtpd

# Check msmtpd container
docker compose ps msmtpd

# Verify SMTP connectivity
docker compose exec msmtpd nc -z localhost 1025
```

## Automation

### Installing Automation

**Install Cron Jobs**:
```bash
# Install automated tasks
sudo ./cron-setup.sh --install

# Using Makefile
make cron-install
```

**Default Automated Tasks**:
- Daily 2 AM: Database backup with rclone sync
- Daily 6 AM: Health check
- Weekly Sunday 3 AM: Full backup with verification
- Weekly Sunday 4 AM: Container updates
- Monthly 1st 5 AM: Comprehensive maintenance

**Manage Cron Jobs**:
```bash
# List current cron jobs
sudo ./cron-setup.sh --list
make cron-list

# Remove cron jobs
sudo ./cron-setup.sh --remove
make cron-remove
```

## Configuration Validation

### Validate Configuration

**Check Docker Compose Configuration**:
```bash
# Validate current configuration
docker compose config

# Using Makefile
make test-config

# Validate template
docker compose -f docker-compose.yml.example config
```

**Run All Tests**:
```bash
# Run comprehensive tests
make test

# Format and validate all configs
make fmt
```

## Advanced Operations

### Container Shell Access

**Access Container Shell**:
```bash
# Access VaultWarden container
docker compose exec vaultwarden sh

# Access Caddy container
docker compose exec caddy sh

# Using Makefile
make shell                    # Default: vaultwarden
make shell SERVICE=caddy
make shell SERVICE=fail2ban
```

### Configuration Summary

**View Configuration**:
```bash
# Show current configuration summary
make config

# Show system information
make info

# Show version information
make version
```

### Watching Services

**Monitor Services in Real-Time**:
```bash
# Watch service status (requires watch command)
make watch

# Monitor logs in real-time
make monitor
```

## Operational Best Practices

### Daily Tasks
- ✅ Review health check results (automated)
- ✅ Monitor backup completion emails
- ✅ Check disk space usage
- ✅ Review fail2ban logs for unusual activity

### Weekly Tasks
- ✅ Review full backup completion
- ✅ Verify offsite backup sync
- ✅ Check container resource usage
- ✅ Review security logs
- ✅ Test email notifications

### Monthly Tasks
- ✅ Run comprehensive maintenance
- ✅ Test backup restoration procedure
- ✅ Review and rotate logs
- ✅ Update containers and system packages
- ✅ Verify emergency access still works

### Quarterly Tasks
- ✅ Complete disaster recovery drill
- ✅ Review and update documentation
- ✅ Audit security configuration
- ✅ Test all operational procedures
- ✅ Review backup retention policies

## Troubleshooting Common Operations

### Services Won't Start
```bash
# Check service logs
docker compose logs

# Validate configuration
docker compose config

# Check for port conflicts
sudo netstat -tulpn | grep -E '80|443'

# Force restart
./startup.sh --force-restart
```

### High Resource Usage
```bash
# Check resource consumption
docker stats

# Review container limits
docker inspect vaultwarden_app | grep -A 10 Memory

# Check for runaway processes
docker compose top
```

### Email Not Working
```bash
# Test msmtpd functionality
./test-email-simple.sh --verbose

# Check msmtpd logs
docker compose logs msmtpd

# Verify SMTP settings
docker compose exec msmtpd cat /etc/msmtprc

# Test from VaultWarden admin panel
# Navigate to /admin → SMTP Settings → Send Test Email
```

### Backup Failures
```bash
# Check disk space
df -h

# Verify Age key exists
ls -l secrets/keys/age-key.txt

# Test backup with dry-run
./backup.sh --type db --dry-run

# Check backup logs
docker compose logs | grep backup
```

### DNS Update Issues
```bash
# Check current IP
curl -s ifconfig.me

# Verify DNS record
dig +short vault.example.com

# Test Cloudflare API token
curl -X GET "https://api.cloudflare.com/client/v4/zones" \\
     -H "Authorization: Bearer YOUR_TOKEN" \\
     -H "Content-Type: application/json"

# Manual DNS update
./update-dns.sh
```

## Performance Optimization

### Resource Tuning

**Adjust Container Limits**:
```bash
# Edit template for resource changes
nano docker-compose.yml.example

# Adjust memory limits for your system
# Example: Increase VaultWarden to 4GB on larger systems
# deploy:
#   resources:
#     limits:
#       memory: 4G

# Regenerate and apply
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com
./startup.sh --force-restart
```

### Database Optimization

**Regular Maintenance**:
```bash
# Monthly database optimization
./db-maint.sh

# Check database size
du -h /var/lib/vaultwarden/data/bwdata/db.sqlite3

# Monitor database growth
watch -n 60 'du -h /var/lib/vaultwarden/data/bwdata/db.sqlite3'
```

### Log Management

**Control Log Size**:
```bash
# Caddy logs are automatically rotated via configuration
# Check current log size
du -sh /var/lib/vaultwarden/logs/

# Manual log cleanup (if needed)
./maintenance.sh --comprehensive
```

## Operational Checklist

### Pre-Deployment Checklist
- ✅ Templates validated with `docker compose config`
- ✅ Secrets configured with proper API tokens
- ✅ Environment variables set in .env
- ✅ DNS pointing to server with Cloudflare proxy
- ✅ Firewall configured with Cloudflare IPs
- ✅ Email tested with test-email-simple.sh
- ✅ Break-glass admin created and tested
- ✅ Initial backup created and verified

### Post-Deployment Checklist
- ✅ Services started and healthy
- ✅ HTTPS accessible via domain
- ✅ Admin panel accessible with credentials
- ✅ Email notifications working
- ✅ Backups scheduled via cron
- ✅ Offsite backup sync configured
- ✅ Fail2ban operational and blocking
- ✅ Emergency procedures documented

### Maintenance Checklist
- ✅ Daily backups completing successfully
- ✅ Weekly full backups with verification
- ✅ Monthly comprehensive maintenance
- ✅ Container updates applied regularly
- ✅ Security patches installed
- ✅ Logs reviewed for issues
- ✅ Resource usage within limits
- ✅ Break-glass admin status verified

---

This operations guide provides comprehensive procedures for managing your VaultWarden-OCI deployment efficiently with enhanced automation, monitoring capabilities, and operational best practices for reliable service delivery.
"""
