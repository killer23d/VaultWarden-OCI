# Troubleshooting Guide - VaultWarden-OCI

This comprehensive troubleshooting guide covers common issues, diagnostic procedures, and recovery methods for VaultWarden-OCI deployments with template-based architecture and enhanced features.

## Quick Reference - Emergency Procedures

### 🚨 SSH Access Lost (Firewall/Account Issues)

**Immediate Action**: Use OCI Serial Console + Break-glass Admin
```bash
# 1. Access OCI Console → Compute → Instance → Console Connection
# 2. Create console connection (if not exists)
# 3. Login with break-glass admin credentials (see: ./create-breakglass-admin.sh status)
# 4. Fix firewall: sudo ufw allow 22/tcp
# 5. Check SSH service: sudo systemctl status sshd
# 6. Regain normal SSH access

# If no break-glass admin exists:
./create-breakglass-admin.sh
```

**Security Hygiene After Recovery**:
```bash
# After successfully regaining access using the serial console:
# 1. Delete the Console Connection in the OCI Console for security
# 2. Rotate break-glass admin password for security:
./create-breakglass-admin.sh password
# 3. Document the incident and root cause
# 4. Review and fix the underlying issue
```

### 🚨 Complete Service Failure

**Immediate Actions**:
```bash
# Check system health with template validation
./health.sh --comprehensive

# Restart all services with race condition fixes
./startup.sh --force-restart

# If that fails, validate template configuration
docker compose config

# If template issues, regenerate configuration
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# If still failing, restore from backup with template integration
./restore.sh --interactive
```

### 🚨 Data Corruption Suspected

**Immediate Actions**:
```bash
# Stop services immediately
./startup.sh --down

# Check database integrity
sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 "PRAGMA integrity_check;"

# If corrupted, restore from latest good backup with atomic operations
./restore.sh --interactive
# Select appropriate database backup from enhanced menu
```

## Diagnostic Framework

### Enhanced System Health Assessment

#### Comprehensive Health Check with Template Validation
```bash
# Run full diagnostic suite with template validation
./health.sh --comprehensive

# Example healthy output:
✅ Docker daemon accessible
✅ vaultwarden is running and healthy
✅ caddy is running and healthy  
✅ fail2ban is running and healthy
✅ ddclient is running and healthy
✅ Memory usage: 45% (< 85% threshold)
✅ Disk usage: 25% (< 85% threshold)
✅ Found 5 recent backup(s)
✅ Age encryption key accessible
✅ Firewall active and configured
✅ Break-glass admin configured and ready
✅ Template configuration valid
✅ Enhanced fail2ban rate limiting active
```

#### Service-Specific Diagnostics
```bash
# Check individual services
docker compose ps
docker compose logs vaultwarden
docker compose logs caddy
docker compose logs fail2ban
docker compose logs ddclient

# Check container health specifically
docker inspect vaultwarden_app --format='{{.State.Health.Status}}'

# Validate template-generated configuration
docker compose config
```

#### Template Configuration Status Check
```bash
# Check template-generated configuration
docker compose config

# Verify templates exist and are readable
ls -la *.example

# Check for template syntax issues
cat docker-compose.yml.example | grep -n "platform:\|linux/arm64"
```

## Service-Specific Troubleshooting

### VaultWarden Application Issues

#### Issue: VaultWarden Won't Start
**Symptoms**: Container exits immediately or fails health checks

**Diagnosis**:
```bash
# Check container logs
docker compose logs vaultwarden

# Validate template-generated configuration
docker compose config

# Common log patterns to look for:
# - Database lock errors
# - Permission denied on data directory
# - Invalid admin token format
# - SSL certificate issues
# - Template configuration errors
```

**Solutions**:
```bash
# Database lock issue
./startup.sh --down
sudo fuser -k /var/lib/vaultwarden/data/bwdata/db.sqlite3 2>/dev/null || true
./startup.sh

# Permission issues
sudo chown -R 1000:1000 /var/lib/vaultwarden/data/
sudo chmod 755 /var/lib/vaultwarden/data/
sudo chmod 600 /var/lib/vaultwarden/data/bwdata/db.sqlite3

# Invalid admin token or template issues
./edit-secrets.sh
# Regenerate admin_token (32-character hex string)

# Template configuration issues
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# Force container recreation
./startup.sh --force-restart
```

### Template Configuration Issues

#### Issue: Services Using Wrong Configuration
**Symptoms**: Services don't reflect expected configuration from templates

**Diagnosis**:
```bash
# Validate template-generated configuration
docker compose config

# Check template files exist and are readable
ls -la *.example

# Verify environment variable loading
source .env && env | grep -E "DOMAIN|ADMIN_EMAIL|CLOUDFLARE"

# Check for template syntax issues
grep -n "platform:\|linux/arm64" docker-compose.yml.example
```

**Solutions**:
```bash
# Regenerate configuration from templates
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# Validate regenerated configuration
docker compose config

# Force restart to reload configuration
./startup.sh --force-restart

# Verify services are using correct configuration
docker compose ps --format "table {{.Service}}	{{.Image}}"
```

### Enhanced fail2ban and Cloudflare Integration

#### Issue: fail2ban Not Blocking IPs or Rate Limiting Issues
**Symptoms**: Malicious IPs not blocked, or API rate limit errors

**Diagnosis**:
```bash
# Check enhanced fail2ban status with rate limiting
docker compose exec fail2ban fail2ban-client status

# Check Cloudflare API connectivity and rate limiting
docker compose logs fail2ban | grep -E "Rate|Error|Cloudflare"

# Test API tokens with rate limiting consideration
curl -X GET "https://api.cloudflare.com/client/v4/zones"      -H "Authorization: Bearer YOUR_FAIL2BAN_TOKEN"      -H "Content-Type: application/json"

# Check rate limiting effectiveness
docker compose logs fail2ban | grep -i "rate" | tail -10
```

**Solutions**:
```bash
# Check API token permissions (Zone:Firewall Services:Edit)
# Verify rate limiting is active and not exceeded
docker compose logs fail2ban | grep -E "Rate.*limit"

# Restart fail2ban if needed
docker compose restart fail2ban

# Check Cloudflare firewall rules
curl -H "Authorization: Bearer YOUR_TOKEN"      "https://api.cloudflare.com/client/v4/zones/ZONE_ID/firewall/access_rules/rules"

# If rate limiting issues, wait and retry
# Enhanced fail2ban includes automatic backoff
```

### Network and Firewall Issues

#### Issue: UFW Firewall Blocks Traffic or Cloudflare IP Update Fails
**Symptoms**: Unable to access services, or firewall update errors

**Diagnosis**:
```bash
# Check firewall status
sudo ufw status numbered

# Check Cloudflare IP update with enhanced error handling
sudo ./update-cloudflare-ips.sh --dry-run

# Verify DNS resolution
nslookup vault.yourdomain.com

# Check Cloudflare API connectivity
curl -X GET "https://api.cloudflare.com/client/v4/ips" | jq .
```

**Solutions**:
```bash
# Update Cloudflare IP ranges with enhanced error handling
sudo ./update-cloudflare-ips.sh

# If Cloudflare API fails, manual emergency access:
sudo ufw allow from any to any port 443
sudo ufw allow from any to any port 80

# Fix underlying issue, then restore restrictive rules:
sudo ./update-cloudflare-ips.sh --force

# If using break-glass admin due to SSH lockout:
# 1. Access via OCI serial console
# 2. Fix firewall: sudo ufw allow 22/tcp
# 3. Delete console connection for security
# 4. Rotate break-glass password
```

## Enhanced Troubleshooting Procedures

### Template Configuration Problems

#### Template Validation Issues
```bash
# Check template syntax
docker compose config
# Should show no errors

# Check for common template issues
grep -n "platform:\|linux/arm64" docker-compose.yml.example

# Verify all required template variables are set
grep -E "\$\{[A-Z_]+\}" docker-compose.yml.example
```

#### Template Regeneration
```bash
# Force regenerate from templates
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# Validate regenerated configuration
docker compose config

# Check differences between template and generated files
diff docker-compose.yml.example docker-compose.yml
diff .env.example .env
```

### Atomic Backup and Restore Issues

#### Backup Creation Problems
```bash
# Check backup creation with enhanced listing
./backup.sh --list

# Test backup creation with atomic operations
./backup.sh --type db --verify

# Check disk space for atomic operations
df -h | grep -E "/$|/var"

# Verify Age key accessibility
./edit-secrets.sh --test
```

#### Restore Problems
```bash
# Interactive restore with enhanced validation
./restore.sh --interactive

# Test restore without executing
./restore.sh --dry-run backup-file.age

# Check backup integrity
age -d -i secrets/keys/age-key.txt backup-file.age > /dev/null
echo $?  # Should return 0
```

### Break-Glass Admin Issues

#### Break-Glass Admin Not Working
```bash
# Check break-glass admin status
./create-breakglass-admin.sh status

# Create or recreate break-glass admin
./create-breakglass-admin.sh

# Test password (without OCI console)
sudo su - break-glass-admin

# Check if OCI console connection exists
# OCI Console → Compute → Instance → Console Connection
```

### Enhanced Monitoring and Alerting Issues

#### Health Check Failures
```bash
# Comprehensive health check with auto-healing
./health.sh --comprehensive --auto-heal

# Check specific health components
./health.sh --check docker
./health.sh --check containers
./health.sh --check resources

# JSON output for debugging
./health.sh --comprehensive --json | jq .
```

## Performance Troubleshooting

### Container Performance Issues

#### High Resource Usage
```bash
# Check container resource usage
docker stats --no-stream

# Check resource limits from template
docker compose config | grep -E "memory|cpus"

# Check system resources
htop
df -h
free -h
```

#### Database Performance Issues
```bash
# Check database performance
sudo ./db-maint.sh --analyze-only

# Check database size and fragmentation
sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 "PRAGMA page_count; PRAGMA freelist_count;"

# Check for database locks
sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 "PRAGMA busy_timeout; PRAGMA journal_mode;"
```

## Recovery Procedures

### Template-Based Recovery

#### Configuration Recovery
```bash
# If configuration is corrupted, regenerate from templates
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
./startup.sh --force-restart
./health.sh --comprehensive
```

#### Complete System Recovery
```bash
# Stop services
./startup.sh --down

# Interactive restore with template integration
./restore.sh --interactive
# Select emergency kit or full backup

# Verify template configuration after restore
docker compose config

# Start services and verify
./startup.sh
./health.sh --comprehensive
```

### Emergency Access Recovery

#### SSH Recovery via Break-Glass Admin
```bash
# If SSH access lost:
# 1. OCI Console → Compute → Instance → Console Connection
# 2. Create console connection
# 3. Login with break-glass admin credentials
# 4. Fix SSH: sudo systemctl restart sshd; sudo ufw allow 22/tcp
# 5. Security cleanup:
#    - Delete console connection
#    - Rotate password: ./create-breakglass-admin.sh password
```

## Common Issues and Solutions

### Issue: Template Files Missing or Corrupted
```bash
# Check if templates exist
ls -la *.example

# If missing, restore from git or backup
git checkout HEAD -- *.example

# Or restore from emergency backup that includes templates
./restore.sh --interactive
# Select emergency kit backup
```

### Issue: Enhanced fail2ban Rate Limiting Triggered
```bash
# Check rate limiting status
docker compose logs fail2ban | grep -i "rate"

# Wait for rate limit reset (typically 1 minute)
# Enhanced fail2ban includes automatic backoff

# If persistent, check API token permissions
curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify"      -H "Authorization: Bearer YOUR_FAIL2BAN_TOKEN"
```

### Issue: Atomic Backup Operations Failing
```bash
# Check disk space (atomic operations need extra space)
df -h

# Check database locks
./startup.sh --down
./backup.sh --type db
./startup.sh

# Verify backup integrity
./backup.sh --list
```

## Monitoring and Logging

### Enhanced Log Analysis

#### Service Logs
```bash
# VaultWarden logs
docker compose logs vaultwarden --tail 100

# Enhanced fail2ban logs with rate limiting
docker compose logs fail2ban --tail 100 | grep -E "Rate|Ban|Error"

# Caddy access logs
docker compose logs caddy --tail 100

# System logs
sudo journalctl -u docker --since "1 hour ago"
```

#### Template Configuration Logs
```bash
# Check template generation logs
grep -i "template\|setup" /var/log/syslog

# Git history of template changes
git log --oneline -- "*.example"
```

### Performance Monitoring

#### System Performance
```bash
# Real-time monitoring
htop
iotop
netstat -tuln

# Historical performance
uptime
free -h
df -h
```

#### Application Performance
```bash
# Container performance
docker stats --no-stream

# Database performance
sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 ".stats"

# Network performance
curl -w "%{time_total}" -o /dev/null -s https://vault.yourdomain.com/
```

---

**Emergency Contacts and Resources:**
- **OCI Console**: https://cloud.oracle.com
- **Cloudflare Dashboard**: https://dash.cloudflare.com  
- **Project Repository**: https://github.com/killer23d/VaultWarden-OCI
- **VaultWarden Wiki**: https://github.com/dani-garcia/vaultwarden/wiki

**Remember**: Always test recovery procedures in a non-production environment. The template-based architecture, enhanced fail2ban security, atomic backup operations, and break-glass admin access provide multiple recovery paths for different failure scenarios. Keep this troubleshooting guide accessible offline in case of complete system failures.
