# Security Guide - VaultWarden-OCI

This comprehensive security guide covers the multi-layered security approach implemented in VaultWarden-OCI, including Cloudflare-only blocking for web traffic, encrypted secrets management, firewall hardening, and emergency access procedures.

## Security Architecture Overview

VaultWarden-OCI implements defense-in-depth with multiple security layers:

```
┌─────────────────────────────────────────┐
│   Layer 1: Cloudflare Edge Security    │
│   - Global WAF                          │
│   - DDoS Protection                     │
│   - IP Blocking (Web Traffic ONLY)     │
│   - TLS Termination at Edge             │
└─────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────┐
│   Layer 2: Host Firewall (UFW)         │
│   - Cloudflare IP Whitelist             │
│   - SSH Protection (Local iptables)     │
│   - Safe Update Mechanism               │
└─────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────┐
│   Layer 3: Application Security         │
│   - Caddy Reverse Proxy                 │
│   - Enhanced Rate Limiting              │
│   - Forensic Logging (3GB retention)    │
│   - Security Headers                    │
└─────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────┐
│   Layer 4: Fail2Ban Monitoring         │
│   - Cloudflare-ONLY for Web Traffic    │
│   - Local iptables ONLY for SSH         │
│   - High-Fidelity Log Parsing           │
│   - Email Alerts via msmtpd             │
└─────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────┐
│   Layer 5: Container Security          │
│   - Non-root Execution                  │
│   - Capability Restrictions             │
│   - Resource Limits                     │
│   - Encrypted Secrets                   │
└─────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────┐
│   Layer 6: Data Security                │
│   - Age + SOPS Encryption               │
│   - Atomic Backup Operations            │
│   - Integrity Verification              │
│   - Encrypted Remote Backups            │
└─────────────────────────────────────────┘
```

## Critical Understanding: Cloudflare Proxy Architecture

### Why Cloudflare-Only Blocking for Web Traffic

**CRITICAL**: When VaultWarden is behind Cloudflare proxy:
- All web traffic appears to come from Cloudflare IP addresses
- The actual attacker's IP is in the `CF-Connecting-IP` header
- Local iptables rules blocking attacker IPs are **completely ineffective**
- The firewall would block Cloudflare's IPs, breaking all web access

### Current Blocking Strategy

#### Web Traffic (Proxied through Cloudflare)
```ini
# All web-facing jails use Cloudflare API ONLY
[vaultwarden-auth]
action = smtp[...]
         cloudflare-apiv4    # ✅ Blocks at Cloudflare edge

[vaultwarden-admin]
action = smtp[...]
         cloudflare-apiv4    # ✅ Blocks at Cloudflare edge

[vaultwarden-web-*]
action = smtp[...]
         cloudflare-apiv4    # ✅ Blocks at Cloudflare edge
```

#### SSH Traffic (Direct, NOT Proxied)
```ini
# SSH jail uses local iptables (direct connection)
[sshd]
action = smtp[...]
         iptables-multiport  # ✅ Local blocking works for SSH
```

### Benefits of Cloudflare-Only Web Blocking
- ✅ **Global reach**: Blocks attackers at Cloudflare's edge, before they reach your server
- ✅ **True source IP**: Uses `CF-Connecting-IP` header for accurate detection
- ✅ **No firewall pollution**: Doesn't add ineffective rules to local firewall
- ✅ **Faster blocking**: Edge blocking is immediate and global
- ✅ **API-driven**: Automated, programmatic control via Cloudflare API

## Cloudflare Integration

### API Token Requirements

Two separate tokens are required for enhanced security:

#### Token 1: DNS Management (Caddy)
```
Name: VaultWarden DNS Management
Permissions:
  - Zone:DNS:Edit
  - Zone:Zone:Read
Zone Resources:
  - Include → Specific zone → yourdomain.com
```

**Used for**:
- Automatic Let's Encrypt DNS challenge
- Dynamic DNS updates for changing IPs

#### Token 2: Firewall Management (Fail2Ban)
```
Name: VaultWarden Firewall Management
Permissions:
  - Zone:Firewall Services:Edit
Zone Resources:
  - Include → Specific zone → yourdomain.com
```

**Used for**:
- Creating WAF rules to block malicious IPs
- Managing Cloudflare-level IP access lists
- Automated ban/unban operations

### Cloudflare WAF Rules

Fail2Ban creates rules like:
```
Rule: fail2ban-vaultwarden-auth
Action: Block
Expression: (ip.src in {1.2.3.4 5.6.7.8})
```

These rules:
- Block at Cloudflare edge (never reach your server)
- Apply globally across all Cloudflare edge locations
- Use actual attacker IP from `CF-Connecting-IP` header
- Expire automatically based on `bantime` configuration

## Encrypted Secrets Management

### Age + SOPS Architecture

All sensitive data is encrypted using industry-standard tools:

```
Age (Encryption)
  ↓
SOPS (Secrets Management)
  ↓
Docker Secrets (Runtime)
  ↓
Containers (Read-Only Access)
```

### Protected Secrets

```yaml
# secrets/secrets.yaml (encrypted)
admin_token: "32-character-hex-string"
admin_basic_auth_hash: "$2b$12$bcrypt_hash"
caddy_cloudflare_dns_token: "cloudflare_dns_token"
fail2ban_cloudflare_firewall_token: "cloudflare_firewall_token"
smtp_password: "smtp_password"
push_installation_id: "optional"
push_installation_key: "optional"
```

### Enhanced Security Features

The `edit-secrets.sh` script includes:
- **Process privacy**: SOPS key path never exposed in process list
- **Secure temp files**: Proper cleanup of temporary decrypted data
- **Automatic backups**: Creates backup before editing
- **Validation**: Comprehensive checks after editing
- **Editor security**: Validates editor is not running as root

### Managing Secrets

```bash
# Edit secrets securely (recommended)
./edit-secrets.sh

# Specify editor
./edit-secrets.sh --editor vim

# Validate secrets without editing
sops -d secrets/secrets.yaml > /dev/null && echo "Valid"

# Backup secrets manually
cp secrets/secrets.yaml secrets/secrets.yaml.backup
```

## Fail2Ban Configuration

### Cloudflare-Only Web Jails

All web-facing jails now use Cloudflare API exclusively:

```ini
# iptables removed - ineffective for proxied traffic
[vaultwarden-auth]
action = smtp[name=vaultwarden-auth, ...]
         cloudflare-apiv4

[vaultwarden-admin]
action = smtp[name=vaultwarden-admin, ...]
         cloudflare-apiv4

[vaultwarden-web-auth]
action = smtp[name=vaultwarden-web-auth, ...]
         cloudflare-apiv4
```

### Local iptables for SSH Only

SSH protection uses local iptables (direct connection):

```ini
# SSH is NOT proxied, so iptables works correctly
[sshd]
action = smtp[name=sshd, ...]
         iptables-multiport[name=sshd, port="ssh", protocol=tcp]
```

### Enhanced Detection Capabilities

#### High-Fidelity VaultWarden Log Parsing
```ini
# Direct application log monitoring
[vaultwarden-auth]
logpath  = /var/log/vaultwarden/vaultwarden.log
filter   = vaultwarden-auth
maxretry = 3
bantime  = 2h
```

#### Specialized Caddy Log Monitoring
```ini
# Enhanced forensic logs with long retention
[vaultwarden-web-auth]
logpath  = /var/log/caddy/auth_attempts.log  # 750MB retention
filter   = vaultwarden-web-caddy
maxretry = 10

[vaultwarden-web-admin]
logpath  = /var/log/caddy/admin_access.log   # 750MB retention
maxretry = 5
```

### Email Notifications via msmtpd

Email alerts are sent via containerized msmtpd:

```ini
# All jails include email notifications
action = smtp[name=jail_name, dest="admin@example.com", sender="fail2ban@domain.com"]
         cloudflare-apiv4  # or iptables-multiport for SSH
```

Benefits:
- ✅ No host dependencies (mailutils not required)
- ✅ Consistent SMTP configuration
- ✅ Dedicated container logs for troubleshooting
- ✅ Resource-efficient (32MB limit)

## Firewall Hardening (UFW)

### Cloudflare IP Whitelist

Only Cloudflare IPs are allowed for web traffic:

```bash
# Allow Cloudflare IPv4 ranges
sudo ufw allow from 173.245.48.0/20 to any port 443 proto tcp
sudo ufw allow from 103.21.244.0/22 to any port 443 proto tcp
# ... (all Cloudflare IPv4 ranges)

# Allow Cloudflare IPv6 ranges
sudo ufw allow from 2400:cb00::/32 to any port 443 proto tcp
# ... (all Cloudflare IPv6 ranges)
```

### SSH Protection

```bash
# SSH access (rate limited)
sudo ufw limit 22/tcp comment 'SSH rate limit'
```

### Safe Firewall Updates

The maintenance script includes race condition fixes:

```bash
# Enhanced update process
./maintenance.sh --update-firewall

# Features:
# 1. Adds new rules BEFORE removing old ones
# 2. Validates rules before applying
# 3. Falls back to safe defaults if API fails
# 4. Comprehensive logging of all changes
```

## Container Security

### Non-Root Execution

All containers run as non-root users:

```yaml
services:
  vaultwarden:
    user: "${PUID}:${PGID}"  # Typically 1000:1000

  caddy:
    user: "${PUID}:${PGID}"

  # fail2ban and msmtpd use container-default non-root users
```

### Capability Restrictions

Containers drop all capabilities and only add necessary ones:

```yaml
vaultwarden:
  cap_drop:
    - ALL
  # No capabilities added

caddy:
  cap_drop:
    - ALL
  cap_add:
    - NET_BIND_SERVICE  # Required for ports 80/443

fail2ban:
  cap_add:
    - NET_ADMIN  # Required for iptables (SSH only)
    - NET_RAW    # Required for network monitoring
```

### Resource Limits

Prevents resource exhaustion attacks:

```yaml
vaultwarden:
  deploy:
    resources:
      limits:
        memory: 2G
        cpus: '0.6'

caddy:
  deploy:
    resources:
      limits:
        memory: 1G
        cpus: '0.3'

fail2ban:
  deploy:
    resources:
      limits:
        memory: 1G
        cpus: '0.2'

msmtpd:
  deploy:
    resources:
      limits:
        memory: 32M
        cpus: '0.05'
```

### Security Options

```yaml
security_opt:
  - no-new-privileges:true
```

Prevents privilege escalation within containers.

## Application Security

### Admin Panel Protection

Two-factor protection for admin panel:

1. **Caddy Basic Authentication** (bcrypt hash):
```caddyfile
route /admin* {
    import admin_basic_auth
    reverse_proxy vaultwarden:80
}
```

2. **Admin Token** (in encrypted secrets):
```yaml
admin_token: "32-character-hex-string"
```

### Rate Limiting

Caddy implements strict rate limits:

```caddyfile
# API authentication rate limiting
rate_limit {
    zone api_auth_rl {
        match_path /api/accounts/prelogin /identity/connect/token
        capacity 10
        window 5m
    }
}

# Admin panel rate limiting
rate_limit {
    zone admin_rl {
        capacity 5
        window 5m
    }
}
```

### Security Headers

```caddyfile
header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "SAMEORIGIN"
    Referrer-Policy "same-origin"
    Permissions-Policy "geolocation=(), microphone=(), camera=()"
    Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'"
    -Server
}
```

## Forensic Logging

### Enhanced Log Retention (60x Improvement)

Total forensic capacity: **~3GB** (vs previous 50MB)

```
Main Access Log:   50MB × 20 files = 1GB    (30-day retention)
Admin Access Log:  25MB × 30 files = 750MB  (90-day retention)
Auth Attempts Log: 25MB × 30 files = 750MB  (90-day retention)
Security Log:      10MB × 50 files = 500MB  (180-day retention)
```

### Structured JSON Logging

All logs use structured JSON format for easy parsing:

```json
{
  "level": "info",
  "ts": "2024-11-10T14:30:15.123Z",
  "request": {
    "remote_ip": "1.2.3.4",
    "remote_port": "54321",
    "client_ip": "1.2.3.4",
    "proto": "HTTP/2.0",
    "method": "POST",
    "host": "vault.example.com",
    "uri": "/api/accounts/prelogin",
    "headers": {
      "User-Agent": ["..."],
      "Cf-Connecting-Ip": ["1.2.3.4"]
    }
  },
  "duration": 0.123,
  "status": 401
}
```

### Log Locations

```bash
# VaultWarden application logs
${PROJECT_STATE_DIR}/logs/vaultwarden/vaultwarden.log

# Caddy logs (multiple specialized logs)
${PROJECT_STATE_DIR}/logs/caddy/access.log
${PROJECT_STATE_DIR}/logs/caddy/admin_access.log
${PROJECT_STATE_DIR}/logs/caddy/auth_attempts.log
${PROJECT_STATE_DIR}/logs/caddy/security.log

# Fail2Ban logs
${PROJECT_STATE_DIR}/logs/fail2ban/fail2ban.log

# msmtpd logs
${PROJECT_STATE_DIR}/logs/msmtpd/msmtpd.log
```

## Emergency Access

### Break-Glass Admin Account

A dedicated emergency admin account for OCI serial console access:

#### Features
- Separate non-root user with sudo privileges
- SSH key authentication for normal access
- Password authentication enabled ONLY for OCI console
- Secure credential generation
- Comprehensive audit logging

#### Creating Break-Glass Admin

```bash
# Create emergency admin
./create-breakglass-admin.sh

# Or use Makefile
make breakglass-create

# Check status
./create-breakglass-admin.sh --status
make breakglass-status
```

#### Using Break-Glass Admin

**Scenario**: Locked out of SSH (firewall issue)

1. Access OCI Console → Compute → Instance → Console Connection
2. Create console connection if not exists
3. Launch Cloud Shell connection
4. Login with break-glass admin credentials
5. Fix the issue (e.g., `sudo ufw allow 22/tcp`)
6. Verify SSH access restored
7. **CRITICAL**: Delete console connection
8. Rotate break-glass admin password

#### Security Considerations

- ✅ Only use for emergencies
- ✅ Delete console connection immediately after use
- ✅ Rotate password after each use
- ✅ Monitor audit logs for unauthorized access
- ✅ Validate break-glass admin security quarterly

## Backup Security

### Encrypted Backups

All backups are encrypted with Age:

```bash
# Backup process
1. Create database snapshot (atomic operation)
2. Verify integrity (SQLite integrity check)
3. Encrypt with Age (recipient: age public key)
4. Store encrypted backup
5. Verify encryption successful
6. Cleanup temporary files securely
```

### Backup Verification

```bash
# Quick verification (checksum-based)
./backup.sh --type db

# Full verification (end-to-end recoverability test)
./backup.sh --type full --full-verification

# Verification process:
1. Decrypt backup
2. Extract contents
3. Verify database integrity
4. Confirm all files present
5. Cleanup test environment
```

### Remote Backup Security

```bash
# Configure encrypted remote storage
rclone config

# Backup with remote sync
./backup.sh --type db --rclone

# Security features:
# - Encrypted BEFORE upload
# - TLS in transit to remote
# - Age encryption at rest
# - Access token secured in rclone config
```

## Security Monitoring

### Health Checks

```bash
# Comprehensive security health check
./health.sh

# Checks include:
# - All containers running
# - Resource usage within limits
# - Fail2ban operational
# - Cloudflare API accessible
# - Secrets properly encrypted
# - Firewall rules correct
# - No security misconfigurations
```

### Monitoring Fail2Ban

```bash
# Check ban status
docker compose exec fail2ban fail2ban-client status

# View recent bans
docker compose exec fail2ban fail2ban-client status vaultwarden-auth

# Check Cloudflare integration
docker compose logs fail2ban | grep -i cloudflare

# View banned IPs
docker compose exec fail2ban fail2ban-client get vaultwarden-auth banip
```

### Log Analysis

```bash
# View authentication failures
cat ${PROJECT_STATE_DIR}/logs/caddy/auth_attempts.log | jq 'select(.status == 401)'

# View admin panel access
cat ${PROJECT_STATE_DIR}/logs/caddy/admin_access.log | jq

# View security events
cat ${PROJECT_STATE_DIR}/logs/caddy/security.log | jq 'select(.status >= 400)'

# Analyze VaultWarden logs
grep "ERROR" ${PROJECT_STATE_DIR}/logs/vaultwarden/vaultwarden.log
```

## Security Best Practices

### Initial Setup
- ✅ Generate strong bcrypt hash for admin basic auth
- ✅ Use separate Cloudflare API tokens (DNS and Firewall)
- ✅ Enable Cloudflare proxy (orange cloud) for DNS record
- ✅ Configure HTTPS-only redirect at Cloudflare
- ✅ Enable Cloudflare WAF managed rules
- ✅ Set up break-glass admin immediately
- ✅ Test emergency access procedures
- ✅ Create initial encrypted backup
- ✅ Configure email notifications
- ✅ Verify all health checks pass

### Ongoing Operations
- ✅ Monitor Fail2Ban logs weekly
- ✅ Review Cloudflare analytics monthly
- ✅ Test backup restoration monthly
- ✅ Rotate secrets annually
- ✅ Update containers weekly (automated)
- ✅ Review firewall rules quarterly
- ✅ Test emergency procedures quarterly
- ✅ Monitor resource usage monthly
- ✅ Review forensic logs for incidents
- ✅ Keep break-glass admin credentials secure

### Incident Response

If you detect suspicious activity:

1. **Immediate Actions**:
   ```bash
   # Check Fail2Ban status
   docker compose exec fail2ban fail2ban-client status

   # Review recent bans
   docker compose logs fail2ban --tail=100

   # Check for unauthorized access
   grep "401\|403\|404" ${PROJECT_STATE_DIR}/logs/caddy/access.log
   ```

2. **Analysis**:
   ```bash
   # Analyze authentication failures
   cat ${PROJECT_STATE_DIR}/logs/caddy/auth_attempts.log | jq

   # Check admin panel access
   cat ${PROJECT_STATE_DIR}/logs/caddy/admin_access.log | jq

   # Review VaultWarden logs
   tail -n 500 ${PROJECT_STATE_DIR}/logs/vaultwarden/vaultwarden.log
   ```

3. **Response**:
   ```bash
   # Manual ban if needed (Cloudflare)
   # Use Cloudflare dashboard → Security → WAF → Tools
   # Add IP to IP Access Rules → Block

   # Emergency: Disable user accounts
   # Access admin panel → Users → Disable

   # Create incident backup
   ./backup.sh --type emergency
   ```

4. **Recovery**:
   ```bash
   # If compromised, rotate all secrets
   ./edit-secrets.sh

   # Update admin token and hash
   # Restart services
   ./startup.sh --force-restart

   # Verify security
   ./health.sh
   ```

## Security Troubleshooting

### Cloudflare API Issues

```bash
# Test DNS token
curl -X GET "https://api.cloudflare.com/client/v4/zones" \
     -H "Authorization: Bearer YOUR_DNS_TOKEN" \
     -H "Content-Type: application/json"

# Test Firewall token
curl -X GET "https://api.cloudflare.com/client/v4/zones/ZONE_ID/firewall/access_rules/rules" \
     -H "Authorization: Bearer YOUR_FIREWALL_TOKEN" \
     -H "Content-Type: application/json"
```

### Fail2Ban Not Blocking

```bash
# Check Cloudflare action is configured
docker compose exec fail2ban cat /data/fail2ban/action.d/cloudflare-apiv4.conf

# Verify zone ID and token
docker compose exec fail2ban env | grep CF_

# Test filter regex
docker compose exec fail2ban fail2ban-regex \
  /var/log/vaultwarden/vaultwarden.log \
  /data/fail2ban/filter.d/vaultwarden-auth.conf

# Check for errors
docker compose logs fail2ban | grep -i error
```

### Email Notifications Not Working

```bash
# Check msmtpd container
docker compose logs msmtpd

# Test email manually
./test-email-simple.sh --verbose

# Verify SMTP settings
grep SMTP .env

# Check secrets
./edit-secrets.sh --test
```

## Compliance and Hardening

### CIS Docker Benchmark Alignment

- ✅ Containers run as non-root
- ✅ Capabilities dropped and minimally added
- ✅ Resource limits configured
- ✅ Security options enabled (no-new-privileges)
- ✅ Secrets not in environment variables
- ✅ Read-only filesystems where possible
- ✅ Minimal images used
- ✅ Health checks configured

### Additional Hardening

For additional security:

```bash
# Enable audit logging
sudo apt install auditd
sudo systemctl enable auditd

# Install additional security tools
sudo apt install aide rkhunter

# Configure automatic security updates
sudo apt install unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

---

This security guide reflects the current architecture with Cloudflare-only blocking for web traffic, local iptables for SSH, comprehensive resource management, enhanced forensic logging, and robust security practices optimized for small teams requiring enterprise-grade password management security.
