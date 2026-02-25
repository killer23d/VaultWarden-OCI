# VaultWarden-OCI

**Production-Ready VaultWarden for Small Teams**

A streamlined, secure, and operationally excellent VaultWarden deployment optimized for teams of 10 or fewer users. Designed for cloud platforms like Oracle Cloud Infrastructure (OCI) with dynamic IPs, this project focuses on essential functionality, ease of maintenance, and robust security for reliable password management.

## 🎯 What Makes This Different

This is a **template-based, hardened deployment** designed specifically for small teams who want:

- **Set-and-forget reliability** with template-based maintenance and automated operations
- **Template-first approach** - all configuration files maintained as `.example` templates
- **Cloudflare-only blocking** for web traffic (iptables removed from proxied services)
- **Robust security** with comprehensive Cloudflare integration and encrypted secrets
- **Simple operations** with comprehensive automation and health monitoring
- **Emergency recovery** with break-glass admin access for critical situations
- **Quality of life improvements** with Makefile shortcuts and interactive tools
- **Clear documentation** focused on practical deployment and maintenance

### Key Features

- **Template-Based Configuration**: All config files generated from maintainable `.example` templates
- **Enhanced Security**: Cloudflare-only blocking for web traffic, local iptables only for SSH
- **Resource Management**: Container limits optimized for 6GB systems with balanced allocation
- **Core Scripts**: 13 essential scripts for complete lifecycle management
- **Unified Libraries**: 5 shared libraries (common, Docker, crypto, security, backup_utils) for consistent functionality
- **Dynamic DNS**: Automatic Cloudflare DNS record updates
- **Edge Security**: Cloudflare proxy with Fail2ban integration for global IP blocking
- **Firewall Hardening**: UFW configured with Cloudflare IP validation and safe fallback
- **Encrypted Secrets**: Age + SOPS for industry-standard secrets management
- **Automated Operations**: Comprehensive cron jobs for backups, updates, and maintenance
- **Emergency Access**: Break-glass admin for OCI serial console recovery
- **Interactive Tools**: Makefile shortcuts and interactive backup/restore functionality
- **Containerized Email**: Postfix sidecar for reliable email delivery without host dependencies
- **Self-Healing**: Health checks with auto-recovery for unhealthy containers

## ⚡ Quick Start (15 Minutes)

Deploy a secure VaultWarden instance:

```bash
# 1. Clone and prepare
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

# 2. Run automated setup (uses template-based approach)
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto

# 3. Log out and log back in
#    setup.sh adds your user to the docker group. You must start a fresh
#    session for that group membership to take effect before running any
#    docker or make commands.
exit
# Re-SSH into your instance, then cd back into the project directory:
cd VaultWarden-OCI

# 4. Configure secrets (CRITICAL - set admin_basic_auth_hash and API tokens)
./edit-secrets.sh

# 5. Configure environment (.env file - set CLOUDFLARE_ZONE_ID, etc.)
nano .env

# 6. Start services
./startup.sh
# Or use Makefile: make start

# 7. Setup automation (recommended for set-and-forget operation)
sudo ./cron-setup.sh --install

# 8. Create break-glass admin for emergency access (RECOMMENDED)
./create-breakglass-admin.sh
# Or use Makefile: make breakglass-create

# 9. Verify deployment
./health.sh
# Or use Makefile: make health
```

**🎉 Your VaultWarden is now operational at https://vault.yourdomain.com**

## 🛠️ Template-Based Architecture

### Configuration Management

All configuration files are managed through templates for easier maintenance:

```
📁 Project Structure
├── docker-compose.yml.example          # Template for Docker Compose
├── docker-compose.override.yml.example # Template for email decoupling
├── .env.example                        # Template for environment variables
├── docker-compose.yml                  # Generated from template by setup.sh
├── .env                               # Generated from template by setup.sh
├── caddy/Caddyfile                    # Enhanced reverse proxy configuration
├── fail2ban/
│   ├── action.d/
│   │   ├── cloudflare-apiv4.conf      # Cloudflare API blocking action
│   │   └── smtp.conf                  # Email notification action
│   ├── filter.d/                      # Comprehensive filter configurations
│   │   ├── vaultwarden-auth.conf      # Authentication failure detection
│   │   ├── vaultwarden-admin.conf     # Admin panel protection
│   │   └── vaultwarden-web-caddy.conf # Web interface protection
│   └── jail.d/
│       └── vaultwarden-oci.conf       # Complete jail configuration
└── lib/
    ├── common.sh                      # Shared utility functions
    ├── crypto.sh                      # Encryption/decryption utilities
    ├── docker.sh                      # Docker management functions
    ├── security.sh                    # Security validation functions
    └── backup_utils.sh                # Backup-specific utilities
```

### Benefits of Template Approach

✅ **Single source of truth** - Edit templates, not generated files
✅ **No more hardcoded values** - Platform architecture issues eliminated
✅ **Easy maintenance** - Direct file editing with syntax highlighting
✅ **Testable configuration** - `docker compose config` works immediately
✅ **Version control friendly** - Clean diffs and proper file history
✅ **Consistent deployments** - Same templates produce identical configurations

## 🏗️ Architecture

### Simple, Secure Stack

```
 Cloudflare Edge (Proxy, WAF, DNS)
       ↑ ↓
 Host Firewall (UFW - Cloudflare IPs + SSH only)
       ↑ ↓
┌─────────────────────────────────────────┐
│      Template Management Layer          │
│  ┌──────────────┐  ┌──────────────┐    │
│  │.example files│→ │Generated files│    │ ── Enhanced Setup Process
│  │(Templates)   │  │(.env, compose)│    │
│  └──────────────┘  └──────────────┘    │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│           Management Layer              │
│  ┌──────────┐  ┌──────────────┐        │
│  │13 Scripts│  │5 Libraries   │        │ ── Encrypted Secrets (Age + SOPS)
│  │(Ops)     │  │(Common+Utils)│        │
│  └──────────┘  └──────────────┘        │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│        Docker Application Stack         │
│  ┌──────┐  ┌───────────┐  ┌──────────┐ │
│  │Caddy │→ │VaultWarden│  │ Postfix  │ │
│  │(SSL) │  │(App)      │  │ (Email)  │ │
│  └──────┘  └───────────┘  └──────────┘ │
│   1GB Limit   2GB Limit                │
│  ┌────────┐                             │
│  │fail2ban│─────────────────────────────┤ Cloudflare-only for web
│  │(Sec)   │     1GB Limit               │ Local iptables only for SSH
│  └────────┘                             │
└─────────────────────────────────────────┘
      ↓
┌─────────────────────────────────────────┐
│         Emergency Recovery Layer        │
│  ┌──────────────┐                       │
│  │Break-Glass   │ ← OCI Serial Console  │ ── Emergency Access Path
│  │Admin Account │   Access              │
│  └──────────────┘                       │
└─────────────────────────────────────────┘
```

## 🛠️ Core Scripts

### Essential Operations

| Script | Purpose | Key Features | Frequency |
| :-- | :-- | :-- | :-- |
| `./setup.sh` | One-time system setup | Template-based config generation, UFW validation | Once |
| `./startup.sh` | Start/stop/restart services | **Secure secrets (umask 077)**, log perm fixes, sudo-aware health check | As needed |
| `./health.sh` | System health monitoring | **Auto-recovery (`--auto-recover`)**, sudo-aware backup verification | Automated |
| `./backup.sh` | Create encrypted backups | Atomic operations, integrity verification, full verification mode | Daily (automated) |
| `./restore.sh` | Restore from encrypted backups | Interactive selection, validation | Emergency |

### Configuration & Maintenance

| Script | Purpose | Key Features | Frequency |
| :-- | :-- | :-- | :-- |
| `./edit-secrets.sh` | Secure secrets management | Enhanced privacy, secure environment handling | Initial + changes |
| `./update.sh` | Update containers/system packages | Automated backup before updates | Weekly (automated) |
| `./maintenance.sh` | System cleanup, optimization, DNS update, and on-demand DB/email maintenance | Safe database operations, comprehensive cleanup, unified sub-commands | Monthly (automated) |
| `./cron-setup.sh` | Configure automation | Secure privilege management, validation | Once |

### Emergency & Recovery

| Script | Purpose | Key Features | Frequency |
| :-- | :-- | :-- | :-- |
| `./create-breakglass-admin.sh` | Emergency admin for serial console | OCI console access, secure creation | Once + as needed |
| `./maintenance.sh --db-maint` | Deep database maintenance | Safe offline SQLite VACUUM + WAL checkpoint | Monthly (automated) |
| `./maintenance.sh --update-dns` | Manual DNS updates | Cloudflare API integration | As needed |

### Email Testing

| Script | Purpose | Key Features | Frequency |
| :-- | :-- | :-- | :-- |
| `./maintenance.sh --test-email` | Test email configuration | Tests Postfix container, validates SMTP relay, end-to-end delivery check | Setup + troubleshooting |

## 🚀 Makefile Quick Reference

The Makefile provides convenient shortcuts for common operations:

### Service Management

```bash
make up              # Start all services
make down            # Stop all services
make restart         # Restart with enhanced startup script
make start           # Alias for up
make stop            # Alias for down
make status          # Show service status
```

### Monitoring & Health

```bash
make health          # Run health checks
make health-email    # Health check with email notification
make logs            # Show all service logs
make logs SERVICE=vaultwarden  # Show specific service logs
make logs-postfix    # Shortcut to view Postfix email logs
```

### Backup & Restore

```bash
make backup          # Create database backup (silent — no email)
make backup-full     # Create full system backup (emails on completion)
make backup-emergency # Create emergency recovery kit (emails on completion)
make list-backups    # List available backups
make restore         # Interactive restore
```

### Maintenance

```bash
make update          # Update container images
make update-system   # Update system and containers
make maintenance     # Run full maintenance (cleanup, Docker, DB, DNS, firewall)
make maintenance-full # Full maintenance with email notification
make update-dns      # Update Cloudflare DNS record to current IP
make db-maint        # Deep database maintenance (requires sudo)
```

### Security

```bash
make breakglass-create  # Create emergency admin
make breakglass-status  # Check emergency admin status
make breakglass-remove  # Remove emergency admin
```

### Development & Testing

```bash
make dev-setup       # Setup development environment
make test            # Run all tests (secrets + email + config)
make test-secrets    # Test secrets decryption
make test-email      # Test Postfix email configuration (verbose)
make test-config     # Validate Docker Compose configuration
make dry-run         # Preview all operations without executing
make fmt             # Validate all configuration files
make shell           # Open shell in container (default: vaultwarden)
make shell SERVICE=caddy # Open shell in specific container
```

## 🔧 Enhanced Security Features

### Current Security Improvements

- **Cloudflare-Only Web Blocking**:
    - **CRITICAL**: All web-facing jails use Cloudflare API exclusively
    - iptables removed from proxied services (traffic comes from Cloudflare IPs, not attacker IPs)
    - Local iptables ONLY used for SSH (direct connection, not proxied)
    - Advanced retry logic with exponential backoff
    - Comprehensive regex-based filtering (no external dependencies)
    - Rate limiting detection and response
- **Secure Startup & Secrets**:
    - `startup.sh` enforces `umask 077` during secrets generation (files created with 600 permissions)
    - Atomic file creation avoids race conditions
    - Log directories automatically created with correct PUID:PGID ownership
    - Health checks automatically escalate privileges (sudo) only when needed for backup verification
- **Resilient Health Monitoring**:
    - `health.sh` includes `--auto-recover` to restart unhealthy containers automatically
    - Robust backup verification uses `sudo` safely (interactive vs non-interactive detection)
    - Proper error handling for domain connectivity checks
- **Resource Management**:
    - Container memory limits optimized for 6GB systems
    - Balanced CPU allocation preventing monopolization
    - Memory reservations ensuring stable operation
- **Template Security**:
    - No hardcoded credentials in generated files
    - Consistent security configurations across deployments
    - Version control safe templates with validation
- **Containerized Email**:
    - Postfix sidecar eliminates host mail utility dependencies
    - Dedicated container for SMTP relay (port 587)
    - Consistent SMTP configuration across all services (scripts and fail2ban)
    - Enhanced reliability and troubleshooting via unified `--test-email` diagnostic

### Multi-Layer Security

- **Encrypted Secrets**: All sensitive data encrypted with Age and managed via SOPS
- **Cloudflare Integration**:
    - Traffic proxied through Cloudflare's edge network
    - **Cloudflare-only blocking for web**: All web-facing jails use CF API only (iptables ineffective due to proxy)
    - **Local iptables for SSH**: SSH jail uses iptables since it's direct connection
    - Automatic IP list updates with safe firewall integration
- **Host Firewall**: UFW configured with Cloudflare IP validation and safe fallback
- **HTTPS Enforcement**: Automatic HTTPS via Caddy with Let's Encrypt
- **Security Headers**: Comprehensive security headers (HSTS, CSP, etc.)
- **Rate Limiting**: API and admin endpoint protection with forensic logging
- **Admin Protection**: Basic authentication with bcrypt hashing
- **Container Security**: Non-root execution, capability restrictions, resource constraints
- **Emergency Recovery**: Secure break-glass admin access

## 📦 Backup & Recovery

### Enhanced Backup Strategy

- **Atomic Operations**: Prevents corrupt backups during creation
- **Safe Database Operations**: WAL checkpoints for live snapshots
- **Full Verification Mode**: Optional end-to-end recoverability testing
- **Conservative Space Management**: Disk space validation before operations
- **Daily**: Encrypted database backups (retention: 14 days)
- **Weekly**: Encrypted full system backups (retention: 30 days)
- **Manual**: Emergency recovery kits (retention: 90 days)
- **Offsite**: Automatic rclone sync to configured remote storage
- **Verification**: Pre-encryption integrity checks and optional full verification

### Backup Operations

```bash
# Create different types of backups
./backup.sh --type db          # Quick database backup
./backup.sh --type full        # Complete system backup
./backup.sh --type emergency   # Disaster recovery kit

# With full verification (recommended weekly)
./backup.sh --type full --full-verification

# With offsite sync
./backup.sh --type db --rclone  # Backup with remote sync

# List and manage backups
./backup.sh --list             # Show all available backups

# Using Makefile
make backup                    # Database backup (silent)
make backup-full              # Full system backup (emails on completion)
make backup-emergency         # Emergency kit (emails on completion)
make list-backups             # List backups
```

### Recovery Process

```bash
# Interactive restore (recommended)
./restore.sh

# Or restore specific backup file
./restore.sh --file /path/to/backup-file.age

# Using Makefile
make restore                   # Interactive restore
```

## 🔧 Configuration

### Template-Based Configuration

1. **Initial Setup** (uses templates):

```bash
# Setup copies and populates templates
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com
```

2. **Cloudflare Setup**:

```bash
# Create two API tokens at https://dash.cloudflare.com/profile/api-tokens
# Token 1: DNS (Zone:DNS:Edit + Zone:Zone:Read for your domain)
# Token 2: Firewall (Zone:Firewall Services:Edit for your domain)
```

3. **Environment Configuration** (.env):

```bash
# Generated from .env.example, then customize:
nano .env
# Set: CLOUDFLARE_ZONE_ID, RCLONE_REMOTE_NAME, etc.
```

4. **Secrets Configuration**:

```bash
# Securely edit secrets
./edit-secrets.sh
# Set: admin_basic_auth_hash, caddy_cloudflare_dns_token, fail2ban_cloudflare_firewall_token
# Generate bcrypt hash: docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password
```

5. **Email Configuration**:

```bash
# Email uses a containerized Postfix relay (no host mail dependencies).
# Configure SMTP relay settings in .env:
nano .env
# Set: SMTP_HOST, SMTP_PORT, SMTP_USERNAME, ALLOWED_SENDER_DOMAINS, etc.

# Set SMTP password in secrets:
./edit-secrets.sh
# Set: smtp_password

# Test email functionality:
./maintenance.sh --test-email --verbose
# Or use Makefile: make test-email
```

6. **Emergency Access Setup** (Recommended):

```bash
./create-breakglass-admin.sh
# Or use: make breakglass-create
# Creates emergency admin account for OCI serial console access
```

### Template Maintenance

For ongoing maintenance, edit the template files:

```bash
# Edit templates (source of truth)
nano docker-compose.yml.example  # For Docker Compose changes
nano .env.example               # For new environment variables

# Apply template changes
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# Restart to apply changes
./startup.sh --force-restart    # Apply changes
# Or use: make restart
```

## 🆘 Troubleshooting

### Common Issues

**Service Won't Start**:

```bash
# Check service status (uses enhanced health check)
./health.sh
# Or: make health

# View container logs
docker compose logs vaultwarden
# Or: make logs SERVICE=vaultwarden

# Validate configuration
docker compose config
# Or: make test-config

# Force restart with fresh configuration
./startup.sh --force-restart
# Or: make restart
```

**Template Issues**:

```bash
# Validate templates
docker compose config

# Re-generate from templates
sudo ./setup.sh --force --domain your-domain.com --email your-email@domain.com

# Check for template syntax issues
cat docker-compose.yml.example | grep -n "platform:\|linux/arm64"
```

**Email Issues**:

```bash
# Run the built-in email diagnostic (tests Postfix container,
# fail2ban integration, host script config, and end-to-end delivery)
./maintenance.sh --test-email --verbose
# Or: make test-email

# Check Postfix container status and logs
docker compose ps postfix
docker compose logs postfix
# Or: make logs-postfix

# Verify Postfix SMTP port is responding
docker compose exec postfix nc -z localhost 587

# Check fail2ban can reach Postfix
docker compose exec fail2ban nc -zv postfix 587

# Send a test email to a specific recipient
./maintenance.sh --test-email --recipient you@example.com

# Debug steps if delivery fails:
#   1. Verify SMTP relay credentials in secrets (./edit-secrets.sh)
#   2. Verify ALLOWED_SENDER_DOMAINS in .env
#   3. Check Postfix relay configuration
#   4. Review Postfix logs: docker compose logs postfix | grep -i error

# Send test email from VaultWarden admin panel
# Navigate to: https://vault.yourdomain.com/admin → SMTP Settings → Send Test Email
```

**Fail2Ban Issues**:

```bash
# Check fail2ban status
docker compose exec fail2ban fail2ban-client status

# Check Cloudflare API connectivity
docker compose logs fail2ban | grep -i cloudflare

# Test API token
curl -X GET "https://api.cloudflare.com/client/v4/zones" \
     -H "Authorization: Bearer YOUR_TOKEN" \
     -H "Content-Type: application/json"

# Validate filter syntax
docker compose exec fail2ban fail2ban-regex /var/log/vaultwarden/vaultwarden.log /data/fail2ban/filter.d/vaultwarden-auth.conf

# NOTE: Web-facing jails (vaultwarden-auth, vaultwarden-admin, vaultwarden-web-*)
# use Cloudflare API ONLY - local iptables removed as traffic is proxied
```

### Emergency Recovery

#### SSH Access Lost (Most Common Emergency)

1. **Use break-glass admin via OCI Console**:
    - Access OCI Console → Compute → Instance → Console Connection
    - Login with break-glass admin credentials
    - Fix firewall: `sudo ufw allow 22/tcp`
    - Fix SSH: `sudo systemctl restart sshd`
    - **Security cleanup**: Delete Console Connection, rotate password
2. **If no break-glass admin configured**:
    - Use OCI boot volume attachment method
    - Create break-glass admin for future: `./create-breakglass-admin.sh`
    - Or use: `make breakglass-create`

## 🛡️ Security Best Practices

### During Initial Setup

- ✅ Use template-based setup: `./setup.sh` (not manual file editing)
- ✅ Log out and log back in after `setup.sh` to apply docker group membership
- ✅ Configure break-glass admin: `./create-breakglass-admin.sh` or `make breakglass-create`
- ✅ Test OCI serial console access (verify it works)
- ✅ Create and test backup restoration: `./backup.sh --type emergency`
- ✅ Generate proper bcrypt hash for admin_basic_auth_hash
- ✅ Validate Cloudflare API tokens work correctly
- ✅ Test email functionality: `make test-email`
- ✅ Run comprehensive health check: `./health.sh` or `make health`

### Ongoing Operations

- ✅ Monitor break-glass admin status regularly
- ✅ Keep template files updated and version controlled
- ✅ Test emergency procedures quarterly
- ✅ Monitor fail2ban effectiveness and API limits
- ✅ Verify UFW rules after any network changes
- ✅ Review container resource usage periodically
- ✅ Test email notifications regularly: `make test-email`
- ✅ Understand Cloudflare-only blocking for web traffic (iptables removed)

### Template Security

- 📝 Never commit actual .env or docker-compose.yml files
- 📝 Keep .example files as the authoritative source
- 📝 Use setup.sh for all configuration generation
- 📝 Validate templates before deployment: `docker compose config`
- 📝 Test template changes in non-production first

## 📚 Documentation

Comprehensive documentation is available in the `docs/` directory:

- **[DEPLOYMENT.md](docs/DEPLOYMENT.md)** - Detailed deployment guide
- **[CONFIGURATION.md](docs/CONFIGURATION.md)** - Complete configuration reference
- **[SECURITY.md](docs/SECURITY.md)** - Security hardening and best practices
- **[OPERATIONS.md](docs/OPERATIONS.md)** - Day-to-day operations guide
- **[BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md)** - Backup and recovery procedures
- **[SCRIPTS.md](docs/SCRIPTS.md)** - Script reference guide
- **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** - Common issues and solutions
- **[MIGRATION.md](docs/MIGRATION.md)** - Migration from other setups
- **[API.md](docs/API.md)** - API usage and integration
- **[ADVANCED-CUSTOMIZATION.md](docs/ADVANCED-CUSTOMIZATION.md)** - Advanced customization options

## 📄 License

MIT License - see LICENSE file for details.
