# Configuration Guide - VaultWarden-OCI

This comprehensive configuration guide covers system setup, environment variables, secrets management, and advanced configuration options for VaultWarden-OCI using the new template-based architecture.

## Quick Configuration Overview

### Essential Configuration Steps

1. **Template-Based Setup**: `sudo ./setup.sh --auto --domain vault.example.com --email admin@example.com`
2. **Secrets Configuration**: `./edit-secrets.sh`
3. **Environment Variables**: Edit generated `.env` file with your specific settings
4. **Emergency Access**: `./create-breakglass-admin.sh`
5. **Remote Backups**: `rclone config` (optional)
6. **Validation**: `docker compose config`

## Template-Based Configuration

### Configuration File Generation

All configuration files are now generated from templates:

```bash
# Template files (source of truth):
├── docker-compose.yml.example
├── .env.example
└── Generated files:
    ├── docker-compose.yml
    └── .env
```

### Template Benefits
- **Single source of truth**: Edit templates, not generated files
- **No hardcoded values**: Platform-agnostic configurations
- **Easy maintenance**: Version control friendly
- **Consistent deployments**: Same templates produce identical configurations

## Environment Variables (.env)

### Core Application Settings

Generated from `.env.example` template during setup:

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
RCLONE_REMOTE_NAME=your_remote_name     # Configure with: rclone config
# Examples: "gdrive", "s3", "dropbox", "onedrive"
```

### Container Version Management

```bash
# Production Mode (Recommended - Pinned Versions)
# Set automatically by setup.sh --auto
VAULTWARDEN_VERSION=1.30.5             # Pin to stable version
CADDY_VERSION=2.8.4                    # Pin to stable version
FAIL2BAN_VERSION=1.1.0                 # Pin to stable version
DDCLIENT_VERSION=3.11.2                # Pin to stable version

# Development Mode (Latest Versions)
# Set by setup.sh --use-latest (versions commented out)
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
# SMTP_PASSWORD configured in secrets (./edit-secrets.sh)
```

## Secrets Management

### Encrypted Secrets Configuration

Use the interactive secrets editor to configure sensitive data:

```bash
# Edit encrypted secrets
./edit-secrets.sh
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
# DNS updates token (Zone:DNS:Edit + Zone:Zone:Read permission)
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
./edit-secrets.sh

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

### Enhanced fail2ban Intrusion Prevention

#### Enhanced Jail Configuration with Rate Limiting
```ini
# Located in: fail2ban/jail.local
[vaultwarden-admin]
enabled = true
filter = vaultwarden-admin
logpath = /var/log/vaultwarden/*.log
maxretry = 3
bantime = 3600
findtime = 600
action = cloudflare-optimized[name=%(name)s]

[vaultwarden-api]
enabled = true
filter = vaultwarden-api
logpath = /var/log/vaultwarden/*.log
maxretry = 5
bantime = 3600
findtime = 600
action = cloudflare-optimized[name=%(name)s]
```

#### Enhanced Cloudflare Action with Rate Limiting
```ini
# Located in: fail2ban/action.d/cloudflare-optimized.conf
# Features:
# - Rate limiting (max 30 API calls/minute)
# - Comprehensive error handling and logging
# - Graceful failure recovery
# - No more API abuse or hanging requests
```

## Template Management

### Editing Templates

For ongoing maintenance, edit the template files (source of truth):

```bash
# Edit templates
nano docker-compose.yml.example # For Docker Compose changes
nano .env.example # For new environment variables

# Apply template changes
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
./startup.sh --force-restart # Apply changes
```

### Template Validation

```bash
# Validate templates before applying
docker compose config

# Check for template syntax issues
cat docker-compose.yml.example | grep -n "platform:\|linux/arm64"
```

## Network and Firewall Configuration

### UFW Firewall Rules

The firewall is automatically configured during setup with enhanced warnings:

```bash
# View current firewall rules
sudo ufw status numbered

# Update Cloudflare IP ranges with improved error handling
sudo ./update-cloudflare-ips.sh

# Manual firewall management (if needed)
sudo ufw allow 22/tcp          # SSH access
sudo ufw reload                # Apply changes
```

### Enhanced Cloudflare IP Management

```bash
# Automatic IP range updates (weekly via cron) with improved UFW setup
sudo ./update-cloudflare-ips.sh

# Preview IP range changes with clear warnings
sudo ./update-cloudflare-ips.sh --dry-run

# Force update without prompts
sudo ./update-cloudflare-ips.sh --force
```

## Backup Configuration

### Local Backup Settings with Atomic Operations

```bash
# Configure backup retention in .env
BACKUP_RETENTION_DAYS=30              # Full backups
DB_BACKUP_RETENTION_DAYS=14           # Database backups
EMERGENCY_BACKUP_RETENTION_DAYS=90    # Emergency kits

# Enhanced backup operations with atomic operations
./backup.sh --type db                 # Atomic database backup
./backup.sh --type full               # Complete system backup
./backup.sh --type emergency          # Disaster recovery kit
./backup.sh --list                    # Enhanced listing with timestamps, sizes, IDs
```

### Remote Backup Configuration

```bash
# Interactive rclone setup
rclone config

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
# Create emergency admin account for OCI serial console access
./create-breakglass-admin.sh

# Check emergency admin status
./create-breakglass-admin.sh status

# Set/change emergency admin password
./create-breakglass-admin.sh password
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
7. **Rotate break-glass password**: `./create-breakglass-admin.sh password`

## Configuration Best Practices

### Template-Based Environment

1. **Edit templates**: Always edit `.example` files as source of truth
2. **Use setup.sh**: Apply changes via `sudo ./setup.sh --force`
3. **Version control templates**: Keep `.example` files in version control
4. **Validate first**: Always run `docker compose config` before deployment
5. **Document changes**: Document customizations in template comments

### Production Environment

1. **Use pinned versions** for stability (automatically set by `setup.sh --auto`)
2. **Use strong secrets** generated by the secrets tool
3. **Configure remote backups** with `rclone config`
4. **Setup break-glass admin** with `./create-breakglass-admin.sh`
5. **Enable monitoring** with comprehensive health checks
6. **Regular updates** with planned maintenance

### Security Configuration

1. **Separate API tokens** for DNS and firewall management
2. **Strong admin authentication** with bcrypt hashes
3. **Encrypted backup storage** with Age encryption
4. **Enhanced firewall restriction** with improved UFW setup
5. **Regular credential rotation** quarterly
6. **Emergency access testing** annually

### Operational Configuration

1. **Template-based approach** for all configuration changes
2. **Atomic backup operations** with enhanced reliability
3. **Enhanced fail2ban** with rate limiting and error handling
4. **Interactive restore** with backup selection
5. **Comprehensive health monitoring** with auto-healing
6. **Break-glass admin access** for emergency recovery

---

This configuration guide provides comprehensive coverage of all configuration aspects for VaultWarden-OCI, incorporating the latest template-based architecture, enhanced fail2ban security with rate limiting, atomic backup operations, and quality of life improvements optimized for small team deployments with reliability and ease of management.
