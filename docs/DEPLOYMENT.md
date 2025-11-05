# Deployment Guide - VaultWarden-OCI

This comprehensive deployment guide covers initial setup, configuration, and post-deployment procedures for VaultWarden-OCI, incorporating the current template-based architecture, enhanced security features, and resource optimization for small teams.

## Quick Deployment (15 Minutes)

### Prerequisites Checklist

- [ ] **Server**: Ubuntu 24.04 LTS (or similar Debian-based)
- [ ] **Resources**: 1 vCPU, 2GB RAM, 20GB storage (minimum for 6GB system optimization)
- [ ] **Network**: Public IP with ports 22, 80, 443 accessible
- [ ] **Domain**: DNS control for your domain
- [ ] **Cloudflare**: Account with domain configured
- [ ] **Email**: SMTP access for notifications (optional)

### Rapid Deployment Steps

```bash
# 1. Clone repository
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

# 2. Automated setup with template-based approach
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto

# 3. Configure secrets with enhanced privacy protection
./edit-secrets.sh

# 4. Configure environment from template
nano .env  # Set CLOUDFLARE_ZONE_ID and other settings

# 5. Start services with enhanced startup handling
./startup.sh

# 6. Setup secure automation
sudo ./cron-setup.sh --install

# 7. Create emergency access
./create-breakglass-admin.sh

# 8. Comprehensive verification
./health.sh
```

**🎉 Deployment complete! Access at https://vault.yourdomain.com**

## Current Template-Based Architecture

### Configuration Management

All configuration files are managed through templates with enhanced features:

```
📁 Project Structure
├── docker-compose.yml.example          # Template with resource limits
├── docker-compose.override.yml.example # Email decoupling template  
├── .env.example                        # Environment template
├── docker-compose.yml                  # Generated from template
├── .env                               # Generated from template
├── caddy/Caddyfile                    # Enhanced logging configuration
├── fail2ban/
│   ├── action.d/
│   │   ├── cloudflare-apiv4.conf      # Dual CF+UFW action (optimized)
│   │   └── smtp.conf                  # Email notifications (msmtpd)
│   ├── filter.d/                      # Regex-based filters (no dependencies)
│   │   ├── vaultwarden-auth.conf      # Authentication failures
│   │   ├── vaultwarden-admin.conf     # Admin panel attacks
│   │   └── vaultwarden-web-caddy.conf # Web interface protection
│   └── jail.d/
│       └── vaultwarden-oci.conf       # Complete jail configuration
└── lib/
    ├── common.sh                      # Shared utilities
    ├── crypto.sh                      # Encryption functions
    ├── docker.sh                      # Docker management
    └── security.sh                    # Security validation functions
```

### Enhanced Template Features

✅ **Resource Optimization** - Container limits for 6GB systems  
✅ **Enhanced Security** - Comprehensive validation and hardening  
✅ **Email Decoupling** - Optional msmtpd container for portability  
✅ **Forensic Logging** - Enhanced log retention (3GB vs previous 50MB)  
✅ **Version Control Safe** - No secrets in templates  
✅ **Testable Configuration** - Full validation before deployment  

## Detailed Deployment Process

### Phase 1: Server Preparation

#### System Requirements

##### Minimum Requirements
- **CPU**: 1 vCPU (ARM64 or x86_64)
- **Memory**: 2GB RAM (optimized for 6GB systems)
- **Storage**: 20GB available space
- **Network**: Dynamic IP with DNS control

##### Recommended (OCI A1 Flex - Always Free)
- **CPU**: 1 OCPU (ARM64) 
- **Memory**: 6GB RAM (container limits: VW 2GB, Caddy 1GB, F2B 512MB)
- **Storage**: 50GB block storage
- **Network**: Always Free tier eligible

##### Production Requirements  
- **CPU**: 2+ vCPU for >10 users
- **Memory**: 4GB+ RAM (container limits scale appropriately)
- **Storage**: 100GB+ for enhanced log retention
- **Network**: Static IP preferred

#### Enhanced Server Setup

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Install required dependencies
sudo apt install -y curl wget git nano ufw fail2ban msmtp-mta

# Set timezone for consistent logging
sudo timedatectl set-timezone UTC

# Configure hostname
sudo hostnamectl set-hostname vaultwarden

# Create dedicated user with proper permissions
sudo useradd -m -s /bin/bash vaultwarden
sudo usermod -aG sudo,docker vaultwarden
```

### Phase 2: Enhanced Project Installation

#### Repository Setup with Validation
```bash
# Clone and verify project repository
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI

# Set script permissions
chmod +x *.sh

# Validate project structure
ls -la
# Should show: *.sh scripts, *.example templates, lib/, fail2ban/, docs/

# Verify library dependencies
ls -la lib/
# Should show: common.sh, crypto.sh, docker.sh, security.sh
```

#### Template-Based Installation with Enhanced Options
```bash
# Production setup with template generation (recommended)
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto

# Development setup with latest versions
sudo ./setup.sh --domain vault-dev.yourdomain.com --email dev@yourdomain.com --use-latest

# Forced reinstallation with validation
sudo ./setup.sh --domain vault.example.com --email admin@example.com --force --validate
```

### Phase 3: Enhanced Configuration

#### Critical Configuration Steps

##### 1. Cloudflare API Tokens (Enhanced Security)
```bash
# Create API tokens at: https://dash.cloudflare.com/profile/api-tokens

# Token 1: DNS Management (Caddy)
# Permissions: Zone:DNS:Edit + Zone:Zone:Read
# Zone Resources: Include - Specific zone - yourdomain.com

# Token 2: Firewall Management (Fail2Ban Dual Action)  
# Permissions: Zone:Firewall Services:Edit
# Zone Resources: Include - Specific zone - yourdomain.com
```

##### 2. Environment Variables (.env - Enhanced Template)
```bash
# Edit environment configuration (generated from .env.example)
nano .env

# Core settings:
DOMAIN=vault.yourdomain.com
ADMIN_EMAIL=admin@yourdomain.com
CLOUDFLARE_ZONE_ID=your_zone_id_here      # From Cloudflare dashboard
PROJECT_STATE_DIR=/var/lib/vaultwarden     # Enhanced state management
TZ=UTC                                     # Timezone consistency

# Resource management (6GB system optimization):
PUID=1000
PGID=1000

# Enhanced logging and forensics:
# (Configured automatically in templates)

# Optional remote backup:
RCLONE_REMOTE_NAME=your_remote_name        # Configure with: rclone config

# Version pinning (production stability):
VAULTWARDEN_VERSION=1.30.5                # Stable release
CADDY_VERSION=2.8.4-cloudflare           # With Cloudflare module
FAIL2BAN_VERSION=1.1.0                    # Enhanced fail2ban
MSMTPD_VERSION=1.0.0                      # msmtpd relay
```

##### 3. Enhanced Secrets Configuration
```bash
# Configure secrets with enhanced privacy protection
./edit-secrets.sh

# Required secrets (securely managed):
# - admin_token: 32-character hex string for API access
# - admin_basic_auth_hash: bcrypt hash for admin panel
# - caddy_cloudflare_dns_token: DNS management token
# - fail2ban_cloudflare_firewall_token: Firewall management token

# Optional secrets:
# - smtp_password: Email notification credentials
# - push_installation_id/key: Bitwarden push notifications

# Enhanced security features:
# - SOPS key path never exposed in process list
# - Secure temporary file handling
# - Automatic backup creation before editing
# - Comprehensive validation after editing
```

#### Enhanced Configuration Validation
```bash
# Validate Docker Compose configuration with resource limits
docker compose config

# Validate templates independently  
docker compose -f docker-compose.yml.example config

# Test enhanced secrets management
./edit-secrets.sh --validate

# Comprehensive security validation
./lib/security.sh && echo "Security validation passed"
```

### Phase 4: Enhanced Service Deployment

#### Initial Startup with Resource Management
```bash
# Start all services with enhanced handling
./startup.sh

# Monitor startup with resource awareness
docker stats --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"

# Verify resource limits are applied
docker compose ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Check service logs
docker compose logs vaultwarden --follow --tail=50
docker compose logs caddy --follow --tail=50
docker compose logs fail2ban --follow --tail=50
```

#### Enhanced Health Verification
```bash
# Comprehensive health check with resource monitoring
./health.sh --comprehensive

# Expected output includes:
# ✅ Docker daemon accessible
# ✅ All containers running within resource limits  
# ✅ VaultWarden: 2GB limit, healthy
# ✅ Caddy: 1GB limit, healthy
# ✅ Fail2ban: 512MB limit, healthy
# ✅ Memory usage: X% (< 85% threshold)
# ✅ Enhanced logging operational (3GB capacity)
# ✅ Dual Cloudflare+UFW blocking functional
# ✅ Forensic log retention: 30-180 days
```

#### Network Configuration with Enhanced Firewall
```bash
# Update Cloudflare IP ranges with safe handling
./maintenance.sh --update-firewall

# Verify enhanced firewall rules
sudo ufw status numbered

# Test DNS resolution
nslookup vault.yourdomain.com

# Test web connectivity with enhanced headers
curl -I https://vault.yourdomain.com/
```

### Phase 5: Enhanced Post-Deployment Setup

#### Secure Automation Configuration
```bash
# Setup enhanced secure automation
sudo ./cron-setup.sh --install

# Verify secure cron job installation
sudo crontab -l | grep vaultwarden

# Enhanced automation includes:
# - Comprehensive health checks every 30 minutes
# - Safe database maintenance daily at 2:00 AM
# - Atomic backups daily at 3:00 AM  
# - Enhanced firewall updates weekly (Sunday 4:00 AM)
# - Full system backups weekly (Sunday 5:00 AM)
```

#### Emergency Access with Enhanced Security
```bash
# Create break-glass admin with enhanced validation
./create-breakglass-admin.sh

# Verify emergency access with security checks
./create-breakglass-admin.sh --status

# Test OCI serial console access (if using OCI)
# Document emergency procedures securely
```

#### Enhanced Backup Strategy
```bash
# Create initial backups with enhanced features
./backup.sh --type db          # Atomic database backup
./backup.sh --type full        # Complete system backup  
./backup.sh --type emergency   # Disaster recovery kit

# Enhanced backup listing with detailed information
./backup.sh --list

# Configure remote backups with encryption
rclone config
# Update RCLONE_REMOTE_NAME in .env after configuration

# Test backup restoration
./restore.sh --test
```

## Current Enhanced Features

### Resource Management for 6GB Systems

#### Container Resource Allocation
- **VaultWarden**: 2GB memory limit, 0.6 CPU (60% of single CPU)
- **Caddy**: 1GB memory limit, 0.3 CPU (30% of single CPU)  
- **Fail2Ban**: 512MB memory limit, 0.2 CPU (20% of single CPU)
- **msmtpd**: 32MB memory limit, 0.05 CPU (5% of single CPU)
- **Total**: ~3.53GB allocated, remainder for host OS and buffers

#### Memory Reservations
- **VaultWarden**: 512MB guaranteed minimum
- **Caddy**: 256MB guaranteed minimum
- **Fail2Ban**: 128MB guaranteed minimum
- **msmtpd**: 8MB guaranteed minimum

### Enhanced Fail2Ban with Dual Actions

#### Advanced Security Features
- **Dual Blocking**: Cloudflare API + local UFW for comprehensive protection
- **Idempotent Operations**: Checks existing rules before creating new ones
- **Retry Logic**: Exponential backoff for API failures
- **Graceful Degradation**: Falls back to UFW if Cloudflare fails
- **Comprehensive Logging**: Detailed status reporting for all operations

#### Regex-Based Filters (No Dependencies)
- **No JMESPath**: All filters use regex for Caddy JSON logs
- **Enhanced Detection**: Covers authentication, admin, web, and API attacks
- **Performance Optimized**: Fast regex matching without external libraries

### Enhanced Logging and Forensics

#### Massive Log Retention Improvement (60x increase)
- **Main Access Log**: 50MB × 20 files = 1GB total
- **Admin Access Log**: 25MB × 30 files = 750MB (90-day retention)
- **Auth Attempts Log**: 25MB × 30 files = 750MB (90-day retention) 
- **Security Blocks Log**: 10MB × 50 files = 500MB (180-day retention)
- **Total Forensic Capacity**: ~3GB vs previous 50MB

#### Structured JSON Logging
- **Request Correlation**: X-Request-ID across all logs
- **Timezone Consistency**: All containers use TZ environment variable
- **Enhanced Timestamps**: Microsecond precision for correlation
- **Forensic Analysis Ready**: Structured data for automated analysis

### Enhanced Template Security

#### Secure Configuration Management
- **No Hardcoded Secrets**: All sensitive data in encrypted secrets
- **Validation Before Deployment**: Template syntax checking
- **Version Control Safe**: Templates contain no credentials
- **Consistent Security**: Same security model across all deployments

## Enhanced Best Practices

### Template-Based Configuration Management

1. **Edit Templates Only**: Always modify `.example` files, never generated ones
2. **Use Enhanced Setup**: Apply changes via `./setup.sh --force --validate`  
3. **Resource Awareness**: Consider 6GB system limitations in customizations
4. **Security Validation**: Use `./health.sh --comprehensive` after changes
5. **Document Customizations**: Maintain clear documentation of template changes

### Enhanced Security Operations

1. **Comprehensive Validation**: Use enhanced security validation functions
2. **Resource Monitoring**: Monitor container resource usage regularly
3. **Enhanced Fail2Ban**: Monitor dual-action blocking effectiveness  
4. **Forensic Preparedness**: Leverage 3GB log retention for incident response
5. **Emergency Access**: Test break-glass admin access quarterly

### Enhanced Operational Excellence  

1. **Atomic Operations**: Use enhanced backup and maintenance operations
2. **Secure Automation**: Leverage secure cron setup with privilege validation
3. **Resource Optimization**: Monitor and tune container resource allocation
4. **Comprehensive Health**: Use detailed health monitoring and auto-repair
5. **Enhanced Recovery**: Maintain multiple backup types and test restoration

### Enhanced Troubleshooting

#### Resource-Related Issues
```bash
# Check container resource usage
docker stats --no-stream

# Verify resource limits are applied
docker inspect vaultwarden_app | grep -A 10 "Resources"

# Monitor memory pressure
free -h && cat /proc/meminfo | grep Available
```

#### Enhanced Fail2Ban Troubleshooting
```bash
# Check dual-action effectiveness
docker compose logs fail2ban | grep -E "(cloudflare|ufw)"

# Validate filter regex
docker compose exec fail2ban fail2ban-regex /var/log/caddy/access.log /data/fail2ban/filter.d/vaultwarden-web-caddy.conf

# Test Cloudflare API connectivity
curl -X GET "https://api.cloudflare.com/client/v4/zones" \
     -H "Authorization: Bearer YOUR_TOKEN"
```

---

This enhanced deployment guide reflects the current state of VaultWarden-OCI with comprehensive resource management, advanced security features, enhanced logging capabilities, and robust operational excellence optimized for small teams on resource-constrained systems.