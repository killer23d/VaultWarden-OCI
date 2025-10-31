# Deployment Guide - VaultWarden-OCI

This comprehensive deployment guide covers initial setup, configuration, and post-deployment procedures for VaultWarden-OCI, including the latest template-based approach and quality of life improvements.

## Quick Deployment (15 Minutes)

### Prerequisites Checklist

- [ ] **Server**: Ubuntu 24.04 LTS (or similar Debian-based)
- [ ] **Resources**: 1 vCPU, 2GB RAM, 20GB storage (minimum)
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

# 2. Automated setup with template-based approach (installs everything)
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto

# 3. Configure secrets (CRITICAL)
./edit-secrets.sh

# 4. Configure environment from template
nano .env  # Set CLOUDFLARE_ZONE_ID and other settings

# 5. Start services
./startup.sh

# 6. Setup automation
sudo ./cron-setup.sh --install

# 7. Create emergency access
./create-breakglass-admin.sh

# 8. Verify deployment
./health.sh
```

**🎉 Deployment complete! Access at https://vault.yourdomain.com**

## Template-Based Architecture

### Configuration Management

All configuration files are now managed through templates for easier maintenance:

```
📁 Project Structure
├── docker-compose.yml.example # Template for Docker Compose
├── .env.example # Template for environment variables
├── docker-compose.yml # Generated from template by setup.sh
├── .env # Generated from template by setup.sh
├── caddy/Caddyfile # Static configuration file
└── fail2ban/
    ├── action.d/
    │ └── cloudflare-optimized.conf # Enhanced action with rate limiting
    ├── filter.d/ # Static filter configurations
    └── jail.d/ # Static jail configurations
```

### Benefits of Template Approach

✅ **Single source of truth** - Edit templates, not generated files  
✅ **No more hardcoded values** - Platform architecture issues eliminated  
✅ **Easy maintenance** - Direct file editing with syntax highlighting  
✅ **Testable configuration** - `docker compose config` works immediately  
✅ **Version control friendly** - Clean diffs and proper file history  
✅ **Consistent deployments** - Same templates produce identical configurations

## Detailed Deployment Process

### Phase 1: Server Preparation

#### System Requirements

##### Minimum Requirements
- **CPU**: 1 vCPU (ARM64 or x86_64)
- **Memory**: 2GB RAM
- **Storage**: 20GB available space
- **Network**: Dynamic IP with DNS control

##### Recommended (OCI A1 Flex - Always Free)
- **CPU**: 1 OCPU (ARM64) 
- **Memory**: 6GB RAM
- **Storage**: 50GB block storage
- **Network**: Always Free tier eligible

##### Production Requirements  
- **CPU**: 2+ vCPU for >10 users
- **Memory**: 4GB+ RAM for heavy usage
- **Storage**: 100GB+ for long-term data retention
- **Network**: Static IP preferred

#### Server Setup

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Set timezone (optional)
sudo timedatectl set-timezone UTC

# Configure hostname (optional)
sudo hostnamectl set-hostname vaultwarden

# Create dedicated user (optional but recommended)
sudo useradd -m -s /bin/bash vaultwarden
sudo usermod -aG sudo vaultwarden
sudo su - vaultwarden
```

### Phase 2: Project Installation

#### Repository Setup
```bash
# Clone project repository
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI

# Set script permissions
chmod +x *.sh

# Verify project structure
ls -la
# Should show: *.sh scripts, *.example templates, docs/, etc.
```

#### Template-Based Installation
```bash
# Production setup with template generation (recommended)
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto

# Development setup with latest versions
sudo ./setup.sh --domain vault-dev.yourdomain.com --email dev@yourdomain.com --auto --use-latest

# Custom setup with specific options
sudo ./setup.sh --domain vault.example.com --email admin@example.com --force --skip-deps
```

### Phase 3: Configuration

#### Critical Configuration Steps

##### 1. Cloudflare API Tokens
```bash
# Create API tokens at: https://dash.cloudflare.com/profile/api-tokens

# Token 1: DNS Management (ddclient)
# Permissions: Zone:DNS:Edit + Zone:Zone:Read
# Zone Resources: Include - Specific zone - yourdomain.com

# Token 2: Firewall Management (fail2ban)  
# Permissions: Zone:Firewall Services:Edit
# Zone Resources: Include - Specific zone - yourdomain.com
```

##### 2. Environment Variables (.env - Generated from Template)
```bash
# Edit environment configuration (generated from .env.example)
nano .env

# Required settings:
DOMAIN=vault.yourdomain.com
ADMIN_EMAIL=admin@yourdomain.com
CLOUDFLARE_ZONE_ID=your_zone_id_here      # From Cloudflare dashboard
PROJECT_STATE_DIR=/var/lib/vaultwarden     # Data storage location
TZ=UTC                                     # Timezone setting

# Optional remote backup:
RCLONE_REMOTE_NAME=your_remote_name        # Configure with: rclone config

# Version management (template-based approach):
# Production (automatically set by setup.sh --auto):
VAULTWARDEN_VERSION=1.30.5                # Pin to stable version
CADDY_VERSION=2.8.4                       # Pin to stable version
FAIL2BAN_VERSION=1.1.0                    # Pin to stable version
DDCLIENT_VERSION=3.11.2                   # Pin to stable version

# Development (set with --use-latest flag):
# Versions commented out to use latest tags
```

##### 3. Encrypted Secrets Configuration
```bash
# Configure secrets interactively
./edit-secrets.sh

# Required secrets:
# - admin_token: 32-character hex string for API access
# - admin_basic_auth_hash: bcrypt hash for admin panel
# - ddclient_api_token: Cloudflare DNS token
# - fail2ban_api_token: Cloudflare firewall token

# Optional secrets:
# - smtp_password: Email notification password
# - backup_passphrase: Additional backup encryption
# - push_installation_id/key: Bitwarden push notifications
```

#### Configuration Validation
```bash
# Validate Docker Compose configuration
docker compose config

# Test Age key accessibility
./edit-secrets.sh --test

# Verify environment variables
source .env && env | grep -E "DOMAIN|ADMIN_EMAIL|CLOUDFLARE"
```

### Phase 4: Service Deployment

#### Initial Startup
```bash
# Start all services
./startup.sh

# Monitor startup logs
docker compose logs vaultwarden --follow
docker compose logs caddy --follow

# Check service status
docker compose ps
```

#### Health Verification
```bash
# Comprehensive health check
./health.sh --comprehensive

# Expected output:
# ✅ Docker daemon accessible
# ✅ vaultwarden is running and healthy
# ✅ caddy is running and healthy
# ✅ fail2ban is running and healthy
# ✅ ddclient is running and healthy
# ✅ Memory usage: X% (< 85% threshold)
# ✅ Disk usage: X% (< 85% threshold)
# ✅ Age encryption key accessible
# ✅ Firewall active and configured
```

#### Network Configuration
```bash
# Update Cloudflare IP ranges in firewall
sudo ./update-cloudflare-ips.sh

# Verify firewall rules
sudo ufw status numbered

# Test DNS resolution
nslookup vault.yourdomain.com

# Test web connectivity
curl -f https://vault.yourdomain.com/
```

### Phase 5: Post-Deployment Setup

#### Automation Configuration
```bash
# Setup complete automation (recommended)
sudo ./cron-setup.sh --install

# Verify cron jobs
sudo crontab -l | grep vaultwarden

# Automation includes:
# - Health checks every 6 hours
# - Database backups daily at 2:00 AM
# - Full system backups weekly on Sunday
# - System updates monthly
# - Cloudflare IP updates weekly
```

#### Emergency Access Setup
```bash
# Create break-glass admin for emergency access
./create-breakglass-admin.sh

# Verify emergency access status
./create-breakglass-admin.sh status

# Document emergency credentials securely
# Test OCI serial console access (if using OCI)
```

#### Initial Backup Creation
```bash
# Create initial backups (with enhanced atomic operations)
./backup.sh --type db          # Database backup
./backup.sh --type full        # Complete system backup
./backup.sh --type emergency   # Disaster recovery kit

# Verify backup creation with enhanced listing
./backup.sh --list

# Configure remote backups (optional)
rclone config
# Update RCLONE_REMOTE_NAME in .env after configuration
```

## Enhanced Features

### Template-Based Configuration Management

#### Template Maintenance
```bash
# For ongoing maintenance, edit the template files:
nano docker-compose.yml.example # For Docker Compose changes
nano .env.example # For new environment variables

# Apply template changes
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
./startup.sh --force-restart # Apply changes
```

### Enhanced fail2ban with Rate Limiting

#### New Security Improvements
- **Enhanced fail2ban**: Rate limiting (max 30 API calls/minute)
- **Comprehensive error handling** and logging
- **Graceful failure recovery**
- **No more API abuse** or hanging requests

#### Improved UFW Setup
- **Clear warnings** when Cloudflare API fails
- **Fallback firewall configuration**
- **Interactive prompts** for failure scenarios

### Atomic Backup Operations

#### Enhanced Backup Strategy
- **Atomic Operations**: Prevents corrupt backups during creation
- **Better Disk Space Management**: More conservative space checks
- **Improved Database Consistency**: WAL checkpoints for live snapshots
- **Enhanced Listing**: Shows backups with timestamps, sizes, and IDs

### Emergency Recovery

#### Break-Glass Admin for OCI Serial Console
When SSH access is lost:

1. **Access OCI Console** → Compute → Instance → Console Connection
2. **Create console connection** (if not exists)
3. **Connect to serial console**
4. **Login with break-glass admin credentials**
5. **Fix SSH/firewall issues**
6. **Delete console connection** for security
7. **Rotate break-glass password**: `./create-breakglass-admin.sh password`

## Best Practices

### Template-Based Configuration

1. **Edit Templates**: Always edit `.example` files, not generated ones
2. **Use setup.sh**: Apply template changes via `setup.sh --force`
3. **Version Control**: Keep templates in version control
4. **Validate First**: Always run `docker compose config` before deployment
5. **Document Changes**: Document customizations in templates

### Security Best Practices

1. **Strong Authentication**: Use strong passwords and API tokens
2. **Network Security**: Restrict firewall rules to minimum required
3. **Enhanced fail2ban**: Monitor rate limiting and error handling
4. **Regular Updates**: Keep system and containers updated
5. **Emergency Access**: Test break-glass admin access annually

### Operational Best Practices

1. **Template Maintenance**: Use template-based approach for all changes
2. **Atomic Backups**: Rely on enhanced backup operations
3. **Interactive Tools**: Use enhanced backup listing and restore features
4. **Emergency Preparedness**: Maintain break-glass admin access
5. **Health Monitoring**: Use comprehensive health checks

---

This deployment guide provides comprehensive coverage of all deployment scenarios and configurations for VaultWarden-OCI, incorporating the latest template-based architecture, enhanced fail2ban security, atomic backup operations, and quality of life improvements for reliable, secure password management optimized for small teams.
