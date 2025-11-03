# Configuration Guide - VaultWarden-OCI

This comprehensive configuration guide covers system setup, environment variables, secrets management, and advanced configuration options for VaultWarden-OCI using the current template-based architecture with enhanced resource management and security features.

## Quick Configuration Overview

### Essential Configuration Steps

1. **Template-Based Setup**: `sudo ./setup.sh --auto --domain vault.example.com --email admin@example.com`
2. **Enhanced Secrets Configuration**: `./edit-secrets.sh`
3. **Environment Variables**: Edit generated `.env` file with your specific settings
4. **Emergency Access**: `./create-breakglass-admin.sh`
5. **Remote Backups**: `rclone config` (optional)
6. **Configuration Validation**: `docker compose config`

## Current Template-Based Architecture

### Enhanced Configuration File Structure

All configuration files are generated from enhanced templates:

```bash
# Template files (source of truth):
├── docker-compose.yml.example          # With resource limits and security
├── docker-compose.override.yml.example # Email decoupling (optional)
├── .env.example                        # Environment template
└── Generated files (deployment-specific):
    ├── docker-compose.yml               # Generated from template
    └── .env                            # Generated from template
```

### Current Template Benefits
- **Resource Management**: Container limits optimized for 6GB systems
- **Enhanced Security**: Comprehensive validation and hardening
- **Email Decoupling**: Optional SSMTP container for portability
- **Forensic Logging**: Enhanced log retention and structured JSON
- **Version Control Safe**: No secrets embedded in templates
- **Validation Ready**: Full syntax and dependency checking

## Environment Variables (.env)

### Core Application Settings

Generated from enhanced `.env.example` template during setup:

```bash
# Domain and Email Configuration
DOMAIN=vault.yourdomain.com              # Your VaultWarden domain
ADMIN_EMAIL=admin@yourdomain.com         # Administrator email

# Enhanced Project Configuration
PROJECT_STATE_DIR=/var/lib/vaultwarden   # Data storage directory
SSH_PORT=22                              # SSH port (change if non-standard)
TZ=UTC                                   # Timezone for consistent logging
PUID=1000                                # User ID for containers
PGID=1000                                # Group ID for containers
```

### Cloudflare Integration (Enhanced)

```bash
# Cloudflare Zone Configuration
CLOUDFLARE_ZONE_ID=your_zone_id_here    # Get from Cloudflare dashboard
# Find at: Cloudflare Dashboard → Domain → Overview → Zone ID (right sidebar)

# Enhanced DNS Management
# (API tokens configured in encrypted secrets)
```

### Enhanced Resource Management

```bash
# Container Resource Limits (6GB System Optimization)
# VaultWarden Container
VAULTWARDEN_MEMORY_LIMIT=2G             # Main application (largest allocation)
VAULTWARDEN_MEMORY_RESERVATION=512M     # Guaranteed minimum memory
VAULTWARDEN_CPU_LIMIT=0.6               # 60% of single CPU core
VAULTWARDEN_CPU_RESERVATION=0.2         # 20% guaranteed minimum

# Caddy Container  
CADDY_MEMORY_LIMIT=1G                   # Reverse proxy with SSL
CADDY_MEMORY_RESERVATION=256M           # Guaranteed minimum for SSL
CADDY_CPU_LIMIT=0.3                     # 30% of single CPU core
CADDY_CPU_RESERVATION=0.1               # 10% guaranteed minimum

# Fail2Ban Container
FAIL2BAN_MEMORY_LIMIT=512M              # Log parsing and rule processing
FAIL2BAN_MEMORY_RESERVATION=128M        # Guaranteed minimum for logs
FAIL2BAN_CPU_LIMIT=0.2                  # 20% of single CPU core
FAIL2BAN_CPU_RESERVATION=0.05           # 5% guaranteed minimum
```

### Enhanced Backup Configuration

```bash
# Local Backup Settings with Atomic Operations
BACKUP_RETENTION_DAYS=30                # Days to keep local full backups
DB_BACKUP_RETENTION_DAYS=14             # Days to keep database backups
EMERGENCY_BACKUP_RETENTION_DAYS=90      # Days to keep emergency kits

# Remote Backup Configuration (Optional)
RCLONE_REMOTE_NAME=your_remote_name     # Configure with: rclone config
# Examples: "gdrive", "s3", "dropbox", "onedrive"

# Enhanced Backup Features
BACKUP_VERIFICATION=true                # Enable backup integrity checking
BACKUP_ATOMIC_OPERATIONS=true           # Use atomic backup operations
```

### Container Version Management (Enhanced)

```bash
# Production Mode (Recommended - Pinned Versions)
# Set automatically by setup.sh --auto for stability
VAULTWARDEN_VERSION=1.30.5             # Pin to stable version
CADDY_VERSION=2.8.4-cloudflare         # Pin with Cloudflare module  
FAIL2BAN_VERSION=1.1.0                 # Pin to stable version

# Development Mode (Latest Versions)
# Set by setup.sh --use-latest (versions commented out)
#VAULTWARDEN_VERSION=1.30.5            # Commented = use latest
#CADDY_VERSION=2.8.4-cloudflare        # Commented = use latest
#FAIL2BAN_VERSION=1.1.0                # Commented = use latest
```

### Enhanced Email Configuration

```bash
# SMTP Settings for Notifications (Optional)
SMTP_HOST=smtp.gmail.com               # SMTP server
SMTP_PORT=587                          # SMTP port (587 for STARTTLS)
SMTP_FROM=vaultwarden@yourdomain.com   # From address
SMTP_FROM_NAME=VaultWarden-Notifications # Display name
SMTP_USERNAME=your_email@gmail.com     # SMTP username
SMTP_SECURITY=starttls                 # Security method
# SMTP_PASSWORD configured in encrypted secrets

# Email Decoupling (Optional - uses override template)
USE_SSMTP_CONTAINER=false              # Enable dedicated SSMTP container
```

## Enhanced Secrets Management

### Encrypted Secrets with Privacy Protection

Use the enhanced interactive secrets editor with improved security:

```bash
# Edit encrypted secrets with enhanced privacy
./edit-secrets.sh

# Enhanced security features:
# - SOPS key path never exposed in process list
# - Secure temporary file handling  
# - Automatic backup creation before editing
# - Comprehensive validation after editing
# - Editor security validation
```

### Required Secrets (Enhanced)

#### VaultWarden Admin Authentication
```yaml
# Admin token for API access (32-character hex string)  
admin_token: "1234567890abcdef1234567890abcdef"

# Admin panel basic auth hash (bcrypt - use caddy hash-password)
admin_basic_auth_hash: "$2b$12$hash_generated_by_caddy_tool"
```

#### Cloudflare API Tokens (Enhanced)
```yaml
# DNS management token for Caddy (Zone:DNS:Edit + Zone:Zone:Read)
caddy_cloudflare_dns_token: "your_dns_management_token"

# Firewall management token for Fail2Ban (Zone:Firewall Services:Edit)
fail2ban_cloudflare_firewall_token: "your_firewall_management_token"
```

#### Optional Secrets (Enhanced)
```yaml
# SMTP password for email notifications
smtp_password: "your_smtp_password"

# Bitwarden push notifications (optional)
push_installation_id: "your_installation_id"
push_installation_key: "your_installation_key"
```

### Enhanced Secrets Management Commands

```bash
# Interactive secrets editing with enhanced privacy (recommended)
./edit-secrets.sh

# Editor selection with validation
./edit-secrets.sh --editor vim

# Skip backup creation (not recommended)
./edit-secrets.sh --no-backup

# Skip validation after editing (not recommended) 
./edit-secrets.sh --no-validation

# Validate secrets without editing
sops -d secrets/secrets.yaml > /dev/null && echo "Secrets valid"
```

## Enhanced Container Configuration

### VaultWarden Application Settings (Enhanced)

#### Enhanced Security Configuration
```bash
# These environment variables affect VaultWarden behavior:
SIGNUPS_ALLOWED=false                  # Disable open registration
INVITATIONS_ALLOWED=true              # Admin-controlled invitations only
EMERGENCY_ACCESS_ALLOWED=true         # Allow emergency access feature
PASSWORD_ITERATIONS=350000            # High iteration count (was 600000)
PASSWORD_HINTS_ALLOWED=false          # Don't allow password hints
SHOW_PASSWORD_HINT=false              # Don't show password hints
WEB_VAULT_ENABLED=true                # Enable web vault interface
WEBSOCKET_ENABLED=false               # Disable WebSocket (comment to enable)

# Enhanced Logging and Forensics
LOG_FILE=/logs/vaultwarden.log        # Structured log file location
LOG_LEVEL=warn                        # Log level (error, warn, info, debug)
EXTENDED_LOGGING=true                 # Enhanced audit logging
```

#### Enhanced Database Configuration
```bash
# SQLite database settings with performance optimization
DATABASE_MAX_CONNS=10                 # Maximum database connections
DATABASE_URL=data/db.sqlite3          # Database path (relative to container)

# Database optimization (applied by maintenance scripts)
# - WAL mode for better concurrency
# - Automatic VACUUM operations (offline)
# - Integrity checking before operations
```

### Enhanced Caddy Configuration

#### Enhanced Logging and Forensics
The current Caddyfile includes comprehensive forensic logging:

```caddyfile
# Located in: caddy/Caddyfile
# Enhanced log retention (60x improvement):
log {
    output file /logs/access.log {
        roll_size 50MB      # Increased from 10MB
        roll_keep 20        # Increased from 5 files
        roll_keep_for 30d   # Keep for 30 days
    }
    format json {
        time_format "2006-01-02T15:04:05.000Z07:00"
    }
}

# Specialized logging for different endpoints:
# - Admin access log: 25MB x 30 files = 750MB (90-day retention)
# - Auth attempts log: 25MB x 30 files = 750MB (90-day retention)  
# - Security blocks log: 10MB x 50 files = 500MB (180-day retention)
```

#### Enhanced Rate Limiting
```caddyfile
# Stricter rate limiting appropriate for password manager:
rate_limit {
    zone static_rl {
        capacity 20         # Reduced from 60
    }
    zone admin_rl {
        capacity 5          # Very strict for admin panel
    }
    zone api_auth_rl {      # NEW: API authentication rate limiting
        match_path /api/accounts/prelogin /identity/connect/token
        capacity 10         # 10 auth attempts per 5 minutes per IP
    }
}
```

### Enhanced Fail2Ban Configuration

#### Dual Cloudflare + UFW Action
```ini
# Located in: fail2ban/action.d/cloudflare-apiv4.conf
# Current advanced features:
# - Idempotent operations (checks existing rules before creating)
# - Retry logic with exponential backoff
# - UFW fallback if Cloudflare API fails
# - Transactional ban/unban operations
# - Comprehensive logging and status reporting
```

#### Enhanced Filter Configuration (No Dependencies)
```ini
# All filters now use regex (no JMESPath dependency):

# fail2ban/filter.d/vaultwarden-auth.conf
# - Authentication failure detection via VaultWarden logs

# fail2ban/filter.d/vaultwarden-admin.conf  
# - Admin panel attack detection

# fail2ban/filter.d/vaultwarden-web-caddy.conf
# - Web interface protection via Caddy JSON logs
# - Rate limiting detection (429 status codes)
# - Fallback regex patterns for compatibility
```

#### Enhanced Jail Configuration
```ini
# Located in: fail2ban/jail.d/vaultwarden-oci.conf
# Current jail settings optimized for password manager:

[vaultwarden-auth]
maxretry = 3               # Strict retry limit
bantime = 2h              # 2-hour ban
action = %(action_mwl)s cloudflare-apiv4

[vaultwarden-admin]  
maxretry = 2               # Very strict for admin panel
bantime = 24h             # 24-hour ban
action = %(action_mwl)s cloudflare-apiv4

[vaultwarden-web]
maxretry = 10             # More lenient for web interface
bantime = 1h              # 1-hour ban
action = %(action_mwl)s cloudflare-apiv4
```

## Enhanced Template Management

### Editing Templates (Current Best Practice)

For ongoing maintenance, always edit template files as source of truth:

```bash
# Edit templates (never edit generated files directly)
nano docker-compose.yml.example # For container/service changes
nano .env.example # For new environment variables

# Apply template changes with validation
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# Restart services to apply changes
./startup.sh --force-restart
```

### Enhanced Template Validation

```bash
# Validate templates before applying (recommended)
docker compose -f docker-compose.yml.example config

# Check for common template issues
grep -n "platform:\|linux/arm64" docker-compose.yml.example

# Validate resource limits make sense for your system
grep -A 5 -B 5 "memory:\|cpus:" docker-compose.yml.example
```

### Template Customization Examples

#### Email Decoupling (Optional)
```bash
# Enable email decoupling using override template
cp docker-compose.override.yml.example docker-compose.override.yml

# Configure SMTP settings in .env
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
# ... (other SMTP settings)

# Restart to apply email decoupling
docker compose up -d
```

#### Resource Limit Adjustment
```yaml
# In docker-compose.yml.example, adjust resource limits:
deploy:
  resources:
    limits:
      memory: 4G        # Increase for larger systems
      cpus: '1.0'       # Increase for more CPU cores
```

## Enhanced Network and Firewall Configuration

### UFW Firewall with Enhanced Safety

The firewall is configured with enhanced safety measures:

```bash
# View current firewall status
sudo ufw status numbered

# Enhanced firewall update with race condition fixes
./maintenance.sh --update-firewall

# The enhanced process:
# 1. Adds new Cloudflare rules before removing old ones
# 2. Validates rules before applying
# 3. Provides clear warnings if API fails
# 4. Falls back to safe default rules
```

### Enhanced Cloudflare IP Management

```bash
# Safe firewall updates (prevents service interruption)
./maintenance.sh --update-firewall

# Features:
# - Race condition fixes (add before remove)  
# - API failure handling with clear warnings
# - Safe fallback if Cloudflare API is unavailable
# - Comprehensive logging of all changes
```

## Enhanced Backup Configuration

### Atomic Backup Operations

```bash
# Configure enhanced backup settings in .env
BACKUP_RETENTION_DAYS=30              # Full backups
DB_BACKUP_RETENTION_DAYS=14           # Database backups  
EMERGENCY_BACKUP_RETENTION_DAYS=90    # Emergency kits

# Enhanced backup operations with atomic features:
./backup.sh --type db                 # Atomic database backup
./backup.sh --type full               # Complete system backup
./backup.sh --type emergency          # Disaster recovery kit

# Enhanced backup listing with detailed information:
./backup.sh --list
# Shows: timestamp, size, type, integrity status, file ID
```

### Safe Database Operations

```bash
# Enhanced database maintenance (stops VaultWarden first)
./maintenance.sh --comprehensive

# Safe database operations include:
# 1. Stop VaultWarden service
# 2. WAL checkpoint before operations
# 3. Integrity check before VACUUM
# 4. Safe offline VACUUM operation
# 5. Integrity check after operations
# 6. Restart VaultWarden service
# 7. Verify service health
```

### Remote Backup with Enhanced Security

```bash
# Configure encrypted remote backup
rclone config

# Set remote name in .env
RCLONE_REMOTE_NAME=your_secure_remote

# Test enhanced remote backup
./backup.sh --type db --rclone

# Enhanced remote features:
# - Age encryption before upload
# - Integrity verification before encryption
# - Secure cleanup of temporary files
# - Comprehensive error handling
```

## Enhanced Emergency Access Configuration

### Break-Glass Admin with Enhanced Security

```bash
# Create emergency admin with validation
./create-breakglass-admin.sh

# Enhanced security features:
# - Validates script ownership (prevents privilege escalation)
# - Creates separate non-root user with sudo privileges
# - Configures secure SSH key authentication
# - Enables password auth for OCI console access only
# - Comprehensive audit logging
# - Secure credential generation and storage
```

### Emergency Admin Commands

```bash
# Check emergency admin status
./create-breakglass-admin.sh --status

# Generate new emergency password
./create-breakglass-admin.sh --password

# Validate emergency admin security
./create-breakglass-admin.sh --validate

# Remove emergency admin (when no longer needed)
./create-breakglass-admin.sh --remove
```

## Enhanced Configuration Best Practices

### Current Template-Based Environment

1. **Edit templates only**: Always modify `.example` files as source of truth
2. **Use enhanced setup**: Apply changes via `sudo ./setup.sh --force --validate`
3. **Resource awareness**: Consider 6GB system limitations in customizations
4. **Security validation**: Use enhanced security validation functions
5. **Document customizations**: Maintain clear documentation in template comments

### Enhanced Production Environment

1. **Use resource limits**: Container limits prevent system resource exhaustion
2. **Use pinned versions**: Automatically set by `setup.sh --auto` for stability
3. **Enhanced secrets**: SOPS key paths never exposed in process lists
4. **Atomic operations**: Backup and maintenance operations prevent corruption
5. **Comprehensive monitoring**: Use comprehensive health checks with diagnostics
6. **Forensic logging**: 3GB log capacity for incident investigation

### Enhanced Security Configuration

1. **Dual API tokens**: Separate tokens for DNS and firewall management
2. **Enhanced authentication**: Secure admin panel with bcrypt hashing
3. **Comprehensive validation**: Script ownership and permission validation
4. **Enhanced firewall**: Safe Cloudflare IP updates with race condition fixes
5. **Secure automation**: Cron scripts validated for privilege escalation risks
6. **Enhanced emergency access**: Break-glass admin with comprehensive security

### Enhanced Operational Excellence

1. **Template-driven changes**: All configuration via template modification
2. **Atomic operations**: Backup and database operations prevent corruption
3. **Resource optimization**: Container limits optimized for small teams
4. **Comprehensive health**: Use comprehensive diagnostics for status
5. **Enhanced recovery**: Multiple backup types with integrity verification
6. **Forensic readiness**: Enhanced logging for incident investigation

---

This enhanced configuration guide reflects the current state of VaultWarden-OCI with comprehensive resource management, advanced security features, enhanced operational capabilities, and forensic logging optimized for small teams requiring reliable, maintainable password management infrastructure.
