# Troubleshooting Guide - VaultWarden-OCI-Simplified

This comprehensive troubleshooting guide covers common issues, diagnostic procedures, and recovery methods for VaultWarden-OCI-Simplified deployments.

## Quick Reference - Emergency Procedures

### 🚨 SSH Access Lost (Firewall/Account Issues)

**Immediate Action**: Use OCI Serial Console + Break-glass Admin
```bash
# 1. Access OCI Console → Compute → Instance → Console Connection
# 2. Login with break-glass admin credentials (see setup in SCRIPTS.md)
# 3. Fix firewall: sudo ufw allow 22/tcp
# 4. Check SSH service: sudo systemctl status sshd
# 5. Regain normal SSH access

# If no break-glass admin exists:
sudo ./create-breakglass-admin.sh create
```

**Security Hygiene After Recovery**:
```bash
# After successfully regaining access using the serial console:
# 1. Delete the Console Connection in the OCI Console for security
# 2. If you used the break-glass admin password via serial console, rotate it:
sudo ./create-breakglass-admin.sh password
```

### 🚨 Complete Service Failure

**Immediate Actions**:
```bash
# Check system health
./health.sh --comprehensive

# Restart all services
./startup.sh --force-restart

# If that fails, restore from backup
./restore.sh backups/emergency/latest-kit.age
```

### 🚨 Data Corruption Suspected

**Immediate Actions**:
```bash
# Stop services immediately
./startup.sh --down

# Check database integrity
sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 "PRAGMA integrity_check;"

# If corrupted, restore from latest good backup
./restore.sh backups/db/latest-clean-backup.age
```

## Diagnostic Framework

### System Health Assessment

#### Comprehensive Health Check
```bash
# Run full diagnostic suite
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
```

#### Version Status Check
```bash
# Check configured vs running versions
grep "_VERSION=" .env
docker compose ps --format "table {{.Service}}	{{.Image}}"

# Check for available updates
./update.sh --type containers --check-only
```

## Service-Specific Troubleshooting

### VaultWarden Application Issues

#### Issue: VaultWarden Won't Start
**Symptoms**: Container exits immediately or fails health checks

**Diagnosis**:
```bash
# Check container logs
docker compose logs vaultwarden

# Common log patterns to look for:
# - Database lock errors
# - Permission denied on data directory
# - Invalid admin token format
# - SSL certificate issues
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

# Invalid admin token
./edit-secrets.sh
# Regenerate admin_token (32-character hex string)

# Force container recreation
./startup.sh --force-restart
```

### Version Management Issues

#### Issue: Container Using Wrong Version
**Symptoms**: Container runs different version than configured in .env

**Diagnosis**:
```bash
# Check environment variable loading
docker compose config | grep "image:"

# Check .env syntax (no spaces around =)
grep "_VERSION" .env

# Verify version pins are active
cat .env | grep -E "^[A-Z_]*_VERSION="
```

**Solutions**:
```bash
# Fix .env syntax (no spaces around = sign)
# Correct format:
VAULTWARDEN_VERSION=1.30.5

# Incorrect format:
# VAULTWARDEN_VERSION = 1.30.5

# Force restart to reload configuration
./startup.sh --force-restart

# Use update.sh to fix version pins
./update.sh --pin vaultwarden 1.30.5
./startup.sh --force-restart
```

### Emergency Recovery

#### SSH Access Lost (Most Common Emergency)
1. **Use break-glass admin via OCI Console**:
   - Access OCI Console → Compute → Instance → Console Connection
   - Login with break-glass admin credentials
   - Fix firewall: `sudo ufw allow 22/tcp`
   - Fix SSH: `sudo systemctl restart sshd`
   - **Security cleanup**: Delete the Console Connection in the OCI Console for security
   - **Rotate password**: If you used the break-glass admin password via serial console: `sudo ./create-breakglass-admin.sh password`

2. **If no break-glass admin configured**:
   - Use OCI boot volume attachment method
   - Create break-glass admin for future: `sudo ./create-breakglass-admin.sh create`

## Makefile Quality of Life Improvements

The project now includes convenient Makefile shortcuts for common operations:

### Backup and Restore Operations
```bash
# List all available backups
make list-backups

# Interactive backup restoration
make restore

# Create different backup types
make backup-db
make backup-full
make backup-emergency
```

### Version Management and Updates
```bash
# Check for available updates (no changes made)
make check-updates
make check-system-updates

# Update with automatic backup
make update-containers

# Version management
make pin SERVICE=vaultwarden VERSION=1.31.0
make unpin SERVICE=caddy
make pins  # Show current version pins
```

### System Monitoring and Maintenance
```bash
# Quick system overview
make status

# Comprehensive health check
make health

# Configuration validation
make config-check

# Follow service logs
make logs-follow SERVICE=caddy
```

### Emergency Access
```bash
# Break-glass admin management
make breakglass-status
make breakglass-create
make breakglass-password
```

## Container Version Management Best Practices

**When using latest tags** (e.g., in development or for emergency patches):
- Always run `docker compose pull` before `make restart` or `./startup.sh --force-restart` to ensure you are using the newest image layer and not a stale local one
- After any update (`make update-containers` or manual version changes), verify the running versions with `docker compose ps --format 'table {{.Service}}	{{.Image}}'`

---

**Emergency Contacts and Resources:**
- **OCI Console**: https://cloud.oracle.com
- **Cloudflare Dashboard**: https://dash.cloudflare.com  
- **Project Repository**: https://github.com/killer23d/VaultWarden-OCI-Simplified
- **VaultWarden Wiki**: https://github.com/dani-garcia/vaultwarden/wiki

**Remember**: Always test recovery procedures in a non-production environment before relying on them in emergencies. Keep this troubleshooting guide accessible offline in case of complete system failures.
