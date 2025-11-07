# Troubleshooting Guide - VaultWarden-OCI

Common issues and solutions for VaultWarden-OCI deployment and operations.

## General Troubleshooting Approach

1. **Check service status**: `./health.sh` or `make health`
2. **Review logs**: `docker compose logs` or `make logs`
3. **Validate configuration**: `docker compose config` or `make test-config`
4. **Check resources**: `docker stats`
5. **Verify connectivity**: Test network, DNS, and firewall

## Service Issues

### Services Won't Start

**Symptoms**:
- Services fail to start
- Containers exit immediately
- Docker Compose errors

**Diagnosis**:
```bash
# Check service status
./health.sh
docker compose ps

# View logs
docker compose logs
make logs

# Validate configuration
docker compose config
make test-config
```

**Solutions**:
```bash
# Fix configuration and restart
./startup.sh --force-restart
make restart

# If templates are invalid, validate first
docker compose -f docker-compose.yml.example config

# Regenerate from templates
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com
./startup.sh --force-restart
```

### VaultWarden Container Crashes

**Symptoms**:
- VaultWarden container stops unexpectedly
- Database errors in logs
- Web vault inaccessible

**Diagnosis**:
```bash
# Check VaultWarden logs
docker compose logs vaultwarden | tail -100
make logs SERVICE=vaultwarden

# Check for database issues
docker compose exec vaultwarden sqlite3 /data/db.sqlite3 "PRAGMA integrity_check;"

# Check resource usage
docker stats vaultwarden_app
```

**Solutions**:
```bash
# Database corruption
./db-maint.sh

# If database is corrupt, restore from backup
./restore.sh --type db

# Check resource limits
docker inspect vaultwarden_app | grep -A 10 Memory

# Increase limits if needed (edit template)
nano docker-compose.yml.example
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com
./startup.sh --force-restart
```

### Caddy Certificate Issues

**Symptoms**:
- HTTPS not working
- Certificate errors
- DNS-01 challenge failures

**Diagnosis**:
```bash
# Check Caddy logs
docker compose logs caddy | grep -i error
make logs SERVICE=caddy

# Verify Cloudflare API token
./edit-secrets.sh --test

# Check DNS resolution
dig +short vault.example.com

# Test Cloudflare API
curl -X GET "https://api.cloudflare.com/client/v4/zones" \\
     -H "Authorization: Bearer YOUR_DNS_TOKEN"
```

**Solutions**:
```bash
# Verify Cloudflare DNS token in secrets
./edit-secrets.sh
# Ensure caddy_cloudflare_dns_token is set

# Restart Caddy to retry
docker compose restart caddy

# Force certificate renewal
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## Configuration Issues

### Template Validation Errors

**Symptoms**:
- `docker compose config` fails
- Syntax errors in generated files
- Services won't start due to config errors

**Diagnosis**:
```bash
# Validate template
docker compose -f docker-compose.yml.example config

# Check for common issues
cat docker-compose.yml.example | grep -n "platform:\\|linux/arm64"

# Validate current config
docker compose config
```

**Solutions**:
```bash
# Fix template syntax
nano docker-compose.yml.example

# Validate after changes
docker compose -f docker-compose.yml.example config

# Regenerate from fixed template
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com
```

### Environment Variable Issues

**Symptoms**:
- Services missing configuration
- Incorrect behavior
- Connection failures

**Diagnosis**:
```bash
# Check .env file
cat .env | grep -v "^#"

# Verify critical variables are set
grep -E "DOMAIN|CLOUDFLARE_ZONE_ID|SMTP_HOST" .env

# Check if services are using environment
docker compose config | grep -A 5 environment
```

**Solutions**:
```bash
# Edit environment file
nano .env

# Or regenerate from template
cp .env.example .env
# Edit with correct values
nano .env

# Restart services to apply
./startup.sh --force-restart
```

### Secrets Decryption Failures

**Symptoms**:
- Cannot edit secrets
- Services can't load secrets
- Age decryption errors

**Diagnosis**:
```bash
# Test secrets decryption
./edit-secrets.sh --test
make test-secrets

# Verify Age key exists
ls -l secrets/keys/age-key.txt

# Check permissions
ls -la secrets/
```

**Solutions**:
```bash
# If Age key is missing, regenerate
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com

# Fix permissions
chmod 700 secrets/
chmod 600 secrets/keys/age-key.txt

# Test decryption
age -d -i secrets/keys/age-key.txt secrets/secrets.yaml
```

## Network and Connectivity Issues

### Cannot Access Web Vault

**Symptoms**:
- HTTPS site unreachable
- Connection timeout
- DNS resolution failures

**Diagnosis**:
```bash
# Check if services are running
docker compose ps

# Test local connectivity
curl -I http://localhost:80

# Check Caddy logs
docker compose logs caddy | grep -i error

# Verify DNS resolution
dig +short vault.example.com

# Check firewall
sudo ufw status
```

**Solutions**:
```bash
# Restart services
./startup.sh --force-restart

# Update DNS if IP changed
./update-dns.sh

# Verify Cloudflare proxy is enabled
# Check Cloudflare dashboard: DNS → Proxied (orange cloud)

# Update firewall if Cloudflare IPs changed
./maintenance.sh --update-firewall
```

### Firewall Blocking Access

**Symptoms**:
- Connection refused
- Timeout errors
- Can't reach services

**Diagnosis**:
```bash
# Check UFW status
sudo ufw status numbered

# Check for Cloudflare rules
sudo ufw status | grep CF

# Test from external IP
curl -I https://vault.example.com
```

**Solutions**:
```bash
# Update Cloudflare IP ranges safely
./maintenance.sh --update-firewall

# If firewall is blocking everything, check UFW
sudo ufw status

# Emergency: temporarily disable UFW (NOT RECOMMENDED for production)
# sudo ufw disable
# Fix firewall rules, then:
# sudo ufw enable

# Properly update firewall
./maintenance.sh --update-firewall
```

### DNS Not Updating

**Symptoms**:
- Wrong IP in DNS
- Dynamic IP changed but DNS still old
- Cannot reach site after IP change

**Diagnosis**:
```bash
# Check current public IP
curl -s ifconfig.me

# Check DNS record
dig +short vault.example.com

# Compare IPs
echo "Public IP: $(curl -s ifconfig.me)"
echo "DNS IP: $(dig +short vault.example.com)"
```

**Solutions**:
```bash
# Manual DNS update
./update-dns.sh

# Verify Cloudflare API token works
curl -X GET "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID" \\
     -H "Authorization: Bearer YOUR_DNS_TOKEN"

# Check CLOUDFLARE_ZONE_ID in .env
grep CLOUDFLARE_ZONE_ID .env
```

## Email Issues

### Email Not Sending (msmtpd)

**Symptoms**:
- Email notifications not received
- SMTP errors in logs
- VaultWarden can't send email

**Diagnosis**:
```bash
# Check msmtpd container status
docker compose ps msmtpd
docker compose logs msmtpd

# Test email functionality
./test-email-simple.sh --verbose

# Check msmtpd configuration
docker compose exec msmtpd cat /etc/msmtprc

# Verify SMTP connectivity
docker compose exec msmtpd nc -z localhost 1025
```

**Solutions**:
```bash
# Verify SMTP settings in .env
nano .env
# Check: SMTP_HOST, SMTP_PORT, SMTP_USERNAME

# Verify SMTP password in secrets
./edit-secrets.sh
# Check: smtp_password

# Restart msmtpd
docker compose restart msmtpd

# Test again
./test-email-simple.sh

# Send test from VaultWarden admin panel
# Navigate to: https://vault.example.com/admin → SMTP Settings → Send Test Email
```

### SMTP Authentication Failures

**Symptoms**:
- Authentication failed errors
- 535 SMTP errors in logs
- msmtpd can't connect to SMTP server

**Diagnosis**:
```bash
# Check SMTP credentials
./edit-secrets.sh --test

# View msmtpd logs for auth errors
docker compose logs msmtpd | grep -i auth
```

**Solutions**:
```bash
# Update SMTP password
./edit-secrets.sh
# Set correct smtp_password

# Verify SMTP settings
nano .env
# Ensure SMTP_USERNAME matches your email

# For Gmail, create app-specific password
# https://myaccount.google.com/apppasswords

# Restart services
docker compose restart msmtpd vaultwarden
```

## Backup and Restore Issues

### Backup Creation Fails

**Symptoms**:
- Backup script errors
- Insufficient disk space
- Encryption failures

**Diagnosis**:
```bash
# Check disk space
df -h /path/to/backups

# Verify Age key
ls -l secrets/keys/age-key.txt

# Test backup with dry-run
./backup.sh --type db --dry-run

# Check VaultWarden status
docker compose ps vaultwarden
```

**Solutions**:
```bash
# Free up disk space
./maintenance.sh --comprehensive

# If Age key missing, regenerate
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com

# Retry backup
./backup.sh --type db

# Check backup logs
docker compose logs | grep backup
```

### Restore Fails

**Symptoms**:
- Decryption errors
- Database corruption after restore
- Services won't start after restore

**Diagnosis**:
```bash
# Verify backup file integrity
sha256sum -c backup.age.sha256

# Test Age key
age -d -i secrets/keys/age-key.txt backup.age > /dev/null

# Check backup metadata
cat backup.age.meta
```

**Solutions**:
```bash
# Try older backup if current is corrupt
./backup.sh --list
./restore.sh --file /path/to/older-backup.age

# If Age key doesn't match, use emergency kit
./restore.sh --type emergency

# After restore, verify services
./health.sh --comprehensive
```

### Offsite Backup Sync Fails

**Symptoms**:
- Rclone errors
- Connection timeouts
- Authentication failures

**Diagnosis**:
```bash
# Test rclone connectivity
rclone lsd your_remote_name:

# Check rclone config
rclone config show your_remote_name

# Verify remote name in .env
grep RCLONE_REMOTE_NAME .env
```

**Solutions**:
```bash
# Reconfigure rclone
rclone config

# Update remote name in .env
nano .env
# Set: RCLONE_REMOTE_NAME=your_remote_name

# Test with small file
echo "test" | rclone rcat your_remote_name:test.txt
rclone cat your_remote_name:test.txt

# Retry backup
./backup.sh --type db --rclone
```

## Security Issues

### Fail2Ban Not Blocking

**Symptoms**:
- Repeated failed login attempts
- IPs not being banned
- Fail2ban inactive

**Diagnosis**:
```bash
# Check fail2ban status
docker compose exec fail2ban fail2ban-client status

# Check specific jail
docker compose exec fail2ban fail2ban-client status vaultwarden-auth

# View logs
docker compose logs fail2ban | tail -100

# Check dual action effectiveness
docker compose logs fail2ban | grep -E "CF.*ok|UFW.*ok"
```

**Solutions**:
```bash
# Restart fail2ban
docker compose restart fail2ban

# Verify Cloudflare firewall token
./edit-secrets.sh
# Check: fail2ban_cloudflare_firewall_token

# Test Cloudflare API
curl -X GET "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/firewall/access_rules/rules" \\
     -H "Authorization: Bearer YOUR_FIREWALL_TOKEN"

# Check filter syntax
docker compose exec fail2ban fail2ban-regex \\
  /var/log/vaultwarden/vaultwarden.log \\
  /data/fail2ban/filter.d/vaultwarden-auth.conf
```

### Admin Panel Inaccessible

**Symptoms**:
- 401 Unauthorized errors
- Basic auth prompts repeatedly
- Cannot login to /admin

**Diagnosis**:
```bash
# Check Caddy basic auth configuration
docker compose logs caddy | grep admin

# Verify admin_basic_auth_hash in secrets
./edit-secrets.sh --test
```

**Solutions**:
```bash
# Generate new bcrypt hash
docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password

# Update secrets with new hash
./edit-secrets.sh
# Set: admin_basic_auth_hash (paste bcrypt hash)

# Restart Caddy
docker compose restart caddy

# Test admin access
curl -u "admin:your_password" https://vault.example.com/admin
```

### Break-Glass Admin Not Working

**Symptoms**:
- Cannot login via OCI console
- SSH key authentication fails
- Emergency access unavailable

**Diagnosis**:
```bash
# Check break-glass admin status
./create-breakglass-admin.sh --status
make breakglass-status

# Verify user exists
sudo id vw-breakglass

# Check SSH configuration
sudo cat /home/vw-breakglass/.ssh/authorized_keys
```

**Solutions**:
```bash
# Recreate break-glass admin
./create-breakglass-admin.sh --create
make breakglass-create

# Test via OCI Console
# Navigate to: OCI Console → Instance → Console Connection

# If needed, remove and recreate
./create-breakglass-admin.sh --remove
./create-breakglass-admin.sh --create
```

## Performance Issues

### High CPU Usage

**Symptoms**:
- System slow or unresponsive
- High CPU percentage in docker stats
- Services timing out

**Diagnosis**:
```bash
# Check container CPU usage
docker stats --no-stream

# Check for runaway processes
docker compose top

# Review resource limits
docker inspect vaultwarden_app | grep -A 10 CPU
```

**Solutions**:
```bash
# Adjust CPU limits in template
nano docker-compose.yml.example
# Increase cpus value for affected container

# Regenerate and apply
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com
./startup.sh --force-restart

# Check for database issues
./db-maint.sh
```

### High Memory Usage

**Symptoms**:
- Out of memory errors
- Containers being killed
- System swapping heavily

**Diagnosis**:
```bash
# Check memory usage
docker stats --no-stream

# Check for memory leaks
docker compose logs | grep -i "out of memory"

# Review memory limits
docker inspect vaultwarden_app | grep -A 10 Memory
```

**Solutions**:
```bash
# Increase memory limits
nano docker-compose.yml.example
# Adjust memory values for your system

# Regenerate and restart
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com
./startup.sh --force-restart

# Run maintenance
./maintenance.sh --comprehensive
```

### Slow Database Performance

**Symptoms**:
- Slow web vault responses
- Database timeouts
- High database file size

**Diagnosis**:
```bash
# Check database size
du -h /var/lib/vaultwarden/data/bwdata/db.sqlite3

# Check database integrity
docker compose exec vaultwarden sqlite3 /data/db.sqlite3 "PRAGMA integrity_check;"

# Review VaultWarden logs
docker compose logs vaultwarden | grep -i slow
```

**Solutions**:
```bash
# Run database maintenance
./db-maint.sh

# If database is very large, consider cleanup
# Review and remove old trash items, sends, etc. via admin panel

# Restart VaultWarden
docker compose restart vaultwarden
```

## Getting Help

### Diagnostic Information to Collect

When reporting issues, include:

```bash
# System information
./health.sh --comprehensive --json > health-report.json

# Service logs
docker compose logs > service-logs.txt

# Configuration (sanitized)
docker compose config > config.txt
cat .env | grep -v "PASSWORD\\|TOKEN\\|SECRET" > env-sanitized.txt

# Resource usage
docker stats --no-stream > resource-usage.txt

# Version information
make version > version-info.txt
```

### Emergency Recovery

If all else fails:

```bash
# 1. Stop services
docker compose down

# 2. Create emergency backup (if possible)
./backup.sh --type emergency

# 3. Restore from last known good backup
./restore.sh

# 4. If complete failure, rebuild from emergency kit
# See BACKUP-RESTORE.md → Complete System Loss

# 5. Contact support with diagnostic information
```

---

This troubleshooting guide covers common issues and their solutions for VaultWarden-OCI. For issues not covered here, check the GitHub issues or create a new issue with diagnostic information.
"""
