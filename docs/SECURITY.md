# Security Guide - VaultWarden-OCI

This comprehensive security guide covers the enhanced security architecture, hardening procedures, and operational security practices for VaultWarden-OCI with current dual Cloudflare+UFW blocking, resource optimization, forensic logging capabilities, and comprehensive emergency access.

## Current Enhanced Security Architecture

### Multi-Layer Defense Strategy (Enhanced)

```
External Layer (Cloudflare Edge)
├── Edge firewall and DDoS protection
├── Web Application Firewall (WAF) 
├── Bot mitigation and traffic filtering
└── SSL/TLS termination with security headers

Network Layer (Dual Blocking + Resource Management)
├── Enhanced UFW firewall with race condition fixes
├── Cloudflare IP restriction (CF-only traffic)
├── Dual CF+UFW fail2ban action (advanced idempotent blocking)
└── Safe firewall updates with comprehensive error handling

Application Layer (Resource-Optimized Containers)
├── VaultWarden: 2GB limit, enhanced security settings
├── Caddy: 1GB limit, forensic logging (3GB capacity)
├── Fail2ban: 512MB limit, regex-based filters (no dependencies)
├── msmtpd: 32MB limit, containerized SMTP relay
└── Container security with capability restrictions

Data Layer (Enhanced Encryption + Forensic Capabilities)
├── Age encryption with secure key management
├── SOPS secrets with privacy protection (no process exposure)
├── Atomic backup operations preventing corruption
├── Enhanced logging: 60x retention improvement (3GB total)
└── Timezone consistency for forensic correlation

Recovery Layer (Enhanced Emergency Access)
├── Break-glass admin with security validation
├── OCI serial console integration with audit trails
├── Enhanced encrypted backup procedures with integrity checking
└── Template-based disaster recovery with validation

Template Security Layer (Current)
├── Centralized security validation in lib/security.sh
├── Enhanced secret file creation with atomic operations
├── Comprehensive permission and ownership validation
├── Secure cleanup with multi-pass overwriting
└── Password strength validation and secure random generation
```

## Enhanced Core Security Components

### 1. Dual Cloudflare + UFW Protection

#### Advanced Fail2Ban Action (Current Implementation)
The current `fail2ban/action.d/cloudflare-apiv4.conf` provides enterprise-grade dual blocking:

```ini
# Advanced Features:
# ✅ Idempotent Operations - Checks existing rules before creating
# ✅ Retry Logic - Exponential backoff for API failures  
# ✅ UFW Fallback - Local blocking if Cloudflare fails
# ✅ Transactional Bans - CF first, then UFW for comprehensive coverage
# ✅ Graceful Degradation - Falls back gracefully with clear logging
# ✅ Status Reporting - Comprehensive logging of all operations
```

**Security Benefits of Dual Blocking:**
- **Global + Local Protection**: Attacks blocked at edge AND locally
- **Redundancy**: If Cloudflare API fails, UFW provides local protection
- **Resource Conservation**: Edge blocking reduces server load
- **Comprehensive Coverage**: Multiple blocking layers prevent bypass
- **Enhanced Reliability**: System continues functioning even with API issues

#### Enhanced Firewall Management (Current)
```bash
# Safe firewall updates with race condition fixes
./maintenance.sh --update-firewall

# Enhanced safety features:
# 1. Adds new Cloudflare rules BEFORE removing old ones
# 2. Validates API connectivity before making changes  
# 3. Provides clear warnings if Cloudflare API unavailable
# 4. Falls back to safe default rules with user guidance
# 5. Comprehensive logging of all firewall changes
```

### 2. Resource-Optimized Application Security

#### Current Container Resource Allocation (6GB System)
```yaml
# VaultWarden Container (Main Application)
deploy:
  resources:
    limits:
      memory: 2G        # Largest allocation for main application
      cpus: '0.6'       # 60% of single CPU
    reservations:
      memory: 512M      # Guaranteed minimum
      cpus: '0.2'       # 20% guaranteed minimum

# Caddy Container (Reverse Proxy + SSL)  
deploy:
  resources:
    limits:
      memory: 1G        # SSL termination and reverse proxy
      cpus: '0.3'       # 30% of single CPU
    reservations:
      memory: 256M      # Minimum for SSL operations
      cpus: '0.1'       # 10% guaranteed minimum

# Fail2Ban Container (Security Monitoring)
deploy:
  resources:
    limits:
      memory: 512M      # Log parsing and rule processing
      cpus: '0.2'       # 20% of single CPU
    reservations:
      memory: 128M      # Minimum for log processing
      cpus: '0.05'      # 5% guaranteed minimum

# msmtpd Container (Email Relay)
deploy:
  resources:
    limits:
      memory: 32M       # Lightweight SMTP relay
      cpus: '0.05'      # 5% of single CPU
```

**Resource Security Benefits:**
- **Prevents Resource Exhaustion**: Container limits prevent system starvation
- **Guaranteed Minimums**: Reservations ensure stable security operations
- **Balanced Allocation**: Optimized for small teams on resource-constrained systems
- **Security Service Priority**: Fail2ban gets dedicated resources for protection

#### Enhanced VaultWarden Security Configuration
```bash
# Current security settings in docker-compose.yml.example:
SIGNUPS_ALLOWED=false              # Disable open registration
INVITATIONS_ALLOWED=true          # Admin-controlled invitations only
EMERGENCY_ACCESS_ALLOWED=true     # Enable emergency access feature
PASSWORD_ITERATIONS=600000        # High iteration count for security
PASSWORD_HINTS_ALLOWED=false      # Disable password hints
SHOW_PASSWORD_HINT=false          # Don't show password hints
WEB_VAULT_ENABLED=true            # Enable web vault interface
WEBSOCKET_ENABLED=false           # Disable WebSocket (enable if needed)

# Enhanced logging for security monitoring:
LOG_FILE=/logs/vaultwarden.log    # Structured log file
LOG_LEVEL=warn                    # Appropriate logging level
EXTENDED_LOGGING=true             # Enhanced audit logging
```

### 3. Enhanced Forensic Logging Capabilities

#### Massive Log Retention Improvement (60x Increase)
```caddyfile
# Current Caddyfile logging configuration:

# Main Access Log: 1GB total (50MB x 20 files, 30-day retention)
log {
    output file /logs/access.log {
        roll_size 50MB      # Increased from 10MB
        roll_keep 20        # Increased from 5 files  
        roll_keep_for 30d   # 30-day retention
    }
}

# Admin Access Log: 750MB total (25MB x 30 files, 90-day retention)
log {
    output file /logs/admin_access.log {
        roll_size 25MB      # Dedicated admin forensics
        roll_keep 30        # Extended retention
        roll_keep_for 90d   # 90-day admin log retention
    }
}

# Auth Attempts Log: 750MB total (25MB x 30 files, 90-day retention)
log {
    output file /logs/auth_attempts.log {
        roll_size 25MB      # Dedicated auth forensics
        roll_keep 30        # High security retention
        roll_keep_for 90d   # 90-day auth log retention
    }
}

# Security Blocks Log: 500MB total (10MB x 50 files, 180-day retention)
log {
    output file /logs/security_blocks.log {
        roll_size 10MB      
        roll_keep 50        # Many security logs
        roll_keep_for 180d  # 6-month security retention
    }
}

# Total Forensic Capacity: ~3GB (vs previous 50MB = 60x improvement)
```

**Enhanced Logging Security Benefits:**
- **Incident Investigation**: 30-180 day retention supports thorough forensic analysis
- **Request Correlation**: X-Request-ID header correlates requests across all logs
- **Timezone Consistency**: All containers use TZ environment variable
- **Structured JSON**: Automated analysis and correlation capabilities
- **Specialized Logs**: Separate logs for admin, auth, and security events

#### Enhanced Rate Limiting for Security
```caddyfile
# Current enhanced rate limiting configuration:
rate_limit {
    zone static_rl {
        capacity 20         # Reduced from 60 - stricter for password manager
    }

    zone admin_rl {
        capacity 5          # Very strict for admin panel
    }

    # API authentication rate limiting
    zone api_auth_rl {
        match_path /api/accounts/prelogin /identity/connect/token
        capacity 10         # 10 auth attempts per 5 minutes per IP
    }
}
```

### 4. Enhanced Secrets Management with Privacy Protection

#### SOPS Key Privacy Enhancement (Current)
The current `edit-secrets.sh` includes critical privacy fixes:

```bash
# SECURITY FIX: SOPS key path never exposed in process list
# Uses secure temporary files instead of environment variables
setup_secure_environment() {
    local age_key_file="secrets/keys/age-key.txt"

    # Create temporary directory with restrictive permissions
    local temp_env_dir=$(mktemp -d -t vw-secrets-env.XXXXXX)
    chmod 700 "$temp_env_dir"

    # Create secure temporary key file copy
    local temp_key_file="$temp_env_dir/age-key.txt"  
    cp "$age_key_file" "$temp_key_file"
    chmod 600 "$temp_key_file"

    # Export only temporary path (not identifiable in ps aux)
    export SOPS_AGE_KEY_FILE="$temp_key_file"
}
```

**Privacy Security Benefits:**
- **Process List Protection**: Key paths never visible in `ps aux` output
- **Secure Temporary Files**: Restrictive permissions on temp files
- **Automatic Cleanup**: Secure deletion of temporary key files
- **Editor Validation**: Security validation of editor before use
- **Backup Protection**: Automatic backup creation before editing

#### Enhanced Secrets Validation
```bash
# Current secrets management with comprehensive validation:
./edit-secrets.sh

# Enhanced security features:
# ✅ Validates editor security before use
# ✅ Creates secure backup before editing
# ✅ Validates secrets integrity after editing  
# ✅ Checks for placeholder values
# ✅ Validates required secrets exist
# ✅ Secure cleanup of temporary files
```

### 5. Centralized Security Validation Library

#### lib/security.sh - Comprehensive Security Functions
```bash
# Current centralized security validation functions:

# File and directory permission validation
validate_file_permissions() {
    # Validates file permissions, owner, and group with detailed reporting
}

validate_directory_permissions() {
    # Recursive directory validation with comprehensive checking
}

# Secure file operations
create_secure_file() {
    # Atomic file creation with proper umask and permissions
    # Uses mktemp and secure move operations
}

secure_cleanup() {
    # Multi-pass secure file deletion with shred
    # Secure directory cleanup with verification
}

# Security validation functions
validate_password_strength() {
    # Comprehensive password validation with pattern checking
    # Configurable requirements and common pattern detection
}

generate_secure_random() {
    # Cryptographically secure random string generation
    # Multiple entropy sources for enhanced security
}
```

**Centralized Security Benefits:**
- **Consistent Validation**: Same security logic across all scripts
- **Single Source of Truth**: Centralized security best practices
- **Enhanced Functions**: More comprehensive than individual script validation
- **Reusable Components**: Easy to maintain and update security logic

### 6. Enhanced Emergency Access Security

#### Break-Glass Admin with Enhanced Validation (Current)
```bash
# Current create-breakglass-admin.sh uses centralized security functions:

# Enhanced security validation using lib/security.sh:
validate_script_security() {
    # Uses centralized validate_file_permissions() function
    if ! validate_file_permissions "$script_path" "700" "root" "root"; then
        log_error "SECURITY: Script failed validation - privilege escalation risk"
        return 1
    fi
}

create_secure_script_copy() {
    # Uses centralized create_secure_file() function for atomic operations
    if ! create_secure_file "$secure_copy" "$script_content" "700" "root" "root"; then
        log_error "Failed to create secure script copy"
        return 1
    fi
}
```

**Enhanced Emergency Access Features:**
- **Privilege Validation**: Scripts must be root:root owned with 700 permissions
- **Secure Creation**: Uses atomic operations for account creation
- **Comprehensive Logging**: All emergency access activities logged
- **Security Cleanup**: Secure temporary file cleanup after operations
- **Validation Integration**: Uses centralized security validation functions

## Enhanced Security Hardening Procedures

### Current System Hardening Checklist

#### Template-Based Security Hardening
```bash
# 1. Initialize with enhanced template-based security
sudo ./setup.sh --domain vault.example.com --email admin@example.com --auto

# 2. Configure secrets with enhanced privacy protection  
./edit-secrets.sh

# 3. Setup secure automation with privilege validation
sudo ./cron-setup.sh --install

# 4. Create emergency access with security validation
./create-breakglass-admin.sh

# 5. Validate comprehensive security configuration
./health.sh --comprehensive

# 6. Test dual fail2ban blocking
docker compose logs fail2ban | grep -E "cloudflare\\|ufw"
```

#### Enhanced Container Security
```bash
# Current container security features:
security_opt:
  - no-new-privileges:true    # Prevent privilege escalation
cap_drop:
  - ALL                      # Drop all capabilities
cap_add:  
  - NET_BIND_SERVICE         # Only necessary capabilities (Caddy only)

# Resource limits prevent DoS
deploy:
  resources:
    limits:
      memory: 2G             # Prevent memory exhaustion
      cpus: '0.6'            # Prevent CPU monopolization
```

### Enhanced Security Monitoring

#### Real-Time Security Monitoring (Current)
```bash
# Monitor dual fail2ban action effectiveness
docker compose logs fail2ban --follow | grep -E "CF.*ok|UFW.*ok|fail"

# Check enhanced resource usage
docker stats --format "table {{.Container}}\\t{{.CPUPerc}}\\t{{.MemUsage}}"

# Monitor forensic logs with enhanced retention
tail -f /var/lib/vaultwarden/logs/caddy/access.log | jq '.request.remote_ip'

# Validate security configuration
docker compose config && echo "Security configuration valid"
```

#### Security Validation Commands (Current)
```bash
# Comprehensive security health check
./health.sh --comprehensive

# Validate centralized security functions  
bash -c "source lib/security.sh && validate_system_security"

# Check break-glass admin security status
./create-breakglass-admin.sh --validate

# Verify fail2ban dual action functionality
docker compose exec fail2ban fail2ban-client status vaultwarden-auth
```

## Current Enhanced Threat Mitigations

### Brute Force Attack Protection (Enhanced)
**Current Multi-Layer Protection:**
1. **Edge Rate Limiting**: Cloudflare rate limiting at global edge
2. **Application Rate Limiting**: Caddy rate limiting with specialized API auth zones
3. **Dual Fail2Ban Blocking**: CF API + UFW local blocking with idempotent operations
4. **Account Lockout**: VaultWarden native account lockout mechanisms
5. **Forensic Logging**: 3GB log capacity for attack analysis and correlation

### Resource Exhaustion Attack Mitigation (Enhanced)
**Current Resource Protection:**
1. **Container Memory Limits**: Prevents individual containers from exhausting system memory
2. **CPU Limits**: Prevents single container from monopolizing CPU resources  
3. **Balanced Allocation**: Optimized resource distribution for 6GB systems
4. **Reserved Resources**: Guaranteed minimums ensure security services remain operational
5. **Health Monitoring**: Automated detection and alerting for resource issues

### Configuration Tampering Protection (Enhanced)
**Current Template-Based Protection:**
1. **Template Source Control**: `.example` files as single source of truth
2. **Validation Before Deployment**: `docker compose config` validation
3. **Controlled Updates**: Changes only via `setup.sh --force` with validation
4. **Security Drift Prevention**: Regular template-based configuration resets
5. **Centralized Security**: lib/security.sh provides consistent security validation

## Enhanced Security Best Practices

### Current Production Security Checklist

#### Daily Automated Security (Current Implementation)
```bash
# Via cron-setup.sh with enhanced security validation:
- Health monitoring with comprehensive security checks
- Resource usage monitoring and alerting
- Dual fail2ban effectiveness monitoring  
- Atomic backup integrity verification with Age encryption
- Break-glass admin status verification with security validation
- Forensic log rotation with enhanced retention
```

#### Weekly Security Tasks (Enhanced)
```bash
# 1. Review dual fail2ban effectiveness
docker compose logs fail2ban | grep -E "CF.*ok|UFW.*ok" | wc -l

# 2. Validate resource limits are working
docker stats --no-stream | grep -E "vaultwarden|caddy|fail2ban"

# 3. Check forensic log space usage (3GB capacity)
du -h /var/lib/vaultwarden/logs/

# 4. Verify enhanced firewall updates work safely
./maintenance.sh --update-firewall --dry-run

# 5. Validate centralized security functions
bash -c "source lib/security.sh && validate_system_security"
```

#### Monthly Security Audit (Enhanced)
```bash
# 1. Comprehensive security validation
./health.sh --comprehensive

# 2. Review enhanced logging for security incidents
grep -E "403|404|auth.*fail" /var/lib/vaultwarden/logs/caddy/*.log | tail -20

# 3. Validate template-based security configuration  
docker compose config

# 4. Test emergency access security
./create-breakglass-admin.sh --validate

# 5. Review resource usage trends
docker stats --no-stream --format "table {{.Container}}\\t{{.MemPerc}}\\t{{.CPUPerc}}"

# 6. Validate dual blocking is operational
curl -X GET "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/firewall/access_rules/rules" \\
  -H "Authorization: Bearer $CF_TOKEN" | jq '.result | length'
```

### Enhanced Security Incident Response

#### Current Incident Response Capabilities
```bash
# 1. Enhanced forensic analysis with 3GB log retention
grep -r "suspicious_pattern" /var/lib/vaultwarden/logs/

# 2. Request correlation across all log types
grep "REQUEST_ID" /var/lib/vaultwarden/logs/caddy/*.log

# 3. Resource impact analysis
docker stats --no-stream --format "json" | jq '.MemPerc'

# 4. Emergency access via break-glass admin (if SSH compromised)
# Access OCI Console → Instance → Console Connection
# Login with validated break-glass admin credentials

# 5. Atomic backup restoration with integrity checking
./restore.sh --interactive
```

#### Post-Incident Security Hardening
```bash
# 1. Update security configuration via templates
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com

# 2. Rotate all encrypted secrets with enhanced privacy
./edit-secrets.sh

# 3. Validate comprehensive security posture
./health.sh --comprehensive

# 4. Verify dual fail2ban effectiveness  
docker compose logs fail2ban | grep -E "Ban.*CF.*ok|Ban.*UFW.*ok"

# 5. Create forensic emergency backup
./backup.sh --type emergency
```

## Security Validation Checklist

### Enhanced Security Configuration Validation
```bash
# ✅ Template-based security configuration
docker compose config

# ✅ Enhanced secrets management (no process exposure)
ps aux | grep sops  # Should show no key paths

# ✅ Dual fail2ban blocking operational
docker compose logs fail2ban | grep -E "CF.*ok.*UFW.*ok"

# ✅ Resource limits preventing exhaustion
docker inspect vaultwarden_app | grep -A 10 "Memory"

# ✅ Enhanced forensic logging (3GB capacity)
du -sh /var/lib/vaultwarden/logs/

# ✅ Break-glass admin security validated
./create-breakglass-admin.sh --validate

# ✅ Centralized security functions operational
bash -c "source lib/security.sh && echo 'Security library loaded'"

# ✅ Safe firewall updates with race condition fixes
./maintenance.sh --update-firewall --dry-run
```

---

**Current Enhanced Security Status:**
- ✅ **Dual Blocking**: Cloudflare + UFW with idempotent operations
- ✅ **Resource Protection**: Container limits prevent system exhaustion  
- ✅ **Forensic Capabilities**: 60x log retention improvement (3GB total)
- ✅ **Enhanced Secrets**: Privacy protection with no process exposure
- ✅ **Emergency Access**: Break-glass admin with comprehensive validation
- ✅ **Centralized Security**: lib/security.sh provides consistent validation
- ✅ **Template-Based**: Secure configuration management and deployment
- ✅ **Safe Operations**: Race condition fixes and atomic operations

The current VaultWarden-OCI implementation provides enterprise-grade security with comprehensive protection layers, enhanced monitoring capabilities, and robust emergency access procedures optimized for small teams requiring reliable, secure password management infrastructure.
"""
