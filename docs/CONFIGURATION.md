# Configuration Guide - VaultWarden-OCI-Simplified

This comprehensive configuration guide covers system setup, environment variables, secrets management, and advanced configuration options for VaultWarden-OCI-Simplified.

## Quick Configuration Overview

### Essential Configuration Steps

1. **System Setup**: `sudo ./setup.sh --auto --domain vault.example.com --email admin@example.com`
2. **Secrets Configuration**: `make edit-secrets`
3. **Environment Variables**: Edit `.env` file with your specific settings
4. **Version Management**: `make pin SERVICE=vaultwarden VERSION=1.30.5` (production)
5. **Emergency Access**: `make breakglass-create`
6. **Remote Backups**: `make configure-rclone` (optional)
7. **Validation**: `make config-check`

## Environment Variables (.env)

### Core Application Settings

```bash
# Domain and Email Configuration
DOMAIN=vault.yourdomain.com              # Your VaultWarden domain
ADMIN_EMAIL=admin@yourdomain.com         # Administrator email

# Project Configuration
PROJECT_STATE_DIR=/var/lib/vaultwarden   # Data storage directory
SSH_PORT=22                              # SSH port (change if non-standard)
TZ=UTC                                   # Timezone setting
```

### Cloudflare Integration

```bash
# Cloudflare Zone Configuration
CLOUDFLARE_ZONE_ID=your_zone_id_here    # Get from Cloudflare dashboard
# Find at: Cloudflare Dashboard → Domain → Overview → Zone ID (right sidebar)

# Dynamic DNS Settings
DDCLIENT_UPDATE_INTERVAL=300            # DNS update interval (seconds)
DDCLIENT_PROTOCOL=cloudflare            # DNS provider protocol
```

### Backup Configuration

```bash
# Local Backup Settings
BACKUP_RETENTION_DAYS=30                # Days to keep local backups
DB_BACKUP_RETENTION_DAYS=14             # Days to keep database backups
EMERGENCY_BACKUP_RETENTION_DAYS=90      # Days to keep emergency kits

# Remote Backup Configuration (Optional)
RCLONE_REMOTE_NAME=your_remote_name     # Configure with: make configure-rclone
# Examples: "gdrive", "s3", "dropbox", "onedrive"
```

### Container Version Management

```bash
# Production Mode (Recommended - Pinned Versions)
VAULTWARDEN_VERSION=1.30.5             # Pin to stable version
CADDY_VERSION=2.8.4                    # Pin to stable version
FAIL2BAN_VERSION=1.1.0                 # Pin to stable version
DDCLIENT_VERSION=3.11.2                # Pin to stable version

# Development Mode (Latest Versions)
# Comment out or remove version variables to use latest
#VAULTWARDEN_VERSION=1.30.5            # Commented = use latest
#CADDY_VERSION=2.8.4                   # Commented = use latest
```

### Resource Limits

```bash
# Container Memory Limits
VAULTWARDEN_MEMORY_LIMIT=512m          # VaultWarden container memory limit
CADDY_MEMORY_LIMIT=128m                # Caddy container memory limit
FAIL2BAN_MEMORY_LIMIT=64m              # Fail2ban container memory limit
DDCLIENT_MEMORY_LIMIT=32m              # DDClient container memory limit

# Container CPU Limits
VAULTWARDEN_CPU_LIMIT=1.0              # VaultWarden CPU limit (cores)
CADDY_CPU_LIMIT=0.5                    # Caddy CPU limit (cores)
```

### Email Configuration (Optional)

```bash
# SMTP Settings for Notifications
SMTP_HOST=smtp.gmail.com               # SMTP server
SMTP_PORT=587                          # SMTP port
SMTP_FROM=vaultwarden@yourdomain.com   # From address
SMTP_USERNAME=your_email@gmail.com     # SMTP username
# SMTP_PASSWORD configured in secrets (make edit-secrets)
```

## Secrets Management

### Encrypted Secrets Configuration

Use the interactive secrets editor to configure sensitive data:

```bash
# Edit encrypted secrets
make edit-secrets
# Or: ./edit-secrets.sh
```

### Required Secrets

#### VaultWarden Admin Authentication
```yaml
# Admin token for API access (32-character hex string)
admin_token: "1234567890abcdef1234567890abcdef"

# Admin panel basic auth hash (bcrypt)
admin_basic_auth_hash: "$2b$12$hash_generated_by_secrets_tool"
```

#### Cloudflare API Tokens
```yaml
# DNS updates token (Zone:DNS:Edit permission)
ddclient_api_token: "your_dns_token_here"

# Firewall management token (Zone:Firewall Services:Edit permission)
fail2ban_api_token: "your_firewall_token_here"
```

#### Backup Security
```yaml
# Additional encryption passphrase for backups
backup_passphrase: "strong_random_passphrase_here"
```

#### Optional Secrets
```yaml
# SMTP password for email notifications
smtp_password: "your_smtp_password"

# Bitwarden push notifications (optional)
push_installation_id: "your_installation_id"
push_installation_key: "your_installation_key"
```

### Secrets Management Commands

```bash
# Interactive secrets editing (recommended)
make edit-secrets

# Test secrets accessibility
./edit-secrets.sh --test

# Show decrypted secrets (use with caution)
./edit-secrets.sh --show

# Rotate Age encryption keys (advanced)
./edit-secrets.sh --rotate-keys
```

## Container Configuration

### VaultWarden Application Settings

#### Security Configuration
```bash
# In .env file, these affect VaultWarden behavior:
SIGNUPS_ALLOWED=false                  # Disable open registration
SIGNUPS_VERIFY=true                   # Require email verification
INVITATIONS_ALLOWED=true              # Admin-controlled invitations
PASSWORD_ITERATIONS=600000            # High iteration count for security
SHOW_PASSWORD_HINT=false              # Don't show password hints
SESSION_TIMEOUT=3600                  # 1-hour session timeout
EXTENDED_LOGGING=true                 # Enhanced audit logging
```

#### Database Configuration
```bash
# SQLite database settings
DATABASE_MAX_CONNS=10                 # Maximum database connections
DATABASE_URL=sqlite3:data/db.sqlite3  # Database path (relative to container)
```

### Caddy Reverse Proxy Configuration

#### Security Headers
The Caddy configuration includes comprehensive security headers:

```caddyfile
# Located in: caddy/Caddyfile
# Security headers are automatically applied:
- Strict-Transport-Security (HSTS)
- Content-Security-Policy (CSP)
- X-Content-Type-Options
- X-Frame-Options
- X-XSS-Protection
- Referrer-Policy
```

#### SSL/TLS Configuration
```caddyfile
# Automatic HTTPS with Let's Encrypt
{$DOMAIN} {
    reverse_proxy vaultwarden:80

    # Security headers applied automatically
    # Certificate management handled by Caddy
}
```

### fail2ban Intrusion Prevention

#### Jail Configuration
```ini
# Located in: fail2ban/jail.local
[vaultwarden-admin]
enabled = true
filter = vaultwarden-admin
logpath = /var/log/vaultwarden/*.log
maxretry = 3
bantime = 3600
findtime = 600

[vaultwarden-api]
enabled = true
filter = vaultwarden-api
logpath = /var/log/vaultwarden/*.log
maxretry = 5
bantime = 3600
findtime = 600
```

## Version Management Configuration

### Production Version Strategy

```bash
# Pin specific versions for stability
make pin SERVICE=vaultwarden VERSION=1.30.5
make pin SERVICE=caddy VERSION=2.8.4
make pin SERVICE=fail2ban VERSION=1.1.0
make pin SERVICE=ddclient VERSION=3.11.2

# Apply pinned versions
make restart

# Verify pinned versions
make pins
```

### Development Version Strategy

```bash
# Use latest versions for development
make unpin SERVICE=vaultwarden
make unpin SERVICE=caddy

# Apply latest versions
make restart

# Check running versions
docker compose ps --format "table {{.Service}}	{{.Image}}"
```

### Update Management

```bash
# Check for available updates (no changes made)
make check-updates
make check-system-updates

# Update containers with automatic backup
make update-containers

# Update system packages
sudo make update-system
```

## Network and Firewall Configuration

### UFW Firewall Rules

The firewall is automatically configured during setup:

```bash
# View current firewall rules
sudo ufw status numbered

# Update Cloudflare IP ranges
make update-ips
# Or: sudo ./update-cloudflare-ips.sh

# Manual firewall management (if needed)
sudo ufw allow 22/tcp          # SSH access
sudo ufw reload                # Apply changes
```

### Cloudflare IP Management

```bash
# Automatic IP range updates (weekly via cron)
make update-ips

# Preview IP range changes
sudo ./update-cloudflare-ips.sh --dry-run

# Force update without prompts
sudo ./update-cloudflare-ips.sh --force
```

## Backup Configuration

### Local Backup Settings

```bash
# Configure backup retention in .env
BACKUP_RETENTION_DAYS=30              # Full backups
DB_BACKUP_RETENTION_DAYS=14           # Database backups
EMERGENCY_BACKUP_RETENTION_DAYS=90    # Emergency kits

# Manual backup operations
make backup-db                        # Quick database backup
make backup-full                      # Complete system backup
make backup-emergency                 # Disaster recovery kit
make list-backups                     # Show available backups
```

### Remote Backup Configuration

```bash
# Interactive rclone setup
make configure-rclone

# Configure remote name in .env after setup
RCLONE_REMOTE_NAME=your_remote_name

# Test remote backup
./backup.sh --type db --rclone

# Verify remote backups
rclone ls YourRemote:vaultwarden_backups/
```

#### Supported Remote Storage Providers

- **Google Drive**: `rclone config` → Google Drive
- **Amazon S3**: `rclone config` → Amazon S3
- **Dropbox**: `rclone config` → Dropbox
- **Microsoft OneDrive**: `rclone config` → Microsoft OneDrive
- **SFTP**: `rclone config` → SFTP
- **Many others**: See `rclone config` for full list

## Emergency Access Configuration

### Break-Glass Admin Setup

```bash
# Create emergency admin account
make breakglass-create
# Or: sudo ./create-breakglass-admin.sh create

# Check emergency admin status
make breakglass-status
# Or: sudo ./create-breakglass-admin.sh status

# Set/change emergency admin password
make breakglass-password
# Or: sudo ./create-breakglass-admin.sh password
```

### Emergency Admin Properties

- **Separate user account** (not root) with full sudo privileges
- **Password authentication** enabled for OCI serial console access
- **SSH key authentication** for normal remote access
- **Comprehensive audit logging** for all emergency access usage

### OCI Serial Console Access

To use emergency access when SSH is unavailable:

1. **Access OCI Console** → Compute → Instance → Console Connection
2. **Create console connection** (if not exists)
3. **Connect to serial console**
4. **Login with break-glass admin credentials**
5. **Fix SSH/firewall issues**
6. **Delete console connection** for security
7. **Rotate break-glass password**: `make breakglass-password`

## Advanced Configuration

### Custom Resource Limits

```bash
# Adjust container resources in .env
VAULTWARDEN_MEMORY_LIMIT=1g           # Increase for large deployments
VAULTWARDEN_CPU_LIMIT=2.0             # Increase for high load

# Apply changes
make restart
```

### Development Environment Setup

```bash
# Setup with latest versions
sudo ./setup.sh --domain vault-dev.example.com --email dev@example.com --use-latest

# Switch existing deployment to development mode
make unpin SERVICE=vaultwarden
make unpin SERVICE=caddy
make restart
```

### Custom SSL Certificates

If using custom SSL certificates instead of Let's Encrypt:

```bash
# Place certificates in caddy/certs/
# Modify caddy/Caddyfile as needed
# Restart Caddy
docker compose restart caddy
```

## Configuration Validation

### Automated Validation

```bash
# Validate Docker Compose configuration
make config-check

# Comprehensive system health check
make health

# Check configuration syntax
./startup.sh --dry-run
```

### Manual Validation

```bash
# Check environment variables
source .env && env | grep -E "DOMAIN|ADMIN_EMAIL|CLOUDFLARE"

# Verify secrets accessibility
make edit-secrets --test

# Test container configuration
docker compose config
```

## Troubleshooting Configuration Issues

### Common Configuration Problems

#### Environment Variables Not Loading
```bash
# Check .env file syntax (no spaces around = signs)
cat .env | grep -E "^[A-Z_]+=.*$"

# Validate configuration
make config-check

# Restart services to reload configuration
make restart
```

#### Version Management Issues
```bash
# Check current pins
make pins

# Verify running versions
docker compose ps --format "table {{.Service}}	{{.Image}}"

# Reset to known good versions
make pin SERVICE=vaultwarden VERSION=1.30.5
make restart
```

#### Secrets Access Problems
```bash
# Test secrets accessibility
./edit-secrets.sh --test

# Check Age key permissions
ls -la secrets/keys/age-key.txt

# Regenerate Age keys if necessary
./edit-secrets.sh --rotate-keys
```

#### Network Configuration Issues
```bash
# Update Cloudflare IP ranges
make update-ips

# Check firewall status
sudo ufw status

# Verify DNS resolution
nslookup vault.yourdomain.com
```

## Configuration Best Practices

### Production Environment

1. **Pin container versions** for stability: `make pin SERVICE=... VERSION=...`
2. **Use strong secrets** generated by the secrets tool
3. **Configure remote backups** with `make configure-rclone`
4. **Setup break-glass admin** with `make breakglass-create`
5. **Enable monitoring** with comprehensive health checks
6. **Regular updates** with `make check-updates` and planned maintenance

### Security Configuration

1. **Separate API tokens** for DNS and firewall management
2. **Strong admin authentication** with bcrypt hashes
3. **Encrypted backup storage** with Age encryption
4. **Firewall restriction** to Cloudflare IPs only
5. **Regular credential rotation** quarterly
6. **Emergency access testing** annually

### Operational Configuration

1. **Automated backups** with retention policies
2. **Version management** with controlled updates
3. **Health monitoring** with auto-healing
4. **Log management** with appropriate retention
5. **Resource monitoring** with alerting
6. **Documentation maintenance** with current settings

---

This configuration guide provides comprehensive coverage of all configuration aspects for VaultWarden-OCI-Simplified, optimized for small team deployments with emphasis on security, reliability, and ease of management through the new Makefile shortcuts and interactive features.
