# Security Guide - VaultWarden-OCI

This comprehensive security guide covers the security architecture, hardening procedures, and operational security practices for VaultWarden-OCI with enhanced fail2ban security, template-based configuration, and emergency access capabilities.

## Security Architecture Overview

### Multi-Layer Defense Strategy

```
External Layer (Cloudflare)
├── Edge firewall and DDoS protection
├── Web Application Firewall (WAF)
├── Bot mitigation and rate limiting
└── SSL/TLS termination and proxy

Network Layer (Enhanced UFW + Cloud Security)
├── Host-based firewall (UFW) with improved warnings
├── Cloudflare IP restriction (only CF traffic allowed)
├── Enhanced fail2ban with rate limiting and error handling
└── SSH hardening and port management

Application Layer (Template-Based Containers)
├── VaultWarden application security
├── Caddy reverse proxy with security headers
├── Enhanced fail2ban intrusion prevention with rate limiting
└── Template-based container isolation and resource limits

Data Layer (Enhanced Encryption)
├── Database encryption at rest
├── Atomic backup encryption with Age
├── Template-based secrets management with SOPS
├── SSL/TLS for data in transit
└── Admin authentication with bcrypt

Recovery Layer (Break-Glass Access)
├── Emergency admin account for OCI serial console
├── OCI serial console access integration
├── Enhanced encrypted backup recovery procedures
└── Template-based disaster recovery documentation

Template Control Layer
├── Template-based configuration management
├── Source of truth in .example files
├── Controlled deployment via setup.sh
└── Version control friendly security configurations
```

## Core Security Components

### 1. Enhanced Network Security

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

#### Enhanced UFW Firewall Configuration
```bash
# Restrictive firewall with improved warning system
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

# Enhanced rules management with improved error handling:
sudo ./update-cloudflare-ips.sh
```

#### Enhanced fail2ban Integration with Cloudflare

The enhanced fail2ban system now includes comprehensive rate limiting and error handling for optimal security without API abuse:

**Enhanced Features:**
- **Rate Limiting**: Maximum 30 API calls per minute with intelligent backoff
- **Comprehensive Error Handling**: Graceful failure recovery and detailed logging
- **No More API Abuse**: Prevents hanging requests and API token exhaustion
- **Enhanced Logging**: Detailed logging for security analysis and troubleshooting

**Benefits of Enhanced Edge Blocking:**
- **Resource Conservation**: Attack traffic stopped at Cloudflare's edge with rate-limited API calls
- **Global Protection**: Cloudflare's network provides worldwide coverage with enhanced threat intelligence
- **Reduced Server Load**: Your server doesn't process malicious requests, preserving CPU and bandwidth
- **Enhanced Reliability**: Rate limiting prevents fail2ban service disruption due to API limits
- **Improved Monitoring**: Better logging and error handling for security incident analysis

### 2. Template-Based Application Security

#### VaultWarden Security Configuration
```bash
# Core Security Settings (in template-generated .env):
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

### 3. Enhanced Data Encryption and Secrets Management

#### Encryption at Rest
```bash
# VaultWarden Database:
- SQLite database with application-level encryption
- Sensitive data encrypted before storage
- Master key derived from user passwords

# Enhanced Backup Encryption with Atomic Operations:
- All backups encrypted with Age (ChaCha20-Poly1305)
- 256-bit encryption keys
- Authenticated encryption prevents tampering
- Atomic operations prevent corruption during encryption

# Template-Based Secrets Management:
- SOPS + Age for structured secrets encryption
- Ed25519 public key cryptography
- Secrets never stored unencrypted on disk
- Template-based secrets configuration for consistency
```

### 4. Enhanced Emergency Access Security

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

#### Enhanced Serial Console Security
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
- Rotate password quarterly using ./create-breakglass-admin.sh password
- Test access annually (without causing disruption)

# Monitoring:
- Log all break-glass account usage
- Alert on any break-glass account activity
- Review break-glass access in security audits
- Monitor for unauthorized console connections

# Security Cleanup After Use:
- Change break-glass password: ./create-breakglass-admin.sh password
- Document reason for emergency access
- Review and fix root cause of access need
- Delete Console Connection in OCI Console for security
- Consider temporary account disabling if not needed
```

### 5. Template-Based Security Management

#### Secure Template Configuration
```bash
# Template Security Benefits:
- No hardcoded credentials in generated files
- Consistent security configurations across deployments
- Version control safe templates
- Single source of truth for security settings

# Template Security Validation:
docker compose config  # Validate template-generated configuration
./edit-secrets.sh --test  # Verify secrets accessibility

# Template Update Security:
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com
# Maintains security settings while updating configuration
```

## Enhanced Security Hardening Procedures

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

#### Enhanced Application Level Security
```bash
# 1. Generate strong secrets with template validation
./edit-secrets.sh

# 2. Configure restrictive firewall with enhanced error handling
sudo ./update-cloudflare-ips.sh

# 3. Enable comprehensive monitoring
./health.sh --comprehensive

# 4. Setup break-glass admin for emergency access
./create-breakglass-admin.sh

# 5. Validate template-based configuration
docker compose config

# 6. Create initial backup with atomic operations
./backup.sh --type emergency

# 7. Validate enhanced security configuration
./health.sh --comprehensive
```

### Ongoing Security Maintenance

#### Daily Automated Tasks
```bash
# Via cron-setup.sh automation:
- Health monitoring with auto-heal
- Enhanced security log analysis
- Enhanced fail2ban monitoring with rate limiting
- Atomic backup integrity verification
- Break-glass admin status verification
```

#### Weekly Security Tasks
```bash
# 1. Review enhanced fail2ban logs with rate limiting analysis
docker compose logs fail2ban | grep -E "Ban|Unban|Rate" | tail -20

# 2. Check for security updates
sudo apt list --upgradable
docker compose pull --dry-run

# 3. Verify Cloudflare IP ranges are current with enhanced error handling
sudo ./update-cloudflare-ips.sh --dry-run

# 4. Review access logs for anomalies
docker compose logs caddy | grep -E "admin|error|403|404" | tail -20

# 5. Check break-glass admin status
./create-breakglass-admin.sh status
```

#### Monthly Security Tasks
```bash
# 1. Comprehensive security audit
./health.sh --comprehensive

# 2. Review container versions for security updates
docker compose pull --dry-run

# 3. Review and rotate secrets if needed
./edit-secrets.sh

# 4. Security-focused backup verification with atomic operations
./backup.sh --type emergency

# 5. Test break-glass admin access (status check only)
./create-breakglass-admin.sh status

# 6. Validate template-based security configuration
docker compose config

# 7. Review enhanced fail2ban rate limiting effectiveness
docker compose logs fail2ban | grep -i "rate\|limit\|error" | wc -l
```

#### Quarterly Security Tasks
```bash
# 1. Rotate encryption keys
./edit-secrets.sh --rotate-keys

# 2. Full security penetration test
# - Test for new vulnerabilities
# - Verify all security controls including enhanced fail2ban
# - Update security documentation

# 3. Disaster recovery test with template restoration
# - Test backup restoration: ./restore.sh --interactive
# - Verify break-glass admin access via OCI serial console
# - Test template-based recovery procedures

# 4. Security audit and compliance review
# - Review all access logs
# - Audit user accounts and permissions
# - Update security documentation
# - Review enhanced fail2ban rate limiting logs
# - Validate template-based security configurations
```

## Enhanced Threat Model and Mitigations

### External Threats

#### DDoS Attacks
**Threat**: Overwhelming server with traffic to cause service disruption
**Enhanced Mitigations**:
- Cloudflare DDoS protection at edge
- Rate limiting at application layer
- Enhanced fail2ban dynamic blocking with rate-limited edge integration
- Resource monitoring with auto-scaling (cloud provider)
- Comprehensive logging for attack analysis

#### Brute Force Attacks
**Threat**: Automated password guessing against admin or user accounts
**Enhanced Mitigations**:
- Strong password policies enforced
- Account lockout after failed attempts (enhanced fail2ban with rate limiting)
- Rate limiting on authentication endpoints
- IP-based blocking at Cloudflare edge with intelligent API usage
- Break-glass admin as recovery option
- Enhanced logging and monitoring

#### Application Vulnerability Exploitation
**Threat**: Exploitation of vulnerabilities in VaultWarden or dependencies
**Enhanced Mitigations**:
- Template-based configuration for consistent security
- Regular security updates (monitored and tested)
- Container isolation (Docker)
- Web Application Firewall (Cloudflare)
- Input validation and sanitization
- Enhanced monitoring and alerting

### Internal Threats

#### Compromised Administrative Access
**Threat**: Attacker gains admin credentials or SSH access
**Enhanced Mitigations**:
- Multi-factor authentication for admin panel
- SSH key-based authentication only
- Regular credential rotation
- Comprehensive audit logging with enhanced fail2ban
- Break-glass admin for recovery
- Template-based configuration control

#### Data Exfiltration
**Threat**: Unauthorized access to password database or user data
**Enhanced Mitigations**:
- Database encryption at rest
- Atomic encrypted backups with separate keys
- Network segmentation (container isolation)
- Access logging and monitoring
- Template-based security controls
- Enhanced fail2ban protection

### Template-Based Security

#### Configuration Tampering
**Threat**: Unauthorized modification of security configurations
**Enhanced Mitigations**:
- Template-based configuration management
- Source of truth in version-controlled .example files
- Controlled deployment via setup.sh
- Configuration validation before deployment
- Immutable security settings in templates

#### Security Drift
**Challenge**: Security configurations becoming inconsistent over time
**Enhanced Strategy**:
```bash
# Regular template-based security validation:
1. docker compose config                # Validate current configuration
2. sudo ./setup.sh --force --domain vault.example.com --email admin@example.com  # Reset to template
3. ./health.sh --comprehensive         # Verify security controls
4. ./create-breakglass-admin.sh status # Verify emergency access
```

## Enhanced Security Monitoring

### Real-Time Security Monitoring

#### Enhanced fail2ban Monitoring
```bash
# Monitor enhanced fail2ban with rate limiting
docker compose logs fail2ban --follow | grep -E "Ban|Unban|Rate|Error"

# Check fail2ban status with rate limiting information
docker compose exec fail2ban fail2ban-client status vaultwarden-admin

# Monitor rate limiting effectiveness
docker compose logs fail2ban | grep -i "rate" | tail -10
```

#### Security Log Analysis
```bash
# Comprehensive security log review
./health.sh --comprehensive --quiet --json > security-status.json

# Monitor break-glass admin activity
sudo journalctl -u ssh | grep "break-glass-admin"

# Review template-based configuration changes
git log --oneline -- "*.example"
```

### Security Alerting

#### Enhanced Alert Configuration
```bash
# Configure security alerts in health.sh
./health.sh --comprehensive --email-alert

# Monitor enhanced fail2ban alerts
docker compose logs fail2ban | grep -E "NOTICE|WARNING|ERROR"

# Template-based security validation alerts
docker compose config || echo "Template validation failed"
```

## Best Practices Summary

### Production Environment Security

1. **Template-Based Security**: Always use template-based configuration management
2. **Enhanced fail2ban**: Leverage rate limiting and error handling features
3. **Break-Glass Access**: Maintain emergency admin for OCI serial console access
4. **Atomic Backups**: Use enhanced backup operations with encryption
5. **Monitoring**: Enable comprehensive health and security monitoring
6. **Regular Updates**: Test all updates in development with template validation

### Security Maintenance Routine

#### Weekly (5 minutes)
```bash
./create-breakglass-admin.sh status
docker compose logs fail2ban | grep -E "Rate|Error" | tail -5
sudo ./update-cloudflare-ips.sh --dry-run
```

#### Monthly (15 minutes)
```bash
./health.sh --comprehensive
./backup.sh --type emergency
sudo ./update-cloudflare-ips.sh
docker compose config  # Validate template configuration
```

#### Quarterly (30 minutes)
```bash
./edit-secrets.sh --rotate-keys
# Test break-glass admin access via OCI console (status check)
# Review and update template-based security configurations
# Full security audit and documentation review
# Review enhanced fail2ban rate limiting effectiveness
```

## Security Incident Response

### Enhanced Incident Response Procedures

#### Security Incident Detection
```bash
# Enhanced monitoring for security incidents
./health.sh --comprehensive --json | jq '.security_status'
docker compose logs fail2ban | grep -E "CRITICAL|WARNING|Rate.*exceeded"
```

#### Incident Response with Break-Glass Access
```bash
# If SSH access compromised, use break-glass admin:
# 1. Access OCI Console → Instance → Console Connection
# 2. Login with break-glass admin credentials
# 3. Investigate and contain incident
# 4. Restore from atomic backup if needed: ./restore.sh --interactive
# 5. Update security configurations via templates
# 6. Delete Console Connection for security
# 7. Rotate break-glass password: ./create-breakglass-admin.sh password
```

#### Post-Incident Security Hardening
```bash
# Enhanced post-incident procedures
# 1. Create emergency backup: ./backup.sh --type emergency
# 2. Review enhanced fail2ban logs: docker compose logs fail2ban
# 3. Update template-based security configurations
# 4. Test break-glass admin access
# 5. Comprehensive security audit: ./health.sh --comprehensive
```

---

**Security Contact Information:**
- **Emergency Security Issues**: Document your emergency contact procedures
- **Security Audit Requests**: Maintain current security documentation
- **Vulnerability Reporting**: Follow responsible disclosure procedures
- **Break-Glass Access**: Keep emergency credentials secure and accessible

**Remember**: Security is an ongoing process enhanced by template-based configuration management, rate-limited fail2ban protection, and reliable emergency access capabilities. Regular monitoring, updates, and testing are essential for maintaining a secure VaultWarden deployment with comprehensive security controls.
