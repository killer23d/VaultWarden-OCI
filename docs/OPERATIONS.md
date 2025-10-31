# Operations Guide - VaultWarden-OCI

This guide provides practical operational procedures for maintaining VaultWarden-OCI in a production environment, optimized for single administrator, small team deployments with template-based architecture and enhanced automation.

## Set-and-Forget Operations Philosophy

VaultWarden-OCI is designed for minimal operational overhead with maximum reliability through:

- **Template-Based Configuration**: Single source of truth with `.example` files
- **Automated Operations**: Comprehensive cron-based automation via `cron-setup.sh`
- **Enhanced Monitoring**: Proactive health checks with auto-healing capabilities
- **Atomic Operations**: Reliable backup and restore procedures
- **Emergency Access**: Break-glass admin for critical recovery scenarios

## Daily Operations (5 minutes)

### Automated Health Check Review
```bash
# Check automated health monitoring results (configured via cron-setup.sh)
tail -20 /var/log/vaultwarden/health.log

# Quick manual health check if needed
./health.sh --quiet

# Expected output: No warnings or errors
# If issues found, run comprehensive check:
./health.sh --comprehensive --auto-heal
```

### Service Status Verification
```bash
# Quick service status check
docker compose ps

# All services should show "Up" and "healthy" status
# If any service is down:
./startup.sh --force-restart
```

### Enhanced Backup Status Check
```bash
# Verify recent backups exist with enhanced listing
./backup.sh --list | head -5

# Should show recent backups with timestamps and sizes
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

# 3. Check version status and template configuration
docker compose config  # Validate template-generated configuration
docker compose ps --format "table {{.Service}}	{{.Image}}"

# 4. Check for available updates
./update.sh --type containers --check-only
```

### Enhanced Security Log Review
```bash
# Check enhanced fail2ban activity with rate limiting
docker compose logs fail2ban --since 7d | grep -E "Ban|Unban|Rate"

# Review admin panel access attempts
docker compose logs caddy --since 7d | grep "/admin"

# Check firewall status and Cloudflare IP updates
sudo ufw status
sudo ./update-cloudflare-ips.sh --dry-run
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

### Enhanced System Maintenance
```bash
# 1. Run comprehensive health check with template validation
./health.sh --comprehensive --email-alert

# 2. System maintenance (automated via cron, but verify)
sudo ./maintenance.sh --type standard --dry-run
# If output looks reasonable:
sudo ./maintenance.sh --type standard --force

# 3. Database maintenance (quarterly, but check status)
sudo ./db-maint.sh --analyze-only
```

### Template-Based Configuration Review
```bash
# 1. Validate current template-generated configuration
docker compose config

# 2. Check for security updates
./update.sh --type containers --check-only

# 3. Review template files for any needed updates
ls -la *.example

# 4. Consider updating services if needed (with template regeneration)
# Example: Update to new stable version
# Edit .env to update version, then:
# ./startup.sh --force-restart
```

### Enhanced Backup Verification
```bash
# 1. Create manual emergency backup with atomic operations
./backup.sh --type emergency --rclone --email

# 2. Verify backup integrity with enhanced listing
./backup.sh --list

# 3. Test age key accessibility
./edit-secrets.sh --test

# 4. Verify rclone sync (if configured)
rclone ls YourRemote:vaultwarden_backups/ --max-age 30d | wc -l
```

### Security Review
```bash
# 1. Check break-glass admin status
./create-breakglass-admin.sh status

# 2. Review secrets status
./edit-secrets.sh --show | grep -E "CHANGE_ME|password|token"
# Should not show any CHANGE_ME values

# 3. Update Cloudflare IPs with enhanced error handling
sudo ./update-cloudflare-ips.sh --dry-run

# 4. Check for system updates
sudo ./update.sh --type system --check-only
```

## Template-Based Configuration Management

### Template Maintenance Workflow
```bash
# 1. Edit template files (source of truth)
nano docker-compose.yml.example  # For Docker configuration changes
nano .env.example               # For environment variable changes

# 2. Validate template changes
docker compose config  # Should show no errors

# 3. Apply template changes
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# 4. Restart services to apply changes
./startup.sh --force-restart

# 5. Verify changes
./health.sh --comprehensive
```

### Configuration Drift Prevention
```bash
# Regular template validation (weekly)
docker compose config

# Check for manual modifications to generated files
diff docker-compose.yml docker-compose.yml.example
diff .env .env.example

# If drift detected, regenerate from templates:
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
```

## Enhanced Backup and Recovery Operations

### Automated Backup Strategy
```bash
# Daily (automated via cron-setup.sh): Database backups with atomic operations
# Weekly (automated via cron-setup.sh): Full system backups with template preservation
# Manual: Emergency kits with complete recovery capability

# All backups include:
# - Atomic operations to prevent corruption
# - WAL checkpoints for live database snapshots
# - Template files for complete system reconstruction
# - Enhanced verification and integrity checks
```

### Enhanced Recovery Operations

#### Database Recovery with Atomic Operations
```bash
# 1. Stop services
./startup.sh --down

# 2. Interactive restore with enhanced backup selection
./restore.sh --interactive
# Select database backup from enhanced menu

# 3. Restart and verify
./startup.sh
./health.sh --comprehensive
```

#### Complete System Recovery with Template Integration
```bash
# 1. Stop all services
./startup.sh --down

# 2. Interactive full system restore with template handling
./restore.sh --interactive
# Select full system backup or emergency kit

# 3. Restart and verify
./startup.sh
./health.sh --comprehensive
```

#### Emergency Recovery from Bare Metal
```bash
# 1. Fresh installation (new server)
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

# 2. Restore from emergency backup (includes templates)
./restore.sh /path/to/emergency-kit-YYYYMMDD-HHMMSS.tar.gz.age

# 3. Verify template-based configuration and update DNS
docker compose config
./health.sh --comprehensive
```

## Emergency Procedures

### Enhanced SSH Access Recovery
```bash
# Use break-glass admin via OCI serial console:
# 1. Access OCI Console → Compute → Instance → Console Connection
# 2. Create console connection (if not exists)
# 3. Login with break-glass admin credentials
# 4. Diagnose and fix SSH issues:

sudo systemctl status sshd
sudo systemctl restart sshd
sudo ufw allow 22/tcp
sudo ufw reload

# 5. Test SSH recovery
# 6. Security cleanup:
#    - Delete Console Connection in OCI Console
#    - Rotate break-glass password: ./create-breakglass-admin.sh password
```

### Service Failure with Template Validation
```bash
# 1. Quick service restart
./startup.sh --force-restart

# 2. If services still failing, check template configuration
docker compose config
docker compose logs

# 3. If persistent issues, restore from backup with template integration
./startup.sh --down
./restore.sh --interactive  # Select appropriate backup
./startup.sh
```

### Template Configuration Corruption
```bash
# 1. Stop services immediately
./startup.sh --down

# 2. Regenerate configuration from templates
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# 3. Restart and verify
./startup.sh
./health.sh --comprehensive
```

### Security Incident with Enhanced Response
```bash
# 1. Immediate isolation (if severe)
./startup.sh --down
sudo ufw deny in

# 2. Preserve evidence and create emergency backup
cp -r /var/log/ /tmp/incident-$(date +%Y%m%d-%H%M%S)/
./backup.sh --type emergency --rclone

# 3. Review enhanced fail2ban logs
docker compose logs fail2ban | grep -E "Rate|Ban|Error"

# 4. Investigate and recover with template-based approach
# Review logs, restore from clean backup, regenerate templates
# Re-enable services only after verification
```

## Enhanced Monitoring and Alerting

### Comprehensive Health Monitoring
```bash
# Automated health check with auto-healing (configured via cron-setup.sh)
./health.sh --comprehensive --auto-heal --email-alert

# JSON output for external monitoring systems
./health.sh --comprehensive --json > /tmp/vaultwarden-status.json
```

### Enhanced Log Analysis
```bash
# Check for errors in the last 24 hours
docker compose logs --since 24h | grep -i error

# Monitor enhanced fail2ban with rate limiting
docker compose logs fail2ban --tail 100 | grep -E "Rate|Ban"

# Check system logs for issues
sudo journalctl -u docker --since "24 hours ago" | tail -20

# Review template configuration changes
git log --oneline -- "*.example"
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

# Template configuration validation
docker compose config
```

## Maintenance Schedules

### Enhanced Automated Tasks (via cron-setup.sh)
- **Every 6 hours**: Health monitoring with auto-heal and template validation
- **Daily 2:00 AM**: Database backups with atomic operations and rclone sync
- **Weekly Sunday 1:00 AM**: Full system backups with template preservation
- **Weekly Sunday 3:00 AM**: Container updates with backup creation
- **Monthly First Sunday 3:30 AM**: System updates with template validation
- **Monthly First Sunday 4:00 AM**: System maintenance with cleanup
- **Weekly Sunday 5:00 AM**: Cloudflare IP updates with enhanced error handling

### Manual Tasks Schedule

#### Daily (5 minutes)
- Review automated health check results
- Verify service status
- Check enhanced backup creation with listing
- Verify break-glass admin status

#### Weekly (15 minutes)
- Review logs for errors or security issues with enhanced fail2ban analysis
- Check version status and template configuration validation
- Verify resource usage levels
- Review enhanced fail2ban activity with rate limiting

#### Monthly (30 minutes)
- Comprehensive health check with template validation
- System maintenance verification with enhanced features
- Backup integrity verification with atomic operations
- Security review with enhanced monitoring
- Break-glass admin status check and template configuration review

#### Quarterly (1 hour)
- Full security audit with template-based configuration review
- Test emergency procedures including break-glass admin access
- Review and update template-based documentation
- Consider version updates with template regeneration
- Database optimization review with enhanced maintenance

## Configuration Management Best Practices

### Template-Based Environment Configuration (.env)
```bash
# View current configuration (generated from template)
cat .env | grep -v '^#' | grep -v '^$'

# Check for any CHANGE_ME values that need updating
grep "CHANGE_ME" .env
# Should return no results in production

# Validate template-generated configuration
docker compose config
```

### Enhanced Secrets Management
```bash
# Regular secrets review (quarterly)
./edit-secrets.sh --test

# Update secrets when needed
./edit-secrets.sh

# After secrets changes, restart services (REQUIRED)
./startup.sh --force-restart
```

### Network and Firewall Management
```bash
# Update Cloudflare IP ranges with enhanced error handling (automated weekly)
sudo ./update-cloudflare-ips.sh

# Check firewall status
sudo ufw status numbered

# Verify DNS resolution
nslookup vault.yourdomain.com
```

## Performance Optimization

### Enhanced Database Performance
```bash
# Monthly database analysis with enhanced checks
sudo ./db-maint.sh --analyze-only

# Quarterly database optimization (automated)
sudo ./db-maint.sh --backup

# Check database size and fragmentation
sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 "PRAGMA page_count; PRAGMA freelist_count;"
```

### System Performance with Template Optimization
```bash
# Clean up disk space if needed
sudo ./maintenance.sh --type standard --force

# Deep cleanup if disk usage > 80%
sudo ./maintenance.sh --type deep --force

# Monitor container performance
docker stats vaultwarden_app --no-stream

# Validate template-generated resource limits
docker compose config | grep -E "memory|cpus"
```

## Best Practices for Single Admin Operations

### Template-Based Documentation
- Keep offline copies of template files and troubleshooting procedures
- Document any template customizations and configuration changes
- Maintain current backup of encryption keys and template files
- Document break-glass admin credentials securely

### Enhanced Testing
- Test backup restoration procedures quarterly with atomic operations
- Verify break-glass admin access annually via OCI serial console (status check)
- Test template regeneration and update procedures in development
- Verify enhanced monitoring and alerting systems monthly

### Security with Template Integration
- Review access logs monthly with enhanced fail2ban analysis
- Keep system and container versions updated via template configuration
- Monitor security advisories for components used in templates
- Maintain strong, unique passwords for all accounts including break-glass admin

### Enhanced Automation
- Rely on automated tasks for routine operations via cron-setup.sh
- Monitor automated task completion via enhanced logging
- Manually verify critical automated operations monthly
- Adjust automation based on operational experience and template updates
- Regularly validate template-based configurations

---

This operations guide is designed for the reality of single-administrator, small team environments where template-based simplicity, enhanced reliability, and clear procedures are essential for effective system management with minimal operational overhead.
