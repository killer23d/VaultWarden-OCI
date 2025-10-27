# Deployment Guide - VaultWarden-OCI-Simplified

This comprehensive deployment guide covers initial setup, configuration, and post-deployment procedures for VaultWarden-OCI-Simplified, including the latest quality of life improvements and best practices.

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
git clone https://github.com/killer23d/VaultWarden-OCI-Simplified.git
cd VaultWarden-OCI-Simplified
chmod +x *.sh

# 2. Automated setup (installs everything)
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto

# 3. Configure secrets (CRITICAL)
make edit-secrets

# 4. Configure environment
nano .env  # Set CLOUDFLARE_ZONE_ID and other settings

# 5. Start services
make up

# 6. Setup automation
sudo ./cron-setup.sh

# 7. Create emergency access
make breakglass-create

# 8. Verify deployment
make health
```

**🎉 Deployment complete! Access at https://vault.yourdomain.com**

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
git clone https://github.com/killer23d/VaultWarden-OCI-Simplified.git
cd VaultWarden-OCI-Simplified

# Set script permissions
chmod +x *.sh

# Verify project structure
ls -la
# Should show: *.sh scripts, docker-compose.yml, .env.example, docs/, etc.
```

#### Automated Installation
```bash
# Production setup with pinned versions (recommended)
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto

# Development setup with latest versions
sudo ./setup.sh --domain vault-dev.yourdomain.com --email dev@yourdomain.com --auto --use-latest

# Custom setup with specific options
sudo ./setup.sh --domain vault.example.com --email admin@example.com --force --skip-deps
```

#### Manual Installation (Advanced)
```bash
# Install dependencies manually
sudo apt install -y docker.io docker-compose-plugin age sops nano rclone sqlite3 argon2 jq mailutils ufw curl

# Configure firewall
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw --force enable

# Generate Age encryption keys
age-keygen -o secrets/keys/age-key.txt
age-keygen -y secrets/keys/age-key.txt > secrets/keys/age-public-key.txt

# Create environment file
cp .env.example .env
```

### Phase 3: Configuration

#### Critical Configuration Steps

##### 1. Cloudflare API Tokens
```bash
# Create API tokens at: https://dash.cloudflare.com/profile/api-tokens

# Token 1: DNS Management (ddclient)
# Permissions: Zone:DNS:Edit
# Zone Resources: Include - Specific zone - yourdomain.com

# Token 2: Firewall Management (fail2ban)  
# Permissions: Zone:Firewall Services:Edit
# Zone Resources: Include - Specific zone - yourdomain.com
```

##### 2. Environment Variables (.env)
```bash
# Edit environment configuration
nano .env

# Required settings:
DOMAIN=vault.yourdomain.com
ADMIN_EMAIL=admin@yourdomain.com
CLOUDFLARE_ZONE_ID=your_zone_id_here      # From Cloudflare dashboard
PROJECT_STATE_DIR=/var/lib/vaultwarden     # Data storage location
TZ=UTC                                     # Timezone setting

# Optional remote backup:
RCLONE_REMOTE_NAME=your_remote_name        # Configure with: make configure-rclone

# Version management (production):
VAULTWARDEN_VERSION=1.30.5                # Pin to stable version
CADDY_VERSION=2.8.4                       # Pin to stable version
FAIL2BAN_VERSION=1.1.0                    # Pin to stable version
DDCLIENT_VERSION=3.11.2                   # Pin to stable version
```

##### 3. Encrypted Secrets Configuration
```bash
# Configure secrets interactively
make edit-secrets
# Or: ./edit-secrets.sh

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
make config-check
# Or: docker compose config

# Test Age key accessibility
./edit-secrets.sh --test

# Verify environment variables
source .env && env | grep -E "DOMAIN|ADMIN_EMAIL|CLOUDFLARE"
```

### Phase 4: Service Deployment

#### Initial Startup
```bash
# Start all services
make up
# Or: ./startup.sh

# Monitor startup logs
make logs SERVICE=vaultwarden
make logs SERVICE=caddy

# Check service status
docker compose ps
```

#### Health Verification
```bash
# Comprehensive health check
make health
# Or: ./health.sh --comprehensive

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
make update-ips
# Or: sudo ./update-cloudflare-ips.sh

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
sudo ./cron-setup.sh

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
make breakglass-create
# Or: sudo ./create-breakglass-admin.sh create

# Verify emergency access status
make breakglass-status
# Or: sudo ./create-breakglass-admin.sh status

# Document emergency credentials securely
# Test OCI serial console access (if using OCI)
```

#### Initial Backup Creation
```bash
# Create initial backups
make backup-db          # Database backup
make backup-full        # Complete system backup
make backup-emergency   # Disaster recovery kit

# Verify backup creation
make list-backups
# Or: ./backup.sh --list

# Configure remote backups (optional)
make configure-rclone
# Update RCLONE_REMOTE_NAME in .env after configuration
```

#### Version Management Setup
```bash
# For production (recommended): Pin specific versions
make pin SERVICE=vaultwarden VERSION=1.30.5
make pin SERVICE=caddy VERSION=2.8.4
make pin SERVICE=fail2ban VERSION=1.1.0
make pin SERVICE=ddclient VERSION=3.11.2

# For development: Use latest versions  
make unpin SERVICE=vaultwarden
make unpin SERVICE=caddy

# Verify version configuration
make pins
# Or: ./update.sh --show-pins

# Check running versions
docker compose ps --format "table {{.Service}}	{{.Image}}"
```

## Deployment Scenarios

### Cloud Provider Deployments

#### Oracle Cloud Infrastructure (OCI)

##### OCI Always Free Tier
```bash
# Ideal configuration for Always Free tier:
# - VM.Standard.A1.Flex: 1 OCPU, 6GB RAM (ARM64)
# - 50GB Block Volume
# - Dynamic public IP

# OCI-specific considerations:
# - Configure security list to allow ports 22, 80, 443
# - Use OCI DNS or external DNS provider
# - Consider OCI Object Storage for backups
```

##### OCI Serial Console Integration
```bash
# Setup break-glass admin for OCI console access
make breakglass-create

# Test serial console connection:
# 1. OCI Console → Compute → Instance → Console Connection
# 2. Create console connection
# 3. Connect via browser or SSH
# 4. Login with break-glass admin credentials
# 5. Delete console connection after testing
```

#### Amazon Web Services (AWS)

##### EC2 Deployment
```bash
# Recommended EC2 configuration:
# - Instance type: t3.micro or t3.small
# - AMI: Ubuntu 24.04 LTS
# - Security group: SSH (22), HTTP (80), HTTPS (443)
# - Elastic IP for static IP (optional)

# AWS-specific considerations:
# - Use Route 53 for DNS or external provider
# - Consider S3 for backup storage
# - Enable CloudWatch monitoring
```

#### Google Cloud Platform (GCP)

##### Compute Engine Deployment
```bash
# Recommended GCE configuration:
# - Machine type: e2-micro or e2-small
# - Image: Ubuntu 24.04 LTS
# - Firewall: Allow HTTP/HTTPS traffic
# - Static IP (optional)

# GCP-specific considerations:  
# - Use Cloud DNS or external provider
# - Consider Cloud Storage for backups
# - Enable monitoring and logging
```

#### Microsoft Azure

##### Virtual Machine Deployment
```bash
# Recommended Azure VM configuration:
# - VM size: B1s or B2s
# - Image: Ubuntu 24.04 LTS
# - Network security group: SSH, HTTP, HTTPS
# - Public IP address

# Azure-specific considerations:
# - Use Azure DNS or external provider
# - Consider Blob Storage for backups
# - Enable Azure Monitor
```

### Home Lab Deployment

#### Self-Hosted Configuration
```bash
# Home lab considerations:
# - Dynamic DNS support required
# - Port forwarding: 22, 80, 443
# - Backup strategy for hardware failures
# - UPS for power protection
# - Regular hardware maintenance

# ISP compatibility:
# - Check for port 80/443 restrictions
# - Verify dynamic DNS support
# - Consider business internet for static IP
```

#### Docker Host Requirements
```bash
# Minimum Docker host specifications:
# - Docker Engine 20.10+
# - Docker Compose v2.0+
# - 2GB+ available RAM
# - 20GB+ available storage
# - Reliable internet connection
```

### Development Environment

#### Local Development Setup
```bash
# Development environment deployment
sudo ./setup.sh --domain vault-dev.localhost --email dev@example.com --use-latest

# Development-specific configuration:
# - Use latest container versions
# - Shorter backup retention
# - Additional debug logging
# - Test data population
```

#### Testing Configuration
```bash
# Configure for testing
export TESTING_MODE=true

# Use test credentials
make edit-secrets
# Set weak/test passwords for development only

# Create test data
# Populate with sample data for testing
```

## Post-Deployment Verification

### Functional Testing

#### Web Interface Testing
```bash
# Test web interface accessibility
curl -f https://vault.yourdomain.com/

# Test admin panel (after configuring admin auth)
curl -u "admin:password" https://vault.yourdomain.com/admin/

# Test API endpoints
curl -H "Authorization: Bearer $ADMIN_TOKEN" https://vault.yourdomain.com/admin/config
```

#### Service Integration Testing
```bash
# Test fail2ban integration
# Intentionally trigger login failures and verify IP blocking

# Test ddclient DNS updates
# Verify DNS record updates in Cloudflare dashboard

# Test backup operations
make backup-db
make list-backups

# Test restore operations
make restore --dry-run
```

#### Security Testing
```bash
# Test firewall configuration
nmap -p 22,80,443 vault.yourdomain.com

# Test SSL/TLS configuration
curl -I https://vault.yourdomain.com/
# Verify HTTPS redirect and security headers

# Test admin authentication
# Verify basic auth is required for admin panel
```

### Performance Testing

#### Load Testing
```bash
# Test basic performance
ab -n 100 -c 10 https://vault.yourdomain.com/

# Monitor resource usage
make status
docker stats --no-stream

# Check response times
time curl -f https://vault.yourdomain.com/
```

#### Stress Testing
```bash
# Test under load
# Create multiple user accounts
# Perform concurrent operations
# Monitor system resources
```

### Monitoring Setup

#### Health Monitoring
```bash
# Setup comprehensive monitoring
make health

# Configure email alerts
# Edit SMTP settings in secrets and .env

# Test alert system
./health.sh --comprehensive --email-alert
```

#### Log Monitoring
```bash
# Monitor service logs
make logs-follow SERVICE=vaultwarden
make logs-follow SERVICE=fail2ban

# Setup log rotation
# Configured automatically via setup.sh

# Monitor disk usage
df -h
```

## Deployment Troubleshooting

### Common Deployment Issues

#### Setup Script Failures
```bash
# If setup.sh fails:
# 1. Check system requirements
# 2. Verify internet connectivity
# 3. Check available disk space
# 4. Review setup logs

# Debug setup issues
sudo ./setup.sh --dry-run --domain vault.example.com --email admin@example.com
```

#### Service Startup Failures
```bash
# If services won't start:
make logs SERVICE=vaultwarden
make logs SERVICE=caddy

# Common issues:
# - Incorrect secrets configuration
# - Port conflicts
# - Permission issues
# - Network connectivity problems
```

#### Network Connectivity Issues
```bash
# If external access fails:
# 1. Check firewall rules: sudo ufw status
# 2. Verify DNS resolution: nslookup vault.yourdomain.com
# 3. Test local connectivity: curl -f http://localhost/
# 4. Check cloud provider security groups
# 5. Verify Cloudflare proxy settings
```

#### Configuration Problems
```bash
# If configuration is incorrect:
make config-check
./edit-secrets.sh --test

# Reset configuration if needed:
cp .env.example .env
make edit-secrets --init
```

### Recovery Procedures

#### Deployment Rollback
```bash
# If deployment fails and rollback needed:
make down
git checkout HEAD~1  # Rollback to previous version
make up
make health
```

#### Fresh Installation
```bash
# If complete reinstallation needed:
make down
docker system prune -af
sudo rm -rf /var/lib/vaultwarden
# Re-run deployment process
```

## Best Practices

### Security Best Practices

1. **Strong Authentication**: Use strong passwords and API tokens
2. **Network Security**: Restrict firewall rules to minimum required
3. **SSL/TLS**: Always use HTTPS with proper certificates
4. **Regular Updates**: Keep system and containers updated
5. **Access Control**: Limit admin access to authorized users
6. **Audit Logging**: Enable comprehensive logging and monitoring

### Operational Best Practices

1. **Backup Strategy**: Implement automated backups with testing
2. **Monitoring**: Setup proactive monitoring and alerting
3. **Documentation**: Maintain current deployment documentation
4. **Change Management**: Use version control for configuration changes
5. **Disaster Recovery**: Test recovery procedures regularly
6. **Capacity Planning**: Monitor resource usage and plan scaling

### Maintenance Best Practices

1. **Regular Health Checks**: Daily health monitoring
2. **Update Management**: Planned update cycles with testing
3. **Backup Verification**: Regular backup restoration testing  
4. **Security Reviews**: Quarterly security assessments
5. **Performance Monitoring**: Continuous performance tracking
6. **Emergency Preparedness**: Maintain emergency procedures

---

This deployment guide provides comprehensive coverage of all deployment scenarios and configurations for VaultWarden-OCI-Simplified, incorporating the latest quality of life improvements and best practices for reliable, secure password management.
