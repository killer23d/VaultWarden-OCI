[# Operations Guide - VaultWarden-OCI-Simplified

This guide provides practical operational procedures for maintaining VaultWarden-OCI-Simplified in a production environment, optimized for single administrator, small team deployments.

## Daily Operations (5 minutes)

### Automated Health Check Review
```bash
# Check automated health monitoring results
tail -20 logs/health.log

# Quick manual health check if needed
./health.sh --quiet

# Expected output: No warnings or errors
# If issues found, run comprehensive check:
./health.sh --comprehensive
```

### Service Status Verification
```bash
# Quick service status check
docker compose ps

# All services should show "Up" and "healthy" status
# If any service is down:
./startup.sh --force-restart
```

### Backup Status Check
```bash
# Verify recent backups exist
ls -la backups/db/ | tail -3

# Should show daily database backups
# If missing recent backups, check cron:
sudo crontab -l | grep backup
```

## Weekly Operations (15 minutes)

### System Status Review
```bash
# 1. Check automated operations
sudo crontab -l | grep vaultwarden

# 2. Review service logs for issues
docker compose logs --since 7d | grep -i error

# 3. Check version status
echo "=== Configured Versions ==="
grep "_VERSION=" .env

echo "=== Running Versions ==="
docker compose ps --format "table {{.Service}}	{{.Image}}"

# 4. Check for available updates
./update.sh --type containers --check-only
```

### Security Log Review
```bash
# Check fail2ban activity
docker compose logs fail2ban --since 7d | grep -E "Ban|Unban"

# Review admin panel access attempts
docker compose logs caddy --since 7d | grep "/admin"

# Check firewall status
sudo ufw status
```

### Resource Usage Check
```bash
# System resources
df -h                    # Disk usage
free -h                  # Memory usage
docker stats --no-stream # Container resource usage

# Look for:
# - Disk usage < 80%
# - Memory usage < 85%
# - No excessive CPU usage
```

## Monthly Operations (30 minutes)

### System Maintenance
```bash
# 1. Run comprehensive health check
./health.sh --comprehensive --email-alert

# 2. System maintenance (automated via cron, but verify)
sudo ./maintenance.sh --type standard --dry-run
# If output looks reasonable:
sudo ./maintenance.sh --type standard

# 3. Database maintenance (quarterly, but check status)
sudo ./db-maint.sh --analyze-only
```

### Version Management Review
```bash
# 1. Check for security updates
./update.sh --type containers --check-only

# 2. Review current version pins
grep "_VERSION=" .env

# 3. Consider updating non-critical services if needed
# Example: Update fail2ban to latest
./update.sh --unpin fail2ban
./update.sh --type containers --service fail2ban
./update.sh --pin fail2ban $(docker inspect vaultwarden_fail2ban --format='{{index .Config.Image}}' | cut -d: -f2)
```

### Backup Verification
```bash
# 1. Create manual emergency backup
./backup.sh --type emergency --rclone --email

# 2. Verify backup integrity
ls -la backups/emergency/ | tail -3

# 3. Test age key accessibility
./edit-secrets.sh --test

# 4. Verify rclone sync (if configured)
rclone ls YourRemote:vaultwarden_backups/ --max-age 30d | wc -l
```

### Security Review
```bash
# 1. Check break-glass admin status
sudo ./create-breakglass-admin.sh status

# 2. Review secrets status
./edit-secrets.sh --show | grep -E "CHANGE_ME|password|token"
# Should not show any CHANGE_ME values

# 3. Update Cloudflare IPs if needed
sudo ./update-cloudflare-ips.sh --dry-run

# 4. Check for system updates
sudo ./update.sh --type system --check-only
```

## Version Management Operations

### Production Version Update Workflow
```bash
# 1. Create backup before any version changes
./backup.sh --type full --rclone

# 2. Check what updates are available
./update.sh --type containers --check-only

# 3. Update to specific tested version (example: VaultWarden)
./update.sh --pin vaultwarden 1.31.0

# 4. Apply the update
./update.sh --type containers --backup

# 5. Verify the update
./health.sh --comprehensive
docker compose ps --format "table {{.Service}}	{{.Image}}"

# 6. Monitor for 24 hours, rollback if issues:
# ./update.sh --pin vaultwarden 1.30.5
# ./startup.sh --force-restart
```

### Emergency Security Patch
```bash
# 1. Quick security patch for critical vulnerability
./update.sh --unpin vaultwarden    # Allow latest to get security patch
./update.sh --type containers      # Apply immediately
./health.sh --comprehensive        # Verify system health

# 2. Monitor and re-pin once stable
# Wait 24-48 hours, then:
current_version=$(docker inspect vaultwarden_app --format='{{index .Config.Image}}' | cut -d: -f2)
./update.sh --pin vaultwarden $current_version
```

### Development/Testing Version Management
```bash
# Switch to latest versions for testing
./update.sh --unpin vaultwarden
./update.sh --unpin caddy
./startup.sh --force-restart

# Test new features, then pin to stable if satisfied
./update.sh --pin vaultwarden 1.31.0
./update.sh --pin caddy 2.8.5
./startup.sh --force-restart
```

## Backup and Recovery Operations

### Standard Backup Operations
```bash
# Daily (automated via cron): Database backups
# ./backup.sh --type db --rclone

# Weekly (automated via cron): Full system backups  
# ./backup.sh --type full --rclone

# Manual emergency backup before major changes
./backup.sh --type emergency --rclone --email
```

### Recovery Operations

#### Database Recovery
```bash
# 1. Stop services
./startup.sh --down

# 2. Restore from recent database backup
./restore.sh backups/db/vw-db-backup-YYYYMMDD-HHMMSS.sqlite3.gz.age

# 3. Restart and verify
./startup.sh
./health.sh --comprehensive
```

#### Complete System Recovery
```bash
# 1. Stop all services
./startup.sh --down

# 2. Restore from full system backup
./restore.sh backups/full/vw-full-backup-YYYYMMDD-HHMMSS.tar.gz.age

# 3. Restart and verify
./startup.sh
./health.sh --comprehensive
```

#### Emergency Recovery from Scratch
```bash
# 1. Fresh installation (new server)
git clone https://github.com/killer23d/VaultWarden-OCI-Simplified.git
cd VaultWarden-OCI-Simplified
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto

# 2. Restore from emergency backup
./restore.sh /path/to/emergency-kit-YYYYMMDD-HHMMSS.tar.gz.age

# 3. Verify and update DNS if needed
./health.sh --comprehensive
```

## Emergency Procedures

### SSH Access Lost
```bash
# Use break-glass admin via OCI serial console:
# 1. Access OCI Console → Compute → Instance → Console Connection
# 2. Login with break-glass admin credentials
# 3. Diagnose and fix SSH issues:

sudo systemctl status sshd
sudo systemctl restart sshd
sudo ufw allow 22/tcp
sudo ufw reload

# 4. Test SSH recovery
```

### Service Failure
```bash
# 1. Quick service restart
./startup.sh --force-restart

# 2. If services still failing, check logs
docker compose logs

# 3. If persistent issues, restore from backup
./startup.sh --down
./restore.sh backups/full/latest-good-backup.age
./startup.sh
```

### Data Corruption
```bash
# 1. Stop services immediately
./startup.sh --down

# 2. Check database integrity
sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 "PRAGMA integrity_check;"

# 3. If corrupted, restore from backup
./restore.sh backups/db/latest-clean-backup.age

# 4. Restart and verify
./startup.sh
./health.sh --comprehensive
```

### Security Incident
```bash
# 1. Immediate isolation (if severe)
./startup.sh --down
sudo ufw deny in

# 2. Preserve evidence
cp -r /var/log/ /tmp/incident-$(date +%Y%m%d-%H%M%S)/
./backup.sh --type emergency

# 3. Investigate and recover
# Review logs, restore from clean backup, update versions
# Re-enable services only after verification
```

## Monitoring and Alerting

### Health Monitoring Setup
```bash
# Comprehensive health check (run weekly)
./health.sh --comprehensive --email-alert

# JSON output for external monitoring systems
./health.sh --comprehensive --json > /tmp/vaultwarden-status.json
```

### Log Analysis
```bash
# Check for errors in the last 24 hours
docker compose logs --since 24h | grep -i error

# Monitor specific service logs
docker compose logs vaultwarden --tail 100
docker compose logs fail2ban --tail 50

# Check system logs for issues
sudo journalctl -u docker --since "24 hours ago" | tail -20
```

### Performance Monitoring
```bash
# Container resource usage
docker stats --no-stream

# System resource usage
htop  # or top
df -h
free -h

# Network connectivity tests
curl -f http://localhost:80/alive
nslookup vault.yourdomain.com
```

## Maintenance Schedules

### Automated Tasks (via cron-setup.sh)
- **Every 6 hours**: Health monitoring with auto-heal
- **Daily 2:00 AM**: Database backups with rclone sync
- **Weekly Sunday 1:00 AM**: Full system backups
- **Weekly Sunday 3:00 AM**: Container updates
- **Monthly First Sunday 3:30 AM**: System updates
- **Monthly First Sunday 4:00 AM**: System maintenance
- **Weekly Sunday 5:00 AM**: Cloudflare IP updates

### Manual Tasks Schedule

#### Daily (5 minutes)
- Review automated health check results
- Verify service status
- Check backup creation

#### Weekly (15 minutes)
- Review logs for errors or security issues
- Check version status and available updates
- Verify resource usage levels
- Review fail2ban activity

#### Monthly (30 minutes)
- Comprehensive health check
- System maintenance verification
- Backup integrity verification
- Security review and updates
- Break-glass admin status check

#### Quarterly (1 hour)
- Full security audit
- Test emergency procedures
- Review and update documentation
- Consider version updates for new features
- Database optimization review

## Configuration Management

### Environment Configuration (.env)
```bash
# View current configuration
cat .env | grep -v '^#' | grep -v '^$'

# Check for any CHANGE_ME values that need updating
grep "CHANGE_ME" .env
# Should return no results in production

# Version pins for production stability
grep "_VERSION=" .env
```

### Secrets Management
```bash
# Regular secrets review (quarterly)
./edit-secrets.sh --test

# Update secrets when needed
./edit-secrets.sh

# After secrets changes, restart services
./startup.sh --force-restart
```

### Firewall and Network
```bash
# Update Cloudflare IP ranges (automated weekly, manual if needed)
sudo ./update-cloudflare-ips.sh

# Check firewall status
sudo ufw status numbered

# Verify DNS resolution
nslookup vault.yourdomain.com
```

## Performance Optimization

### Database Performance
```bash
# Monthly database analysis
sudo ./db-maint.sh --analyze-only

# Quarterly database optimization (automated)
sudo ./db-maint.sh --backup

# Check database size and fragmentation
sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 "PRAGMA page_count; PRAGMA freelist_count;"
```

### System Performance
```bash
# Clean up disk space if needed
sudo ./maintenance.sh --type standard

# Deep cleanup if disk usage > 80%
sudo ./maintenance.sh --type deep

# Monitor container performance
docker stats vaultwarden_app --no-stream
```

## Best Practices for Single Admin Operations

### Documentation
- Keep offline copies of troubleshooting procedures
- Document any custom configurations or changes
- Maintain current backup of encryption keys
- Document break-glass admin credentials securely

### Testing
- Test backup restoration procedures quarterly
- Verify break-glass admin access annually (status check)
- Test update and rollback procedures in development
- Verify monitoring and alerting systems monthly

### Security
- Review access logs monthly
- Keep system and container versions updated
- Monitor security advisories for used components
- Maintain strong, unique passwords for all accounts

### Automation
- Rely on automated tasks for routine operations
- Monitor automated task completion via logs
- Manually verify critical automated operations monthly
- Adjust automation based on operational experience

---

This operations guide is designed for the reality of single-administrator, small team environments where simplicity, reliability, and clear procedures are essential for effective system management.
](https://github.com/killer23d/VaultWarden-OCI-Simplified)
