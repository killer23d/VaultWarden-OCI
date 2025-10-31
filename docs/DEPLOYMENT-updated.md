# Deployment Guide

Comprehensive deployment guide for VaultWarden-OCI using the template-based configuration approach.

## Overview

This guide covers deploying VaultWarden-OCI with:
- Template-based configuration management
- Enhanced fail2ban with rate limiting
- Improved UFW firewall setup with Cloudflare validation
- Oracle Cloud Infrastructure (OCI) optimization
- Emergency access preparation

## Prerequisites

### System Requirements

**Minimum Specifications:**
- **CPU**: 1 OCPU (ARM64 or x86_64)
- **Memory**: 1GB RAM (6GB recommended for OCI Flex)
- **Storage**: 20GB boot disk + 50GB block volume (recommended)
- **Network**: Public IP with unrestricted outbound access
- **OS**: Ubuntu 20.04 LTS or newer, Oracle Linux 8+

**Recommended OCI Configuration:**
- **Shape**: VM.Standard.A1.Flex (1 OCPU, 6GB RAM)
- **Boot Volume**: 50GB
- **Network**: Public subnet with Internet Gateway
- **Security**: Custom security list (managed by UFW)

### External Services

**Required:**
- **Cloudflare Account**: Free tier sufficient
- **Domain**: Must be managed by Cloudflare
- **Email**: For Let's Encrypt certificates (can be personal)

**Optional:**
- **SMTP Service**: For VaultWarden email notifications
- **Cloud Storage**: For offsite backup sync (rclone supported)

### Cloudflare API Tokens

**CRITICAL**: Create these tokens BEFORE deployment:

1. **DNS API Token** (for Caddy ACME challenges):
   - Go to: https://dash.cloudflare.com/profile/api-tokens
   - Template: "Custom token"
   - Permissions: 
     - `Zone:DNS:Edit` 
     - `Zone:Zone:Read`
   - Zone Resources: `Include - Specific zone - yourdomain.com`

2. **Firewall API Token** (for fail2ban IP blocking):
   - Template: "Custom token"
   - Permissions: `Zone:Firewall Services:Edit`
   - Zone Resources: `Include - Specific zone - yourdomain.com`

## Pre-Deployment Setup

### OCI Instance Setup

```bash
# 1. Create OCI instance with Ubuntu 20.04 LTS
# 2. Configure networking (public subnet + internet gateway)
# 3. Add SSH key for initial access
# 4. Connect via SSH
ssh ubuntu@your-instance-ip

# 5. Update system
sudo apt update && sudo apt upgrade -y

# 6. Set hostname
sudo hostnamectl set-hostname vaultwarden
```

### Cloudflare DNS Setup

```bash
# Create A record in Cloudflare:
# Name: vault (or your preferred subdomain)
# Type: A
# Content: your-instance-public-ip
# Proxy status: Proxied (orange cloud)
# TTL: Auto
```

## Template-Based Deployment

### Step 1: Download and Prepare

```bash
# Clone repository
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI

# Make scripts executable
chmod +x *.sh

# Verify template files exist
ls -la *.example
# Should show: .env.example, docker-compose.yml.example
```

### Step 2: Automated Setup (Template-Based)

```bash
# Run setup with your domain and email
# This will:
# - Install all dependencies
# - Copy and populate template files
# - Generate encryption keys
# - Configure firewall with Cloudflare IP validation
# - Create directory structure

sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto
```

**Key Setup Features:**
- ✅ **Template copying**: Generates `docker-compose.yml` from `docker-compose.yml.example`
- ✅ **Environment population**: Creates `.env` from `.env.example` with your values
- ✅ **Enhanced UFW**: Warns if Cloudflare IP fetch fails, provides fallback options
- ✅ **Validation**: Validates generated Docker Compose configuration
- ✅ **No hardcoded values**: Eliminates platform architecture issues

**Expected Output:**
```
✅ Template-Based Configuration:
   - docker-compose.yml copied from docker-compose.yml.example  
   - .env file populated from .env.example template
   - Easy maintenance via template files
```

### Step 3: Configure Secrets

**CRITICAL**: This step configures all sensitive credentials.

```bash
# Edit encrypted secrets
./edit-secrets.sh

# Configure these values:
# 1. admin_basic_auth_hash (bcrypt format)
# 2. caddy_cloudflare_dns_token (DNS API token)
# 3. fail2ban_cloudflare_firewall_token (Firewall API token)
# 4. smtp_password (if using email)
```

**Generate bcrypt hash for admin panel:**
```bash
# Generate bcrypt hash for Caddy basic auth
docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password
# Enter your desired admin password
# Copy the resulting hash to admin_basic_auth_hash
```

### Step 4: Environment Configuration

```bash
# Edit the generated .env file
nano .env

# Required settings:
DOMAIN=vault.yourdomain.com
ADMIN_EMAIL=admin@yourdomain.com
CLOUDFLARE_ZONE_ID=your_actual_zone_id_here

# Optional settings:
RCLONE_REMOTE_NAME=your_backup_remote
SMTP_HOST=your-smtp-server.com
# ... other SMTP settings if using email
```

**Find your Cloudflare Zone ID:**
```bash
# Method 1: Cloudflare Dashboard
# Go to your domain overview, Zone ID is in the right sidebar

# Method 2: API
curl -X GET "https://api.cloudflare.com/client/v4/zones" \
     -H "Authorization: Bearer YOUR_DNS_TOKEN" \
     -H "Content-Type: application/json" | jq '.result[] | {name, id}'
```

### Step 5: Start Services

```bash
# Start VaultWarden stack
./startup.sh

# Check status
./health.sh

# View logs if needed
docker compose logs -f vaultwarden
docker compose logs -f caddy
docker compose logs -f fail2ban
```

### Step 6: Setup Automation

```bash
# Install cron jobs for maintenance, backups, updates
sudo ./cron-setup.sh --install

# Verify cron jobs
sudo crontab -l
```

### Step 7: Emergency Access (CRITICAL)

```bash
# Create break-glass admin for OCI serial console
./create-breakglass-admin.sh

# Test OCI console connection (IMPORTANT)
# 1. Go to OCI Console → Compute → Instances → Your Instance
# 2. Click "Console Connection"
# 3. Create connection and test login with break-glass credentials
# 4. Delete the console connection after testing
```

## Verification

### Service Health Check

```bash
# Comprehensive health check
./health.sh

# Should show:
# ✅ All containers running
# ✅ VaultWarden responding
# ✅ Caddy certificates obtained
# ✅ fail2ban active
# ✅ Firewall configured
# ✅ DNS resolving correctly
```

### Web Interface Test

```bash
# Test HTTPS access
curl -I https://vault.yourdomain.com
# Should return: HTTP/2 200

# Test admin panel (will prompt for credentials)
curl -I https://vault.yourdomain.com/admin
# Should return: HTTP/2 401 (without credentials)
```

### Security Verification

```bash
# Check firewall status
sudo ufw status numbered
# Should show Cloudflare IP ranges and SSH only

# Check fail2ban status
docker compose exec fail2ban fail2ban-client status
# Should show active jails: vaultwarden-admin, vaultwarden-api, sshd

# Test fail2ban Cloudflare integration
docker compose logs fail2ban | grep -i cloudflare
# Should show successful API connections, no errors
```

## Post-Deployment Configuration

### VaultWarden Initial Setup

1. **Access Web Interface**:
   - Go to: https://vault.yourdomain.com
   - Create your first user account

2. **Configure Admin Panel**:
   - Go to: https://vault.yourdomain.com/admin
   - Use credentials you set in admin_basic_auth_hash
   - Review settings, users, diagnostics

3. **Test User Registration** (if enabled):
   - Verify signup process works
   - Test email delivery if configured

### Backup Configuration

```bash
# Test backup functionality
./backup.sh --type db
./backup.sh --list

# Configure offsite backup (optional)
# 1. Setup rclone remote
rclone config

# 2. Update .env with remote name
nano .env
# Set: RCLONE_REMOTE_NAME=your_remote_name

# 3. Test offsite sync
./backup.sh --type db --rclone
```

### SSL Certificate Verification

```bash
# Check certificate status
docker compose exec caddy caddy list-certificates

# Test HTTPS grade
# Go to: https://www.ssllabs.com/ssltest/
# Enter: https://vault.yourdomain.com
# Should achieve A+ rating
```

## Template Maintenance

### Updating Configuration Templates

```bash
# Edit template files (source of truth)
nano docker-compose.yml.example  # For Docker Compose changes
nano .env.example               # For new environment variables

# Apply template changes
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
./startup.sh --force-restart    # Restart with new config
```

### Version Control Best Practices

```bash
# Track template files in git
git add docker-compose.yml.example .env.example
git commit -m "Update template configurations"

# Never commit actual config files
echo ".env" >> .gitignore
echo "docker-compose.yml" >> .gitignore
```

## Troubleshooting Deployment

### Setup Script Issues

```bash
# Check setup logs
sudo ./setup.sh --dry-run --domain vault.test.com --email test@test.com
# Shows what setup would do without making changes

# Validate templates
docker compose config
# Should show no errors

# Re-run setup if needed
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
```

### Firewall Issues

```bash
# Check UFW status
sudo ufw status numbered

# If Cloudflare IP fetch failed during setup:
# 1. Check internet connectivity
curl -I https://www.cloudflare.com/ips-v4

# 2. Manually add Cloudflare IPs
curl https://www.cloudflare.com/ips-v4 | while read ip; do sudo ufw allow from $ip to any port 80,443; done
curl https://www.cloudflare.com/ips-v6 | while read ip; do sudo ufw allow from $ip to any port 80,443; done

# 3. Re-run setup
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
```

### Service Startup Issues

```bash
# Check container status
docker compose ps

# Check logs for errors
docker compose logs vaultwarden
docker compose logs caddy
docker compose logs fail2ban

# Validate configuration
docker compose config

# Force restart
./startup.sh --force-restart
```

### fail2ban Issues

```bash
# Check fail2ban status
docker compose exec fail2ban fail2ban-client status

# Test Cloudflare API connectivity
curl -X GET "https://api.cloudflare.com/client/v4/zones/YOUR_ZONE_ID/firewall/access_rules/rules" \
     -H "Authorization: Bearer YOUR_FIREWALL_TOKEN" \
     -H "Content-Type: application/json"

# Check rate limiting
docker compose logs fail2ban | grep -i "rate limit"

# Restart fail2ban if needed
docker compose restart fail2ban
```

### Template Validation Issues

```bash
# Check for template syntax issues
yamllint docker-compose.yml.example

# Check for hardcoded platform issues
grep -n "platform:" docker-compose.yml.example
grep -n "linux/arm64" docker-compose.yml.example
# Should return no results

# Validate environment template
cat .env.example | grep -v "^#" | grep "="
# Check for placeholder values
```

## Security Hardening

### Post-Deployment Security

```bash
# Change default SSH port (recommended)
sudo nano /etc/ssh/sshd_config
# Set: Port 2222
sudo systemctl restart sshd
sudo ufw allow 2222/tcp
sudo ufw delete allow 22/tcp

# Update SSH port in setup
nano .env
# Set: SSH_PORT=2222
```

### Regular Security Tasks

```bash
# Monthly security update
sudo apt update && sudo apt upgrade -y
./update.sh --system-only

# Quarterly break-glass test
# 1. Test OCI console connection
# 2. Verify break-glass admin works
# 3. Document any access issues
```

## Performance Optimization

### OCI-Specific Optimizations

```bash
# Adjust resource limits for OCI Flex
nano .env

# For 1 OCPU, 6GB RAM:
VAULTWARDEN_CPU_LIMIT=0.6
VAULTWARDEN_MEMORY_LIMIT=1.5g
CADDY_CPU_LIMIT=0.15
CADDY_MEMORY_LIMIT=256m
FAIL2BAN_CPU_LIMIT=0.05
FAIL2BAN_MEMORY_LIMIT=128m

# Apply changes
./startup.sh --force-restart
```

### Database Optimization

```bash
# Setup automated database maintenance
sudo ./cron-setup.sh --install
# This enables monthly database optimization

# Manual database maintenance
./db-maint.sh --optimize
```

## Disaster Recovery Planning

### Essential Backups

```bash
# Create initial emergency kit
./backup.sh --type emergency

# Download and store securely:
# 1. Age encryption key: secrets/keys/age-key.txt
# 2. Emergency backup file
# 3. Break-glass admin credentials
# 4. OCI Console access details
```

### Recovery Documentation

```bash
# Document for emergency reference:
# 1. Domain: vault.yourdomain.com
# 2. OCI Instance OCID
# 3. Break-glass admin username
# 4. Cloudflare Zone ID
# 5. Emergency contact information
```

---

**Next Steps**: See [CONFIGURATION.md](CONFIGURATION.md) for advanced configuration options and [OPERATIONS.md](OPERATIONS.md) for ongoing maintenance procedures.