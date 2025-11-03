# Operations Guide - VaultWarden-OCI

This guide provides practical operational procedures for maintaining VaultWarden-OCI in a production environment, optimized for single administrator, small team deployments with current template-based architecture, resource management, and enhanced automation.

## Set-and-Forget Operations Philosophy

VaultWarden-OCI is designed for minimal operational overhead with maximum reliability through:

- **Template-Based Configuration**: Single source of truth with `.example` files
- **Automated Operations**: Comprehensive cron-based automation via `cron-setup.sh`
- **Enhanced Monitoring**: Proactive health checks with auto-healing capabilities
- **Atomic Operations**: Reliable backup and restore procedures
- **Emergency Access**: Break-glass admin for critical recovery scenarios
- **Resource Limits**: Container limits prevent resource exhaustion on small hosts
- **Dual Blocking**: Cloudflare + UFW ensures robust intrusion prevention

## Daily Operations (5 minutes)

### Automated Health Check Review
```bash
# Check automated health monitoring results (configured via cron-setup.sh)
tail -20 /var/log/vaultwarden-cron/health.log

# Quick manual health check if needed
./health.sh --quiet

# If issues found, run comprehensive check with auto-heal:
./health.sh --comprehensive --auto-heal
```

### Service Status Verification
```bash
# Quick service status check
docker compose ps

# All services should show "Up" and "healthy"
# If any service is down:
./startup.sh --force-restart
```

### Backup Status Check (Atomic)
```bash
# Verify recent backups exist with detailed listing
./backup.sh --list | head -5

# If missing, check cron jobs
sudo crontab -l | grep vaultwarden
```

## Weekly Operations (15 minutes)

### System Status Review
```bash
# 1. Verify automation
sudo crontab -l | grep vaultwarden

# 2. Review logs for issues
docker compose logs --since 7d | grep -i error

# 3. Validate configuration
docker compose config  # Validate template-generated configuration

# 4. Check for updates
./update.sh --type containers --check-only
```

### Security Activity Review
```bash
# Enhanced fail2ban status (dual CF+UFW)
docker compose logs fail2ban --since 7d | grep -E "Ban|Unban|CF|UFW|Rate"

# Admin panel access review
docker compose logs caddy --since 7d | grep "/admin"

# Firewall status and Cloudflare IP updates
sudo ufw status numbered
./maintenance.sh --update-firewall --dry-run
```

### Resource Usage Check
```bash
# System resources
df -h                    # Disk usage
free -h                  # Memory usage
docker stats --no-stream # Container resource usage

# Targets:
# - Disk usage < 80%
# - Memory usage < 85%
# - No container exceeding limits persistently
```

## Monthly Operations (30 minutes)

### System Maintenance
```bash
# 1. Comprehensive health check
./health.sh --comprehensive --email-alert

# 2. Standard maintenance (safe cleanup)
sudo ./maintenance.sh --type standard --dry-run
sudo ./maintenance.sh --type standard --force

# 3. Database analysis (quarterly optimization)
sudo ./db-maint.sh --analyze-only
```

### Template Review
```bash
# 1. Validate template-generated configuration
docker compose config

# 2. Check template files for changes
ls -la *.example

# 3. Apply template updates if needed
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
./startup.sh --force-restart
```

### Backup Verification
```bash
# 1. Create manual emergency backup
./backup.sh --type emergency --rclone --email

# 2. Verify backup list and integrity
./backup.sh --list
./edit-secrets.sh --test

# 3. Verify remote rclone sync (if configured)
rclone ls YourRemote:vaultwarden_backups/ --max-age 30d | wc -l
```

## Template-Based Configuration Management

### Maintenance Workflow
```bash
# 1. Edit template files (source of truth)
nano docker-compose.yml.example
nano .env.example

# 2. Validate templates
docker compose -f docker-compose.yml.example config

# 3. Apply changes
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# 4. Restart and verify
./startup.sh --force-restart
./health.sh --comprehensive
```

### Drift Prevention
```bash
# Validate generated config regularly
docker compose config

# Detect drift
cmp -s docker-compose.yml docker-compose.yml.example || echo "Drift detected"
cmp -s .env .env.example || echo "Drift detected"

# Regenerate if drifted
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
```

## Backup and Recovery Operations

### Automated Strategy (via cron-setup.sh)
- Daily 3:00 AM: Database backups (atomic, optional rclone)
- Weekly Sunday 1:00 AM: Full backups (atomic, template-included)
- Weekly Sunday 5:00 AM: Cloudflare IP updates (safe ordering)

### Database Recovery
```bash
./startup.sh --down
./restore.sh --interactive  # Select DB backup
./startup.sh
./health.sh --comprehensive
```

### Full System Recovery (Template-Integrated)
```bash
./startup.sh --down
./restore.sh --interactive  # Select full or emergency kit
./startup.sh
./health.sh --comprehensive
```

## Emergency Procedures

### SSH Access Recovery (Break-Glass)
```bash
# 1. OCI Console → Compute → Instance → Console Connection
# 2. Login with break-glass admin credentials
# 3. Fix SSH and firewall
sudo systemctl restart sshd
sudo ufw allow 22/tcp

# 4. Cleanup
# Delete OCI console connection and rotate password
./create-breakglass-admin.sh password
```

### Service Recovery with Validation
```bash
./startup.sh --force-restart
docker compose config || sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
./restore.sh --interactive
```

## Monitoring and Alerting

### Health Monitoring
```bash
./health.sh --comprehensive --auto-heal --email-alert
./health.sh --comprehensive --json > /tmp/vaultwarden-status.json
```

### Log Analysis
```bash
# Recent errors
docker compose logs --since 24h | grep -i error

# Fail2Ban dual action
docker compose logs fail2ban --tail 100 | grep -E "CF|UFW|Ban|Unban|Rate"

# Template changes
git log --oneline -- "*.example"
```

### Performance Monitoring
```bash
docker stats --no-stream
htop
free -h
df -h
curl -f https://$DOMAIN/alive
```

## Maintenance Schedules

### Automated Tasks
- Health checks every 30 minutes (cron-setup.sh)
- DB backups daily at 3:00 AM
- Full backups weekly on Sunday 1:00 AM
- Container updates weekly (optional via update.sh)
- System maintenance monthly
- Cloudflare IP updates weekly at 5:00 AM

### Manual Checks
- Daily: Health and service checks
- Weekly: Logs, updates, resource usage
- Monthly: Health, maintenance, backups, security review
- Quarterly: DR tests, template review, resource tuning

---

This operations guide reflects the current project state with template-based configuration, resource-aware deployment, dual Cloudflare+UFW protection, and enhanced automation designed for reliable, low-touch operations.
