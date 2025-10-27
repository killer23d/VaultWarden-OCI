# Security Guide - VaultWarden-OCI-Simplified

This comprehensive security guide covers the security architecture, hardening procedures, and operational security practices for VaultWarden-OCI-Simplified.

## Security Architecture Overview

### Multi-Layer Defense Strategy

```
External Layer (Cloudflare)
├── Edge firewall and DDoS protection
├── Web Application Firewall (WAF)
├── Bot mitigation and rate limiting
└── SSL/TLS termination and proxy

Network Layer (UFW + Cloud Security)
├── Host-based firewall (UFW)
├── Cloudflare IP restriction (only CF traffic allowed)
├── Cloud provider security groups
└── SSH hardening and port management

Application Layer (Containers)
├── VaultWarden application security
├── Caddy reverse proxy with security headers
├── fail2ban intrusion prevention
└── Container isolation and resource limits

Data Layer (Encryption)
├── Database encryption at rest
├── Backup encryption with Age
├── Secrets management with SOPS
├── SSL/TLS for data in transit
└── Admin authentication with bcrypt

Recovery Layer (Break-Glass Access)
├── Emergency admin account for serial console
├── OCI serial console access
├── Encrypted backup recovery procedures
└── Disaster recovery documentation

Version Control Layer
├── Container version pinning for stability
├── Controlled update procedures
├── Rollback capabilities
└── Security patch management
```

## Core Security Components

### 1. Network Security

#### Cloudflare Edge Protection
```bash
# Traffic Flow Security:
Internet → Cloudflare Edge → Your Server
         ↑
    [WAF, DDoS Protection, Bot Mitigation]

# Security Features Enabled:
- "I'm Under Attack Mode" available for DDoS
- Security Level: Medium (adjust based on needs)
- Bot Fight Mode: ON
- Browser Integrity Check: ON
- Challenge Passage: 30 minutes
```

#### UFW Firewall Configuration
```bash
# Restrictive firewall - only Cloudflare IPs allowed for web traffic
Default Policies:
- Incoming: DENY (default)
- Outgoing: ALLOW (default)
- Routed: DENY (default)

Allowed Traffic:
- SSH (port 22 or custom) from anywhere (or restrict to your IPs)
- HTTP (port 80) from Cloudflare IPs only
- HTTPS (port 443) from Cloudflare IPs only

# View current rules:
sudo ufw status numbered

# Rules are automatically managed by:
sudo ./update-cloudflare-ips.sh
```

#### fail2ban Integration with Cloudflare

Integrating fail2ban with Cloudflare's firewall actions ensures malicious IPs are blocked at the network edge, preventing attack traffic from consuming server resources. This is generally more efficient than relying solely on local firewall rules.

**Benefits of Edge Blocking:**
- **Resource Conservation**: Attack traffic is stopped at Cloudflare's edge before reaching your server
- **Global Protection**: Cloudflare's network provides worldwide coverage and threat intelligence
- **Reduced Server Load**: Your server doesn't process malicious requests, preserving CPU and bandwidth
- **Enhanced Logging**: Centralized threat visibility across Cloudflare's analytics dashboard

### 2. Application Security

#### VaultWarden Security Configuration
```bash
# Core Security Settings (in .env):
SIGNUPS_ALLOWED=false              # Disable open registration
SIGNUPS_VERIFY=true               # Require email verification
INVITATIONS_ALLOWED=true          # Admin-controlled invitations only
PASSWORD_ITERATIONS=600000        # High iteration count
SHOW_PASSWORD_HINT=false          # Don't show password hints

# Admin Security:
ADMIN_TOKEN_FILE=/run/secrets/admin_token    # Secure token storage
DISABLE_ADMIN_TOKEN=false                    # Keep admin token enabled

# Session Security:
SESSION_TIMEOUT=3600              # 1-hour session timeout
EXTENDED_LOGGING=true             # Enhanced audit logging
```

#### Caddy Security Headers

Caddy is configured with comprehensive security headers to protect against common web vulnerabilities:

```caddyfile
# Security headers applied to all responses:

# HTTPS Enforcement - Prevents downgrade attacks
Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"

# Content Protection
X-Content-Type-Options "nosniff"           # Prevents MIME type sniffing
X-Frame-Options "DENY"                     # Prevents clickjacking attacks
X-XSS-Protection "1; mode=block"           # Enables XSS filtering
Referrer-Policy "strict-origin-when-cross-origin"

# Content Security Policy - Mitigates XSS attacks
Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' wss: https:; frame-src 'self'; object-src 'none'; base-uri 'self';"

# Remove server identification - Security through obscurity
-Server
-X-Powered-By
```

**Security Header Benefits:**
- **Strict-Transport-Security (HSTS)**: Forces HTTPS connections and prevents downgrade attacks
- **Content-Security-Policy (CSP)**: Mitigates cross-site scripting (XSS) attacks by controlling resource loading
- **X-Frame-Options**: Prevents clickjacking by controlling iframe embedding
- **X-Content-Type-Options**: Prevents MIME type confusion attacks

### 3. Data Encryption and Secrets Management

#### Encryption at Rest
```bash
# VaultWarden Database:
- SQLite database with application-level encryption
- Sensitive data encrypted before storage
- Master key derived from user passwords

# Backup Encryption:
- All backups encrypted with Age (ChaCha20-Poly1305)
- 256-bit encryption keys
- Authenticated encryption prevents tampering

# Secrets Management:
- SOPS + Age for structured secrets encryption
- Ed25519 public key cryptography
- Secrets never stored unencrypted on disk
```

### 4. Emergency Access Security

#### Break-Glass Admin Account
```bash
# Purpose: Emergency access via OCI serial console when SSH fails
# Security Model: Controlled privilege escalation for recovery

# Account Properties:
- Separate user account (not root)
- Full sudo privileges (required for system repair)
- Password authentication (required for serial console)
- SSH key authentication (normal remote access)
- Comprehensive audit logging

# When to Use:
- UFW firewall misconfiguration blocks SSH
- SSH daemon configuration errors
- Primary admin account locked/corrupted
- Network connectivity issues preventing SSH
```

#### Serial Console Security
```bash
# Access Control:
- Requires OCI tenancy administrator privileges
- Requires console connection creation permissions
- Physical access control via cloud provider

# Authentication Factors:
1. OCI IAM authentication (cloud account access)
2. Instance console connection permissions  
3. Break-glass admin password (local account)

# Security Considerations:
- Console sessions are logged by OCI
- All commands executed are auditable
- Session timeout enforced by cloud provider
- No persistent access (session-based only)
```

#### Break-Glass Security Best Practices
```bash
# Account Management:
- Use strong, unique password (different from all other accounts)
- Document credentials in secure, offline location
- Rotate password quarterly
- Test access annually (without causing disruption)

# Monitoring:
- Log all break-glass account usage
- Alert on any break-glass account activity
- Review break-glass access in security audits
- Monitor for unauthorized console connections

# Cleanup:
- Change break-glass password after use
- Document reason for emergency access
- Review and fix root cause of access need
- Consider temporary account disabling if not needed
```

### 5. Version Control Security

#### Secure Update Management
```bash
# Version Pinning for Security:
- Pin production versions to prevent unexpected updates
- Control update timing for security patches
- Maintain rollback capability for failed updates

# Security Update Process:
1. Monitor security advisories for pinned versions
2. Test security updates in development environment
3. Apply critical security patches quickly via version unpinning
4. Re-pin to new secure versions after validation
```

#### Version Security Commands
```bash
# Check current versions for security assessment
make pins
docker compose ps --format "table {{.Service}}	{{.Image}}"

# Quick security patch deployment
make unpin SERVICE=vaultwarden  # Get latest security patch
make update-containers          # Apply immediately
make health                     # Verify security

# Re-pin after security validation
make pin SERVICE=vaultwarden VERSION=1.31.1  # Pin to patched version
```

## Security Hardening Procedures

### Initial Hardening Checklist

#### System Level Security
```bash
# 1. Update system packages
sudo apt update && sudo apt upgrade -y

# 2. Configure automatic security updates
sudo dpkg-reconfigure -plow unattended-upgrades

# 3. Harden SSH configuration
sudo nano /etc/ssh/sshd_config
# Key settings:
PermitRootLogin no
PasswordAuthentication no  # (after SSH keys configured)
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2

# 4. Configure system firewall (separate from VaultWarden UFW)
sudo ufw default deny incoming
sudo ufw default allow outgoing
```

#### Application Level Security
```bash
# 1. Generate strong secrets
make edit-secrets

# 2. Configure restrictive firewall
make update-ips

# 3. Enable comprehensive monitoring
make health

# 4. Setup break-glass admin
make breakglass-create

# 5. Pin production versions
make pin SERVICE=vaultwarden VERSION=1.30.5
make pin SERVICE=caddy VERSION=2.8.4

# 6. Create initial backup
make backup-emergency

# 7. Validate configuration
make config-check
```

### Ongoing Security Maintenance

#### Daily Automated Tasks
```bash
# Via cron-setup.sh automation:
- Health monitoring with auto-heal
- Security log analysis
- Failed login attempt monitoring
- Backup integrity verification
- Break-glass admin status verification
```

#### Weekly Security Tasks
```bash
# 1. Review fail2ban logs
docker compose logs fail2ban | grep -E "Ban|Unban" | tail -20

# 2. Check for security updates
make check-system-updates
make check-updates

# 3. Verify Cloudflare IP ranges are current
make update-ips --dry-run

# 4. Review access logs for anomalies
make logs SERVICE=caddy | grep -E "admin|error|403|404"

# 5. Check break-glass admin status
make breakglass-status
```

#### Monthly Security Tasks
```bash
# 1. Comprehensive security audit
make health

# 2. Review container versions for security updates
make check-updates

# 3. Review and rotate secrets if needed
make edit-secrets

# 4. Security-focused backup verification
make backup-emergency

# 5. Test break-glass admin access (status check only)
make breakglass-status

# 6. Review version pins for security patches
make pins
```

#### Quarterly Security Tasks
```bash
# 1. Rotate encryption keys
./edit-secrets.sh --rotate-keys

# 2. Full security penetration test
# - Test for new vulnerabilities
# - Verify all security controls
# - Update security documentation

# 3. Disaster recovery test
# - Test backup restoration: make restore
# - Verify break-glass admin access
# - Test OCI serial console access

# 4. Security audit and compliance review
# - Review all access logs
# - Audit user accounts and permissions
# - Update security documentation
# - Review version management security
```

## Threat Model and Mitigations

### External Threats

#### DDoS Attacks
**Threat**: Overwhelming server with traffic to cause service disruption
**Mitigations**:
- Cloudflare DDoS protection at edge
- Rate limiting at application layer
- fail2ban dynamic blocking with edge integration
- Resource monitoring with auto-scaling (cloud provider)

#### Brute Force Attacks
**Threat**: Automated password guessing against admin or user accounts
**Mitigations**:
- Strong password policies enforced
- Account lockout after failed attempts (fail2ban)
- Rate limiting on authentication endpoints
- IP-based blocking at Cloudflare edge
- Break-glass admin as recovery option

#### Application Vulnerability Exploitation
**Threat**: Exploitation of vulnerabilities in VaultWarden or dependencies
**Mitigations**:
- Version pinning with controlled updates
- Regular security updates (monitored and tested)
- Container isolation (Docker)
- Web Application Firewall (Cloudflare)
- Input validation and sanitization

### Internal Threats

#### Compromised Administrative Access
**Threat**: Attacker gains admin credentials or SSH access
**Mitigations**:
- Multi-factor authentication for admin panel
- SSH key-based authentication only
- Regular credential rotation
- Comprehensive audit logging
- Break-glass admin for recovery
- Version control to rollback malicious changes

#### Data Exfiltration
**Threat**: Unauthorized access to password database or user data
**Mitigations**:
- Database encryption at rest
- Encrypted backups with separate keys
- Network segmentation (container isolation)
- Access logging and monitoring
- Version pinning to prevent supply chain attacks

### Version Management Security

#### Supply Chain Attacks
**Threat**: Malicious code in container image updates
**Mitigations**:
- Version pinning prevents automatic malicious updates
- Controlled update process with testing
- Image verification before deployment
- Rollback capability for compromised versions

#### Security Patch Management
**Challenge**: Balancing security patches with stability
**Strategy**:
```bash
# Emergency security patch workflow:
1. make unpin SERVICE=[service]     # Allow latest for critical patch
2. make update-containers           # Apply patch immediately
3. make health                      # Verify system integrity
4. make pin SERVICE=[service] VERSION=[ver] # Re-pin to patched version
```

## Best Practices Summary

### Production Environment Security

1. **Version Management**: Always pin container versions in production
2. **Access Control**: Use break-glass admin for emergency access only
3. **Monitoring**: Enable comprehensive health and security monitoring
4. **Updates**: Test all updates in development before production
5. **Backups**: Maintain encrypted backups with regular restoration tests

### Security Maintenance Routine

#### Weekly (5 minutes)
```bash
make breakglass-status
make check-updates
make logs SERVICE=fail2ban | tail -10
```

#### Monthly (15 minutes)
```bash
make health
make backup-emergency
make update-ips
```

#### Quarterly (30 minutes)
```bash
make edit-secrets --rotate-keys
# Test break-glass admin access via OCI console
# Review and update version pins for security
# Full security audit and documentation review
```

---

**Security Contact Information:**
- **Emergency Security Issues**: Document your emergency contact procedures
- **Security Audit Requests**: Maintain current security documentation
- **Vulnerability Reporting**: Follow responsible disclosure procedures
- **Break-Glass Access**: Keep emergency credentials secure and accessible

**Remember**: Security is an ongoing process, not a one-time setup. Regular monitoring, updates, and testing are essential for maintaining a secure VaultWarden deployment with proper emergency access capabilities.
