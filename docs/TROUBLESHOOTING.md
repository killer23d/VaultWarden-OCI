# Troubleshooting Guide - VaultWarden-OCI

This comprehensive troubleshooting guide covers common issues, diagnostic procedures, and recovery methods for VaultWarden-OCI with current template-based architecture, dual CF+UFW protection, atomic backup operations, and enhanced emergency access.

## Quick Reference - Emergency Procedures

### 🚨 SSH Access Lost (Firewall/Account Issues)

**Immediate Action**: Use OCI Serial Console + Break-glass Admin
```bash
# OCI Console → Compute → Instance → Console Connection
# Login with break-glass admin (check with: ./create-breakglass-admin.sh status)
# Fix firewall and SSH
sudo ufw allow 22/tcp
sudo systemctl restart sshd

# Post-recovery hygiene
./create-breakglass-admin.sh password  # Rotate password
```

### 🚨 Complete Service Failure
```bash
./health.sh --comprehensive
./startup.sh --force-restart
docker compose config
sudo ./setup.sh --force --domain $DOMAIN --email $ADMIN_EMAIL
./restore.sh --interactive
```

### 🚨 Data Corruption Suspected
```bash
./startup.sh --down
sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 "PRAGMA integrity_check;"
./restore.sh --interactive  # Select latest good DB backup
```

## Diagnostic Framework

### Comprehensive Health Assessment
```bash
./health.sh --comprehensive
# Expect: all services healthy, backups recent, keys accessible, firewall configured
```

### Service Diagnostics
```bash
docker compose ps
docker compose logs vaultwarden
docker compose logs caddy
docker compose logs fail2ban
```

### Template Status
```bash
docker compose config
ls -la *.example
grep -n "platform:\|linux/arm64" docker-compose.yml.example
```

## Service-Specific Troubleshooting

### VaultWarden Won't Start
```bash
docker compose logs vaultwarden
./startup.sh --down && ./startup.sh
sudo chown -R 1000:1000 /var/lib/vaultwarden/data/
./edit-secrets.sh  # Verify admin_token format
sudo ./setup.sh --force --domain $DOMAIN --email $ADMIN_EMAIL
```

### Template Misconfiguration
```bash
docker compose config
sudo ./setup.sh --force --domain $DOMAIN --email $ADMIN_EMAIL
./startup.sh --force-restart
```

### Fail2Ban / Cloudflare Issues
```bash
docker compose exec fail2ban fail2ban-client status
docker compose logs fail2ban | grep -E "Rate|CF|UFW|Error"
# Verify CF token permissions (Zone:Firewall Services:Edit)
```

### Firewall / Cloudflare IP Update Problems
```bash
sudo ufw status numbered
./maintenance.sh --update-firewall --dry-run
nslookup $DOMAIN
curl -s https://api.cloudflare.com/client/v4/ips | jq .
```

## Enhanced Troubleshooting Procedures

### Template Validation
```bash
docker compose -f docker-compose.yml.example config
grep -n "platform:\|linux/arm64" docker-compose.yml.example
```

### Backup/Restore
```bash
./backup.sh --list
./backup.sh --type db --verify
./restore.sh --interactive
```

### Break-Glass Admin
```bash
./create-breakglass-admin.sh status
sudo su - break-glass-admin || ./create-breakglass-admin.sh
```

## Performance Troubleshooting

### Resource Usage
```bash
docker stats --no-stream
htop
free -h
df -h
```

### Database Performance
```bash
sudo ./db-maint.sh --analyze-only
sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 "PRAGMA page_count; PRAGMA freelist_count;"
```

## Recovery Procedures

### Template-Based Recovery
```bash
sudo ./setup.sh --force --domain $DOMAIN --email $ADMIN_EMAIL
./startup.sh --force-restart
./health.sh --comprehensive
```

### Full Recovery
```bash
./startup.sh --down
./restore.sh --interactive
./startup.sh
./health.sh --comprehensive
```

---

Keep this guide accessible offline. With template-based configuration, dual CF+UFW protection, atomic backups, and break-glass admin, multiple recovery paths exist for rapid incident resolution.
