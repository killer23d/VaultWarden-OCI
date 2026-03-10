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
│   - Email Alerts via Postfix            │
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
# Fail2ban 1.1.0-r3 leverages iptables-legacy fallbacks to ensure compatibility
# with modern OS networking stacks (like Oracle Linux and Debian).
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

All web-facing jails use Cloudflare API exclusively:

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

SSH protection uses local iptables (direct connection). Fail2Ban runs with
`network_mode: host` to allow direct host iptables manipulation:

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
filter   = vaultwarden-web-auth
maxretry = 10

[vaultwarden-web-admin]
logpath  = /var/log/caddy/admin_access.log   # 750MB retention
maxretry = 5
```

### Email Notifications via Postfix

Email alerts are sent via the containerised Postfix relay (`bokysan/docker-postfix`,
port 587). Fail2Ban uses `network_mode: host` and therefore reaches Postfix
at `127.0.0.1:587`:

```ini
# All jails include email notifications
action = smtp[name=jail_name, dest="admin@example.com", sender="fail2ban@domain.com"]
         cloudflare-apiv4  # or iptables-multiport for SSH
```

Benefits:
- ✅ No host dependencies (mailutils not required)
- ✅ Consistent SMTP configuration via a single Postfix relay
- ✅ Dedicated container logs for troubleshooting (`docker compose logs postfix`)
- ✅ Resource-efficient (256MB memory limit, 0.1 CPU)

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

The maintenance script applies new Cloudflare IP ranges **before** removing
old ones to eliminate race conditions:

```bash
# Safe update (targeted mode — skips routine cleanup)
./maintenance.sh --update-firewall

# Features:
# 1. Fetches current Cloudflare IPv4 + IPv6 ranges
# 2. Adds new rules BEFORE removing old ones
# 3. Validates ranges with regex before applying
# 4. Falls back safely if API fails
# 5. Comprehensive logging of all changes
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

  # postfix uses container-default user; fail2ban uses host networking
```

### Capability Restrictions

Containers drop all capabilities and only add the minimum required:

```yaml
vaultwarden:
  cap_drop:
    - ALL
  # No additional capabilities

caddy:
  cap_drop:
    - ALL
  cap_add:
    - NET_BIND_SERVICE  # Required for ports 80/443

postfix:
  cap_drop:
    - ALL
  cap_add:
    - CHOWN              # Mail queue ownership
    - SETUID             # User switching
    - SETGID             # Group switching
    - NET_BIND_SERVICE   # Port 587
    - DAC_OVERRIDE       # Spool permission overrides (REQUIRED)
    - FOWNER             # Spool file ownership (REQUIRED)

fail2ban:
  # network_mode: host — no cap_drop (host network namespace)
  cap_add:
    - NET_ADMIN  # Required for iptables manipulation
    - NET_RAW    # Required for network monitoring
```

### Resource Limits

Prevents resource exhaustion attacks. Values are tightly optimised:

```yaml
vaultwarden:
  deploy:
    resources:
      limits:
        memory: 512M
        cpus: '0.3'
      reservations:
        memory: 128M
        cpus: '0.1'

caddy:
  deploy:
    resources:
      limits:
        memory: 512M
        cpus: '0.25'
      reservations:
        memory: 128M
        cpus: '0.1'

fail2ban:
  deploy:
    resources:
      limits:
        memory: 512M
        cpus: '0.15'
      reservations:
        memory: 128M
        cpus: '0.05'

postfix:
  deploy:
    resources:
      limits:
        memory: 256M
        cpus: '0.1'
        pids: 50
      reservations:
        memory: 64M
        cpus: '0.02'
```

### Security Options

```yaml
security_opt:
  - no-new-privileges:true
```

Applied to all containers. Prevents privilege escalation within containers.

### Log Rotation (Docker Driver)

All runtime containers cap their Docker json-file logs at the driver level
to prevent disk fill:

```yaml
logging:
  driver: "json-file"
  options:
    max-size: "20m"   # caddy: 20m × 5 = 100MB worst-case
    max-file: "5"
# vaultwarden: 10m × 5 = 50MB
# postfix:      5m × 3 = 15MB
# fail2ban:     5m × 3 = 15MB
```

## Application Security

### Admin Panel Protection

Two-factor protection for the admin panel:

1. **Caddy Basic Authentication** (bcrypt hash from secrets):
```caddyfile
route /admin* {
    import admin_basic_auth
    reverse_proxy vaultwarden:80
}
```

2. **Admin Token** (stored in encrypted secrets):
```yaml
admin_token: "32-character-hex-string"
```

### Rate Limiting (Cloudflare WAF)

Cloudflare WAF rules must be configured manually in the Cloudflare dashboard:

| Rule | Path | Limit | Action |
|---|---|---|---|
| Auth endpoint protection | `/identity/connect/token*`, `/api/accounts/prelogin*` | 10 req / 1 min per IP | Block (429) |
| Admin panel protection | `/admin*` | 5 req / 1 min per IP | Block (429) |
| General API protection (optional) | `/api/*` | 100 req / 1 min per IP | Managed Challenge |

### Security Headers

The following hardened security headers are enforced in the Caddyfile:

```caddyfile
header {
    # HSTS with preload
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"

    # Classic security headers
    X-Content-Type-Options "nosniff"
    X-Frame-Options "DENY"
    X-XSS-Protection "1; mode=block"
    Referrer-Policy "strict-origin-when-cross-origin"

    # Modern isolation headers (Spectre mitigation)
    Cross-Origin-Opener-Policy "same-origin"
    Cross-Origin-Resource-Policy "same-origin"
    Cross-Origin-Embedder-Policy "credentialless"
    X-DNS-Prefetch-Control "off"

    # Content Security Policy
    Content-Security-Policy "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' wss: https:; frame-src 'self'; object-src 'none'; base-uri 'self';"

    # Permissions Policy (restrict dangerous features)
    Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=(), usb=()"

    # Request tracking (response header)
    X-Request-ID {uuid}

    # Remove server identification
    -Server
    -X-Powered-By
}
```

## Forensic Logging

### 4-Log Forensic Architecture (~3 GB Total Capacity)

Caddy routes log output by named logger to dedicated files, preventing
double-firing across log categories and enabling per-category retention targets.

```
Main Access Log:   50MB × 20 files = 1GB    (30-day retention)   → access.log
Admin Access Log:  25MB × 30 files = 750MB  (90-day retention)   → admin_access.log
Auth Attempts Log: 25MB × 30 files = 750MB  (90-day retention)   → auth_attempts.log
Security Log:      10MB × 50 files = 500MB  (180-day retention)  → security.log
```

### Structured JSON Logging

All Caddy logs use structured JSON format for easy parsing:

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

# Caddy logs (4 specialised forensic logs)
${PROJECT_STATE_DIR}/logs/caddy/access.log        # General access (access_log)
${PROJECT_STATE_DIR}/logs/caddy/admin_access.log  # Admin panel traffic (admin_log)
${PROJECT_STATE_DIR}/logs/caddy/auth_attempts.log # Auth endpoints (auth_log)
${PROJECT_STATE_DIR}/logs/caddy/security.log      # Catch-all / suspicious (security_log)

# Fail2Ban logs
${PROJECT_STATE_DIR}/logs/fail2ban/fail2ban.log

# Postfix logs
${PROJECT_STATE_DIR}/logs/postfix/
docker compose logs postfix   # live container output
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
sudo ./create-breakglass-admin.sh --create

# Or use Makefile
make breakglass-create

# Check status
sudo ./create-breakglass-admin.sh --status
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
# Standard backup (checksum-based verification)
./backup.sh --type db

# Full backup with end-to-end recoverability test
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
# Basic health check (containers + service accessibility)
./health.sh

# Comprehensive check (adds disk, SSL, DB, backups, resources, config, security)
./health.sh --comprehensive

# With automatic recovery of unhealthy containers
./health.sh --auto-recover

# Full comprehensive check with email alert and auto-recovery
./health.sh --comprehensive --email --auto-recover
```

Checks performed:
- All containers running and healthy (`vaultwarden`, `caddy`, `fail2ban`, `postfix`)
- Local service accessibility on port 8080
- Disk space against configurable threshold (default 80%)
- SSL certificate expiry (warn < 30 days, critical < 7 days)
- Database size and growth rate
- Backup age and decryptability
- Resource usage (comprehensive mode)
- Configuration validity (comprehensive mode)
- Security status: Fail2Ban, Age key, SOPS config (comprehensive mode)

### Monitoring Fail2Ban

```bash
# Check ban status across all jails
docker compose exec fail2ban fail2ban-client status

# View specific jail bans
docker compose exec fail2ban fail2ban-client status vaultwarden-auth

# Check Cloudflare integration
docker compose logs fail2ban | grep -i cloudflare

# View banned IPs for a jail
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

# Analyse VaultWarden logs
grep "ERROR" ${PROJECT_STATE_DIR}/logs/vaultwarden/vaultwarden.log
```

## Security Best Practices

### Initial Setup
- ✅ Generate strong bcrypt hash for admin basic auth
- ✅ Use separate Cloudflare API tokens (DNS and Firewall)
- ✅ Enable Cloudflare proxy (orange cloud) for DNS record
- ✅ Configure HTTPS-only redirect at Cloudflare
- ✅ Enable Cloudflare WAF managed rules
- ✅ Configure WAF rate limiting rules (auth, admin, API)
- ✅ Set up break-glass admin immediately
- ✅ Test emergency access procedures
- ✅ Create initial encrypted backup
- ✅ Configure email notifications and run `make test-email`
- ✅ Verify all health checks pass: `./health.sh --comprehensive`

### Ongoing Operations
- ✅ Monitor Fail2Ban logs weekly
- ✅ Review Cloudflare analytics monthly
- ✅ Test backup restoration monthly
- ✅ Rotate secrets annually
- ✅ Update containers weekly (automated via cron)
- ✅ Review firewall rules quarterly
- ✅ Test emergency procedures quarterly
- ✅ Monitor resource usage monthly
- ✅ Review forensic logs for incidents
- ✅ Keep break-glass admin credentials secure
- ✅ Run `sudo ./cron-setup.sh --validate` after pulling repo updates

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
   # Analyse authentication failures
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
   ./startup.sh --force

   # Verify security
   ./health.sh --comprehensive
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

# Test filter regex against live log
docker compose exec fail2ban fail2ban-regex \
  /var/log/vaultwarden/vaultwarden.log \
  /data/fail2ban/filter.d/vaultwarden-auth.conf

# Check for errors
docker compose logs fail2ban | grep -i error
```

### Email Notifications Not Working

```bash
# Check postfix container status and logs
docker compose ps postfix
docker compose logs postfix          # live output
make logs-postfix                    # shortcut

# Run full email diagnostic (4 tests)
./maintenance.sh --test-email

# Verbose output for detailed diagnosis
./maintenance.sh --test-email --verbose

# Test with specific recipient
./maintenance.sh --test-email --recipient admin@example.com

# Preview without sending (dry-run)
./maintenance.sh --test-email --dry-run

# Verify SMTP settings in .env
grep -E 'SMTP|POSTFIX|ALLOWED_SENDER' .env

# Verify SMTP password in secrets
./edit-secrets.sh
```

## Compliance and Hardening

### CIS Docker Benchmark Alignment

- ✅ Containers run as non-root
- ✅ Capabilities dropped and minimally added
- ✅ Resource limits configured (memory, CPU, PIDs)
- ✅ Security options enabled (`no-new-privileges:true`)
- ✅ Secrets not in environment variables (Docker secrets via files)
- ✅ Docker json-file log rotation caps applied
- ✅ Minimal images used
- ✅ Health checks configured on all containers

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

This security guide reflects the current architecture with Cloudflare-only blocking for web traffic, local iptables for SSH (Fail2Ban in host-network mode), containerised Postfix email relay, comprehensive resource management, enhanced forensic logging, and robust security practices optimised for small teams requiring enterprise-grade password management security.
